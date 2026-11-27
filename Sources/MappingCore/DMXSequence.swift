import Foundation

public enum DMXSequenceError: Error, LocalizedError, Equatable {
    case invalid(String)
    case limit(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "Invalid DMX sequence: \(detail)"
        case .limit(let detail): return "DMX sequence limit reached: \(detail)"
        }
    }
}

/// A full raw universe snapshot. Missing universes represent retired levels.
public struct DMXSequenceFrame: Equatable, Sendable {
    public let microseconds: UInt64
    public let universes: [Int: [UInt8]]

    public init(microseconds: UInt64, universes: [Int: [UInt8]]) {
        self.microseconds = microseconds
        self.universes = universes
    }

    fileprivate func checkedEncodedSize() throws -> Int {
        guard universes.count <= DMXSequence.maximumUniverses else { throw DMXSequenceError.limit("64 universes per frame") }
        var size = DMXSequence.frameHeaderBytes
        for (number, slots) in universes {
            guard (0...63_999).contains(number), (1...512).contains(slots.count) else {
                throw DMXSequenceError.invalid("universe must be 0…63999 and have 1…512 slots")
            }
            size += 4 + slots.count
        }
        return size
    }
}

public struct DMXSequence: Equatable, Sendable {
    public static let fileExtension = "acdmx"
    public static let maximumFileBytes = 64 * 1_024 * 1_024
    public static let maximumUniverses = 64
    public static let maximumFrames = 216_000
    public static let maximumDurationMicroseconds: UInt64 = 4 * 60 * 60 * 1_000_000
    private static let magic = Array("ACDMXSEQ".utf8)
    fileprivate static let headerBytes = 24
    fileprivate static let frameHeaderBytes = 10

    public let frames: [DMXSequenceFrame]
    public let durationMicroseconds: UInt64
    public let universeIDs: Set<Int>
    private let encodedSize: Int

    public init(frames: [DMXSequenceFrame], durationMicroseconds: UInt64) throws {
        var recorder = DMXSequenceRecorder()
        // This path validates a full sequence without coalescing identical
        // snapshots, so loading and saving preserves the exact stored stream.
        for frame in frames { try recorder.append(frame, coalesce: false) }
        self = try recorder.finish(at: durationMicroseconds)
    }

    fileprivate init(validatedFrames: [DMXSequenceFrame], duration: UInt64, universeIDs: Set<Int>, encodedSize: Int) {
        frames = validatedFrames
        durationMicroseconds = duration
        self.universeIDs = universeIDs
        self.encodedSize = encodedSize
    }

    /// Return the covering recorded snapshot, or nil in the leading gap.
    /// A later gap holds the immediately preceding snapshot.
    public func frameIndex(at microseconds: UInt64) -> Int? {
        var low = 0
        var high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].microseconds <= microseconds { low = middle + 1 }
            else { high = middle }
        }
        return low > 0 ? low - 1 : nil
    }

    public func snapshot(at microseconds: UInt64) -> [Int: [UInt8]] {
        frameIndex(at: microseconds).map { frames[$0].universes } ?? [:]
    }

    public func encoded() -> Data {
        var data = Data(Self.magic)
        data.reserveCapacity(encodedSize)
        func integer<T: FixedWidthInteger>(_ value: T) {
            var encoded = value.bigEndian
            withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
        }
        integer(UInt16(1))
        integer(UInt16(0))
        integer(UInt32(frames.count))
        integer(durationMicroseconds)
        for frame in frames {
            integer(frame.microseconds)
            integer(UInt16(frame.universes.count))
            for (number, slots) in frame.universes.sorted(by: { $0.key < $1.key }) {
                integer(UInt16(number))
                integer(UInt16(slots.count))
                data.append(contentsOf: slots)
            }
        }
        return data
    }

    public init(data: Data) throws {
        guard data.count <= Self.maximumFileBytes else { throw DMXSequenceError.limit("64 MiB file") }
        var reader = DMXSequenceReader(data)
        guard try reader.bytes(Self.magic.count).elementsEqual(Self.magic), try reader.integer(2) == 1,
              try reader.integer(2) == 0 else {
            throw DMXSequenceError.invalid("magic, version or reserved fields")
        }
        let count = Int(try reader.integer(4))
        let duration = try reader.integer(8)
        guard (1...Self.maximumFrames).contains(count), count <= reader.remaining / Self.frameHeaderBytes else {
            throw DMXSequenceError.invalid("declared frame count exceeds bounds or file length")
        }
        guard (1...Self.maximumDurationMicroseconds).contains(duration) else {
            throw DMXSequenceError.invalid("duration must be positive and at most four hours")
        }
        var recorder = DMXSequenceRecorder()
        for _ in 0..<count {
            let time = try reader.integer(8)
            let universeCount = Int(try reader.integer(2))
            guard time <= duration, universeCount <= Self.maximumUniverses,
                  universeCount <= reader.remaining / 5 else {
                throw DMXSequenceError.invalid("frame time or universe count exceeds bounds")
            }
            var universes: [Int: [UInt8]] = [:]
            var previous = -1
            for _ in 0..<universeCount {
                let id = Int(try reader.integer(2))
                let slots = Int(try reader.integer(2))
                guard id > previous, id <= 63_999, (1...512).contains(slots) else {
                    throw DMXSequenceError.invalid("unsorted/duplicate universe or malformed slot count")
                }
                universes[id] = Array(try reader.bytes(slots))
                previous = id
            }
            try recorder.append(DMXSequenceFrame(microseconds: time, universes: universes), coalesce: false)
        }
        guard reader.remaining == 0 else { throw DMXSequenceError.invalid("trailing data") }
        self = try recorder.finish(at: duration)
    }

    /// Write the complete local file and atomically replace an explicit file.
    public func save(to url: URL) throws {
        guard url.isFileURL else { throw DMXSequenceError.invalid("select a local sequence file") }
        try encoded().write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> Self {
        guard url.isFileURL else { throw DMXSequenceError.invalid("select a local sequence file") }
        let file = url.resolvingSymlinksInPath()
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw DMXSequenceError.invalid("a regular file is required") }
        guard let size = values.fileSize, size <= maximumFileBytes else { throw DMXSequenceError.limit("64 MiB file") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        return try Self(data: data)
    }
}

private struct DMXSequenceReader {
    let data: Data
    var position: Data.Index
    var remaining: Int { data.endIndex - position }

    init(_ data: Data) { self.data = data; position = data.startIndex }

    mutating func bytes(_ count: Int) throws -> Data.SubSequence {
        guard count >= 0, count <= remaining else { throw DMXSequenceError.invalid("truncated data") }
        let end = position + count
        let result = data[position..<end]
        position = end
        return result
    }

    mutating func integer(_ count: Int) throws -> UInt64 {
        try bytes(count).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

/// Retains bounded exact snapshots. Adjacent identical captures are held by
/// their predecessor, while the explicit stop timestamp preserves duration.
public struct DMXSequenceRecorder: Sendable {
    private var frames: [DMXSequenceFrame] = []
    private var universeIDs = Set<Int>()
    private var encodedSize = DMXSequence.headerBytes
    public private(set) var lastObservedMicroseconds: UInt64?
    public var frameCount: Int { frames.count }

    public init() {}

    public mutating func capture(_ universes: [Int: [UInt8]], at microseconds: UInt64) throws {
        try append(DMXSequenceFrame(microseconds: microseconds, universes: universes), coalesce: true)
    }

    fileprivate mutating func append(_ frame: DMXSequenceFrame, coalesce: Bool) throws {
        let time = frame.microseconds
        guard time <= DMXSequence.maximumDurationMicroseconds else { throw DMXSequenceError.limit("four-hour duration") }
        if let lastObservedMicroseconds {
            guard time > lastObservedMicroseconds else { throw DMXSequenceError.invalid("timestamps must increase") }
        }
        let size = try frame.checkedEncodedSize()
        let nextUniverses = universeIDs.union(frame.universes.keys)
        guard nextUniverses.count <= DMXSequence.maximumUniverses else { throw DMXSequenceError.limit("64 universes per file") }
        if !coalesce || frames.last?.universes != frame.universes {
            guard frames.count < DMXSequence.maximumFrames, size <= DMXSequence.maximumFileBytes - encodedSize else {
                throw DMXSequenceError.limit("216,000 frames or 64 MiB file")
            }
            frames.append(frame)
            encodedSize += size
            universeIDs = nextUniverses
        }
        lastObservedMicroseconds = time
    }

    public func finish(at microseconds: UInt64) throws -> DMXSequence {
        guard let lastObservedMicroseconds, !frames.isEmpty else {
            throw DMXSequenceError.invalid("capture contains no sampled frames")
        }
        guard microseconds >= lastObservedMicroseconds, (1...DMXSequence.maximumDurationMicroseconds).contains(microseconds) else {
            throw DMXSequenceError.invalid("duration must be positive and cover all observed frames")
        }
        return DMXSequence(validatedFrames: frames, duration: microseconds, universeIDs: universeIDs, encodedSize: encodedSize)
    }
}

public struct DMXSequenceTick: Equatable, Sendable {
    public let microseconds: UInt64
    public let frameIndex: Int?
    public let isPlaying: Bool
}

public struct DMXSequencePlayer: Sendable {
    public let sequence: DMXSequence
    public private(set) var microseconds: UInt64 = 0
    public private(set) var isPlaying = false
    public private(set) var generation: UInt64 = 0
    private var hostAnchor: UInt64 = 0
    private var positionAnchor: UInt64 = 0
    private var lastHost: UInt64 = 0

    public init(sequence: DMXSequence) { self.sequence = sequence }

    public var current: DMXSequenceTick {
        DMXSequenceTick(microseconds: microseconds, frameIndex: sequence.frameIndex(at: microseconds), isPlaying: isPlaying)
    }

    @discardableResult
    public mutating func play(at hostTime: UInt64) -> UInt64 {
        if isPlaying { return generation }
        if microseconds >= sequence.durationMicroseconds { microseconds = 0 }
        anchor(at: hostTime)
        isPlaying = true
        return generation
    }

    @discardableResult
    public mutating func stop() -> UInt64 {
        generation &+= 1
        isPlaying = false
        return generation
    }

    @discardableResult
    public mutating func seek(to time: UInt64, at hostTime: UInt64) -> UInt64 {
        microseconds = min(time, sequence.durationMicroseconds)
        if microseconds == sequence.durationMicroseconds { isPlaying = false }
        anchor(at: hostTime)
        return generation
    }

    /// An old scheduled tick or a backwards clock sample cannot publish bytes.
    public mutating func tick(at hostTime: UInt64, generation token: UInt64) -> DMXSequenceTick? {
        guard token == generation, isPlaying, hostTime >= lastHost else { return nil }
        lastHost = hostTime
        let elapsed = hostTime - hostAnchor
        let remaining = sequence.durationMicroseconds - positionAnchor
        microseconds = positionAnchor + min(remaining, elapsed)
        if microseconds == sequence.durationMicroseconds { isPlaying = false }
        return current
    }

    private mutating func anchor(at hostTime: UInt64) {
        generation &+= 1
        hostAnchor = hostTime
        lastHost = hostTime
        positionAnchor = microseconds
    }
}
