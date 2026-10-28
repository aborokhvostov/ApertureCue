#if os(macOS)
import AppKit
import MappingCore

/// Production document adapters and actual native montage controls. Fixtures
/// are original generated media; all windows remain hidden and no dialogs run.
@MainActor enum MontageEditorSelfTest {
    private struct Failure:LocalizedError {
        var message:String
        var errorDescription:String? {message}
    }
    static func run(editor e:EditorController,directory:URL)throws->[String] {
        var checks:[String]=[]
        func expect(_ condition:@autoclosure()throws->Bool,_ message:String)throws {
            guard try condition() else {throw Failure(message:message)}
        }
        func required<T>(_ value:T?,_ message:String)throws->T {
            guard let value else {throw Failure(message:message)};return value
        }
        func pump(_ timeout:Double,_ condition:()->Bool)->Bool {
            let deadline=ProcessInfo.processInfo.systemUptime+timeout
            repeat {
                if condition() {return true}
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01))
            } while ProcessInfo.processInfo.systemUptime<deadline
            return condition()
        }
        func rejected(_ name:String,_ action:()throws->Void)throws {
            let before=e.project,undo=e.history.undoLabel,redo=e.history.redoLabel,dirty=e.dirty
            let edited=e.window?.isDocumentEdited,selection=e.selectedID
            var didThrow=false
            do {try action()} catch {didThrow=true}
            try expect(didThrow,"Montage adapter accepted "+name)
            try expect(e.project==before && e.history.undoLabel==undo && e.history.redoLabel==redo && e.dirty==dirty && e.window?.isDocumentEdited==edited && e.selectedID==selection,
                       "Rejected montage edit changed document/history/dirty/selection: "+name)
        }
        defer {e.stopShow();e.montageWindow?.close();e.montageWindow=nil}

        e.stopAutomationRecording(reason:"Montage checks");e.stopShow();e.lighting.stop()
        let mediaDirectory=directory.appendingPathComponent("montage-generated-media",isDirectory:true)
        try DemoGenerator.generate(at:mediaDirectory)
        let generated=try ProjectStore.load(from:mediaDirectory.appendingPathComponent("Demo.aperturecue.json"))
        let image=try required(generated.assets.first {$0.kind=="image"},"Generated montage image missing")
        let movie=try required(generated.assets.first {$0.kind=="video"},"Generated montage video missing")
        let surface=Surface(name:"Montage editor target",mediaID:image.id,output:Point2.unitQuad)
        let fixture=Project(name:"Native montage editor fixture",assets:[image,movie],surfaces:[surface])
        let fixtureURL=directory.appendingPathComponent("montage-initial.aperturecue.json")
        try ProjectStore.save(fixture,to:fixtureURL)
        e.dirty=false;e.openProject(fixtureURL)
        try expect(e.project==fixture && !e.dirty && !e.history.canUndo,"Montage fixture did not open cleanly")
        try expect(pump(12) {e.media.duration(for:movie.id)>2.9},"Generated montage video duration did not become ready")
        e.selectedID=surface.id
        let ui=MontageWindowController(editor:e);e.montageWindow=ui
        ui.window?.orderOut(nil);ui.window?.contentView?.layoutSubtreeIfNeeded()
        try expect(ui.window?.isVisible==false && ui.montageTable.numberOfRows==0 && ui.assetPicker.numberOfItems==2,
                   "Hidden montage editor was visible or did not list only real assets")
        let beforeDraft=e.project
        ui.newMontageButton.performClick(nil)
        for _ in 0..<5 {e.tick()}
        ui.window?.contentView?.layoutSubtreeIfNeeded()
        try expect(ui.nameField.frame.width>=250 && ui.nameField.frame.height>10 && ui.createButton.frame.width>0,"Montage draft fields lost their native layout after paused timer updates")
        ui.nameField.stringValue="Original montage";ui.durationField.stringValue="12"
        ui.montageLoopButton.performClick(nil)
        ui.refresh()
        try expect(e.project==beforeDraft && !e.dirty && !e.history.canUndo && ui.nameField.stringValue=="Original montage" && ui.durationField.stringValue=="12",
                   "New montage draft changed the document or was overwritten by refresh")
        ui.createButton.performClick(nil)
        let montageID=try required(ui.selectedMontageID,"Create montage callback did not select a saved UUID")
        var montage=try required(e.project.montages.first {$0.id==montageID},"Created montage missing")
        try expect(montage.name=="Original montage" && montage.duration==12 && montage.loop && montage.gapMode == .black && montage.clips.isEmpty && e.dirty,
                   "Actual Create montage callback did not save the draft properties")
        let created=e.project
        e.undoEdit();try expect(e.project==fixture && !e.history.canUndo,"Create montage was not one complete undo command")
        e.redoEdit();try expect(e.project==created,"Create montage redo lost its stable UUID")
        ui.selectMontage(id:montageID)
        ui.nameField.stringValue="Saved montage";ui.durationField.stringValue="10"
        ui.montageLoopButton.performClick(nil);ui.gapPicker.selectItem(at:1);ui.gapPicker.actionBlock?(1)
        ui.saveButton.performClick(nil)
        montage=try required(e.project.montages.first {$0.id==montageID},"Saved montage missing")
        try expect(montage.name=="Saved montage" && montage.duration==10 && !montage.loop && montage.gapMode == .skip,
                   "Actual Save montage properties callback lost duration/loop/gap")
        let settingsSaved=e.project
        e.undoEdit();try expect(e.project==created,"Save montage properties was not one undo command")
        e.redoEdit();try expect(e.project==settingsSaved,"Redo montage properties differs")
        ui.selectMontage(id:montageID)
        checks.append("hidden native montage Create/Save are explicit, preserve drafts and have complete one-command Undo/Redo")

        ui.selectAsset(id:movie.id)
        ui.clipStartField.stringValue="1";ui.clipDurationField.stringValue="2"
        ui.sourceInField.stringValue="0.25";ui.sourceOutField.stringValue="1.25";ui.rateField.stringValue="2"
        ui.clipLoopButton.performClick(nil);ui.addClipButton.performClick(nil)
        let videoID=try required(ui.selectedClipID,"Add video clip did not select its UUID")
        let video=try required(e.project.montages[0].clips.first {$0.id==videoID},"Saved video clip missing")
        try expect(video.assetID==movie.id && video.start==1 && video.duration==2 && video.sourceIn==0.25 && video.sourceOut==1.25 && video.rate==2 && video.loop,
                   "Actual Add clip callback lost video placement/trim/rate/loop")
        let addedVideo=e.project
        ui.clipStartField.stringValue="0.5";ui.nameField.stringValue="Unsaved metadata draft"
        e.refresh()
        try expect(ui.clipStartField.stringValue=="0.5" && ui.nameField.stringValue=="Unsaved metadata draft" && e.project==addedVideo,
                   "Production refresh overwrote unsaved clip/metadata fields or implicitly committed them")
        ui.saveClipButton.performClick(nil)
        try expect(e.project.montages[0].name=="Saved montage" && e.project.montages[0].clips.count==1 && e.project.montages[0].clips[0].id==videoID && e.project.montages[0].clips[0].start==0.5,
                   "Save clip changed its UUID, duplicated it or implicitly saved montage metadata")
        let editedVideo=e.project
        e.undoEdit();try expect(e.project==addedVideo,"Clip update was not one complete undo command")
        e.redoEdit();try expect(e.project==editedVideo,"Clip update redo lost source timing")
        ui.selectMontage(id:montageID);ui.newClipButton.performClick(nil);ui.selectAsset(id:image.id)
        ui.clipStartField.stringValue="4";ui.clipDurationField.stringValue="2"
        // Disabled video values must never leak into a saved image clip.
        ui.sourceInField.stringValue="9";ui.sourceOutField.stringValue="99";ui.rateField.stringValue="4";ui.clipLoopButton.state = .on
        ui.addClipButton.performClick(nil)
        let imageID=try required(ui.selectedClipID,"Add image clip did not select its UUID")
        let imageClip=try required(e.project.montages[0].clips.first {$0.id==imageID},"Saved image clip missing")
        try expect(imageClip.assetID==image.id && imageClip.start==4 && imageClip.duration==2 && imageClip.sourceIn==0 && imageClip.sourceOut==1 && imageClip.rate==1 && !imageClip.loop && !ui.sourceInField.isEnabled,
                   "Image clip did not canonicalize disabled video fields")
        ui.clipTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try expect(ui.selectedClipID==videoID,"Actual clip table selection did not bind its saved UUID")
        ui.strip.onSelect?(imageID)
        try expect(ui.selectedClipID==imageID,"Montage strip selection did not bind its saved clip")
        ui.seekClipButton.performClick(nil)
        try expect(e.showRuntime.time==4 && ui.strip.playhead==4 && !e.showRuntime.isPlaying,"Seek clip start did not reach the paused master clock")
        let beforeClipDelete=e.project
        ui.deleteClipButton.performClick(nil)
        try expect(e.project.montages[0].clips.map(\.id)==[videoID],"Delete clip callback removed the wrong UUID")
        e.undoEdit();try expect(e.project==beforeClipDelete,"Delete clip Undo did not restore the complete definition")
        e.redoEdit();try expect(e.project.montages[0].clips.map(\.id)==[videoID],"Delete clip Redo differs")
        e.undoEdit();ui.selectMontage(id:montageID)
        checks.append("native video/image clip Add/Save/Delete retain UUIDs and source timing, canonicalize images, select and seek with Undo/Redo")

        let valid=e.project
        let invalidClips:[(String,MontageClip)]=[
            ("overlap",MontageClip(assetID:image.id,start:2,duration:3)),
            ("missing asset",MontageClip(assetID:UUID(),start:7,duration:1)),
            ("nested montage",MontageClip(assetID:montageID,start:7,duration:1)),
            ("nonfinite placement",MontageClip(assetID:image.id,start:.nan,duration:1)),
            ("image video fields",MontageClip(assetID:image.id,start:7,duration:1,sourceIn:1,sourceOut:2)),
            ("video rate",MontageClip(assetID:movie.id,start:7,duration:1,sourceOut:2,rate:0.1)),
            ("trim past decoded duration",MontageClip(assetID:movie.id,start:7,duration:1,sourceOut:20)),
            ("nonloop source exhaustion",MontageClip(assetID:movie.id,start:7,duration:2,sourceOut:1))]
        for (name,clip) in invalidClips {try rejected(name) {try e.montageSaveClip(montageID:montageID,clip:clip)}}
        try rejected("montage shorter than its saved clips") {try e.montageUpdate(id:montageID,name:"Rejected",duration:1,loop:false,gapMode:.black)}
        try rejected("missing montage assignment") {try e.montageAssign(id:UUID())}
        try expect(e.project==valid,"Invalid montage sequence changed accepted state")
        checks.append("production montage adapters atomically reject overlap, missing/nested sources, nonfinite placement, invalid trim/rate and shortened horizons")

        ui.selectMontage(id:montageID);ui.assignButton.performClick(nil)
        try expect(e.project.surfaces[0].mediaID==montageID && ui.assetPicker.numberOfItems==2,"Assign callback failed or introduced a virtual source into the asset picker")
        let assigned=e.project
        e.undoEdit();try expect(e.project==valid,"Montage assignment Undo lost previous ordinary source")
        e.redoEdit();try expect(e.project==assigned,"Montage assignment Redo lost its virtual source UUID")
        _=try e.cueCreate(name:"Full montage owner",scope:.full,bindings:[],duration:0,followAfter:nil)
        _=try e.cueCreate(name:"Selective montage source",scope:.selective,bindings:[CueBinding(surfaceID:surface.id,parameters:[.source])],duration:0,followAfter:nil)
        _=try e.cueCreate(name:"Selective opacity snapshot",scope:.selective,bindings:[CueBinding(surfaceID:surface.id,parameters:[.opacity])],duration:0,followAfter:nil)
        var dormant=surface;dormant.id=UUID();dormant.mediaID=montageID;dormant.name="Dormant full montage owner"
        e.mutate("Montage dormant snapshot fixture") {$0.cues[0].surfaces.append(dormant)}
        let snapshots=e.project.cues
        ui.selectMontage(id:montageID);ui.nameField.stringValue="Shared definition edit";ui.saveButton.performClick(nil)
        try expect(e.project.cues==snapshots && e.project.surfaces[0].mediaID==montageID,"Editing shared montage definition recaptured or rewrote cue snapshots")
        let beforeDelete=e.project
        ui.deleteButton.performClick(nil)
        try expect(e.project.montages.isEmpty && e.project.surfaces.allSatisfy {$0.mediaID != montageID} && e.project.cues.flatMap(\.surfaces).allSatisfy {$0.mediaID != montageID},
                   "Delete montage left current/full/selective/dormant snapshot source references")
        try ProjectStore.validate(e.project)
        e.undoEdit();try expect(e.project==beforeDelete,"Delete montage did not restore definition and every cue/current reference in one Undo")
        e.redoEdit();try expect(e.project.montages.isEmpty && e.project.cues.flatMap(\.surfaces).allSatisfy {$0.mediaID != montageID},"Delete montage Redo retained cue references")
        e.undoEdit()
        checks.append("montage assignment and shared definitions retain cue UUID snapshots; deletion clears all current/full/selective/dormant refs with complete Undo/Redo")

        let savedURL=directory.appendingPathComponent("montage-saved.aperturecue.json")
        e.saveTo(savedURL);let saved=e.project
        let json=try required(try JSONSerialization.jsonObject(with:Data(contentsOf:savedURL)) as? [String:Any],"Saved montage JSON missing")
        try expect(saved.version==7 && (json["version"] as? Int)==7 && (json["montages"] as? [[String:Any]])?.count==1 && !e.dirty && (try ProjectStore.load(from:savedURL))==saved,
                   "Montage Save lost schema-7 definitions, clips or source references")
        e.newProject()
        try expect(e.montageWindow==nil && e.project.montages.isEmpty && e.showRuntime.time==0,"New retained old montage window/definitions/playhead")
        e.openProject(savedURL)
        try expect(e.project==saved && !e.dirty && !e.history.canUndo && e.montageWindow==nil && e.showRuntime.time==0,
                   "Montage Save/New/Open did not preserve schema-7 state with clean runtime")
        let collectedURL=try ProjectStore.collect(e.project,to:directory.appendingPathComponent("montage-collected",isDirectory:true))
        let collected=try ProjectStore.load(from:collectedURL)
        try expect(collected.montages==saved.montages && collected.surfaces==saved.surfaces && collected.cues==saved.cues && collected.assets.map(\.id)==saved.assets.map(\.id),
                   "Collect rewrote montage/clip/cue UUID references")
        for asset in collected.assets {
            let original=try required(saved.assets.first {$0.id==asset.id},"Collected source asset UUID changed")
            try expect(asset.path.hasPrefix(collectedURL.deletingLastPathComponent().path+"/") && (try Data(contentsOf:URL(fileURLWithPath:asset.path)))==(try Data(contentsOf:URL(fileURLWithPath:original.path))),
                       "Collected montage media was missing, external or changed bytes")
        }
        e.openProject(collectedURL)
        try expect(e.project==collected && e.project.montages[0].clips.map(\.id)==saved.montages[0].clips.map(\.id) && !e.dirty && !e.history.canUndo,
                   "Production Open lost a collected montage definition or stable clip UUID")
        checks.append("schema-7 Save/New/Open and collected original image/H.264 bytes retain montage, clip, source and cue UUIDs with clean document/runtime")
        return checks
    }
}
#endif
