#if os(macOS)
import AppKit
import CoreMIDI
import Darwin
import MetalKit
import MappingCore

@MainActor enum ShowControlSelfTest {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class MIDITrace: @unchecked Sendable {
        private let lock = NSLock()
        private var packets: [[UInt8]] = []
        func append(_ bytes: [UInt8]) {
            lock.lock()
            defer { lock.unlock() }
            if packets.count < 16 { packets.append(bytes) }
        }
        var values: [[UInt8]] {
            lock.lock()
            defer { lock.unlock() }
            return packets
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message: message) }
    }

    private static func pump(timeout: Double, until ready: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !ready(), ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.008))
        }
        return ready()
    }

    private static func receiver() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        try require(fd >= 0, "Could not create a localhost OSC endpoint")
        var success = false
        defer { if !success { close(fd) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try require(bound == 0 && fcntl(fd, F_SETFL, O_NONBLOCK) == 0, "OSC receiver bind or non-blocking configuration failed")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        try require(named == 0, "Could not read OSC receiver port")
        success = true
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    private static func readOSC(_ fd: Int32) throws -> [OSCMessage] {
        var buffer = [UInt8](repeating: 0, count: 1024)
        var messages: [OSCMessage] = []
        for _ in 0..<16 {
            let size = recv(fd, &buffer, buffer.count, 0)
            if size <= 0 { break }
            messages += try OSCCodec.decode(Data(buffer.prefix(size)))
        }
        return messages
    }

    private static func waitForOSC(_ fd: Int32) throws -> [OSCMessage] {
        var result: [OSCMessage] = []
        var readFailure: Error?
        _ = pump(timeout: 0.7) {
            do { result += try readOSC(fd) }
            catch { readFailure = error }
            return !result.isEmpty || readFailure != nil
        }
        if let readFailure { throw readFailure }
        return result
    }

    static func run() -> Int32 {
        var checks: [String] = []
        var maximumError: Double?
        var sampledPoints = 0
        let started = ProcessInfo.processInfo.systemUptime
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/local/show-control", isDirectory: true)
        func pass(_ name: String) { checks.append(name); print("PASS show control: \(name)") }
        func report(_ passed: Bool, error: String? = nil) {
            var result: [String: Any] = [
                "schemaVersion": 1, "passed": passed, "checks": checks, "checkCount": checks.count,
                "timestampUTC": ISO8601DateFormatter().string(from: Date()),
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "hardwareVerification": false,
                "scope": "Production editor, localhost UDP, isolated CoreMIDI virtual source, external clock fixture process"
            ]
            if let maximumError {
                result["externalClockMaximumPhaseErrorSeconds"] = maximumError
                result["externalClockSampleCount"] = sampledPoints
            }
            if let error { result["error"] = error }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
            }
        }
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try require(MTLCreateSystemDefaultDevice() != nil, "Show control editor needs a logged-in Metal session")
            let editor = EditorController()
            editor.timer?.invalidate()
            editor.timer = nil
            editor.window?.orderOut(nil)
            editor.window?.isReleasedWhenClosed = false
            editor.metalView.isPaused = true
            editor.lightingView.isPaused = true
            defer {
                editor.resetShowControlSession()
                editor.network?.stop()
                editor.midi?.stop()
                editor.lighting?.stop()
                editor.media?.reset()
                editor.dirty = false
                editor.window?.close()
            }

            let (fd, port) = try receiver()
            defer { close(fd) }
            let first = ShowControlEvent(time: 0.5, command: .osc(port: port, address: "/fixture/level", value: .float(0.25)))
            let note = ShowControlEvent(time: 0.75, command: .midi(kind: .noteOn, channel: 2, number: 60, value: 100))
            let missed = ShowControlEvent(time: 1.75, command: .osc(port: port, address: "/fixture/skipped", value: nil))
            let subsequent = ShowControlEvent(time: 2.5, command: .osc(port: port, address: "/fixture/resumed", value: .boolean(true)))
            editor.mutate("Original show control fixture") {
                $0.showControlTracks = [ShowControlTrack(name: "Test output", events: [first, note, missed, subsequent])]
            }
            let host = ProcessInfo.processInfo.systemUptime
            editor.playShow(at: host)
            editor.advanceShow(at: host + 0.51)
            editor.stopShow(at: host + 0.52)
            try require(try readOSC(fd).isEmpty, "Unarmed output emitted an event")
            try require(editor.showControlSession.output.midiSource == 0, "Unarmed output created MIDI endpoint")
            pass("saved tracks remain silent until the session arms outputs")

            try editor.setShowControlOutputArmed(true)
            var inputClient: MIDIClientRef = 0
            var input: MIDIPortRef = 0
            let trace = MIDITrace()
            try require(MIDIClientCreateWithBlock("ApertureCue Show Test Receiver" as CFString, &inputClient, nil) == noErr,
                        "Could not create virtual MIDI test receiver")
            defer { MIDIClientDispose(inputClient) }
            let connected = MIDIInputPortCreateWithBlock(inputClient, "Show test trace" as CFString, &input) { list, _ in
                guard let offset = MemoryLayout<MIDIPacketList>.offset(of: \.packet) else { return }
                var packet = UnsafeRawPointer(list).advanced(by: offset).assumingMemoryBound(to: MIDIPacket.self)
                for _ in 0..<min(list.pointee.numPackets, 16) {
                    let count = min(Int(packet.pointee.length), 256)
                    trace.append(withUnsafeBytes(of: packet.pointee.data) { Array($0.prefix(count)) })
                    packet = UnsafePointer(MIDIPacketNext(packet))
                }
            }
            try require(connected == noErr, "Could not create test MIDI input port")
            defer { MIDIPortDispose(input) }
            try require(MIDIPortConnectSource(input, editor.showControlSession.output.midiSource, nil) == noErr,
                        "Could not connect to the application's virtual show output")

            let second = ProcessInfo.processInfo.systemUptime
            editor.playShow(at: second)
            editor.advanceShow(at: second)
            editor.advanceShow(at: second + 0.8)
            editor.advanceShow(at: second + 0.8)
            try require(try waitForOSC(fd) == [OSCMessage(address: "/fixture/level", arguments: [.float(0.25)])],
                        "Forward crossing did not emit exactly one typed UDP packet")
            let receivedNote = pump(timeout: 2) { !trace.values.isEmpty }
            try require(receivedNote && trace.values == [[0x91, 60, 100]],
                        "CoreMIDI virtual receiver expected one Note On; found \(trace.values)")
            pass("timed natural crossing emits the expected typed OSC and virtual MIDI exactly once")

            editor.seekShow(to: 2, at: second + 0.85)
            editor.advanceShow(at: second + 0.86)
            try require(try readOSC(fd).isEmpty, "Forward scrub emitted skipped OSC")
            try require(pump(timeout: 2) { trace.values.count == 2 }, "Seek did not release virtual MIDI note")
            try require(trace.values == [[0x91, 60, 100], [0x81, 60, 0]], "MIDI release differed from original note")
            editor.advanceShow(at: second + 1.45)
            let resumedMessages = try waitForOSC(fd)
            try require(resumedMessages == [OSCMessage(address: "/fixture/resumed", arguments: [.bool(true)])],
                        "Expected one natural OSC event after seek; found \(resumedMessages) at \(editor.showRuntime.time) s, \(editor.showControlSession.outputStatus)")
            editor.stopShow(at: second + 1.4)
            editor.resetShowControlSession()
            try require(!editor.showControlSession.outputsArmed && editor.showControlSession.output.midiSource == 0,
                        "Output reset retained virtual source or arm")
            pass("scrubbing skips old events, releases MIDI notes and retains later crossings")

            try editor.armExternalShowClock(source: "fixture", port: 0)
            guard let clockPort = editor.showControlSession.listener?.boundPort else { throw Failure(message: "No external clock port") }
            try require(editor.showControlSession.clock.state == .waiting, "Clock started without a selected source packet")
            let anchor = ProcessInfo.processInfo.systemUptime + 0.7
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["--show-clock-fixture", String(clockPort), String(anchor)]
            var environment = ProcessInfo.processInfo.environment
            environment["APERTURECUE_SHOW_CLOCK_FIXTURE"] = "local-only"
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            var errors: [Double] = []
            let sampled = pump(timeout: 4) {
                let now = ProcessInfo.processInfo.systemUptime
                editor.applyExternalShowClock(at: now)
                editor.advanceShow(at: now)
                if editor.showControlSession.clock.state == .locked, editor.showRuntime.isPlaying,
                   now >= anchor + 0.15, now <= anchor + 1.45 {
                    errors.append(abs(editor.showRuntime.time - (1 + now - anchor)))
                }
                return now > anchor + 1.6
            }
            try require(sampled && errors.count >= 24, "External clock phase measurement had too few running samples")
            maximumError = errors.max()
            sampledPoints = errors.count
            try require((maximumError ?? .infinity) < 0.18, "Interprocess clock phase error exceeded 180 ms")
            try require(pump(timeout: 3) {
                let now = ProcessInfo.processInfo.systemUptime
                editor.applyExternalShowClock(at: now)
                editor.advanceShow(at: now)
                return editor.showControlSession.clock.state == .lost
            }, "Missing external packets did not enter lost state")
            try require(!editor.showRuntime.isPlaying && !editor.media.isPlaying, "External loss did not hold local media/show")
            pass("separate sender process locks on real localhost UDP, measures phase and holds the show on loss")

            let sender = ShowControlOutput()
            defer { sender.stop() }
            let restored = ExternalShowClockPacket(source: "fixture", session: UUID(), sequence: 0, position: 0.25, playing: false)
            try sender.sendOSC(OSCCodec.encode(restored.message()), port: clockPort)
            try require(pump(timeout: 1) {
                let now = ProcessInfo.processInfo.systemUptime
                editor.applyExternalShowClock(at: now)
                editor.advanceShow(at: now)
                return editor.showControlSession.clock.state == .locked
            }, "External clock did not accept a restarted session after loss")
            try require(editor.showRuntime.time == 0.25 && !editor.showRuntime.isPlaying, "Restarted paused sender did not align exactly")
            editor.seekShow(to: 1)
            try require(editor.showControlSession.listener == nil && editor.showControlSession.clock.state == .off &&
                        editor.showRuntime.time == 1, "Local seek did not release external ownership")
            pass("reacquisition restores paused position silently; local seek takes control back")
            report(true)
            return 0
        } catch {
            report(false, error: error.localizedDescription)
            fputs("FAIL show control: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    /// Bounded CLI child for measuring interprocess synchronization only.
    static func clockFixture(arguments: [String]) -> Int32 {
        guard ProcessInfo.processInfo.environment["APERTURECUE_SHOW_CLOCK_FIXTURE"] == "local-only",
              arguments.count == 4, let port = UInt16(arguments[2]), port > 0,
              let start = Double(arguments[3]), start.isFinite,
              abs(start - ProcessInfo.processInfo.systemUptime) < 3 else { return 2 }
        let sender = ShowControlOutput()
        defer { sender.stop() }
        let id = UUID()
        var sequence: Int32 = 0
        if start > ProcessInfo.processInfo.systemUptime {
            Thread.sleep(forTimeInterval: max(0, start - ProcessInfo.processInfo.systemUptime))
        }
        do {
            let until = start + 1.5
            while ProcessInfo.processInfo.systemUptime < until, sequence < 20 {
                let position = 1 + ProcessInfo.processInfo.systemUptime - start
                let packet = ExternalShowClockPacket(source: "fixture", session: id, sequence: sequence,
                                                     position: position, playing: true)
                try sender.sendOSC(OSCCodec.encode(packet.message()), port: port)
                sequence += 1
                Thread.sleep(forTimeInterval: 0.08)
            }
            return sequence > 0 ? 0 : 1
        } catch { return 1 }
    }
}
#endif
