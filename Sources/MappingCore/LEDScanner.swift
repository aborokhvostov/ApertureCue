import Foundation

/// One addressed flash bracketed by dark samples. The rasters are 8-bit luma
/// in top-to-bottom row order. JSON carries the raster bytes as base64.
public struct LEDScanFrameSet: Codable, Equatable, Sendable {
    public var slot: Int
    public var darkBefore: Data
    public var flash: Data
    public var darkAfter: Data

    public init(slot: Int, darkBefore: Data, flash: Data, darkAfter: Data) {
        self.slot = slot
        self.darkBefore = darkBefore
        self.flash = flash
        self.darkAfter = darkAfter
    }
}

public struct LEDScanCapture: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumSlots = 170
    public static let maximumAxis = 1024
    public static let maximumPixels = 262_144
    public static let maximumRasterBytes = 32 * 1024 * 1024
    public static let maximumDocumentBytes = 44 * 1024 * 1024

    public var version: Int
    public var width: Int
    public var height: Int
    public var frames: [LEDScanFrameSet]

    public init(version: Int = currentVersion, width: Int, height: Int, frames: [LEDScanFrameSet]) {
        self.version = version
        self.width = width
        self.height = height
        self.frames = frames
    }

    public func validate() throws {
        guard version == Self.currentVersion else { throw ProjectError.invalid("unsupported LED scan file version") }
        guard (8...Self.maximumAxis).contains(width), (8...Self.maximumAxis).contains(height),
              width * height <= Self.maximumPixels else { throw ProjectError.invalid("LED scan raster dimensions exceed limits") }
        let pixels = width * height
        guard (1...Self.maximumSlots).contains(frames.count), frames.count * pixels * 3 <= Self.maximumRasterBytes else {
            throw ProjectError.invalid("LED scan requires 1–170 slots within a 32 MiB raster budget")
        }
        let slots = Set(frames.map(\.slot))
        guard slots == Set(1...frames.count),
              frames.allSatisfy({ $0.darkBefore.count == pixels && $0.flash.count == pixels && $0.darkAfter.count == pixels }) else {
            throw ProjectError.invalid("LED scan slots must be unique and consecutive; all rasters must match the declared size")
        }
    }

    public static func load(from url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= maximumDocumentBytes else {
            throw ProjectError.invalid("LED scan import requires a regular JSON file at most 44 MiB")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var bytes = Data()
        while bytes.count <= maximumDocumentBytes {
            guard let chunk = try handle.read(upToCount: min(65_536, maximumDocumentBytes + 1 - bytes.count)), !chunk.isEmpty else { break }
            bytes.append(chunk)
        }
        guard bytes.count <= maximumDocumentBytes else { throw ProjectError.invalid("LED scan document exceeds 44 MiB") }
        let capture = try JSONDecoder().decode(Self.self, from: bytes)
        try capture.validate()
        return capture
    }
}

public enum LEDScanIssue: String, Codable, Equatable, Sendable {
    case noSignal, ambiguous, repeatedPosition
}

public struct LEDScanDetection: Equatable, Sendable {
    public let slot: Int
    public let point: Point2?
    public let issue: LEDScanIssue?
}

public struct LEDScanResult: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let detections: [LEDScanDetection]

    public var unresolvedSlots: [Int] { detections.filter { $0.point == nil }.map(\.slot) }

    public func makeFixture(name: String, universe: Int, address: Int, channelOrder: String,
                            skippingUnresolved: Bool = false) throws -> Fixture {
        let skipped = unresolvedSlots.map { $0 - 1 }
        guard skipped.isEmpty || (skippingUnresolved && skipped.count < detections.count) else {
            let missing = unresolvedSlots.prefix(12).map(String.init).joined(separator: ", ")
            throw ProjectError.invalid("unresolved LED slots \(missing) • patch addresses were preserved")
        }
        let points = detections.map { $0.point ?? Point2(0, 0) }
        let fixture = Fixture(name: name, universe: universe, address: address, points: points, channelOrder: channelOrder,
                              skippedPixels: skipped.isEmpty ? nil : skipped)
        try FixtureSampler.validate(fixtures: [fixture])
        return fixture
    }
}

public enum LEDScanner {
    private struct Highlight {
        var energy = 0
        var weightedX = 0.0
        var weightedY = 0.0
        var size = 0
        var point: Point2 { Point2(weightedX / Double(energy), weightedY / Double(energy)) }
    }

    public static func decode(_ capture: LEDScanCapture) throws -> LEDScanResult {
        try capture.validate()
        let width = capture.width
        let height = capture.height
        var detections = capture.frames.sorted(by: { $0.slot < $1.slot }).map {
            decode($0, width: width, height: height)
        }
        var repeated = Set<Int>()
        for i in detections.indices {
            guard let first = detections[i].point else { continue }
            for j in detections.indices.dropFirst(i + 1) {
                guard let second = detections[j].point else { continue }
                let dx = (first.x - second.x) * Double(width)
                let dy = (first.y - second.y) * Double(height)
                if dx * dx + dy * dy < 4 { repeated.formUnion([i, j]) }
            }
        }
        for index in repeated {
            detections[index] = LEDScanDetection(slot: detections[index].slot, point: nil, issue: .repeatedPosition)
        }
        return LEDScanResult(width: width, height: height, detections: detections)
    }

    private static func decode(_ images: LEDScanFrameSet, width: Int, height: Int) -> LEDScanDetection {
        let count = width * height
        var histogram = [Int](repeating: 0, count: 511)
        var residuals = [Int16](repeating: 0, count: count)
        images.darkBefore.withUnsafeBytes { beforeBuffer in
            images.flash.withUnsafeBytes { flashBuffer in
                images.darkAfter.withUnsafeBytes { afterBuffer in
                    let before = beforeBuffer.bindMemory(to: UInt8.self)
                    let flash = flashBuffer.bindMemory(to: UInt8.self)
                    let after = afterBuffer.bindMemory(to: UInt8.self)
                    for i in 0..<count {
                        let dark = (Int(before[i]) + Int(after[i]) + 1) / 2
                        let delta = Int(flash[i]) - dark
                        residuals[i] = Int16(delta)
                        histogram[delta + 255] += 1
                    }
                }
            }
        }
        let middle = median(histogram, count: count)
        let ambient = middle - 255
        var noiseHistogram = [Int](repeating: 0, count: histogram.count)
        for i in histogram.indices { noiseHistogram[abs(i - middle)] += histogram[i] }
        let noise = median(noiseHistogram, count: count)
        let threshold = max(22, 5 * noise + 10)

        var mask = residuals.map { Int($0) - ambient >= threshold }
        let maximumSize = min(4096, max(8, count / 50))
        var winner: Highlight?
        var second: Highlight?
        var search: [Int] = []
        for start in mask.indices where mask[start] {
            search.removeAll(keepingCapacity: true)
            search.append(start)
            mask[start] = false
            var cursor = 0
            var cluster = Highlight()
            while cursor < search.count {
                let pixel = search[cursor]
                cursor += 1
                let x = pixel % width
                let y = pixel / width
                let energy = Int(residuals[pixel]) - ambient
                cluster.energy += energy
                cluster.weightedX += (Double(x) + 0.5) * Double(energy)
                cluster.weightedY += (Double(y) + 0.5) * Double(energy)
                cluster.size += 1
                for nextY in max(0, y - 1)...min(height - 1, y + 1) {
                    for nextX in max(0, x - 1)...min(width - 1, x + 1) {
                        let next = nextY * width + nextX
                        if mask[next] { search.append(next); mask[next] = false }
                    }
                }
            }
            guard (3...maximumSize).contains(cluster.size) else { continue }
            if winner.map({ cluster.energy > $0.energy }) ?? true {
                second = winner
                winner = cluster
            } else if second.map({ cluster.energy > $0.energy }) ?? true {
                second = cluster
            }
        }
        guard let winner else { return LEDScanDetection(slot: images.slot, point: nil, issue: .noSignal) }
        if let second, second.energy * 100 >= winner.energy * 68 {
            return LEDScanDetection(slot: images.slot, point: nil, issue: .ambiguous)
        }
        return LEDScanDetection(slot: images.slot,
                                point: Point2(winner.point.x / Double(width), winner.point.y / Double(height)), issue: nil)
    }

    private static func median(_ histogram: [Int], count: Int) -> Int {
        var cumulative = 0
        for (value, occurrences) in histogram.enumerated() {
            cumulative += occurrences
            if cumulative >= (count + 1) / 2 { return value }
        }
        return 0
    }
}
