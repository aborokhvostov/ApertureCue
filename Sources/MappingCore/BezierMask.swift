import Foundation

/// Closed cubic contour in the mask's declared coordinate space. Tangents are
/// independent absolute points. Fill is the existing even/odd polygon rule.
public struct BezierMask: Codable, Equatable, Sendable {
    public var nodes: [StrokeNode]
    public init(nodes: [StrokeNode]) {self.nodes=nodes}

    public func validate() throws {
        guard (3...128).contains(nodes.count),nodes.allSatisfy({node in
            [node.anchor,node.incoming,node.outgoing].allSatisfy(Self.finite)
        }) else {throw ProjectError.invalid("a closed Bezier mask needs 3...128 finite nodes and tangents within the working range")}
    }

    public static let ellipse=BezierMask(nodes:[
        StrokeNode(anchor:Point2(0.5,0.1),incoming:Point2(0.2790861000676826,0.1),outgoing:Point2(0.7209138999323174,0.1)),
        StrokeNode(anchor:Point2(0.9,0.5),incoming:Point2(0.9,0.2790861000676826),outgoing:Point2(0.9,0.7209138999323174)),
        StrokeNode(anchor:Point2(0.5,0.9),incoming:Point2(0.7209138999323174,0.9),outgoing:Point2(0.2790861000676826,0.9)),
        StrokeNode(anchor:Point2(0.1,0.5),incoming:Point2(0.1,0.7209138999323174),outgoing:Point2(0.1,0.2790861000676826))
    ])

    /// Straight closed edges represented with collapsed endpoint tangents.
    public static func polygon(_ points: [Point2]) throws -> BezierMask {
        let mask=BezierMask(nodes:points.map {StrokeNode(anchor:$0)})
        try mask.validate(); return mask
    }

    /// De Casteljau subdivision uses distance to the finite chord. Thus loops,
    /// collinear reversals and coincident segment endpoints cannot evade the
    /// bound. The returned polygon omits the repeated closing vertex.
    /// metricScale=(width,height), tolerance=0.5 requests a pixel-space bound.
    public func flattened(tolerance: Double = 0.00025, metricScale: Point2 = Point2(1,1),
                          maximumSegments: Int = 256, maximumDepth: Int = 16) throws -> [Point2] {
        try validate()
        guard tolerance.isFinite,tolerance>0,metricScale.x.isFinite,metricScale.y.isFinite,
              metricScale.x>0,metricScale.y>0,metricScale.x<=16384,metricScale.y<=16384,
              (3...4096).contains(maximumSegments),(0...20).contains(maximumDepth) else {
            throw ProjectError.invalid("invalid Bezier mask metric, tolerance or subdivision budget")
        }
        var result=[nodes[0].anchor],segments=0
        func append(_ point: Point2) throws {
            guard segments<maximumSegments else {throw ProjectError.invalid("Bezier mask exceeds its segment precision budget")}
            segments+=1; result.append(point)
        }
        func flatten(_ a: Point2,_ b: Point2,_ c: Point2,_ d: Point2,_ depth: Int) throws {
            let error=max(Self.distanceToSegment(b,a,d,metricScale),Self.distanceToSegment(c,a,d,metricScale))
            if error<=tolerance {try append(d); return}
            guard depth<maximumDepth else {throw ProjectError.invalid("Bezier mask exceeds its subdivision depth precision budget")}
            let ab=Point2.interpolate(a,b,t:0.5),bc=Point2.interpolate(b,c,t:0.5),cd=Point2.interpolate(c,d,t:0.5)
            let abc=Point2.interpolate(ab,bc,t:0.5),bcd=Point2.interpolate(bc,cd,t:0.5),middle=Point2.interpolate(abc,bcd,t:0.5)
            try flatten(a,ab,abc,middle,depth+1); try flatten(middle,bcd,cd,d,depth+1)
        }
        for index in nodes.indices {
            let a=nodes[index],b=nodes[(index+1)%nodes.count]
            try flatten(a.anchor,a.outgoing,b.incoming,b.anchor,0)
        }
        // Every segment contributes its endpoint, including the exact first
        // anchor on closure. Keeping interior repeated points is intentional.
        result.removeLast()
        guard result.count>=3 else {throw ProjectError.invalid("Bezier mask has fewer than three flattened vertices")}
        return result
    }

    public func contains(_ point: Point2,tolerance: Double = 0.00025) throws -> Bool {
        Geometry.contains(point,polygon:try flattened(tolerance:tolerance))
    }

    /// Split the actual cubic, preserving the path and its independent handles.
    public func insertingNode(after index: Int) throws -> BezierMask {
        try validate()
        guard nodes.indices.contains(index),nodes.count<128 else {throw ProjectError.invalid("choose an existing Bezier mask edge; at most 128 nodes are supported")}
        let next=(index+1)%nodes.count,a=nodes[index],b=nodes[next]
        let p=Point2.interpolate(a.anchor,a.outgoing,t:0.5),q=Point2.interpolate(a.outgoing,b.incoming,t:0.5),r=Point2.interpolate(b.incoming,b.anchor,t:0.5)
        let s=Point2.interpolate(p,q,t:0.5),t=Point2.interpolate(q,r,t:0.5),middle=Point2.interpolate(s,t,t:0.5)
        var result=self
        result.nodes[index].outgoing=p; result.nodes[next].incoming=r
        result.nodes.insert(StrokeNode(anchor:middle,incoming:s,outgoing:t),at:index+1)
        return result
    }

    public func removingNode(at index: Int) throws -> BezierMask {
        try validate()
        guard nodes.indices.contains(index),nodes.count>3 else {throw ProjectError.invalid("a closed Bezier mask needs at least three nodes")}
        var result=self; result.nodes.remove(at:index); return result
    }

    public func movingAnchor(at index: Int,to point: Point2) throws -> BezierMask {
        try validate()
        guard nodes.indices.contains(index),Self.finite(point) else {throw ProjectError.invalid("invalid Bezier mask anchor edit")}
        var result=self
        let old=nodes[index],delta=Point2(point.x-old.anchor.x,point.y-old.anchor.y)
        result.nodes[index]=StrokeNode(anchor:point,incoming:Point2(old.incoming.x+delta.x,old.incoming.y+delta.y),outgoing:Point2(old.outgoing.x+delta.x,old.outgoing.y+delta.y))
        try result.validate(); return result
    }

    private static func finite(_ p: Point2) -> Bool {p.x.isFinite && p.y.isFinite && abs(p.x)<=10000 && abs(p.y)<=10000}
    private static func distanceToSegment(_ p: Point2,_ a: Point2,_ b: Point2,_ scale: Point2) -> Double {
        let dx=(b.x-a.x)*scale.x,dy=(b.y-a.y)*scale.y,px=(p.x-a.x)*scale.x,py=(p.y-a.y)*scale.y
        let squared=dx*dx+dy*dy,t=squared>0 ? min(1,max(0,(px*dx+py*dy)/squared)) : 0
        return hypot(px-t*dx,py-t*dy)
    }
}
