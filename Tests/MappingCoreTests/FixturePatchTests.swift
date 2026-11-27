import Foundation
import XCTest
@testable import MappingCore

final class FixturePatchTests: XCTestCase {
    func testChannelEncodingBoundariesAndColorRoles() throws {
        let channels = [
            FixtureChannel(name: "Red", source: .red, encoding: .coarseFine),
            FixtureChannel(name: "Green", source: .green, encoding: .fineCoarse),
            FixtureChannel(name: "Blue", source: .blue),
            FixtureChannel(name: "White", source: .white),
            FixtureChannel(name: "Cyan", source: .cyan),
            FixtureChannel(name: "Magenta", source: .magenta),
            FixtureChannel(name: "Yellow", source: .yellow),
            FixtureChannel(name: "Intensity", source: .luma),
            FixtureChannel(name: "Reserved", source: .reserved, encoding: .coarseFine),
        ]
        let fixture = Fixture(name: "Profile", universe: 3, address: 477, points: [
            Point2(0, 0), Point2(0.5, 0), Point2(1, 0),
        ], definition: FixtureDefinition(channels: channels))
        let frame = try FixtureSampler.sample(fixtures: [fixture]) { point in
            switch point.x {
            case 0: return RGBColor(0, 0, 0)
            case 1: return RGBColor(1, 1, 1)
            default: return RGBColor(1, 0.5, 0.25)
            }
        }
        let slots = try XCTUnwrap(frame[3])
        XCTAssertEqual(fixture.channelCountPerPixel, 12)
        XCTAssertEqual(slots.count, 512)
        XCTAssertEqual(Array(slots[475..<476]), [0])
        XCTAssertEqual(Array(slots[476..<488]), [0, 0, 0, 0, 0, 0, 255, 255, 255, 0, 0, 0])
        XCTAssertEqual(Array(slots[488..<500]), [191, 255, 0, 64, 0, 64, 0, 128, 191, 150, 0, 0])
        XCTAssertEqual(Array(slots[500..<512]), [0, 0, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0])
    }

    func testAutomationOverridesAndOutputSamplingContract() throws {
        let output = UUID()
        let footprint = FixtureSampling(width: 0.25, height: 0.5)
        let drive = FixtureSurfaceDrive(surfaceID: UUID(), parameter: "opacity")
        let definition = FixtureDefinition(channels: [
            FixtureChannel(name: "Pan", source: .pan, encoding: .coarseFine, value: 0.25, drive: drive),
            FixtureChannel(name: "Tilt", source: .tilt, encoding: .fineCoarse, value: 0.5),
            FixtureChannel(name: "Dimmer", source: .dimmer, value: 1),
            FixtureChannel(name: "Focus", source: .constant),
            FixtureChannel(name: "Red", source: .red, encoding: .coarseFine),
        ])
        let fixture = Fixture(name: "Moving profile", points: [Point2(0.25, 0.75)], definition: definition,
                              sampling: footprint, outputID: output)
        let plan = try FixtureSampler.makePlan(fixtures: [fixture])
        var visits = 0
        let first = try plan.sample { route, point in
            visits += 1
            XCTAssertEqual(route.outputID, output)
            XCTAssertEqual(route.sampling, footprint)
            XCTAssertEqual(route.definition?.channels.first?.drive, drive)
            XCTAssertEqual(point, Point2(0.25, 0.75))
            return RGBColor(0, 0, 0)
        }
        XCTAssertEqual(Array(try XCTUnwrap(first[1]).prefix(8)), [64, 0, 0, 128, 255, 0, 0, 0])
        let next = try plan.sample(overrides: [fixture.id: ["Pan": 1, "Tilt": 0, "Focus": 0.5]]) { _, _ in
            visits += 1
            return RGBColor(2, -1, 0)
        }
        XCTAssertEqual(Array(try XCTUnwrap(next[1]).prefix(8)), [255, 255, 0, 0, 255, 128, 255, 255])
        for overrides in [[fixture.id: ["Red": 1.0]], [fixture.id: ["Pan": -.infinity]], [UUID(): ["Pan": 0.5]]] {
            XCTAssertThrowsError(try plan.sample(overrides: overrides) { _, _ in
                visits += 1
                return RGBColor(0, 0, 0)
            })
        }
        XCTAssertEqual(visits, 2)
        XCTAssertThrowsError(try plan.sample { _, _ in RGBColor(.nan, 0, 0) })
        var invalid = fixture
        invalid.definition?.channels[0].drive?.parameter = "unsupported"
        XCTAssertThrowsError(try FixtureSampler.validate(fixtures: [invalid]))
        invalid = fixture
        invalid.definition?.channels[4].drive = drive
        XCTAssertThrowsError(try FixtureSampler.validate(fixtures: [invalid]))
    }

    func testPatchRejectionAndLegacyPortableFixture() throws {
        struct LegacyFixture: Decodable {
            let value: Fixture
            init(from decoder: Decoder) throws {
                value = try Fixture(from: decoder, legacy: true)
            }
        }
        let legacy = Fixture(name: "Legacy GRB", universe: 2, address: 510, points: [Point2(1, 1)], channelOrder: "GRB")
        let encoded = try JSONEncoder().encode(legacy)
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(Fixture.self, from: encoded), legacy)
        var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["definition", "sampling", "outputID", "skippedPixels"] {
            XCTAssertNil(unknown[key])
            unknown[key] = true
        }
        let hostile = try JSONSerialization.data(withJSONObject: unknown)
        XCTAssertEqual(try decoder.decode(LegacyFixture.self, from: hostile).value, legacy)
        XCTAssertThrowsError(try decoder.decode(Fixture.self, from: hostile))

        let oneSlot = FixtureDefinition(channels: [FixtureChannel(name: "Red", source: .red)])
        var single = Fixture(name: "512 singles", points: Array(repeating: Point2(0.5, 0.5), count: 512),
                             definition: oneSlot)
        try FixtureSampler.validate(fixtures: [single])
        single.address = 2
        XCTAssertThrowsError(try FixtureSampler.validate(fixtures: [single]))
        single = legacy
        single.definition = FixtureDefinition(channels: [
            FixtureChannel(name: "Red", source: .red), FixtureChannel(name: "Red", source: .green),
        ])
        XCTAssertThrowsError(try FixtureSampler.validate(fixtures: [single]))
        single = legacy
        single.sampling = FixtureSampling(width: 0, height: 1)
        XCTAssertThrowsError(try FixtureSampler.validate(fixtures: [single]))
        single.sampling = FixtureSampling(width: 0.25, height: .nan)
        XCTAssertThrowsError(try FixtureSampler.validate(fixtures: [single]))
        single = legacy
        single.skippedPixels = [0, 0]
        XCTAssertThrowsError(try FixtureSampler.validate(fixtures: [single]))
        single.skippedPixels = [1]
        XCTAssertThrowsError(try FixtureSampler.validate(fixtures: [single]))
        single = legacy
        single.universe = 0
        XCTAssertEqual(try FixtureSampler.sample(fixtures: [single]) { _ in RGBColor(1, 0, 0) }.keys.sorted(), [0])
        single.universe = 63999
        XCTAssertEqual(try FixtureSampler.sample(fixtures: [single]) { _ in RGBColor(1, 0, 0) }.keys.sorted(), [63999])
        single.universe = 64000
        XCTAssertThrowsError(try FixtureSampler.validate(fixtures: [single]))
    }

    func testSerpentineLayoutReservesSkippedDMXSlots() throws {
        let start = Point2(0, 0)
        let end = Point2(1, 1)
        let points = try FixtureLayout.matrix(from: start, to: end, rows: 2, columns: 3, serpentine: true)
        XCTAssertEqual(points, [Point2(0, 0), Point2(0.5, 0), Point2(1, 0),
                                Point2(1, 1), Point2(0.5, 1), Point2(0, 1)])
        XCTAssertEqual(try FixtureLayout.matrix(from: start, to: end, rows: 2, columns: 3).suffix(3),
                       [Point2(0, 1), Point2(0.5, 1), Point2(1, 1)])
        XCTAssertEqual(try FixtureLayout.matrix(from: start, to: end, rows: 2, columns: 1), [Point2(0.5, 0), Point2(0.5, 1)])
        XCTAssertEqual(try FixtureLayout.line(from: start, to: end, count: 3), [start, Point2(0.5, 0.5), end])
        XCTAssertThrowsError(try FixtureLayout.matrix(from: start, to: end, rows: Int.max, columns: Int.max))
        XCTAssertThrowsError(try FixtureLayout.line(from: start, to: Point2(.infinity, 0), count: 2))
        let fixture = Fixture(name: "Snake", address: 4, points: points, skippedPixels: [4, 1])
        var visited = [Point2]()
        let frames = try FixtureSampler.sample(fixtures: [fixture]) { point in
            visited.append(point)
            return RGBColor(point.x, point.y, 1)
        }
        XCTAssertEqual(visited, [points[0], points[2], points[3], points[5]])
        XCTAssertEqual(Array(try XCTUnwrap(frames[1]).prefix(21)), [
            0, 0, 0, 0, 0, 255, 0, 0, 0, 255, 0, 255, 255, 255, 255, 0, 0, 0, 0, 255, 255,
        ])
        let overlappingHole = Fixture(name: "Still occupied", address: 7, points: [start])
        XCTAssertThrowsError(try FixtureSampler.validate(fixtures: [fixture, overlappingHole]))
    }

    func testCSVAtomicImportAndPhysicalRows() throws {
        let header = (FixtureLayoutImport.requiredCSVColumns + FixtureLayoutImport.optionalCSVColumns).joined(separator: ",")
        let id = UUID()
        let first = "\"Сцена, \"\"свет\"\"\r\nA\",1,10,GRB,0,0,1,1,1,3,false,1,\(id.uuidString),0.1,0.2"
        let second = "Matrix,2,1,RGB,0,0,1,1,2,2,true,0|3,,,"
        let existing = [Fixture(name: "Prior", address: 1, points: [Point2(0, 0)])]
        let good = Data("\u{FEFF}\(header)\r\n\(first)\r\n\(second)\n".utf8)
        let loaded = try FixtureLayoutImport.decode(good, format: .csv, appendingTo: existing)
        XCTAssertEqual(loaded.first, existing.first)
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded[1].name, "Сцена, \"свет\"\nA")
        XCTAssertEqual(loaded[1].outputID, id)
        XCTAssertEqual(loaded[1].sampling, FixtureSampling(width: 0.1, height: 0.2))
        XCTAssertEqual(loaded[1].points, [Point2(0, 0), Point2(0.5, 0.5), Point2(1, 1)])
        XCTAssertEqual(loaded[2].points, [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)])
        XCTAssertEqual(loaded[2].skippedPixels, [0, 3])
        let collision = Data("\(header)\n\(first)\nOverlap,1,13,RGB,0,0,1,1,1,1,false,,,,".utf8)
        XCTAssertThrowsError(try FixtureLayoutImport.decode(collision, format: .csv, appendingTo: existing)) { error in
            XCTAssertEqual((error as? FixtureLayoutImportError)?.row, 4)
            XCTAssertTrue(error.localizedDescription.contains("overlapping fixture channel addresses"))
        }
        let priorCollision = existing + [Fixture(name: "Occupied", address: 13, points: [Point2(0, 0)])]
        XCTAssertThrowsError(try FixtureLayoutImport.decode(good, format: .csv, appendingTo: priorCollision)) { error in
            XCTAssertEqual((error as? FixtureLayoutImportError)?.row, 2)
            XCTAssertTrue(error.localizedDescription.contains("overlapping fixture channel addresses"))
        }
        let broken = Data("\(header)\n\"unterminated".utf8)
        XCTAssertThrowsError(try FixtureLayoutImport.decode(broken, format: .csv)) { error in
            XCTAssertEqual((error as? FixtureLayoutImportError)?.row, 2)
        }
        XCTAssertThrowsError(try FixtureLayoutImport.decode(Data("name,wrong\nFixture,1".utf8), format: .csv)) { error in
            XCTAssertEqual((error as? FixtureLayoutImportError)?.row, 1)
        }
        let duplicateHeader = header.replacingOccurrences(of: "address", with: "universe")
        XCTAssertThrowsError(try FixtureLayoutImport.decode(Data("\(duplicateHeader)\n\(first)".utf8), format: .csv)) { error in
            XCTAssertEqual((error as? FixtureLayoutImportError)?.row, 1)
            XCTAssertTrue(error.localizedDescription.contains("duplicate"))
        }
        XCTAssertThrowsError(try FixtureLayoutImport.decode(Data(repeating: 0, count: FixtureLayoutImport.maximumBytes + 1), format: .csv))
        XCTAssertEqual(existing.count, 1)
    }

    func testJSONAtomicImportDiagnosticsAndRoundTrip() throws {
        let first = Fixture(name: "First", points: [Point2(0.5, 0.5)], definition: FixtureDefinition(channels: [
            FixtureChannel(name: "Tilt", source: .tilt, encoding: .fineCoarse, value: 0.5,
                           drive: FixtureSurfaceDrive(surfaceID: UUID(), parameter: "brightness")),
        ]), sampling: FixtureSampling(width: 1, height: 0.25), outputID: UUID(), skippedPixels: [0])
        let second = Fixture(name: "Second", address: 3, points: [Point2(0, 0)])
        let data = try JSONEncoder().encode([first, second])
        XCTAssertEqual(try FixtureLayoutImport.decode(data, format: .json), [first, second])
        let duplicate = try JSONEncoder().encode([second, second])
        XCTAssertThrowsError(try FixtureLayoutImport.decode(duplicate, format: .json)) { error in
            XCTAssertEqual((error as? FixtureLayoutImportError)?.row, 2)
            XCTAssertTrue(error.localizedDescription.contains("duplicate fixture IDs"))
        }
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        rows[1]["address"] = "wrong"
        let malformed = try JSONSerialization.data(withJSONObject: rows)
        XCTAssertThrowsError(try FixtureLayoutImport.decode(malformed, format: .json)) { error in
            XCTAssertEqual((error as? FixtureLayoutImportError)?.row, 2)
            XCTAssertTrue(error.localizedDescription.contains("address"))
        }
        XCTAssertThrowsError(try FixtureLayoutImport.decode(Data("[]".utf8), format: .json))
    }

    func testSVGPositionsUseExistingSafeParser() throws {
        let guide = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="10 20 100 100">
          <g transform="translate(20 30)"><circle cx="20" cy="20" r="5"/></g>
          <rect x="70" y="75" width="20" height="10"/>
        </svg>
        """
        let points = try FixtureLayout.svgPositions(Data(guide.utf8))
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].x, 0.3, accuracy: 0.000001)
        XCTAssertEqual(points[0].y, 0.3, accuracy: 0.000001)
        XCTAssertEqual(points[1].x, 0.7, accuracy: 0.000001)
        XCTAssertEqual(points[1].y, 0.6, accuracy: 0.000001)
        let outside = #"<svg viewBox="0 0 10 10"><circle cx="30" cy="40" r="1"/></svg>"#
        XCTAssertThrowsError(try FixtureLayout.svgPositions(Data(outside.utf8)))
        let external = #"<svg viewBox="0 0 10 10"><use href="remote.svg#guide"/></svg>"#
        XCTAssertThrowsError(try FixtureLayout.svgPositions(Data(external.utf8)))
    }
}
