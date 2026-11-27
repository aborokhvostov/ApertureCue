#if os(macOS)
import CoreMIDI
import Foundation
import MappingCore

/// One pending decoded sample crosses from CoreMIDI to the main queue. A
/// generation tied to the selected source invalidates its in-flight callbacks.
private final class MIDITimeCodeReceiveBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let deliver: @MainActor (Int, MIDITimeCodeEvent, Double) -> Void
    private var decoder = MIDITimeCodeDecoder()
    private var generation = 0
    private var source: MIDIEndpointRef = 0
    private var invalidated = false
    private var pending: (MIDITimeCodeEvent, Double)?
    private var scheduled = false
    private static let maximumPackets = 64

    init(deliver: @escaping @MainActor (Int, MIDITimeCodeEvent, Double) -> Void) {
        self.deliver = deliver
    }

    func connect(_ endpoint: MIDIEndpointRef, generation: Int) {
        lock.withLock {
            self.generation = generation
            source = endpoint
            invalidated = false
            decoder.reset()
            pending = nil
        }
    }

    var needsReconnect: Bool { lock.withLock { invalidated } }

    func notice(_ notification: UnsafePointer<MIDINotification>) {
        guard notification.pointee.messageID == .msgObjectRemoved,
              Int(notification.pointee.messageSize) >= MemoryLayout<MIDIObjectAddRemoveNotification>.size else { return }
        let object = UnsafeRawPointer(notification).assumingMemoryBound(to: MIDIObjectAddRemoveNotification.self).pointee.child
        lock.withLock {
            guard source != 0, object == source else { return }
            invalidated = true
            decoder.reset()
            pending = nil
        }
    }

    func receive(_ list: UnsafePointer<MIDIPacketList>, from context: UnsafeMutableRawPointer?) {
        guard let context, let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet),
              let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data) else { return }
        let moment = ProcessInfo.processInfo.systemUptime
        let token = Int(bitPattern: context)
        let shouldSchedule = lock.withLock {
            guard token != 0, generation == token, !invalidated else { return false }
            let count = Int(list.pointee.numPackets)
            guard count <= Self.maximumPackets else { decoder.reset(); return false }
            var bytes: [UInt8] = []
            var packet = UnsafeRawPointer(list).advanced(by: packetOffset).assumingMemoryBound(to: MIDIPacket.self)
            for _ in 0..<count {
                let length = Int(packet.pointee.length)
                guard length <= MIDITimeCodeDecoder.maximumBytesPerFeed - bytes.count else {
                    decoder.reset()
                    return false
                }
                let data = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
                bytes.append(contentsOf: UnsafeBufferPointer(start: data, count: length))
                packet = UnsafePointer(MIDIPacketNext(packet))
            }
            guard let latest = decoder.feed(bytes, at: moment).last else { return false }
            pending = (latest, moment)
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if shouldSchedule { DispatchQueue.main.async { [weak self] in self?.drain() } }
    }

    @MainActor private func drain() {
        let message = lock.withLock { () -> (Int, MIDITimeCodeEvent, Double)? in
            defer { scheduled = false; pending = nil }
            guard !invalidated, let pending, generation != 0 else { return nil }
            return (generation, pending.0, pending.1)
        }
        if let (token, event, time) = message { deliver(token, event, time) }
    }
}

@MainActor final class MIDITimeCodeAdapter {
    let inputUID: Int32
    let inputName: String
    let origin: Double
    var sourceKey: String { "mtc-\(inputUID)" }
    private(set) var isConnected = false
    private(set) var latestEvent: MIDITimeCodeEvent?
    private let handler: (ExternalShowClockPacket, Double) -> Void
    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private var endpoint: MIDIEndpointRef = 0
    private var bridge: MIDITimeCodeReceiveBridge?
    private var nextScanTime = 0.0
    private var generation = 0
    private var connection = 0
    private var sequence: Int32 = 0
    private let session = UUID()

    init(inputUID: Int32, inputName: String, origin: Double,
         handler: @escaping (ExternalShowClockPacket, Double) -> Void) throws {
        guard inputUID != 0, origin.isFinite, (0..<86_400).contains(origin) else {
            throw ProjectError.invalid("select a MIDI source and an origin between 0 and 86399.999 seconds")
        }
        self.inputUID = inputUID
        self.inputName = inputName
        self.origin = origin
        self.handler = handler
        let receiver = MIDITimeCodeReceiveBridge { [weak self] generation, event, time in
            self?.receive(event, at: time, generation: generation)
        }
        bridge = receiver
        do {
            try Self.check(MIDIClientCreateWithBlock("ApertureCue MIDI Time Code" as CFString, &client) { notice in
                receiver.notice(notice)
            }, "create MIDI time-code client")
            try Self.check(MIDIInputPortCreateWithBlock(client, "MIDI Time Code In" as CFString, &port) { list, context in
                receiver.receive(list, from: context)
            }, "create MIDI time-code input")
            refreshEndpoint(at: ProcessInfo.processInfo.systemUptime)
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        bridge?.connect(0, generation: 0)
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func stop() {
        disconnect()
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        bridge = nil
        latestEvent = nil
    }

    func refreshEndpoint(at time: Double) {
        guard port != 0, time.isFinite, time >= nextScanTime else { return }
        nextScanTime = time + 0.25
        let chosen = Self.resolve(inputUID)
        if chosen != endpoint || bridge?.needsReconnect == true { disconnect() }
        guard endpoint == 0, chosen != 0, generation < Int.max else { return }
        generation += 1
        bridge?.connect(chosen, generation: generation)
        if MIDIPortConnectSource(port, chosen, UnsafeMutableRawPointer(bitPattern: generation)) == noErr {
            endpoint = chosen
            connection = generation
            isConnected = true
        } else {
            bridge?.connect(0, generation: 0)
        }
    }

    private func disconnect() {
        bridge?.connect(0, generation: 0)
        connection = 0
        if port != 0, endpoint != 0 { MIDIPortDisconnectSource(port, endpoint) }
        endpoint = 0
        isConnected = false
        latestEvent = nil
    }

    private func receive(_ event: MIDITimeCodeEvent, at time: Double, generation: Int) {
        guard connection == generation, sequence < Int32.max else { return }
        latestEvent = event
        sequence += 1
        let position = event.clockSeconds - origin
        let packet = ExternalShowClockPacket(source: sourceKey, session: session, sequence: sequence,
                                             position: max(0, position), playing: event.motion == .forward && position >= 0)
        handler(packet, time)
    }

    private static func resolve(_ uid: Int32) -> MIDIEndpointRef {
        var resolved: MIDIEndpointRef = 0
        let count = min(MIDIGetNumberOfSources(), 1_024)
        for index in 0..<count {
            let candidate = MIDIGetSource(index)
            var identifier: Int32 = 0
            var offline: Int32 = 0
            guard candidate != 0, MIDIObjectGetIntegerProperty(candidate, kMIDIPropertyUniqueID, &identifier) == noErr,
                  identifier == uid else { continue }
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(candidate, kMIDIPropertyName, &name) == noErr,
               let name, name.takeRetainedValue() as String == ShowControlOutput.midiSourceName { continue }
            if MIDIObjectGetIntegerProperty(candidate, kMIDIPropertyOffline, &offline) == noErr, offline != 0 { continue }
            guard resolved == 0 else { return 0 }
            resolved = candidate
        }
        return resolved
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw SystemFailure(message: "Cannot \(operation): CoreMIDI status \(status)") }
    }
}
#endif
