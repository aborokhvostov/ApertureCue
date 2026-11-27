#if os(macOS)
import Foundation
import Darwin
import MappingCore

enum ControlCommand: Equatable {
    case play, pause, seek(Double), blackout(Bool), cue(Int), opacity(Int, Double)
    case externalClock(ExternalShowClockPacket, Double)
    case rawOSC(OSCMessage)
    static func from(_ message:OSCMessage) -> ControlCommand? {
        let argument = ControlInputValue(arguments: message.arguments)
        let scalar: Double?
        if case let .normalized(value)? = argument { scalar = value } else { scalar = nil }
        switch message.address {
        case "/aperturecue/play": return argument == .pulse ? .play : nil
        case "/aperturecue/pause": return argument == .pulse ? .pause : nil
        case "/aperturecue/seek": return scalar.map { .seek(max(0, $0)) }
        case "/aperturecue/blackout": return scalar.map { .blackout($0 != 0) }
        case "/aperturecue/cue":
            guard let value = scalar, value >= 0, value < 4096, value.rounded() == value else { return nil }
            return .cue(Int(value))
        default:
            guard ControlInput.isConcreteOSCPath(message.address) else { return nil }
            let parts = message.address.split(separator: "/")
            if parts.count == 4, parts[0] == "aperturecue", parts[1] == "surface", parts[3] == "opacity",
               let index = Int(parts[2]), (0..<4096).contains(index), let scalar {
                return .opacity(index, max(0, min(1, scalar)))
            }
            return nil
        }
    }
}

struct SystemFailure: LocalizedError {
    let message:String
    var errorDescription:String? { message }
}

struct OSCInputStats: Equatable {
    var datagrams = 0
    var rejected = 0
    var limited = 0
    var droppedCommands = 0
}

/// The main thread receives at most one scheduled batch. A canceled socket
/// generation cannot deliver any of its queued commands to a new session.
private final class ControlMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ControlCommand] = []
    private var scheduled = false
    private var counts = OSCInputStats()
    private let callback: (ControlCommand) -> Void

    init(_ callback: @escaping (ControlCommand) -> Void) { self.callback = callback }

    func countDatagram(rejected: Bool = false, limited: Bool = false) {
        lock.lock()
        counts.datagrams += 1
        if rejected { counts.rejected += 1 }
        if limited { counts.limited += 1 }
        lock.unlock()
    }

    var stats: OSCInputStats {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    func enqueue(_ commands: [ControlCommand]) {
        guard !commands.isEmpty else { return }
        lock.lock()
        let overflow = max(0, pending.count + commands.count - 256)
        counts.droppedCommands += overflow
        pending.removeFirst(min(pending.count, overflow))
        pending.append(contentsOf: commands.suffix(256))
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule {
            DispatchQueue.main.async { [self] in
                lock.lock()
                let batch = pending
                pending.removeAll(keepingCapacity: true)
                scheduled = false
                lock.unlock()
                batch.forEach(callback)
            }
        }
    }
}

private final class OSCReceiveBudget: @unchecked Sendable {
    // Owned by the serial socket queue.
    private var tokens = 128.0
    private var sampledAt = ProcessInfo.processInfo.systemUptime

    func admit(at time: Double) -> Bool {
        tokens = min(128, tokens + max(0, time - sampledAt) * 512)
        sampledAt = time
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

@MainActor final class NetworkController {
    private var source: DispatchSourceRead?
    private var generation: UUID?
    private var mailbox: ControlMailbox?
    private let handler: (ControlCommand) -> Void
    private let clockOnly: Bool
    private let rawOSC: Bool
    var isRunning: Bool { source != nil }
    var stats: OSCInputStats { mailbox?.stats ?? OSCInputStats() }
    private(set) var boundPort: UInt16?

    init(clockOnly: Bool = false, rawOSC: Bool = false, handler: @escaping (ControlCommand) -> Void) {
        self.clockOnly = clockOnly
        self.rawOSC = rawOSC
        self.handler = handler
    }

    func start(port: UInt16, address host: String = "127.0.0.1", peer: String? = nil) throws {
        guard !isRunning else { throw SystemFailure(message: "Stop the current OSC input before restarting it") }
        var hostIP = in_addr()
        var peerIP = in_addr()
        guard inet_pton(AF_INET, host, &hostIP) == 1, hostIP.s_addr != 0,
              hostIP.s_addr != UInt32.max, (UInt32(bigEndian: hostIP.s_addr) >> 24) < 224 else {
            throw SystemFailure(message: "Choose one literal local IPv4 bind address")
        }
        if let peer {
            guard inet_pton(AF_INET, peer, &peerIP) == 1, peerIP.s_addr != 0,
                  peerIP.s_addr != UInt32.max, (UInt32(bigEndian: peerIP.s_addr) >> 24) < 224 else {
                throw SystemFailure(message: "Choose one literal unicast IPv4 sender")
            }
        } else if host != "127.0.0.1" {
            throw SystemFailure(message: "An OSC listener beyond loopback requires one explicit sender IPv4 address")
        }
        if clockOnly && (host != "127.0.0.1" || peer != nil) {
            throw SystemFailure(message: "External clock accepts localhost")
        }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SystemFailure(message: "Cannot open OSC socket: " + String(cString: strerror(errno))) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = hostIP
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw SystemFailure(message: "Cannot bind OSC \(host):\(port): " + message)
        }
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &addressLength) }
        }
        guard named == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd)
            throw SystemFailure(message: "Cannot configure non-blocking OSC input")
        }
        boundPort = UInt16(bigEndian: address.sin_port)
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "org.aperturecue.osc"))
        let token = UUID()
        generation = token
        let mailbox = ControlMailbox { [weak self] command in
            guard let self, self.generation == token else { return }
            self.handler(command)
        }
        self.mailbox = mailbox
        let budget = OSCReceiveBudget()
        let shouldReadClock = clockOnly
        let shouldReadRaw = rawOSC
        let sender = peer == nil ? nil : peerIP.s_addr
        reader.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65536)
            for _ in 0..<64 {
                var origin = sockaddr_in()
                var originLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let size = withUnsafeMutablePointer(to: &origin) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buffer, buffer.count, 0, $0, &originLength)
                    }
                }
                if size < 0 { break }
                guard origin.sin_family == sa_family_t(AF_INET), sender == nil || sender == origin.sin_addr.s_addr else {
                    mailbox.countDatagram(rejected: true)
                    continue
                }
                let timestamp = ProcessInfo.processInfo.systemUptime
                guard budget.admit(at: timestamp) else {
                    mailbox.countDatagram(limited: true)
                    continue
                }
                guard let messages = try? OSCCodec.decode(Data(buffer.prefix(size))) else {
                    mailbox.countDatagram(rejected: true)
                    continue
                }
                mailbox.countDatagram()
                let commands = messages.compactMap { message -> ControlCommand? in
                    if shouldReadClock {
                        return ExternalShowClockPacket(message: message).map { .externalClock($0, timestamp) }
                    }
                    if shouldReadRaw {
                        guard ControlInput.isConcreteOSCPath(message.address),
                              ControlInputValue(arguments: message.arguments) != nil else { return nil }
                        return .rawOSC(message)
                    }
                    return ControlCommand.from(message)
                }
                mailbox.enqueue(commands)
            }
        }
        reader.setCancelHandler { close(fd) }
        source = reader
        reader.resume()
    }

    func stop() {
        generation = nil
        boundPort = nil
        source?.cancel()
        source = nil
    }
}

func legacyMIDICommand(_ event: MIDIControlEvent) -> ControlCommand? {
    switch event {
    case let .note(_, note, _, true):
        switch note {
        case 60: return .play
        case 61: return .pause
        case 62: return .blackout(true)
        case 63: return .blackout(false)
        case 36...59: return .cue(note - 36)
        default: return nil
        }
    case let .controlChange(_, 1, value): return .opacity(0, Double(value) / 127)
    default: return nil
    }
}

@MainActor enum ProtocolLoopback {
    static func run() -> Int32 {
        do {
            var received:[ControlCommand] = []
            let controller = NetworkController { received.append($0) }; try controller.start(port:19090)
            defer { controller.stop() }
            let fd = socket(AF_INET,SOCK_DGRAM,0); guard fd >= 0 else { throw SystemFailure(message:"Loopback socket") }; defer { close(fd) }
            func send(_ data:Data) throws {
                var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(19090).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let count = data.withUnsafeBytes { b in withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { sendto(fd,b.baseAddress,data.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
                guard count == data.count else { throw SystemFailure(message:"UDP send failed") }
            }
            try send(OSCCodec.encodeBundle([OSCMessage(address:"/aperturecue/play"),OSCMessage(address:"/aperturecue/seek",arguments:[.float(1.25)]),OSCMessage(address:"/aperturecue/surface/2/opacity",arguments:[.float(0.5)])]))
            let until = Date().addingTimeInterval(3)
            while received.count < 3, Date() < until { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
            guard received == [.play,.seek(1.25),.opacity(2,0.5)] else { throw SystemFailure(message:"OSC UDP commands differ: \(received)") }
            var parser = MIDIControlCodec()
            guard parser.feed([0x90,60,100,61,0,61,100,0xF8,0xB0,1,127]).compactMap(legacyMIDICommand) == [.play,.pause,.opacity(0,1)] else { throw SystemFailure(message:"MIDI running status parser differs") }
            print("PASS OSC immediate-bundle UDP localhost loopback and MIDI parser. No lighting/MIDI hardware verified.")
            return 0
        } catch { fputs("FAIL \(error.localizedDescription)\n",stderr); return 1 }
    }
}
#endif
