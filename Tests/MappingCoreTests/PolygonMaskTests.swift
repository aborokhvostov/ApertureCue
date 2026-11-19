import XCTest
import Foundation
@testable import MappingCore

final class PolygonMaskTests: XCTestCase {
    func testConcaveInvertedFeatherAndDegenerateSegments() throws {
        let polygon=[Point2(0.2,0.2),Point2(0.8,0.2),Point2(0.8,0.4),Point2(0.4,0.4),Point2(0.4,0.8),Point2(0.2,0.8),Point2(0.2,0.8)]
        let style=PolygonMaskSettings(feather:0.1)
        func alpha(_ x:Double,_ y:Double,_ inverted:Bool=false) -> Double {
            var settings=style; settings.inverted=inverted
            return PolygonMaskGeometry.alpha(at:Point2(x,y),polygon:polygon,settings:settings)
        }
        XCTAssertEqual(alpha(0.3,0.3),1,accuracy:1e-12)
        XCTAssertEqual(alpha(0.25,0.3),0.5,accuracy:1e-12)
        XCTAssertEqual(alpha(0.2,0.3),0)
        XCTAssertEqual(alpha(0.6,0.6),0)
        XCTAssertEqual(alpha(0.6,0.6,true),1)
        XCTAssertEqual(alpha(0.85,0.3,true),0.5,accuracy:1e-12)
        var last=0.0
        for i in 0...100 {
            let next=alpha(0.2+Double(i)/1000,0.3)
            XCTAssertTrue(next+1e-12 >= last); last=next
        }
        XCTAssertEqual(PolygonMaskGeometry.alpha(at:Point2(0.2,0.3),polygon:polygon,settings:.init()),1)
        XCTAssertEqual(PolygonMaskGeometry.alpha(at:Point2(0.5,0.5),polygon:[],settings:.init(inverted:true)),1)
        for width in [-1,0.51,Double.infinity,Double.nan] {
            XCTAssertThrowsError(try ProjectStore.validate(Project(surfaces:[Surface(maskSettings:.init(feather:width))])))
        }
    }

    func testMaskCueAtomicityAndCoordinateSwitching() throws {
        let a=Surface(mask:Point2.unitQuad,maskSettings:.init(feather:0.1))
        var b=a; b.mask=Point2.insetQuad; b.maskSettings.feather=0.3
        let partial=try CueSelection.capture(name:"Mask",surfaces:[b],bindings:[CueBinding(surfaceID:a.id,parameters:[.mask])],duration:2)
        let engine=CueEngine(); engine.begin(from:[a],cue:partial,at:0)
        let mid=try XCTUnwrap(engine.sample(at:1)?.first)
        XCTAssertEqual(mid.mask[0],Point2(0.05,0.05)); XCTAssertEqual(mid.maskSettings.feather,0.2,accuracy:1e-12)
        XCTAssertEqual(mid.input,a.input); XCTAssertEqual(mid.output,a.output)
        b.maskSettings.space = .outputCanvas; b.maskSettings.inverted=true
        for t in [0.25,0.5,0.75] {
            let expected=t < 0.5 ? a : b
            let full=CueEngine.interpolate(a,b,t:t)
            let selected=CueSelection.interpolate(a,b,parameters:[.mask],t:t)
            XCTAssertEqual(full.mask,expected.mask); XCTAssertEqual(full.maskSettings,expected.maskSettings)
            XCTAssertEqual(selected,full)
            let excluded=CueSelection.interpolate(a,b,parameters:[.opacity],t:t)
            XCTAssertEqual(excluded.mask,a.mask); XCTAssertEqual(excluded.maskSettings,a.maskSettings)
        }
    }

    func testSchemaElevenMigrationStrictnessSaveCollectAndHistory() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueMask-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url=directory.appendingPathComponent("mask.aperturecue.json")
        let surface=Surface(mask:Point2.insetQuad,shape:.triangle,triangleVertices:[Point2(0.2,0.2),Point2(0.8,0.3),Point2(0.4,0.9)],
                            maskSettings:.init(space:.outputCanvas,inverted:true,feather:0.12))
        let p=Project(surfaces:[surface],cues:[Cue(name:"Full",surfaces:[surface])])
        try ProjectStore.save(p,to:url); XCTAssertEqual(try ProjectStore.load(from:url),p)
        let collected=try ProjectStore.collect(p,to:directory.appendingPathComponent("Collected"))
        XCTAssertEqual(try ProjectStore.load(from:collected),p)
        try ProjectStore.saveRecovery(p,for:url)
        XCTAssertEqual(try ProjectStore.loadRecovery(for:url),p)
        var changed=p; changed.surfaces[0].maskSettings.inverted=false
        let history=EditHistory(); history.commit(before:p,after:changed,label:"Mask")
        XCTAssertEqual(history.undo(current:changed),p)
        XCTAssertEqual(history.redo(current:p),changed)
        let encoded=try JSONEncoder().encode(p)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        var badSurface=try XCTUnwrap((object["surfaces"] as? [[String:Any]])?.first)
        badSurface["maskSettings"]=["space":"future-space","inverted":true,"feather":0.1]
        object["surfaces"]=[badSurface]
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:object)))
        for version in 0...10 {
            object["version"]=version
            badSurface["maskSettings"]=["malformed": [1,2,3]]
            object["surfaces"]=[badSurface]
            var cues=try XCTUnwrap(object["cues"] as? [[String:Any]])
            cues[0]["surfaces"]=[badSurface]; object["cues"]=cues
            try JSONSerialization.data(withJSONObject:object).write(to:url)
            let migrated=try ProjectStore.load(from:url)
            XCTAssertEqual(migrated.surfaces[0].maskSettings,.init())
            XCTAssertEqual(migrated.cues[0].surfaces[0].maskSettings,.init())
            XCTAssertEqual(migrated.surfaces[0].mask,surface.mask)
            if version >= 9 { XCTAssertEqual(migrated.surfaces[0].triangleVertices,surface.triangleVertices) }
        }
        var old=p; old.version=10
        try ProjectStore.save(old,to:url)
        XCTAssertEqual(try ProjectStore.load(from:url).surfaces[0].maskSettings,.init())
    }
}
