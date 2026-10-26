import XCTest
import Foundation
@testable import MappingCore

final class StrokeTests:XCTestCase {
    private var scratch:URL!
    override func setUpWithError() throws {
        scratch=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueStroke-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:scratch) }
    private func point(_ a:Point2,_ b:Point2,file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertEqual(a.x,b.x,accuracy:1e-9,file:file,line:line); XCTAssertEqual(a.y,b.y,accuracy:1e-9,file:file,line:line)
    }
    private func cubic(_ a:Point2,_ b:Point2,_ c:Point2,_ d:Point2,_ t:Double) -> Point2 {
        let v=1-t
        return Point2(v*v*v*a.x+3*v*v*t*b.x+3*v*t*t*c.x+t*t*t*d.x,v*v*v*a.y+3*v*v*t*b.y+3*v*t*t*c.y+t*t*t*d.y)
    }
    private func nearest(_ p:Point2,_ samples:[Point2]) -> Double {
        zip(samples,samples.dropFirst()).map { a,b in
            let dx=(b.x-a.x)*StrokeGeometry.aspectRatio,dy=b.y-a.y
            let x=(p.x-a.x)*StrokeGeometry.aspectRatio,y=p.y-a.y
            let length=dx*dx+dy*dy
            let t=length>0 ? min(1,max(0,(x*dx+y*dy)/length)) : 0
            return hypot(x-t*dx,y-t*dy)
        }.min() ?? .infinity
    }

    func testMetricWidthCapsJoinsClosedAndTextureCoordinates() throws {
        var surface=Surface(shape:.line,stroke:StrokePath(nodes:[StrokeNode(anchor:Point2(0.2,0.5)),StrokeNode(anchor:Point2(0.8,0.5))],width:0.2))
        let hit=try XCTUnwrap(StrokeGeometry.hit(local:Point2(0.5,0.55),surface:surface))
        XCTAssertEqual(hit.distance,0.05,accuracy:1e-12); XCTAssertEqual(hit.along,0.5,accuracy:1e-12); XCTAssertEqual(hit.across,0.75,accuracy:1e-12)
        let cap=Point2(0.2-0.05/StrokeGeometry.aspectRatio,0.5)
        let capHit=try XCTUnwrap(StrokeGeometry.hit(local:cap,surface:surface))
        XCTAssertEqual(capHit.distance,0.05,accuracy:1e-12); XCTAssertEqual(capHit.along,0,accuracy:1e-12); XCTAssertEqual(capHit.across,0.5,accuracy:1e-12)
        XCTAssertTrue(StrokeGeometry.contains(local:cap,surface:surface))
        XCTAssertFalse(StrokeGeometry.contains(local:Point2(0.5,0.61),surface:surface))
        XCTAssertFalse(StrokeGeometry.contains(local:Point2(.nan,0.5),surface:surface))
        surface.stroke.nodes=[StrokeNode(anchor:Point2(0,0.5)),StrokeNode(anchor:Point2(0.5,0.5)),StrokeNode(anchor:Point2(0.5,0.9))]
        XCTAssertTrue(StrokeGeometry.contains(local:Point2(0.53,0.46),surface:surface))
        XCTAssertFalse(StrokeGeometry.contains(local:Point2(-0.01,0.5),surface:surface)) // cage clips cap
        surface.stroke.closed=true
        let samples=try StrokeGeometry.samples(surface:surface)
        XCTAssertEqual(samples.first,samples.last); XCTAssertEqual(samples.count,4)
        XCTAssertTrue(StrokeGeometry.contains(local:Point2(0.25,0.7),surface:surface)) // closing edge
        XCTAssertFalse(StrokeGeometry.contains(local:Point2(0.35,0.62),surface:surface)) // no filled polygon
        surface.stroke.nodes.insert(surface.stroke.nodes[0],at:1)
        XCTAssertEqual(try StrokeGeometry.samples(surface:surface),samples) // adjacent duplicates harmless
    }

    func testCubicFlatteningAccuracyReversalsAndCoincidentEndpointLoops() throws {
        var surface=Surface(shape:.bezier,stroke:.bezier)
        let samples=try StrokeGeometry.samples(surface:surface),a=surface.stroke.nodes[0],b=surface.stroke.nodes[1]
        XCTAssertEqual(samples.first,a.anchor); XCTAssertEqual(samples.last,b.anchor)
        XCTAssertGreaterThan(samples.count,8); XCTAssertTrue(samples.count<=257)
        for index in 0...1000 {
            let exact=cubic(a.anchor,a.outgoing,b.incoming,b.anchor,Double(index)/1000)
            XCTAssertTrue(nearest(exact,samples)<=StrokeGeometry.defaultTolerance+1e-10)
        }
        surface.stroke.nodes=[StrokeNode(anchor:Point2(0.4,0.5),outgoing:Point2(0.95,0.5)),StrokeNode(anchor:Point2(0.6,0.5),incoming:Point2(0.05,0.5))]
        let reversal=try StrokeGeometry.samples(surface:surface)
        XCTAssertGreaterThan(reversal.count,2)
        XCTAssertTrue(zip(reversal,reversal.dropFirst()).contains { $1.x<$0.x })
        surface.stroke.nodes=[StrokeNode(anchor:Point2(0.5,0.5),outgoing:Point2(0.9,0.1)),StrokeNode(anchor:Point2(0.5,0.5),incoming:Point2(0.1,0.1))]
        let loop=try StrokeGeometry.samples(surface:surface)
        XCTAssertGreaterThan(loop.count,2); XCTAssertEqual(loop.first,loop.last)
        XCTAssertTrue(loop.contains { $0.y<0.3 })
        surface.shape = .line
        XCTAssertThrowsError(try StrokeGeometry.samples(surface:surface)) // handles ignored by polyline
    }

    func testMalformedBoundsAndExplicitPrecisionBudgetRejection() throws {
        var surface=Surface(shape:.line)
        let original=surface
        for width in [0.0,0.0001,1.01,Double.nan,Double.infinity] {
            surface=original;surface.stroke.width=width
            XCTAssertThrowsError(try ProjectStore.validate(Project(surfaces:[surface])))
        }
        for p in [Point2(-0.01,0.5),Point2(1.01,0.5),Point2(.nan,0.5),Point2(0.5,.infinity)] {
            surface=original;surface.stroke.nodes[0].outgoing=p
            XCTAssertThrowsError(try StrokeGeometry.samples(surface:surface))
            surface.shape = .quad
            XCTAssertThrowsError(try ProjectStore.validate(Project(surfaces:[surface]))) // dormant payload validated
        }
        surface=original;surface.stroke.nodes=[]
        XCTAssertThrowsError(try StrokeGeometry.samples(surface:surface))
        surface=original;surface.stroke.nodes=Array(repeating:StrokeNode(anchor:Point2(0.5,0.5)),count:33)
        XCTAssertThrowsError(try StrokeGeometry.samples(surface:surface))
        surface=original;surface.stroke.closed=true
        XCTAssertThrowsError(try StrokeGeometry.samples(surface:surface))
        surface=Surface(shape:.bezier,stroke:.bezier)
        for tolerance in [0.0,-1,Double.nan,Double.infinity,1.01] { XCTAssertThrowsError(try StrokeGeometry.samples(surface:surface,tolerance:tolerance)) }
        XCTAssertThrowsError(try StrokeGeometry.samples(surface:surface,tolerance:1e-30))
        surface.stroke.nodes=(0..<32).map { i in
            let x=Double(i)/31,y=i%2==0 ? 0.2 : 0.8
            return StrokeNode(anchor:Point2(x,y),incoming:Point2(max(0,x-0.02),1-y),outgoing:Point2(min(1,x+0.02),1-y))
        }
        XCTAssertThrowsError(try StrokeGeometry.samples(surface:surface,tolerance:1e-7))
        var invalidCue=original;invalidCue.stroke.width=0
        XCTAssertThrowsError(try ProjectStore.validate(Project(surfaces:[original],cues:[Cue(name:"Bad path",surfaces:[invalidCue])])))
    }

    func testCrossingTieOwnershipAndProjectedMeshInverse() throws {
        var surface=Surface(output:[Point2(0.1,0.2),Point2(0.9,0.1),Point2(0.8,0.9),Point2(0.2,0.8)],shape:.line,
                            stroke:StrokePath(nodes:[StrokeNode(anchor:Point2(0.2,0.2)),StrokeNode(anchor:Point2(0.8,0.8)),StrokeNode(anchor:Point2(0.2,0.8)),StrokeNode(anchor:Point2(0.8,0.2))]))
        let crossing=try XCTUnwrap(StrokeGeometry.hit(local:Point2(0.5,0.5),surface:surface))
        XCTAssertEqual(crossing.distance,0,accuracy:1e-12); XCTAssertTrue(crossing.along<0.5)
        for local in [Point2(0.5,0.5),Point2(0.2,0.2),Point2(0.8,0.2)] {
            let out=try SurfaceGeometry.outputPoint(local:local,surface:surface)
            point(try SurfaceGeometry.localPoint(output:out,surface:surface),local)
            XCTAssertTrue(SurfaceGeometry.contains(output:out,surface:surface))
        }
        let empty=try SurfaceGeometry.outputPoint(local:Point2(0.1,0.9),surface:surface)
        XCTAssertFalse(SurfaceGeometry.contains(output:empty,surface:surface))
        surface.meshColumns=2;surface.meshRows=2;surface.mesh=try Geometry.regularMesh(quad:surface.output,columns:2,rows:2)
        surface.mesh[4].x+=0.05;surface.mesh[4].y-=0.04
        for local in [Point2(0.5,0.5),Point2(0.25,0.25),Point2(0.7,0.3)] {
            let out=try SurfaceGeometry.outputPoint(local:local,surface:surface)
            point(try SurfaceGeometry.localPoint(output:out,surface:surface),local)
            XCTAssertTrue(SurfaceGeometry.contains(output:out,surface:surface))
        }
        XCTAssertThrowsError(try SurfaceGeometry.localPoint(output:Point2(2,2),surface:surface))
        XCTAssertThrowsError(try SurfaceGeometry.localPoint(output:Point2(.nan,0),surface:surface))
        var straight=Surface(output:Point2.unitQuad,shape:.line)
        straight.meshColumns=2; straight.meshRows=2
        straight.mesh=try Geometry.regularMesh(quad:straight.output,columns:2,rows:2)
        straight.mesh[4]=Point2(0.6,0.57)
        let warpedCenterline=try SurfaceGeometry.outputCenterline(surface:straight)
        XCTAssertTrue(warpedCenterline.count>=3)
        XCTAssertTrue(warpedCenterline.contains { hypot($0.x-0.6,$0.y-0.57)<1e-12 })
        point(try XCTUnwrap(warpedCenterline.first),try SurfaceGeometry.outputPoint(local:straight.stroke.nodes[0].anchor,surface:straight))
        point(try XCTUnwrap(warpedCenterline.last),try SurfaceGeometry.outputPoint(local:straight.stroke.nodes[1].anchor,surface:straight))
        surface.mesh=Array(repeating:Point2(0,0),count:9)
        XCTAssertThrowsError(try SurfaceGeometry.localPoint(output:Point2(0,0),surface:surface))
    }

    func testSchemaFourMigrationDefaultsAndMalformedPersistence() throws {
        let url=scratch.appendingPathComponent("stroke.json")
        for version in 0...3 {
            var old=Project(version:version,surfaces:[Surface(shape:.ellipse,stroke:.bezier)])
            old.cues=[Cue(name:"Extension",surfaces:[Surface(shape:.bezier,stroke:.bezier)])]
            old.surfaces[0].stroke.width=0 // unknown pre-v4 extension is not activated
            try JSONEncoder().encode(old).write(to:url)
            let loaded=try ProjectStore.load(from:url)
            XCTAssertEqual(loaded.version,4); XCTAssertEqual(loaded.surfaces[0].stroke,.line)
            XCTAssertEqual(loaded.surfaces[0].shape,version<2 ? .quad : .ellipse)
            XCTAssertEqual(loaded.cues[0].surfaces[0].shape,.quad)
            XCTAssertEqual(loaded.cues[0].surfaces[0].stroke,.line)
            try ProjectStore.save(old,to:url)
            XCTAssertEqual(try ProjectStore.load(from:url).surfaces[0].stroke,.line)
        }
        try Data("{\"version\":4,\"surfaces\":[{\"shape\":\"line\"}]}".utf8).write(to:url)
        XCTAssertEqual(try ProjectStore.load(from:url).surfaces[0].stroke,.line)
        try Data("{\"version\":4,\"surfaces\":[{\"shape\":\"line\",\"stroke\":{\"nodes\":[]}}]}".utf8).write(to:url)
        XCTAssertThrowsError(try ProjectStore.load(from:url))
        try Data("{\"version\":999}".utf8).write(to:url)
        XCTAssertThrowsError(try ProjectStore.load(from:url)) { XCTAssertEqual($0 as? ProjectError,.unsupportedVersion(999)) }
    }

    func testCuePathInterpolationFramesAndCollapseRemainValid() throws {
        let a=Surface(shape:.line)
        var b=a;b.stroke.width=0.2
        b.stroke.nodes[0]=StrokeNode(anchor:Point2(0.2,0.2));b.stroke.nodes[1]=StrokeNode(anchor:Point2(0.7,0.7))
        let middle=CueEngine.interpolate(a,b,t:0.5)
        point(middle.stroke.nodes[0].anchor,Point2(0.175,0.35));XCTAssertEqual(middle.stroke.width,0.14,accuracy:1e-12)
        try ProjectStore.validate(Project(surfaces:[middle]))
        let group=SurfaceGroup(name:"Other frame")
        b.groupID=group.id
        XCTAssertEqual(CueEngine.interpolate(a,b,t:0.49).stroke,a.stroke)
        XCTAssertEqual(CueEngine.interpolate(a,b,t:0.5).stroke,b.stroke)
        b=a;b.shape = .bezier;b.stroke = .bezier
        XCTAssertEqual(CueEngine.interpolate(a,b,t:0.49).stroke,a.stroke)
        XCTAssertEqual(CueEngine.interpolate(a,b,t:0.5).stroke,b.stroke)
        b=a;b.stroke.nodes.reverse()
        let collapse=CueEngine.interpolate(a,b,t:0.5)
        XCTAssertEqual(collapse.stroke,b.stroke)
        try ProjectStore.validate(Project(surfaces:[collapse]))
        XCTAssertEqual(CueEngine.interpolate(a,b,t:0),a);XCTAssertEqual(CueEngine.interpolate(a,b,t:1),b)
    }

    func testGroupHistorySaveAndPortableCollectionKeepLocalStroke() throws {
        let assetURL=scratch.appendingPathComponent("original.dat")
        try Data([1,2,3,4]).write(to:assetURL)
        let asset=MediaAsset(name:"Original test data",path:assetURL.path,kind:"image")
        let group=SurfaceGroup(name:"Stage",transform:.rotation(degrees:18).concatenating(.scale(x:0.7,y:0.9)))
        let surface=Surface(mediaID:asset.id,shape:.bezier,groupID:group.id,stroke:.bezier)
        let before=Project(assets:[asset],surfaces:[surface],cues:[Cue(name:"Path snapshot",surfaces:[surface])],groups:[group])
        let assigned=try GroupEngine.assign(surfaceID:surface.id,to:nil,in:before)
        XCTAssertEqual(assigned.surfaces[0].stroke,surface.stroke)
        let dissolved=try GroupEngine.dissolve(groupID:group.id,in:before)
        XCTAssertEqual(dissolved.surfaces[0].stroke,surface.stroke);XCTAssertEqual(dissolved.cues[0].surfaces[0].stroke,surface.stroke)
        let originalOutput=try GroupEngine.resolve(surfaces:before.surfaces,groups:before.groups)[0]
        for local in try StrokeGeometry.samples(surface:surface) {
            point(try SurfaceGeometry.outputPoint(local:local,surface:originalOutput),try SurfaceGeometry.outputPoint(local:local,surface:dissolved.surfaces[0]))
        }
        let history=EditHistory();history.commit(before:before,after:dissolved,label:"Dissolve stroke")
        XCTAssertEqual(history.undo(current:dissolved),before);XCTAssertEqual(history.redo(current:before),dissolved)
        let url=scratch.appendingPathComponent("saved.json")
        try ProjectStore.save(before,to:url);XCTAssertEqual(try ProjectStore.load(from:url),before)
        let collected=try ProjectStore.collect(before,to:scratch.appendingPathComponent("portable"))
        try FileManager.default.removeItem(at:assetURL)
        let restored=try ProjectStore.load(from:collected)
        XCTAssertEqual(restored.surfaces,before.surfaces);XCTAssertEqual(restored.cues,before.cues);XCTAssertEqual(restored.groups,before.groups)
        XCTAssertTrue(FileManager.default.fileExists(atPath:restored.assets[0].path))
    }
}
