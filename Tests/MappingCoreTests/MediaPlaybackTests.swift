import Foundation
import XCTest
@testable import MappingCore

final class MediaPlaybackTests:XCTestCase {
    func testTrimForwardReverseLoopAndHalfOpenEndpoints() throws {
        let once=MediaPlaybackSettings(trimIn:2,trimOut:5,rate:2,mode:.once)
        let expected:[Double]=[2,3,4]
        for (i,time) in [0.0,0.5,1].enumerated() {
            let sample=try MediaPlayback.sample(elapsed:time,duration:9,settings:once)
            XCTAssertEqual(sample.position,expected[i],accuracy:1e-12)
            XCTAssertEqual(sample.direction,1);XCTAssertFalse(sample.ended)
        }
        let final=try MediaPlayback.sample(elapsed:1.5,duration:9,settings:once)
        XCTAssertTrue(final.ended);XCTAssertEqual(final.direction,0)
        XCTAssertTrue(final.position<5);XCTAssertTrue(final.position>4.999)
        var reverse=once;reverse.rate = -2
        XCTAssertTrue(try MediaPlayback.sample(elapsed:0,duration:9,settings:reverse).position>4.999)
        XCTAssertEqual(try MediaPlayback.sample(elapsed:0.5,duration:9,settings:reverse).position,4,accuracy:1e-12)
        XCTAssertEqual(try MediaPlayback.sample(elapsed:1.5,duration:9,settings:reverse).position,2)
        var loop=once;loop.mode = .loop
        let wrapped=try MediaPlayback.sample(elapsed:1.5,duration:9,settings:loop)
        XCTAssertEqual(wrapped.position,2);XCTAssertEqual(wrapped.discontinuityIndex,1)
        XCTAssertFalse(wrapped.ended)
        // Shorter actual media truncates the requested range, never samples EOF.
        let clamped=try MediaPlayback.sample(elapsed:4,duration:3,settings:once)
        XCTAssertTrue(clamped.ended);XCTAssertTrue(clamped.position<3)
    }
    func testPingPongHoldZeroRateAndSourceRangeBounds() throws {
        let settings=MediaPlaybackSettings(trimIn:1,trimOut:3,mode:.pingPong)
        let points:[(Double,Double,Double,UInt64)]=[(0,1,1,0),(1,2,1,0),(2,2.999999,-1,1),(3,2,-1,1),(4,1,1,2),(7,2,-1,3)]
        for (time,position,direction,epoch) in points {
            let value=try MediaPlayback.sample(elapsed:time,duration:4,settings:settings)
            XCTAssertEqual(value.position,position,accuracy:1e-8);XCTAssertEqual(value.direction,direction)
            XCTAssertEqual(value.discontinuityIndex,epoch);XCTAssertFalse(value.ended)
        }
        var hold=settings;hold.mode = .hold
        XCTAssertEqual(try MediaPlayback.sample(elapsed:100,duration:4,settings:hold).position,1)
        hold.mode = .loop;hold.rate=0
        XCTAssertEqual(try MediaPlayback.sample(elapsed:100,duration:4,settings:hold).direction,0)
        hold.rate = -1;hold.mode = .hold
        XCTAssertTrue(try MediaPlayback.sample(elapsed:100,duration:4,settings:hold).position>2.999)
        let tiny=MediaPlaybackSettings(trimIn:1,trimOut:1.00001)
        let sample=try MediaPlayback.sample(elapsed:MediaPlayback.maximumTime,duration:2,settings:tiny)
        XCTAssertTrue(sample.position>=1);XCTAssertTrue(sample.position<1.00001)
        for invalid in [Double.nan,Double.infinity,-1,MediaPlayback.maximumTime+1] {
            XCTAssertThrowsError(try MediaPlayback.sample(elapsed:invalid,duration:4,settings:settings))
        }
        var invalid=settings;invalid.rate=9;XCTAssertThrowsError(try invalid.validate())
        invalid=settings;invalid.trimOut=1;XCTAssertThrowsError(try invalid.validate())
        invalid=settings;invalid.randomInterval=0;XCTAssertThrowsError(try invalid.validate())
        XCTAssertThrowsError(try MediaPlayback.sample(elapsed:0,duration:0.5,settings:settings))
    }
    func testRandomCounterTraceIsSeekOrderIndependentAndSeeded() throws {
        let random=MediaPlaybackSettings(trimIn:0.2,trimOut:1.2,rate:1,mode:.random,randomSeed:0x12345678,randomInterval:0.25)
        let first=try (0..<20).map {try MediaPlayback.sample(elapsed:Double($0)*0.25,duration:2,settings:random,frameRate:10)}
        for index in [19,2,17,0,6,2,19] {
            XCTAssertEqual(try MediaPlayback.sample(elapsed:Double(index)*0.25,duration:2,settings:random,frameRate:10),first[index])
        }
        let goldenIndices=[3,5,7,9,9,4,6,7,3,9,1,5,9,8,3,4,1,8,2,4]
        for (index,value) in first.enumerated() {
            XCTAssertEqual(value.position,0.2+Double(goldenIndices[index])/10,accuracy:1e-10)
        }
        XCTAssertTrue(Set(first.map(\.position)).count>3)
        for value in first {
            XCTAssertTrue(value.position>=0.2);XCTAssertTrue(value.position<1.2)
            XCTAssertEqual((value.position-0.2)*10,((value.position-0.2)*10).rounded(),accuracy:1e-10)
        }
        var other=random;other.randomSeed=1
        let second=try (0..<20).map {try MediaPlayback.sample(elapsed:Double($0)*0.25,duration:2,settings:other,frameRate:10)}
        XCTAssertFalse(first==second)
        XCTAssertEqual(try MediaPlayback.sample(elapsed:0.249,duration:2,settings:random,frameRate:10),first[0])
    }
    func testSourceClockIndependentPauseSeekAndMasterRejoin() throws {
        var source=SourceTransport()
        XCTAssertEqual(try source.position(masterTime:7,hostTime:100),7)
        try source.play(at:100,masterTime:7)
        XCTAssertEqual(source.mode,.independent);XCTAssertTrue(source.isPlaying)
        XCTAssertEqual(try source.position(masterTime:200,hostTime:102),9)
        try source.pause(at:103)
        XCTAssertEqual(try source.position(masterTime:300,hostTime:1000),10)
        try source.seek(to:2,at:1000)
        XCTAssertEqual(try source.position(masterTime:300,hostTime:1001),2)
        try source.play(at:1001)
        XCTAssertEqual(try source.position(masterTime:300,hostTime:1002),3)
        let before=source
        XCTAssertThrowsError(try source.seek(to:.nan,at:1002));XCTAssertEqual(source,before)
        XCTAssertThrowsError(try source.play(at:.infinity));XCTAssertEqual(source,before)
        source.followMaster();XCTAssertEqual(try source.position(masterTime:8,hostTime:1003),8)
        XCTAssertFalse(source.isPlaying)
    }
    func testSequenceNaturalOrderFrozenGapsFrameIndexAndUnsafeNames() throws {
        let names=["f10.PNG","f001.png","f2.png","f1.png","f000000000000000000000000003.png","README.txt",".DS_Store"]
        let manifest=try MediaSequenceSettings.discover(names:names,fps:2)
        XCTAssertEqual(manifest.frames,["f1.png","f001.png","f2.png","f000000000000000000000000003.png","f10.PNG"])
        XCTAssertEqual(manifest.duration,2.5)
        XCTAssertEqual(try manifest.frameIndex(at:0),0)
        XCTAssertEqual(try manifest.frameIndex(at:0.5),1)
        XCTAssertEqual(try manifest.frameIndex(at:2.4999),4)
        XCTAssertThrowsError(try manifest.frameIndex(at:2.5))
        XCTAssertThrowsError(try manifest.frameIndex(at:.nan))
        for name in ["../x.png","/x.png","sub/x.png","sub\\x.png","x\0.png","x\n.png","x.gif"] {
            XCTAssertThrowsError(try MediaSequenceSettings(frames:[name]).validate())
        }
        XCTAssertThrowsError(try MediaSequenceSettings(frames:["a.png","a.png"]).validate())
        XCTAssertThrowsError(try MediaSequenceSettings(frames:["a.png"],fps:0).validate())
        XCTAssertThrowsError(try MediaSequenceSettings(frames:[]).validate())
        XCTAssertThrowsError(try MediaSequenceSettings.discover(names:["../x.png"]))
        XCTAssertThrowsError(try MediaSequenceSettings(frames:(0...MediaSequenceSettings.maximumFrames).map {"f\($0).png"}).validate())
        // A manifest is frozen, rather than implicitly changing with each discovery.
        let fresh=try MediaSequenceSettings.discover(names:names+["f5.png"],fps:2)
        XCTAssertEqual(manifest.frames.count,5);XCTAssertEqual(fresh.frames.count,6)
    }
    func testSchemaThirteenSettingsRoundTripAndLegacyExtensionsIgnoredBeforeDecode() throws {
        var video=MediaAsset(name:"Original",path:"movie.mov",kind:"video",loop:false)
        XCTAssertEqual(MediaPlayback.effectiveSettings(video).mode,.once)
        video.playback=MediaPlaybackSettings(trimIn:0.1,trimOut:2,rate:-0.5,mode:.pingPong)
        video.audioRouting=AudioRoutingSettings(inputChannels:2,outputChannels:1,gains:[0.5,0.5])
        let project=Project(assets:[video])
        let data=try JSONEncoder().encode(project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:data),project)
        var root=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        var assets=try XCTUnwrap(root["assets"] as? [[String:Any]])
        assets[0]["playback"]="foreign extension";assets[0]["sequence"]=["not":"a manifest"];assets[0]["audioRouting"]=42
        root["assets"]=assets
        for version in 0...12 {
            root["version"]=version
            let old=try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:root))
            XCTAssertNil(old.assets[0].playback);XCTAssertNil(old.assets[0].sequence);XCTAssertNil(old.assets[0].audioRouting)
            XCTAssertEqual(MediaPlayback.effectiveSettings(old.assets[0]).mode,.once)
        }
        root["version"]=13
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:root)))
        assets[0]["kind"]="sequence";root["assets"]=assets;root["version"]=12
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:root)))
    }
}
