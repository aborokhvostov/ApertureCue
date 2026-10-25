import Foundation

/// Coordinates use a top-left origin and downward-positive y in both input and output spaces.
public struct Point2: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let unitQuad = [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)]
    public static let insetQuad = [Point2(0.1, 0.1), Point2(0.9, 0.1), Point2(0.9, 0.9), Point2(0.1, 0.9)]
    public static func interpolate(_ a: Point2, _ b: Point2, t: Double) -> Point2 {
        Point2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    }
}

public enum GeometryError: Error, LocalizedError, Equatable {
    case invalidPointCount
    case nonFinite
    case degenerateQuad
    case nonConvexQuad
    case singularTransform
    case pointAtInfinity
    public var errorDescription: String? {
        switch self {
        case .invalidPointCount: return "A quadrilateral requires exactly four points."
        case .nonFinite: return "Geometry contains a non-finite coordinate."
        case .degenerateQuad: return "The quadrilateral has zero area or a collapsed edge."
        case .nonConvexQuad: return "The quadrilateral is concave or self-intersecting."
        case .singularTransform: return "The perspective transformation is singular."
        case .pointAtInfinity: return "The transformed point lies at infinity."
        }
    }
}

public enum Geometry {
    public static func validateQuad(_ points: [Point2]) throws {
        guard points.count == 4 else { throw GeometryError.invalidPointCount }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw GeometryError.nonFinite }
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let scale = max(maxX - minX, maxY - minY)
        guard scale > 1e-12 else { throw GeometryError.degenerateQuad }
        let epsilon = max(1e-18, scale * scale * 1e-10)
        var positive: Bool?
        for i in 0..<4 {
            let a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard abs(cross) > epsilon else { throw GeometryError.degenerateQuad }
            if let previous = positive, previous != (cross > 0) { throw GeometryError.nonConvexQuad }
            positive = cross > 0
        }
    }

    /// The even/odd rule supports concave masks. Polygon boundary is included.
    public static func contains(_ point: Point2, polygon: [Point2]) -> Bool {
        guard polygon.count >= 3, point.x.isFinite, point.y.isFinite else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[j], b = polygon[i]
            let cross = (point.x-a.x)*(b.y-a.y) - (point.y-a.y)*(b.x-a.x)
            if abs(cross) < 1e-10 && point.x >= min(a.x,b.x)-1e-10 && point.x <= max(a.x,b.x)+1e-10 && point.y >= min(a.y,b.y)-1e-10 && point.y <= max(a.y,b.y)+1e-10 { return true }
            if (a.y > point.y) != (b.y > point.y) {
                if point.x < (b.x-a.x)*(point.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    public static func regularMesh(quad: [Point2], columns: Int, rows: Int) throws -> [Point2] {
        try validateQuad(quad)
        guard columns >= 1, rows >= 1, columns <= 64, rows <= 64 else { throw GeometryError.invalidPointCount }
        let h = try Homography.solve(from: Point2.unitQuad, to: quad)
        return try (0...rows).flatMap { row in
            try (0...columns).map { column in
                try h.applying(Point2(Double(column)/Double(columns), Double(row)/Double(rows)))
            }
        }
    }
}

public struct Homography: Equatable, Sendable {
    /// Row-major projective matrix. The final coefficient is not required to equal one.
    public let values: [Double]
    public init(values: [Double]) throws {
        guard values.count == 9 else { throw GeometryError.invalidPointCount }
        guard values.allSatisfy(\.isFinite) else { throw GeometryError.nonFinite }
        self.values = values
    }

    public static func solve(from: [Point2], to: [Point2]) throws -> Homography {
        try Geometry.validateQuad(from); try Geometry.validateQuad(to)
        // Normalize around the centroid. This keeps small/translated quads well conditioned
        // and permits a valid final transform whose bottom-right coefficient is zero.
        let sourceCenter = Point2(from.map(\.x).reduce(0,+)/4,from.map(\.y).reduce(0,+)/4)
        let targetCenter = Point2(to.map(\.x).reduce(0,+)/4,to.map(\.y).reduce(0,+)/4)
        let sourceScale = from.map { hypot($0.x-sourceCenter.x,$0.y-sourceCenter.y) }.max()!
        let targetScale = to.map { hypot($0.x-targetCenter.x,$0.y-targetCenter.y) }.max()!
        let normalizedFrom = from.map { Point2(($0.x-sourceCenter.x)/sourceScale,($0.y-sourceCenter.y)/sourceScale) }
        let normalizedTo = to.map { Point2(($0.x-targetCenter.x)/targetScale,($0.y-targetCenter.y)/targetScale) }
        // Four two-dimensional correspondences supply eight linear equations.
        var a = Array(repeating: Array(repeating: 0.0, count: 9), count: 8)
        for i in 0..<4 {
            let x = normalizedFrom[i].x, y = normalizedFrom[i].y, u = normalizedTo[i].x, v = normalizedTo[i].y
            a[2*i] = [x,y,1,0,0,0,-u*x,-u*y,u]
            a[2*i+1] = [0,0,0,x,y,1,-v*x,-v*y,v]
        }
        for column in 0..<8 {
            let pivot = (column..<8).max { abs(a[$0][column]) < abs(a[$1][column]) }!
            guard abs(a[pivot][column]) > 1e-12 else { throw GeometryError.singularTransform }
            if pivot != column { a.swapAt(pivot, column) }
            let divisor = a[column][column]
            for j in column..<9 { a[column][j] /= divisor }
            for row in 0..<8 where row != column {
                let factor = a[row][column]
                for j in column..<9 { a[row][j] -= factor * a[column][j] }
            }
        }
        func multiply(_ l:[Double],_ r:[Double]) -> [Double] {
            var result=Array(repeating:0.0,count:9)
            for row in 0..<3 { for col in 0..<3 { for k in 0..<3 { result[row*3+col] += l[row*3+k]*r[k*3+col] } } }
            return result
        }
        let sourceNormalization = [1/sourceScale,0,-sourceCenter.x/sourceScale,0,1/sourceScale,-sourceCenter.y/sourceScale,0,0,1]
        let targetDenormalization = [targetScale,0,targetCenter.x,0,targetScale,targetCenter.y,0,0,1]
        let normalizedMatrix = (0..<8).map { a[$0][8] } + [1]
        var matrix = multiply(targetDenormalization,multiply(normalizedMatrix,sourceNormalization))
        // A projective matrix is defined only up to a common scale.
        let scale = abs(matrix[8]) > 1e-10 ? matrix[8] : matrix.map(abs).max()!
        matrix = matrix.map { $0/scale }
        let result = try Homography(values:matrix)
        // Reject inconsistent/numerically unstable solutions before they reach the renderer.
        for i in 0..<4 {
            let mapped = try result.applying(from[i])
            guard hypot(mapped.x-to[i].x, mapped.y-to[i].y) < 1e-6 * max(1, abs(to[i].x), abs(to[i].y)) else { throw GeometryError.singularTransform }
        }
        return result
    }

    public func applying(_ point: Point2) throws -> Point2 {
        guard point.x.isFinite && point.y.isFinite else { throw GeometryError.nonFinite }
        let m = values
        let denominator = m[6]*point.x + m[7]*point.y + m[8]
        guard abs(denominator) > 1e-12 else { throw GeometryError.pointAtInfinity }
        let x = (m[0]*point.x+m[1]*point.y+m[2])/denominator
        let y = (m[3]*point.x+m[4]*point.y+m[5])/denominator
        guard x.isFinite && y.isFinite else { throw GeometryError.nonFinite }
        return Point2(x,y)
    }

    public func inverse() throws -> Homography {
        let m = values
        let c = [m[4]*m[8]-m[5]*m[7], m[2]*m[7]-m[1]*m[8], m[1]*m[5]-m[2]*m[4],
                 m[5]*m[6]-m[3]*m[8], m[0]*m[8]-m[2]*m[6], m[2]*m[3]-m[0]*m[5],
                 m[3]*m[7]-m[4]*m[6], m[1]*m[6]-m[0]*m[7], m[0]*m[4]-m[1]*m[3]]
        let determinant = m[0]*c[0] + m[1]*c[3] + m[2]*c[6]
        guard abs(determinant) > 1e-12 else { throw GeometryError.singularTransform }
        return try Homography(values: c.map { $0/determinant })
    }
}
