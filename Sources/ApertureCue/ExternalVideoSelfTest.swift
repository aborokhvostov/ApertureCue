#if os(macOS)
import AppKit
import Foundation
import MappingCore

@MainActor enum ExternalVideoSelfTest {
    static let artworkSize = [96, 64]
    private static let generatedBGRA: [UInt8] = [23, 92, 221, 255]
    private static let expectedRGBA: [UInt8] = [221, 92, 23, 255]

    static func fixture() -> Project {
        let feed = MediaAsset(name: "Original external video", path: "demo-feed", kind: "external-video", loop: false, volume: 0)
        let picture = Surface(name: "External video", mediaID: feed.id,
                              output: [Point2(0.09, 0.15), Point2(0.68, 0.15), Point2(0.68, 0.85), Point2(0.09, 0.85)],
                              generator: "solid")
        let side = Surface(name: "Original comparison gradient",
                           output: [Point2(0.73, 0.15), Point2(0.91, 0.15), Point2(0.91, 0.85), Point2(0.73, 0.85)],
                           generator: "gradient")
        return Project(name: "ApertureCue External Video", assets: [feed], surfaces: [picture, side], outputs: [OutputConfig()])
    }

    static func publishDemo(arguments: [String]) -> Int32 {
        guard arguments.count == 4 || arguments.count == 5 else {
            fputs("Usage: --publish-demo-feed INBOX NAME [SECONDS]\n", stderr)
            return 2
        }
        do {
            let name = arguments[3]
            guard ExternalVideoFrame.isValidName(name) else { throw ProjectError.invalid("Invalid demo feed name") }
            let seconds = arguments.count == 5 ? Double(arguments[4]) ?? 0 : 30
            guard (0.5...3600).contains(seconds) else {
                throw ProjectError.invalid("Demo duration must be between 0.5 and 3600 seconds")
            }
            let root = try ExternalVideoInbox.verifyProducerDirectory(URL(fileURLWithPath: arguments[2]))
            let id = UUID()
            let fixed = arguments.count == 5 && ProcessInfo.processInfo.environment["APERTURECUE_FRAME_FIXTURE"] == "1"
            let first = ProcessInfo.processInfo.systemUptime
            let width = artworkSize[0], height = artworkSize[1]
            var sequence: UInt64 = 0
            while ProcessInfo.processInfo.systemUptime - first < seconds, FileManager.default.fileExists(atPath: root.path) {
                sequence += 1
                var colors = generatedBGRA
                if !fixed {
                    colors[1] = UInt8(30 + (sequence % 30) * 6)
                    colors[0] = UInt8(199 - (sequence % 30) * 6)
                }
                var pixels = Data(capacity: width * height * 4)
                for _ in 0..<(width * height) { pixels.append(contentsOf: colors) }
                let frame = try ExternalVideoFrame(producer: id, sequence: sequence, width: width, height: height, bgra: pixels)
                try ExternalVideoInbox.publish(frame, name: name, in: root)
                Thread.sleep(forTimeInterval: 1.0 / 20.0)
            }
            return 0
        } catch {
            fputs("Video producer: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func run(syphonHelper: URL? = nil) -> Int32 {
        let modes = syphonHelper == nil ? "external-video" : "syphon-loopback"
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/local/" + modes)
        let start = ProcessInfo.processInfo.systemUptime
        var checks: [String] = []
        var failure: String?
        var samples: [[UInt8]] = []
        var measurements: [String: Double] = [:]
        do {
            _ = NSApplication.shared
            let editor = EditorController()
            editor.timer?.invalidate()
            defer { editor.externalVideo.stop(); editor.window?.close() }
            let surface = Surface(name: "Only original video", output: Point2.unitQuad, generator: "checker")
            editor.project = Project(name: "Original bridge test", surfaces: [surface], outputs: [OutputConfig()])
            editor.selectedID = surface.id
            editor.reconcile()
            editor.refresh()
            let inbox = try editor.externalVideo.start()
            let feed = "original_fixture"
            let server = "ApertureCue-test-" + UUID().uuidString
            var processes: [Process] = []
            defer { processes.forEach(stop) }
            let publisher: Process
            if let syphonHelper {
                publisher = try child(syphonHelper, ["original-fixture", server])
                processes.append(publisher)
                processes.append(try child(syphonHelper, ["receive", inbox.path, feed, server]))
            } else {
                publisher = try launchDemo(inbox: inbox, name: feed)
                processes.append(publisher)
            }
            try expect(pump(7, editor) { editor.externalVideo.observedNames.contains(feed) },
                       "The independent producer was not discovered")
            checks.append(syphonHelper == nil ? "Separate process published an inbox feed" : "Official Syphon discovered an original server in a separate process")
            let mediaID = try editor.addExternalVideo(feed, assign: true)
            try expect(editor.project.surfaces[0].mediaID == mediaID, "Discovered feed was not assigned")
            try expect(pump(4, editor) { editor.externalVideo.isReceiving(feed) }, "Feed was discovered but did not upload a texture")
            let first = try pixel(editor)
            try expect(close(first, to: expectedRGBA), "Rendered external video did not match original BGRA oracle: \(first)")
            samples.append(first)
            checks.append("Selected video feeds the regular Metal composition with matching display pixels")
            stop(publisher)
            let lossStart = ProcessInfo.processInfo.systemUptime
            try expect(pump(3, editor) { !editor.externalVideo.isReceiving(feed) }, "Stale video was retained after producer stopped")
            measurements["lossAfterProducerStopSeconds"] = ProcessInfo.processInfo.systemUptime - lossStart
            let black = try pixel(editor)
            try expect(close(black, to: [0, 0, 0, 255]), "Lost feed did not render the defined black source")
            samples.append(black)
            checks.append("Loss expires an unchanged frame and the assigned surface renders black")
            if let syphonHelper {
                processes.append(try child(syphonHelper, ["original-fixture", server]))
            } else {
                processes.append(try launchDemo(inbox: inbox, name: feed))
            }
            try expect(pump(7, editor) { editor.externalVideo.isReceiving(feed) }, "Replacement producer did not reacquire")
            let restored = try pixel(editor)
            try expect(close(restored, to: expectedRGBA), "Reconnected producer did not restore image")
            samples.append(restored)
            checks.append("A replacement producer recovers without reassigning the surface")
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("aperturecue-external-document-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: temp) }
            let file = temp.appendingPathComponent("OwnBridge.aperturecue.json")
            editor.saveTo(file)
            try expect(!editor.dirty, "Cannot save test project")
            editor.openProject(file)
            try expect(editor.externalVideo.directory == nil && editor.project.assets[0].path == feed,
                       "Reload did not retain the feed name and stop the inbox")
            try expect(close(try pixel(editor), to: [0, 0, 0, 255]), "Saved source started itself during Open")
            checks.append("Schema 17 reopens the logical feed without rearming the session")
        } catch {
            failure = error.localizedDescription
            fputs("External video test failed: \(error.localizedDescription)\n", stderr)
        }
        var report: [String: Any] = [
            "passed": failure == nil, "checkCount": checks.count, "checks": checks, "scope": modes,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start, "hardwareVerification": false,
            "fixtureSize": artworkSize, "logicalOutputs": 1, "surfaceCount": 1, "samplesRGBA": samples,
            "measurements": measurements,
            "timestampUTC": ISO8601DateFormatter().string(from: Date())
        ]
        if let failure { report["error"] = failure }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        } catch { fputs("External video report failed: \(error.localizedDescription)\n", stderr); return 1 }
        for result in checks { print("PASS external video: " + result) }
        return failure == nil ? 0 : 1
    }

    private static func child(_ binary: URL, _ args: [String], fixture: Bool = false) throws -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        if fixture {
            var environment = ProcessInfo.processInfo.environment
            environment["APERTURECUE_FRAME_FIXTURE"] = "1"
            process.environment = environment
        }
        try process.run()
        return process
    }

    private static func stop(_ process: Process) {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }

    private static func launchDemo(inbox: URL, name: String) throws -> Process {
        let binary = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        return try child(binary, ["--publish-demo-feed", inbox.path, name, "18"], fixture: true)
    }

    private static func pump(_ duration: Double, _ editor: EditorController, until condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        repeat {
            if editor.externalVideo.update() { editor.updateRender() }
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private static func pixel(_ editor: EditorController) throws -> [UInt8] {
        editor.updateRender()
        guard let image = editor.renderer.snapshot(width: 48, height: 32), let data = image.bitmapData else {
            throw SystemFailure(message: "Could not read test composition")
        }
        let offset = 16 * image.bytesPerRow + 24 * 4
        return Array(UnsafeBufferPointer(start: data + offset, count: 4))
    }

    private static func close(_ pixel: [UInt8], to expected: [UInt8]) -> Bool {
        pixel.count == expected.count && zip(pixel, expected).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        if try !condition() { throw SystemFailure(message: reason) }
    }
}
#endif
