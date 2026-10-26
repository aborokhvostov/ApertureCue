#if os(macOS)
import AppKit
import MappingCore

extension EditorController {
    /// Build labels once per control refresh, with bounded text for deep trees.
    func groupLabels() -> [UUID:String] {
        let groups = Dictionary(project.groups.map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first })
        var labels:[UUID:String] = [:]
        for group in project.groups {
            var names:[String] = [], cursor:UUID? = group.id, visited:Set<UUID> = []
            while let current = cursor,let g = groups[current],visited.insert(current).inserted,names.count < 64 {
                names.append(String(g.name.prefix(36))); cursor = g.parentID
            }
            let path = names.reversed().joined(separator:" / ")
            labels[group.id] = (path.count > 180 ? "…"+String(path.suffix(180)) : path) + " · " + group.id.uuidString.prefix(6)
        }
        return labels
    }
    func groupPath(_ id:UUID) -> String { groupLabels()[id] ?? "Missing group" }

    /// Each operation publishes a validated value snapshot as one history command.
    func assignSelectedGroup(_ id:UUID?) throws {
        guard let surfaceID = selectedID else { return }
        let candidate = try GroupEngine.assign(surfaceID:surfaceID,to:id,in:project)
        mutate("Assign parent group") { $0 = candidate }; selectedGroupID = id
    }
    @discardableResult
    func saveGroup(id:UUID?,name:String,parentID:UUID?,opacity:Double,enabled:Bool,assignSelected:Bool) throws -> UUID {
        var candidate = project
        let groupID:UUID
        if let id,let index = candidate.groups.firstIndex(where:{$0.id == id}) {
            groupID = id
            if candidate.groups[index].parentID != parentID { candidate = try GroupEngine.reparent(groupID:id,to:parentID,in:candidate) }
            guard let updated = candidate.groups.firstIndex(where:{$0.id == id}) else { throw ProjectError.invalid("group no longer exists") }
            candidate.groups[updated].name = name; candidate.groups[updated].opacity = opacity; candidate.groups[updated].enabled = enabled
        } else {
            guard id == nil else { throw ProjectError.invalid("group no longer exists") }
            let group = SurfaceGroup(name:name,parentID:parentID,opacity:opacity,enabled:enabled)
            groupID = group.id; candidate.groups.append(group)
        }
        try ProjectStore.validate(candidate)
        if assignSelected,let surfaceID = selectedID { candidate = try GroupEngine.assign(surfaceID:surfaceID,to:groupID,in:candidate) }
        mutate("Save group") { $0 = candidate }; selectedGroupID = groupID
        return groupID
    }
    func transformGroup(_ id:UUID,by transform:Affine2D) throws {
        let candidate = try GroupEngine.applyWorldTransform(groupID:id,transform:transform,in:project)
        mutate("Transform group") { $0 = candidate }; selectedGroupID = id
    }
    func dissolveGroup(_ id:UUID) throws {
        let parent = project.groups.first(where:{$0.id == id})?.parentID
        let candidate = try GroupEngine.dissolve(groupID:id,in:project)
        mutate("Dissolve group") { $0 = candidate }; selectedGroupID = parent
    }

    func configureGroups() {
        let ids = project.groups.map(\.id), names = groupLabels()
        let titles = ids.map { names[$0] ?? "Missing group" }
        let current = selectedGroupID ?? selectedIndex.flatMap { project.surfaces[$0].groupID }
        let picker = ActionPopUp(items:["New group"] + titles,selected:current.flatMap { ids.firstIndex(of:$0).map {$0+1} } ?? 0,action:{_ in})
        let name = ActionField("",action:{_ in})
        let parent = ActionPopUp(items:["Root"] + titles,action:{_ in})
        let opacity = ActionField("1",action:{_ in})
        let enabled = NSButton(checkboxWithTitle:"Group visible",target:nil,action:nil)
        let assign = NSButton(checkboxWithTitle:"Assign selected surface (keep output geometry)",target:nil,action:nil)
        assign.state = .off; assign.isEnabled = selectedIndex != nil
        func load(_ index:Int) {
            if index > 0,let g = project.groups.first(where:{$0.id == ids[index-1]}) {
                name.stringValue = g.name; opacity.stringValue = String(g.opacity); enabled.state = g.enabled ? .on : .off
                parent.selectItem(at:g.parentID.flatMap { ids.firstIndex(of:$0).map {$0+1} } ?? 0)
            } else {
                name.stringValue = "Group \(project.groups.count+1)"; opacity.stringValue = "1"; enabled.state = .on; parent.selectItem(at:0)
            }
        }
        load(picker.indexOfSelectedItem); picker.actionBlock = load
        let alert = NSAlert(); alert.messageText = "Groups"
        alert.informativeText = "Move, scale and rotate a hierarchy together. Group opacity affects each layer; layer order stays unchanged. Scene snapshots share the current group setup. Save properties before opening Transform."
        let view = stack([label("Group"),picker,label("Name"),name,label("Parent (output geometry stays in place)"),parent,
                          label("Opacity 0…1"),opacity,enabled,assign])
        view.frame = NSRect(x:0,y:0,width:440,height:300)
        for control in [picker,name,parent,opacity] { control.widthAnchor.constraint(equalToConstant:420).isActive = true }
        alert.accessoryView = view
        alert.addButton(withTitle:"Save group"); alert.addButton(withTitle:"Transform…"); alert.addButton(withTitle:"Dissolve"); alert.addButton(withTitle:"Cancel")
        let response = alert.runModal()
        let id = picker.indexOfSelectedItem > 0 ? ids[picker.indexOfSelectedItem-1] : nil
        do {
            if response == .alertFirstButtonReturn {
                guard let value = Double(opacity.stringValue),value.isFinite else { throw ProjectError.invalid("enter a finite group opacity from 0 to 1") }
                _ = try saveGroup(id:id,name:name.stringValue,parentID:parent.indexOfSelectedItem > 0 ? ids[parent.indexOfSelectedItem-1] : nil,opacity:value,enabled:enabled.state == .on,assignSelected:assign.state == .on)
            } else if response == .alertSecondButtonReturn {
                guard let id else { throw ProjectError.invalid("save the new group before transforming it") }
                selectedGroupID = id; configureGroupTransform(id)
            } else if response == .alertThirdButtonReturn {
                guard let id else { throw ProjectError.invalid("choose an existing group to dissolve") }
                try dissolveGroup(id)
            }
        } catch { showError(error) }
    }

    func configureGroupTransform(_ id:UUID) {
        do {
            let center = try GroupEngine.bounds(for:id,in:project)?.center ?? Point2(0.5,0.5)
            let dx = ActionField("0",action:{_ in}),dy = ActionField("0",action:{_ in})
            let sx = ActionField("1",action:{_ in}),sy = ActionField("1",action:{_ in})
            let degrees = ActionField("0",action:{_ in})
            let px = ActionField(String(format:"%.8f",center.x),action:{_ in}),py = ActionField(String(format:"%.8f",center.y),action:{_ in})
            let view = stack([label("Translate x / y (normalized canvas)"),stack([dx,dy],vertical:false),
                              label("Scale x / y (nonzero; negative mirrors)"),stack([sx,sy],vertical:false),
                              label("Clockwise degrees (16:9 editor canvas)"),degrees,
                              label("Pivot x / y (world canvas; default hierarchy center)"),stack([px,py],vertical:false)])
            view.frame = NSRect(x:0,y:0,width:430,height:240)
            for field in [dx,dy,sx,sy,px,py] { field.widthAnchor.constraint(equalToConstant:200).isActive = true }
            degrees.widthAnchor.constraint(equalToConstant:414).isActive = true
            let alert = NSAlert(); alert.messageText = "Transform \(groupPath(id))"
            alert.informativeText = "Apply scale, then rotation around the pivot, then translation. Child geometry and source crops stay editable. Undo restores the whole operation."
            alert.accessoryView = view; alert.addButton(withTitle:"Apply transform"); alert.addButton(withTitle:"Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let fields = [dx,dy,sx,sy,degrees,px,py]
            let numbers = try fields.map { field -> Double in
                guard let n = Double(field.stringValue),n.isFinite else { throw ProjectError.invalid("enter finite transform values") }; return n
            }
            let pivot = Point2(numbers[5],numbers[6])
            let transform = Affine2D.translation(x:numbers[0],y:numbers[1])
                .concatenating(Affine2D.rotation(degrees:numbers[4],around:pivot,aspectRatio:16.0/9.0))
                .concatenating(Affine2D.scale(x:numbers[2],y:numbers[3],around:pivot))
            try transformGroup(id,by:transform)
        } catch { showError(error) }
    }
}
#endif
