import XCTest
import Foundation
@testable import MappingCore

final class OSCQueryTests: XCTestCase {
    private func object(_ response: OSCQueryResponse) throws -> [String: Any] {
        guard case .json(let bytes) = response else { throw ProtocolError.malformed("expected a JSON response") }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    func testNamespaceAndAttributeResponses() throws {
        let gain = OSCQueryNode(path: "/show/gain", description: "Gain", access: .readWrite, type: "f",
                                value: [.float(0.25)], range: [.init(min: 0, max: 1)])
        let scene = OSCQueryNode(path: "/show/go", description: "Go", access: .writeOnly, type: "i")
        let blob = OSCQueryNode(path: "/show/data", type: "b", value: [.blob(Data([1, 2, 3]))])
        let unset = OSCQueryNode(path: "/unset", type: "ii", range: [nil, .init(values: [.int(2), .int(3)])])
        let tree = try OSCQuerySnapshot(nodes: [gain, scene, blob, unset])
        let root = try object(tree.response(path: "/"))
        XCTAssertEqual(root["FULL_PATH"] as? String, "/")
        XCTAssertEqual(root["ACCESS"] as? Int, 0)
        let rootChildren = try XCTUnwrap(root["CONTENTS"] as? [String: Any])
        let show = try XCTUnwrap(rootChildren["show"] as? [String: Any])
        let showChildren = try XCTUnwrap(show["CONTENTS"] as? [String: Any])
        let metadata = try XCTUnwrap(showChildren["gain"] as? [String: Any])
        XCTAssertEqual(metadata["FULL_PATH"] as? String, gain.path)
        XCTAssertEqual(metadata["ACCESS"] as? Int, 3)
        XCTAssertEqual(metadata["TYPE"] as? String, "f")
        XCTAssertEqual(metadata["DESCRIPTION"] as? String, "Gain")
        let value = try object(tree.response(path: gain.path, attribute: .value))
        XCTAssertEqual(value.count, 1)
        XCTAssertEqual(value["VALUE"] as? [Double], [0.25])
        let range = try object(tree.response(path: gain.path, attribute: .range))
        XCTAssertEqual(range["RANGE"] as? [[String: Double]], [["MIN": 0, "MAX": 1]])
        XCTAssertEqual(try tree.response(path: scene.path, attribute: .value), .noContent)
        XCTAssertEqual(try tree.response(path: "/absent"), .notFound)
        XCTAssertTrue(try object(tree.response(path: unset.path, attribute: .value)).isEmpty)
        let untypedBounds = try object(tree.response(path: unset.path, attribute: .range))
        let boundEntries = try XCTUnwrap(untypedBounds["RANGE"] as? [Any])
        XCTAssertTrue(boundEntries.first is NSNull)
        let blobValue = try object(tree.response(path: blob.path, attribute: .value))
        XCTAssertTrue((blobValue["VALUE"] as? [Any])?.first is NSNull)
    }

    func testMethodPathTypeAndBudgetValidation() throws {
        let good = OSCQueryNode(path: "/show/opacity", type: "f", value: [.float(0.5)])
        let tree = try OSCQuerySnapshot(nodes: [good])
        for path in ["show/fade", "/", "/show//fade", "/show/../fade", "/show/*", "/show/é", "/a/", "/" + String(repeating: "x", count: 384)] {
            XCTAssertFalse(OSCQuerySnapshot.isMethodPath(path), path)
        }
        XCTAssertTrue(OSCQuerySnapshot.isMethodPath("/show/A-b_c.d~e/123"))
        let invalid = [
            OSCQueryNode(path: good.path, type: "f", value: [.float(.nan)]),
            OSCQueryNode(path: good.path, type: "i", value: [.float(1)]),
            OSCQueryNode(path: good.path, access: .writeOnly, type: "f", value: [.float(1)]),
            OSCQueryNode(path: good.path, type: "f", range: [.init(min: 2, max: 1)]),
            OSCQueryNode(path: good.path, type: "f", range: []),
            OSCQueryNode(path: good.path, type: "i", range: [.init(min: 0.5)]),
            OSCQueryNode(path: good.path, type: "b", value: [.blob(Data(count: 257))]),
            OSCQueryNode(path: good.path, type: "s", value: [.string(String(repeating: "a", count: 257))])
        ]
        for node in invalid { XCTAssertThrowsError(try OSCQuerySnapshot(nodes: [node])) }
        XCTAssertThrowsError(try OSCQuerySnapshot(nodes: [good, good]))
        let tooMany = (0...OSCQuerySnapshot.maximumNodes).map { OSCQueryNode(path: "/n/\($0)", type: "i") }
        XCTAssertThrowsError(try OSCQuerySnapshot(nodes: tooMany))
        XCTAssertEqual(tree.node(at: good.path), good)
    }

    func testStructureChangeDiffOmitsLiveValues() throws {
        let node = OSCQueryNode(path: "/show/fade", description: "Fade", type: "f", value: [.float(0.5)])
        let original = try OSCQuerySnapshot(nodes: [node])
        var changed = node
        changed.value = [.float(0.75)]
        let newValues = try OSCQuerySnapshot(nodes: [changed])
        XCTAssertFalse(original == newValues)
        XCTAssertTrue(original.hasSameMetadata(as: newValues))
        changed.description = "Renamed fade"
        XCTAssertFalse(original.hasSameMetadata(as: try OSCQuerySnapshot(nodes: [changed])))
        XCTAssertFalse(original.hasSameMetadata(as: try OSCQuerySnapshot()))
    }
}
