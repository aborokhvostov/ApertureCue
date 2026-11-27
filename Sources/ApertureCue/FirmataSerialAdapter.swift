#if os(macOS)
import Darwin
import Foundation
import MappingCore

private final class FirmataSerialEndpoint {
    private let descriptor: Int32
    private let original: termios
    private static let bufferSize = 4096

    static func openSelected(path: String) throws -> FirmataSerialEndpoint {
        guard LightingAdapterSerialSink.isDevicePath(path) else {
            throw SystemFailure(message: "Enter the explicit /dev/cu.* path of the Firmata device.")
        }
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw failure("open the selected device", errno) }
        return try FirmataSerialEndpoint(owning: descriptor)
    }

    /// Also used with the owned slave descriptor of an original pseudo-terminal fixture.
    init(owning descriptor: Int32) throws {
        var previous = termios()
        do {
            var info = stat()
            let flags = fcntl(descriptor, F_GETFL)
            guard descriptor >= 0, flags >= 0, fstat(descriptor, &info) == 0,
                  mode_t(info.st_mode) & S_IFMT == S_IFCHR, tcgetattr(descriptor, &previous) == 0 else {
                throw SystemFailure(message: "The selected Firmata endpoint is not a character terminal.")
            }
            guard ioctl(descriptor, UInt(TIOCEXCL)) == 0 else { throw Self.failure("reserve the device", errno) }
            guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw Self.failure("configure serial I/O", errno) }
            var raw = previous
            cfmakeraw(&raw)
            raw.c_cflag &= ~tcflag_t(CSIZE | CSTOPB | PARENB | CCTS_OFLOW | CRTS_IFLOW)
            raw.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
            withUnsafeMutableBytes(of: &raw.c_cc) {
                $0[Int(VMIN)] = 1
                $0[Int(VTIME)] = 0
            }
            guard cfsetispeed(&raw, speed_t(B57600)) == 0, cfsetospeed(&raw, speed_t(B57600)) == 0,
                  tcsetattr(descriptor, TCSANOW, &raw) == 0 else { throw Self.failure("set 57600 8N1", errno) }
        } catch {
            if descriptor >= 0 { Darwin.close(descriptor) }
            throw error
        }
        self.descriptor = descriptor
        original = previous
    }

    deinit {
        var previous = original
        _ = tcsetattr(descriptor, TCSANOW, &previous)
        Darwin.close(descriptor)
    }

    func readAvailable() throws -> Data {
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&entry, 1, 0)
        if ready < 0, errno == EINTR { return Data() }
        guard ready >= 0 else { throw Self.failure("poll serial input", errno) }
        guard ready > 0 else { return Data() }
        try checkConnection(entry)
        guard entry.revents & Int16(POLLIN) != 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: Self.bufferSize)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return Data() }
        guard count >= 0 else { throw Self.failure("read serial input", errno) }
        guard count > 0 else { throw SystemFailure(message: "The Firmata serial device disconnected.") }
        return Data(bytes.prefix(count))
    }

    func write(_ bytes: Data) throws {
        guard !bytes.isEmpty else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw SystemFailure(message: "The Firmata serial write timed out.") }
                var entry = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let result = Darwin.poll(&entry, 1, Int32((remaining * 1000).rounded(.up)))
                if result < 0, errno == EINTR { continue }
                guard result >= 0 else { throw Self.failure("poll serial output", errno) }
                guard result > 0 else { throw SystemFailure(message: "The Firmata serial write timed out.") }
                try checkConnection(entry)
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard written > 0 else { throw Self.failure("write serial output", errno) }
                offset += written
            }
        }
    }

    private func checkConnection(_ entry: pollfd) throws {
        guard entry.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
            throw SystemFailure(message: "The Firmata serial device disconnected.")
        }
    }

    private static func failure(_ operation: String, _ status: Int32) -> SystemFailure {
        SystemFailure(message: "Could not \(operation). \(String(cString: strerror(status)))")
    }
}

struct FirmataAdapterSnapshot: Equatable, Sendable {
    var phase = FirmataPhase.disconnected
    var input: FirmataInput?
    var ticket: UUID?
    var sample: FirmataSample?
    var output = FirmataOutputState.idle
    var error: String?
}

/// Serial and protocol state stay on one worker. The main-thread mailbox keeps the latest sample.
final class FirmataSerialAdapter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.aperturecue.firmata", qos: .userInitiated)
    private let observer: @MainActor @Sendable (FirmataAdapterSnapshot) -> Void
    private let mailboxLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var endpoint: FirmataSerialEndpoint?
    private var machine = FirmataSession()
    private var inputTicket: UUID?
    private var failure: String?
    private var published = FirmataAdapterSnapshot()
    private var queuedUpdate: FirmataAdapterSnapshot?
    private var updateScheduled = false

    init(observer: @escaping @MainActor @Sendable (FirmataAdapterSnapshot) -> Void) {
        self.observer = observer
    }

    deinit { timer?.cancel() }

    func connect(path: String) {
        queue.async { [self] in install { try FirmataSerialEndpoint.openSelected(path: path) } }
    }

    func connectVirtual(owning descriptor: Int32) {
        queue.async { [self] in install { try FirmataSerialEndpoint(owning: descriptor) } }
    }

    func disconnect() {
        queue.async { [self] in
            if machine.input != nil, let bytes = try? machine.configureInput(nil) { try? endpoint?.write(bytes) }
            close()
            publish()
        }
    }

    func configureInput(_ input: FirmataInput?, ticket: UUID?) {
        queue.async { [self] in
            do {
                let bytes = try machine.configureInput(input)
                inputTicket = ticket
                writeCommand(bytes)
            } catch { reportActionError(error) }
        }
    }

    func writeDigital(pin: Int, high: Bool) {
        queue.async { [self] in
            do {
                // Consume a queued reboot before considering any new output command.
                pump()
                let bytes = try machine.writeDigital(pin: pin, high: high, at: Self.now)
                writeCommand(bytes)
            } catch { reportActionError(error) }
        }
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    private func install(_ open: () throws -> FirmataSerialEndpoint) {
        close()
        do {
            let serial = try open()
            try serial.write(machine.connect(at: Self.now))
            endpoint = serial
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(4))
            timer.setEventHandler { [weak self] in self?.pump() }
            self.timer = timer
            timer.resume()
        } catch { close(error.localizedDescription) }
        publish()
    }

    private func pump() {
        guard let endpoint else { return }
        do {
            let now = Self.now
            let incoming = try endpoint.readAvailable()
            try endpoint.write(machine.receive(incoming, at: now))
            try endpoint.write(machine.tick(at: now))
            if machine.input == nil { inputTicket = nil }
            if case .failed = machine.phase {
                timer?.cancel()
                timer = nil
                self.endpoint = nil
            }
        } catch { close(error.localizedDescription) }
        publish()
    }

    private func writeCommand(_ bytes: Data) {
        do {
            try endpoint?.write(bytes)
            failure = nil
        } catch { close(error.localizedDescription) }
        publish()
    }

    private func close(_ failure: String? = nil) {
        timer?.cancel()
        timer = nil
        endpoint = nil
        machine.disconnect()
        inputTicket = nil
        self.failure = failure
    }

    private func reportActionError(_ error: Error) {
        if endpoint != nil || failure == nil { failure = error.localizedDescription }
        publish(force: true)
    }

    private func publish(force: Bool = false) {
        let snapshot = FirmataAdapterSnapshot(phase: machine.phase, input: machine.input, ticket: inputTicket,
                                               sample: machine.latestSample, output: machine.output, error: failure)
        guard force || snapshot != published else { return }
        published = snapshot
        mailboxLock.lock()
        queuedUpdate = snapshot
        let schedule = !updateScheduled
        updateScheduled = true
        mailboxLock.unlock()
        if schedule {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.mailboxLock.lock()
                let latest = self.queuedUpdate
                self.queuedUpdate = nil
                self.updateScheduled = false
                self.mailboxLock.unlock()
                if let latest { self.observer(latest) }
            }
        }
    }
}
#endif
