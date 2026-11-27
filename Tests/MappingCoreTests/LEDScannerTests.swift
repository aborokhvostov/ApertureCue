import XCTest
import Foundation
@testable import MappingCore

final class LEDScannerTests: XCTestCase {
    private let width = 30
    private let height = 24

    private func frames(slot: Int, centers: [(Int, Int)], isolatedPixel: Bool = false) -> LEDScanFrameSet {
        var before = [UInt8]()
        var flash = [UInt8]()
        var after = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let base = 28 + (x * 3 + y) / 7
                let hashNoise = (x * 17 + y * 7 + 3) % 7 - 3
                let spot = centers.contains { abs($0.0 - x) <= 1 && abs($0.1 - y) <= 1 }
                let spike = isolatedPixel && x == 0 && y == height - 1
                before.append(UInt8(base))
                after.append(UInt8(base + 14))
                flash.append(UInt8(base + 33 + hashNoise + (spike ? 136 : spot ? 96 : 0)))
            }
        }
        return LEDScanFrameSet(slot: slot, darkBefore: Data(before), flash: Data(flash), darkAfter: Data(after))
    }

    func testRastersDecodeAmbientCompensatedInSlotOrder() throws {
        let capture = LEDScanCapture(width: width, height: height,
            frames: [frames(slot: 3, centers: [(23, 20)]), frames(slot: 1, centers: [(6, 5)], isolatedPixel: true), frames(slot: 2, centers: [(17, 13)])])
        let serialized = try JSONEncoder().encode(capture)
        let decoded = try JSONDecoder().decode(LEDScanCapture.self, from: serialized)
        XCTAssertEqual(decoded, capture)
        let result = try LEDScanner.decode(decoded)
        XCTAssertEqual(result.detections.map(\.slot), [1, 2, 3])
        XCTAssertTrue(result.unresolvedSlots.isEmpty)
        for (entry, expected) in zip(result.detections, [(6, 5), (17, 13), (23, 20)]) {
            let point = try XCTUnwrap(entry.point)
            XCTAssertEqual(point.x * Double(width), Double(expected.0) + 0.5, accuracy: 0.03)
            XCTAssertEqual(point.y * Double(height), Double(expected.1) + 0.5, accuracy: 0.03)
        }
    }

    func testAmbiguousMissingAndRepeatedPositionsPreserveSlots() throws {
        let capture = LEDScanCapture(width: width, height: height, frames: [
            frames(slot: 1, centers: [(6, 5)]), frames(slot: 2, centers: []),
            frames(slot: 3, centers: [(5, 14), (22, 18)]), frames(slot: 4, centers: [(12, 18)]),
            frames(slot: 5, centers: [(12, 18)]), frames(slot: 6, centers: [(23, 4)])
        ])
        let result = try LEDScanner.decode(capture)
        XCTAssertEqual(result.detections.map(\.issue), [nil, .noSignal, .ambiguous, .repeatedPosition, .repeatedPosition, nil])
        XCTAssertEqual(result.unresolvedSlots, [2, 3, 4, 5])
        XCTAssertThrowsError(try result.makeFixture(name: "Original scan", universe: 2, address: 4, channelOrder: "RGB"))
        let patch = try result.makeFixture(name: "Original scan", universe: 2, address: 4, channelOrder: "RGB", skippingUnresolved: true)
        XCTAssertEqual(patch.skippedPixels, [1, 2, 3, 4])
        let frame = try FixtureSampler.sample(fixtures: [patch]) { _ in RGBColor(1, 0.5, 0.25) }
        let channels = try XCTUnwrap(frame[2])
        XCTAssertEqual(Array(channels[3..<6]), [255, 128, 64])
        XCTAssertEqual(Array(channels[6..<18]), Array(repeating: 0, count: 12))
        XCTAssertEqual(Array(channels[18..<21]), [255, 128, 64])
        var competing = patch
        competing.id = UUID()
        competing.address = 7
        competing.points = [Point2(0.5, 0.5)]
        competing.skippedPixels = nil
        XCTAssertThrowsError(try FixtureSampler.validate(fixtures: [patch, competing]))
    }

    func testScannerValidationAndProjectPatchLimit() throws {
        let first = frames(slot: 1, centers: [(6, 5)])
        XCTAssertThrowsError(try LEDScanner.decode(.init(version: 9, width: width, height: height, frames: [first])))
        XCTAssertThrowsError(try LEDScanner.decode(.init(width: Int.max, height: Int.max, frames: [first])))
        XCTAssertThrowsError(try LEDScanner.decode(.init(width: width, height: height, frames: [first, first])))
        var truncated = first
        truncated.flash.removeLast()
        XCTAssertThrowsError(try LEDScanner.decode(.init(width: width, height: height, frames: [truncated])))
        XCTAssertThrowsError(try LEDScanner.decode(.init(width: 512, height: 512, frames: Array(repeating: first, count: 43))))
        let one = try LEDScanner.decode(.init(width: width, height: height, frames: [first]))
        XCTAssertThrowsError(try one.makeFixture(name: "Crossed boundary", universe: 1, address: 511, channelOrder: "RGB"))
    }
}
