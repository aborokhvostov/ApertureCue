import Foundation

public enum OSCQueryAccess: Int, Sendable {
    case readOnly = 1
    case writeOnly = 2
    case readWrite = 3

    public var isReadable: Bool { self != .writeOnly }
}

public struct OSCQueryRange: Equatable, Sendable {
    public var min: Double?
    public var max: Double?
    public var values: [OSCArgument]?

    public init(min: Double? = nil, max: Double? = nil, values: [OSCArgument]? = nil) {
        self.min = min
        self.max = max
        self.values = values
    }
}

/// A method in the OSC namespace. Access describes the OSC command channel;
/// the HTTP and WebSocket endpoints only query or subscribe to published state.
public struct OSCQueryNode: Equatable, Sendable {
    public var path: String
    public var description: String
    public var access: OSCQueryAccess
    public var type: String
    public var value: [OSCArgument]?
    public var range: [OSCQueryRange?]?

    public init(path: String, description: String = "", access: OSCQueryAccess = .readOnly,
                type: String, value: [OSCArgument]? = nil, range: [OSCQueryRange?]? = nil) {
        self.path = path
        self.description = description
        self.access = access
        self.type = type
        self.value = value
        self.range = range
    }

    public func hasSameMetadata(as other: Self) -> Bool {
        path == other.path && description == other.description && access == other.access && type == other.type && range == other.range
    }
}

public enum OSCQueryAttribute: String, CaseIterable, Sendable {
    case fullPath = "FULL_PATH"
    case description = "DESCRIPTION"
    case contents = "CONTENTS"
    case access = "ACCESS"
    case type = "TYPE"
    case value = "VALUE"
    case range = "RANGE"
}

public enum OSCQueryResponse: Equatable, Sendable {
    case json(Data)
    case noContent
    case notFound
    case tooLarge
}

public struct OSCQuerySnapshot: Equatable, Sendable {
    public static let maximumNodes = 2048
    public static let maximumPathBytes = 384
    public static let maximumResponseBytes = 1024 * 1024
    private static let maximumEntries = 8192
    private static let maximumInputBytes = 512 * 1024
    private let methods: [String: OSCQueryNode]
    private let children: [String: Set<String>]

    public init(nodes: [OSCQueryNode] = []) throws {
        guard nodes.count <= Self.maximumNodes else { throw ProtocolError.malformed("OSC Query method count exceeds 2048") }
        var methods: [String: OSCQueryNode] = [:]
        var children: [String: Set<String>] = ["/": []]
        var budget = Self.maximumInputBytes
        var branchCount = 0
        for node in nodes {
            guard let segments = Self.segments(node.path), !segments.isEmpty,
                  node.description.utf8.count <= 256, methods[node.path] == nil else {
                throw ProtocolError.malformed("OSC Query method path, description or duplicate")
            }
            budget -= try Self.measure(node)
            guard budget >= 0 else { throw ProtocolError.malformed("OSC Query metadata budget exceeded") }
            var prefix = ""
            for segmentSlice in segments {
                let segment = String(segmentSlice)
                if children[prefix.isEmpty ? "/" : prefix, default: []].insert(segment).inserted { branchCount += 1 }
                prefix += "/" + segment
            }
            guard branchCount <= Self.maximumEntries else { throw ProtocolError.malformed("OSC Query tree limit exceeded") }
            methods[node.path] = node
        }
        self.methods = methods
        self.children = children
    }

    public static func isMethodPath(_ path: String) -> Bool {
        guard let segments = segments(path) else { return false }
        return !segments.isEmpty
    }

    private static func segments(_ path: String) -> [Substring]? {
        guard path.hasPrefix("/"), path.utf8.count <= maximumPathBytes else { return nil }
        if path == "/" { return [] }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 12 else { return nil }
        for component in components {
            guard !component.isEmpty, component != ".", component != "..", component.utf8.allSatisfy({ byte in
                switch byte {
                case 45, 46, 48...57, 65...90, 95, 97...122, 126: return true
                default: return false
                }
            }) else { return nil }
        }
        return components
    }

    private static func measure(_ node: OSCQueryNode) throws -> Int {
        let types = Array(node.type.utf8)
        let supported: Set<UInt8> = [105, 102, 115, 84, 70, 98] // i f s T F b
        guard types.count <= 8, types.allSatisfy(supported.contains) else {
            throw ProtocolError.malformed("OSC Query types must use up to eight i, f, s, T, F or b arguments")
        }
        var cost = node.path.utf8.count + node.description.utf8.count + types.count
        if let value = node.value {
            guard node.access.isReadable, types.count == value.count else {
                throw ProtocolError.malformed("OSC Query VALUE does not match access or argument count")
            }
            for (tag, argument) in zip(types, value) { cost += try measure(argument, tag: tag) }
        }
        if let ranges = node.range {
            guard ranges.count == types.count else { throw ProtocolError.malformed("OSC Query RANGE count differs from TYPE") }
            for (tag, range) in zip(types, ranges) {
                guard let range else { continue }
                let numeric = tag == 105 || tag == 102
                let limits = [range.min, range.max].compactMap { $0 }
                let validLimits = limits.allSatisfy { limit in
                    guard numeric, limit.isFinite else { return false }
                    if tag == 102 { return Float(limit).isFinite }
                    return limit.rounded() == limit && limit >= Double(Int32.min) && limit <= Double(Int32.max)
                }
                guard validLimits, (range.min ?? -.infinity) <= (range.max ?? .infinity) else {
                    throw ProtocolError.malformed("OSC Query numeric range is invalid")
                }
                let options = range.values ?? []
                guard options.count <= 16 else { throw ProtocolError.malformed("OSC Query option count exceeds 16") }
                for option in options { cost += try measure(option, tag: tag) }
            }
        }
        return cost
    }

    private static func measure(_ value: OSCArgument, tag: UInt8) throws -> Int {
        switch value {
        case .int where tag == 105: return 4
        case .float(let n) where tag == 102 && n.isFinite: return 4
        case .bool where tag == 84 || tag == 70: return 1
        case .blob(let blob) where tag == 98 && blob.count <= 256: return blob.count
        case .string(let s) where tag == 115:
            guard s.utf8.count <= 256, s.utf8.allSatisfy({ $0 > 0 && $0 < 128 }) else { break }
            return s.utf8.count
        default: break
        }
        throw ProtocolError.malformed("OSC Query value is unsupported or mismatched to TYPE")
    }

    public func node(at path: String) -> OSCQueryNode? { methods[path] }

    public func hasSameMetadata(as other: Self) -> Bool {
        methods.count == other.methods.count && methods.allSatisfy { path, node in
            other.methods[path].map { node.hasSameMetadata(as: $0) } ?? false
        }
    }

    public func response(path: String, attribute: OSCQueryAttribute? = nil) throws -> OSCQueryResponse {
        guard methods[path] != nil || children[path] != nil else { return .notFound }
        let object: [String: Any]
        if let attribute {
            if attribute == .value, let node = methods[path], !node.access.isReadable { return .noContent }
            object = attributes(path: path, selecting: attribute)
        } else {
            object = attributes(path: path, selecting: nil)
        }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return bytes.count <= Self.maximumResponseBytes ? .json(bytes) : .tooLarge
    }

    private static func jsonValue(_ value: OSCArgument) -> Any {
        switch value {
        case .int(let n): return n
        case .float(let n): return n
        case .string(let s): return s
        case .bool(let b): return b
        case .blob: return NSNull()
        }
    }

    private func attributes(path: String, selecting attribute: OSCQueryAttribute?) -> [String: Any] {
        var object: [String: Any] = [:]
        func matches(_ candidate: OSCQueryAttribute) -> Bool { attribute == nil || attribute == candidate }
        let node = methods[path]
        if matches(.fullPath) { object["FULL_PATH"] = path }
        if matches(.access) { object["ACCESS"] = node?.access.rawValue ?? 0 }
        if matches(.description) { object["DESCRIPTION"] = node?.description ?? (path == "/" ? "ApertureCue" : "") }
        if matches(.type), let node { object["TYPE"] = node.type }
        if matches(.value), let value = node?.value { object["VALUE"] = value.map(Self.jsonValue) }
        if matches(.range), let range = node?.range {
            object["RANGE"] = range.map { item -> Any in
                guard let item else { return NSNull() }
                var bounds: [String: Any] = [:]
                if let min = item.min { bounds["MIN"] = min }
                if let max = item.max { bounds["MAX"] = max }
                if let values = item.values { bounds["VALS"] = values.map(Self.jsonValue) }
                return bounds
            }
        }
        if matches(.contents), let descendants = children[path] {
            var contents: [String: Any] = [:]
            let prefix = path == "/" ? "/" : path + "/"
            for child in descendants { contents[child] = attributes(path: prefix + child, selecting: nil) }
            object["CONTENTS"] = contents
        }
        return object
    }
}
