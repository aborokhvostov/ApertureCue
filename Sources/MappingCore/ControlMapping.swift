import Foundation

public enum MIDIMapKind: String, Codable, CaseIterable, Sendable {
    case note, cc7, cc14, pitchBend
}

public enum ControlInput: Codable, Equatable, Hashable, Sendable {
    case osc(String)
    case midi(kind: MIDIMapKind, channel: Int, number: Int)

    public static func isConcreteOSCPath(_ path: String) -> Bool {
        let bytes = path.utf8
        guard (2...256).contains(bytes.count), bytes.first == 47, bytes.last != 47 else { return false }
        let excluded: Set<UInt8> = [35, 42, 44, 63, 91, 93, 123, 125]
        var previous: UInt8 = 0
        for byte in bytes {
            guard (33...126).contains(byte), !excluded.contains(byte), byte != 47 || previous != 47 else { return false }
            previous = byte
        }
        return true
    }

    public func validate() throws {
        switch self {
        case let .osc(path):
            guard Self.isConcreteOSCPath(path) else { throw ProjectError.invalid("Enter a concrete ASCII OSC address") }
        case let .midi(kind, channel, number):
            let numbers: ClosedRange<Int>
            switch kind {
            case .note, .cc7: numbers = 0...127
            case .cc14: numbers = 0...31
            case .pitchBend: numbers = 0...0
            }
            guard (1...16).contains(channel), numbers.contains(number) else {
                throw ProjectError.invalid("Invalid MIDI channel or controller number")
            }
        }
    }
}

public enum ControlTarget: Codable, Equatable, Hashable, Sendable {
    case surface(UUID, parameter: String)
    case scene(UUID)
    case play, pause, togglePlayback, stop, seek, blackout

    var acceptsScalar: Bool {
        switch self {
        case .surface, .seek, .blackout: return true
        default: return false
        }
    }

    var supportsFeedback: Bool {
        switch self {
        case .surface, .blackout, .togglePlayback: return true
        default: return false
        }
    }
}

public struct ControlBinding: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var input: ControlInput
    public var target: ControlTarget
    public var inverted: Bool
    public var feedback: Bool

    public init(id: UUID = UUID(), input: ControlInput, target: ControlTarget,
                inverted: Bool = false, feedback: Bool = false) {
        self.id = id
        self.input = input
        self.target = target
        self.inverted = inverted
        self.feedback = feedback
    }
}

public struct ControlMap: Codable, Equatable, Sendable {
    public var bindings: [ControlBinding]

    public init(bindings: [ControlBinding] = []) { self.bindings = bindings }

    public func validate(surfaceIDs: Set<UUID>, cueIDs: Set<UUID>) throws {
        guard bindings.count <= 256,
              Set(bindings.map(\.id)).count == bindings.count,
              Set(bindings.map(\.input)).count == bindings.count else {
            throw ProjectError.invalid("Mappings must have unique inputs and IDs. Limit 256.")
        }
        for binding in bindings {
            try binding.input.validate()
            if case .osc(let path) = binding.input, ControlAddressSpace.isReserved(path) {
                throw ProjectError.invalid("This OSC path is reserved for directly addressing current show state")
            }
            switch binding.target {
            case let .surface(id, parameter):
                guard surfaceIDs.contains(id) else { throw ProjectError.invalid("Mapped surface no longer exists") }
                _ = try TimelineEngine.parameterRange(parameter)
            case let .scene(id):
                guard cueIDs.contains(id) else { throw ProjectError.invalid("Mapped scene no longer exists") }
            default: break
            }
            if binding.feedback {
                guard case .midi = binding.input, binding.target.supportsFeedback else {
                    throw ProjectError.invalid("Feedback requires MIDI and readable surface, blackout or playback state")
                }
            }
        }
    }

    public mutating func prune(surfaceIDs: Set<UUID>, cueIDs: Set<UUID>) {
        bindings.removeAll { binding in
            switch binding.target {
            case .surface(let id, _): return !surfaceIDs.contains(id)
            case .scene(let id): return !cueIDs.contains(id)
            default: return false
            }
        }
    }
}

public enum ControlInputValue: Equatable, Sendable {
    case pulse
    case normalized(Double)

    public init?(arguments: [OSCArgument]) {
        if arguments.isEmpty { self = .pulse; return }
        guard arguments.count == 1 else { return nil }
        switch arguments[0] {
        case let .float(value):
            guard value.isFinite else { return nil }
            self = .normalized(Double(value))
        case let .int(value): self = .normalized(Double(value))
        case let .bool(value): self = .normalized(value ? 1 : 0)
        default: return nil
        }
    }
}

public struct ControlIntent: Equatable, Sendable {
    public let target: ControlTarget
    public let value: Double?
    public let absoluteSeek: Bool

    public init(target: ControlTarget, value: Double?, absoluteSeek: Bool = false) {
        self.target = target
        self.value = value
        self.absoluteSeek = absoluteSeek
    }
}

/// One lookup per input. A held trigger only fires once until its value drops
/// below the release threshold. Explicit no-argument OSC messages are pulses.
public struct ControlRouter {
    private var definition = ControlMap()
    private var routes: [ControlInput: ControlBinding] = [:]
    private var held: Set<UUID> = []
    private var surfaceIDs: Set<UUID> = []
    private var cueIDs: Set<UUID> = []

    public init() {}

    public mutating func configure(_ map: ControlMap, surfaceIDs: Set<UUID>, cueIDs: Set<UUID>) throws {
        if map == definition && self.surfaceIDs == surfaceIDs && self.cueIDs == cueIDs { return }
        try map.validate(surfaceIDs: surfaceIDs, cueIDs: cueIDs)
        let unchanged = Set(map.bindings.filter { routes[$0.input] == $0 }.map(\.id))
        held.formIntersection(unchanged)
        routes = Dictionary(uniqueKeysWithValues: map.bindings.map { ($0.input, $0) })
        definition = map
        self.surfaceIDs = surfaceIDs
        self.cueIDs = cueIDs
    }

    public mutating func clearHeldInputs() { held.removeAll() }
    public func contains(_ input: ControlInput) -> Bool { routes[input] != nil }

    public mutating func route(_ input: ControlInput, value: ControlInputValue) -> ControlIntent? {
        guard let binding = routes[input] else { return nil }
        switch value {
        case .pulse:
            guard !binding.target.acceptsScalar else { return nil }
            return ControlIntent(target: binding.target, value: nil)
        case let .normalized(raw):
            guard raw.isFinite else { return nil }
            let bounded = min(1, max(0, raw))
            let position = binding.inverted ? 1 - bounded : bounded
            if binding.target.acceptsScalar { return ControlIntent(target: binding.target, value: position) }
            if position <= 0.25 { held.remove(binding.id) }
            guard position >= 0.5, held.insert(binding.id).inserted else { return nil }
            return ControlIntent(target: binding.target, value: nil)
        }
    }
}

public enum ControlAddressSpace {
    public static let surfaces = "/aperturecue/surfaces/"
    public static let time = "/aperturecue/transport/time"
    public static let playing = "/aperturecue/transport/playing"
    public static let blackout = "/aperturecue/blackout/value"

    public static func surface(_ id: UUID, _ parameter: String) -> String {
        surfaces + id.uuidString.lowercased() + "/" + parameter
    }

    public static func surfaceTarget(_ path: String) -> (id: UUID, parameter: String)? {
        guard path.hasPrefix(surfaces) else { return nil }
        let pieces = path.dropFirst(surfaces.count).split(separator: "/")
        guard pieces.count == 2, let id = UUID(uuidString: String(pieces[0])) else { return nil }
        let parameter = String(pieces[1])
        guard TimelineEngine.parameters.contains(parameter), path == surface(id, parameter) else { return nil }
        return (id, parameter)
    }

    public static func isReserved(_ path: String) -> Bool {
        path.hasPrefix(surfaces) || [time, playing, blackout].contains(path)
    }
}
