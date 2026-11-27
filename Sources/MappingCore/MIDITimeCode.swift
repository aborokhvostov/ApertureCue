import Foundation

public enum MIDITimeCodeRate: UInt8, CaseIterable, Sendable {
    case fps24 = 0
    case fps25 = 1
    case drop2997 = 2
    case fps30 = 3

    public var framesPerSecond: Double {
        switch self {
        case .fps24: return 24
        case .fps25: return 25
        case .drop2997: return 30_000 / 1_001
        case .fps30: return 30
        }
    }

    fileprivate var nominalFramesPerSecond: Int {
        self == .drop2997 ? 30 : Int(framesPerSecond)
    }

    fileprivate var framesPerDay: Int {
        nominalFramesPerSecond * 86_400 - (self == .drop2997 ? 2_592 : 0)
    }
}

public struct MIDITimeCodePosition: Equatable, Sendable {
    public let rate: MIDITimeCodeRate
    public let hours: Int
    public let minutes: Int
    public let seconds: Int
    public let frames: Int

    public init?(rate: MIDITimeCodeRate, hours: Int, minutes: Int, seconds: Int, frames: Int) {
        guard (0..<24).contains(hours), (0..<60).contains(minutes), (0..<60).contains(seconds),
              (0..<rate.nominalFramesPerSecond).contains(frames) else { return nil }
        guard rate != .drop2997 || minutes.isMultiple(of: 10) || seconds != 0 || frames >= 2 else { return nil }
        self.rate = rate
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    public var elapsedSeconds: Double { clockSeconds(frameCorrection: 0) }

    fileprivate func clockSeconds(frameCorrection: Int) -> Double {
        let totalMinutes = hours * 60 + minutes
        let nominalFrame = (totalMinutes * 60 + seconds) * rate.nominalFramesPerSecond + frames
        let dropped = rate == .drop2997 ? 2 * (totalMinutes - totalMinutes / 10) : 0
        let ordinal = (nominalFrame - dropped + frameCorrection + rate.framesPerDay) % rate.framesPerDay
        return Double(ordinal) / rate.framesPerSecond
    }
}

public enum MIDITimeCodeMotion: Equatable, Sendable {
    case locate, forward, reverse

    fileprivate var frameCorrection: Int {
        switch self {
        case .locate: return 0
        case .forward: return 2
        case .reverse: return -2
        }
    }
}

public struct MIDITimeCodeEvent: Equatable, Sendable {
    public let position: MIDITimeCodePosition
    public let motion: MIDITimeCodeMotion

    /// The assembled label lags a running source by two video frames in the
    /// direction of travel. Locate messages are immediate and uncorrected.
    public var clockSeconds: Double { position.clockSeconds(frameCorrection: motion.frameCorrection) }
}

/// Bounded MIDI 1.0 byte-stream assembler. It accepts fragmented messages and
/// interleaved System Real-Time bytes. It emits only a complete contiguous
/// quarter-frame cycle or a precisely shaped universal full-frame locate.
public struct MIDITimeCodeDecoder: Sendable {
    public static let maximumBytesPerFeed = 4_096
    public static let fragmentTimeout = 0.2

    private var lastByteTime: Double?
    private var awaitingQuarterData = false
    private var sysEx: [UInt8]?
    private var sysExStartTime: Double?
    private var sysExOverflow = false
    private var lastQuarterTime: Double?
    private var parts = [UInt8](repeating: 0, count: 8)
    private var nextPart: Int?
    private var step = 1

    public init() {}

    public mutating func reset() { self = Self() }

    public mutating func feed(_ bytes: [UInt8], at hostTime: Double) -> [MIDITimeCodeEvent] {
        guard hostTime.isFinite, hostTime >= 0, bytes.count <= Self.maximumBytesPerFeed else {
            reset()
            return []
        }
        guard !bytes.isEmpty else { return [] }
        if let lastByteTime, hostTime < lastByteTime || hostTime - lastByteTime >= Self.fragmentTimeout { reset() }
        var events: [MIDITimeCodeEvent] = []
        for byte in bytes {
            if let event = consume(byte, at: hostTime) { events.append(event) }
        }
        lastByteTime = hostTime
        return events
    }

    private mutating func consume(_ byte: UInt8, at time: Double) -> MIDITimeCodeEvent? {
        if byte >= 0xF8 {
            if byte == 0xFF { reset() }
            return nil
        }
        if byte >= 0x80 {
            let expired = sysExStartTime.map { time - $0 >= Self.fragmentTimeout } ?? true
            let completed = byte == 0xF7 && !sysExOverflow && !expired ? sysEx : nil
            sysEx = byte == 0xF0 ? [] : nil
            sysExStartTime = byte == 0xF0 ? time : nil
            sysExOverflow = false
            awaitingQuarterData = byte == 0xF1
            guard let completed, let position = Self.fullFrame(completed) else { return nil }
            nextPart = nil
            return MIDITimeCodeEvent(position: position, motion: .locate)
        }
        if let sysexCount = sysEx?.count {
            if sysexCount < 8 { sysEx?.append(byte) }
            else { sysExOverflow = true }
            return nil
        }
        guard awaitingQuarterData else { return nil }
        awaitingQuarterData = false
        return quarterFrame(byte, at: time)
    }

    private mutating func quarterFrame(_ byte: UInt8, at time: Double) -> MIDITimeCodeEvent? {
        if let lastQuarterTime, time - lastQuarterTime >= Self.fragmentTimeout { nextPart = nil }
        lastQuarterTime = time
        let part = Int(byte >> 4)
        let value = byte & 0x0F
        guard value & ~Self.valueMasks[part] == 0 else {
            nextPart = nil
            return nil
        }
        if part != nextPart {
            nextPart = nil
            guard part == 0 || part == 7 else { return nil }
            step = part == 0 ? 1 : -1
            parts[part] = value
            nextPart = part + step
            return nil
        }
        parts[part] = value
        let next = part + step
        if (0...7).contains(next) {
            nextPart = next
            return nil
        }
        nextPart = nil
        guard let position = Self.position(hour: parts[6] | (parts[7] << 4),
                                          minute: parts[4] | (parts[5] << 4),
                                          second: parts[2] | (parts[3] << 4),
                                          frame: parts[0] | (parts[1] << 4)) else { return nil }
        return MIDITimeCodeEvent(position: position, motion: step == 1 ? .forward : .reverse)
    }

    private static func fullFrame(_ bytes: [UInt8]) -> MIDITimeCodePosition? {
        guard bytes.count == 8, bytes[0] == 0x7F, bytes[2] == 0x01, bytes[3] == 0x01 else { return nil }
        return position(hour: bytes[4], minute: bytes[5], second: bytes[6], frame: bytes[7])
    }

    private static let valueMasks: [UInt8] = [0x0F, 0x01, 0x0F, 0x03, 0x0F, 0x03, 0x0F, 0x07]

    private static func position(hour: UInt8, minute: UInt8, second: UInt8, frame: UInt8) -> MIDITimeCodePosition? {
        guard let rate = MIDITimeCodeRate(rawValue: hour >> 5) else { return nil }
        return MIDITimeCodePosition(rate: rate, hours: Int(hour & 0x1F), minutes: Int(minute),
                                    seconds: Int(second), frames: Int(frame))
    }
}
