#if os(macOS)
import CoreMIDI
import Foundation
import MappingCore

/// CoreMIDI serializes callbacks for an input port. The lock also protects
/// connection replacement and bounded delivery to the main actor.
private final class MIDIControlReceiveBridge: @unchecked Sendable {
    static let maximumPacketsPerCallback = 64
    static let maximumPendingEvents = 256
    private let lock = NSLock()
    private let deliver: @MainActor (Int, [MIDIControlEvent], Int) -> Void
    private var generation = 0
    private var codec = MIDIControlCodec()
    private var pending: [MIDIControlEvent] = []
    private var droppedBatches = 0
    private var scheduled = false

    init(deliver: @escaping @MainActor (Int, [MIDIControlEvent], Int) -> Void) {
        self.deliver = deliver
    }

    func setConnection(_ generation: Int) {
        lock.lock()
        self.generation = generation
        codec.reset()
        pending.removeAll(keepingCapacity: true)
        droppedBatches = 0
        lock.unlock()
    }

    func receive(_ list: UnsafePointer<MIDIPacketList>, context: UnsafeMutableRawPointer?) {
        guard let context, let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet),
              let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data) else { return }
        let token = Int(bitPattern: context)
        // A connection reference is only a generation number. The receive
        // block retains this bridge, and never dereferences the opaque value.
        lock.lock()
        guard token == generation, generation != 0 else { lock.unlock(); return }
        var bytes: [UInt8] = []
        let packetCount = Int(list.pointee.numPackets)
        var truncated = packetCount > Self.maximumPacketsPerCallback
        var packet = UnsafeRawPointer(list).advanced(by: packetOffset).assumingMemoryBound(to: MIDIPacket.self)
        for index in 0..<min(Self.maximumPacketsPerCallback, packetCount) {
            let length = Int(packet.pointee.length)
            let available = MIDIControlCodec.maximumBytesPerFeed - bytes.count
            let count = min(available, length)
            if count > 0 {
                let data = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
                bytes.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
            }
            if count < length || (bytes.count == MIDIControlCodec.maximumBytesPerFeed && index + 1 < packetCount) {
                truncated = true
                break
            }
            packet = UnsafePointer(MIDIPacketNext(packet))
        }
        pending.append(contentsOf: codec.feed(bytes))
        let eventsTruncated = codec.eventsTruncatedLastFeed
        if truncated { codec.reset() }
        let excess = max(0, pending.count - Self.maximumPendingEvents)
        if excess > 0 { pending.removeFirst(excess) }
        if truncated || excess > 0 || eventsTruncated {
            droppedBatches = min(droppedBatches + 1, 1_000_000)
        }
        let shouldSchedule = !scheduled && (!pending.isEmpty || droppedBatches > 0)
        if shouldSchedule { scheduled = true }
        lock.unlock()
        if shouldSchedule { DispatchQueue.main.async { [weak self] in self?.drain() } }
    }

    @MainActor private func drain() {
        lock.lock()
        let token = generation
        let events = pending
        let drops = droppedBatches
        pending.removeAll(keepingCapacity: true)
        droppedBatches = 0
        scheduled = false
        lock.unlock()
        if token != 0 && (!events.isEmpty || drops > 0) { deliver(token, events, drops) }
    }
}

private final class MIDIControlTopologyBridge: @unchecked Sendable {
    private static let maximumRemovals = 64
    private let lock = NSLock()
    private var removed: Set<MIDIObjectRef> = []
    private var scheduled = false
    private var overflow = false
    private let deliver: @MainActor (Set<MIDIObjectRef>, Bool) -> Void

    init(deliver: @escaping @MainActor (Set<MIDIObjectRef>, Bool) -> Void) {
        self.deliver = deliver
    }

    func receive(_ message: UnsafePointer<MIDINotification>) {
        let kind = message.pointee.messageID
        // Driver property/setup changes and endpoint appearance are enough to
        // rescan. Clock traffic never reaches this notification path.
        guard kind == .msgSetupChanged || kind == .msgObjectAdded ||
              kind == .msgObjectRemoved || kind == .msgPropertyChanged else { return }
        let removedObject: MIDIObjectRef?
        if kind == .msgObjectRemoved, Int(message.pointee.messageSize) >= MemoryLayout<MIDIObjectAddRemoveNotification>.size {
            removedObject = UnsafeRawPointer(message).assumingMemoryBound(to: MIDIObjectAddRemoveNotification.self).pointee.child
        } else {
            removedObject = nil
        }
        lock.lock()
        if let removedObject {
            if removed.count < Self.maximumRemovals { removed.insert(removedObject) }
            else { overflow = true }
        }
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if shouldSchedule { DispatchQueue.main.async { [weak self] in self?.drain() } }
    }

    @MainActor private func drain() {
        lock.lock()
        let removals = removed, overflowed = overflow
        removed.removeAll(keepingCapacity: true)
        overflow = false
        scheduled = false
        lock.unlock()
        deliver(removals, overflowed)
    }
}

/// A session owns one selected MIDI 1.0 input and an optional selected feedback
/// destination. Endpoint identity comes from CoreMIDI's persistent unique ID.
@MainActor final class MIDIControlAdapter {
    struct Endpoint: Equatable {
        let uid: Int32
        let name: String
    }

    private static let maximumEndpointScan = 1024
    private var client: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var outputPort: MIDIPortRef = 0
    private var inputRef: MIDIEndpointRef = 0
    private var outputRef: MIDIEndpointRef = 0
    private var requestedInput: Int32?
    private var requestedFeedback: Int32?
    private var sessionID: UUID?
    private var connectionGeneration = 0
    private var connectedGeneration = 0
    private var receiver: MIDIControlReceiveBridge?
    private var topology: MIDIControlTopologyBridge?
    private let handler: (MIDIControlEvent) -> Void
    var onEndpointsChanged: (() -> Void)?
    private(set) var connectedInputUID: Int32?
    private(set) var connectedFeedbackUID: Int32?
    var inputConnectionGeneration: Int { connectedGeneration }
    private(set) var feedbackConnectionGeneration = 0
    private(set) var droppedInputBatches = 0
    var isRunning: Bool { client != 0 }

    init(handler: @escaping (MIDIControlEvent) -> Void) { self.handler = handler }

    static func inputEndpoints() -> [Endpoint] { endpoints(input: true).map(\.endpoint) }
    static func outputEndpoints() -> [Endpoint] { endpoints(input: false).map(\.endpoint) }

    func start(inputUID: Int32?, feedbackUID: Int32? = nil) throws {
        guard inputUID != 0, feedbackUID != 0, inputUID != nil || feedbackUID != nil else {
            throw SystemFailure(message: "Select a MIDI input or feedback destination")
        }
        stop()
        requestedInput = inputUID
        requestedFeedback = feedbackUID
        let id = UUID()
        sessionID = id
        let notifications = MIDIControlTopologyBridge { [weak self] removed, overflowed in
            guard let self, self.sessionID == id else { return }
            self.refreshEndpoints(removed: removed, overflowed: overflowed)
        }
        let events = MIDIControlReceiveBridge { [weak self] generation, events, drops in
            guard let self, self.sessionID == id, self.connectedGeneration == generation else { return }
            self.droppedInputBatches = min(self.droppedInputBatches + drops, 1_000_000)
            for event in events {
                guard self.sessionID == id, self.connectedGeneration == generation else { break }
                self.handler(event)
            }
        }
        topology = notifications
        receiver = events
        do {
            try Self.check(MIDIClientCreateWithBlock("ApertureCue Mapped MIDI" as CFString, &client) { notice in
                notifications.receive(notice)
            }, "create MIDI client")
            if inputUID != nil {
                try Self.check(MIDIInputPortCreateWithBlock(client, "Mapped MIDI In" as CFString, &inputPort) { list, context in
                    events.receive(list, context: context)
                }, "create MIDI input port")
            }
            if feedbackUID != nil {
                try Self.check(MIDIOutputPortCreate(client, "Mapped MIDI Feedback" as CFString, &outputPort),
                               "create MIDI output port")
            }
        } catch {
            stop()
            throw error
        }
        refreshEndpoints()
    }

    func stop() {
        sessionID = nil
        unbindInput()
        outputRef = 0
        connectedFeedbackUID = nil
        feedbackConnectionGeneration = 0
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        if outputPort != 0 { MIDIPortDispose(outputPort); outputPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        receiver = nil
        topology = nil
        requestedInput = nil
        requestedFeedback = nil
        droppedInputBatches = 0
        onEndpointsChanged?()
    }

    deinit {
        receiver?.setConnection(0)
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func refreshEndpoints() { refreshEndpoints(removed: [], overflowed: false) }

    func sendFeedback(_ event: MIDIControlEvent) throws {
        var resolvedUID: Int32 = 0
        guard outputPort != 0, outputRef != 0,
              MIDIObjectGetIntegerProperty(outputRef, kMIDIPropertyUniqueID, &resolvedUID) == noErr,
              resolvedUID == requestedFeedback else {
            throw SystemFailure(message: "Selected MIDI feedback destination is unavailable")
        }
        let messages = try event.encodedMessages()
        try Self.send(messages, port: outputPort, destination: outputRef)
    }

    private func refreshEndpoints(removed: Set<MIDIObjectRef>, overflowed: Bool) {
        guard isRunning else { return }
        if requestedInput != nil {
            let matching = Self.endpoints(input: true).first { $0.endpoint.uid == requestedInput }
            if overflowed || removed.contains(inputRef) || matching?.ref != inputRef { unbindInput() }
            if inputRef == 0, let matching { bindInput(matching.ref, uid: matching.endpoint.uid) }
        }
        if requestedFeedback != nil {
            let matching = Self.endpoints(input: false).first { $0.endpoint.uid == requestedFeedback }
            if overflowed || removed.contains(outputRef) || matching?.ref != outputRef {
                outputRef = 0
                connectedFeedbackUID = nil
                feedbackConnectionGeneration = 0
                if let matching, let token = nextConnectionGeneration() {
                    outputRef = matching.ref
                    connectedFeedbackUID = matching.endpoint.uid
                    feedbackConnectionGeneration = token
                }
            }
        }
        onEndpointsChanged?()
    }

    private func bindInput(_ endpoint: MIDIEndpointRef, uid: Int32) {
        guard inputPort != 0, let token = nextConnectionGeneration() else { return }
        receiver?.setConnection(token)
        let context = UnsafeMutableRawPointer(bitPattern: token)
        if MIDIPortConnectSource(inputPort, endpoint, context) == noErr {
            inputRef = endpoint
            connectedGeneration = token
            connectedInputUID = uid
        } else {
            receiver?.setConnection(0)
        }
    }

    private func nextConnectionGeneration() -> Int? {
        guard connectionGeneration < Int.max else { return nil }
        connectionGeneration += 1
        return connectionGeneration
    }

    private func unbindInput() {
        receiver?.setConnection(0)
        connectedGeneration = 0
        if inputPort != 0, inputRef != 0 { MIDIPortDisconnectSource(inputPort, inputRef) }
        inputRef = 0
        connectedInputUID = nil
    }

    private static func endpoints(input: Bool) -> [(endpoint: Endpoint, ref: MIDIEndpointRef)] {
        let count = min(Int(input ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()), maximumEndpointScan)
        var byUID: [Int32: (Endpoint, MIDIEndpointRef)] = [:]
        var ambiguous = Set<Int32>()
        for index in 0..<count {
            let ref = input ? MIDIGetSource(index) : MIDIGetDestination(index)
            var uid: Int32 = 0, offline: Int32 = 0
            guard ref != 0, MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &uid) == noErr, uid != 0 else { continue }
            if MIDIObjectGetIntegerProperty(ref, kMIDIPropertyOffline, &offline) == noErr, offline != 0 { continue }
            if input && name(ref, property: kMIDIPropertyName) == ShowControlOutput.midiSourceName { continue }
            if byUID[uid] != nil {
                byUID[uid] = nil
                ambiguous.insert(uid)
            }
            guard !ambiguous.contains(uid) else { continue }
            let displayName = name(ref, property: kMIDIPropertyDisplayName) ?? name(ref, property: kMIDIPropertyName) ?? "MIDI endpoint"
            byUID[uid] = (Endpoint(uid: uid, name: displayName), ref)
        }
        return byUID.values.sorted { lhs, rhs in
            lhs.0.name == rhs.0.name ? lhs.0.uid < rhs.0.uid : lhs.0.name < rhs.0.name
        }
    }

    private static func name(_ ref: MIDIEndpointRef, property: CFString) -> String? {
        var raw: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(ref, property, &raw) == noErr, let raw else { return nil }
        let name = raw.takeRetainedValue() as String
        let clean = String(name.prefix(128).filter { character in
            !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        })
        return clean.isEmpty ? nil : clean
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw SystemFailure(message: "Cannot \(operation): CoreMIDI status \(status)") }
    }

    private static func send(_ messages: [[UInt8]], port: MIDIPortRef, destination: MIDIEndpointRef) throws {
        // Encoding admits at most two short messages. Both fit in this
        // packet list's inline capacity with room for per-packet headers.
        var storage = MIDIPacketList()
        let status = withUnsafeMutablePointer(to: &storage) { list -> OSStatus in
            var packet = MIDIPacketListInit(list)
            for message in messages {
                let appended = message.withUnsafeBufferPointer { buffer -> UnsafeMutablePointer<MIDIPacket>? in
                    guard let bytes = buffer.baseAddress else { return nil }
                    return MIDIPacketListAdd(list, MemoryLayout<MIDIPacketList>.size, packet, 0, buffer.count, bytes)
                }
                guard let appended else { return kMIDIInvalidClient }
                packet = appended
            }
            return MIDISend(port, destination, list)
        }
        try check(status, "send MIDI feedback")
    }
}
#endif
