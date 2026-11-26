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

        // Editing a cage carries a curved lattice instead of deleting it or its
        // independently edited source. A source cage edit must affect the warp.
        let independent=try SurfaceEditing.settingMeshLink(surfaceID:id,enabled:false,in:linkedMove)
        let originalSurface=independent.surfaces[0]
        let oldWorld=try GroupEngine.resolve(surfaces:independent.surfaces,groups:independent.groups)[0]
        let move=Affine2D.translation(x:0.025,y:0.015)
        let newWorldCage=try oldWorld.output.map {try move.applying($0)}
        let cageEdit=try SurfaceEditing.editingCage(surfaceID:id,points:newWorldCage,input:false,in:independent)
        XCTAssertEqual(cageEdit.surfaces[0].bezierWarp,originalSurface.bezierWarp)
        XCTAssertEqual(cageEdit.surfaces[0].inputWarp,originalSurface.inputWarp)
        XCTAssertEqual(cageEdit.surfaces[0].inputWarpTransform,originalSurface.inputWarpTransform)
        for uv in [Point2(0.2,0.3),Point2(0.7,0.6)] {
            XCTAssertEqual(try SurfaceGeometry.sourcePoint(local:uv,surface:cageEdit.surfaces[0]),
                           try SurfaceGeometry.sourcePoint(local:uv,surface:originalSurface))
        }
        let inputMove=Affine2D.translation(x:0.03,y:-0.01)
        let newInput=try originalSurface.input.map {try inputMove.applying($0)}
        let sourceEdit=try SurfaceEditing.editingCage(surfaceID:id,points:newInput,input:true,in:independent)
        XCTAssertEqual(sourceEdit.surfaces[0].output,originalSurface.output)
        XCTAssertEqual(sourceEdit.surfaces[0].warpTransform,originalSurface.warpTransform)
        for uv in [Point2(0.2,0.3),Point2(0.7,0.6)] {
            let expected=try inputMove.applying(SurfaceGeometry.sourcePoint(local:uv,surface:originalSurface))
            let actual=try SurfaceGeometry.sourcePoint(local:uv,surface:sourceEdit.surfaces[0])
            XCTAssertEqual(actual.x,expected.x,accuracy:1e-10);XCTAssertEqual(actual.y,expected.y,accuracy:1e-10)
        }
        let inputToWorld=try Homography.solve(from:linkedMove.surfaces[0].input,to:oldWorld.output)
        let coupled=try SurfaceEditing.editingCage(surfaceID:id,points:newInput,input:true,in:linkedMove)
        let coupledWorld=try GroupEngine.resolve(surfaces:coupled.surfaces,groups:coupled.groups)[0]
        for index in newInput.indices {
            let expected=try inputToWorld.applying(newInput[index])
            XCTAssertEqual(coupledWorld.output[index].x,expected.x,accuracy:1e-10)
            XCTAssertEqual(coupledWorld.output[index].y,expected.y,accuracy:1e-10)
        }
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
        XCTAssertEqual(try SurfaceEditing.editingCage(surfaceID:id,points:[],input:false,in:locked),locked)
        XCTAssertThrowsError(try SurfaceEditing.editingWarpControl(surfaceID:id,index:Int.max,world:Point2(0,0),input:false,in:project))

        var regular=base
        regular.surfaces[0].meshColumns=2;regular.surfaces[0].meshRows=2
        regular.surfaces[0].mesh=try Geometry.regularMesh(quad:regular.surfaces[0].output,columns:2,rows:2)
        regular.surfaces[0].mesh[4].x += 0.025
        regular=try SurfaceEditing.settingMeshLink(surfaceID:id,enabled:true,in:regular)
        regular.surfaces[0].inputMesh[4].y += 0.02
        regular=try SurfaceEditing.settingMeshLink(surfaceID:id,enabled:false,in:regular)
        let regularBefore=regular.surfaces[0]
        let oldResolved=try GroupEngine.resolve(surfaces:regular.surfaces,groups:regular.groups)[0]
        let perspective=Affine2D(a:0.93,b:0.02,c:0.03,d:1.02,tx:0.015,ty:-0.01,px:0.2,py:0.05,pw:1)
        let target=try oldResolved.output.map {try perspective.applying($0)}
        let changed=try SurfaceEditing.editingCage(surfaceID:id,points:target,input:false,in:regular)
        let resolved=try GroupEngine.resolve(surfaces:changed.surfaces,groups:changed.groups)[0]
        XCTAssertFalse(changed.surfaces[0].meshWeights.isEmpty)
        XCTAssertEqual(changed.surfaces[0].inputMesh,regularBefore.inputMesh)
        for uv in [Point2(0.2,0.3),Point2(0.7,0.6)] {
            let expected=try perspective.applying(SurfaceGeometry.outputPoint(local:uv,surface:oldResolved))
            let actual=try SurfaceGeometry.outputPoint(local:uv,surface:resolved)
            XCTAssertEqual(actual.x,expected.x,accuracy:1e-9);XCTAssertEqual(actual.y,expected.y,accuracy:1e-9)
            XCTAssertEqual(try SurfaceGeometry.sourcePoint(local:uv,surface:changed.surfaces[0]),
                           try SurfaceGeometry.sourcePoint(local:uv,surface:regularBefore))
        }
        let sourceShift=Affine2D.translation(x:0.02,y:0.01)
        let shifted=try SurfaceEditing.editingCage(surfaceID:id,points:regularBefore.input.map {try sourceShift.applying($0)},input:true,in:regular)
        XCTAssertEqual(shifted.surfaces[0].output,regularBefore.output)
        for index in regularBefore.inputMesh.indices {
            let expected=try sourceShift.applying(regularBefore.inputMesh[index])
            XCTAssertEqual(shifted.surfaces[0].inputMesh[index].x,expected.x,accuracy:1e-10)
            XCTAssertEqual(shifted.surfaces[0].inputMesh[index].y,expected.y,accuracy:1e-10)
        }
        let worldToInput=try Homography.solve(from:oldResolved.output,to:regularBefore.input)
        let relinked=try SurfaceEditing.settingMeshLink(surfaceID:id,enabled:true,in:regular)
        let linkedCage=try SurfaceEditing.editingCage(surfaceID:id,points:target,input:false,in:relinked)
        for index in target.indices {
            let expected=try worldToInput.applying(target[index])
            XCTAssertEqual(linkedCage.surfaces[0].input[index].x,expected.x,accuracy:1e-10)
            XCTAssertEqual(linkedCage.surfaces[0].input[index].y,expected.y,accuracy:1e-10)
        }
        XCTAssertThrowsError(try SurfaceEditing.editingCage(surfaceID:id,points:Array(repeating:Point2(0.5,0.5),count:4),input:false,in:regular))
        XCTAssertEqual(regular.surfaces[0],regularBefore)
        let rootSurface=Surface(output:Point2.insetQuad)
        let exactCage=[Point2(0.08,0.095),Point2(0.93,0.11),Point2(0.89,0.91),Point2(0.1,0.87)]
        let rootEdit=try SurfaceEditing.editingCage(surfaceID:rootSurface.id,points:exactCage,input:false,in:Project(surfaces:[rootSurface]))
        XCTAssertEqual(rootEdit.surfaces[0].output,exactCage)
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
