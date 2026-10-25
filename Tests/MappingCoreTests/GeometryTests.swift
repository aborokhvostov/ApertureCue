import XCTest
import Foundation
@testable import MappingCore

final class GeometryTests: XCTestCase {
    func testProjectiveCornerAndInteriorMapping() throws {
        let target=[Point2(0.1,0.2),Point2(0.9,0.1),Point2(0.75,0.95),Point2(0.25,0.8)]
        let h=try Homography.solve(from:Point2.unitQuad,to:target)
        for i in 0..<4 {
            let p=try h.applying(Point2.unitQuad[i])
            XCTAssertEqual(p.x,target[i].x,accuracy:1e-10); XCTAssertEqual(p.y,target[i].y,accuracy:1e-10)
        }
        let inverse=try h.inverse()
        for row in 0...10 {
            for col in 0...10 {
                let p=Point2(Double(col)/10,Double(row)/10)
                let restored=try inverse.applying(h.applying(p))
                XCTAssertEqual(restored.x,p.x,accuracy:1e-9); XCTAssertEqual(restored.y,p.y,accuracy:1e-9)
            }
        }
        // A project's center is the intersection of its diagonals, not a bilinear average.
        let center=try h.applying(Point2(0.5,0.5))
        let average=Point2(target.map(\.x).reduce(0,+)/4,target.map(\.y).reduce(0,+)/4)
        XCTAssertGreaterThan(hypot(center.x-average.x,center.y-average.y),0.01)
    }

    func testInputCropIndependentOfOutput() throws {
        let crop=[Point2(0.2,0.3),Point2(0.8,0.3),Point2(0.8,0.7),Point2(0.2,0.7)]
        let h=try Homography.solve(from:Point2.insetQuad,to:crop)
        let center=try h.applying(Point2(0.5,0.5))
        XCTAssertEqual(center.x,0.5,accuracy:1e-12); XCTAssertEqual(center.y,0.5,accuracy:1e-12)
        let topLeft=try h.applying(Point2.insetQuad[0])
        XCTAssertEqual(topLeft.x,0.2,accuracy:1e-12); XCTAssertEqual(topLeft.y,0.3,accuracy:1e-12)
        // Valid transforms need not admit h22=1 before coordinate normalization.
        let source=[Point2(1,1),Point2(2,1),Point2(2,2),Point2(1,2)]
        let target=[Point2(2,1),Point2(1.5,0.5),Point2(1.5,1),Point2(2,2)]
        let projective=try Homography.solve(from:source,to:target)
        let interior=try projective.applying(Point2(1.5,1.5))
        XCTAssertEqual(interior.x,5.0/3.0,accuracy:1e-10)
        XCTAssertEqual(interior.y,1,accuracy:1e-10)
    }

    func testDegenerateAndSelfCrossingQuadsRejected() {
        XCTAssertThrowsError(try Geometry.validateQuad([Point2(0,0),Point2(1,0),Point2(1,0),Point2(0,1)]))
        XCTAssertThrowsError(try Geometry.validateQuad([Point2(0,0),Point2(1,1),Point2(1,0),Point2(0,1)]))
        XCTAssertThrowsError(try Geometry.validateQuad([Point2(0,0),Point2(1,0),Point2(0.3,0.2),Point2(0,1)]))
        XCTAssertThrowsError(try Geometry.validateQuad([Point2(.nan,0),Point2(1,0),Point2(1,1),Point2(0,1)]))
        XCTAssertThrowsError(try Homography(values:[1,0,0,0,0,0,0,0,0]).inverse())
        XCTAssertThrowsError(try Homography(values:[1,0,0,0,1,0,0,0,0]).applying(Point2(1,1)))
    }

    func testClockwiseAndCounterclockwiseAccepted() throws {
        try Geometry.validateQuad(Point2.unitQuad)
        try Geometry.validateQuad(Point2.unitQuad.reversed())
    }

    func testProjectiveRegularMesh() throws {
        let mesh=try Geometry.regularMesh(quad:Point2.insetQuad,columns:4,rows:3)
        XCTAssertEqual(mesh.count,20)
        XCTAssertEqual(mesh.first!.x,0.1,accuracy:1e-12)
        XCTAssertEqual(mesh.first!.y,0.1,accuracy:1e-12)
        XCTAssertEqual(mesh.last!.x,0.9,accuracy:1e-12)
        XCTAssertEqual(mesh.last!.y,0.9,accuracy:1e-12)
        XCTAssertThrowsError(try Geometry.regularMesh(quad:Point2.unitQuad,columns:100000,rows:1))
    }

    func testConcaveMaskAndBoundary() {
        let polygon=[Point2(0,0),Point2(1,0),Point2(1,0.4),Point2(0.4,0.4),Point2(0.4,1),Point2(0,1)]
        XCTAssertTrue(Geometry.contains(Point2(0.2,0.9),polygon:polygon))
        XCTAssertTrue(Geometry.contains(Point2(0.4,0.4),polygon:polygon))
        XCTAssertFalse(Geometry.contains(Point2(0.9,0.9),polygon:polygon))
        XCTAssertFalse(Geometry.contains(Point2(-0.1,0.1),polygon:polygon))
    }
}
