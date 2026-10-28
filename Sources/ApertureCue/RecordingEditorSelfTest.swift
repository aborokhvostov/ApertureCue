#if os(macOS)
import AppKit
import MappingCore

/// Native controller/inspector recording checks using separate original fixtures.
/// No visible windows, input devices, dialogs or network senders are started.
@MainActor enum RecordingEditorSelfTest {
    private struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
    static func run(editor e: EditorController, directory: URL) throws -> [String] {
        var checks: [String] = []
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw Failure(message: message) }
        }
        func required<T>(_ value: T?, _ message: String) throws -> T {
            guard let value else { throw Failure(message: message) }; return value
        }
        func passed(_ name: String) { checks.append(name) }
        func install(_ project: Project, name: String) throws {
            e.stopAutomationRecording(reason: "Install recording fixture"); e.stopShow(); e.lighting.stop()
            let url = directory.appendingPathComponent(name + ".aperturecue.json")
            try ProjectStore.save(project, to: url)
            e.dirty = false; e.openProject(url)
            try expect(e.project == project && !e.dirty && !e.history.canUndo, "Recording fixture failed to open cleanly")
        }
        func start(at anchor: Double, time: Double = 2) throws {
            e.seekShow(to: time, at: anchor); e.playShow(at: anchor)
            try e.startAutomationRecording(at: anchor)
            try expect(e.isRecordingAutomation && e.showRuntime.isPlaying, "Recording did not start against the future synthetic host anchor")
        }
        func pump(timeout: Double, condition: () -> Bool) -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            repeat {
                if condition() { return true }
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            } while Date() < deadline
            return condition()
        }
        defer {
            e.stopAutomationRecording(reason: "Recording checks complete"); e.stopShow(); e.lighting.stop()
            e.timelineWindow?.close(); e.timelineWindow = nil
        }
        let surface = Surface(name: "Original recording surface", output: Point2.unitQuad, opacity: 0.5, generator: "solid")
        let parameters = TimelineEngine.parameters
        let baseValues: [String: Double] = ["opacity": 0.5, "brightness": 1, "gamma": 1, "red": 1, "green": 1, "blue": 1]
        let tracks = parameters.map { parameter in
            AutomationTrack(name: "Record " + parameter, surfaceID: surface.id, parameter: parameter,
                            keyframes: [AutomationKeyframe(time: 0, value: baseValues[parameter]!), AutomationKeyframe(time: 10, value: baseValues[parameter]!)])
        }
        let scalarProject = Project(name: "Six scalar recording fixture", surfaces: [surface], timeline: tracks)
        let opacityID = try required(tracks.first(where: { $0.parameter == "opacity" })?.id, "Opacity track missing")

        let disabledSurface = Surface(name: "Disabled recording target")
        let dormant = Surface(name: "Dormant full snapshot target")
        let disabledTrack = AutomationTrack(name: "Disabled", surfaceID: disabledSurface.id, parameter: "opacity", keyframes: [AutomationKeyframe(time: 0, value: 1)], enabled: false)
        let dormantTrack = AutomationTrack(name: "Dormant", surfaceID: dormant.id, parameter: "brightness", keyframes: [AutomationKeyframe(time: 0, value: 1)])
        var armProject = scalarProject
        armProject.surfaces.append(disabledSurface); armProject.timeline += [disabledTrack, dormantTrack]
        armProject.cues = [Cue(name: "Dormant owner", surfaces: [dormant], duration: 0)]
        try install(armProject, name: "recording-ui")
        let ui = TimelineWindowController(editor: e); e.timelineWindow = ui
        ui.window?.orderOut(nil); ui.selectedTrackID = opacityID; ui.refresh()
        ui.window?.contentView?.layoutSubtreeIfNeeded()
        try expect(ui.window?.isVisible == false && ui.armTrackButton.isEnabled && !ui.recordInputButton.isEnabled, "Hidden recording UI did not gate Arm and Record against stopped playback")
        ui.armTrackButton.performClick(nil)
        try expect(e.armedRecordingTracks == [opacityID] && ui.armTrackButton.title == "Disarm selected" && !e.dirty && !e.history.canUndo && e.project == armProject, "Actual Arm callback changed the saved document/history or lost session state")
        for invalidID in [disabledTrack.id, dormantTrack.id] {
            var rejected = false
            do { try e.setRecordingArmed(trackID: invalidID, armed: true) } catch { rejected = true }
            try expect(rejected && !e.armedRecordingTracks.contains(invalidID), "Disabled or dormant track was eligible for recording")
        }
        let uiAnchor = ProcessInfo.processInfo.systemUptime + 1000
        e.seekShow(to: 2, at: uiAnchor); e.playShow(at: uiAnchor); ui.updatePlayhead()
        ui.recordInputButton.performClick(nil)
        try expect(e.isRecordingAutomation && ui.recordInputButton.title == "Stop recording", "Actual Record input callback failed to enter recording")
        ui.recordInputButton.performClick(nil); ui.disarmAllButton.performClick(nil)
        try expect(!e.isRecordingAutomation && e.armedRecordingTracks.isEmpty && !e.dirty && !e.history.canUndo && e.project == armProject, "Record/Stop with no inspector input or Disarm all changed the document")
        passed("hidden recording Arm/Record/Stop/Disarm callbacks are session-only and reject disabled/dormant targets")

        try install(scalarProject, name: "recording-six-scalars")
        for track in tracks { try e.setRecordingArmed(trackID: track.id, armed: true) }
        try start(at: ProcessInfo.processInfo.systemUptime + 1000, time: 4)
        let replacements: [String: Double] = ["opacity": 0.73, "brightness": 1.7, "gamma": 2.3, "red": 0.31, "green": 0.47, "blue": 0.59]
        for parameter in parameters {
            let slider = try required(e.recording.sliders[parameter], "Actual inspector AutomationSlider missing for " + parameter)
            slider.valueBlock?(replacements[parameter]!, nil)
            let track = try required(e.project.timeline.first { $0.parameter == parameter }, "Recorded scalar track disappeared")
            try expect(track.keyframes.contains { $0.time == 4 && $0.value == replacements[parameter]! && $0.interpolation == .linear }, "Inspector callback did not record the correct field/value: " + parameter)
            try expect(e.project.surfaces == [surface] && e.recording.gesture == nil && e.recording.labels[parameter]?.stringValue.contains("[REC]") == true, "Inspector recording changed base surface fields or left an open gesture: " + parameter)
        }
        let sixRecorded = e.project
        for _ in parameters { e.undoEdit() }
        try expect(e.project == scalarProject && !e.history.canUndo, "Six inspector input gestures did not produce exactly six Undo commands")
        for _ in parameters { e.redoEdit() }
        try expect(e.project == sixRecorded, "Redo did not restore all six independently recorded scalar tracks")
        passed("six production inspector slider callbacks record ordinary scalar keys without editing base surfaces and undo once per gesture")

        let outsideStart = AutomationKeyframe(time: 0, value: 0.1, interpolation: .bezier, control1: Point2(0.2, 0.1), control2: Point2(0.8, 0.9))
        let outsideEnd = AutomationKeyframe(time: 6, value: 0.6, interpolation: .hold, control1: Point2(0.1, 0.2), control2: Point2(0.9, 0.8))
        let lastKey = AutomationKeyframe(time: 10, value: 0.9)
        let spanTrack = AutomationTrack(name: "Touched span", surfaceID: surface.id, parameter: "opacity", keyframes: [outsideStart, AutomationKeyframe(time: 2, value: 0.2, interpolation: .hold), AutomationKeyframe(time: 3, value: 0.3), AutomationKeyframe(time: 4, value: 0.4, interpolation: .bezier), outsideEnd, lastKey])
        let spanProject = Project(name: "Recording inclusive span", surfaces: [surface], fixtures: [Fixture(name: "Recording light", points: [Point2(0.5, 0.5)])], timeline: [spanTrack])
        try install(spanProject, name: "recording-span")
        try e.setRecordingArmed(trackID: spanTrack.id, armed: true)
        let spanAnchor = ProcessInfo.processInfo.systemUptime + 1000
        try start(at: spanAnchor)
        let token = try required(e.beginAutomationGesture(surfaceID: surface.id, parameter: "opacity", at: spanAnchor), "Recording gesture did not acquire a token")
        e.recordAutomationValue(0.7, token: token, at: spanAnchor + 1)
        e.recordAutomationValue(0.8, token: token, at: spanAnchor + 2)
        try expect(e.project.surfaces == [surface] && e.effectiveSurfaces.first?.opacity == 0.8 && e.renderer.surfaces.first?.opacity == 0.8, "Active recording override did not reach production effective/editor surfaces")
        let bitmap = try required(e.renderer.snapshot(width: 32, height: 18), "Active recording Metal snapshot failed")
        let pixels = try required(bitmap.bitmapData, "Recording snapshot pixels unavailable")
        let pixelOffset = 9 * bitmap.bytesPerRow + 16 * 4
        try expect(abs(Int(pixels[pixelOffset]) - 204) <= 1, "Active recording override did not reach production Metal pixels")
        e.lighting.isSending = false; e.lighting.isSampling = true; e.lastLighting = 0; e.tick()
        try expect(pump(timeout: 5) {
            e.lastLighting = 0; e.tick()
            return e.lighting.renderer.surfaces == e.effectiveSurfaces && abs(Int(e.lighting.lastUniverses[1]?.first ?? 0) - 204) <= 1
        }, "Production GPU light sampling did not follow active recording opacity")
        e.lighting.stop()
        passed("active recording override reaches actual Metal pixels and GPU light sampling without base-field changes")
        e.endAutomationGesture(token: token, at: spanAnchor + 3)
        let expectedKeys = [outsideStart, AutomationKeyframe(time: 2, value: 0.2), AutomationKeyframe(time: 3, value: 0.7), AutomationKeyframe(time: 4, value: 0.8), AutomationKeyframe(time: 5, value: 0.8), outsideEnd, lastKey]
        try expect(e.project.timeline[0].keyframes == expectedKeys && e.project.surfaces == [surface] && e.history.undoLabel == "Record automation gesture", "Inclusive recording span or outside key metadata differs")
        let spanRecorded = e.project
        e.undoEdit(); try expect(e.project == spanProject && !e.history.canUndo, "Multi-sample recording was not exactly one Undo")
        e.redoEdit(); try expect(e.project == spanRecorded, "Redo did not restore the complete recorded span")
        passed("multi-sample recording replaces inclusive touched keys, retains outside metadata and commits one Undo/Redo")

        try install(spanProject, name: "recording-no-movement")
        try e.setRecordingArmed(trackID: spanTrack.id, armed: true)
        let idleAnchor = ProcessInfo.processInfo.systemUptime + 1000
        try start(at: idleAnchor)
        let idleToken = try required(e.beginAutomationGesture(surfaceID: surface.id, parameter: "opacity", at: idleAnchor), "No-movement gesture missing")
        e.recordAutomationValue(0.2, token: idleToken, at: idleAnchor + 1)
        e.endAutomationGesture(token: idleToken, at: idleAnchor + 2)
        e.advanceShow(at: idleAnchor + 3)
        try expect(e.project == spanProject && !e.dirty && !e.history.canUndo && e.window?.isDocumentEdited == false, "No-movement gesture or timer-only playback changed keys/history/dirty state")
        passed("no-movement recording gestures and timer-only playback remain clean history-free no-ops")

        let denseTrack=AutomationTrack(name:"Recording release budget",surfaceID:surface.id,parameter:"opacity",
            keyframes:(0..<4096).map {AutomationKeyframe(time:Double($0)*10/4095,value:0.2)})
        try install(Project(name:"Recording release budget",surfaces:[surface],timeline:[denseTrack]),name:"recording-release-budget")
        try e.setRecordingArmed(trackID:denseTrack.id,armed:true)
        let budgetAnchor=ProcessInfo.processInfo.systemUptime+1000
        try start(at:budgetAnchor,time:0)
        let budgetToken=try required(e.beginAutomationGesture(surfaceID:surface.id,parameter:"opacity",at:budgetAnchor),"Budget gesture missing")
        e.recordAutomationValue(0.6,token:budgetToken,at:budgetAnchor)
        let acceptedAtBudget=e.project
        e.endAutomationGesture(token:budgetToken,at:budgetAnchor+0.0001)
        try expect(!e.isRecordingAutomation && e.recordingMessage.contains("4096") && e.project==acceptedAtBudget && e.project.timeline[0].keyframes.count==4096,
                   "A mouse-up endpoint beyond the key budget did not stop cleanly and retain accepted keys")
        try ProjectStore.validate(e.project)
        e.recordAutomationValue(0.1,token:budgetToken,at:budgetAnchor+1)
        try expect(e.project==acceptedAtBudget,"Late input after release budget failure changed the accepted document")
        e.undoEdit()
        try expect(e.project.timeline==[denseTrack] && !e.history.canUndo,"Release budget interruption did not retain exactly one gesture command")
        passed("recording release key-budget failure stops atomically and retains accepted keys with one Undo")

        let stopTrack = AutomationTrack(name: "Discontinuity target", surfaceID: surface.id, parameter: "opacity", keyframes: [AutomationKeyframe(time: 0, value: 0.2), AutomationKeyframe(time: 10, value: 0.8)])
        for action in ["pause", "seek", "stop", "loop", "GO", "mutation"] {
            var project = Project(name: "Recording stop " + action, surfaces: [surface], cues: [Cue(name: "Stop recording scene", surfaces: [surface], duration: 0)], timeline: [stopTrack])
            if action == "loop" { project.timelineSettings.loopEnabled = true; project.timelineSettings.loopStart = 0; project.timelineSettings.loopEnd = 4 }
            try install(project, name: "recording-stop-" + action)
            try e.setRecordingArmed(trackID: stopTrack.id, armed: true)
            let anchor = ProcessInfo.processInfo.systemUptime + 1000
            try start(at: anchor)
            let oldSlider = try required(e.recording.sliders["opacity"], "Discontinuity fixture inspector missing")
            let oldToken = try required(e.beginAutomationGesture(surfaceID: surface.id, parameter: "opacity", at: anchor), "Discontinuity recording token missing")
            e.recordAutomationValue(0.77, token: oldToken, at: anchor + 1)
            switch action {
            case "pause": e.pauseShow(at: anchor + 2)
            case "seek": e.seekShow(to: 7, at: anchor + 2)
            case "stop": e.stopShow(at: anchor + 2)
            case "loop": e.advanceShow(at: anchor + 3)
            case "GO": e.goCue(index: 0); e.commitInterruptedCue()
            default: e.mutate("Recording test document edit") { $0.name = "Edited recording document" }
            }
            try expect(!e.isRecordingAutomation && e.recording.gesture == nil && e.recording.token == nil && e.armedRecordingTracks == [stopTrack.id], "Transport/document action did not finalize recording while retaining session arm: " + action)
            try expect(e.project.timeline[0].keyframes.contains { $0.time == 3 && $0.value == 0.77 }, "Transport/document action discarded published recording samples: " + action)
            let afterAction = e.project, undoLabel = e.history.undoLabel
            oldSlider.valueBlock?(0.04, oldToken); oldSlider.endBlock?(oldToken)
            e.recordAutomationValue(0.05, token: oldToken, at: anchor + 5)
            e.endAutomationGesture(token: oldToken, at: anchor + 5)
            try expect(e.project == afterAction && e.history.undoLabel == undoLabel && e.project.surfaces == [surface], "Late old recording token edited keys/base state after " + action)
            if action == "mutation" { e.undoEdit() }
            e.undoEdit(); try expect(e.project == project && !e.history.canUndo, "Stopped recording did not retain a single gesture command before " + action)
        }
        passed("pause/seek/stop/loop/GO/document edits finalize recording and absorb late native gesture tokens")

        try install(scalarProject, name: "recording-persistence-initial")
        try e.setRecordingArmed(trackID: opacityID, armed: true)
        let saveAnchor = ProcessInfo.processInfo.systemUptime + 1000
        try start(at: saveAnchor)
        let saveToken = try required(e.beginAutomationGesture(surfaceID: surface.id, parameter: "opacity", at: saveAnchor), "Persistence recording token missing")
        e.recordAutomationValue(0.65, token: saveToken, at: saveAnchor + 1)
        let activeRecoveryURL = directory.appendingPathComponent("recording-active-recovery.aperturecue.json")
        try ProjectStore.saveRecovery(e.project, for: activeRecoveryURL)
        let recoveredActive = try ProjectStore.loadRecovery(for: activeRecoveryURL)
        try expect(recoveredActive == e.project && recoveredActive.timeline[0].keyframes.contains { $0.time == 3 && $0.value == 0.65 } && e.recording.gesture != nil && !e.history.canUndo, "Active accepted recording samples were not ordinary recovery data before history commit")
        try FileManager.default.removeItem(at: ProjectStore.recoveryURL(for: activeRecoveryURL))
        e.endAutomationGesture(token: saveToken, at: saveAnchor + 2)
        let savedURL = directory.appendingPathComponent("recording-saved.aperturecue.json")
        e.saveTo(savedURL); let saved = e.project
        let json = try required(try JSONSerialization.jsonObject(with: Data(contentsOf: savedURL)) as? [String: Any], "Saved recording JSON object missing")
        let reloaded = try ProjectStore.load(from: savedURL)
        try expect(saved.version == Project.currentVersion && !e.dirty && !e.isRecordingAutomation && json["recording"] == nil && json["armedRecordingTracks"] == nil && reloaded == saved, "Recorded ordinary keys changed schema or persisted ephemeral recording/arm state")
        e.stopShow(at: saveAnchor + 20)
        try start(at: saveAnchor + 20)
        _ = e.beginAutomationGesture(surfaceID: surface.id, parameter: "opacity", at: saveAnchor + 20)
        e.newProject()
        try expect(e.project.name == "Untitled" && e.armedRecordingTracks.isEmpty && !e.isRecordingAutomation && e.recording.gesture == nil && e.showRuntime.time == 0 && !e.dirty, "Clean active no-movement New retained recording/session state")
        e.openProject(savedURL)
        try expect(e.project == saved && e.project.version == Project.currentVersion && e.armedRecordingTracks.isEmpty && !e.isRecordingAutomation && e.showRuntime.time == 0 && !e.history.canUndo, "Save/New/Open did not retain ordinary recording keys and clear session arm/runtime state")
        passed("active recording recovery and ordinary schema-6 Save/New/Open retain keys while session arming resets")
        return checks
    }
}
#endif
