import Foundation

/// A primitive in the normalized local cage. Source-UV polygon masks are separate.
public enum SurfaceShape: String, Codable, CaseIterable, Sendable {
    case quad, triangle, ellipse, line, bezier

    public var isStroke:Bool { self == .line || self == .bezier }

    /// Signed distance to the closest primitive edge, positive inside. Triangle
    /// distances use its three supporting half-planes, matching the GPU shader.
    public func signedDistance(at point: Point2) -> Double {
        guard point.x.isFinite, point.y.isFinite else { return -.infinity }
        switch self {
        case .quad: return min(point.x, 1-point.x, point.y, 1-point.y)
        case .triangle: return min((point.y-2*point.x+1)/sqrt(5), (point.y+2*point.x-1)/sqrt(5), 1-point.y)
        case .ellipse: return 0.5-hypot(point.x-0.5, point.y-0.5)
        case .line,.bezier: return -.infinity // Requires the surface's centerline/width.
        }
    }

    public func contains(_ point: Point2) -> Bool { signedDistance(at:point) >= -1e-10 }

    /// The closed contour does not repeat its first vertex. Ellipse sampling is
    /// bounded regardless of caller input; straight primitives need only corners.
    public func outline(segments: Int = 64) -> [Point2] {
        switch self {
        case .quad,.line,.bezier: return Point2.unitQuad
        case .triangle: return TriangleGeometry.canonical
        case .ellipse:
            let count = max(8,min(256,segments))
            return (0..<count).map { index in
                let angle = -Double.pi/2 + Double(index)*2*Double.pi/Double(count)
                return Point2(0.5+0.5*cos(angle),0.5+0.5*sin(angle))
            }
        }
    }
}

/// Three vertices in the unit cage. Edge planes use normalized local distance,
/// positive on the inside for either winding.
public struct TriangleGeometry: Sendable {
    public static let canonical = [Point2(0.5,0), Point2(1,1), Point2(0,1)]
    public let planes: [SIMD3<Double>]

    public init(vertices: [Point2]) throws {
        guard vertices.count == 3,
              vertices.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            throw ProjectError.invalid("triangle requires three vertices inside its unit cage")
        }
        let a = vertices[0], b = vertices[1], c = vertices[2]
        let area = (b.x-a.x)*(c.y-a.y) - (b.y-a.y)*(c.x-a.x)
        guard abs(area) >= 1e-6 else { throw ProjectError.invalid("triangle vertices must enclose an area") }
        let direction = area > 0 ? 1.0 : -1.0
        planes = vertices.indices.map { index in
            let start = vertices[index], end = vertices[(index+1)%3]
            let dx = end.x-start.x, dy = end.y-start.y
            let scale = direction/hypot(dx,dy)
            let x = -dy*scale, y = dx*scale
            return SIMD3(x,y,-x*start.x-y*start.y)
        }
    }

    public func contains(_ point: Point2) -> Bool {
        planes.allSatisfy { $0.x*point.x+$0.y*point.y+$0.z >= -1e-10 }
    }

}

/// Matches projective cages, perspective-correct regular mesh triangles and
/// a caller-supplied (or default 1280×720) conforming Bezier tessellation.
public enum SurfaceGeometry {
    public static func outputPoint(local: Point2,surface: Surface,tessellation: WarpTessellation? = nil) throws -> Point2 {
        try SurfaceWarpGeometry.validateLocal(local)
        return try PreparedSurfaceGeometry(surface:surface,tessellation:tessellation).point(local)
    }

    public static func outputPoints(local: [Point2],surface: Surface,tessellation: WarpTessellation? = nil) throws -> [Point2] {
        for point in local {try SurfaceWarpGeometry.validateLocal(point)}
        let mapping=try PreparedSurfaceGeometry(surface:surface,tessellation:tessellation)
        return try local.map {try mapping.point($0)}
    }

    /// Source-domain pre-crop coordinates. Stroke callers pass arc-length/across
    /// UV here; sourcePoint deliberately does not infer that parameterization.
    public static func sourcePoint(local: Point2,surface: Surface) throws -> Point2 {
        try SurfaceSourceMapping(surface:surface).point(at:local)
    }

    /// Folded meshes are not one-to-one. The first nondegenerate covering
    /// triangle owns an ambiguous edit; contains still checks every preimage.
    public static func localPoint(output: Point2,surface: Surface,tessellation: WarpTessellation? = nil) throws -> Point2 {
        guard output.x.isFinite,output.y.isFinite else {throw GeometryError.nonFinite}
        guard let point=try PreparedSurfaceGeometry(surface:surface,tessellation:tessellation).localPoints(output).first else {
            throw ProjectError.invalid("output point lies outside the surface cage or warp")
        }
        return Point2(min(1,max(0,point.x)),min(1,max(0,point.y)))
    }

    /// The closed primitive contour omits its repeated closing vertex. Straight
    /// primitive edges split at every regular/tessellated grid diagonal. The
    /// legacy ellipse sample count is retained for non-Bezier surfaces.
    public static func outputOutline(surface: Surface,segments: Int = 64,tessellation: WarpTessellation? = nil) throws -> [Point2] {
        let local: [Point2]
        if surface.shape == .triangle {
            _ = try TriangleGeometry(vertices:surface.triangleVertices); local=surface.triangleVertices
        } else {local=surface.shape.outline(segments:segments)}
        let mapping=try PreparedSurfaceGeometry(surface:surface,tessellation:tessellation)
        if !mapping.hasGrid || (surface.shape == .ellipse && surface.bezierWarp == nil) {return try local.map {try mapping.point($0)}}
        return try projectedPolyline(local,mapping:mapping,closed:true)
    }

    public static func outputCenterline(surface: Surface,tessellation: WarpTessellation? = nil) throws -> [Point2] {
        let local=try StrokeGeometry.samples(surface:surface)
        let mapping=try PreparedSurfaceGeometry(surface:surface,tessellation:tessellation)
        if !mapping.hasGrid {return try local.map {try mapping.point($0)}}
        return try projectedPolyline(local,mapping:mapping,closed:false)
    }

    private static func projectedPolyline(_ local: [Point2],mapping: PreparedSurfaceGeometry,closed: Bool) throws -> [Point2] {
        guard let first=local.first else {return []}
        let edgeCount=closed ? local.count : max(0,local.count-1)
        var result: [Point2]=[]
        for index in 0..<edgeCount {
            let a=local[index],b=local[(index+1)%local.count]
            let parameters=SurfaceWarpGeometry.edgeParameters(from:a,to:b,columns:mapping.columns,rows:mapping.rows)
            guard result.count+parameters.count<=131072 else {throw ProjectError.invalid("projected surface contour exceeds its point budget")}
            for t in parameters {result.append(try mapping.point(Point2.interpolate(a,b,t:t)))}
        }
        if !closed {result.append(try mapping.point(local.last ?? first))}
        return result
    }

    /// Geometric primitive selection is independent of masks/feather. All
    /// covered preimages are tested on folded meshes, not only the first inverse.
    public static func contains(output: Point2,surface: Surface,tessellation: WarpTessellation? = nil) -> Bool {
        guard output.x.isFinite,output.y.isFinite,
              let mapping=try? PreparedSurfaceGeometry(surface:surface,tessellation:tessellation),
              let points=try? mapping.localPoints(output) else {return false}
        let triangle=surface.shape == .triangle ? try? TriangleGeometry(vertices:surface.triangleVertices) : nil
        let stroke=surface.shape.isStroke ? try? StrokeGeometry.samples(surface:surface) : nil
        for local in points {
            if surface.shape == .triangle {if triangle?.contains(local) == true {return true}}
            else if surface.shape.isStroke {
                guard let stroke,(0...1).contains(local.x),(0...1).contains(local.y) else {continue}
                let p=Point2(local.x*StrokeGeometry.aspectRatio,local.y)
                for (start,end) in zip(stroke,stroke.dropFirst()) {
                    let a=Point2(start.x*StrokeGeometry.aspectRatio,start.y),b=Point2(end.x*StrokeGeometry.aspectRatio,end.y)
                    let dx=b.x-a.x,dy=b.y-a.y,squared=dx*dx+dy*dy
                    guard squared>1e-24 else {continue}
                    let t=min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dy)/squared))
                    if hypot(p.x-a.x-t*dx,p.y-a.y-t*dy)<=surface.stroke.width/2+1e-10 {return true}
                }
            } else if surface.shape.contains(local) {return true}
        }
        return false
    }
}
