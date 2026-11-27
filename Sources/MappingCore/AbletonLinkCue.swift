import Foundation

/// A read-only observation from the optional Link helper. macOS processes
/// sample the same monotonic clock. Beat numbers are local to the Link peer.
public struct AbletonLinkObservation: Codable, Equatable, Sendable {
    public let version: Int
    public let sequence: UInt64
    public let hostMicros: UInt64
    public let peers: Int
    public let tempo: Double
    public let beat: Double
    public let phase: Double

    public init(version: Int = 1, sequence: UInt64, hostMicros: UInt64, peers: Int, tempo: Double, beat: Double, phase: Double) {
        self.version = version
        self.sequence = sequence
        self.hostMicros = hostMicros
        self.peers = peers
        self.tempo = tempo
        self.beat = beat
        self.phase = phase
    }

    public var isValid: Bool {
        guard version == 1, sequence > 0, hostMicros > 0, (0...4096).contains(peers),
              (1...1000).contains(tempo), (-1e9...1e9).contains(beat), (0..<AbletonLinkCueQueue.quantum).contains(phase) else { return false }
        let bar = (beat - phase) / AbletonLinkCueQueue.quantum
        return abs(bar - bar.rounded()) <= 0.000_1
    }
}

public enum AbletonLinkCueUpdate: Equatable, Sendable {
    case recall(UUID)
    case signalLost
    case clockMoved
    case boundaryMissed
}

/// One pending local cue. A scene launches on a confirmed crossing from fresh,
/// continuous Link observations. Acquisition and re-acquisition never replay it.
public struct AbletonLinkCueQueue: Sendable {
    public static let quantum = 4.0
    public static let maximumSampleAge: UInt64 = 250_000
    private static let maximumLaunchDelay = 0.15
    private static let beatDeviation = 0.10

    public private(set) var latest: AbletonLinkObservation?
    public private(set) var pendingCue: UUID?
    private var boundaryBeat: Double?
    private var lastAccepted: AbletonLinkObservation?

    public init() {}

    public mutating func cancel() {
        pendingCue = nil
        boundaryBeat = nil
    }

    @discardableResult public mutating func enqueue(_ cue: UUID, now: UInt64) throws -> Double {
        guard let latest, latest.peers > 0, Self.fresh(latest, at: now) else {
            throw ProjectError.invalid("wait for a live Link peer before lining up a cue")
        }
        let age = Double(now - latest.hostMicros) / 1_000_000
        let localBeat = latest.beat + age * latest.tempo / 60
        let bar = latest.beat - latest.phase
        let target = bar + (floor((localBeat - bar) / Self.quantum) + 1) * Self.quantum
        pendingCue = cue
        boundaryBeat = target
        return target
    }

    public mutating func observe(_ observation: AbletonLinkObservation?, now: UInt64) -> AbletonLinkCueUpdate? {
        guard let observation else {
            guard let latest, !Self.fresh(latest, at: now) else { return nil }
            self.latest = nil
            return cancelPending(with: .signalLost)
        }
        guard observation.isValid, Self.fresh(observation, at: now) else {
            latest = nil
            return cancelPending(with: .signalLost)
        }
        let previous = lastAccepted
        if previous == observation { return nil }
        if let previous, observation.sequence <= previous.sequence || observation.hostMicros <= previous.hostMicros {
            latest = nil
            return cancelPending(with: .clockMoved)
        }
        lastAccepted = observation
        latest = observation
        guard observation.peers > 0 else { return cancelPending(with: .signalLost) }
        guard let previous else { return nil }
        let micros = observation.hostMicros - previous.hostMicros
        guard micros <= Self.maximumSampleAge else {
            latest = nil
            return cancelPending(with: .signalLost)
        }
        let interval = Double(micros) / 1_000_000 / 60
        let difference = observation.beat - previous.beat
        let minimum = min(observation.tempo, previous.tempo) * interval - Self.beatDeviation
        let maximum = max(observation.tempo, previous.tempo) * interval + Self.beatDeviation
        guard (minimum...maximum).contains(difference) else {
            latest = nil
            return cancelPending(with: .clockMoved)
        }
        guard let cue = pendingCue, let boundaryBeat, observation.beat >= boundaryBeat else { return nil }
        cancel()
        let observationAge = Double(now - observation.hostMicros) / 1_000_000
        let pastBoundary = (observation.beat - boundaryBeat) * 60 / observation.tempo
        return observationAge + pastBoundary <= Self.maximumLaunchDelay ? .recall(cue) : .boundaryMissed
    }

    private static func fresh(_ observation: AbletonLinkObservation, at now: UInt64) -> Bool {
        now >= observation.hostMicros && now - observation.hostMicros <= maximumSampleAge
    }

    private mutating func cancelPending(with update: AbletonLinkCueUpdate) -> AbletonLinkCueUpdate? {
        guard pendingCue != nil else { return nil }
        cancel()
        return update
    }
}
