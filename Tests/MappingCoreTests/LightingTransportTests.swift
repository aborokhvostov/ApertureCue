import Foundation
import XCTest
@testable import MappingCore

final class LightingTransportTests: XCTestCase {
    func testTargetedArtPollGoldenBytesAndLegacyLength() throws {
        let request = try ArtNetDiscoveryCodec.encodeTargetedPoll(0x0123...0x7f45)
        let prefix = Array("Art-Net\0".utf8)
        XCTAssertEqual(Array(request), prefix + [0, 0x20, 0, 14, 0x30, 0, 0x7f, 0x45, 0x01, 0x23])
        XCTAssertEqual(try ArtNetDiscoveryCodec.decodePoll(request), 0x0123...0x7f45)
        let legacy = Data(prefix + [0, 0x20, 0, 14, 0, 0])
        XCTAssertNil(try ArtNetDiscoveryCodec.decodePoll(legacy))
        XCTAssertThrowsError(try ArtNetDiscoveryCodec.decodePoll(legacy.dropLast()))
        XCTAssertThrowsError(try ArtNetDiscoveryCodec.encodeTargetedPoll(-1...1))
        XCTAssertThrowsError(try ArtNetDiscoveryCodec.encodeTargetedPoll(32767...32768))
        var wrongVersion = Array(request)
        wrongVersion[11] = 13
        XCTAssertThrowsError(try ArtNetDiscoveryCodec.decodePoll(Data(wrongVersion)))
    }

    func testArtPollReplyBindingsPortsAndBounds() throws {
        var bytes = [UInt8](repeating: 0, count: 239)
        bytes.replaceSubrange(0..<10, with: Array("Art-Net\0".utf8) + [0, 0x21])
        bytes.replaceSubrange(10..<16, with: [127, 0, 0, 1, 0x36, 0x19])
        bytes[18] = 2
        bytes[19] = 3
        bytes.replaceSubrange(26..<30, with: [76, 69, 68, 1])
        bytes[173] = 2
        bytes[174] = 0xc0
        bytes[175] = 0x81
        bytes[186] = 0xf1
        bytes[190] = 2
        bytes[191] = 4
        bytes.replaceSubrange(207..<212, with: [127, 0, 0, 1, 3])
        bytes[226] = 1
        bytes[227] = 0x2c
        let node = try ArtNetDiscoveryCodec.decodeReply(Data(bytes))
        XCTAssertEqual(node.shortName, "LED?")
        XCTAssertEqual(node.bindingAddress, "127.0.0.1")
        XCTAssertEqual(node.bindingIndex, 3)
        XCTAssertEqual(node.inputPortAddresses, [0x231])
        XCTAssertEqual(node.outputPortAddresses, [0x232])
        XCTAssertEqual(node.subscriptions, [0x231, 0x232])
        XCTAssertEqual(node.refreshRateHz, 300)
        let legacy = try ArtNetDiscoveryCodec.decodeReply(Data(bytes.prefix(207)))
        XCTAssertNil(legacy.bindingAddress)
        XCTAssertEqual(legacy.bindingIndex, 0)
        XCTAssertEqual(legacy.subscriptions, node.subscriptions)
        XCTAssertEqual(legacy.refreshRateHz, 44)
        for length in 0..<207 {
            XCTAssertThrowsError(try ArtNetDiscoveryCodec.decodeReply(Data(bytes.prefix(length))))
        }
        bytes[173] = 5
        XCTAssertThrowsError(try ArtNetDiscoveryCodec.decodeReply(Data(bytes)))
        bytes[173] = 1
        bytes[15] = 0
        XCTAssertThrowsError(try ArtNetDiscoveryCodec.decodeReply(Data(bytes)))
    }

    func testSACNSyncVectorAndIPv4Destination() throws {
        let cid = try XCTUnwrap(UUID(uuidString: "01020304-0506-0708-090a-0b0c0d0e0f10"))
        let expected = SACNSynchronization(address: 0x012c, sequence: 42, cid: cid)
        let packet = try SACNSynchronizationCodec.encode(expected)
        let bytes = Array(packet)
        XCTAssertEqual(bytes.count, 49)
        XCTAssertEqual(Array(bytes[16..<22]), [0x70, 33, 0, 0, 0, 8])
        XCTAssertEqual(Array(bytes[22..<38]), Array(UInt8(1)...16))
        XCTAssertEqual(Array(bytes[38..<49]), [0x70, 11, 0, 0, 0, 1, 42, 0x01, 0x2c, 0, 0])
        XCTAssertEqual(try SACNSynchronizationCodec.decode(packet), expected)
        XCTAssertEqual(try SACNCodec.multicastAddress(universe: expected.address), "239.255.1.44")
        XCTAssertEqual(try SACNCodec.multicastAddress(universe: 1), "239.255.0.1")
        XCTAssertEqual(try SACNCodec.multicastAddress(universe: 63999), "239.255.249.255")
        XCTAssertThrowsError(try SACNCodec.multicastAddress(universe: 64000))
        XCTAssertThrowsError(try SACNSynchronizationCodec.encode(.init(address: 0, sequence: 1, cid: cid)))
        XCTAssertThrowsError(try SACNSynchronizationCodec.decode(packet.dropLast()))
        var malformed = bytes
        malformed[43] = 2
        XCTAssertThrowsError(try SACNSynchronizationCodec.decode(Data(malformed)))
    }
}
