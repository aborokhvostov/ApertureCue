import XCTest
@testable import MappingCore

final class MIDIControlCodecTests: XCTestCase {
    func testRunningStatusRealtimeAndSystemCancellation() {
        var decoder = MIDIControlCodec()
        XCTAssertEqual(decoder.feed([0x92, 60]), [])
        XCTAssertEqual(decoder.feed([0xF8, 96, 61, 0, 0xFA]), [
            .realtime(.clock), .note(channel: 3, note: 60, velocity: 96, isOn: true),
            .note(channel: 3, note: 61, velocity: 0, isOn: false), .realtime(.start)
        ])
        XCTAssertEqual(decoder.feed([0x81, 60, 20, 62, 21, 0xF1, 64, 43, 0xFB]), [
            .note(channel: 2, note: 60, velocity: 20, isOn: false),
            .note(channel: 2, note: 62, velocity: 21, isOn: false), .realtime(.continuePlayback)
        ])
        XCTAssertEqual(decoder.feed([0xF0, 1, 2, 0xF8, 7, 0xF7, 32, 45, 0xFC]), [.realtime(.clock), .realtime(.stop)])
        XCTAssertEqual(decoder.feed([0xC0, 7, 8, 0xD0, 80, 90, 0xE0, 0, 64]), [.pitchBend(channel: 1, value: 8192)])
    }

    func testFourteenBitControlStateIsPerChannelAndResettable() {
        var decoder = MIDIControlCodec()
        XCTAssertEqual(decoder.feed([0xB0, 1, 4, 0xB1, 33, 10, 0xB0, 33, 3]), [
            .controlChange(channel: 1, controller: 1, value: 4),
            .controlChange(channel: 2, controller: 33, value: 10),
            .controlChange(channel: 1, controller: 33, value: 3),
            .controlChange14(channel: 1, controller: 1, value: 515)
        ])
        XCTAssertEqual(decoder.feed([0xB1, 1, 6, 0xB0, 7, 127, 39, 127]), [
            .controlChange(channel: 2, controller: 1, value: 6),
            .controlChange14(channel: 2, controller: 1, value: 778),
            .controlChange(channel: 1, controller: 7, value: 127),
            .controlChange(channel: 1, controller: 39, value: 127),
            .controlChange14(channel: 1, controller: 7, value: 16383)
        ])
        decoder.reset()
        XCTAssertEqual(decoder.feed([33, 10, 0xB0, 33, 11]), [.controlChange(channel: 1, controller: 33, value: 11)])
    }

    func testBoundsAndFeedbackEncoding() throws {
        var decoder = MIDIControlCodec()
        let oversized = [UInt8(0x90)] + [UInt8](repeating: 60, count: MIDIControlCodec.maximumBytesPerFeed + 2)
        XCTAssertEqual(decoder.feed(oversized).count, MIDIControlCodec.maximumEventsPerFeed)
        XCTAssertTrue(decoder.eventsTruncatedLastFeed)
        XCTAssertEqual(decoder.feed([62, 90]), [])
        XCTAssertFalse(decoder.eventsTruncatedLastFeed)
        XCTAssertEqual(decoder.feed([0x90, 64, 100]), [.note(channel: 1, note: 64, velocity: 100, isOn: true)])

        XCTAssertEqual(try MIDIControlEvent.note(channel: 16, note: 0, velocity: 127, isOn: false).encodedMessages(), [[0x8F, 0, 127]])
        XCTAssertEqual(try MIDIControlEvent.controlChange14(channel: 2, controller: 31, value: 16383).encodedMessages(), [[0xB1, 31, 127], [0xB1, 63, 127]])
        XCTAssertEqual(try MIDIControlEvent.pitchBend(channel: 1, value: 8192).encodedMessages(), [[0xE0, 0, 64]])
        XCTAssertEqual(try MIDIControlEvent.realtime(.continuePlayback).encodedMessages(), [[0xFB]])
        XCTAssertThrowsError(try MIDIControlEvent.pitchBend(channel: 0, value: 8192).encodedMessages())
        XCTAssertThrowsError(try MIDIControlEvent.controlChange14(channel: 1, controller: 32, value: 0).encodedMessages())
        XCTAssertThrowsError(try MIDIControlEvent.controlChange14(channel: 1, controller: 31, value: 16384).encodedMessages())
    }
}
