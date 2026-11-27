import Foundation

public enum PJLinkAuthentication: String, CaseIterable, Sendable {
    case sha256
    case legacyMD5
    case unprotected

    public var title: String {
        switch self {
        case .sha256: return "SHA-256"
        case .legacyMD5: return "Legacy MD5"
        case .unprotected: return "No authentication"
        }
    }
}

public enum PJLinkPower: String, Equatable, Sendable {
    case standby = "0"
    case on = "1"
    case cooling = "2"
    case warming = "3"

    public var title: String {
        switch self {
        case .standby: return "Standby"
        case .on: return "On"
        case .cooling: return "Cooling"
        case .warming: return "Warming up"
        }
    }
}

public enum PJLinkMute: String, Equatable, Sendable {
    case clear = "30"
    case video = "11"
    case audio = "21"
    case both = "31"

    public var title: String {
        switch self {
        case .clear: return "Off"
        case .video: return "Video muted"
        case .audio: return "Audio muted"
        case .both: return "Audio and video muted"
        }
    }
}

public enum PJLinkCondition: UInt8, Equatable, Sendable {
    case clearOrUnsupported = 0
    case warning = 1
    case fault = 2
}

public struct PJLinkFaults: Equatable, Sendable {
    public let fan: PJLinkCondition
    public let lamp: PJLinkCondition
    public let temperature: PJLinkCondition
    public let cover: PJLinkCondition
    public let filter: PJLinkCondition
    public let other: PJLinkCondition

    public init(fan: PJLinkCondition, lamp: PJLinkCondition, temperature: PJLinkCondition,
                cover: PJLinkCondition, filter: PJLinkCondition, other: PJLinkCondition) {
        self.fan = fan
        self.lamp = lamp
        self.temperature = temperature
        self.cover = cover
        self.filter = filter
        self.other = other
    }
}

public enum PJLinkCommand: Equatable, Sendable {
    case powerStatus, muteStatus, faults, deviceClass
    case setPower(Bool), setMute(Bool)

    public var body: String {
        switch self {
        case .powerStatus, .setPower: return "POWR"
        case .muteStatus, .setMute: return "AVMT"
        case .faults: return "ERST"
        case .deviceClass: return "CLSS"
        }
    }

    private var parameter: String {
        switch self {
        case .setPower(let enabled): return enabled ? "1" : "0"
        case .setMute(let enabled): return enabled ? "31" : "30"
        default: return "?"
        }
    }

    public var isWrite: Bool {
        switch self {
        case .setPower, .setMute: return true
        default: return false
        }
    }

    public var wire: Data { Data(("%1" + body + " " + parameter + "\r").utf8) }
}

public enum PJLinkRejection: String, Equatable, Sendable {
    case unsupported = "ERR1"
    case parameter = "ERR2"
    case unavailable = "ERR3"
    case deviceFailure = "ERR4"

    public var title: String {
        switch self {
        case .unsupported: return "Command unsupported (ERR1)"
        case .parameter: return "Parameter rejected (ERR2)"
        case .unavailable: return "Unavailable in the current projector state (ERR3)"
        case .deviceFailure: return "Projector reported a fault (ERR4)"
        }
    }
}

public enum PJLinkReply: Equatable, Sendable {
    case acknowledged
    case power(PJLinkPower)
    case mute(PJLinkMute)
    case faults(PJLinkFaults)
    case deviceClass(Int)
    case rejected(PJLinkRejection)
}

public enum PJLinkProtocolError: Error, LocalizedError, Equatable {
    case malformedLine
    case malformedReply
    case malformedGreeting
    case authenticationRejected
    case authenticationMismatch
    case invalidPassword
    case invalidTransaction
    case disconnected
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .malformedLine: return "Malformed PJLink line or line length"
        case .malformedReply: return "PJLink reply does not match the command"
        case .malformedGreeting: return "Unsupported PJLink greeting"
        case .authenticationRejected: return "Projector rejected authentication"
        case .authenticationMismatch: return "Projector authentication differs from the selected mode"
        case .invalidPassword: return "Enter a PJLink password of 1…32 ASCII letters or digits"
        case .invalidTransaction: return "Invalid PJLink transaction"
        case .disconnected: return "Projector disconnected before replying"
        case .timedOut: return "PJLink transaction timed out"
        case .cancelled: return "PJLink transaction cancelled"
        }
    }
}

/// CR-terminated ASCII lines. The public decoder accepts bounded TCP fragments
/// and retains partial lines between reads.
public struct PJLinkLineDecoder {
    public static let maximumLineBytes = 135 // header, class, name, separator + 128 payload bytes
    public static let maximumFragmentBytes = 512
    private var partial: [UInt8] = []
    public var hasPartialLine: Bool { !partial.isEmpty }

    public init() {}

    public mutating func append(_ fragment: Data) throws -> [String] {
        guard fragment.count <= Self.maximumFragmentBytes else { throw PJLinkProtocolError.malformedLine }
        var lines: [String] = []
        for byte in fragment {
            if byte == 13 {
                guard !partial.isEmpty else { throw PJLinkProtocolError.malformedLine }
                lines.append(String(decoding: partial, as: UTF8.self))
                partial.removeAll(keepingCapacity: true)
            } else {
                guard (32...126).contains(byte), partial.count < Self.maximumLineBytes else {
                    throw PJLinkProtocolError.malformedLine
                }
                partial.append(byte)
            }
        }
        return lines
    }
}

public enum PJLinkGreeting: Equatable, Sendable {
    case unprotected
    case password(challenge: String)
    case modernChallenge([UInt8])

    public init(line: String) throws {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.first?.uppercased() == "PJLINK" else { throw PJLinkProtocolError.malformedGreeting }
        if parts.count == 2, parts[1].uppercased() == "ERRA" { throw PJLinkProtocolError.authenticationRejected }
        if parts.count == 2, parts[1] == "0" { self = .unprotected; return }
        if parts.count == 3, parts[1] == "1", Self.decodeHex(parts[2], count: 4) != nil {
            self = .password(challenge: String(parts[2]))
            return
        }
        if parts.count == 3, parts[1] == "2", let bytes = Self.decodeHex(parts[2], count: 16) {
            self = .modernChallenge(bytes)
            return
        }
        if parts.count == 2, ["ERR1", "ERR2", "2"].contains(parts[1].uppercased()) {
            throw PJLinkProtocolError.authenticationMismatch
        }
        throw PJLinkProtocolError.malformedGreeting
    }

    private static func decodeHex(_ text: Substring, count: Int) -> [UInt8]? {
        let characters = Array(text.utf8)
        guard characters.count == count * 2 else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var bytes: [UInt8] = []
        for offset in stride(from: 0, to: characters.count, by: 2) {
            guard let first = nibble(characters[offset]), let second = nibble(characters[offset + 1]) else { return nil }
            bytes.append(first << 4 | second)
        }
        return bytes
    }
}

public enum PJLinkCodec {
    public static let securityInquiry = Data("PJLINK 2\r".utf8)

    public static func validPassword(_ password: String) -> Bool {
        (1...32).contains(password.utf8.count) && password.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    public static func legacyDigestInput(challenge: String, password: String) throws -> Data {
        guard validPassword(password) else { throw PJLinkProtocolError.invalidPassword }
        guard case .password = try PJLinkGreeting(line: "PJLINK 1 " + challenge) else {
            throw PJLinkProtocolError.malformedGreeting
        }
        return Data((challenge + password).utf8)
    }

    public static func modernDigestInput(projectorNonce: [UInt8], controllerNonce: [UInt8], password: String) throws -> Data {
        guard validPassword(password) else { throw PJLinkProtocolError.invalidPassword }
        guard projectorNonce.count == 16, controllerNonce.count == 16 else { throw PJLinkProtocolError.malformedGreeting }
        let mixed = zip(projectorNonce, controllerNonce).map { $0 ^ $1 }
        return Data((hex(mixed) + password).utf8)
    }

    public static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }

    public static func reply(to command: PJLinkCommand, line: String) throws -> PJLinkReply {
        if line.uppercased() == "PJLINK ERRA" { throw PJLinkProtocolError.authenticationRejected }
        let prefix = "%1" + command.body + "="
        guard line.utf8.count <= PJLinkLineDecoder.maximumLineBytes,
              line.prefix(prefix.count).uppercased() == prefix else { throw PJLinkProtocolError.malformedReply }
        let body = String(line.dropFirst(prefix.count))
        if let result = PJLinkRejection(rawValue: body.uppercased()) { return .rejected(result) }
        switch command {
        case .setPower, .setMute:
            if body.uppercased() == "OK" { return .acknowledged }
        case .powerStatus:
            if let state = PJLinkPower(rawValue: body) { return .power(state) }
        case .muteStatus:
            if let state = PJLinkMute(rawValue: body) { return .mute(state) }
        case .deviceClass:
            if body == "1" || body == "2", let value = Int(body) { return .deviceClass(value) }
        case .faults:
            let values = body.utf8.compactMap { byte -> PJLinkCondition? in
                guard (48...50).contains(byte) else { return nil }
                return PJLinkCondition(rawValue: byte - 48)
            }
            if body.utf8.count == 6, values.count == 6 {
                return .faults(PJLinkFaults(fan: values[0], lamp: values[1], temperature: values[2],
                                           cover: values[3], filter: values[4], other: values[5]))
            }
        }
        throw PJLinkProtocolError.malformedReply
    }
}

public protocol PJLinkTransport {
    mutating func send(_ message: Data) throws
    mutating func receiveLine() throws -> String
}

public enum PJLinkDigest: Equatable, Sendable { case sha256, md5 }

/// Bounded Class 1 request flow. The adapter supplies the TCP connection,
/// deadline and platform digest implementation.
public enum PJLinkClient {
    public static let port: UInt16 = 4352
    public static let statusCommands: [PJLinkCommand] = [.powerStatus, .muteStatus, .faults, .deviceClass]

    public static func transact<Transport: PJLinkTransport>(
        over transport: inout Transport, using authentication: PJLinkAuthentication,
        password: String, commands: [PJLinkCommand],
        controllerNonce: () -> [UInt8],
        digest: (PJLinkDigest, Data) -> [UInt8]
    ) throws -> [PJLinkReply] {
        guard (1...4).contains(commands.count), commands.count == 1 || !commands.contains(where: \.isWrite) else {
            throw PJLinkProtocolError.invalidTransaction
        }
        if authentication == .unprotected {
            guard password.isEmpty else { throw PJLinkProtocolError.invalidTransaction }
        } else {
            guard PJLinkCodec.validPassword(password) else { throw PJLinkProtocolError.invalidPassword }
        }
        let greeting = try PJLinkGreeting(line: transport.receiveLine())
        let authenticationPrefix: String
        switch (authentication, greeting) {
        case (.unprotected, .unprotected):
            authenticationPrefix = ""
        case (.legacyMD5, .password(let challenge)):
            let bytes = digest(.md5, try PJLinkCodec.legacyDigestInput(challenge: challenge, password: password))
            guard bytes.count == 16 else { throw PJLinkProtocolError.invalidTransaction }
            authenticationPrefix = PJLinkCodec.hex(bytes)
        case (.sha256, .password):
            try transport.send(PJLinkCodec.securityInquiry)
            let upgraded = try PJLinkGreeting(line: transport.receiveLine())
            guard case .modernChallenge(let projectorNonce) = upgraded else {
                throw PJLinkProtocolError.authenticationMismatch
            }
            let controller = controllerNonce()
            let input = try PJLinkCodec.modernDigestInput(projectorNonce: projectorNonce, controllerNonce: controller, password: password)
            let bytes = digest(.sha256, input)
            guard bytes.count == 32 else { throw PJLinkProtocolError.invalidTransaction }
            authenticationPrefix = PJLinkCodec.hex(controller) + PJLinkCodec.hex(bytes)
        default:
            throw PJLinkProtocolError.authenticationMismatch
        }
        var results: [PJLinkReply] = []
        for (index, command) in commands.enumerated() {
            var message = index == 0 ? Data(authenticationPrefix.utf8) : Data()
            message.append(command.wire)
            try transport.send(message)
            try results.append(PJLinkCodec.reply(to: command, line: transport.receiveLine()))
        }
        return results
    }
}
