import XCTest
import Foundation
@testable import MappingCore

final class AutomationRecordingTests:XCTestCase {
    private func track(_ surface:Surface=Surface(),parameter:String="opacity",keys:[AutomationKeyframe]?=nil) -> AutomationTrack {
        AutomationTrack(name:"Original track",surfaceID:surface.id,parameter:parameter,
                        keyframes:keys ?? [AutomationKeyframe(time:0,value:0.2),AutomationKeyframe(time:10,value:0.8)])
    }
    private func changed(_ source:AutomationTrack,_ value:Double=0.4) -> AutomationTrack {
        var track=source;track.keyframes[0].value=value;return track
    }

    func testInclusiveSpanReplacementPreservesOutsideKeysAndTrackIdentity() throws {
        let keys=[AutomationKeyframe(time:0,value:0.1,interpolation:.bezier,control1:Point2(0.2,0.7),control2:Point2(0.8,0.9)),
                  AutomationKeyframe(time:2,value:0.3,interpolation:.hold),AutomationKeyframe(time:4,value:0.7),
                  AutomationKeyframe(time:6,value:0.8,interpolation:.bezier,control1:Point2(0.1,0.3),control2:Point2(0.5,0.8)),
                  AutomationKeyframe(time:10,value:0.9,interpolation:.hold)]
        let original=track(keys:keys)
        var recording=try AutomationRecording(track:original,time:2,value:0.3,duration:10)
        try recording.append(time:3,value:0.6);try recording.append(time:6,value:0.5)
        let result=try recording.finish()
        XCTAssertEqual(result.id,original.id);XCTAssertEqual(result.name,original.name)
        XCTAssertEqual(result.surfaceID,original.surfaceID);XCTAssertEqual(result.parameter,original.parameter);XCTAssertEqual(result.enabled,original.enabled)
        XCTAssertEqual(result.keyframes.first,keys.first);XCTAssertEqual(result.keyframes.last,keys.last)
        XCTAssertEqual(result.keyframes.map(\.time),[0,2,3,6,10])
        XCTAssertEqual(Array(result.keyframes[1...3]),[AutomationKeyframe(time:2,value:0.3),AutomationKeyframe(time:3,value:0.6),AutomationKeyframe(time:6,value:0.5)])
        XCTAssertEqual(original.keyframes,keys);XCTAssertTrue(recording.changed)
        XCTAssertEqual(recording.sampleCount,3);XCTAssertEqual(recording.lastTime,6);XCTAssertEqual(recording.lastValue,0.5)
        XCTAssertEqual(try XCTUnwrap(Automation.value(at:2.5,keyframes:result.keyframes)),0.45,accuracy:1e-12)
    }

    func testSameTimestampReplacementNoOpAndRejectedSamplesAreAtomic() throws {
        var recording=try AutomationRecording(track:track(),time:1,value:0.3,duration:10)
        XCTAssertFalse(recording.changed)
        try recording.append(time:1,value:0.3);XCTAssertFalse(recording.changed);XCTAssertEqual(recording.sampleCount,1)
        try recording.append(time:1,value:0.9);XCTAssertTrue(recording.changed);XCTAssertEqual(recording.sampleCount,1)
        XCTAssertEqual(recording.track.keyframes.map(\.time),[0,1,10])
        XCTAssertEqual(recording.lastValue,0.9)
        try recording.append(time:1,value:0.3);XCTAssertTrue(recording.changed)
        let prior=recording.track
        for pair in [(0.9,0.4),(Double.nan,0.4),(Double.infinity,0.4),(-1,0.4),(11,0.4),(2,Double.nan),(2,Double.infinity),(2,-0.1),(2,1.1)] {
            XCTAssertThrowsError(try recording.append(time:pair.0,value:pair.1))
            XCTAssertEqual(recording.track,prior);XCTAssertEqual(recording.sampleCount,1)
            XCTAssertEqual(recording.lastTime,1);XCTAssertEqual(recording.lastValue,0.3);XCTAssertTrue(recording.changed)
        }
        var noMovement=try AutomationRecording(track:track(),time:0,value:0.2,duration:10)
        _ = try noMovement.finish(time:5)
        XCTAssertFalse(noMovement.changed);XCTAssertEqual(noMovement.sampleCount,2)
    }

    func testParameterRangesInitialValidationAndDisabledTracks() throws {
        for parameter in TimelineEngine.parameters {
            let range=try TimelineEngine.parameterRange(parameter)
            let source=track(parameter:parameter,keys:[AutomationKeyframe(time:0,value:range.lowerBound),AutomationKeyframe(time:10,value:range.upperBound)])
            var recording=try AutomationRecording(track:source,time:0,value:range.lowerBound,duration:10)
            try recording.append(time:10,value:range.upperBound)
            XCTAssertEqual(recording.track.keyframes.map(\.value),[range.lowerBound,range.upperBound])
            XCTAssertThrowsError(try recording.append(time:10,value:range.lowerBound-0.001))
            XCTAssertThrowsError(try recording.append(time:10,value:range.upperBound+0.001))
        }
        let source=track()
        for duration in [0.0,-1,Double.nan,Double.infinity,ShowRuntime.maximumTime+1] {
            XCTAssertThrowsError(try AutomationRecording(track:source,time:0,value:0.2,duration:duration))
        }
        for time in [-1.0,11,Double.nan,Double.infinity] {
            XCTAssertThrowsError(try AutomationRecording(track:source,time:time,value:0.2,duration:10))
        }
        var invalid=source;invalid.enabled=false
        XCTAssertThrowsError(try AutomationRecording(track:invalid,time:0,value:0.2,duration:10))
        invalid=source;invalid.parameter="unknown"
        XCTAssertThrowsError(try AutomationRecording(track:invalid,time:0,value:0.2,duration:10))
        invalid=source;invalid.keyframes.reverse()
        XCTAssertThrowsError(try AutomationRecording(track:invalid,time:0,value:0.2,duration:10))
        invalid=source;invalid.keyframes[0].value=2
        XCTAssertThrowsError(try AutomationRecording(track:invalid,time:0,value:0.2,duration:10))
        XCTAssertThrowsError(try AutomationRecording(track:source,time:0,value:0.2,duration:5))
    }

    func testSessionAndMergedTrackBoundsAllowReplacementAtCapacity() throws {
        let original=track(keys:[AutomationKeyframe(time:0,value:0.2)])
        var recording=try AutomationRecording(track:original,time:0,value:0.2,duration:5000)
        for index in 1..<4096 { try recording.append(time:Double(index),value:index % 2 == 0 ? 0.2 : 0.4) }
        XCTAssertEqual(recording.sampleCount,4096);XCTAssertEqual(recording.track.keyframes.count,4096)
        let prior=recording.track
        XCTAssertThrowsError(try recording.append(time:4096,value:0.5))
        XCTAssertEqual(recording.track,prior);XCTAssertEqual(recording.lastTime,4095)
        try recording.append(time:4095,value:0.8)
        XCTAssertEqual(recording.sampleCount,4096);XCTAssertEqual(recording.lastValue,0.8)
        let full=track(keys:(0..<4096).map { AutomationKeyframe(time:Double($0),value:0.3) })
        XCTAssertThrowsError(try AutomationRecording(track:full,time:0.5,value:0.4,duration:5000))
        var replacing=try AutomationRecording(track:full,time:1000,value:0.3,duration:5000)
        let before=replacing.track
        XCTAssertThrowsError(try replacing.append(time:1000.5,value:0.5))
        XCTAssertEqual(replacing.track,before);XCTAssertEqual(replacing.sampleCount,1);XCTAssertFalse(replacing.changed)
        try replacing.append(time:1001,value:0.5)
        XCTAssertEqual(replacing.track.keyframes.count,4096);XCTAssertTrue(replacing.changed)
    }

    func testFinishOrdinaryKeysSaveAndSingleHistoryCommit() throws {
        let surface=Surface(),original=track(surface)
        var recording=try AutomationRecording(track:original,time:1,value:0.26,duration:10)
        try recording.append(time:2,value:0.6)
        let beforeFinish=recording.track
        XCTAssertThrowsError(try recording.finish(time:1.5));XCTAssertEqual(recording.track,beforeFinish)
        let result=try recording.finish(time:3)
        XCTAssertEqual(result.keyframes.map(\.time),[0,1,2,3,10]);XCTAssertEqual(result.keyframes[3],AutomationKeyframe(time:3,value:0.6))
        let before=Project(surfaces:[surface],timeline:[original]),history=EditHistory()
        var after=before;after.timeline=[result]
        history.commit(before:before,after:after,label:"Record gesture")
        XCTAssertEqual(history.undo(current:after),before);XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.redo(current:before),after)
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueRecording-"+UUID().uuidString+".json")
        defer { try? FileManager.default.removeItem(at:url) }
        try ProjectStore.save(after,to:url)
        let loaded=try ProjectStore.load(from:url)
        XCTAssertEqual(loaded.version,6);XCTAssertEqual(loaded.timeline,[result])
    }

    func testTracksOnlyConfigurePreservesNaturalClockWithoutDiscontinuity() throws {
        let surface=Surface(),original=track(surface),runtime=ShowRuntime(),settings=TimelineSettings(duration:10)
        try runtime.configure(settings:settings,tracks:[original],surfaces:[surface],at:100)
        _ = runtime.tick(at:100);runtime.play(at:100)
        XCTAssertEqual(runtime.tick(at:101).time,1)
        try runtime.configure(settings:settings,tracks:[changed(original)],surfaces:[surface],at:102)
        let edited=runtime.tick(at:102)
        XCTAssertEqual(edited.time,2);XCTAssertTrue(edited.isPlaying);XCTAssertFalse(edited.discontinuity)
        XCTAssertEqual(try runtime.apply(surfaces:[surface])[0].opacity,0.48,accuracy:1e-12)
        let later=runtime.tick(at:103)
        XCTAssertEqual(later.time,3);XCTAssertFalse(later.discontinuity)
        runtime.seek(to:5,at:104)
        try runtime.configure(settings:settings,tracks:[changed(original,0.5)],surfaces:[surface],at:104)
        XCTAssertTrue(runtime.tick(at:104).discontinuity)
        XCTAssertFalse(runtime.tick(at:104).discontinuity)
        var resized=settings;resized.duration=11;resized.loopEnd=11
        try runtime.configure(settings:resized,tracks:[changed(original,0.5)],surfaces:[surface],at:104)
        XCTAssertTrue(runtime.tick(at:104).discontinuity)
        try runtime.configure(settings:resized,tracks:[changed(original,0.5)],surfaces:[surface,Surface()],at:104)
        XCTAssertTrue(runtime.tick(at:104).discontinuity)
    }

    func testTrackEditsRetainPauseLoopCrossingsAndExactlyOnceEvents() throws {
        let surface=Surface(),original=track(surface),cue=UUID()
        let event=TimelineMarker(time:1,action:.cue,cueID:cue),pause=TimelineMarker(time:2)
        let settings=TimelineSettings(duration:10,markers:[event,pause]),runtime=ShowRuntime()
        try runtime.configure(settings:settings,tracks:[original],surfaces:[surface],cueIDs:[cue],at:0)
        _ = runtime.tick(at:0);runtime.play(at:0)
        try runtime.configure(settings:settings,tracks:[changed(original)],surfaces:[surface],cueIDs:[cue],at:3)
        let crossing=runtime.tick(at:3)
        XCTAssertEqual(crossing.time,2);XCTAssertFalse(crossing.isPlaying);XCTAssertTrue(crossing.discontinuity)
        XCTAssertEqual(crossing.cueIDs,[cue]);XCTAssertEqual(crossing.firedMarkerIDs,[event.id,pause.id])
        XCTAssertEqual(runtime.tick(at:4).firedMarkerIDs,[]);XCTAssertFalse(runtime.tick(at:4).discontinuity)
        let shortTrack=track(surface,keys:[AutomationKeyframe(time:0,value:0.2),AutomationKeyframe(time:2,value:0.8)])
        let looping=ShowRuntime(),loopSettings=TimelineSettings(duration:2,loopEnabled:true,markers:[event])
        try looping.configure(settings:loopSettings,tracks:[shortTrack],surfaces:[surface],cueIDs:[cue],at:0)
        _ = looping.tick(at:0);looping.play(at:0)
        try looping.configure(settings:loopSettings,tracks:[changed(shortTrack)],surfaces:[surface],cueIDs:[cue],at:5)
        // A second edit before delivery must retain the same queued traversal.
        try looping.configure(settings:loopSettings,tracks:[changed(shortTrack,0.5)],surfaces:[surface],cueIDs:[cue],at:5)
        let wrapped=looping.tick(at:5)
        XCTAssertEqual(wrapped.time,1);XCTAssertTrue(wrapped.isPlaying);XCTAssertTrue(wrapped.discontinuity)
        XCTAssertEqual(wrapped.cueIDs,[cue,cue,cue]);XCTAssertEqual(wrapped.firedMarkerIDs,[event.id,event.id,event.id])
        let next=looping.tick(at:5.2)
        XCTAssertEqual(next.time,1.2,accuracy:1e-12);XCTAssertEqual(next.firedMarkerIDs,[]);XCTAssertFalse(next.discontinuity)
    }

    func testProjectAggregateBudgetAndRejectedConfigureRemainAtomic() throws {
        let surfaces=(0..<17).map { _ in Surface() }
        let full=(0..<4096).map { AutomationKeyframe(time:Double($0),value:0.3) }
        var tracks=surfaces.enumerated().map { index,surface in
            track(surface,keys:index == 0 ? Array(full.dropLast()) : index == 16 ? [full[0]] : full)
        }
        let settings=TimelineSettings(duration:5000),before=Project(surfaces:surfaces,timeline:tracks,timelineSettings:settings)
        try ProjectStore.validate(before)
        var recording=try AutomationRecording(track:tracks[0],time:1000.5,value:0.3,duration:5000)
        try recording.append(time:1000.5,value:0.6)
        tracks[0]=recording.track
        var oversized=before;oversized.timeline=tracks
        XCTAssertThrowsError(try ProjectStore.validate(oversized));XCTAssertEqual(before.timeline[0].keyframes.count,4095)
        let runtime=ShowRuntime()
        try runtime.configure(settings:settings,tracks:before.timeline,surfaces:surfaces,at:0)
        _ = runtime.tick(at:0);runtime.play(at:0)
        XCTAssertThrowsError(try runtime.configure(settings:settings,tracks:tracks,surfaces:surfaces,at:2))
        let tick=runtime.tick(at:3)
        XCTAssertEqual(tick.time,3);XCTAssertTrue(tick.isPlaying);XCTAssertFalse(tick.discontinuity)
        XCTAssertEqual(try runtime.apply(surfaces:surfaces)[0].opacity,0.3)
    }
}
