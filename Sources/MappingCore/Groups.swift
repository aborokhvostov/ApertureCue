import Foundation

/// Column-vector affine mapping: x'=a*x+c*y+tx, y'=b*x+d*y+ty.
/// Coefficients retain shear introduced by nested rotation/non-uniform scale.
public struct Affine2D: Codable, Equatable, Sendable {
    public var a:Double, b:Double, c:Double, d:Double, tx:Double, ty:Double
    /// Projective extension of the historical affine API. The default last row
    /// preserves all pre-schema12 transforms exactly.
    public var px:Double, py:Double, pw:Double
    public init(a:Double=1,b:Double=0,c:Double=0,d:Double=1,tx:Double=0,ty:Double=0,
                px:Double=0,py:Double=0,pw:Double=1) {
        self.a=a; self.b=b; self.c=c; self.d=d; self.tx=tx; self.ty=ty
        self.px=px; self.py=py; self.pw=pw
    }
    public init(values:[Double]) throws {
        guard values.count == 9 else { throw GeometryError.invalidPointCount }
        self.init(a:values[0],b:values[3],c:values[1],d:values[4],tx:values[2],ty:values[5],px:values[6],py:values[7],pw:values[8])
        try validate()
    }
    public var values:[Double] { [a,c,tx,b,d,ty,px,py,pw] }
    public static let identity=Affine2D()
    public static func perspective(from:[Point2]=Point2.unitQuad,to:[Point2]) throws -> Affine2D {
        try Affine2D(values:Homography.solve(from:from,to:to).values)
    }
    public func applying(_ p:Point2) throws -> Point2 {
        try Homography(values:values).applying(p)
    }
    /// self * other: the other transform acts first.
    public func concatenating(_ other:Affine2D) -> Affine2D {
        let m=values,n=other.values
        var out=Array(repeating:0.0,count:9)
        for row in 0..<3 { for column in 0..<3 {
            out[row*3+column]=(0..<3).reduce(0) { $0+m[row*3+$1]*n[$1*3+column] }
        } }
        return Affine2D(a:out[0],b:out[3],c:out[1],d:out[4],tx:out[2],ty:out[5],px:out[6],py:out[7],pw:out[8])
    }
    public func inverse() throws -> Affine2D {
        try validate()
        let m=values
        let c=[m[4]*m[8]-m[5]*m[7],m[2]*m[7]-m[1]*m[8],m[1]*m[5]-m[2]*m[4],
               m[5]*m[6]-m[3]*m[8],m[0]*m[8]-m[2]*m[6],m[2]*m[3]-m[0]*m[5],
               m[3]*m[7]-m[4]*m[6],m[1]*m[6]-m[0]*m[7],m[0]*m[4]-m[1]*m[3]]
        let determinant=m[0]*c[0]+m[1]*c[3]+m[2]*c[6]
        let v=c.map { $0/determinant }
        return Affine2D(a:v[0],b:v[3],c:v[1],d:v[4],tx:v[2],ty:v[5],px:v[6],py:v[7],pw:v[8])
    }
    public static func translation(x:Double,y:Double) -> Affine2D { Affine2D(tx:x,ty:y) }
    public static func scale(x:Double,y:Double,around pivot:Point2=Point2(0.5,0.5)) -> Affine2D {
        translation(x:pivot.x,y:pivot.y).concatenating(Affine2D(a:x,d:y)).concatenating(translation(x:-pivot.x,y:-pivot.y))
    }
    public static func rotation(degrees:Double,around pivot:Point2=Point2(0.5,0.5),aspectRatio:Double=1) -> Affine2D {
        let radians=degrees*Double.pi/180, cosine=cos(radians), sine=sin(radians)
        return translation(x:pivot.x,y:pivot.y).concatenating(Affine2D(a:cosine,b:sine*aspectRatio,c:-sine/aspectRatio,d:cosine)).concatenating(translation(x:-pivot.x,y:-pivot.y))
    }
    func validate() throws {
        guard values.allSatisfy({$0.isFinite && abs($0)<=10000}) else { throw ProjectError.invalid("group transform exceeds finite working range") }
        let m=values
        let terms=[m[0]*(m[4]*m[8]-m[5]*m[7]),m[1]*(m[5]*m[6]-m[3]*m[8]),m[2]*(m[3]*m[7]-m[4]*m[6])]
        let determinant=terms.reduce(0,+), scale=terms.map(abs).reduce(0,+)
        guard abs(determinant)>max(1e-30,scale*1e-12) else { throw ProjectError.invalid("group transform is singular or ill-conditioned") }
        if px == 0 && py == 0 {
            let norm=max(abs(a),abs(b),abs(c),abs(d)), det=a*d-b*c
            guard norm>1e-12,abs(pw)>1e-12,abs(det)>max(1e-24,norm*norm*1e-12) else { throw ProjectError.invalid("group transform is singular or ill-conditioned") }
        }
    }
    private enum CodingKeys:String,CodingKey { case a,b,c,d,tx,ty,px,py,pw }
    public init(from decoder:Decoder) throws { try self.init(from:decoder,legacy:false) }
    init(from decoder:Decoder,legacy:Bool) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        self.init(a:try c.decode(Double.self,forKey:.a),b:try c.decode(Double.self,forKey:.b),
                  c:try c.decode(Double.self,forKey:.c),d:try c.decode(Double.self,forKey:.d),
                  tx:try c.decode(Double.self,forKey:.tx),ty:try c.decode(Double.self,forKey:.ty),
                  px:legacy ? 0 : try c.decodeIfPresent(Double.self,forKey:.px) ?? 0,
                  py:legacy ? 0 : try c.decodeIfPresent(Double.self,forKey:.py) ?? 0,
                  pw:legacy ? 1 : try c.decodeIfPresent(Double.self,forKey:.pw) ?? 1)
    }
}

public struct SurfaceGroup: Codable, Equatable, Identifiable, Sendable {
    public var id:UUID
    public var name:String
    public var parentID:UUID?
    public var transform:Affine2D
    public var opacity:Double
    public var enabled:Bool
    public var isolated:Bool = false
    public var blendMode:String = "normal"
    public var masks:[CompositionMask] = []
    public var effects:EffectsSettings = .init()
    public var composites:Bool { isolated || blendMode != "normal" || !masks.isEmpty || effects != .init() }
    public init(id:UUID=UUID(),name:String="Group",parentID:UUID?=nil,transform:Affine2D = .identity,opacity:Double=1,enabled:Bool=true) {
        self.id=id; self.name=name; self.parentID=parentID; self.transform=transform; self.opacity=opacity; self.enabled=enabled
    }
    private enum CodingKeys:String,CodingKey { case id,name,parentID,transform,opacity,enabled,isolated,blendMode,masks,effects }
    public init(from decoder:Decoder) throws { try self.init(from:decoder,legacy:false) }
    init(from decoder:Decoder,legacy:Bool) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        self.init(id:try c.decode(UUID.self,forKey:.id),name:try c.decode(String.self,forKey:.name),
                  parentID:try c.decodeIfPresent(UUID.self,forKey:.parentID),
                  transform:try Affine2D(from:c.superDecoder(forKey:.transform),legacy:legacy),
                  opacity:try c.decode(Double.self,forKey:.opacity),enabled:try c.decode(Bool.self,forKey:.enabled))
        if !legacy {
            isolated=try c.decodeIfPresent(Bool.self,forKey:.isolated) ?? false
            blendMode=try c.decodeIfPresent(String.self,forKey:.blendMode) ?? "normal"
            masks=try c.decodeIfPresent([CompositionMask].self,forKey:.masks) ?? []
            effects=try c.decodeIfPresent(EffectsSettings.self,forKey:.effects) ?? .init()
        }
    }
}

public struct GroupBounds: Equatable, Sendable {
    public let min:Point2, max:Point2
    public var center:Point2 { Point2((min.x+max.x)/2,(min.y+max.y)/2) }
}

/// Non-isolated grouping: geometry and per-surface opacity/visibility inherit
/// through the hierarchy; back-to-front layer order and source UV are unchanged.
public enum GroupEngine {
    private struct State { var transform:Affine2D; var opacity:Double; var enabled:Bool; var layerOpacity:Double }
    private static let root=State(transform:.identity,opacity:1,enabled:true,layerOpacity:1)

    private static func context(_ groups:[SurfaceGroup]) throws -> [UUID:State] {
        guard groups.count<=4096 else { throw ProjectError.invalid("too many groups") }
        var definitions:[UUID:SurfaceGroup]=[:]
        for group in groups {
            guard definitions.updateValue(group,forKey:group.id)==nil else { throw ProjectError.invalid("duplicate group IDs") }
            guard group.name.utf8.count<=4096 else { throw ProjectError.invalid("group name is too long") }
            guard group.opacity.isFinite,(0...1).contains(group.opacity) else { throw ProjectError.invalid("group opacity is outside 0...1") }
            try group.transform.validate()
            try Effects.validate(group.effects);try CompositionPlan.validateMasks(group.masks)
            guard ["normal","add","multiply","screen"].contains(group.blendMode) else { throw ProjectError.invalid("unsupported group blend mode") }
        }
        var result:[UUID:State]=[:]
        for group in groups where result[group.id]==nil {
            var chain:[SurfaceGroup]=[], seen=Set<UUID>(), cursor:UUID?=group.id
            while let id=cursor, result[id]==nil {
                guard let current=definitions[id] else { throw ProjectError.invalid("group references nonexistent parent") }
                guard seen.insert(id).inserted else { throw ProjectError.invalid("group hierarchy contains a cycle") }
                chain.append(current)
                guard chain.count<=64 else { throw ProjectError.invalid("group hierarchy exceeds 64 levels") }
                cursor=current.parentID
            }
            var inherited=cursor.flatMap { result[$0] } ?? root
            // Depth must include an already cached ancestor, not only this chain.
            var ancestor=cursor, depth=chain.count
            while let id=ancestor {
                depth+=1
                guard depth<=64 else { throw ProjectError.invalid("group hierarchy exceeds 64 levels") }
                ancestor=definitions[id]?.parentID
            }
            for item in chain.reversed() {
                inherited=State(transform:inherited.transform.concatenating(item.transform),opacity:inherited.opacity*item.opacity,enabled:inherited.enabled && item.enabled,layerOpacity:inherited.layerOpacity*(item.composites ? 1 : item.opacity))
                try inherited.transform.validate()
                result[item.id]=inherited
            }
        }
        return result
    }
    private static func state(for id:UUID?,context:[UUID:State]) throws -> State {
        guard let id else { return root }
        guard let state=context[id] else { throw ProjectError.invalid("surface references nonexistent group") }
        return state
    }
    private static func geometry(_ surface:Surface,by transform:Affine2D) throws -> Surface {
        // Hierarchy resolution also runs before ProjectStore's surface checks.
        // Treat decoded parallel arrays as untrusted before indexing them here.
        guard surface.meshWeights.isEmpty || (surface.meshWeights.count==surface.mesh.count &&
              surface.meshWeights.allSatisfy({$0.isFinite && $0>1e-12 && $0<=10000})) else {
            throw ProjectError.invalid("invalid projective mesh weights")
        }
        var result=surface
        result.output=try surface.output.map { try transform.applying($0) }
        result.mesh=try surface.mesh.map { try transform.applying($0) }
        if !surface.mesh.isEmpty {
            let w=surface.mesh.enumerated().map { index,p in
                (surface.meshWeights.isEmpty ? 1 : surface.meshWeights[index])*(transform.px*p.x+transform.py*p.y+transform.pw)
            }
            guard w.allSatisfy({$0>1e-12}) || w.allSatisfy({$0 < -1e-12}),let scale=w.map(abs).max(),scale>1e-12 else { throw ProjectError.invalid("group perspective crosses the mesh horizon") }
            let normalized=w.map { abs($0)/scale }
            guard normalized.allSatisfy({$0>1e-12}) else {throw ProjectError.invalid("resolved mesh weights exceed the safe projective precision range")}
            result.meshWeights=normalized.allSatisfy({abs($0-1)<1e-14}) ? [] : normalized
        }
        if let warp=surface.bezierWarp {
            result.warpTransform=transform.concatenating(surface.warpTransform)
            try warp.validate(projection:Homography(values:result.warpTransform.values))
        }
        let weights=surface.output.map { transform.px*$0.x+transform.py*$0.y+transform.pw }
        guard weights.allSatisfy({$0>1e-12}) || weights.allSatisfy({$0 < -1e-12}) else { throw ProjectError.invalid("group perspective crosses its surface horizon") }
        try Geometry.validateQuad(result.output)
        guard (result.output+result.mesh).allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x)<=10000 && abs($0.y)<=10000}) else { throw ProjectError.invalid("resolved group geometry exceeds finite working range") }
        return result
    }
    private static func resolve(_ surfaces:[Surface],context:[UUID:State],composition:Bool=false) throws -> [Surface] {
        try surfaces.map { surface in
            let inherited=try state(for:surface.groupID,context:context)
            var result=try geometry(surface,by:inherited.transform)
            result.opacity *= composition ? inherited.layerOpacity : inherited.opacity; result.enabled = result.enabled && inherited.enabled
            return result
        }
    }
    public static func resolve(surfaces:[Surface],groups:[SurfaceGroup]) throws -> [Surface] {
        try resolve(surfaces,context:context(groups))
    }
    public static func resolveForComposition(surfaces:[Surface],groups:[SurfaceGroup]) throws -> [Surface] {
        try resolve(surfaces,context:context(groups),composition:true)
    }
    public static func worldTransform(for groupID:UUID?,groups:[SurfaceGroup]) throws -> Affine2D {
        try state(for:groupID,context:context(groups)).transform
    }
    /// Validation shares one hierarchy resolution across all saved snapshots.
    public static func validate(_ project:Project) throws {
        let inherited=try context(project.groups)
        guard project.groups.filter(\.composites).count<=16 else {throw ProjectError.invalid("a composition supports at most sixteen isolated groups")}
        try CompositionPlan.validateStack(surfaces:project.surfaces,groups:project.groups)
        _=try resolve(project.surfaces,context:inherited)
        for cue in project.cues {
            try CueSelection.validate(cue)
            if cue.scope == .full {try CompositionPlan.validateStack(surfaces:cue.surfaces,groups:project.groups)}
            _=try resolve(CueSelection.validationSurfaces(cue),context:inherited)
        }
    }
    public static func assign(surfaceID:UUID,to groupID:UUID?,in project:Project) throws -> Project {
        try ProjectStore.validate(project)
        guard let i=project.surfaces.firstIndex(where:{$0.id==surfaceID}) else { throw ProjectError.invalid("surface to assign does not exist") }
        if project.surfaces[i].groupID == groupID { return project }
        let inherited=try context(project.groups)
        let old=try state(for:project.surfaces[i].groupID,context:inherited).transform
        let target=try state(for:groupID,context:inherited).transform
        var candidate=project
        candidate.surfaces[i]=try geometry(candidate.surfaces[i],by:target.inverse().concatenating(old))
        candidate.surfaces[i].groupID=groupID; candidate.surfaces[i].group=""
        try ProjectStore.validate(candidate)
        return candidate
    }
    public static func reparent(groupID:UUID,to parentID:UUID?,in project:Project) throws -> Project {
        try ProjectStore.validate(project)
        guard let i=project.groups.firstIndex(where:{$0.id==groupID}) else { throw ProjectError.invalid("group to reparent does not exist") }
        if project.groups[i].parentID == parentID { return project }
        let inherited=try context(project.groups)
        let old=try state(for:groupID,context:inherited).transform
        let parent=try state(for:parentID,context:inherited).transform
        var candidate=project
        candidate.groups[i].parentID=parentID
        candidate.groups[i].transform=try parent.inverse().concatenating(old)
        try ProjectStore.validate(candidate)
        return candidate
    }
    public static func applyWorldTransform(groupID:UUID,transform:Affine2D,in project:Project) throws -> Project {
        try ProjectStore.validate(project); try transform.validate()
        guard let i=project.groups.firstIndex(where:{$0.id==groupID}) else { throw ProjectError.invalid("group to transform does not exist") }
        if transform == .identity { return project }
        let parent=try worldTransform(for:project.groups[i].parentID,groups:project.groups)
        var candidate=project
        candidate.groups[i].transform=try parent.inverse().concatenating(transform).concatenating(parent).concatenating(project.groups[i].transform)
        try ProjectStore.validate(candidate)
        return candidate
    }
    /// Dissolve one group into its parent while preserving current and cue image
    /// geometry, inherited opacity and visibility. Surfaces/media are not deleted.
    public static func dissolve(groupID:UUID,in project:Project) throws -> Project {
        try ProjectStore.validate(project)
        guard let group=project.groups.first(where:{$0.id==groupID}) else { throw ProjectError.invalid("group to dissolve does not exist") }
        guard !group.composites else { throw ProjectError.invalid("disable isolated composition/masks/FX before dissolving a group") }
        // A partial appearance recall uses whichever frame is current at GO.
        // Include every stored frame that another cue can select; dormant
        // unselected snapshot parents never describe a possible frame.
        var frames=project.surfaces+project.cues.filter { $0.scope == .full }.flatMap(\.surfaces)
        for cue in project.cues where cue.scope == .selective {
            let geometryIDs=Set(cue.bindings.filter { $0.parameters.contains(.outputGeometry) }.map(\.surfaceID))
            frames += cue.surfaces.filter { geometryIDs.contains($0.id) }
        }
        let directIDs=Set(frames.filter { $0.groupID == groupID }.map(\.id))
        let outsideIDs=Set(frames.filter { $0.groupID != groupID }.map(\.id))
        if group.opacity != 1, project.timeline.contains(where: { $0.parameter == "opacity" && directIDs.contains($0.surfaceID) }) {
            throw ProjectError.invalid("cannot dissolve a non-unit-opacity group while a directly assigned surface has an opacity track; remove its track or set group opacity to 1 first")
        }
        for cue in project.cues where cue.scope == .selective {
            let snapshots=Dictionary(uniqueKeysWithValues:cue.surfaces.map { ($0.id,$0) })
            for binding in cue.bindings {
                if binding.parameters.contains(.outputGeometry) {
                    // A cue leaving this frame can expose local appearance just
                    // as a cue entering it can add inherited appearance.
                    if directIDs.contains(binding.surfaceID) || snapshots[binding.surfaceID]?.groupID == groupID {
                        if group.opacity != 1 && !binding.parameters.contains(.opacity) {
                            throw ProjectError.invalid("cannot dissolve a non-unit-opacity group used by a geometry cue without opacity; include opacity or set group opacity to 1 first")
                        }
                        if !group.enabled && !binding.parameters.contains(.visibility) {
                            throw ProjectError.invalid("cannot dissolve a hidden group used by a geometry cue without visibility; include visibility or enable the group first")
                        }
                    }
                } else if directIDs.contains(binding.surfaceID) && outsideIDs.contains(binding.surfaceID) {
                    if group.opacity != 1 && binding.parameters.contains(.opacity) {
                        throw ProjectError.invalid("cannot dissolve a non-unit-opacity group while an appearance-only cue can target both its frame and an outside frame; include output geometry or set group opacity to 1 first")
                    }
                    if !group.enabled && binding.parameters.contains(.visibility) {
                        throw ProjectError.invalid("cannot dissolve a hidden group while an appearance-only cue can target both its frame and an outside frame; include output geometry or enable the group first")
                    }
                }
            }
        }
        var candidate=project
        for i in candidate.groups.indices where candidate.groups[i].parentID==groupID {
            candidate.groups[i].parentID=group.parentID
            candidate.groups[i].transform=group.transform.concatenating(candidate.groups[i].transform)
            candidate.groups[i].opacity *= group.opacity
            candidate.groups[i].enabled = candidate.groups[i].enabled && group.enabled
        }
        func detached(_ surfaces:[Surface]) throws -> [Surface] {
            try surfaces.map { surface in
                guard surface.groupID==groupID else { return surface }
                var result=try geometry(surface,by:group.transform)
                result.groupID=group.parentID; result.group=""
                result.opacity *= group.opacity; result.enabled = result.enabled && group.enabled
                return result
            }
        }
        candidate.surfaces=try detached(candidate.surfaces)
        for i in candidate.cues.indices {
            if candidate.cues[i].scope == .full { candidate.cues[i].surfaces=try detached(candidate.cues[i].surfaces);continue }
            let parameters=Dictionary(uniqueKeysWithValues:candidate.cues[i].bindings.map { ($0.surfaceID,Set($0.parameters)) })
            candidate.cues[i].surfaces=try candidate.cues[i].surfaces.map { surface in
                guard let mask=parameters[surface.id] else { return surface }
                if !mask.contains(.outputGeometry) {
                    // Without a recalled frame, appearance is evaluated in the
                    // current target's frame. The guard above ensures every
                    // stored possible frame agrees on direct membership.
                    guard directIDs.contains(surface.id) else { return surface }
                    var result=surface
                    if mask.contains(.opacity) { result.opacity *= group.opacity }
                    if mask.contains(.visibility) { result.enabled = result.enabled && group.enabled }
                    return result
                }
                guard surface.groupID == groupID else { return surface }
                var result=try geometry(surface,by:group.transform)
                result.groupID=group.parentID
                if mask.contains(.opacity) { result.opacity *= group.opacity }
                if mask.contains(.visibility) { result.enabled = result.enabled && group.enabled }
                return result
            }
        }
        candidate.groups.removeAll { $0.id==groupID }
        try ProjectStore.validate(candidate)
        return candidate
    }
    public static func bounds(for groupID:UUID,in project:Project) throws -> GroupBounds? {
        let inherited=try context(project.groups)
        _=try state(for:groupID,context:inherited)
        let definitions=Dictionary(uniqueKeysWithValues:project.groups.map { ($0.id,$0) })
        let members=project.surfaces.filter { surface in
            var cursor=surface.groupID
            while let id=cursor { if id==groupID { return true }; cursor=definitions[id]?.parentID }
            return false
        }
        let points=try resolve(members,context:inherited).flatMap { $0.output+$0.mesh }
        guard !points.isEmpty else { return nil }
        return GroupBounds(min:Point2(points.map(\.x).min()!,points.map(\.y).min()!),max:Point2(points.map(\.x).max()!,points.map(\.y).max()!))
    }
    /// Legacy label equality meant shared visibility, so one root group per exact
    /// nonempty label preserves that membership across surfaces and cue snapshots.
    public static func migrateLegacyLabels(_ project:Project) -> Project {
        var result=project
        // Groups/groupID were not defined before schema 3; ignore extension data.
        result.groups=[]
        var labels:[String:UUID]=[:]
        func converted(_ surfaces:[Surface]) -> [Surface] {
            surfaces.map { surface in
                var updated=surface; updated.groupID=nil
                if !surface.group.isEmpty {
                    let id:UUID
                    if let existing=labels[surface.group] { id=existing }
                    else { id=UUID(); labels[surface.group]=id; result.groups.append(SurfaceGroup(id:id,name:surface.group)) }
                    updated.groupID=id
                }
                updated.group=""
                return updated
            }
        }
        result.surfaces=converted(project.surfaces)
        for i in result.cues.indices { result.cues[i].surfaces=converted(project.cues[i].surfaces) }
        return result
    }
}
