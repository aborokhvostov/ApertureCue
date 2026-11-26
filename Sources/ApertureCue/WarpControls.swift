#if os(macOS)
import AppKit
import MappingCore

extension EditorController {
    func createBezierWarp(columns: Int = 1,rows: Int = 1) throws {
        guard let index=editableGeometryIndex else {return}
        overlay.finishDrag()
        let id=project.surfaces[index].id,candidate=try SurfaceEditing.creatingBezierWarp(surfaceID:id,columns:columns,rows:rows,in:project)
        mutate("Create Bezier warp") {$0=candidate}
        modePicker.selectItem(at:0);overlay.warpMode=true;overlay.meshMode=false;overlay.maskMode=false;overlay.pathMode=false
        updateRender();refreshInspector()
    }

    func resetBezierWarp() throws {
        guard let index=editableGeometryIndex else {return}
        overlay.finishDrag()
        let candidate=try SurfaceEditing.resettingBezierWarp(surfaceID:project.surfaces[index].id,in:project)
        overlay.warpMode=false;mutate("Reset Bezier warp") {$0=candidate}
        updateRender();refreshInspector()
    }

    func toggleMeshLink() throws {
        guard let index=editableGeometryIndex else {return}
        overlay.finishDrag()
        let surface=project.surfaces[index]
        let candidate=try SurfaceEditing.settingMeshLink(surfaceID:surface.id,enabled:!surface.meshLinked,in:project)
        mutate("Link source mesh") {$0=candidate}
    }

    func setWarpEditing(input: Bool) {
        guard let index=editableGeometryIndex else {return}
        overlay.finishDrag()
        do {
            let id=project.surfaces[index].id,candidate: Project
            if input {candidate=try SurfaceEditing.preparingInputWarp(surfaceID:id,in:project)}
            else if project.surfaces[index].bezierWarp == nil {candidate=try SurfaceEditing.creatingBezierWarp(surfaceID:id,in:project)}
            else {candidate=project}
            mutate(input ? "Prepare source Bezier warp" : "Create Bezier warp") {$0=candidate}
            modePicker.selectItem(at:input ? 1 : 0)
            overlay.warpMode=true;overlay.meshMode=false;overlay.maskMode=false;overlay.pathMode=false
            updateRender();refreshInspector()
        } catch {showError(error)}
    }

    /// Canvas drags already own one history command through onBegin/onEnd. A
    /// rejected sample keeps the last valid model and only the active lattice
    /// point is replaced; other handles never pass through an ambiguous inverse.
    func editWarpHandle(surfaceID: UUID,index: Int,world: Point2,input: Bool) throws {
        guard dragBefore != nil,let selected=editableGeometryIndex,project.surfaces[selected].id==surfaceID else {return}
        let candidate=try SurfaceEditing.editingWarpControl(surfaceID:surfaceID,index:index,world:world,input:input,in:project)
        project=candidate;editError="";updateRender()
    }

    func configureWarp() {
        guard let index=editableGeometryIndex else {return}
        overlay.finishDrag()
        let surface=project.surfaces[index],generation=documentGeneration
        if surface.bezierWarp == nil {
            let columns=ActionField("1",action:{_ in}),rows=ActionField("1",action:{_ in})
            let view=stack([label("Patch columns / rows · 1…8"),stack([columns,rows],vertical:false)])
            view.frame=NSRect(x:0,y:0,width:400,height:70)
            for field in [columns,rows] {field.widthAnchor.constraint(equalToConstant:190).isActive=true}
            let alert=NSAlert();alert.messageText="Create Bezier warp"
            alert.informativeText="The initial warp preserves the projective cage and quad crop. This replaces the existing regular mesh and its source edits. Independent handles remain editable; source linking is initially off."
            alert.accessoryView=view;alert.addButton(withTitle:"Create warp");alert.addButton(withTitle:"Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {return}
            do {
                try checkWarpModal(surface,generation:generation)
                guard let c=Int(columns.stringValue),let r=Int(rows.stringValue) else {throw ProjectError.invalid("enter patch counts from 1 to 8")}
                try createBezierWarp(columns:c,rows:r)
            } catch {showError(error)}
            return
        }
        guard let output=surface.bezierWarp else {return}
        let space=ActionPopUp(items:["Output world coordinates","Input source UV"],selected:inputMode ? 1 : 0,action:{_ in})
        let picker=ActionPopUp(items:output.controls.indices.map {"Control row \($0/output.controlColumns+1), column \($0%output.controlColumns+1)"},action:{_ in})
        let x=ActionField("",action:{_ in}),y=ActionField("",action:{_ in})
        let group: Affine2D
        do {group=try GroupEngine.worldTransform(for:surface.groupID,groups:project.groups)}
        catch {showError(error);return}
        func load() {
            let selected=picker.indexOfSelectedItem
            guard output.controls.indices.contains(selected) else {return}
            do {
                let point: Point2
                if space.indexOfSelectedItem == 1 {
                    let source=try surface.inputWarp ?? BezierWarp.regular(quad:Point2.unitQuad,columns:output.columns,rows:output.rows)
                    let transform: Affine2D
                    if surface.inputWarp != nil {transform=surface.inputWarpTransform}
                    else {transform=try Self.warpFrame(from:surface.input)}
                    point=try transform.applying(source.controls[selected])
                } else {point=try group.concatenating(surface.warpTransform).applying(output.controls[selected])}
                x.stringValue=String(point.x);y.stringValue=String(point.y)
            } catch {x.stringValue="";y.stringValue=""}
        }
        space.actionBlock={_ in load()};picker.actionBlock={_ in load()};load()
        defer {space.actionBlock=nil;picker.actionBlock=nil}
        let view=stack([label("Space"),space,label("Independent lattice control"),picker,label("x / y"),stack([x,y],vertical:false)])
        view.frame=NSRect(x:0,y:0,width:450,height:180)
        for control in [space,picker] {control.widthAnchor.constraint(equalToConstant:440).isActive=true}
        for field in [x,y] {field.widthAnchor.constraint(equalToConstant:215).isActive=true}
        let alert=NSAlert();alert.messageText="Bezier warp controls"
        alert.informativeText="Save changes one control. Output points use the world canvas; input points use source UV. A linked mesh also moves the matching source/output control. Reset restores the cage and quad crop and removes both Bezier lattices."
        alert.accessoryView=view
        for title in ["Save point","Edit on canvas","Reset warp","Cancel"] {alert.addButton(withTitle:title)}
        let response=alert.runModal()
        guard [.alertFirstButtonReturn,.alertSecondButtonReturn,.alertThirdButtonReturn].contains(response) else {return}
        do {
            try checkWarpModal(surface,generation:generation)
            let input=space.indexOfSelectedItem==1
            if response == .alertFirstButtonReturn {
                guard let px=Double(x.stringValue),let py=Double(y.stringValue) else {throw ProjectError.invalid("enter finite warp coordinates")}
                let candidate=try SurfaceEditing.editingWarpControl(surfaceID:surface.id,index:picker.indexOfSelectedItem,world:Point2(px,py),input:input,in:project)
                mutate("Edit Bezier control") {$0=candidate};setWarpEditing(input:input)
            } else if response == .alertSecondButtonReturn {setWarpEditing(input:input)}
            else {try resetBezierWarp()}
        } catch {showError(error)}
    }

    func configureSurfaceTransform() {
        guard let index=editableGeometryIndex else {return}
        overlay.finishDrag()
        let surface=project.surfaces[index],generation=documentGeneration
        do {
            let world=try GroupEngine.resolve(surfaces:[surface],groups:project.groups)[0]
            let center=Point2(world.output.map(\.x).reduce(0,+)/4,world.output.map(\.y).reduce(0,+)/4)
            let dx=ActionField("0",action:{_ in}),dy=ActionField("0",action:{_ in}),sx=ActionField("1",action:{_ in}),sy=ActionField("1",action:{_ in})
            let angle=ActionField("0",action:{_ in}),px=ActionField(String(center.x),action:{_ in}),py=ActionField(String(center.y),action:{_ in})
            let view=stack([label("World translation x / y"),stack([dx,dy],vertical:false),label("Scale x / y · nonzero, negative mirrors"),stack([sx,sy],vertical:false),label("Clockwise rotation degrees · 16:9 canvas"),angle,label("World pivot x / y · default cage center"),stack([px,py],vertical:false)])
            view.frame=NSRect(x:0,y:0,width:430,height:240)
            for field in [dx,dy,sx,sy,px,py] {field.widthAnchor.constraint(equalToConstant:200).isActive=true}
            angle.widthAnchor.constraint(equalToConstant:414).isActive=true
            let alert=NSAlert();alert.messageText="Transform selected surface"
            alert.informativeText="Apply scale, then rotation, then translation. Source crop, input mesh and other surfaces keep their values."
            alert.accessoryView=view;alert.addButton(withTitle:"Apply transform");alert.addButton(withTitle:"Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {return}
            try checkWarpModal(surface,generation:generation)
            let values=try [dx,dy,sx,sy,angle,px,py].map {field -> Double in
                guard let value=Double(field.stringValue),value.isFinite else {throw ProjectError.invalid("enter finite surface transform values")};return value
            }
            let pivot=Point2(values[5],values[6]),delta=Affine2D.translation(x:values[0],y:values[1])
                .concatenating(Affine2D.rotation(degrees:values[4],around:pivot,aspectRatio:16.0/9.0))
                .concatenating(Affine2D.scale(x:values[2],y:values[3],around:pivot))
            let candidate=try SurfaceEditing.applyingWorldTransform(surfaceID:surface.id,transform:delta,in:project)
            mutate("Transform surface") {$0=candidate}
        } catch {showError(error)}
    }

    func nudgeSurface(dx: Double,dy: Double) {
        guard let index=editableGeometryIndex else {return}
        overlay.finishDrag()
        do {
            let candidate=try SurfaceEditing.applyingWorldTransform(surfaceID:project.surfaces[index].id,transform:.translation(x:dx,y:dy),in:project)
            mutate("Nudge surface") {$0=candidate};editError=""
        } catch {editError=error.localizedDescription}
    }

    func createFreehandSurface(points: [Point2]) throws {
        overlay.finishDrag()
        let result=try SurfaceEditing.addingFreehand(points:points,name:"Freehand \(project.surfaces.count+1)",in:project)
        mutate("Draw freehand surface") {$0=result.project};selectedID=result.surfaceID
        modePicker.selectItem(at:0);overlay.warpMode=false;overlay.meshMode=false;overlay.maskMode=false;overlay.pathMode=true
        refresh()
    }

    private func checkWarpModal(_ surface: Surface,generation: UUID) throws {
        guard generation==documentGeneration,let current=editableGeometryIndex,project.surfaces[current]==surface else {
            throw ProjectError.invalid("the selected surface changed while the geometry editor was open; reopen the editor")
        }
    }
    private static func warpFrame(from quad: [Point2]) throws -> Affine2D {
        let h=try Homography.solve(from:Point2.unitQuad,to:quad).values
        return Affine2D(a:h[0],b:h[3],c:h[1],d:h[4],tx:h[2],ty:h[5],px:h[6],py:h[7],pw:h[8])
    }
}
#endif
