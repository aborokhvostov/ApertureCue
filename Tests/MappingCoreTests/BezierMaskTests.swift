import XCTest
import Foundation
@testable import MappingCore

final class BezierMaskTests: XCTestCase {
    private func cubic(_ a: Point2,_ b: Point2,_ c: Point2,_ d: Point2,_ t: Double) -> Point2 {
        let u=1-t
        return Point2(u*u*u*a.x+3*u*u*t*b.x+3*u*t*t*c.x+t*t*t*d.x,
                      u*u*u*a.y+3*u*u*t*b.y+3*u*t*t*c.y+t*t*t*d.y)
    }
    private func distance(_ p: Point2,_ polygon: [Point2],scale: Point2=Point2(1,1)) -> Double {
        var best=Double.infinity
        for index in polygon.indices {
            let a=polygon[index],b=polygon[(index+1)%polygon.count]
            let dx=(b.x-a.x)*scale.x,dy=(b.y-a.y)*scale.y,px=(p.x-a.x)*scale.x,py=(p.y-a.y)*scale.y
            let squared=dx*dx+dy*dy,t=squared>0 ? min(1,max(0,(px*dx+py*dy)/squared)) : 0
            best=min(best,hypot(px-dx*t,py-dy*t))
        }
        return best
    }

    func testClosedCurveDenseOracleWindingAndPixelMetric() throws {
        let mask=BezierMask.ellipse,scale=Point2(1920,1080)
        let polygon=try mask.flattened(tolerance:0.5,metricScale:scale)
        XCTAssertTrue(polygon.count>16 && polygon.count<=256)
        for index in mask.nodes.indices {
            let a=mask.nodes[index],b=mask.nodes[(index+1)%mask.nodes.count]
            for sample in 0...500 {
                let p=cubic(a.anchor,a.outgoing,b.incoming,b.anchor,Double(sample)/500)
                XCTAssertTrue(distance(p,polygon,scale:scale)<=0.5+1e-8)
            }
        }
        XCTAssertTrue(try mask.contains(Point2(0.5,0.5)));XCTAssertFalse(try mask.contains(Point2(0.05,0.5)))
        let reversed=BezierMask(nodes:mask.nodes.reversed().map {StrokeNode(anchor:$0.anchor,incoming:$0.outgoing,outgoing:$0.incoming)})
        let reversePolygon=try reversed.flattened()
        for y in 0...20 {for x in 0...20 {
            let p=Point2(Double(x)/20,Double(y)/20)
            XCTAssertEqual(Geometry.contains(p,polygon:try mask.flattened()),Geometry.contains(p,polygon:reversePolygon))
        }}
    }

    func testCubicSplitClosingEdgeHandlesAndNumericAnchor() throws {
        let mask=BezierMask.ellipse,split=try mask.insertingNode(after:3)
        XCTAssertEqual(split.nodes.count,5)
        let a=mask.nodes[3],b=mask.nodes[0]
        for sample in 0...100 {
            let t=Double(sample)/100,exact=cubic(a.anchor,a.outgoing,b.incoming,b.anchor,t),actual: Point2
            if t<=0.5 {actual=cubic(split.nodes[3].anchor,split.nodes[3].outgoing,split.nodes[4].incoming,split.nodes[4].anchor,t*2)}
            else {actual=cubic(split.nodes[4].anchor,split.nodes[4].outgoing,split.nodes[0].incoming,split.nodes[0].anchor,(t-0.5)*2)}
            XCTAssertEqual(actual.x,exact.x,accuracy:1e-12);XCTAssertEqual(actual.y,exact.y,accuracy:1e-12)
        }
        let moved=try mask.movingAnchor(at:1,to:Point2(0.95,0.55))
        XCTAssertEqual(moved.nodes[1].incoming.x-mask.nodes[1].incoming.x,0.05,accuracy:1e-12)
        XCTAssertEqual(moved.nodes[1].outgoing.y-mask.nodes[1].outgoing.y,0.05,accuracy:1e-12)
        XCTAssertEqual(moved.nodes[0],mask.nodes[0]);XCTAssertEqual(moved.nodes[2],mask.nodes[2])
        XCTAssertEqual(try split.removingNode(at:4).nodes.count,4)
        XCTAssertEqual(try JSONDecoder().decode(BezierMask.self,from:JSONEncoder().encode(split)),split)
    }

    func testLoopsCollinearReversalAndPrecisionBudgetsRejectExplicitly() throws {
        let reversal=BezierMask(nodes:[
            StrokeNode(anchor:Point2(0.2,0.2),outgoing:Point2(0.9,0.2)),
            StrokeNode(anchor:Point2(0.3,0.2),incoming:Point2(0.9,0.2)),
            StrokeNode(anchor:Point2(0.2,0.8))
        ])
        let polygon=try reversal.flattened(tolerance:0.001)
        XCTAssertTrue(polygon.contains(where:{$0.x>0.6}))
        var loop=reversal;loop.nodes[1].anchor=loop.nodes[0].anchor;loop.nodes[0].outgoing=Point2(0.9,0.1);loop.nodes[1].incoming=Point2(0.9,0.9)
        let loopPolygon=try loop.flattened(tolerance:0.001)
        XCTAssertTrue(loopPolygon.count>5)
        XCTAssertThrowsError(try BezierMask.ellipse.flattened(tolerance:1e-12,maximumSegments:8))
        XCTAssertThrowsError(try BezierMask.ellipse.flattened(tolerance:1e-12,maximumDepth:0))
        XCTAssertThrowsError(try BezierMask.ellipse.flattened(metricScale:Point2(0,1)))
        XCTAssertThrowsError(try BezierMask(nodes:[]).validate())
        var bad=BezierMask.ellipse;bad.nodes[0].outgoing.x=Double.nan;XCTAssertThrowsError(try bad.validate())
        let triangle=try BezierMask.polygon([Point2(0,0),Point2(1,0),Point2(0,1)])
        XCTAssertThrowsError(try triangle.removingNode(at:0))
        XCTAssertThrowsError(try triangle.insertingNode(after:Int.max))
        XCTAssertThrowsError(try triangle.movingAnchor(at:0,to:Point2(10001,0)))
    }
}
