import Foundation

/// Column-vector affine mapping: x'=a*x+c*y+tx, y'=b*x+d*y+ty.
/// Coefficients retain shear introduced by nested rotation/non-uniform scale.
public struct Affine2D: Codable, Equatable, Sendable {
    public var a:Double, b:Double, c:Double, d:Double, tx:Double, ty:Double
    public init(a:Double=1,b:Double=0,c:Double=0,d:Double=1,tx:Double=0,ty:Double=0) {
        self.a=a; self.b=b; self.c=c; self.d=d; self.tx=tx; self.ty=ty
    }
    public static let identity=Affine2D()
    public func applying(_ p:Point2) throws -> Point2 {
        let q=Point2(a*p.x+c*p.y+tx,b*p.x+d*p.y+ty)
        guard p.x.isFinite,p.y.isFinite,q.x.isFinite,q.y.isFinite else { throw GeometryError.nonFinite }
        return q
    }
    /// self * other: the other transform acts first.
    public func concatenating(_ other:Affine2D) -> Affine2D {
        Affine2D(a:a*other.a+c*other.b,b:b*other.a+d*other.b,
                 c:a*other.c+c*other.d,d:b*other.c+d*other.d,
                 tx:a*other.tx+c*other.ty+tx,ty:b*other.tx+d*other.ty+ty)
    }
    public func inverse() throws -> Affine2D {
        try validate()
        let determinant=a*d-b*c
        return Affine2D(a:d/determinant,b:-b/determinant,c:-c/determinant,d:a/determinant,
                        tx:(c*ty-d*tx)/determinant,ty:(b*tx-a*ty)/determinant)
    }
    public static func translation(x:Double,y:Double) -> Affine2D { Affine2D(tx:x,ty:y) }
    public static func scale(x:Double,y:Double,around pivot:Point2=Point2(0.5,0.5)) -> Affine2D {
        translation(x:pivot.x,y:pivot.y).concatenating(Affine2D(a:x,d:y)).concatenating(translation(x:-pivot.x,y:-pivot.y))
    }
    /// Positive angles turn clockwise in y-down coordinates. aspectRatio is the
    /// canvas width/height; 1 means the normalized unit plane.
    public static func rotation(degrees:Double,around pivot:Point2=Point2(0.5,0.5),aspectRatio:Double=1) -> Affine2D {
        let radians=degrees*Double.pi/180, cosine=cos(radians), sine=sin(radians)
        let rotation=Affine2D(a:cosine,b:sine*aspectRatio,c:-sine/aspectRatio,d:cosine)
        return translation(x:pivot.x,y:pivot.y).concatenating(rotation).concatenating(translation(x:-pivot.x,y:-pivot.y))
    }
    fileprivate func validate() throws {
        guard [a,b,c,d,tx,ty].allSatisfy({$0.isFinite && abs($0)<=10000}) else { throw ProjectError.invalid("group transform exceeds finite working range") }
        let norm=max(abs(a),abs(b),abs(c),abs(d)), determinant=a*d-b*c
        guard norm>1e-12, abs(determinant)>max(1e-24,norm*norm*1e-12) else { throw ProjectError.invalid("group transform is singular or ill-conditioned") }
    }
}

public struct SurfaceGroup: Codable, Equatable, Identifiable, Sendable {
    public var id:UUID
    public var name:String
    public var parentID:UUID?
    public var transform:Affine2D
    public var opacity:Double
    public var enabled:Bool
    public init(id:UUID=UUID(),name:String="Group",parentID:UUID?=nil,transform:Affine2D = .identity,opacity:Double=1,enabled:Bool=true) {
        self.id=id; self.name=name; self.parentID=parentID; self.transform=transform; self.opacity=opacity; self.enabled=enabled
    }
}

public struct GroupBounds: Equatable, Sendable {
    public let min:Point2, max:Point2
    public var center:Point2 { Point2((min.x+max.x)/2,(min.y+max.y)/2) }
}

/// Non-isolated grouping: geometry and per-surface opacity/visibility inherit
/// through the hierarchy; back-to-front layer order and source UV are unchanged.
public enum GroupEngine {
    private struct State { var transform:Affine2D; var opacity:Double; var enabled:Bool }
    private static let root=State(transform:.identity,opacity:1,enabled:true)

    private static func context(_ groups:[SurfaceGroup]) throws -> [UUID:State] {
        guard groups.count<=4096 else { throw ProjectError.invalid("too many groups") }
        var definitions:[UUID:SurfaceGroup]=[:]
        for group in groups {
            guard definitions.updateValue(group,forKey:group.id)==nil else { throw ProjectError.invalid("duplicate group IDs") }
            guard group.name.utf8.count<=4096 else { throw ProjectError.invalid("group name is too long") }
            guard group.opacity.isFinite,(0...1).contains(group.opacity) else { throw ProjectError.invalid("group opacity is outside 0...1") }
            try group.transform.validate()
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
                inherited=State(transform:inherited.transform.concatenating(item.transform),opacity:inherited.opacity*item.opacity,enabled:inherited.enabled && item.enabled)
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
        var result=surface
        result.output=try surface.output.map { try transform.applying($0) }
        result.mesh=try surface.mesh.map { try transform.applying($0) }
        try Geometry.validateQuad(result.output)
        guard (result.output+result.mesh).allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x)<=10000 && abs($0.y)<=10000}) else { throw ProjectError.invalid("resolved group geometry exceeds finite working range") }
        return result
    }
    private static func resolve(_ surfaces:[Surface],context:[UUID:State]) throws -> [Surface] {
        try surfaces.map { surface in
            let inherited=try state(for:surface.groupID,context:context)
            var result=try geometry(surface,by:inherited.transform)
            result.opacity *= inherited.opacity; result.enabled = result.enabled && inherited.enabled
            return result
        }
    }
    public static func resolve(surfaces:[Surface],groups:[SurfaceGroup]) throws -> [Surface] {
        try resolve(surfaces,context:context(groups))
    }
    public static func worldTransform(for groupID:UUID?,groups:[SurfaceGroup]) throws -> Affine2D {
        try state(for:groupID,context:context(groups)).transform
    }
    /// Validation shares one hierarchy resolution across all saved snapshots.
    public static func validate(_ project:Project) throws {
        let inherited=try context(project.groups)
        _=try resolve(project.surfaces,context:inherited)
        for cue in project.cues {
            try CueSelection.validate(cue)
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
