import Foundation

public enum FixtureLayout {
    public static let maximumPoints = 512

    public static func line(from start: Point2, to end: Point2, count: Int) throws -> [Point2] {
        guard FixturePatchValidator.isNormalized(start), FixturePatchValidator.isNormalized(end),
              (1...maximumPoints).contains(count) else {
            throw ProjectError.invalid("fixture line requires normalized endpoints and 1–\(maximumPoints) points")
        }
        return (0..<count).map { Point2.interpolate(start, end, t: fraction($0, of: count)) }
    }

    /// Endpoints are opposite corners. Single-cell axes use the midpoint of that axis.
    /// Serpentine order reverses every second row without moving any sample positions.
    public static func matrix(from start: Point2, to end: Point2, rows: Int, columns: Int,
                              serpentine: Bool = false) throws -> [Point2] {
        guard FixturePatchValidator.isNormalized(start), FixturePatchValidator.isNormalized(end),
              (1...maximumPoints).contains(rows), (1...maximumPoints).contains(columns),
              rows * columns <= maximumPoints else {
            throw ProjectError.invalid("fixture matrix requires normalized corners and 1–\(maximumPoints) cells")
        }
        var points = [Point2]()
        points.reserveCapacity(rows * columns)
        for row in 0..<rows {
            let y = start.y + (end.y - start.y) * fraction(row, of: rows)
            for index in 0..<columns {
                let column = serpentine && !row.isMultiple(of: 2) ? columns - 1 - index : index
                let x = start.x + (end.x - start.x) * fraction(column, of: columns)
                points.append(Point2(x, y))
            }
        }
        return points
    }

    /// One sample per visible SVG shape at the center of its normalized anchor bounds, in document order.
    public static func svgPositions(_ data: Data) throws -> [Point2] {
        let document = try SVGImport.parse(data)
        return try document.shapes.enumerated().map { index, shape in
            let anchors = shape.paths.flatMap { $0.nodes.map(\.anchor) }
            guard let minX = anchors.map(\.x).min(), let maxX = anchors.map(\.x).max(),
                  let minY = anchors.map(\.y).min(), let maxY = anchors.map(\.y).max() else {
                throw ProjectError.invalid("SVG guide \(index + 1) has no position")
            }
            let point = Point2((minX + maxX) / 2, (minY + maxY) / 2)
            guard FixturePatchValidator.isNormalized(point) else {
                throw ProjectError.invalid("SVG guide \(index + 1) is outside the viewBox")
            }
            return point
        }
    }

    private static func fraction(_ index: Int, of count: Int) -> Double {
        count == 1 ? 0.5 : Double(index) / Double(count - 1)
    }
}

public enum FixtureLayoutFormat: String, Sendable {
    case csv, json
}

public struct FixtureLayoutImportError: Error, LocalizedError, Equatable, Sendable {
    /// Physical starting line in CSV or one-based array entry in JSON.
    public let row: Int?
    public let reason: String

    public var errorDescription: String? {
        if let row { return "Fixture layout row \(row): \(reason)" }
        return "Fixture layout: \(reason)"
    }
}

public enum FixtureLayoutImport {
    public static let maximumBytes = 1024 * 1024
    public static let requiredCSVColumns = [
        "name", "universe", "address", "channelOrder", "x1", "y1", "x2", "y2", "rows", "columns", "serpentine"
    ]
    public static let optionalCSVColumns = ["skippedPixels", "outputID", "sampleWidth", "sampleHeight"]

    /// Returns the entire merged patch after every row has passed geometry and address validation.
    public static func decode(_ data: Data, format: FixtureLayoutFormat, appendingTo existing: [Fixture] = []) throws -> [Fixture] {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw FixtureLayoutImportError(row: nil, reason: "file must contain 1–\(maximumBytes) bytes")
        }
        var result = existing
        var patch = FixturePatchValidator()
        for fixture in existing {
            do {
                try patch.append(fixture)
            } catch {
                throw FixtureLayoutImportError(row: nil, reason: "existing patch: \(message(error))")
            }
        }
        func append(_ fixture: Fixture, row: Int) throws {
            do {
                try patch.append(fixture)
                result.append(fixture)
            } catch {
                throw FixtureLayoutImportError(row: row, reason: message(error))
            }
        }
        switch format {
        case .csv:
            try decodeCSV(data, append: append)
        case .json:
            let rows: FixtureLayoutJSONRows
            do {
                rows = try JSONDecoder().decode(FixtureLayoutJSONRows.self, from: data)
            } catch let error as FixtureLayoutImportError {
                throw error
            } catch {
                throw FixtureLayoutImportError(row: nil, reason: "expected a JSON array of fixtures")
            }
            for (index, fixture) in rows.fixtures.enumerated() { try append(fixture, row: index + 1) }
        }
        guard result.count > existing.count else {
            throw FixtureLayoutImportError(row: nil, reason: "no fixture rows")
        }
        return result
    }

    private static func decodeCSV(_ data: Data, append: (Fixture, Int) throws -> Void) throws {
        var headers: [String]?
        let allColumns = requiredCSVColumns + optionalCSVColumns
        try FixtureLayoutCSV.read(data, maximumColumns: allColumns.count) { fields, line in
            guard let header = headers else {
                let columns = Set(fields)
                guard columns.count == fields.count, columns.isSubset(of: Set(allColumns)),
                      Set(requiredCSVColumns).isSubset(of: columns) else {
                    throw FixtureLayoutImportError(row: line, reason: "header requires \(requiredCSVColumns.joined(separator: ", ")) with no duplicate or unknown columns")
                }
                headers = fields
                return
            }
            guard fields.count == header.count else {
                throw FixtureLayoutImportError(row: line, reason: "expected \(header.count) fields, found \(fields.count)")
            }
            do {
                try append(csvFixture(Dictionary(uniqueKeysWithValues: zip(header, fields))), line)
            } catch let error as FixtureLayoutImportError {
                throw error
            } catch {
                throw FixtureLayoutImportError(row: line, reason: message(error))
            }
        }
    }

    private static func csvFixture(_ fields: [String: String]) throws -> Fixture {
        func field(_ name: String) -> String { (fields[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func integer(_ name: String) throws -> Int {
            guard let value = Int(field(name)) else { throw ProjectError.invalid("\(name) must be an integer") }
            return value
        }
        func number(_ name: String) throws -> Double {
            guard let value = Double(field(name)), value.isFinite else {
                throw ProjectError.invalid("\(name) must be a finite number")
            }
            return value
        }
        let name = field("name")
        guard !name.isEmpty else { throw ProjectError.invalid("name is required") }
        let serpentine: Bool
        switch field("serpentine").lowercased() {
        case "true": serpentine = true
        case "false": serpentine = false
        default: throw ProjectError.invalid("serpentine must be true or false")
        }
        let start = try Point2(number("x1"), number("y1"))
        let end = try Point2(number("x2"), number("y2"))
        let rows = try integer("rows")
        let columns = try integer("columns")
        let points: [Point2]
        if rows == 1 {
            points = try FixtureLayout.line(from: start, to: end, count: columns)
        } else {
            points = try FixtureLayout.matrix(from: start, to: end, rows: rows, columns: columns, serpentine: serpentine)
        }

        let skips = field("skippedPixels")
        let skipped: [Int]? = try skips.isEmpty ? nil : skips.split(separator: "|", omittingEmptySubsequences: false).map { entry in
            guard let index = Int(entry) else { throw ProjectError.invalid("skippedPixels requires integer indices separated by |") }
            return index
        }
        let route = field("outputID")
        let outputID = UUID(uuidString: route)
        guard route.isEmpty || outputID != nil else { throw ProjectError.invalid("outputID must be a UUID") }
        let sampling: FixtureSampling?
        if field("sampleWidth").isEmpty && field("sampleHeight").isEmpty {
            sampling = nil
        } else {
            sampling = try FixtureSampling(width: number("sampleWidth"), height: number("sampleHeight"))
        }
        return try Fixture(name: name, universe: integer("universe"), address: integer("address"), points: points,
                           channelOrder: field("channelOrder"), sampling: sampling, outputID: outputID, skippedPixels: skipped)
    }

    private static func message(_ error: Error) -> String {
        if case ProjectError.invalid(let reason) = error { return reason }
        return error.localizedDescription
    }
}

private struct FixtureLayoutJSONRows: Decodable {
    let fixtures: [Fixture]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded = [Fixture]()
        while !container.isAtEnd {
            let row = container.currentIndex + 1
            guard row <= FixturePatchValidator.maximumFixtures else {
                throw FixtureLayoutImportError(row: row, reason: "too many fixtures")
            }
            do {
                decoded.append(try container.decode(Fixture.self))
            } catch let error as DecodingError {
                throw FixtureLayoutImportError(row: row, reason: Self.message(error))
            }
        }
        fixtures = decoded
    }

    private static func message(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        let reason: String
        switch error {
        case .keyNotFound(let key, let detail):
            context = detail
            reason = "missing field \(key.stringValue)"
        case .valueNotFound(_, let detail), .typeMismatch(_, let detail), .dataCorrupted(let detail):
            context = detail
            reason = detail.debugDescription
        @unknown default:
            return "invalid fixture value"
        }
        let path = context.codingPath.dropFirst().map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? reason : "\(path): \(reason)"
    }
}

private enum FixtureLayoutCSV {
    private enum State { case fieldStart, unquoted, quoted, afterQuote }

    static func read(_ data: Data, maximumColumns: Int, visit: ([String], Int) throws -> Void) throws {
        guard let contents = String(data: data, encoding: .utf8), !contents.contains("\0") else {
            throw FixtureLayoutImportError(row: nil, reason: "CSV must be UTF-8 text")
        }
        let bytes = Array(contents.utf8)
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        var line = 1
        var startLine = 1
        var fields = [String]()
        var field = [UInt8]()
        var state = State.fieldStart

        func finishField() throws {
            guard fields.count < maximumColumns else {
                throw FixtureLayoutImportError(row: startLine, reason: "too many CSV fields")
            }
            fields.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            state = .fieldStart
        }
        func finishRow() throws {
            if state != .fieldStart || !fields.isEmpty {
                try finishField()
                try visit(fields, startLine)
                fields.removeAll(keepingCapacity: true)
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 10 || byte == 13 {
                if state == .quoted {
                    field.append(10)
                } else {
                    try finishRow()
                    startLine = line + 1
                }
                line += 1
                if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
            } else {
                switch (state, byte) {
                case (.quoted, 34): state = .afterQuote
                case (.afterQuote, 34):
                    field.append(byte)
                    state = .quoted
                case (.quoted, _): field.append(byte)
                case (_, 44): try finishField()
                case (.fieldStart, 34): state = .quoted
                case (.afterQuote, _), (.unquoted, 34):
                    throw FixtureLayoutImportError(row: startLine, reason: "unexpected CSV quote or trailing text")
                default:
                    field.append(byte)
                    state = .unquoted
                }
            }
            index += 1
        }
        guard state != .quoted else {
            throw FixtureLayoutImportError(row: startLine, reason: "unclosed quoted field")
        }
        try finishRow()
    }
}
