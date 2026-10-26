#if os(macOS)
import AppKit
import MappingCore

extension EditorController {
    func setStrokeEditing(_ enabled:Bool) {
        modePicker.selectItem(at:0); overlay.meshMode=false; overlay.maskMode=false
        overlay.pathMode=enabled; updateRender(); refreshInspector()
    }
    func replaceStroke(_ stroke:StrokePath,label:String="Edit stroke") throws {
        guard let i=selectedIndex,project.surfaces[i].shape.isStroke else { return }
        var candidate=project; candidate.surfaces[i].stroke=stroke
        try ProjectStore.validate(candidate)
        mutate(label) { $0=candidate }
    }
    /// Handles arrive in world space, then invert the parent and cage/mesh once.
    func editStrokeHandles(surfaceID:UUID,world:[Point2]) throws {
        guard let i=project.surfaces.firstIndex(where:{$0.id==surfaceID}),project.surfaces[i].shape.isStroke else { return }
        let surface=project.surfaces[i]
        let perNode=surface.shape == .bezier ? 3 : 1
        guard world.count==surface.stroke.nodes.count*perNode else { throw ProjectError.invalid("stroke handle count changed") }
        let inverse=try GroupEngine.worldTransform(for:surface.groupID,groups:project.groups).inverse()
        var stroke=surface.stroke
        for j in stroke.nodes.indices {
            let anchor=try SurfaceGeometry.localPoint(output:inverse.applying(world[j*perNode]),surface:surface)
            if perNode==3 {
                stroke.nodes[j]=StrokeNode(anchor:anchor,
                    incoming:try SurfaceGeometry.localPoint(output:inverse.applying(world[j*perNode+1]),surface:surface),
                    outgoing:try SurfaceGeometry.localPoint(output:inverse.applying(world[j*perNode+2]),surface:surface))
            } else {
                let delta=Point2(anchor.x-stroke.nodes[j].anchor.x,anchor.y-stroke.nodes[j].anchor.y)
                stroke.nodes[j]=StrokeNode(anchor:anchor,incoming:Point2(stroke.nodes[j].incoming.x+delta.x,stroke.nodes[j].incoming.y+delta.y),outgoing:Point2(stroke.nodes[j].outgoing.x+delta.x,stroke.nodes[j].outgoing.y+delta.y))
            }
        }
        var candidate=project; candidate.surfaces[i].stroke=stroke
        try ProjectStore.validate(candidate); project=candidate; editError=""; updateRender()
    }
    func insertStrokeNode(after selected:Int) throws {
        guard let i=selectedIndex else { return }; let surface=project.surfaces[i]
        var path=surface.stroke
        guard path.nodes.count<32 else { throw ProjectError.invalid("a path supports at most 32 nodes") }
        let aIndex=min(max(0,selected),path.closed ? path.nodes.count-1 : path.nodes.count-2)
        let bIndex=(aIndex+1)%path.nodes.count, a=path.nodes[aIndex], b=path.nodes[bIndex]
        let node:StrokeNode
        if surface.shape == .bezier {
            let p=Point2.interpolate(a.anchor,a.outgoing,t:0.5), q=Point2.interpolate(a.outgoing,b.incoming,t:0.5), r=Point2.interpolate(b.incoming,b.anchor,t:0.5)
            let s=Point2.interpolate(p,q,t:0.5), t=Point2.interpolate(q,r,t:0.5), anchor=Point2.interpolate(s,t,t:0.5)
            path.nodes[aIndex].outgoing=p; path.nodes[bIndex].incoming=r
            node=StrokeNode(anchor:anchor,incoming:s,outgoing:t)
        } else { node=StrokeNode(anchor:Point2.interpolate(a.anchor,b.anchor,t:0.5)) }
        path.nodes.insert(node,at:aIndex+1); try replaceStroke(path,label:"Insert stroke node")
    }
    func removeStrokeNode(at index:Int) throws {
        guard let i=selectedIndex else { return }; var path=project.surfaces[i].stroke
        guard path.nodes.count>(path.closed ? 3 : 2),path.nodes.indices.contains(index) else { throw ProjectError.invalid("an open path needs two nodes; a closed path needs three") }
        path.nodes.remove(at:index); try replaceStroke(path,label:"Remove stroke node")
    }
    func configureStroke() {
        guard let i=selectedIndex,project.surfaces[i].shape.isStroke else { return }
        let surface=project.surfaces[i], path=surface.stroke
        let picker=ActionPopUp(items:path.nodes.indices.map { "Node \($0+1)" },action:{_ in})
        let ax=ActionField("",action:{_ in}), ay=ActionField("",action:{_ in})
        let ix=ActionField("",action:{_ in}), iy=ActionField("",action:{_ in})
        let ox=ActionField("",action:{_ in}), oy=ActionField("",action:{_ in})
        let width=ActionField(String(path.width),action:{_ in})
        let closed=NSButton(checkboxWithTitle:"Closed path (at least three nodes)",target:nil,action:nil); closed.state=path.closed ? .on : .off
        func load(_ index:Int) {
            let node=path.nodes[index]
            for (f,v) in zip([ax,ay,ix,iy,ox,oy],[node.anchor.x,node.anchor.y,node.incoming.x,node.incoming.y,node.outgoing.x,node.outgoing.y]) { f.stringValue=String(v) }
        }
        picker.actionBlock=load; load(0)
        let view=stack([label("Node"),picker,label("Anchor x / y"),stack([ax,ay],vertical:false),label("Incoming tangent x / y"),stack([ix,iy],vertical:false),label("Outgoing tangent x / y"),stack([ox,oy],vertical:false),label("Width · fraction of local cage height (0.001…1)"),width,closed])
        view.frame=NSRect(x:0,y:0,width:430,height:330)
        for f in [ax,ay,ix,iy,ox,oy] { f.widthAnchor.constraint(equalToConstant:200).isActive=true; f.isEnabled=surface.shape == .bezier || f === ax || f === ay }
        for v in [picker,width] { v.widthAnchor.constraint(equalToConstant:414).isActive=true }
        let alert=NSAlert(); alert.messageText="Stroke path"
        alert.informativeText="Local points and tangents use 0…1 inside the cage. Width deforms with the cage; round caps/joins are clipped at its edge. Save one node at a time. Insert splits the selected segment; Remove changes its neighbours."
        alert.accessoryView=view; alert.addButton(withTitle:"Save node"); alert.addButton(withTitle:"Insert after"); alert.addButton(withTitle:"Remove node"); alert.addButton(withTitle:"Cancel")
        let response=alert.runModal(), nodeIndex=picker.indexOfSelectedItem
        do {
            if response == .alertFirstButtonReturn {
                let values=try [ax,ay,ix,iy,ox,oy,width].map { field -> Double in
                    guard let v=Double(field.stringValue),v.isFinite else { throw ProjectError.invalid("enter finite stroke coordinates and width") }; return v
                }
                var edited=path
                edited.nodes[nodeIndex]=StrokeNode(anchor:Point2(values[0],values[1]),incoming:Point2(values[2],values[3]),outgoing:Point2(values[4],values[5]))
                edited.width=values[6]; edited.closed=closed.state == .on
                try replaceStroke(edited)
            } else if response == .alertSecondButtonReturn { try insertStrokeNode(after:nodeIndex) }
            else if response == .alertThirdButtonReturn { try removeStrokeNode(at:nodeIndex) }
        } catch { showError(error) }
    }
}
#endif
