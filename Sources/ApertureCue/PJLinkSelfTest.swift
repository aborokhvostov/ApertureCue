#if os(macOS)
import Darwin
import Foundation
import MappingCore

private struct PJLinkFixtureFailure: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

/// Independent scripted TCP peer. It checks literal bytes and knows no client codec.
private final class PJLinkFixture: @unchecked Sendable {
    enum Step: Sendable {
        case send([String])
        case expect(String)
        case idle(Double)
        case clientClosed
    }

    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var failure: String?
    let port: UInt16

    init(_ steps: [Step]) throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PJLinkFixtureFailure(detail: "Cannot create loopback TCP simulator") }
        var started = false
        defer { if !started { Darwin.close(fd) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            throw PJLinkFixtureFailure(detail: "Cannot listen on loopback simulator")
        }
        var outputLength = length
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &outputLength) }
        }
        guard named == 0 else { throw PJLinkFixtureFailure(detail: "Cannot read simulator port") }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue(label: "org.aperturecue.test.pjlink").async { [self] in
            defer {
                Darwin.close(fd)
                completion.signal()
            }
            do { try Self.execute(steps, listener: fd) }
            catch {
                lock.lock()
                failure = error.localizedDescription
                lock.unlock()
            }
        }
        started = true
    }

    func finish() throws {
        guard completion.wait(timeout: .now() + 5) == .success else {
            throw PJLinkFixtureFailure(detail: "Projector simulator did not finish")
        }
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw PJLinkFixtureFailure(detail: failure) }
    }

    private static func execute(_ steps: [Step], listener: Int32) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        try readable(listener, before: deadline)
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { throw PJLinkFixtureFailure(detail: "Projector simulator could not accept client") }
        defer { Darwin.close(client) }
        var noSIGPIPE: Int32 = 1
        guard fcntl(client, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw PJLinkFixtureFailure(detail: "Projector simulator could not configure socket")
        }
        var noDelay: Int32 = 1
        _ = setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        for step in steps {
            switch step {
            case .send(let fragments):
                for fragment in fragments {
                    let bytes = Array(fragment.utf8)
                    let wrote = bytes.withUnsafeBufferPointer { send(client, $0.baseAddress, $0.count, 0) }
                    guard wrote == bytes.count else { throw PJLinkFixtureFailure(detail: "Projector simulator short write") }
                    Thread.sleep(forTimeInterval: 0.004)
                }
            case .expect(let line):
                let expected = Array(line.utf8)
                var incoming: [UInt8] = []
                while incoming.count < 256 {
                    try readable(client, before: deadline)
                    var byte: UInt8 = 0
                    let result = recv(client, &byte, 1, 0)
                    if result < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    guard result == 1 else { throw PJLinkFixtureFailure(detail: "Projector simulator expected a complete command") }
                    incoming.append(byte)
                    if byte == 13 { break }
                }
                guard incoming == expected else { throw PJLinkFixtureFailure(detail: "Projector simulator received a different command") }
            case .idle(let seconds):
                Thread.sleep(forTimeInterval: seconds)
            case .clientClosed:
                try readable(client, before: deadline)
                var byte: UInt8 = 0
                guard recv(client, &byte, 1, 0) == 0 else {
                    throw PJLinkFixtureFailure(detail: "Client sent an extra command or did not close the transaction")
                }
            }
        }
    }

    private static func readable(_ fd: Int32, before deadline: Double) throws {
        while true {
            let time = deadline - ProcessInfo.processInfo.systemUptime
            guard time > 0 else { throw PJLinkFixtureFailure(detail: "Projector simulator timed out") }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let status = poll(&descriptor, 1, Int32(min(80, ceil(time * 1_000))))
            if status > 0 { return }
            if status < 0, errno != EINTR { throw PJLinkFixtureFailure(detail: "Projector simulator poll failed") }
        }
    }
}

@MainActor enum PJLinkSelfTest {
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw PJLinkFixtureFailure(detail: message) }
    }

    private static func converse(
        _ steps: [PJLinkFixture.Step], _ mode: PJLinkAuthentication,
        credential: String = "", commands: [PJLinkCommand],
        cancellation: PJLinkCancellation = .init(), timeout: Double = 2.5,
        nonce: () -> [UInt8] = NativePJLinkClient.randomNonce
    ) throws -> Result<[PJLinkReply], Error> {
        let fixture = try PJLinkFixture(steps)
        let result = Result {
            try NativePJLinkClient.run(host: "127.0.0.1", port: fixture.port,
                                       authentication: mode, password: credential,
                                       commands: commands, cancellation: cancellation,
                                       seconds: timeout, nonce: nonce)
        }
        try fixture.finish()
        return result
    }

    private static func error(_ result: Result<[PJLinkReply], Error>) -> PJLinkProtocolError? {
        if case .failure(let error) = result { return error as? PJLinkProtocolError }
        return nil
    }

    static func run() -> Int32 {
        let started = ProcessInfo.processInfo.systemUptime
        var checks: [String] = []
        func passed(_ title: String) { checks.append(title); print("PASS PJLink: " + title) }
        func report(_ success: Bool, failure: String? = nil) {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("artifacts/local/pjlink", isDirectory: true)
            var data: [String: Any] = [
                "schemaVersion": 1, "passed": success, "checks": checks, "checkCount": checks.count,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "timestampUTC": ISO8601DateFormatter().string(from: Date()), "hardwareVerification": false,
                "scope": "Production PJLink client with independent original fragmented localhost TCP simulator"
            ]
            if let failure { data["error"] = failure }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .prettyPrinted]) {
                try? json.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
            }
        }

        do {
            let result = try converse([
                .send(["PJ", "LINK", " 0", "\r"]),
                .expect("%1POWR ?\r"), .send(["%1PO", "WR=3", "\r"]),
                .expect("%1AVMT ?\r"), .send(["%1AVMT=ERR3", "\r"]),
                .expect("%1ERST ?\r"), .send(["%1ERST=012", "100\r"]),
                .expect("%1CLSS ?\r"), .send(["%1CLSS=2\r"]), .clientClosed
            ], .unprotected, commands: PJLinkClient.statusCommands).get()
            try expect(result == [.power(.warming), .rejected(.unavailable),
                                  .faults(.init(fan: .clearOrUnsupported, lamp: .warning, temperature: .fault,
                                                cover: .warning, filter: .clearOrUnsupported, other: .clearOrUnsupported)),
                                  .deviceClass(2)], "Typed fragmented status did not match original simulator")
            passed("Fragmented TCP greeting and replies preserve warming, unavailable mute and diagnostics")

            let simulatedCredential = "ACFakeProjector42"
            let controller: [UInt8] = [0xfa, 0x00, 0x99, 0x88, 0x77, 0x66, 0x55, 0x44,
                                      0x33, 0x22, 0x11, 0xef, 0xdd, 0xcc, 0xbb, 0x77]
            // Golden digest generated independently with hashlib on original challenge bytes.
            let modernHeader = "fa00998877665544332211efddccbb77" + "dc35ae9fb3be96a004748a5c1c362dd6cf2f34464562faf7a9779a96925935e9"
            let modern = try converse([
                .send(["PJLINK 1 4d39e2aa\r"]), .expect("PJLINK 2\r"),
                .send(["PJLINK 2 1032547698badcfe", "0123456789abcdef\r"]),
                .expect(modernHeader + "%1POWR 0\r"), .send(["%1POWR=OK\r"]), .clientClosed
            ], .sha256, credential: simulatedCredential, commands: [.setPower(false)], nonce: { controller }).get()
            try expect(modern == [.acknowledged], "SHA-256 simulator power acknowledgement differs")
            passed("SHA-256 upgrade and password digest match independent golden bytes")

            let legacy = try converse([
                .send(["PJLINK 1 4d39e2", "aa\r"]),
                .expect("c85e232b17bf0ff565402cd3622f6b6d%1AVMT 31\r"),
                .send(["%1AVMT=OK\r"]), .clientClosed
            ], .legacyMD5, credential: simulatedCredential, commands: [.setMute(true)]).get()
            try expect(legacy == [.acknowledged], "Legacy simulator mute acknowledgement differs")
            passed("Explicit legacy mode emits the independent MD5 and mute bytes")

            let downgrade = try converse([
                .send(["PJLINK 1 4d39e2aa\r"]), .expect("PJLINK 2\r"),
                .send(["PJLINK ERR1\r"]), .clientClosed
            ], .sha256, credential: simulatedCredential, commands: [.setPower(true)])
            try expect(error(downgrade) == .authenticationMismatch, "Required modern mode accepted a downgrade")
            let rejected = try converse([
                .send(["PJLINK 1 4d39e2aa\r"]),
                .expect("c85e232b17bf0ff565402cd3622f6b6d%1POWR ?\r"),
                .send(["PJLINK ERRA\r"]), .clientClosed
            ], .legacyMD5, credential: simulatedCredential, commands: [.powerStatus])
            try expect(error(rejected) == .authenticationRejected, "Authentication rejection was lost")
            passed("Unsupported upgrade and ERRA close without retrying or sending a downgraded write")

            let closed = try converse([.send(["PJLINK 0\r"]), .expect("%1POWR ?\r"), .send(["%1POWR="])],
                                      .unprotected, commands: [.powerStatus])
            try expect(error(closed) == .disconnected, "Truncated response was treated as a complete reply")
            let noReply = try converse([
                .send(["PJLINK 0\r"]), .expect("%1POWR ?\r"), .idle(0.45), .clientClosed
            ], .unprotected, commands: [.powerStatus], timeout: 0.30)
            try expect(error(noReply) == .timedOut, "Missing reply did not time out")
            let token = PJLinkCancellation()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.20) { token.cancel() }
            let cancelled = try converse([.idle(0.4), .clientClosed], .unprotected,
                                         commands: [.powerStatus], cancellation: token)
            try expect(error(cancelled) == .cancelled, "Cancel did not retire the socket waiting for a greeting")
            passed("Peer close, monotonic deadline and user cancellation release the TCP exchange")
            report(true)
            return 0
        } catch {
            report(false, failure: error.localizedDescription)
            fputs("FAIL PJLink: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
#endif
