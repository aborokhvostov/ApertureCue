import XCTest
import Foundation
@testable import MappingCore

final class BezierWarpTests: XCTestCase {
    /// Independent de Casteljau oracle, not the production Bernstein evaluator.
    private func curve(_ controls: [Point2],_ t: Double) -> Point2 {
        var p=controls
        while p.count>1 {p=zip(p,p.dropFirst()).map {Point2.interpolate($0,$1,t:t)}}
        return p[0]
    }
    private func oracle(_ warp: BezierWarp,_ uv: Point2) -> Point2 {
        let sx=uv.x*Double(warp.columns),sy=uv.y*Double(warp.rows)
        let x=min(warp.columns-1,Int(sx)),y=min(warp.rows-1,Int(sy))
        let u=sx-Double(x),v=sy-Double(y)
        return curve((0..<4).map {j in
            curve((0..<4).map {i in warp.controls[(y*3+j)*warp.controlColumns+x*3+i]},u)
        },v)
    }
    private func project(_ p: Point2,_ h: Homography?) -> Point2 {
        guard let m=h?.values else {return p}
        let w=m[6]*p.x+m[7]*p.y+m[8]
        return Point2((m[0]*p.x+m[1]*p.y+m[2])/w,(m[3]*p.x+m[4]*p.y+m[5])/w)
    }
    private func check(_ warp: BezierWarp,_ h: Homography? = nil,width: Int = 1920,height: Int = 1080) throws {
        let mesh=try warp.tessellated(width:width,height:height,projection:h)
        XCTAssertTrue(mesh.maximumErrorPixels<=0.5)
        XCTAssertEqual(mesh.indices.count,mesh.columns*mesh.rows*6)
        XCTAssertEqual(mesh.vertices.count,(mesh.columns+1)*(mesh.rows+1))
        for y in 0...35 {for x in 0...41 {
            let uv=Point2(Double(x)/41,Double(y)/35),exact=project(oracle(warp,uv),h),actual=try mesh.point(at:uv)
            let error=hypot((actual.x-exact.x)*Double(width),(actual.y-exact.y)*Double(height))
            XCTAssertTrue(error<=mesh.maximumErrorPixels+1e-7,"\(error) > \(mesh.maximumErrorPixels)")
            let evaluated=try warp.point(at:uv,projection:h)
            XCTAssertEqual(evaluated.x,exact.x,accuracy:1e-11)
            XCTAssertEqual(evaluated.y,exact.y,accuracy:1e-11)
        }}
    }

    func testFlatPatchRationalCageAndDenseCurvedPixelBound() throws {
        let flat=try BezierWarp.regular(quad:Point2.unitQuad)
        let mesh=try flat.tessellated(width:1920,height:1080)
        XCTAssertEqual(mesh.columns,1);XCTAssertEqual(mesh.rows,1);XCTAssertEqual(mesh.indices.count,6)
        XCTAssertEqual(try mesh.point(at:Point2(0.32,0.64)),Point2(0.32,0.64))
        var curved=flat
        curved.controls[5]=Point2(0.18,0.04); curved.controls[6]=Point2(0.8,0.24)
        curved.controls[9]=Point2(0.28,0.86); curved.controls[10]=Point2(0.75,0.93)
        try check(curved)
        let h=try Homography(values:[-0.95,0.08,0.98,0.04,0.9,0.02,0.16,-0.08,1])
        try check(curved,h)
        let cage=try Homography.solve(from:Point2.unitQuad,to:[Point2(0.05,0.1),Point2(0.95,0.2),Point2(0.8,0.95),Point2(0.2,0.8)])
        try check(flat,cage)
    }

    func testSharedPatchEdgesIndependentTangentsAndStableInverse() throws {
        var warp=try BezierWarp.regular(quad:Point2.unitQuad,columns:2,rows:1)
        warp.controls[9]=Point2(0.22,0.25);warp.controls[11]=Point2(0.75,0.45)
        warp.controls[10].y=0.2
        let left=try warp.point(at:Point2(0.5-1e-9,0.4)),right=try warp.point(at:Point2(0.5+1e-9,0.4))
        XCTAssertTrue(hypot(left.x-right.x,left.y-right.y)<1e-7)
        XCTAssertEqual(warp.controls[9],Point2(0.22,0.25));XCTAssertEqual(warp.controls[11],Point2(0.75,0.45))
        let mesh=try warp.tessellated(width:1280,height:720)
        XCTAssertEqual(mesh.columns%2,0)
        for y in 0...mesh.rows {
            let uv=Point2(0.5,Double(y)/Double(mesh.rows))
            XCTAssertEqual(mesh.vertices[y*(mesh.columns+1)+mesh.columns/2].output,try warp.point(at:uv))
        }
        for uv in [Point2(0.17,0.23),Point2(0.61,0.72),Point2(0.88,0.13)] {
            let output=try mesh.point(at:uv),inverse=try XCTUnwrap(mesh.localPoint(at:output))
            XCTAssertEqual(inverse.x,uv.x,accuracy:1e-9);XCTAssertEqual(inverse.y,uv.y,accuracy:1e-9)
        }
        try check(warp,width:1280,height:720)
        let refined=try warp.tessellated(width:1280,height:720,minimumSubdivision:32)
        XCTAssertTrue(refined.columns>=64 && refined.rows>=32)
    }

    func testPrecisionBudgetsMalformedDataAndRoundTrip() throws {
        let flat=try BezierWarp.regular(quad:Point2.unitQuad)
        XCTAssertEqual(try JSONDecoder().decode(BezierWarp.self,from:JSONEncoder().encode(flat)),flat)
        XCTAssertThrowsError(try BezierWarp(columns:Int.max,rows:1,controls:[]).validate())
        XCTAssertThrowsError(try BezierWarp.regular(quad:Point2.unitQuad,columns:0))
        var bad=flat;bad.controls[0].x=Double.nan;XCTAssertThrowsError(try bad.validate())
        bad=flat;bad.controls.removeLast();XCTAssertThrowsError(try bad.validate())
        XCTAssertThrowsError(try flat.tessellated(width:0,height:100))
        XCTAssertThrowsError(try flat.tessellated(width:100,height:100,pixelTolerance:0.51))
        XCTAssertThrowsError(try flat.tessellated(width:100,height:100,minimumSubdivision:3))
        XCTAssertThrowsError(try flat.point(at:Point2(-0.01,0.5)))
        let horizon=try Homography(values:[1,0,0,0,1,0,2,0,-1])
        XCTAssertThrowsError(try flat.tessellated(width:100,height:100,projection:horizon))
        var extreme=flat;extreme.controls[5]=Point2(8,8)
        XCTAssertThrowsError(try extreme.tessellated(width:16384,height:16384,maximumTriangles:2))
        XCTAssertThrowsError(try extreme.tessellated(width:16384,height:16384,pixelTolerance:1e-12,maximumTriangles:32))
        let negative=try Homography(values:[-1,0,0,0,-1,0,0,0,-1])
        let mesh=try flat.tessellated(width:100,height:100,projection:negative)
        XCTAssertEqual(try mesh.point(at:Point2(0.3,0.7)),Point2(0.3,0.7))
    }

    func testExplicitMeshLinkPreservesSourceUntilEnabled() throws {
        let output=try Geometry.regularMesh(quad:Point2.insetQuad,columns:2,rows:2)
        let crop=[Point2(0.2,0.3),Point2(0.8,0.3),Point2(0.8,0.7),Point2(0.2,0.7)]
        let input=try Geometry.regularMesh(quad:crop,columns:2,rows:2)
        let target=Point2(output[4].x+0.08,output[4].y-0.08)
        let unlinked=try MeshLinkGeometry.movingOutputVertex(output:output,input:input,index:4,to:target,outputQuad:Point2.insetQuad,inputQuad:crop,linked:false)
        XCTAssertEqual(unlinked.input,input)
        let linked=try MeshLinkGeometry.movingOutputVertex(output:output,input:input,index:4,to:target,outputQuad:Point2.insetQuad,inputQuad:crop,linked:true)
        XCTAssertEqual(linked.input[4].x,input[4].x+0.06,accuracy:1e-12)
        XCTAssertEqual(linked.input[4].y,input[4].y-0.04,accuracy:1e-12)
        for index in input.indices where index != 4 {XCTAssertEqual(linked.input[index],input[index]);XCTAssertEqual(linked.output[index],output[index])}
        XCTAssertThrowsError(try MeshLinkGeometry.movingOutputVertex(output:output,input:[],index:4,to:target,outputQuad:Point2.insetQuad,inputQuad:crop,linked:true))
        XCTAssertThrowsError(try MeshLinkGeometry.movingOutputVertex(output:output,input:input,index:Int.max,to:target,outputQuad:Point2.insetQuad,inputQuad:crop,linked:true))
    }
}
