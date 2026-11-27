import Foundation

public enum FirmataError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedVersion(Int, Int)
    case invalidDiscovery
    case handshakeTimedOut
    case boardUnavailable
    case unsupportedPin
    case outputBusy

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let major, let minor):
            return "Firmata \(major).\(minor) is unsupported. This adapter requires protocol 2.5 or later in the 2.x series."
        case .invalidDiscovery: return "The board returned inconsistent Firmata pin capabilities."
        case .handshakeTimedOut: return "The Firmata handshake timed out."
        case .boardUnavailable: return "Connect and discover a Firmata board first."
        case .unsupportedPin: return "The selected pin does not support this operation or is the current input."
        case .outputBusy: return "Wait for the current digital write to finish."
        }
    }
}

public enum FirmataInput: Equatable, Sendable {
    case analog(channel: Int)
    case digital(pin: Int)
}

public struct FirmataSample: Equatable, Sendable {
    public let input: FirmataInput
    public let value: Int
    public let maximum: Int
    public var normalized: Double { Double(value) / Double(maximum) }
}

public struct FirmataPin: Equatable, Sendable {
    public let index: Int
    public let digitalInput: Bool
    public let digitalOutput: Bool
    public let analogChannel: Int?
    public let analogResolution: Int?
}

public struct FirmataBoard: Equatable, Sendable {
    public let protocolMajor: Int
    public let protocolMinor: Int
    public let pins: [FirmataPin]
}

public enum FirmataPhase: Equatable, Sendable {
    case disconnected
    case discovering
    case ready(FirmataBoard)
    case failed(FirmataError)
}

public enum FirmataOutputState: Equatable, Sendable {
    case idle
    case pending(pin: Int, high: Bool)
    case confirmed(pin: Int, high: Bool)
    case unconfirmed(pin: Int)
}

private enum FirmataMessage {
    case version(Int, Int)
    case digital(Int, Int)
    case analog(Int, Int)
    case capabilities([UInt8])
    case analogMapping([UInt8])
    case pinState(pin: Int, mode: UInt8, value: Int)
    case reset
}

/// Incremental Firmata input. The data buffer is bounded even for an unterminated SysEx packet.
private struct FirmataParser: Sendable {
    private static let maximumSysExBytes = 4096
    private enum Partial: Sendable {
        case idle, fixed(UInt8), second(UInt8, UInt8), sysEx, discardSysEx
    }
    private var partial = Partial.idle
    private var sysEx = [UInt8]()

    mutating func read(_ byte: UInt8) -> FirmataMessage? {
        if byte >= 0x80 {
            switch byte {
            case 0xF0:
                sysEx.removeAll(keepingCapacity: true)
                partial = .sysEx
            case 0xF7:
                let isComplete: Bool
                if case .sysEx = partial { isComplete = true } else { isComplete = false }
                partial = .idle
                defer { sysEx.removeAll(keepingCapacity: true) }
                return isComplete ? decodeSysEx() : nil
            case 0xF9, 0x90...0x9F, 0xE0...0xEF: partial = .fixed(byte)
            case 0xFF:
                partial = .idle
                return .reset
            default: partial = .idle
            }
            return nil
        }
        switch partial {
        case .idle, .discardSysEx:
            return nil
        case .sysEx:
            if sysEx.count < Self.maximumSysExBytes {
                sysEx.append(byte)
            } else {
                sysEx.removeAll(keepingCapacity: true)
                partial = .discardSysEx
            }
            return nil
        case .fixed(let status):
            partial = .second(status, byte)
            return nil
        case .second(let status, let low):
            partial = .idle
            if status == 0xF9 { return .version(Int(low), Int(byte)) }
            let channel = Int(status & 0x0F)
            let value = Int(low) | (Int(byte) << 7)
            if status & 0xF0 == 0xE0 { return .analog(channel, value) }
            return value <= 255 ? .digital(channel, value) : nil
        }
    }

    private func decodeSysEx() -> FirmataMessage? {
        guard let command = sysEx.first else { return nil }
        switch command {
        case 0x6C: return .capabilities(Array(sysEx.dropFirst()))
        case 0x6A: return .analogMapping(Array(sysEx.dropFirst()))
        case 0x6E:
            guard (4...6).contains(sysEx.count) else { return nil }
            let value = sysEx.dropFirst(3).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 7)) }
            return .pinState(pin: Int(sysEx[1]), mode: sysEx[2], value: value)
        default: return nil
        }
    }
}

public struct FirmataSession: Sendable {
    private struct Capabilities: Sendable {
        var input = false
        var output = false
        var analogBits: Int?
    }

    private static let versionQuery: [UInt8] = [0xF9]
    private static let discoveryQueries: [UInt8] = [0xF0, 0x6B, 0xF7, 0xF0, 0x69, 0xF7]
    private static let handshakeTimeout = 8.0
    private static let retryInterval = 0.75
    private static let outputTimeout = 1.0

    public private(set) var phase = FirmataPhase.disconnected
    public private(set) var input: FirmataInput?
    public private(set) var latestSample: FirmataSample?
    public private(set) var output = FirmataOutputState.idle

    private var parser = FirmataParser()
    private var version: (major: Int, minor: Int)?
    private var capabilities: [Capabilities]?
    private var analogMapping: [UInt8]?
    private var discoveryDeadline = 0.0
    private var retryAt = 0.0
    private var pendingUntil = 0.0
    private var confirmedOutputs = Set<Int>()

    public init() {}

    public mutating func connect(at now: Double) -> Data {
        self = Self()
        startDiscovery(at: now)
        return Data(Self.versionQuery)
    }

    public mutating func disconnect() { self = Self() }

    /// Retries only identification requests. Pin modes and writes are never replayed automatically.
    public mutating func tick(at now: Double) -> Data {
        if case .pending(let pin, _) = output, now >= pendingUntil {
            output = .unconfirmed(pin: pin)
            confirmedOutputs.remove(pin)
        }
        guard phase == .discovering else { return Data() }
        if now >= discoveryDeadline {
            phase = .failed(.handshakeTimedOut)
            return Data()
        }
        guard now >= retryAt else { return Data() }
        retryAt = now + Self.retryInterval
        return Data(version == nil ? Self.versionQuery : Self.discoveryQueries)
    }

    /// Consumes a serial fragment and returns identification commands needed by the new state.
    public mutating func receive(_ bytes: Data, at now: Double) -> Data {
        guard phase == .discovering || isReady else { return Data() }
        // Only the most recent identification transition can require a response in this fragment.
        var response = [UInt8]()
        for byte in bytes {
            guard let message = parser.read(byte) else { continue }
            let command = receive(message, at: now)
            if !command.isEmpty { response = command }
            if case .failed = phase { return Data() }
        }
        return Data(response)
    }

    public mutating func configureInput(_ selection: FirmataInput?) throws -> Data {
        guard case .ready(let board) = phase else { throw FirmataError.boardUnavailable }
        guard !isOutputPending else { throw FirmataError.outputBusy }
        let newPin = try selection.map { try pin(for: $0, on: board) }
        var bytes = input.map { reportCommand(for: $0, enable: false) } ?? []
        input = selection
        latestSample = nil
        if let selection, let newPin {
            confirmedOutputs.remove(newPin.index)
            let mode: UInt8
            switch selection {
            case .analog: mode = 2
            case .digital: mode = 0
            }
            bytes += [0xF4, UInt8(newPin.index), mode]
            bytes += reportCommand(for: selection, enable: true)
        }
        return Data(bytes)
    }

    /// Requests one explicitly selected digital write and a readback of its firmware pin state.
    public mutating func writeDigital(pin: Int, high: Bool, at now: Double) throws -> Data {
        guard case .ready(let board) = phase else { throw FirmataError.boardUnavailable }
        guard !isOutputPending else { throw FirmataError.outputBusy }
        guard board.pins.indices.contains(pin), board.pins[pin].digitalOutput,
              try input.map({ try self.pin(for: $0, on: board).index }) != pin else {
            throw FirmataError.unsupportedPin
        }
        var bytes: [UInt8] = []
        if !confirmedOutputs.contains(pin) { bytes = [0xF4, UInt8(pin), 1] }
        bytes += [0xF5, UInt8(pin), high ? 1 : 0, 0xF0, 0x6D, UInt8(pin), 0xF7]
        output = .pending(pin: pin, high: high)
        pendingUntil = now + Self.outputTimeout
        return Data(bytes)
    }

    private var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    private var isOutputPending: Bool {
        if case .pending = output { return true }
        return false
    }

    private mutating func startDiscovery(at now: Double) {
        phase = .discovering
        version = nil
        capabilities = nil
        analogMapping = nil
        input = nil
        latestSample = nil
        output = .idle
        confirmedOutputs.removeAll()
        discoveryDeadline = now + Self.handshakeTimeout
        retryAt = now + Self.retryInterval
    }

    private mutating func receive(_ message: FirmataMessage, at now: Double) -> [UInt8] {
        switch message {
        case .reset:
            let continuedDeadline = phase == .discovering ? discoveryDeadline : nil
            startDiscovery(at: now)
            if let continuedDeadline {
                discoveryDeadline = continuedDeadline
                // A repeated reset byte during discovery does not trigger additional writes.
                return []
            }
            return Self.versionQuery
        case .version(let major, let minor):
            guard major == 2, minor >= 5 else {
                startDiscovery(at: now)
                phase = .failed(.unsupportedVersion(major, minor))
                return []
            }
            if isReady { startDiscovery(at: now) }
            if let previous = version, previous.major == major, previous.minor == minor { return [] }
            capabilities = nil
            analogMapping = nil
            version = (major, minor)
            retryAt = now + Self.retryInterval
            return Self.discoveryQueries
        case .capabilities(let data):
            guard phase == .discovering, version != nil else { return [] }
            do {
                capabilities = try Self.decodeCapabilities(data)
                try completeDiscovery()
            } catch { phase = .failed(.invalidDiscovery) }
        case .analogMapping(let values):
            guard phase == .discovering, version != nil else { return [] }
            analogMapping = values
            do { try completeDiscovery() } catch { phase = .failed(.invalidDiscovery) }
        case .digital(let port, let bits):
            guard case .digital(let pin) = input, pin / 8 == port else { return [] }
            latestSample = FirmataSample(input: .digital(pin: pin), value: (bits >> (pin % 8)) & 1, maximum: 1)
        case .analog(let channel, let raw):
            guard input == .analog(channel: channel), case .ready(let board) = phase,
                  let pin = try? pin(for: .analog(channel: channel), on: board), let bits = pin.analogResolution else { return [] }
            let maximum = (1 << bits) - 1
            guard raw <= maximum else { return [] }
            latestSample = FirmataSample(input: .analog(channel: channel), value: raw, maximum: maximum)
        case .pinState(let pin, let mode, let raw):
            guard case .pending(let expectedPin, let high) = output, pin == expectedPin else { return [] }
            if mode == 1, raw == (high ? 1 : 0), now < pendingUntil {
                output = .confirmed(pin: pin, high: high)
                confirmedOutputs.insert(pin)
            } else {
                output = .unconfirmed(pin: pin)
                confirmedOutputs.remove(pin)
            }
        }
        return []
    }

    private func pin(for selection: FirmataInput, on board: FirmataBoard) throws -> FirmataPin {
        switch selection {
        case .digital(let pin):
            guard board.pins.indices.contains(pin), board.pins[pin].digitalInput else { throw FirmataError.unsupportedPin }
            return board.pins[pin]
        case .analog(let channel):
            guard let pin = board.pins.first(where: { $0.analogChannel == channel }) else { throw FirmataError.unsupportedPin }
            return pin
        }
    }

    private func reportCommand(for selection: FirmataInput, enable: Bool) -> [UInt8] {
        switch selection {
        case .analog(let channel): return [0xC0 | UInt8(channel), enable ? 1 : 0]
        case .digital(let pin): return [0xD0 | UInt8(pin / 8), enable ? 1 : 0]
        }
    }

    private mutating func completeDiscovery() throws {
        guard let version, let capabilities, let analogMapping else { return }
        guard capabilities.count == analogMapping.count else { throw FirmataError.invalidDiscovery }
        var channels = Set<UInt8>()
        var pins = [FirmataPin]()
        for (index, capability) in capabilities.enumerated() {
            let mapping = analogMapping[index]
            if mapping != 127 {
                guard capability.analogBits != nil, channels.insert(mapping).inserted else {
                    throw FirmataError.invalidDiscovery
                }
            }
            let isAnalog = mapping < 16
            pins.append(FirmataPin(index: index, digitalInput: capability.input, digitalOutput: capability.output,
                                   analogChannel: isAnalog ? Int(mapping) : nil,
                                   analogResolution: isAnalog ? capability.analogBits : nil))
        }
        phase = .ready(FirmataBoard(protocolMajor: version.major, protocolMinor: version.minor, pins: pins))
    }

    private static func decodeCapabilities(_ data: [UInt8]) throws -> [Capabilities] {
        var pins = [Capabilities]()
        var capability = Capabilities()
        var index = 0
        while index < data.count {
            let mode = data[index]
            if mode == 127 {
                guard pins.count < 128 else { throw FirmataError.invalidDiscovery }
                pins.append(capability)
                capability = Capabilities()
                index += 1
                continue
            }
            guard index + 1 < data.count, data[index + 1] < 127 else { throw FirmataError.invalidDiscovery }
            let bits = Int(data[index + 1])
            switch mode {
            case 0:
                guard !capability.input, bits == 1 else { throw FirmataError.invalidDiscovery }
                capability.input = true
            case 1:
                guard !capability.output, bits == 1 else { throw FirmataError.invalidDiscovery }
                capability.output = true
            case 2:
                guard capability.analogBits == nil, (1...14).contains(bits) else { throw FirmataError.invalidDiscovery }
                capability.analogBits = bits
            default: break
            }
            index += 2
        }
        guard !pins.isEmpty, data.last == 127 else { throw FirmataError.invalidDiscovery }
        return pins
    }
}
