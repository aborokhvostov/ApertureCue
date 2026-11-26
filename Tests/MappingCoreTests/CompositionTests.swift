import XCTest
import Foundation
@testable import MappingCore

final class CompositionTests:XCTestCase {
    func testSchemaTwelveRoundTripCollectRecoveryAndLegacyExtensions() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueComposition-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let path=folder.appendingPathComponent("show.aperturecue.json")
        var group=SurfaceGroup(name:"Perspective group",transform:try .perspective(to:[Point2(0.1,0.1),Point2(0.9,0.2),Point2(0.8,0.9),Point2(0.2,0.8)]))
        group.isolated=true;group.masks=[CompositionMask(curve:.ellipse)]
        let material=MaterialDefinition(expression:"vec4(uv,0.5,1.0)")
        var output=OutputConfig();output.edgeBlend.right=0.2
        var layer=Surface(output:Point2.unitQuad,groupID:group.id)
        layer.materialID=material.id;layer.effects.saturation=0.5
        layer.bezierWarp=try BezierWarp.regular(quad:Point2.unitQuad)
        layer.masks=[CompositionMask(points:Point2.unitQuad)]
        var p=Project(surfaces:[layer],outputs:[output],cues:[Cue(name:"Composition",surfaces:[layer])],groups:[group])
        p.materials=[material];p.globalMasks=[CompositionMask(curve:.ellipse)]
        try ProjectStore.save(p,to:path);XCTAssertEqual(try ProjectStore.load(from:path),p)
        try ProjectStore.saveRecovery(p,for:path);XCTAssertEqual(try ProjectStore.loadRecovery(for:path),p)
        let collected=try ProjectStore.collect(p,to:folder.appendingPathComponent("Collected"))
        XCTAssertEqual(try ProjectStore.load(from:collected),p)
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as? [String:Any])
        json["version"]=11;json["materials"]="undefined";json["globalMasks"]="undefined"
        var bad=try XCTUnwrap((json["surfaces"] as? [[String:Any]])?.first)
        for key in ["materialID","materialValues","effects","masks","bezierWarp","inputWarp","inputMesh","meshWeights","meshLinked","warpTransform","feedbackOutputID"] {bad[key]="undefined"}
        json["surfaces"]=[bad]
        var cues=try XCTUnwrap(json["cues"] as? [[String:Any]]);cues[0]["surfaces"]=[bad];json["cues"]=cues
        var groups=try XCTUnwrap(json["groups"] as? [[String:Any]])
        for key in ["isolated","masks","effects","blendMode"] {groups[0][key]="undefined"}
        var transform=try XCTUnwrap(groups[0]["transform"] as? [String:Any]);transform["px"]="undefined";transform["py"]="undefined";transform["pw"]="undefined";groups[0]["transform"]=transform;json["groups"]=groups
        var outputs=try XCTUnwrap(json["outputs"] as? [[String:Any]]);outputs[0]["edgeBlend"]="undefined";json["outputs"]=outputs
        try JSONSerialization.data(withJSONObject:json).write(to:path)
        let old=try ProjectStore.load(from:path)
        XCTAssertEqual(old.materials,[]);XCTAssertEqual(old.globalMasks,[])
        XCTAssertNil(old.surfaces[0].materialID);XCTAssertNil(old.surfaces[0].bezierWarp)
        XCTAssertEqual(old.surfaces[0].effects,.init());XCTAssertEqual(old.cues[0].surfaces[0].masks,[])
        XCTAssertEqual(old.groups[0].transform.px,0);XCTAssertFalse(old.groups[0].isolated)
        XCTAssertEqual(old.outputs[0].edgeBlend,.init());XCTAssertEqual(old.outputs[0].id,output.id)
        json["version"]=12
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:json)))
    }

    func testProjectiveHierarchyAndIsolatedOpacityStackPolicy() throws {
        let transform=try Affine2D.perspective(to:[Point2(0.1,0.1),Point2(0.9,0.2),Point2(0.8,0.9),Point2(0.2,0.8)])
        let inverse=try transform.inverse()
        for point in [Point2(0.2,0.3),Point2(0.8,0.4)] {
            let result=try inverse.applying(transform.applying(point))
            XCTAssertEqual(result.x,point.x,accuracy:1e-10);XCTAssertEqual(result.y,point.y,accuracy:1e-10)
        }
        var group=SurfaceGroup(transform:transform,opacity:0.5);group.isolated=true
        let a=Surface(output:Point2.unitQuad,opacity:0.8,groupID:group.id),b=Surface(output:Point2.unitQuad,groupID:group.id),outside=Surface()
        let p=Project(surfaces:[a,b,outside],groups:[group]);try ProjectStore.validate(p)
        XCTAssertEqual(try GroupEngine.resolveForComposition(surfaces:p.surfaces,groups:p.groups)[0].opacity,0.8)
        XCTAssertEqual(try GroupEngine.resolve(surfaces:p.surfaces,groups:p.groups)[0].opacity,0.4)
        var invalid=p;invalid.surfaces=[a,outside,b]
        XCTAssertThrowsError(try ProjectStore.validate(invalid))
        var hidden=outside;hidden.enabled=false
        invalid.surfaces=[a,hidden,b];try ProjectStore.validate(invalid)
        XCTAssertThrowsError(try GroupEngine.dissolve(groupID:group.id,in:p))
        var horizon=p;horizon.groups[0].transform=Affine2D(px:1,py:0,pw:-0.5)
        XCTAssertThrowsError(try ProjectStore.validate(horizon))
    }

    func testNewSelectiveFieldsAndCurveGeometryRemainAtomic() throws {
        let a=Surface();var b=a
        b.materialID=UUID();b.materialValues=["amount":[0.2]];b.effects.inverted=true
        b.masks=[CompositionMask(curve:.ellipse)];b.bezierWarp=try BezierWarp.regular(quad:Point2.unitQuad)
        b.warpTransform = .translation(x:0.1,y:0.2)
        let fields:[CueParameter]=[.material,.effects,.mask,.outputGeometry]
        let cue=try CueSelection.capture(name:"Advanced",surfaces:[b],bindings:[CueBinding(surfaceID:a.id,parameters:fields)],duration:2)
        let result=try XCTUnwrap(CueSelection.destination(from:[a],cue:cue).first)
        XCTAssertEqual(result,b)
        let excluded=CueSelection.interpolate(a,b,parameters:[.opacity],t:0.75)
        XCTAssertEqual(excluded.materialID,a.materialID);XCTAssertEqual(excluded.effects,a.effects);XCTAssertEqual(excluded.masks,a.masks)
        let early=CueSelection.interpolate(a,b,parameters:[.outputGeometry],t:0.25)
        XCTAssertNil(early.bezierWarp);XCTAssertEqual(early.output,a.output)
        let late=CueSelection.interpolate(a,b,parameters:[.outputGeometry],t:0.75)
        XCTAssertEqual(late.bezierWarp,b.bezierWarp);XCTAssertEqual(late.warpTransform,b.warpTransform)
        var legacy=Project(version:11,surfaces:[a],cues:[cue])
        legacy.cues[0].bindings[0].parameters=[.material]
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(legacy)))
    }

    func testCompositionBudgetsReferencesAndInvalidTransforms() throws {
        var s=Surface();s.materialID=UUID()
        XCTAssertThrowsError(try ProjectStore.validate(Project(surfaces:[s])))
        s=Surface();s.feedbackOutputID=UUID()
        XCTAssertThrowsError(try ProjectStore.validate(Project(surfaces:[s])))
        let output=OutputConfig(width:8192,height:8192);s.feedbackOutputID=output.id
        XCTAssertThrowsError(try ProjectStore.validate(Project(surfaces:[s],outputs:[output])))
        var group=SurfaceGroup();group.isolated=true
        XCTAssertThrowsError(try ProjectStore.validate(Project(groups:(0..<17).map {_ in var g=group;g.id=UUID();return g})))
        var p=Project();p.globalMasks=[CompositionMask(settings:.init(space:.sourceUV))]
        XCTAssertThrowsError(try ProjectStore.validate(p))
        var input=Surface();input.inputWarp=try BezierWarp.regular(quad:Point2.unitQuad)
        XCTAssertThrowsError(try ProjectStore.validate(Project(surfaces:[input])))

        let precisionGroup=SurfaceGroup(transform:Affine2D(a:1,d:1e-6,px:1,pw:1e-6))
        var precisionMesh=Surface(output:Point2.unitQuad,meshColumns:1,meshRows:1,mesh:try Geometry.regularMesh(quad:Point2.unitQuad,columns:1,rows:1),groupID:precisionGroup.id)
        precisionMesh.meshWeights=[1e-10,1,1,1]
        XCTAssertThrowsError(try ProjectStore.validate(Project(surfaces:[precisionMesh],groups:[precisionGroup])))

        let path=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueMalformedWeights-"+UUID().uuidString+".json")
        defer {try? FileManager.default.removeItem(at:path)}
        var malformed=Surface(output:Point2.unitQuad,meshColumns:1,meshRows:1,
                              mesh:try Geometry.regularMesh(quad:Point2.unitQuad,columns:1,rows:1))
        for weights in [[1.0],[1.0,1,1],[1.0,1,1,1,1]] {
            malformed.meshWeights=weights
            XCTAssertThrowsError(try GroupEngine.resolve(surfaces:[malformed],groups:[]))
            let current=Project(surfaces:[malformed])
            let stored=Project(surfaces:[Surface()],cues:[Cue(name:"Malformed stored mesh",surfaces:[malformed])])
            let dormant=Cue(name:"Malformed dormant mesh",surfaces:[malformed],scope:.selective,
                            bindings:[CueBinding(surfaceID:malformed.id,parameters:[.opacity])])
            for candidate in [current,stored,Project(cues:[dormant])] {
                XCTAssertThrowsError(try ProjectStore.validate(candidate))
                // A corrupted schema-12 document must fail loading, not trap
                // before surface validation reaches the parallel-array check.
                try JSONEncoder().encode(candidate).write(to:path,options:.atomic)
                XCTAssertThrowsError(try ProjectStore.load(from:path))
            }
        }
    }
}
