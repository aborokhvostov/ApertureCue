import Foundation

public enum ProtocolError: Error, LocalizedError, Equatable {
    case malformed(String)
    case unsupported(String)
    public var errorDescription: String? {
        switch self { case .malformed(let s): return "Malformed packet: \(s)"; case .unsupported(let s): return "Unsupported protocol feature: \(s)" }
    }
}

public enum OSCArgument: Equatable, Sendable {
    case int(Int32), float(Float), string(String), bool(Bool)
}
public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var arguments: [OSCArgument]
    public init(address: String, arguments: [OSCArgument] = []) { self.address=address; self.arguments=arguments }
}

/// OSC 1.0 messages and immediate bundles. Scheduled NTP timetags are explicitly rejected.
public enum OSCCodec {
    public static func encode(_ message: OSCMessage) throws -> Data {
        guard message.address.hasPrefix("/"), message.address.utf8.count <= 4096, message.arguments.count <= 256 else { throw ProtocolError.malformed("OSC address or argument count") }
        var bytes=try string(message.address), tags="," , arguments:[UInt8]=[]
        for argument in message.arguments {
            switch argument {
            case .int(let n): tags += "i"; arguments += be32(UInt32(bitPattern:n))
            case .float(let f):
                guard f.isFinite else { throw ProtocolError.malformed("non-finite OSC float") }
                tags += "f"; arguments += be32(f.bitPattern)
            case .string(let s): tags += "s"; arguments += try string(s)
            case .bool(let b): tags += b ? "T" : "F"
            }
        }
        bytes += try string(tags); bytes += arguments
        guard bytes.count <= 65504 else { throw ProtocolError.malformed("OSC packet exceeds UDP size") }
        return Data(bytes)
    }
    public static func encodeBundle(_ messages: [OSCMessage]) throws -> Data {
        guard messages.count <= 256 else { throw ProtocolError.malformed("too many OSC messages") }
        var result=Array("#bundle\0".utf8)+[0,0,0,0,0,0,0,1]
        for message in messages {
            let bytes=try encode(message)
            result += be32(UInt32(bytes.count)); result += bytes
        }
        guard result.count <= 65504 else { throw ProtocolError.malformed("OSC bundle exceeds UDP size") }
        return Data(result)
    }
    public static func decode(_ data: Data) throws -> [OSCMessage] {
        guard !data.isEmpty, data.count <= 65504, data.count % 4 == 0 else { throw ProtocolError.malformed("OSC size or alignment") }
        var count=0
        return try packet(Array(data),depth:0,count:&count)
    }
    private static func packet(_ bytes:[UInt8],depth:Int,count:inout Int) throws -> [OSCMessage] {
        guard depth <= 8 else { throw ProtocolError.malformed("OSC bundle nesting limit") }
        var cursor=0
        if bytes.starts(with:Array("#bundle\0".utf8)) {
            guard bytes.count >= 16 else { throw ProtocolError.malformed("truncated OSC bundle") }
            guard Array(bytes[8..<16]) == [0,0,0,0,0,0,0,1] else { throw ProtocolError.unsupported("scheduled OSC bundle timetag; only immediate (1) is supported") }
            cursor=16; var result:[OSCMessage]=[]
            while cursor < bytes.count {
                let length=Int(try read32(bytes,&cursor))
                guard length > 0, length % 4 == 0, length <= bytes.count-cursor else { throw ProtocolError.malformed("OSC bundle element length") }
                result += try packet(Array(bytes[cursor..<cursor+length]),depth:depth+1,count:&count)
                cursor += length
            }
            return result
        }
        count += 1
        guard count <= 256 else { throw ProtocolError.malformed("OSC bundle message count limit") }
        let address=try readString(bytes,&cursor)
        guard address.hasPrefix("/"), address.utf8.count <= 4096 else { throw ProtocolError.malformed("OSC address") }
        let tags=try readString(bytes,&cursor)
        guard tags.hasPrefix(","), tags.count <= 257 else { throw ProtocolError.malformed("OSC type tags") }
        var arguments:[OSCArgument]=[]
        for tag in tags.dropFirst() {
            switch tag {
            case "i": arguments.append(.int(Int32(bitPattern:try read32(bytes,&cursor))))
            case "f":
                let f=Float(bitPattern:try read32(bytes,&cursor))
                guard f.isFinite else { throw ProtocolError.malformed("non-finite OSC float") }
                arguments.append(.float(f))
            case "s": arguments.append(.string(try readString(bytes,&cursor)))
            case "T": arguments.append(.bool(true))
            case "F": arguments.append(.bool(false))
            default: throw ProtocolError.unsupported("OSC type tag \(tag)")
            }
        }
        guard cursor == bytes.count else { throw ProtocolError.malformed("OSC trailing arguments") }
        return [OSCMessage(address:address,arguments:arguments)]
    }
    private static func string(_ s:String) throws -> [UInt8] {
        let bytes=Array(s.utf8)
        guard bytes.count <= 32768, bytes.allSatisfy({ $0 > 0 && $0 < 128 }) else { throw ProtocolError.malformed("OSC 1.0 strings must be non-null ASCII") }
        return bytes + Array(repeating:0,count:4-(bytes.count%4))
    }
    private static func readString(_ bytes:[UInt8],_ cursor:inout Int) throws -> String {
        guard cursor < bytes.count, let terminator=bytes[cursor...].firstIndex(of:0), terminator-cursor <= 32768 else { throw ProtocolError.malformed("unterminated OSC string") }
        let end=terminator+1, padded=(end+3)/4*4
        guard padded <= bytes.count, bytes[end..<padded].allSatisfy({ $0 == 0 }), bytes[cursor..<terminator].allSatisfy({ $0 < 128 }) else { throw ProtocolError.malformed("OSC string padding or encoding") }
        let s=String(bytes:bytes[cursor..<terminator],encoding:.ascii)!
        cursor=padded; return s
    }
}

public struct ArtDMX: Equatable, Sendable {
    public var universe: Int
    public var sequence: UInt8
    public var physical: UInt8
    public var channels: [UInt8]
    public init(universe:Int,sequence:UInt8=0,physical:UInt8=0,channels:[UInt8]) {
        self.universe=universe; self.sequence=sequence; self.physical=physical; self.channels=channels
    }
}

/// ArtDmx codec, Art-Net 4 rev DP. Legacy port-address zero is decoded but is deprecated.
public enum ArtNetCodec {
    public static let port: UInt16 = 6454
    public static func encode(_ packet:ArtDMX) throws -> Data {
        guard (0...32767).contains(packet.universe), !packet.channels.isEmpty, packet.channels.count <= 512 else { throw ProtocolError.malformed("ArtDmx universe or channel count") }
        var channels=packet.channels
        if channels.count % 2 != 0 { channels.append(0) }
        var b=Array("Art-Net\0".utf8)+[0x00,0x50,0,14,packet.sequence,packet.physical,UInt8(packet.universe&255),UInt8(packet.universe>>8)]
        b += be16(UInt16(channels.count)); b += channels
        return Data(b)
    }
    public static func decode(_ data:Data) throws -> ArtDMX {
        let b=Array(data)
        guard b.count >= 20, b.count <= 65507, b.starts(with:Array("Art-Net\0".utf8)), b[8] == 0, b[9] == 0x50 else { throw ProtocolError.malformed("ArtDmx header") }
        guard UInt16(b[10])<<8 | UInt16(b[11]) >= 14 else { throw ProtocolError.unsupported("Art-Net protocol version below 14") }
        let universe=Int(b[14]) | Int(b[15])<<8, length=Int(b[16])<<8 | Int(b[17])
        guard universe <= 32767, (2...512).contains(length), length%2 == 0, b.count >= 18+length else { throw ProtocolError.malformed("ArtDmx payload length or universe") }
        // The specification requires ignoring trailing bytes to permit future extensions.
        return ArtDMX(universe:universe,sequence:b[12],physical:b[13],channels:Array(b[18..<18+length]))
    }
}

public struct SACNPacket: Equatable, Sendable {
    public var universe:Int
    public var sequence:UInt8
    public var priority:UInt8
    public var sourceName:String
    public var cid:UUID
    public var channels:[UInt8]
    public var options:UInt8
    public var synchronizationAddress:Int
    public init(universe:Int,sequence:UInt8=0,priority:UInt8=100,sourceName:String="ApertureCue",cid:UUID=UUID(),channels:[UInt8],options:UInt8=0,synchronizationAddress:Int=0) {
        self.universe=universe; self.sequence=sequence; self.priority=priority; self.sourceName=sourceName; self.cid=cid
        self.channels=channels; self.options=options; self.synchronizationAddress=synchronizationAddress
    }
}

/// ANSI E1.31-2018 data-packet codec, DMX start code zero. Discovery/sync packets are separate protocols.
public enum SACNCodec {
    public static let port: UInt16 = 5568
    public static func multicastAddress(universe:Int) throws -> String {
        guard (1...63999).contains(universe) else { throw ProtocolError.malformed("sACN universe") }
        return "239.255.\(universe>>8).\(universe&255)"
    }
    public static func encode(_ p:SACNPacket) throws -> Data {
        let name=Array(p.sourceName.utf8)
        guard (1...63999).contains(p.universe), p.priority <= 200, name.count <= 63, !name.contains(0), p.channels.count <= 512,
              p.options & 0x1f == 0, (0...63999).contains(p.synchronizationAddress) else { throw ProtocolError.malformed("sACN field range") }
        let length=126+p.channels.count
        var b:[UInt8]=[0,16,0,0]
        b += Array("ASC-E1.17\0\0\0".utf8)
        b += be16(UInt16(0x7000 | (length-16))); b += be32(4)
        var uuid=p.cid.uuid
        b += withUnsafeBytes(of:&uuid) { Array($0) }
        b += be16(UInt16(0x7000 | (length-38))); b += be32(2)
        b += name; b += Array(repeating:0,count:64-name.count)
        b += [p.priority]; b += be16(UInt16(p.synchronizationAddress)); b += [p.sequence,p.options]
        b += be16(UInt16(p.universe)); b += be16(UInt16(0x7000 | (length-115)))
        b += [2,0xa1,0,0,0,1]; b += be16(UInt16(p.channels.count+1)); b += [0]; b += p.channels
        return Data(b)
    }
    public static func decode(_ data:Data) throws -> SACNPacket {
        let b=Array(data)
        guard (126...638).contains(b.count), Array(b[0..<4]) == [0,16,0,0], Array(b[4..<16]) == Array("ASC-E1.17\0\0\0".utf8) else { throw ProtocolError.malformed("sACN preamble or size") }
        func u16(_ at:Int) -> Int { Int(b[at])<<8 | Int(b[at+1]) }
        func u32(_ at:Int) -> UInt32 { UInt32(b[at])<<24 | UInt32(b[at+1])<<16 | UInt32(b[at+2])<<8 | UInt32(b[at+3]) }
        guard u16(16) == (0x7000 | (b.count-16)), u16(38) == (0x7000 | (b.count-38)), u16(115) == (0x7000 | (b.count-115)) else { throw ProtocolError.malformed("sACN PDU flags or lengths") }
        guard u32(18) == 4, u32(40) == 2, b[117] == 2, b[118] == 0xa1, u16(119) == 0, u16(121) == 1 else { throw ProtocolError.unsupported("sACN vectors or property addressing") }
        guard u16(123) == b.count-125, b[125] == 0, b[108] <= 200, b[112] & 0x1f == 0,
              (1...63999).contains(u16(113)), (0...63999).contains(u16(109)) else { throw ProtocolError.malformed("sACN universe, property count, options, priority, or start code") }
        let nameBytes=Array(b[44..<108])
        guard let end=nameBytes.firstIndex(of:0), let name=String(bytes:nameBytes[0..<end],encoding:.utf8) else { throw ProtocolError.malformed("sACN source name") }
        let c=Array(b[22..<38])
        let cid=UUID(uuid:(c[0],c[1],c[2],c[3],c[4],c[5],c[6],c[7],c[8],c[9],c[10],c[11],c[12],c[13],c[14],c[15]))
        return SACNPacket(universe:u16(113),sequence:b[111],priority:b[108],sourceName:name,cid:cid,channels:Array(b[126...]),options:b[112],synchronizationAddress:u16(109))
    }
}

private func be16(_ n:UInt16) -> [UInt8] { [UInt8(n>>8),UInt8(n&255)] }
private func be32(_ n:UInt32) -> [UInt8] { [UInt8((n>>24)&255),UInt8((n>>16)&255),UInt8((n>>8)&255),UInt8(n&255)] }
private func read32(_ bytes:[UInt8],_ cursor:inout Int) throws -> UInt32 {
    guard cursor <= bytes.count-4 else { throw ProtocolError.malformed("truncated 32-bit value") }
    let n=UInt32(bytes[cursor])<<24 | UInt32(bytes[cursor+1])<<16 | UInt32(bytes[cursor+2])<<8 | UInt32(bytes[cursor+3])
    cursor += 4; return n
}

public struct RGBColor: Equatable, Sendable {
    public var r:Double, g:Double, b:Double
    public init(_ r:Double,_ g:Double,_ b:Double) { self.r=r; self.g=g; self.b=b }
}

public struct Fixture: Codable, Equatable, Identifiable, Sendable {
    public var id:UUID
    public var name:String
    public var universe:Int
    /// One-based DMX address. A fixture never wraps implicitly into another universe.
    public var address:Int
    public var points:[Point2]
    public var channelOrder:String
    public init(id:UUID=UUID(),name:String,universe:Int=1,address:Int=1,points:[Point2],channelOrder:String="RGB") {
        self.id=id; self.name=name; self.universe=universe; self.address=address; self.points=points; self.channelOrder=channelOrder
    }
}

public enum FixtureSampler {
    public static func validate(fixtures:[Fixture]) throws {
        guard fixtures.count <= 4096 else { throw ProjectError.invalid("too many fixtures") }
        var occupied:[Int:Set<Int>]=[:]
        guard Set(fixtures.map(\.id)).count == fixtures.count else { throw ProjectError.invalid("duplicate fixture IDs") }
        for fixture in fixtures {
            guard (1...32767).contains(fixture.universe), (1...512).contains(fixture.address), !fixture.points.isEmpty,
                  fixture.name.utf8.count <= 4096, fixture.points.count <= 170, ["RGB","GRB","RGBW"].contains(fixture.channelOrder),
                  fixture.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { throw ProjectError.invalid("fixture address, geometry or color order") }
            let stride=fixture.channelOrder.count
            guard fixture.address-1+fixture.points.count*stride <= 512 else { throw ProjectError.invalid("fixture crosses a universe boundary") }
            for address in (fixture.address-1)..<(fixture.address-1+fixture.points.count*stride) {
                guard occupied[fixture.universe,default:[]].insert(address).inserted else { throw ProjectError.invalid("overlapping fixture channel addresses") }
            }
        }
    }
    /// Samples normalized output positions into full universes. Validation precedes all callbacks.
    public static func sample(fixtures:[Fixture],sample:(Point2)->RGBColor) throws -> [Int:[UInt8]] {
        try validate(fixtures:fixtures)
        var result:[Int:[UInt8]]=[:]
        for fixture in fixtures {
            let stride=fixture.channelOrder.count
            if result[fixture.universe] == nil { result[fixture.universe]=Array(repeating:0,count:512) }
            for (index,point) in fixture.points.enumerated() {
                let rgb=sample(point)
                guard rgb.r.isFinite, rgb.g.isFinite, rgb.b.isFinite else { throw ProjectError.invalid("non-finite sampled color") }
                let r=min(1,max(0,rgb.r)), g=min(1,max(0,rgb.g)), b=min(1,max(0,rgb.b))
                let white=fixture.channelOrder == "RGBW" ? min(r,g,b) : 0
                let values:[Character:Double]=["R":r-white,"G":g-white,"B":b-white,"W":white]
                for (offset,channel) in fixture.channelOrder.enumerated() {
                    let address=fixture.address-1+index*stride+offset
                    result[fixture.universe]![address]=UInt8((values[channel]!*255).rounded())
                }
            }
        }
        return result
    }
}
