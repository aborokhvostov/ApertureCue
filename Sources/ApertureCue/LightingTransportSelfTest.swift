#if os(macOS)
import Foundation
import Darwin
import MappingCore

@MainActor
enum LightingTransportSelfTest {
    private final class Receiver {
        private(set) var descriptor: Int32
        let port: UInt16
        private let capturesDestination: Bool

        init(port: UInt16, wildcard: Bool = false, reuse: Bool = true, group: String? = nil) throws {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { throw SystemFailure(message: "Cannot create test receiver") }
            descriptor = fd
            capturesDestination = group != nil
            self.port = try Self.configure(fd, port: port, wildcard: wildcard, reuse: reuse, group: group)
        }

        deinit {
            if descriptor >= 0 { Darwin.close(descriptor) }
        }

        func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }

        private static func configure(_ fd: Int32, port: UInt16, wildcard: Bool, reuse: Bool, group: String?) throws -> UInt16 {
            do {
                if reuse {
                    var yes: Int32 = 1
                    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
                    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
                }
                var endpoint = local(port: port, wildcard: wildcard)
                let bindResult = withUnsafeMutablePointer(to: &endpoint) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard bindResult == 0, fcntl(fd, F_SETFL, O_NONBLOCK) >= 0 else {
                    throw SystemFailure(message: "Test receiver bind: " + String(cString: strerror(errno)))
                }
                if let group {
                    var enabled: Int32 = 1
                    guard setsockopt(fd, IPPROTO_IP, IP_RECVDSTADDR, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                        throw SystemFailure(message: "Cannot record multicast destination address")
                    }
                    var membership = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(group)),
                                             imr_interface: in_addr(s_addr: inet_addr("127.0.0.1")))
                    guard setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership,
                                     socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
                        throw SystemFailure(message: "Loopback multicast join: " + String(cString: strerror(errno)))
                    }
                }
                var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                let readResult = withUnsafeMutablePointer(to: &endpoint) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
                }
                guard readResult == 0 else { throw SystemFailure(message: "No UDP test receiver endpoint") }
                return UInt16(bigEndian: endpoint.sin_port)
            } catch {
                Darwin.close(fd)
                throw error
            }
        }

        private static func local(port: UInt16, wildcard: Bool = false) -> sockaddr_in {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = wildcard ? 0 : inet_addr("127.0.0.1")
            return address
        }

        func receive() -> (Data, UInt16, String?)? {
            var bytes = [UInt8](repeating: 0, count: 1024)
            var peer = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            var destination: String?
            let count = bytes.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { endpoint in
                        if capturesDestination {
                            let result = receiveWithDestination(bytes, endpoint: endpoint)
                            destination = result.1
                            return result.0
                        }
                        return recvfrom(descriptor, bytes.baseAddress, bytes.count, 0, endpoint, &size)
                    }
                }
            }
            return count > 0 ? (Data(bytes.prefix(count)), UInt16(bigEndian: peer.sin_port), destination) : nil
        }

        private func receiveWithDestination(_ bytes: UnsafeMutableRawBufferPointer,
                                            endpoint: UnsafeMutablePointer<sockaddr>) -> (Int, String?) {
            var vector = iovec(iov_base: bytes.baseAddress, iov_len: bytes.count)
            var ancillary = [UInt32](repeating: 0, count: 16)
            return ancillary.withUnsafeMutableBytes { control in
                withUnsafeMutablePointer(to: &vector) { vector in
                    var message = msghdr(msg_name: UnsafeMutableRawPointer(endpoint),
                                        msg_namelen: socklen_t(MemoryLayout<sockaddr_in>.size),
                                        msg_iov: vector, msg_iovlen: 1,
                                        msg_control: control.baseAddress, msg_controllen: socklen_t(control.count),
                                        msg_flags: 0)
                    let count = recvmsg(descriptor, &message, 0)
                    let offset = (MemoryLayout<cmsghdr>.size + 3) & ~3
                    guard count > 0, Int(message.msg_controllen) >= offset + 4 else { return (count, nil) }
                    let header = control.loadUnaligned(as: cmsghdr.self)
                    guard header.cmsg_level == IPPROTO_IP, header.cmsg_type == IP_RECVDSTADDR else { return (count, nil) }
                    let group = (offset..<(offset + 4)).map { String(control[$0]) }.joined(separator: ".")
                    return (count, group)
                }
            }
        }

        func send(_ data: Data, to port: UInt16) throws {
            var peer = Self.local(port: port)
            let sent = data.withUnsafeBytes { bytes in
                withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == data.count else { throw SystemFailure(message: "Simulator reply failed") }
        }
    }

    static func run() -> Int32 {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/local/lighting-transport", isDirectory: true)
        let report = directory.appendingPathComponent("report.json")
        var checks: [String] = []
        var results: [String: Any] = [
            "reportVersion": 1,
            "scope": "Real macOS UDP sockets on loopback only, original simulated Art-Net node, no device probes",
            "hardwareVerification": false
        ]
        let start = ProcessInfo.processInfo.systemUptime
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try checkTargetedDiscovery()
            checks.append("targeted ArtPoll from source port 6454 accepts two deduplicated original bindings, reports loss and rediscovers")
            results["sampleRateDeltaSeconds"] = try checkSyncRateAndRetirement()
            checks.append("unicast sync order and CID, bounded newest-frame replacement, universe retirement and stop")
            try checkMulticast()
            checks.append("two sACN data universes and a distinct sync universe reach their IPv4 multicast groups on loopback")
            try checkSocketRecovery()
            checks.append("exclusive Art-Net port loss retries the latest frame after socket recovery; Stop sends zero")
            results["passed"] = true
        } catch {
            results["passed"] = false
            results["error"] = error.localizedDescription
            fputs("LIGHTING TRANSPORT FAILED: \(error.localizedDescription)\n", stderr)
        }
        results["checks"] = checks
        results["checkCount"] = checks.count
        results["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
        do {
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        } catch {
            fputs("Lighting transport report write failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
        if results["passed"] as? Bool == true {
            print("PASS lighting transport: \(checks.count) checks. \(report.path)")
            return 0
        }
        return 1
    }

    private static func checkTargetedDiscovery() throws {
        let controller = LightingController()
        let node = try Receiver(port: 0)
        let range = 0x120...0x124
        func probe(reply: Bool) throws -> [ArtPollReply] {
            var answer: Result<[ArtPollReply], Error>?
            try controller.discoverArtNet(address: "127.0.0.1", range: range, peerPort: node.port,
                                         timeout: 0.25, minimumInterval: 0.0) { answer = $0 }
            let request = try receive(node, count: 1)[0]
            try require(request.1 == ArtNetCodec.port, "ArtPoll source UDP port mismatch")
            try require(try ArtNetDiscoveryCodec.decodePoll(request.0) == range, "Inclusive targeted range changed")
            if reply {
                try node.send(Data([1, 2, 3]), to: request.1)
                try node.send(replyFixture(binding: 1, portAddress: 0x122), to: request.1)
                try node.send(replyFixture(binding: 1, portAddress: 0x122), to: request.1)
                try node.send(replyFixture(binding: 2, portAddress: 0x124), to: request.1)
                try node.send(replyFixture(binding: 3, portAddress: 0x128), to: request.1)
            }
            try wait(2) { answer != nil }
            guard let answer else { throw SystemFailure(message: "Targeted response did not complete") }
            return try answer.get()
        }
        let first = try probe(reply: true)
        try require(first.map(\.bindingIndex) == [1, 2], "Probe did not filter the original simulated bindings")
        try require(try probe(reply: false).isEmpty, "A missing reply returned stale bindings")
        try require(try probe(reply: true) == first, "Explicit re-probe did not rediscover the resumed endpoint")
    }

    private static func replyFixture(binding: UInt8, portAddress: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 239)
        bytes.replaceSubrange(0..<16, with: Array("Art-Net\0".utf8) + [0, 0x21, 127, 0, 0, 1, 0x36, 0x19])
        let name = Array("Original loopback node".utf8)
        bytes.replaceSubrange(44..<(44 + name.count), with: name)
        bytes[18] = UInt8(portAddress >> 8)
        bytes[19] = UInt8((portAddress >> 4) & 15)
        bytes[173] = 1
        bytes[174] = 0x80
        bytes[190] = UInt8(portAddress & 15)
        bytes.replaceSubrange(207..<212, with: [127, 0, 0, 1, binding])
        return Data(bytes)
    }

    private static func checkSyncRateAndRetirement() throws -> Double {
        let controller = LightingController()
        let receiver = try Receiver(port: SACNCodec.port)
        try controller.startNetworkOutput(mode: .sacn, address: "127.0.0.1", multicast: false,
                                          synchronizationAddress: 300, maximumRateHz: 5)
        controller.publishUniverseFrame([1: [11], 2: [22]])
        let first = try receive(receiver, count: 3).map(\.0)
        let a = try SACNCodec.decode(first[0])
        let b = try SACNCodec.decode(first[1])
        let sync = try SACNSynchronizationCodec.decode(first[2])
        try require(a.universe == 1 && b.universe == 2 && a.channels == [11] && b.channels == [22],
                    "sACN frame missing data universes before sync")
        try require(a.cid == b.cid && a.cid == sync.cid && a.synchronizationAddress == 300 &&
                    b.synchronizationAddress == 300 && sync.address == 300 && sync.sequence == 1,
                    "sACN framing did not bind both data universes to an independent sync sequence")
        let firstTime = ProcessInfo.processInfo.systemUptime
        for byte: UInt8 in 1...60 { controller.publishUniverseFrame([1: [byte]]) }
        let retired = try receive(receiver, count: 6).map(\.0)
        let delta = ProcessInfo.processInfo.systemUptime - firstTime
        let newest = try SACNCodec.decode(retired[0])
        let zero = try SACNCodec.decode(retired[1])
        let nextSync = try SACNSynchronizationCodec.decode(retired[2])
        try require(newest.channels == [60] && newest.universe == 1 && newest.sequence == a.sequence &+ 1 && delta >= 0.17,
                    "Rate limiter dropped the newest frame or transmitted too early")
        try require(zero.universe == 2 && zero.channels == [0] && zero.options == 0 &&
                    nextSync.sequence == sync.sequence &+ 1, "Retirement lacked ordered sync and zero data")
        for (offset, bytes) in retired.dropFirst(3).enumerated() {
            let packet = try SACNCodec.decode(bytes)
            try require(packet.universe == 2 && packet.options == 0x40 && packet.synchronizationAddress == 0 &&
                        packet.channels == [0] && packet.sequence == zero.sequence &+ UInt8(offset + 1),
                        "Per-universe termination broke sequence, flags or ordering")
        }
        controller.stop()
        let stopped = try receive(receiver, count: 5).map(\.0)
        try require(try SACNCodec.decode(stopped[0]).universe == 1 &&
                    SACNCodec.decode(stopped[0]).channels == [0] &&
                    SACNSynchronizationCodec.decode(stopped[1]).address == 300 &&
                    stopped.dropFirst(2).allSatisfy { (try? SACNCodec.decode($0).options) == 0x40 },
                    "Stop did not publish one synchronized zero and three terminations for remaining universe")
        return delta
    }

    private static func checkMulticast() throws {
        let us = [258, 259, 300]
        // Using one listener mirrors an application joining three groups. Each
        // test sender binds the multicast interface to 127.0.0.1 explicitly.
        let receiver = try Receiver(port: SACNCodec.port, wildcard: true, group: "239.255.1.2")
        for group in ["239.255.1.3", "239.255.1.44"] {
            var membership = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(group)),
                                     imr_interface: in_addr(s_addr: inet_addr("127.0.0.1")))
            try require(setsockopt(receiver.descriptor, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership,
                                   socklen_t(MemoryLayout<ip_mreq>.size)) == 0,
                        "Cannot join the test multicast group on loopback")
        }
        let controller = LightingController(loopbackMulticast: true)
        try controller.startNetworkOutput(mode: .sacn, address: "", multicast: true,
                                          synchronizationAddress: us[2], maximumRateHz: 30)
        controller.publishUniverseFrame([us[0]: [50], us[1]: [80]])
        let frame = try receive(receiver, count: 3)
        try require(try SACNCodec.decode(frame[0].0).universe == us[0] &&
                    SACNCodec.decode(frame[1].0).universe == us[1] &&
                    SACNSynchronizationCodec.decode(frame[2].0).address == us[2] &&
                    frame.map(\.2) == ["239.255.1.2", "239.255.1.3", "239.255.1.44"],
                    "Unexpected multicast frame or kernel-reported destination group")
        controller.stop()
        _ = try receive(receiver, count: 9)
    }

    private static func checkSocketRecovery() throws {
        let blocker = try Receiver(port: ArtNetCodec.port, wildcard: true, reuse: false)
        let controller = LightingController()
        try controller.startNetworkOutput(mode: .artnet, address: "127.0.0.1", multicast: false,
                                          synchronizationAddress: 0, maximumRateHz: 30)
        controller.publishUniverseFrame([5: [17, 19]])
        try wait(2) { controller.errorDescription.contains("retrying") }
        controller.publishUniverseFrame([5: [30, 31]])
        blocker.close()
        let receiver = try Receiver(port: ArtNetCodec.port)
        let packet = try receive(receiver, count: 1)[0]
        let frame = try ArtNetCodec.decode(packet.0)
        try require(frame.universe == 5 && frame.channels == [30, 31] && packet.1 == ArtNetCodec.port,
                    "Socket recovery sent stale levels, wrong universe or source port")
        controller.stop()
        let stopped = try ArtNetCodec.decode(receive(receiver, count: 1)[0].0)
        try require(stopped.universe == 5 && stopped.channels == [0, 0] && stopped.sequence == frame.sequence &+ 1,
                    "Recovered output did not stop with a sequenced zero frame")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw SystemFailure(message: message) }
    }

    private static func wait(_ seconds: Double, until condition: () -> Bool) throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < end else { throw SystemFailure(message: "Lighting transport timeout") }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    private static func receive(_ receiver: Receiver, count: Int) throws -> [(Data, UInt16, String?)] {
        var replies: [(Data, UInt16, String?)] = []
        try wait(3) {
            while let frame = receiver.receive(), replies.count < 64 { replies.append(frame) }
            return replies.count >= count
        }
        try require(replies.count == count, "Unexpected lighting datagram count")
        return replies
    }
}
#endif
