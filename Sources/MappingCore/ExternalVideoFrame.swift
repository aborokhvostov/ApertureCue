import Foundation

/// A portable, immutable frame record for independently built local producers.
/// Consumers manage session selection, freshness and resource ownership separately.
public struct ExternalVideoFrame: Equatable, Sendable {
    public static let headerBytes = 40
    public static let maximumWidth = 1280
    public static let maximumHeight = 720
    public static let maximumFileBytes = headerBytes + maximumWidth * maximumHeight * 4
    private static let magic = Array("ACFRAME1".utf8)

    public let producer: UUID
    public let sequence: UInt64
    public let width: Int
    public let height: Int
    public let bgra: Data
    public var bytesPerRow: Int { width * 4 }

    public init(producer: UUID, sequence: UInt64, width: Int, height: Int, bgra: Data) throws {
        guard sequence > 0, (1...Self.maximumWidth).contains(width),
              (1...Self.maximumHeight).contains(height), bgra.count == width * height * 4 else {
            throw ProjectError.invalid("Invalid sequence, dimensions or length for an external BGRA frame")
        }
        self.producer = producer
        self.sequence = sequence
        self.width = width
        self.height = height
        self.bgra = bgra
    }

    public func serialized() -> Data {
        var versioned = Data(Self.magic)
        var identifier = producer.uuid
        var order = sequence.bigEndian
        var w = UInt32(width).bigEndian
        var h = UInt32(height).bigEndian
        withUnsafeBytes(of: &identifier) { versioned.append(contentsOf: $0) }
        withUnsafeBytes(of: &order) { versioned.append(contentsOf: $0) }
        withUnsafeBytes(of: &w) { versioned.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { versioned.append(contentsOf: $0) }
        versioned.append(bgra)
        return versioned
    }

    public init(serialized data: Data) throws {
        guard data.count > Self.headerBytes, data.count <= Self.maximumFileBytes,
              data.prefix(8).elementsEqual(Self.magic) else {
            throw ProjectError.invalid("External frame header or byte budget")
        }
        let header = Array(data.prefix(Self.headerBytes))
        let id = UUID(uuid: (header[8], header[9], header[10], header[11], header[12], header[13], header[14], header[15],
                             header[16], header[17], header[18], header[19], header[20], header[21], header[22], header[23]))
        func unpack(_ bytes: ArraySlice<UInt8>) -> UInt64 {
            bytes.reduce(0) { ($0 << 8) | UInt64($1) }
        }
        let width = Int(unpack(header[32..<36]))
        let height = Int(unpack(header[36..<40]))
        try self.init(producer: id, sequence: unpack(header[24..<32]), width: width, height: height,
                      bgra: Data(data.dropFirst(Self.headerBytes)))
    }

    public static func isValidName(_ value: String) -> Bool {
        let bytes = value.utf8
        guard (1...48).contains(bytes.count) else { return false }
        return bytes.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
            (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
}

/// Admission uses local monotonic time. A competing producer can replace a
/// selected name only after losing its previous live owner.
public struct ExternalFrameOrder: Sendable {
    private(set) public var producer: UUID?
    private(set) public var lastSequence: UInt64 = 0
    private var lastArrival: Double?
    public static let timeout = 1.0

    public init() {}

    public func isFresh(at host: Double) -> Bool {
        guard let lastArrival, host.isFinite else { return false }
        return host >= lastArrival && host - lastArrival < Self.timeout
    }

    public mutating func admit(_ frame: ExternalVideoFrame, at host: Double) -> Bool {
        guard host.isFinite, host >= (lastArrival ?? 0) else { return false }
        if frame.producer == producer {
            guard frame.sequence > lastSequence else { return false }
        } else if isFresh(at: host) {
            return false
        }
        producer = frame.producer
        lastSequence = frame.sequence
        lastArrival = host
        return true
    }
}
