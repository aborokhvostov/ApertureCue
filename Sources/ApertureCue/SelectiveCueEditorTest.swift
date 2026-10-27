#if os(macOS)
import AppKit
import MappingCore

/// Production controller and actual native control callbacks; all windows stay hidden.
@MainActor enum SelectiveCueEditorTest {
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
            let url = directory.appendingPathComponent(name + ".aperturecue.json")
            try ProjectStore.save(project, to: url)
            e.dirty = false; e.openProject(url)
        }
        defer { e.cueWindow?.window?.close(); e.cueWindow = nil; e.stopShow() }

        let a = Surface(name: "Selective hidden A", opacity: 0.25, brightness: 0.8, enabled: false)
        let b = Surface(name: "Selective B", opacity: 0.6, brightness: 1.2)
        try install(Project(name: "Selective editor fixture", surfaces: [a, b]), name: "selective-initial")
        e.selectedID = a.id
        let ui = CueWindowController(editor: e); e.cueWindow = ui
        ui.window?.orderOut(nil); ui.window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))
        try expect((ui.window?.frame.width ?? .infinity)<=1121 && (ui.window?.contentView?.bounds.width ?? .infinity)<=1121,"Cue labels expanded the requested window width")
        try expect(ui.window?.isVisible == false && ui.surfaceTable.numberOfRows == 2, "Selective cue editor was visible or did not populate its current surfaces")
        try expect(ui.draftBindings == [CueBinding(surfaceID: a.id, parameters: [.opacity])], "New draft did not default to opacity on the selected current surface")
        ui.surfaceTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try required(ui.checkboxes[.brightness], "Brightness checkbox missing").performClick(nil)
        ui.surfaceTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try expect(ui.checkboxes[.opacity]?.state == .on && ui.checkboxes[.brightness]?.state == .off, "Changing surface rows leaked the second surface field selection")
        ui.surfaceTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try expect(ui.checkboxes[.brightness]?.state == .on && ui.checkboxes[.opacity]?.state == .off, "Changing surface rows discarded a UUID-bound draft field selection")
        ui.nameField.stringValue = "UI selective capture"; ui.durationField.stringValue = "0"
        ui.captureSelectiveButton.performClick(nil)
        let cueID = try required(ui.selectedCueID, "Actual Capture selective callback did not select its new cue")
        var cue = try required(e.project.cues.first { $0.id == cueID }, "Selective capture missing")
        try expect(cue.scope == .selective && cue.bindings == [CueBinding(surfaceID: a.id, parameters: [.opacity]), CueBinding(surfaceID: b.id, parameters: [.brightness])], "Actual capture did not publish the two-surface field mask")
        try expect(cue.surfaces == [a, b] && !ui.scopePicker.isEnabled, "Selective capture did not store current values or saved scope remained editable")
        try expect((ui.window?.frame.width ?? .infinity)<=1121,"Stored cue values expanded the requested window width")
        passed("hidden native selective cue capture and stable per-surface checkbox callbacks")

        let c = Surface(name: "Later layer C", opacity: 0.4, brightness: 1.4)
        e.mutate("Alter selective live values") { project in
            project.surfaces[0].opacity = 0.9; project.surfaces[0].brightness = 2
            project.surfaces[1].brightness = 3
            project.surfaces = [project.surfaces[1], project.surfaces[0], c]
        }
        ui.selectCue(id: cueID)
        ui.surfaceTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try required(ui.checkboxes[.brightness], "Brightness checkbox disappeared").performClick(nil)
        let beforeMaskSave = e.project
        ui.nameField.stringValue = "Saved mask without capture"; ui.followField.stringValue = ""
        ui.saveButton.performClick(nil)
        cue = try required(e.project.cues.first { $0.id == cueID }, "Saved selective cue missing")
        try expect(cue.name == "Saved mask without capture" && cue.bindings.first?.parameters == [.opacity, .brightness], "Save callback did not publish metadata and changed field mask")
        try expect(cue.surfaces == [a, b], "Saving a selective mask implicitly recaptured live values")
        let afterMaskSave = e.project
        e.undoEdit(); try expect(e.project == beforeMaskSave, "Undo cue mask save did not restore the complete prior project")
        e.redoEdit(); try expect(e.project == afterMaskSave, "Redo cue mask save did not restore saved snapshot values and mask")
        do {
            try e.cueUpdate(id: cueID, name: "Invalid conversion", scope: .full, bindings: [], duration: 0, followAfter: nil)
            throw Failure(message: "Changing a saved cue scope was accepted")
        } catch is Failure { throw Failure(message: "Changing a saved cue scope was accepted") }
        catch { try expect(e.project == afterMaskSave, "Rejected cue scope conversion changed the document") }
        passed("cue mask Save keeps captured values, rejects scope conversion and has complete undo/redo")

        ui.recaptureButton.performClick(nil)
        cue = try required(e.project.cues.first { $0.id == cueID }, "Recaptured selective cue missing")
        try expect(cue.surfaces.first(where: { $0.id == a.id })?.opacity == 0.9 && cue.surfaces.first(where: { $0.id == a.id })?.brightness == 2 && cue.surfaces.first(where: { $0.id == b.id })?.brightness == 3, "Explicit Recapture callback did not replace its selected targets with current values")
        let afterRecapture = e.project
        e.undoEdit(); try expect(e.project == afterMaskSave, "Undo explicit recapture lost original stored values")
        e.redoEdit(); try expect(e.project == afterRecapture, "Redo explicit recapture lost newly captured values")
        passed("explicit native Recapture replaces stored values separately from mask Save with undo/redo")

        let track = AutomationTrack(name: "Selective opacity override", surfaceID: a.id, parameter: "opacity", keyframes: [AutomationKeyframe(time: 0, value: 0.3), AutomationKeyframe(time: 10, value: 0.6)])
        e.mutate("Prepare selective GO fixture") { project in
            let ai = project.surfaces.firstIndex { $0.id == a.id }!
            let bi = project.surfaces.firstIndex { $0.id == b.id }!
            project.surfaces[ai].opacity = 0.1; project.surfaces[ai].brightness = 4
            project.surfaces[ai].color = [0.2, 0.4, 0.6]
            project.surfaces[bi].brightness = 5; project.surfaces[bi].opacity = 0.45
            project.timeline = [track]; project.timelineSettings.stopAtEnd = false
        }
        e.seekShow(to: 4); e.playShow()
        let beforeGo = e.project, beforeTime = e.showRuntime.time
        ui.goButton.performClick(nil); e.tick()
        let recalledA = try required(e.project.surfaces.first { $0.id == a.id }, "Selective GO lost hidden target")
        let recalledB = try required(e.project.surfaces.first { $0.id == b.id }, "Selective GO lost second target")
        try expect(e.project.surfaces.map(\.id) == [b.id, a.id, c.id] && e.project.surfaces.last == c, "Selective GO changed current order or removed/changed a later layer")
        try expect(recalledA.opacity == 0.9 && recalledA.brightness == 2 && !recalledA.enabled && recalledA.color == [0.2, 0.4, 0.6] && recalledB.brightness == 3 && recalledB.opacity == 0.45, "Selective GO did not recall just included fields on hidden/current targets")
        try expect(e.project.timeline == [track] && e.showRuntime.isPlaying && e.media.isPlaying && e.showRuntime.time >= beforeTime && e.showRuntime.time < beforeTime + 2 && e.media.currentTime >= beforeTime, "Selective GO reset the running show/media clock or timeline")
        let effectiveA = try required(e.effectiveSurfaces.first { $0.id == a.id }, "Timeline effective target missing after selective GO")
        try expect(abs(effectiveA.opacity - (0.3 + 0.03 * e.showRuntime.time)) < 1e-9, "Timeline stopped overriding the selectively recalled base field")
        e.pauseShow(); let afterGo = e.project
        e.undoEdit(); try expect(e.project == beforeGo, "Selective GO did not undo in one document command")
        e.redoEdit(); try expect(e.project == afterGo, "Selective GO redo changed current layer order or untouched fields")
        passed("selective GO preserves hidden targets, current order, later layers, running clocks and active timeline overrides")

        let onlyMissing = try e.cueCreate(name: "Only missing target", scope: .selective, bindings: [CueBinding(surfaceID: a.id, parameters: [.opacity])], duration: 0, followAfter: nil)
        e.selectedID = a.id; e.deleteSurface()
        let missingURL = directory.appendingPathComponent("selective-missing.aperturecue.json")
        e.saveTo(missingURL)
        let beforeMissing = e.project, oldUndo = e.history.undoLabel
        let missingIndex = try required(e.project.cues.firstIndex { $0.id == onlyMissing }, "Missing-only cue removed with live surface")
        e.goCue(index: missingIndex); e.tick()
        try expect(e.project == beforeMissing && !e.dirty && e.window?.isDocumentEdited == false && e.history.undoLabel == oldUndo, "Missing-only selective GO dirtied or changed the document/history")
        try expect(!e.project.surfaces.contains { $0.id == a.id } && e.cueMessage.contains("1 missing"), "Missing selective target was resurrected or not reported")
        try expect(try ProjectStore.load(from: missingURL) == e.project, "Selective snapshot with missing target did not round-trip")
        passed("missing-only selective recall skips targets without resurrection, history entry or dirty state")

        let ghost = Surface(name: "Full-only timeline target")
        let full1 = Cue(name: "First full owner", surfaces: [ghost], duration: 0)
        let full2 = Cue(name: "Last full owner", surfaces: [ghost], duration: 0)
        let selectiveGhost = try CueSelection.capture(name: "Selective cannot recreate target", surfaces: [ghost], bindings: [CueBinding(surfaceID: ghost.id, parameters: [.opacity])], duration: 0)
        let orphanTrack = AutomationTrack(name: "Full snapshot target", surfaceID: ghost.id, parameter: "opacity", keyframes: [AutomationKeyframe(time: 0, value: 0.2), AutomationKeyframe(time: 10, value: 0.8)])
        var orphanProject = Project(name: "Cue deletion owners", surfaces: [b], cues: [full1, full2, selectiveGhost], timeline: [orphanTrack])
        orphanProject.timelineSettings.markers = [TimelineMarker(name: "First owner reference", time: 2, action: .cue, cueID: full1.id)]
        try install(orphanProject, name: "selective-owner-deletion")
        try e.cueDelete(id: full1.id)
        try expect(e.project.timeline == [orphanTrack] && e.project.timelineSettings.markers.isEmpty, "Deleting one full owner removed a still-valid track or left a cue marker")
        let beforeLastOwnerDelete = e.project
        try e.cueDelete(id: full2.id)
        try expect(e.project.timeline.isEmpty && e.project.cues == [selectiveGhost], "Deleting last full owner kept orphan automation through a selective snapshot")
        try ProjectStore.validate(e.project)
        e.undoEdit(); try expect(e.project == beforeLastOwnerDelete, "Undo last full owner deletion did not restore its orphan track")
        e.undoEdit(); try expect(e.project == orphanProject, "Undo first full owner deletion did not restore cue marker and full snapshots")
        e.redoEdit(); e.redoEdit()
        try expect(e.project.timeline.isEmpty && e.project.cues == [selectiveGhost], "Redo full owner deletion did not prune orphan tracks")
        passed("full-cue deletion retains other owners then atomically prunes orphan tracks and markers with undo/redo")

        let mediaDirectory=directory.appendingPathComponent("selective-generated-media",isDirectory:true)
        try DemoGenerator.generate(at:mediaDirectory)
        var movieProject=try ProjectStore.load(from:mediaDirectory.appendingPathComponent("Demo.aperturecue.json"))
        let movie=try required(movieProject.assets.first {$0.kind == "video"},"Generated movie missing")
        movieProject.surfaces[0].mediaID=movie.id
        movieProject.surfaces[0].opacity=0.2
        movieProject.cues=[try CueSelection.capture(name:"Movie opacity only",surfaces:movieProject.surfaces,
            bindings:[CueBinding(surfaceID:movieProject.surfaces[0].id,parameters:[.opacity])],duration:0)]
        try install(movieProject,name:"selective-running-movie")
        func pump(_ timeout:Double,_ condition:()->Bool)->Bool {
            let deadline=ProcessInfo.processInfo.systemUptime+timeout
            repeat {
                if condition() {return true}
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01))
            } while ProcessInfo.processInfo.systemUptime < deadline
            return condition()
        }
        try expect(pump(12) {e.media.duration(for:movie.id)>2.9},"Selective movie decoder did not become ready")
        e.mutate("Change live movie opacity") {$0.surfaces[0].opacity=0.9}
        e.seekShow(to:0.5);e.playShow()
        try expect(pump(8) {e.media.texture(for:movie.id) != nil && e.media.playbackTime(for:movie.id)>0.65},"Selective movie did not decode while playing")
        let movieTime=e.media.playbackTime(for:movie.id),showTime=e.showRuntime.time
        e.goCue(index:0);e.tick()
        try expect(e.project.surfaces[0].mediaID==movie.id && e.project.surfaces[0].opacity==0.2 && e.media.isPlaying && e.showRuntime.isPlaying,
                   "Source-excluding selective cue changed source or stopped playback")
        try expect(e.showRuntime.time>=showTime && e.media.playbackTime(for:movie.id)>=movieTime-0.08,"Selective GO restarted the decoded movie/show clock")
        try expect(pump(2) {e.media.texture(for:movie.id) != nil && e.media.playbackTime(for:movie.id)>movieTime+0.15},"Decoded movie did not continue after selective GO")
        e.pauseShow()
        passed("source-excluding selective recall preserves a running generated H.264 decoder and show clock")
        return checks
    }
}
#endif
