import Foundation

/// Absolute local-cage control points. Incoming/outgoing default to the anchor;
/// they remain independent so corners and asymmetric cubic handles are possible.
public struct StrokeNode: Codable, Equatable, Sendable {
    public var anchor:Point2
    public var incoming:Point2
    public var outgoing:Point2
    public init(anchor:Point2,incoming:Point2?=nil,outgoing:Point2?=nil) {
        self.anchor=anchor; self.incoming=incoming ?? anchor; self.outgoing=outgoing ?? anchor
    }
    private enum CodingKeys:String,CodingKey { case anchor,incoming,outgoing }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        self.init(anchor:try c.decode(Point2.self,forKey:.anchor),
                  incoming:try c.decodeIfPresent(Point2.self,forKey:.incoming),
                  outgoing:try c.decodeIfPresent(Point2.self,forKey:.outgoing))
    }
}

/// A textured round-cap/round-join ribbon inside the surface's unit cage.
/// Width is measured in cage-height units with a fixed 16:9 local metric.
/// Group/cage/mesh deformation then transforms the complete ribbon together.
public struct StrokePath: Codable, Equatable, Sendable {
    public var nodes:[StrokeNode]
    public var width:Double
    public var closed:Bool
    public init(nodes:[StrokeNode],width:Double=0.08,closed:Bool=false) {
        self.nodes=nodes; self.width=width; self.closed=closed
    }
    public static let line=StrokePath(nodes:[StrokeNode(anchor:Point2(0.15,0.5)),StrokeNode(anchor:Point2(0.85,0.5))])
    public static let bezier=StrokePath(nodes:[
        StrokeNode(anchor:Point2(0.15,0.65),outgoing:Point2(0.3,0.05)),
        StrokeNode(anchor:Point2(0.85,0.35),incoming:Point2(0.7,0.95))
    ])
    private enum CodingKeys:String,CodingKey { case nodes,width,closed }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        self.init(nodes:try c.decode([StrokeNode].self,forKey:.nodes),
                  width:try c.decodeIfPresent(Double.self,forKey:.width) ?? 0.08,
                  closed:try c.decodeIfPresent(Bool.self,forKey:.closed) ?? false)
    }
}

public struct StrokeHit: Equatable, Sendable {
    /// Distance to the centerline in the fixed local metric, not an alpha value.
    public var distance:Double
    /// Arc-length coordinate along the flattened centerline, clamped at caps.
    public var along:Double
    /// Signed normal coordinate across the full width; 0.5 is the centerline.
    public var across:Double
}

public enum StrokeGeometry {
    public static let aspectRatio=16.0/9.0
    public static let maximumSegments=256
    public static let maximumDepth=10
    public static let defaultTolerance=0.0005

    /// Bounds and storage validation. Non-stroke surfaces also validate dormant
    /// payloads so converting a surface cannot activate malformed geometry.
    public static func validate(_ path:StrokePath) throws {
        guard (2...32).contains(path.nodes.count), !path.closed || path.nodes.count>=3 else { throw ProjectError.invalid("stroke requires 2...32 nodes, or at least 3 when closed") }
        guard path.width.isFinite,(0.001...1).contains(path.width) else { throw ProjectError.invalid("stroke width must be finite in 0.001...1 cage-height units") }
        for node in path.nodes {
            guard [node.anchor,node.incoming,node.outgoing].allSatisfy({$0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)}) else { throw ProjectError.invalid("stroke points must lie in the finite unit cage") }
        }
    }

    /// Bounded adaptive de Casteljau flattening in the 16:9 local metric. A
    /// rejected precision budget is explicit; no silently coarse curve is used.
    /// Closed paths repeat their first point once to represent the closing edge.
    public static func samples(surface:Surface,tolerance:Double=defaultTolerance) throws -> [Point2] {
        try validate(surface.stroke)
        guard surface.shape.isStroke else { throw ProjectError.invalid("centerline samples require a line or Bezier surface") }
        guard tolerance.isFinite,tolerance>0,tolerance<=1 else { throw ProjectError.invalid("stroke flattening tolerance must be finite in (0,1]") }
        let nodes=surface.stroke.nodes, count=surface.stroke.closed ? nodes.count : nodes.count-1
        var result=[nodes[0].anchor]
        func append(_ point:Point2) throws {
            if let last=result.last,metricDistance(last,point)<=1e-12 { return }
            guard result.count<=maximumSegments else { throw ProjectError.invalid("stroke curve exceeds the 256-segment precision budget") }
            result.append(point)
        }
        func flatten(_ a:Point2,_ b:Point2,_ c:Point2,_ d:Point2,_ depth:Int) throws {
            // Distance to the finite chord, rather than only its supporting
            // line, catches collinear cubic reversals/overshoot and loops.
            let error=max(distanceToSegment(b,a,d),distanceToSegment(c,a,d))
            if error<=tolerance { try append(d); return }
            guard depth<maximumDepth else { throw ProjectError.invalid("stroke curve exceeds the subdivision depth precision budget") }
            let ab=Point2.interpolate(a,b,t:0.5),bc=Point2.interpolate(b,c,t:0.5),cd=Point2.interpolate(c,d,t:0.5)
            let abc=Point2.interpolate(ab,bc,t:0.5),bcd=Point2.interpolate(bc,cd,t:0.5),middle=Point2.interpolate(abc,bcd,t:0.5)
            try flatten(a,ab,abc,middle,depth+1); try flatten(middle,bcd,cd,d,depth+1)
        }
        for i in 0..<count {
            let a=nodes[i],b=nodes[(i+1)%nodes.count]
            if surface.shape == .bezier { try flatten(a.anchor,a.outgoing,b.incoming,b.anchor,0) }
            else { try append(b.anchor) }
        }
        guard result.count>=2,zip(result,result.dropFirst()).reduce(0,{ $0+metricDistance($1.0,$1.1) })>1e-9 else { throw ProjectError.invalid("stroke centerline has zero length") }
        return result
    }

    /// Nearest segment of the capsule union, including round caps/joins. At
    /// exact crossings the earliest centerline segment owns texture coordinates;
    /// coverage is a union and must be composited only once by the renderer.
    /// Returns a nearest point even outside the ribbon/cage for distance oracles.
    public static func hit(local:Point2,surface:Surface) -> StrokeHit? {
        guard local.x.isFinite,local.y.isFinite,let points=try? samples(surface:surface) else { return nil }
        let lengths=zip(points,points.dropFirst()).map { metricDistance($0,$1) },total=lengths.reduce(0,+)
        var best:StrokeHit?,travelled=0.0
        for i in lengths.indices {
            let length=lengths[i]
            guard length>1e-12 else { continue }
            let a=metric(points[i]),b=metric(points[i+1]),p=metric(local)
            let dx=b.x-a.x,dy=b.y-a.y
            let t=min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dy)/(length*length)))
            let q=Point2(a.x+t*dx,a.y+t*dy),distance=hypot(p.x-q.x,p.y-q.y)
            let normal=((p.y-q.y)*dx-(p.x-q.x)*dy)/length
            if best.map({ distance<$0.distance }) ?? true {
                best=StrokeHit(distance:distance,along:(travelled+t*length)/total,across:min(1,max(0,0.5+normal/surface.stroke.width)))
            }
            travelled+=length
        }
        return best
    }
    public static func contains(local:Point2,surface:Surface) -> Bool {
        guard (0...1).contains(local.x),(0...1).contains(local.y),let hit=hit(local:local,surface:surface) else { return false }
        return hit.distance<=surface.stroke.width/2+1e-10
    }
    private static func metric(_ p:Point2) -> Point2 { Point2(p.x*aspectRatio,p.y) }
    private static func metricDistance(_ a:Point2,_ b:Point2) -> Double { hypot((b.x-a.x)*aspectRatio,b.y-a.y) }
    private static func distanceToSegment(_ p:Point2,_ a:Point2,_ b:Point2) -> Double {
        let q=metric(p),x=metric(a),y=metric(b),dx=y.x-x.x,dy=y.y-x.y,lengthSquared=dx*dx+dy*dy
        guard lengthSquared>1e-24 else { return hypot(q.x-x.x,q.y-x.y) }
        let t=min(1,max(0,((q.x-x.x)*dx+(q.y-x.y)*dy)/lengthSquared))
        return hypot(q.x-x.x-t*dx,q.y-x.y-t*dy)
    }
}
