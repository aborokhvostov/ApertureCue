#if os(macOS)
import AppKit
import MappingCore

extension EditorController {
    /// Reset only the edited side. Keep the other side's independently authored
    /// mapping and retain any topology it needs; a flat output lattice is a quad.
    func resetSelectedGeometry() {
        guard let index=editableGeometryIndex else {return}
        overlay.finishDrag()
        do {
            var candidate=project,surface=candidate.surfaces[index]
            surface.meshLinked=false
            if inputMode {
                surface.input=Point2.unitQuad;surface.inputMesh=[]
                surface.inputWarp=nil;surface.inputWarpTransform = .identity
            } else {
                surface.output=Point2.insetQuad
                if let warp=surface.bezierWarp {
                    surface.bezierWarp=try BezierWarp.regular(quad:Point2.unitQuad,columns:warp.columns,rows:warp.rows)
                    surface.warpTransform=try .perspective(to:Point2.insetQuad)
                } else if !surface.mesh.isEmpty {
                    surface.mesh=try Geometry.regularMesh(quad:Point2.insetQuad,columns:surface.meshColumns,rows:surface.meshRows)
                    surface.meshWeights=[]
                }
            }
            candidate.surfaces[index]=surface
            try ProjectStore.validate(candidate)
            if inputMode {overlay.warpMode=false;overlay.meshMode=false}
            mutate("Reset geometry") {$0=candidate}
        } catch {showError(error)}
    }

    /// Export the document composition regardless of the editor's input preview.
    /// Restore every temporary renderer setting before its next visible frame.
    func compositionExportFrame(width:Int=1920,height:Int=1080) -> NSBitmapImageRep? {
        let saved=renderer.surfaces,groups=renderer.compositionGroups,masks=renderer.globalMasks,edge=renderer.edgeBlend
        defer {
            renderer.surfaces=saved;renderer.compositionGroups=groups
            renderer.globalMasks=masks;renderer.edgeBlend=edge
        }
        renderer.surfaces=effectiveSurfaces
        renderer.compositionGroups=project.groups;renderer.globalMasks=project.globalMasks
        renderer.edgeBlend=renderer.outputID.flatMap {id in project.outputs.first(where:{$0.id==id})?.edgeBlend} ?? .init()
        return renderer.render(width:width,height:height)
    }
}
#endif
