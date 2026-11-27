#if os(macOS)
import AppKit
import Darwin
import MappingCore

/// One newest sampled frame is retained while the UDP worker is busy.
@MainActor final class LightingController {
    enum WireProtocol: String, Hashable, Sendable { case artnet = "Art-Net", sacn = "sACN" }

    private static let maximumLiveUniverses = 128
    var fixtures: [Fixture] = [] {
        didSet {
            guard fixtures != oldValue else { return }
            patchGeneration &+= 1
            patch = nil
            if source == .composition {
                pending = nil
                wake?.cancel()
                wake = nil
            }
        }
    }
    var isSampling = false
    var isSending = false
    private(set) var lastUniverses: [Int: [UInt8]] = [:]
    private(set) var errorDescription = ""
    var destination = "127.0.0.1"
    var wireProtocol: WireProtocol = .artnet
    private(set) var multicast = false
    private(set) var synchronizationAddress = 0
    private(set) var maximumRateHz = 30.0
    private(set) var discoveryInFlight = false

    private struct Destination: Hashable {
        let mode: WireProtocol
        let address: String
        let multicast: Bool
        init(_ target: LightingWireTarget) {
            mode = target.mode
            address = target.multicast ? "" : target.address
            multicast = target.multicast
        }
    }
    private struct SequenceState {
        var universe: [Int: UInt8] = [:]
        var sync: UInt8 = 0
        var lastFrame: Double?
        var lastUse = 0.0
    }
    private struct Stream {
        let target: LightingWireTarget
        let channelCounts: [Int: Int]
    }
    private let cid = UUID()
    private var destinations: [Destination: SequenceState] = [:]
    private var stream: Stream?
    private enum FrameSource { case composition, sequence, networkInput }
    private var source = FrameSource.composition
    private var previewBeforeAlternate = false
    private var lastSampleAt: Double?
    private var patchGeneration: UInt64 = 0
    private var patch: FixturePatchPlan?
    private var samplerBusy = false
    private var senderBusy = false
    private var generation: UInt64 = 0
    private var pending: [Int: [UInt8]]?
    private var wake: DispatchWorkItem?
    private var retryAfter = 0.0
    private var lastPoll = -Double.infinity
    private let queue = DispatchQueue(label: "org.aperturecue.lighting", qos: .userInitiated)
    private let discoveryQueue = DispatchQueue(label: "org.aperturecue.lighting.discovery", qos: .utility)
    private let multicastInterface: in_addr?
    private var monitorWindow: LightingMonitorWindow?
    let monitorInput = LightingMonitorInput()
    let lightingAdapterPreview = LightingAdapterPreviewController()
    private(set) lazy var sequenceSession = DMXSequenceSession(
        ensureSampling: { [weak self] in
            guard let self, self.source == .composition, !self.fixtures.isEmpty else {
                throw SystemFailure(message: "Add a fixture and select composition sampling before recording.")
            }
            self.isSampling = true
        },
        canOutput: { [weak self] in self?.isSending == true && self?.source == .composition },
        beginOutput: { [weak self] universes in try self?.beginAlternate(.sequence, universes: universes) },
        outputFrame: { [weak self] frame, discontinuity in
            guard let self, self.isSending, self.source == .sequence else {
                throw SystemFailure(message: "Sequence output is no longer armed.")
            }
            if discontinuity { self.supersedeUnsentFrame() }
            self.acceptFrame(frame)
        },
        endOutput: { [weak self] in self?.endAlternate(.sequence) }
    )
    private var networkWindow: LightingNetworkWindow?
    var renderer: MetalRenderer!
    private var sourceFrame: [Int: [UInt8]] = [:]
    var blackout = false {
        didSet {
            guard blackout != oldValue, !sourceFrame.isEmpty else { return }
            if blackout && source == .composition {
                sequenceSession.capture(sourceFrame.mapValues { Self.zeros($0.count) })
            }
            if blackout || source != .composition { acceptFrame(sourceFrame) }
        }
    }

    init(loopbackMulticast: Bool = false) {
        multicastInterface = loopbackMulticast ? in_addr(s_addr: inet_addr("127.0.0.1")) : nil
    }

    func update(surfaces: [Surface], outputs: [OutputConfig] = []) {
        guard isSampling, source == .composition else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastSampleAt, now - lastSampleAt >= 1, !lastUniverses.isEmpty {
            sequenceSession.capture([:], at: now)
            acceptFrame([:])
        }
        guard !samplerBusy else { return }
        guard !fixtures.isEmpty else {
            if !lastUniverses.isEmpty { acceptFrame([:]) }
            return
        }
        let sampledFixtures = fixtures
        let plan: FixturePatchPlan
        do {
            if let patch { plan = patch }
            else {
                try validateLivePatch()
                if isSending { try validateUniverses(Set(fixtures.map(\.universe)), for: wireProtocol) }
                plan = try FixtureSampler.makePlan(fixtures: sampledFixtures)
                patch = plan
            }
        } catch {
            stop()
            errorDescription = error.localizedDescription
            networkWindow?.updateStatus()
            monitorWindow?.update()
            return
        }
        let outputIDs = Array(Set(sampledFixtures.map(\.outputID))).sorted {
            ($0?.uuidString ?? "") < ($1?.uuidString ?? "")
        }
        let routes = outputIDs.map { id -> MetalRenderer.SnapshotRoute in
            guard let id else {
                return MetalRenderer.SnapshotRoute(outputID: renderer.outputID, edgeBlend: renderer.edgeBlend)
            }
            return MetalRenderer.SnapshotRoute(outputID: id, edgeBlend: outputs.first { $0.id == id }?.edgeBlend ?? .init())
        }
        let areaRoutes = Set(sampledFixtures.filter { $0.sampling != nil }.map(\.outputID))
        let overrides = Self.fixtureOverrides(fixtures: sampledFixtures, surfaces: surfaces)
        let requestGeneration = generation
        let requestPatch = patchGeneration
        samplerBusy = true
        renderer.surfaces = surfaces
        renderer.snapshotBatchAsync(width: 320, height: 180, routes: routes) { [weak self] images in
            guard let self else { return }
            self.samplerBusy = false
            guard self.isSampling, self.source == .composition, self.generation == requestGeneration,
                  self.patchGeneration == requestPatch, let images else { return }
            var rasters: [UUID?: LightingRaster] = [:]
            for (id, image) in zip(outputIDs, images) {
                guard let raster = LightingRaster(image, withArea: areaRoutes.contains(id)) else { return }
                rasters[id] = raster
            }
            do {
                let levels = try plan.sample(overrides: overrides) { fixture, point in
                    rasters[fixture.outputID]?.color(at: point, area: fixture.sampling) ?? MappingCore.RGBColor(0, 0, 0)
                }
                self.publishUniverseFrame(levels)
            } catch {
                self.stop()
                self.errorDescription = error.localizedDescription
                self.networkWindow?.updateStatus()
                self.monitorWindow?.update()
            }
        }
    }

    static func fixtureOverrides(fixtures: [Fixture], surfaces: [Surface]) -> [UUID: [String: Double]] {
        let drives = fixtures.flatMap { ($0.definition?.channels ?? []).compactMap(\.drive) }
        guard !drives.isEmpty else { return [:] }
        let byID = Dictionary(surfaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [UUID: [String: Double]] = [:]
        for fixture in fixtures {
            for channel in fixture.definition?.channels ?? [] {
                guard let drive = channel.drive, let surface = byID[drive.surfaceID],
                      let range = try? TimelineEngine.parameterRange(drive.parameter),
                      let value = TimelineEngine.parameterValue(drive.parameter, on: surface) else { continue }
                let unit = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                result[fixture.id, default: [:]][channel.name] = min(1, max(0, unit))
            }
        }
        return result
    }

    private static func zeros(_ count: Int) -> [UInt8] { Array(repeating: 0, count: count) }

    private func validateLivePatch() throws {
        guard Set(fixtures.map(\.universe)).count <= Self.maximumLiveUniverses else {
            throw SystemFailure(message: "Live lighting supports up to \(Self.maximumLiveUniverses) patched universes.")
        }
    }

    private func validateUniverses(_ universes: Set<Int>, for mode: WireProtocol) throws {
        let range = mode == .sacn ? 1...63999 : 0...32767
        guard universes.allSatisfy(range.contains) else {
            throw SystemFailure(message: "\(mode.rawValue) requires universes \(range.lowerBound)…\(range.upperBound).")
        }
    }

    func publishUniverseFrame(_ universes: [Int: [UInt8]]) {
        guard isSampling, source == .composition else { return }
        lastSampleAt = ProcessInfo.processInfo.systemUptime
        // Blackout also zeros manual/position slots and removes any prior nonzero frame.
        sequenceSession.capture(blackout ? universes.mapValues { Self.zeros($0.count) } : universes)
        acceptFrame(universes)
    }

    private func acceptFrame(_ input: [Int: [UInt8]]) {
        sourceFrame = input
        let universes = blackout ? input.mapValues { Self.zeros($0.count) } : input
        lastUniverses = universes
        if source == .composition { lightingAdapterPreview.publish(universes) }
        monitorWindow?.update()
        guard isSending else { return }
        pending = universes
        flush()
    }

    private func supersedeUnsentFrame() {
        pending = nil
        wake?.cancel()
        wake = nil
        retryAfter = 0
        generation &+= 1
    }

    private func beginAlternate(_ incoming: FrameSource, universes: Set<Int>) throws {
        guard source == .composition, isSending else { throw SystemFailure(message: "Arm network output first.") }
        try validateUniverses(universes, for: wireProtocol)
        previewBeforeAlternate = isSampling
        supersedeUnsentFrame()
        lightingAdapterPreview.stop()
        source = incoming
    }

    private func endAlternate(_ expectedSource: FrameSource) {
        guard source == expectedSource else { return }
        let keepPreview = previewBeforeAlternate
        stop()
        isSampling = keepPreview
        monitorWindow?.update()
    }

    var isRoutingIncoming: Bool { source == .networkInput }
    var canRouteIncoming: Bool { source == .composition && isSending }

    func routeIncoming() throws {
        guard let universe = monitorInput.listenUniverse else { throw SystemFailure(message: "Start the DMX receiver first.") }
        try beginAlternate(.networkInput, universes: [universe])
        updateIncoming(at: ProcessInfo.processInfo.systemUptime)
    }

    func stopRoutingIncoming() { endAlternate(.networkInput) }

    func updateIncoming(at now: Double) {
        if source == .networkInput {
            let frame = monitorInput.snapshot(at: now).frame
            let levels = frame.map { [$0.universe: $0.channels] } ?? [:]
            if levels != sourceFrame || !levels.isEmpty { acceptFrame(levels) }
        }
        monitorWindow?.update(at: now)
    }

    func stopDocument(completion: (@MainActor @Sendable () -> Void)? = nil) {
        monitorInput.stop()
        sequenceSession.reset()
        stop(completion: completion)
    }

    func startNetworkOutput(mode: WireProtocol, address: String, multicast: Bool,
                            synchronizationAddress: Int, maximumRateHz: Double) throws {
        guard maximumRateHz.isFinite, (1...30).contains(maximumRateHz) else {
            throw SystemFailure(message: "Lighting output requires a rate from 1 to 30 Hz")
        }
        guard mode == .sacn || (!multicast && synchronizationAddress == 0),
              (0...63999).contains(synchronizationAddress) else {
            throw SystemFailure(message: "Only sACN supports multicast and synchronization here")
        }
        if !multicast { _ = try LightingUDP.unicastAddress(address) }
        try validateLivePatch()
        try validateUniverses(Set(fixtures.map(\.universe)), for: mode)
        stop()
        self.wireProtocol = mode
        self.destination = address
        self.multicast = multicast
        self.synchronizationAddress = synchronizationAddress
        self.maximumRateHz = maximumRateHz
        self.errorDescription = ""
        isSampling = true
        isSending = true
        sequenceSession.refreshNetworkState()
        networkWindow?.updateStatus()
    }

    func validateDestination() throws {
        if !multicast { _ = try LightingUDP.unicastAddress(destination) }
    }

    func stop(completion: (@MainActor @Sendable () -> Void)? = nil) {
        generation &+= 1
        source = .composition
        isSampling = false
        isSending = false
        lastSampleAt = nil
        sequenceSession.networkOutputWasStopped()
        if sequenceSession.isRecording {
            sequenceSession.capture([:])
            sequenceSession.finishCapture()
        }
        errorDescription = ""
        pending = nil
        wake?.cancel()
        wake = nil
        retryAfter = 0
        if let stream {
            self.stream = nil
            let black = stream.channelCounts.mapValues { Array(repeating: UInt8(0), count: $0) }
            if let packets = try? packets(black, retired: stream.channelCounts, target: stream.target) {
                let target = stream.target
                let interface = multicastInterface
                let token = generation
                queue.async { [weak self] in
                    do {
                        try LightingUDP.transmit(packets, target: target, multicastInterface: interface)
                    } catch {
                        let message = error.localizedDescription
                        DispatchQueue.main.async {
                            guard let self, self.generation == token, !self.isSending else { return }
                            self.errorDescription = "Output stopped · zero/termination send failed · " + message
                            self.networkWindow?.updateStatus()
                        }
                    }
                }
            }
        }
        lastUniverses = [:]
        sourceFrame = [:]
        monitorWindow?.update()
        networkWindow?.updateStatus()
        if let completion {
            let drain = DispatchGroup()
            drain.enter()
            lightingAdapterPreview.stop { drain.leave() }
            drain.enter()
            queue.async { drain.leave() }
            drain.notify(queue: .main) { completion() }
        } else {
            lightingAdapterPreview.stop()
        }
    }

    private var selectedTarget: LightingWireTarget {
        LightingWireTarget(mode: wireProtocol, address: destination, multicast: wireProtocol == .sacn && multicast,
                           synchronizationAddress: wireProtocol == .sacn ? synchronizationAddress : 0)
    }

    private func flush() {
        guard isSending, !senderBusy, let universes = pending else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let target = selectedTarget
        let lastFrame = destinations[Destination(target)]?.lastFrame
        let readyAt = max(retryAfter, lastFrame.map { $0 + 1 / maximumRateHz } ?? 0)
        if now < readyAt {
            guard wake == nil else { return }
            let token = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == token else { return }
                self.wake = nil
                self.flush()
            }
            wake = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (readyAt - now), execute: work)
            return
        }
        wake?.cancel()
        wake = nil
        pending = nil
        do {
            try validateDestination()
            let previousCounts = stream?.target == target ? stream?.channelCounts ?? [:] : [:]
            let retired = previousCounts.filter { universes[$0.key] == nil }
            var update = universes
            for (universe, count) in retired { update[universe] = Array(repeating: 0, count: count) }
            guard !update.isEmpty else { return }
            let batch = try packets(update, retired: retired, target: target, frameTime: now)
            let currentCounts = universes.mapValues(\.count)
            let attempted = previousCounts.merging(currentCounts) { _, new in new }
            stream = Stream(target: target, channelCounts: attempted)
            let token = generation
            let interface = multicastInterface
            senderBusy = true
            queue.async { [weak self] in
                let failure: String?
                do {
                    try LightingUDP.transmit(batch, target: target, multicastInterface: interface)
                    failure = nil
                } catch {
                    failure = error.localizedDescription
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.senderBusy = false
                    if self.generation == token, self.isSending {
                        let completed = ProcessInfo.processInfo.systemUptime
                        self.destinations[Destination(target)]?.lastFrame = completed
                        self.errorDescription = failure.map { $0 + " · retrying output" } ?? ""
                        if failure == nil {
                            self.stream = Stream(target: target, channelCounts: currentCounts)
                        } else {
                            self.retryAfter = completed + 0.5
                            if self.pending == nil { self.pending = self.lastUniverses }
                        }
                        self.networkWindow?.updateStatus()
                    }
                    self.flush()
                }
            }
        } catch {
            stop()
            errorDescription = error.localizedDescription
            networkWindow?.updateStatus()
        }
    }

    private func packets(_ levels: [Int: [UInt8]], retired: [Int: Int], target: LightingWireTarget,
                         frameTime: Double? = nil) throws -> [LightingDatagram] {
        let key = Destination(target)
        var sequence = destinations[key] ?? SequenceState()
        var result: [LightingDatagram] = []
        func data(_ universe: Int, channels: [UInt8], terminated: Bool) throws -> LightingDatagram {
            let previous = sequence.universe[universe] ?? 0
            let next: UInt8 = target.mode == .artnet && previous == 255 ? 1 : previous &+ 1
            sequence.universe[universe] = next
            let encoded: Data
            if target.mode == .artnet {
                encoded = try ArtNetCodec.encode(.init(universe: universe, sequence: next, channels: channels))
            } else {
                encoded = try SACNCodec.encode(.init(universe: universe, sequence: next, cid: cid, channels: channels,
                                                    options: terminated ? 0x40 : 0,
                                                    synchronizationAddress: terminated ? 0 : target.synchronizationAddress))
            }
            return LightingDatagram(destination: try target.destination(for: universe), data: encoded)
        }
        for universe in levels.keys.sorted() {
            if let channels = levels[universe] { result.append(try data(universe, channels: channels, terminated: false)) }
        }
        if target.synchronizationAddress > 0, !result.isEmpty {
            sequence.sync &+= 1
            let address = target.synchronizationAddress
            let encoded = try SACNSynchronizationCodec.encode(.init(address: address, sequence: sequence.sync, cid: cid))
            result.append(LightingDatagram(destination: try target.destination(for: address), data: encoded))
        }
        if target.mode == .sacn {
            for universe in retired.keys.sorted() {
                guard let count = retired[universe] else { continue }
                let black = Array(repeating: UInt8(0), count: count)
                for _ in 0..<3 { result.append(try data(universe, channels: black, terminated: true)) }
            }
        }
        // Bound saved sequence state across long editing sessions. Active
        // streams keep their own per-universe counters, including on stop.
        if sequence.universe.count > 8192 {
            let retained = Set(levels.keys)
            sequence.universe = sequence.universe.filter { retained.contains($0.key) }
        }
        if let frameTime { sequence.lastFrame = frameTime }
        sequence.lastUse = ProcessInfo.processInfo.systemUptime
        destinations[key] = sequence
        if destinations.count > 8,
           let oldest = destinations.filter({ $0.key != key }).min(by: { $0.value.lastUse < $1.value.lastUse }) {
            destinations.removeValue(forKey: oldest.key)
        }
        return result
    }

    func discoverArtNet(address: String, range: ClosedRange<Int>, peerPort: UInt16 = ArtNetCodec.port,
                        timeout: Double = 1.2, minimumInterval: Double = 2.75,
                        completion: @escaping (Result<[ArtPollReply], Error>) -> Void) throws {
        guard peerPort != 0, (0.02...3).contains(timeout), (0...3).contains(minimumInterval) else {
            throw SystemFailure(message: "ArtPoll timing or peer port is invalid")
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard !discoveryInFlight, now - lastPoll >= minimumInterval else {
            throw SystemFailure(message: "Wait before requesting another ArtPoll")
        }
        _ = try LightingUDP.unicastAddress(address)
        let request = try ArtNetDiscoveryCodec.encodeTargetedPoll(range)
        lastPoll = now
        discoveryInFlight = true
        discoveryQueue.async { [weak self] in
            let discovered = Result { try LightingUDP.discover(request, target: address, range: range,
                                                               peerPort: peerPort, timeout: timeout) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.discoveryInFlight = false
                completion(discovered)
            }
        }
    }

    func showNetworkSettings() {
        if let networkWindow {
            networkWindow.updateStatus()
            networkWindow.showWindow(nil)
            networkWindow.window?.makeKeyAndOrderFront(nil)
        } else {
            let window = LightingNetworkWindow(lighting: self)
            networkWindow = window
            window.showWindow(nil)
            window.window?.makeKeyAndOrderFront(nil)
        }
    }

    func showSimulator() {
        let monitor = monitorWindow ?? LightingMonitorWindow(lighting: self)
        monitorWindow = monitor
        monitor.showWindow(nil)
        monitor.window?.makeKeyAndOrderFront(nil)
        monitor.update()
    }
}
#endif
