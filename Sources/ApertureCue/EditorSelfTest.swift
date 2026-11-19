#if os(macOS)
import AppKit
import MetalKit
import QuartzCore
import MappingCore

/// Integration checks through the production editor controller and document methods.
/// All windows belong to this test process and remain hidden. No dialogs, visible
/// fullscreen presentation, camera authorization, network start, or interaction with another app occurs.
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
            try expect(e.overlay.wantsLayer && e.overlay.wantsUpdateLayer && !e.overlay.isOpaque && e.overlay.layer?.isOpaque == false,"Editor overlay does not own a transparent layer above Metal")
            try expect(e.window?.isVisible == false,"Editor test window became visible")
            let overlayFixture=Surface(output:[Point2(0.1,0.2),Point2(0.7,0.25),Point2(0.8,0.6),Point2(0.2,0.7)])
            e.overlay.setFrameSize(NSSize(width:128,height:96)); e.overlay.surfaces=[overlayFixture]; e.overlay.selectedID=overlayFixture.id; e.overlay.updateLayer()
            let selectedPath=e.overlay.layer?.sublayers?.compactMap {$0 as? CAShapeLayer}.first(where:{$0.lineWidth == 2 && $0.fillColor == nil})?.path
            let pathBounds=try required(selectedPath,"Vector selection cage missing").boundingBoxOfPath
            try expect(abs(pathBounds.minY-19.2)<1e-8 && abs(pathBounds.maxY-67.2)<1e-8,"Vector cage vertically differs from document/mouse coordinates")
            e.updateRender()
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
            e.seekShow(to:5)
            let effective=try required(e.effectiveSurfaces.first { $0.id == addedID },"Automated surface missing")
            try expect(abs(effective.opacity-0.5)<1e-12,"Controller did not apply timeline at current seek time")
            e.project.cues[0].duration=0
            let beforeRecall=e.project
            e.goCue(index:0); e.tick()
            let inactive=try required(e.project.surfaces.first { $0.id == addedID },"Scene recall discarded an uncaptured surface definition")
            try expect(!inactive.enabled && e.project.timeline == [track],"Scene absence did not preserve a dormant automation target")
            try ProjectStore.validate(e.project)
            let recalledURL=directory.appendingPathComponent("recalled.aperturecue.json")
            try ProjectStore.save(e.project,to:recalledURL)
            try expect(try ProjectStore.load(from:recalledURL) == e.project,"Scene recall with dormant automation could not round-trip")
            e.undoEdit()
            try expect(e.project == beforeRecall,"Undo scene recall did not restore the full surface/track state")
            e.selectedID=addedID
            passed("scene recall hides uncaptured surfaces, preserves automation targets and remains savable/undoable")
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

            e.seekShow(to:8); e.playShow()
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
            e.seekShow(to:8); e.playShow(); e.dirty=false
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
            e.openOutput(config,fullscreen:false,showWindow:false)
            let constructed=try required(e.outputWindows[.preview(config.id)],"Production output constructor did not register its window")
            let outputWindow=constructed.0,outputRenderer=constructed.1
            (outputWindow.contentView?.subviews.first { $0 is MTKView } as? MTKView)?.isPaused=true
            e.toggleBlackout()
            try expect(outputRenderer.blackout && !e.renderer.blackout && outputRenderer.surfaces == e.effectiveSurfaces,"Editor did not propagate blackout/effective surfaces to its independent output")
            try expect(outputRenderer.media === e.media && !outputWindow.isVisible,"Hidden output did not share the editor media pool or became visible")
            guard let black=outputRenderer.snapshot(width:32,height:18),let pixels=black.bitmapData else { throw Failure(message:"Hidden output blackout snapshot failed") }
            let offset=9*black.bytesPerRow+16*4
            try expect(pixels[offset] == 0 && pixels[offset+1] == 0 && pixels[offset+2] == 0,"Output blackout did not reach the production Metal render")
            e.toggleBlackout(); e.closeOutputs()
            try expect(e.outputWindows.isEmpty && !outputWindow.isVisible,"closeOutputs retained an output window")
            try expect(e.window?.isVisible == false,"Editor test showed its window during document operations")
            try ProjectStore.validate(e.project)
            passed("production hidden output constructor shares media, receives blackout and closes")

            let connectedDisplays=ProjectionDisplay.connected
            let selectedDisplay=try required(connectedDisplays.first {
                ProjectionDisplay.target($0.id,in:connectedDisplays) != nil
            },"No active, non-mirrored display for the hidden fullscreen check")
            e.openOutput(config,fullscreen:true,showWindow:false)
            try expect(e.outputWindows.isEmpty,"Unassigned fullscreen fell back to a display index")
            try e.presentOutput(id:config.id,fullscreen:true,displayUUID:selectedDisplay.id,showWindow:false)
            let fullscreen=try required(e.outputWindows[.fullscreen(config.id)],"Production fullscreen constructor did not register its hidden window")
            let projection=fullscreen.0
            let targetScreen=selectedDisplay.screen
            try expect(projection.styleMask == .borderless,"Fullscreen output retained a window border or title bar")
            try expect(projection.frame == targetScreen.frame,"Fullscreen output does not cover the selected screen's full frame")
            try expect(projection.level.rawValue > NSWindow.Level.mainMenu.rawValue,"Fullscreen output remains below the system menu level")
            try expect(!projection.isVisible && !projection.isKeyWindow,"Hidden fullscreen construction presented or activated the window")
            guard let escape=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:projection.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53) else { throw Failure(message:"Cannot create the local Escape test event") }
            projection.keyDown(with:escape)
            try expect(e.outputWindows.isEmpty && !projection.isVisible,"Escape did not close and unregister the projection window")
            try expect(e.window?.isVisible == false,"Hidden output constructor activated the editor")
            report["hiddenFullscreenConfigurationVerified"]=true
            report["fullscreenPresentationVerified"]=false
            passed("hidden production fullscreen frame, borderless style, menu-level coverage and Escape cleanup")

            let secondOutput=OutputConfig(name:config.name,screenIndex:config.screenIndex)
            let outputLayerA=Surface(name:"Only A",output:Point2.unitQuad,color:[1,0,0],outputID:config.id,generator:"solid")
            let outputLayerB=Surface(name:"Only B",output:Point2.unitQuad,color:[0,1,0],outputID:secondOutput.id,generator:"solid")
            let beforeDisplayFixture=e.project
            e.mutate("Two output fixtures") {
                $0.outputs.append(secondOutput)
                $0.surfaces += [outputLayerA,outputLayerB]
            }
            let routeProject=e.project
            try e.presentOutput(id:config.id,fullscreen:false,displayUUID:nil,showWindow:false)
            try e.presentOutput(id:secondOutput.id,fullscreen:false,displayUUID:selectedDisplay.id,showWindow:false)
            try expect(e.project==routeProject && e.outputWindows.count==2,"Opening two previews changed bindings or collapsed the routes")
            for (candidate, rgb) in [(config,[UInt8(255),0,0]),(secondOutput,[UInt8(0),255,0])] {
                let output=try required(e.outputWindows[.preview(candidate.id)],"Independent routed preview is missing")
                let bitmap=try required(output.1.snapshot(width:32,height:18),"Independent routed Metal frame missing")
                let bytes=try required(bitmap.bitmapData,"Independent preview pixel bytes missing")
                let offset=9*bitmap.bytesPerRow+16*4
                try expect(Array(UnsafeBufferPointer(start:bytes+offset,count:3))==rgb,"Two previews did not show independently routed surfaces")
            }
            passed("two hidden output previews on one display show distinct routed Metal pixels without changing bindings")

            try e.presentOutput(id:config.id,fullscreen:true,displayUUID:selectedDisplay.id,showWindow:false)
            do {
                try e.presentOutput(id:secondOutput.id,fullscreen:true,displayUUID:selectedDisplay.id,showWindow:false)
                throw Failure(message:"Two fullscreen outputs occupied the same display")
            } catch is Failure { throw Failure(message:"Two fullscreen outputs occupied the same display") }
            catch { try expect(e.project==routeProject,"Rejected display selection changed the project") }
            try expect(e.outputWindows.count==3 && e.outputWindows[.preview(config.id)] != nil,
                       "Opening fullscreen dismissed the preview for the same route")
            let distractor=ProjectionDisplay(id:UUID(),screen:targetScreen,allowsFullscreen:true)
            e.reconcileOutputWindows(displays:[distractor,selectedDisplay])
            e.reconcileOutputWindows(displays:[selectedDisplay,distractor])
            try expect(e.outputWindows[.fullscreen(config.id)]?.displayUUID==selectedDisplay.id,"Reordering displays changed the fullscreen route")
            for topology in [[distractor],[selectedDisplay,selectedDisplay],
                             [ProjectionDisplay(id:selectedDisplay.id,screen:targetScreen,allowsFullscreen:false)]] {
                e.reconcileOutputWindows(displays:topology)
                try expect(e.project==routeProject && e.outputWindows[.fullscreen(config.id)]==nil && e.outputWindows[.preview(secondOutput.id)]?.displayUUID==nil &&
                           e.outputWindows.count==2 && !e.outputMessage.isEmpty,"Missing, ambiguous or mirrored display did not close only fullscreen")
                e.reconcileOutputWindows(displays:connectedDisplays)
                try expect(e.outputWindows[.fullscreen(config.id)]==nil,"Returning display reopened fullscreen without a user action")
                try e.presentOutput(id:config.id,fullscreen:true,displayUUID:selectedDisplay.id,showWindow:false)
            }
            e.undoEdit()
            try expect(e.project==beforeDisplayFixture && e.outputWindows[.preview(secondOutput.id)]==nil,"Undo removal retained an output window")
            e.undoEdit()
            try expect(e.project.outputs.first?.displayUUID==nil && e.outputWindows[.fullscreen(config.id)]==nil,"Undo assignment retained fullscreen")
            e.redoEdit()
            try expect(e.project.outputs.first?.displayUUID==selectedDisplay.id && e.outputWindows[.fullscreen(config.id)]==nil,"Redo reopened a fullscreen window")
            e.closeOutputs()
            passed("simulated display reorder, disconnect, duplicate, mirror and history changes preserve routes and require explicit fullscreen reopen")

            e.addSurface(shape:.triangle)
            let shapeID=try required(e.selectedID,"Shape creation lost selection")
            try expect(e.project.surfaces.last?.shape == .triangle,"Triangle button path did not create a triangle")
            guard let shapePicker=e.inspector.arrangedSubviews.compactMap({ $0 as? ActionPopUp }).first(where:{ $0.itemTitles == ["Quad","Triangle","Ellipse","Line","Bézier"] }),let action=shapePicker.action else { throw Failure(message:"Working inspector shape selector missing") }
            shapePicker.selectItem(at:2)
            app.sendAction(action,to:shapePicker.target,from:shapePicker)
            try expect(e.project.surfaces.last?.shape == .ellipse,"Shape selector did not edit the selected surface")
            e.undoEdit(); try expect(e.project.surfaces.last?.shape == .triangle,"Undo did not restore triangle shape")
            e.redoEdit(); try expect(e.project.surfaces.last?.shape == .ellipse,"Redo did not restore ellipse shape")
            e.modePicker.selectItem(at:1); e.updateRender()
            try expect(e.renderer.surfaces.first?.shape == .quad,"Input preview was clipped by output surface shape")
            e.modePicker.selectItem(at:0); e.updateRender()
            var picking=try required(e.project.surfaces.last,"Shape picking fixture missing")
            picking.output=Point2.unitQuad
            let lower=Surface(name:"Lower picking layer",output:Point2.unitQuad)
            e.overlay.surfaces=[lower,picking]
            try expect(e.overlay.hitSurface(at:Point2(0.02,0.02)) == lower.id,"Ellipse empty corner captured selection of lower layer")
            try expect(e.overlay.hitSurface(at:Point2(0.5,0.5)) == shapeID,"Ellipse interior was not selectable")
            e.updateRender()
            passed("triangle creation, actual shape selector, undo/redo, unclipped input and shape-aware selection")

            e.mutate("Shape snapshot") { $0.cues.append(Cue(name:"Shape snapshot",surfaces:$0.surfaces,duration:0)) }
            let shapeURL=directory.appendingPathComponent("shapes.aperturecue.json")
            e.saveTo(shapeURL)
            let shaped=e.project
            e.newProject(); e.openProject(shapeURL)
            try expect(e.project == shaped && e.project.version == Project.currentVersion,"Current-schema shape document did not reopen through production controller")
            try expect(e.project.surfaces.last?.shape == .ellipse && e.project.cues.last?.surfaces.last?.shape == .ellipse,"Reopen lost surface or snapshot shape")
            try ProjectStore.validate(e.project)
            passed("current-schema surface and scene shapes survive production save/new/open")

            let beforeInterrupted=e.project
            e.history.clear(); e.dirty=false
            var interruptedTarget=e.project.surfaces
            interruptedTarget[0].opacity=0.2
            let interruptedCue=Cue(name:"Interrupted fixture",surfaces:interruptedTarget,duration:2)
            e.cueBefore=e.project; e.cueTarget=interruptedCue
            e.cueEngine.begin(from:e.project.surfaces,cue:interruptedCue,at:0)
            guard let midpoint=e.cueEngine.sample(at:1) else { throw Failure(message:"Cue interruption fixture did not sample") }
            e.project.surfaces=midpoint
            e.overlay.onBegin?(); e.overlay.onEnd?()
            try expect(e.dirty && e.history.canUndo && e.cueTarget == nil && e.cueBefore == nil && !e.cueEngine.isTransitioning,"No-op handle click lost interrupted cue history/dirty state")
            e.undoEdit(); try expect(e.project == beforeInterrupted,"Undo interrupted cue did not restore its starting document")
            let afterInterruptedUndo=e.project
            e.mutate("No-op after cue undo") {_ in}
            try expect(e.project == afterInterruptedUndo && e.cueBefore == nil,"Stale cue snapshot changed a later no-op edit")
            passed("no-op editing interrupts a scene with dirty/undo state and clears stale cue snapshots")

            func pointsNear(_ a:[Point2],_ b:[Point2]) -> Bool {
                a.count == b.count && zip(a,b).allSatisfy { hypot($0.x-$1.x,$0.y-$1.y) < 1e-9 }
            }
            e.selectedID=shapeID; e.refresh()
            let originalWorld=try required(e.effectiveSurfaces.first { $0.id == shapeID },"Grouped fixture missing")
            let rootGroup=try e.saveGroup(id:nil,name:"Stage",parentID:nil,opacity:0.8,enabled:true,assignSelected:true)
            let childGroup=try e.saveGroup(id:nil,name:"Panel",parentID:rootGroup,opacity:0.5,enabled:true,assignSelected:true)
            let localBefore=try required(e.project.surfaces.first { $0.id == shapeID },"Assigned child missing")
            try expect(pointsNear(e.effectiveSurfaces.last!.output,originalWorld.output),"Assigning group moved the rendered geometry")
            let delta=Affine2D.translation(x:0.03,y:0.02).concatenating(.rotation(degrees:11,around:Point2(0.5,0.5),aspectRatio:16.0/9.0)).concatenating(.scale(x:0.8,y:0.75))
            let beforeTransform=e.project
            try e.transformGroup(rootGroup,by:delta)
            let moved=try required(e.effectiveSurfaces.first { $0.id == shapeID },"Transformed child missing")
            try expect(pointsNear(moved.output,try originalWorld.output.map { try delta.applying($0) }),"Parent transform did not move the descendant in world space")
            try expect(e.project.surfaces.last?.output == localBefore.output && e.project.surfaces.last?.input == localBefore.input,"Non-destructive group transform rewrote local output/input")
            e.undoEdit(); try expect(e.project == beforeTransform,"Undo group transform did not restore the full document")
            e.redoEdit()
            passed("hierarchical group creation/assignment and non-destructive transform with undo/redo")

            var worldQuad=try required(e.resolvedBaseSurfaces.first { $0.id == shapeID },"Resolved overlay child missing").output
            worldQuad[0].x += 0.015; worldQuad[0].y += 0.01
            let inverse=try GroupEngine.worldTransform(for:childGroup,groups:e.project.groups).inverse()
            e.overlay.onBegin?(); e.overlay.onChange?(shapeID,worldQuad,false,false); e.overlay.onEnd?()
            try expect(pointsNear(e.project.surfaces.last!.output,try worldQuad.map { try inverse.applying($0) }),"Grouped output drag stored world coordinates as local")
            try expect(pointsNear(e.overlay.surfaces.last!.output,worldQuad),"Grouped overlay did not return to its dragged world cage")
            e.editSurface("Test grouped mesh") { s in s.meshColumns=2; s.meshRows=2; s.mesh=(try? Geometry.regularMesh(quad:s.output,columns:2,rows:2)) ?? [] }
            e.overlay.meshMode=true; e.updateRender()
            let meshBefore=e.project.surfaces.last!.mesh
            var worldMesh=e.overlay.surfaces.last!.mesh; worldMesh[4].x += 0.01
            e.overlay.onBegin?(); e.overlay.onChange?(shapeID,worldMesh,false,true); e.overlay.onEnd?()
            try expect(pointsNear(e.project.surfaces.last!.mesh,try worldMesh.map { try inverse.applying($0) }),"Grouped mesh drag did not invert parent mapping")
            e.undoEdit(); try expect(e.project.surfaces.last!.mesh == meshBefore,"Undo grouped mesh drag did not preserve the mesh")
            let sourceCrop=[Point2(0.1,0.15),Point2(0.9,0.15),Point2(0.9,0.85),Point2(0.1,0.85)]
            e.modePicker.selectItem(at:1); e.overlay.meshMode=true; e.updateRender()
            e.overlay.onBegin?(); e.overlay.onChange?(shapeID,sourceCrop,true,true); e.overlay.onEnd?()
            try expect(e.project.surfaces.last!.input == sourceCrop && e.project.surfaces.last!.mesh == meshBefore,"Input/mesh flags corrupted local mesh or transformed source UV")
            let sourceMask=[Point2(0.2,0.2),Point2(0.8,0.2),Point2(0.5,0.8)]
            e.overlay.maskMode=true; e.overlay.onBegin?(); e.overlay.onChange?(shapeID,sourceMask,true,true); e.overlay.onEnd?()
            try expect(e.project.surfaces.last!.mask == sourceMask,"Grouped source mask was transformed as output geometry")
            e.overlay.maskMode=false; e.overlay.meshMode=false; e.modePicker.selectItem(at:0); e.refresh()
            passed("grouped output/mesh drags invert parent frame; input and masks stay in source UV")

            let other=try e.saveGroup(id:nil,name:"Alternate parent",parentID:nil,opacity:0.6,enabled:true,assignSelected:false)
            try e.transformGroup(other,by:.translation(x:-0.1,y:0.04).concatenating(.scale(x:0.9,y:1.1)))
            let beforeReparent=e.effectiveSurfaces.last!.output
            _=try e.saveGroup(id:childGroup,name:"Panel",parentID:other,opacity:0.5,enabled:true,assignSelected:false)
            try expect(pointsNear(e.effectiveSurfaces.last!.output,beforeReparent),"Reparent moved the world image")
            let beforeCycle=e.project
            do { _=try e.saveGroup(id:other,name:"Invalid cycle",parentID:childGroup,opacity:1,enabled:true,assignSelected:false); throw Failure(message:"Editor accepted a group parent cycle") }
            catch is Failure { throw Failure(message:"Editor accepted a group parent cycle") }
            catch { try expect(e.project == beforeCycle,"Rejected cycle partially changed the document") }
            let ownFlags=e.project.surfaces.map(\.enabled)
            e.toggleGroup(); try expect(e.project.surfaces.map(\.enabled) == ownFlags && !e.effectiveSurfaces.last!.enabled,"Group hide rewrote child visibility flags")
            e.toggleGroup(); try expect(e.effectiveSurfaces.last!.enabled,"Group show did not restore ancestor visibility")
            guard let parentPicker=e.inspector.arrangedSubviews.compactMap({$0 as? ActionPopUp}).first(where:{$0.itemTitles.first == "Root / no group"}),let parentAction=parentPicker.action else { throw Failure(message:"Working parent group selector missing") }
            parentPicker.selectItem(at:0); app.sendAction(parentAction,to:parentPicker.target,from:parentPicker)
            try expect(e.project.surfaces.last!.groupID == nil && pointsNear(e.effectiveSurfaces.last!.output,beforeReparent),"Root assignment picker lost output geometry")
            e.undoEdit(); try expect(e.project.surfaces.last!.groupID == childGroup,"Undo parent assignment lost group membership")
            passed("group reparent/visibility and real parent picker preserve geometry; cycles reject atomically")

            let groupTrack=AutomationTrack(name:"Grouped opacity",surfaceID:shapeID,parameter:"opacity",keyframes:[AutomationKeyframe(time:0,value:0.4),AutomationKeyframe(time:1,value:0.4)])
            e.mutate("Group automation fixture") {$0.timeline.append(groupTrack)}
            try expect(abs(e.effectiveSurfaces.last!.opacity-0.12) < 1e-9,"Group opacity was applied before automation or applied twice")
            let beforeUnsafe=e.project
            do { try e.dissolveGroup(childGroup); throw Failure(message:"Unsafe animated opacity dissolve was accepted") }
            catch is Failure { throw Failure(message:"Unsafe animated opacity dissolve was accepted") }
            catch { try expect(e.project == beforeUnsafe,"Rejected dissolve changed groups or animation") }
            e.mutate("Remove group opacity fixture") {$0.timeline.removeAll {$0.id == groupTrack.id}}
            e.captureCue()
            let beforeDissolve=e.project, renderBeforeDissolve=e.effectiveSurfaces.last!
            try e.dissolveGroup(childGroup)
            let afterDissolve=e.effectiveSurfaces.last!
            try expect(pointsNear(afterDissolve.output,renderBeforeDissolve.output) && pointsNear(afterDissolve.mesh,renderBeforeDissolve.mesh) && abs(afterDissolve.opacity-renderBeforeDissolve.opacity)<1e-9,"Dissolve changed current rendered state")
            try expect(e.project.cues.last!.surfaces.last!.groupID == other && !e.project.groups.contains {$0.id == childGroup},"Dissolve left a dangling scene group reference")
            e.undoEdit(); try expect(e.project == beforeDissolve,"Undo dissolve did not restore hierarchy and scenes")
            e.redoEdit(); try ProjectStore.validate(e.project)
            passed("group opacity follows automation; dissolve preserves scene references and rejects unsafe tracks")

            e.openOutput(config,fullscreen:false,showWindow:false)
            let groupedOutput=try required(e.outputWindows[.preview(config.id)],"Grouped output missing").1
            try expect(groupedOutput.surfaces == e.effectiveSurfaces && groupedOutput.media === e.media,"Independent output received local rather than resolved group geometry")
            e.lighting.isSampling=true; e.lighting.isSending=false
            e.mutate("Grouped sampling fixture") {$0.fixtures=[Fixture(name:"Group sampling",universe:1,address:1,points:[Point2(0.5,0.5)],channelOrder:"RGB")]}
            e.lastLighting=0; e.tick()
            try expect(e.lighting.renderer.surfaces == e.effectiveSurfaces,"Lighting renderer did not receive the same flattened effective hierarchy")
            try expect(pump(timeout:5) {!e.lighting.lastUniverses.isEmpty},"Grouped local light sampling did not complete")
            e.lighting.stop(); e.closeOutputs()
            let groupURL=directory.appendingPathComponent("groups.aperturecue.json")
            e.saveTo(groupURL); let groupSaved=e.project
            e.newProject(); try expect(e.selectedGroupID == nil && e.project.groups.isEmpty,"New retained old group selection/definitions")
            e.openProject(groupURL)
            try expect(e.project == groupSaved && e.project.version == Project.currentVersion,"Schema-3 groups did not survive production save/new/open")
            report["groupCount"]=e.project.groups.count
            passed("group output/light composition and schema-3 save/new/open share resolved geometry")

            let pixelParent=SurfaceGroup(name:"Pixel parent",transform:Affine2D(a:0.8314254606237348,b:0.31417766612461406,c:-0.10525529347649067,d:0.8803328406604252,tx:0.17312406516308548,ty:-0.07650681991806495))
            let pixelChild=SurfaceGroup(name:"Pixel child",parentID:pixelParent.id)
            let pixelSurface=Surface(name:"Checker",output:[Point2(0.09441550974712976,0.1637106255209871),Point2(0.4900000000000001,0.22999999999999998),Point2(0.45999999999999996,0.8800000000000001),Point2(0.08999999999999997,0.8000000000000002)],generator:"checker",groupID:pixelChild.id)
            e.mutate("Pixel fixture") {$0=Project(surfaces:[pixelSurface],groups:[pixelParent,pixelChild])}
            e.selectedID=pixelSurface.id; e.refresh()
            func editorPixels() throws -> [UInt8] {
                guard let bitmap=e.renderer.snapshot(width:128,height:96),let bytes=bitmap.bitmapData else { throw Failure(message:"Editor pixel regression readback failed") }
                return Array(UnsafeBufferPointer(start:bytes,count:bitmap.bytesPerRow*bitmap.pixelsHigh))
            }
            let baselinePixels=try editorPixels()
            try expect(stride(from:0,to:baselinePixels.count,by:4).filter {baselinePixels[$0] > 150}.count > 400,"Editor baseline checker was not visible")
            try e.dissolveGroup(pixelChild.id)
            try expect(try editorPixels() == baselinePixels,"Production editor dissolve changed checker pixels")
            e.undoEdit(); try expect(try editorPixels() == baselinePixels,"Editor undo changed checker pixels")
            e.redoEdit(); try expect(try editorPixels() == baselinePixels,"Editor redo changed checker pixels")
            passed("production editor dissolve/undo/redo preserve exact visible checker pixels")

            e.addSurface(shape:.bezier)
            let strokeID=try required(e.selectedID,"Stroke creation has no selection")
            let createdStroke=try required(e.project.surfaces.last,"Stroke was not appended")
            try expect(createdStroke.shape == .bezier && createdStroke.stroke == .bezier && e.overlay.pathMode,"Bezier creation did not initialize its editable curve")
            let strokePicker=try required(e.inspector.arrangedSubviews.compactMap {$0 as? ActionPopUp}.first(where:{$0.itemTitles == ["Quad","Triangle","Ellipse","Line","Bézier"]}),"Actual stroke shape picker missing")
            strokePicker.selectItem(at:3); strokePicker.actionBlock?(3)
            try expect(e.project.surfaces.last?.shape == .line && e.project.surfaces.last?.stroke == createdStroke.stroke,"Shape picker lost editable node data")
            e.undoEdit(); try expect(e.project.surfaces.last == createdStroke,"Undo shape picker did not restore Bezier")
            e.setShapePointEditing(true)
            let beforeInsert=e.project
            try e.insertStrokeNode(after:0)
            try expect(e.project.surfaces.last?.stroke.nodes.count == 3,"Insert did not split its cubic")
            let split=e.project
            try e.removeStrokeNode(at:1); try expect(e.project.surfaces.last?.stroke.nodes.count == 2,"Remove did not remove the selected node")
            e.undoEdit(); try expect(e.project == split,"Undo node removal lost tangent data")
            e.undoEdit(); try expect(e.project == beforeInsert,"Undo insertion lost original curve")
            var hardLine=Surface(shape:.line)
            hardLine.stroke.nodes=(0..<32).map { i in
                StrokeNode(anchor:Point2(i%2 == 0 ? 0.1 : 0.9,0.5),incoming:Point2(0.9,0.05),outgoing:Point2(0.1,0.95))
            }
            e.mutate("Conversion budget fixture") {$0=Project(surfaces:[hardLine])}; e.selectedID=hardLine.id; e.refresh()
            let validLine=e.project
            do { try e.changeSurfaceShape(.bezier); throw Failure(message:"Shape conversion accepted an exhausted curve budget") }
            catch is Failure { throw Failure(message:"Shape conversion accepted an exhausted curve budget") }
            catch { try expect(e.project == validLine,"Rejected shape conversion changed the project") }
            var loopCurve=Surface(shape:.bezier,stroke:StrokePath(nodes:[StrokeNode(anchor:Point2(0.5,0.5),outgoing:Point2(0.1,0.1)),StrokeNode(anchor:Point2(0.5,0.5),incoming:Point2(0.9,0.1))]))
            loopCurve.name="Closed-end cubic with an open path"
            e.mutate("Conversion collapse fixture") {$0=Project(surfaces:[loopCurve])}; e.selectedID=loopCurve.id; e.refresh()
            let validLoop=e.project
            do { try e.changeSurfaceShape(.line); throw Failure(message:"Shape conversion accepted a zero-length line") }
            catch is Failure { throw Failure(message:"Shape conversion accepted a zero-length line") }
            catch { try expect(e.project == validLoop,"Rejected collapsed conversion changed the project") }
            passed("stroke creation, actual shape picker, cubic split/remove and undo preserve path data")

            var strokeFixture=createdStroke
            strokeFixture.output=Point2.insetQuad; strokeFixture.input=[Point2(0.2,0.1),Point2(0.8,0.1),Point2(0.8,0.9),Point2(0.2,0.9)]
            strokeFixture.meshColumns=2; strokeFixture.meshRows=2
            strokeFixture.mesh=try Geometry.regularMesh(quad:strokeFixture.output,columns:2,rows:2)
            strokeFixture.mesh[4].x += 0.07
            let strokeGroup=SurfaceGroup(name:"Stroke frame",transform:Affine2D.rotation(degrees:8,aspectRatio:16.0/9.0).concatenating(.scale(x:0.9,y:0.85)))
            strokeFixture.groupID=strokeGroup.id
            e.mutate("Stroke drag fixture") {$0=Project(surfaces:[strokeFixture],groups:[strokeGroup])}
            e.selectedID=strokeID; e.setShapePointEditing(true); e.refresh()
            let strokeBeforeDrag=e.project
            let resolvedStroke=try required(e.resolvedBaseSurfaces.first,"Resolved stroke missing")
            var pathHandles=e.overlay.pathControlPoints(resolvedStroke)
            let tangent=Point2(0.4,0.2)
            pathHandles[2]=try SurfaceGeometry.outputPoint(local:tangent,surface:resolvedStroke)
            e.overlay.onBegin?(); e.overlay.onChange?(strokeID,pathHandles,false,false); e.overlay.onEnd?()
            let dragged=e.project.surfaces[0]
            try expect(hypot(dragged.stroke.nodes[0].outgoing.x-tangent.x,dragged.stroke.nodes[0].outgoing.y-tangent.y)<1e-8,"World tangent drag did not invert group and warped cage")
            try expect(dragged.input == strokeFixture.input && dragged.output == strokeFixture.output && dragged.mesh == strokeFixture.mesh,"Path editing changed source/cage/warp")
            let afterStrokeDrag=e.project
            e.undoEdit(); try expect(e.project == strokeBeforeDrag,"Undo path drag differs")
            e.redoEdit(); try expect(e.project == afterStrokeDrag,"Redo path drag differs")
            var invalidPath=dragged.stroke; invalidPath.nodes[0].anchor.x = -1
            do { try e.replaceStroke(invalidPath); throw Failure(message:"Invalid stroke was accepted") }
            catch is Failure { throw Failure(message:"Invalid stroke was accepted") }
            catch { try expect(e.project == afterStrokeDrag,"Rejected path changed document/history") }
            passed("world path tangent drag inverts hierarchy and mesh, preserves source, and rejects invalid edits")

            e.captureCue()
            let strokeURL=directory.appendingPathComponent("strokes.aperturecue.json")
            e.saveTo(strokeURL); let savedStroke=e.project
            e.newProject(); try expect(!e.overlay.pathMode,"New document retained path editing")
            e.openProject(strokeURL)
            try expect(e.project == savedStroke && e.project.version == Project.currentVersion,"Stroke scene/path did not survive schema-4 save/new/open")
            try expect(e.renderer.surfaces.first?.stroke == savedStroke.surfaces.first?.stroke,"Production renderer lost path payload")
            let strokePixels=try editorPixels()
            try expect(stride(from:0,to:strokePixels.count,by:4).contains {strokePixels[$0]>40},"Production editor stroke rendered no visible pixels")
            passed("stroke scenes and schema-4 save/new/open retain visible production geometry")

            let showSurface=Surface(name:"Timeline red",output:Point2.unitQuad,color:[1,0,0],generator:"solid")
            let showOutput=OutputConfig(name:"Timeline output")
            var sceneSurface=showSurface;sceneSurface.brightness=0.6
            let showCue=Cue(name:"Timeline scene",surfaces:[sceneSurface],duration:0)
            e.mutate("Timeline fixture") {$0=Project(surfaces:[showSurface],outputs:[showOutput],cues:[showCue],fixtures:[Fixture(name:"Timeline light",points:[Point2(0.5,0.5)])])}
            e.selectedID=showSurface.id
            let showTrackID=try e.timelineAddTrack(surfaceID:showSurface.id,parameter:"opacity")
            try e.timelineEditKey(trackID:showTrackID,index:0,key:AutomationKeyframe(time:0,value:0,interpolation:.hold))
            try e.timelineEditKey(trackID:showTrackID,index:1,key:AutomationKeyframe(time:2,value:0.25,interpolation:.bezier,control1:Point2(0.3,0),control2:Point2(0.7,1)))
            try e.timelineEditKey(trackID:showTrackID,index:nil,key:AutomationKeyframe(time:6,value:0.75))
            try e.timelineEditKey(trackID:showTrackID,index:nil,key:AutomationKeyframe(time:10,value:1))
            e.seekShow(to:1);try expect(e.renderer.surfaces[0].opacity==0,"Hold timeline did not retain outgoing value")
            e.seekShow(to:4);try expect(abs(e.renderer.surfaces[0].opacity-0.5)<1e-9,"Bezier timeline did not evaluate against master show time")
            e.openOutput(showOutput,fullscreen:false,showWindow:false)
            let showOutputRenderer=try required(e.outputWindows[.preview(showOutput.id)],"Timeline output missing").1
            try expect(showOutputRenderer.surfaces == e.renderer.surfaces,"Timeline output used a different time/program")
            let showPixels=try editorPixels()
            try expect(abs(Int(showPixels[(48*128+64)*4])-128)<=1,"Timeline opacity did not reach actual Metal output")
            e.lighting.isSampling=true;e.lighting.isSending=false;e.lastLighting=0;e.tick()
            try expect(e.lighting.renderer.surfaces == e.effectiveSurfaces,"Timeline light sampling used different show time")
            try expect(pump(timeout:5) {abs(Int(e.lighting.lastUniverses[1]?.first ?? 0)-128)<=1},"Timeline GPU light sample did not follow master opacity")
            e.lighting.stop();e.closeOutputs()
            passed("master timeline without video drives hold/Bezier editor, independent output and GPU light sampling")

            let beforeInvalidKey=e.project
            do { try e.timelineEditKey(trackID:showTrackID,index:1,key:AutomationKeyframe(time:0,value:0.5));throw Failure(message:"Duplicate timeline key accepted") }
            catch is Failure {throw Failure(message:"Duplicate timeline key accepted")}
            catch {try expect(e.project==beforeInvalidKey,"Rejected key collision changed document")}
            do { try e.timelineEditKey(trackID:showTrackID,index:1,key:AutomationKeyframe(time:2,value:0.25,interpolation:.bezier,control1:Point2(0.8,0),control2:Point2(0.2,1)));throw Failure(message:"Non-monotonic curve time accepted") }
            catch is Failure {throw Failure(message:"Non-monotonic curve time accepted")}
            catch {try expect(e.project==beforeInvalidKey,"Rejected Bezier control changed document")}
            try e.timelineSetTrackEnabled(id:showTrackID,enabled:false)
            try expect(e.renderer.surfaces[0].opacity==1,"Disabled timeline still overrides base state")
            e.undoEdit();try expect(e.project==beforeInvalidKey,"Undo timeline enable did not restore tracks")
            let secondTrackID=try e.timelineAddTrack(surfaceID:showSurface.id,parameter:"brightness")
            try expect(e.project.timeline.count==2,"Second parameter track was not created")
            try e.timelineRemoveTrack(id:secondTrackID);e.undoEdit();try expect(e.project.timeline.count==2,"Undo track deletion lost binding")
            e.redoEdit();try expect(e.project.timeline.count==1,"Redo track deletion differs")
            passed("timeline mutations reject collisions/invalid curves atomically and preserve enabled/binding history")

            let timeline=TimelineWindowController(editor:e);e.timelineWindow=timeline
            timeline.window?.orderOut(nil);timeline.selectedTrackID=showTrackID;timeline.refresh()
            timeline.window?.contentView?.layoutSubtreeIfNeeded()
            try expect(timeline.canvas.bounds.width > (timeline.window?.contentView?.bounds.width ?? 1200)*0.6,"Timeline graph did not fill the available window width")
            try expect(timeline.canvas.track?.id==showTrackID && timeline.window?.isVisible==false,"Hidden timeline did not bind the actual selected track")
            let beforeGraphInsert=e.project
            timeline.canvas.onInsertKey?(5,0.65)
            try expect(e.project.timeline[0].keyframes.contains {$0.time==5 && $0.value==0.65},"Actual graph insert callback did not publish a key")
            e.undoEdit();try expect(e.project==beforeGraphInsert,"One graph insert Undo did not restore the project")
            e.redoEdit()
            let graphIndex=try required(e.project.timeline[0].keyframes.firstIndex {$0.time==5},"Inserted graph key missing")
            let beforeGraphDrag=e.project
            timeline.canvas.onEditKey?(graphIndex,AutomationKeyframe(time:5.5,value:0.7,interpolation:.hold))
            try expect(e.project.timeline[0].keyframes.contains {$0.time==5.5 && $0.interpolation == .hold},"Actual graph drag callback did not move key/mode")
            e.undoEdit();try expect(e.project==beforeGraphDrag,"Graph drag did not commit as one Undo")
            e.redoEdit();timeline.canvas.onSeek?(4)
            try expect(e.showRuntime.time==4 && timeline.canvas.playhead==4,"Ruler seek did not reach the master clock and graph playhead")
            passed("hidden graphical timeline binds track and production insert/drag/ruler callbacks with one-command history")

            let pauseMarker=try e.timelineAddMarker(name:"Wait",time:3,action:.pause,cueID:nil)
            let cueMarker=try e.timelineAddMarker(name:"Recall",time:5,action:.cue,cueID:showCue.id)
            e.stopShow(at:100);e.playShow(at:100);e.advanceShow(at:104)
            try expect(e.showRuntime.time==3 && !e.showRuntime.isPlaying && !e.media.isPlaying && abs(e.media.currentTime-3)<1e-9,"Pause marker did not latch show/media at exact crossing")
            try expect(e.cueTarget==nil,"Pause marker allowed a later scene marker in the same tick")
            e.seekShow(to:5,at:150);try expect(e.cueTarget==nil,"Explicit seek fired a scene marker")
            e.playShow(at:200);e.advanceShow(at:201);try expect(e.cueTarget==nil,"Play at a scene marker retriggered it")
            e.stopShow(at:300);try e.timelineDeleteMarker(id:pauseMarker)
            e.playShow(at:300);e.advanceShow(at:305.2)
            try expect(e.cueTarget?.id==showCue.id,"Natural scene marker did not call the production scene engine")
            e.commitInterruptedCue();e.stopShow(at:400)
            try e.timelineDeleteMarker(id:cueMarker)
            var loopSettings=e.project.timelineSettings;loopSettings.loopEnabled=true;loopSettings.loopStart=2;loopSettings.loopEnd=6
            try e.timelineUpdateSettings(loopSettings)
            e.seekShow(to:5.8,at:500);e.playShow(at:500);e.advanceShow(at:500.5);e.pauseShow(at:500.5)
            try expect(abs(e.showRuntime.time-2.3)<1e-9 && abs(e.media.currentTime-2.3)<1e-9,"Loop range did not preserve overshoot and resync media")
            passed("natural pause/scene markers, seek suppression and loop overshoot synchronize production show/media adapters")

            _=try e.timelineAddMarker(name:"Scene reference",time:5,action:.cue,cueID:showCue.id)
            let beforeSceneDelete=e.project;e.cuePicker.selectItem(at:0);e.deleteCue()
            try expect(e.project.cues.isEmpty && e.project.timelineSettings.markers.isEmpty,"Deleting scene left a dangling timeline marker")
            e.undoEdit();try expect(e.project==beforeSceneDelete,"Undo scene deletion did not restore marker references")
            let timelineURL=directory.appendingPathComponent("timeline.aperturecue.json")
            e.saveTo(timelineURL);let timelineSaved=e.project
            e.newProject();try expect(e.timelineWindow==nil && !e.showRuntime.isPlaying && e.showRuntime.time==0,"New retained old timeline window/runtime")
            e.openProject(timelineURL)
            try expect(e.project==timelineSaved && e.project.version==Project.currentVersion && e.showRuntime.time==0 && !e.showRuntime.isPlaying,"Timeline schema/settings/keys did not survive save/new/open with clean runtime")
            passed("timeline scene references, loop/settings/curves persist and new/open reset window/playhead/runtime")

            var legacyLong=Project(version:4,name:"Legacy continuing transport",surfaces:[Surface(name:"Long show")])
            legacyLong.timeline=[]
            let legacyLongURL=directory.appendingPathComponent("legacy-long.aperturecue.json")
            try JSONEncoder().encode(legacyLong).write(to:legacyLongURL)
            e.dirty=false;e.openProject(legacyLongURL)
            try expect(!e.project.timelineSettings.stopAtEnd,"Legacy project gained a new ten-second stop")
            e.seekShow(to:60,at:100)
            try expect(e.showRuntime.time==60 && e.media.currentTime==60,"Legacy continuing transport cannot seek past the graph horizon")
            e.playShow(at:100);e.advanceShow(at:101)
            try expect(e.showRuntime.time==61 && e.showRuntime.isPlaying && e.media.isPlaying,"Legacy transport stopped a long show at ten seconds")
            e.pauseShow(at:101);e.stopShow()
            passed("legacy projects retain continuing master playback and seek beyond the default graph horizon")

            for name in try SelectiveCueEditorTest.run(editor:e,directory:directory) { passed(name) }
            for name in try RecordingEditorSelfTest.run(editor:e,directory:directory) { passed(name) }
            for name in try RecordingMediaSelfTest.run(editor:e,directory:directory) { passed(name) }
            for name in try MontageEditorSelfTest.run(editor:e,directory:directory) { passed(name) }

            var lockedSurface=Surface(name:"Locked stroke",shape:.bezier,stroke:.bezier)
            lockedSurface.input=crop
            lockedSurface.mask=[Point2(0.1,0.1),Point2(0.8,0.1),Point2(0.8,0.8),Point2(0.1,0.8)]
            lockedSurface.meshColumns=2; lockedSurface.meshRows=2
            lockedSurface.mesh=try Geometry.regularMesh(quad:lockedSurface.output,columns:2,rows:2)
            var cueSurface=lockedSurface; cueSurface.output=output
            cueSurface.mesh=try Geometry.regularMesh(quad:output,columns:2,rows:2)
            let geometryCue=Cue(name:"Move locked surface",surfaces:[cueSurface],duration:0)
            let opacityTrack=AutomationTrack(name:"Locked opacity",surfaceID:lockedSurface.id,parameter:"opacity",
                                             keyframes:[AutomationKeyframe(time:0,value:1),AutomationKeyframe(time:10,value:0)])
            e.mutate("Geometry lock fixture") { $0=Project(surfaces:[lockedSurface],cues:[geometryCue],timeline:[opacityTrack]) }
            e.selectedID=lockedSurface.id; e.modePicker.selectItem(at:0); e.refresh()
            func geometryButton(_ title:String) throws -> ActionButton {
                try required(e.inspector.arrangedSubviews.compactMap { $0 as? ActionButton }.first { $0.title==title },"Missing geometry control \(title)")
            }
            try geometryButton("Lock geometry").performClick(nil)
            let locked=e.project
            try expect(locked.geometryLockedSurfaceIDs==[lockedSurface.id] && e.history.undoLabel=="Lock geometry","Inspector lock did not commit one history command")
            e.undoEdit(); try expect(e.project.geometryLockedSurfaceIDs.isEmpty,"Undo did not unlock the layer")
            e.redoEdit(); try expect(e.project==locked,"Redo did not restore the geometry lock")

            e.goCue(index:0)
            for (input,mesh,mask,path) in [(false,false,false,false),(true,false,false,false),(false,true,false,false),
                                           (true,false,true,false),(false,false,false,true)] {
                e.overlay.maskMode=mask; e.overlay.pathMode=path
                e.overlay.onBegin?(); e.overlay.onChange?(lockedSurface.id,output,input,mesh); e.overlay.onEnd?()
            }
            e.overlay.maskMode=false; e.overlay.pathMode=false
            try expect(e.cueTarget?.id==geometryCue.id && e.dragBefore==nil && e.project==locked,"Locked drag changed the document or interrupted GO")
            try expect(e.overlay.hitSurface(at:Point2(0.5,0.5))==lockedSurface.id,"Locked stroke could not be selected by its visible contour")
            for title in ["Reset quad / input","Create 4 × 4 warp mesh","Edit mesh points","Edit polygon mask","Remove mask","Path nodes…"] {
                let button=try geometryButton(title)
                try expect(!button.isEnabled,"Locked geometry control was enabled: \(title)")
                button.actionBlock?()
            }
            let lockedShapePicker=try required(e.inspector.arrangedSubviews.compactMap { $0 as? ActionPopUp }.first,"Missing shape picker")
            try expect(!lockedShapePicker.isEnabled,"Locked shape picker was enabled")
            lockedShapePicker.actionBlock?(0)
            let widthSlider=try required(e.inspector.arrangedSubviews.compactMap { $0 as? ActionSlider }.first,"Missing stroke-width slider")
            try expect(!widthSlider.isEnabled,"Locked width slider was enabled")
            widthSlider.actionBlock?(0.3)
            try e.insertStrokeNode(after:0)
            try e.editStrokeHandles(surfaceID:lockedSurface.id,world:[])
            try expect(e.project==locked && e.history.undoLabel=="Lock geometry" && e.cueTarget?.id==geometryCue.id,"Locked commands changed document, history or GO")
            passed("geometry lock keeps layer selectable, blocks canvas and inspector geometry actions and leaves pending GO intact")

            e.tick()
            try expect(e.project.surfaces[0].output==output && e.project.geometryLockedSurfaceIDs==[lockedSurface.id],"Full GO failed to move the locked geometry or changed the lock")
            e.seekShow(to:5)
            try expect(e.effectiveSurfaces.first?.opacity==0.5,"Automation no longer renders on the locked layer")
            let lockURL=directory.appendingPathComponent("geometry-lock.aperturecue.json")
            e.saveTo(lockURL); let savedLock=e.project
            e.newProject(); try expect(e.project.geometryLockedSurfaceIDs.isEmpty,"New inherited a previous document lock")
            e.openProject(lockURL); try expect(e.project==savedLock && e.editableGeometryIndex==nil,"Reopen lost the geometry lock")
            try geometryButton("Unlock geometry").performClick(nil)
            try expect(e.history.undoLabel=="Unlock geometry" && e.editableGeometryIndex != nil,"Unlock did not restore editing")
            let unlockedCrop=Point2.unitQuad
            e.overlay.onBegin?(); e.overlay.onChange?(lockedSurface.id,unlockedCrop,true,false); e.overlay.onEnd?()
            try expect(e.project.surfaces[0].input==unlockedCrop && e.history.undoLabel=="Move control point","Unlocked input drag did not commit")
            e.undoEdit(); e.undoEdit(); try expect(e.project==savedLock,"Undo unlock lost saved surface state")
            e.deleteSurface(); try expect(e.project.geometryLockedSurfaceIDs.isEmpty,"Deletion left an orphan lock")
            e.undoEdit(); try expect(e.project==savedLock,"Delete Undo failed to restore layer and lock")
            passed("scene and automation still render locked layers; lock and unlock round trip with save, reopen and history")

            let triangleGroup=SurfaceGroup(name:"Triangle frame",transform:Affine2D(a:-0.8,b:0.05,c:0.1,d:0.8,tx:0.85,ty:0.05))
            var triangle=Surface(name:"Editable triangle",input:crop,output:output,shape:.triangle,groupID:triangleGroup.id)
            triangle.meshColumns=2; triangle.meshRows=2
            triangle.mesh=try Geometry.regularMesh(quad:output,columns:2,rows:2)
            triangle.mesh[4].x += 0.06
            e.mutate("Triangle vertices fixture") { $0=Project(surfaces:[triangle],groups:[triangleGroup]) }
            e.selectedID=triangle.id; e.refresh()
            try geometryButton("Edit triangle vertices").performClick(nil)
            try expect(e.overlay.pathMode && !e.inputMode,"Triangle inspector button did not enter vertex editing")
            let triangleFrame=try required(e.resolvedBaseSurfaces.first,"Triangle frame missing")
            let targetVertex=Point2(0.27,0.25)
            let vertexWorld=try SurfaceGeometry.outputPoint(local:targetVertex,surface:triangleFrame)
            let collapsedWorld=try SurfaceGeometry.outputPoint(local:Point2(0.5,1),surface:triangleFrame)
            e.overlay.onBegin?()
            e.overlay.onTriangleDrag?(triangle.id,0,vertexWorld)
            let movedTriangle=e.project.surfaces[0]
            e.overlay.onTriangleDrag?(triangle.id,0,collapsedWorld)
            e.overlay.onEnd?()
            try expect(e.project.surfaces[0]==movedTriangle && pointsNear([movedTriangle.triangleVertices[0]],[targetVertex]),
                       "Triangle vertex drag lost its last valid point in the group/mesh frame")
            var expectedTriangle=triangle
            expectedTriangle.triangleVertices[0]=movedTriangle.triangleVertices[0]
            try expect(movedTriangle==expectedTriangle && e.history.undoLabel=="Move control point",
                       "Triangle drag changed a stationary vertex, cage, mesh or input")
            e.undoEdit(); try expect(e.project.surfaces[0]==triangle,"Triangle vertex Undo did not restore all points")
            e.redoEdit(); try expect(e.project.surfaces[0]==movedTriangle,"Triangle vertex Redo did not restore edited points")
            try geometryButton("Reset triangle vertices").performClick(nil)
            try expect(e.project.surfaces[0]==triangle,"Reset triangle vertices changed other fields")
            e.undoEdit()
            try geometryButton("Lock geometry").performClick(nil)
            try expect(!(try geometryButton("Reset triangle vertices")).isEnabled,"Locked triangle offers an enabled reset")
            e.overlay.onBegin?(); e.overlay.onTriangleDrag?(triangle.id,0,collapsedWorld); e.overlay.onEnd?()
            try expect(e.project.surfaces[0]==movedTriangle && e.history.undoLabel=="Lock geometry","Locked triangle accepted a drag")
            let triangleURL=directory.appendingPathComponent("triangle-vertices.aperturecue.json")
            e.saveTo(triangleURL)
            let savedTriangle=e.project
            e.newProject(); e.openProject(triangleURL)
            try expect(e.project==savedTriangle && !e.overlay.pathMode,"Custom vertices and lock did not survive reopening")
            passed("triangle vertex editing through mirrored group and mesh changes only its active vertex, with lock, reset, Undo/Redo and reopen")

            var maskSurface=Surface(name:"Mask editor",input:crop,output:output,groupID:triangleGroup.id)
            maskSurface.meshColumns=2; maskSurface.meshRows=2
            maskSurface.mesh=try Geometry.regularMesh(quad:output,columns:2,rows:2)
            e.mutate("Mask fixture") { $0=Project(surfaces:[maskSurface],groups:[triangleGroup]) }
            e.selectedID=maskSurface.id; e.refresh()
            try geometryButton("Add polygon mask").performClick(nil)
            try expect(e.overlay.maskMode && e.inputMode,"Source mask did not open in input view")
            let sourceMaskProject=e.project
            let maskPicker=try required(e.inspector.arrangedSubviews.compactMap { $0 as? ActionPopUp }.first(where:{$0.itemTitles.contains("Output canvas coordinates")}),"Mask coordinate picker missing")
            maskPicker.actionBlock?(1)
            try expect(e.project.surfaces[0].maskSettings.space == .outputCanvas && !e.inputMode && e.overlay.maskMode,"Output mask did not switch to output canvas")
            let outputMask=e.project
            e.undoEdit(); try expect(e.project==sourceMaskProject && e.inputMode,"Undo coordinate space did not restore input mask view")
            e.redoEdit(); try expect(e.project==outputMask && !e.inputMode,"Redo coordinate space did not restore output mask view")
            var draggedMask=outputMask.surfaces[0].mask; draggedMask[0]=Point2(0.17,0.23)
            e.overlay.onBegin?(); e.overlay.onChange?(maskSurface.id,draggedMask,false,false); e.overlay.onEnd?()
            var expectedMask=outputMask.surfaces[0]; expectedMask.mask=draggedMask
            try expect(e.project.surfaces[0]==expectedMask,"Output mask drag applied group inverse or changed UV/mesh/cage")
            e.undoEdit(); try expect(e.project==outputMask,"Mask drag Undo differs")
            e.redoEdit()
            try geometryButton("Invert mask: OFF").performClick(nil)
            let maskSlider=try required(e.inspector.arrangedSubviews.compactMap {$0 as? ActionSlider}.last,"Mask feather slider missing")
            maskSlider.actionBlock?(0.125)
            try expect(e.project.surfaces[0].maskSettings == PolygonMaskSettings(space:.outputCanvas,inverted:true,feather:0.125),"Mask inspector callbacks did not persist settings")
            let maskURL=directory.appendingPathComponent("mask-settings.aperturecue.json")
            e.saveTo(maskURL); let savedMask=e.project
            e.newProject(); e.openProject(maskURL)
            try expect(e.project==savedMask && !e.overlay.maskMode,"Mask settings did not survive Save/reopen")
            try geometryButton("Lock geometry").performClick(nil)
            let protectedMask=e.project
            let disabledPicker=try required(e.inspector.arrangedSubviews.compactMap {$0 as? ActionPopUp}.first(where:{$0.itemTitles.contains("Output canvas coordinates")}),"Locked mask picker missing")
            let disabledFeather=try required(e.inspector.arrangedSubviews.compactMap {$0 as? ActionSlider}.last,"Locked mask slider missing")
            let disabledInvert=try geometryButton("Invert mask: ON")
            try expect(!disabledPicker.isEnabled && !disabledFeather.isEnabled && !disabledInvert.isEnabled,"Locked mask controls remained enabled")
            disabledPicker.actionBlock?(0); disabledFeather.actionBlock?(0.4); disabledInvert.actionBlock?(); e.editPolygonMask()
            try expect(e.project==protectedMask && !e.overlay.maskMode,"Locked mask accepted direct inspector callbacks")
            passed("mask space switches editing view with Undo/Redo; output points stay in canvas coordinates through group and mesh")
            passed("mask inversion/feather native controls, save/reopen and geometry-lock guards")

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
