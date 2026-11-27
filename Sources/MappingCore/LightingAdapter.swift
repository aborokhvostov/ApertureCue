import Foundation

/// Buffered DMX-Pro output-only frame. A virtual COM port carries this message;
/// generating DMX break and periodic refresh belongs to the selected adapter.
public enum BufferedDMXPro {
    public static let channelCount = 512
    public static let packetByteCount = 518
    public static let blackout = Data([0x7E, 6, 1, 2, 0] + [UInt8](repeating: 0, count: channelCount) + [0xE7])

    public static func encode(_ channels: [UInt8]) throws -> Data {
        guard channels.count == channelCount else {
            throw ProtocolError.malformed("buffered DMX output requires one full 512-slot universe")
        }
        var data = Data([0x7E, 6, 1, 2, 0])
        data.append(contentsOf: channels)
        data.append(0xE7)
        return data
    }

    public static func inspect(_ frame: Data) throws -> [UInt8] {
        guard frame.count == packetByteCount, frame.prefix(5).elementsEqual([0x7E, 6, 1, 2, 0]), frame.last == 0xE7 else {
            throw ProtocolError.malformed("expected a complete buffered DMX output-only frame")
        }
        return Array(frame.dropFirst(5).dropLast())
    }
}

public enum LightingAdapterEncoding: Equatable, Sendable {
    case bufferedDMX
    /// A raw red, green, blue byte triplet for each consecutive pixel. This
    /// layout describes a payload for an optional clocked adapter or simulator.
    case spiRGB(firstAddress: Int, pixels: Int)
}

public struct LightingAdapterRoute: Equatable, Sendable {
    public let universe: Int
    public let encoding: LightingAdapterEncoding

    public init(universe: Int, encoding: LightingAdapterEncoding) throws {
        guard (0...63999).contains(universe) else { throw ProjectError.invalid("adapter universe must be 0…63999") }
        if case .spiRGB(let firstAddress, let pixels) = encoding {
            guard (1...512).contains(firstAddress), (1...170).contains(pixels), firstAddress - 1 + pixels * 3 <= 512 else {
                throw ProjectError.invalid("SPI RGB pixels must fit inside one universe")
            }
        }
        self.universe = universe
        self.encoding = encoding
    }

    public func packet(in universes: [Int: [UInt8]]) throws -> Data? {
        guard let channels = universes[universe] else { return nil }
        guard channels.count == 512 else { throw ProtocolError.malformed("adapter input must be one full 512-slot universe") }
        switch encoding {
        case .bufferedDMX: return try BufferedDMXPro.encode(channels)
        case .spiRGB(let address, let pixels):
            let first = address - 1
            return Data(channels[first..<(first + pixels * 3)])
        }
    }
}
