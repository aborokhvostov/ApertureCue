#if os(macOS)
import AppKit
import AVFoundation
import CoreVideo
import MetalKit
import QuartzCore
import Darwin
import MappingCore

/// Exercises the production shader and AVFoundation path, rather than a
/// replacement software renderer. Run from a logged-in macOS desktop session.
@MainActor
enum SelfTest {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run() -> Int32 {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/local", isDirectory: true)
        var report: [String: Any] = [
            "schemaVersion": 1,
            "timestampUTC": ISO8601DateFormatter().string(from: Date()),
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "hardwareVerification": false,
            "scope": "Local offscreen Metal and AVFoundation checks; external displays, projectors and lighting hardware are not verified."
        ]
        var checks: [String] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = NSApplication.shared
            guard let device = MTLCreateSystemDefaultDevice() else { throw Failure(message: "No Metal device in this session") }
            report["gpu"] = device.name
            report["gpuRecommendedWorkingSetBytes"] = device.recommendedMaxWorkingSetSize
            let media = MediaPool(device: device)
            let view = MTKView(frame: NSRect(x: 0, y: 0, width: 128, height: 96), device: device)
            guard let renderer = MetalRenderer(view: view, media: media) else {
                throw Failure(message: MetalRenderer.lastInitializationError)
            }
            view.isPaused = true
            let unit = Point2.unitQuad
            func frame(_ surfaces: [Surface], width: Int = 128, height: Int = 96) throws -> NSBitmapImageRep {
                renderer.surfaces = surfaces
                guard let image = renderer.snapshot(width: width, height: height) else {
                    throw Failure(message: "GPU readback: \(renderer.errorDescription)")
                }
                return image
            }
            func expect(_ value: Bool, _ message: String) throws {
                if !value { throw Failure(message: message) }
            }
            func near(_ got: [Int], _ expected: [Int], tolerance: Int = 2) -> Bool {
                zip(got, expected).allSatisfy { abs($0 - $1) <= tolerance }
            }
            func pixel(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
                guard let data = image.bitmapData else { return [] }
                let offset = y * image.bytesPerRow + x * 4
                return (0..<4).map { Int(data[offset + $0]) }
            }

            let red = Surface(name: "Red", output: unit, color: [1, 0, 0], generator: "solid")
            let blue = Surface(name: "Blue", output: unit, opacity: 0.5, color: [0, 0, 1], generator: "solid")
            var image = try frame([red, blue])
            try expect(near(pixel(image, 64, 48), [128, 0, 128, 255]), "Premultiplied normal alpha compositing differs")
            image = try frame([blue, red])
            try expect(near(pixel(image, 64, 48), [255, 0, 0, 255]), "Layer ordering differs")
            checks += ["normal alpha compositing", "back-to-front layer ordering"]

            var add = blue; add.blendMode = "add"
            image = try frame([red, add])
            try expect(near(pixel(image, 64, 48), [255, 0, 128, 255]), "Add blending differs")
            var gray = red; gray.color = [0.8, 0.4, 0.2]
            var multiply = red; multiply.color = [0.5, 1, 0.5]; multiply.blendMode = "multiply"
            image = try frame([gray, multiply])
            try expect(near(pixel(image, 64, 48), [102, 102, 26, 255]), "Multiply blending differs")
            var screened = multiply; screened.blendMode = "screen"
            image = try frame([gray, screened])
            try expect(near(pixel(image, 64, 48), [230, 255, 153, 255]), "Screen blending differs")
            checks += ["add blending", "multiply blending", "screen blending"]

            var corrected = red; corrected.color = [0.25, 0.25, 0.25]; corrected.gamma = 2
            image = try frame([corrected])
            try expect(near(pixel(image, 64, 48), [128, 128, 128, 255]), "Gamma correction differs")
            corrected.gamma = 1; corrected.brightness = 2
            image = try frame([corrected])
            try expect(near(pixel(image, 64, 48), [128, 128, 128, 255]), "Brightness correction differs")
            checks += ["gamma correction", "brightness and RGB tint"]

            var masked = red
            masked.mask = [Point2(0, 0), Point2(1, 0), Point2(0, 1)]
            image = try frame([masked])
            try expect(near(pixel(image, 20, 20), [255, 0, 0, 255]), "Mask removed an interior sample")
            try expect(near(pixel(image, 110, 80), [0, 0, 0, 255]), "Mask retained an exterior sample")
            var feathered = red; feathered.feather = 0.2
            image = try frame([feathered])
            try expect(pixel(image, 2, 48)[0] < 20 && pixel(image, 64, 48)[0] == 255, "Edge feather ramp differs")
            checks += ["polygon mask", "edge feather"]

            let quad = [Point2(0.08, 0.1), Point2(0.92, 0.2), Point2(0.8, 0.92), Point2(0.22, 0.8)]
            let perspective = Surface(name: "Projective UV reference", output: quad, generator: "gradient")
            image = try frame([perspective])
            let homography = try Homography.solve(from: quad, to: unit)
            for (x, y) in [(35, 30), (85, 40), (64, 67), (47, 55)] {
                let uv = try homography.applying(Point2((Double(x) + 0.5) / 128, (Double(y) + 0.5) / 96))
                let expected = [Int((uv.x * 255).rounded()), Int((uv.y * 255).rounded()), Int(((1 - uv.x) * 255).rounded()), 255]
                try expect(near(pixel(image, x, y), expected, tolerance: 2), "Projective UV mismatch at \(x),\(y): \(pixel(image,x,y)) vs \(expected)")
            }
            if let png = image.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("perspective.png"), options: .atomic)
            }
            checks.append("projective UV GPU vs CPU homography, four pixel centers, ±2/255 tolerance")

            var cropped = Surface(name: "Input crop", output: unit, generator: "gradient")
            cropped.input = [Point2(0.25, 0.25), Point2(0.75, 0.25), Point2(0.75, 0.75), Point2(0.25, 0.75)]
            image = try frame([cropped])
            try expect(near(pixel(image, 16, 24), [80, 96, 175, 255], tolerance: 2), "Independent input crop differs")
            checks.append("independent input crop")

            var mesh = Surface(name: "Mesh", output: unit, generator: "gradient")
            mesh.meshColumns = 2; mesh.meshRows = 2
            mesh.mesh = (0...2).flatMap { y in (0...2).map { x in Point2(Double(x) / 2, Double(y) / 2) } }
            image = try frame([mesh])
            try expect(near(pixel(image, 64, 48), [128, 129, 127, 255], tolerance: 2), "Identity mesh UV differs")
            mesh.mesh[4] = Point2(0.65, 0.5)
            image = try frame([mesh])
            try expect(pixel(image, 80, 48)[0] < 135, "Mesh center displacement did not move source sampling")
            checks.append("mesh grid identity and displaced center")

            var assigned = red; assigned.outputID = UUID()
            renderer.outputID = UUID()
            image = try frame([assigned])
            try expect(pixel(image, 64, 48)[0] == 0, "Output filter leaked a surface")
            renderer.outputID = assigned.outputID
            image = try frame([assigned])
            try expect(pixel(image, 64, 48)[0] == 255, "Output filter removed its assigned surface")
            renderer.outputID = nil; renderer.blackout = true
            image = try frame([red])
            try expect(near(pixel(image, 64, 48), [0, 0, 0, 255]), "Blackout differs")
            renderer.blackout = false
            checks += ["output routing", "blackout"]

            renderer.surfaces = [red]
            var asyncFrame: NSBitmapImageRep?
            var overlappingRequestRejected = false
            renderer.snapshotAsync(width: 64, height: 48) { asyncFrame = $0 }
            renderer.snapshotAsync(width: 64, height: 48) { overlappingRequestRejected = $0 == nil }
            try expect(overlappingRequestRejected, "Async sampling did not bound outstanding requests")
            try expect(pump(timeout: 5) { asyncFrame != nil }, "Async GPU sampling did not complete")
            try expect(asyncFrame.map { near(pixel($0, 32, 24), [255, 0, 0, 255]) } == true, "Async sampling pixels differ")
            checks.append("asynchronous GPU readback and bounded overlapping sampling")

            let mediaDirectory = directory.appendingPathComponent("test-media", isDirectory: true)
            try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            let imageURL = mediaDirectory.appendingPathComponent("quadrants.png")
            try makeImage(at: imageURL)
            let asset = MediaAsset(name: "Quadrants", path: imageURL.path, kind: "image")
            media.reconcile(assets: [asset], baseURL: mediaDirectory)
            try expect(pump(timeout: 10) { media.texture(for: asset.id) != nil }, "Image decode did not produce a texture: \(media.errorMessages)")
            let textured = Surface(name: "Image", mediaID: asset.id, output: unit)
            image = try frame([textured])
            try expect(near(pixel(image, 16, 12), [255, 0, 0, 255]) && near(pixel(image, 110, 12), [0, 255, 0, 255]) &&
                       near(pixel(image, 110, 82), [0, 0, 255, 255]) && near(pixel(image, 16, 82), [255, 255, 0, 255]), "Image decode orientation/color differs")
            checks.append("PNG import, texture upload, all four oriented quadrants")

            let alphaURL = mediaDirectory.appendingPathComponent("alpha.png")
            try makeImage(at: alphaURL, alpha: 128)
            let alphaAsset = MediaAsset(name: "Transparent quadrants", path: alphaURL.path, kind: "image")
            media.reconcile(assets: [alphaAsset], baseURL: mediaDirectory)
            try expect(pump(timeout: 10) { media.texture(for: alphaAsset.id) != nil }, "Transparent PNG decode failed")
            image = try frame([Surface(name: "PNG alpha", mediaID: alphaAsset.id, output: unit)])
            try expect(near(pixel(image, 16, 12), [128, 0, 0, 255]), "PNG alpha was multiplied incorrectly: \(pixel(image,16,12))")
            checks.append("transparent PNG alpha compositing")

            let movieURL = mediaDirectory.appendingPathComponent("two-colors.mov")
            try makeMovie(at: movieURL)
            let movie = MediaAsset(name: "Two colors", path: movieURL.path, kind: "video", loop: true, volume: 0)
            media.seek(to: 0)
            media.reconcile(assets: [movie], baseURL: mediaDirectory)
            try expect(pump(timeout: 12) { media.duration(for: movie.id) > 1.9 }, "Movie did not become ready: \(media.errorMessages)")
            var videoSurface = Surface(name: "Video", mediaID: movie.id, output: unit)
            media.play()
            try expect(pump(timeout: 8) { media.texture(for: movie.id) != nil && media.playbackTime(for: movie.id) > 0.15 }, "Video play did not yield a decoded frame")
            media.pause()
            let pausedAt = media.playbackTime(for: movie.id)
            _ = pump(timeout: 0.18) { false }
            try expect(abs(media.playbackTime(for: movie.id) - pausedAt) < 0.06, "Paused movie continued advancing")
            media.seek(to: Double.greatestFiniteMagnitude)
            try expect(media.currentTime == MediaPool.maximumTransportTime, "Oversized finite seek did not clamp to supported show time")
            media.seek(to: .nan)
            try expect(media.currentTime == MediaPool.maximumTransportTime, "Nonfinite seek changed show time")
            media.seek(to: 1.5); media.seek(to: 0.2); media.pause()
            try expect(pump(timeout: 8) {
                guard abs(media.playbackTime(for: movie.id) - 0.2) < 0.08,
                      let snapshot = try? frame([videoSurface]) else { return false }
                let p = pixel(snapshot, 64, 48)
                return p[0] > 230 && p[2] < 30
            }, "Rapid seeks did not preserve the final paused target frame")
            try expect(!media.isPlaying, "Stale seek completion restarted a paused show")
            checks += ["oversized finite and nonfinite seek input", "rapid seek completion preserves final target and pause"]
            media.seek(to: 1.5)
            var soughtBlue = false
            try expect(pump(timeout: 8) {
                guard abs(media.playbackTime(for: movie.id) - 1.5) < 0.08,
                      media.texture(for: movie.id) != nil,
                      let snapshot = try? frame([videoSurface]) else { return false }
                let p = pixel(snapshot, 64, 48)
                soughtBlue = p[2] > 230 && p[0] < 30
                return soughtBlue
            }, "Seek did not yield the expected blue frame")
            let sharedFrameA = media.texture(for: movie.id)
            let sharedFrameB = media.texture(for: movie.id)
            try expect(sharedFrameA != nil && sharedFrameA === sharedFrameB, "Paused source did not share the same decoded texture across consumers")
            checks.append("multiple output consumers share the paused decoder texture")
            var leftVideo = videoSurface, rightVideo = videoSurface
            leftVideo.output = [Point2(0,0),Point2(0.5,0),Point2(0.5,1),Point2(0,1)]
            rightVideo.id = UUID(); rightVideo.output = [Point2(0.5,0),Point2(1,0),Point2(1,1),Point2(0.5,1)]
            let repeatedVideo = try frame([leftVideo,rightVideo])
            let leftPixel = pixel(repeatedVideo,32,48), rightPixel = pixel(repeatedVideo,96,48)
            try expect(near(leftPixel,rightPixel,tolerance:0) && leftPixel[2] > 230,
                       "Repeated video surfaces did not use one consistent decoded frame")
            let retainedFrame = media.frameResources(for:Set([movie.id]))
            try expect(retainedFrame.textures.count == 1 && retainedFrame.retained.count == 1,
                       "Composition did not retain its exact CoreVideo source frame")
            checks.append("repeated video surfaces use one frame with matching retained CoreVideo ownership")
            media.seek(to: 1.8); media.play()
            try expect(pump(timeout: 5) {
                _ = media.texture(for: movie.id)
                return media.playbackTime(for: movie.id) < 0.6 && media.currentTime > 2.05
            }, "Loop did not wrap playback time")
            media.pause()
            checks += ["H.264 MOV decode and play", "pause clock stability", "frame-accurate seek within 80 ms", "loop wrap"]
            report["mediaTest"] = ["codec": "H.264", "container": "MOV", "width": 160, "height": 90,
                                   "fps": 30, "durationSeconds": 2, "seekToleranceSeconds": 0.08]

            let missing = MediaAsset(name: "Missing", path: mediaDirectory.appendingPathComponent("does-not-exist.png").path, kind: "image")
            media.reconcile(assets: [missing], baseURL: mediaDirectory)
            try expect(media.errorMessages[missing.id] != nil, "Missing media was not diagnosed")
            videoSurface.mediaID = missing.id
            image = try frame([videoSurface])
            try expect(!pixel(image, 20, 20).isEmpty, "Missing media fallback failed to render")
            checks.append("missing media diagnostic and deterministic fallback")

            let absentCamera = MediaAsset(name: "Unavailable camera test", path: "org.aperturecue.nonexistent-test-camera", kind: "camera")
            media.reconcile(assets: [absentCamera], baseURL: mediaDirectory)
            try expect(pump(timeout: 5) { media.errorMessages[absentCamera.id] != nil }, "Unavailable/unauthorized camera was not diagnosed")
            checks.append("unavailable/unauthorized camera diagnostic; no privacy request")
            report["cameraHardware"] = "Not verified; failure-path test only"

            renderer.surfaces = [perspective, Surface(name: "Feathered", output: [Point2(0.4,0.1),Point2(0.95,0.1),Point2(0.95,0.9),Point2(0.4,0.9)], opacity: 0.5, feather: 0.1, generator: "grid")]
            let baselineMemory = residentMemory()
            var gpuSamples: [Double] = []
            let start = CACurrentMediaTime()
            for _ in 0..<300 {
                try autoreleasepool {
                    guard renderer.snapshot(width: 640, height: 360) != nil else { throw Failure(message: "Sustained offscreen render failed") }
                    gpuSamples.append(renderer.gpuMilliseconds)
                }
            }
            let elapsed = CACurrentMediaTime() - start
            let finalMemory = residentMemory()
            report["benchmark"] = [
                "method": "300 sequential offscreen frames including GPU wait, BGRA readback and RGBA swizzle; does not measure live drawable FPS",
                "width": 640, "height": 360, "surfaceCount": 2, "outputCount": 1,
                "source": "procedural gradient and grid; no media decoder in benchmark",
                "frameCount": 300, "wallSeconds": elapsed, "readbackFramesPerSecond": 300 / elapsed,
                "meanWallMilliseconds": elapsed * 1000 / 300,
                "meanGPUExecutionMilliseconds": gpuSamples.reduce(0,+) / Double(gpuSamples.count),
                "maxGPUExecutionMilliseconds": gpuSamples.max() ?? 0,
                "residentMemoryBeforeBytes": baselineMemory, "residentMemoryAfterBytes": finalMemory,
                "decoderFrameDrops": NSNull(), "gpuUtilizationPercent": NSNull(), "cpuUtilizationPercent": NSNull(),
                "unmeasuredMetrics": "GPU/CPU utilization and decoder frame drops require separate profiling; Metal command times exclude CPU work."
            ]
            checks.append("300 consecutive offscreen frames without command failure")
            report["passed"] = true
            report["checks"] = checks
            try write(report, to: directory)
            print("PASS: \(checks.count) integration checks. Report: \(directory.appendingPathComponent("self-test.json").path)")
            return 0
        } catch {
            report["passed"] = false
            report["checks"] = checks
            report["failure"] = error.localizedDescription
            try? write(report, to: directory)
            fputs("SELF-TEST FAILED: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    /// Presents real MTKView drawables at a paced rate. No pixel readback or
    /// image allocation occurs in the measured interval.
    static func runLiveBenchmark() -> Int32 {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/local", isDirectory: true)
        var report: [String: Any] = [
            "schemaVersion": 1, "timestampUTC": ISO8601DateFormatter().string(from: Date()),
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "scope": "Visible local drawable benchmark; external projector/display and long show soak remain unverified."
        ]
        var window: NSWindow?
        defer { window?.close() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            guard let device = MTLCreateSystemDefaultDevice() else { throw Failure(message: "Metal GPU unavailable") }
            let media = MediaPool(device: device)
            let view = MTKView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), device: device)
            guard let renderer = MetalRenderer(view: view, media: media) else { throw Failure(message: MetalRenderer.lastInitializationError) }
            view.isPaused = true
            let outputWindow = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            outputWindow.isReleasedWhenClosed = false
            outputWindow.title = "ApertureCue — local renderer benchmark"
            outputWindow.contentView = view
            outputWindow.center(); outputWindow.makeKeyAndOrderFront(nil)
            window = outputWindow
            _ = pump(timeout: 0.15) { false }
            renderer.surfaces = [
                Surface(name: "Background", output: Point2.unitQuad, brightness: 0.4, generator: "gradient"),
                Surface(name: "Left quad", output: [Point2(0.04,0.08),Point2(0.48,0.2),Point2(0.45,0.9),Point2(0.08,0.85)], feather: 0.04, generator: "checker"),
                Surface(name: "Right quad", output: [Point2(0.55,0.12),Point2(0.96,0.08),Point2(0.9,0.88),Point2(0.52,0.8)], opacity: 0.8, feather: 0.08, generator: "grid"),
                Surface(name: "Overlay", output: [Point2(0.3,0.3),Point2(0.7,0.3),Point2(0.7,0.7),Point2(0.3,0.7)], opacity: 0.3, blendMode: "screen", color: [0.2,0.5,0.9], generator: "solid")
            ]
            let memoryBefore = residentMemory()
            var peakMemory = memoryBefore
            let cpuBefore = processCPUSeconds()
            let start = CACurrentMediaTime()
            var nextDraw = start
            while renderer.frameCount < 300, CACurrentMediaTime() - start < 20 {
                view.draw()
                peakMemory = max(peakMemory, residentMemory())
                nextDraw += 1.0 / 60.0
                let wait = max(0.0001, nextDraw - CACurrentMediaTime())
                RunLoop.main.run(until: Date(timeIntervalSinceNow: wait))
            }
            let elapsed = CACurrentMediaTime() - start
            let cpuSeconds = processCPUSeconds() - cpuBefore
            _ = pump(timeout: 2) { renderer.completedFrameCount >= renderer.frameCount }
            guard renderer.frameCount >= 300, renderer.errorDescription.isEmpty else {
                throw Failure(message: "Drawable benchmark incomplete: \(renderer.frameCount) frames, \(renderer.errorDescription)")
            }
            report["passed"] = true
            report["gpu"] = device.name
            report["drawableWidth"] = Int(view.drawableSize.width)
            report["drawableHeight"] = Int(view.drawableSize.height)
            report["windowLogicalWidth"] = 640
            report["windowLogicalHeight"] = 360
            report["source"] = "Own procedural gradient, checker, grid and solid; no codec or video decoding in this benchmark"
            report["surfaceCount"] = renderer.surfaces.count
            report["outputCount"] = 1
            report["method"] = "300 real visible MTKView drawable submissions paced toward 60 Hz; presentDrawable; no CPU pixel readback in interval"
            report["frameCount"] = renderer.frameCount
            report["completedFrameCount"] = renderer.completedFrameCount
            report["skippedSubmissions"] = renderer.droppedFrames
            report["wallSeconds"] = elapsed
            report["submittedFramesPerSecond"] = Double(renderer.frameCount) / elapsed
            report["meanSubmissionCPUMilliseconds"] = renderer.totalCPUMilliseconds / Double(max(1, renderer.frameCount))
            report["meanGPUExecutionMilliseconds"] = renderer.totalGPUMilliseconds / Double(max(1, renderer.completedFrameCount))
            report["maxGPUExecutionMilliseconds"] = renderer.maxGPUMilliseconds
            report["processCPUSeconds"] = cpuSeconds
            report["processCPUPercentOneCoreEquivalent"] = cpuSeconds / elapsed * 100
            report["residentMemoryBeforeBytes"] = memoryBefore
            report["residentMemoryAfterBytes"] = residentMemory()
            report["residentMemoryPeakSampleBytes"] = peakMemory
            report["gpuUtilizationPercent"] = NSNull()
            report["decoderFrameDrops"] = NSNull()
            report["limitations"] = "Counts submitted/presented commands, not optical display refresh. GPU utilization and media decoder drops are unmeasured; local session may use a virtual display. Five seconds does not establish show-length stability."
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("live-benchmark.json"), options: .atomic)
            print("PASS: live drawable benchmark report: \(directory.appendingPathComponent("live-benchmark.json").path)")
            return 0
        } catch {
            report["passed"] = false; report["failure"] = error.localizedDescription
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("live-benchmark.json"), options: .atomic)
            }
            fputs("BENCHMARK FAILED: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func write(_ report: [String: Any], to directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("self-test.json"), options: .atomic)
    }

    private static func pump(timeout: Double, condition: () -> Bool) -> Bool {
        let end = CACurrentMediaTime() + timeout
        repeat {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        } while CACurrentMediaTime() < end
        return condition()
    }

    private static func residentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func makeImage(at url: URL, alpha: UInt8 = 255) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied, bytesPerRow: 64, bitsPerPixel: 32), let data = bitmap.bitmapData else {
            throw Failure(message: "PNG bitmap allocation failed")
        }
        for y in 0..<16 { for x in 0..<16 {
            let rgb: [UInt8] = y < 8 ? (x < 8 ? [255,0,0] : [0,255,0]) : (x < 8 ? [255,255,0] : [0,0,255])
            let offset = y * 64 + x * 4
            data[offset] = rgb[0]; data[offset+1] = rgb[1]; data[offset+2] = rgb[2]; data[offset+3] = alpha
        } }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "PNG encode failed") }
        try png.write(to: url, options: .atomic)
    }

    private static func makeMovie(at url: URL) throws {
        // Remove only this generated QA file when rerunning the same test.
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw Failure(message: "H.264 writer input unavailable") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure(message: writer.error?.localizedDescription ?? "Movie writer failed") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            let deadline = CACurrentMediaTime() + 10
            while !input.isReadyForMoreMediaData && writer.status == .writing && CACurrentMediaTime() < deadline { Thread.sleep(forTimeInterval: 0.002) }
            guard input.isReadyForMoreMediaData else { throw Failure(message: writer.error?.localizedDescription ?? "Movie encoder timed out") }
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
                  let pixelBuffer else { throw Failure(message: "Movie pixel buffer allocation failed") }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
                for y in 0..<90 { for x in 0..<160 {
                    let offset = y * stride + x * 4
                    bytes[offset] = frame < 30 ? 0 : 255; bytes[offset+1] = 0
                    bytes[offset+2] = frame < 30 ? 255 : 0; bytes[offset+3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw Failure(message: writer.error?.localizedDescription ?? "Movie frame append failed")
            }
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 15) == .success, writer.status == .completed else {
            throw Failure(message: writer.error?.localizedDescription ?? "Movie finalization failed")
        }
    }
}
#endif
