#if os(macOS)
import AppKit
import MappingCore

extension EditorController {
    func setMaskSpace(_ space: PolygonMaskSpace) {
        guard let index=editableGeometryIndex, project.surfaces[index].maskSettings.space != space else { return }
        overlay.finishDrag()
        // A deliberate coordinate reinterpretation, not a lossy inverse mapping
        // through a possibly folded mesh or a stroke's arclength parameterization.
        editSurface("Mask coordinates") { $0.maskSettings.space=space }
    }

    func editPolygonMask() {
        guard editableGeometryIndex != nil else { return }
        overlay.finishDrag()
        editSurface("Mask") { surface in
            if surface.mask.isEmpty {
                surface.mask=[Point2(0.1,0.1),Point2(0.9,0.1),Point2(0.8,0.9),Point2(0.2,0.9)]
            }
        }
        overlay.maskMode=true; overlay.meshMode=false; overlay.pathMode=false
        updateRender(); refreshInspector()
    }

    func replaceMaskVertices(_ vertices: [Point2], label: String = "Edit mask vertex") throws {
        guard let index=editableGeometryIndex else { return }
        overlay.finishDrag()
        try PolygonMaskGeometry.validateVertices(vertices)
        var candidate=project; candidate.surfaces[index].mask=vertices
        try ProjectStore.validate(candidate)
        mutate(label) { $0=candidate }
    }

    func insertMaskVertex(after index: Int) throws {
        guard let i=editableGeometryIndex else { return }
        try replaceMaskVertices(PolygonMaskGeometry.insertingVertex(in:project.surfaces[i].mask,after:index),label:"Insert mask vertex")
    }

    func removeMaskVertex(at index: Int) throws {
        guard let i=editableGeometryIndex else { return }
        try replaceMaskVertices(PolygonMaskGeometry.removingVertex(in:project.surfaces[i].mask,at:index),label:"Remove mask vertex")
    }

    func configureMaskVertices() {
        guard let i=editableGeometryIndex, !project.surfaces[i].mask.isEmpty else { return }
        overlay.finishDrag()
        let surface=project.surfaces[i], generation=documentGeneration
        let picker=ActionPopUp(items:surface.mask.indices.map { "Vertex \($0+1)" },action:{_ in})
        let x=ActionField("",action:{_ in}), y=ActionField("",action:{_ in})
        func load(_ index: Int) {
            guard surface.mask.indices.contains(index) else { return }
            x.stringValue=String(surface.mask[index].x); y.stringValue=String(surface.mask[index].y)
        }
        picker.actionBlock=load; load(0)
        let coordinates=surface.maskSettings.space == .sourceUV ? "Source UV" : "Output canvas"
        let view=stack([label("Vertex · \(surface.mask.count) / 128"),picker,label(coordinates+" · x / y"),stack([x,y],vertical:false)])
        view.frame=NSRect(x:0,y:0,width:400,height:120)
        picker.widthAnchor.constraint(equalToConstant:390).isActive=true
        for field in [x,y] { field.widthAnchor.constraint(equalToConstant:190).isActive=true }
        let alert=NSAlert(); alert.messageText="Polygon mask vertices"
        alert.informativeText="Save one vertex at a time. Insert splits the edge after the selected vertex, including the closing edge. Remove joins its neighbours. Coordinates 0…1 span the selected space; values outside it are allowed."
        alert.accessoryView=view
        for title in ["Save vertex","Insert after","Remove vertex","Cancel"] { alert.addButton(withTitle:title) }
        alert.buttons[1].isEnabled=surface.mask.count < 128
        alert.buttons[2].isEnabled=surface.mask.count > 3
        let response=alert.runModal()
        guard [.alertFirstButtonReturn,.alertSecondButtonReturn,.alertThirdButtonReturn].contains(response) else { return }
        do {
            // The modal loop can process document/selection changes and scenes.
            // Never apply captured coordinates to a replacement or changed layer.
            guard generation == documentGeneration, let current=editableGeometryIndex,
                  project.surfaces[current] == surface else {
                throw ProjectError.invalid("the surface changed while editing the mask; reopen Mask vertices")
            }
            let index=picker.indexOfSelectedItem
            guard surface.mask.indices.contains(index) else { throw ProjectError.invalid("choose a mask vertex") }
            if response == .alertFirstButtonReturn {
                guard let px=Double(x.stringValue),let py=Double(y.stringValue) else {
                    throw ProjectError.invalid("enter finite mask coordinates")
                }
                var vertices=surface.mask; vertices[index]=Point2(px,py)
                try replaceMaskVertices(vertices)
            } else if response == .alertSecondButtonReturn { try insertMaskVertex(after:index) }
            else { try removeMaskVertex(at:index) }
        } catch { showError(error) }
    }
}
#endif
