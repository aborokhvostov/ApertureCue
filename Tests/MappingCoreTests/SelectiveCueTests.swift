import XCTest
import Foundation
@testable import MappingCore

final class SelectiveCueTests:XCTestCase {
    private var scratch:URL!
    override func setUpWithError() throws {
        scratch=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueSelective-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:scratch) }
    private func cue(_ surface:Surface,_ parameters:[CueParameter],duration:Double=2,follow:Double?=nil) throws -> Cue {
        try CueSelection.capture(name:"Partial",surfaces:[surface],bindings:[CueBinding(surfaceID:surface.id,parameters:parameters)],duration:duration,followAfter:follow)
    }
    private func object<T:Encodable>(_ value:T) throws -> [String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as? [String:Any])
    }
    private func write(_ object:[String:Any]) throws -> URL {
        let url=scratch.appendingPathComponent("show.aperturecue")
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:url)
        return url
    }

    func testEveryMaskCopiesOnlyItsAtomicFieldsAndPreservesCurrentLayers() throws {
        let original=Surface(name:"Current name")
        var snapshot=Surface(id:original.id,name:"Saved name",mediaID:UUID(),input:Point2.insetQuad,output:Point2.unitQuad,
                             opacity:0.3,brightness:2,enabled:false,blendMode:"screen",feather:0.2,gamma:2,color:[0.2,0.4,0.6],
                             mask:[Point2(0,0),Point2(1,0),Point2(0.5,1)],meshColumns:1,meshRows:1,mesh:Point2.unitQuad,
                             outputID:UUID(),generator:"gradient",shape:.bezier,groupID:UUID(),stroke:.bezier)
        // Differing legacy metadata must never be recalled by any selective mask.
        snapshot.group="Dormant label"
        let keys:[CueParameter:Set<String>]=[
            .opacity:["opacity"],.brightness:["brightness"],.gamma:["gamma"],.color:["color"],.feather:["feather"],
            .blendMode:["blendMode"],.visibility:["enabled"],.source:["mediaID","generator"],.input:["input"],
            .outputGeometry:["output","mesh","meshRows","meshColumns","groupID"],.shape:["shape","stroke"],.mask:["mask"],.routing:["outputID"]]
        let before=try object(original),saved=try object(snapshot)
        let unrelated=Surface(name:"New layer"),first=Surface(name:"First")
        for parameter in CueParameter.allCases {
            let capture=try cue(snapshot,[parameter])
            XCTAssertEqual(capture.surfaces,[snapshot]);XCTAssertEqual(capture.scope,.selective)
            let merged=try CueSelection.destination(from:[first,original,unrelated],cue:capture)
            XCTAssertEqual(merged.map(\.id),[first.id,original.id,unrelated.id])
            XCTAssertEqual(merged[0],first);XCTAssertEqual(merged[2],unrelated)
            let after=try object(merged[1])
            for key in Set(before.keys).union(saved.keys) {
                let expected=keys[parameter]!.contains(key) ? saved[key] : before[key]
                if let expected=expected as? NSObject { XCTAssertTrue((after[key] as? NSObject)?.isEqual(expected) == true,"\(parameter): \(key)") }
                else { XCTAssertNil(after[key],"\(parameter): \(key)") }
            }
        }
    }

    func testHiddenVisibilityAndMissingTargetsNeverFadeOrRestoreUnselectedLayers() throws {
        let hidden=Surface(name:"Hidden",opacity:0.73,enabled:false),untouched=Surface(name:"Untouched",opacity:0.61)
        var destination=hidden;destination.enabled=true;destination.opacity=0.04
        let absent=Surface(name:"Deleted")
        let capture=try CueSelection.capture(name:"Visibility",surfaces:[destination,absent],bindings:[
            CueBinding(surfaceID:absent.id,parameters:[.opacity]),CueBinding(surfaceID:hidden.id,parameters:[.visibility])])
        XCTAssertEqual(CueSelection.missingTargets(from:[hidden,untouched],cue:capture),[absent.id])
        let engine=CueEngine();engine.begin(from:[untouched,hidden],cue:capture,at:20)
        let early=try XCTUnwrap(engine.sample(at:20.25)),middle=try XCTUnwrap(engine.sample(at:20.5))
        XCTAssertEqual(early.map(\.id),[untouched.id,hidden.id]);XCTAssertEqual(early[0],untouched)
        XCTAssertFalse(early[1].enabled);XCTAssertTrue(middle[1].enabled)
        XCTAssertEqual(early[1].opacity,0.73);XCTAssertEqual(middle[1].opacity,0.73)
        XCTAssertEqual(engine.sample(at:21),try CueSelection.destination(from:[untouched,hidden],cue:capture))
        XCTAssertEqual(try CueSelection.destination(from:[],cue:capture),[])
    }

    func testSelectedNumericAndDiscreteInterpolationEndpointsAndInstantFollow() throws {
        let a=Surface(opacity:0.2,brightness:2,enabled:false,feather:0.1,gamma:1,color:[1,2,3])
        var b=a;b.opacity=0.8;b.brightness=6;b.gamma=3;b.color=[3,4,5];b.feather=0.3
        b.enabled=true;b.generator="solid";b.mediaID=UUID();b.blendMode="add";b.outputID=UUID()
        let parameters:[CueParameter]=[.opacity,.brightness,.gamma,.color,.feather,.visibility,.source,.blendMode,.routing]
        let capture=try cue(b,parameters,follow:3),engine=CueEngine()
        engine.begin(from:[a],cue:capture,at:10)
        XCTAssertEqual(engine.sample(at:10),[a])
        let early=try XCTUnwrap(engine.sample(at:10.5)).first!,mid=try XCTUnwrap(engine.sample(at:11)).first!
        XCTAssertEqual(early.opacity,0.35,accuracy:1e-12);XCTAssertFalse(early.enabled)
        XCTAssertEqual(early.mediaID,a.mediaID);XCTAssertEqual(early.generator,a.generator);XCTAssertEqual(early.blendMode,a.blendMode)
        XCTAssertEqual(mid.opacity,0.5,accuracy:1e-12);XCTAssertEqual(mid.brightness,4);XCTAssertEqual(mid.gamma,2)
        XCTAssertEqual(mid.color,[2,3,4]);XCTAssertEqual(mid.feather,0.2,accuracy:1e-12)
        XCTAssertTrue(mid.enabled);XCTAssertEqual(mid.mediaID,b.mediaID);XCTAssertEqual(mid.generator,"solid")
        XCTAssertEqual(mid.blendMode,"add");XCTAssertEqual(mid.outputID,b.outputID)
        XCTAssertEqual(engine.sample(at:12),[b]);XCTAssertFalse(engine.shouldFollow(at:14.99));XCTAssertTrue(engine.shouldFollow(at:15))
        engine.begin(from:[a],cue:try cue(b,[.brightness],duration:0,follow:0),at:30)
        var instant=a;instant.brightness=6
        XCTAssertEqual(engine.sample(at:30),[instant]);XCTAssertTrue(engine.shouldFollow(at:30))
    }

    func testGeometryFramesQuadCollapseStrokeAndMaskCompatibility() throws {
        let a=Surface(input:Point2.unitQuad,output:Point2.unitQuad,mask:Point2.unitQuad,meshColumns:1,meshRows:1,mesh:Point2.unitQuad)
        var b=a;b.input=Point2.insetQuad;b.output=Point2.insetQuad;b.mesh=Point2.insetQuad;b.mask=Point2.insetQuad
        let engine=CueEngine();engine.begin(from:[a],cue:try cue(b,[.input,.outputGeometry,.mask]),at:0)
        let smooth=try XCTUnwrap(engine.sample(at:1)).first!
        XCTAssertEqual(smooth.input[0],Point2(0.05,0.05));XCTAssertEqual(smooth.output[0],Point2(0.05,0.05))
        XCTAssertEqual(smooth.mesh[0],Point2(0.05,0.05));XCTAssertEqual(smooth.mask[0],Point2(0.05,0.05))
        b.groupID=UUID()
        engine.begin(from:[a],cue:try cue(b,[.outputGeometry]),at:0)
        XCTAssertEqual(try XCTUnwrap(engine.sample(at:0.9)).first!,a)
        let newFrame=try XCTUnwrap(engine.sample(at:1)).first!
        XCTAssertEqual(newFrame.groupID,b.groupID);XCTAssertEqual(newFrame.output,b.output);XCTAssertEqual(newFrame.mesh,b.mesh)
        XCTAssertEqual(newFrame.input,a.input);XCTAssertEqual(newFrame.mask,a.mask)
        // Opposite winding is valid at each endpoint but collapses halfway.
        b=a;b.output=[Point2(1,0),Point2(0,0),Point2(0,1),Point2(1,1)]
        b.input=b.output;b.mesh=b.output
        engine.begin(from:[a],cue:try cue(b,[.input,.outputGeometry]),at:0)
        let guarded=try XCTUnwrap(engine.sample(at:1)).first!
        try Geometry.validateQuad(guarded.output);try Geometry.validateQuad(guarded.input)
        XCTAssertEqual(guarded.output,b.output);XCTAssertEqual(guarded.mesh,b.mesh)
        var line=Surface(shape:.line),reversed=line
        reversed.stroke.nodes.reverse();reversed.mask=[Point2(0,0),Point2(1,0),Point2(0,1)]
        engine.begin(from:[line],cue:try cue(reversed,[.shape,.mask]),at:0)
        let valid=try XCTUnwrap(engine.sample(at:1)).first!
        _ = try StrokeGeometry.samples(surface:valid)
        XCTAssertEqual(valid.stroke,reversed.stroke);XCTAssertEqual(valid.mask,reversed.mask)
        line.stroke.width=0.1;reversed=line;reversed.stroke.width=0.3
        engine.begin(from:[line],cue:try cue(reversed,[.shape]),at:0)
        XCTAssertEqual(try XCTUnwrap(engine.sample(at:1)).first!.stroke.width,0.2,accuracy:1e-12)
    }

    func testInterruptionUsesActualCurrentStateAndPreservesShowAndMediaClock() throws {
        let surface=Surface(opacity:0.2,brightness:1),clock=TransportClock()
        clock.play(at:100)
        var one=surface;one.opacity=1
        let engine=CueEngine();engine.begin(from:[surface],cue:try cue(one,[.opacity]),at:100)
        let current=try XCTUnwrap(engine.sample(at:101))
        var two=surface;two.brightness=5
        engine.begin(from:current,cue:try cue(two,[.brightness]),at:101)
        XCTAssertEqual(engine.sample(at:101),current)
        let later=try XCTUnwrap(engine.sample(at:102))
        XCTAssertEqual(later[0].opacity,0.6,accuracy:1e-12);XCTAssertEqual(later[0].brightness,3)
        XCTAssertEqual(clock.time(at:102),2);XCTAssertTrue(clock.isPlaying)
        let track=AutomationTrack(name:"Master",surfaceID:surface.id,parameter:"opacity",keyframes:[AutomationKeyframe(time:0,value:0.25)])
        let project=Project(surfaces:current,cues:[try cue(two,[.brightness])],timeline:[track])
        var recalled=project;recalled.surfaces=try CueSelection.destination(from:project.surfaces,cue:project.cues[0])
        XCTAssertEqual(recalled.timeline,project.timeline);XCTAssertEqual(recalled.timelineSettings,project.timelineSettings)
        XCTAssertEqual(try TimelineEngine.apply(tracks:recalled.timeline,time:1,surfaces:recalled.surfaces)[0].opacity,0.25)
        XCTAssertThrowsError(try ProjectStore.validate(Project(cues:[try cue(two,[.brightness])],timeline:[track])))
        try ProjectStore.validate(Project(cues:[Cue(name:"Restore",surfaces:[surface])],timeline:[track]))
    }

    func testCaptureAndMaskValidationRejectMalformedSelections() throws {
        let s=Surface(),binding=CueBinding(surfaceID:UUID(),parameters:[.opacity])
        XCTAssertThrowsError(try CueSelection.capture(name:"Empty",surfaces:[s],bindings:[]))
        XCTAssertThrowsError(try CueSelection.capture(name:"Missing",surfaces:[s],bindings:[binding]))
        XCTAssertThrowsError(try cue(s,[]));XCTAssertThrowsError(try cue(s,[.opacity,.opacity]))
        let valid=try cue(s,[.opacity])
        var invalid=valid;invalid.bindings += invalid.bindings;XCTAssertThrowsError(try CueSelection.validate(invalid))
        invalid=valid;invalid.surfaces.append(Surface());XCTAssertThrowsError(try CueSelection.validate(invalid))
        invalid=valid;invalid.scope = .full;XCTAssertThrowsError(try CueSelection.validate(invalid))
        invalid=valid;invalid.name=String(repeating:"é",count:2049);XCTAssertThrowsError(try CueSelection.validate(invalid))
        invalid=valid;invalid.duration = .nan;XCTAssertThrowsError(try CueSelection.validate(invalid))
        invalid=valid;invalid.followAfter = -1;XCTAssertThrowsError(try CueSelection.validate(invalid))
        invalid=valid;invalid.bindings=Array(repeating:valid.bindings[0],count:4097);XCTAssertThrowsError(try CueSelection.validate(invalid))
        let engine=CueEngine();engine.begin(from:[s],cue:invalid,at:0)
        XCTAssertFalse(engine.isTransitioning);XCTAssertNil(engine.activeCueID)
        let boundary=try CueSelection.capture(name:String(repeating:"a",count:4096),surfaces:[s],bindings:valid.bindings)
        try CueSelection.validate(boundary)
    }

    func testLegacySchemasIgnoreExtensionsAndSchemaSixIsStrict() throws {
        let s=Surface(),capture=try cue(s,[.opacity])
        for version in 0...5 {
            var legacy=try object(Project(version:version,surfaces:[s],cues:[capture]))
            var entries=try XCTUnwrap(legacy["cues"] as? [[String:Any]])
            entries[0]["scope"]="future-extension";entries[0]["bindings"]=["not":"a binding"]
            legacy["cues"]=entries
            let migrated=try ProjectStore.load(from:write(legacy))
            XCTAssertEqual(migrated.version,6);XCTAssertEqual(migrated.cues[0].scope,.full);XCTAssertEqual(migrated.cues[0].bindings,[])
            let saved=scratch.appendingPathComponent("save-\(version).json")
            try ProjectStore.save(Project(version:version,surfaces:[s],cues:[capture]),to:saved)
            XCTAssertEqual(try ProjectStore.load(from:saved).cues[0].scope,.full)
        }
        let current=try object(Project(surfaces:[s],cues:[capture]))
        XCTAssertEqual(try ProjectStore.load(from:write(current)).cues,[capture])
        for key in ["scope","bindings"] {
            var broken=current,entries=try XCTUnwrap(current["cues"] as? [[String:Any]])
            entries[0].removeValue(forKey:key);broken["cues"]=entries
            XCTAssertThrowsError(try ProjectStore.load(from:write(broken)))
        }
        for mutation in 0..<4 {
            var broken=current,entries=try XCTUnwrap(current["cues"] as? [[String:Any]])
            if mutation == 0 { entries[0]["scope"]="unknown" }
            else {
                var bindings=try XCTUnwrap(entries[0]["bindings"] as? [[String:Any]])
                bindings[0]["parameters"]=mutation == 1 ? ["unknown"] : mutation == 2 ? ["opacity","opacity"] : []
                entries[0]["bindings"]=bindings
            }
            broken["cues"]=entries;XCTAssertThrowsError(try ProjectStore.load(from:write(broken)))
        }
    }

    func testPersistenceHistoryCollectionAndDormantResourceReferenceValidation() throws {
        let media=scratch.appendingPathComponent("original.png");try Data([1,3,5,7]).write(to:media)
        let asset=MediaAsset(name:"Original",path:media.path,kind:"image"),output=OutputConfig(),group=SurfaceGroup()
        let snapshot=Surface(mediaID:asset.id,outputID:output.id,groupID:group.id)
        let capture=try cue(snapshot,[.source,.routing,.outputGeometry])
        let before=Project(assets:[asset],surfaces:[],outputs:[output],groups:[group])
        var project=before;project.cues=[capture]
        let history=EditHistory();history.commit(before:before,after:project,label:"Capture partial")
        XCTAssertEqual(history.undo(current:project),before);XCTAssertEqual(history.redo(current:before),project)
        let folder=scratch.appendingPathComponent("collected"),url=try ProjectStore.collect(project,to:folder)
        try FileManager.default.removeItem(at:media)
        let loaded=try ProjectStore.load(from:url)
        XCTAssertEqual(loaded.cues,[capture]);XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:loaded.assets[0].path)),Data([1,3,5,7]))
        for parameter in [CueParameter.source,.routing,.outputGeometry] {
            let bound=try cue(snapshot,[parameter])
            XCTAssertThrowsError(try ProjectStore.validate(Project(cues:[bound])))
        }
        let dormant=try cue(snapshot,[.opacity])
        try ProjectStore.validate(Project(cues:[dormant]))
        let saved=scratch.appendingPathComponent("dormant.json")
        try ProjectStore.save(Project(cues:[dormant]),to:saved)
        XCTAssertEqual(try ProjectStore.load(from:saved).cues[0].surfaces,[snapshot])
        var malformed=dormant;malformed.surfaces[0].color=[]
        XCTAssertThrowsError(try ProjectStore.validate(Project(cues:[malformed])))
        malformed=dormant;malformed.surfaces[0].output=Array(repeating:Point2(0,0),count:4)
        XCTAssertThrowsError(try ProjectStore.validate(Project(cues:[malformed])))
    }

    func testGroupDissolveIgnoresUnselectedFramesAndGuardsPartialAppearance() throws {
        let group=SurfaceGroup(transform:.translation(x:0.1,y:0.2),opacity:0.5,enabled:false)
        let snapshot=Surface(opacity:0.8,groupID:group.id)
        let opacityOnly=try cue(snapshot,[.opacity])
        let track=AutomationTrack(name:"Dormant opacity",surfaceID:snapshot.id,parameter:"opacity",keyframes:[AutomationKeyframe(time:0,value:0.4)])
        var current=snapshot;current.groupID=nil
        let project=Project(surfaces:[current],cues:[opacityOnly],timeline:[track],groups:[group])
        let dissolved=try GroupEngine.dissolve(groupID:group.id,in:project)
        XCTAssertEqual(dissolved.groups,[]);XCTAssertEqual(dissolved.cues,[opacityOnly]);XCTAssertEqual(dissolved.timeline,[track])
        try ProjectStore.validate(dissolved)
        let geometryOnly=try cue(snapshot,[.outputGeometry])
        let guarded=Project(cues:[geometryOnly],groups:[group])
        XCTAssertThrowsError(try GroupEngine.dissolve(groupID:group.id,in:guarded))
        XCTAssertEqual(guarded.cues,[geometryOnly]);XCTAssertEqual(guarded.groups,[group])
        let opacityAndGeometry=try cue(snapshot,[.outputGeometry,.opacity])
        XCTAssertThrowsError(try GroupEngine.dissolve(groupID:group.id,in:Project(cues:[opacityAndGeometry],groups:[group])))
        let all=try cue(snapshot,[.outputGeometry,.opacity,.visibility])
        let baked=try GroupEngine.dissolve(groupID:group.id,in:Project(cues:[all],groups:[group]))
        XCTAssertEqual(baked.cues[0].surfaces[0].opacity,0.4);XCTAssertFalse(baked.cues[0].surfaces[0].enabled)
        XCTAssertNil(baked.cues[0].surfaces[0].groupID)
        XCTAssertEqual(baked.cues[0].surfaces[0].output,try snapshot.output.map { try group.transform.applying($0) })
        var neutral=group;neutral.opacity=1;neutral.enabled=true
        let justGeometry=try GroupEngine.dissolve(groupID:group.id,in:Project(cues:[geometryOnly],groups:[neutral]))
        XCTAssertEqual(justGeometry.cues[0].surfaces[0].opacity,snapshot.opacity)
        XCTAssertEqual(justGeometry.cues[0].surfaces[0].enabled,snapshot.enabled)
        // An unselected snapshot frame is irrelevant, but the current target's
        // direct membership determines inherited appearance during partial GO.
        var direct=snapshot;direct.opacity=0.6
        var dormant=snapshot;dormant.groupID=UUID()
        for parameters:[CueParameter] in [[.opacity],[.visibility],[.opacity,.visibility]] {
            let partial=try cue(dormant,parameters)
            let original=Project(surfaces:[direct],cues:[partial],groups:[group])
            let before=try GroupEngine.resolve(surfaces:CueSelection.destination(from:original.surfaces,cue:partial),groups:original.groups)
            let detached=try GroupEngine.dissolve(groupID:group.id,in:original)
            let after=try GroupEngine.resolve(surfaces:CueSelection.destination(from:detached.surfaces,cue:detached.cues[0]),groups:detached.groups)
            XCTAssertEqual(after[0].output,before[0].output)
            XCTAssertEqual(after[0].opacity,before[0].opacity);XCTAssertEqual(after[0].enabled,before[0].enabled)
            XCTAssertEqual(detached.cues[0].surfaces[0].groupID,dormant.groupID)
            XCTAssertEqual(detached.cues[0].surfaces[0].output,dormant.output)
            XCTAssertEqual(detached.cues[0].surfaces[0].opacity,parameters.contains(.opacity) ? 0.4 : dormant.opacity)
            XCTAssertEqual(detached.cues[0].surfaces[0].enabled,parameters.contains(.visibility) ? false : dormant.enabled)
            try ProjectStore.validate(detached)
        }
        // Leaving a baked frame while omitting appearance also changes the
        // result, even though the recalled snapshot itself is outside G.
        var outside=snapshot;outside.groupID=nil
        let leaving=try cue(outside,[.outputGeometry])
        XCTAssertThrowsError(try GroupEngine.dissolve(groupID:group.id,in:Project(surfaces:[snapshot],cues:[leaving],groups:[group])))
        let leavingWithOpacity=try cue(outside,[.outputGeometry,.opacity])
        XCTAssertThrowsError(try GroupEngine.dissolve(groupID:group.id,in:Project(surfaces:[snapshot],cues:[leavingWithOpacity],groups:[group])))
        let completeLeaving=try cue(outside,[.outputGeometry,.opacity,.visibility])
        let safeLeaving=try GroupEngine.dissolve(groupID:group.id,in:Project(surfaces:[snapshot],cues:[completeLeaving],groups:[group]))
        XCTAssertEqual(try CueSelection.destination(from:safeLeaving.surfaces,cue:safeLeaving.cues[0]),[outside])
        // A later full or geometry cue can change the target's frame. A fixed
        // appearance-only payload cannot be baked for both possible memberships.
        for parameters:[CueParameter] in [[.opacity],[.visibility],[.opacity,.visibility]] {
            let partial=try cue(dormant,parameters)
            let fullOutside=Cue(name:"Outside",surfaces:[outside])
            XCTAssertThrowsError(try GroupEngine.dissolve(groupID:group.id,in:Project(surfaces:[snapshot],cues:[partial,fullOutside],groups:[group])))
            XCTAssertThrowsError(try GroupEngine.dissolve(groupID:group.id,in:Project(surfaces:[snapshot],cues:[partial,completeLeaving],groups:[group])))
            // Unambiguous full-cue restoration into G still supports conversion
            // when the target is currently absent.
            let restored=Project(cues:[partial,Cue(name:"Inside",surfaces:[snapshot])],groups:[group])
            let bakedRestore=try GroupEngine.dissolve(groupID:group.id,in:restored)
            let before=try GroupEngine.resolve(surfaces:CueSelection.destination(from:[snapshot],cue:partial),groups:[group])
            let after=try GroupEngine.resolve(surfaces:CueSelection.destination(from:bakedRestore.cues[1].surfaces,cue:bakedRestore.cues[0]),groups:[])
            XCTAssertEqual(after[0].opacity,before[0].opacity);XCTAssertEqual(after[0].enabled,before[0].enabled)
        }
    }
}
