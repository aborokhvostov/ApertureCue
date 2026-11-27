import Foundation
import XCTest
@testable import MappingCore

final class AbletonLinkCueTests: XCTestCase {
    private func sample(_ sequence: UInt64, _ micros: UInt64, _ beat: Double, peers: Int = 1, tempo: Double = 120) -> AbletonLinkObservation {
        let phase = beat - floor(beat / 4) * 4
        return AbletonLinkObservation(sequence: sequence, hostMicros: micros, peers: peers, tempo: tempo, beat: beat, phase: phase)
    }

    func testQueuesStrictNextBoundaryAndRecallsOneTime() throws {
        let cue = UUID()
        var queue = AbletonLinkCueQueue()
        XCTAssertThrowsError(try queue.enqueue(cue, now: 1_000_000))
        let initial = sample(1, 1_000_000, 3.9)
        XCTAssertNil(queue.observe(initial, now: 1_000_000))
        XCTAssertEqual(try queue.enqueue(cue, now: 1_000_000), 4, accuracy: 1e-10)
        XCTAssertNil(queue.observe(sample(2, 1_040_000, 3.98), now: 1_050_000))
        let boundary = sample(3, 1_065_000, 4.03)
        XCTAssertEqual(queue.observe(boundary, now: 1_080_000), .recall(cue))
        XCTAssertNil(queue.observe(boundary, now: 1_090_000))
        XCTAssertNil(queue.pendingCue)
        XCTAssertEqual(try queue.enqueue(cue, now: 1_095_000), 8, accuracy: 1e-10)
        queue.cancel()
        XCTAssertNil(queue.pendingCue)

        queue = AbletonLinkCueQueue()
        _ = queue.observe(sample(1, 5_000_000, 3.99), now: 5_018_000)
        XCTAssertEqual(try queue.enqueue(cue, now: 5_019_000), 8, accuracy: 1e-10)
    }

    func testCancelsOnSignalLossDiscontinuityAndLateCrossing() throws {
        let cue = UUID()
        var queue = AbletonLinkCueQueue()
        _ = queue.observe(sample(1, 1_000_000, 3.5), now: 1_000_000)
        try queue.enqueue(cue, now: 1_000_000)
        XCTAssertEqual(queue.observe(sample(2, 1_025_000, 3.55, peers: 0), now: 1_025_000), .signalLost)
        XCTAssertThrowsError(try queue.enqueue(cue, now: 1_025_000))
        XCTAssertNil(queue.observe(sample(3, 1_050_000, 3.6), now: 1_050_000))
        try queue.enqueue(cue, now: 1_050_000)
        XCTAssertEqual(queue.observe(sample(4, 1_075_000, 7.65), now: 1_075_000), .clockMoved)
        XCTAssertThrowsError(try queue.enqueue(cue, now: 1_075_000))
        XCTAssertNil(queue.observe(sample(5, 1_100_000, 7.7), now: 1_100_000))
        try queue.enqueue(cue, now: 1_100_000)
        XCTAssertEqual(queue.observe(sample(4, 1_110_000, 7.72), now: 1_110_000), .clockMoved)
        XCTAssertThrowsError(try queue.enqueue(cue, now: 1_110_000))
        XCTAssertNil(queue.observe(sample(6, 1_125_000, 7.75), now: 1_125_000))
        try queue.enqueue(cue, now: 1_125_000)
        XCTAssertEqual(queue.observe(nil, now: 1_400_000), .signalLost)

        queue = AbletonLinkCueQueue()
        _ = queue.observe(sample(1, 1_000_000, 3.95), now: 1_000_000)
        try queue.enqueue(cue, now: 1_000_000)
        XCTAssertEqual(queue.observe(sample(2, 1_135_000, 4.22), now: 1_205_000), .boundaryMissed)
        XCTAssertNil(queue.pendingCue)
    }
}
