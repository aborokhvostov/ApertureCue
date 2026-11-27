#if os(macOS)
import Foundation
import MappingCore

/// Owns one selected byte sink on a serial worker. Frame offers replace a
/// single mailbox value. A generation invalidates all queued output on Stop.
final class LightingAdapterOutput {
    enum Status: Equatable {
        case stopped, opening, active, stopping, failed(String)
    }

    private struct Request {
        var generation: UInt64 = 0
        var status: Status = .stopped
        var pending: Data?
        var lastOffer: Double = 0
        var sentCount = 0
    }

    private let queue = DispatchQueue(label: "org.aperturecue.usb-dmx", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private var request = Request()
    private var sink: LightingAdapterByteSink?
    private var timer: DispatchSourceTimer?
    private var lastWritten: Data?
    static let sourceTimeout = 1.0

    init() { queue.setSpecific(key: queueKey, value: 1) }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == 1 { closeWire(blackout: true) }
        else { queue.sync { _ = closeWire(blackout: true) } }
    }

    var status: Status { lock.withLock { request.status } }
    var sentCount: Int { lock.withLock { request.sentCount } }

    func start(initial: Data, factory: @escaping () throws -> LightingAdapterByteSink) throws {
        _ = try BufferedDMXPro.inspect(initial)
        let generation = try lock.withLock { () throws -> UInt64 in
            switch request.status {
            case .stopped, .failed: break
            default: throw SystemFailure(message: "Stop the current USB output before selecting another endpoint")
            }
            request.generation &+= 1
            request.status = .opening
            request.pending = initial
            request.lastOffer = ProcessInfo.processInfo.systemUptime
            request.sentCount = 0
            return request.generation
        }
        queue.async { [weak self] in self?.open(factory: factory, generation: generation) }
    }

    /// Exposed for the sampled universe callback and virtual fixtures.
    func offer(_ frame: Data) {
        guard (try? BufferedDMXPro.inspect(frame)) != nil else { return }
        lock.withLock {
            guard request.status == .active || request.status == .opening else { return }
            request.pending = frame
            request.lastOffer = ProcessInfo.processInfo.systemUptime
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        let generation = lock.withLock { () -> UInt64? in
            if request.status == .stopped || (request.status == .stopping && completion == nil) { return nil }
            if request.status != .stopping {
                request.generation &+= 1
                request.pending = nil
                request.status = .stopping
            }
            return request.generation
        }
        guard let generation else { completion?(); return }
        queue.async { [weak self] in
            if let self, self.isCurrent(generation), self.status == .stopping {
                let failure = self.closeWire(blackout: true)
                self.setStatus(failure.map(Status.failed) ?? .stopped, generation: generation)
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool { lock.withLock { request.generation == generation } }

    private func setStatus(_ status: Status, generation: UInt64) {
        lock.withLock {
            guard request.generation == generation else { return }
            request.status = status
            if status != .active { request.pending = nil }
        }
    }

    private func open(factory: () throws -> LightingAdapterByteSink, generation: UInt64) {
        guard isCurrent(generation) else { return }
        do {
            let next = try factory()
            guard isCurrent(generation) else { next.close(); return }
            sink = next
            lastWritten = nil
            setStatus(.active, generation: generation)
            let clock = DispatchSource.makeTimerSource(queue: queue)
            clock.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(2))
            clock.setEventHandler { [weak self] in self?.flush(generation: generation) }
            timer = clock
            clock.resume()
        } catch {
            setStatus(.failed(error.localizedDescription), generation: generation)
        }
    }

    private func flush(generation: UInt64) {
        guard let sink else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let frame = lock.withLock { () -> Data? in
            guard request.generation == generation, request.status == .active else { return nil }
            let latest = request.pending
            request.pending = nil
            return now - request.lastOffer > Self.sourceTimeout ? BufferedDMXPro.blackout : latest
        }
        guard let frame, frame != lastWritten, isCurrent(generation) else { return }
        do {
            try sink.write(frame)
            lastWritten = frame
            lock.withLock { if request.generation == generation { request.sentCount += 1 } }
        } catch {
            _ = closeWire(blackout: true)
            setStatus(.failed(error.localizedDescription), generation: generation)
        }
    }

    @discardableResult private func closeWire(blackout: Bool) -> String? {
        timer?.cancel()
        timer = nil
        var failure: String?
        if let sink {
            if blackout {
                do { try sink.write(BufferedDMXPro.blackout) }
                catch { failure = "USB output closed. Blackout could not be sent: \(error.localizedDescription)" }
            }
            sink.close()
        }
        sink = nil
        lastWritten = nil
        return failure
    }
}
#endif
