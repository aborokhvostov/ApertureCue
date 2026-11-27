#if os(macOS)
import Foundation
import CryptoKit
import MappingCore

struct OSCQueryHTTPProblem: Error {
    var status: Int
    var reason: String
}

struct OSCQueryHTTPRequest {
    static let maximumBytes = 8192
    static let headerEnd = Data([13, 10, 13, 10])
    let path: String
    let query: String?
    let websocketAccept: String?

    init(header: Data, localPort: UInt16) throws {
        let malformed = OSCQueryHTTPProblem(status: 400, reason: "Bad Request")
        guard header.count <= Self.maximumBytes, let text = String(data: header, encoding: .ascii) else { throw malformed }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, lines.count <= 64 else { throw malformed }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0",
              parts[1].utf8.count <= 1024,
              parts[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw malformed }
        guard parts[0] == "GET" else { throw OSCQueryHTTPProblem(status: 405, reason: "Method Not Allowed") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw malformed }
            let name = line[..<colon].lowercased()
            guard name.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) || (97...122).contains($0) }) else { throw malformed }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }),
                  headers.updateValue(value, forKey: name) == nil else { throw malformed }
        }
        let localNames = ["127.0.0.1", "localhost", "localhost."]
        let numbered = localNames.map { "\($0):\(localPort)" }
        let hosts = localPort == 80 ? localNames + numbered : numbered
        let forbidden = OSCQueryHTTPProblem(status: 403, reason: "Forbidden")
        guard let host = headers["host"]?.lowercased(), hosts.contains(host) else { throw forbidden }
        if let origin = headers["origin"], !hosts.contains(where: { origin == "http://" + $0 }) { throw forbidden }
        guard headers["transfer-encoding"] == nil, headers["content-length"].map({ $0 == "0" }) ?? true else { throw malformed }
        let target = parts[1].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let fields = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = fields.first, let rawPath = String(first).removingPercentEncoding else { throw malformed }
        let normalized = rawPath.count > 1 && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
        guard normalized == "/" || OSCQuerySnapshot.isMethodPath(normalized) else { throw malformed }
        path = normalized
        if fields.count == 2, !fields[1].isEmpty {
            guard fields[1].utf8.count <= 64, let attribute = String(fields[1]).removingPercentEncoding else { throw malformed }
            query = attribute
        } else { query = nil }
        if let upgrade = headers["upgrade"] {
            let tokens = headers["connection"]?.lowercased().split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            guard upgrade.lowercased() == "websocket", tokens.contains("upgrade"), parts[2] == "HTTP/1.1" else { throw malformed }
            guard headers["sec-websocket-version"] == "13" else {
                throw OSCQueryHTTPProblem(status: 426, reason: "Upgrade Required")
            }
            guard path == "/", query == nil, let key = headers["sec-websocket-key"],
                  let input = Data(base64Encoded: key), input.count == 16, input.base64EncodedString() == key else { throw malformed }
            let challenge = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
            websocketAccept = Data(Insecure.SHA1.hash(data: challenge)).base64EncodedString()
        } else { websocketAccept = nil }
    }
}

struct OSCQueryWebSocketFrame {
    static let maximumPayload = 4096
    let opcode: UInt8
    let final: Bool
    let payload: Data

    static func consumeClientFrame(in buffer: inout Data) throws -> Self? {
        guard buffer.count >= 2 else { return nil }
        let bytes = buffer.prefix(14)
        let start = bytes.startIndex
        let initial = bytes[start]
        let second = bytes[start + 1]
        let final = initial & 0x80 != 0
        let opcode = initial & 0x0F
        let allowed: Set<UInt8> = [0, 1, 2, 8, 9, 10]
        guard initial & 0x70 == 0, second & 0x80 != 0, allowed.contains(opcode) else {
            throw OSCQueryWebSocketError.protocolViolation
        }
        var length = Int(second & 0x7F)
        var header = 2
        if opcode >= 8, (!final || length > 125) { throw OSCQueryWebSocketError.protocolViolation }
        if length == 127 { throw OSCQueryWebSocketError.oversize }
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[start + 2]) << 8 | Int(bytes[start + 3])
            guard length >= 126 else { throw OSCQueryWebSocketError.protocolViolation }
            header += 2
        }
        guard length <= maximumPayload else { throw OSCQueryWebSocketError.oversize }
        let prefix = header + 4
        guard buffer.count >= prefix + length else { return nil }
        let mask = [bytes[start + header], bytes[start + header + 1], bytes[start + header + 2], bytes[start + header + 3]]
        var payload = Data()
        payload.reserveCapacity(length)
        for (index, byte) in buffer.dropFirst(prefix).prefix(length).enumerated() {
            payload.append(byte ^ mask[index % 4])
        }
        buffer.removeFirst(prefix + length)
        return Self(opcode: opcode, final: final, payload: payload)
    }

    static func encoded(opcode: UInt8, payload: Data = Data()) -> Data {
        precondition(payload.count <= UInt16.max)
        var result = Data([0x80 | opcode])
        if payload.count <= 125 { result.append(UInt8(payload.count)) }
        else { result.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]) }
        result.append(payload)
        return result
    }

    static func closePayload(code: UInt16) -> Data {
        Data([UInt8(code >> 8), UInt8(code & 0xFF)])
    }

    static func validateClosePayload(_ payload: Data) throws {
        if payload.isEmpty { return }
        guard payload.count >= 2 else { throw OSCQueryWebSocketError.protocolViolation }
        let index = payload.startIndex
        let code = UInt16(payload[index]) << 8 | UInt16(payload[index + 1])
        let reserved: Set<UInt16> = [1004, 1005, 1006, 1015]
        guard ((1000...1014).contains(code) && !reserved.contains(code)) || (3000...4999).contains(code) else {
            throw OSCQueryWebSocketError.protocolViolation
        }
        guard String(data: payload.dropFirst(2), encoding: .utf8) != nil else { throw OSCQueryWebSocketError.invalidText }
    }
}

enum OSCQueryWebSocketError: Error {
    case protocolViolation, unsupported, invalidText, policy, oversize
    var closeCode: UInt16 {
        switch self {
        case .protocolViolation: return 1002
        case .unsupported: return 1003
        case .invalidText: return 1007
        case .policy: return 1008
        case .oversize: return 1009
        }
    }
}
#endif
