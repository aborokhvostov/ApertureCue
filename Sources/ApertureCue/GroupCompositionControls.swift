#if os(macOS)
import AppKit
import MappingCore

@MainActor private final class GroupEffectsFields {
    let mode=ActionPopUp(items:["No key","Chroma key","Luma key"],action:{_ in})
    let values=(0..<8).map {_ in ActionField("",action:{_ in})}
    let invert=NSButton(checkboxWithTitle:"Invert RGB",target:nil,action:nil)
    init(_ settings:EffectsSettings) {load(settings)}
    func load(_ s:EffectsSettings) {
        mode.selectItem(at:s.keyMode == .none ? 0 : (s.keyMode == .chroma ? 1 : 2))
        let components=s.keyColor+[s.threshold,s.softness,s.spill,s.saturation,Double(s.posterizeLevels)]
        for (field,value) in zip(values,components) {field.stringValue=String(value)}
        invert.state=s.inverted ? .on : .off
    }
    func read() throws -> EffectsSettings {
        let numbers=try values.map {field ->Double in guard let value=Double(field.stringValue),value.isFinite else {throw ProjectError.invalid("enter finite group effect values")};return value}
        guard numbers[7].rounded()==numbers[7],(0...256).contains(numbers[7]) else {throw ProjectError.invalid("posterize levels must be 0 or an integer 2…256")}
        let settings=EffectsSettings(keyMode:mode.indexOfSelectedItem==0 ? .none : (mode.indexOfSelectedItem==1 ? .chroma : .luma),keyColor:Array(numbers[0...2]),
                                     threshold:numbers[3],softness:numbers[4],spill:numbers[5],saturation:numbers[6],inverted:invert.state == .on,posterizeLevels:Int(numbers[7]))
        try Effects.validate(settings);return settings
    }
    func view()->NSView {
        for field in values {field.widthAnchor.constraint(equalToConstant:125).isActive=true}
        return stack([mode,label("Key color RGB (0…1)"),stack(Array(values[0...2]),vertical:false),
                      label("Threshold / softness / spill (0…1)"),stack(Array(values[3...5]),vertical:false),
                      label("Saturation (0…2) / posterize levels (0 or 2…256)"),stack(Array(values[6...7]),vertical:false),invert])
    }
}

extension EditorController {
    func saveGroupComposition(groupID:UUID,isolated:Bool,blendMode:String,effects:EffectsSettings) throws {
        try Effects.validate(effects)
        guard let index=project.groups.firstIndex(where:{$0.id==groupID}) else {throw ProjectError.invalid("group no longer exists")}
        var candidate=project;candidate.groups[index].isolated=isolated;candidate.groups[index].blendMode=blendMode;candidate.groups[index].effects=effects
        try ProjectStore.validate(candidate);overlay.finishDrag();mutate("Group composition") {$0=candidate};selectedGroupID=groupID
    }

    func configureGroupComposition() {
        let groups=project.groups,snapshot=project,generation=documentGeneration
        guard !groups.isEmpty else {showError(ProjectError.invalid("create a group before editing group composition"));return}
        let id=selectedGroupID ?? selectedIndex.flatMap {project.surfaces[$0].groupID}
        let current=id.flatMap {value in groups.firstIndex(where:{$0.id==value})} ?? 0
        let picker=ActionPopUp(items:groups.enumerated().map {"\($0.offset+1). \($0.element.name)"},selected:current,action:{_ in})
        let isolated=NSButton(checkboxWithTitle:"Isolated group composition",target:nil,action:nil)
        let modes=["normal","add","multiply","screen"],blend=ActionPopUp(items:["normal","add","multiply","screen"],action:{_ in})
        let effects=GroupEffectsFields(groups[current].effects)
        func load(_ index:Int) {
            guard groups.indices.contains(index) else {return};let group=groups[index]
            isolated.state=group.isolated ? .on : .off;blend.selectItem(at:modes.firstIndex(of:group.blendMode) ?? 0);effects.load(group.effects)
        }
        picker.actionBlock=load;load(current)
        let view=stack([label("Group"),picker,isolated,label("Group blend mode"),blend,effects.view()])
        view.frame=NSRect(x:0,y:0,width:430,height:390)
        for control in [picker,blend] {control.widthAnchor.constraint(equalToConstant:420).isActive=true}
        let alert=NSAlert();alert.messageText="Group composition and effects"
        alert.informativeText="Masks, FX and non-normal blend also enable group composition. Descendant layers must be contiguous in layer order. Save + masks saves these settings first, then opens group mask controls."
        alert.accessoryView=view;alert.addButton(withTitle:"Save group");alert.addButton(withTitle:"Save + masks…");alert.addButton(withTitle:"Cancel")
        let response=alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else {return}
        do {
            let index=picker.indexOfSelectedItem
            guard generation==documentGeneration,project==snapshot,groups.indices.contains(index),modes.indices.contains(blend.indexOfSelectedItem) else {throw ProjectError.invalid("project changed while configuring group composition")}
            try saveGroupComposition(groupID:groups[index].id,isolated:isolated.state == .on,blendMode:modes[blend.indexOfSelectedItem],effects:effects.read())
            if response == .alertSecondButtonReturn {configureScopedMasks(initialScope:.group(groups[index].id))}
        } catch {showError(error)}
    }

    func applyGroupPerspective(groupID:UUID,to destination:[Point2]) throws {
        guard let bounds=try GroupEngine.bounds(for:groupID,in:project) else {throw ProjectError.invalid("group needs a current surface before perspective editing")}
        let source=[bounds.min,Point2(bounds.max.x,bounds.min.y),bounds.max,Point2(bounds.min.x,bounds.max.y)]
        let delta=try Affine2D.perspective(from:source,to:destination)
        let candidate=try GroupEngine.applyWorldTransform(groupID:groupID,transform:delta,in:project)
        overlay.finishDrag();mutate("Group perspective") {$0=candidate};selectedGroupID=groupID
    }

    func configureGroupPerspective() {
        let groups=project.groups,snapshot=project,generation=documentGeneration
        guard !groups.isEmpty else {showError(ProjectError.invalid("create a group before editing group perspective"));return}
        let id=selectedGroupID ?? selectedIndex.flatMap {project.surfaces[$0].groupID}
        let selected=id.flatMap {value in groups.firstIndex(where:{$0.id==value})} ?? 0
        let picker=ActionPopUp(items:groups.enumerated().map {"\($0.offset+1). \($0.element.name)"},selected:selected,action:{_ in})
        let fields=(0..<8).map {_ in ActionField("",action:{_ in})}
        func load(_ index:Int) {
            guard groups.indices.contains(index) else {return}
            let bounds=try? GroupEngine.bounds(for:groups[index].id,in:snapshot)
            let low=bounds?.min ?? Point2(0,0),high=bounds?.max ?? Point2(1,1)
            for (field,value) in zip(fields,[low.x,low.y,high.x,low.y,high.x,high.y,low.x,high.y]) {field.stringValue=String(value)}
        }
        picker.actionBlock=load;load(selected)
        let view=stack([picker,label("Destination corners · normalized world x / y"),label("Top left"),stack(Array(fields[0...1]),vertical:false),
                        label("Top right"),stack(Array(fields[2...3]),vertical:false),label("Bottom right"),stack(Array(fields[4...5]),vertical:false),
                        label("Bottom left"),stack(Array(fields[6...7]),vertical:false)])
        view.frame=NSRect(x:0,y:0,width:420,height:300)
        for field in fields {field.widthAnchor.constraint(equalToConstant:200).isActive=true}
        let alert=NSAlert();alert.messageText="Group perspective"
        alert.informativeText="Map the current world bounding rectangle to a convex four-corner destination. Shared group perspective changes the group and its descendants, including geometry-locked layers. Singular transforms and horizons reject."
        alert.accessoryView=view;alert.addButton(withTitle:"Apply perspective");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {return}
        do {
            let index=picker.indexOfSelectedItem
            guard generation==documentGeneration,project==snapshot,groups.indices.contains(index) else {throw ProjectError.invalid("project changed while configuring group perspective")}
            let values=try fields.map {field ->Double in guard let value=Double(field.stringValue),value.isFinite else {throw ProjectError.invalid("enter finite perspective corners")};return value}
            try applyGroupPerspective(groupID:groups[index].id,to:stride(from:0,to:8,by:2).map {Point2(values[$0],values[$0+1])})
        } catch {showError(error)}
    }
}
#endif
