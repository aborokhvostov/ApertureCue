import XCTest
import Foundation
@testable import MappingCore

final class ShowScheduleTests: XCTestCase {
    private func utc(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    private func calendar(_ events: [String]) -> Data {
        Data((["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//ApertureCue//Original Schedule Fixture//EN"]
              + events + ["END:VCALENDAR", ""]).joined(separator: "\r\n").utf8)
    }

    func testICSImportWeeklyRulesExclusionsAndMetadata() throws {
        let cue = UUID()
        let source = calendar([
            "BEGIN:VEVENT", "UID:original-weekly", "SUMMARY:Morning\\, test",
            " fixture", "DTSTART;TZID=Europe/Moscow:20261123T100000", "RRULE:FREQ=WEEKLY;BYDAY=MO,FR;COUNT=4",
            "EXDATE;TZID=Europe/Moscow:20261127T100000", "DTEND;TZID=Europe/Moscow:20261123T103000",
            "DESCRIPTION:This annotation is outside the show document", "BEGIN:VALARM", "ACTION:DISPLAY",
            "TRIGGER:-PT5M", "END:VALARM", "END:VEVENT",
            "BEGIN:VEVENT", "UID:original-floating", "DTSTART:20261130T100000", "END:VEVENT"
        ])
        let entries = try ShowScheduleICS.parse(source, cueID: cue, floatingTimeZoneID: "America/New_York")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Morning, testfixture")
        XCTAssertEqual(entries[0].cueID, cue)
        XCTAssertEqual(entries[0].sourceUID, "original-weekly")
        XCTAssertEqual(try entries[0].startDate(), try utc("2026-11-23T07:00:00Z"))
        XCTAssertEqual(try entries[1].startDate(), try utc("2026-11-30T15:00:00Z"))
        XCTAssertEqual(entries[0].recurrence?.weekdays, [.mo, .fr])
        XCTAssertEqual(entries[0].excludedStarts, [try utc("2026-11-27T07:00:00Z")])
        let summaryBytes = try JSONEncoder().encode(entries)
        XCTAssertFalse(String(decoding: summaryBytes, as: UTF8.self).contains("This annotation"))

        let runtime = ShowScheduleRuntime()
        let entry = entries[0]
        try runtime.arm(ShowSchedule(entries: [entry]), cueIDs: [cue], at: utc("2026-11-23T06:59:50Z"))
        XCTAssertEqual(runtime.poll(at: try utc("2026-11-23T07:00:00Z"))?.entryID, entry.id)
        XCTAssertNil(runtime.poll(at: try utc("2026-11-27T07:00:00Z")))
        XCTAssertEqual(runtime.poll(at: try utc("2026-11-30T07:00:00Z"))?.entryID, entry.id)
        XCTAssertEqual(runtime.poll(at: try utc("2026-12-04T07:00:00Z"))?.entryID, entry.id)
        XCTAssertNil(runtime.poll(at: try utc("2026-12-07T07:00:00Z")))
    }

    func testLocalDSTGapAndRepeatedHourPolicy() throws {
        let cue = UUID()
        var entry = ShowScheduleEntry(name: "Local start", cueID: cue, localStart: "20260307T023000",
                                      timeZoneID: "America/New_York", recurrence: .init(frequency: .daily, count: 2))
        let runtime = ShowScheduleRuntime()
        try runtime.arm(ShowSchedule(entries: [entry]), cueIDs: [cue], at: utc("2026-03-07T07:29:50Z"))
        XCTAssertEqual(runtime.poll(at: try utc("2026-03-07T07:30:00Z"))?.entryID, entry.id)
        XCTAssertNil(runtime.poll(at: try utc("2026-03-08T07:30:00Z")))
        XCTAssertEqual(runtime.poll(at: try utc("2026-03-09T06:30:00Z"))?.entryID, entry.id)
        XCTAssertNil(runtime.poll(at: try utc("2026-03-10T06:30:00Z")))
        entry.localStart = "20260308T023000"
        XCTAssertThrowsError(try entry.startDate())
        entry.localStart = "20261101T013000"
        entry.recurrence = nil
        XCTAssertEqual(try entry.startDate(), try utc("2026-11-01T05:30:00Z"))
        runtime.reset()
        try runtime.arm(ShowSchedule(entries: [entry]), cueIDs: [cue], at: utc("2026-11-01T05:29:30Z"))
        XCTAssertEqual(runtime.poll(at: try utc("2026-11-01T05:30:00Z"))?.entryID, entry.id)
        XCTAssertNil(runtime.poll(at: try utc("2026-11-01T06:30:00Z")))
    }

    func testDelayedPollingConflictsAndClockRollback() throws {
        let cue = UUID()
        let a = ShowScheduleEntry(name: "Earlier", cueID: cue, localStart: "20261126T080000", timeZoneID: "UTC")
        var first = a
        first.id = UUID()
        first.localStart = "20261126T080010"
        var second = first
        second.id = UUID()
        let schedule = ShowSchedule(entries: [a, first, second])
        let runtime = ShowScheduleRuntime()
        XCTAssertNil(runtime.poll(at: try utc("2026-11-26T08:00:00Z")))
        try runtime.arm(schedule, cueIDs: [cue], at: utc("2026-11-26T07:59:50Z"))
        XCTAssertEqual(runtime.poll(at: try utc("2026-11-26T08:00:19Z"))?.entryID, first.id)
        XCTAssertNil(runtime.poll(at: try utc("2026-11-26T08:00:00Z")))
        XCTAssertNil(runtime.poll(at: try utc("2026-11-26T08:00:20Z")))
        runtime.disarm()
        try runtime.arm(schedule, cueIDs: [cue], at: utc("2026-11-26T07:59:50Z"))
        XCTAssertNil(runtime.poll(at: try utc("2026-11-26T08:00:21Z")))
        runtime.reset()
        try runtime.arm(schedule, cueIDs: [cue], at: utc("2026-11-26T07:59:50Z"))
        XCTAssertNil(runtime.poll(at: try utc("2026-11-26T08:00:41Z")))
        runtime.reset()
        try runtime.arm(schedule, cueIDs: [cue], at: utc("2026-11-26T07:59:50Z"))
        XCTAssertEqual(runtime.poll(at: try utc("2026-11-26T08:00:40Z"))?.entryID, first.id)
        runtime.reset()
        try runtime.arm(schedule, cueIDs: [cue], at: utc("2026-11-26T08:00:10Z"))
        XCTAssertNil(runtime.poll(at: try utc("2026-11-26T08:00:11Z")))
        runtime.reset()
        let edge = try utc("2026-11-26T08:00:00Z")
        let beforeEdge = Date(timeIntervalSinceReferenceDate: edge.timeIntervalSinceReferenceDate.nextDown)
        try runtime.arm(schedule, cueIDs: [cue], at: edge.addingTimeInterval(-1))
        XCTAssertNil(runtime.poll(at: beforeEdge))
        XCTAssertEqual(runtime.poll(at: edge)?.entryID, a.id)
    }

    func testUnboundedWeeklyIntervalAndInclusiveUntil() throws {
        let cue = UUID()
        let rule = try ShowScheduleICS.parseRecurrence("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR;UNTIL=20261211T080000Z")
        let entry = ShowScheduleEntry(name: "Test", cueID: cue, localStart: "20261123T080000", timeZoneID: "UTC", recurrence: rule)
        let runtime = ShowScheduleRuntime()
        try runtime.arm(ShowSchedule(entries: [entry]), cueIDs: [cue], at: utc("2026-11-22T08:00:00Z"))
        XCTAssertEqual(runtime.poll(at: try utc("2026-11-23T08:00:00Z"))?.entryID, entry.id)
        XCTAssertEqual(runtime.poll(at: try utc("2026-11-27T08:00:00Z"))?.entryID, entry.id)
        XCTAssertNil(runtime.poll(at: try utc("2026-11-30T08:00:00Z")))
        XCTAssertEqual(runtime.poll(at: try utc("2026-12-11T08:00:00Z"))?.entryID, entry.id)
        XCTAssertNil(runtime.poll(at: try utc("2026-12-21T08:00:00Z")))
        XCTAssertEqual(try ShowScheduleICS.parseRecurrence(ShowScheduleICS.formatRecurrence(rule)), rule)
    }

    func testInvalidICSAndModelAreRejectedAtomically() throws {
        let cue = UUID()
        let original = ["BEGIN:VEVENT", "UID:original", "DTSTART:20261127T100000Z", "END:VEVENT"]
        for invalid in [
            original + original,
            ["BEGIN:VEVENT", "UID:invalid", "DTSTART;VALUE=DATE:20261127", "END:VEVENT"],
            ["BEGIN:VEVENT", "UID:invalid", "DTSTART;TZID=Missing/Zone:20261127T100000", "END:VEVENT"],
            ["BEGIN:VEVENT", "UID:invalid", "DTSTART;TZID=Europe/Moscow:20261127T100000Z", "END:VEVENT"],
            ["BEGIN:VEVENT", "UID:invalid", "DTSTART:20260230T100000Z", "END:VEVENT"],
            ["BEGIN:VEVENT", "UID:invalid", "DTSTART:20261127T100000Z", "RRULE:FREQ=MONTHLY", "END:VEVENT"],
            ["BEGIN:VEVENT", "UID:invalid", "DTSTART:20261127T100000Z", "RRULE:FREQ=DAILY;COUNT=513", "END:VEVENT"],
            ["BEGIN:VEVENT", "UID:invalid", "DTSTART:20261127T100000Z", "RRULE:FREQ=WEEKLY;BYDAY=MO", "END:VEVENT"],
            ["BEGIN:VEVENT", "UID:invalid", "DTSTART:20261127T100000Z", "STATUS:CANCELLED", "END:VEVENT"],
            ["BEGIN:VEVENT", "UID:invalid", "DTSTART:20261127T100000Z", "RDATE:20261128T100000Z", "END:VEVENT"],
            ["METHOD:CANCEL"] + original,
            ["BEGIN:VTIMEZONE", "TZID:Europe/Moscow", "END:VTIMEZONE"] + original
        ] {
            XCTAssertThrowsError(try ShowScheduleICS.parse(calendar(invalid), cueID: cue, floatingTimeZoneID: "UTC"))
        }
        XCTAssertThrowsError(try ShowScheduleICS.parse(Data(repeating: 65, count: 262_145), cueID: cue, floatingTimeZoneID: "UTC"))
        let entries = try ShowScheduleICS.parse(calendar(original), cueID: cue, floatingTimeZoneID: "UTC")
        let runtime = ShowScheduleRuntime()
        try runtime.arm(ShowSchedule(entries: entries), cueIDs: [cue], at: utc("2026-11-27T09:59:50Z"))
        XCTAssertThrowsError(try runtime.configure(ShowSchedule(entries: entries), cueIDs: [], at: utc("2026-11-27T09:59:55Z")))
        XCTAssertThrowsError(try runtime.configure(ShowSchedule(entries: entries + entries), cueIDs: [cue], at: utc("2026-11-27T09:59:55Z")))
        XCTAssertEqual(runtime.poll(at: try utc("2026-11-27T10:00:00Z"))?.entryID, entries[0].id)
    }

    func testSavedScheduleAndLegacyVersionIgnoreNewField() throws {
        let cue = Cue(name: "Original scheduling scene", surfaces: [Surface()])
        let rule = ShowScheduleRecurrence(frequency: .weekly, interval: 3, count: 8, weekdays: [.fr])
        let entry = ShowScheduleEntry(name: "Round trip", cueID: cue.id, localStart: "20261127T100000", timeZoneID: "UTC", recurrence: rule)
        var project = Project(name: "Original schedule project", surfaces: cue.surfaces, cues: [cue])
        project.showSchedule = ShowSchedule(entries: [entry])
        try ProjectStore.validate(project)
        let encoded = try JSONEncoder().encode(project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: encoded).showSchedule, project.showSchedule)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy["version"] = 13
        legacy["showSchedule"] = "unrecognized field in version 13"
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertTrue(try JSONDecoder().decode(Project.self, from: legacyData).showSchedule.entries.isEmpty)
        legacy["version"] = Project.currentVersion
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: legacy)))
    }
}
