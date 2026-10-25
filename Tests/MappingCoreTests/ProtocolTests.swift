import XCTest
import Foundation
@testable import MappingCore

final class ProtocolTests: XCTestCase {
    func testOSCOfficialGoldenMessageAndTypes() throws {
        // OSC 1.0 byte order: address padded, type tags padded, big-endian int/float.
        let message=OSCMessage(address:"/test",arguments:[.int(-1),.float(0.5),.string("abc"),.bool(true),.bool(false)])
        let encoded=try OSCCodec.encode(message)
        XCTAssertEqual(Array(encoded),[47,116,101,115,116,0,0,0,44,105,102,115,84,70,0,0,255,255,255,255,63,0,0,0,97,98,99,0])
        XCTAssertEqual(try OSCCodec.decode(encoded),[message])
        XCTAssertEqual(try OSCCodec.decode(OSCCodec.encode(OSCMessage(address:"/empty"))),[OSCMessage(address:"/empty")])
    }
    func testOSCImmediateBundlesAndMalformedInput() throws {
        let messages=[OSCMessage(address:"/play"),OSCMessage(address:"/seek",arguments:[.float(1.25)])]
        let bundle=try OSCCodec.encodeBundle(messages)
        XCTAssertEqual(try OSCCodec.decode(bundle),messages)
        var scheduled=Array(bundle); scheduled[15]=2
        XCTAssertThrowsError(try OSCCodec.decode(Data(scheduled)))
        var invalidPadding=Array(try OSCCodec.encode(OSCMessage(address:"/a"))); invalidPadding[3]=1
        XCTAssertThrowsError(try OSCCodec.decode(Data(invalidPadding)))
        XCTAssertThrowsError(try OSCCodec.decode(Data([47,97,0,0,44,105,0,0])))
        XCTAssertThrowsError(try OSCCodec.encode(OSCMessage(address:"no slash")))
        XCTAssertThrowsError(try OSCCodec.encode(OSCMessage(address:"/a",arguments:[.string("a\0b")])))
        XCTAssertThrowsError(try OSCCodec.encode(OSCMessage(address:"/a",arguments:[.float(.infinity)])))
        var unknown=Array(try OSCCodec.encode(OSCMessage(address:"/a"))); unknown[5]=98
        XCTAssertThrowsError(try OSCCodec.decode(Data(unknown)))
    }
    func testOSCTruncationsAndRecursionAreBounded() throws {
        let encoded=try OSCCodec.encode(OSCMessage(address:"/address",arguments:[.int(1),.string("payload")]))
        for length in 0..<encoded.count { XCTAssertThrowsError(try OSCCodec.decode(encoded.prefix(length))) }
        var nested=try OSCCodec.encode(OSCMessage(address:"/a"))
        for _ in 0..<10 {
            let n=UInt32(nested.count)
            nested=Data(Array("#bundle\0".utf8)+[0,0,0,0,0,0,0,1,UInt8(n>>24),UInt8((n>>16)&255),UInt8((n>>8)&255),UInt8(n&255)])+nested
        }
        XCTAssertThrowsError(try OSCCodec.decode(nested))
    }
    func testArtDMXGoldenPacketAndAddressBounds() throws {
        let p=ArtDMX(universe:0x1234,sequence:7,channels:[255,128,0])
        let d=try ArtNetCodec.encode(p)
        XCTAssertEqual(Array(d),[65,114,116,45,78,101,116,0,0,80,0,14,7,0,0x34,0x12,0,4,255,128,0,0])
        let result=try ArtNetCodec.decode(d)
        XCTAssertEqual(result.universe,p.universe); XCTAssertEqual(result.sequence,p.sequence); XCTAssertEqual(result.channels,[255,128,0,0])
        XCTAssertThrowsError(try ArtNetCodec.encode(ArtDMX(universe:32768,channels:[1,2])))
        XCTAssertThrowsError(try ArtNetCodec.encode(ArtDMX(universe:-1,channels:[1,2])))
        XCTAssertThrowsError(try ArtNetCodec.encode(ArtDMX(universe:0,channels:[])))
        var b=Array(d); b[17]=3; XCTAssertThrowsError(try ArtNetCodec.decode(Data(b)))
        b=Array(d); b[15]=128; XCTAssertThrowsError(try ArtNetCodec.decode(Data(b)))
        XCTAssertEqual(try ArtNetCodec.decode(d+Data([9,9])).channels,result.channels)
        for length in 0..<d.count { XCTAssertThrowsError(try ArtNetCodec.decode(d.prefix(length))) }
    }
    func testSACNFieldOffsetsLengthsAndRoundTrip() throws {
        let cid=UUID(uuidString:"00112233-4455-6677-8899-AABBCCDDEEFF")!
        let p=SACNPacket(universe:63999,sequence:255,priority:200,sourceName:"Test source",cid:cid,channels:Array(repeating:42,count:512),options:0x80)
        let d=try SACNCodec.encode(p), b=Array(d)
        XCTAssertEqual(d.count,638)
        XCTAssertEqual(Array(b[16..<18]),[0x72,0x6e]) // root: 622 bytes
        XCTAssertEqual(Array(b[38..<40]),[0x72,0x58]) // framing: 600 bytes
        XCTAssertEqual(Array(b[115..<117]),[0x72,0x0b]) // DMP: 523 bytes
        XCTAssertEqual(Array(b[22..<38]),[0,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255])
        XCTAssertEqual(Array(b[123..<126]),[2,1,0])
        XCTAssertEqual(try SACNCodec.decode(d),p)
        XCTAssertEqual(try SACNCodec.multicastAddress(universe:257),"239.255.1.1")
        var corrupt=b; corrupt[17] ^= 1; XCTAssertThrowsError(try SACNCodec.decode(Data(corrupt)))
        corrupt=b; corrupt[125]=1; XCTAssertThrowsError(try SACNCodec.decode(Data(corrupt)))
        corrupt=b; corrupt[114]=0; corrupt[113]=0; XCTAssertThrowsError(try SACNCodec.decode(Data(corrupt)))
        XCTAssertThrowsError(try SACNCodec.encode(SACNPacket(universe:0,channels:[1])))
        XCTAssertThrowsError(try SACNCodec.encode(SACNPacket(universe:1,priority:201,channels:[1])))
        XCTAssertThrowsError(try SACNCodec.encode(SACNPacket(universe:1,sourceName:String(repeating:"a",count:64),channels:[1])))
        for length in 0..<d.count { XCTAssertThrowsError(try SACNCodec.decode(d.prefix(length))) }
    }
    func testFixtureSamplingOrderWhiteExtractionAndAddressing() throws {
        let rgb=Fixture(name:"RGB",universe:1,address:1,points:[Point2(0,0)],channelOrder:"RGB")
        let grb=Fixture(name:"GRB",universe:1,address:4,points:[Point2(1,0)],channelOrder:"GRB")
        let rgbw=Fixture(name:"RGBW",universe:2,address:509,points:[Point2(0,1)],channelOrder:"RGBW")
        let universes=try FixtureSampler.sample(fixtures:[rgb,grb,rgbw]) { point in
            if point.y == 1 { return RGBColor(1,0.5,0.25) }
            return RGBColor(1,0.5,0)
        }
        XCTAssertEqual(universes[1]!.count,512); XCTAssertEqual(Array(universes[1]![0..<6]),[255,128,0,128,255,0])
        XCTAssertEqual(Array(universes[2]![508..<512]),[191,64,0,64])
        XCTAssertThrowsError(try FixtureSampler.sample(fixtures:[rgb,rgb]) { _ in RGBColor(1,1,1) })
        let overlap=Fixture(name:"Overlap",address:2,points:[Point2(0,0)])
        XCTAssertThrowsError(try FixtureSampler.sample(fixtures:[rgb,overlap]) { _ in RGBColor(1,1,1) })
        let overflow=Fixture(name:"Overflow",address:511,points:[Point2(0,0)])
        XCTAssertThrowsError(try FixtureSampler.sample(fixtures:[overflow]) { _ in RGBColor(1,1,1) })
        let invalid=Fixture(name:"Outside",points:[Point2(2,0)])
        XCTAssertThrowsError(try FixtureSampler.sample(fixtures:[invalid]) { _ in RGBColor(1,1,1) })
    }
}
