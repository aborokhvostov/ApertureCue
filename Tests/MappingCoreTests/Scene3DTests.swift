import XCTest
import Foundation
@testable import MappingCore

final class Scene3DTests:XCTestCase {
    func testOBJNegativeIndicesTextureSeamsAndNormals() throws {
        let source="""
        mtllib ../../never-opened.mtl
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        vt 0 0
        vt 1 0
        vt 1 1
        vt 0 1
        vt 0.5 0.5
        vn 0 0 1
        f -4/-5/-1 -3/-4/-1 -2/-3/-1 -1/-2/-1
        f 1/5/1 2/2/1 3/3/1
        """
        let mesh=try OBJMesh.parse(source)
        XCTAssertEqual(mesh.indices.count,9); XCTAssertEqual(mesh.vertices.count,5)
        let originUVs=mesh.vertices.filter { $0.position == Point3(0,0,0) }.compactMap(\.uv)
        XCTAssertTrue(originUVs.contains(Point2(0,0))); XCTAssertTrue(originUVs.contains(Point2(0.5,0.5)))
        XCTAssertTrue(mesh.indices.allSatisfy { Int($0)<mesh.vertices.count })
    }
    func testOBJConcaveTriangulationAreaAndReversedWinding() throws {
        let vertices="""
        v 0 0 0
        v 2 0 0
        v 2 1 0
        v 1 1 0
        v 1 2 0
        v 0 2 0

        """
        for face in ["f 1 2 3 4 5 6","f 6 5 4 3 2 1"] {
            let mesh=try OBJMesh.parse(vertices+face)
            XCTAssertEqual(mesh.indices.count,12)
            var signedArea=0.0
            for i in stride(from:0,to:mesh.indices.count,by:3) {
                let a=mesh.vertices[Int(mesh.indices[i])].position,b=mesh.vertices[Int(mesh.indices[i+1])].position,c=mesh.vertices[Int(mesh.indices[i+2])].position
                let area=((b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x))/2
                XCTAssertGreaterThan(abs(area),1e-12); signedArea += area
            }
            XCTAssertEqual(abs(signedArea),3,accuracy:1e-10)
            XCTAssertEqual(signedArea>0,face.hasPrefix("f 1"))
        }
        let small=try OBJMesh.parse("v 0 0 0\nv 0.0000001 0 0\nv 0 0.0000001 0\nf 1 2 3")
        XCTAssertEqual(small.indices.count,3)
    }
    func testOBJInvalidIndicesDegeneracyAndUnsupportedGeometry() throws {
        let prefix="v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\n"
        for face in ["f 0 1 2","f 1 2 5","f -5 -2 -1","f 1 2 2","f 1 3 2 4","f 1/1 2/1 3/1","f 1//1 2//1 3//1"] {
            XCTAssertThrowsError(try OBJMesh.parse(prefix+face))
        }
        XCTAssertThrowsError(try OBJMesh.parse("v nan 0 0\nf 1 1 1"))
        XCTAssertThrowsError(try OBJMesh.parse(prefix+"l 1 2"))
        XCTAssertThrowsError(try OBJMesh.parse("v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 1\nf 1 2 3 4"))
        XCTAssertThrowsError(try OBJMesh.parse(prefix+"f 1 2 3 \\"))
    }
    func testCameraProjectionClippingAndOrientation() throws {
        let camera=Camera3D(verticalFOV:90,aspect:1,near:0.1,far:10)
        let center=try XCTUnwrap(camera.project(Point3(0,0,0)))
        XCTAssertEqual(center.x,0.5,accuracy:1e-12); XCTAssertEqual(center.y,0.5,accuracy:1e-12); XCTAssertEqual(center.depth,3)
        let right=try XCTUnwrap(camera.project(Point3(3,0,0))),top=try XCTUnwrap(camera.project(Point3(0,3,0)))
        XCTAssertEqual(right.x,1,accuracy:1e-12); XCTAssertEqual(top.y,0,accuracy:1e-12)
        XCTAssertNil(try camera.project(Point3(0,0,2.95))); XCTAssertNil(try camera.project(Point3(0,0,4))); XCTAssertNil(try camera.project(Point3(0,0,-8)))
        let closer=try XCTUnwrap(camera.project(Point3(1,0,1)))
        XCTAssertEqual(closer.x,0.75,accuracy:1e-12)
        var invalid=camera; invalid.up=Point3(0,0,1); XCTAssertThrowsError(try invalid.validate())
        invalid=camera; invalid.verticalFOV=0; XCTAssertThrowsError(try invalid.validate())
        invalid=camera; invalid.far=0.01; XCTAssertThrowsError(try invalid.validate())
    }
    func testProjectionBakeUsesPerspectivePhysicalMidpointsAndUVs() throws {
        let mesh=try OBJMesh.parse("v 0 0 0\nv 1 0 1\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nf 1/1 2/2 3/3")
        let camera=Camera3D(verticalFOV:90,aspect:1)
        let surfaces=try mesh.projectedSurfaces(camera:camera)
        XCTAssertEqual(surfaces.count,3)
        let physicalMidpoint=try XCTUnwrap(camera.project(Point3(0.5,0,0.5)))
        XCTAssertEqual(surfaces[0].output[1].x,physicalMidpoint.x,accuracy:1e-12)
        let a=try XCTUnwrap(camera.project(Point3(0,0,0))),b=try XCTUnwrap(camera.project(Point3(1,0,1)))
        XCTAssertGreaterThan(abs(surfaces[0].output[1].x-(a.x+b.x)/2),0.01)
        XCTAssertEqual(surfaces[0].input[1],Point2(0.5,1))
        let mapping=try Homography.solve(from:surfaces[0].output,to:surfaces[0].input)
        for i in 0..<4 {
            let uv=try mapping.applying(surfaces[0].output[i])
            XCTAssertEqual(uv.x,surfaces[0].input[i].x,accuracy:1e-10)
            XCTAssertEqual(uv.y,surfaces[0].input[i].y,accuracy:1e-10)
        }
        var project=Project(surfaces:surfaces)
        try ProjectStore.validate(project)
        let asset=MediaAsset(name:"Image",path:"texture.png",kind:"image")
        project.assets=[asset]; project.surfaces=try mesh.projectedSurfaces(camera:camera,mediaID:asset.id)
        try ProjectStore.validate(project)
        XCTAssertTrue(project.surfaces.allSatisfy { $0.mediaID == asset.id })
    }
    func testProjectionBakeConcaveFaceDepthSortAndClipping() throws {
        let mesh=try OBJMesh.parse("v 0 0 0\nv 2 0 0\nv 2 1 0\nv 1 1 0\nv 1 2 0\nv 0 2 0\nf 1 2 3 4 5 6")
        XCTAssertEqual(try mesh.projectedSurfaces(camera:Camera3D()).count,12)
        let layers=try OBJMesh.parse("v 0 0 1\nv 1 0 1\nv 0 1 1\nv 0 0 -1\nv 1 0 -1\nv 0 1 -1\nf 1 2 3\nf 4 5 6")
        let surfaces=try layers.projectedSurfaces(camera:Camera3D())
        XCTAssertTrue(surfaces[0].name.contains("triangle 2"))
        XCTAssertTrue(surfaces[3].name.contains("triangle 1"))
        XCTAssertThrowsError(try layers.projectedSurfaces(camera:Camera3D(position:Point3(0,0,0),target:Point3(0,0,1),near:2)))
        XCTAssertThrowsError(try OBJMesh(vertices:layers.vertices,indices:[999,0,1]).projectedSurfaces(camera:Camera3D()))
        XCTAssertThrowsError(try OBJMesh(vertices:layers.vertices,indices:Array(repeating:0,count:4098)).projectedSurfaces(camera:Camera3D()))
    }
}
