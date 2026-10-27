import XCTest
import Foundation
@testable import MappingCore

final class TimelineRuntimeTests:XCTestCase {
    private func track(_ surface:Surface,_ keys:[AutomationKeyframe],parameter:String="opacity",enabled:Bool=true) -> AutomationTrack {
        AutomationTrack(name:"Original curve",surfaceID:surface.id,parameter:parameter,keyframes:keys,enabled:enabled)
    }
    private func runtime(settings:TimelineSettings,tracks:[AutomationTrack]=[],surfaces:[Surface]=[],cues:Set<UUID>=[]) throws -> ShowRuntime {
        let value=ShowRuntime();try value.configure(settings:settings,tracks:tracks,surfaces:surfaces,cueIDs:cues,at:0);_ = value.tick(at:0);return value
    }
    func testHoldLinearBezierExactKeysAndImmutableCurve() throws {
        let keys=[AutomationKeyframe(time:0,value:0.2,interpolation:.hold),AutomationKeyframe(time:2,value:0.8),AutomationKeyframe(time:4,value:0.4)]
        XCTAssertEqual(try Automation.value(at:-10,keyframes:keys),0.2)
        XCTAssertEqual(try Automation.value(at:1.99,keyframes:keys),0.2)
        XCTAssertEqual(try Automation.value(at:2,keyframes:keys),0.8)
        XCTAssertEqual(try XCTUnwrap(Automation.value(at:3,keyframes:keys)),0.6,accuracy:1e-12)
        XCTAssertEqual(try Automation.value(at:400,keyframes:keys),0.4)
        var curveKeys=[AutomationKeyframe(time:1,value:2,interpolation:.bezier,control1:Point2(0,0.75),control2:Point2(1,0.75)),AutomationKeyframe(time:9,value:10)]
        let curve=try AutomationCurve(keyframes:curveKeys)
        // Independent polynomial at t=.25: x=.15625, y=.4375.
        XCTAssertEqual(try XCTUnwrap(curve.value(at:2.25)),5.5,accuracy:1e-10)
        XCTAssertEqual(try curve.value(at:1),2);XCTAssertEqual(try curve.value(at:9),10)
        curveKeys[0].value=9
        XCTAssertEqual(try curve.value(at:1),2)
        XCTAssertNil(try AutomationCurve(keyframes:[]).value(at:0))
        XCTAssertThrowsError(try curve.value(at:.nan))
        for bad in [Point2(-0.1,0),Point2(0,1.01),Point2(.nan,0)] {
            var invalid=keys;invalid[0].control1=bad
            XCTAssertThrowsError(try AutomationCurve(keyframes:invalid))
        }
        var reversed=keys;reversed[0].control1.x=0.9;reversed[0].control2.x=0.1
        XCTAssertThrowsError(try AutomationCurve(keyframes:reversed))
    }
    func testCompiledProgramBinarySearchDisabledAndDormantTargets() throws {
        let surface=Surface(),dormant=Surface()
        let keys=(0..<4096).map {AutomationKeyframe(time:Double($0),value:Double($0)/4095)}
        let fade=track(surface,keys),gamma=track(surface,[AutomationKeyframe(time:0,value:2)],parameter:"gamma"),off=track(surface,[AutomationKeyframe(time:0,value:0)],parameter:"brightness",enabled:false)
        let hidden=track(dormant,[AutomationKeyframe(time:0,value:0.3)])
        let program=try TimelineProgram(tracks:[fade,gamma,off,hidden],surfaces:[surface,dormant])
        for time in [0.0,1.5,2048,4095,5000] {
            let sampled=try program.apply(time:time,surfaces:[surface])
            XCTAssertEqual(sampled[0].opacity,min(time,4095)/4095,accuracy:1e-12)
            XCTAssertEqual(sampled[0].gamma,2);XCTAssertEqual(sampled[0].brightness,1)
        }
        XCTAssertEqual(try program.apply(time:1,surfaces:[]),[])
        XCTAssertEqual(try program.apply(time:1,surfaces:[dormant])[0].opacity,0.3)
        XCTAssertThrowsError(try program.apply(time:.infinity,surfaces:[surface]))
        XCTAssertThrowsError(try program.apply(time:0,surfaces:[surface,surface]))
        var unknown=fade;unknown.surfaceID=UUID()
        XCTAssertThrowsError(try TimelineProgram(tracks:[unknown],surfaces:[surface]))
        var duplicate=fade;duplicate.id=UUID()
        XCTAssertThrowsError(try TimelineProgram(tracks:[fade,duplicate],surfaces:[surface]))
    }
    func testIndependentTransportPlayPauseSeekEndAndInvalidHostTime() throws {
        let surface=Surface()
        let show=try runtime(settings:TimelineSettings(duration:5),tracks:[track(surface,[AutomationKeyframe(time:0,value:0),AutomationKeyframe(time:5,value:1)])],surfaces:[surface])
        show.play(at:100)
        XCTAssertEqual(show.tick(at:102).time,2)
        XCTAssertEqual(try show.apply(surfaces:[surface])[0].opacity,0.4,accuracy:1e-12)
        show.pause(at:102.5);XCTAssertEqual(show.time,2.5);XCTAssertFalse(show.isPlaying)
        XCTAssertEqual(show.tick(at:999).time,2.5)
        show.seek(to:1,at:1000);XCTAssertTrue(show.tick(at:1000).discontinuity)
        show.play(at:1001);XCTAssertEqual(show.tick(at:1002).time,2)
        let end=show.tick(at:1010);XCTAssertEqual(end.time,5);XCTAssertFalse(end.isPlaying);XCTAssertTrue(end.discontinuity)
        show.play(at:2000);XCTAssertEqual(show.time,0);XCTAssertEqual(show.tick(at:2001).time,1)
        show.seek(to:.nan,at:2001);show.pause(at:.infinity);XCTAssertEqual(show.time,1);XCTAssertTrue(show.isPlaying)
        XCTAssertEqual(show.tick(at:.nan).time,1)
        XCTAssertEqual(show.tick(at:1999).time,1) // Backward host sample cannot rewind anchor.
        XCTAssertEqual(show.tick(at:2002).time,2)
        show.seek(to:5,at:2002);XCTAssertFalse(show.tick(at:2002).isPlaying)
        show.stop(at:2003);XCTAssertEqual(show.time,0);XCTAssertFalse(show.isPlaying)
        show.play(at:-Double.greatestFiniteMagnitude)
        let huge=show.tick(at:Double.greatestFiniteMagnitude)
        XCTAssertEqual(huge.time,5);XCTAssertFalse(huge.isPlaying)
    }
    func testMarkerCrossingsPauseResumeSeekAndExactBoundaries() throws {
        let cue=UUID(),zero=TimelineMarker(name:"Zero",time:0,action:.cue,cueID:cue),fire=TimelineMarker(name:"Cue",time:1,action:.cue,cueID:cue),pause=TimelineMarker(name:"Wait",time:2),end=TimelineMarker(name:"End cue",time:4,action:.cue,cueID:cue)
        XCTAssertThrowsError(try TimelineSettings.validate(TimelineSettings(duration:4,markers:[zero]),tracks:[],cueIDs:[cue]))
        let show=try runtime(settings:TimelineSettings(duration:4,markers:[pause,end,fire]),cues:[cue])
        show.play(at:10)
        let first=show.tick(at:11);XCTAssertEqual(first.cueIDs,[cue]);XCTAssertEqual(first.firedMarkerIDs,[fire.id])
        XCTAssertEqual(show.tick(at:11).firedMarkerIDs,[])
        let stopped=show.tick(at:14)
        XCTAssertEqual(stopped.time,2);XCTAssertFalse(stopped.isPlaying);XCTAssertEqual(stopped.firedMarkerIDs,[pause.id]);XCTAssertTrue(stopped.discontinuity)
        show.play(at:20);XCTAssertEqual(show.tick(at:20).firedMarkerIDs,[])
        let final=show.tick(at:22)
        XCTAssertEqual(final.time,4);XCTAssertEqual(final.firedMarkerIDs,[end.id]);XCTAssertFalse(final.isPlaying)
        show.seek(to:3,at:30);XCTAssertEqual(show.tick(at:30).firedMarkerIDs,[])
        show.seek(to:1,at:31);show.play(at:31)
        XCTAssertEqual(show.tick(at:31).firedMarkerIDs,[]) // Landing at exact cue time is not crossing it.
        XCTAssertEqual(show.tick(at:31.5).firedMarkerIDs,[])
    }
    func testLoopRangeExactWrapMarkerOrderingAndLongElapsedBudget() throws {
        let cue=UUID(),start=TimelineMarker(name:"Loop entry",time:2,action:.cue,cueID:cue),middle=TimelineMarker(name:"Middle",time:3,action:.cue,cueID:cue),end=TimelineMarker(name:"End",time:4,action:.cue,cueID:cue)
        let settings=TimelineSettings(duration:8,loopEnabled:true,loopStart:2,loopEnd:4,markers:[end,start,middle])
        let show=try runtime(settings:settings,cues:[cue]);show.play(at:0)
        let first=show.tick(at:4)
        XCTAssertEqual(first.time,2);XCTAssertEqual(first.firedMarkerIDs,[start.id,middle.id,end.id]);XCTAssertTrue(first.discontinuity)
        let second=show.tick(at:6)
        XCTAssertEqual(second.time,2);XCTAssertEqual(second.firedMarkerIDs,[middle.id,end.id])
        let partial=show.tick(at:7.5);XCTAssertEqual(partial.time,3.5);XCTAssertEqual(partial.firedMarkerIDs,[middle.id])
        let large=show.tick(at:1000000.25)
        XCTAssertTrue(large.eventsSkipped);XCTAssertTrue(large.firedMarkerIDs.count<=ShowRuntime.eventBudget)
        XCTAssertEqual(large.time,2.25,accuracy:1e-9);XCTAssertTrue(large.isPlaying)
        XCTAssertEqual(show.tick(at:1000000.25).firedMarkerIDs,[])
    }
    func testEventBudgetStillHonorsPauseAndAtomicConfiguration() throws {
        let cue=UUID()
        var markers=(1...300).map {TimelineMarker(name:"Cue \($0)",time:Double($0)/1000,action:.cue,cueID:cue)}
        let pause=TimelineMarker(name:"Mandatory wait",time:0.5);markers.append(pause)
        let show=try runtime(settings:TimelineSettings(duration:1,loopEnabled:true,loopEnd:1,markers:markers),cues:[cue]);show.play(at:0)
        let sampled=show.tick(at:100000)
        XCTAssertEqual(sampled.time,0.5);XCTAssertFalse(sampled.isPlaying);XCTAssertTrue(sampled.eventsSkipped)
        XCTAssertEqual(sampled.firedMarkerIDs.count,ShowRuntime.eventBudget)
        let before=show.settings
        var bad=before;bad.loopEnd=0
        XCTAssertThrowsError(try show.configure(settings:bad,tracks:[],surfaces:[],cueIDs:[cue],at:100001))
        XCTAssertEqual(show.settings,before);XCTAssertEqual(show.time,0.5)
        let unchanged=try runtime(settings:TimelineSettings(duration:10))
        unchanged.play(at:100)
        try unchanged.configure(settings:unchanged.settings,tracks:[],surfaces:[],at:102)
        XCTAssertEqual(unchanged.tick(at:103).time,3) // Same config cannot reset host anchor.
        var shortened=unchanged.settings;shortened.duration=2;shortened.loopEnd=2
        try unchanged.configure(settings:shortened,tracks:[],surfaces:[],at:104)
        XCTAssertEqual(unchanged.time,2);XCTAssertFalse(unchanged.isPlaying);XCTAssertTrue(unchanged.tick(at:104).discontinuity)
        let cueA=UUID(),cueB=UUID()
        let first=TimelineMarker(time:1,action:.cue,cueID:cueA),second=TimelineMarker(time:1.5,action:.cue,cueID:cueB),wait=TimelineMarker(time:2)
        let naturalSettings=TimelineSettings(duration:5,markers:[first,second,wait])
        let natural=try runtime(settings:naturalSettings,cues:[cueA,cueB]);natural.play(at:0)
        var edited=naturalSettings;edited.duration=6;edited.loopEnd=6
        try natural.configure(settings:edited,tracks:[],surfaces:[],cueIDs:[cueA,cueB],at:1.25)
        // An unrelated second edit must retain the already queued first crossing.
        edited.duration=7;edited.loopEnd=7
        try natural.configure(settings:edited,tracks:[],surfaces:[],cueIDs:[cueA,cueB],at:1.75)
        let delivered=natural.tick(at:2.5)
        XCTAssertEqual(delivered.cueIDs,[cueA,cueB]);XCTAssertEqual(delivered.firedMarkerIDs,[first.id,second.id,wait.id])
        XCTAssertEqual(delivered.time,2);XCTAssertFalse(delivered.isPlaying)
        XCTAssertEqual(natural.tick(at:3).firedMarkerIDs,[])
        natural.stop(at:10);natural.play(at:10)
        edited.duration=8;edited.loopEnd=8
        try natural.configure(settings:edited,tracks:[],surfaces:[],cueIDs:[cueA,cueB],at:11.25)
        natural.seek(to:0,at:11.25)
        XCTAssertEqual(natural.tick(at:11.25).firedMarkerIDs,[]) // Explicit seek discards queued natural events.
        natural.stop(at:20);natural.play(at:20)
        edited.duration=9;edited.loopEnd=9
        try natural.configure(settings:edited,tracks:[],surfaces:[],cueIDs:[cueA,cueB],at:21.25)
        var invalid=edited;invalid.duration=0
        XCTAssertThrowsError(try natural.configure(settings:invalid,tracks:[],surfaces:[],cueIDs:[cueA,cueB],at:21.5))
        XCTAssertEqual(natural.tick(at:21.25).firedMarkerIDs,[first.id]) // Rejected config did not drain/drop queued events.
        edited.duration=10;edited.loopEnd=10
        try natural.configure(settings:edited,tracks:[],surfaces:[],cueIDs:[cueA,cueB],at:21.75)
        natural.stop(at:21.75);XCTAssertEqual(natural.tick(at:22).firedMarkerIDs,[])
        let queuedBudget=try runtime(settings:TimelineSettings(duration:1,markers:markers),cues:[cue]);queuedBudget.play(at:0)
        var expanded=queuedBudget.settings;expanded.duration=2;expanded.loopEnd=2
        try queuedBudget.configure(settings:expanded,tracks:[],surfaces:[],cueIDs:[cue],at:0.2)
        let bounded=queuedBudget.tick(at:0.6)
        XCTAssertEqual(bounded.firedMarkerIDs.count,ShowRuntime.eventBudget);XCTAssertTrue(bounded.eventsSkipped)
        XCTAssertEqual(bounded.time,0.5);XCTAssertFalse(bounded.isPlaying)
    }
    func testSettingsAndMarkerReferenceValidation() throws {
        let surface=Surface(),cue=UUID()
        let tracks=[track(surface,[AutomationKeyframe(time:0,value:0),AutomationKeyframe(time:20,value:1)])]
        let inferred=Project(surfaces:[surface],timeline:tracks)
        XCTAssertEqual(inferred.timelineSettings.duration,20);XCTAssertEqual(inferred.timelineSettings.loopEnd,20)
        try ProjectStore.validate(inferred)
        var bad=inferred;bad.timelineSettings.duration=10;bad.timelineSettings.loopEnd=10
        XCTAssertThrowsError(try ProjectStore.validate(bad))
        for duration in [0.0,-1,31536001,.nan,.infinity] {
            XCTAssertThrowsError(try TimelineSettings.validate(TimelineSettings(duration:duration),tracks:[],cueIDs:[]))
        }
        let m=TimelineMarker(time:1,action:.cue,cueID:cue)
        XCTAssertThrowsError(try TimelineSettings.validate(TimelineSettings(markers:[m]),tracks:[],cueIDs:[]))
        XCTAssertThrowsError(try TimelineSettings.validate(TimelineSettings(markers:[m,m]),tracks:[],cueIDs:[cue]))
        var sameTime=m;sameTime.id=UUID()
        XCTAssertThrowsError(try TimelineSettings.validate(TimelineSettings(markers:[m,sameTime]),tracks:[],cueIDs:[cue]))
        var pause=m;pause.action = .pause
        XCTAssertThrowsError(try TimelineSettings.validate(TimelineSettings(markers:[pause]),tracks:[],cueIDs:[cue]))
        var outside=m;outside.time=11
        XCTAssertThrowsError(try TimelineSettings.validate(TimelineSettings(markers:[outside]),tracks:[],cueIDs:[cue]))
        XCTAssertThrowsError(try TimelineSettings.validate(TimelineSettings(markers:(0...1024).map {TimelineMarker(time:Double($0)/200)}),tracks:[],cueIDs:[]))
        let missingFlag=try JSONDecoder().decode(TimelineSettings.self,from:Data("{\"duration\":3,\"loopEnabled\":false,\"loopStart\":0,\"loopEnd\":3,\"markers\":[]}".utf8))
        XCTAssertTrue(missingFlag.stopAtEnd)
        let newShow=try runtime(settings:missingFlag);newShow.play(at:0)
        XCTAssertEqual(newShow.tick(at:60).time,3);XCTAssertFalse(newShow.isPlaying)
        let continuing=try runtime(settings:TimelineSettings(duration:10,stopAtEnd:false));continuing.play(at:0)
        XCTAssertEqual(continuing.tick(at:60).time,60);XCTAssertTrue(continuing.isPlaying)
        var shortHorizon=continuing.settings;shortHorizon.duration=2;shortHorizon.loopEnd=2
        try continuing.configure(settings:shortHorizon,tracks:[],surfaces:[],at:60)
        XCTAssertEqual(continuing.tick(at:61).time,61);XCTAssertTrue(continuing.isPlaying)
        let repeating=try runtime(settings:TimelineSettings(duration:8,loopEnabled:true,loopStart:2,loopEnd:4,stopAtEnd:false))
        repeating.play(at:0);XCTAssertEqual(repeating.tick(at:5).time,3);XCTAssertTrue(repeating.isPlaying)
    }
    func testLegacyLinearNormalizationSchemaFiveHistoryAndPortableRoundTrip() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueTimelineRuntime-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:directory)}
        let file=directory.appendingPathComponent("project.json"),surface=Surface()
        let fancy=track(surface,[AutomationKeyframe(time:0,value:0,interpolation:.hold),AutomationKeyframe(time:15,value:1,interpolation:.bezier,control1:Point2(0,1),control2:Point2(1,0))])
        for version in 0...4 {
            let legacy=Project(version:version,surfaces:[surface],timeline:[fancy],timelineSettings:TimelineSettings(duration:20,markers:[TimelineMarker(time:4)]))
            try JSONEncoder().encode(legacy).write(to:file)
            let migrated=try ProjectStore.load(from:file)
            XCTAssertEqual(migrated.version,Project.currentVersion);XCTAssertEqual(migrated.timelineSettings.duration,15)
            XCTAssertEqual(migrated.timelineSettings.markers,[]);XCTAssertFalse(migrated.timelineSettings.loopEnabled)
            XCTAssertFalse(migrated.timelineSettings.stopAtEnd)
            let legacyRuntime=try runtime(settings:migrated.timelineSettings,tracks:migrated.timeline,surfaces:migrated.surfaces)
            legacyRuntime.play(at:0);let longMovie=legacyRuntime.tick(at:60)
            XCTAssertEqual(longMovie.time,60);XCTAssertTrue(longMovie.isPlaying)
            XCTAssertEqual(try legacyRuntime.apply(surfaces:migrated.surfaces)[0].opacity,1)
            legacyRuntime.seek(to:120,at:61);XCTAssertEqual(legacyRuntime.tick(at:61).time,120)
            legacyRuntime.seek(to:Double.greatestFiniteMagnitude,at:62)
            let globalEnd=legacyRuntime.tick(at:62);XCTAssertEqual(globalEnd.time,ShowRuntime.maximumTime);XCTAssertFalse(globalEnd.isPlaying)
            XCTAssertTrue(migrated.timeline[0].keyframes.allSatisfy {$0.interpolation == .linear && $0.control1 == Point2(1.0/3,1.0/3) && $0.control2 == Point2(2.0/3,2.0/3)})
            XCTAssertEqual(try TimelineEngine.apply(tracks:migrated.timeline,time:7.5,surfaces:migrated.surfaces)[0].opacity,0.5)
            try ProjectStore.save(legacy,to:file)
            XCTAssertEqual(try ProjectStore.load(from:file).timelineSettings,migrated.timelineSettings)
        }
        let cue=Cue(name:"Original scene",surfaces:[surface]),before=Project(surfaces:[surface])
        let after=Project(surfaces:[surface],cues:[cue],timeline:[fancy],timelineSettings:TimelineSettings(duration:20,loopEnabled:true,loopStart:1,loopEnd:18,markers:[TimelineMarker(time:3,action:.cue,cueID:cue.id),TimelineMarker(time:5)]))
        try ProjectStore.save(after,to:file);XCTAssertEqual(try ProjectStore.load(from:file),after)
        let collected=try ProjectStore.collect(after,to:directory.appendingPathComponent("portable"))
        XCTAssertEqual(try ProjectStore.load(from:collected),after)
        let history=EditHistory();history.commit(before:before,after:after,label:"Timeline")
        XCTAssertEqual(history.undo(current:after),before);XCTAssertEqual(history.redo(current:before),after)
    }
}
