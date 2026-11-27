#if os(macOS)
import AppKit
import Darwin
import MappingCore

@MainActor enum LightEngineSelfTest {
    static func fixture() -> Project {
        let output = OutputConfig(name: "Wall")
        let accentOutput = OutputConfig(name: "Accent")
        let wall = Surface(name: "Wall gradient", output: Point2.unitQuad, outputID: output.id, generator: "gradient")
        let accent = Surface(name: "Accent signal", output: Point2.unitQuad, color: [0.2, 0.85, 0.2],
                             outputID: accentOutput.id, generator: "solid")
        let points = (try? FixtureLayout.matrix(from: Point2(0.1, 0.2), to: Point2(0.9, 0.8),
                                               rows: 3, columns: 8, serpentine: true)) ?? [Point2(0.5, 0.5)]
        let grid = Fixture(name: "Serpentine wall", universe: 1, points: points, channelOrder: "RGBW",
                           sampling: FixtureSampling(width: 0.075, height: 0.10), outputID: output.id, skippedPixels: [4, 14])
        let spot = Fixture(name: "Virtual moving light", universe: 2, address: 17, points: [Point2(0.6, 0.5)],
                           definition: FixtureDefinition(channels: [
                            FixtureChannel(name: "Red", source: .red),
                            FixtureChannel(name: "Green", source: .green),
                            FixtureChannel(name: "Blue", source: .blue),
                            FixtureChannel(name: "Pan", source: .pan, encoding: .coarseFine, value: 0.5,
                                           drive: FixtureSurfaceDrive(surfaceID: accent.id, parameter: "opacity")),
                            FixtureChannel(name: "Tilt", source: .tilt, encoding: .fineCoarse, value: 0.25),
                            FixtureChannel(name: "Dimmer", source: .dimmer, value: 0.65),
                            FixtureChannel(name: "Reserved", source: .reserved)
                           ]), outputID: accentOutput.id)
        let automation = AutomationTrack(name: "Accent and pan", surfaceID: accent.id, parameter: "opacity",
                                         keyframes: [AutomationKeyframe(time: 0, value: 0.25),
                                                     AutomationKeyframe(time: 4, value: 0.75),
                                                     AutomationKeyframe(time: 8, value: 0.25)])
        return Project(name: "ApertureCue Light Engine", surfaces: [wall, accent], outputs: [output, accentOutput],
                       fixtures: [grid, spot], timeline: [automation],
                       timelineSettings: .init(duration: 8, loopEnabled: true))
    }

    static func run() -> Int32 {
        let app = NSApplication.shared
        _ = app
        let start = ProcessInfo.processInfo.systemUptime
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("artifacts/local/light-engine", isDirectory: true)
        var checks: [String] = []
        var failure: String?
        var samples: [String: Any] = [:]
        do {
            try checkRaster()
            checks.append("Nearest and clipped box kernels match a sharp two-by-two RGBA oracle")
            try checkPatchAndComposition(samples: &samples)
            checks.append("Production editor applies atomic patch edits and Undo/Redo, persists the current schema and restores an off session")
            checks.append("Metal reads two logical routes from the same composition tick and encodes scoped color and animated 16-bit position")
            try checkRouter(samples: &samples)
            checks.append("ArtDmx input on an isolated port rejects duplicates and other universes, routes real sACN, retires on input loss")
            try checkReplay()
            checks.append("Armed capture replay sends exact bytes, replaces a selected frame on seek and retires the stream on stop")
        } catch {
            failure = error.localizedDescription
            fputs("LIGHT ENGINE FAILED: \(error.localizedDescription)\n", stderr)
        }
        var result: [String: Any] = [
            "schemaVersion": 1, "passed": failure == nil, "checkCount": checks.count, "checks": checks,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
            "timestampUTC": ISO8601DateFormatter().string(from: Date()),
            "fixtureResolution": [320, 180], "surfaceCount": 2, "logicalOutputs": 2,
            "hardwareVerification": false, "observations": samples
        ]
        if let failure { result["failure"] = failure }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bytes = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        } catch {
            fputs("Cannot write Light engine report: \(error.localizedDescription)\n", stderr)
            return 1
        }
        for check in checks { print("PASS light engine: " + check) }
        return failure == nil ? 0 : 1
    }

    private static func checkRaster() throws {
        guard let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32), let bytes = image.bitmapData else {
            throw SystemFailure(message: "Cannot construct lighting color oracle")
        }
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 0, 0, 0, 255]
        for index in rgba.indices { bytes[index] = rgba[index] }
        guard let raster = LightingRaster(image, withArea: true) else { throw SystemFailure(message: "No lighting raster") }
        try expect(raster.color(at: Point2(0, 0), area: nil) == MappingCore.RGBColor(1, 0, 0), "Top-left nearest differs")
        try expect(raster.color(at: Point2(1, 1), area: nil) == MappingCore.RGBColor(0, 0, 0), "Bottom-right clamp differs")
        try expect(raster.color(at: Point2(0.5, 0.5), area: .init(width: 1, height: 1)) == MappingCore.RGBColor(0.25, 0.25, 0.25),
                   "RGBA area average differs")
        try expect(raster.color(at: Point2(0, 0), area: .init(width: 1, height: 1)) == MappingCore.RGBColor(1, 0, 0),
                   "Edge clipping includes an out-of-range sample")
    }

    private static func checkPatchAndComposition(samples: inout [String: Any]) throws {
        let editor = EditorController()
        editor.timer?.invalidate()
        defer { editor.lighting.stopDocument(); editor.window?.close() }
        let model = fixture()
        editor.project = model
        editor.reconcile()
        editor.refresh()
        guard let renderer = editor.lighting.renderer else { throw SystemFailure(message: "No lighting Metal renderer") }
        samples["gpu"] = renderer.device.name
        var edited = model.fixtures
        edited[1].address = 46
        try editor.replaceFixturePatch(edited, label: "Native patch fixture")
        try expect(editor.project.fixtures == edited, "Native patch did not update selected slot")
        editor.undoEdit()
        try expect(editor.project.fixtures == model.fixtures, "Undo failed to restore fixture addresses")
        editor.redoEdit()
        try expect(editor.project.fixtures == edited, "Redo failed to restore patch")
        do {
            var overlap = edited
            var invalid = overlap[0]
            invalid.id = UUID()
            overlap.append(invalid)
            try editor.replaceFixturePatch(overlap, label: "Rejected overlap")
            throw SystemFailure(message: "Overlapping patch accepted")
        } catch is ProjectError {}
        try expect(editor.project.fixtures == edited, "Rejected patch modified the document")
        editor.lighting.isSampling = true
        let halfOpacity = try TimelineEngine.apply(tracks: model.timeline, time: 2, surfaces: model.surfaces)
        editor.lighting.update(surfaces: halfOpacity, outputs: model.outputs)
        try expect(pump(3) { editor.lighting.lastUniverses.count == 2 }, "Routed Metal samples never published")
        let first = editor.lighting.lastUniverses[1] ?? []
        let spot = editor.lighting.lastUniverses[2] ?? []
        try expect(first.count == 512 && spot.count == 512, "Patch buffers not full universe size")
        let pixels = Array(first.prefix(20))
        let custom = Array(spot[45..<54])
        try expect(Array(pixels.suffix(4)) == [0, 0, 0, 0] && pixels[2] > pixels[0] && pixels[2] > pixels[1],
                   "Routed wall or skipped RGBW pixel differs: \(pixels)")
        try expect(custom[1] > custom[0] && custom[0] == custom[2] && Array(custom[3...]) == [128, 0, 0, 64, 166, 0],
                   "Accent route or driven coarse/fine order differs: \(custom)")
        samples["wallSlots1to20"] = pixels
        samples["accentSlots46to54"] = custom
        editor.lighting.blackout = true
        try expect(editor.lighting.lastUniverses.values.allSatisfy { $0.allSatisfy { $0 == 0 } }, "Blackout left a position slot nonzero")
        let fileManager = FileManager.default
        let temp = fileManager.temporaryDirectory.appendingPathComponent("aperturecue-light-engine-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temp) }
        let file = temp.appendingPathComponent("OwnPatch.aperturecue.json")
        editor.saveTo(file)
        try expect(!editor.dirty, "Native Save did not clear the dirty state")
        editor.openProject(file)
        try expect(editor.project.version == Project.currentVersion && editor.project.fixtures == edited
                   && !editor.lighting.isSending && !editor.lighting.isSampling, "Light state or saved patch on reopen differs")
    }

    private static func checkRouter(samples: inout [String: Any]) throws {
        let lighting = LightingController()
        defer { lighting.stopDocument() }
        let udp = try LightingSelfTest.Receiver(port: SACNCodec.port)
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SystemFailure(message: "Cannot open test sender") }
        defer { Darwin.close(fd) }
        do {
            try lighting.monitorInput.start(port: ArtNetCodec.port, universe: 5, wire: .artnet)
            throw SystemFailure(message: "Loop-prone input on output port was accepted")
        } catch let error as SystemFailure where error.localizedDescription.contains("other than") {}
        let port = try lighting.monitorInput.start(port: 0, universe: 5, wire: .artnet)
        try lighting.startNetworkOutput(mode: .sacn, address: "127.0.0.1", multicast: false,
                                        synchronizationAddress: 0, maximumRateHz: 30)
        try lighting.routeIncoming()
        try transmit(ArtNetCodec.encode(.init(universe: 8, sequence: 1, channels: [2, 2])), fd: fd, port: port)
        try transmit(ArtNetCodec.encode(.init(universe: 5, sequence: 255, channels: [15, 25])), fd: fd, port: port)
        try transmit(ArtNetCodec.encode(.init(universe: 5, sequence: 1, channels: [42, 97])), fd: fd, port: port)
        try transmit(ArtNetCodec.encode(.init(universe: 5, sequence: 1, channels: [99, 99])), fd: fd, port: port)
        let routed = try waitPacket(udp, timeout: 2, advance: { lighting.updateIncoming(at: ProcessInfo.processInfo.systemUptime) }) {
            $0.universe == 5 && $0.channels == [42, 97]
        }
        try expect(routed.channels == [42, 97], "Routed slots differ")
        let c = lighting.monitorInput.snapshot(at: ProcessInfo.processInfo.systemUptime)
        try expect(c.received == 2 && c.discarded == 2, "Unexpected admission or duplicate handling")
        _ = try waitPacket(udp, timeout: 3, advance: { lighting.updateIncoming(at: ProcessInfo.processInfo.systemUptime) }) {
            $0.universe == 5 && $0.channels == [0, 0] && $0.options & 0x40 == 0
        }
        for _ in 0..<3 {
            _ = try waitPacket(udp, timeout: 2) { $0.universe == 5 && $0.options & 0x40 != 0 }
        }
        try expect(lighting.lastUniverses.isEmpty, "Timed-out route retained stale slots")
        lighting.stopRoutingIncoming()
        try expect(!lighting.isSending, "Ending a route left network output armed")
        samples["routedChannels"] = routed.channels
        samples["invalidOrDuplicateInputs"] = c.discarded
    }

    private static func checkReplay() throws {
        let lighting = LightingController()
        defer { lighting.stopDocument() }
        let udp = try LightingSelfTest.Receiver(port: SACNCodec.port)
        let sequence = try DMXSequence(frames: [DMXSequenceFrame(microseconds: 0, universes: [3: [16, 27]]),
                                               DMXSequenceFrame(microseconds: 500_000, universes: [3: [83, 94]])],
                                       durationMicroseconds: 1_000_000)
        lighting.sequenceSession.install(sequence)
        try lighting.startNetworkOutput(mode: .sacn, address: "127.0.0.1", multicast: false,
                                        synchronizationAddress: 0, maximumRateHz: 30)
        let session = lighting.sequenceSession
        try session.play(network: true, automaticTicks: false)
        _ = try waitPacket(udp, timeout: 2) { $0.universe == 3 && $0.channels == [16, 27] }
        try session.seek(to: 0.6)
        _ = try waitPacket(udp, timeout: 2) { $0.universe == 3 && $0.channels == [83, 94] }
        session.stopPlayback()
        _ = try waitPacket(udp, timeout: 2) { $0.universe == 3 && $0.channels == [0, 0] && $0.options & 0x40 == 0 }
        for _ in 0..<3 {
            _ = try waitPacket(udp, timeout: 2) { $0.universe == 3 && $0.options & 0x40 != 0 }
        }
        try expect(!lighting.isSending && !session.isNetworkReplay, "Stopping replay did not disarm output")
    }

    private static func transmit(_ payload: Data, fd: Int32, port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        let sent = payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        try expect(sent == payload.count, "Unable to send the original test frame")
    }

    private static func waitPacket(_ socket: LightingSelfTest.Receiver, timeout: Double,
                                   advance: () -> Void = {}, matching: (SACNPacket) -> Bool) throws -> SACNPacket {
        var matched: SACNPacket?
        let got = pump(timeout) {
            advance()
            for _ in 0..<128 {
                guard let bytes = socket.receive() else { break }
                if let packet = try? SACNCodec.decode(bytes), matching(packet) { matched = packet; return true }
            }
            return false
        }
        guard got, let matched else { throw SystemFailure(message: "Expected sACN packet did not arrive") }
        return matched
    }

    private static func pump(_ seconds: Double, until completion: () -> Bool) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if completion() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.004))
        } while ProcessInfo.processInfo.systemUptime < end
        return completion()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SystemFailure(message: message) }
    }
}
#endif
