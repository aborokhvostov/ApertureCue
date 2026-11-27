import Foundation

public enum FixtureChannelSource: String, Codable, CaseIterable, Sendable {
    case red, green, blue, white, cyan, magenta, yellow, luma
    case pan, tilt, dimmer, constant, reserved

    public var hasManualValue: Bool {
        switch self {
        case .pan, .tilt, .dimmer, .constant: return true
        default: return false
        }
    }
}

public enum FixtureChannelEncoding: String, Codable, CaseIterable, Sendable {
    case eightBit, coarseFine, fineCoarse

    public var slotCount: Int { self == .eightBit ? 1 : 2 }
}

public struct FixtureSurfaceDrive: Codable, Equatable, Sendable {
    public var surfaceID: UUID
    public var parameter: String

    public init(surfaceID: UUID, parameter: String) {
        self.surfaceID = surfaceID
        self.parameter = parameter
    }
}

public struct FixtureChannel: Codable, Equatable, Sendable {
    public var name: String
    public var source: FixtureChannelSource
    public var encoding: FixtureChannelEncoding
    /// Normalized value for pan, tilt, dimmer and other manually controlled slots.
    public var value: Double
    public var drive: FixtureSurfaceDrive?

    public init(name: String, source: FixtureChannelSource, encoding: FixtureChannelEncoding = .eightBit,
                value: Double = 0, drive: FixtureSurfaceDrive? = nil) {
        self.name = name
        self.source = source
        self.encoding = encoding
        self.value = value
        self.drive = drive
    }
}

public struct FixtureDefinition: Codable, Equatable, Sendable {
    public static let maximumChannels = 64
    public var channels: [FixtureChannel]

    public init(channels: [FixtureChannel]) { self.channels = channels }
    public var slotCount: Int { channels.reduce(0) { $0 + $1.encoding.slotCount } }

    public func validate() throws {
        guard (1...Self.maximumChannels).contains(channels.count) else {
            throw ProjectError.invalid("fixture definition requires 1–\(Self.maximumChannels) channels")
        }
        var names = Set<String>()
        for channel in channels {
            guard !channel.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  channel.name.utf8.count <= 128, channel.name.rangeOfCharacter(from: .controlCharacters) == nil,
                  names.insert(channel.name).inserted else {
                throw ProjectError.invalid("fixture channel names must be nonempty, unique and at most 128 UTF-8 bytes")
            }
            guard (0...1).contains(channel.value) else {
                throw ProjectError.invalid("fixture channel \(channel.name) requires a normalized value from 0 to 1")
            }
            if let drive = channel.drive {
                guard channel.source.hasManualValue, (try? TimelineEngine.parameterRange(drive.parameter)) != nil else {
                    throw ProjectError.invalid("fixture channel \(channel.name) requires a manual role and a supported surface parameter for automation")
                }
            }
        }
    }
}

/// Full width and height of a normalized output-space box centered on each sample point.
public struct FixtureSampling: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct Fixture: Codable, Equatable, Identifiable, Sendable {
    public static let universeRange = 0...63999
    public var id: UUID
    public var name: String
    public var universe: Int
    /// One-based DMX address. A fixture never wraps implicitly into another universe.
    public var address: Int
    public var points: [Point2]
    public var channelOrder: String
    public var definition: FixtureDefinition?
    public var sampling: FixtureSampling?
    public var outputID: UUID?
    /// Zero-based positions in point order. Each skipped pixel reserves its full patch stride.
    public var skippedPixels: [Int]?

    public init(id: UUID = UUID(), name: String, universe: Int = 1, address: Int = 1, points: [Point2],
                channelOrder: String = "RGB", definition: FixtureDefinition? = nil, sampling: FixtureSampling? = nil,
                outputID: UUID? = nil, skippedPixels: [Int]? = nil) {
        self.id = id
        self.name = name
        self.universe = universe
        self.address = address
        self.points = points
        self.channelOrder = channelOrder
        self.definition = definition
        self.sampling = sampling
        self.outputID = outputID
        self.skippedPixels = skippedPixels
    }

    public var channelCountPerPixel: Int { definition?.slotCount ?? channelOrder.count }

    public var hasLightEngineExtensions: Bool {
        definition != nil || sampling != nil || outputID != nil || skippedPixels != nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, universe, address, points, channelOrder, definition, sampling, outputID, skippedPixels
    }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, legacy: false)
    }

    init(from decoder: Decoder, legacy: Bool) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        universe = try values.decode(Int.self, forKey: .universe)
        address = try values.decode(Int.self, forKey: .address)
        points = try values.decode([Point2].self, forKey: .points)
        channelOrder = try values.decode(String.self, forKey: .channelOrder)
        guard !legacy else { return }
        definition = try values.decodeIfPresent(FixtureDefinition.self, forKey: .definition)
        sampling = try values.decodeIfPresent(FixtureSampling.self, forKey: .sampling)
        outputID = try values.decodeIfPresent(UUID.self, forKey: .outputID)
        skippedPixels = try values.decodeIfPresent([Int].self, forKey: .skippedPixels)
    }
}

struct FixturePatchValidator {
    static let maximumFixtures = 4096
    static let slotsPerUniverse = 512
    private var identities = Set<UUID>()
    private var occupied: [Int: IndexSet] = [:]

    mutating func append(_ fixture: Fixture) throws {
        guard identities.count < Self.maximumFixtures else { throw ProjectError.invalid("too many fixtures") }
        guard !identities.contains(fixture.id) else { throw ProjectError.invalid("duplicate fixture IDs") }
        let maximumPoints = fixture.definition == nil ? 170 : Self.slotsPerUniverse
        guard Fixture.universeRange.contains(fixture.universe), (1...Self.slotsPerUniverse).contains(fixture.address),
              fixture.name.utf8.count <= 4096, (1...maximumPoints).contains(fixture.points.count),
              ["RGB", "GRB", "RGBW"].contains(fixture.channelOrder),
              fixture.points.allSatisfy(Self.isNormalized) else {
            throw ProjectError.invalid("fixture address, geometry or color order")
        }
        try fixture.definition?.validate()
        if let sampling = fixture.sampling {
            guard (0...1).contains(sampling.width), sampling.width > 0,
                  (0...1).contains(sampling.height), sampling.height > 0 else {
                throw ProjectError.invalid("fixture sample width and height must be greater than 0 and at most 1")
            }
        }
        if let skipped = fixture.skippedPixels {
            guard skipped.count <= fixture.points.count, Set(skipped).count == skipped.count,
                  skipped.allSatisfy(fixture.points.indices.contains) else {
                throw ProjectError.invalid("fixture skipped pixels must be unique zero-based indices in the layout")
            }
        }
        let start = fixture.address - 1
        let end = start + fixture.points.count * fixture.channelCountPerPixel
        guard end <= Self.slotsPerUniverse else { throw ProjectError.invalid("fixture crosses a universe boundary") }
        let addresses = start..<end
        guard occupied[fixture.universe]?.intersects(integersIn: addresses) != true else {
            throw ProjectError.invalid("overlapping fixture channel addresses in universe \(fixture.universe), slots \(fixture.address)–\(end)")
        }
        identities.insert(fixture.id)
        occupied[fixture.universe, default: IndexSet()].insert(integersIn: addresses)
    }

    static func isNormalized(_ point: Point2) -> Bool {
        (0...1).contains(point.x) && (0...1).contains(point.y)
    }
}

public enum FixtureSampler {
    public static func validate(fixtures: [Fixture]) throws {
        guard fixtures.count <= FixturePatchValidator.maximumFixtures else { throw ProjectError.invalid("too many fixtures") }
        var patch = FixturePatchValidator()
        for fixture in fixtures {
            do {
                try patch.append(fixture)
            } catch ProjectError.invalid(let reason) {
                throw ProjectError.invalid("fixture \(fixture.name): \(reason)")
            }
        }
    }

    /// Validates and compiles an immutable snapshot of a fixture patch for repeated frame sampling.
    public static func makePlan(fixtures: [Fixture]) throws -> FixturePatchPlan {
        try validate(fixtures: fixtures)
        return FixturePatchPlan(fixtures: fixtures)
    }

    public static func sample(fixtures: [Fixture], sample: (Point2) -> RGBColor) throws -> [Int: [UInt8]] {
        try self.sample(fixtures: fixtures, using: { _, point in sample(point) })
    }

    /// The source callback receives the fixture's output route and sampling footprint.
    public static func sample(fixtures: [Fixture], overrides: [UUID: [String: Double]] = [:],
                              using sample: (Fixture, Point2) -> RGBColor) throws -> [Int: [UInt8]] {
        try makePlan(fixtures: fixtures).sample(overrides: overrides, using: sample)
    }
}

public struct FixturePatchPlan: Sendable {
    private struct PatchedFixture: Sendable {
        let fixture: Fixture
        let channels: [FixtureChannel]
        let stride: Int
        let extractsWhite: Bool
        let skippedPixels: Set<Int>

        private static let red = FixtureChannel(name: "Red", source: .red)
        private static let green = FixtureChannel(name: "Green", source: .green)
        private static let blue = FixtureChannel(name: "Blue", source: .blue)
        private static let white = FixtureChannel(name: "White", source: .white)

        init(_ fixture: Fixture) {
            self.fixture = fixture
            if let definition = fixture.definition {
                channels = definition.channels
            } else {
                switch fixture.channelOrder {
                case "GRB": channels = [Self.green, Self.red, Self.blue]
                case "RGBW": channels = [Self.red, Self.green, Self.blue, Self.white]
                default: channels = [Self.red, Self.green, Self.blue]
                }
            }
            stride = fixture.channelCountPerPixel
            extractsWhite = channels.contains { $0.source == .white }
            skippedPixels = Set(fixture.skippedPixels ?? [])
        }
    }

    private let patch: [PatchedFixture]
    private let manualChannels: [UUID: Set<String>]

    fileprivate init(fixtures: [Fixture]) {
        patch = fixtures.map(PatchedFixture.init)
        manualChannels = Dictionary(uniqueKeysWithValues: patch.map {
            ($0.fixture.id, Set($0.channels.filter { $0.source.hasManualValue }.map(\.name)))
        })
    }

    /// Overrides are normalized values keyed by fixture UUID and manual channel name for the current frame.
    /// Validation precedes callbacks. Skipped slots emit zero without sampling.
    public func sample(overrides: [UUID: [String: Double]] = [:],
                       using sample: (Fixture, Point2) -> RGBColor) throws -> [Int: [UInt8]] {
        for (id, values) in overrides {
            guard let supported = manualChannels[id],
                  values.allSatisfy({ supported.contains($0.key) && (0...1).contains($0.value) }) else {
                throw ProjectError.invalid("fixture overrides require known manual channels and normalized values")
            }
        }

        var result: [Int: [UInt8]] = [:]
        for entry in patch {
            let levels = overrides[entry.fixture.id] ?? [:]
            try encode(entry, overrides: levels, using: sample,
                       into: &result[entry.fixture.universe, default: Array(repeating: 0, count: FixturePatchValidator.slotsPerUniverse)])
        }
        return result
    }

    private func encode(_ entry: PatchedFixture, overrides: [String: Double],
                        using sample: (Fixture, Point2) -> RGBColor, into slots: inout [UInt8]) throws {
        for (index, point) in entry.fixture.points.enumerated() where !entry.skippedPixels.contains(index) {
            let rgb = sample(entry.fixture, point)
            guard rgb.r.isFinite, rgb.g.isFinite, rgb.b.isFinite else {
                throw ProjectError.invalid("non-finite sampled color")
            }
            let r = min(1, max(0, rgb.r))
            let g = min(1, max(0, rgb.g))
            let b = min(1, max(0, rgb.b))
            let white = entry.extractsWhite ? min(r, g, b) : 0
            var address = entry.fixture.address - 1 + index * entry.stride
            for channel in entry.channels {
                let level: Double
                switch channel.source {
                case .red: level = r - white
                case .green: level = g - white
                case .blue: level = b - white
                case .white: level = white
                case .cyan: level = 1 - r
                case .magenta: level = 1 - g
                case .yellow: level = 1 - b
                case .luma: level = min(1, 0.2126 * r + 0.7152 * g + 0.0722 * b)
                case .pan, .tilt, .dimmer, .constant: level = overrides[channel.name] ?? channel.value
                case .reserved: level = 0
                }
                switch channel.encoding {
                case .eightBit:
                    slots[address] = UInt8((level * 255).rounded())
                case .coarseFine, .fineCoarse:
                    let value = UInt16((level * 65535).rounded())
                    let coarse = UInt8(value >> 8)
                    let fine = UInt8(truncatingIfNeeded: value)
                    slots[address] = channel.encoding == .coarseFine ? coarse : fine
                    slots[address + 1] = channel.encoding == .coarseFine ? fine : coarse
                }
                address += channel.encoding.slotCount
            }
        }
    }
}
