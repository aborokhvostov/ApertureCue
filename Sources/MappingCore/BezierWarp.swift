import Foundation

/// Row-major bicubic control lattice. Adjacent patches share their boundary
/// controls; the handles on either side remain independent (C0, not forced C1).
public struct BezierWarp: Codable, Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public var controls: [Point2]
    public init(columns: Int = 1, rows: Int = 1, controls: [Point2]) {
        self.columns=columns; self.rows=rows; self.controls=controls
    }
    public var controlColumns: Int { (1...8).contains(columns) ? columns*3+1 : 0 }
    public var controlRows: Int { (1...8).contains(rows) ? rows*3+1 : 0 }

    public func validate() throws {
        guard (1...8).contains(columns), (1...8).contains(rows),
              controls.count == (columns*3+1)*(rows*3+1), controls.allSatisfy(Self.finite) else {
            throw ProjectError.invalid("Bezier warp needs 1...8 patches per axis and a finite (3c+1) × (3r+1) control lattice")
        }
    }

    public func validate(projection: Homography) throws {
        try validate()
        for y in 0..<rows { for x in 0..<columns { _ = try homogeneousPatch(x,y,projection:projection) } }
    }

    /// A piecewise bilinear initial lattice. The outer quad remains a separate
    /// cage; each control is an absolute point in its current output-local frame.
    public static func regular(quad: [Point2], columns: Int = 1, rows: Int = 1) throws -> BezierWarp {
        try Geometry.validateQuad(quad)
        guard (1...8).contains(columns), (1...8).contains(rows),quad.allSatisfy(finite) else {
            throw ProjectError.invalid("invalid Bezier warp dimensions or cage")
        }
        var controls: [Point2]=[]
        for y in 0...rows*3 { for x in 0...columns*3 {
            let u=Double(x)/Double(columns*3),v=Double(y)/Double(rows*3)
            controls.append(bilinear(quad[0],quad[1],quad[3],quad[2],u,v))
        } }
        return BezierWarp(columns:columns,rows:rows,controls:controls)
    }

    public func point(at local: Point2, projection: Homography? = nil) throws -> Point2 {
        try validate()
        guard local.x.isFinite,local.y.isFinite,(0...1).contains(local.x),(0...1).contains(local.y) else {
            throw ProjectError.invalid("Bezier warp evaluation requires a finite unit coordinate")
        }
        return try evaluated(local,projection:projection)
    }

    /// Every patch uses the same dyadic subdivision level. Shared vertices and
    /// edges therefore have identical positions/UV and cannot form T junctions.
    /// The certificate bounds the exact rational surface against its triangle
    /// interpolant in the declared width/height. An exhausted budget rejects.
    public func tessellated(width: Int, height: Int, projection: Homography? = nil,
                            pixelTolerance: Double = 0.5, maximumTriangles: Int = 32768, minimumSubdivision: Int = 1) throws -> WarpTessellation {
        try validate()
        guard (1...16384).contains(width),(1...16384).contains(height),
              pixelTolerance.isFinite,pixelTolerance>0,pixelTolerance<=0.5,
              maximumTriangles>=2,maximumTriangles<=131072, (1...256).contains(minimumSubdivision),
              minimumSubdivision & (minimumSubdivision-1) == 0 else {
            throw ProjectError.invalid("invalid Bezier warp resolution, pixel tolerance or triangle budget")
        }
        let scale=Point2(Double(width),Double(height))
        var cells: [[WarpHomogeneousPoint]]=[]
        for y in 0..<rows { for x in 0..<columns { cells.append(try homogeneousPatch(x,y,projection:projection)) } }
        var subdivision=1
        for depth in 0...8 {
            guard cells.count<=maximumTriangles/2 else {
                throw ProjectError.invalid("Bezier warp exceeds its triangle precision budget")
            }
            var bound=0.0
            for cell in cells { bound=max(bound,try Self.errorBound(cell,scale:scale)) }
            if bound <= pixelTolerance, subdivision >= minimumSubdivision {
                let c=columns*subdivision,r=rows*subdivision
                var vertices: [WarpVertex]=[]
                vertices.reserveCapacity((c+1)*(r+1))
                for y in 0...r { for x in 0...c {
                    let local=Point2(Double(x)/Double(c),Double(y)/Double(r))
                    vertices.append(WarpVertex(output:try evaluated(local,projection:projection),local:local))
                } }
                var indices: [Int]=[]; indices.reserveCapacity(c*r*6)
                for y in 0..<r { for x in 0..<c {
                    let a=y*(c+1)+x,b=a+1,d=a+c+1,e=d+1
                    indices += [a,b,e,a,e,d]
                } }
                return WarpTessellation(columns:c,rows:r,vertices:vertices,indices:indices,maximumErrorPixels:bound)
            }
            guard depth<8,cells.count<=maximumTriangles/8 else {
                throw ProjectError.invalid("Bezier warp cannot reach its pixel tolerance within the subdivision budget")
            }
            cells=cells.flatMap(Self.splitPatch); subdivision*=2
        }
        throw ProjectError.invalid("Bezier warp precision budget exhausted")
    }

    func evaluated(_ local: Point2, projection: Homography?) throws -> Point2 {
        let sx=local.x*Double(columns),sy=local.y*Double(rows)
        let x=min(columns-1,Int(sx)),y=min(rows-1,Int(sy))
        let u=sx-Double(x),v=sy-Double(y)
        let bu=Self.basis(u),bv=Self.basis(v)
        var px=0.0,py=0.0
        for j in 0..<4 { for i in 0..<4 {
            let p=controls[(y*3+j)*controlColumns+x*3+i],w=bu[i]*bv[j]
            px+=p.x*w; py+=p.y*w
        } }
        let p=Point2(px,py),result=try projection?.applying(p) ?? p
        guard Self.finite(result) else { throw ProjectError.invalid("projected Bezier warp exceeds the finite working range") }
        return result
    }

    private func homogeneousPatch(_ x: Int, _ y: Int, projection: Homography?) throws -> [WarpHomogeneousPoint] {
        let m=projection?.values ?? [1,0,0,0,1,0,0,0,1]
        guard m.count==9,m.allSatisfy(\.isFinite) else { throw GeometryError.nonFinite }
        var result: [WarpHomogeneousPoint]=[]
        for j in 0..<4 { for i in 0..<4 {
            let p=controls[(y*3+j)*controlColumns+x*3+i]
            result.append(WarpHomogeneousPoint(x:m[0]*p.x+m[1]*p.y+m[2],y:m[3]*p.x+m[4]*p.y+m[5],w:m[6]*p.x+m[7]*p.y+m[8]))
        } }
        if result.allSatisfy({$0.w<0}) { result=result.map { $0.scaled(-1) } }
        let maximum=result.map {abs($0.w)}.max() ?? 0
        guard maximum>0,result.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.w.isFinite && $0.w>maximum*1e-10 && Self.finite($0.normalized)}) else {
            throw ProjectError.invalid("Bezier warp crosses or approaches the projective horizon")
        }
        return result.map { WarpHomogeneousPoint(x:$0.x/maximum,y:$0.y/maximum,w:$0.w/maximum) }
    }

    /// For homogeneous cubics N/W and bilinear corner interpolant B, elevate
    /// N and W*B to degree (4,4). Bernstein convex-hull bounds give
    /// |N/W-B| <= max_i |(N-WB)_i| / min_i W_i. B-to-two-triangles adds at most
    /// one quarter of the corner twist. Both norms use the screen pixel metric.
    private static func errorBound(_ p: [WarpHomogeneousPoint], scale: Point2) throws -> Double {
        let corners=[p[0].normalized,p[3].normalized,p[12].normalized,p[15].normalized]
        let minWeight=p.map(\.w).min()!
        let choose3=[1.0,3,3,1],choose4=[1.0,4,6,4,1]
        var residual=0.0
        for j in 0...4 { for i in 0...4 {
            var dx=0.0,dy=0.0
            for b in 0...1 { for a in 0...1 {
                let x=i-a,y=j-b
                guard (0...3).contains(x),(0...3).contains(y) else { continue }
                let factor=choose3[x]/choose4[i]*choose3[y]/choose4[j]
                let n=p[y*4+x],corner=corners[b*2+a]
                dx+=factor*(n.x-n.w*corner.x); dy+=factor*(n.y-n.w*corner.y)
            } }
            residual=max(residual,hypot(dx*scale.x,dy*scale.y)/minWeight)
        } }
        let twist=Point2(corners[0].x-corners[1].x-corners[2].x+corners[3].x,
                         corners[0].y-corners[1].y-corners[2].y+corners[3].y)
        let result=residual+hypot(twist.x*scale.x,twist.y*scale.y)/4
        guard result.isFinite else { throw ProjectError.invalid("nonfinite Bezier warp precision bound") }
        let coordinateScale=max(1,p.map {max(abs($0.normalized.x),abs($0.normalized.y))}.max() ?? 1)
        let roundingAllowance=Double.ulpOfOne*512*coordinateScale*max(scale.x,scale.y)/minWeight
        return result+max(1e-10,roundingAllowance)
    }

    private static func splitPatch(_ p: [WarpHomogeneousPoint]) -> [[WarpHomogeneousPoint]] {
        var left=Array(repeating:WarpHomogeneousPoint.zero,count:16),right=left
        for y in 0..<4 {
            let split=splitCurve(Array(p[(y*4)..<(y*4+4)]))
            for x in 0..<4 { left[y*4+x]=split.0[x]; right[y*4+x]=split.1[x] }
        }
        var output: [[WarpHomogeneousPoint]]=[]
        for half in [left,right] {
            var top=Array(repeating:WarpHomogeneousPoint.zero,count:16),bottom=top
            for x in 0..<4 {
                let split=splitCurve((0..<4).map {half[$0*4+x]})
                for y in 0..<4 { top[y*4+x]=split.0[y]; bottom[y*4+x]=split.1[y] }
            }
            output += [top,bottom]
        }
        return output
    }
    private static func splitCurve(_ p: [WarpHomogeneousPoint]) -> ([WarpHomogeneousPoint],[WarpHomogeneousPoint]) {
        let a=p[0].midpoint(p[1]),b=p[1].midpoint(p[2]),c=p[2].midpoint(p[3])
        let d=a.midpoint(b),e=b.midpoint(c),f=d.midpoint(e)
        return ([p[0],a,d,f],[f,e,c,p[3]])
    }
    private static func basis(_ t: Double) -> [Double] { let a=1-t; return [a*a*a,3*a*a*t,3*a*t*t,t*t*t] }
    private static func finite(_ p: Point2) -> Bool {p.x.isFinite && p.y.isFinite && abs(p.x)<=10000 && abs(p.y)<=10000}
    private static func bilinear(_ a: Point2,_ b: Point2,_ c: Point2,_ d: Point2,_ u: Double,_ v: Double) -> Point2 {
        Point2.interpolate(Point2.interpolate(a,b,t:u),Point2.interpolate(c,d,t:u),t:v)
    }
}

private struct WarpHomogeneousPoint {
    var x: Double; var y: Double; var w: Double
    static let zero=WarpHomogeneousPoint(x:0,y:0,w:0)
    var normalized: Point2 {Point2(x/w,y/w)}
    func scaled(_ scale: Double) -> Self {Self(x:x*scale,y:y*scale,w:w*scale)}
    func midpoint(_ b: Self) -> Self {Self(x:(x+b.x)/2,y:(y+b.y)/2,w:(w+b.w)/2)}
}

public struct WarpVertex: Codable, Equatable, Sendable {
    public var output: Point2
    public var local: Point2
    public init(output: Point2, local: Point2) {self.output=output;self.local=local}
}

public struct WarpTessellation: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let vertices: [WarpVertex]
    public let indices: [Int]
    public let maximumErrorPixels: Double

    public func point(at local: Point2) throws -> Point2 {
        guard local.x.isFinite,local.y.isFinite,(0...1).contains(local.x),(0...1).contains(local.y) else {
            throw ProjectError.invalid("tessellated warp evaluation needs a finite unit coordinate")
        }
        let sx=local.x*Double(columns),sy=local.y*Double(rows)
        let x=min(columns-1,Int(sx)),y=min(rows-1,Int(sy)),u=sx-Double(x),v=sy-Double(y)
        let a=y*(columns+1)+x,b=a+1,d=a+columns+1,c=d+1
        if v<=u {return Self.mix(vertices[a].output,vertices[b].output,vertices[c].output,1-u,u-v,v)}
        return Self.mix(vertices[a].output,vertices[c].output,vertices[d].output,1-v,u,v-u)
    }

    /// First triangle owns an ambiguous inverse on a folded surface, matching
    /// the existing regular-mesh editing policy. No unique inverse is claimed.
    public func localPoint(at output: Point2) -> Point2? {
        guard output.x.isFinite,output.y.isFinite else {return nil}
        for start in stride(from:0,to:indices.count,by:3) {
            let a=vertices[indices[start]],b=vertices[indices[start+1]],c=vertices[indices[start+2]]
            let ux=b.output.x-a.output.x,uy=b.output.y-a.output.y,vx=c.output.x-a.output.x,vy=c.output.y-a.output.y
            let determinant=ux*vy-uy*vx,scale=max(abs(ux),abs(uy),abs(vx),abs(vy))
            guard scale>0,abs(determinant)>max(1e-20,scale*scale*1e-12) else {continue}
            let px=output.x-a.output.x,py=output.y-a.output.y
            let wb=(px*vy-py*vx)/determinant,wc=(ux*py-uy*px)/determinant,wa=1-wb-wc
            if min(wa,wb,wc)>=(-1e-10) {return Self.mix(a.local,b.local,c.local,wa,wb,wc)}
        }
        return nil
    }
    private static func mix(_ a: Point2,_ b: Point2,_ c: Point2,_ wa: Double,_ wb: Double,_ wc: Double) -> Point2 {
        Point2(a.x*wa+b.x*wb+c.x*wc,a.y*wa+b.y*wb+c.y*wc)
    }
}

public struct LinkedMeshVertices: Equatable, Sendable {
    public let output: [Point2]
    public let input: [Point2]
}

public enum MeshLinkGeometry {
    /// Only an explicit link moves input vertices. The delta is measured in the
    /// output cage's normalized frame and added in the input cage's frame.
    /// Switching the link flag alone never reconciles or overwrites either mesh.
    public static func movingOutputVertex(output: [Point2], input: [Point2], index: Int, to point: Point2,
                                          outputQuad: [Point2], inputQuad: [Point2], linked: Bool) throws -> LinkedMeshVertices {
        guard (4...4225).contains(output.count),input.count==output.count,output.indices.contains(index),
              (output+input+[point]).allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x)<=10000 && abs($0.y)<=10000}) else {
            throw ProjectError.invalid("linked meshes need matching finite vertices and an existing selected index")
        }
        var a=output,b=input; a[index]=point
        if linked {
            let outputInverse=try Homography.solve(from:outputQuad,to:Point2.unitQuad)
            let inputInverse=try Homography.solve(from:inputQuad,to:Point2.unitQuad)
            let inputForward=try Homography.solve(from:Point2.unitQuad,to:inputQuad)
            let before=try outputInverse.applying(output[index]),after=try outputInverse.applying(point),source=try inputInverse.applying(input[index])
            b[index]=try inputForward.applying(Point2(source.x+after.x-before.x,source.y+after.y-before.y))
            guard b[index].x.isFinite,b[index].y.isFinite,abs(b[index].x)<=10000,abs(b[index].y)<=10000 else {
                throw ProjectError.invalid("linked input mesh exceeds finite working range")
            }
        }
        return LinkedMeshVertices(output:a,input:b)
    }
}
