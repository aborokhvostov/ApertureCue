import Foundation

public struct ArtPollReply: Equatable, Sendable {
    public let advertisedAddress: String
    public let bindingAddress: String?
    public let bindingIndex: UInt8
    public let shortName: String
    public let longName: String
    public let inputPortAddresses: [Int]
    public let outputPortAddresses: [Int]
    public let refreshRateHz: Int

    public var subscriptions: Set<Int> { Set(inputPortAddresses + outputPortAddresses) }
}

/// Art-Net 4 rev 1.4dp targeted polling and read-only reply inspection.
public enum ArtNetDiscoveryCodec {
    private static let signature = Array("Art-Net\0".utf8)
    public static func encodeTargetedPoll(_ addresses: ClosedRange<Int>) throws -> Data {
        guard (0...32767).contains(addresses.lowerBound), (0...32767).contains(addresses.upperBound) else {
            throw ProtocolError.malformed("ArtPoll target range")
        }
        let top = addresses.upperBound
        let bottom = addresses.lowerBound
        // Optional manufacturer and OEM fields are omitted. The flags enable
        // targeted mode and disable VLC, with no unsolicited reports requested.
        return Data(signature + [0, 0x20, 0, 14, 0x30, 0,
                                 UInt8(top >> 8), UInt8(top & 255),
                                 UInt8(bottom >> 8), UInt8(bottom & 255)])
    }

    public static func decodePoll(_ data: Data) throws -> ClosedRange<Int>? {
        let bytes = try payload(data, opcode: 0x20, minimum: 14)
        guard readUInt16(bytes, at: 10) >= 14 else { throw ProtocolError.unsupported("ArtPoll protocol version") }
        guard bytes[12] & 0x20 != 0 else { return nil }
        // Receivers accept the older 14-byte minimum and zero-fill omissions.
        let top = readUInt16(bytes, at: 14)
        let bottom = readUInt16(bytes, at: 16)
        guard top <= 32767, bottom <= top else { throw ProtocolError.malformed("ArtPoll target range") }
        return bottom...top
    }

    public static func decodeReply(_ data: Data) throws -> ArtPollReply {
        let bytes = try payload(data, opcode: 0x21, minimum: 207)
        guard bytes[14] == 0x36, bytes[15] == 0x19, bytes[18] < 128, bytes[19] < 16 else {
            throw ProtocolError.malformed("ArtPollReply port, net or subnet")
        }
        let ports = readUInt16(bytes, at: 172)
        guard ports <= 4 else { throw ProtocolError.unsupported("ArtPollReply reports more than four ports in one binding") }
        let base = Int(bytes[18]) << 8 | Int(bytes[19]) << 4
        var inputs: [Int] = []
        var outputs: [Int] = []
        for port in 0..<ports {
            let kind = bytes[174 + port]
            // This subset uses DMX512 ports. Other media are visible by node
            // identity and do not contribute subscriptions.
            guard kind & 0x3f == 0 else { continue }
            if kind & 0x40 != 0 { inputs.append(base | Int(bytes[186 + port] & 0x0f)) }
            if kind & 0x80 != 0 { outputs.append(base | Int(bytes[190 + port] & 0x0f)) }
        }
        let advertised = ipv4(bytes[10..<14])
        guard advertised != "0.0.0.0" else { throw ProtocolError.malformed("ArtPollReply has no node address") }
        let binding = ipv4(bytes[207..<211])
        return ArtPollReply(
            advertisedAddress: advertised,
            bindingAddress: binding == "0.0.0.0" ? nil : binding,
            bindingIndex: bytes[211],
            shortName: text(bytes[26..<44]),
            longName: text(bytes[44..<108]),
            inputPortAddresses: inputs,
            outputPortAddresses: outputs,
            refreshRateHz: max(44, readUInt16(bytes, at: 226))
        )
    }

    private static func payload(_ data: Data, opcode: UInt8, minimum: Int) throws -> [UInt8] {
        guard (minimum...65507).contains(data.count) else { throw ProtocolError.malformed("Art-Net discovery packet length") }
        var bytes = Array(data.prefix(239))
        guard bytes.starts(with: signature), bytes[8] == 0, bytes[9] == opcode else {
            throw ProtocolError.malformed("Art-Net discovery header")
        }
        bytes += Array(repeating: 0, count: 239 - bytes.count)
        return bytes
    }

    private static func readUInt16(_ bytes: [UInt8], at index: Int) -> Int {
        Int(bytes[index]) << 8 | Int(bytes[index + 1])
    }

    private static func ipv4(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map(String.init).joined(separator: ".")
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        // Remove terminal controls from device labels before displaying them.
        let clean = bytes.prefix { $0 != 0 }.map { (32...126).contains($0) ? $0 : 0x3f }
        return String(decoding: clean, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

public struct SACNSynchronization: Equatable, Sendable {
    public let address: Int
    public let sequence: UInt8
    public let cid: UUID

    public init(address: Int, sequence: UInt8, cid: UUID) {
        self.address = address
        self.sequence = sequence
        self.cid = cid
    }
}

/// IPv4 synchronization framing paired with the existing start-code-zero data codec.
public enum SACNSynchronizationCodec {
    private static let identifier = Array("ASC-E1.17\0\0\0".utf8)

    public static func encode(_ packet: SACNSynchronization) throws -> Data {
        guard (1...63999).contains(packet.address) else { throw ProtocolError.malformed("sACN sync universe") }
        var bytes: [UInt8] = [0, 16, 0, 0]
        bytes += identifier
        bytes += [0x70, 33, 0, 0, 0, 8] // Extended Root Layer, 49−16 bytes.
        var uuid = packet.cid.uuid
        bytes += withUnsafeBytes(of: &uuid) { Array($0) }
        bytes += [0x70, 11, 0, 0, 0, 1, packet.sequence,
                  UInt8(packet.address >> 8), UInt8(packet.address & 255), 0, 0]
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> SACNSynchronization {
        guard data.count == 49 else { throw ProtocolError.malformed("sACN sync packet length") }
        let bytes = Array(data)
        guard Array(bytes[0..<4]) == [0, 16, 0, 0], Array(bytes[4..<16]) == identifier,
              Array(bytes[16..<22]) == [0x70, 33, 0, 0, 0, 8],
              Array(bytes[38..<44]) == [0x70, 11, 0, 0, 0, 1] else {
            throw ProtocolError.malformed("sACN sync layers")
        }
        let address = Int(bytes[45]) << 8 | Int(bytes[46])
        guard (1...63999).contains(address) else { throw ProtocolError.malformed("sACN sync universe") }
        let id = Array(bytes[22..<38])
        let cid = UUID(uuid: (id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7],
                              id[8], id[9], id[10], id[11], id[12], id[13], id[14], id[15]))
        return SACNSynchronization(address: address, sequence: bytes[44], cid: cid)
    }
}
