#if os(macOS)
import Foundation
import Darwin
import CoreMIDI
import MappingCore

enum ControlCommand: Equatable {
    case play, pause, seek(Double), blackout(Bool), cue(Int), opacity(Int, Double)
    static func from(_ message:OSCMessage) -> ControlCommand? {
        func number() -> Double? {
            switch message.arguments.first { case .int(let n): return Double(n); case .float(let n): return Double(n); case .bool(let b): return b ? 1 : 0; default: return nil }
        }
        switch message.address {
        case "/aperturecue/play": return .play
        case "/aperturecue/pause": return .pause
        case "/aperturecue/seek": return number().map { .seek(max(0,$0)) }
        case "/aperturecue/blackout": return number().map { .blackout($0 != 0) }
        case "/aperturecue/cue": if let n = number(), n >= 0, n < 4096 { return .cue(Int(n)) }; return nil
        default:
            let parts = message.address.split(separator:"/")
            if parts.count == 4, parts[0] == "aperturecue", parts[1] == "surface", parts[3] == "opacity", let i = Int(parts[2]), i >= 0, i < 4096, let n = number() { return .opacity(i,max(0,min(1,n))) }
            return nil
        }
    }
}

struct SystemFailure: LocalizedError {
    let message:String
    var errorDescription:String? { message }
}

/// The main thread receives at most one pending batch, with a strict command cap.
private final class ControlMailbox {
    private let lock = NSLock()
    private var pending:[ControlCommand] = []
    private var scheduled = false
    private let callback:(ControlCommand)->Void
    init(_ callback:@escaping (ControlCommand)->Void) { self.callback = callback }
    func enqueue(_ commands:[ControlCommand]) {
        guard !commands.isEmpty else { return }
        lock.lock(); pending.append(contentsOf:commands.suffix(256))
        if pending.count > 256 { pending.removeFirst(pending.count-256) }
        let needsSchedule = !scheduled; scheduled = true; lock.unlock()
        if needsSchedule { DispatchQueue.main.async { [self] in
            lock.lock(); let batch = pending; pending.removeAll(keepingCapacity:true); scheduled = false; lock.unlock()
            batch.forEach(callback)
        } }
    }
}

/// UDP input is opt-in and bound to loopback. Parsing runs on a dedicated queue.
@MainActor final class NetworkController {
    private var source:DispatchSourceRead?
    private let handler:(ControlCommand)->Void
    var isRunning:Bool { source != nil }
    init(handler:@escaping (ControlCommand)->Void) { self.handler = handler }
    func start(port:UInt16) throws {
        stop()
        let fd = socket(AF_INET,SOCK_DGRAM,0)
        guard fd >= 0 else { throw SystemFailure(message:"Cannot open OSC socket: \(String(cString:strerror(errno)))") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { let e = errno; close(fd); throw SystemFailure(message:"Cannot bind OSC localhost:\(port): \(String(cString:strerror(e)))") }
        _ = fcntl(fd,F_SETFL,O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor:fd,queue:DispatchQueue(label:"org.aperturecue.osc"))
        let mailbox = ControlMailbox(handler)
        reader.setEventHandler {
            var buffer = [UInt8](repeating:0,count:65536)
            // Bound work per callback so a flood cannot monopolize the dispatch queue.
            for _ in 0..<64 {
                let size = recv(fd,&buffer,buffer.count,0)
                if size <= 0 { break }
                guard let messages = try? OSCCodec.decode(Data(buffer.prefix(size))) else { continue }
                let commands = messages.compactMap(ControlCommand.from)
                mailbox.enqueue(commands)
            }
        }
        reader.setCancelHandler { close(fd) }; source = reader; reader.resume()
    }
    func stop() { source?.cancel(); source = nil }
}

/// Stateful MIDI 1.0 channel-message parser; real-time bytes do not disturb running status.
final class MIDIParser {
    private let lock = NSLock()
    private var status:UInt8 = 0, bytes:[UInt8] = [], inSysEx = false
    func feed(_ data:[UInt8]) -> [ControlCommand] {
        lock.lock(); defer { lock.unlock() }
        var result:[ControlCommand] = []
        for byte in data {
            if byte >= 0xF8 { continue }
            if byte == 0xF0 { inSysEx = true; status = 0; bytes = []; continue }
            if byte == 0xF7 { inSysEx = false; continue }
            if inSysEx { continue }
            if byte & 0x80 != 0 { status = byte < 0xF0 ? byte : 0; bytes = []; continue }
            guard status != 0 else { continue }; bytes.append(byte)
            let command = status & 0xF0
            let size = (command == 0xC0 || command == 0xD0) ? 1 : 2
            guard bytes.count == size else { continue }
            if command == 0x90, bytes[1] > 0 {
                switch bytes[0] { case 60: result.append(.play); case 61: result.append(.pause); case 62: result.append(.blackout(true)); case 63: result.append(.blackout(false)); case 36...59: result.append(.cue(Int(bytes[0]-36))); default: break }
            } else if command == 0xB0, bytes[0] == 1 { result.append(.opacity(0,Double(bytes[1])/127)) }
            bytes = []
        }
        return result
    }
}

@MainActor final class MIDIController {
    private var client:MIDIClientRef = 0, port:MIDIPortRef = 0
    private let handler:(ControlCommand)->Void
    private var sourceContexts:[UnsafeMutableRawPointer] = []
    init(handler:@escaping (ControlCommand)->Void) { self.handler = handler }
    func start() throws {
        stop()
        var status = MIDIClientCreateWithBlock("ApertureCue" as CFString,&client,nil)
        guard status == noErr else { throw SystemFailure(message:"MIDI client error \(status)") }
        let mailbox = ControlMailbox(handler)
        // CoreMIDI invokes the callback on its own serialized receive thread.
        status = MIDIInputPortCreateWithBlock(client,"Control" as CFString,&port) { list,context in
            guard let context else { return }
            let parser = Unmanaged<MIDIParser>.fromOpaque(context).takeUnretainedValue()
            let offset = MemoryLayout<MIDIPacketList>.offset(of:\.packet)!
            var p = UnsafeRawPointer(list).advanced(by:offset).assumingMemoryBound(to:MIDIPacket.self)
            var commands:[ControlCommand] = []
            for _ in 0..<list.pointee.numPackets {
                let count = min(256,Int(p.pointee.length))
                let data = withUnsafeBytes(of:p.pointee.data) { Array($0.prefix(count)) }
                commands += parser.feed(data); p = UnsafePointer(MIDIPacketNext(p))
            }
            mailbox.enqueue(commands)
        }
        guard status == noErr else { stop(); throw SystemFailure(message:"MIDI input error \(status)") }
        for index in 0..<MIDIGetNumberOfSources() {
            let context = Unmanaged.passRetained(MIDIParser()).toOpaque()
            if MIDIPortConnectSource(port,MIDIGetSource(index),context) == noErr { sourceContexts.append(context) }
            else { Unmanaged<MIDIParser>.fromOpaque(context).release() }
        }
    }
    func stop() {
        if port != 0 { MIDIPortDispose(port); port = 0 }; if client != 0 { MIDIClientDispose(client); client = 0 }
        sourceContexts.forEach { Unmanaged<MIDIParser>.fromOpaque($0).release() }; sourceContexts.removeAll()
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
            let parser = MIDIParser()
            guard parser.feed([0x90,60,100,61,0,61,100,0xF8,0xB0,1,127]) == [.play,.pause,.opacity(0,1)] else { throw SystemFailure(message:"MIDI running status parser differs") }
            print("PASS OSC immediate-bundle UDP localhost loopback and MIDI parser. No lighting/MIDI hardware verified.")
            return 0
        } catch { fputs("FAIL \(error.localizedDescription)\n",stderr); return 1 }
    }
}
#endif
