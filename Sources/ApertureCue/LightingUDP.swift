#if os(macOS)
import Foundation
import Darwin
import MappingCore

struct LightingWireTarget: Hashable, Sendable {
    let mode: LightingController.WireProtocol
    let address: String
    let multicast: Bool
    let synchronizationAddress: Int

    func destination(for universe: Int) throws -> String {
        if multicast { return try SACNCodec.multicastAddress(universe: universe) }
        return address
    }
    var port: UInt16 { mode == .artnet ? ArtNetCodec.port : SACNCodec.port }
}

struct LightingDatagram: Sendable {
    let destination: String
    let data: Data
}

enum LightingUDP {
    static func unicastAddress(_ text: String) throws -> in_addr {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else {
            throw SystemFailure(message: "Enter a numeric IPv4 destination")
        }
        let number = UInt32(bigEndian: address.s_addr)
        let first = number >> 24
        guard (1..<224).contains(first), number != 0x02ff_ffff, number != 0x0aff_ffff else {
            throw SystemFailure(message: "Enter a unicast IPv4 destination")
        }
        return address
    }

    private static func address(_ host: in_addr, port: UInt16) -> sockaddr_in {
        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        endpoint.sin_family = sa_family_t(AF_INET)
        endpoint.sin_port = port.bigEndian
        endpoint.sin_addr = host
        return endpoint
    }

    private static func open(artNet: Bool, multicastInterface: in_addr? = nil) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SystemFailure(message: "Cannot create lighting UDP socket") }
        do {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) >= 0 else { throw socketFailure("Lighting UDP socket") }
            if artNet {
                var yes: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
                var local = address(in_addr(), port: ArtNetCodec.port)
                let result = withUnsafePointer(to: &local) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard result == 0 else { throw socketFailure("Art-Net source port 6454") }
            }
            if var interface = multicastInterface {
                guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &interface, socklen_t(MemoryLayout<in_addr>.size)) == 0 else {
                    throw socketFailure("sACN multicast interface")
                }
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func socketFailure(_ action: String) -> SystemFailure {
        SystemFailure(message: "\(action): \(String(cString: strerror(errno)))")
    }

    private static func send(_ data: Data, to host: in_addr, port: UInt16, fd: Int32) throws {
        var peer = address(host, port: port)
        let count = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard count == data.count else { throw socketFailure("Lighting UDP send") }
    }

    static func transmit(_ datagrams: [LightingDatagram], target: LightingWireTarget,
                         multicastInterface: in_addr? = nil) throws {
        guard !datagrams.isEmpty else { return }
        let fd = try open(artNet: target.mode == .artnet, multicastInterface: multicastInterface)
        defer { close(fd) }
        if target.multicast {
            var ttl: UInt8 = 1
            guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size)) == 0 else {
                throw socketFailure("sACN multicast scope")
            }
        }
        for datagram in datagrams {
            var host = in_addr()
            guard inet_pton(AF_INET, datagram.destination, &host) == 1 else {
                throw SystemFailure(message: "Invalid lighting endpoint")
            }
            try send(datagram.data, to: host, port: target.port, fd: fd)
        }
    }

    /// A single targeted probe to an explicit peer and a bounded reply window.
    /// Production uses the Art-Net port. An isolated software node may inject a
    /// different peer port and never sends to an external interface.
    static func discover(_ request: Data, target: String, range: ClosedRange<Int>,
                         peerPort: UInt16 = ArtNetCodec.port, timeout: Double = 1.2) throws -> [ArtPollReply] {
        let peerAddress = try unicastAddress(target)
        let fd = try open(artNet: true)
        defer { close(fd) }
        try send(request, to: peerAddress, port: peerPort, fd: fd)

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bindings: [String: ArtPollReply] = [:]
        var inspected = 0
        var buffer = [UInt8](repeating: 0, count: 1024)
        while inspected < 128, bindings.count < 32 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&readiness, 1, Int32(max(1, min(1200, remaining * 1000))))
            if result == 0 { break }
            if result < 0 {
                if errno == EINTR { continue }
                throw socketFailure("ArtPoll response wait")
            }
            guard readiness.revents & Int16(POLLIN) != 0 else { break }
            var peer = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &size)
                    }
                }
            }
            inspected += 1
            guard count > 0, peer.sin_addr.s_addr == peerAddress.s_addr,
                  UInt16(bigEndian: peer.sin_port) == peerPort,
                  let reply = try? ArtNetDiscoveryCodec.decodeReply(Data(buffer.prefix(count))),
                  reply.subscriptions.contains(where: range.contains) else { continue }
            let key = "\(reply.bindingAddress ?? reply.advertisedAddress):\(reply.bindingIndex)"
            bindings[key] = reply
        }
        return bindings.sorted { $0.key < $1.key }.map(\.value)
    }
}
#endif
