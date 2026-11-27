import Foundation
import XCTest
@testable import MappingCore

final class ConductorTests: XCTestCase {
    func testRowExclusivityPriorityBankSwitchAndImmutableCapture() throws {
        let surface = Surface()
        func cell(_ name: String, _ value: Double, loops: Bool = false) -> ConductorCell {
            let track = AutomationTrack(name: name, surfaceID: surface.id, parameter: "opacity",
                keyframes: [AutomationKeyframe(time: 0, value: 0), AutomationKeyframe(time: 2, value: value)])
            return ConductorCell(name: name, duration: 2, loops: loops, tracks: [track])
        }
        let first = cell("Rise", 1, loops: true)
        let replacement = cell("Alternate", 0.25)
        let override = cell("Override", 0.5)
        let bank = ConductorBank(name: "A", rows: [
            ConductorRow(name: "Top", cells: [first, replacement]),
            ConductorRow(name: "Bottom", cells: [override])
        ])
        let other = ConductorBank(name: "B", rows: [ConductorRow(name: "Only", cells: [first, override].map {
            ConductorCell(name: $0.name, duration: $0.duration, tracks: $0.tracks)
        })])
        let runtime = ConductorRuntime()
        var model = Conductor(banks: [bank, other])
        try runtime.configure(model, surfaces: [surface])
        try runtime.launch(bankID: bank.id, cellID: first.id, at: 10)
        try runtime.launch(bankID: bank.id, cellID: first.id, at: 11)
        XCTAssertEqual(try runtime.apply(to: [surface], hostTime: 11.5, showTime: 0)[0].opacity, 0.75)
        XCTAssertEqual(try runtime.apply(to: [surface], hostTime: 12.5, showTime: 0)[0].opacity, 0.25)
        try runtime.launch(bankID: bank.id, cellID: replacement.id, at: 12)
        try runtime.launch(bankID: bank.id, cellID: override.id, at: 12)
        XCTAssertEqual(runtime.activeCellIDs, Set([replacement.id, override.id]))
        XCTAssertEqual(try runtime.apply(to: [surface], hostTime: 15, showTime: 3)[0].opacity, 0.5)
        runtime.stop(rowID: bank.rows[1].id)
        XCTAssertEqual(try runtime.apply(to: [surface], hostTime: 15, showTime: 3)[0].opacity, 0.25)
        try runtime.launch(bankID: other.id, cellID: other.rows[0].cells[0].id, at: 15)
        XCTAssertEqual(runtime.activeCellIDs.count, 1)
        model.banks[1].rows[0].cells[0].name = "Edited"
        try runtime.configure(model, surfaces: [surface])
        XCTAssertTrue(runtime.activeCellIDs.isEmpty)
    }

    func testSignalClockGraphCycleAndParameterMapping() throws {
        let surface = Surface()
        let triangle = ShowSignal(name: "Triangle", kind: .triangle)
        let square = ShowSignal(name: "Gate", kind: .square)
        var multiply = ShowSignal(name: "Gated", kind: .multiply, inputs: [triangle.id, square.id])
        let binding = ShowSignalBinding(signalID: multiply.id, surfaceID: surface.id, parameter: "brightness",
                                        minimum: 1, maximum: 3)
        let runtime = ConductorRuntime()
        try runtime.configure(Conductor(signals: [multiply, triangle, square], bindings: [binding]), surfaces: [surface])
        XCTAssertEqual(try runtime.apply(to: [surface], hostTime: 10, showTime: 0.25)[0].brightness, 2)
        XCTAssertEqual(try runtime.apply(to: [surface], hostTime: 50, showTime: 0.75)[0].brightness, 1)
        multiply.inputs[0] = multiply.id
        XCTAssertThrowsError(try runtime.configure(Conductor(signals: [triangle, multiply, square], bindings: [binding]),
                                                   surfaces: [surface]))
        XCTAssertEqual(try runtime.apply(to: [surface], hostTime: 80, showTime: 0.25)[0].brightness, 2)
    }

    func testJumpLimitsStopSeekAndCueCurve() throws {
        let jump = TimelineMarker(time: 2, action: .jump, jumpTime: 1, jumpLimit: 2)
        let pause = TimelineMarker(time: 3)
        let runtime = ShowRuntime()
        try runtime.configure(settings: TimelineSettings(duration: 5, markers: [jump, pause]),
                              tracks: [], surfaces: [], at: 0)
        runtime.play(at: 0)
        XCTAssertEqual(runtime.tick(at: 8).time, 1)
        XCTAssertEqual(runtime.tick(at: 9).firedMarkerIDs, [jump.id])
        let stopped = runtime.tick(at: 12)
        XCTAssertEqual(stopped.time, 3)
        XCTAssertFalse(stopped.isPlaying)
        XCTAssertEqual(stopped.firedMarkerIDs, [pause.id])
        runtime.seek(to: 1, at: 30)
        XCTAssertTrue(runtime.tick(at: 30).firedMarkerIDs.isEmpty)
        runtime.play(at: 30)
        XCTAssertEqual(runtime.tick(at: 31).firedMarkerIDs, [jump.id])
        runtime.allowsPositionJumps = false
        runtime.seek(to: 0, at: 40)
        let externallyOwned = runtime.tick(at: 44)
        XCTAssertEqual(externallyOwned.time, 3)
        XCTAssertEqual(externallyOwned.firedMarkerIDs, [pause.id])


        let surface = Surface(opacity: 1)
        var destination = surface
        destination.opacity = 0
        let cue = Cue(name: "Ease", surfaces: [destination], duration: 2, followAfter: 1, curve: .easeIn)
        let cueEngine = CueEngine()
        cueEngine.begin(from: [surface], cue: cue, at: 10)
        XCTAssertEqual(cueEngine.sample(at: 11)?[0].opacity, 0.75)
        XCTAssertEqual(cueEngine.sample(at: 12)?[0].opacity, 0)
        XCTAssertFalse(cueEngine.shouldFollow(at: 12.99))
        XCTAssertTrue(cueEngine.shouldFollow(at: 13))
    }

    func testEventsAndMarkersUseOneBudgetAndDoNotReplayAfterSeek() throws {
        let cue = UUID()
        let recall = TimelineMarker(time: 1, action: .cue, cueID: cue)
        let pause = TimelineMarker(time: 2)
        let command = ShowControlCommand.midi(kind: .controlChange, channel: 1, number: 1, value: 64)
        let events = (0..<300).map { _ in ShowControlEvent(time: 1, command: command) }
        let track = ShowControlTrack(name: "Test events", events: events)
        let runtime = ShowRuntime()
        try runtime.configure(settings: TimelineSettings(duration: 5, markers: [recall, pause]),
                              tracks: [], surfaces: [], cueIDs: [cue], controlTracks: [track], at: 0)
        runtime.play(at: 0)
        let tick = runtime.tick(at: 4)
        XCTAssertEqual(tick.time, 2)
        XCTAssertFalse(tick.isPlaying)
        XCTAssertEqual(tick.cueIDs, [cue])
        XCTAssertEqual(tick.controlEvents.map(\.id), Array(events.prefix(255)).map(\.id))
        XCTAssertTrue(tick.eventsSkipped)
        runtime.seek(to: 0.5, at: 10)
        XCTAssertTrue(runtime.tick(at: 10).controlEvents.isEmpty)
        runtime.seek(to: 1.5, at: 11)
        XCTAssertTrue(runtime.tick(at: 11).controlEvents.isEmpty)
        runtime.play(at: 12)
        XCTAssertTrue(runtime.tick(at: 13).controlEvents.isEmpty)
    }

    func testSchema14AndIgnoredUndefinedLegacyExtensions() throws {
        let fixture = Project.demo()
        var project = fixture
        project.conductor = Conductor(banks: [ConductorBank(name: "Test")])
        project.cues[0].curve = .easeOut
        project.timelineSettings.markers = [TimelineMarker(time: 2, action: .jump, jumpTime: 0, jumpLimit: 1)]
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        try ProjectStore.validate(decoded)
        XCTAssertEqual(decoded, project)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? [String: Any])
        object["version"] = 13
        object["conductor"] = "malformed"
        object["showSchedule"] = [false]
        object["showControlTracks"] = false
        var cues = try XCTUnwrap(object["cues"] as? [[String: Any]])
        cues[0]["curve"] = 999
        object["cues"] = cues
        let old = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(old.conductor.banks.isEmpty)
        XCTAssertEqual(old.cues[0].curve, .linear)
        XCTAssertTrue(old.showControlTracks.isEmpty)
    }
}
