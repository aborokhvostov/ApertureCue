#if os(macOS)
import AppKit
import MetalKit
import MappingCore

@MainActor enum LEDScanSelfTest {
    static func run() -> Int32 {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("aperturecue-original-led-scan-\(UUID())", isDirectory: true)
        let report = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("artifacts/local/led-scan-test", isDirectory: true)
        let started = ProcessInfo.processInfo.systemUptime
        var checks: [String] = []
        var failure: String?
        defer { try? fm.removeItem(at: root) }
        func expect(_ condition: Bool, _ description: String) throws {
            guard condition else { throw SystemFailure(message: description) }
        }
        func pass(_ text: String) { checks.append(text); print("PASS LED scan: " + text) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            let input = root.appendingPathComponent("Original.acledscan.json")
            try LEDScanExample.save(to: input)
            let capture = try LEDScanCapture.load(from: input)
            let result = try LEDScanner.decode(capture)
            let expected = LEDScanExample.foci.map { Point2((Double($0.0) + 0.5) / 48, (Double($0.1) + 0.5) / 36) }
            try expect(result.unresolvedSlots.isEmpty && result.detections.count == expected.count,
                       "Original side-lit capture did not resolve all LEDs")
            for (sample, center) in zip(result.detections, expected) {
                guard let point = sample.point else { throw SystemFailure(message: "Resolved fixture lost its point") }
                try expect(abs(point.x - center.x) < 1e-8 && abs(point.y - center.y) < 1e-8,
                           "Top-origin pixel center differs from the synthetic capture")
            }
            pass("versioned original capture round-trips and decodes known top-left centers under ambient drift")

            NSApplication.shared.setActivationPolicy(.prohibited)
            try expect(MTLCreateSystemDefaultDevice() != nil, "No Metal device in this graphics session")
            let editor = EditorController()
            editor.timer?.invalidate()
            editor.timer = nil
            editor.window?.orderOut(nil)
            editor.metalView.isPaused = true
            editor.lightingView.isPaused = true
            editor.network?.stop()
            editor.midi?.stop()
            editor.lighting.stop()
            defer { editor.lighting.stop(); editor.closeOutputs(); editor.media.reset() }
            editor.project = Project(name: "Original synthetic LED scan fixture", surfaces: [Surface()])
            editor.reconcile()
            editor.refresh()
            let fixture = try editor.installLEDScan(result, name: "Original scanned LEDs", universe: 8, address: 10, channelOrder: "GRB")
            try expect(editor.project.fixtures == [fixture], "The native document lost its decoded fixture")
            editor.undoEdit()
            try expect(editor.project.fixtures.isEmpty, "LED scan fixture Undo left a patch")
            editor.redoEdit()
            try expect(editor.project.fixtures == [fixture], "LED scan fixture Redo did not restore the patch")
            var overlappingRejected = false
            do { _ = try editor.installLEDScan(result, name: "Overlapping scan", universe: 8, address: 11, channelOrder: "RGB") }
            catch { overlappingRejected = true }
            try expect(overlappingRejected && editor.project.fixtures == [fixture], "An overlap changed the active patch")
            pass("native import commits once, respects overlap validation and integrates with Undo/Redo")

            let projectFile = root.appendingPathComponent("Document.aperturecue.json")
            editor.saveTo(projectFile)
            let saved = try ProjectStore.load(from: projectFile)
            try expect(saved.fixtures == [fixture], "Save/Open changed decoded coordinates")
            let mapped = try FixtureSampler.sample(fixtures: saved.fixtures) { point in RGBColor(point.x, point.y, 0.25) }
            let expectedBytes = expected.flatMap { point -> [UInt8] in
                [UInt8((point.y * 255).rounded()), UInt8((point.x * 255).rounded()), 64]
            }
            try expect(mapped[8].map { Array($0[9..<18]) } == expectedBytes, "Normalized scan coordinates did not feed the patched slots")
            pass("saved scan fixture drives the expected nine DMX slots in production patch order")

            var withOcclusion = capture
            withOcclusion.frames[1].flash = withOcclusion.frames[1].darkBefore
            let partial = try LEDScanner.decode(withOcclusion)
            try expect(partial.unresolvedSlots == [2], "Occluded slot was silently remapped")
            let gap = try editor.installLEDScan(partial, name: "Original partial scan", universe: 9, address: 1,
                                               channelOrder: "RGB", skippingUnresolved: true)
            let withGap = try FixtureSampler.sample(fixtures: [gap]) { _ in RGBColor(1, 1, 1) }
            try expect(gap.skippedPixels == [1] && withGap[9].map { Array($0.prefix(9)) } == [255, 255, 255, 0, 0, 0, 255, 255, 255],
                       "Partial scan renumbered LED addresses or illuminated an unresolved position")
            pass("optional partial import preserves patch addresses and writes zero for an occluded LED")
        } catch {
            failure = error.localizedDescription
            fputs("FAIL LED scan: \(error.localizedDescription)\n", stderr)
        }
        var data: [String: Any] = [
            "schemaVersion": 1, "passed": failure == nil, "checkCount": checks.count, "checks": checks,
            "timestampUTC": ISO8601DateFormatter().string(from: Date()),
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Original simulated grayscale flash stack and hidden native fixture editor; normalized positions and patched byte oracle",
            "fixtureDimensions": [48, 36], "fixtureFlashes": 3, "cameraAccess": false, "hardwareVerification": false,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started
        ]
        if let failure { data["failure"] = failure }
        do {
            try fm.createDirectory(at: report, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
                .write(to: report.appendingPathComponent("report.json"), options: .atomic)
        } catch { fputs("LED scan report failed: \(error.localizedDescription)\n", stderr); return 1 }
        return failure == nil ? 0 : 1
    }
}
#endif
