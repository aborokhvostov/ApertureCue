import Foundation

public enum ShowOSCValue: Codable, Equatable, Sendable {
    case integer(Int32), float(Float), string(String), boolean(Bool)

    var argument: OSCArgument {
        switch self {
        case .integer(let value): return .int(value)
        case .float(let value): return .float(value)
        case .string(let value): return .string(value)
        case .boolean(let value): return .bool(value)
        }
    }
}

public enum ShowMIDIKind: String, Codable, CaseIterable, Sendable {
    case noteOn, noteOff, controlChange

    var status: UInt8 {
        switch self {
        case .noteOn: return 0x90
        case .noteOff: return 0x80
        case .controlChange: return 0xB0
        }
    }
}

/// Each command has a bounded destination. MIDI uses the application's virtual
/// source and OSC uses a loopback UDP port selected in the document.
public enum ShowControlCommand: Codable, Equatable, Sendable {
    case osc(port: UInt16, address: String, value: ShowOSCValue?)
    case midi(kind: ShowMIDIKind, channel: Int, number: Int, value: Int)

    public func oscPacket() throws -> Data? {
        guard case let .osc(port, address, value) = self else { return nil }
        let legal = address.utf8.allSatisfy { byte in
            (33...126).contains(byte) && ![UInt8(35), 42, 44, 63, 91, 93, 123, 125].contains(byte)
        }
        guard port > 0, address.hasPrefix("/"), address.count > 1, address.utf8.count <= 256, legal else {
            throw ProjectError.invalid("OSC event requires a concrete ASCII address and port 1…65535")
        }
        if case .string(let value) = value, value.utf8.count > 256 {
            throw ProjectError.invalid("OSC string argument exceeds 256 bytes")
        }
        return try OSCCodec.encode(OSCMessage(address: address, arguments: value.map { [$0.argument] } ?? []))
    }

    public func midiBytes() throws -> [UInt8]? {
        guard case let .midi(kind, channel, number, value) = self else { return nil }
        guard (1...16).contains(channel), (0...127).contains(number), (0...127).contains(value) else {
            throw ProjectError.invalid("MIDI channel must be 1…16; number and value must be 0…127")
        }
        return [kind.status | UInt8(channel - 1), UInt8(number), UInt8(value)]
    }

    public func validate() throws {
        _ = try oscPacket()
        _ = try midiBytes()
    }
}

public struct ShowControlEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var time: Double
    public var command: ShowControlCommand

    public init(id: UUID = UUID(), time: Double, command: ShowControlCommand) {
        self.id = id
        self.time = time
        self.command = command
    }
}

public struct ShowControlTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var events: [ShowControlEvent]

    public static let maximumTracks = 64
    public static let maximumEvents = 4096

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, events: [ShowControlEvent] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.events = events
    }

    public static func validate(_ tracks: [Self], duration: Double) throws {
        guard duration.isFinite, duration > 0, tracks.count <= maximumTracks else {
            throw ProjectError.invalid("show controls require a finite duration and at most 64 tracks")
        }
        var ids = Set<UUID>()
        var eventIDs = Set<UUID>()
        for track in tracks {
            guard ids.insert(track.id).inserted, !track.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  track.name.utf8.count <= 256, track.events.count <= maximumEvents - eventIDs.count else {
                throw ProjectError.invalid("show control track name, duplicate identity or event limit is invalid")
            }
            for event in track.events {
                guard eventIDs.insert(event.id).inserted, event.time.isFinite, event.time > 0, event.time <= duration else {
                    throw ProjectError.invalid("show event needs a unique identity and a positive time within the timeline")
                }
                try event.command.validate()
            }
        }
    }

    /// Stable by document track order and event order at identical timestamps.
    public static func events(_ tracks: [Self]) -> [ShowControlEvent] {
        tracks.filter(\.enabled).flatMap(\.events).enumerated().sorted { lhs, rhs in
            lhs.element.time == rhs.element.time ? lhs.offset < rhs.offset : lhs.element.time < rhs.element.time
        }.map(\.element)
    }
}
