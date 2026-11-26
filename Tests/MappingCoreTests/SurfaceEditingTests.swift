import XCTest
import Foundation
@testable import MappingCore

final class SurfaceEditingTests: XCTestCase {
    private func fixture() -> (Project,UUID) {
        let group=SurfaceGroup(transform:Affine2D(a:-0.85,b:0.05,c:0.04,d:0.9,tx:0.9,ty:0.03,px:0.15,py:0.05,pw:1))
        let surface=Surface(input:[Point2(0.1,0.1),Point2(0.9,0.2),Point2(0.8,0.9),Point2(0.2,0.8)],output:[Point2(0.05,0.1),Point2(0.95,0.2),Point2(0.8,0.95),Point2(0.2,0.8)],groupID:group.id)
        return (Project(surfaces:[surface],groups:[group]),surface.id)
    }

    func testWarpCreationNumericActiveControlLinkAndReset() throws {
        let (original,id)=fixture()
        let project=try SurfaceEditing.creatingBezierWarp(surfaceID:id,in:original)
        let before=project.surfaces[0],warp=try XCTUnwrap(before.bezierWarp)
        XCTAssertEqual(before.input,original.surfaces[0].input);XCTAssertEqual(before.output,original.surfaces[0].output)
        let source=try SurfaceSourceMapping(surface:before),base=try Homography.solve(from:Point2.unitQuad,to:before.input)
        for uv in [Point2(0.13,0.24),Point2(0.47,0.62),Point2(0.84,0.71)] {
            XCTAssertEqual(try source.point(at:uv),try base.applying(uv))
        }
        let group=try GroupEngine.worldTransform(for:before.groupID,groups:project.groups)
        let targetRaw=Point2(warp.controls[5].x+0.01,warp.controls[5].y+0.02)
        let world=try group.concatenating(before.warpTransform).applying(targetRaw)
        let edited=try SurfaceEditing.editingWarpControl(surfaceID:id,index:5,world:world,input:false,in:project)
        let moved=try XCTUnwrap(edited.surfaces[0].bezierWarp)
        for index in warp.controls.indices {
            XCTAssertEqual(moved.controls[index].x,index==5 ? targetRaw.x : warp.controls[index].x,accuracy:1e-10)
            XCTAssertEqual(moved.controls[index].y,index==5 ? targetRaw.y : warp.controls[index].y,accuracy:1e-10)
        }
        XCTAssertNil(edited.surfaces[0].inputWarp);XCTAssertEqual(edited.surfaces[0].input,before.input)
        let linked=try SurfaceEditing.settingMeshLink(surfaceID:id,enabled:true,in:project)
        let linkedMove=try SurfaceEditing.editingWarpControl(surfaceID:id,index:5,world:world,input:false,in:linked)
        let input=try XCTUnwrap(linkedMove.surfaces[0].inputWarp)
        XCTAssertEqual(input.controls[5].x,targetRaw.x,accuracy:1e-10);XCTAssertEqual(input.controls[5].y,targetRaw.y,accuracy:1e-10)
        for index in warp.controls.indices where index != 5 {XCTAssertEqual(input.controls[index],warp.controls[index])}
        let reset=try SurfaceEditing.resettingBezierWarp(surfaceID:id,in:linkedMove)
        XCTAssertNil(reset.surfaces[0].bezierWarp);XCTAssertNil(reset.surfaces[0].inputWarp)
        XCTAssertEqual(reset.surfaces[0].output,before.output);XCTAssertEqual(reset.surfaces[0].input,before.input)
    }

    func testWorldTransformPreservesSourceAndLockedCommandsAreAtomic() throws {
        let (base,id)=fixture()
        var project=try SurfaceEditing.creatingBezierWarp(surfaceID:id,in:base)
        project=try SurfaceEditing.preparingInputWarp(surfaceID:id,in:project)
        let before=try GroupEngine.resolve(surfaces:project.surfaces,groups:project.groups)[0]
        let delta=Affine2D.translation(x:0.03,y:-0.02).concatenating(.rotation(degrees:7,aspectRatio:16.0/9.0))
        let transformed=try SurfaceEditing.applyingWorldTransform(surfaceID:id,transform:delta,in:project)
        let after=try GroupEngine.resolve(surfaces:transformed.surfaces,groups:transformed.groups)[0]
        for index in before.output.indices {
            let expected=try delta.applying(before.output[index])
            XCTAssertEqual(after.output[index].x,expected.x,accuracy:1e-10);XCTAssertEqual(after.output[index].y,expected.y,accuracy:1e-10)
        }
        XCTAssertEqual(transformed.surfaces[0].input,project.surfaces[0].input)
        XCTAssertEqual(transformed.surfaces[0].inputWarp,project.surfaces[0].inputWarp)
        XCTAssertEqual(transformed.surfaces[0].inputWarpTransform,project.surfaces[0].inputWarpTransform)
        var locked=project;locked.geometryLockedSurfaceIDs=[id]
        XCTAssertEqual(try SurfaceEditing.creatingBezierWarp(surfaceID:id,in:locked),locked)
        XCTAssertEqual(try SurfaceEditing.resettingBezierWarp(surfaceID:id,in:locked),locked)
        XCTAssertEqual(try SurfaceEditing.settingMeshLink(surfaceID:id,enabled:true,in:locked),locked)
        XCTAssertEqual(try SurfaceEditing.editingWarpControl(surfaceID:id,index:0,world:Point2(.nan,0),input:false,in:locked),locked)
        XCTAssertEqual(try SurfaceEditing.applyingWorldTransform(surfaceID:id,transform:delta,in:locked),locked)
        XCTAssertThrowsError(try SurfaceEditing.editingWarpControl(surfaceID:id,index:Int.max,world:Point2(0,0),input:false,in:project))
    }

    func testFreehandFittingToleranceBudgetsAndCreation() throws {
        let straight=(0..<512).map {Point2(0.1+0.8*Double($0)/511,0.4)}
        XCTAssertEqual(try FreehandPath.fit(points:straight),[straight.first!,straight.last!])
        let smooth=(0...100).map {Point2(0.1+0.8*Double($0)/100,0.5+0.1*sin(Double($0)/100*Double.pi*2))}
        let fitted=try FreehandPath.fit(points:smooth)
        XCTAssertTrue(fitted.count<=32 && fitted.count>2)
        for p in smooth {
            var distance=Double.infinity
            for (a,b) in zip(fitted,fitted.dropFirst()) {
                let aspect=16.0/9.0,dx=(b.x-a.x)*aspect,dy=b.y-a.y,px=(p.x-a.x)*aspect,py=p.y-a.y
                let t=min(1,max(0,(px*dx+py*dy)/(dx*dx+dy*dy)))
                distance=min(distance,hypot(px-t*dx,py-t*dy))
            }
            XCTAssertTrue(distance<=0.001+1e-12)
        }
        let result=try SurfaceEditing.addingFreehand(points:smooth,in:Project())
        XCTAssertEqual(result.project.surfaces[0].id,result.surfaceID)
        XCTAssertEqual(result.project.surfaces[0].shape,.line)
        XCTAssertEqual(result.project.surfaces[0].stroke.nodes.count,fitted.count)
        try ProjectStore.validate(result.project)
        let zigzag=(0..<100).map {Point2(Double($0)/100,$0%2==0 ? 0.1 : 0.9)}
        XCTAssertThrowsError(try FreehandPath.fit(points:zigzag,tolerance:0.0001))
        XCTAssertThrowsError(try FreehandPath.fit(points:Array(repeating:Point2(0.1,0.1),count:10)))
        XCTAssertThrowsError(try FreehandPath.fit(points:straight+[Point2(1,1)]))
        XCTAssertThrowsError(try FreehandPath.fit(points:[Point2(.nan,0),Point2(1,1)]))
    }
}
