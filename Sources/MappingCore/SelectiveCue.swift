import Foundation

public enum CueScope:String,Codable,CaseIterable,Sendable { case full,selective }

/// Each case is an atomic recall unit. Geometry includes its coordinate frame;
/// source and shape include the payloads needed to interpret their selectors.
public enum CueParameter:String,Codable,CaseIterable,Sendable {
    case opacity,brightness,gamma,color,feather,blendMode,visibility,source,input,outputGeometry,shape,mask,routing
}

public struct CueBinding:Codable,Equatable,Sendable {
    public var surfaceID:UUID
    public var parameters:[CueParameter]
    public init(surfaceID:UUID,parameters:[CueParameter]) { self.surfaceID=surfaceID; self.parameters=parameters }
}

public enum CueSelection {
    public static func capture(name:String,surfaces:[Surface],bindings:[CueBinding],duration:Double=1,
                               followAfter:Double?=nil,id:UUID=UUID()) throws -> Cue {
        guard Set(surfaces.map(\.id)).count == surfaces.count else { throw ProjectError.invalid("duplicate capture surface IDs") }
        let byID=Dictionary(uniqueKeysWithValues:surfaces.map { ($0.id,$0) })
        let snapshots=try bindings.map { binding -> Surface in
            guard let surface=byID[binding.surfaceID] else { throw ProjectError.invalid("cue capture references nonexistent surface") }
            return surface
        }
        let cue=Cue(id:id,name:name,surfaces:snapshots,duration:duration,followAfter:followAfter,scope:.selective,bindings:bindings)
        try validate(cue)
        return cue
    }

    public static func validate(_ cue:Cue) throws {
        guard cue.name.utf8.count <= 4096 else { throw ProjectError.invalid("cue name is too long") }
        guard cue.duration.isFinite,(0...86400).contains(cue.duration) else { throw ProjectError.invalid("invalid cue duration") }
        if let follow=cue.followAfter { guard follow.isFinite,(0...86400).contains(follow) else { throw ProjectError.invalid("invalid cue follow time") } }
        guard cue.surfaces.count <= 4096,Set(cue.surfaces.map(\.id)).count == cue.surfaces.count else {
            throw ProjectError.invalid("cue surface count or duplicate IDs")
        }
        if cue.scope == .full {
            guard cue.bindings.isEmpty else { throw ProjectError.invalid("full cue cannot contain selective bindings") }
            return
        }
        guard !cue.bindings.isEmpty,cue.bindings.count <= 4096,
              Set(cue.bindings.map(\.surfaceID)).count == cue.bindings.count else {
            throw ProjectError.invalid("selective cue binding count or duplicate targets")
        }
        guard Set(cue.bindings.map(\.surfaceID)) == Set(cue.surfaces.map(\.id)) else {
            throw ProjectError.invalid("selective cue bindings must exactly match its snapshots")
        }
        for binding in cue.bindings {
            guard !binding.parameters.isEmpty,Set(binding.parameters).count == binding.parameters.count else {
                throw ProjectError.invalid("selective cue has empty or duplicate parameters")
            }
        }
    }

    public static func missingTargets(from surfaces:[Surface],cue:Cue) -> [UUID] {
        guard cue.scope == .selective else { return [] }
        let ids=Set(surfaces.map(\.id))
        return cue.bindings.map(\.surfaceID).filter { !ids.contains($0) }
    }

    /// Unselected resource references are dormant snapshot data. Their payloads
    /// remain bounded and structurally valid, but need not still exist in the show.
    /// Call validate first; this helper does not substitute for mask validation.
    public static func validationSurfaces(_ cue:Cue) -> [Surface] {
        guard cue.scope == .selective else { return cue.surfaces }
        let bindings=Dictionary(cue.bindings.map { ($0.surfaceID,Set($0.parameters)) },uniquingKeysWith: { a,_ in a })
        return cue.surfaces.map { surface in
            var copy=surface
            let parameters=bindings[surface.id] ?? []
            if !parameters.contains(.source) { copy.mediaID=nil }
            if !parameters.contains(.routing) { copy.outputID=nil }
            if !parameters.contains(.outputGeometry) { copy.groupID=nil }
            return copy
        }
    }

    /// Merge onto the current layers. A selective cue never restores a deleted
    /// target, changes layer ordering, or replaces current names and IDs.
    public static func destination(from surfaces:[Surface],cue:Cue) throws -> [Surface] {
        try validate(cue)
        guard cue.scope == .selective else { return cue.surfaces }
        let snapshots=Dictionary(uniqueKeysWithValues:cue.surfaces.map { ($0.id,$0) })
        let bindings=Dictionary(uniqueKeysWithValues:cue.bindings.map { ($0.surfaceID,$0.parameters) })
        return surfaces.map { current in
            guard let parameters=bindings[current.id],let snapshot=snapshots[current.id] else { return current }
            var merged=current
            for parameter in parameters { copy(parameter,from:snapshot,to:&merged) }
            return merged
        }
    }

    private static func copy(_ parameter:CueParameter,from b:Surface,to s:inout Surface) {
        switch parameter {
        case .opacity:s.opacity=b.opacity
        case .brightness:s.brightness=b.brightness
        case .gamma:s.gamma=b.gamma
        case .color:s.color=b.color
        case .feather:s.feather=b.feather
        case .blendMode:s.blendMode=b.blendMode
        case .visibility:s.enabled=b.enabled
        case .source:s.mediaID=b.mediaID;s.generator=b.generator
        case .input:s.input=b.input
        case .outputGeometry:s.output=b.output;s.mesh=b.mesh;s.meshColumns=b.meshColumns;s.meshRows=b.meshRows;s.groupID=b.groupID
        case .shape:s.shape=b.shape;s.stroke=b.stroke
        case .mask:s.mask=b.mask
        case .routing:s.outputID=b.outputID
        }
    }

    /// Interpolate only the mask, without the full-scene visibility/opacity fade.
    static func interpolate(_ a:Surface,_ b:Surface,parameters:[CueParameter],t:Double) -> Surface {
        let u=min(1,max(0,t))
        if u <= 0 { return a }; if u >= 1 { return b }
        let discrete=u < 0.5 ? a : b
        var s=a
        func mix(_ x:Double,_ y:Double) -> Double { x+(y-x)*u }
        func points(_ x:[Point2],_ y:[Point2]) -> [Point2] { zip(x,y).map { Point2.interpolate($0,$1,t:u) } }
        for parameter in parameters {
            copy(parameter,from:discrete,to:&s)
            switch parameter {
            case .opacity:s.opacity=mix(a.opacity,b.opacity)
            case .brightness:s.brightness=mix(a.brightness,b.brightness)
            case .gamma:s.gamma=mix(a.gamma,b.gamma)
            case .color:if a.color.count == b.color.count { s.color=zip(a.color,b.color).map(mix) }
            case .feather:s.feather=mix(a.feather,b.feather)
            case .input:
                let candidate=points(a.input,b.input)
                if (try? Geometry.validateQuad(candidate)) != nil { s.input=candidate }
            case .outputGeometry:
                if a.groupID == b.groupID,a.meshColumns == b.meshColumns,a.meshRows == b.meshRows,a.mesh.count == b.mesh.count {
                    let quad=points(a.output,b.output)
                    if (try? Geometry.validateQuad(quad)) != nil { s.output=quad;s.mesh=points(a.mesh,b.mesh) }
                }
            case .shape:
                if a.shape == b.shape,a.shape.isStroke,a.stroke.closed == b.stroke.closed,a.stroke.nodes.count == b.stroke.nodes.count {
                    let nodes=zip(a.stroke.nodes,b.stroke.nodes).map { x,y in
                        StrokeNode(anchor:Point2.interpolate(x.anchor,y.anchor,t:u),
                                   incoming:Point2.interpolate(x.incoming,y.incoming,t:u),
                                   outgoing:Point2.interpolate(x.outgoing,y.outgoing,t:u))
                    }
                    s.stroke=StrokePath(nodes:nodes,width:mix(a.stroke.width,b.stroke.width),closed:a.stroke.closed)
                }
            case .mask:if a.mask.count == b.mask.count { s.mask=points(a.mask,b.mask) }
            case .visibility,.source,.blendMode,.routing:break
            }
        }
        if s.shape.isStroke,(try? StrokeGeometry.samples(surface:s)) == nil {
            // Shape and destination geometry can interact. Fall back together to
            // the valid endpoint frame, still modifying only included fields.
            for parameter in parameters where parameter == .shape || parameter == .outputGeometry {
                copy(parameter,from:discrete,to:&s)
            }
        }
        return s
    }
}
