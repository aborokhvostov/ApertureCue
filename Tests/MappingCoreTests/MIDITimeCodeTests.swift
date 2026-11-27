import XCTest
@testable import MappingCore

final class MIDITimeCodeTests: XCTestCase {
    func testQuarterFrameDirectionsFragmentationAndCorrection() throws {
        var decoder = MIDITimeCodeDecoder()
        let labels: [UInt8] = [0x05, 0x11, 0x22, 0x31, 0x49, 0x52, 0x61, 0x72]
        var output: [MIDITimeCodeEvent] = []
        for (index, data) in labels.enumerated() {
            let hostTime = Double(index) * 0.01
            XCTAssertTrue(decoder.feed([0xF1, 0xF8], at: hostTime).isEmpty)
            output += decoder.feed([data, 0xFE, 0x90, 100, 64], at: hostTime + 0.001)
        }
        XCTAssertEqual(output.count, 1)
        let forward = try XCTUnwrap(output.first)
        XCTAssertEqual(forward.motion, .forward)
        XCTAssertEqual(forward.position, MIDITimeCodePosition(rate: .fps25, hours: 1, minutes: 41, seconds: 18, frames: 21))
        XCTAssertEqual(forward.clockSeconds, 6_078 + 23.0 / 25, accuracy: 1e-10)
        let reverseMessage: [UInt8] = labels.reversed().flatMap { [0xF1, $0] }
        let reverse = try XCTUnwrap(decoder.feed(reverseMessage, at: 0.10).first)
        XCTAssertEqual(reverse.motion, .reverse)
        XCTAssertEqual(reverse.clockSeconds, 6_078 + 19.0 / 25, accuracy: 1e-10)
    }

    func testFullFrameDropLabelsAndMidnight() throws {
        var decoder = MIDITimeCodeDecoder()
        XCTAssertTrue(decoder.feed([0xF0, 0x7F, 0x09, 0x01], at: 1).isEmpty)
        let drop = try XCTUnwrap(decoder.feed([0x01, 0x40, 0x01, 0x00, 0x02, 0xF8, 0xF7], at: 1.01).first)
        XCTAssertEqual(drop.position.rate, .drop2997)
        XCTAssertEqual(drop.motion, .locate)
        XCTAssertEqual(drop.clockSeconds, 1_800 * 1_001.0 / 30_000, accuracy: 1e-10)
        XCTAssertTrue(decoder.feed([0xF0, 0x7F, 0x7F, 1, 1, 0x40, 1, 0, 1, 0xF7], at: 1.02).isEmpty)
        let tenthMinute = try XCTUnwrap(decoder.feed([0xF0, 0x7F, 0x7F, 1, 1, 0x40, 10, 0, 0, 0xF7], at: 1.03).first)
        XCTAssertEqual(tenthMinute.clockSeconds, 17_982 * 1_001.0 / 30_000, accuracy: 1e-10)
        let dropBoundary: [UInt8] = [0x0C, 0x11, 0x2B, 0x33, 0x40, 0x50, 0x60, 0x74]
        let crossed = try XCTUnwrap(decoder.feed(dropBoundary.flatMap { [0xF1, $0] }, at: 1.04).first)
        XCTAssertEqual(crossed.clockSeconds, drop.clockSeconds, accuracy: 1e-10)
        let endOfDay: [UInt8] = [0x07, 0x11, 0x2B, 0x33, 0x4B, 0x53, 0x67, 0x71]
        let wrapped = try XCTUnwrap(decoder.feed(endOfDay.flatMap { [0xF1, $0] }, at: 1.05).first)
        XCTAssertEqual(wrapped.clockSeconds, 1.0 / 24, accuracy: 1e-10)
    }

    func testDiscontinuousReservedAndOversizedInputCannotComplete() throws {
        let cycle: [UInt8] = [0xF1, 0x03, 0xF1, 0x10, 0xF1, 0x20, 0xF1, 0x30,
                              0xF1, 0x40, 0xF1, 0x50, 0xF1, 0x60, 0xF1, 0x76]
        var decoder = MIDITimeCodeDecoder()
        XCTAssertTrue(decoder.feed(Array(cycle.prefix(8)), at: 0).isEmpty)
        XCTAssertTrue(decoder.feed(Array(cycle.suffix(8)), at: 0.20).isEmpty)
        var malformed = cycle
        malformed[3] = 0x12
        XCTAssertTrue(decoder.feed(malformed, at: 0.21).isEmpty)
        malformed = cycle
        malformed.removeSubrange(8..<10)
        XCTAssertTrue(decoder.feed(malformed, at: 0.22).isEmpty)
        let extendedSysEx: [UInt8] = [0xF0, 0x7F, 0x7F, 1, 1, 0, 0, 0, 0, 0, 0xF7]
        XCTAssertTrue(decoder.feed(extendedSysEx, at: 0.23).isEmpty)
        XCTAssertTrue(decoder.feed(cycle + Array(repeating: 0, count: 4_096), at: 0.24).isEmpty)
        let recovered = try XCTUnwrap(decoder.feed(cycle, at: 0.25).first)
        XCTAssertEqual(recovered.position.rate, .fps30)
        XCTAssertEqual(recovered.clockSeconds, 5.0 / 30, accuracy: 1e-10)

        XCTAssertTrue(decoder.feed(Array(cycle.prefix(8)), at: 1).isEmpty)
        XCTAssertTrue(decoder.feed([0x90, 60, 64], at: 1.12).isEmpty)
        XCTAssertTrue(decoder.feed(Array(cycle.suffix(8)), at: 1.24).isEmpty)
        XCTAssertTrue(decoder.feed([0xF0, 0x7F, 0x7F, 1, 1], at: 1.30).isEmpty)
        XCTAssertTrue(decoder.feed([0xF8], at: 1.42).isEmpty)
        XCTAssertTrue(decoder.feed([0, 0, 0, 0, 0xF7], at: 1.54).isEmpty)
    }
}
