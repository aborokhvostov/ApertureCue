#if os(macOS)
import Foundation
import Darwin
import MappingCore

protocol LightingAdapterByteSink: AnyObject {
    /// A sink owns its endpoint on the adapter worker and bounds the write time.
    func write(_ data: Data) throws
    func close()
}

/// Concrete, selected macOS virtual COM endpoint for a *buffered* USB adapter.
/// It does not bit-bang DMX, query the hardware, or change its firmware.
final class LightingAdapterSerialSink: LightingAdapterByteSink {
    private var descriptor: Int32
    private var original: termios
    private static let writeBudget = 0.12

    static func isDevicePath(_ path: String) -> Bool {
        let prefix = "/dev/cu."
        guard path.hasPrefix(prefix) else { return false }
        let suffix = path.dropFirst(prefix.count)
        return (1...127).contains(suffix.utf8.count) && suffix != "." && suffix != ".." && suffix.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }

    init(path: String) throws {
        guard Self.isDevicePath(path) else { throw SystemFailure(message: "Enter one concrete /dev/cu.* buffered USB adapter path") }
        let descriptor = Darwin.open(path, O_WRONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Self.failure("open", errno) }
        var previous = termios()
        do {
            var statValue = stat()
            guard fstat(descriptor, &statValue) == 0, mode_t(statValue.st_mode) & S_IFMT == S_IFCHR else {
                throw SystemFailure(message: "The selected serial path is not a character device")
            }
            // Device-level exclusivity avoids interleaving frames with another app.
            guard ioctl(descriptor, UInt(TIOCEXCL)) == 0 else { throw Self.failure("reserve the endpoint", errno) }
            guard tcgetattr(descriptor, &previous) == 0 else { throw Self.failure("read serial settings", errno) }
            var raw = previous
            cfmakeraw(&raw)
            raw.c_cflag &= ~tcflag_t(CSIZE | CSTOPB | PARENB | CCTS_OFLOW | CRTS_IFLOW)
            raw.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
            guard cfsetispeed(&raw, speed_t(B115200)) == 0, cfsetospeed(&raw, speed_t(B115200)) == 0,
                  tcsetattr(descriptor, TCSANOW, &raw) == 0 else { throw Self.failure("configure serial settings", errno) }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        self.descriptor = descriptor
        original = previous
    }

    deinit { close() }

    func write(_ data: Data) throws {
        guard descriptor >= 0, data.count == BufferedDMXPro.packetByteCount else {
            throw SystemFailure(message: "Buffered USB output is closed or the frame size is invalid")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + Self.writeBudget
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var index = 0
            while index < bytes.count {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw SystemFailure(message: "Buffered USB serial write timed out") }
                var pollEntry = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let result = Darwin.poll(&pollEntry, 1, Int32((remaining * 1000).rounded(.up)))
                if result < 0, errno == EINTR { continue }
                guard result >= 0 else { throw Self.failure("wait for serial write", errno) }
                guard result > 0 else { throw SystemFailure(message: "Buffered USB serial write timed out") }
                if pollEntry.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    throw SystemFailure(message: "Buffered USB serial endpoint disconnected")
                }
                let written = Darwin.write(descriptor, base.advanced(by: index), bytes.count - index)
                if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard written > 0 else { throw Self.failure("write buffered USB frame", errno) }
                index += written
            }
        }
    }

    func close() {
        guard descriptor >= 0 else { return }
        // Restoring host-side tty settings with TCSANOW avoids a draining wait.
        _ = tcsetattr(descriptor, TCSANOW, &original)
        Darwin.close(descriptor)
        descriptor = -1
    }

    private static func failure(_ operation: String, _ status: Int32) -> SystemFailure {
        SystemFailure(message: "Could not \(operation) on the selected serial adapter: \(String(cString: strerror(status)))")
    }
}
#endif
