import Foundation

public struct Point3:Codable,Equatable,Sendable {
    public var x:Double, y:Double, z:Double
    public init(_ x:Double,_ y:Double,_ z:Double) { self.x=x; self.y=y; self.z=z }
    public init(x:Double,y:Double,z:Double) { self.init(x,y,z) }
    public static func - (a:Point3,b:Point3) -> Point3 { Point3(a.x-b.x,a.y-b.y,a.z-b.z) }
    public var isFinite:Bool { x.isFinite && y.isFinite && z.isFinite }
    fileprivate var length:Double { sqrt(x*x+y*y+z*z) }
    fileprivate func dot(_ b:Point3) -> Double { x*b.x+y*b.y+z*b.z }
    fileprivate func cross(_ b:Point3) -> Point3 { Point3(y*b.z-z*b.y,z*b.x-x*b.z,x*b.y-y*b.x) }
    fileprivate func normalized() throws -> Point3 {
        let n=length
        guard isFinite,n.isFinite,n > 1e-12 else { throw Scene3DError.invalid("zero or non-finite direction vector") }
        return Point3(x/n,y/n,z/n)
    }
}

public enum Scene3DError:Error,LocalizedError,Equatable {
    case invalid(String)
    public var errorDescription:String? { switch self { case .invalid(let message):return "Invalid 3D scene: "+message } }
}

public struct OBJVertex:Codable,Equatable,Sendable {
    public var position:Point3
    /// OBJ UVs retain the format's bottom-left convention. Flip v when sampling a top-left image.
    public var uv:Point2?
    public init(position:Point3,uv:Point2?=nil) { self.position=position; self.uv=uv }
}

public struct OBJMesh:Codable,Equatable,Sendable {
    /// Unified position/UV vertices. UV seams therefore produce distinct vertices.
    public var vertices:[OBJVertex]
    public var indices:[UInt32]
    public init(vertices:[OBJVertex],indices:[UInt32]) { self.vertices=vertices; self.indices=indices }

    /// Polygonal Wavefront OBJ subset: v/vt/vn/f, positive and negative indices, planar n-gons.
    /// Materials and object/group metadata are ignored; external files are never opened.
    public static func parse(_ source:String) throws -> OBJMesh {
        guard source.utf8.count <= 16*1024*1024, !source.contains("\0") else { throw Scene3DError.invalid("OBJ source exceeds 16 MiB or contains NUL") }
        var positions:[Point3]=[], texcoords:[Point2]=[], normalCount=0
        var vertices:[OBJVertex]=[], indices:[UInt32]=[], unified:[String:UInt32]=[:]
        var pending="", lineNumber=0
        func number(_ text:Substring) throws -> Double {
            guard let value=Double(text),value.isFinite,abs(value)<=1e9 else { throw Scene3DError.invalid("line \(lineNumber): invalid numeric coordinate") }
            return value
        }
        func index(_ text:Substring,_ count:Int) throws -> Int {
            guard let value=Int(text),value != 0,value >= -count,value <= count else { throw Scene3DError.invalid("line \(lineNumber): OBJ index outside defined vertex list") }
            return value > 0 ? value-1 : count+value
        }
        for rawLine in source.split(separator:"\n",omittingEmptySubsequences:false) {
            lineNumber += 1
            guard lineNumber <= 1_000_000, rawLine.utf8.count <= 65536 else { throw Scene3DError.invalid("OBJ line count/length limit") }
            let content=rawLine.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)[0].trimmingCharacters(in:.whitespacesAndNewlines)
            if content.hasSuffix("\\") {
                pending += String(content.dropLast())+" "
                guard pending.utf8.count <= 65536 else { throw Scene3DError.invalid("OBJ continued line length limit") }
                continue
            }
            let statement=pending+content; pending=""
            let tokens=statement.split(whereSeparator:{ $0.isWhitespace })
            guard let directive=tokens.first else { continue }
            switch directive {
            case "v":
                guard tokens.count == 4 || tokens.count == 5,positions.count < 200_000 else { throw Scene3DError.invalid("line \(lineNumber): v requires x y z [w], bounded to 200000 vertices") }
                let x=try number(tokens[1]),y=try number(tokens[2]),z=try number(tokens[3])
                let w=tokens.count == 5 ? try number(tokens[4]) : 1
                guard abs(w)>1e-12 else { throw Scene3DError.invalid("line \(lineNumber): zero homogeneous vertex weight") }
                let position=Point3(x/w,y/w,z/w)
                guard position.isFinite, max(abs(position.x),abs(position.y),abs(position.z)) <= 1e9 else { throw Scene3DError.invalid("homogeneous OBJ coordinate outside working range") }
                positions.append(position)
            case "vt":
                guard (2...4).contains(tokens.count),texcoords.count < 200_000 else { throw Scene3DError.invalid("line \(lineNumber): vt arity or count") }
                let u=try number(tokens[1]),v=tokens.count >= 3 ? try number(tokens[2]) : 0
                if tokens.count == 4 { _=try number(tokens[3]) }
                texcoords.append(Point2(u,v))
            case "vn":
                guard tokens.count == 4,normalCount < 200_000 else { throw Scene3DError.invalid("line \(lineNumber): vn arity or count") }
                _=try number(tokens[1]); _=try number(tokens[2]); _=try number(tokens[3]); normalCount += 1
            case "f":
                guard (4...257).contains(tokens.count) else { throw Scene3DError.invalid("line \(lineNumber): face requires 3...256 vertices") }
                var face:[OBJVertex]=[], keys:[String]=[]
                for token in tokens.dropFirst() {
                    let parts=token.split(separator:"/",omittingEmptySubsequences:false)
                    guard (1...3).contains(parts.count), !parts[0].isEmpty else { throw Scene3DError.invalid("line \(lineNumber): face index syntax") }
                    let pi=try index(parts[0],positions.count)
                    var ti:Int?
                    if parts.count >= 2,!parts[1].isEmpty { ti=try index(parts[1],texcoords.count) }
                    if parts.count == 2,parts[1].isEmpty { throw Scene3DError.invalid("line \(lineNumber): empty texture index") }
                    if parts.count == 3 { guard !parts[2].isEmpty else { throw Scene3DError.invalid("line \(lineNumber): empty normal index") }; _=try index(parts[2],normalCount) }
                    face.append(OBJVertex(position:positions[pi],uv:ti.map { texcoords[$0] }))
                    keys.append("\(pi)/\(ti.map(String.init) ?? "")")
                }
                let triangles=try triangulate(face.map(\.position))
                guard indices.count+triangles.count*3 <= 1_200_000 else { throw Scene3DError.invalid("OBJ exceeds 400000 triangles") }
                for triangle in triangles {
                    for corner in triangle {
                        let key=keys[corner]
                        if let existing=unified[key] { indices.append(existing) }
                        else {
                            guard vertices.count < 600_000 else { throw Scene3DError.invalid("OBJ unified vertex count limit") }
                            let new=UInt32(vertices.count); unified[key]=new; vertices.append(face[corner]); indices.append(new)
                        }
                    }
                }
            case "o","g","s","usemtl","mtllib":continue
            case "p","l","curv","curv2","surf","cstype","deg","bmat","step","parm","trim","hole","scrv","sp","end","con","vp":
                throw Scene3DError.invalid("line \(lineNumber): freeform/point/line geometry \(directive) is unsupported")
            default:throw Scene3DError.invalid("line \(lineNumber): unknown OBJ directive \(directive)")
            }
        }
        guard pending.isEmpty,!indices.isEmpty else { throw Scene3DError.invalid("unterminated continuation or no polygon faces") }
        return OBJMesh(vertices:vertices,indices:indices)
    }

    private static func triangulate(_ points:[Point3]) throws -> [[Int]] {
        var normal=Point3(0,0,0)
        let origin=points[0]
        let extent=points.map { ($0-origin).length }.max()!
        guard extent.isFinite,extent > 1e-10 else { throw Scene3DError.invalid("collapsed OBJ face") }
        let normalized=points.map { Point3(($0.x-origin.x)/extent,($0.y-origin.y)/extent,($0.z-origin.z)/extent) }
        for i in normalized.indices {
            let a=normalized[i],b=normalized[(i+1)%normalized.count]
            normal.x += (a.y-b.y)*(a.z+b.z); normal.y += (a.z-b.z)*(a.x+b.x); normal.z += (a.x-b.x)*(a.y+b.y)
        }
        let n=try normal.normalized()
        guard normalized.allSatisfy({ abs($0.dot(n)) <= 1e-6 }) else { throw Scene3DError.invalid("non-planar OBJ polygon") }
        let axis=abs(n.x)>abs(n.y) ? (abs(n.x)>abs(n.z) ? 0:2) : (abs(n.y)>abs(n.z) ? 1:2)
        let p=normalized.map { axis == 0 ? Point2($0.y,$0.z) : axis == 1 ? Point2($0.x,$0.z) : Point2($0.x,$0.y) }
        let epsilon=1e-12
        func cross(_ a:Point2,_ b:Point2,_ c:Point2) -> Double { (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x) }
        func onSegment(_ a:Point2,_ b:Point2,_ q:Point2) -> Bool {
            abs(cross(a,b,q))<=epsilon && q.x>=min(a.x,b.x)-epsilon && q.x<=max(a.x,b.x)+epsilon && q.y>=min(a.y,b.y)-epsilon && q.y<=max(a.y,b.y)+epsilon
        }
        for i in p.indices {
            let i2=(i+1)%p.count
            guard hypot(p[i].x-p[i2].x,p[i].y-p[i2].y)>1e-10 else { throw Scene3DError.invalid("duplicate OBJ face corner") }
            for j in (i+1)..<p.count {
                let j2=(j+1)%p.count
                if j == i2 || j2 == i { continue }
                let a=cross(p[i],p[i2],p[j]),b=cross(p[i],p[i2],p[j2]),c=cross(p[j],p[j2],p[i]),d=cross(p[j],p[j2],p[i2])
                if a*b < 0 && c*d < 0 || onSegment(p[i],p[i2],p[j]) || onSegment(p[i],p[i2],p[j2]) || onSegment(p[j],p[j2],p[i]) || onSegment(p[j],p[j2],p[i2]) { throw Scene3DError.invalid("self-intersecting OBJ face") }
            }
        }
        let area=p.indices.reduce(0.0) { value,i in value+p[i].x*p[(i+1)%p.count].y-p[(i+1)%p.count].x*p[i].y }
        guard abs(area)>epsilon else { throw Scene3DError.invalid("zero-area OBJ face") }
        let sign=area>0 ? 1.0:-1.0
        var remaining=Array(p.indices),result:[[Int]]=[]
        while remaining.count>3 {
            var ear:Int?
            for k in remaining.indices {
                let a=remaining[(k+remaining.count-1)%remaining.count],b=remaining[k],c=remaining[(k+1)%remaining.count]
                guard sign*cross(p[a],p[b],p[c])>epsilon else { continue }
                let contains=remaining.contains { q in
                    if q==a || q==b || q==c { return false }
                    return sign*cross(p[a],p[b],p[q]) >= -epsilon && sign*cross(p[b],p[c],p[q]) >= -epsilon && sign*cross(p[c],p[a],p[q]) >= -epsilon
                }
                if !contains { result.append([a,b,c]); ear=k; break }
            }
            guard let ear=ear else { throw Scene3DError.invalid("OBJ polygon cannot be triangulated without degeneracy") }
            remaining.remove(at:ear)
        }
        guard sign*cross(p[remaining[0]],p[remaining[1]],p[remaining[2]])>epsilon else { throw Scene3DError.invalid("degenerate final OBJ triangle") }
        result.append(remaining); return result
    }
}

public struct ProjectedPoint:Equatable,Sendable {
    public var x:Double, y:Double, depth:Double
    public init(x:Double,y:Double,depth:Double) { self.x=x; self.y=y; self.depth=depth }
}

/// Right-handed pinhole camera. Projected x/y use a top-left normalized output origin.
public struct Camera3D:Codable,Equatable,Sendable {
    public var position:Point3
    public var target:Point3
    public var up:Point3
    public var verticalFOV:Double
    public var aspect:Double
    public var near:Double
    public var far:Double
    public init(position:Point3=Point3(0,0,3),target:Point3=Point3(0,0,0),up:Point3=Point3(0,1,0),verticalFOV:Double=60,aspect:Double=16.0/9.0,near:Double=0.01,far:Double=1000) {
        self.position=position; self.target=target; self.up=up; self.verticalFOV=verticalFOV; self.aspect=aspect; self.near=near; self.far=far
    }
    public func validate() throws {
        guard position.isFinite,target.isFinite,up.isFinite,verticalFOV.isFinite,(1...179).contains(verticalFOV),aspect.isFinite,(1e-6...1e6).contains(aspect),near.isFinite,far.isFinite,near>0,far>near else { throw Scene3DError.invalid("camera field of view, clipping range or vectors") }
        let forward=try (target-position).normalized()
        _=try forward.cross(up).normalized()
    }
    /// Offscreen coordinates are retained for later viewport clipping; depth outside near...far is nil.
    public func project(_ point:Point3) throws -> ProjectedPoint? {
        try validate()
        guard point.isFinite else { throw Scene3DError.invalid("non-finite projected point") }
        let forward=try (target-position).normalized(),right=try forward.cross(up).normalized(),vertical=right.cross(forward)
        let relative=point-position,depth=relative.dot(forward)
        guard depth>=near,depth<=far else { return nil }
        let tangent=tan(verticalFOV*Double.pi/360)
        return ProjectedPoint(x:0.5+relative.dot(right)/(2*depth*tangent*aspect),y:0.5-relative.dot(vertical)/(2*depth*tangent),depth:depth)
    }
}

extension OBJMesh {
    /// Bake a static pinhole projection into editor-native quadrilateral patches.
    /// This is painter ordering, not a depth-buffered 3D scene: intersecting triangles need splitting.
    public func projectedSurfaces(camera:Camera3D,mediaID:UUID?=nil) throws -> [Surface] {
        try camera.validate()
        guard !indices.isEmpty,indices.count%3 == 0,indices.count/3 <= 1365,
              indices.allSatisfy({ Int($0)<vertices.count }),
              vertices.allSatisfy({ $0.position.isFinite && ($0.uv == nil || ($0.uv!.x.isFinite && $0.uv!.y.isFinite)) }) else { throw Scene3DError.invalid("projection requires valid mesh indices and at most 1365 triangles") }
        struct Triangle { var index:Int; var corners:[OBJVertex]; var depth:Double }
        var triangles:[Triangle]=[]
        for index in stride(from:0,to:indices.count,by:3) {
            let corners=(0..<3).map { vertices[Int(indices[index+$0])] }
            let projections=try corners.map { try camera.project($0.position) }
            guard projections.allSatisfy({ $0 != nil }) else { continue }
            triangles.append(Triangle(index:index/3,corners:corners,depth:projections.reduce(0) { $0+$1!.depth }/3))
        }
        triangles.sort { $0.depth == $1.depth ? $0.index<$1.index : $0.depth>$1.depth }
        var result:[Surface]=[]
        func average3(_ a:Point3,_ b:Point3,_ c:Point3) -> Point3 { Point3((a.x+b.x+c.x)/3,(a.y+b.y+c.y)/3,(a.z+b.z+c.z)/3) }
        func midpoint3(_ a:Point3,_ b:Point3) -> Point3 { Point3((a.x+b.x)/2,(a.y+b.y)/2,(a.z+b.z)/2) }
        let fallback=[Point2(0,0),Point2(1,0),Point2(0,1)]
        for triangle in triangles {
            let positions=triangle.corners.map(\.position)
            // OBJ stores bottom-left texture v; Surface input uses top-left image coordinates.
            let uv=triangle.corners.allSatisfy({ $0.uv != nil }) ? triangle.corners.map { Point2($0.uv!.x,1-$0.uv!.y) } : fallback
            let center3=average3(positions[0],positions[1],positions[2])
            let centerUV=Point2((uv[0].x+uv[1].x+uv[2].x)/3,(uv[0].y+uv[1].y+uv[2].y)/3)
            for corner in 0..<3 {
                let next=(corner+1)%3,previous=(corner+2)%3
                let physical=[positions[corner],midpoint3(positions[corner],positions[next]),center3,midpoint3(positions[previous],positions[corner])]
                let input=[uv[corner],Point2.interpolate(uv[corner],uv[next],t:0.5),centerUV,Point2.interpolate(uv[previous],uv[corner],t:0.5)]
                let projected=try physical.map { try camera.project($0) }
                guard projected.allSatisfy({ $0 != nil }) else { continue }
                let output=projected.map { Point2($0!.x,$0!.y) }
                // Edge-on triangles have zero screen area and are invisible.
                guard (try? Geometry.validateQuad(output)) != nil else { continue }
                do { try Geometry.validateQuad(input) }
                catch { throw Scene3DError.invalid("triangle \(triangle.index+1) has degenerate texture coordinates") }
                result.append(Surface(name:"OBJ triangle \(triangle.index+1) patch \(corner+1)",mediaID:mediaID,input:input,output:output))
            }
        }
        guard !result.isEmpty else { throw Scene3DError.invalid("no visible nondegenerate triangles inside camera clipping range") }
        return result
    }
}
