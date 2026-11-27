#if os(macOS)
import Foundation
import MappingCore

/// The optional process communicates only over its inherited stdout pipe.
/// One bounded JSON line is parsed at a time, with one latest result to poll.
private final class AbletonLinkReader: @unchecked Sendable {
    private let lock = NSLock()
    private let decoder = JSONDecoder()
    private var line = Data()
    private var latest: AbletonLinkObservation?
    private var failure: String?
    private var finished = false

    func read(from handle: FileHandle) {
        lock.withLock {
            guard !finished else { return }
            do {
                guard let data = try handle.read(upToCount: 4096), !data.isEmpty else {
                    finished = true
                    return
                }
                for byte in data {
                    if byte == 0x0A {
                        let decoded = try decoder.decode(AbletonLinkObservation.self, from: line)
                        guard decoded.isValid else { throw SystemFailure(message: "Invalid Link observation") }
                        latest = decoded
                        line.removeAll(keepingCapacity: true)
                    } else {
                        guard line.count < 512 else { throw SystemFailure(message: "Link observation exceeds 512 bytes") }
                        line.append(byte)
                    }
                }
            } catch {
                failure = "Invalid Ableton Link bridge output"
                finished = true
            }
        }
    }

    var state: (observation: AbletonLinkObservation?, failure: String?, finished: Bool) {
        lock.withLock { (latest, failure, finished) }
    }
}

@MainActor final class AbletonLinkBridge {
    private let process = Process()
    private let output = Pipe()
    private let reader = AbletonLinkReader()
    let name: String

    init(executable: URL, testFixture: Bool) throws {
        guard executable.isFileURL, executable.lastPathComponent == "aperturecue-link",
              FileManager.default.isExecutableFile(atPath: executable.path),
              try executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw SystemFailure(message: "Choose a built aperturecue-link executable")
        }
        name = executable.lastPathComponent
        process.executableURL = executable
        process.arguments = [testFixture ? "--test-loopback" : "--connect"]
        if testFixture {
            var environment = ProcessInfo.processInfo.environment
            environment["APERTURECUE_LINK_DIAGNOSTIC"] = "loopback-only"
            process.environment = environment
        }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [reader] handle in reader.read(from: handle) }
        do { try process.run() }
        catch {
            output.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
            throw error
        }
    }

    var state: (observation: AbletonLinkObservation?, failure: String?) {
        let state = reader.state
        if let failure = state.failure { return (nil, failure) }
        if !process.isRunning || state.finished { return (nil, "Ableton Link bridge disconnected") }
        return (state.observation, nil)
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        if process.isRunning { process.terminate() }
    }

    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        if process.isRunning { process.terminate() }
    }

    nonisolated static var now: UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }
}
#endif
