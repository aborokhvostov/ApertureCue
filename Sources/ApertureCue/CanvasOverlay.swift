#if os(macOS)
import AppKit
import MappingCore

final class CanvasOverlay: NSView {
    var surfaces: [Surface] = [] { didSet { needsDisplay = true } }
    var selectedID: UUID? { didSet { needsDisplay = true } }
    var inputMode = false { didSet { needsDisplay = true } }
    var meshMode = false
    var maskMode = false
    var onSelect: ((UUID) -> Void)?
    var onBegin: (() -> Void)?
    var onChange: ((UUID, [Point2], Bool, Bool) -> Void)?
    var onEnd: (() -> Void)?
    private var dragging: Int?
    private var original: [Point2] = []
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
        if inputMode { return s.input }
        if meshMode && !s.mesh.isEmpty { return s.mesh }
        return s.output
    }
    override func draw(_ dirtyRect: NSRect) {
        for surface in surfaces where !inputMode || surface.id == selectedID {
            let selected = surface.id == selectedID
            let pts = inputMode ? surface.input : surface.output
            guard pts.count == 4 else { continue }
            let path = NSBezierPath(); path.move(to: point(pts[0]))
            pts.dropFirst().forEach { path.line(to: point($0)) }; path.close()
            let shaped = !inputMode && surface.shape != .quad
            (selected ? NSColor.systemCyan.withAlphaComponent(shaped ? 0.35 : 1) : NSColor.white.withAlphaComponent(0.35)).setStroke()
            path.lineWidth = selected ? 2 : 1; path.stroke()
            if !inputMode && (shaped || !surface.mesh.isEmpty) {
                let points = (try? SurfaceGeometry.outputOutline(surface:surface)) ?? []
                let contour = NSBezierPath()
                if let first = points.first { contour.move(to:point(first)) }
                points.dropFirst().forEach { contour.line(to:point($0)) }
                contour.close()
                (selected ? NSColor.systemCyan : NSColor.white.withAlphaComponent(0.6)).setStroke()
                contour.lineWidth = selected ? 2 : 1; contour.stroke()
            }
            if selected {
                let handles = vertices(surface)
                if maskMode && handles.count > 1 {
                    let m = NSBezierPath(); m.move(to: point(handles[0]))
                    handles.dropFirst().forEach { m.line(to: point($0)) }; m.close()
                    NSColor.systemOrange.setStroke(); m.stroke()
                }
                for (index, vertex) in handles.enumerated() {
                    let p = point(vertex)
                    let r = NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                    NSColor.black.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: -1, dy: -1)).fill()
                    NSColor.systemCyan.setFill(); NSBezierPath(ovalIn: r).fill()
                    if handles.count <= 4 {
                        ("\(index + 1)" as NSString).draw(at: NSPoint(x: p.x + 8, y: p.y + 3), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)])
                    }
                }
                let title = surface.name + (inputMode ? " · INPUT" : " · OUTPUT")
                (title as NSString).draw(at: NSPoint(x: 12, y: 12), withAttributes: [.foregroundColor: NSColor.systemCyan, .font: NSFont.boldSystemFont(ofSize: 13)])
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let surface = surfaces.first(where: { $0.id == selectedID }) {
            let handles = vertices(surface)
            if let index = handles.indices.min(by: { hypot(point(handles[$0]).x-p.x, point(handles[$0]).y-p.y) < hypot(point(handles[$1]).x-p.x, point(handles[$1]).y-p.y) }), hypot(point(handles[index]).x-p.x, point(handles[index]).y-p.y) < 18 {
                dragging = index; original = handles; onBegin?(); return
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
        surfaces.reversed().first { $0.enabled && $0.opacity > 0 && SurfaceGeometry.contains(output:output,surface:$0) }?.id
    }
    override func mouseDragged(with event: NSEvent) {
        guard let i = dragging, let id = selectedID else { return }
        var pts = original; pts[i] = normalized(event)
        if !meshMode && !maskMode && (try? Geometry.validateQuad(pts)) == nil { return }
        onChange?(id, pts, inputMode, meshMode)
    }
    override func mouseUp(with event: NSEvent) {
        if dragging != nil { dragging = nil; onEnd?() }
    }
}
#endif
