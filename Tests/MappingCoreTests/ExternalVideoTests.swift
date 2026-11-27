import Foundation
import XCTest
@testable import MappingCore

final class ExternalVideoTests: XCTestCase {
    func testFrameGoldenAndMalformedBudget() throws {
        let producer = try XCTUnwrap(UUID(uuidString: "10203040-5060-7080-90A0-B0C0D0E0F000"))
        let frame = try ExternalVideoFrame(producer: producer, sequence: 0x0123456789ABCDEF, width: 2, height: 1,
                                           bgra: Data([1, 2, 3, 255, 90, 91, 92, 255]))
        let expected = Array("ACFRAME1".utf8) + [0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80,
                         0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0, 0, 1, 0x23, 0x45, 0x67,
                         0x89, 0xAB, 0xCD, 0xEF, 0, 0, 0, 2, 0, 0, 0, 1, 1, 2, 3, 255, 90, 91, 92, 255]
        let encoded = frame.serialized()
        XCTAssertEqual(encoded, Data(expected))
        XCTAssertEqual(try ExternalVideoFrame(serialized: encoded), frame)
        for size in 0..<encoded.count { XCTAssertThrowsError(try ExternalVideoFrame(serialized: Data(encoded.prefix(size)))) }
        var width = encoded
        width[32] = 255
        XCTAssertThrowsError(try ExternalVideoFrame(serialized: width))
        var trailing = encoded
        trailing.append(0)
        XCTAssertThrowsError(try ExternalVideoFrame(serialized: trailing))
        XCTAssertThrowsError(try ExternalVideoFrame(producer: producer, sequence: 0, width: 2, height: 1, bgra: frame.bgra))
    }

    func testOwnerFreshnessAndReplayRejection() throws {
        let first = UUID()
        let second = UUID()
        let one = try ExternalVideoFrame(producer: first, sequence: 3, width: 1, height: 1, bgra: Data([0, 0, 0, 255]))
        let two = try ExternalVideoFrame(producer: second, sequence: 1, width: 1, height: 1, bgra: one.bgra)
        var order = ExternalFrameOrder()
        XCTAssertTrue(order.admit(one, at: 1))
        XCTAssertFalse(order.admit(one, at: 1.2))
        XCTAssertFalse(order.admit(two, at: 1.9))
        XCTAssertTrue(order.isFresh(at: 1.99))
        XCTAssertFalse(order.isFresh(at: 2))
        XCTAssertFalse(order.admit(one, at: 2))
        XCTAssertTrue(order.admit(two, at: 2))
        XCTAssertFalse(order.admit(one, at: 2.1))
        XCTAssertFalse(order.admit(two, at: .infinity))
        XCTAssertEqual(order.producer, second)
    }

    func testFeedReferenceMigratesAndCollectsWithoutFile() throws {
        let fileSystem = FileManager.default
        let scratch = fileSystem.temporaryDirectory.appendingPathComponent("OriginalExternalVideoTest-" + UUID().uuidString)
        try fileSystem.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fileSystem.removeItem(at: scratch) }
        let asset = MediaAsset(name: "Original feed", path: "lobby_1-A", kind: "external-video", loop: false, volume: 0)
        XCTAssertFalse(asset.hasLocalFile)
        var project = Project(name: "Original video bridge", assets: [asset], surfaces: [Surface(mediaID: asset.id)])
        let url = scratch.appendingPathComponent("own.aperturecue.json")
        try ProjectStore.save(project, to: url)
        XCTAssertEqual(try ProjectStore.load(from: url), project)
        let portable = try ProjectStore.collect(project, to: scratch.appendingPathComponent("copy"))
        XCTAssertEqual(try ProjectStore.load(from: portable).assets, [asset])
        project.version = 16
        XCTAssertThrowsError(try ProjectStore.validate(project))
        project.version = Project.currentVersion
        for name in ["/x", "a.b", "A B", "", "a:b", "α", String(repeating: "a", count: 49)] {
            project.assets[0].path = name
            XCTAssertThrowsError(try ProjectStore.validate(project))
        }
    }
}
