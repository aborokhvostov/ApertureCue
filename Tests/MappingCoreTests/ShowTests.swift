import XCTest
import Foundation
@testable import MappingCore

final class ShowTests: XCTestCase {
    func testPlayPauseSeekAndLoopWithInjectedHostTime() {
        let c=TransportClock(duration:10,loop:true)
        c.play(at:100); XCTAssertEqual(c.time(at:103),3)
        c.pause(at:103); XCTAssertEqual(c.time(at:110),3)
        c.play(at:120); XCTAssertEqual(c.time(at:128),1)
        c.seek(to:7,at:130); XCTAssertEqual(c.time(at:132),9)
        XCTAssertEqual(c.time(at:134),1)
        c.pause(at:134); c.seek(to:-100,at:140)
        XCTAssertEqual(c.time(at:140),0)
        c.seek(to:.nan,at:140); XCTAssertEqual(c.time(at:140),0)
    }
    func testNonLoopingEndAndRestart() {
        let c=TransportClock(duration:5,loop:false)
        c.play(at:0); XCTAssertEqual(c.time(at:10),5)
        c.update(at:10); XCTAssertFalse(c.isPlaying); XCTAssertEqual(c.time(at:20),5)
        c.play(at:30); XCTAssertEqual(c.time(at:31),1)
    }
    func testPauseFreezesUnboundedGeneratorTime() {
        let c=TransportClock()
        c.play(at:100); XCTAssertEqual(c.time(at:1000),900)
        c.pause(at:1000); XCTAssertEqual(c.time(at:99999),900)
    }
    func testCueInterpolationAndFollow() throws {
        let a=Surface(name:"A",opacity:1), b=Surface(id:UUID(),name:"Added",opacity:0.8)
        var destination=a; destination.opacity=0.2; destination.output=Point2.unitQuad
        let cue=Cue(name:"Next",surfaces:[destination,b],duration:2,followAfter:3)
        let engine=CueEngine(); engine.begin(from:[a],cue:cue,at:10)
        let mid=try XCTUnwrap(engine.sample(at:11))
        XCTAssertEqual(mid.count,2); XCTAssertEqual(mid[0].opacity,0.6,accuracy:1e-12)
        XCTAssertEqual(mid[0].output[0].x,0.05,accuracy:1e-12)
        XCTAssertEqual(mid[1].opacity,0.4,accuracy:1e-12)
        XCTAssertEqual(engine.sample(at:12),cue.surfaces)
        XCTAssertFalse(engine.isTransitioning); XCTAssertFalse(engine.shouldFollow(at:14.99)); XCTAssertTrue(engine.shouldFollow(at:15))
        XCTAssertNil(engine.sample(at:16)); engine.cancel(); XCTAssertFalse(engine.shouldFollow(at:99))
    }
    func testRemovedLayerFadesAndZeroDurationCue() throws {
        let a=Surface(name:"Outgoing")
        let engine=CueEngine(); engine.begin(from:[a],cue:Cue(name:"Empty",surfaces:[],duration:1),at:0)
        XCTAssertEqual(try XCTUnwrap(engine.sample(at:0.5)).first!.opacity,0.5)
        XCTAssertEqual(engine.sample(at:1),[])
        engine.begin(from:[],cue:Cue(name:"Instant",surfaces:[a],duration:0),at:5)
        XCTAssertEqual(engine.sample(at:5),[a])
    }
    func testAutomationInterpolatesAndRejectsInvalidTimes() throws {
        let keys=[AutomationKeyframe(time:1,value:0),AutomationKeyframe(time:3,value:10)]
        XCTAssertEqual(try Automation.value(at:0,keyframes:keys),0)
        XCTAssertEqual(try Automation.value(at:2,keyframes:keys),5)
        XCTAssertEqual(try Automation.value(at:4,keyframes:keys),10)
        XCTAssertThrowsError(try Automation.value(at:2,keyframes:[keys[1],keys[0]]))
    }
}
