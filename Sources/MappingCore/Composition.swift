import Foundation

/// A mask is owned by a layer, a group, or the composition. For group masks
/// sourceUV means that group's local plane; global masks require outputCanvas.
public struct CompositionMask: Codable, Equatable, Identifiable, Sendable {
    public var id:UUID
    public var name:String
    public var enabled:Bool
    public var points:[Point2]
    public var curve:BezierMask?
    public var settings:PolygonMaskSettings
    public init(id:UUID=UUID(),name:String="Mask",enabled:Bool=true,points:[Point2]=Point2.insetQuad,
                curve:BezierMask?=nil,settings:PolygonMaskSettings = .init(space:.outputCanvas)) {
        self.id=id;self.name=name;self.enabled=enabled;self.points=points;self.curve=curve;self.settings=settings
    }
    public func polygon(tolerance:Double=0.00025) throws -> [Point2] {
        if let curve {
            let p=try curve.flattened(tolerance:tolerance)
            guard p.count>=3 else {throw ProjectError.invalid("closed curve mask needs three noncollapsed contour samples")}
            return p
        }
        try PolygonMaskGeometry.validateVertices(points); return points
    }
    public func validate() throws {
        guard name.utf8.count<=4096 else { throw ProjectError.invalid("mask name is too long") }
        guard points.count<=128,points.allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x)<=10000 && abs($0.y)<=10000}) else {throw ProjectError.invalid("mask coordinate payload exceeds its working range")}
        try PolygonMaskGeometry.validate(settings)
        _ = try polygon()
    }
}

public enum CompositionPlan {
    public static let maximumMasksPerScope=8
    public static func validateMasks(_ masks:[CompositionMask],global:Bool=false) throws {
        guard masks.count<=maximumMasksPerScope,Set(masks.map(\.id)).count==masks.count else {
            throw ProjectError.invalid("a scope supports at most eight masks with unique IDs")
        }
        for mask in masks {
            try mask.validate()
            if global,mask.settings.space != .outputCanvas { throw ProjectError.invalid("global masks use output-canvas coordinates") }
        }
    }

    /// Isolated groups are single stack items. Requiring contiguous descendant
    /// ranges makes the original back-to-front order explicit and lossless.
    public static func validateStack(surfaces:[Surface],groups:[SurfaceGroup]) throws {
        let surfaces=surfaces.filter(\.enabled)
        let byID=Dictionary(groups.map { ($0.id,$0) },uniquingKeysWith: { a,_ in a })
        for group in groups where group.composites {
            let indices=surfaces.indices.filter { index in
                var cursor=surfaces[index].groupID, visited=Set<UUID>()
                while let id=cursor,visited.insert(id).inserted {
                    if id==group.id { return true };cursor=byID[id]?.parentID
                }
                return false
            }
            if let first=indices.first,let last=indices.last,indices.count != last-first+1 {
                throw ProjectError.invalid("isolated group descendants must be contiguous in layer order; move its layers together first")
            }
        }
    }
}
