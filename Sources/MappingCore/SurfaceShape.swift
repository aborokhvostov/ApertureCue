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
        case .triangle: return [Point2(0.5,0), Point2(1,1), Point2(0,1)]
        case .ellipse:
            let count = max(8,min(256,segments))
            return (0..<count).map { index in
                let angle = -Double.pi/2 + Double(index)*2*Double.pi/Double(count)
                return Point2(0.5+0.5*cos(angle),0.5+0.5*sin(angle))
            }
        }
    }
}

/// Matches the renderer's projective cage and the exact two-triangle split of
/// every regular mesh cell. Contains tests all folded/overlapping mesh triangles.
public enum SurfaceGeometry {
    public static func outputPoint(local: Point2, surface: Surface) throws -> Point2 {
        guard local.x.isFinite, local.y.isFinite else { throw GeometryError.nonFinite }
        guard (0...1).contains(local.x), (0...1).contains(local.y) else { throw ProjectError.invalid("local point is outside its unit cage") }
        if surface.mesh.isEmpty {
            return try Homography.solve(from:Point2.unitQuad,to:surface.output).applying(local)
        }
        guard validMesh(surface) else { throw ProjectError.invalid("invalid surface mesh") }
        return meshPoint(local:local,surface:surface)
    }

    /// Inverse of the editable cage/mesh. Folded meshes are not one-to-one;
    /// the first nondegenerate covering triangle owns an ambiguous edit.
    public static func localPoint(output:Point2,surface:Surface) throws -> Point2 {
        guard output.x.isFinite,output.y.isFinite else { throw GeometryError.nonFinite }
        if surface.mesh.isEmpty {
            let point=try Homography.solve(from:surface.output,to:Point2.unitQuad).applying(output)
            guard point.x >= -1e-9,point.x<=1+1e-9,point.y >= -1e-9,point.y<=1+1e-9 else { throw ProjectError.invalid("output point lies outside the surface cage") }
            return Point2(min(1,max(0,point.x)),min(1,max(0,point.y)))
        }
        guard validMesh(surface) else { throw ProjectError.invalid("invalid surface mesh") }
        let columns=surface.meshColumns,rows=surface.meshRows
        for y in 0..<rows {
            for x in 0..<columns {
                let a=y*(columns+1)+x,b=a+1,d=a+columns+1,c=d+1
                let u=Double(x)/Double(columns),v=Double(y)/Double(rows),u1=Double(x+1)/Double(columns),v1=Double(y+1)/Double(rows)
                let candidates=[(a,b,c,Point2(u,v),Point2(u1,v),Point2(u1,v1)),(a,c,d,Point2(u,v),Point2(u1,v1),Point2(u,v1))]
                for (i,j,k,p,q,r) in candidates {
                    if let w=barycentric(output,surface.mesh[i],surface.mesh[j],surface.mesh[k]) {
                        let local=interpolate(p,q,r,w.0,w.1,w.2)
                        return Point2(min(1,max(0,local.x)),min(1,max(0,local.y)))
                    }
                }
            }
        }
        throw ProjectError.invalid("output point lies outside the surface mesh")
    }

    /// Projects one closed primitive contour without repeating its first point.
    /// Mesh validation or the projective solve happens once for the entire batch.
    /// Straight edges split at every mesh cell/diagonal boundary, preserving their
    /// exact piecewise-linear shape. Ellipses use 8...256 local curve samples.
    public static func outputOutline(surface: Surface, segments: Int = 64) throws -> [Point2] {
        let local=surface.shape.outline(segments:segments)
        if surface.mesh.isEmpty {
            let projection=try Homography.solve(from:Point2.unitQuad,to:surface.output)
            return try local.map { try projection.applying($0) }
        }
        guard validMesh(surface) else { throw ProjectError.invalid("invalid surface mesh") }
        if surface.shape == .ellipse { return local.map { meshPoint(local:$0,surface:surface) } }
        var contour:[Point2]=[]
        for index in local.indices {
            let a=local[index], b=local[(index+1)%local.count]
            for t in meshEdgeParameters(from:a,to:b,columns:surface.meshColumns,rows:surface.meshRows) {
                contour.append(meshPoint(local:Point2.interpolate(a,b,t:t),surface:surface))
            }
        }
        return contour
    }

    /// Project the flattened stroke through every crossed regular-mesh cell and
    /// diagonal. The editor centerline follows the same piecewise-linear warp
    /// as fragment-local coordinates, including straight local line segments.
    public static func outputCenterline(surface:Surface) throws -> [Point2] {
        let local=try StrokeGeometry.samples(surface:surface)
        if surface.mesh.isEmpty {
            let projection=try Homography.solve(from:Point2.unitQuad,to:surface.output)
            return try local.map { try projection.applying($0) }
        }
        guard validMesh(surface) else { throw ProjectError.invalid("invalid stroke surface mesh") }
        var result:[Point2]=[]
        for (a,b) in zip(local,local.dropFirst()) {
            for t in meshEdgeParameters(from:a,to:b,columns:surface.meshColumns,rows:surface.meshRows) {
                result.append(meshPoint(local:Point2.interpolate(a,b,t:t),surface:surface))
            }
        }
        if let last=local.last { result.append(meshPoint(local:last,surface:surface)) }
        return result
    }

    /// The caller has already validated the complete mesh and local unit point.
    private static func meshPoint(local: Point2, surface: Surface) -> Point2 {
        let columns=surface.meshColumns, rows=surface.meshRows
        let scaledX=local.x*Double(columns), scaledY=local.y*Double(rows)
        let x=min(columns-1,Int(scaledX)), y=min(rows-1,Int(scaledY))
        let u=scaledX-Double(x), v=scaledY-Double(y)
        let a=y*(columns+1)+x, b=a+1, d=a+columns+1, c=d+1
        if v <= u { return interpolate(surface.mesh[a],surface.mesh[b],surface.mesh[c],1-u,u-v,v) }
        return interpolate(surface.mesh[a],surface.mesh[c],surface.mesh[d],1-v,u,v-u)
    }

    private static func meshEdgeParameters(from a:Point2,to b:Point2,columns:Int,rows:Int) -> [Double] {
        var parameters=[0.0]
        func crossings(start:Double,end:Double,levels:ClosedRange<Int>,scale:Double) {
            let delta=end-start
            guard abs(delta) > 1e-14 else { return }
            for level in levels {
                let t=(Double(level)/scale-start)/delta
                if t > 1e-12 && t < 1-1e-12 { parameters.append(t) }
            }
        }
        // For a cell's a-b-c / a-c-d split, the diagonal is
        // columns*x - rows*y == cellColumn - cellRow.
        crossings(start:a.x,end:b.x,levels:0...columns,scale:Double(columns))
        crossings(start:a.y,end:b.y,levels:0...rows,scale:Double(rows))
        crossings(start:Double(columns)*a.x-Double(rows)*a.y,
                  end:Double(columns)*b.x-Double(rows)*b.y,levels:(-rows)...columns,scale:1)
        parameters.sort()
        var unique:[Double]=[]
        for t in parameters where unique.last.map({ abs($0-t) > 1e-11 }) ?? true { unique.append(t) }
        return unique
    }

    /// Geometric primitive selection, independent of visibility, feather and UV
    /// mask. Those are appearance controls, not cage selection restrictions.
    public static func contains(output: Point2, surface: Surface) -> Bool {
        guard output.x.isFinite, output.y.isFinite else { return false }
        if surface.mesh.isEmpty {
            guard let inverse=try? Homography.solve(from:surface.output,to:Point2.unitQuad),
                  let local=try? inverse.applying(output) else { return false }
            return containsLocal(local,surface:surface)
        }
        guard validMesh(surface) else { return false }
        let columns=surface.meshColumns, rows=surface.meshRows
        for y in 0..<rows {
            for x in 0..<columns {
                let a=y*(columns+1)+x, b=a+1, d=a+columns+1, c=d+1
                let u=Double(x)/Double(columns), v=Double(y)/Double(rows)
                let u1=Double(x+1)/Double(columns), v1=Double(y+1)/Double(rows)
                if let weights=barycentric(output,surface.mesh[a],surface.mesh[b],surface.mesh[c]),
                   containsLocal(interpolate(Point2(u,v),Point2(u1,v),Point2(u1,v1),weights.0,weights.1,weights.2),surface:surface) { return true }
                if let weights=barycentric(output,surface.mesh[a],surface.mesh[c],surface.mesh[d]),
                   containsLocal(interpolate(Point2(u,v),Point2(u1,v1),Point2(u,v1),weights.0,weights.1,weights.2),surface:surface) { return true }
            }
        }
        return false
    }

    private static func containsLocal(_ local:Point2,surface:Surface) -> Bool {
        surface.shape.isStroke ? StrokeGeometry.contains(local:local,surface:surface) : surface.shape.contains(local)
    }

    private static func validMesh(_ surface: Surface) -> Bool {
        let c=surface.meshColumns, r=surface.meshRows
        return c > 0 && c <= 64 && r > 0 && r <= 64 && surface.mesh.count == (c+1)*(r+1)
            && surface.mesh.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }
    private static func interpolate(_ a:Point2,_ b:Point2,_ c:Point2,_ wa:Double,_ wb:Double,_ wc:Double) -> Point2 {
        Point2(a.x*wa+b.x*wb+c.x*wc,a.y*wa+b.y*wb+c.y*wc)
    }
    private static func barycentric(_ point:Point2,_ a:Point2,_ b:Point2,_ c:Point2) -> (Double,Double,Double)? {
        let ux=b.x-a.x, uy=b.y-a.y, vx=c.x-a.x, vy=c.y-a.y
        let determinant=ux*vy-uy*vx
        let scale=max(abs(ux),abs(uy),abs(vx),abs(vy))
        guard scale > 0, abs(determinant) > max(1e-20,scale*scale*1e-12) else { return nil }
        let px=point.x-a.x, py=point.y-a.y
        let wb=(px*vy-py*vx)/determinant, wc=(ux*py-uy*px)/determinant, wa=1-wb-wc
        let epsilon=1e-10
        guard wa >= -epsilon, wb >= -epsilon, wc >= -epsilon else { return nil }
        return (wa,wb,wc)
    }
}
