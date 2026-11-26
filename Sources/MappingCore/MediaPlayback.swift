import Foundation

public enum MediaPlaybackMode:String,Codable,CaseIterable,Sendable {
    case once,loop,hold,pingPong,random
}

/// Persistent source settings; elapsed time belongs to a runtime transport.
/// Negative rate reads backwards; zero rate and Hold keep the initial position.
public struct MediaPlaybackSettings:Codable,Equatable,Sendable {
    public var trimIn:Double
    public var trimOut:Double?
    public var rate:Double
    public var mode:MediaPlaybackMode
    public var randomSeed:UInt64
    public var randomInterval:Double
    public init(trimIn:Double=0,trimOut:Double?=nil,rate:Double=1,mode:MediaPlaybackMode = .loop,randomSeed:UInt64=1,randomInterval:Double=0.1) {
        self.trimIn=trimIn;self.trimOut=trimOut;self.rate=rate;self.mode=mode;self.randomSeed=randomSeed;self.randomInterval=randomInterval
    }
    public func validate() throws {
        guard trimIn.isFinite,trimIn>=0,trimIn<=MediaPlayback.maximumTime,
              rate.isFinite,abs(rate)<=8,randomInterval.isFinite,
              randomInterval>=1.0/240,randomInterval<=3600 else {throw ProjectError.invalid("invalid source playback settings")}
        if let end=trimOut {
            guard end.isFinite,end<=MediaPlayback.maximumTime,end-trimIn>=1e-6 else {throw ProjectError.invalid("source trim must have a positive bounded span")}
        }
    }
}

public struct MediaPlaybackSample:Equatable,Sendable {
    /// Target item time, always inside the half-open decoded source interval.
    public let position:Double
    /// Normalized source-time direction: -1, 0 or +1, independent of rate magnitude.
    public let direction:Double
    public let ended:Bool
    /// Wrap, bounce or random epoch, suitable for detecting source discontinuities.
    public let discontinuityIndex:UInt64
}

public enum MediaPlayback {
    public static let maximumTime:Double=86400*365
    public static func effectiveSettings(_ asset:MediaAsset) -> MediaPlaybackSettings {
        asset.playback ?? MediaPlaybackSettings(mode:asset.loop ? .loop : .once)
    }
    public static func sample(elapsed:Double,duration:Double,settings:MediaPlaybackSettings,frameRate:Double=30) throws -> MediaPlaybackSample {
        try settings.validate()
        guard elapsed.isFinite,elapsed>=0,elapsed<=maximumTime,duration.isFinite,duration>0,duration<=maximumTime,
              frameRate.isFinite,frameRate>=1.0/240,frameRate<=240 else {throw ProjectError.invalid("source sample time, duration or frame rate is invalid")}
        let start=settings.trimIn,end=min(duration,settings.trimOut ?? duration),span=end-start
        guard span>=1e-6 else {throw ProjectError.invalid("source trim does not overlap available media")}
        // Leave a real margin for CMTime conversion, while retaining the final VFR
        // frame rather than assuming that it lasts one nominal frame interval.
        let last=max(start,end-min(1e-6,span/2))
        let reverse=settings.rate<0,sign=reverse ? -1.0 : 1.0
        let distance=elapsed*abs(settings.rate)
        func result(_ position:Double,_ direction:Double,_ ended:Bool=false,_ epoch:UInt64=0)->MediaPlaybackSample {
            MediaPlaybackSample(position:min(last,max(start,position)),direction:direction,ended:ended,discontinuityIndex:epoch)
        }
        if settings.mode == .hold || settings.rate==0 {return result(reverse ? last : start,0)}
        switch settings.mode {
        case .hold:return result(reverse ? last : start,0)
        case .once:
            let ended=distance>=span
            return result(reverse ? end-distance : start+distance,ended ? 0 : sign,ended)
        case .loop:
            let epoch=UInt64(floor(distance/span))
            let phase=distance.truncatingRemainder(dividingBy:span)
            return result(reverse ? end-phase : start+phase,sign,false,epoch)
        case .pingPong:
            let epoch=UInt64(floor(distance/span)),phase=distance.truncatingRemainder(dividingBy:span)
            let backwards=(epoch%2==1) != reverse
            return result(backwards ? end-phase : start+phase,backwards ? -1 : 1,false,epoch)
        case .random:
            let epoch=UInt64(floor(distance/settings.randomInterval))
            // Counter-based SplitMix64: random access and backward seek do not
            // depend on call order, process hash seeds or mutable RNG state.
            var bits=settings.randomSeed &+ epoch &* 0x9e3779b97f4a7c15
            bits=(bits ^ (bits >> 30)) &* 0xbf58476d1ce4e5b9
            bits=(bits ^ (bits >> 27)) &* 0x94d049bb133111eb
            bits ^= bits >> 31
            let count=max(1,Int(ceil(span*frameRate)))
            let index=Int(bits%UInt64(count))
            return result(start+Double(index)/frameRate,0,false,epoch)
        }
    }
}

public enum SourceTransportMode:String,Codable,Sendable {case followMaster,independent}

/// Host-clock transport used by per-source controls. It does not own a decoder,
/// run a timer or change the saved project when time advances.
public struct SourceTransport:Equatable,Sendable {
    public private(set) var mode:SourceTransportMode = .followMaster
    public private(set) var isPlaying=false
    private var heldTime:Double=0
    private var anchor:Double=0
    public init() {}
    public func position(masterTime:Double,hostTime:Double) throws -> Double {
        try Self.validateHost(hostTime)
        if mode == .followMaster {return try Self.validTime(masterTime)}
        return min(MediaPlayback.maximumTime,heldTime+(isPlaying ? max(0,hostTime-anchor) : 0))
    }
    public mutating func followMaster() {mode = .followMaster;isPlaying=false}
    public mutating func play(at hostTime:Double,masterTime:Double=0) throws {
        let time=try position(masterTime:masterTime,hostTime:hostTime)
        mode = .independent;heldTime=time;anchor=hostTime;isPlaying=true
    }
    public mutating func pause(at hostTime:Double,masterTime:Double=0) throws {
        let time=try position(masterTime:masterTime,hostTime:hostTime)
        mode = .independent;heldTime=time;anchor=hostTime;isPlaying=false
    }
    public mutating func seek(to time:Double,at hostTime:Double) throws {
        let position=try Self.validTime(time);try Self.validateHost(hostTime)
        mode = .independent;heldTime=position;anchor=hostTime
    }
    private static func validateHost(_ time:Double) throws {
        guard time.isFinite,time>=0 else {throw ProjectError.invalid("source host time is invalid")}
    }
    private static func validTime(_ time:Double) throws -> Double {
        guard time.isFinite,time>=0,time<=MediaPlayback.maximumTime else {throw ProjectError.invalid("source time exceeds the bounded working range")}
        return time
    }
}

/// A folder source has a frozen manifest. Gaps in numeric filenames are played
/// consecutively; directory additions are admitted only by an explicit refresh.
public struct MediaSequenceSettings:Codable,Equatable,Sendable {
    public static let maximumFrames=10000
    public static let supportedExtensions:Set<String>=["png","jpg","jpeg","tif","tiff","bmp"]
    public var frames:[String]
    public var fps:Double
    public init(frames:[String],fps:Double=30) {self.frames=frames;self.fps=fps}
    public var duration:Double {Double(frames.count)/fps}
    public func validate() throws {
        guard !frames.isEmpty,frames.count<=Self.maximumFrames,Set(frames).count==frames.count,
              fps.isFinite,fps>=1.0/240,fps<=240 else {throw ProjectError.invalid("image sequence requires 1…10000 unique frames and a bounded FPS")}
        for name in frames {
            guard Self.isSafeFrameName(name) else {throw ProjectError.invalid("image sequence contains an unsafe or unsupported frame name")}
        }
    }
    public static func isSafeFrameName(_ name:String) -> Bool {
        !name.isEmpty && name.utf8.count<=255 && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) &&
        supportedExtensions.contains(URL(fileURLWithPath:name).pathExtension.lowercased())
    }
    public static func discover(names:[String],fps:Double=30) throws -> MediaSequenceSettings {
        guard names.count<=100000 else {throw ProjectError.invalid("image sequence directory exceeds enumeration limit")}
        let admitted=names.filter {supportedExtensions.contains(URL(fileURLWithPath:$0).pathExtension.lowercased())}
        var settings=MediaSequenceSettings(frames:admitted,fps:fps)
        try settings.validate()
        settings.frames.sort(by:naturalOrder)
        return settings
    }
    /// Constant-time sampling after validate() at import/reconcile. Frame-name
    /// validation is deliberately not repeated for every presentation tick.
    public func frameIndex(at time:Double) throws -> Int {
        guard !frames.isEmpty,frames.count<=Self.maximumFrames,fps.isFinite,fps>=1.0/240,fps<=240,
              time.isFinite,time>=0,time<duration else {throw ProjectError.invalid("image sequence time is outside its half-open duration")}
        return min(frames.count-1,Int(floor(time*fps)))
    }
    /// Numeric runs compare as arbitrary-length integers, then by zero padding.
    /// No locale, filesystem enumeration order or integer conversion is involved.
    public static func naturalOrder(_ lhs:String,_ rhs:String) -> Bool {
        let a=Array(lhs.lowercased().utf8),b=Array(rhs.lowercased().utf8)
        var i=0,j=0
        while i<a.count && j<b.count {
            let da=(48...57).contains(a[i]),db=(48...57).contains(b[j])
            if da && db {
                let ai=i,bj=j
                while i<a.count && (48...57).contains(a[i]) {i+=1}
                while j<b.count && (48...57).contains(b[j]) {j+=1}
                var az=ai,bz=bj
                while az<i-1 && a[az]==48 {az+=1}
                while bz<j-1 && b[bz]==48 {bz+=1}
                if i-az != j-bz {return i-az<j-bz}
                let av=Array(a[az..<i]),bv=Array(b[bz..<j])
                if av != bv {return av.lexicographicallyPrecedes(bv)}
                if i-ai != j-bj {return i-ai<j-bj}
            } else {
                if a[i] != b[j] {return a[i]<b[j]};i+=1;j+=1
            }
        }
        if i != a.count || j != b.count {return i==a.count}
        return lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
