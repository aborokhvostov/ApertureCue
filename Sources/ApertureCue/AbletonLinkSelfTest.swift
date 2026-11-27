#if os(macOS)
import AppKit
import MetalKit
import MappingCore

@MainActor enum AbletonLinkSelfTest {
    private final class FixtureOutput: @unchecked Sendable {
        private let lock = NSLock()
        private let received = DispatchSemaphore(value: 0)
        private var current = Data()
        private var lines: [Data] = []

        func read(_ handle: FileHandle) {
            guard let bytes = try? handle.read(upToCount: 256), !bytes.isEmpty else { received.signal(); return }
            lock.withLock {
                for byte in bytes {
                    if byte == 10 {
                        if lines.count < 4 { lines.append(current); received.signal() }
                        current.removeAll(keepingCapacity: true)
                    } else if current.count < 256 {
                        current.append(byte)
                    }
                }
            }
        }

        func take() throws -> String {
            guard received.wait(timeout: .now() + 1) == .success,
                  let line = lock.withLock({ lines.isEmpty ? nil : lines.removeFirst() }) else {
                throw SystemFailure(message: "Link fixture peer did not reply")
            }
            return String(decoding: line, as: UTF8.self)
        }
    }

    private final class Peer {
        let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private let reader = FixtureOutput()

        init(_ executable: URL) throws {
            guard executable.lastPathComponent == "aperturecue-link-peer",
                  FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw SystemFailure(message: "Select a built loopback fixture peer")
            }
            process.executableURL = executable
            process.standardInput = input
            process.standardOutput = output
            var environment = ProcessInfo.processInfo.environment
            environment["APERTURECUE_LINK_DIAGNOSTIC"] = "loopback-only"
            process.environment = environment
            output.fileHandleForReading.readabilityHandler = { [reader] handle in reader.read(handle) }
            try process.run()
            guard try reader.take() == "ready" else { throw SystemFailure(message: "Invalid Link fixture peer greeting") }
        }

        deinit { stop() }

        func stop() {
            if process.isRunning {
                try? send("quit")
                try? input.fileHandleForWriting.close()
            }
            output.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
        }

        func send(_ text: String) throws {
            try input.fileHandleForWriting.write(contentsOf: Data((text + "\n").utf8))
        }

        func sample(_ time: UInt64) throws -> (tempo: Double, phase: Double) {
            try send("sample \(time)")
            let values = try reader.take().split(separator: " ")
            guard values.count == 5, UInt64(values[1]) == time,
                  let tempo = Double(values[2]), let phase = Double(values[4]), (0..<4).contains(phase) else {
                throw SystemFailure(message: "Invalid common-time Link sample")
            }
            return (tempo, phase)
        }
    }

    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 4, arguments[1] == "--ableton-link-test" else {
            fputs("Usage: --ableton-link-test /path/to/fixtures/aperturecue-link /path/to/fixtures/aperturecue-link-peer\n", stderr)
            return 2
        }
        let helper = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let fixtureURL = URL(fileURLWithPath: arguments[3]).standardizedFileURL
        let began = ProcessInfo.processInfo.systemUptime
        var checks: [String] = []
        var phaseErrors: [Double] = []
        var launchPhase: Double?
        var failure: String?
        func pass(_ issue: String) { checks.append(issue); print("PASS Ableton Link: " + issue) }
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try expect(MTLCreateSystemDefaultDevice() != nil, "A native test needs a logged-in Metal session")
            let editor = EditorController()
            editor.timer?.invalidate()
            editor.timer = nil
            editor.window?.orderOut(nil)
            editor.metalView.isPaused = true
            editor.lightingView.isPaused = true
            editor.network?.stop()
            editor.midi?.stop()
            editor.lighting.stop()
            let session = editor.abletonLinkSession
            defer {
                session.reset()
                editor.closeOutputs()
                editor.media.reset()
                editor.dirty = false
                editor.window?.close()
            }
            let base = Surface(name: "Original Live Link source")
            var target = base
            target.name = "Original quantized scene"
            target.opacity = 0.42
            let cue = Cue(name: "Original Link scene", surfaces: [target], duration: 0)
            editor.project = Project(name: "Original Link phase fixture", surfaces: [base], cues: [cue])
            editor.reconcile()
            editor.refresh()
            let peer = try Peer(fixtureURL)
            defer { peer.stop() }
            try session.connect(helper, fixture: true)
            try expect(pump(5, editor) { session.observation?.peers == 1 }, "Two independent Link processes did not discover each other")
            try peer.send("tempo 137")
            try expect(pump(4, editor) { abs((session.observation?.tempo ?? 0) - 137) < 0.002 },
                       "Bridge did not follow the independent peer tempo")
            var previous: UInt64 = 0
            for _ in 0..<24 {
                try expect(pump(0.5, editor) { (session.observation?.sequence ?? 0) > previous }, "Link bridge stopped sending samples")
                guard let sample = session.observation else { throw SystemFailure(message: "Link lost while measuring phase") }
                let other = try peer.sample(sample.hostMicros)
                let raw = abs(sample.phase - other.phase)
                phaseErrors.append(min(raw, 4 - raw))
                previous = sample.sequence
            }
            try expect((phaseErrors.max() ?? .infinity) < 0.025, "Independent Link peers did not agree on phase")
            pass("selected bridge and independent loopback Link peer converged on tempo and phase")

            try expect(pump(3, editor) { (session.observation?.phase ?? 4) < 3.0 }, "No sufficiently distant 4-beat boundary")
            try session.queueCue(cue, document: editor.documentGeneration, project: editor.project)
            try expect(editor.project.surfaces == [base] && session.pendingCue == cue.id, "Scene ran before its Link boundary")
            try expect(pump(4, editor) { editor.project.surfaces == [target] }, "Link did not launch the queued scene")
            launchPhase = session.observation?.phase
            try expect((launchPhase ?? .infinity) < 0.32 && session.pendingCue == nil && !editor.showRuntime.isPlaying,
                       "Link cue was not one-shot near the boundary or changed the show transport")
            pass("selected native scene launched once near the next bar without changing show transport")

            try session.queueCue(cue, document: editor.documentGeneration, project: editor.project)
            editor.project.timelineSettings.duration += 1
            editor.pollAbletonLink()
            try expect(session.pendingCue == nil && session.message.contains("show changed"), "Timeline edit left a stale queued cue")
            try session.queueCue(cue, document: editor.documentGeneration, project: editor.project)
            editor.seekShow(to: 0.25)
            try expect(session.pendingCue == nil, "Manual seek did not cancel the queued cue")
            try expect(pump(3, editor) { (session.observation?.phase ?? 4) < 2.5 }, "Could not queue before peer departure")
            try session.queueCue(cue, document: editor.documentGeneration, project: editor.project)
            peer.stop()
            try expect(pump(7, editor) { session.observation?.peers == 0 }, "Link did not report last peer departure")
            try expect(session.pendingCue == nil && session.message.contains("signal was lost"),
                       "Last peer departure did not cancel the queued cue before launch")
            pass("timeline edit, seek and last peer departure cancel pending actions")

            let replacement = try Peer(fixtureURL)
            defer { replacement.stop() }
            try expect(pump(6, editor) { session.observation?.peers == 1 }, "Replacement peer did not reacquire Link")
            try expect(session.pendingCue == nil, "Reacquisition replayed the old queue")
            try session.queueCue(cue, document: editor.documentGeneration, project: editor.project)
            let panel = AbletonLinkWindow(editor: editor)
            session.window = panel
            panel.window?.close()
            try expect(session.pendingCue == nil && session.bridgeName == nil, "Closing the Link panel retained a helper or cue")
            pass("recovery does not replay and closing the native panel disarms")
        } catch {
            failure = error.localizedDescription
            fputs("FAIL Ableton Link: \(error.localizedDescription)\n", stderr)
        }
        var report: [String: Any] = [
            "schemaVersion": 1, "passed": failure == nil, "checkCount": checks.count, "checks": checks,
            "timestampUTC": ISO8601DateFormatter().string(from: Date()),
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began, "phaseSampleCount": phaseErrors.count,
            "scope": "Native selected cue, independently built read-only Link bridge, separate controllable upstream peer, private loopback multicast"
        ]
        if let maximum = phaseErrors.max() { report["maximumPhaseErrorBeats"] = maximum }
        if let launchPhase { report["nativeLaunchPhaseBeats"] = launchPhase }
        if let failure { report["failure"] = failure }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/local/ableton-link", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        } catch {
            fputs("Link report failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
        return failure == nil ? 0 : 1
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw SystemFailure(message: description) }
    }

    private static func pump(_ seconds: Double, _ editor: EditorController, until condition: () -> Bool) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            editor.pollAbletonLink()
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        } while ProcessInfo.processInfo.systemUptime < end
        return condition()
    }
}
#endif
