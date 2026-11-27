#if os(macOS)
import AppKit
import CoreMIDI
import MetalKit
import MappingCore

@MainActor enum MIDITimeCodeSelfTest {
    private struct FixtureReady: Codable {
        let uid: Int32
        let name: String
        let phaseAnchor: Double
    }

    private static let origin = 3_600.0
    private static let fixtureGate = "APERTURECUE_TIME_CODE_FIXTURE"

    static func run() -> Int32 {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("aperturecue-original-mtc-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        let began = ProcessInfo.processInfo.systemUptime
        var checks: [String] = []
        var errors: [Double] = []
        var failure: String?
        func pass(_ text: String) { checks.append(text); print("PASS MIDI time code: " + text) }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            NSApplication.shared.setActivationPolicy(.prohibited)
            try expect(MTLCreateSystemDefaultDevice() != nil, "MIDI clock editor needs a logged-in Metal session")
            let editor = EditorController()
            editor.timer?.invalidate()
            editor.timer = nil
            editor.window?.orderOut(nil)
            editor.metalView.isPaused = true
            editor.lightingView.isPaused = true
            editor.network?.stop()
            editor.midi?.stop()
            editor.lighting.stop()
            defer {
                editor.resetShowControlSession()
                editor.closeOutputs()
                editor.media.reset()
                editor.dirty = false
                editor.window?.close()
            }
            func tick() {
                let time = ProcessInfo.processInfo.systemUptime
                editor.applyExternalShowClock(at: time)
                editor.advanceShow(at: time)
            }

            var localClient: MIDIClientRef = 0
            try check(MIDIClientCreateWithBlock("ApertureCue MTC Test" as CFString, &localClient, nil), "create virtual test client")
            defer { MIDIClientDispose(localClient) }
            let distractor = try source(localClient, name: "Original unselected MTC " + UUID().uuidString)
            defer { MIDIEndpointDispose(distractor) }
            let file = directory.appendingPathComponent("source.json")
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            child.arguments = ["--midi-time-code-fixture", file.path]
            var environment = ProcessInfo.processInfo.environment
            environment[fixtureGate] = "virtual-only"
            child.environment = environment
            child.standardOutput = FileHandle.nullDevice
            try child.run()
            defer { if child.isRunning { child.terminate() } }
            var readyMessage: FixtureReady?
            try expect(pump(4) {
                guard let data = try? Data(contentsOf: file) else { return false }
                readyMessage = try? JSONDecoder().decode(FixtureReady.self, from: data)
                return readyMessage != nil
            }, "Separate CoreMIDI fixture process did not publish an endpoint")
            guard let ready = readyMessage else { throw SystemFailure(message: "MIDI source handshake is missing") }
            try expect(pump(2) { MIDIControlAdapter.inputEndpoints().contains { $0.uid == ready.uid } },
                       "Child's virtual MIDI source is absent from CoreMIDI discovery")
            try editor.armMIDITimeCode(inputUID: ready.uid, name: ready.name, origin: origin)
            try expect(editor.showControlSession.timeCode?.isConnected == true, "Selected virtual endpoint did not connect")
            try send([0xF0, 0x7F, 0x7F, 1, 1, 0x21, 0, 29, 7, 0xF7], from: distractor)
            _ = pump(0.12) { tick(); return false }
            try expect(editor.showControlSession.clock.state == .waiting, "Another endpoint acquired the selected external clock")
            var refusedOSC = false
            do { try editor.armExternalShowClock(source: "competing-source", port: 0) }
            catch { refusedOSC = true }
            try expect(refusedOSC && editor.showControlSession.listener == nil, "OSC and MTC armed simultaneous clock ownership")
            try expect(pump(2) {
                tick()
                return editor.showControlSession.clock.state == .locked && editor.showControlSession.timeCode?.latestEvent?.motion == .locate
            }, "Selected virtual source full-frame locate did not arrive")
            try expect(abs(editor.showRuntime.time - 1.24) < 0.000_01 && !editor.showRuntime.isPlaying,
                       "A full-frame locator failed to apply source origin while keeping the show paused")
            pass("selected virtual UID and one-clock ownership are enforced; full-frame locate is paused and origin-relative")

            try expect(pump(4) {
                tick()
                let now = ProcessInfo.processInfo.systemUptime
                if now >= ready.phaseAnchor + 0.18, now <= ready.phaseAnchor + 1.12,
                   editor.showControlSession.clock.state == .locked, editor.showRuntime.isPlaying {
                    errors.append(abs(editor.showRuntime.currentTime(at: now) - (2.08 + now - ready.phaseAnchor)))
                }
                return now >= ready.phaseAnchor + 1.20
            }, "Separate-process MIDI stream did not reach phase interval")
            try expect(errors.count >= 20 && (errors.max() ?? .infinity) < 0.105,
                       "MTC phase did not converge within 105 ms across at least 20 live samples")
            pass("separate CoreMIDI process sends paced quarter frames and measures native show phase")

            try expect(pump(3) {
                tick()
                return !child.isRunning && editor.showControlSession.timeCode?.isConnected == false
                    && editor.showControlSession.clock.state == .lost
            }, "Selected endpoint disappearance did not lose and freeze the show clock")
            try expect(!editor.showRuntime.isPlaying && !editor.media.isPlaying, "MIDI source loss left transport or media running")
            let frozen = editor.showRuntime.time
            let wrongReplacement = try source(localClient, name: ready.name)
            defer { MIDIEndpointDispose(wrongReplacement) }
            try send([0xF0, 0x7F, 0x7F, 1, 1, 0x21, 0, 32, 10, 0xF7], from: wrongReplacement)
            _ = pump(0.30) { tick(); return false }
            try expect(editor.showControlSession.clock.state == .lost && editor.showRuntime.time == frozen,
                       "A same-name endpoint with a different UID restored the lost clock")

            let replacement = try source(localClient, name: ready.name, uid: ready.uid)
            defer { MIDIEndpointDispose(replacement) }
            try expect(pump(3) { tick(); return editor.showControlSession.timeCode?.isConnected == true },
                       "Replacement with the selected UID did not reconnect")
            try send([0xF0, 0x7F, 0x7F, 1, 1, 0x21, 0, 4, 5, 0xF7], from: replacement)
            try expect(pump(2) { tick(); return editor.showControlSession.clock.state == .locked },
                       "The replacement source did not reacquire")
            try expect(abs(editor.showRuntime.time - 4.2) < 0.000_01 && !editor.showRuntime.isPlaying,
                       "Reacquisition did not apply the replacement's paused position")
            pass("endpoint loss freezes at the holdover boundary and only the same UID restores ownership")

            let reverse: [UInt8] = quarterValues(second: 2, frame: 0).reversed().flatMap { [0xF1, $0] }
            try send(reverse, from: replacement)
            try expect(pump(2) { tick(); return editor.showControlSession.timeCode?.latestEvent?.motion == .reverse },
                       "Reverse quarter-frame sequence did not reach the transport")
            try expect(abs(editor.showRuntime.time - 1.92) < 0.000_01 && !editor.showRuntime.isPlaying,
                       "Reverse time code should scrub and stay paused")
            try send([0xF0, 0x7F, 0x7F, 1, 1, 0x21, 0, 18, 0, 0xF7], from: replacement)
            editor.seekShow(to: 0.75)
            _ = pump(0.12) { tick(); return false }
            try expect(!editor.showControlSession.isClockArmed && editor.showControlSession.clock.state == .off
                       && abs(editor.showRuntime.time - 0.75) < 0.000_01,
                       "Manual take-over did not discard pending MTC and restore local control")
            pass("reverse time code scrubs without reverse playback and local seek revokes pending input")
        } catch {
            failure = error.localizedDescription
            fputs("FAIL MIDI time code: \(error.localizedDescription)\n", stderr)
        }
        var report: [String: Any] = [
            "schemaVersion": 1, "passed": failure == nil, "checkCount": checks.count, "checks": checks,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began,
            "timestampUTC": ISO8601DateFormatter().string(from: Date()), "phaseSampleCount": errors.count,
            "scope": "Native editor clock with independent-process original virtual CoreMIDI source and selected virtual UID recovery",
            "hardwareVerification": false
        ]
        if let maximum = errors.max() { report["maximumPhaseErrorSeconds"] = maximum }
        if let failure { report["failure"] = failure }
        let reportDirectory = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("artifacts/local/midi-time-code", isDirectory: true)
        do {
            try fm.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
            let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: reportDirectory.appendingPathComponent("report.json"), options: .atomic)
        } catch {
            fputs("MIDI time-code report failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
        return failure == nil ? 0 : 1
    }

    static func runFixture(arguments: [String]) -> Int32 {
        guard ProcessInfo.processInfo.environment[fixtureGate] == "virtual-only",
              arguments.count == 3, arguments[1] == "--midi-time-code-fixture" else { return 2 }
        do {
            var client: MIDIClientRef = 0
            try check(MIDIClientCreateWithBlock("ApertureCue Independent Virtual MTC" as CFString, &client, nil), "create independent virtual client")
            defer { MIDIClientDispose(client) }
            let name = "Original paced MTC " + UUID().uuidString
            let output = try source(client, name: name)
            defer { MIDIEndpointDispose(output) }
            var uid: Int32 = 0
            try check(MIDIObjectGetIntegerProperty(output, kMIDIPropertyUniqueID, &uid), "read virtual source UID")
            try expect(uid != 0, "Independent source has no unique ID")
            let anchor = ProcessInfo.processInfo.systemUptime + 1.35
            let ready = FixtureReady(uid: uid, name: name, phaseAnchor: anchor)
            try JSONEncoder().encode(ready).write(to: URL(fileURLWithPath: arguments[2]), options: .withoutOverwriting)
            wait(until: anchor - 0.28)
            try send([0xF0, 0x7F, 0x7F, 1, 1, 0x21, 0, 1, 6, 0xF7], from: output)
            for cycle in 0..<18 {
                let frameNumber = 2 * cycle
                let values = quarterValues(second: 2 + frameNumber / 25, frame: frameNumber % 25)
                for (part, message) in values.enumerated() {
                    wait(until: anchor + Double(cycle) * 0.08 - Double(7 - part) * 0.01)
                    try send([0xF1, message], from: output)
                }
            }
            wait(until: anchor + 1.48)
            return 0
        } catch {
            fputs("Independent virtual MTC sender failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    /// Original 01:00:SS:FF / 25 fps reference from the MTC wire layout.
    private static func quarterValues(second: Int, frame: Int) -> [UInt8] {
        [UInt8(frame & 0xF), UInt8(0x10 | (frame >> 4)),
         UInt8(0x20 | (second & 0xF)), UInt8(0x30 | (second >> 4)), 0x40, 0x50, 0x61, 0x72]
    }

    private static func source(_ client: MIDIClientRef, name: String, uid: Int32? = nil) throws -> MIDIEndpointRef {
        var endpoint: MIDIEndpointRef = 0
        try check(MIDISourceCreate(client, name as CFString, &endpoint), "create virtual test source")
        if let uid {
            do { try check(MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, uid), "restore virtual source UID") }
            catch { MIDIEndpointDispose(endpoint); throw error }
        }
        return endpoint
    }

    private static func send(_ bytes: [UInt8], from endpoint: MIDIEndpointRef) throws {
        var list = MIDIPacketList()
        let status = withUnsafeMutablePointer(to: &list) { pointer -> OSStatus in
            let last = MIDIPacketListInit(pointer)
            let packet = bytes.withUnsafeBufferPointer { data -> UnsafeMutablePointer<MIDIPacket>? in
                guard let base = data.baseAddress else { return nil }
                return MIDIPacketListAdd(pointer, MemoryLayout<MIDIPacketList>.size, last, 0, data.count, base)
            }
            guard packet != nil else { return kMIDIInvalidClient }
            return MIDIReceived(endpoint, pointer)
        }
        try check(status, "send original MTC fixture bytes")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
        guard condition() else { throw SystemFailure(message: reason) }
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw SystemFailure(message: "Cannot \(operation): CoreMIDI status \(status)") }
    }

    private static func wait(until time: Double) {
        let remaining = time - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }

    private static func pump(_ seconds: Double, until condition: () -> Bool) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        } while ProcessInfo.processInfo.systemUptime < end
        return condition()
    }
}
#endif
