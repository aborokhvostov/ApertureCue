#if os(macOS)
import AppKit
import QuartzCore
import MappingCore

@MainActor enum CompositionEditorSelfTest {
    private struct Failure:LocalizedError {let message:String;var errorDescription:String? {message}}
    static func run(editor e:EditorController,directory:URL) throws -> [String] {
        let original=e.project,originalURL=e.projectURL,originalSelection=e.selectedID,originalGroup=e.selectedGroupID,originalMedia=e.selectedMediaID
        let originalDirty=e.dirty,originalMode=e.modePicker.indexOfSelectedItem,originalGeneration=e.documentGeneration
        let originalBlackout=e.blackout,originalRenderOutput=e.renderer.outputID
        let originalError=e.editError,originalOutputMessage=e.outputMessage
        var checks:[String]=[]
        func expect(_ value:@autoclosure() throws ->Bool,_ message:String) throws {if try !value() {throw Failure(message:message)}}
        func reject(_ action:() throws ->Void,_ message:String) throws {
            do {try action()} catch is ProjectError {return}
            throw Failure(message:message)
        }
        func passed(_ name:String) {checks.append(name);print("PASS editor composition: "+name)}
        func fixture(_ project:Project,selected:UUID?) {
            e.closeOutputs();e.overlay.finishDrag();e.cueEngine.cancel();e.cueTarget=nil;e.cueBefore=nil;e.showRuntime.stop();e.media.pause()
            e.project=project;e.projectURL=nil;e.selectedID=selected;e.selectedMediaID=nil;e.selectedGroupID=nil;e.documentGeneration=UUID();e.dirty=false;e.history.clear()
            e.modePicker.selectItem(at:0);e.overlay.maskMode=false;e.overlay.meshMode=false;e.overlay.pathMode=false;e.overlay.warpMode=false;e.overlay.drawMode=false
            e.editError="";e.blackout=false;e.renderer.outputID=nil;e.reconcile();e.refresh()
        }
        defer {
            e.closeOutputs();e.overlay.finishDrag();e.cueEngine.cancel();e.cueTarget=nil;e.cueBefore=nil;e.showRuntime.stop();e.media.pause()
            e.project=original;e.projectURL=originalURL;e.selectedID=originalSelection;e.selectedGroupID=originalGroup;e.selectedMediaID=originalMedia
            e.documentGeneration=originalGeneration;e.dirty=originalDirty;e.history.clear();e.dragBefore=nil
            e.modePicker.selectItem(at:originalMode);e.overlay.maskMode=false;e.overlay.meshMode=false;e.overlay.pathMode=false;e.overlay.warpMode=false;e.overlay.drawMode=false
            e.editError=originalError;e.outputMessage=originalOutputMessage;e.blackout=originalBlackout;e.renderer.outputID=originalRenderOutput;e.reconcile();e.refresh()
        }
        let group=SurfaceGroup(name:"Composition test group")
        let a=Surface(name:"Layer A",input:Point2.insetQuad,output:[Point2(0.1,0.1),Point2(0.65,0.1),Point2(0.65,0.8),Point2(0.1,0.8)],groupID:group.id)
        let b=Surface(name:"Layer B",output:[Point2(0.4,0.2),Point2(0.9,0.2),Point2(0.9,0.9),Point2(0.4,0.9)],groupID:group.id)
        fixture(Project(surfaces:[a,b],groups:[group]),selected:a.id)
        var layerMask=CompositionMask(name:"Layer cubic",curve:.ellipse,settings:.init(space:.sourceUV,feather:0.01))
        let beforeMask=e.project
        try e.saveCompositionMask(layerMask,scope:.surface(a.id))
        let savedLayerMask=e.project
        e.undoEdit();try expect(e.project==beforeMask,"Layer mask Undo differs")
        e.redoEdit();try expect(e.project==savedLayerMask,"Layer mask Redo differs")
        try e.insertCompositionMaskNode(scope:.surface(a.id),maskID:layerMask.id,after:3)
        let split=try required(e.project.surfaces[0].masks.first?.curve,"Split cubic mask missing")
        try expect(split.nodes.count==5 && split.nodes[4].anchor != split.nodes[3].anchor,"Cubic closing edge did not split")
        try e.removeCompositionMaskNode(scope:.surface(a.id),maskID:layerMask.id,at:4)
        try expect(e.project.surfaces[0].masks[0].curve?.nodes.count==4,"Scoped node removal failed")
        e.toggleGeometryLock(for:a.id);let locked=e.project,label=e.history.undoLabel
        layerMask.settings.inverted=true
        try reject({try e.saveCompositionMask(layerMask,scope:.surface(a.id))},"Locked scoped mask accepted Save")
        try reject({try e.removeCompositionMask(layerMask.id,scope:.surface(a.id))},"Locked scoped mask accepted Delete")
        try expect(e.project==locked && e.history.undoLabel==label,"Locked mask changed document/history")
        e.toggleGeometryLock(for:a.id)
        passed("layer cubic masks use real save/split/remove callbacks, locks and Undo/Redo")

        let groupMask=CompositionMask(name:"Group mask",settings:.init(space:.sourceUV))
        let globalMask=CompositionMask(name:"Global mask",curve:.ellipse,settings:.init(space:.outputCanvas,inverted:true,feather:0.02))
        try e.saveCompositionMask(groupMask,scope:.group(group.id));try e.saveCompositionMask(globalMask,scope:.global)
        try expect(e.project.groups[0].masks==[groupMask] && e.project.globalMasks==[globalMask],"Group/global mask scope lost")
        let validScopes=e.project,scopeLabel=e.history.undoLabel
        try reject({try e.saveCompositionMask(CompositionMask(settings:.init(space:.sourceUV)),scope:.global)},"Global source-UV mask accepted")
        try expect(e.project==validScopes && e.history.undoLabel==scopeLabel,"Invalid mask scope changed history")
        try e.removeCompositionMask(groupMask.id,scope:.group(group.id));e.undoEdit()
        try expect(e.project==validScopes,"Scoped mask delete Undo failed")
        passed("group/global scope ownership, global space rejection and deletion history")

        fixture(Project(surfaces:[a,b],groups:[group]),selected:a.id)
        try e.saveGroupComposition(groupID:group.id,isolated:true,blendMode:"screen",effects:.init(saturation:0.4))
        let isolated=e.project
        try expect(isolated.groups[0].isolated && isolated.groups[0].blendMode=="screen" && isolated.groups[0].effects.saturation==0.4,"Group composition callbacks lost settings")
        e.undoEdit();try expect(e.project.groups[0]==group,"Group composition Undo differs")
        e.redoEdit();try expect(e.project==isolated,"Group composition Redo differs")
        var interleaved=isolated;interleaved.groups[0].isolated=false;interleaved.groups[0].effects = .init();interleaved.groups[0].blendMode="normal"
        interleaved.surfaces.insert(Surface(name:"Outside group"),at:1);e.project=interleaved
        let invalidHistory=e.history.undoLabel
        try reject({try e.saveGroupComposition(groupID:group.id,isolated:true,blendMode:"normal",effects:.init())},"Interleaved isolated group accepted")
        try expect(e.project==interleaved && e.history.undoLabel==invalidHistory,"Interleaved rejection was not atomic")
        fixture(Project(surfaces:[a,b],groups:[group]),selected:a.id)
        passed("isolated group FX/blend controls, history and contiguous-stack rejection")

        let bounds=try required(GroupEngine.bounds(for:group.id,in:e.project),"Group bounds missing")
        let source=[bounds.min,Point2(bounds.max.x,bounds.min.y),bounds.max,Point2(bounds.min.x,bounds.max.y)]
        let destination=[Point2(0.2,0.1),Point2(0.85,0.2),Point2(0.78,0.92),Point2(0.1,0.78)]
        let delta=try Homography.solve(from:source,to:destination),beforePerspective=e.project
        try e.applyGroupPerspective(groupID:group.id,to:destination)
        let afterPerspective=e.project,resolved=try GroupEngine.resolve(surfaces:e.project.surfaces,groups:e.project.groups)
        try expect(afterPerspective.surfaces==beforePerspective.surfaces,"Group perspective rewrote local surface/input state")
        for index in a.output.indices {
            let expected=try delta.applying(a.output[index]),actual=resolved[0].output[index]
            try expect(hypot(actual.x-expected.x,actual.y-expected.y)<1e-9,"Group perspective differs from independent homography")
        }
        e.undoEdit();try expect(e.project==beforePerspective,"Perspective Undo failed")
        e.redoEdit();try expect(e.project==afterPerspective,"Perspective Redo failed")
        passed("group perspective keeps local/source fields and matches world homography with Undo/Redo")

        let svg="<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect width='100' height='100' fill='red'/><rect y='50' width='100' height='50' fill='blue'/><path fill='green' fill-rule='evenodd' d='M10 10H90V90H10Z M30 30H70V70H30Z'/></svg>"
        let document=try SVGImport.parse(Data(svg.utf8)),bitmap=try SVGImageRenderer.bitmap(document,maximumDimension:100)
        try expect(pixel(bitmap,5,5)==[255,0,0,255] && pixel(bitmap,5,95)==[0,0,255,255],"SVG raster sRGB/orientation differs")
        try expect(pixel(bitmap,15,15)==[0,128,0,255] && pixel(bitmap,50,60)==[0,0,255,255],"SVG compound hole differs")
        let opacity="<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><g opacity='0.5'><rect width='100' height='100' fill='red'/><rect x='20' width='80' height='100' fill='blue'/></g></svg>"
        let alpha=try SVGImageRenderer.bitmap(SVGImport.parse(Data(opacity.utf8)),maximumDimension:100)
        try expect(pixel(alpha,50,50)==[0,0,128,128],"SVG overlapping group opacity applied more than once")
        passed("SVG native raster exact sRGB, orientation, compound holes and isolated overlapping opacity")

        let slot=Surface(name:"SVG image slot",output:Point2.unitQuad)
        fixture(Project(surfaces:[slot]),selected:slot.id)
        let importFolder=directory.appendingPathComponent("svg-owned",isDirectory:true)
        let assetID=try e.importSVG(data:Data(svg.utf8),name:"Original SVG",directory:importFolder,maximumDimension:100)
        let asset=try required(e.project.assets.first(where:{$0.id==assetID}),"SVG asset missing")
        try expect(asset.path.hasPrefix(importFolder.path+"/") && FileManager.default.fileExists(atPath:asset.path),"SVG import is not a durable owned PNG")
        let imported=e.project,importLabel=e.history.undoLabel
        try reject({_ = try e.importSVG(data:Data("<!DOCTYPE svg><svg/>".utf8),name:"Rejected",directory:importFolder)},"Unsafe SVG accepted")
        try expect(e.project==imported && e.history.undoLabel==importLabel,"Rejected SVG changed project/history")
        e.undoEdit();try expect(e.project.assets.isEmpty && FileManager.default.fileExists(atPath:asset.path),"SVG Undo deleted durable Redo asset")
        e.redoEdit();try expect(e.project==imported,"SVG import Redo differs")
        let deadline=CACurrentMediaTime()+5
        while e.media.texture(for:assetID)==nil,CACurrentMediaTime()<deadline {_ = RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.01))}
        try expect(e.media.texture(for:assetID) != nil,"Imported SVG PNG did not become an ordinary media texture")
        e.updateRender();let rendered=try required(e.renderer.snapshot(width:100,height:100),"SVG media composition snapshot failed")
        try expect(near(pixel(rendered,5,5),[255,0,0,255]) && near(pixel(rendered,5,95),[0,0,255,255]),"SVG durable PNG render differs from raster")
        passed("SVG import owns persistent media, rejects atomically and survives Undo/Redo through production media/Metal")

        let beforeWall=e.project,wallConfig=VideoWallConfiguration(columns:2,rows:2,overlapX:0.2,overlapY:0.25)
        let outputIDs=try e.createVideoWall(wallConfig),wall=e.project,tiles=try VideoWall.tiles(wallConfig)
        try expect(outputIDs.count==4 && Set(outputIDs).count==4 && wall.outputs.count==4 && wall.surfaces.count==5 && !wall.surfaces[0].enabled,"Video wall did not atomically create routes/hide source")
        for i in tiles.indices {
            let layer=wall.surfaces[i+1]
            try expect(layer.outputID==outputIDs[i] && layer.input==tiles[i].input && layer.output==Point2.unitQuad && layer.mediaID==assetID,"Video wall tile crop/source/route differs")
            try expect(wall.outputs[i].displayUUID==nil && wall.outputs[i].edgeBlend==tiles[i].edgeBlend,"Wall implicitly assigned a display or lost overlap")
        }
        e.undoEdit();try expect(e.project==beforeWall,"Video wall Undo failed")
        e.redoEdit();try expect(e.project==wall,"Video wall Redo failed")
        e.openOutput(wall.outputs[0],fullscreen:false,showWindow:false)
        let preview=try required(e.outputWindows[.preview(outputIDs[0])],"Hidden wall preview missing")
        try expect(preview.0.isVisible==false && preview.1.outputID==outputIDs[0],"Wall route preview became visible or targeted wrong route")
        let calibration=EdgeBlendSettings(left:0.1,right:0.2,power:2,gamma:1.4,blackLevel:0.01)
        try e.saveEdgeBlend(outputID:outputIDs[0],settings:calibration)
        try expect(e.project.outputs[0].edgeBlend==calibration && preview.1.edgeBlend==calibration,"Output blend saver did not update live hidden renderer")
        e.closeOutputs()
        passed("2x2 video wall crop/routes, unassigned displays, Undo/Redo and hidden edge-blend preview")

        let warpSurface=Surface(name:"Warp callbacks",input:Point2.insetQuad,output:Point2.insetQuad)
        fixture(Project(surfaces:[warpSurface]),selected:warpSurface.id)
        try e.createBezierWarp();try e.toggleMeshLink()
        let beforeDrag=e.project,current=e.project.surfaces[0]
        let controls=try required(current.bezierWarp,"Output Bezier lattice missing").controls
        let world=try current.warpTransform.applying(controls[5]),target=Point2(world.x+0.01,world.y-0.01)
        e.overlay.onBegin?();e.overlay.onWarpDrag?(warpSurface.id,5,target,false);e.overlay.onEnd?()
        let afterDrag=e.project
        try expect(afterDrag != beforeDrag && afterDrag.surfaces[0].inputWarp != beforeDrag.surfaces[0].inputWarp,"Linked warp canvas callback did not update source/output")
        for i in controls.indices where i != 5 {try expect(afterDrag.surfaces[0].bezierWarp?.controls[i]==controls[i],"Warp drag changed stationary control")}
        e.undoEdit();try expect(e.project==beforeDrag,"Warp drag Undo differs")
        e.redoEdit();try expect(e.project==afterDrag,"Warp drag Redo differs")
        try e.toggleMeshLink();e.modePicker.selectItem(at:1);e.updateRender()
        let beforeInput=e.project;e.overlay.onNudge?(0.01,0)
        try expect(e.project.surfaces[0].output==beforeInput.surfaces[0].output && e.project.surfaces[0].input[0].x==beforeInput.surfaces[0].input[0].x+0.01,"Unlinked input nudge changed output")
        e.modePicker.selectItem(at:0);e.updateRender();let beforeNudge=e.project;e.overlay.onNudge?(0.01,0)
        try expect(e.project.surfaces[0].input==beforeNudge.surfaces[0].input && e.project.surfaces[0].output != beforeNudge.surfaces[0].output,"Output nudge changed input or did nothing")
        e.toggleGeometryLock(for:warpSurface.id);let lockedWarp=e.project
        e.overlay.onNudge?(0.1,0);e.overlay.onBegin?();e.overlay.onWarpDrag?(warpSurface.id,5,world,false);e.overlay.onEnd?()
        try expect(e.project==lockedWarp,"Geometry lock allowed warp/nudge callbacks")
        passed("linked Bezier canvas drag, stationary controls, input/output nudge, locks and history")

        fixture(Project(),selected:nil)
        e.overlay.onFreehand?([Point2(0.1,0.2),Point2(0.2,0.3),Point2(0.35,0.25),Point2(0.5,0.5)])
        try expect(e.project.surfaces.count==1 && e.project.surfaces[0].shape.isStroke,"Freehand callback did not create a textured path")
        let freehand=e.project;e.undoEdit();try expect(e.project.surfaces.isEmpty,"Freehand Undo failed")
        e.redoEdit();try expect(e.project==freehand,"Freehand Redo failed")
        passed("production freehand callback creates an ordinary undoable stroke surface")

        fixture(Project(surfaces:[warpSurface]),selected:warpSurface.id)
        try e.createBezierWarp();e.setWarpEditing(input:true)
        let initialSource=try SurfaceGeometry.sourcePoint(local:Point2(0.4,0.6),surface:e.project.surfaces[0])
        let inputControl=try required(e.project.surfaces[0].inputWarp,"Input warp missing").controls[5]
        let inputPoint=try e.project.surfaces[0].inputWarpTransform.applying(inputControl)
        e.overlay.onBegin?();e.overlay.onWarpDrag?(warpSurface.id,5,Point2(inputPoint.x+0.1,inputPoint.y),true);e.overlay.onEnd?()
        let editedSource=try SurfaceGeometry.sourcePoint(local:Point2(0.4,0.6),surface:e.project.surfaces[0])
        try expect(editedSource != initialSource,"Source control edit was invisible")
        e.modePicker.selectItem(at:0);e.overlay.warpMode=false;e.updateRender()
        let cageBefore=e.project
        let newCage=[Point2(0.12,0.08),Point2(0.92,0.14),Point2(0.85,0.94),Point2(0.1,0.85)]
        e.overlay.onBegin?();e.overlay.onChange?(warpSurface.id,newCage,false,false);e.overlay.onEnd?()
        try expect(e.project.surfaces[0].inputWarp==cageBefore.surfaces[0].inputWarp && e.project.surfaces[0].bezierWarp==cageBefore.surfaces[0].bezierWarp,"Cage callback discarded a lattice")
        try expect(try SurfaceGeometry.sourcePoint(local:Point2(0.4,0.6),surface:e.project.surfaces[0])==editedSource,"Unlinked output cage changed source UV")
        let resetBefore=e.project;e.resetSelectedGeometry()
        try expect(e.project.surfaces[0].output==Point2.insetQuad && e.project.surfaces[0].inputWarp==resetBefore.surfaces[0].inputWarp,"Output reset lost independent source mapping")
        e.undoEdit();try expect(e.project==resetBefore,"Output reset Undo differs")
        e.redoEdit();e.modePicker.selectItem(at:1);e.resetSelectedGeometry()
        try expect(e.project.surfaces[0].input==Point2.unitQuad && e.project.surfaces[0].inputWarp==nil,"Input reset retained active source warp")
        e.modePicker.selectItem(at:0);e.setWarpEditing(input:false);e.refreshInspector()
        let createMesh=try required(e.inspector.arrangedSubviews.compactMap {$0 as? ActionButton}.first {$0.title=="Create 4 × 4 warp mesh"},"Create regular mesh control missing")
        try expect(createMesh.isEnabled,"Create regular mesh unexpectedly disabled")
        if let action=createMesh.action {NSApplication.shared.sendAction(action,to:createMesh.target,from:createMesh)}
        try expect(e.project.surfaces[0].mesh.count==25 && !e.overlay.warpMode && e.overlay.meshMode,"Regular mesh replacement left Bezier mode without handles")
        try e.toggleMeshLink();let regularBefore=e.project
        e.resetSelectedGeometry();try ProjectStore.validate(e.project)
        try expect(e.project.surfaces[0].inputMesh==regularBefore.surfaces[0].inputMesh && !e.project.surfaces[0].meshLinked,"Regular output reset lost source topology or left implicit link")
        passed("real cage/reset/regular-mesh controls preserve independent mappings, restore flat output and keep usable handles")

        var exportGroup=SurfaceGroup(name:"Export isolation",opacity:0.5);exportGroup.isolated=true
        let exportBackground=Surface(output:Point2.unitQuad,color:[0,1,0],generator:"solid")
        let exportLayer=Surface(output:Point2.unitQuad,color:[1,0,0],generator:"solid",groupID:exportGroup.id)
        var exportProject=Project(surfaces:[exportBackground,exportLayer],groups:[exportGroup])
        exportProject.globalMasks=[CompositionMask(points:[Point2(0.1,0.1),Point2(0.7,0.1),Point2(0.7,0.9),Point2(0.1,0.9)])]
        fixture(exportProject,selected:exportLayer.id)
        let outputExport=try required(e.compositionExportFrame(width:64,height:64),"Output export missing")
        e.modePicker.selectItem(at:1);e.updateRender()
        let previewSurfaces=e.renderer.surfaces
        let inputExport=try required(e.compositionExportFrame(width:64,height:64),"Input-mode export missing")
        try expect(near(pixel(outputExport,32,32),[128,128,0,255]) && near(pixel(outputExport,55,32),[0,0,0,255]),"Export oracle lost group opacity/global mask")
        try expect(pixel(inputExport,32,32)==pixel(outputExport,32,32) && pixel(inputExport,55,32)==pixel(outputExport,55,32),"Input-mode export differs from output composition")
        try expect(e.renderer.surfaces==previewSurfaces && e.renderer.compositionGroups.isEmpty && e.renderer.globalMasks.isEmpty,"Export changed the input preview configuration")
        passed("PNG production export keeps group isolation and global masks in Input mode and restores preview")

        let feedbackOutput=OutputConfig(name:"Editor feedback reset",width:32,height:18)
        var feedbackLayer=Surface(output:Point2.unitQuad,generator:"solid");feedbackLayer.feedbackOutputID=feedbackOutput.id
        fixture(Project(surfaces:[feedbackLayer],outputs:[feedbackOutput]),selected:feedbackLayer.id)
        e.advanceFeedback()
        let feedbackDeadline=CACurrentMediaTime()+10
        while e.feedback?.pending==true,CACurrentMediaTime()<feedbackDeadline {RunLoop.current.run(until:Date(timeIntervalSinceNow:0.005))}
        try expect(e.feedback?.frame != nil,"Editor feedback fixture did not publish")
        e.deleteSurface();e.tick()
        try expect(e.feedback?.frame==nil && e.renderer.feedbackFrame==nil,"Deleting last feedback layer retained history")
        e.undoEdit()
        try expect(e.feedback?.frame==nil,"Undo revived discarded feedback history")
        passed("deleting the last feedback layer resets hub and renderer leases before Undo")

        e.selectedID=feedbackLayer.id;e.refresh()
        let feedbackBeforeImport=e.project
        e.importMediaFiles([URL(fileURLWithPath:asset.path)])
        try expect(e.project.surfaces[0].mediaID != nil && e.project.surfaces[0].feedbackOutputID==nil,"Ordinary import retained feedback or failed assignment")
        let ordinaryImport=e.project
        e.undoEdit();try expect(e.project==feedbackBeforeImport,"Media replacement Undo lost feedback source")
        e.redoEdit();try expect(e.project==ordinaryImport,"Media replacement Redo differs")
        passed("ordinary media import replaces feedback atomically and retains source assignment history")

        var modeStroke=Surface(name:"Mode transitions",output:Point2.unitQuad,shape:.bezier)
        modeStroke.stroke = .bezier
        fixture(Project(surfaces:[modeStroke]),selected:modeStroke.id)
        try e.createBezierWarp();let modeWarp=e.project.surfaces[0].bezierWarp
        e.setShapePointEditing(true)
        try expect(e.overlay.pathMode && !e.overlay.warpMode && !e.overlay.meshMode && !e.overlay.drawMode,"Path tool retained another tool's handles")
        e.overlay.updateLayer() // Six path handles must never index a 16-control warp lattice.
        e.setWarpEditing(input:false);e.editPolygonMask()
        try expect(e.overlay.maskMode && !e.overlay.warpMode && !e.overlay.pathMode,"Mask tool retained warp gesture routing")
        var movedMask=e.project.surfaces[0].mask;movedMask[0].x+=0.02
        e.overlay.onBegin?();e.overlay.onChange?(modeStroke.id,movedMask,true,false);e.overlay.onEnd?()
        try expect(e.project.surfaces[0].mask==movedMask && e.project.surfaces[0].bezierWarp==modeWarp,"Mask gesture edited warp controls")
        e.beginFreehand();e.setWarpEditing(input:false)
        try expect(e.overlay.warpMode && !e.overlay.drawMode && !e.overlay.maskMode,"Warp tool retained armed freehand capture")
        passed("path, mask, warp, mesh and freehand modes have exclusive handle and gesture ownership")

        fixture(wall,selected:wall.surfaces[1].id)
        let persistentGroup=SurfaceGroup(name:"Persistent composite")
        e.mutate("Persistent group fixture") {p in p.groups.append(persistentGroup);for i in 1..<p.surfaces.count {p.surfaces[i].groupID=persistentGroup.id}}
        try e.saveCompositionMask(CompositionMask(curve:.ellipse,settings:.init(space:.sourceUV)),scope:.surface(wall.surfaces[1].id))
        try e.saveCompositionMask(CompositionMask(settings:.init(space:.outputCanvas)),scope:.group(persistentGroup.id))
        try e.saveCompositionMask(CompositionMask(curve:.ellipse,settings:.init(space:.outputCanvas)),scope:.global)
        try e.saveGroupComposition(groupID:persistentGroup.id,isolated:true,blendMode:"normal",effects:.init(saturation:0.8))
        try e.createBezierWarp();try e.toggleMeshLink()
        e.mutate("Persistent cue fixture") {$0.cues=[Cue(name:"Composition",surfaces:$0.surfaces,duration:0)]}
        let url=directory.appendingPathComponent("composition-stage2.aperturecue.json")
        e.saveTo(url);try expect(!e.dirty && e.projectURL==url,"Composition controller Save failed")
        let saved=e.project;e.openProject(url)
        try expect(e.project==saved && e.project.version==Project.currentVersion,"Schema composition save/reopen differs")
        let collectedURL=try ProjectStore.collect(saved,to:directory.appendingPathComponent("composition-collected-"+UUID().uuidString))
        var collected=try ProjectStore.load(from:collectedURL);let copiedPaths=collected.assets.map(\.path);collected.assets=saved.assets
        try expect(collected==saved && copiedPaths.allSatisfy {FileManager.default.fileExists(atPath:$0)},"Composition Collect lost model data or SVG PNG")
        passed("schema composition persistence and portable Collect retain masks/groups/warp/link/wall/SVG resources")
        checks += try MaterialEditorSelfTest.run(editor:e)
        return checks
    }
    private static func required<T>(_ value:T?,_ message:String) throws ->T {guard let value else {throw Failure(message:message)};return value}
    private static func pixel(_ bitmap:NSBitmapImageRep,_ x:Int,_ y:Int)->[Int] {guard let data=bitmap.bitmapData else {return []};let o=y*bitmap.bytesPerRow+x*4;return (0..<4).map {Int(data[o+$0])}}
    private static func near(_ a:[Int],_ b:[Int])->Bool {a.count==b.count && zip(a,b).allSatisfy {abs($0-$1)<=2}}
}
#endif
