import Foundation

/// Per-output attenuation in normalized output coordinates. Black lift is a
/// software calibration parameter; it cannot reduce a projector's physical black.
public struct EdgeBlendSettings: Codable, Equatable, Sendable {
    public var left:Double, right:Double, top:Double, bottom:Double
    public var power:Double, gamma:Double, blackLevel:Double
    public init(left:Double=0,right:Double=0,top:Double=0,bottom:Double=0,
                power:Double=1,gamma:Double=1,blackLevel:Double=0) {
        self.left=left; self.right=right; self.top=top; self.bottom=bottom
        self.power=power; self.gamma=gamma; self.blackLevel=blackLevel
    }
}

public enum EdgeBlend {
    public static func validate(_ settings:EdgeBlendSettings) throws {
        guard [settings.left,settings.right,settings.top,settings.bottom].allSatisfy({$0.isFinite && (0...1).contains($0)}),
              settings.left+settings.right<=1,settings.top+settings.bottom<=1,
              settings.power.isFinite,(0.1...10).contains(settings.power),
              settings.gamma.isFinite,(0.1...5).contains(settings.gamma),
              settings.blackLevel.isFinite,(0...1).contains(settings.blackLevel) else {
            throw ProjectError.invalid("invalid edge blend widths, power, gamma or black level")
        }
    }
    /// Symmetric normalized power ramp: ramp(t)+ramp(1-t)=1, including all
    /// supported powers. Shared overlap coordinates must be complementary.
    public static func ramp(_ t:Double,power:Double=1) -> Double {
        guard t.isFinite,power.isFinite,(0.1...10).contains(power) else { return 0 }
        let u=min(1,max(0,t))
        if u<=0 {return 0}; if u>=1 {return 1}
        let a=pow(u,power),b=pow(1-u,power)
        return a/(a+b)
    }
    public static func gain(at point:Point2,settings:EdgeBlendSettings) -> Double {
        guard point.x.isFinite,point.y.isFinite,(0...1).contains(point.x),(0...1).contains(point.y),
              (try? validate(settings)) != nil else { return 0 }
        func edge(_ distance:Double,_ width:Double) -> Double {
            width>0 ? ramp(distance/width,power:settings.power) : 1
        }
        return edge(point.x,settings.left)*edge(1-point.x,settings.right)*edge(point.y,settings.top)*edge(1-point.y,settings.bottom)
    }
    /// RGB is unpremultiplied normalized compositor color; alpha remains owned
    /// by the compositor. Pair-sum tests use gamma=1, blackLevel=0.
    public static func channel(_ value:Double,at point:Point2,settings:EdgeBlendSettings) -> Double {
        guard value.isFinite,point.x.isFinite,point.y.isFinite,(0...1).contains(point.x),(0...1).contains(point.y),(try? validate(settings)) != nil else {return 0}
        let corrected=pow(min(1,max(0,value)),1/settings.gamma)
        return settings.blackLevel+(1-settings.blackLevel)*corrected*gain(at:point,settings:settings)
    }
}
