import Foundation

public enum MIDIRealtime: UInt8, Codable, Equatable, Sendable {
    case clock = 0xF8
    case start = 0xFA
    case continuePlayback = 0xFB
    case stop = 0xFC
}

public enum MIDIControlEvent: Equatable, Sendable {
    case note(channel: Int, note: Int, velocity: Int, isOn: Bool)
    case controlChange(channel: Int, controller: Int, value: Int)
    case controlChange14(channel: Int, controller: Int, value: Int)
    case pitchBend(channel: Int, value: Int)
    case realtime(MIDIRealtime)

    /// A 14-bit CC emits two MIDI 1.0 channel messages. All other cases emit one.
    public func encodedMessages() throws -> [[UInt8]] {
        func byte(_ value: Int, name: String, range: ClosedRange<Int> = 0...127) throws -> UInt8 {
            guard range.contains(value) else { throw ProtocolError.malformed("MIDI \(name) is out of range") }
            return UInt8(value)
        }
        func status(_ base: UInt8, channel: Int) throws -> UInt8 {
            base | (try byte(channel, name: "channel", range: 1...16) - 1)
        }
        func pair(_ value: Int) throws -> (msb: UInt8, lsb: UInt8) {
            guard (0...16383).contains(value) else { throw ProtocolError.malformed("MIDI 14-bit value is out of range") }
            return (UInt8(value >> 7), UInt8(value & 127))
        }
        switch self {
        case let .note(channel, note, velocity, isOn):
            return [[try status(isOn ? 0x90 : 0x80, channel: channel),
                     try byte(note, name: "note"), try byte(velocity, name: "velocity")]]
        case let .controlChange(channel, controller, value):
            return [[try status(0xB0, channel: channel), try byte(controller, name: "controller"),
                     try byte(value, name: "controller value")]]
        case let .controlChange14(channel, controller, value):
            let prefix = try status(0xB0, channel: channel)
            let msbController = try byte(controller, name: "14-bit controller", range: 0...31)
            let split = try pair(value)
            return [[prefix, msbController, split.msb], [prefix, msbController + 32, split.lsb]]
        case let .pitchBend(channel, value):
            let split = try pair(value)
            return [[try status(0xE0, channel: channel), split.lsb, split.msb]]
        case let .realtime(event):
            return [[event.rawValue]]
        }
    }
}

/// One decoder belongs to one selected endpoint/connection. Running status
/// survives real-time bytes and callback boundaries. System-common statuses
/// cancel it. Unsupported channel messages are consumed at their true length.
public struct MIDIControlCodec: Sendable {
    public static let maximumBytesPerFeed = 4096
    public static let maximumEventsPerFeed = 256

    private var runningStatus: UInt8 = 0
    private var firstData: UInt8?
    private var inSysEx = false
    private var coarse = [Int16](repeating: -1, count: 16 * 32)
    private var fine = [Int16](repeating: -1, count: 16 * 32)
    public private(set) var eventsTruncatedLastFeed = false

    public init() {}

    public mutating func reset() { self = Self() }

    public mutating func feed(_ bytes: [UInt8]) -> [MIDIControlEvent] {
        var result: [MIDIControlEvent] = []
        var exceededEvents = false
        func append(_ event: MIDIControlEvent) {
            if result.count < Self.maximumEventsPerFeed { result.append(event) }
            else { exceededEvents = true }
        }
        for byte in bytes.prefix(Self.maximumBytesPerFeed) {
            if byte >= 0xF8 {
                if let action = MIDIRealtime(rawValue: byte) { append(.realtime(action)) }
                continue
            }
            if byte >= 0x80 {
                firstData = nil
                inSysEx = byte == 0xF0
                runningStatus = byte < 0xF0 ? byte : 0
                continue
            }
            guard !inSysEx, runningStatus != 0 else { continue }
            let command = runningStatus & 0xF0
            let channel = Int(runningStatus & 0x0F) + 1
            if command == 0xC0 || command == 0xD0 { continue }
            guard let first = firstData else { firstData = byte; continue }
            firstData = nil
            switch command {
            case 0x80, 0x90:
                append(.note(channel: channel, note: Int(first), velocity: Int(byte), isOn: command == 0x90 && byte > 0))
            case 0xB0:
                append(.controlChange(channel: channel, controller: Int(first), value: Int(byte)))
                if let value = pair(channel: channel, controller: Int(first), value: Int16(byte)) {
                    append(value)
                }
            case 0xE0:
                append(.pitchBend(channel: channel, value: (Int(byte) << 7) | Int(first)))
            default:
                break
            }
        }
        // A discarded byte range can contain status and CC mutations. Start
        // fresh on the next delivery rather than using stale running state.
        if bytes.count > Self.maximumBytesPerFeed { reset() }
        eventsTruncatedLastFeed = exceededEvents || bytes.count > Self.maximumBytesPerFeed
        return result
    }

    private mutating func pair(channel: Int, controller: Int, value: Int16) -> MIDIControlEvent? {
        guard controller < 64 else { return nil }
        let base = controller % 32
        let index = (channel - 1) * 32 + base
        if controller < 32 { coarse[index] = value }
        else { fine[index] = value }
        guard coarse[index] >= 0, fine[index] >= 0 else { return nil }
        return .controlChange14(channel: channel, controller: base, value: Int(coarse[index]) * 128 + Int(fine[index]))
    }
}
