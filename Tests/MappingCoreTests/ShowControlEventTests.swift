import XCTest
@testable import MappingCore
import Foundation

final class ShowControlEventTests: XCTestCase {
    func testEventEncodingOrderAndBounds() throws {
        let later = ShowControlEvent(time: 3, command: .midi(kind: .controlChange, channel: 16, number: 127, value: 0))
        let first = ShowControlEvent(time: 1, command: .osc(port: 9002, address: "/show/level", value: .float(0.25)))
        let sameTime = ShowControlEvent(time: 1, command: .midi(kind: .noteOn, channel: 1, number: 60, value: 123))
        let disabled = ShowControlEvent(time: 0.5, command: .midi(kind: .noteOff, channel: 1, number: 60, value: 0))
        let tracks = [
            ShowControlTrack(name: "OSC and MIDI", events: [later, first]),
            ShowControlTrack(name: "MIDI", events: [sameTime]),
            ShowControlTrack(name: "Muted", enabled: false, events: [disabled])
        ]
        try ShowControlTrack.validate(tracks, duration: 3)
        XCTAssertEqual(ShowControlTrack.events(tracks), [first, sameTime, later])
        let packet = try XCTUnwrap(try first.command.oscPacket())
        XCTAssertEqual(try OSCCodec.decode(packet), [OSCMessage(address: "/show/level", arguments: [.float(0.25)])])
        XCTAssertEqual(try later.command.midiBytes(), [0xBF, 127, 0])
        XCTAssertEqual(try sameTime.command.midiBytes(), [0x90, 60, 123])
        XCTAssertNil(try first.command.midiBytes())
        XCTAssertNil(try later.command.oscPacket())
        XCTAssertEqual(try JSONDecoder().decode([ShowControlTrack].self, from: JSONEncoder().encode(tracks)), tracks)

        XCTAssertThrowsError(try ShowControlTrack.validate(tracks, duration: 2))
        XCTAssertThrowsError(try ShowControlTrack.validate(tracks + tracks, duration: 3))
        var invalid = tracks
        invalid[2].events = [first]
        XCTAssertThrowsError(try ShowControlTrack.validate(invalid, duration: 3))
        invalid[2].events = [ShowControlEvent(time: 0, command: .osc(port: 9002, address: "/ready", value: nil))]
        XCTAssertThrowsError(try ShowControlTrack.validate(invalid, duration: 3))
        XCTAssertThrowsError(try ShowControlCommand.osc(port: 0, address: "/valid", value: nil).validate())
        XCTAssertThrowsError(try ShowControlCommand.osc(port: 9002, address: "/invalid*", value: nil).validate())
        XCTAssertThrowsError(try ShowControlCommand.osc(port: 9002, address: "/valid", value: .float(.infinity)).validate())
        XCTAssertThrowsError(try ShowControlCommand.osc(port: 9002, address: "/valid", value: .string(String(repeating: "a", count: 257))).validate())
        XCTAssertThrowsError(try ShowControlCommand.midi(kind: .noteOff, channel: 0, number: 60, value: 0).validate())
        XCTAssertThrowsError(try ShowControlCommand.midi(kind: .noteOff, channel: 2, number: 128, value: 0).validate())
    }

    func testExternalClockPacketAndPhaseCorrections() throws {
        let stream = UUID()
        let packet = ExternalShowClockPacket(source: "show_A", session: stream, sequence: 0, position: 5.25, playing: true)
        let encoded = try OSCCodec.encode(packet.message())
        let wire = try XCTUnwrap(try OSCCodec.decode(encoded).first)
        XCTAssertEqual(ExternalShowClockPacket(message: wire), packet)
        XCTAssertNil(ExternalShowClockPacket(message: OSCMessage(address: ExternalShowClockPacket.address, arguments: wire.arguments + [.int(0)])))

        var clock = ExternalShowClock()
        XCTAssertFalse(clock.receive(packet, at: 10))
        XCTAssertThrowsError(try clock.arm(source: "space is invalid"))
        try clock.arm(source: "show_A")
        var wrong = packet
        wrong.source = "other"
        XCTAssertFalse(clock.receive(wrong, at: 10))
        XCTAssertFalse(clock.receive(packet, at: .nan))
        XCTAssertTrue(clock.receive(packet, at: 10))
        XCTAssertEqual(clock.update(at: 10.25, localPosition: 0, localPlaying: false), .align(position: 5.5, playing: true))
        XCTAssertEqual(clock.state, .locked)
        XCTAssertNil(clock.update(at: 10.375, localPosition: 5.65, localPlaying: true))
        var newer = packet
        newer.sequence = 1
        newer.position = 6
        XCTAssertTrue(clock.receive(newer, at: 10.5))
        XCTAssertEqual(clock.update(at: 10.625, localPosition: 5.8, localPlaying: true), .align(position: 6.125, playing: true))
        // A local Pause marker wins over unchanged remote Running.
        XCTAssertNil(clock.update(at: 10.7, localPosition: 6.2, localPlaying: false))
        XCTAssertEqual(clock.state, .held)
        newer.sequence = 2
        newer.playing = false
        XCTAssertTrue(clock.receive(newer, at: 10.75))
        XCTAssertEqual(clock.update(at: 10.875, localPosition: 6.2, localPlaying: false), .align(position: 6, playing: false))
        newer.sequence = 3
        newer.playing = true
        XCTAssertTrue(clock.receive(newer, at: 11))
        XCTAssertEqual(clock.update(at: 11.125, localPosition: 6, localPlaying: false), .align(position: 6.125, playing: true))

        let localLoop = 1.0...3.0
        newer.sequence = 4
        newer.position = 4.99
        XCTAssertTrue(clock.receive(newer, at: 12))
        XCTAssertEqual(clock.update(at: 12, localPosition: 1.4, localPlaying: true, loop: localLoop),
                       .align(position: 2.99, playing: true))
        XCTAssertNil(clock.update(at: 12.02, localPosition: 2.98, localPlaying: true, loop: localLoop))
    }

    func testExternalClockLossOrderingAndRestart() throws {
        var clock = ExternalShowClock()
        try clock.arm(source: "one")
        let initial = ExternalShowClockPacket(source: "one", session: UUID(), sequence: 3, position: 12, playing: true)
        XCTAssertTrue(clock.receive(initial, at: 1))
        XCTAssertEqual(clock.update(at: 1, localPosition: 0, localPlaying: false), .align(position: 12, playing: true))
        XCTAssertFalse(clock.receive(initial, at: 1.5))
        var old = initial
        old.sequence = 2
        XCTAssertFalse(clock.receive(old, at: 1.5))
        var restarted = initial
        restarted.sequence = 0
        restarted.session = UUID()
        restarted.position = 0.25
        XCTAssertFalse(clock.receive(restarted, at: 1.5))
        XCTAssertEqual(clock.update(at: 2, localPosition: 13, localPlaying: true), .freeze(hostTime: 1.75))
        XCTAssertEqual(clock.state, .lost)
        XCTAssertNil(clock.update(at: 3, localPosition: 12.75, localPlaying: false))
        XCTAssertTrue(clock.receive(restarted, at: 3))
        XCTAssertEqual(clock.update(at: 3.125, localPosition: 12.75, localPlaying: false), .align(position: 0.375, playing: true))
        old.sequence = 9
        XCTAssertFalse(clock.receive(old, at: 4))
        restarted.sequence = 1
        XCTAssertFalse(clock.receive(restarted, at: 2))
        XCTAssertTrue(clock.receive(restarted, at: 4))
        XCTAssertEqual(clock.update(at: 4.125, localPosition: 12.75, localPlaying: false), .align(position: 0.375, playing: true))
        clock.disarm()
        XCTAssertEqual(clock.state, .off)
        XCTAssertFalse(clock.receive(restarted, at: 5))
        XCTAssertNil(clock.update(at: 5, localPosition: 0, localPlaying: false))
    }
}
