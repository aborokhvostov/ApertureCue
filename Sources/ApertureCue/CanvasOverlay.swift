#if os(macOS)
import AppKit
import QuartzCore
import MappingCore

final class CanvasOverlay: NSView {
    var surfaces: [Surface] = [] { didSet { needsDisplay = true } }
    var selectedID: UUID? { didSet { needsDisplay = true } }
    var geometryLockedSurfaceIDs: Set<UUID> = [] {
        didSet { if oldValue != geometryLockedSurfaceIDs { needsDisplay = true } }
    }
    var inputMode = false { didSet { needsDisplay = true } }
    var pathMode = false { didSet { needsDisplay = true } }
    var meshMode = false
    var maskMode = false
    var warpMode=false
    var drawMode=false {didSet {if !drawMode {freehand=[]};needsDisplay=true}}
    var onWarpDrag:((UUID,Int,Point2,Bool)->Void)?
    var onFreehand:(([Point2])->Void)?
    var onNudge:((Double,Double)->Void)?
    private var freehand:[Point2]=[]
    private var warpCache:[UUID:(Surface,Int,Int,WarpTessellation)]=[:]
    private func tessellation(_ s:Surface) -> WarpTessellation? {
        guard s.bezierWarp != nil else {return nil}
        let scale=window?.backingScaleFactor ?? 2
        let w=max(1,min(16384,Int(bounds.width*scale))),h=max(1,min(16384,Int(bounds.height*scale)))
        if let (old,cw,ch,t)=warpCache[s.id],cw==w,ch==h,old.bezierWarp==s.bezierWarp,old.warpTransform==s.warpTransform,old.inputWarp==s.inputWarp,old.inputWarpTransform==s.inputWarpTransform,old.input==s.input {return t}
        guard let t=try? SurfaceWarpGeometry.tessellation(surface:s,width:w,height:h) else {return nil}
        warpCache[s.id]=(s,w,h,t);return t
    }
    var onSelect: ((UUID) -> Void)?
    var onBegin: (() -> Void)?
    var onChange: ((UUID, [Point2], Bool, Bool) -> Void)?
    var onTriangleDrag: ((UUID, Int, Point2) -> Void)?
    var onEnd: (() -> Void)?
    private var drag: (id: UUID, index: Int, points: [Point2], triangle: Bool,warp:Bool)?
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private func point(_ p: Point2) -> NSPoint { NSPoint(x: p.x * bounds.width, y: p.y * bounds.height) }
    private func normalized(_ event: NSEvent) -> Point2 {
        let p = convert(event.locationInWindow, from: nil)
        var x = max(-0.5, min(1.5, p.x / max(1, bounds.width)))
        var y = max(-0.5, min(1.5, p.y / max(1, bounds.height)))
        if event.modifierFlags.contains(.shift) { x = (x * 20).rounded() / 20; y = (y * 20).rounded() / 20 }
        return Point2(x, y)
    }
    private func vertices(_ s: Surface) -> [Point2] {
        if maskMode { return s.mask }
        if warpMode {
            let warp=inputMode ? s.inputWarp : s.bezierWarp
            let transform=inputMode ? s.inputWarpTransform : s.warpTransform
            return (try? warp?.controls.map {try transform.applying($0)}) ?? []
        }
        if inputMode { return meshMode && !s.inputMesh.isEmpty ? s.inputMesh : s.input }
        if pathMode && s.shape == .triangle {
            return (try? SurfaceGeometry.outputPoints(local:s.triangleVertices,surface:s,tessellation:tessellation(s))) ?? []
        }
        if pathMode && s.shape.isStroke { return pathControlPoints(s) }
        if meshMode && !s.mesh.isEmpty { return s.mesh }
        return s.output
    }
    func pathControlPoints(_ surface:Surface) -> [Point2] {
        let points=surface.stroke.nodes.flatMap { node in surface.shape == .bezier ? [node.anchor,node.incoming,node.outgoing] : [node.anchor] }
        return (try? SurfaceGeometry.outputPoints(local:points,surface:surface,tessellation:tessellation(surface))) ?? []
    }
    override var wantsUpdateLayer: Bool { true }
    override func setFrameSize(_ newSize:NSSize) { super.setFrameSize(newSize); needsDisplay = true }
    override func updateLayer() {
        guard let backing = layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        backing.contents = nil; backing.backgroundColor = NSColor.clear.cgColor
        backing.sublayers?.forEach { $0.removeFromSuperlayer() }
        let muted = CGMutablePath(), contours = CGMutablePath(), selectedPath = CGMutablePath(), centerlines = CGMutablePath(), guides = CGMutablePath(), mask = CGMutablePath(), handles = CGMutablePath()
        // The flipped backing view supplies the same y-down convention as the
        // document and mouse events. Do not apply a second vertical flip.
        func cg(_ p:Point2) -> CGPoint { CGPoint(x:p.x*bounds.width,y:p.y*bounds.height) }
        func polygon(_ points:[Point2],into path:CGMutablePath) {
            guard let first = points.first else { return }
            path.move(to:cg(first)); points.dropFirst().forEach { path.addLine(to:cg($0)) }; path.closeSubpath()
        }
        let scale = window?.backingScaleFactor ?? 2
        func stroke(_ path:CGPath,color:NSColor,width:CGFloat,fill:NSColor? = nil) {
            let shape = CAShapeLayer(); shape.frame = bounds; shape.contentsScale = scale
            shape.path = path; shape.strokeColor = color.cgColor; shape.fillColor = fill?.cgColor
            shape.lineWidth = width; shape.lineJoin = .round; backing.addSublayer(shape)
        }
        func text(_ string:String,at p:NSPoint,fontSize:CGFloat,bold:Bool) {
            let title = CATextLayer(); title.contentsScale = scale; title.string = string
            title.font = (bold ? NSFont.boldSystemFont(ofSize:fontSize) : NSFont.monospacedSystemFont(ofSize:fontSize,weight:.bold)).fontName as CFString
            title.fontSize = fontSize; title.foregroundColor = NSColor.systemCyan.cgColor
            let y = backing.isGeometryFlipped ? p.y : bounds.height-p.y-fontSize-5
            title.frame = CGRect(x:p.x,y:y,width:max(20,bounds.width-p.x),height:fontSize+5)
            backing.addSublayer(title)
        }
        var numberLabels:[(String,NSPoint)] = []
        var selectedTitle:String?
        for surface in surfaces where !inputMode || surface.id == selectedID {
            let selected = surface.id == selectedID
            let points = inputMode ? surface.input : surface.output
            guard points.count == 4 else { continue }
            let shaped = !inputMode && surface.shape != .quad
            polygon(points,into:selected && !shaped ? selectedPath : muted)
            if !inputMode && (shaped || !surface.mesh.isEmpty || surface.bezierWarp != nil),let outline = try? SurfaceGeometry.outputOutline(surface:surface,tessellation:tessellation(surface)) {
                polygon(outline,into:selected ? selectedPath : contours)
            }
            if !inputMode && surface.shape.isStroke, let projected=try? SurfaceGeometry.outputCenterline(surface:surface,tessellation:tessellation(surface)),let first=projected.first {
                centerlines.move(to:cg(first)); projected.dropFirst().forEach {centerlines.addLine(to:cg($0))}
            }
            if selected {
                let outputMode = pathMode ? (surface.shape == .triangle ? "VERTICES" : "PATH") : "OUTPUT"
                selectedTitle = surface.name + " · " + (inputMode ? "INPUT" : outputMode)
                if geometryLockedSurfaceIDs.contains(surface.id) {
                    selectedTitle = surface.name + (inputMode ? " · INPUT LOCKED" : " · OUTPUT LOCKED")
                    continue
                }
                let vertices = vertices(surface)
                if pathMode && !inputMode && surface.shape == .bezier {
                    for node in stride(from:0,to:vertices.count,by:3) {
                        guides.move(to:cg(vertices[node+1])); guides.addLine(to:cg(vertices[node])); guides.addLine(to:cg(vertices[node+2]))
                    }
                }
                if maskMode && vertices.count > 1 { polygon(vertices,into:mask) }
                for (index,p) in vertices.enumerated() {
                    let q = cg(p); handles.addEllipse(in:CGRect(x:q.x-5,y:q.y-5,width:10,height:10))
                    if vertices.count <= 4 || pathMode || maskMode {
                        let value=pathMode && surface.shape == .bezier ? "\(index/3+1)" + (["","i","o"][index%3]) : String(index+1)
                        numberLabels.append((value,NSPoint(x:p.x*bounds.width+8,y:p.y*bounds.height+3)))
                    }
                }
            }
        }
        if let first=freehand.first {guides.move(to:cg(first));freehand.dropFirst().forEach {guides.addLine(to:cg($0))}}
        stroke(muted,color:NSColor.white.withAlphaComponent(0.35),width:1)
        stroke(contours,color:NSColor.white.withAlphaComponent(0.6),width:1)
        stroke(selectedPath,color:.systemCyan,width:2)
        stroke(centerlines,color:NSColor.systemCyan.withAlphaComponent(0.6),width:1)
        stroke(guides,color:.systemOrange,width:1)
        stroke(mask,color:.systemOrange,width:1)
        stroke(handles,color:.black,width:2,fill:.systemCyan)
        for (value,position) in numberLabels { text(value,at:position,fontSize:11,bold:false) }
        if let selectedTitle { text(selectedTitle,at:NSPoint(x:12,y:12),fontSize:13,bold:true) }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if drawMode {freehand=[normalized(event)];needsDisplay=true;return}
        if let surface = surfaces.first(where: { $0.id == selectedID }), !geometryLockedSurfaceIDs.contains(surface.id) {
            let handles = vertices(surface)
            if let index = handles.indices.min(by: { hypot(point(handles[$0]).x-p.x, point(handles[$0]).y-p.y) < hypot(point(handles[$1]).x-p.x, point(handles[$1]).y-p.y) }), hypot(point(handles[index]).x-p.x, point(handles[index]).y-p.y) < 18 {
                let triangle = pathMode && !inputMode && !maskMode && surface.shape == .triangle
                drag = (surface.id, index, handles, triangle,warpMode); onBegin?(); return
            }
        }
        if !inputMode {
            let output = Point2(p.x/max(1,bounds.width),p.y/max(1,bounds.height))
            if let id = hitSurface(at:output) { onSelect?(id) }
        }
    }
    /// Geometry picking uses the same local shape/mesh as the compositor.
    /// Source masks are edited independently and do not change selection bounds.
    func hitSurface(at output:Point2) -> UUID? {
        surfaces.reversed().first { $0.enabled && $0.opacity > 0 && SurfaceGeometry.contains(output:output,surface:$0,tessellation:tessellation($0)) }?.id
    }
    override func mouseDragged(with event: NSEvent) {
        if drawMode {
            let p=normalized(event)
            if freehand.count<513,freehand.last != p {freehand.append(p)}
            needsDisplay=true;return
        }
        guard let (id, i, original, triangle,warp) = drag, id == selectedID, !geometryLockedSurfaceIDs.contains(id) else { return }
        if warp {onWarpDrag?(id,i,normalized(event),inputMode);return}
        if triangle { onTriangleDrag?(id,i,normalized(event)); return }
        var pts = original; pts[i] = normalized(event)
        if pathMode,let surface=surfaces.first(where:{$0.id == id}),surface.shape == .bezier,i%3 == 0 {
            let delta=Point2(pts[i].x-original[i].x,pts[i].y-original[i].y)
            for handle in [i+1,i+2] { pts[handle]=Point2(original[handle].x+delta.x,original[handle].y+delta.y) }
        }
        if !pathMode && !meshMode && !maskMode && (try? Geometry.validateQuad(pts)) == nil { return }
        onChange?(id, pts, inputMode, meshMode)
    }
    override func mouseUp(with event: NSEvent) {
        if drawMode {
            let points=freehand;drawMode=false
            if points.count>=2 {onFreehand?(points)}
            return
        }
        finishDrag()
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode==53 {drawMode=false;finishDrag();return}
        let amount=event.modifierFlags.contains(.shift) ? 0.01 : 0.001
        switch event.keyCode {
        case 123:onNudge?(-amount,0)
        case 124:onNudge?(amount,0)
        case 125:onNudge?(0,amount)
        case 126:onNudge?(0,-amount)
        default:super.keyDown(with:event)
        }
    }
    func finishDrag() {
        guard drag != nil else { return }
        drag = nil; onEnd?()
    }
}
#endif
