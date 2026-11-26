#if os(macOS)
import AppKit
import MappingCore

enum EditorMaskScope:Equatable {
    case surface(UUID),group(UUID),global
}

extension EditorController {
    func compositionMasks(for scope:EditorMaskScope) throws -> [CompositionMask] {
        switch scope {
        case .surface(let id):guard let s=project.surfaces.first(where:{$0.id==id}) else {throw ProjectError.invalid("mask layer no longer exists")};return s.masks
        case .group(let id):guard let g=project.groups.first(where:{$0.id==id}) else {throw ProjectError.invalid("mask group no longer exists")};return g.masks
        case .global:return project.globalMasks
        }
    }
    func saveCompositionMask(_ mask:CompositionMask,scope:EditorMaskScope) throws {
        if case .surface(let id)=scope,project.geometryLockedSurfaceIDs.contains(id) {throw ProjectError.invalid("unlock layer geometry before editing its masks")}
        try mask.validate()
        var masks=try compositionMasks(for:scope)
        if let i=masks.firstIndex(where:{$0.id==mask.id}) {masks[i]=mask} else {masks.append(mask)}
        try replaceCompositionMasks(masks,scope:scope,label:"Save scoped mask")
    }
    func removeCompositionMask(_ id:UUID,scope:EditorMaskScope) throws {
        if case .surface(let layer)=scope,project.geometryLockedSurfaceIDs.contains(layer) {throw ProjectError.invalid("unlock layer geometry before removing masks")}
        var masks=try compositionMasks(for:scope)
        guard let i=masks.firstIndex(where:{$0.id==id}) else {throw ProjectError.invalid("mask no longer exists")}
        masks.remove(at:i);try replaceCompositionMasks(masks,scope:scope,label:"Remove scoped mask")
    }
    private func replaceCompositionMasks(_ masks:[CompositionMask],scope:EditorMaskScope,label:String) throws {
        var candidate=project
        switch scope {
        case .surface(let id):guard let i=candidate.surfaces.firstIndex(where:{$0.id==id}) else {throw ProjectError.invalid("missing mask layer")};candidate.surfaces[i].masks=masks
        case .group(let id):guard let i=candidate.groups.firstIndex(where:{$0.id==id}) else {throw ProjectError.invalid("missing mask group")};candidate.groups[i].masks=masks
        case .global:candidate.globalMasks=masks
        }
        try ProjectStore.validate(candidate);overlay.finishDrag();mutate(label) {$0=candidate}
    }
    func insertCompositionMaskNode(scope:EditorMaskScope,maskID:UUID,after index:Int) throws {
        guard var mask=try compositionMasks(for:scope).first(where:{$0.id==maskID}) else {throw ProjectError.invalid("mask no longer exists")}
        if let curve=mask.curve {mask.curve=try curve.insertingNode(after:index)}
        else {mask.points=try PolygonMaskGeometry.insertingVertex(in:mask.points,after:index)}
        try saveCompositionMask(mask,scope:scope)
    }
    func removeCompositionMaskNode(scope:EditorMaskScope,maskID:UUID,at index:Int) throws {
        guard var mask=try compositionMasks(for:scope).first(where:{$0.id==maskID}) else {throw ProjectError.invalid("mask no longer exists")}
        if let curve=mask.curve {mask.curve=try curve.removingNode(at:index)}
        else {mask.points=try PolygonMaskGeometry.removingVertex(in:mask.points,at:index)}
        try saveCompositionMask(mask,scope:scope)
    }

    func configureScopedMasks(initialScope:EditorMaskScope?=nil) {
        let snapshot=project,generation=documentGeneration
        var scopes:[EditorMaskScope]=[],titles:[String]=[]
        if let id=selectedID,snapshot.surfaces.contains(where:{$0.id==id}) {scopes.append(.surface(id));titles.append("Selected layer")}
        let groupID:UUID?
        if case .group(let id)?=initialScope {groupID=id}
        else {groupID=selectedGroupID ?? selectedIndex.flatMap {snapshot.surfaces[$0].groupID}}
        if let id=groupID,let group=snapshot.groups.first(where:{$0.id==id}) {scopes.append(.group(id));titles.append("Group · "+group.name)}
        scopes.append(.global);titles.append("Global composition")
        if let requested=initialScope,!scopes.contains(requested) {showError(ProjectError.invalid("requested mask scope is no longer available"));return}
        let selected=initialScope.flatMap {scopes.firstIndex(of:$0)} ?? 0
        let scopePicker=ActionPopUp(items:titles,selected:selected,action:{_ in})
        let maskPicker=ActionPopUp(items:[],action:{_ in}),type=ActionPopUp(items:["Polygon","Bézier contour"],action:{_ in})
        let name=ActionField("Mask",action:{_ in}),feather=ActionField("0",action:{_ in})
        let space=ActionPopUp(items:["Source UV / group local","Output canvas"],action:{_ in})
        let enabled=NSButton(checkboxWithTitle:"Enabled",target:nil,action:nil),inverted=NSButton(checkboxWithTitle:"Invert (cut out interior)",target:nil,action:nil)
        var displayed:[CompositionMask]=[]
        func masks(_ scope:EditorMaskScope)->[CompositionMask] {
            switch scope {case .surface(let id):return snapshot.surfaces.first(where:{$0.id==id})?.masks ?? []
            case .group(let id):return snapshot.groups.first(where:{$0.id==id})?.masks ?? []
            case .global:return snapshot.globalMasks}
        }
        func loadMask(_ index:Int) {
            let mask=displayed.indices.contains(index-1) ? displayed[index-1] : CompositionMask(name:"Mask",settings:.init(space:scopes[scopePicker.indexOfSelectedItem] == .global ? .outputCanvas : .sourceUV))
            name.stringValue=mask.name;feather.stringValue=String(mask.settings.feather);enabled.state=mask.enabled ? .on : .off;inverted.state=mask.settings.inverted ? .on : .off
            type.selectItem(at:mask.curve==nil ? 0 : 1);space.selectItem(at:mask.settings.space == .sourceUV ? 0 : 1)
            space.isEnabled=scopes[scopePicker.indexOfSelectedItem] != .global
        }
        func loadScope(_ index:Int) {
            guard scopes.indices.contains(index) else {return}
            displayed=masks(scopes[index]);maskPicker.removeAllItems()
            maskPicker.addItems(withTitles:["New mask"]+displayed.enumerated().map {"\($0.offset+1). \($0.element.name)"});maskPicker.selectItem(at:0);loadMask(0)
        }
        scopePicker.actionBlock=loadScope;maskPicker.actionBlock=loadMask;loadScope(selected)
        let view=stack([label("Scope"),scopePicker,label("Mask · at most eight per scope"),maskPicker,name,type,space,stack([enabled,inverted],vertical:false),label("Feather (0…0.5, selected coordinate space)"),feather])
        view.frame=NSRect(x:0,y:0,width:430,height:300)
        for control in [scopePicker,maskPicker,type,space] {control.widthAnchor.constraint(equalToConstant:420).isActive=true}
        name.widthAnchor.constraint(equalToConstant:420).isActive=true;feather.widthAnchor.constraint(equalToConstant:200).isActive=true
        let alert=NSAlert();alert.messageText="Layer, group and global masks"
        alert.informativeText="Masks multiply within their scope. Group local coordinates use the group frame; global masks use output canvas. Nodes saves these properties first, then edits control points. New Bézier contours start as an ellipse; converting an existing curve to polygon connects its anchors."
        alert.accessoryView=view;for title in ["Save mask","Nodes…","Delete mask","Cancel"] {alert.addButton(withTitle:title)}
        let response=alert.runModal()
        guard [.alertFirstButtonReturn,.alertSecondButtonReturn,.alertThirdButtonReturn].contains(response) else {return}
        do {
            guard generation==documentGeneration,project==snapshot,scopes.indices.contains(scopePicker.indexOfSelectedItem) else {throw ProjectError.invalid("project changed while editing masks; reopen the dialog")}
            let scope=scopes[scopePicker.indexOfSelectedItem],index=maskPicker.indexOfSelectedItem-1
            if response == .alertThirdButtonReturn {
                guard displayed.indices.contains(index) else {throw ProjectError.invalid("choose an existing mask to delete")}
                try removeCompositionMask(displayed[index].id,scope:scope);return
            }
            let existing=displayed.indices.contains(index)
            var mask=existing ? displayed[index] : CompositionMask()
            mask.name=name.stringValue;mask.enabled=enabled.state == .on
            guard let width=Double(feather.stringValue) else {throw ProjectError.invalid("enter finite mask feather")}
            mask.settings=PolygonMaskSettings(space:scope == .global ? .outputCanvas : (space.indexOfSelectedItem==0 ? .sourceUV : .outputCanvas),inverted:inverted.state == .on,feather:width)
            if type.indexOfSelectedItem==1,mask.curve==nil {mask.curve=existing ? try BezierMask.polygon(mask.points) : .ellipse}
            if type.indexOfSelectedItem==0,let curve=mask.curve {mask.points=curve.nodes.map(\.anchor);mask.curve=nil}
            try saveCompositionMask(mask,scope:scope)
            if response == .alertSecondButtonReturn {configureCompositionMaskNodes(scope:scope,maskID:mask.id)}
        } catch {showError(error)}
    }

    func configureCompositionMaskNodes(scope:EditorMaskScope,maskID:UUID) {
        do {
            guard let mask=try compositionMasks(for:scope).first(where:{$0.id==maskID}) else {throw ProjectError.invalid("mask no longer exists")}
            let generation=documentGeneration,snapshot=project
            let nodes=mask.curve?.nodes ?? mask.points.map {StrokeNode(anchor:$0)}
            let picker=ActionPopUp(items:nodes.indices.map {"Node \($0+1)"},action:{_ in})
            let fields=(0..<6).map {_ in ActionField("",action:{_ in})}
            func load(_ index:Int) {
                guard nodes.indices.contains(index) else {return};let n=nodes[index]
                for (field,value) in zip(fields,[n.anchor.x,n.anchor.y,n.incoming.x,n.incoming.y,n.outgoing.x,n.outgoing.y]) {field.stringValue=String(value)}
            }
            picker.actionBlock=load;load(0)
            for (i,field) in fields.enumerated() {field.widthAnchor.constraint(equalToConstant:200).isActive=true;field.isEnabled=mask.curve != nil || i<2}
            let view=stack([picker,label("Anchor x / y"),stack(Array(fields[0...1]),vertical:false),label("Incoming tangent x / y"),stack(Array(fields[2...3]),vertical:false),label("Outgoing tangent x / y"),stack(Array(fields[4...5]),vertical:false)])
            view.frame=NSRect(x:0,y:0,width:420,height:220)
            let alert=NSAlert();alert.messageText="Scoped mask nodes"
            alert.informativeText="Coordinates use the mask's declared space. Tangents are independent absolute coordinates. Insert splits the chosen closed edge; Remove changes its neighbours."
            alert.accessoryView=view;for title in ["Save node","Insert after","Remove node","Cancel"] {alert.addButton(withTitle:title)}
            alert.buttons[1].isEnabled=nodes.count<128;alert.buttons[2].isEnabled=nodes.count>3
            let response=alert.runModal()
            guard [.alertFirstButtonReturn,.alertSecondButtonReturn,.alertThirdButtonReturn].contains(response) else {return}
            guard generation==documentGeneration,project==snapshot,nodes.indices.contains(picker.indexOfSelectedItem) else {throw ProjectError.invalid("project changed while editing mask nodes")}
            let index=picker.indexOfSelectedItem
            if response == .alertSecondButtonReturn {try insertCompositionMaskNode(scope:scope,maskID:maskID,after:index)}
            else if response == .alertThirdButtonReturn {try removeCompositionMaskNode(scope:scope,maskID:maskID,at:index)}
            else {
                let values=try fields.map {field ->Double in guard let value=Double(field.stringValue),value.isFinite else {throw ProjectError.invalid("enter finite mask node coordinates")};return value}
                var edited=mask
                if var curve=mask.curve {curve.nodes[index]=StrokeNode(anchor:Point2(values[0],values[1]),incoming:Point2(values[2],values[3]),outgoing:Point2(values[4],values[5]));edited.curve=curve}
                else {edited.points[index]=Point2(values[0],values[1])}
                try saveCompositionMask(edited,scope:scope)
            }
        } catch {showError(error)}
    }
}
#endif
