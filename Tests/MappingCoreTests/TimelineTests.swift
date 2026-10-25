import XCTest
import Foundation
@testable import MappingCore

final class TimelineTests:XCTestCase {
    func testFixturesAndTimelinePersistWithLegacyDefaults() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueTimeline-"+UUID().uuidString+".aperturecue")
        defer { try? FileManager.default.removeItem(at:url) }
        var p=Project.demo()
        p.fixtures=[Fixture(name:"Strip",universe:2,address:10,points:[Point2(0.25,0.5),Point2(0.75,0.5)],channelOrder:"GRB")]
        p.timeline=[AutomationTrack(name:"Fade",surfaceID:p.surfaces[0].id,parameter:"opacity",keyframes:[AutomationKeyframe(time:0,value:0),AutomationKeyframe(time:10,value:1)])]
        try ProjectStore.save(p,to:url)
        XCTAssertEqual(try ProjectStore.load(from:url),p)
        try Data("{\"version\":1,\"name\":\"Old build\"}".utf8).write(to:url)
        let old=try ProjectStore.load(from:url)
        XCTAssertEqual(old.fixtures,[]); XCTAssertEqual(old.timeline,[])
    }
    func testTimelineSeekLoopAndDisabledTrack() throws {
        let surface=Surface(name:"Surface")
        let opacity=AutomationTrack(name:"Fade",surfaceID:surface.id,parameter:"opacity",keyframes:[AutomationKeyframe(time:0,value:0),AutomationKeyframe(time:10,value:1)])
        let disabled=AutomationTrack(name:"Off",surfaceID:surface.id,parameter:"brightness",keyframes:[AutomationKeyframe(time:0,value:0)],enabled:false)
        let clock=TransportClock(duration:10,loop:true)
        clock.play(at:100)
        var sample=try TimelineEngine.apply(tracks:[opacity,disabled],time:clock.time(at:105),surfaces:[surface])
        XCTAssertEqual(sample[0].opacity,0.5,accuracy:1e-12); XCTAssertEqual(sample[0].brightness,1)
        clock.seek(to:2,at:106)
        sample=try TimelineEngine.apply(tracks:[opacity],time:clock.time(at:106),surfaces:[surface])
        XCTAssertEqual(sample[0].opacity,0.2,accuracy:1e-12)
        sample=try TimelineEngine.apply(tracks:[opacity],time:clock.time(at:115),surfaces:[surface])
        XCTAssertEqual(sample[0].opacity,0.1,accuracy:1e-12)
        XCTAssertEqual(try TimelineEngine.apply(tracks:[opacity],time:1,surfaces:[]),[])
    }
    func testTimelineColorGammaAndValidation() throws {
        var p=Project.demo(); let id=p.surfaces[0].id
        p.timeline=[AutomationTrack(name:"Red",surfaceID:id,parameter:"red",keyframes:[AutomationKeyframe(time:0,value:0),AutomationKeyframe(time:2,value:2)]),
                    AutomationTrack(name:"Gamma",surfaceID:id,parameter:"gamma",keyframes:[AutomationKeyframe(time:0,value:1),AutomationKeyframe(time:2,value:3)])]
        try ProjectStore.validate(p)
        let sample=try TimelineEngine.apply(tracks:p.timeline,time:1,surfaces:p.surfaces)
        XCTAssertEqual(sample[0].color,[1,1,1]); XCTAssertEqual(sample[0].gamma,2)
        p.timeline[0].surfaceID=UUID(); p.timeline[0].enabled=false
        XCTAssertThrowsError(try ProjectStore.validate(p))
        p.timeline[0].surfaceID=id; p.timeline[0].keyframes=[AutomationKeyframe(time:1,value:1),AutomationKeyframe(time:0,value:0)]
        XCTAssertThrowsError(try ProjectStore.validate(p))
        p.timeline[0].keyframes=[AutomationKeyframe(time:0,value:1)]; p.timeline.append(p.timeline[0])
        p.timeline[2].id=UUID(); XCTAssertThrowsError(try ProjectStore.validate(p))
        p.timeline.removeLast(); p.timeline[1].keyframes=[AutomationKeyframe(time:0,value:0)]
        XCTAssertThrowsError(try ProjectStore.validate(p))
    }
    func testProjectRejectsFixtureOverlapBeforeSampling() throws {
        var p=Project.demo()
        p.fixtures=[Fixture(name:"A",address:1,points:[Point2(0,0)]),Fixture(name:"B",address:3,points:[Point2(1,1)])]
        XCTAssertThrowsError(try ProjectStore.validate(p))
        var calls=0
        XCTAssertThrowsError(try FixtureSampler.sample(fixtures:p.fixtures) { _ in calls += 1; return RGBColor(1,1,1) })
        XCTAssertEqual(calls,0)
        p.fixtures[1].address=4; try ProjectStore.validate(p)
        p.fixtures[1].universe=0; XCTAssertThrowsError(try ProjectStore.validate(p))
    }
    func testDormantTimelineTargetRetainedByCueCanBeSaved() throws {
        let surface=Surface(name:"Dormant target")
        let track=AutomationTrack(name:"Fade",surfaceID:surface.id,parameter:"opacity",keyframes:[AutomationKeyframe(time:0,value:0),AutomationKeyframe(time:1,value:1)])
        var p=Project(name:"Empty current scene",cues:[Cue(name:"Bring back",surfaces:[surface])],timeline:[track])
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueDormant-"+UUID().uuidString+".aperturecue")
        defer { try? FileManager.default.removeItem(at:url) }
        try ProjectStore.save(p,to:url)
        XCTAssertEqual(try ProjectStore.load(from:url),p)
        XCTAssertEqual(try TimelineEngine.apply(tracks:p.timeline,time:0.5,surfaces:p.surfaces),[])
        XCTAssertEqual(try TimelineEngine.apply(tracks:p.timeline,time:0.5,surfaces:p.cues[0].surfaces)[0].opacity,0.5)
        p.cues=[]; XCTAssertThrowsError(try ProjectStore.validate(p))
    }
}
