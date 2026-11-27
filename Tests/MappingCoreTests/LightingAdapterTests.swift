import XCTest
import Foundation
@testable import MappingCore

final class LightingAdapterTests: XCTestCase {
    func testBufferedUSBProMatchesGoldenBytes() throws {
        var channels = [UInt8](repeating: 0, count: 512)
        channels[0...2] = [0x7E, 0xE7, 0x33]
        channels[511] = 0x55
        let packet = try BufferedDMXPro.encode(channels)
        XCTAssertEqual(packet.count, 518)
        XCTAssertEqual(Array(packet.prefix(8)), [0x7E, 0x06, 0x01, 0x02, 0x00, 0x7E, 0xE7, 0x33])
        XCTAssertEqual(Array(packet.suffix(3)), [0, 0x55, 0xE7])
        XCTAssertEqual(try BufferedDMXPro.inspect(packet), channels)
        XCTAssertEqual(try BufferedDMXPro.inspect(BufferedDMXPro.blackout), Array(repeating: 0, count: 512))
        var wrongSize = packet
        wrongSize[wrongSize.startIndex + 2] = 0
        XCTAssertThrowsError(try BufferedDMXPro.inspect(wrongSize))
        XCTAssertThrowsError(try BufferedDMXPro.encode(Array(channels.dropLast())))
    }

    func testSPIRGBExportKeepsChannelOrderAndBounds() throws {
        var channels = [UInt8](repeating: 0, count: 512)
        let expected: [UInt8] = [1, 3, 5, 7, 9, 11]
        channels.replaceSubrange(506...511, with: expected)
        let route = try LightingAdapterRoute(universe: 24, encoding: .spiRGB(firstAddress: 507, pixels: 2))
        XCTAssertEqual(try route.packet(in: [24: channels]), Data(expected))
        XCTAssertNil(try route.packet(in: [25: channels]))
        XCTAssertThrowsError(try route.packet(in: [24: [0, 1]]))
        XCTAssertThrowsError(try LightingAdapterRoute(universe: 24, encoding: .spiRGB(firstAddress: 508, pixels: 2)))
        XCTAssertThrowsError(try LightingAdapterRoute(universe: -1, encoding: .bufferedDMX))
        let dmx = try LightingAdapterRoute(universe: 0, encoding: .bufferedDMX)
        let frame = try XCTUnwrap(try dmx.packet(in: [0: channels]))
        XCTAssertEqual(try BufferedDMXPro.inspect(frame), channels)
    }
}
