import Foundation

/// Prepared source-domain mapping. For strokes the caller supplies arc-length /
/// across-width coordinates; this type does not reparameterize a centerline.
public struct SurfaceSourceMapping: Sendable {
    private let base: Homography
    private let warp: BezierWarp?
    private let projection: Homography?
    private let deltas: [Point2]
    private let columns: Int
    private let rows: Int

    public init(surface: Surface) throws {
        let mapping=try Homography.solve(from:Point2.unitQuad,to:surface.input)
        base=mapping; warp=surface.inputWarp
        if let warp=surface.inputWarp {
            guard surface.inputMesh.isEmpty else {throw ProjectError.invalid("source mesh and Bezier source warp are mutually exclusive")}
            let transform=try Homography(values:surface.inputWarpTransform.values)
            try warp.validate(projection:transform); projection=transform
            columns=0; rows=0; deltas=[]
        } else {
            projection=nil; columns=surface.meshColumns; rows=surface.meshRows
            if surface.inputMesh.isEmpty {deltas=[]}
            else {
                guard SurfaceWarpGeometry.validRegularMesh(surface),surface.inputMesh.count==surface.mesh.count,
                      surface.inputMesh.allSatisfy(SurfaceWarpGeometry.finite) else {
                    throw ProjectError.invalid("source mesh must match the regular output mesh")
                }
                var differences: [Point2]=[]
                for y in 0...rows {for x in 0...columns {
                    let index=y*(columns+1)+x,uv=try mapping.applying(Point2(Double(x)/Double(columns),Double(y)/Double(rows)))
                    differences.append(Point2(surface.inputMesh[index].x-uv.x,surface.inputMesh[index].y-uv.y))
                }}
                deltas=differences
            }
        }
    }

    public func point(at local: Point2) throws -> Point2 {
        try SurfaceWarpGeometry.validateLocal(local)
        if let warp {return try warp.evaluated(local,projection:projection)}
        let point=try base.applying(local)
        guard !deltas.isEmpty else {return point}
        let cell=SurfaceWarpGeometry.cell(local,columns:columns,rows:rows)
        let d=SurfaceWarpGeometry.mix(deltas[cell.a],deltas[cell.b],deltas[cell.c],cell.wa,cell.wb,cell.wc)
        let result=Point2(point.x+d.x,point.y+d.y)
        guard SurfaceWarpGeometry.finite(result) else {throw ProjectError.invalid("source mesh mapping exceeds the finite working range")}
        return result
    }
}

public enum SurfaceWarpGeometry {
    /// Includes the source delta's interpolation error when an independent input
    /// warp is active. Half a texture pixel is shared between source warp and
    /// base input homography, whose difference is interpolated by the adapter.
    public static func tessellation(surface: Surface,width: Int = 1280,height: Int = 720,
                                    sourceWidth: Int? = nil,sourceHeight: Int? = nil) throws -> WarpTessellation? {
        guard let warp=surface.bezierWarp else {return nil}
        let projection=try Homography(values:surface.warpTransform.values)
        var output=try warp.tessellated(width:width,height:height,projection:projection,maximumTriangles:65536)
        if let source=surface.inputWarp {
            guard source.columns==warp.columns,source.rows==warp.rows else {throw ProjectError.invalid("input and output Bezier warps must have matching patch topology")}
            let w=sourceWidth ?? width,h=sourceHeight ?? height
            let input=try source.tessellated(width:w,height:h,projection:Homography(values:surface.inputWarpTransform.values),pixelTolerance:0.25,maximumTriangles:65536)
            let base=try BezierWarp.regular(quad:Point2.unitQuad,columns:warp.columns,rows:warp.rows)
            let cropped=try base.tessellated(width:w,height:h,projection:Homography.solve(from:Point2.unitQuad,to:surface.input),pixelTolerance:0.25,maximumTriangles:65536)
            let subdivision=max(output.columns/warp.columns,input.columns/warp.columns,cropped.columns/warp.columns)
            if output.columns/warp.columns<subdivision {
                output=try warp.tessellated(width:width,height:height,projection:projection,maximumTriangles:65536,minimumSubdivision:subdivision)
            }
        }
        return output
    }

    static func validateLocal(_ local: Point2) throws {
        guard local.x.isFinite,local.y.isFinite else {throw GeometryError.nonFinite}
        guard (0...1).contains(local.x),(0...1).contains(local.y) else {throw ProjectError.invalid("local point is outside its unit cage")}
    }
    static func finite(_ point: Point2) -> Bool {point.x.isFinite && point.y.isFinite && abs(point.x)<=10000 && abs(point.y)<=10000}
    static func validRegularMesh(_ surface: Surface) -> Bool {
        let c=surface.meshColumns,r=surface.meshRows
        return (1...64).contains(c) && (1...64).contains(r) && surface.mesh.count==(c+1)*(r+1)
            && surface.mesh.allSatisfy(finite)
            && (surface.meshWeights.isEmpty || (surface.meshWeights.count==surface.mesh.count && surface.meshWeights.allSatisfy({$0.isFinite && $0>1e-12 && $0<=10000})))
    }
    static func cell(_ local: Point2,columns: Int,rows: Int) -> (a: Int,b: Int,c: Int,wa: Double,wb: Double,wc: Double) {
        let sx=local.x*Double(columns),sy=local.y*Double(rows),x=min(columns-1,Int(sx)),y=min(rows-1,Int(sy))
        let u=sx-Double(x),v=sy-Double(y),a=y*(columns+1)+x,b=a+1,d=a+columns+1,c=d+1
        if v<=u {return (a,b,c,1-u,u-v,v)}
        return (a,c,d,1-v,u,v-u)
    }
    static func mix(_ a: Point2,_ b: Point2,_ c: Point2,_ wa: Double,_ wb: Double,_ wc: Double) -> Point2 {
        Point2(a.x*wa+b.x*wb+c.x*wc,a.y*wa+b.y*wb+c.y*wc)
    }
    static func barycentric(_ point: Point2,_ a: Point2,_ b: Point2,_ c: Point2) -> (Double,Double,Double)? {
        let ux=b.x-a.x,uy=b.y-a.y,vx=c.x-a.x,vy=c.y-a.y,determinant=ux*vy-uy*vx,scale=max(abs(ux),abs(uy),abs(vx),abs(vy))
        guard scale>0,abs(determinant)>max(1e-20,scale*scale*1e-12) else {return nil}
        let px=point.x-a.x,py=point.y-a.y,wb=(px*vy-py*vx)/determinant,wc=(ux*py-uy*px)/determinant,wa=1-wb-wc
        guard min(wa,wb,wc)>=(-1e-10) else {return nil}
        return (wa,wb,wc)
    }
    static func edgeParameters(from a: Point2,to b: Point2,columns: Int,rows: Int) -> [Double] {
        var parameters=[0.0]
        func crossings(start: Double,end: Double,levels: ClosedRange<Int>,scale: Double) {
            let delta=end-start
            guard abs(delta)>1e-14 else {return}
            for level in levels {
                let t=(Double(level)/scale-start)/delta
                if t>1e-12,t<1-1e-12 {parameters.append(t)}
            }
        }
        crossings(start:a.x,end:b.x,levels:0...columns,scale:Double(columns))
        crossings(start:a.y,end:b.y,levels:0...rows,scale:Double(rows))
        crossings(start:Double(columns)*a.x-Double(rows)*a.y,end:Double(columns)*b.x-Double(rows)*b.y,levels:(-rows)...columns,scale:1)
        parameters.sort()
        var unique: [Double]=[]
        for value in parameters where unique.last.map({abs($0-value)>1e-11}) ?? true {unique.append(value)}
        return unique
    }
}

/// One preparation per batch avoids repeated homography solves, validation or
/// tessellation for contour vertices. Callers can supply their cached grid.
struct PreparedSurfaceGeometry {
    let surface: Surface
    let tessellation: WarpTessellation?
    let projection: Homography?
    var columns: Int {tessellation?.columns ?? surface.meshColumns}
    var rows: Int {tessellation?.rows ?? surface.meshRows}
    var hasGrid: Bool {tessellation != nil || !surface.mesh.isEmpty}

    init(surface: Surface,tessellation: WarpTessellation? = nil) throws {
        self.surface=surface
        if surface.bezierWarp != nil {
            self.tessellation=try tessellation ?? SurfaceWarpGeometry.tessellation(surface:surface)
            projection=nil
        } else if !surface.mesh.isEmpty {
            guard SurfaceWarpGeometry.validRegularMesh(surface) else {throw ProjectError.invalid("invalid surface mesh")}
            self.tessellation=nil; projection=nil
        } else {
            self.tessellation=nil; projection=try Homography.solve(from:Point2.unitQuad,to:surface.output)
        }
    }
    func point(_ local: Point2) throws -> Point2 {
        if let tessellation {return try tessellation.point(at:local)}
        if let projection {return try projection.applying(local)}
        let p=SurfaceWarpGeometry.cell(local,columns:surface.meshColumns,rows:surface.meshRows)
        if surface.meshWeights.isEmpty {return SurfaceWarpGeometry.mix(surface.mesh[p.a],surface.mesh[p.b],surface.mesh[p.c],p.wa,p.wb,p.wc)}
        let wa=p.wa*surface.meshWeights[p.a],wb=p.wb*surface.meshWeights[p.b],wc=p.wc*surface.meshWeights[p.c],total=wa+wb+wc
        guard total.isFinite,total>1e-15 else {throw ProjectError.invalid("surface mesh crosses its projective horizon")}
        return SurfaceWarpGeometry.mix(surface.mesh[p.a],surface.mesh[p.b],surface.mesh[p.c],wa/total,wb/total,wc/total)
    }

    func localPoints(_ output: Point2) throws -> [Point2] {
        if let projection {
            let point=try projection.inverse().applying(output)
            return point.x>=(-1e-9) && point.x<=1+1e-9 && point.y>=(-1e-9) && point.y<=1+1e-9 ? [point] : []
        }
        var result: [Point2]=[]
        if let tessellation {
            for start in stride(from:0,to:tessellation.indices.count,by:3) {
                let a=tessellation.vertices[tessellation.indices[start]],b=tessellation.vertices[tessellation.indices[start+1]],c=tessellation.vertices[tessellation.indices[start+2]]
                if let w=SurfaceWarpGeometry.barycentric(output,a.output,b.output,c.output) {
                    result.append(SurfaceWarpGeometry.mix(a.local,b.local,c.local,w.0,w.1,w.2))
                }
            }
            return result
        }
        let columns=surface.meshColumns,rows=surface.meshRows
        for y in 0..<rows {for x in 0..<columns {
            let a=y*(columns+1)+x,b=a+1,d=a+columns+1,c=d+1
            let u=Double(x)/Double(columns),v=Double(y)/Double(rows),u1=Double(x+1)/Double(columns),v1=Double(y+1)/Double(rows)
            for (i,j,k,p,q,r) in [(a,b,c,Point2(u,v),Point2(u1,v),Point2(u1,v1)),(a,c,d,Point2(u,v),Point2(u1,v1),Point2(u,v1))] {
                if let w=SurfaceWarpGeometry.barycentric(output,surface.mesh[i],surface.mesh[j],surface.mesh[k]) {
                    if surface.meshWeights.isEmpty {result.append(SurfaceWarpGeometry.mix(p,q,r,w.0,w.1,w.2))}
                    else {
                        let wa=w.0/surface.meshWeights[i],wb=w.1/surface.meshWeights[j],wc=w.2/surface.meshWeights[k],total=wa+wb+wc
                        if total.isFinite,total>1e-15,min(wa/total,wb/total,wc/total)>=(-1e-9) {result.append(SurfaceWarpGeometry.mix(p,q,r,wa/total,wb/total,wc/total))}
                    }
                }
            }
        }}
        return result
    }
}
