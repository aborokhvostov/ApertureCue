#if os(macOS)
import Foundation
import MappingCore

/// The actual adapter worker receives an isolated in-memory byte sink. No test
/// enumerates or opens device nodes.
enum LightingAdapterSelfTest {
    private final class VirtualSink: LightingAdapterByteSink {
        private let lock = NSLock()
        private var output: [Data] = []
        private var closed = false
        let firstWrite = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let holdFirst: Bool
        let failLive: Bool

        init(holdFirst: Bool = false, failLive: Bool = false) {
            self.holdFirst = holdFirst
            self.failLive = failLive
        }
        var frames: [Data] { lock.withLock { output } }
        var didClose: Bool { lock.withLock { closed } }

        func write(_ data: Data) throws {
            let first = lock.withLock { output.isEmpty }
            if first {
                firstWrite.signal()
                if holdFirst, gate.wait(timeout: .now() + 2) == .timedOut {
                    throw SystemFailure(message: "virtual write gate timed out")
                }
            }
            if failLive && data != BufferedDMXPro.blackout { throw SystemFailure(message: "synthetic serial disconnect") }
            lock.withLock { output.append(data) }
        }
        func close() { lock.withLock { closed = true } }
    }

    static func run() -> Int32 {
        let start = ProcessInfo.processInfo.systemUptime
        let report = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("artifacts/local/lighting-adapter-test", isDirectory: true)
        var checks: [String] = []
        var failure: String?
        func pass(_ text: String) { checks.append(text); print("PASS lighting adapter: " + text) }
        do {
            var channels = [UInt8](repeating: 0, count: 512)
            channels[0] = 23
            channels[1] = 42
            channels[2] = 81
            let original = try BufferedDMXPro.encode(channels)
            let inspector = try BufferedDMXPro.inspect(original)
            guard original.count == 518, inspector == channels,
                  original.prefix(5).elementsEqual([0x7E, 6, 1, 2, 0]), original.last == 0xE7 else {
                throw SystemFailure(message: "buffered DMX frame differs from the independent header and payload oracle")
            }
            let rgb = try LightingAdapterRoute(universe: 12, encoding: .spiRGB(firstAddress: 1, pixels: 1))
            guard try rgb.packet(in: [12: channels]) == Data([23, 42, 81]), try rgb.packet(in: [11: channels]) == nil else {
                throw SystemFailure(message: "SPI preview differed from selected universe RGB slots")
            }
            guard ["", "/dev/null", "/dev/cu.", "/dev/cu.x/../tty", "/tmp/dev/cu.usbserial"].allSatisfy({ !LightingAdapterSerialSink.isDevicePath($0) }),
                  LightingAdapterSerialSink.isDevicePath("/dev/cu.usbserial-original-test") else {
                throw SystemFailure(message: "explicit serial path validation changed")
            }
            pass("buffered USB packet and SPI payload match native preview byte oracles; serial endpoint syntax is explicit")

            let held = VirtualSink(holdFirst: true)
            let output = LightingAdapterOutput()
            try output.start(initial: original) { held }
            guard held.firstWrite.wait(timeout: .now() + 2) == .success else { throw SystemFailure(message: "worker did not enter virtual sink") }
            var newest = original
            for value in 1...80 {
                channels[0] = UInt8(value)
                newest = try BufferedDMXPro.encode(channels)
                output.offer(newest)
            }
            held.gate.signal()
            try wait("latest frame") { held.frames.count >= 2 }
            guard held.frames == [original, newest] else { throw SystemFailure(message: "worker published queued stale frames instead of the latest") }
            pass("worker retained one latest frame through a blocked virtual write")

            try wait("stale source blackout", seconds: 2) { held.frames.last == BufferedDMXPro.blackout }
            output.offer(newest)
            try wait("fresh sample restored") { held.frames.last == newest }
            output.stop()
            try wait("virtual stop") { output.status == .stopped && held.didClose }
            guard held.frames.last == BufferedDMXPro.blackout else { throw SystemFailure(message: "Stop closed before the zero frame") }
            let finalCount = held.frames.count
            output.offer(original)
            Thread.sleep(forTimeInterval: 0.09)
            guard held.frames.count == finalCount else { throw SystemFailure(message: "late offer wrote to closed endpoint") }
            pass("stale input sends zero, fresh input recovers and Stop sends a last zero before close")

            let failed = VirtualSink(failLive: true)
            try output.start(initial: original) { failed }
            try wait("virtual failure") {
                if case .failed = output.status { return failed.didClose }
                return false
            }
            guard failed.frames == [BufferedDMXPro.blackout] else { throw SystemFailure(message: "write fault did not attempt zero before close") }
            pass("a simulated write failure closes the adapter without retrying live data")
        } catch {
            failure = error.localizedDescription
            fputs("FAIL lighting adapter: \(error.localizedDescription)\n", stderr)
        }
        var data: [String: Any] = [
            "schemaVersion": 1, "passed": failure == nil, "checkCount": checks.count, "checks": checks,
            "timestampUTC": ISO8601DateFormatter().string(from: Date()),
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Native adapter worker and injectable local virtual byte sink; buffered DMX-Pro output frame and SPI RGB payload",
            "virtualSink": true, "hardwareAccess": false, "hardwareVerification": false,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start
        ]
        if let failure { data["failure"] = failure }
        do {
            try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
                .write(to: report.appendingPathComponent("report.json"), options: .atomic)
        } catch { fputs("Lighting adapter report failed: \(error.localizedDescription)\n", stderr); return 1 }
        return failure == nil ? 0 : 1
    }

    private static func wait(_ description: String, seconds: Double = 1, until condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw SystemFailure(message: "timeout: \(description)")
    }
}
#endif
