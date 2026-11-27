#if os(macOS)
import AppKit
import MappingCore

@MainActor enum DMXSequenceSelfTest {
    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(detail: message) }
    }

    private static func pump(_ timeout: Double, until ready: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !ready(), ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.006))
        }
        return ready()
    }

    static func run() -> Int32 {
        let started = ProcessInfo.processInfo.systemUptime
        var checks: [String] = []
        var scope: [String: Any] = [:]
        func pass(_ name: String) { checks.append(name); print("PASS DMX sequence: \(name)") }
        func report(result: Bool, failure: String? = nil) {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("artifacts/local/dmx-sequence", isDirectory: true)
            var body: [String: Any] = [
                "schemaVersion": 1, "passed": result, "checkCount": checks.count, "checks": checks,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "timestampUTC": ISO8601DateFormatter().string(from: Date()), "hardwareVerification": false,
                "scope": "Native DMX sequence session, original raw universe values, injected monotonic clock and isolated output callbacks",
                "workload": scope
            ]
            if let failure { body["failure"] = failure }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
            }
        }

        do {
            var samplingRequests = 0
            var armed = false
            var began: [Set<Int>] = []
            var emitted: [([Int: [UInt8]], Bool)] = []
            var ended = 0
            let panel = DMXSequenceSession(
                ensureSampling: { samplingRequests += 1 },
                canOutput: { armed },
                beginOutput: { began.append($0) },
                outputFrame: { frame, discontinuity in
                    guard armed else { throw Failure(detail: "Fixture output lost its arm") }
                    emitted.append((frame, discontinuity))
                },
                endOutput: { ended += 1 }
            )
            defer { panel.reset() }
            let first: [Int: [UInt8]] = [1: [12, 25, 200, 255]]
            let second: [Int: [UInt8]] = [1: [2, 0], 5: [124, 222, 3]]
            try panel.startCapture(at: 10)
            panel.capture(first, at: 10.125)
            panel.capture(second, at: 9.5)
            panel.capture(first, at: 10.250)
            panel.capture(second, at: 10.500)
            panel.capture([:], at: 10.625)
            panel.finishCapture(at: 10.750)
            guard let sequence = panel.sequence else { throw Failure(detail: "Capture failed to establish a portable sequence") }
            try expect(samplingRequests == 1 && sequence.frames.map(\.microseconds) == [125_000, 500_000, 625_000] &&
                       sequence.durationMicroseconds == 750_000 && sequence.universeIDs == [1, 5],
                       "Capture did not retain exact monotonic snapshots or duration")
            scope = ["recordedDurationMicroseconds": Int(sequence.durationMicroseconds), "universeCount": 2,
                     "snapshotCount": sequence.frames.count, "maximumFixtureSlotsPerUniverse": 4]
            pass("Live capture preserves exact microsecond timing, raw values and explicit retirement")

            var rejected = false
            do { try panel.play(network: true, at: 11, automaticTicks: false) }
            catch { rejected = true }
            try expect(rejected && began.isEmpty && emitted.isEmpty, "Unarmed output accepted replay")
            armed = true
            try panel.play(network: false, at: 20, automaticTicks: false)
            let simulation = panel.replayGeneration
            try expect(panel.player?.current.frameIndex == nil, "Simulation omitted the leading gap")
            panel.advance(at: 20.125, generation: simulation)
            try expect(panel.sequence?.snapshot(at: panel.player?.microseconds ?? 0) == first,
                       "Simulation missed recorded bytes at the first boundary")
            panel.advance(at: 20.600, generation: simulation)
            try expect(panel.sequence?.snapshot(at: panel.player?.microseconds ?? 0) == second,
                       "Simulation did not hold the correct later snapshot")
            panel.advance(at: 20.750, generation: simulation)
            try expect(!panel.isPlaying && began.isEmpty && emitted.isEmpty && ended == 0,
                       "Simulation changed the armed route or failed to end")
            pass("Default preview holds gaps and remains isolated from an already armed output")

            try panel.play(network: true, at: 30, automaticTicks: false)
            let old = panel.replayGeneration
            try expect(began == [[1, 5]] && emitted.count == 1 && emitted[0].0.isEmpty && emitted[0].1,
                       "Network handoff did not begin with leading-gap clear and discontinuity")
            panel.advance(at: 30.125, generation: old)
            try expect(emitted.count == 2 && emitted[1].0 == first && !emitted[1].1,
                       "First network handoff did not preserve exact raw bytes")
            try panel.seek(to: 0.5, at: 30.250)
            let current = panel.replayGeneration
            try expect(emitted.count == 3 && emitted[2].0 == second && emitted[2].1,
                       "Seek did not hand off exact replacement slots and a discontinuity")
            panel.advance(at: 30.375, generation: old)
            try expect(emitted.count == 3, "Old transport generation still published frames")
            panel.advance(at: 30.375, generation: current)
            try expect(emitted.count == 4 && emitted[3].0.isEmpty, "Retirement did not hand off an empty snapshot")
            panel.stopPlayback()
            panel.advance(at: 31, generation: current)
            try expect(ended == 1 && emitted.count == 4 && !panel.isPlaying, "Stop retained queued network replay")
            pass("Explicit output handoff carries exact snapshots, seek generation and one retirement")

            panel.install(sequence)
            try panel.play(network: true, at: 40, automaticTicks: false)
            let replacement = panel.replayGeneration
            let before = emitted.count
            panel.advance(at: 41, generation: current)
            try expect(emitted.count == before, "New sequence accepted a timer from the prior document")
            armed = false
            panel.networkOutputWasStopped()
            panel.advance(at: 40.375, generation: replacement)
            try expect(!panel.isPlaying && !panel.isNetworkReplay && emitted.count == before && ended == 1,
                       "External disarm reentered the controller or retained playback")
            pass("Replacing a sequence or losing output arm invalidates the prior native timer")

            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("acdmx-fixture-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("original.acdmx")
            panel.save(to: file)
            try expect(pump(3) { !panel.isBusy } && (try DMXSequence.load(from: file)) == sequence,
                       "Asynchronous atomic save did not produce exact bytes")
            panel.reset()
            panel.load(from: file)
            try expect(pump(3) { !panel.isBusy } && panel.sequence == sequence,
                       "Asynchronous reload did not install the saved bytes")
            let invalid = directory.appendingPathComponent("invalid.acdmx")
            try Data([1, 2, 3]).write(to: invalid)
            panel.load(from: invalid)
            try expect(pump(3) { !panel.isBusy } && panel.sequence == sequence &&
                       panel.status.contains("Invalid DMX sequence"),
                       "Invalid load replaced the accepted replay data or hid the error")
            panel.load(from: file)
            panel.reset()
            try expect(pump(3) { !panel.isBusy } && panel.sequence == nil, "Old file result installed into a reset session")
            pass("Asynchronous save and load round-trip; invalid and stale files leave session data safe")
            report(result: true)
            return 0
        } catch {
            report(result: false, failure: error.localizedDescription)
            fputs("FAIL DMX sequence: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
#endif
