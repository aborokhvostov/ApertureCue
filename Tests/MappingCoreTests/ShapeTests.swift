import XCTest
import Foundation
@testable import MappingCore

final class ShapeTests: XCTestCase {
    private var scratch: URL!
    override func setUpWithError() throws {
        scratch=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueShapes-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:scratch) }

    func testCustomTrianglePersistenceMigrationAndSelectiveCue() throws {
        let vertices = [Point2(0.1,0.1), Point2(0.8,0.1), Point2(0.1,0.7)]
        let shape = Surface(shape:.triangle,triangleVertices:vertices)
        let full = Cue(name:"Triangle",surfaces:[shape])
        let selected = try CueSelection.capture(name:"Triangle shape",surfaces:[shape],
            bindings:[CueBinding(surfaceID:shape.id,parameters:[.shape])])
        let url = scratch.appendingPathComponent("triangle.aperturecue.json")
        let current = Project(surfaces:[shape],cues:[full,selected],geometryLockedSurfaceIDs:[shape.id])
        try ProjectStore.save(current,to:url)
        XCTAssertEqual(try ProjectStore.load(from:url),current)

        var legacy = current
        legacy.version = 8
        let data = try JSONEncoder().encode(legacy)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        var layers = try XCTUnwrap(root["surfaces"] as? [[String:Any]])
        layers[0]["triangleVertices"] = "undefined"
        root["surfaces"] = layers
        var cues = try XCTUnwrap(root["cues"] as? [[String:Any]])
        for i in cues.indices { cues[i]["surfaces"] = layers }
        root["cues"] = cues
        try JSONSerialization.data(withJSONObject:root).write(to:url)
        let migrated = try ProjectStore.load(from:url)
        XCTAssertEqual(migrated.surfaces[0].triangleVertices,TriangleGeometry.canonical)
        XCTAssertTrue(migrated.cues.allSatisfy { $0.surfaces[0].triangleVertices == TriangleGeometry.canonical })
        XCTAssertEqual(migrated.geometryLockedSurfaceIDs,[shape.id])
        root["version"] = Project.currentVersion
        try JSONSerialization.data(withJSONObject:root).write(to:url)
        XCTAssertThrowsError(try ProjectStore.load(from:url))

        var base = shape
        base.triangleVertices = TriangleGeometry.canonical
        base.input = Point2.insetQuad
        base.output = Point2.unitQuad
        let recalled = try XCTUnwrap(CueSelection.destination(from:[base],cue:selected).first)
        XCTAssertEqual(recalled.triangleVertices,vertices)
        XCTAssertEqual(recalled.input,base.input)
        XCTAssertEqual(recalled.output,base.output)
        let engine = CueEngine()
        for cue in [full,selected] {
            engine.begin(from:[base],cue:cue,at:0)
            XCTAssertEqual(engine.sample(at:0.49)?.first?.triangleVertices,TriangleGeometry.canonical)
            XCTAssertEqual(engine.sample(at:0.5)?.first?.triangleVertices,vertices)
        }
    }

    func testCustomTriangleWindingProjectionAndInvalidVertices() throws {
        let vertices = [Point2(0.1,0.1), Point2(0.8,0.1), Point2(0.1,0.7)]
        var surface = Surface(shape:.triangle,triangleVertices:vertices)
        let inside = try SurfaceGeometry.outputPoint(local:Point2(0.2,0.2),surface:surface)
        let outside = try SurfaceGeometry.outputPoint(local:Point2(0.6,0.65),surface:surface)
        for winding in [vertices,Array(vertices.reversed())] {
            surface.triangleVertices = winding
            XCTAssertTrue(SurfaceGeometry.contains(output:inside,surface:surface))
            XCTAssertFalse(SurfaceGeometry.contains(output:outside,surface:surface))
            XCTAssertEqual(try SurfaceGeometry.outputOutline(surface:surface),
                           try winding.map { try SurfaceGeometry.outputPoint(local:$0,surface:surface) })
        }
        for invalid in [[Point2(0.1,0.1),Point2(0.5,0.1),Point2(0.9,0.1)],
                        [Point2(.nan,0),vertices[1],vertices[2]],
                        [Point2(-0.01,0),vertices[1],vertices[2]], [vertices[0],vertices[1]]] {
            surface.triangleVertices = invalid
            XCTAssertThrowsError(try ProjectStore.validate(Project(surfaces:[surface])))
        }
    }

    func testPrimitiveDistancesBoundariesAndBoundedOutlines() throws {
        XCTAssertEqual(SurfaceShape.quad.signedDistance(at:Point2(0.5,0.5)),0.5,accuracy:1e-12)
        XCTAssertEqual(SurfaceShape.ellipse.signedDistance(at:Point2(0.8,0.9)),0,accuracy:1e-12)
        XCTAssertEqual(SurfaceShape.triangle.signedDistance(at:Point2(0.5,0.5)),0.5/sqrt(5),accuracy:1e-12)
        for shape in [SurfaceShape.quad,.triangle,.ellipse] {
            XCTAssertTrue(shape.contains(Point2(0.5,0.5)))
            XCTAssertFalse(shape.contains(Point2(-0.1,0.5)))
            XCTAssertFalse(shape.contains(Point2(.nan,0.5)))
            XCTAssertFalse(shape.contains(Point2(0.5,.infinity)))
            for point in shape.outline() { XCTAssertEqual(shape.signedDistance(at:point),0,accuracy:1e-10) }
        }
        XCTAssertFalse(SurfaceShape.triangle.contains(Point2(0.05,0.1)))
        XCTAssertFalse(SurfaceShape.ellipse.contains(Point2(0.05,0.05)))
        XCTAssertTrue(SurfaceShape.triangle.contains(Point2(0.5,0)))
        XCTAssertEqual(SurfaceShape.ellipse.outline(segments:Int.max).count,256)
        XCTAssertEqual(SurfaceShape.ellipse.outline(segments:Int.min).count,8)
        XCTAssertEqual(SurfaceShape.triangle.outline().count,3)
        XCTAssertEqual(SurfaceShape.quad.outline().count,4)
    }

    func testProjectivePrimitiveHitTestingAndIndependentInput() throws {
        var surface=Surface(output:[Point2(0.1,0.2),Point2(0.9,0.1),Point2(0.8,0.9),Point2(0.2,0.8)],shape:.ellipse)
        let center=try SurfaceGeometry.outputPoint(local:Point2(0.5,0.5),surface:surface)
        let corner=try SurfaceGeometry.outputPoint(local:Point2(0.05,0.05),surface:surface)
        XCTAssertTrue(SurfaceGeometry.contains(output:center,surface:surface))
        XCTAssertFalse(SurfaceGeometry.contains(output:corner,surface:surface))
        surface.input=[Point2(0.2,0.3),Point2(0.8,0.3),Point2(0.8,0.7),Point2(0.2,0.7)]
        XCTAssertEqual(try SurfaceGeometry.outputPoint(local:Point2(0.5,0.5),surface:surface),center)
        XCTAssertTrue(SurfaceGeometry.contains(output:center,surface:surface))
        surface.shape = .triangle
        let tip=try SurfaceGeometry.outputPoint(local:Point2(0.5,0),surface:surface)
        XCTAssertTrue(SurfaceGeometry.contains(output:tip,surface:surface))
        XCTAssertFalse(SurfaceGeometry.contains(output:corner,surface:surface))
        surface.shape = .quad
        XCTAssertTrue(SurfaceGeometry.contains(output:corner,surface:surface))
        XCTAssertFalse(SurfaceGeometry.contains(output:Point2(2,2),surface:surface))
        XCTAssertFalse(SurfaceGeometry.contains(output:Point2(.nan,0),surface:surface))
        XCTAssertThrowsError(try SurfaceGeometry.outputPoint(local:Point2(2,0),surface:surface))
        XCTAssertThrowsError(try SurfaceGeometry.outputPoint(local:Point2(.nan,0),surface:surface))
        surface.output=Array(repeating:Point2(0,0),count:4)
        XCTAssertFalse(SurfaceGeometry.contains(output:center,surface:surface))
    }

    func testMeshInterpolationAndFoldedPrimitiveHitTesting() throws {
        var surface=Surface(meshColumns:1,meshRows:1,mesh:[Point2(0,0),Point2(2,0),Point2(0,1),Point2(1,1)],shape:.triangle)
        let upper=try SurfaceGeometry.outputPoint(local:Point2(0.75,0.25),surface:surface)
        XCTAssertEqual(upper.x,1.25,accuracy:1e-12); XCTAssertEqual(upper.y,0.25,accuracy:1e-12)
        let lower=try SurfaceGeometry.outputPoint(local:Point2(0.25,0.75),surface:surface)
        XCTAssertEqual(lower.x,0.25,accuracy:1e-12); XCTAssertEqual(lower.y,0.75,accuracy:1e-12)
        let center=try SurfaceGeometry.outputPoint(local:Point2(0.5,0.5),surface:surface)
        XCTAssertTrue(SurfaceGeometry.contains(output:center,surface:surface))
        let outer=try SurfaceGeometry.outputPoint(local:Point2(0.05,0.05),surface:surface)
        XCTAssertFalse(SurfaceGeometry.contains(output:outer,surface:surface))
        // The first cell covers this screen point outside its local triangle;
        // the folded second cell covers it inside. Do not stop at the first hit.
        surface.meshColumns=2; surface.mesh=[Point2(0,0),Point2(1,0),Point2(-1,0),Point2(0,1),Point2(1,1),Point2(-1,1)]
        XCTAssertTrue(SurfaceGeometry.contains(output:Point2(0.4,0.4),surface:surface))
        surface.mesh=Array(repeating:Point2(0,0),count:6)
        XCTAssertFalse(SurfaceGeometry.contains(output:Point2(0,0),surface:surface))
        surface.meshRows=0
        XCTAssertFalse(SurfaceGeometry.contains(output:Point2(0,0),surface:surface))
        XCTAssertThrowsError(try SurfaceGeometry.outputPoint(local:Point2(0.5,0.5),surface:surface))
        XCTAssertThrowsError(try SurfaceGeometry.outputOutline(surface:surface))

        // Batch contours match point projection while keeping expensive mesh
        // validation/projective solves outside the per-contour-point loop.
        var outlineSurface=Surface(shape:.ellipse)
        for (local,output) in zip(outlineSurface.shape.outline(),try SurfaceGeometry.outputOutline(surface:outlineSurface)) {
            let expected=try SurfaceGeometry.outputPoint(local:local,surface:outlineSurface)
            XCTAssertEqual(output.x,expected.x,accuracy:1e-12); XCTAssertEqual(output.y,expected.y,accuracy:1e-12)
        }
        outlineSurface.meshColumns=3; outlineSurface.meshRows=2
        outlineSurface.mesh=try Geometry.regularMesh(quad:Point2.unitQuad,columns:3,rows:2)
        outlineSurface.mesh[1].y = -0.2
        outlineSurface.mesh[5].x += 0.1
        for (local,output) in zip(outlineSurface.shape.outline(),try SurfaceGeometry.outputOutline(surface:outlineSurface)) {
            let expected=try SurfaceGeometry.outputPoint(local:local,surface:outlineSurface)
            XCTAssertEqual(output.x,expected.x,accuracy:1e-12); XCTAssertEqual(output.y,expected.y,accuracy:1e-12)
        }
        XCTAssertEqual(try SurfaceGeometry.outputOutline(surface:outlineSurface,segments:Int.max).count,256)
        outlineSurface.shape = .quad
        XCTAssertTrue(try SurfaceGeometry.outputOutline(surface:outlineSurface).contains(outlineSurface.mesh[1]))
        outlineSurface.shape = .triangle
        let triangleContour=try SurfaceGeometry.outputOutline(surface:outlineSurface)
        // One vertical grid crossing and one cell-diagonal crossing on an edge.
        for local in [Point2(2.0/3,1.0/3),Point2(1.0/7,5.0/7)] {
            let expected=try SurfaceGeometry.outputPoint(local:local,surface:outlineSurface)
            XCTAssertTrue(triangleContour.contains { hypot($0.x-expected.x,$0.y-expected.y) < 1e-12 })
        }
        outlineSurface.meshColumns=64; outlineSurface.meshRows=64
        outlineSurface.mesh=try Geometry.regularMesh(quad:Point2.unitQuad,columns:64,rows:64)
        XCTAssertTrue(try SurfaceGeometry.outputOutline(surface:outlineSurface).count <= 768)
    }

    func testLegacyQuadMigrationAndFutureShapeRejection() throws {
        let url=scratch.appendingPathComponent("legacy.aperturecue.json")
        for version in [0,1] {
            var project=Project(version:version,surfaces:[Surface(shape:.ellipse)])
            project.cues=[Cue(name:"Old snapshot",surfaces:[Surface(shape:.triangle)])]
            try JSONEncoder().encode(project).write(to:url)
            let loaded=try ProjectStore.load(from:url)
            XCTAssertEqual(loaded.version,Project.currentVersion)
            XCTAssertEqual(loaded.surfaces[0].shape,.quad)
            XCTAssertEqual(loaded.cues[0].surfaces[0].shape,.quad)
        }
        try Data("{\"version\":1,\"surfaces\":[{\"name\":\"Legacy quad\"}]}".utf8).write(to:url)
        XCTAssertEqual(try ProjectStore.load(from:url).surfaces[0].shape,.quad)
        try Data("{\"version\":2,\"surfaces\":[{\"shape\":\"unsupported\"}]}".utf8).write(to:url)
        XCTAssertThrowsError(try ProjectStore.load(from:url))
        try Data("{\"version\":999}".utf8).write(to:url)
        XCTAssertThrowsError(try ProjectStore.load(from:url)) { XCTAssertEqual($0 as? ProjectError,.unsupportedVersion(999)) }
        XCTAssertTrue(ProjectError.unsupportedVersion(999).localizedDescription.contains("0 through \(Project.currentVersion)"))
    }

    func testShapesRoundTripCuesCollectAndHistory() throws {
        let before=Project(surfaces:[Surface(shape:.quad)])
        var project=before
        project.surfaces[0].shape = .ellipse
        project.surfaces[0].input=[Point2(0.2,0.3),Point2(0.8,0.3),Point2(0.8,0.7),Point2(0.2,0.7)]
        var triangle=project.surfaces[0]; triangle.shape = .triangle
        project.cues=[Cue(name:"Triangle",surfaces:[triangle])]
        let url=scratch.appendingPathComponent("shapes.aperturecue.json")
        try ProjectStore.save(project,to:url)
        XCTAssertEqual(try ProjectStore.load(from:url),project)
        let collected=try ProjectStore.collect(project,to:scratch.appendingPathComponent("portable"))
        XCTAssertEqual(try ProjectStore.load(from:collected),project)
        let history=EditHistory()
        history.commit(before:before,after:project,label:"Primitive")
        XCTAssertEqual(history.undo(current:project),before)
        XCTAssertEqual(history.redo(current:before),project)
        XCTAssertEqual(CueEngine.interpolate(project.surfaces[0],triangle,t:0).shape,.ellipse)
        XCTAssertEqual(CueEngine.interpolate(project.surfaces[0],triangle,t:0.49).shape,.ellipse)
        XCTAssertEqual(CueEngine.interpolate(project.surfaces[0],triangle,t:0.5).shape,.triangle)
        XCTAssertEqual(CueEngine.interpolate(project.surfaces[0],triangle,t:1).shape,.triangle)
        for t in [0.0,0.49,0.5,1] {
            XCTAssertEqual(CueEngine.interpolate(project.surfaces[0],triangle,t:t).input,project.surfaces[0].input)
        }
    }
}
