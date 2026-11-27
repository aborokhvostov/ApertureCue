import Foundation
import XCTest
@testable import MappingCore

final class ControlMappingTests: XCTestCase {
    func testStableUUIDRoutesAndSchemaIsolation() throws {
        let original = Project.demo()
        var changed = original
        let surfaceID = changed.surfaces[0].id
        let cueID = changed.cues[1].id
        let map = ControlMap(bindings: [
            .init(input: .osc("/fader/a"), target: .surface(surfaceID, parameter: "opacity"), inverted: true),
            .init(input: .midi(kind: .note, channel: 2, number: 40), target: .scene(cueID))
        ])
        changed.controlMap = map
        changed.surfaces.swapAt(0, 1)
        changed.cues.swapAt(0, 1)
        let roundTrip = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(changed))
        try ProjectStore.validate(roundTrip)
        XCTAssertEqual(roundTrip.controlMap, map)
        var router = ControlRouter()
        try router.configure(map, surfaceIDs: Set(changed.surfaces.map(\.id)), cueIDs: Set(changed.cues.map(\.id)))
        XCTAssertEqual(router.route(.osc("/fader/a"), value: .normalized(0.75)),
                       ControlIntent(target: .surface(surfaceID, parameter: "opacity"), value: 0.25))

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(changed)) as? [String: Any])
        legacy["version"] = 14
        legacy["controlMap"] = [true, "undefined in old schema"]
        let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.controlMap, ControlMap())
        XCTAssertEqual(decoded.cues, roundTrip.cues)
    }

    func testHeldKeysAndFeedbackBounds() throws {
        let key = ControlInput.midi(kind: .note, channel: 16, number: 127)
        let binding = ControlBinding(input: key, target: .togglePlayback, feedback: true)
        var router = ControlRouter()
        try router.configure(.init(bindings: [binding]), surfaceIDs: [], cueIDs: [])
        XCTAssertEqual(router.route(key, value: .normalized(1))?.target, .togglePlayback)
        XCTAssertNil(router.route(key, value: .normalized(0.4)))
        XCTAssertNil(router.route(key, value: .normalized(1)))
        XCTAssertNil(router.route(key, value: .normalized(0.25)))
        XCTAssertEqual(router.route(key, value: .normalized(0.5))?.target, .togglePlayback)
        router.clearHeldInputs()
        XCTAssertEqual(router.route(key, value: .normalized(1))?.target, .togglePlayback)
        XCTAssertNil(router.route(key, value: .normalized(.nan)))
        let invalid = [
            ControlBinding(input: .midi(kind: .cc14, channel: 1, number: 32), target: .play),
            ControlBinding(input: .osc("/address/*"), target: .play),
            ControlBinding(input: .osc("/address//empty"), target: .play),
            ControlBinding(input: .osc("/fader/a"), target: .blackout, feedback: true),
            ControlBinding(input: .osc(ControlAddressSpace.time), target: .seek)
        ]
        for row in invalid {
            XCTAssertThrowsError(try ControlMap(bindings: [row]).validate(surfaceIDs: [], cueIDs: []))
        }
        XCTAssertThrowsError(try ControlMap(bindings: [binding, binding]).validate(surfaceIDs: [], cueIDs: []))
    }

    func testOSCBlobGoldenPacketAndCorpusBounds() throws {
        let message = OSCMessage(address: "/b", arguments: [.blob(Data([0, 255, 1]))])
        let expected: [UInt8] = [47, 98, 0, 0, 44, 98, 0, 0, 0, 0, 0, 3, 0, 255, 1, 0]
        let packet = try OSCCodec.encode(message)
        XCTAssertEqual(Array(packet), expected)
        XCTAssertEqual(try OSCCodec.decode(packet), [message])
        var invalidPadding = expected
        invalidPadding[15] = 8
        XCTAssertThrowsError(try OSCCodec.decode(Data(invalidPadding)))
        var invalidLength = expected
        invalidLength[8] = 0xFF
        XCTAssertThrowsError(try OSCCodec.decode(Data(invalidLength)))
        for end in 0..<packet.count { XCTAssertThrowsError(try OSCCodec.decode(packet.prefix(end))) }
        let large = OSCMessage(address: "/b", arguments: [.blob(Data(repeating: 42, count: 32768))])
        XCTAssertThrowsError(try OSCCodec.encodeBundle([large, large]))
        XCTAssertNil(ControlInputValue(arguments: [.int(1), .int(2)]))
        XCTAssertNil(ControlInputValue(arguments: [.float(.infinity)]))
    }
}
