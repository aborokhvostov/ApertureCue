#if os(macOS)
import AppKit
import MappingCore

extension EditorController {
    var allCompositionRenderers:[MetalRenderer] {
        var result:[MetalRenderer]=[]
        if let renderer {result.append(renderer)}
        result += outputWindows.values.map {$0.1}
        if let r=lighting?.renderer {result.append(r)}
        return result
    }
    func configureCompositionRenderer(_ target:MetalRenderer) {
        target.compositionGroups=project.groups;target.globalMasks=project.globalMasks
        target.materialDefinitions=project.materials;target.materialTime=showRuntime.time
        target.feedbackTextures=feedback?.textures ?? [:];target.feedbackFrame=feedback?.frame
        target.edgeBlend=target.outputID.flatMap {id in project.outputs.first(where:{$0.id==id})?.edgeBlend} ?? .init()
        if target === renderer,inputMode {target.compositionGroups=[];target.globalMasks=[];target.edgeBlend = .init()}
    }
    func updateCompositionConfiguration() {
        for target in allCompositionRenderers {configureCompositionRenderer(target)}
    }
    func updateFeedbackTextures() {
        for target in allCompositionRenderers {
            target.feedbackTextures=feedback?.textures ?? [:];target.feedbackFrame=feedback?.frame
        }
    }
    func advanceFeedback() {
        feedback?.advance(surfaces:effectiveSurfaces,outputs:project.outputs,groups:project.groups,masks:project.globalMasks,materials:project.materials,time:showRuntime.time,blackout:blackout)
    }
    func configureFeedback() {
        guard let index=selectedIndex else {return}
        let surface=project.surfaces[index],generation=documentGeneration,outputs=project.outputs
        let picker=ActionPopUp(items:["No output feedback"]+outputTitles(outputs),selected:surface.feedbackOutputID.flatMap {id in outputs.firstIndex(where:{$0.id==id}).map {$0+1}} ?? 0,action:{_ in})
        picker.frame=NSRect(x:0,y:0,width:400,height:28)
        let alert=NSAlert();alert.messageText="Previous-frame output source"
        alert.informativeText="The selected surface samples the last completed output generation. All routes read the same previous generation, so cycles are delayed. First frame and resets are black. Up to 8 referenced routes, 4096 per axis, 16M total pixels; four retained generations maximum. Save replaces its media source."
        alert.accessoryView=picker;alert.addButton(withTitle:"Save source");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {return}
        do {
            guard generation==documentGeneration,let i=selectedIndex,project.surfaces[i]==surface else {throw ProjectError.invalid("selected surface changed; reopen feedback source")}
            let selected=picker.indexOfSelectedItem
            guard selected>=0,selected<=outputs.count else {throw ProjectError.invalid("choose an output")}
            try assignFeedbackSource(selected==0 ? nil : outputs[selected-1].id)
        } catch {showError(error)}
    }
    func assignFeedbackSource(_ id:UUID?) throws {
        guard let i=selectedIndex else {return}
        var candidate=project;candidate.surfaces[i].feedbackOutputID=id
        if id != nil {candidate.surfaces[i].mediaID=nil}
        try ProjectStore.validate(candidate)
        mutate("Output feedback source") {$0=candidate}
        feedback?.reset()
    }
    func nudgeInput(dx:Double,dy:Double) {
        guard let i=editableGeometryIndex else {return}
        overlay.finishDrag()
        do {
            let s=project.surfaces[i],delta=Affine2D.translation(x:dx,y:dy)
            var candidate=project
            if s.meshLinked {
                let parent=try GroupEngine.worldTransform(for:s.groupID,groups:project.groups)
                let mapping=try parent.concatenating(Affine2D.perspective(from:s.input,to:s.output))
                candidate=try SurfaceEditing.applyingWorldTransform(surfaceID:s.id,transform:mapping.concatenating(delta).concatenating(mapping.inverse()),in:project)
            }
            candidate.surfaces[i].input=try s.input.map {try delta.applying($0)}
            candidate.surfaces[i].inputMesh=try s.inputMesh.map {try delta.applying($0)}
            if s.inputWarp != nil {candidate.surfaces[i].inputWarpTransform=delta.concatenating(s.inputWarpTransform)}
            try ProjectStore.validate(candidate);mutate("Nudge input") {$0=candidate}
        } catch {editError=error.localizedDescription}
    }
    func beginFreehand() {
        overlay.finishDrag();modePicker.selectItem(at:0)
        overlay.drawMode=true;overlay.warpMode=false;overlay.maskMode=false;overlay.meshMode=false;overlay.pathMode=false
        window?.makeFirstResponder(overlay);updateRender()
    }
}
#endif
