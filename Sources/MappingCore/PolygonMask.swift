import Foundation

/// Coordinates belong to one layer. Output-canvas masks remain fixed when the
/// layer's cage, mesh or parent group moves; they never mask adjacent layers.
public enum PolygonMaskSpace: String, Codable, CaseIterable, Sendable {
    case sourceUV, outputCanvas
}

public struct PolygonMaskSettings: Codable, Equatable, Sendable {
    public var space: PolygonMaskSpace
    public var inverted: Bool
    /// Inward smoothstep distance in normalized coordinates of the chosen space.
    public var feather: Double
    public init(space: PolygonMaskSpace = .sourceUV, inverted: Bool = false, feather: Double = 0) {
        self.space=space; self.inverted=inverted; self.feather=feather
    }
}

public enum PolygonMaskGeometry {
    public static func validateVertices(_ vertices: [Point2]) throws {
        guard (3...128).contains(vertices.count), vertices.allSatisfy({
            $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 10000 && abs($0.y) <= 10000
        }) else { throw ProjectError.invalid("a mask needs 3...128 finite vertices within the working range") }
    }

    /// Split the selected closed edge without changing its coverage or feather.
    public static func insertingVertex(in vertices: [Point2], after index: Int) throws -> [Point2] {
        try validateVertices(vertices)
        guard vertices.count < 128, vertices.indices.contains(index) else {
            throw ProjectError.invalid("choose an existing mask edge; at most 128 vertices are supported")
        }
        var result=vertices
        result.insert(Point2.interpolate(vertices[index],vertices[(index+1)%vertices.count],t:0.5),at:index+1)
        return result
    }

    public static func removingVertex(in vertices: [Point2], at index: Int) throws -> [Point2] {
        try validateVertices(vertices)
        guard vertices.count > 3, vertices.indices.contains(index) else {
            throw ProjectError.invalid("a mask needs at least three vertices; use Remove mask to clear it")
        }
        var result=vertices; result.remove(at:index); return result
    }

    public static func validate(_ settings: PolygonMaskSettings) throws {
        guard settings.feather.isFinite, (0...0.5).contains(settings.feather) else {
            throw ProjectError.invalid("mask feather must be finite and within 0...0.5")
        }
    }

    /// Even/odd filling, including concavity and self crossings. Empty masks
    /// pass through, including when inverted. Degenerate segments stay finite.
    public static func alpha(at point: Point2, polygon: [Point2], settings: PolygonMaskSettings) -> Double {
        guard polygon.count >= 3 else { return 1 }
        guard point.x.isFinite, point.y.isFinite else { return 0 }
        let inside=Geometry.contains(point,polygon:polygon)
        var distance=Double.infinity
        for i in polygon.indices {
            let a=polygon[i], b=polygon[(i+1)%polygon.count]
            let dx=b.x-a.x, dy=b.y-a.y, squared=dx*dx+dy*dy
            let t=squared > 0 ? min(1,max(0,((point.x-a.x)*dx+(point.y-a.y)*dy)/squared)) : 0
            distance=min(distance,hypot(point.x-a.x-t*dx,point.y-a.y-t*dy))
        }
        let kept=settings.inverted ? !inside : inside
        guard kept else { return 0 }
        guard settings.feather > 0 else { return 1 }
        let u=min(1,max(0,distance/settings.feather))
        return u*u*(3-2*u)
    }

    /// Different spaces/inversion modes switch the whole mask at the midpoint;
    /// points from unrelated coordinate systems must never morph together.
    static func interpolate(_ a: Surface, _ b: Surface, t: Double, into result: inout Surface) {
        let discrete=t < 0.5 ? a : b
        result.mask=discrete.mask; result.maskSettings=discrete.maskSettings
        if a.mask.count == b.mask.count, a.maskSettings.space == b.maskSettings.space,
           a.maskSettings.inverted == b.maskSettings.inverted {
            result.mask=zip(a.mask,b.mask).map { Point2.interpolate($0,$1,t:t) }
            result.maskSettings.feather=a.maskSettings.feather+(b.maskSettings.feather-a.maskSettings.feather)*t
        }
    }
}
