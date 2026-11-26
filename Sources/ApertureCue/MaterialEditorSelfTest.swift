#if os(macOS)
import AppKit
import MappingCore

/// Hidden production-command checks, not modal/UI automation. This helper is
/// for EditorSelfTest's stopped, disposable controller: it closes outputs,
/// pauses transport, clears history, and restores the original document fields
/// on exit. It does not attempt to restore a live show's transport/history.
@MainActor enum MaterialEditorSelfTest {
    private struct Failure:LocalizedError {let message:String;var errorDescription:String? {message}}
    static func run(editor e:EditorController) throws -> [String] {
        let original=e.project,originalURL=e.projectURL,originalSelection=e.selectedID
        let originalGroup=e.selectedGroupID,originalMedia=e.selectedMediaID,originalGeneration=e.documentGeneration
        let originalDirty=e.dirty,originalMode=e.modePicker.indexOfSelectedItem,originalBlackout=e.blackout
        let originalOutput=e.renderer.outputID,originalError=e.editError,originalRenderError=e.renderer.errorDescription
        let originalCache=e.renderer.materialCache
        func stop() {
            e.closeOutputs();e.overlay.finishDrag();e.cueEngine.cancel();e.cueTarget=nil;e.cueBefore=nil
            e.showRuntime.stop();e.media.pause();e.feedback?.reset();e.dragBefore=nil;e.history.clear()
        }
        stop()
        defer {
            stop();e.project=original;e.projectURL=originalURL;e.selectedID=originalSelection
            e.selectedGroupID=originalGroup;e.selectedMediaID=originalMedia;e.documentGeneration=originalGeneration
            e.dirty=originalDirty;e.blackout=originalBlackout;e.modePicker.selectItem(at:originalMode)
            e.renderer.outputID=originalOutput;e.overlay.maskMode=false;e.overlay.meshMode=false
            e.overlay.pathMode=false;e.overlay.warpMode=false;e.overlay.drawMode=false
            e.editError=originalError;e.reconcile();e.refresh()
            e.renderer.materialCache=originalCache;e.renderer.errorDescription=originalRenderError
        }
        func expect(_ condition:@autoclosure() throws ->Bool,_ message:String) throws {
            if try !condition() {throw Failure(message:message)}
        }
        func required<T>(_ value:T?,_ message:String) throws ->T {
            guard let value else {throw Failure(message:message)};return value
        }
        func rejected(_ action:() throws ->Void,_ message:String) throws {
            let before=e.project,dirty=e.dirty,undo=e.history.undoLabel,redo=e.history.redoLabel
            let canUndo=e.history.canUndo,canRedo=e.history.canRedo
            var failed=false
            do {try action()} catch {failed=true}
            try expect(failed,message)
            try expect(e.project==before && e.dirty==dirty && e.history.undoLabel==undo && e.history.redoLabel==redo &&
                       e.history.canUndo==canUndo && e.history.canRedo==canRedo,"Rejected material/FX command changed document or history")
        }
        func pixels() throws -> [UInt8] {
            e.updateRender()
            let image=try required(e.renderer.snapshot(width:64,height:48),"Material editor snapshot failed: "+e.renderer.errorDescription)
            let data=try required(image.bitmapData,"Material editor snapshot has no bytes")
            // Read selected pixels rather than platform-dependent row padding.
            return [(8,8),(20,24),(39,13),(54,37)].flatMap {x,y in
                let offset=y*image.bytesPerRow+x*4;return (0..<4).map {data[offset+$0]}
            }
        }
        var checks:[String]=[]
        func passed(_ name:String) {checks.append(name);print("PASS editor material: "+name)}
        let a=Surface(name:"Original material left",output:[Point2(0,0),Point2(0.5,0),Point2(0.5,1),Point2(0,1)],generator:"gradient")
        let b=Surface(name:"Original material right",output:[Point2(0.5,0),Point2(1,0),Point2(1,1),Point2(0.5,1)],generator:"gradient")
        e.project=Project(name:"Original material command fixture",surfaces:[a,b]);e.projectURL=nil
        e.selectedID=a.id;e.selectedGroupID=nil;e.selectedMediaID=nil;e.documentGeneration=UUID();e.dirty=false
        e.modePicker.selectItem(at:0);e.blackout=false;e.renderer.outputID=nil
        e.overlay.maskMode=false;e.overlay.meshMode=false;e.overlay.pathMode=false;e.overlay.warpMode=false;e.overlay.drawMode=false
        e.reconcile();e.refresh()
        let amount=MaterialInput(name:"amount",label:"Original tint",defaultValue:[0.25])
        let definition=MaterialDefinition(name:"Original native tint",expression:"mix(sample(uv),vec4(0.8,0.2,0.4,1),amount)",
                                          inputs:[amount],credit:"Original ApertureCue test expression; GPL-3.0-or-later")
        let initial=e.project
        try e.saveMaterial(definition,values:["amount":[0.3]])
        let assigned=e.project
        try expect(assigned.materials==[definition] && assigned.surfaces[0].materialID==definition.id &&
                   assigned.surfaces[0].materialValues==["amount":[0.3]],"Save material lost definition/assignment/overrides")
        let accepted=try required(e.renderer.materialCache[definition.id],"Save did not preflight material cache")
        try expect(Set(accepted.pipelines.keys)==Set(["normal","add","multiply","screen"]),"Save did not preflight all blend variants")
        e.undoEdit();try expect(e.project==initial,"Material Save Undo differs")
        e.redoEdit();try expect(e.project==assigned,"Material Save Redo differs")
        passed("material Save + Assign preflights all blend variants and supports document Undo/Redo")

        let lastPixels=try pixels()
        let lastPipelineIDs=accepted.pipelines.mapValues {ObjectIdentifier($0 as AnyObject)}
        var invalid=definition;invalid.expression="vec4(1); while(true){}"
        try rejected({try e.saveMaterial(invalid)},"Invalid expression replaced accepted material")
        try rejected({try e.assignMaterial(definition.id,values:["amount":[2]])},"Out-of-range override accepted")
        try rejected({try e.assignMaterial(definition.id,values:["missing":[0.5]])},"Unknown override accepted")
        try rejected({try e.assignMaterial(UUID())},"Missing material assignment accepted")
        try rejected({try e.assignMaterial(nil,values:["amount":[0.5]])},"Unassigned parameter values accepted")
        let retained=try required(e.renderer.materialCache[definition.id],"Rejected source removed last-good cache")
        try expect(retained.definition==definition && retained.pipelines.mapValues {ObjectIdentifier($0 as AnyObject)}==lastPipelineIDs,
                   "Rejected material replaced accepted pipeline objects")
        try expect(try pixels()==lastPixels,"Rejected material changed last-good production pixels")
        passed("invalid source and assignments preserve document/history, accepted pipeline identities and last-good pixels")

        let beforeFX=e.project
        let fx=EffectsSettings(keyMode:.luma,threshold:0.2,softness:0.08,saturation:0.6,inverted:true,posterizeLevels:5)
        try e.saveEffects(fx);let afterFX=e.project
        try expect(afterFX.surfaces[0].effects==fx,"Save FX lost settings")
        e.undoEdit();try expect(e.project==beforeFX,"FX Undo differs")
        e.redoEdit();try expect(e.project==afterFX,"FX Redo differs")
        try rejected({try e.saveEffects(EffectsSettings(threshold:Double.nan))},"Nonfinite FX accepted")
        e.toggleGeometryLock(for:a.id)
        var lockedFX=fx;lockedFX.saturation=0.8
        try e.saveEffects(lockedFX)
        try expect(e.project.surfaces[0].effects==lockedFX && e.project.geometryLockedSurfaceIDs.contains(a.id),"Geometry lock incorrectly blocked appearance FX")
        passed("surface FX use actual Save callbacks, validation/history and geometry-lock appearance semantics")

        let isfSource="""
        /*{"ISFVSN":"2.0","CREDIT":"Original ApertureCue ISF command fixture; GPL-3.0-or-later","INPUTS":[{"NAME":"inputImage","TYPE":"image"},{"NAME":"amount","TYPE":"float","DEFAULT":0.25,"MIN":0,"MAX":1}]}*/
        void main(){gl_FragColor=mix(IMG_NORM_THIS_PIXEL(inputImage),vec4(isf_FragNormCoord,0.5,1),amount);}
        """
        let beforeISF=e.project
        let imported=try e.importISF(Data(isfSource.utf8),name:"Original native ISF")
        let afterISF=e.project
        try expect(afterISF.materials.contains(imported) && afterISF.surfaces[0].materialID==imported.id &&
                   afterISF.surfaces[0].materialValues.isEmpty && imported.credit.contains("GPL-3.0-or-later"),"ISF callback lost source assignment/defaults/provenance")
        e.undoEdit();try expect(e.project==beforeISF,"ISF import Undo differs")
        e.redoEdit();try expect(e.project==afterISF,"ISF import Redo differs")
        try rejected({_ = try e.importISF(Data("/*{\"ISFVSN\":\"2\",\"IMPORTED\":{\"foreign\":{\"PATH\":\"../foreign.png\"}}}*/ void main(){gl_FragColor=vec4(1);}".utf8),name:"Rejected external")},"External ISF import accepted")
        try rejected({_ = try e.importISF(Data(repeating:32,count:65537),name:"Rejected size")},"Oversized ISF source accepted")
        try rejected({_ = try e.importISF(Data([255]),name:"Rejected encoding")},"Non-UTF8 ISF source accepted")
        passed("ISF import retains provenance and assignment with Undo/Redo and atomically rejects unsupported/oversized/invalid text")

        try e.assignMaterial(definition.id,values:["amount":[0.3]])
        e.selectedID=b.id;try e.assignMaterial(definition.id,values:["amount":[0.7]])
        let fullID=try e.cueCreate(name:"Original full material scene",scope:.full,bindings:[],duration:0,followAfter:nil)
        let bindings=[CueBinding(surfaceID:a.id,parameters:[.material,.effects])]
        let selectiveID=try e.cueCreate(name:"Original material + FX selective",scope:.selective,bindings:bindings,duration:0,followAfter:nil)
        let persisted=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(e.project))
        try ProjectStore.validate(persisted)
        try expect(persisted==e.project && persisted.version==12,"Material/FX project round trip differs")
        let selective=try required(persisted.cues.first(where:{$0.id==selectiveID}),"Selective material cue missing")
        try expect(selective.bindings==bindings && selective.surfaces[0].materialID==definition.id &&
                   selective.surfaces[0].materialValues==["amount":[0.3]] && selective.surfaces[0].effects==lockedFX,
                   "Selective material/FX field masks or captured payloads lost in persistence")
        passed("shared current/full/selective material and FX assignments retain atomic masks in schema-12 persistence")

        e.selectedID=a.id;try e.assignMaterial(nil)
        e.selectedID=b.id;try e.assignMaterial(nil)
        var incompatible=definition;incompatible.inputs=[];incompatible.expression="sample(uv)"
        try rejected({try e.saveMaterial(incompatible,assignSelected:false)},"Definition edit ignored material parameters in stored scenes")
        try expect(e.project.cues.contains(where:{$0.id==fullID}) && e.project.materials.contains(definition),"Shared scene validation removed stored definition")
        let library=e.project.materials
        try e.assignMaterial(imported.id);try e.assignMaterial(nil)
        try expect(e.project.materials==library && e.project.cues.first(where:{$0.id==selectiveID})?.surfaces.first?.materialID==definition.id,
                   "Clear selected material deleted shared library/scene state")
        try e.assignMaterial(definition.id,values:["amount":[0.5]])
        let beforeDelete=e.project
        try e.deleteMaterial(definition.id);let deleted=e.project
        try expect(!deleted.materials.contains(where:{$0.id==definition.id}) && deleted.materials.contains(imported),"Delete removed wrong library definitions")
        try expect((deleted.surfaces+deleted.cues.flatMap(\.surfaces)).allSatisfy {$0.materialID != definition.id && ($0.materialID != nil || $0.materialValues.isEmpty)},
                   "Delete left material IDs or orphan overrides in current/stored surfaces")
        e.undoEdit();try expect(e.project==beforeDelete,"Material deletion Undo did not restore all current/scene references")
        e.redoEdit();try expect(e.project==deleted,"Material deletion Redo differs")
        passed("definition edits validate stored scene overrides; clear preserves library and delete clears/restores all current/scene references")
        return checks
    }
}
#endif
