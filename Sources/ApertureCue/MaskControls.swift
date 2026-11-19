#if os(macOS)
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
}
#endif
