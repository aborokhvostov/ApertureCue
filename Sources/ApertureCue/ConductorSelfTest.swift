#if os(macOS)
import AppKit
import MappingCore
import MetalKit

@MainActor enum ConductorSelfTest {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func require(_ valid: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !valid() { throw Failure(message: message) }
    }

    static func fixture() -> Project {
        var left = Surface(name: "Left automation", generator: "solid")
        left.output = [Point2(0.06, 0.20), Point2(0.44, 0.20), Point2(0.44, 0.80), Point2(0.06, 0.80)]
        left.color = [1, 0.25, 0.1]
        var right = Surface(name: "Right automation", generator: "solid")
        right.output = [Point2(0.56, 0.20), Point2(0.94, 0.20), Point2(0.94, 0.80), Point2(0.56, 0.80)]
        right.color = [0.1, 0.4, 1]
        func track(_ name: String, _ surface: Surface, from first: Double, to last: Double) -> AutomationTrack {
            AutomationTrack(name: name, surfaceID: surface.id, parameter: "opacity",
                            keyframes: [.init(time: 0, value: first), .init(time: 2, value: last)])
        }
        let rise = track("Rise", left, from: 0, to: 1)
        let fall = track("Fall", right, from: 1, to: 0)
        let dim = track("Dim", left, from: 0.3, to: 0.3)
        let bank = ConductorBank(name: "Parallel tracks", rows: [
            ConductorRow(name: "Left", cells: [
                ConductorCell(name: "Rise", duration: 2, loops: true, tracks: [rise]),
                ConductorCell(name: "Dim", duration: 2, tracks: [dim])
            ]),
            ConductorRow(name: "Right", cells: [ConductorCell(name: "Fall", duration: 2, loops: true, tracks: [fall])])
        ])
        let backup = ConductorBank(name: "Alternate bank", rows: [
            ConductorRow(name: "Left", cells: [ConductorCell(name: "Dim", duration: 2, tracks: [dim])])
        ])
        let signal = ShowSignal(name: "Slow triangle", kind: .triangle, frequency: 0.5)
        let binding = ShowSignalBinding(signalID: signal.id, surfaceID: right.id, parameter: "blue", minimum: 0.5, maximum: 1)
        var dark = right
        dark.opacity = 0.2
        var project = Project(name: "ApertureCue Show Control", surfaces: [left, right], outputs: [OutputConfig(name: "Preview")],
                              cues: [Cue(name: "Open", surfaces: [left, right], curve: .easeInOut),
                                     Cue(name: "Dim blue", surfaces: [left, dark], curve: .easeOut)],
                              timeline: [rise, fall],
                              timelineSettings: TimelineSettings(duration: 4, markers: [
                                TimelineMarker(name: "Repeat opening", time: 2, action: .jump, jumpTime: 0.5, jumpLimit: 2),
                                TimelineMarker(name: "Hold", time: 3.5, action: .pause)
                              ]))
        project.conductor = Conductor(banks: [bank, backup], signals: [signal], bindings: [binding])
        return project
    }

    static func run() -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueConductor-" + UUID().uuidString)
        let reportURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/local/conductor/report.json")
        var checks: [String] = []
        var editor: EditorController?
        var failure: String?
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            if let editor {
                editor.timer?.invalidate()
                editor.resetShowControlSessions()
                editor.media?.reset()
                editor.lighting?.stop()
                editor.dirty = false
                editor.window?.delegate = nil
                editor.window?.close()
            }
            try? FileManager.default.removeItem(at: folder)
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let url = folder.appendingPathComponent("show.aperturecue.json")
            let model = fixture()
            try ProjectStore.save(model, to: url)
            let controller = EditorController()
            editor = controller
            controller.timer?.invalidate()
            controller.openProject(url)
            try require(controller.project == model, "The schema 14 demo did not open exactly")
            guard let device = MTLCreateSystemDefaultDevice() else { throw Failure(message: "Metal device unavailable") }
            let bank = model.conductor.banks[0]
            try controller.launchConductorCell(bankID: bank.id, cellID: bank.rows[0].cells[0].id, at: 100)
            try controller.launchConductorCell(bankID: bank.id, cellID: bank.rows[1].cells[0].id, at: 100.5)
            controller.conductorHostTime = 101
            controller.updateRender()
            let sampled = controller.effectiveSurfaces
            try require(sampled.count == 2 && sampled[0].opacity == 0.5 && sampled[1].opacity == 0.75,
                        "Parallel rows did not sample their independent anchors")
            try require(controller.showRuntime.time == 0, "Launching Conductor cells moved the master clock")
            guard let frame = controller.compositionExportFrame(width: 128, height: 80), let bytes = frame.bitmapData else {
                throw Failure(message: "Production Metal renderer did not export the combined show frame")
            }
            let left = 40 * frame.bytesPerRow + 32 * 4
            let right = 40 * frame.bytesPerRow + 96 * 4
            try require(bytes[left] > 80 && bytes[left] > bytes[left + 2] && bytes[right + 2] > 60 && bytes[right + 2] > bytes[right],
                        "Rendered frame does not contain both original Conductor layers")
            checks.append("Parallel rows retain independent clocks and drive the production Metal frame on " + device.name)

            try controller.launchConductorCell(bankID: bank.id, cellID: bank.rows[0].cells[1].id, at: 102)
            try require(controller.conductorRuntime.activeCellIDs.count == 2 && controller.effectiveSurfaces[0].opacity == 0.3,
                        "Replacing a row affected another row")
            let alternate = model.conductor.banks[1]
            try controller.launchConductorCell(bankID: alternate.id, cellID: alternate.rows[0].cells[0].id, at: 103)
            try require(controller.conductorRuntime.activeCellIDs.count == 1, "Bank change did not clear the previous bank")
            controller.stopShow(at: 103)
            try require(controller.conductorRuntime.activeCellIDs.isEmpty, "Show stop left Conductor rows active")
            checks.append("Row replacement, bank switch and Show Stop clear only the documented active rows")

            let track = model.timeline[0]
            try controller.timelineRetimeKeys(trackID: track.id, from: 0, through: 2, to: 1, scale: 0.5)
            try require(controller.project.timeline[0].keyframes.map(\.time) == [1, 2], "Retime did not transform the selected range")
            try require(controller.project.conductor.banks[0].rows[0].cells[0].tracks[0] == track,
                        "Retiming changed an already captured cell")
            controller.undoEdit()
            try require(controller.project.timeline[0] == track, "Undo did not restore recorded keys")
            controller.redoEdit()
            try require(controller.project.timeline[0].keyframes.map(\.time) == [1, 2], "Redo did not restore range edit")
            checks.append("Undo/Redo retimes a track without changing an existing cell")

            controller.saveTo(url)
            let loaded = try ProjectStore.load(from: url)
            try require(loaded == controller.project, "Saved show did not preserve timeline, banks, signals and markers")
            controller.openProject(url)
            try require(controller.conductorRuntime.activeCellIDs.isEmpty && controller.project == loaded,
                        "Open restored a transient cell or lost a saved show field")
            checks.append("Schema 14 Save/Open preserves banks, signals, automation, easing and markers with a fresh session")

            var sequence = loaded
            var first = sequence.surfaces
            first[0].opacity = 0.4
            let instant = Cue(name: "Instant full scene", surfaces: first, duration: 0)
            var selective = sequence.surfaces[1]
            selective.opacity = 0.25
            let second = try CueSelection.capture(name: "Instant right opacity", surfaces: [selective],
                bindings: [CueBinding(surfaceID: selective.id, parameters: [.opacity])], duration: 0, followAfter: nil)
            sequence.cues = [instant, second]
            sequence.timelineSettings.markers = [
                TimelineMarker(time: 0.5, action: .cue, cueID: instant.id),
                TimelineMarker(time: 0.75, action: .cue, cueID: second.id)
            ]
            controller.mutate("Install marker burst fixture") { $0 = sequence }
            controller.stopShow(at: 200)
            controller.playShow(at: 200)
            controller.advanceShow(at: 201)
            try require(controller.project.surfaces.map(\.opacity) == [0.4, 0.25],
                        "A late tick discarded an earlier instant scene in the same batch")
            checks.append("Two instant full/selective cues crossed in one tick publish in order")

        } catch { failure = error.localizedDescription }

        let report: [String: Any] = [
            "schemaVersion": 1, "timestampUTC": ISO8601DateFormatter().string(from: Date()),
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "passed": failure == nil, "checks": checks, "checkCount": checks.count,
            "durationSeconds": ProcessInfo.processInfo.systemUptime - started,
            "resolution": [128, 80], "surfaceCount": 2, "logicalOutputCount": 1,
            "hardwareVerification": false,
            "scope": "Native editor commands, fake host time and production Metal export of an original procedural show",
            "failure": failure ?? ""
        ]
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        } catch { print("Conductor report failed: \(error.localizedDescription)"); return 1 }
        if let failure { print("FAIL Conductor: " + failure); return 1 }
        print("PASS Conductor: \(checks.count) checks")
        return 0
    }
}
#endif
