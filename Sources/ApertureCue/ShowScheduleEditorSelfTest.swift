#if os(macOS)
import AppKit
import MetalKit
import MappingCore

@MainActor enum ShowScheduleEditorSelfTest {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run() -> Int32 {
        let manager = FileManager.default
        let output = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("artifacts/local/show-schedule", isDirectory: true)
        let directory = manager.temporaryDirectory.appendingPathComponent("aperturecue-schedule-\(UUID())", isDirectory: true)
        let start = ProcessInfo.processInfo.systemUptime
        var checks: [String] = []
        var failure: String?
        defer { try? manager.removeItem(at: directory) }

        func expect(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
            if try !condition() { throw Failure(message: description) }
        }
        func passed(_ description: String) {
            checks.append(description)
            print("PASS schedule: \(description)")
        }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            NSApplication.shared.setActivationPolicy(.prohibited)
            try expect(MTLCreateSystemDefaultDevice() != nil, "No Metal device in this graphics session")
            let editor = EditorController()
            editor.timer?.invalidate()
            editor.timer = nil
            editor.window?.orderOut(nil)
            editor.metalView.isPaused = true
            editor.lightingView.isPaused = true
            editor.network?.stop()
            editor.midi?.stop()
            editor.lighting?.stop()
            defer {
                editor.resetShowSchedule()
                editor.closeOutputs()
                editor.media.reset()
                editor.window?.delegate = nil
                editor.window?.close()
            }
            var target = Surface(name: "Original schedule fixture", opacity: 0.25)
            let cue = Cue(name: "Original scheduled dim", surfaces: [target], duration: 0)
            target.opacity = 1
            editor.project = Project(name: "Original schedule fixture", surfaces: [target], cues: [cue])
            editor.reconcile()
            editor.refresh()
            editor.showScheduleWindow = ShowScheduleWindow(editor: editor)
            try expect(editor.showScheduleWindow?.window?.isVisible == false, "Schedule fixture window should be hidden")
            let originalFile = directory.appendingPathComponent("original.ics")
            let calendar = """
            BEGIN:VCALENDAR
            VERSION:2.0
            PRODID:-//ApertureCue//Original Schedule Fixture//EN
            BEGIN:VEVENT
            UID:original-scheduled-editor-test
            SUMMARY:Original scheduled dim event
            DTSTART:20261127T120000Z
            RRULE:FREQ=DAILY;COUNT=2
            END:VEVENT
            END:VCALENDAR
            """
            try Data(calendar.utf8).write(to: originalFile, options: .atomic)
            let entries = try ShowScheduleWindow.readCalendar(originalFile, cueID: cue.id, zoneID: "UTC")
            try editor.saveShowScheduleEntries(entries)
            try expect(entries.count == 1 && editor.project.showSchedule.entries == entries, "Native import lost the event or selected scene")
            editor.undoEdit()
            try expect(editor.project.showSchedule.entries.isEmpty, "Schedule import Undo left an event")
            editor.redoEdit()
            try expect(editor.project.showSchedule.entries == entries, "Schedule import Redo changed the imported entry")
            var duplicateRejected = false
            do { try editor.saveShowScheduleEntries(ShowScheduleWindow.readCalendar(originalFile, cueID: cue.id, zoneID: "UTC")) }
            catch { duplicateRejected = true }
            try expect(duplicateRejected && editor.project.showSchedule.entries == entries, "Duplicate ICS import changed the document")
            passed("local ICS import binds its scene, supports Undo/Redo and rejects duplicate UID atomically")

            guard let entry = entries.first else { throw Failure(message: "Missing imported entry") }
            let time = try entry.startDate()
            try expect(editor.pollShowSchedule(at: time) == nil && editor.cueTarget == nil, "A disarmed schedule recalled a scene")
            try editor.setShowScheduleArmed(true, at: time.addingTimeInterval(-1))
            try expect(editor.pollShowSchedule(at: time)?.cueID == cue.id, "Scheduled start did not enter the normal scene path")
            try expect(editor.cueTarget?.id == cue.id && editor.cueEngine.sample(at: editor.cueStart)?.first?.opacity == 0.25,
                       "Scheduled recall did not use the real cue engine")
            try expect(editor.pollShowSchedule(at: time.addingTimeInterval(1)) == nil, "A duplicate poll replayed the scheduled scene")
            passed("disarmed runtime has no effect and an armed wall-clock crossing uses production scene GO once")

            editor.showScheduleWindow?.close()
            editor.showScheduleWindow = nil
            let later = time.addingTimeInterval(5)
            var moved = entry
            moved.localStart = try ShowScheduleICS.localStart(for: later, timeZoneID: "UTC")
            editor.project.showSchedule = ShowSchedule(entries: [moved])
            editor.reconcileShowSchedule(at: time.addingTimeInterval(1))
            try expect(editor.showScheduleRuntime.isConfigured(for: editor.project.showSchedule)
                       && editor.pollShowSchedule(at: later)?.time == later,
                       "Armed schedule kept old data without a Schedule window")
            editor.project.showSchedule = ShowSchedule(entries: entries)
            editor.reconcileShowSchedule(at: later)
            passed("armed schedule reconciles document edits without an open Schedule window")

            let projectURL = directory.appendingPathComponent("Schedule.aperturecue.json")
            editor.saveTo(projectURL)
            let saved = try ProjectStore.load(from: projectURL)
            try expect(!editor.dirty && saved.showSchedule.entries == entries, "Manual Save lost the scheduled scene")
            editor.openProject(projectURL)
            try expect(editor.showScheduleWindow == nil && !editor.showScheduleRuntime.isArmed,
                       "Reopening retained the armed runtime or old window")
            try expect(editor.project.showSchedule.entries == entries && editor.pollShowSchedule(at: time.addingTimeInterval(86_400)) == nil,
                       "Reopening lost the event or replayed it without arming")
            passed("Save/Open preserves the calendar and disarms the schedule on document replacement")

            try editor.cueDelete(id: cue.id)
            try expect(editor.project.showSchedule.entries.isEmpty, "Scene deletion left a dangling schedule entry")
            editor.undoEdit()
            try expect(editor.project.showSchedule.entries == entries, "Scene delete Undo did not restore the schedule entry")
            passed("deleting a scene prunes calendar references and Undo restores them")
        } catch {
            failure = error.localizedDescription
            fputs("FAIL schedule: \(error.localizedDescription)\n", stderr)
        }

        var report: [String: Any] = [
            "schemaVersion": 1,
            "timestampUTC": ISO8601DateFormatter().string(from: Date()),
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Original local ICS, native document and hidden Schedule window, injected wall clock, production CueEngine",
            "passed": failure == nil,
            "checkCount": checks.count,
            "checks": checks,
            "windowsShown": false,
            "systemCalendarAccess": false,
            "hardwareVerification": false,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start
        ]
        if let failure { report["failure"] = failure }
        do {
            try manager.createDirectory(at: output, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("report.json"), options: .atomic)
        } catch {
            fputs("Schedule report failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
        return failure == nil ? 0 : 1
    }
}
#endif
