import XCTest
@testable import MappingCore
import Foundation

final class DMXSequenceTests: XCTestCase {
    func testCanonicalBinaryAndAtomicFileReplacement() throws {
        let frames = [
            DMXSequenceFrame(microseconds: 17, universes: [4: [2, 255], 0: [11]]),
            DMXSequenceFrame(microseconds: 48, universes: [:]),
            DMXSequenceFrame(microseconds: 93, universes: [63_999: Array(repeating: 253, count: 512)])
        ]
        let sequence = try DMXSequence(frames: frames, durationMicroseconds: 95)
        let bytes = sequence.encoded()
        XCTAssertEqual(Array(bytes.prefix(24)), Array("ACDMXSEQ".utf8) + [
            0, 1, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 95
        ])
        XCTAssertEqual(Array(bytes[24..<45]), [
            0, 0, 0, 0, 0, 0, 0, 17, 0, 2,
            0, 0, 0, 1, 11,
            0, 4, 0, 2, 2, 255
        ])
        XCTAssertEqual(try DMXSequence(data: bytes), sequence)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmx-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("first").appendingPathExtension(DMXSequence.fileExtension)
        try sequence.save(to: file)
        XCTAssertEqual(try DMXSequence.load(from: file), sequence)
        let replacement = try DMXSequence(frames: [DMXSequenceFrame(microseconds: 0, universes: [42: [20]])], durationMicroseconds: 16)
        try replacement.save(to: file)
        XCTAssertEqual(try DMXSequence.load(from: file), replacement)
        XCTAssertThrowsError(try DMXSequence.load(from: directory))

        let oversize = directory.appendingPathComponent("oversize.acdmx")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversize.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversize)
        try handle.truncate(atOffset: UInt64(DMXSequence.maximumFileBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try DMXSequence.load(from: oversize))
    }

    func testMalformedFramesAndBudgets() throws {
        let sample = DMXSequenceFrame(microseconds: 17, universes: [0: [11], 4: [2, 255]])
        let sequence = try DMXSequence(frames: [sample], durationMicroseconds: 18)
        let data = sequence.encoded()
        for length in 0..<data.count {
            XCTAssertThrowsError(try DMXSequence(data: data.prefix(length)))
        }
        var corrupt = data
        corrupt.append(0)
        XCTAssertThrowsError(try DMXSequence(data: corrupt))
        corrupt = data
        corrupt[9] = 2
        XCTAssertThrowsError(try DMXSequence(data: corrupt))
        corrupt = data
        corrupt[12] = 255
        XCTAssertThrowsError(try DMXSequence(data: corrupt))
        corrupt = data
        corrupt[40] = 0 // duplicate universe 0
        XCTAssertThrowsError(try DMXSequence(data: corrupt))
        corrupt = data
        corrupt[37] = 0 // empty slot data for a declared universe
        XCTAssertThrowsError(try DMXSequence(data: corrupt))
        XCTAssertThrowsError(try DMXSequence(frames: [sample, sample], durationMicroseconds: 30))
        XCTAssertThrowsError(try DMXSequence(frames: [sample], durationMicroseconds: 16))
        XCTAssertThrowsError(try DMXSequence(frames: [sample], durationMicroseconds: DMXSequence.maximumDurationMicroseconds + 1))
        XCTAssertThrowsError(try DMXSequence(frames: [.init(microseconds: 0, universes: [-1: [2]])], durationMicroseconds: 30))
        XCTAssertThrowsError(try DMXSequence(frames: [.init(microseconds: 0, universes: [1: Array(repeating: 0, count: 513)])], durationMicroseconds: 30))
        let changingUniverses = (0...DMXSequence.maximumUniverses).map { id in
            DMXSequenceFrame(microseconds: UInt64(id), universes: [id: [0]])
        }
        XCTAssertThrowsError(try DMXSequence(frames: changingUniverses, durationMicroseconds: 100))
    }

    func testCaptureCoalescesGapsWithoutLosingExplicitClear() throws {
        var recorder = DMXSequenceRecorder()
        try recorder.capture([1: [255, 70]], at: 250)
        try recorder.capture([1: [255, 70]], at: 270)
        XCTAssertEqual(recorder.frameCount, 1)
        XCTAssertEqual(recorder.lastObservedMicroseconds, 270)
        XCTAssertThrowsError(try recorder.capture([1: [80]], at: 260))
        XCTAssertEqual(recorder.frameCount, 1)
        XCTAssertThrowsError(try recorder.finish(at: 269))
        try recorder.capture([:], at: 450)
        try recorder.capture([1: [3, 0], 5: [40]], at: 700)
        let sequence = try recorder.finish(at: 800)
        XCTAssertEqual(sequence.frames.map(\.microseconds), [250, 450, 700])
        XCTAssertEqual(sequence.universeIDs, [1, 5])
        XCTAssertNil(sequence.frameIndex(at: 249))
        XCTAssertEqual(sequence.snapshot(at: 250), [1: [255, 70]])
        XCTAssertEqual(sequence.snapshot(at: 449), [1: [255, 70]])
        XCTAssertEqual(sequence.frameIndex(at: 450), 1)
        XCTAssertEqual(sequence.snapshot(at: 699), [:])
        XCTAssertEqual(sequence.snapshot(at: 700), [1: [3, 0], 5: [40]])
        XCTAssertEqual(sequence.snapshot(at: 800), [1: [3, 0], 5: [40]])
    }

    func testReplayUsesMonotonicTimeAndRejectsOldSeekGeneration() throws {
        let sequence = try DMXSequence(frames: [
            .init(microseconds: 10, universes: [1: [1]]),
            .init(microseconds: 25, universes: [1: [2]]),
            .init(microseconds: 72, universes: [1: [3]])
        ], durationMicroseconds: 80)
        var player = DMXSequencePlayer(sequence: sequence)
        let begun = player.play(at: 1_000)
        XCTAssertNil(player.tick(at: 999, generation: begun))
        XCTAssertNil(player.tick(at: 1_009, generation: begun)?.frameIndex)
        XCTAssertEqual(player.tick(at: 1_010, generation: begun)?.frameIndex, 0)
        XCTAssertEqual(player.tick(at: 1_060, generation: begun)?.frameIndex, 1)
        XCTAssertNil(player.tick(at: 1_020, generation: begun))

        let seek = player.seek(to: 12, at: 1_070)
        XCTAssertEqual(player.current.frameIndex, 0)
        XCTAssertNil(player.tick(at: 1_080, generation: begun))
        XCTAssertEqual(player.tick(at: 1_083, generation: seek)?.frameIndex, 1)
        XCTAssertEqual(player.tick(at: .max, generation: seek),
                       DMXSequenceTick(microseconds: 80, frameIndex: 2, isPlaying: false))
        XCTAssertNil(player.tick(at: .max, generation: seek))
        let restarted = player.play(at: 2_000)
        XCTAssertEqual(player.microseconds, 0)
        XCTAssertTrue(restarted != seek)
        player.stop()
        XCTAssertNil(player.tick(at: 2_100, generation: restarted))
    }
}
