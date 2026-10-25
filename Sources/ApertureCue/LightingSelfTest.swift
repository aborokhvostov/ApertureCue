#if os(macOS)
import AppKit
import MetalKit
import Darwin
import MappingCore

/// Production GPU composition -> asynchronous readback -> fixture sampler ->
/// production sender -> real localhost UDP socket -> strict protocol decoder.
/// No packet is addressed to a fixture or external network interface.
@MainActor
enum LightingSelfTest {
    private final class Receiver {
        let descriptor: Int32
        private(set) var lastPeerPort: UInt16 = 0
        init(port: UInt16) throws {
            descriptor = socket(AF_INET, SOCK_DGRAM, 0)
            guard descriptor >= 0 else { throw SystemFailure(message: "Cannot create lighting test receiver") }
            var reuse: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                let message = String(cString: strerror(errno)); close(descriptor)
                throw SystemFailure(message: "Cannot bind localhost lighting test port \(port): \(message)")
            }
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        }
        deinit { close(descriptor) }
        func receive() -> Data? {
            var bytes = [UInt8](repeating: 0, count: 2048)
            var peer = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, &bytes, bytes.count, 0, $0, &size)
                }
            }
            if count > 0 { lastPeerPort = UInt16(bigEndian: peer.sin_port) }
            return count > 0 ? Data(bytes.prefix(count)) : nil
        }
        func drain() { while receive() != nil {} }
    }

    static func run() -> Int32 {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/local", isDirectory: true)
        var report: [String: Any] = [
            "schemaVersion": 1,
            "timestampUTC": ISO8601DateFormatter().string(from: Date()),
            "destination": "127.0.0.1",
            "hardwareVerification": false,
            "scope": "Production lighting pipeline with localhost UDP only; no Art-Net/sACN fixture hardware compatibility claim"
        ]
        var checks: [String] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = NSApplication.shared
            guard let device = MTLCreateSystemDefaultDevice() else { throw SystemFailure(message: "No Metal GPU") }
            report["gpu"] = device.name
            let media = MediaPool(device: device)
            let view = MTKView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), device: device)
            guard let renderer = MetalRenderer(view: view, media: media) else { throw SystemFailure(message: MetalRenderer.lastInitializationError) }
            view.isPaused = true
            let lighting = LightingController()
            lighting.renderer = renderer
            lighting.destination = "127.0.0.1"
            lighting.isSampling = true; lighting.isSending = true
            defer { lighting.isSampling = false; lighting.isSending = false }
            let artnet = try Receiver(port: 6454)
            let sacn = try Receiver(port: 5568)
            var fixture = Fixture(name: "Three sampling positions", universe: 1, address: 4,
                                  points: [Point2(0.1, 0.25), Point2(0.5, 0.5), Point2(0.9, 0.75)], channelOrder: "RGB")
            lighting.fixtures = [fixture]
            let gradient = Surface(name: "Known output gradient", output: Point2.unitQuad, generator: "gradient")
            let expected: [UInt8] = [26, 64, 229, 128, 128, 127, 230, 192, 25]
            func expect(_ condition: Bool, _ message: String) throws {
                guard condition else { throw SystemFailure(message: message) }
            }
            func channelsMatch(_ channels: [UInt8], address: Int, values: [UInt8], tolerance: Int = 2) -> Bool {
                guard channels.count == 512, address > 0, address - 1 + values.count <= 512 else { return false }
                for index in values.indices {
                    if abs(Int(channels[address - 1 + index]) - Int(values[index])) > tolerance { return false }
                }
                return true
            }
            func receive(_ receiver: Receiver, surfaces: [Surface]) throws -> Data {
                receiver.drain()
                lighting.update(surfaces: surfaces)
                var packet: Data?
                let end = Date(timeIntervalSinceNow: 5)
                repeat {
                    if let data = receiver.receive() { packet = data; break }
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
                } while Date() < end
                guard let packet else { throw SystemFailure(message: "No lighting packet within 5 s: \(lighting.errorDescription)") }
                return packet
            }
            lighting.wireProtocol = .artnet
            let first = try ArtNetCodec.decode(receive(artnet, surfaces: [gradient]))
            try expect(artnet.lastPeerPort == 6454, "ArtDmx source UDP port must be 6454, got \(artnet.lastPeerPort)")
            try expect(first.universe == 1 && first.sequence != 0, "ArtDmx universe or sequence mismatch")
            try expect(first.channels.prefix(3).allSatisfy { $0 == 0 } && channelsMatch(first.channels, address: 4, values: expected), "GPU->ArtDmx channel samples differ: \(Array(first.channels.prefix(12)))")
            checks.append("ArtDmx actual UDP port 6454, universe 1, one-based address 4, three gradient RGB samples ±2/255")
            report["artnetSamples"] = Array(first.channels[3..<12])
            report["artnetSourcePort"] = artnet.lastPeerPort

            lighting.wireProtocol = .sacn
            let second = try SACNCodec.decode(receive(sacn, surfaces: [gradient]))
            try expect(second.universe == 1 && second.sequence == 1 && second.sourceName == "ApertureCue", "sACN metadata or initial per-universe sequence mismatch")
            try expect(channelsMatch(second.channels, address: 4, values: expected), "GPU->sACN channel samples differ")
            checks.append("sACN actual UDP port 5568, source/CID framing and same sampled channel bytes")
            report["sacnSamples"] = Array(second.channels[3..<12])

            fixture.channelOrder = "GRB"; fixture.universe = 2; fixture.address = 1
            lighting.fixtures = [fixture]; lighting.wireProtocol = .artnet
            let grb: [UInt8] = [64, 26, 229, 128, 128, 127, 192, 230, 25]
            let third = try ArtNetCodec.decode(receive(artnet, surfaces: [gradient]))
            try expect(third.universe == 2 && channelsMatch(third.channels, address: 1, values: grb), "GRB patch/order differs")
            checks.append("fixture universe/address edit and GRB reordering")

            fixture.channelOrder = "RGBW"; fixture.points = [Point2(0.5, 0.5)]
            lighting.fixtures = [fixture]; lighting.wireProtocol = .sacn
            let fourth = try SACNCodec.decode(receive(sacn, surfaces: [gradient]))
            try expect(channelsMatch(fourth.channels, address: 1, values: [1, 1, 0, 127]), "RGBW white extraction differs")
            checks.append("RGBW white extraction in full pipeline")

            fixture.channelOrder = "RGB"; fixture.points = [Point2(0.5, 0.5)]
            lighting.fixtures = [fixture]
            let track = AutomationTrack(name: "Opacity", surfaceID: gradient.id, parameter: "opacity",
                keyframes: [AutomationKeyframe(time: 0, value: 0), AutomationKeyframe(time: 2, value: 1)])
            let animated = try TimelineEngine.apply(tracks: [track], time: 1, surfaces: [gradient])
            let fifth = try SACNCodec.decode(receive(sacn, surfaces: animated))
            try expect(channelsMatch(fifth.channels, address: 1, values: [64, 64, 64]), "Lighting ignored evaluated automation surfaces")
            checks.append("evaluated opacity automation reaches sampled network channels")

            renderer.outputID = UUID()
            var routed = gradient; routed.outputID = UUID()
            let sixth = try SACNCodec.decode(receive(sacn, surfaces: [routed]))
            try expect(sixth.channels.allSatisfy { $0 == 0 }, "Output routing filter leaked into sampled universe")
            renderer.outputID = routed.outputID
            let seventh = try SACNCodec.decode(receive(sacn, surfaces: [routed]))
            try expect(channelsMatch(seventh.channels, address: 1, values: [128, 128, 127]), "Matched output routing did not reach lighting")
            checks.append("renderer output routing before fixture sampling")

            renderer.outputID = nil; renderer.blackout = true
            let eighth = try SACNCodec.decode(receive(sacn, surfaces: [gradient]))
            try expect(eighth.channels.allSatisfy { $0 == 0 }, "Blackout did not produce zero network levels")
            renderer.blackout = false
            checks.append("blackout propagates to zero-valued network levels")

            // Change the sampled value so completion is observable without
            // relying on a timing assumption or a previous cached universe.
            lighting.isSending = false
            let white = Surface(name: "White", output: Point2.unitQuad, generator: "solid")
            sacn.drain(); lighting.update(surfaces: [white])
            let end = Date(timeIntervalSinceNow: 5)
            while lighting.lastUniverses[2]?.first != 255, Date() < end {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            }
            try expect(lighting.lastUniverses[2]?.first == 255, "Simulator stopped updating when network send disabled")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            try expect(sacn.receive() == nil, "Network send occurred after disabled sampling update")
            checks.append("simulation continues with network output disabled")

            func waitPackets(_ receiver: Receiver, count: Int) throws -> [Data] {
                var packets: [Data] = []
                let deadline = Date(timeIntervalSinceNow: 5)
                repeat {
                    while let data = receiver.receive() { packets.append(data) }
                    if packets.count >= count { return packets }
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
                } while Date() < deadline
                throw SystemFailure(message: "Expected \(count) stop packets, received \(packets.count): \(lighting.errorDescription)")
            }

            lighting.wireProtocol = .artnet; lighting.isSending = true; lighting.isSampling = true
            _ = try ArtNetCodec.decode(receive(artnet, surfaces: [white]))
            artnet.drain(); lighting.stop()
            let artnetStop = try waitPackets(artnet, count: 1).map(ArtNetCodec.decode)
            try expect(artnetStop.count == 1 && artnetStop[0].universe == 2 && artnetStop[0].channels.allSatisfy { $0 == 0 }, "Art-Net stop did not send exactly one zeroed universe")
            try expect(!lighting.isSampling && !lighting.isSending && lighting.lastUniverses.isEmpty, "Stop left sampling/send state active")
            checks.append("Art-Net stop emits zero levels and resets local output state")

            lighting.wireProtocol = .sacn; lighting.isSending = true; lighting.isSampling = true
            let activeSACN = try SACNCodec.decode(receive(sacn, surfaces: [white]))
            sacn.drain(); lighting.stop()
            let terminated = try waitPackets(sacn, count: 4).map(SACNCodec.decode)
            try expect(terminated.count == 4, "sACN stop did not emit ordinary zero data followed by three termination packets")
            for (index, packet) in terminated.enumerated() {
                let expectedTermination = index > 0
                try expect(packet.universe == 2 && packet.cid == activeSACN.cid && (packet.options & 0x40 != 0) == expectedTermination,
                           "sACN stop lost universe, CID or stream-terminated flag")
                try expect(packet.channels.allSatisfy { $0 == 0 }, "sACN termination retained nonzero levels")
                let previous = index == 0 ? activeSACN.sequence : terminated[index - 1].sequence
                try expect(packet.sequence == previous &+ 1, "sACN stop sequence is not consecutive")
            }
            checks.append("sACN stop emits ordinary zero data then three consecutive StreamTerminated packets retaining CID")

            // A GPU readback completion cannot run on the main thread before
            // this immediate stop. The stale completion must be discarded.
            lighting.wireProtocol = .artnet; lighting.isSampling = true; lighting.isSending = true
            artnet.drain(); sacn.drain()
            lighting.update(surfaces: [white]); lighting.stop()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            try expect(artnet.receive() == nil && sacn.receive() == nil && lighting.lastUniverses.isEmpty,
                       "Stale asynchronous sampling completion emitted or restored output after stop")
            lighting.isSampling = true; lighting.isSending = true
            let restarted = try ArtNetCodec.decode(receive(artnet, surfaces: [white]))
            try expect(channelsMatch(restarted.channels, address: 1, values: [255, 255, 255]), "Sampling stayed busy after stale completion was discarded")
            artnet.drain(); lighting.stop()
            let finalStop = try ArtNetCodec.decode(waitPackets(artnet, count: 1)[0])
            try expect(finalStop.channels.allSatisfy { $0 == 0 }, "Restarted output did not stop with zero levels")
            checks.append("stop discards in-flight GPU sampling completion and permits a clean restart")

            report["passed"] = true; report["checks"] = checks
            report["sampleResolution"] = [320, 180]
            report["samplePixelConvention"] = "floor(normalizedPosition*dimension), shader samples that pixel center"
            report["packetCount"] = 17
            try write(report, to: directory)
            print("PASS: \(checks.count) production lighting pipeline checks. Report: \(directory.appendingPathComponent("lighting-test.json").path)")
            return 0
        } catch {
            report["passed"] = false; report["checks"] = checks; report["failure"] = error.localizedDescription
            try? write(report, to: directory)
            fputs("LIGHTING TEST FAILED: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func write(_ report: [String: Any], to directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("lighting-test.json"), options: .atomic)
    }
}
#endif
