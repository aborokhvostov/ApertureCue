#if os(macOS)
import AppKit
import MappingCore

/// A single selected parameter lane. Ruler scrubs the master show clock; key
/// and tangent drags preview here and publish one validated command on release.
@MainActor final class TimelineCanvas: NSView {
    var track:AutomationTrack? { didSet { if oldValue != track { cachedCurve=nil; cachedPath=nil; if !isDragging { previewKeys=nil }; needsDisplay=true } } }
    var selectedKeyIndex:Int? { didSet { needsDisplay=true } }
    var markers:[TimelineMarker]=[] { didSet { needsDisplay=true } }
    var duration:Double=10 { didSet { needsDisplay=true } }
    var visibleStart:Double=0 { didSet { if oldValue != visibleStart { cachedPath=nil; needsDisplay=true } } }
    var visibleEnd:Double=10 { didSet { if oldValue != visibleEnd { cachedPath=nil; needsDisplay=true } } }
    var valueRange:ClosedRange<Double>=0...1 { didSet { if oldValue != valueRange { cachedPath=nil; needsDisplay=true } } }
    var playhead:Double=0 { didSet { if oldValue != playhead { needsDisplay=true } } }
    var onSelectKey:((Int?)->Void)?
    var onEditKey:((Int,AutomationKeyframe)->Void)?
    var onInsertKey:((Double,Double)->Void)?
    var onSeek:((Double)->Void)?
    private enum Drag { case key(Int), handle(Int,Int), ruler }
    private var drag:Drag?
    private var previewKeys:[AutomationKeyframe]? { didSet { cachedCurve=nil; cachedPath=nil } }
    private var cachedCurve:AutomationCurve?
    private var cachedPath:NSBezierPath?
    var isDragging:Bool { drag != nil }
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override func setFrameSize(_ size:NSSize) { super.setFrameSize(size); cachedPath=nil; needsDisplay=true }
    var graphRect:NSRect { NSRect(x:58,y:44,width:max(1,bounds.width-78),height:max(1,bounds.height-78)) }
    private var span:Double { max(1e-9,visibleEnd-visibleStart) }
    private var valueSpan:Double { max(1e-9,valueRange.upperBound-valueRange.lowerBound) }
    private var keys:[AutomationKeyframe] { previewKeys ?? track?.keyframes ?? [] }
    private func location(time:Double,value:Double)->NSPoint {
        let r=graphRect
        return NSPoint(x:r.minX+CGFloat((time-visibleStart)/span)*r.width,y:r.maxY-CGFloat((value-valueRange.lowerBound)/valueSpan)*r.height)
    }
    private func time(at p:NSPoint)->Double { min(duration,max(0,visibleStart+Double((p.x-graphRect.minX)/graphRect.width)*span)) }
    private func value(at p:NSPoint)->Double { min(valueRange.upperBound,max(valueRange.lowerBound,valueRange.lowerBound+Double((graphRect.maxY-p.y)/graphRect.height)*valueSpan)) }
    private func caption(_ text:String,at p:NSPoint,color:NSColor = .secondaryLabelColor) {
        (text as NSString).draw(at:p,withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.regular),.foregroundColor:color])
    }
    private func line(_ a:NSPoint,_ b:NSPoint,color:NSColor,width:CGFloat=1) {
        color.setStroke(); let p=NSBezierPath(); p.move(to:a); p.line(to:b); p.lineWidth=width; p.stroke()
    }
    private func handlePoints(_ values:[AutomationKeyframe],index:Int)->[NSPoint] {
        guard values.indices.contains(index),index+1<values.count,values[index].interpolation == .bezier,abs(values[index+1].value-values[index].value)>1e-12 else { return [] }
        let a=values[index],b=values[index+1],dt=b.time-a.time,dv=b.value-a.value
        return [a.control1,a.control2].map { location(time:a.time+dt*$0.x,value:a.value+dv*$0.y) }
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let r=graphRect
        NSColor.controlBackgroundColor.setFill(); r.fill()
        for i in 0...8 {
            let t=visibleStart+span*Double(i)/8,x=location(time:t,value:0).x
            line(NSPoint(x:x,y:r.minY),NSPoint(x:x,y:r.maxY),color:NSColor.separatorColor.withAlphaComponent(0.5))
            caption(String(format:"%.3g",t),at:NSPoint(x:x-12,y:22))
        }
        for i in 0...4 {
            let v=valueRange.lowerBound+valueSpan*Double(i)/4,y=location(time:0,value:v).y
            line(NSPoint(x:r.minX,y:y),NSPoint(x:r.maxX,y:y),color:NSColor.separatorColor.withAlphaComponent(0.5))
            caption(String(format:"%.3g",v),at:NSPoint(x:4,y:y-6))
        }
        caption("seconds · drag ruler to seek",at:NSPoint(x:r.minX,y:4))
        if let track {
            caption(track.enabled ? track.name : track.name+" · disabled",at:NSPoint(x:r.minX,y:r.maxY+12),color:track.enabled ? .labelColor : .secondaryLabelColor)
            let values=keys
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect:r).addClip()
            if !values.isEmpty {
                if cachedPath == nil {
                    if cachedCurve == nil { cachedCurve=try? AutomationCurve(keyframes:values) }
                    let curve=NSBezierPath()
                    if let program=cachedCurve {
                        for i in 0...512 {
                            let t=visibleStart+span*Double(i)/512
                            guard let v=try? program.value(at:t) else { continue }
                            let p=location(time:t,value:v)
                            if i == 0 { curve.move(to:p) } else { curve.line(to:p) }
                        }
                    }
                    cachedPath=curve
                }
                (track.enabled ? NSColor.systemCyan : NSColor.secondaryLabelColor).setStroke(); cachedPath?.lineWidth=2; cachedPath?.stroke()
                if let i=selectedKeyIndex,values.indices.contains(i) {
                    let handles=handlePoints(values,index:i)
                    if handles.count==2 {
                        line(location(time:values[i].time,value:values[i].value),handles[0],color:.systemOrange)
                        line(location(time:values[i+1].time,value:values[i+1].value),handles[1],color:.systemOrange)
                        NSColor.systemOrange.setFill()
                        for h in handles { NSBezierPath(ovalIn:NSRect(x:h.x-4,y:h.y-4,width:8,height:8)).fill() }
                    }
                }
                for (i,key) in values.enumerated() where key.time>=visibleStart && key.time<=visibleEnd {
                    let p=location(time:key.time,value:key.value)
                    let diamond=NSBezierPath(); diamond.move(to:NSPoint(x:p.x,y:p.y-6)); diamond.line(to:NSPoint(x:p.x+6,y:p.y)); diamond.line(to:NSPoint(x:p.x,y:p.y+6)); diamond.line(to:NSPoint(x:p.x-6,y:p.y)); diamond.close()
                    (i == selectedKeyIndex ? NSColor.systemYellow : NSColor.systemCyan).setFill(); diamond.fill()
                    NSColor.black.withAlphaComponent(0.6).setStroke(); diamond.stroke()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            caption("Add or select a parameter track",at:NSPoint(x:r.midX-100,y:r.midY),color:.labelColor)
        }
        for marker in markers where marker.time>=visibleStart && marker.time<=visibleEnd {
            let x=location(time:marker.time,value:0).x,color:NSColor=marker.action == .pause ? .systemOrange : .systemPurple
            line(NSPoint(x:x,y:r.minY),NSPoint(x:x,y:r.maxY),color:color.withAlphaComponent(0.45))
            color.setFill(); let flag=NSBezierPath(); flag.move(to:NSPoint(x:x-5,y:34)); flag.line(to:NSPoint(x:x+5,y:34)); flag.line(to:NSPoint(x:x,y:42)); flag.close(); flag.fill()
        }
        if playhead>=visibleStart && playhead<=visibleEnd {
            let x=location(time:playhead,value:0).x
            line(NSPoint(x:x,y:18),NSPoint(x:x,y:r.maxY),color:.systemRed,width:1.5)
        }
    }
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        let p=convert(event.locationInWindow,from:nil),r=graphRect
        if p.y<r.minY && p.x>=r.minX && p.x<=r.maxX { drag = .ruler; onSeek?(time(at:p)); return }
        guard r.contains(p),track != nil else { return }
        let values=keys
        let nearest=values.indices.min { a,b in
            let x=location(time:values[a].time,value:values[a].value),y=location(time:values[b].time,value:values[b].value)
            return hypot(x.x-p.x,x.y-p.y)<hypot(y.x-p.x,y.y-p.y)
        }
        // A tangent may legitimately collapse onto its key. The diamond keeps
        // priority there, so normalized endpoint controls cannot trap key drag.
        if let index=nearest {
            let q=location(time:values[index].time,value:values[index].value)
            if hypot(q.x-p.x,q.y-p.y)<=8 {
                selectedKeyIndex=index; onSelectKey?(index); previewKeys=values; drag = .key(index); return
            }
        }
        if let index=selectedKeyIndex {
            let handles=handlePoints(values,index:index)
            if let h=handles.indices.first(where:{ hypot(handles[$0].x-p.x,handles[$0].y-p.y)<9 }) {
                previewKeys=values; drag = .handle(index,h); return
            }
        }
        if let index=nearest {
            let q=location(time:values[index].time,value:values[index].value)
            if hypot(q.x-p.x,q.y-p.y)<10 {
                selectedKeyIndex=index; onSelectKey?(index); previewKeys=values; drag = .key(index); return
            }
        }
        if event.clickCount>=2 { onInsertKey?(time(at:p),value(at:p)) }
        else { selectedKeyIndex=nil; onSelectKey?(nil) }
    }
    override func mouseDragged(with event:NSEvent) {
        guard let drag else { return }
        let p=convert(event.locationInWindow,from:nil)
        switch drag {
        case .ruler:onSeek?(time(at:p))
        case .key(let i):
            guard var values=previewKeys,values.indices.contains(i) else { return }
            values[i].time=time(at:p); values[i].value=value(at:p)
            // Preserve ordering during preview; collision is rejected again by
            // the production mutation when the mouse is released.
            if i>0 && values[i].time<=values[i-1].time { return }
            if i+1<values.count && values[i].time>=values[i+1].time { return }
            previewKeys=values; needsDisplay=true
        case .handle(let i,let h):
            guard var values=previewKeys,i+1<values.count else { return }
            let a=values[i],b=values[i+1],dt=b.time-a.time,dv=b.value-a.value
            guard dt>0,abs(dv)>1e-12 else { return }
            var control=Point2(min(1,max(0,(time(at:p)-a.time)/dt)),min(1,max(0,(value(at:p)-a.value)/dv)))
            if h==0 { control.x=min(control.x,a.control2.x); values[i].control1=control }
            else { control.x=max(control.x,a.control1.x); values[i].control2=control }
            previewKeys=values; needsDisplay=true
        }
    }
    override func mouseUp(with event:NSEvent) {
        guard let drag else { return }
        let preview=previewKeys,original=track?.keyframes
        self.drag=nil; previewKeys=nil; needsDisplay=true
        switch drag {
        case .ruler:break
        case .key(let i),.handle(let i,_):
            if let preview,let original,preview.indices.contains(i),original.indices.contains(i),preview[i] != original[i] { onEditKey?(i,preview[i]) }
        }
    }
}
#endif
