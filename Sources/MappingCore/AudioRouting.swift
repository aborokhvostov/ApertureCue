import Foundation

/// Signed output-row-major PCM routing. The application adapter may impose a
/// smaller device-specific channel limit. Nil on MediaAsset preserves legacy
/// AVPlayer system-audio behavior; an explicit disabled route produces silence.
public struct AudioRoutingSettings:Codable,Equatable,Sendable {
    public var deviceUID:String?
    public var inputChannels:Int
    public var outputChannels:Int
    public var gains:[Double]
    public var muted:Bool
    public var enabled:Bool
    public init(deviceUID:String?=nil,inputChannels:Int=2,outputChannels:Int=2,gains:[Double]=[1,0,0,1],muted:Bool=false,enabled:Bool=true) {
        self.deviceUID=deviceUID;self.inputChannels=inputChannels;self.outputChannels=outputChannels
        self.gains=gains;self.muted=muted;self.enabled=enabled
    }
    public static func identity(inputChannels:Int,outputChannels:Int,deviceUID:String?=nil) -> AudioRoutingSettings {
        guard (1...32).contains(inputChannels),(1...32).contains(outputChannels) else {
            return AudioRoutingSettings(deviceUID:deviceUID,inputChannels:inputChannels,outputChannels:outputChannels,gains:[])
        }
        var values=Array(repeating:0.0,count:inputChannels*outputChannels)
        for channel in 0..<min(inputChannels,outputChannels) {values[channel*inputChannels+channel]=1}
        return AudioRoutingSettings(deviceUID:deviceUID,inputChannels:inputChannels,outputChannels:outputChannels,gains:values)
    }
    public func validate() throws {
        guard (1...32).contains(inputChannels),(1...32).contains(outputChannels),
              gains.count==inputChannels*outputChannels,gains.allSatisfy({$0.isFinite && abs($0)<=4}) else {throw ProjectError.invalid("audio matrix requires 1…32 channels and finite gains in -4…4")}
        if let uid=deviceUID {guard !uid.isEmpty,uid.utf8.count<=4096,!uid.contains("\0") else {throw ProjectError.invalid("audio device UID is invalid")}}
    }
    /// Deterministic Float PCM reference used by the native audio adapter. Every
    /// multiply accumulates in Double and clips once after the complete row sum.
    /// Volume is a post-matrix master fader, matching the native output mixer.
    public func mix(interleaved:[Float],frameCount:Int,volume:Double=1) throws -> [Float] {
        try validate()
        guard (0...1048576).contains(frameCount),interleaved.count==frameCount*inputChannels,
              volume.isFinite,(0...1).contains(volume),interleaved.allSatisfy({$0.isFinite}) else {throw ProjectError.invalid("PCM buffer size, volume or samples are invalid")}
        var output=Array(repeating:Float(0),count:frameCount*outputChannels)
        guard enabled,!muted,volume>0 else {return output}
        for frame in 0..<frameCount {
            for row in 0..<outputChannels {
                var sum:Double=0
                for column in 0..<inputChannels {sum+=Double(interleaved[frame*inputChannels+column])*gains[row*inputChannels+column]}
                output[frame*outputChannels+row]=Float(max(-1,min(1,sum))*volume)
            }
        }
        return output
    }
}
