#if os(macOS)
import Foundation
import Darwin

/// Exact IPv4 bind and exclusive TCP port ownership. SO_REUSEADDR allows
/// restart when this listener's old connections are still in TIME_WAIT.
enum OSCQuerySocket {
    struct Failure: LocalizedError {
        let operation: String
        let status: Int32
        var errorDescription: String? { "OSC Query \(operation): \(String(cString: strerror(status)))" }
    }

    enum Incoming {
        case peer(Int32)
        case rejected
        case empty
    }

    static func listen(on port: UInt16) throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw Failure(operation: "socket", status: errno) }
        do {
            try nonblocking(descriptor)
            var reuse: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw Failure(operation: "prepare address reuse", status: errno)
            }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: UInt32(0x7F000001).bigEndian)
            address.sin_port = port.bigEndian
            let binding = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard binding == 0 else { throw Failure(operation: "bind 127.0.0.1", status: errno) }
            guard Darwin.listen(descriptor, 16) == 0 else { throw Failure(operation: "listen", status: errno) }
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let status = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
            }
            guard status == 0, address.sin_port != 0 else { throw Failure(operation: "read listen port", status: errno) }
            return (descriptor, UInt16(bigEndian: address.sin_port))
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func accept(from listener: Int32, admit: () -> Bool) throws -> Incoming {
        var address = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let descriptor = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listener, $0, &size) }
        }
        guard descriptor >= 0 else {
            let status = errno
            if status == EAGAIN || status == EWOULDBLOCK || status == EINTR { return .empty }
            if status == ECONNABORTED { return .rejected }
            throw Failure(operation: "accept", status: status)
        }
        guard address.sin_family == AF_INET, UInt32(bigEndian: address.sin_addr.s_addr) == 0x7F000001, admit() else {
            Darwin.close(descriptor)
            return .rejected
        }
        do {
            try nonblocking(descriptor)
            var suppressSignal: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &suppressSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw Failure(operation: "prepare peer", status: errno)
            }
            return .peer(descriptor)
        } catch {
            Darwin.close(descriptor)
            return .rejected
        }
    }

    private static func nonblocking(_ descriptor: Int32) throws {
        let status = fcntl(descriptor, F_GETFL)
        guard status >= 0, fcntl(descriptor, F_SETFL, status | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw Failure(operation: "configure socket", status: errno)
        }
    }
}
#endif
