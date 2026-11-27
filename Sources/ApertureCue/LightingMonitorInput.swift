#if os(macOS)
import Darwin
import Foundation
import MappingCore

/// A diagnostic receiver deliberately isolated from the sender's standard ports.
/// It keeps one bounded, locally sourced universe and one source identity.
final class LightingMonitorInput {
    struct Frame: Equatable, Sendable {
        let universe: Int
        let channels: [UInt8]
    }

    struct Snapshot {
        let frame: Frame?
        let received: Int
        let discarded: Int
        let isStale: Bool
    }

    private struct Source: Equatable {
        let address: UInt32
        let port: UInt16
        let cid: UUID?
    }

    private static let timeout = 1.0
    private let queue = DispatchQueue(label: "org.aperturecue.lighting.monitor")
    private var timer: DispatchSourceTimer?
    private var socketFD: Int32 = -1
    private var universe: Int?
    private var frame: Frame?
    private var source: Source?
    private var lastSequence: UInt8?
    private var lastFrameAt: Double?
    private var received = 0
    private var discarded = 0
    private var wire = LightingController.WireProtocol.artnet

    var listenUniverse: Int? { queue.sync { universe } }

    deinit {
        timer?.cancel()
        if socketFD >= 0 { Darwin.close(socketFD) }
    }

    /// Returns the bound port. Port zero is reserved for internal fixtures.
    @discardableResult
    func start(port: UInt16, universe: Int, wire: LightingController.WireProtocol) throws -> UInt16 {
        let range = wire == .artnet ? 0...32767 : 1...63999
        guard range.contains(universe), port != ArtNetCodec.port, port != SACNCodec.port else {
            throw SystemFailure(message: "Choose a valid universe and a local UDP port other than 6454 or 5568.")
        }
        return try queue.sync {
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { throw Self.failure("Create diagnostic receiver") }
            do {
                guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                    throw Self.failure("Configure diagnostic receiver")
                }
                var local = sockaddr_in()
                local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                local.sin_family = sa_family_t(AF_INET)
                local.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
                local.sin_port = port.bigEndian
                let size = socklen_t(MemoryLayout<sockaddr_in>.size)
                let bound = withUnsafePointer(to: &local) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
                }
                guard bound == 0 else { throw Self.failure("Bind local DMX receiver") }
                var actualSize = size
                let found = withUnsafeMutablePointer(to: &local) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &actualSize) }
                }
                guard found == 0 else { throw Self.failure("Read diagnostic receiver port") }
                stopLocked()
                socketFD = fd
                self.universe = universe
                self.wire = wire
                let poll = DispatchSource.makeTimerSource(queue: queue)
                poll.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
                poll.setEventHandler { [weak self] in self?.drain() }
                timer = poll
                poll.resume()
                return UInt16(bigEndian: local.sin_port)
            } catch {
                Darwin.close(fd)
                throw error
            }
        }
    }

    func stop() { queue.sync { stopLocked() } }

    func snapshot(at hostTime: Double) -> Snapshot {
        queue.sync {
            let stale = lastFrameAt.map { hostTime - $0 >= Self.timeout } ?? false
            return Snapshot(frame: stale ? nil : frame, received: received, discarded: discarded, isStale: stale)
        }
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        if socketFD >= 0 { Darwin.close(socketFD) }
        socketFD = -1
        universe = nil
        frame = nil
        source = nil
        lastSequence = nil
        lastFrameAt = nil
        received = 0
        discarded = 0
    }

    private func drain() {
        guard socketFD >= 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastFrameAt, now - lastFrameAt >= Self.timeout {
            frame = nil
            source = nil
            lastSequence = nil
        }
        var bytes = [UInt8](repeating: 0, count: 1024)
        for _ in 0..<32 {
            var peer = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = bytes.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &peer) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(socketFD, raw.baseAddress, raw.count, 0, $0, &size)
                    }
                }
            }
            guard count >= 0 else { break }
            guard count > 0, count < bytes.count, UInt32(bigEndian: peer.sin_addr.s_addr) >> 24 == 127,
                  consume(Data(bytes.prefix(count)), from: peer, now: now) else {
                discarded &+= 1
                continue
            }
            received &+= 1
        }
    }

    private func consume(_ bytes: Data, from peer: sockaddr_in, now: Double) -> Bool {
        let next: Frame
        let incoming: Source
        let sequence: UInt8
        switch wire {
        case .artnet:
            guard let packet = try? ArtNetCodec.decode(bytes), packet.universe == universe else { return false }
            incoming = Source(address: peer.sin_addr.s_addr, port: peer.sin_port, cid: nil)
            sequence = packet.sequence
            next = Frame(universe: packet.universe, channels: packet.channels)
        case .sacn:
            guard let packet = try? SACNCodec.decode(bytes), packet.universe == universe,
                  packet.options & 0x80 == 0, packet.synchronizationAddress == 0 else { return false }
            // The application sender also may use a new UDP source port per frame.
            incoming = Source(address: peer.sin_addr.s_addr, port: 0, cid: packet.cid)
            if packet.options & 0x40 != 0 {
                guard source == incoming else { return false }
                frame = nil
                source = nil
                lastSequence = nil
                lastFrameAt = nil
                return true
            }
            sequence = packet.sequence
            next = Frame(universe: packet.universe, channels: packet.channels)
        }
        guard source == nil || source == incoming else { return false }
        if let lastSequence {
            if wire == .artnet, sequence != 0, lastSequence != 0 {
                let difference = (Int(sequence) - Int(lastSequence) + 255) % 255
                guard (1...127).contains(difference) else { return false }
            } else if wire == .sacn {
                guard (1...127).contains(sequence &- lastSequence) else { return false }
            }
        }
        source = incoming
        lastSequence = sequence
        frame = next
        lastFrameAt = now
        return true
    }

    private static func failure(_ operation: String) -> SystemFailure {
        SystemFailure(message: "\(operation): \(String(cString: strerror(errno)))")
    }
}
#endif
