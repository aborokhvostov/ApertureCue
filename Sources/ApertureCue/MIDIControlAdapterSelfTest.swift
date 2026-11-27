#if os(macOS)
import CoreMIDI
import Foundation
import MappingCore

@MainActor enum MIDIControlAdapterSelfTest {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [UInt8] = []

        var received: [UInt8] {
            lock.lock()
            defer { lock.unlock() }
            return bytes
        }

        func append(_ list: UnsafePointer<MIDIPacketList>) {
            guard let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet),
                  let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data) else { return }
            lock.lock()
            defer { lock.unlock() }
            var packet = UnsafeRawPointer(list).advanced(by: packetOffset).assumingMemoryBound(to: MIDIPacket.self)
            for _ in 0..<min(8, Int(list.pointee.numPackets)) {
                let count = min(Int(packet.pointee.length), max(0, 256 - bytes.count))
                if count == 0 { break }
                let data = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
                bytes.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
                packet = UnsafePointer(MIDIPacketNext(packet))
            }
        }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message: message) }
    }

    private static func pump(_ timeout: Double, until condition: () -> Bool) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < end {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    private static func uid(_ endpoint: MIDIEndpointRef) throws -> Int32 {
        var id: MIDIUniqueID = 0
        try expect(MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr && id != 0,
                   "CoreMIDI virtual endpoint has no unique ID")
        return id
    }

    private static func source(_ client: MIDIClientRef, name: String, uid: Int32? = nil) throws -> MIDIEndpointRef {
        var endpoint: MIDIEndpointRef = 0
        try expect(MIDISourceCreate(client, name as CFString, &endpoint) == noErr, "Cannot create virtual test MIDI source")
        if let uid, MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, uid) != noErr {
            MIDIEndpointDispose(endpoint)
            throw Failure(message: "Cannot restore unique ID to test MIDI source")
        }
        return endpoint
    }

    private static func destination(_ client: MIDIClientRef, name: String, trace: Trace,
                                    uid: Int32? = nil) throws -> MIDIEndpointRef {
        var endpoint: MIDIEndpointRef = 0
        try expect(MIDIDestinationCreateWithBlock(client, name as CFString, &endpoint) { list, _ in
            trace.append(list)
        } == noErr, "Cannot create virtual test MIDI destination")
        if let uid, MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, uid) != noErr {
            MIDIEndpointDispose(endpoint)
            throw Failure(message: "Cannot restore unique ID to test MIDI destination")
        }
        return endpoint
    }

    private static func send(_ messages: [[UInt8]], to source: MIDIEndpointRef) throws {
        guard messages.count <= 4, messages.allSatisfy({ (1...128).contains($0.count) }),
              messages.reduce(0, { $0 + $1.count }) <= 224 else { throw Failure(message: "Virtual MIDI fixture overflow") }
        var storage = MIDIPacketList()
        let result = withUnsafeMutablePointer(to: &storage) { list -> OSStatus in
            var packet = MIDIPacketListInit(list)
            for message in messages {
                let appended = message.withUnsafeBufferPointer { bytes -> UnsafeMutablePointer<MIDIPacket>? in
                    guard let base = bytes.baseAddress else { return nil }
                    return MIDIPacketListAdd(list, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, base)
                }
                guard let appended else { return kMIDIInvalidClient }
                packet = appended
            }
            return MIDIReceived(source, list)
        }
        try expect(result == noErr, "Could not inject original bytes through virtual MIDI source")
    }

    static func run() -> Int32 {
        let start = ProcessInfo.processInfo.systemUptime
        var checks: [String] = []
        func pass(_ name: String) { checks.append(name); print("PASS MIDI control: \(name)") }
        func report(_ passed: Bool, failure: String? = nil) {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("artifacts/local/midi-control", isDirectory: true)
            var data: [String: Any] = [
                "schemaVersion": 1, "passed": passed, "checks": checks, "checkCount": checks.count,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
                "timestampUTC": ISO8601DateFormatter().string(from: Date()), "hardwareVerification": false,
                "scope": "Production CoreMIDI adapter with original virtual source and destination fixtures"
            ]
            if let failure { data["failure"] = failure }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
            }
        }
        do {
            var client: MIDIClientRef = 0
            try expect(MIDIClientCreateWithBlock("ApertureCue MIDI Control Fixture" as CFString, &client, nil) == noErr,
                       "CoreMIDI fixture client failed")
            defer { MIDIClientDispose(client) }
            let suffix = UUID().uuidString
            let firstName = "Original MIDI input A " + suffix
            let outputName = "Original MIDI feedback A " + suffix
            let inputB = try source(client, name: "Original MIDI input B " + suffix)
            var inputA = try source(client, name: firstName)
            var traceA = Trace()
            var destinationA = try destination(client, name: outputName, trace: traceA)
            let traceB = Trace()
            let destinationB = try destination(client, name: "Original MIDI feedback B " + suffix, trace: traceB)
            defer {
                if inputA != 0 { MIDIEndpointDispose(inputA) }
                if destinationA != 0 { MIDIEndpointDispose(destinationA) }
                MIDIEndpointDispose(inputB)
                MIDIEndpointDispose(destinationB)
            }
            let inputAID = try uid(inputA), inputBID = try uid(inputB), outputAID = try uid(destinationA)
            var events: [MIDIControlEvent] = []
            let adapter = MIDIControlAdapter { events.append($0) }
            defer { adapter.stop() }
            try expect(MIDIControlAdapter.inputEndpoints().contains { $0.uid == inputAID } &&
                       MIDIControlAdapter.outputEndpoints().contains { $0.uid == outputAID }, "Virtual endpoints were absent from discovery")
            try adapter.start(inputUID: inputAID, feedbackUID: outputAID)
            try expect(adapter.connectedInputUID == inputAID && adapter.connectedFeedbackUID == outputAID,
                       "Adapter did not bind requested endpoint UIDs")
            try send([[0x90, 42, 90]], to: inputB)
            try send([[0x90, 60, 80], [0xB0, 1, 7], [0xB0, 33, 15]], to: inputA)
            try expect(pump(2) { events.count >= 4 }, "Selected virtual source did not deliver exact MIDI values")
            try expect(events == [.note(channel: 1, note: 60, velocity: 80, isOn: true),
                                  .controlChange(channel: 1, controller: 1, value: 7),
                                  .controlChange(channel: 1, controller: 33, value: 15),
                                  .controlChange14(channel: 1, controller: 1, value: 911)],
                       "Selected and unselected source events differ")
            pass("Discovery and virtual input isolate the selected UID and decode exact 14-bit controller values")

            try adapter.sendFeedback(.controlChange14(channel: 3, controller: 9, value: 1025))
            try expect(pump(2) { traceA.received.count >= 6 }, "MIDI feedback destination did not receive bytes")
            try expect(traceA.received == [0xB2, 9, 8, 0xB2, 41, 1] && traceB.received.isEmpty,
                       "Feedback bytes or isolated destination differ")
            pass("Typed feedback reaches only the selected virtual destination with exact MIDI bytes")

            try send([[0x90, 63, 90]], to: inputA)
            // Give the CoreMIDI callback time to enqueue while main remains
            // between the old callback and replacing the selected connection.
            Thread.sleep(forTimeInterval: 0.03)
            try adapter.start(inputUID: inputBID, feedbackUID: outputAID)
            try send([[0x90, 43, 95]], to: inputB)
            try expect(pump(2) { events.count > 4 }, "New virtual input did not become active")
            try expect(events.count == 5 && events.last == .note(channel: 1, note: 43, velocity: 95, isOn: true),
                       "Old generation published after input selection changed")
            pass("Replacing a selected input discards queued old-generation commands")

            try adapter.start(inputUID: inputAID, feedbackUID: outputAID)
            try send([[0xB0, 4, 10]], to: inputA)
            try expect(pump(2) { events.count >= 6 }, "Original input did not receive the pre-disconnect coarse value")
            let oldInputGeneration = adapter.inputConnectionGeneration
            let oldOutputGeneration = adapter.feedbackConnectionGeneration
            try expect(MIDIEndpointDispose(inputA) == noErr && MIDIEndpointDispose(destinationA) == noErr,
                       "Could not remove original virtual endpoints")
            inputA = 0
            destinationA = 0
            try expect(pump(2) { adapter.connectedInputUID == nil && adapter.connectedFeedbackUID == nil },
                       "Endpoint disappearance did not clear bound input/output")
            try expect(adapter.inputConnectionGeneration == 0 && adapter.feedbackConnectionGeneration == 0,
                       "Disconnected endpoints retained a bound generation")
            var rejectedUnavailableSend = false
            do { try adapter.sendFeedback(.controlChange(channel: 1, controller: 7, value: 40)) }
            catch { rejectedUnavailableSend = true }
            try expect(rejectedUnavailableSend, "Missing feedback endpoint accepted a send")
            inputA = try source(client, name: firstName, uid: inputAID)
            traceA = Trace()
            destinationA = try destination(client, name: outputName, trace: traceA, uid: outputAID)
            try expect(pump(3) { adapter.connectedInputUID == inputAID && adapter.connectedFeedbackUID == outputAID },
                       "Exact UID replacement did not reconnect after topology notifications")
            try expect(adapter.inputConnectionGeneration > oldInputGeneration && adapter.feedbackConnectionGeneration > oldOutputGeneration,
                       "Reconnect retained the previous endpoint generation")
            try send([[0xB0, 36, 5]], to: inputA)
            try expect(pump(2) { events.count >= 7 }, "Replacement virtual input did not deliver")
            try expect(events.count == 7 && events.last == .controlChange(channel: 1, controller: 36, value: 5),
                       "New connection inherited an old 14-bit CC latch")
            try adapter.sendFeedback(.note(channel: 2, note: 48, velocity: 20, isOn: false))
            try expect(pump(2) { traceA.received.count >= 3 }, "Replacement feedback destination did not receive")
            try expect(traceA.received == [0x81, 48, 20] && traceB.received.isEmpty, "Replacement feedback replayed or reached another route")
            pass("Exact UID reconnection clears the decoder, keeps feedback isolated and drops sends while disconnected")

            for _ in 0..<8 { try send([Array(repeating: 0xF8, count: 112)], to: inputA) }
            Thread.sleep(forTimeInterval: 0.08)
            try expect(pump(2) { adapter.droppedInputBatches > 0 }, "Flood did not exercise the bounded main-thread mailbox")
            try expect(events.count >= 8 && events.dropFirst(7).allSatisfy({ $0 == .realtime(.clock) }),
                       "Virtual clock flood emitted unexpected channel commands")
            adapter.stop()
            let finalCount = events.count
            try send([[0x90, 70, 100]], to: inputA)
            _ = pump(0.13) { events.count != finalCount }
            try expect(events.count == finalCount && !adapter.isRunning, "Stopped adapter still delivered input")
            pass("Realtime flood is bounded and stopping rejects further callbacks")
            report(true)
            return 0
        } catch {
            report(false, failure: error.localizedDescription)
            fputs("FAIL MIDI control: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
#endif
