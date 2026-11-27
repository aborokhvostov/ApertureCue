#if os(macOS)
import Darwin
import Foundation
import MappingCore

/// Foundation's length-based read can wait for the requested count on a pipe.
/// A readiness notification should consume one bounded chunk without waiting.
enum AbletonLinkPipe {
    static func configure(_ handle: FileHandle) throws {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw SystemFailure(message: "Could not configure the Link observation pipe")
        }
    }

    static func read(_ handle: FileHandle, into buffer: inout [UInt8]) throws -> Int? {
        let descriptor = handle.fileDescriptor
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count >= 0 { return count }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
        throw SystemFailure(message: "Could not read the Link observation pipe")
    }
}

/// The optional process communicates only over its inherited stdout pipe.
/// One bounded JSON line is parsed at a time, with one latest result to poll.
private final class AbletonLinkReader: @unchecked Sendable {
    private let lock = NSLock()
    private let decoder = JSONDecoder()
    private var buffer = [UInt8](repeating: 0, count: 4096)
    private var line = Data()
    private var latest: AbletonLinkObservation?
    private var failure: String?
    private var finished = false
    private var closed = false

    func read(from handle: FileHandle) {
        lock.withLock {
            guard !finished else { return }
            do {
                guard let count = try AbletonLinkPipe.read(handle, into: &buffer) else { return }
                guard count > 0 else { finished = true; return }
                for byte in buffer.prefix(count) {
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

    func close(_ handle: FileHandle) {
        handle.readabilityHandler = nil
        lock.withLock {
            guard !closed else { return }
            finished = true
            closed = true
            try? handle.close()
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
        let handle = output.fileHandleForReading
        try AbletonLinkPipe.configure(handle)
        handle.readabilityHandler = { [reader] handle in reader.read(from: handle) }
        do { try process.run() }
        catch {
            reader.close(handle)
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
        reader.close(output.fileHandleForReading)
        if process.isRunning { process.terminate() }
    }

    deinit {
        reader.close(output.fileHandleForReading)
        if process.isRunning { process.terminate() }
    }

    nonisolated static var now: UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }
}
#endif
