import XCTest
import Foundation
@testable import MappingCore

final class SurfaceWarpGeometryTests: XCTestCase {
    func testPerspectiveWeightedRegularMeshPreservesLocalAndSource() throws {
        var surface=Surface(input:[Point2(0.15,0.1),Point2(0.9,0.2),Point2(0.8,0.9),Point2(0.25,0.8)],output:Point2.unitQuad,meshColumns:2,meshRows:2)
        surface.mesh=try Geometry.regularMesh(quad:surface.output,columns:2,rows:2)
        surface.mesh[4]=Point2(0.56,0.42)
        let original=surface,transform=Affine2D(a:-0.9,b:0.08,c:0.05,d:0.9,tx:0.95,ty:0.03,px:0.35,py:-0.1,pw:1)
        let group=SurfaceGroup(transform:transform)
        surface.groupID=group.id
        let resolved=try GroupEngine.resolve(surfaces:[surface],groups:[group])[0]
        let input=try Homography.solve(from:Point2.unitQuad,to:surface.input)
        for uv in [Point2(0.17,0.32),Point2(0.72,0.65),Point2(0.51,0.48)] {
            let old=try SurfaceGeometry.outputPoint(local:uv,surface:original)
            let expected=try transform.applying(old),actual=try SurfaceGeometry.outputPoint(local:uv,surface:resolved)
            XCTAssertEqual(actual.x,expected.x,accuracy:1e-10);XCTAssertEqual(actual.y,expected.y,accuracy:1e-10)
            let local=try SurfaceGeometry.localPoint(output:actual,surface:resolved)
            XCTAssertEqual(local.x,uv.x,accuracy:1e-9);XCTAssertEqual(local.y,uv.y,accuracy:1e-9)
            XCTAssertEqual(try SurfaceGeometry.sourcePoint(local:local,surface:resolved).x,try input.applying(uv).x,accuracy:1e-9)
        }
        XCTAssertFalse(resolved.meshWeights.isEmpty)
    }

    func testInputMeshDeltasKeepExactCropAndOnlySelectedSourceChanges() throws {
        var surface=Surface(input:[Point2(0.1,0.1),Point2(0.9,0.2),Point2(0.7,0.9),Point2(0.25,0.7)],output:Point2.unitQuad,meshColumns:2,meshRows:2)
        surface.mesh=try Geometry.regularMesh(quad:surface.output,columns:2,rows:2)
        surface.inputMesh=try Geometry.regularMesh(quad:surface.input,columns:2,rows:2)
        let base=try Homography.solve(from:Point2.unitQuad,to:surface.input),original=surface
        let mapping=try SurfaceSourceMapping(surface:surface)
        for y in 0...20 {for x in 0...20 {
            let local=Point2(Double(x)/20,Double(y)/20),uv=try mapping.point(at:local),exact=try base.applying(local)
            XCTAssertEqual(uv.x,exact.x,accuracy:1e-12);XCTAssertEqual(uv.y,exact.y,accuracy:1e-12)
        }}
        surface.mesh[4]=Point2(0.3,0.6)
        XCTAssertEqual(try SurfaceGeometry.sourcePoint(local:Point2(0.37,0.42),surface:surface),try SurfaceGeometry.sourcePoint(local:Point2(0.37,0.42),surface:original))
        surface.inputMesh[4].x+=0.07
        let center=try SurfaceGeometry.sourcePoint(local:Point2(0.5,0.5),surface:surface)
        XCTAssertEqual(center.x,try base.applying(Point2(0.5,0.5)).x+0.07,accuracy:1e-12)
        let corner=try SurfaceGeometry.sourcePoint(local:Point2(0,0),surface:surface)
        XCTAssertEqual(corner.x,surface.input[0].x,accuracy:1e-12);XCTAssertEqual(corner.y,surface.input[0].y,accuracy:1e-12)
        var invalid=surface;invalid.inputMesh.removeLast()
        XCTAssertThrowsError(try SurfaceSourceMapping(surface:invalid))
    }

    func testBezierPreparedGridPickingContourAndIndependentInputWarp() throws {
        var surface=Surface(input:[Point2(0.1,0.2),Point2(0.9,0.25),Point2(0.8,0.9),Point2(0.2,0.8)],output:Point2.unitQuad,shape:.triangle)
        var warp=try BezierWarp.regular(quad:Point2.unitQuad)
        warp.controls[5].x-=0.15;warp.controls[6].y+=0.12
        surface.bezierWarp=warp
        surface.warpTransform=Affine2D(a:-0.85,b:0.04,c:0.1,d:0.85,tx:0.9,ty:0.02,px:0.15,py:0.05,pw:1)
        surface.inputWarp=try BezierWarp.regular(quad:Point2.unitQuad)
        let crop=try Homography.solve(from:Point2.unitQuad,to:surface.input)
        surface.inputWarpTransform=Affine2D(a:crop.values[0],b:crop.values[3],c:crop.values[1],d:crop.values[4],tx:crop.values[2],ty:crop.values[5],px:crop.values[6],py:crop.values[7],pw:crop.values[8])
        let tess=try XCTUnwrap(SurfaceWarpGeometry.tessellation(surface:surface,width:1920,height:1080,sourceWidth:1920,sourceHeight:1080))
        for uv in [Point2(0.5,0.5),Point2(0.2,0.8),Point2(0.8,0.8)] {
            let output=try SurfaceGeometry.outputPoint(local:uv,surface:surface,tessellation:tess)
            XCTAssertEqual(output,try tess.point(at:uv))
            let local=try SurfaceGeometry.localPoint(output:output,surface:surface,tessellation:tess)
            XCTAssertEqual(local.x,uv.x,accuracy:1e-8);XCTAssertEqual(local.y,uv.y,accuracy:1e-8)
            XCTAssertTrue(SurfaceGeometry.contains(output:output,surface:surface,tessellation:tess))
            let source=try SurfaceGeometry.sourcePoint(local:uv,surface:surface),exact=try crop.applying(uv)
            XCTAssertEqual(source.x,exact.x,accuracy:1e-10);XCTAssertEqual(source.y,exact.y,accuracy:1e-10)
        }
        let outside=try SurfaceGeometry.outputPoint(local:Point2(0.02,0.02),surface:surface,tessellation:tess)
        XCTAssertFalse(SurfaceGeometry.contains(output:outside,surface:surface,tessellation:tess))
        let contour=try SurfaceGeometry.outputOutline(surface:surface,tessellation:tess)
        XCTAssertTrue(contour.count>3)
        for vertex in surface.triangleVertices {
            let point=try tess.point(at:vertex)
            XCTAssertTrue(contour.contains(where:{hypot($0.x-point.x,$0.y-point.y)<1e-10}))
        }
    }

    func testFoldedBezierChecksEveryPreimageAndLegacyBoundaryRemainsStrict() throws {
        var surface=Surface(output:Point2.unitQuad,shape:.triangle)
        var warp=try BezierWarp.regular(quad:Point2.unitQuad,columns:2,rows:1)
        // Second patch folds over the first; its triangle preimage contains the
        // point while the first patch's geometric triangle preimage does not.
        for y in 0..<4 {for x in 0..<7 {
            let u=Double(x)/3
            warp.controls[y*7+x]=Point2(x<=3 ? u : 1-2*(u-1),Double(y)/3)
        }}
        surface.bezierWarp=warp
        let tess=try XCTUnwrap(SurfaceWarpGeometry.tessellation(surface:surface))
        XCTAssertTrue(SurfaceGeometry.contains(output:Point2(0.4,0.4),surface:surface,tessellation:tess))
        var plain=Surface(output:Point2.unitQuad)
        XCTAssertFalse(SurfaceGeometry.contains(output:Point2(-5e-10,0.5),surface:plain))
        XCTAssertEqual(try SurfaceGeometry.localPoint(output:Point2(-5e-10,0.5),surface:plain),Point2(0,0.5))
        plain.meshColumns=1;plain.meshRows=1;plain.mesh=Point2.unitQuad;plain.meshWeights=[1,0,1,1]
        XCTAssertThrowsError(try SurfaceGeometry.outputPoint(local:Point2(0.5,0.5),surface:plain))
        XCTAssertFalse(SurfaceGeometry.contains(output:Point2(0.5,0.5),surface:plain))
    }
}
