import Foundation

public enum KeyMode: String, Codable, CaseIterable, Sendable { case none, chroma, luma }

/// Evaluated on straight RGBA after material/source lookup and before the
/// existing surface RGB/brightness/gamma and premultiplied compositor.
public struct EffectsSettings: Codable, Equatable, Sendable {
    public var keyMode: KeyMode
    public var keyColor: [Double]
    public var threshold: Double
    public var softness: Double
    public var spill: Double
    public var saturation: Double
    public var inverted: Bool
    /// Zero disables quantization; enabled levels are 2...256.
    public var posterizeLevels: Int
    public init(keyMode: KeyMode = .none, keyColor: [Double] = [0,1,0],
                threshold: Double = 0.1, softness: Double = 0.1, spill: Double = 0,
                saturation: Double = 1, inverted: Bool = false, posterizeLevels: Int = 0) {
        self.keyMode=keyMode; self.keyColor=keyColor; self.threshold=threshold
        self.softness=softness; self.spill=spill; self.saturation=saturation
        self.inverted=inverted; self.posterizeLevels=posterizeLevels
    }
}

public enum Effects {
    public static func validate(_ settings: EffectsSettings) throws {
        guard settings.keyColor.count == 3, settings.keyColor.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              [settings.threshold,settings.softness,settings.spill].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              settings.saturation.isFinite, (0...2).contains(settings.saturation),
              settings.posterizeLevels == 0 || (2...256).contains(settings.posterizeLevels) else {
            throw ProjectError.invalid("invalid chroma/luma key or effects settings")
        }
    }

    /// Deterministic numerical oracle for the production shader snippet below.
    /// Chroma distance is RGB Euclidean distance divided by sqrt(3). Luma is
    /// Rec.709 encoded-RGB weighting, not a color-managed scene-linear measure.
    public static func evaluate(_ rgba: [Double], settings: EffectsSettings) throws -> [Double] {
        try validate(settings)
        guard rgba.count == 4, rgba.allSatisfy(\.isFinite) else { throw ProjectError.invalid("effects input must be finite RGBA") }
        func clamp(_ x: Double) -> Double { min(1,max(0,x)) }
        var rgb=Array(rgba.prefix(3)).map(clamp)
        var alpha=clamp(rgba[3])
        if settings.keyMode != .none {
            let metric: Double
            if settings.keyMode == .chroma {
                metric=sqrt(zip(rgb,settings.keyColor).reduce(0) { $0+pow($1.0-$1.1,2) }/3)
            } else { metric=rgb[0]*0.2126+rgb[1]*0.7152+rgb[2]*0.0722 }
            let u=settings.softness > 0 ? clamp((metric-settings.threshold)/settings.softness) : (metric > settings.threshold ? 1.0 : 0.0)
            alpha *= settings.softness > 0 ? u*u*(3-2*u) : u
            if settings.keyMode == .chroma {
                // A deterministic first-largest tie matches the GPU comparison.
                var dominant=0
                if settings.keyColor[1] > settings.keyColor[dominant] { dominant=1 }
                if settings.keyColor[2] > settings.keyColor[dominant] { dominant=2 }
                let other=(0..<3).filter { $0 != dominant }.map { rgb[$0] }.max() ?? 0
                rgb[dominant] -= max(0,rgb[dominant]-other)*settings.spill
            }
        }
        let luma=rgb[0]*0.2126+rgb[1]*0.7152+rgb[2]*0.0722
        rgb=rgb.map { clamp(luma+($0-luma)*settings.saturation) }
        if settings.inverted { rgb=rgb.map { 1-$0 } }
        if settings.posterizeLevels > 0 {
            let steps=Double(settings.posterizeLevels-1)
            rgb=rgb.map { floor($0*steps+0.5)/steps }
        }
        return rgb+[alpha]
    }

    /// The caller supplies two packed float4s plus a float4 key color:
    /// keyStyle = (mode: none=0/chroma=1/luma=2, threshold, softness, spill)
    /// effectStyle = (saturation, inverted:0/1, posterizeLevels, unused)
    /// keyColor.rgb = normalized key color. No samplers/buffers are introduced.
    public static let metalFunction = """
    float4 apertureEffects(float4 source, float4 keyColor, float4 keyStyle, float4 effectStyle) {
        float3 rgb = clamp(source.rgb,0.0,1.0);
        float alpha = clamp(source.a,0.0,1.0);
        if (keyStyle.x > 0.5) {
            float metric = keyStyle.x < 1.5 ? length(rgb-keyColor.rgb)/sqrt(3.0) : dot(rgb,float3(0.2126,0.7152,0.0722));
            float u = keyStyle.z > 0.0 ? clamp((metric-keyStyle.y)/keyStyle.z,0.0,1.0) : (metric > keyStyle.y ? 1.0 : 0.0);
            alpha *= keyStyle.z > 0.0 ? u*u*(3.0-2.0*u) : u;
            if (keyStyle.x < 1.5) {
                int dominant=0;
                if (keyColor.g > keyColor[dominant]) dominant=1;
                if (keyColor.b > keyColor[dominant]) dominant=2;
                float other = dominant == 0 ? max(rgb.g,rgb.b) : (dominant == 1 ? max(rgb.r,rgb.b) : max(rgb.r,rgb.g));
                rgb[dominant] -= max(0.0,rgb[dominant]-other)*keyStyle.w;
            }
        }
        float luma=dot(rgb,float3(0.2126,0.7152,0.0722));
        rgb=clamp(float3(luma)+(rgb-float3(luma))*effectStyle.x,0.0,1.0);
        if (effectStyle.y > 0.5) rgb=1.0-rgb;
        if (effectStyle.z >= 2.0) { float steps=effectStyle.z-1.0; rgb=floor(rgb*steps+0.5)/steps; }
        return float4(rgb,alpha);
    }
    """
}
