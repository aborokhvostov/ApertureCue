#if os(macOS)
import AppKit
import MetalKit
import QuartzCore
import MappingCore

/// Production callbacks on EditorSelfTest's disposable stopped controller.
/// A missing original movie is deliberate here: these command/state checks do
/// not claim decoder coverage. Sequence fixtures are original generated PNGs.
@MainActor enum MediaSourceEditorSelfTest {
    private struct Failure:LocalizedError {let message:String;var errorDescription:String? {message}}
    static func runStandalone()->Int32 {
        let started=CACurrentMediaTime()
        let base=URL(fileURLWithPath:FileManager.default.currentDirectoryPath,isDirectory:true)
            .appendingPathComponent("artifacts/local/source-editor",isDirectory:true)
        let directory=base.appendingPathComponent(UUID().uuidString,isDirectory:true)
        var editor:EditorController?,checks:[String]=[]
        var report:[String:Any]=[
            "schemaVersion":1,"timestampUTC":ISO8601DateFormatter().string(from:Date()),
            "platform":ProcessInfo.processInfo.operatingSystemVersionString,
            "scope":"Production source/editor commands, hidden Sources window callbacks, original PNG/MOV fixtures, schema-13 persistence and bound recovery; focused independent harness",
            "hardwareVerification":false,"windowsShown":false,"modalDialogs":false,
            "fixtureDirectory":directory.lastPathComponent,
            "limitations":"Automatic hidden native callbacks, not manual GUI evidence. No user project, camera, external display, physical audio/MIDI/light device, audible-output or long-show claim. The dedicated process durability mode checks forced termination separately."
        ]
        defer {
            if let e=editor {
                e.timer?.invalidate();e.timer=nil;e.network?.stop();e.midi?.stop();e.lighting?.stop()
                e.sourceWindow?.close();e.sourceWindow=nil;e.closeOutputs();e.montagePool?.reset();e.feedback?.reset()
                e.media?.pause();e.media?.reset();e.dirty=false;e.recoveryDecision=nil
                e.window?.delegate=nil;e.window?.close()
            }
        }
        func save(_ success:Bool,_ failure:String?=nil) {
            report["passed"]=success;report["checks"]=checks;report["checkCount"]=checks.count
            report["elapsedSeconds"]=CACurrentMediaTime()-started
            if let failure {report["failure"]=failure}
            do {
                try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
                let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
                try data.write(to:base.appendingPathComponent("report.json"),options:.atomic)
                if FileManager.default.fileExists(atPath:directory.path) {try data.write(to:directory.appendingPathComponent("report.json"),options:.atomic)}
            } catch {fputs("Source editor report failed: \(error.localizedDescription)\n",stderr)}
        }
        do {
            try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
            NSApplication.shared.setActivationPolicy(.prohibited)
            guard let device=MTLCreateSystemDefaultDevice() else {throw Failure(message:"No Metal device in this desktop session")}
            report["gpu"]=device.name
            let e=EditorController();editor=e
            e.timer?.invalidate();e.timer=nil;e.network?.stop();e.midi?.stop();e.lighting?.stop()
            e.window?.isReleasedWhenClosed=false;e.window?.orderOut(nil)
            e.metalView.isPaused=true;e.lightingView.isPaused=true
            guard e.renderer != nil,e.media != nil,e.window?.isVisible==false else {throw Failure(message:"Hidden source editor did not initialize its production renderer/media")}
            checks=try run(editor:e,directory:directory)
            save(true);print("PASS source editor integration: \(checks.count) checks. \(base.appendingPathComponent("report.json").path)")
            return 0
        } catch {
            save(false,error.localizedDescription)
            fputs("FAIL source editor integration: \(error.localizedDescription)\n",stderr)
            return 1
        }
    }
    static func run(editor e:EditorController,directory:URL)throws->[String] {
        let original=e.project,originalURL=e.projectURL,originalBaseline=e.recoveryBaseline
        let originalSelected=e.selectedID,originalMedia=e.selectedMediaID,originalGroup=e.selectedGroupID
        let originalDirty=e.dirty,originalGeneration=e.documentGeneration,originalMode=e.modePicker.indexOfSelectedItem
        let originalWork=e.workMessage,originalError=e.editError,originalDecision=e.recoveryDecision
        let originalBlackout=e.blackout,originalRenderOutput=e.renderer.outputID
        var checks:[String]=[]
        func expect(_ value:@autoclosure()throws->Bool,_ message:String)throws {if try !value() {throw Failure(message:message)}}
        func required<T>(_ value:T?,_ message:String)throws->T {guard let value else {throw Failure(message:message)};return value}
        func pass(_ message:String) {checks.append(message);print("PASS source editor: "+message)}
        func pump(_ seconds:Double) {let end=CACurrentMediaTime()+seconds;repeat {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005))} while CACurrentMediaTime()<end}
        func stop() {
            e.sourceWindow?.close();e.sourceWindow=nil;e.closeOutputs();e.overlay.finishDrag();e.cueEngine.cancel();e.cueTarget=nil;e.cueBefore=nil
            e.showRuntime.stop();e.media.pause();e.media.reset();e.montagePool.reset();e.feedback?.reset();e.history.clear();e.dragBefore=nil
        }
        func install(_ project:Project,selected:UUID?) {
            stop();e.project=project;e.projectURL=nil;e.recoveryBaseline=nil;e.selectedID=selected;e.selectedMediaID=nil;e.selectedGroupID=nil
            e.documentGeneration=UUID();e.dirty=false;e.workMessage="";e.editError="";e.blackout=false;e.renderer.outputID=nil
            e.modePicker.selectItem(at:0);e.overlay.pathMode=false;e.overlay.meshMode=false;e.overlay.maskMode=false;e.overlay.warpMode=false;e.overlay.drawMode=false
            e.reconcile();e.refresh()
        }
        defer {
            stop();e.project=original;e.projectURL=originalURL;e.recoveryBaseline=originalBaseline;e.selectedID=originalSelected
            e.selectedMediaID=originalMedia;e.selectedGroupID=originalGroup;e.dirty=originalDirty;e.documentGeneration=originalGeneration
            e.recoveryDecision=originalDecision;e.workMessage=originalWork;e.editError=originalError;e.blackout=originalBlackout;e.renderer.outputID=originalRenderOutput
            e.modePicker.selectItem(at:originalMode);e.reconcile();e.refresh()
        }
        let folder=directory.appendingPathComponent("source-editor-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let movie=MediaAsset(name:"Original missing-file state fixture",path:folder.appendingPathComponent("missing-original.mov").path,kind:"video",volume:0)
        var surface=Surface(name:"Retained source geometry",mediaID:movie.id,input:[Point2(0.1,0.15),Point2(0.8,0.15),Point2(0.8,0.9),Point2(0.1,0.9)],output:Point2.insetQuad)
        surface.meshColumns=2;surface.meshRows=2;surface.mesh=try Geometry.regularMesh(quad:surface.output,columns:2,rows:2)
        surface.mask=[Point2(0.1,0.1),Point2(0.9,0.1),Point2(0.6,0.9)]
        let project=Project(name:"Original source editor fixture",assets:[movie],surfaces:[surface])
        install(project,selected:surface.id)
        let playback=MediaPlaybackSettings(trimIn:0.2,trimOut:2,rate:-0.5,mode:.pingPong,randomSeed:42,randomInterval:0.125)
        try e.sourceSettings(id:movie.id,playback:playback)
        let afterPlayback=e.project
        try expect(afterPlayback.assets[0].playback==playback && afterPlayback.surfaces==[surface],"Source settings changed geometry or lost playback data")
        e.undoEdit();try expect(e.project==project,"Source settings Undo did not retain the previous document")
        e.redoEdit();try expect(e.project==afterPlayback,"Source settings Redo differed")
        let route=AudioRoutingSettings(inputChannels:2,outputChannels:2,gains:[0,1,1,0],muted:true,enabled:false)
        try e.sourceRouting(id:movie.id,routing:route)
        let afterRouting=e.project
        e.undoEdit();try expect(e.project==afterPlayback,"Routing Undo changed another source property")
        e.redoEdit();try expect(e.project==afterRouting && e.project.surfaces==[surface],"Routing Redo or retained geometry differs")
        let undo=e.history.undoLabel
        var failed=false;do {try e.sourceSettings(id:movie.id,playback:.init(rate:.nan))} catch {failed=true}
        try expect(failed && e.project==afterRouting && e.history.undoLabel==undo,"Invalid source settings partially changed document/history")
        failed=false;do {try e.sourceRouting(id:movie.id,routing:.init(inputChannels:2,outputChannels:2,gains:[1]))} catch {failed=true}
        try expect(failed && e.project==afterRouting && e.history.undoLabel==undo,"Invalid audio route partially changed document/history")
        pass("source playback and audio-routing callbacks preserve geometry, validate atomically and support Undo/Redo")

        e.selectedMediaID=movie.id
        let window=MediaSourceWindow(editor:e);e.sourceWindow=window;window.refresh();window.window?.orderOut(nil)
        func views(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(views)}
        func button(_ title:String)throws->ActionButton {
            let content=try required(window.window?.contentView,"Source window has no content")
            return try required(views(content).compactMap {$0 as? ActionButton}.first(where:{$0.title==title}),"Missing source window callback: "+title)
        }
        let sourceContent=try required(window.window?.contentView,"Sources content is absent")
        sourceContent.layoutSubtreeIfNeeded()
        let scrollable=views(sourceContent).compactMap {$0 as? NSScrollView}.contains {$0.hasVerticalScroller}
        let fitting=sourceContent.subviews.first?.fittingSize.height ?? 0
        try expect(scrollable || fitting<=sourceContent.bounds.height+1,"Sources controls exceed the window without a vertical scroll path")
        let originalMaster=e.media.currentTime,originalSourceProject=e.project
        let seekButton=try button("Seek source")
        let seekRow=try required(seekButton.superview as? NSStackView,"Source seek row is absent")
        let seekField=try required(seekRow.arrangedSubviews.compactMap {$0 as? ActionField}.first,"Source seek field is absent")
        seekField.stringValue="0.625";seekButton.performClick(nil)
        try expect(!e.media.sourceFollowsMaster(for:movie.id) && abs(e.media.sourceElapsedTime(for:movie.id)-0.625)<1e-9 && e.media.currentTime==originalMaster,"Source Seek moved master time or failed independent position")
        try button("Play source").performClick(nil);pump(0.04)
        try button("Pause source").performClick(nil)
        let paused=e.media.sourceElapsedTime(for:movie.id);pump(0.02)
        try expect(paused>0.625 && abs(e.media.sourceElapsedTime(for:movie.id)-paused)<1e-9 && e.media.currentTime==originalMaster,"Source Play/Pause did not isolate and retain its elapsed clock")
        seekField.stringValue="nan";seekButton.performClick(nil)
        try expect(e.media.sourceElapsedTime(for:movie.id)==paused,"Nonfinite source seek changed transport")
        try button("Follow master").performClick(nil)
        try expect(e.media.sourceFollowsMaster(for:movie.id) && e.media.sourceElapsedTime(for:movie.id)==originalMaster && e.project==originalSourceProject,"Follow master or runtime buttons changed saved source state")
        let staleSave=try button("Save source settings")
        let sourceDocument=e.project;e.documentGeneration=UUID();let noOpUndo=e.history.undoLabel
        staleSave.performClick(nil)
        try expect(e.project==sourceDocument && e.history.undoLabel==noOpUndo,"An old source-window callback edited a changed document generation")
        window.close();e.sourceWindow=nil
        pass("hidden Sources window Play/Pause/Seek/Follow actions isolate the source clock and reject obsolete document callbacks")

        let sequenceFolder=folder.appendingPathComponent("original-frames",isDirectory:true)
        try FileManager.default.createDirectory(at:sequenceFolder,withIntermediateDirectories:false)
        let names=["frame10.png","frame2.png","frame001.png"]
        for (index,name) in names.enumerated() {
            guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bitmapFormat:.alphaNonpremultiplied,bytesPerRow:0,bitsPerPixel:0),let pixels=bitmap.bitmapData else {throw Failure(message:"Cannot allocate original PNG fixture")}
            for y in 0..<8 {for x in 0..<8 {let offset=y*bitmap.bytesPerRow+x*4;pixels[offset]=UInt8(40+index*60);pixels[offset+1]=UInt8(x*24);pixels[offset+2]=UInt8(y*24);pixels[offset+3]=255}}
            let data=try required(bitmap.representation(using:.png,properties:[:]),"Cannot encode original PNG fixture")
            try data.write(to:sequenceFolder.appendingPathComponent(name))
        }
        let manifest=try EditorController.sequenceManifest(at:sequenceFolder,fps:12.5)
        try expect(manifest.frames==["frame001.png","frame2.png","frame10.png"],"Sequence manifest did not retain deterministic numeric ordering")
        let beforeSequence=e.project
        try e.addSequence(directory:sequenceFolder,manifest:manifest)
        let afterSequence=e.project,sequence=try required(e.project.assets.last,"Imported sequence is absent")
        var assigned=surface;assigned.mediaID=sequence.id
        try expect(sequence.kind=="sequence" && sequence.sequence==manifest && e.project.surfaces==[assigned] && e.selectedID==surface.id,"Sequence import changed geometry, selection or the frozen manifest")
        e.undoEdit();try expect(e.project==beforeSequence,"Sequence import Undo differs")
        e.redoEdit();try expect(e.project==afterSequence,"Sequence import Redo differs")
        let later=sequenceFolder.appendingPathComponent("frame20.png")
        try Data(contentsOf:sequenceFolder.appendingPathComponent(names[0])).write(to:later)
        try expect(e.project.assets.last?.sequence?.frames.count==3,"Directory addition silently changed the saved sequence manifest")
        try e.refreshSequence(id:sequence.id)
        try expect(e.project.assets.last?.sequence?.frames==manifest.frames+["frame20.png"],"Explicit sequence refresh did not append the naturally sorted new frame")
        e.undoEdit();try expect(e.project==afterSequence,"Manifest refresh Undo differs")
        e.redoEdit();let refreshed=e.project
        try expect(refreshed.surfaces==[assigned],"Manifest refresh changed source assignment or geometry")
        pass("original PNG folder import freezes numeric order, retains geometry/history and admits new frames only by explicit refresh")

        let actualMovie=folder.appendingPathComponent("original-generated.mov")
        try MontageSelfTest.makeMovie(at:actualMovie,fps:2)
        let managedAsset=MediaAsset(name:"Original managed visibility fixture",path:actualMovie.path,kind:"video",volume:0,playback:.init(mode:.hold))
        var animated=Surface(name:"Automation reveals zero-base-opacity video",mediaID:managedAsset.id);animated.opacity=0
        let opacity=AutomationTrack(name:"Visible through automation",surfaceID:animated.id,parameter:"opacity",keyframes:[AutomationKeyframe(time:0,value:1)])
        install(Project(name:"Original media demand fixture",assets:[managedAsset],surfaces:[animated],timeline:[opacity]),selected:animated.id)
        let frameDeadline=CACurrentMediaTime()+20
        var textureReady=false
        repeat {
            e.updateRender();e.media.update()
            textureReady=e.media.texture(for:managedAsset.id) != nil
            if textureReady {break}
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005))
        } while CACurrentMediaTime()<frameDeadline
        try expect(e.project.surfaces[0].opacity==0 && e.effectiveSurfaces[0].opacity==1 && textureReady && e.media.presentationTime(for:managedAsset.id) != nil,
                   "Effective opacity automation failed to admit a managed decoder for a base-zero layer")
        pass("effective opacity automation admits and decodes original managed MOV frames even when the saved base opacity is zero")
        install(refreshed,selected:surface.id)

        let portable=folder.appendingPathComponent("portable-copy",isDirectory:true)
        var collectible=e.project
        collectible.assets[0].path=actualMovie.path
        let collectedURL=try ProjectStore.collect(collectible,to:portable)
        let collected=try ProjectStore.load(from:collectedURL)
        try expect(collected.assets.map(\.id)==collectible.assets.map(\.id) && collected.surfaces==collectible.surfaces && collected.assets.last?.sequence==collectible.assets.last?.sequence,"Collected media state or assignment changed")
        let collectedSequence=try required(collected.assets.last,"Collected sequence absent")
        try expect(collectedSequence.path.hasPrefix(portable.path+"/media/") && FileManager.default.fileExists(atPath:URL(fileURLWithPath:collectedSequence.path).appendingPathComponent("frame20.png").path),"Collected folder did not own its exact sequence files")
        let savedURL=folder.appendingPathComponent("source-settings.aperturecue.json")
        e.saveTo(savedURL)
        try expect(!e.dirty && (try ProjectStore.load(from:savedURL))==e.project && e.recoveryBaseline != nil,"Source settings Save did not retain an exact saved revision")
        let json=try required(JSONSerialization.jsonObject(with:Data(contentsOf:savedURL)) as? [String:Any],"Saved source document is not JSON")
        try expect(json["version"] as? Int==Project.currentVersion,"New source settings were not saved in the current schema")
        let saved=e.project;e.dirty=false;e.openProject(savedURL)
        try expect(e.project==saved && e.project.assets[0].playback==playback && e.project.assets[0].audioRouting==route,"Open lost source modes/audio routing or sequence state")
        pass("schema-13 Save/Open and portable collection retain source settings, audio matrix, UUIDs and folder manifests")

        let initialBaseline=try required(e.recoveryBaseline,"Named source project has no recovery baseline")
        var recovery=e.project;recovery.name="Original source recovery fixture"
        recovery.surfaces=[Surface(name:"Recovered replacement first layer",mediaID:sequence.id)]
        try ProjectStore.saveRecovery(recovery,for:savedURL,baseline:initialBaseline)
        var decisions=0;e.recoveryDecision={status in decisions+=1;return status.state == .available}
        e.dirty=false;e.openProject(savedURL)
        try expect(decisions==1 && e.project==recovery && e.dirty && e.selectedID==recovery.surfaces.first?.id,"Bound Restore did not install the recovered model and its first selection")
        e.saveTo(savedURL)
        try expect(!e.dirty && ProjectStore.recoveryStatus(for:savedURL).state == .missing && (try ProjectStore.load(from:savedURL))==recovery,"Manual Save did not clean only its pre-Save bound recovery")
        pass("available recovery uses the decision callback, selects the restored model and is removed by its next successful Save")

        let promptBaseline=try required(e.recoveryBaseline,"Prompt race fixture has no baseline")
        let promptSaved=e.project
        var promptRecovery=promptSaved;promptRecovery.name="Recovery replaced during decision"
        try ProjectStore.saveRecovery(promptRecovery,for:savedURL,baseline:promptBaseline)
        let promptSidecar=ProjectStore.recoveryURL(for:savedURL)
        let promptCorruption=Data("{original sidecar truncated during recovery decision".utf8)
        var corruptedDuringDecision=false;decisions=0
        e.recoveryDecision={status in
            decisions+=1
            guard status.state == .available else {return false}
            do {try promptCorruption.write(to:promptSidecar,options:.atomic);corruptedDuringDecision=true;return true}
            catch {return false}
        }
        e.dirty=false;e.openProject(savedURL)
        try expect(decisions==1 && corruptedDuringDecision && e.project==promptSaved && !e.dirty && e.selectedID==promptSaved.surfaces.first?.id,
                   "A sidecar changed during Restore installed stale data or left the editor model/selection inconsistent")
        try expect(!e.workMessage.isEmpty && e.workMessage.contains("Recovery") && (try Data(contentsOf:promptSidecar))==promptCorruption,
                   "Changed recovery was not diagnosed or its corrupt bytes were overwritten")
        try expect(e.overlay.surfaces.map(\.id)==promptSaved.surfaces.map(\.id) && e.renderer.surfaces.map(\.id)==e.effectiveSurfaces.map(\.id) && e.media.loadedAssetCount==promptSaved.assets.count,
                   "Recovery failure skipped native overlay/render/media reconciliation")
        try expect((try ProjectStore.load(from:savedURL))==promptSaved && e.recoveryBaseline==promptBaseline,
                   "Recovery decision race changed the saved file or its baseline")
        try FileManager.default.removeItem(at:promptSidecar)
        e.recoveryDecision={status in decisions+=1;return status.state == .available}
        pass("a sidecar corrupted during the Restore decision retains the clean saved model, reconciles adapters and preserves the diagnostic bytes")

        let baseline=try required(e.recoveryBaseline,"Updated saved revision has no baseline")
        var pending=e.project;pending.name="Pending old revision"
        try ProjectStore.saveRecovery(pending,for:savedURL,baseline:baseline)
        let sidecar=ProjectStore.recoveryURL(for:savedURL),staleBytes=try Data(contentsOf:sidecar)
        var external=e.project;external.name="New external revision";try ProjectStore.save(external,to:savedURL)
        decisions=0;e.dirty=false;e.openProject(savedURL)
        try expect(decisions==0 && e.project==external && !e.dirty && ProjectStore.recoveryStatus(for:savedURL).state == .stale && (try Data(contentsOf:sidecar))==staleBytes,"Stale recovery prompted, installed or was removed")
        let corrupt=Data("{original truncated editor-recovery fixture".utf8);try corrupt.write(to:sidecar,options:.atomic)
        decisions=0;e.openProject(savedURL)
        try expect(decisions==0 && e.project==external && !e.dirty && (try Data(contentsOf:sidecar))==corrupt,"Corrupt recovery prompted or changed the saved project")
        e.mutate("Own edit with preserved foreign recovery") {$0.name="Saved while preserving invalid recovery"};e.saveTo(savedURL)
        try expect(!e.dirty && (try Data(contentsOf:sidecar))==corrupt,"Successful Save removed a corrupt/unowned recovery")
        try FileManager.default.removeItem(at:sidecar)
        pass("stale and corrupt recovery open without a modal decision and remain preserved even after an explicit Save")

        e.mutate("Own discard fixture") {$0.name="Explicitly discarded unsaved edit"}
        let discardBaseline=try required(e.recoveryBaseline,"Discard fixture has no saved baseline")
        try ProjectStore.saveRecovery(e.project,for:savedURL,baseline:discardBaseline)
        try expect(e.discardChanges() && ProjectStore.recoveryStatus(for:savedURL).state == .missing,"Explicit Discard did not remove the current editor's own bound recovery")
        let foreign=Data("{preserve unrelated invalid sidecar".utf8);try foreign.write(to:sidecar,options:.atomic)
        try expect(e.discardChanges() && (try Data(contentsOf:sidecar))==foreign,"Discard deleted an unowned corrupt sidecar")
        pass("explicit Discard removes owned bound recovery and preserves unrelated invalid sidecars")
        return checks
    }
}
#endif
