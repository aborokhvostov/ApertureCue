#if os(macOS)
import CoreMIDI
import Darwin
import Foundation
import MappingCore

@MainActor final class ShowControlOutput {
    static let midiSourceName = "ApertureCue Show Output"
    private var udp: Int32 = -1
    private var client: MIDIClientRef = 0
    private var source: MIDIEndpointRef = 0
    private var activeNotes = Set<UInt16>()

    var midiSource: MIDIEndpointRef { source }
    private(set) var oscHost = "127.0.0.1"

    func setOSCHost(_ host: String) throws {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1, address.s_addr != 0,
              address.s_addr != UInt32.max, (1...223).contains(UInt32(bigEndian: address.s_addr) >> 24) else {
            throw SystemFailure(message: "Enter one literal unicast IPv4 destination for OSC")
        }
        oscHost = host
    }

    func prepareMIDI() throws {
        guard source == 0 else { return }
        var status = MIDIClientCreateWithBlock("ApertureCue Show Control" as CFString, &client, nil)
        guard status == noErr else { throw SystemFailure(message: "Cannot open show MIDI client: \(status)") }
        status = MIDISourceCreate(client, Self.midiSourceName as CFString, &source)
        if status != noErr {
            MIDIClientDispose(client)
            client = 0
            throw SystemFailure(message: "Cannot create virtual show MIDI source: \(status)")
        }
    }

    func send(_ command: ShowControlCommand) throws {
        switch command {
        case .osc(let port, _, _):
            if let packet = try command.oscPacket() { try sendOSC(packet, port: port) }
        case .midi(let kind, let channel, let number, let value):
            guard let bytes = try command.midiBytes() else { return }
            try prepareMIDI()
            try sendMIDI(bytes)
            let key = UInt16((channel - 1) * 128 + number)
            if kind == .noteOff || (kind == .noteOn && value == 0) { activeNotes.remove(key) }
            else if kind == .noteOn { activeNotes.insert(key) }
        }
    }

    func flushNotes() {
        for key in activeNotes.sorted() {
            _ = try? sendMIDI([0x80 | UInt8(key / 128), UInt8(key % 128), 0])
        }
        activeNotes.removeAll(keepingCapacity: true)
    }

    func stop() {
        flushNotes()
        if source != 0 { MIDIEndpointDispose(source); source = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        if udp >= 0 { close(udp); udp = -1 }
    }

    deinit {
        if source != 0 { MIDIEndpointDispose(source) }
        if client != 0 { MIDIClientDispose(client) }
        if udp >= 0 { close(udp) }
    }

    func sendOSC(_ data: Data, port: UInt16) throws {
        if udp < 0 {
            let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
            guard socketFD >= 0 else { throw SystemFailure(message: "Cannot open show OSC socket") }
            guard fcntl(socketFD, F_SETFL, O_NONBLOCK) == 0 else {
                close(socketFD)
                throw SystemFailure(message: "Cannot configure non-blocking show OSC output")
            }
            udp = socketFD
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr(oscHost)
        address.sin_port = port.bigEndian
        let size = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(udp, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard size == data.count else { throw SystemFailure(message: "Show OSC datagram could not be sent") }
    }

    private func sendMIDI(_ bytes: [UInt8]) throws {
        guard bytes.count == 3 else { throw SystemFailure(message: "Show MIDI requires a three-byte channel message") }
        var packetList = MIDIPacketList()
        let status = withUnsafeMutablePointer(to: &packetList) { list -> OSStatus in
            let first = MIDIPacketListInit(list)
            return bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return kMIDIInvalidClient }
                // A single three-byte packet fits in MIDIPacketList's inline packet.
                _ = MIDIPacketListAdd(list, MemoryLayout<MIDIPacketList>.size, first, 0, bytes.count, base)
                return MIDIReceived(source, list)
            }
        }
        guard status == noErr else { throw SystemFailure(message: "Virtual show MIDI output failed: \(status)") }
    }
}
#endif
