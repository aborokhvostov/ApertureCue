#if os(macOS)
import Foundation
import Darwin
import dnssd
import MappingCore

/// The production server is driven by an independent process through the system
/// HTTP/WebSocket client, with separate DNS-SD browse and resolve calls.
enum OSCQuerySelfTest {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let fixturePrefix = "aperturecue-osc-query-test-"
    private static let gainPath = "/show/gain"
    private static let statePath = "/show/muted"
    private static let newStatePath = "/show/changed"

    static func run() -> Int32 {
        let manager = FileManager.default
        let now = ProcessInfo.processInfo.systemUptime
        let reportRoot = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("artifacts/local/osc-query-test", isDirectory: true)
        let fixture = manager.temporaryDirectory.appendingPathComponent(fixturePrefix + UUID().uuidString, isDirectory: true)
        let server = OSCQueryServer()
        var checks: [String] = []
        var failure: String?
        var process: Process?
        defer {
            if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
            server.stop()
            try? manager.removeItem(at: fixture)
        }
        func passed(_ text: String) { checks.append(text); print("PASS OSC Query: " + text) }

        do {
            try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
            try frameAndHandshakeChecks()
            passed("HTTP upgrade key, segmented masked frames, accepted close payloads and bounded receive corpus")

            try server.publish(nodes(gain: 0.25, muted: false))
            try server.start(port: 0, oscPort: 5678, advertiseLocally: true)
            let port = try wait("listener ready") {
                if case .ready(let port) = server.status { return port }
                if case .failed(let reason) = server.status { throw Failure(message: reason) }
                return nil
            }
            let name = try wait("local discovery registration") {
                if case .ready(let name) = server.discoveryStatus { return name }
                if case .failed(let reason) = server.discoveryStatus { throw Failure(message: reason) }
                return nil
            }
            let conflictingServer = OSCQueryServer()
            do {
                try conflictingServer.start(port: port)
                throw Failure(message: "two OSC Query listeners shared one port")
            } catch let error as OSCQuerySocket.Failure {
                try expect(error.status == EADDRINUSE, "second listener failed for an unexpected reason")
            }
            try Data(String(port).utf8).write(to: fixture.appendingPathComponent("server-port"), options: .atomic)

            let child = Process()
            child.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            child.arguments = ["--osc-query-client-test", String(port), fixture.path, name]
            process = child
            try child.run()
            try waitForFile("listening", in: fixture, child: child)
            passed("separate process discovered the LocalOnly service and read host info, namespace, values, ranges and status codes")
            try server.publish(nodes(gain: 0.75, muted: false))
            try waitForFile("ignored", in: fixture, child: child)
            try server.publish(nodes(gain: 0.5, muted: true))
            try waitForFile("structure", in: fixture, child: child)
            passed("independent WebSocket received live OSC values and IGNORE suppressed the unsubscribed update")
            try server.publish(nodes(gain: 0.5, muted: true, rename: true))
            try waitForFile("finished", in: fixture, child: child)
            child.waitUntilExit()
            try expect(child.terminationStatus == 0, "independent OSC Query client failed")
            passed("PATH_CHANGED invalidated the old tree and reconnect delivered the current value to a new subscription")

            var invalid = nodes(gain: 0.5, muted: true, rename: true)
            invalid.append(invalid[0])
            do { try server.publish(invalid); throw Failure(message: "invalid duplicate publication succeeded") }
            catch is ProtocolError { }
            let client = HTTPClient(port: port)
            try expect(client.get(gainPath + "?VALUE").value["VALUE"] as? [Double] == [0.5], "a failed publish changed the active tree")
            try httpLimitsChecks(port: port, server: server)
            passed("snapshot replacement is atomic and the listener enforces read-only limits and exact host/origin on loopback")

            server.stop()
            try expect(server.status == .stopped && server.connectionCount == 0 && server.discoveryStatus == .off,
                       "stop did not clear the listener, subscriptions or discovery registration")
            try server.start(port: port, oscPort: 5678)
            _ = try wait("listener restarted") {
                if case .ready(let next) = server.status, next == port { return true }
                if case .failed(let reason) = server.status { throw Failure(message: reason) }
                return nil
            }
            try expect(client.get(gainPath + "?VALUE").value["VALUE"] as? [Double] == [0.5], "restart did not serve the current tree")
            passed("stop removed listener and discovery and restart reopened the same loopback port")
        } catch {
            failure = error.localizedDescription
            fputs("FAIL OSC Query: \(error.localizedDescription)\n", stderr)
        }

        var report: [String: Any] = [
            "schemaVersion": 1,
            "timestampUTC": ISO8601DateFormatter().string(from: Date()),
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Production IPv4-loopback TCP, separate Foundation HTTP/WebSocket client and LocalOnly DNS-SD browse/resolve, synthetic parameter tree",
            "passed": failure == nil,
            "checkCount": checks.count,
            "checks": checks,
            "loopbackOnly": true,
            "independentClientProcess": true,
            "hardwareVerification": false,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - now
        ]
        if let failure { report["failure"] = failure }
        do {
            try manager.createDirectory(at: reportRoot, withIntermediateDirectories: true)
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: reportRoot.appendingPathComponent("report.json"), options: .atomic)
        } catch {
            fputs("OSC Query test report failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
        return failure == nil ? 0 : 1
    }

    static func runClient(arguments: [String]) -> Int32 {
        do {
            guard let flag = arguments.firstIndex(of: "--osc-query-client-test"), arguments.count == flag + 4,
                  let port = UInt16(arguments[flag + 1]), port != 0 else { throw Failure(message: "invalid fixture arguments") }
            let directory = URL(fileURLWithPath: arguments[flag + 2], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
            guard directory.lastPathComponent.hasPrefix(fixturePrefix),
                  directory.deletingLastPathComponent().path == temporaryRoot.path,
                  let token = try? String(contentsOf: directory.appendingPathComponent("server-port"), encoding: .utf8),
                  token == String(port) else { throw Failure(message: "expected an original active OSC Query fixture") }
            let name = arguments[flag + 3]
            let discovered = try verifyDiscovery(name: name, port: port)
            try expect(HTTPClient(port: port, host: discovered).get("/?HOST_INFO").status == 200,
                       "resolved DNS-SD hostname did not serve HTTP")
            let http = HTTPClient(port: port)
            let host = try http.get("/ignored-path?HOST_INFO").value
            try expect(host["OSC_PORT"] as? Int == 5678 && host["WS_PORT"] as? Int == Int(port), "HOST_INFO endpoint mismatch")
            try expect((host["EXTENSIONS"] as? [String: Bool])?["LISTEN"] == true, "LISTEN extension is missing")
            let root = try http.get("/").value
            let contents = try required(root["CONTENTS"] as? [String: Any], "root contents missing")
            let show = try required(contents["show"] as? [String: Any], "show container missing")
            let methods = try required(show["CONTENTS"] as? [String: Any], "method container missing")
            let gain = try required(methods["gain"] as? [String: Any], "gain method missing")
            try expect(gain["TYPE"] as? String == "f" && gain["ACCESS"] as? Int == 3, "gain type/access mismatch")
            try expect(http.get(gainPath + "?VALUE").value["VALUE"] as? [Double] == [0.25], "HTTP value mismatch")
            try expect(http.get("/show/%67ain?RANGE").value["RANGE"] as? [[String: Double]] == [["MIN": 0, "MAX": 1]], "HTTP range mismatch")
            try expect(http.get("/show/go?VALUE").status == 204, "write-only value must return 204")
            try expect(http.get("/show/unknown").status == 404, "missing method must return 404")
            try expect(http.get(gainPath + "?UNKNOWN_ATTRIBUTE").status == 204, "unknown extension must return 204")
            let socket = WebSocketClient(port: port)
            try socket.command("LISTEN", path: gainPath)
            try expect(socket.receiveBinary() == golden(path: gainPath, type: "f", bytes: [0x3E, 0x80, 0, 0]), "initial subscription OSC packet mismatch")
            try mark("listening", in: directory)
            try expect(socket.receiveBinary() == golden(path: gainPath, type: "f", bytes: [0x3F, 0x40, 0, 0]), "updated subscription OSC packet mismatch")
            try socket.command("LISTEN", path: statePath)
            try expect(socket.receiveBinary() == golden(path: statePath, type: "i", bytes: [0, 0, 0, 0]), "second subscription packet mismatch")
            try socket.command("IGNORE", path: gainPath)
            try socket.ping()
            try mark("ignored", in: directory)
            try expect(socket.receiveBinary() == golden(path: statePath, type: "i", bytes: [0, 0, 0, 1]), "IGNORE forwarded the wrong packet")
            try mark("structure", in: directory)
            let change = try socket.receiveText()
            let message = try JSONSerialization.jsonObject(with: Data(change.utf8)) as? [String: String]
            try expect(message == ["COMMAND": "PATH_CHANGED", "DATA": "/"], "namespace invalidation mismatch")
            try expect(http.get(statePath).status == 404 && http.get(newStatePath).value["VALUE"] as? [Int] == [1], "renamed path did not refresh over HTTP")
            socket.close()
            let reconnect = WebSocketClient(port: port)
            try reconnect.command("LISTEN", path: gainPath)
            try expect(reconnect.receiveBinary() == golden(path: gainPath, type: "f", bytes: [0x3F, 0, 0, 0]), "reconnected subscriber did not receive current value")
            reconnect.close()
            try mark("finished", in: directory)
            return 0
        } catch {
            fputs("FAIL independent OSC Query client: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func nodes(gain: Float, muted: Bool, rename: Bool = false) -> [OSCQueryNode] {
        [OSCQueryNode(path: gainPath, description: "Gain", access: .readWrite, type: "f", value: [.float(gain)], range: [.init(min: 0, max: 1)]),
         OSCQueryNode(path: rename ? newStatePath : statePath, description: "Muted", type: "i", value: [.int(muted ? 1 : 0)]),
         OSCQueryNode(path: "/show/go", description: "Start scene", access: .writeOnly, type: "i")]
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
        if try !condition() { throw Failure(message: description) }
    }

    private static func required<T>(_ value: T?, _ description: String) throws -> T {
        guard let value else { throw Failure(message: description) }
        return value
    }

    private static func wait<T>(_ description: String, seconds: Double = 8, _ result: () throws -> T?) throws -> T {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if let value = try result() { return value }
            Thread.sleep(forTimeInterval: 0.015)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Failure(message: "timeout: \(description)")
    }

    private static func mark(_ name: String, in directory: URL) throws {
        try Data([1]).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static func waitForFile(_ name: String, in directory: URL, child: Process) throws {
        _ = try wait("independent client \(name)", seconds: 12) { () throws -> Bool? in
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) { return true }
            if !child.isRunning { throw Failure(message: "independent client exited before \(name)") }
            return nil
        }
    }

    private static func golden(path: String, type: String, bytes: [UInt8]) -> Data {
        var raw = Array(path.utf8)
        raw += Array(repeating: UInt8(0), count: 4 - raw.count % 4)
        raw += [44, type.utf8.first ?? 0, 0, 0]
        return Data(raw + bytes)
    }

    private final class Reply<Value> {
        private let signal = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Result<Value, Error>?
        func complete(_ result: Result<Value, Error>) {
            lock.withLock { self.result = result }
            signal.signal()
        }
        func receive() throws -> Value {
            guard signal.wait(timeout: .now() + 4) == .success, let result = lock.withLock({ result }) else {
                throw Failure(message: "independent client reply timed out")
            }
            return try result.get()
        }
    }

    private final class HTTPClient {
        let port: UInt16
        let host: String
        let session: URLSession
        init(port: UInt16, host: String = "127.0.0.1") {
            self.port = port
            self.host = host
            let parameters = URLSessionConfiguration.ephemeral
            parameters.timeoutIntervalForRequest = 4
            parameters.requestCachePolicy = .reloadIgnoringLocalCacheData
            session = URLSession(configuration: parameters)
        }
        deinit { session.invalidateAndCancel() }
        func get(_ path: String) throws -> (status: Int, value: [String: Any]) {
            let url = try required(URL(string: "http://\(host):\(port)\(path)"), "invalid fixture URL")
            let reply = Reply<(Int, Data)>()
            let task = session.dataTask(with: url) { data, response, error in
                if let error { reply.complete(.failure(error)); return }
                guard let response = response as? HTTPURLResponse else {
                    reply.complete(.failure(Failure(message: "HTTP response missing")))
                    return
                }
                reply.complete(.success((response.statusCode, data ?? Data())))
            }
            task.resume()
            let (status, bytes) = try reply.receive()
            let value = bytes.isEmpty ? [:] : try required(JSONSerialization.jsonObject(with: bytes) as? [String: Any], "HTTP response is not a JSON object")
            return (status, value)
        }
    }

    private final class WebSocketClient {
        let session = URLSession(configuration: .ephemeral)
        let task: URLSessionWebSocketTask
        init(port: UInt16) {
            task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/")!)
            task.maximumMessageSize = 4096
            task.resume()
        }
        deinit { session.invalidateAndCancel() }
        func close() { task.cancel(with: .normalClosure, reason: nil) }
        func command(_ command: String, path: String) throws {
            let data = try JSONSerialization.data(withJSONObject: ["COMMAND": command, "DATA": path])
            let text = try required(String(data: data, encoding: .utf8), "invalid command fixture")
            let reply = Reply<Void>()
            task.send(.string(text)) { error in reply.complete(error.map(Result.failure) ?? .success(())) }
            try reply.receive()
        }
        func ping() throws {
            let reply = Reply<Void>()
            task.sendPing { error in reply.complete(error.map(Result.failure) ?? .success(())) }
            try reply.receive()
        }
        func receiveBinary() throws -> Data {
            let reply = Reply<URLSessionWebSocketTask.Message>()
            task.receive { reply.complete($0) }
            guard case .data(let bytes) = try reply.receive() else { throw Failure(message: "expected binary OSC packet") }
            return bytes
        }
        func receiveText() throws -> String {
            let reply = Reply<URLSessionWebSocketTask.Message>()
            task.receive { reply.complete($0) }
            guard case .string(let text) = try reply.receive() else { throw Failure(message: "expected WebSocket text") }
            return text
        }
    }

    private final class BonjourProbe {
        let expectedName: String
        var interface: UInt32?
        var port: UInt16?
        var host: String?
        var error: Int32?
        init(name: String) { self.expectedName = name }
    }

    private static func verifyDiscovery(name: String, port: UInt16) throws -> String {
        let probe = BonjourProbe(name: name)
        let context = Unmanaged.passUnretained(probe).toOpaque()
        var browser: DNSServiceRef?
        let result = DNSServiceBrowse(&browser, 0, kDNSServiceInterfaceIndexLocalOnly, "_oscjson._tcp", "local.", {
            _, flags, interface, error, name, _, _, context in
            guard let context else { return }
            let probe = Unmanaged<BonjourProbe>.fromOpaque(context).takeUnretainedValue()
            if error != kDNSServiceErr_NoError { probe.error = error; return }
            if flags & UInt32(kDNSServiceFlagsAdd) != 0, let name, String(cString: name) == probe.expectedName {
                probe.interface = interface
            }
        }, context)
        guard result == kDNSServiceErr_NoError, let browser else { throw Failure(message: "DNS-SD browse failed: \(result)") }
        defer { DNSServiceRefDeallocate(browser) }
        try serviceReplies(browser) { probe.interface != nil || probe.error != nil }
        try expect(probe.interface == kDNSServiceInterfaceIndexLocalOnly && probe.error == nil, "DNS-SD did not report LocalOnly service")
        var resolver: DNSServiceRef?
        let resolving = DNSServiceResolve(&resolver, 0, kDNSServiceInterfaceIndexLocalOnly, name, "_oscjson._tcp", "local.", {
            _, _, _, error, _, host, bigPort, _, _, context in
            guard let context else { return }
            let probe = Unmanaged<BonjourProbe>.fromOpaque(context).takeUnretainedValue()
            if error != kDNSServiceErr_NoError { probe.error = error; return }
            probe.host = host.map { String(cString: $0) }
            probe.port = UInt16(bigEndian: bigPort)
        }, context)
        guard resolving == kDNSServiceErr_NoError, let resolver else { throw Failure(message: "DNS-SD resolve failed: \(resolving)") }
        defer { DNSServiceRefDeallocate(resolver) }
        try serviceReplies(resolver) { probe.port != nil || probe.error != nil }
        try expect(probe.port == port && probe.host == "localhost." && probe.error == nil, "DNS-SD resolved another address or port")
        return try required(probe.host, "DNS-SD host missing")
    }

    private static func serviceReplies(_ service: DNSServiceRef, until predicate: () -> Bool) throws {
        let descriptor = DNSServiceRefSockFD(service)
        guard descriptor >= 0 else { throw Failure(message: "DNS-SD socket is unavailable") }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if Darwin.poll(&entry, 1, 150) > 0 {
                let result = DNSServiceProcessResult(service)
                guard result == kDNSServiceErr_NoError else { throw Failure(message: "DNS-SD callback error: \(result)") }
            }
        }
        try expect(predicate(), "DNS-SD callback timed out")
    }

    private static func frameAndHandshakeChecks() throws {
        let header = Data("GET / HTTP/1.1\r\nHost: localhost:4321\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13".utf8)
        try expect(OSCQueryHTTPRequest(header: header, localPort: 4321).websocketAccept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "RFC WebSocket accept value mismatch")
        var frame = Data([0x81, 0x82, 10, 20, 30, 40, 0x6B])
        try expect(OSCQueryWebSocketFrame.consumeClientFrame(in: &frame) == nil, "a split frame was consumed early")
        frame.append(0x76)
        let decoded = try OSCQueryWebSocketFrame.consumeClientFrame(in: &frame)
        try expect(decoded?.payload == Data("ab".utf8) && frame.isEmpty, "split frame mask mismatch")
        for invalid in [Data([0x81, 0]), Data([0x81, 0xFE, 0x10, 1]), Data([0x09, 0x80])] {
            var bytes = invalid
            do { _ = try OSCQueryWebSocketFrame.consumeClientFrame(in: &bytes); throw Failure(message: "invalid frame was accepted") }
            catch is OSCQueryWebSocketError { }
        }
        try OSCQueryWebSocketFrame.validateClosePayload(Data([3, 232]))
        do { try OSCQueryWebSocketFrame.validateClosePayload(Data([3, 238])); throw Failure(message: "invalid close code passed") }
        catch is OSCQueryWebSocketError { }
    }

    private static func httpLimitsChecks(port: UInt16, server: OSCQueryServer) throws {
        _ = try wait("WebSocket peers close") { server.connectionCount == 0 ? true : nil }
        try expect(rawStatus(port: port, request: "POST / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n") == 405, "HTTP mutation method rejected incorrectly")
        try expect(rawStatus(port: port, request: "GET / HTTP/1.1\r\nHost: other.example:\(port)\r\n\r\n") == 403, "HTTP host restriction failed")
        try expect(rawStatus(port: port, request: "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nOrigin: http://other.example\r\n\r\n") == 403, "HTTP origin restriction failed")
        let tooLarge = String(repeating: "x", count: 8192)
        try expect(rawStatus(port: port, request: "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-Long: \(tooLarge)\r\n\r\n") == 431, "oversized header did not hit its byte limit")
        var held: [Int32] = []
        defer { for descriptor in held { Darwin.close(descriptor) } }
        for _ in 0..<16 { held.append(try connectedSocket(port: port)) }
        _ = try wait("16 bounded open connections", seconds: 3) { server.connectionCount == 16 ? true : nil }
        let overflow = try connectedSocket(port: port)
        defer { Darwin.close(overflow) }
        var byte: UInt8 = 0
        let received = Darwin.recv(overflow, &byte, 1, 0)
        try expect(received == 0 || (received < 0 && errno == ECONNRESET), "the seventeenth connection held a slot")
    }

    private static func connectedSocket(port: UInt16) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw Failure(message: "loopback fixture socket creation failed") }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { Darwin.close(descriptor); throw Failure(message: "could not connect to localhost fixture") }
        return descriptor
    }

    private static func rawStatus(port: UInt16, request: String) throws -> Int {
        let descriptor = try connectedSocket(port: port)
        defer { Darwin.close(descriptor) }
        let bytes = Data(request.utf8)
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw Failure(message: "empty HTTP fixture request") }
            var written = 0
            while written < buffer.count {
                let amount = Darwin.send(descriptor, base.advanced(by: written), buffer.count - written, 0)
                guard amount > 0 else { throw Failure(message: "HTTP fixture send failed") }
                written += amount
            }
        }
        var reply = Data()
        while !reply.contains(10), reply.count < 512 {
            var buffer = [UInt8](repeating: 0, count: 512)
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { throw Failure(message: "HTTP fixture reply missing") }
            reply.append(contentsOf: buffer.prefix(count))
        }
        let text = String(decoding: reply, as: UTF8.self)
        let status = text.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        return try required(status, "HTTP fixture reply missing status")
    }
}
#endif
