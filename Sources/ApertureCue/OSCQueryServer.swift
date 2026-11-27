#if os(macOS)
import Foundation
import Darwin
import dnssd
import MappingCore

public enum OSCQueryServerStatus: Equatable, Sendable {
    case stopped, starting, ready(port: UInt16), failed(String)
}

public enum OSCQueryDiscoveryStatus: Equatable, Sendable {
    case off, registering, ready(name: String), failed(String)
}

/// Read-side serial TCP server on IPv4 loopback. Query publication hands off
/// immutable value snapshots. No input path reaches the editor or OSC router.
final class OSCQueryServer {
    static let defaultPort: UInt16 = 5679
    private static let maxConnections = 16
    private static let maxWebSockets = 8
    private static let maxSubscriptions = 32
    private static let maxBufferedBytes = 16_384
    private static let healthInterval = 0.05
    private static let discoveryTimeout = 5.0
    private static let pathChanged = OSCQueryWebSocketFrame.encoded(opcode: 1, payload: Data("{\"COMMAND\":\"PATH_CHANGED\",\"DATA\":\"/\"}".utf8))

    private enum Mode { case http, webSocket, ending }

    private struct Rate {
        var tokens: Double
        var last: Double
        let limit: Double

        init(limit: Double, now: Double) { self.tokens = limit; self.last = now; self.limit = limit }
        mutating func take(now: Double) -> Bool {
            tokens = min(limit, tokens + max(0, now - last) * limit)
            last = now
            guard tokens >= 1 else { return false }
            tokens -= 1
            return true
        }
    }

    private final class Client {
        let id = UUID()
        let descriptor: Int32
        var mode = Mode.http
        var rate: Rate
        var buffer = Data()
        var pendingControls: [Data] = []
        var output: PendingWrite?
        var sending: Bool { output != nil }
        var endFrame: Data?
        var deadline: Double
        var lastPing: Double
        var fragments = Data()
        var fragmentCount = 0
        var subscriptions = Set<String>()
        var lastValues: [String: [OSCArgument]] = [:]
        var observedStructure: UInt64 = 0

        init(descriptor: Int32, now: Double) {
            self.descriptor = descriptor
            rate = Rate(limit: 32, now: now)
            deadline = now + 5
            lastPing = now
        }
    }

    private struct PendingWrite {
        let data: Data
        let final: Bool
        let deadline: Double
        var offset = 0
    }

    private struct Revision {
        var snapshot: OSCQuerySnapshot
        var structure: UInt64
    }

    private let queue = DispatchQueue(label: "org.aperturecue.oscquery")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private var currentStatus = OSCQueryServerStatus.stopped
    private var currentDiscovery = OSCQueryDiscoveryStatus.off
    private var revision = Revision(snapshot: try! OSCQuerySnapshot(), structure: 0)
    private var listener: Int32?
    private var readBytes = [UInt8](repeating: 0, count: 4096)
    private var ticker: DispatchSourceTimer?
    private var clients: [UUID: Client] = [:]
    private var acceptRate = Rate(limit: 32, now: 0)
    private var oscPort: UInt16?
    private var queuePort: UInt16 = 0
    private var registration: DNSServiceRef?
    private var discoveryCallback: DiscoveryCallback?
    private var discoveryDeadline: Double?

    private final class DiscoveryCallback {
        weak var server: OSCQueryServer?
        init(server: OSCQueryServer) { self.server = server }
    }

    init() { queue.setSpecific(key: queueKey, value: 1) }
    deinit { stop() }

    var status: OSCQueryServerStatus { lock.withLock { currentStatus } }
    var discoveryStatus: OSCQueryDiscoveryStatus { lock.withLock { currentDiscovery } }

    // Test and diagnostics snapshot. Connection descriptors stay on the server queue.
    var connectionCount: Int { queue.sync { clients.count } }

    func publish(_ nodes: [OSCQueryNode]) throws {
        let next = try OSCQuerySnapshot(nodes: nodes)
        lock.withLock {
            guard next != revision.snapshot else { return }
            if !next.hasSameMetadata(as: revision.snapshot) { revision.structure &+= 1 }
            revision.snapshot = next
        }
    }

    func start(port: UInt16 = defaultPort, oscPort: UInt16? = 5678, advertiseLocally: Bool = false) throws {
        guard oscPort != 0 else { throw ProtocolError.malformed("OSC Query port is invalid") }
        try queue.sync {
            stopLocked()
            lock.withLock { currentStatus = .starting }
            do {
                let socket = try OSCQuerySocket.listen(on: port)
                listener = socket.descriptor
                queuePort = socket.port
                self.oscPort = oscPort
                if advertiseLocally { startDiscovery(port: socket.port) }
                lock.withLock { currentStatus = .ready(port: socket.port) }
            } catch {
                stopLocked(finalStatus: .failed(error.localizedDescription))
                throw error
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.healthInterval, repeating: Self.healthInterval, leeway: .milliseconds(8))
            timer.setEventHandler { [weak self] in self?.checkClients() }
            ticker = timer
            timer.resume()
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == 1 { stopLocked() }
        else { queue.sync { stopLocked() } }
    }

    private func stopLocked(finalStatus: OSCQueryServerStatus = .stopped) {
        ticker?.cancel()
        ticker = nil
        if let listener { Darwin.close(listener) }
        listener = nil
        releaseDiscovery()
        for client in clients.values { Darwin.close(client.descriptor) }
        clients.removeAll()
        queuePort = 0
        oscPort = nil
        acceptRate = Rate(limit: 32, now: ProcessInfo.processInfo.systemUptime)
        lock.withLock {
            currentStatus = finalStatus
            currentDiscovery = .off
        }
    }

    private func startDiscovery(port: UInt16) {
        let callback = DiscoveryCallback(server: self)
        let context = Unmanaged.passUnretained(callback).toOpaque()
        var service: DNSServiceRef?
        let result = DNSServiceRegister(&service, 0, kDNSServiceInterfaceIndexLocalOnly, "ApertureCue OSC Query",
                                        "_oscjson._tcp", "local.", "localhost.", port.bigEndian, 0, nil, {
            _, _, error, name, _, _, context in
            guard let context, let owner = Unmanaged<DiscoveryCallback>.fromOpaque(context).takeUnretainedValue().server else { return }
            owner.discoveryDeadline = nil
            owner.lock.withLock {
                if error == kDNSServiceErr_NoError, let name {
                    owner.currentDiscovery = .ready(name: String(cString: name))
                } else { owner.currentDiscovery = .failed("DNS-SD registration error \(error)") }
            }
        }, context)
        guard result == kDNSServiceErr_NoError, let service else {
            lock.withLock { currentDiscovery = .failed("DNS-SD registration error \(result)") }
            return
        }
        let attach = DNSServiceSetDispatchQueue(service, queue)
        guard attach == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(service)
            lock.withLock { currentDiscovery = .failed("DNS-SD queue error \(attach)") }
            return
        }
        registration = service
        discoveryCallback = callback
        discoveryDeadline = ProcessInfo.processInfo.systemUptime + Self.discoveryTimeout
        lock.withLock { currentDiscovery = .registering }
    }

    private func releaseDiscovery() {
        if let registration { DNSServiceRefDeallocate(registration) }
        registration = nil
        discoveryCallback = nil
        discoveryDeadline = nil
    }

    private func expireDiscovery(at now: Double) {
        if case .failed = discoveryStatus, registration != nil {
            releaseDiscovery()
        } else if let deadline = discoveryDeadline, now >= deadline {
            // The OS can withhold this callback while local network permission
            // is unresolved. Stop only the optional Bonjour registration.
            releaseDiscovery()
            lock.withLock {
                currentDiscovery = .failed("Local discovery did not reply. The OSC Query URL at 127.0.0.1:\(queuePort) is still available.")
            }
        }
    }

    private func acceptConnections(now: Double) throws {
        guard let listener else { return }
        for _ in 0..<Self.maxConnections {
            switch try OSCQuerySocket.accept(from: listener, admit: { clients.count < Self.maxConnections && acceptRate.take(now: now) }) {
            case .empty: return
            case .rejected: continue
            case .peer(let descriptor):
                let client = Client(descriptor: descriptor, now: now)
                clients[client.id] = client
            }
        }
    }

    private func receive(_ client: Client) {
        let length = Darwin.recv(client.descriptor, &readBytes, readBytes.count, 0)
        if length < 0 {
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { drop(client) }
            return
        }
        guard length > 0 else { drop(client); return }
        client.buffer.append(contentsOf: readBytes.prefix(length))
        if client.buffer.count > Self.maxBufferedBytes {
            if client.mode == .http { sendHTTP(client, status: 431, reason: "Request Header Fields Too Large") }
            else { endWebSocket(client, code: 1009) }
        } else if client.mode == .http { readHTTP(client) }
        else if client.mode == .webSocket { readWebSocket(client) }
    }

    private func readHTTP(_ client: Client) {
        guard let boundary = client.buffer.range(of: OSCQueryHTTPRequest.headerEnd) else {
            if client.buffer.count > OSCQueryHTTPRequest.maximumBytes {
                sendHTTP(client, status: 431, reason: "Request Header Fields Too Large")
            }
            return
        }
        if client.buffer.distance(from: client.buffer.startIndex, to: boundary.lowerBound) > OSCQueryHTTPRequest.maximumBytes {
            sendHTTP(client, status: 431, reason: "Request Header Fields Too Large")
            return
        }
        do {
            let request = try OSCQueryHTTPRequest(header: client.buffer[..<boundary.lowerBound], localPort: queuePort)
            client.buffer = Data(client.buffer[boundary.upperBound...])
            if let accept = request.websocketAccept {
                guard clients.values.filter({ $0.mode == .webSocket }).count < Self.maxWebSockets else {
                    sendHTTP(client, status: 503, reason: "Service Unavailable")
                    return
                }
                let current = lock.withLock { revision }
                client.mode = .webSocket
                let now = ProcessInfo.processInfo.systemUptime
                client.deadline = now + 90
                client.lastPing = now
                client.observedStructure = current.structure
                let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                send(client, data: Data(response.utf8))
                if !client.buffer.isEmpty { readWebSocket(client) }
                return
            }
            guard client.buffer.isEmpty else { throw OSCQueryHTTPProblem(status: 400, reason: "Bad Request") }
            if request.query == "HOST_INFO" {
                sendHTTP(client, status: 200, reason: "OK", body: try hostInfo())
                return
            }
            let attribute = request.query.flatMap(OSCQueryAttribute.init(rawValue:))
            if request.query != nil, attribute == nil { sendHTTP(client, status: 204, reason: "No Content"); return }
            let snapshot = lock.withLock { revision.snapshot }
            switch try snapshot.response(path: request.path, attribute: attribute) {
            case .json(let body): sendHTTP(client, status: 200, reason: "OK", body: body)
            case .noContent: sendHTTP(client, status: 204, reason: "No Content")
            case .notFound: sendHTTP(client, status: 404, reason: "Not Found")
            case .tooLarge: sendHTTP(client, status: 503, reason: "Service Unavailable")
            }
        } catch let problem as OSCQueryHTTPProblem {
            sendHTTP(client, status: problem.status, reason: problem.reason)
        } catch {
            sendHTTP(client, status: 500, reason: "Internal Server Error")
        }
    }

    private func hostInfo() throws -> Data {
        let flags = ["ACCESS", "VALUE", "RANGE", "DESCRIPTION", "LISTEN", "PATH_CHANGED"]
        var object: [String: Any] = [
            "NAME": "ApertureCue", "WS_IP": "127.0.0.1", "WS_PORT": queuePort,
            "EXTENSIONS": Dictionary(uniqueKeysWithValues: flags.map { ($0, true) })
        ]
        if let oscPort {
            object["OSC_IP"] = "127.0.0.1"
            object["OSC_PORT"] = oscPort
            object["OSC_TRANSPORT"] = "UDP"
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func sendHTTP(_ client: Client, status: Int, reason: String, body: Data = Data()) {
        var headers = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        if status != 204 { headers += "Content-Length: \(body.count)\r\n" }
        if status == 200 { headers += "Content-Type: application/json\r\n" }
        if status == 405 { headers += "Allow: GET\r\n" }
        if status == 426 { headers += "Sec-WebSocket-Version: 13\r\n" }
        var bytes = Data((headers + "\r\n").utf8)
        bytes.append(body)
        client.mode = .ending
        client.deadline = ProcessInfo.processInfo.systemUptime + 5
        send(client, data: bytes, final: true)
    }

    private struct SubscriptionCommand: Decodable {
        var command: String
        var path: String
        enum CodingKeys: String, CodingKey { case command = "COMMAND", path = "DATA" }
    }

    private func applyCommand(_ bytes: Data, to client: Client) throws {
        guard String(data: bytes, encoding: .utf8) != nil,
              let command = try? JSONDecoder().decode(SubscriptionCommand.self, from: bytes),
              OSCQuerySnapshot.isMethodPath(command.path) else { throw OSCQueryWebSocketError.invalidText }
        switch command.command {
        case "LISTEN":
            let node = lock.withLock { revision.snapshot.node(at: command.path) }
            guard node?.access.isReadable == true, !client.subscriptions.contains(command.path) else { return }
            guard client.subscriptions.count < Self.maxSubscriptions else { throw OSCQueryWebSocketError.policy }
            client.subscriptions.insert(command.path)
        case "IGNORE":
            client.subscriptions.remove(command.path)
            client.lastValues.removeValue(forKey: command.path)
        default: break
        }
    }

    private func readWebSocket(_ client: Client) {
        do {
            while let frame = try OSCQueryWebSocketFrame.consumeClientFrame(in: &client.buffer) {
                let now = ProcessInfo.processInfo.systemUptime
                guard client.rate.take(now: now) else { throw OSCQueryWebSocketError.policy }
                client.deadline = now + 90
                switch frame.opcode {
                case 0:
                    guard client.fragmentCount > 0 else { throw OSCQueryWebSocketError.protocolViolation }
                    client.fragmentCount += 1
                    guard client.fragmentCount <= 16, client.fragments.count + frame.payload.count <= OSCQueryWebSocketFrame.maximumPayload else {
                        throw OSCQueryWebSocketError.oversize
                    }
                    client.fragments.append(frame.payload)
                    if frame.final {
                        try applyCommand(client.fragments, to: client)
                        client.fragments.removeAll()
                        client.fragmentCount = 0
                    }
                case 1:
                    guard client.fragmentCount == 0 else { throw OSCQueryWebSocketError.protocolViolation }
                    if frame.final { try applyCommand(frame.payload, to: client) }
                    else { client.fragments = frame.payload; client.fragmentCount = 1 }
                case 2: throw OSCQueryWebSocketError.unsupported
                case 8:
                    try OSCQueryWebSocketFrame.validateClosePayload(frame.payload)
                    endWebSocket(client, payload: frame.payload)
                    return
                case 9:
                    guard client.pendingControls.count < 8 else { throw OSCQueryWebSocketError.policy }
                    client.pendingControls.append(OSCQueryWebSocketFrame.encoded(opcode: 10, payload: frame.payload))
                case 10: break
                default: throw OSCQueryWebSocketError.protocolViolation
                }
            }
        } catch let error as OSCQueryWebSocketError {
            endWebSocket(client, code: error.closeCode)
        } catch {
            endWebSocket(client, code: 1002)
        }
    }

    private func checkClients() {
        let now = ProcessInfo.processInfo.systemUptime
        expireDiscovery(at: now)
        do { try acceptConnections(now: now) }
        catch {
            stopLocked(finalStatus: .failed(error.localizedDescription))
            return
        }
        let current = lock.withLock { revision }
        for client in Array(clients.values) {
            if now >= client.deadline || client.output.map({ now >= $0.deadline }) == true {
                drop(client)
                continue
            }
            if client.mode != .ending { receive(client) }
            guard clients[client.id] != nil else { continue }
            if client.mode == .webSocket, !client.sending { queueUpdates(for: client, current: current, now: now) }
            flushOutput(client)
        }
    }

    private func queueUpdates(for client: Client, current: Revision, now: Double) {
        var bytes = Data()
        if now - client.lastPing >= 30, client.pendingControls.count < 8 {
            client.pendingControls.append(OSCQueryWebSocketFrame.encoded(opcode: 9))
            client.lastPing = now
        }
        for control in client.pendingControls { bytes.append(control) }
        client.pendingControls.removeAll(keepingCapacity: true)
        if current.structure != client.observedStructure {
            bytes.append(Self.pathChanged)
            client.observedStructure = current.structure
        }
        for path in client.subscriptions.sorted() {
            guard let node = current.snapshot.node(at: path), node.access.isReadable else {
                client.subscriptions.remove(path)
                client.lastValues.removeValue(forKey: path)
                continue
            }
            guard let value = node.value, value != client.lastValues[path],
                  let osc = try? OSCCodec.encode(OSCMessage(address: path, arguments: value)) else { continue }
            let frame = OSCQueryWebSocketFrame.encoded(opcode: 2, payload: osc)
            guard bytes.count + frame.count <= 128 * 1024 else { break }
            bytes.append(frame)
            client.lastValues[path] = value
        }
        if !bytes.isEmpty { send(client, data: bytes) }
    }

    private func send(_ client: Client, data: Data, final: Bool = false) {
        precondition(!client.sending)
        client.output = PendingWrite(data: data, final: final, deadline: ProcessInfo.processInfo.systemUptime + 5)
    }

    private func flushOutput(_ client: Client) {
        guard var output = client.output else { return }
        let count = output.data.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            return Darwin.send(client.descriptor, base.advanced(by: output.offset), bytes.count - output.offset, 0)
        }
        if count < 0 {
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { drop(client) }
            return
        }
        output.offset += count
        guard output.offset == output.data.count else { client.output = output; return }
        client.output = nil
        if output.final { drop(client) }
        else if let closing = client.endFrame {
            client.endFrame = nil
            send(client, data: closing, final: true)
        }
    }

    private func endWebSocket(_ client: Client, code: UInt16) {
        endWebSocket(client, payload: OSCQueryWebSocketFrame.closePayload(code: code))
    }

    private func endWebSocket(_ client: Client, payload: Data) {
        guard client.mode == .webSocket else { return }
        client.mode = .ending
        client.deadline = ProcessInfo.processInfo.systemUptime + 2
        let frame = OSCQueryWebSocketFrame.encoded(opcode: 8, payload: payload)
        if client.sending { client.endFrame = frame }
        else { send(client, data: frame, final: true) }
    }

    private func drop(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        Darwin.close(client.descriptor)
    }
}
#endif
