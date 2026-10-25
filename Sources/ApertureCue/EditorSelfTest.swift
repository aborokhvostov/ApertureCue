#if os(macOS)
import AppKit
import MetalKit
import QuartzCore
import MappingCore

/// Integration checks through the production editor controller and document methods.
/// All windows belong to this test process and remain hidden. No dialogs, fullscreen
/// output, camera authorization, network start, or interaction with another app occurs.
@MainActor
enum EditorSelfTest {
    private struct Failure:LocalizedError {
        var message:String
        var errorDescription:String? { message }
    }

    static func run() -> Int32 {
        let base=URL(fileURLWithPath:FileManager.default.currentDirectoryPath,isDirectory:true)
            .appendingPathComponent("artifacts/local/editor-test",isDirectory:true)
        let directory=base.appendingPathComponent(UUID().uuidString,isDirectory:true)
        var checks:[String]=[]
        var report:[String:Any]=[
            "schemaVersion":1,"timestampUTC":ISO8601DateFormatter().string(from:Date()),
            "platform":ProcessInfo.processInfo.operatingSystemVersionString,
            "scope":"Production EditorController and hidden output renderer integration; no external application, visible output, or hardware interaction.",
            "hardwareVerification":false,"windowsShown":false,"modalDialogs":false
        ]
        var editor:EditorController?
        defer {
            editor?.timer?.invalidate(); editor?.timer=nil
            editor?.network?.stop(); editor?.midi?.stop(); editor?.lighting?.stop()
            editor?.media.pause(); editor?.media.reconcile(assets:[],baseURL:directory)
            editor?.closeOutputs(); editor?.dirty=false; editor?.window?.close()
        }
        func expect(_ condition:@autoclosure()throws->Bool,_ message:String) throws {
            guard try condition() else { throw Failure(message:message) }
        }
        func passed(_ name:String) { checks.append(name); print("PASS editor: \(name)") }
        func writeReport() throws {
            report["checks"]=checks; report["checkCount"]=checks.count
            let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:directory.appendingPathComponent("editor-test.json"),options:.atomic)
            try data.write(to:base.appendingPathComponent("report.json"),options:.atomic)
        }
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let app=NSApplication.shared
            app.setActivationPolicy(.prohibited)
            guard let device=MTLCreateSystemDefaultDevice() else { throw Failure(message:"No Metal device in this desktop session") }
            report["gpu"]=device.name
            let e=EditorController(); editor=e
            e.timer?.invalidate(); e.timer=nil
            e.window?.isReleasedWhenClosed=false; e.window?.orderOut(nil)
            e.metalView.isPaused=true; e.lightingView.isPaused=true
            try expect(e.renderer != nil,"Editor renderer initialization failed")
            try expect(e.window?.isVisible == false,"Editor test window became visible")
            try ProjectStore.validate(e.project)
            passed("hidden editor startup with valid demo project")

            let initialCount=e.project.surfaces.count
            e.addSurface()
            let addedID=try required(e.selectedID,"Add surface did not select its new ID")
            try expect(e.project.surfaces.count == initialCount+1 && e.project.surfaces.last?.id == addedID,"Add surface did not create/select a layer")
            let added=try required(e.project.surfaces.last,"Added surface missing")
            e.duplicateSurface()
            let copied=try required(e.project.surfaces.last,"Duplicate missing")
            try expect(copied.id != added.id && copied.output == added.output && copied.input == added.input,"Duplicate did not preserve geometry with a unique ID")
            try expect(e.selectedID == copied.id && e.project.surfaces.count == initialCount+2,"Duplicate selection/count differs")
            e.deleteSurface()
            try expect(!e.project.surfaces.contains { $0.id == copied.id },"Delete retained its selected layer")
            e.undoEdit()
            try expect(e.project.surfaces.contains { $0.id == copied.id },"Undo did not restore deleted layer")
            e.redoEdit()
            try expect(!e.project.surfaces.contains { $0.id == copied.id } && e.history.canUndo,"Redo did not repeat deletion")
            try ProjectStore.validate(e.project)
            passed("add, duplicate, delete and controller undo/redo")

            e.selectedID=addedID; e.refresh()
            let output=[Point2(0.04,0.11),Point2(0.92,0.19),Point2(0.82,0.92),Point2(0.14,0.83)]
            let beforeOutput=e.project
            e.overlay.onBegin?(); e.overlay.onChange?(addedID,output,false,false); e.overlay.onEnd?()
            let editedIndex=try required(e.selectedIndex,"Output edit lost selection")
            try expect(e.project.surfaces[editedIndex].output == output,"Output drag callback did not edit geometry")
            try expect(e.project.surfaces[editedIndex].input == added.input,"Output drag changed input crop")
            try expect(e.history.undoLabel == "Move control point","Drag was not recorded as a single editor command")
            e.undoEdit(); try expect(e.project == beforeOutput,"Undo did not restore the complete pre-drag project")
            e.redoEdit(); try expect(e.project.surfaces[editedIndex].output == output,"Redo did not restore output geometry")
            let crop=[Point2(0.2,0.25),Point2(0.8,0.25),Point2(0.8,0.75),Point2(0.2,0.75)]
            e.modePicker.selectItem(at:1)
            e.overlay.onBegin?(); e.overlay.onChange?(addedID,crop,true,false); e.overlay.onEnd?()
            try expect(e.project.surfaces[editedIndex].input == crop && e.project.surfaces[editedIndex].output == output,"Input crop is not independent from output geometry")
            e.modePicker.selectItem(at:0); e.updateRender()
            try ProjectStore.validate(e.project)
            passed("production overlay callbacks edit independent input/output with command history")

            let track=AutomationTrack(name:"Editor fade",surfaceID:addedID,parameter:"opacity",keyframes:[AutomationKeyframe(time:0,value:0),AutomationKeyframe(time:10,value:1)])
            e.mutate("Add test automation") { $0.timeline.append(track) }
            e.media.seek(to:5)
            let effective=try required(e.effectiveSurfaces.first { $0.id == addedID },"Automated surface missing")
            try expect(abs(effective.opacity-0.5)<1e-12,"Controller did not apply timeline at current seek time")
            e.deleteSurface()
            try expect(e.project.timeline.isEmpty && !e.project.surfaces.contains { $0.id == addedID },"Surface deletion retained its automation track")
            e.undoEdit(); try expect(e.project.timeline == [track],"Undo did not restore the deleted surface's track")
            e.redoEdit(); try expect(e.project.timeline.isEmpty,"Redo did not remove restored track")
            try ProjectStore.validate(e.project)
            passed("timeline sampling follows seek; delete/undo/redo keep target bindings consistent")

            let imageURL=directory.appendingPathComponent("editor-source.png")
            try makeImage(at:imageURL)
            let asset=MediaAsset(name:"Editor source",path:imageURL.path,kind:"image")
            e.selectedID=e.project.surfaces.first?.id
            e.mutate("Import editor test resource") { $0.assets.append(asset) }
            e.selectedMediaID=asset.id; e.assignMedia()
            try expect(e.project.surfaces.first?.mediaID == asset.id,"Assign media did not bind the selected resource")
            try expect(pump(timeout:8) { e.media.texture(for:asset.id) != nil },"Editor image resource did not load: \(e.media.errorMessages)")
            try expect(e.media.errorMessages[asset.id] == nil,"Valid editor PNG produced a media error")
            try ProjectStore.validate(e.project)
            passed("controller media import mutation, assignment and asynchronous texture load")

            let projectURL=directory.appendingPathComponent("workflow.aperturecue.json")
            try ProjectStore.validate(e.project)
            e.saveTo(projectURL)
            let saved=try ProjectStore.load(from:projectURL)
            try expect(saved == e.project && e.projectURL == projectURL && !e.dirty,"saveTo did not persist/mark the current document clean")
            try expect(e.window?.isDocumentEdited == false && !(e.window?.title.contains(" •") ?? true),"Saved window still displays an unsaved marker")
            var recovery=saved; recovery.name="Recovery-only editor fixture"
            try ProjectStore.saveRecovery(recovery,for:projectURL)
            try expect(try ProjectStore.loadRecovery(for:projectURL).name == recovery.name,"Recovery sidecar did not persist its distinct snapshot")
            try expect(try ProjectStore.load(from:projectURL) == saved,"Writing recovery changed the saved project")
            e.saveTo(projectURL)
            try expect(!FileManager.default.fileExists(atPath:ProjectStore.recoveryURL(for:projectURL).path),"Successful save did not clear its recovery sidecar")
            passed("document save marks clean and preserves separate recovery; next save removes sidecar")

            e.media.seek(to:8); e.media.play()
            e.dirty=false // The fixture explicitly chooses discard without opening a user-facing alert.
            e.newProject(); e.tick()
            try expect(e.project.name == "Untitled" && e.projectURL == nil && !e.dirty,"newProject did not replace the document cleanly")
            try expect(!e.history.canUndo && !e.history.canRedo && e.selectedID == e.project.surfaces.first?.id,"newProject retained old history or selection")
            try expect(e.selectedMediaID == nil || e.project.assets.contains { $0.id == e.selectedMediaID },"newProject retained a selected media ID from the previous document")
            try expect(!e.media.isPlaying && e.media.currentTime == 0 && e.media.loadedAssetCount == 0,"newProject retained old playback state or decoder entries")
            try expect(e.seekSlider.doubleValue == 0 && e.timeLabel.stringValue.hasPrefix("00:00"),"New document displays a stale seek/time value")
            try ProjectStore.validate(e.project)
            passed("new document clears media, playback time, history, URL and selection")

            e.addSurface(); try expect(e.history.canUndo,"Open fixture did not establish old history")
            e.media.seek(to:123); e.media.play(); e.dirty=false
            // There is deliberately no recovery sidecar, so openProject cannot present a restore alert.
            e.openProject(projectURL); e.tick()
            try expect(e.project == saved && e.projectURL == projectURL && !e.dirty,"openProject did not restore the saved document")
            try expect(e.selectedID == saved.surfaces.first?.id && !e.history.canUndo && !e.history.canRedo,"openProject did not reset selection/history")
            try expect(!e.media.isPlaying && e.media.currentTime == 0 && e.seekSlider.doubleValue == 0,"openProject retained previous document playback or seek")
            try expect((e.window?.title.contains(saved.name) ?? false) && e.window?.isDocumentEdited == false,"Opened document title/dirty state differs")
            try expect(pump(timeout:8) { e.media.texture(for:asset.id) != nil },"Reopened document did not resolve its saved image")
            try ProjectStore.validate(e.project)
            passed("open document restores resources and title while resetting history, selection and transport")

            let config=try required(e.project.outputs.first,"Output fixture configuration is missing")
            let outputWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:256,height:144),styleMask:[.titled],backing:.buffered,defer:false)
            outputWindow.isReleasedWhenClosed=false
            let view=MTKView(frame:NSRect(x:0,y:0,width:256,height:144),device:device)
            guard let output=MetalRenderer(view:view,media:e.media) else { throw Failure(message:MetalRenderer.lastInitializationError) }
            view.isPaused=true; outputWindow.contentView=view; output.outputID=config.id
            e.outputWindows[config.id]=(outputWindow,output)
            e.toggleBlackout()
            try expect(output.blackout && !e.renderer.blackout && output.surfaces == e.effectiveSurfaces,"Editor did not propagate blackout/effective surfaces to its independent output")
            try expect(output.media === e.media && !outputWindow.isVisible,"Hidden output did not share the editor media pool or became visible")
            guard let black=output.snapshot(width:32,height:18),let pixels=black.bitmapData else { throw Failure(message:"Hidden output blackout snapshot failed") }
            let offset=9*black.bytesPerRow+16*4
            try expect(pixels[offset] == 0 && pixels[offset+1] == 0 && pixels[offset+2] == 0,"Output blackout did not reach the production Metal render")
            e.toggleBlackout(); e.closeOutputs()
            try expect(e.outputWindows.isEmpty && !outputWindow.isVisible,"closeOutputs retained an output window")
            try expect(e.window?.isVisible == false,"Editor test showed its window during document operations")
            try ProjectStore.validate(e.project)
            passed("hidden independent output shares media, receives blackout and closes without fullscreen")

            report["passed"]=true; report["documentSurfaceCount"]=saved.surfaces.count
            report["documentAssetCount"]=saved.assets.count; report["nativeScreenCount"]=NSScreen.screens.count
            try writeReport()
            print("PASS editor integration: \(checks.count) checks. \(directory.appendingPathComponent("editor-test.json").path)")
            return 0
        } catch {
            report["passed"]=false; report["failure"]=error.localizedDescription
            try? writeReport()
            fputs("EDITOR TEST FAILED: \(error.localizedDescription)\n",stderr)
            return 1
        }
    }

    private static func required<T>(_ value:T?,_ message:String) throws -> T {
        guard let value else { throw Failure(message:message) }; return value
    }
    private static func pump(timeout:Double,condition:()->Bool) -> Bool {
        let deadline=CACurrentMediaTime()+timeout
        repeat {
            if condition() { return true }
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01))
        } while CACurrentMediaTime()<deadline
        return condition()
    }
    private static func makeImage(at url:URL) throws {
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bitmapFormat:.alphaNonpremultiplied,bytesPerRow:32,bitsPerPixel:32),let bytes=bitmap.bitmapData else { throw Failure(message:"Editor fixture PNG allocation failed") }
        for y in 0..<8 { for x in 0..<8 {
            let offset=y*32+x*4
            bytes[offset]=UInt8(x*32); bytes[offset+1]=UInt8(y*32); bytes[offset+2]=128; bytes[offset+3]=255
        } }
        guard let png=bitmap.representation(using:.png,properties:[:]) else { throw Failure(message:"Editor fixture PNG encoding failed") }
        try png.write(to:url,options:.atomic)
    }
}
#endif
