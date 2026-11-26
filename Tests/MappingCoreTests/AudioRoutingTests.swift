import Foundation
import XCTest
@testable import MappingCore

final class AudioRoutingTests:XCTestCase {
    func testPCMMatrixIdentitySwapDownmixSignedGainAndClipping() throws {
        let pcm:[Float]=[0.25,-0.5,0.75,0.125]
        XCTAssertEqual(try AudioRoutingSettings().mix(interleaved:pcm,frameCount:2),pcm)
        let swap=AudioRoutingSettings(gains:[0,1,1,0])
        XCTAssertEqual(try swap.mix(interleaved:pcm,frameCount:2),[-0.5,0.25,0.125,0.75])
        let down=AudioRoutingSettings(inputChannels:2,outputChannels:1,gains:[0.5,0.5])
        XCTAssertEqual(try down.mix(interleaved:pcm,frameCount:2),[-0.125,0.4375])
        XCTAssertEqual(try down.mix(interleaved:pcm,frameCount:2,volume:0.5),[-0.0625,0.21875])
        let difference=AudioRoutingSettings(inputChannels:2,outputChannels:1,gains:[4,-4])
        // Sum before clipping: separately clipped products would cancel to zero.
        XCTAssertEqual(try difference.mix(interleaved:[0.75,0.5,1,-1,-1,1],frameCount:3),[1,1,-1])
        // The native output mixer applies the master fader after matrix clipping.
        // A pre-clipping fader would produce +/-1 here instead of +/-0.5.
        XCTAssertEqual(try difference.mix(interleaved:[1,-1,-1,1],frameCount:2,volume:0.5),[0.5,-0.5])
        let identity=AudioRoutingSettings.identity(inputChannels:2,outputChannels:4)
        XCTAssertEqual(try identity.mix(interleaved:[0.25,-0.5],frameCount:1),[0.25,-0.5,0,0])
    }
    func testMuteDisabledBoundsNonfiniteAndAtomicFailure() throws {
        var route=AudioRoutingSettings();route.muted=true
        XCTAssertEqual(try route.mix(interleaved:[1,-1],frameCount:1),[0,0])
        route.muted=false;route.enabled=false
        XCTAssertEqual(try route.mix(interleaved:[1,-1],frameCount:1),[0,0])
        XCTAssertThrowsError(try route.mix(interleaved:[.nan,0],frameCount:1))
        XCTAssertThrowsError(try route.mix(interleaved:[0,0],frameCount:-1))
        XCTAssertThrowsError(try route.mix(interleaved:[0],frameCount:1))
        XCTAssertThrowsError(try route.mix(interleaved:[0,0],frameCount:1,volume:.infinity))
        var bad=AudioRoutingSettings();bad.gains[0] = .nan
        XCTAssertThrowsError(try bad.validate())
        bad=AudioRoutingSettings();bad.inputChannels=33;XCTAssertThrowsError(try bad.validate())
        bad=AudioRoutingSettings();bad.outputChannels=0;XCTAssertThrowsError(try bad.validate())
        bad=AudioRoutingSettings();bad.gains=[1];XCTAssertThrowsError(try bad.validate())
        bad=AudioRoutingSettings();bad.deviceUID="";XCTAssertThrowsError(try bad.validate())
        bad=AudioRoutingSettings();bad.deviceUID="not\0valid";XCTAssertThrowsError(try bad.validate())
        XCTAssertEqual(try JSONDecoder().decode(AudioRoutingSettings.self,from:JSONEncoder().encode(route)),route)
    }
}
