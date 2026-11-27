#if os(macOS)
import AppKit
import Darwin
import MappingCore

/// One newest sampled frame is retained while the UDP worker is busy.
@MainActor final class LightingController {
    enum WireProtocol: String, Hashable, Sendable { case artnet = "Art-Net", sacn = "sACN" }

    var fixtures: [Fixture] = []
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
    private var simulator: NSWindow?
    private var swatches: FixturePreview?
    private var networkWindow: LightingNetworkWindow?
    var renderer: MetalRenderer!

    init(loopbackMulticast: Bool = false) {
        multicastInterface = loopbackMulticast ? in_addr(s_addr: inet_addr("127.0.0.1")) : nil
    }

    func update(surfaces: [Surface]) {
        guard isSampling, !samplerBusy else { return }
        if fixtures.isEmpty {
            if !lastUniverses.isEmpty { publishUniverseFrame([:]) }
            return
        }
        samplerBusy = true
        renderer.surfaces = surfaces
        let requestGeneration = generation
        let sampledFixtures = fixtures
        renderer.snapshotAsync(width: 320, height: 180) { [weak self] image in
            guard let self else { return }
            self.samplerBusy = false
            guard self.isSampling, self.generation == requestGeneration,
                  let image, let data = image.bitmapData else { return }
            do {
                let universes = try FixtureSampler.sample(fixtures: sampledFixtures) { point in
                    let x = max(0, min(image.pixelsWide - 1, Int(point.x * Double(image.pixelsWide))))
                    let y = max(0, min(image.pixelsHigh - 1, Int(point.y * Double(image.pixelsHigh))))
                    let i = y * image.bytesPerRow + x * 4
                    return RGBColor(Double(data[i]) / 255, Double(data[i + 1]) / 255, Double(data[i + 2]) / 255)
                }
                self.publishUniverseFrame(universes)
            } catch {
                self.stop()
                self.errorDescription = error.localizedDescription
                self.networkWindow?.updateStatus()
            }
        }
    }

    func publishUniverseFrame(_ universes: [Int: [UInt8]]) {
        guard isSampling else { return }
        lastUniverses = universes
        swatches?.universes = universes
        guard isSending else { return }
        pending = universes
        flush()
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
        if mode == .sacn, fixtures.contains(where: { $0.universe == 0 }) {
            throw SystemFailure(message: "sACN universes start at 1")
        }
        stop()
        self.wireProtocol = mode
        self.destination = address
        self.multicast = multicast
        self.synchronizationAddress = synchronizationAddress
        self.maximumRateHz = maximumRateHz
        self.errorDescription = ""
        isSampling = true
        isSending = true
        networkWindow?.updateStatus()
    }

    func validateDestination() throws {
        if !multicast { _ = try LightingUDP.unicastAddress(destination) }
    }

    func stop(completion: (@MainActor @Sendable () -> Void)? = nil) {
        generation &+= 1
        isSampling = false
        isSending = false
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
        swatches?.universes = [:]
        networkWindow?.updateStatus()
        if let completion { queue.async { DispatchQueue.main.async { completion() } } }
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
        if let simulator { simulator.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect:NSRect(x:100,y:100,width:760,height:300),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        w.title = "ApertureCue · LED simulator · No hardware verification"; w.isReleasedWhenClosed = false
        let preview = FixturePreview(); fill(preview,in:w.contentView!); preview.universes = lastUniverses
        simulator = w; swatches = preview; w.center(); w.makeKeyAndOrderFront(nil)
    }
}

final class FixturePreview:NSView {
    var universes:[Int:[UInt8]] = [:] { didSet { needsDisplay = true } }
    override var isFlipped:Bool { true }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.setFill(); bounds.fill()
        var y:CGFloat = 12
        for universe in universes.keys.sorted() {
            ("Universe \(universe) · raw RGB channel triplets" as NSString).draw(at:NSPoint(x:12,y:y),withAttributes:[.foregroundColor:NSColor.white,.font:NSFont.systemFont(ofSize:12)])
            y += 24; let channels = universes[universe]!
            for i in stride(from:0,to:min(channels.count,180),by:3) {
                let cell = i/3, x = CGFloat(cell%30)*24+12, row = CGFloat(cell/30)*24
                let c = NSColor(calibratedRed:Double(channels[i])/255,green:Double(channels[i+1])/255,blue:Double(channels[i+2])/255,alpha:1)
                c.setFill(); NSBezierPath(roundedRect:NSRect(x:x,y:y+row,width:20,height:20),xRadius:3,yRadius:3).fill()
            }; y += 58
        }
    }
}
#endif
