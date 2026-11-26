import Foundation

/// Bounded deterministic polyline fitting. The declared metric tolerance is
/// never raised to meet the node budget: an over-complex gesture is rejected.
public enum FreehandPath {
    public static func fit(points: [Point2],tolerance: Double = 0.001,aspectRatio: Double = 16.0/9.0,maximumNodes: Int = 32) throws -> [Point2] {
        guard (2...512).contains(points.count),(2...32).contains(maximumNodes),tolerance.isFinite,tolerance>0,tolerance<=1,
              aspectRatio.isFinite,aspectRatio>0,aspectRatio<=100,
              points.allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x)<=10000 && abs($0.y)<=10000}) else {
            throw ProjectError.invalid("freehand needs 2...512 finite samples, 2...32 nodes and a valid fitting tolerance")
        }
        var clean: [Point2]=[]
        for point in points where clean.last != point {clean.append(point)}
        guard clean.count>=2,zip(clean,clean.dropFirst()).reduce(0,{ $0+hypot(($1.1.x-$1.0.x)*aspectRatio,$1.1.y-$1.0.y) })>1e-9 else {
            throw ProjectError.invalid("freehand gesture has zero length")
        }
        var retained: Set<Int>=[0,clean.count-1],pending=[(0,clean.count-1)]
        while let (first,last)=pending.popLast() {
            guard last>first+1 else {continue}
            var farthest=first,error=0.0
            for index in (first+1)..<last {
                let distance=distance(clean[index],clean[first],clean[last],aspectRatio)
                if distance>error {error=distance;farthest=index}
            }
            if error>tolerance {
                retained.insert(farthest)
                guard retained.count<=maximumNodes else {throw ProjectError.invalid("freehand exceeds its node budget at the requested precision; draw a simpler segment")}
                pending.append((first,farthest));pending.append((farthest,last))
            }
        }
        let result=retained.sorted().map {clean[$0]}
        guard zip(result,result.dropFirst()).reduce(0,{ $0+hypot(($1.1.x-$1.0.x)*aspectRatio,$1.1.y-$1.0.y) })>1e-9 else {
            throw ProjectError.invalid("freehand fitting would collapse the gesture to zero length")
        }
        return result
    }
    private static func distance(_ p: Point2,_ a: Point2,_ b: Point2,_ aspect: Double) -> Double {
        let dx=(b.x-a.x)*aspect,dy=b.y-a.y,px=(p.x-a.x)*aspect,py=p.y-a.y,squared=dx*dx+dy*dy
        let t=squared>0 ? min(1,max(0,(px*dx+py*dy)/squared)) : 0
        return hypot(px-t*dx,py-t*dy)
    }
}
