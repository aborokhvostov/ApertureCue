#if os(macOS)
import AppKit
import MappingCore

/// Readback pixels use top-left normalized output coordinates.
struct LightingRaster {
    private let image: NSBitmapImageRep
    private let bytes: UnsafeMutablePointer<UInt8>
    private let width: Int
    private let height: Int
    private let stride: Int
    private let integral: [SIMD3<Int32>]

    init?(_ image: NSBitmapImageRep, withArea: Bool) {
        guard let data = image.bitmapData, image.pixelsWide > 0, image.pixelsHigh > 0 else { return nil }
        self.image = image
        bytes = data
        width = image.pixelsWide
        height = image.pixelsHigh
        stride = image.bytesPerRow
        guard withArea else { integral = []; return }
        let pitch = width + 1
        var sums = Array(repeating: SIMD3<Int32>.zero, count: pitch * (height + 1))
        for y in 0..<height {
            var row = SIMD3<Int32>.zero
            for x in 0..<width {
                let offset = y * stride + x * 4
                row = row &+ SIMD3(Int32(data[offset]), Int32(data[offset + 1]), Int32(data[offset + 2]))
                let index = y * pitch + x + 1
                sums[index + pitch] = sums[index] &+ row
            }
        }
        integral = sums
    }

    func color(at point: Point2, area: FixtureSampling?) -> MappingCore.RGBColor {
        let x = min(width - 1, max(0, Int(point.x * Double(width))))
        let y = min(height - 1, max(0, Int(point.y * Double(height))))
        if let area, !integral.isEmpty {
            let xs = Self.extent(at: point.x, span: area.width, size: width, nearest: x)
            let ys = Self.extent(at: point.y, span: area.height, size: height, nearest: y)
            let pitch = width + 1
            let start = ys.lowerBound * pitch
            let end = ys.upperBound * pitch
            let total = integral[end + xs.upperBound] &- integral[end + xs.lowerBound]
                &- integral[start + xs.upperBound] &+ integral[start + xs.lowerBound]
            let divisor = Double(xs.count * ys.count) * 255
            return MappingCore.RGBColor(Double(total.x) / divisor, Double(total.y) / divisor, Double(total.z) / divisor)
        }
        let offset = y * stride + x * 4
        return withExtendedLifetime(image) {
            MappingCore.RGBColor(Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255, Double(bytes[offset + 2]) / 255)
        }
    }

    private static func extent(at position: Double, span: Double, size: Int, nearest: Int) -> Range<Int> {
        let lower = max(0, Int(ceil((position - span / 2) * Double(size) - 0.5)))
        let upper = min(size, Int(floor((position + span / 2) * Double(size) - 0.5)) + 1)
        return lower < upper ? lower..<upper : nearest..<(nearest + 1)
    }
}
#endif
