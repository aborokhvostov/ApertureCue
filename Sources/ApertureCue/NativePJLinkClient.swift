#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import MappingCore

final class PJLinkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Delivers one explicit transaction to one numeric IPv4 endpoint. A worker
/// owns the socket from creation through close. Cancel polls within 50 ms.
enum NativePJLinkClient {
    static func run(host: String, port: UInt16 = PJLinkClient.port, authentication: PJLinkAuthentication,
                    password: String, commands: [PJLinkCommand], cancellation: PJLinkCancellation,
                    seconds: Double = 8, nonce: () -> [UInt8] = randomNonce) throws -> [PJLinkReply] {
        guard seconds.isFinite, (0.05...15).contains(seconds), port != 0 else {
            throw PJLinkProtocolError.invalidTransaction
        }
        guard !cancellation.isCancelled else { throw PJLinkProtocolError.cancelled }
        var socket = try PJLinkSocket(host: host, port: port, deadline: ProcessInfo.processInfo.systemUptime + seconds,
                                      cancellation: cancellation)
        defer { socket.close() }
        return try PJLinkClient.transact(over: &socket, using: authentication, password: password, commands: commands,
                                        controllerNonce: nonce) { algorithm, bytes in
            switch algorithm {
            case .sha256: return Array(SHA256.hash(data: bytes))
            case .md5: return Array(Insecure.MD5.hash(data: bytes))
            }
        }
    }

    static func randomNonce() -> [UInt8] {
        var random = SystemRandomNumberGenerator()
        return (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &random) }
    }
}

private struct PJLinkSocket: PJLinkTransport {
    private let fd: Int32
    private let deadline: Double
    private let cancellation: PJLinkCancellation
    private var decoder = PJLinkLineDecoder()

    init(host: String, port: UInt16, deadline: Double, cancellation: PJLinkCancellation) throws {
        var ipv4 = in_addr()
        guard host.utf8.count <= 15, host.utf8.allSatisfy({ $0 == 46 || (48...57).contains($0) }),
              inet_pton(AF_INET, host, &ipv4) == 1 else {
            throw SystemFailure(message: "Enter one numeric IPv4 projector address.")
        }
        let first = UInt32(bigEndian: ipv4.s_addr) >> 24
        guard (1...223).contains(first) else {
            throw SystemFailure(message: "Choose a unicast IPv4 projector address.")
        }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw Self.systemError("open PJLink socket", errno) }
        self.fd = fd
        self.deadline = deadline
        self.cancellation = cancellation
        var success = false
        defer { if !success { Darwin.close(fd) } }
        var preventSIGPIPE: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &preventSIGPIPE, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw Self.systemError("configure PJLink socket", errno)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = ipv4
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            let code = errno
            guard code == EINPROGRESS || code == EINTR else { throw Self.systemError("connect to projector", code) }
            try wait(for: Int16(POLLOUT))
            var connectionError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &connectionError, &length) == 0 else {
                throw Self.systemError("check PJLink connection", errno)
            }
            guard connectionError == 0 else { throw Self.systemError("connect to projector", connectionError) }
        }
        success = true
    }

    func close() { Darwin.close(fd) }

    mutating func send(_ message: Data) throws {
        guard !message.isEmpty, message.count <= 256 else { throw PJLinkProtocolError.invalidTransaction }
        try message.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw PJLinkProtocolError.invalidTransaction }
            var sent = 0
            while sent < bytes.count {
                try wait(for: Int16(POLLOUT))
                let result = Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, 0)
                if result > 0 { sent += result; continue }
                if result == 0 { throw PJLinkProtocolError.disconnected }
                let code = errno
                guard code == EINTR || code == EAGAIN else { throw Self.systemError("write PJLink command", code) }
            }
        }
    }

    mutating func receiveLine() throws -> String {
        var buffer = [UInt8](repeating: 0, count: PJLinkLineDecoder.maximumFragmentBytes)
        while true {
            try wait(for: Int16(POLLIN))
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 { throw PJLinkProtocolError.disconnected }
            if count < 0 {
                let code = errno
                if code == EINTR || code == EAGAIN { continue }
                throw Self.systemError("read PJLink reply", code)
            }
            let lines = try decoder.append(Data(buffer.prefix(count)))
            if let line = lines.first {
                // This client has exactly one outstanding command. A second
                // unsolicited reply cannot be reused for a future command.
                guard lines.count == 1, !decoder.hasPartialLine else { throw PJLinkProtocolError.malformedReply }
                return line
            }
        }
    }

    private func wait(for events: Int16) throws {
        while true {
            guard !cancellation.isCancelled else { throw PJLinkProtocolError.cancelled }
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { throw PJLinkProtocolError.timedOut }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(50, ceil(left * 1_000))))
            if result > 0 {
                if descriptor.revents & Int16(POLLNVAL) != 0 { throw PJLinkProtocolError.disconnected }
                return
            }
            if result < 0, errno != EINTR { throw Self.systemError("check PJLink socket", errno) }
        }
    }

    private static func systemError(_ operation: String, _ code: Int32) -> SystemFailure {
        SystemFailure(message: "Cannot " + operation + " (" + String(cString: strerror(code)) + ").")
    }
}
#endif
