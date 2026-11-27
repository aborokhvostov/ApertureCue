import Foundation

public struct ExternalShowClockPacket: Equatable, Sendable {
    public static let address = "/aperturecue/clock"

    public var source: String
    public var session: UUID
    public var sequence: Int32
    public var position: Double
    public var playing: Bool

    public init(source: String, session: UUID, sequence: Int32, position: Double, playing: Bool) {
        self.source = source
        self.session = session
        self.sequence = sequence
        self.position = position
        self.playing = playing
    }

    public init?(message: OSCMessage) {
        guard message.address == Self.address, message.arguments.count == 5,
              case let .string(source) = message.arguments[0],
              case let .string(sessionText) = message.arguments[1],
              let session = UUID(uuidString: sessionText),
              case let .int(sequence) = message.arguments[2],
              case let .float(position) = message.arguments[3],
              case let .bool(playing) = message.arguments[4] else { return nil }
        self.init(source: source, session: session, sequence: sequence, position: Double(position), playing: playing)
        guard isValid else { return nil }
    }

    public var isValid: Bool {
        Self.validSource(source) && sequence >= 0 && position.isFinite && (0...31_536_000).contains(position)
    }

    public static func validSource(_ source: String) -> Bool {
        (1...64).contains(source.utf8.count) && source.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
            $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    public func message() throws -> OSCMessage {
        guard isValid else { throw ProjectError.invalid("external clock packet has invalid source, sequence or position") }
        return OSCMessage(address: Self.address, arguments: [
            .string(source), .string(session.uuidString), .int(sequence), .float(Float(position)), .bool(playing)
        ])
    }
}

public enum ExternalShowClockState: Equatable, Sendable {
    case off, waiting, locked, held, lost
}

public enum ExternalShowClockAction: Equatable, Sendable {
    /// Scrub without crossing side effects and apply the sender's transport state.
    case align(position: Double, playing: Bool)
    /// Freeze at the last trusted host-time boundary and clear queued side effects.
    case freeze(hostTime: Double)
}

/// A single explicitly selected source owns the clock. Packets are ordered by
/// session and sequence. A new session can take ownership only after loss.
/// Monotonic input timestamps and a finite holdover make loss deterministic.
public struct ExternalShowClock: Sendable {
    public static let lossTimeout = 0.75
    public static let runningTolerance = 0.080
    public static let pausedTolerance = 0.001

    public private(set) var state: ExternalShowClockState = .off
    public private(set) var source: String?
    private var latest: ExternalShowClockPacket?
    private var latestHostTime = 0.0
    private var acquisition = false
    private var appliedPlaying: Bool?
    private var retired = Set<UUID>()
    private static let maximumRetiredSessions = 64

    public init() {}

    public mutating func arm(source: String) throws {
        guard ExternalShowClockPacket.validSource(source) else {
            throw ProjectError.invalid("clock source uses 1…64 ASCII letters, digits, hyphens, dots or underscores")
        }
        self = Self()
        self.source = source
        state = .waiting
    }

    public mutating func disarm() { self = Self() }

    @discardableResult
    public mutating func receive(_ packet: ExternalShowClockPacket, at hostTime: Double) -> Bool {
        guard packet.isValid, packet.source == source, hostTime.isFinite, hostTime >= 0 else { return false }
        if let latest {
            guard hostTime >= latestHostTime else { return false }
            if latest.session == packet.session {
                guard packet.sequence > latest.sequence else { return false }
            } else {
                guard (state == .lost || hostTime - latestHostTime >= Self.lossTimeout),
                      !retired.contains(packet.session), retired.count < Self.maximumRetiredSessions else { return false }
                retired.insert(latest.session)
                acquisition = true
            }
            if hostTime - latestHostTime >= Self.lossTimeout || state == .lost { acquisition = true }
        } else {
            acquisition = true
        }
        latest = packet
        latestHostTime = hostTime
        return true
    }

    public mutating func update(at hostTime: Double, localPosition: Double, localPlaying: Bool,
                                loop: ClosedRange<Double>? = nil) -> ExternalShowClockAction? {
        guard hostTime.isFinite, localPosition.isFinite, let latest, hostTime >= latestHostTime else { return nil }
        let age = hostTime - latestHostTime
        if age >= Self.lossTimeout {
            guard state != .lost else { return nil }
            let wasActive = state == .locked || state == .held
            state = .lost
            acquisition = true
            return wasActive ? .freeze(hostTime: latestHostTime + Self.lossTimeout) : nil
        }
        let senderChanged = appliedPlaying != latest.playing
        if !acquisition, !senderChanged, latest.playing, !localPlaying {
            // Pause markers and the local show boundary hold the playhead until
            // the sender explicitly stops/resumes or reacquires the session.
            state = .held
            return nil
        }
        let rawPosition = min(31_536_000, latest.position + (latest.playing ? age : 0))
        var estimatedPosition = rawPosition
        var phaseError = abs(rawPosition - localPosition)
        if let loop, loop.lowerBound.isFinite, loop.lowerBound >= 0,
           loop.upperBound.isFinite, loop.upperBound > loop.lowerBound {
            let length = loop.upperBound - loop.lowerBound
            if rawPosition >= loop.upperBound {
                estimatedPosition = loop.lowerBound + (rawPosition - loop.upperBound).truncatingRemainder(dividingBy: length)
                phaseError = abs(estimatedPosition - localPosition)
            }
            if latest.playing, localPlaying, loop.contains(estimatedPosition), loop.contains(localPosition) {
                // Both running positions straddle the wrap if their cyclic
                // difference is smaller. Keep the natural marker crossing.
                phaseError = min(phaseError, max(0, length - phaseError))
            }
        }
        let tolerance = latest.playing ? Self.runningTolerance : Self.pausedTolerance
        state = .locked
        defer {
            acquisition = false
            appliedPlaying = latest.playing
        }
        guard acquisition || senderChanged || localPlaying != latest.playing || phaseError > tolerance else { return nil }
        return .align(position: estimatedPosition, playing: latest.playing)
    }
}
