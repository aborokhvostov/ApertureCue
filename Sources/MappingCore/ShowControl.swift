import Foundation

/// A host-monotonic transport. No wall-clock time is used; tests can inject timestamps.
public final class TransportClock {
    public var duration: Double = 0
    public var loop: Bool = true
    public private(set) var isPlaying = false
    private var anchorTime: Double = 0
    private var anchorHostTime: Double = 0
    public init(duration: Double = 0, loop: Bool = true) { self.duration=duration; self.loop=loop }
    public var currentTime: Double { time(at:ProcessInfo.processInfo.systemUptime) }
    public func time(at hostTime: Double) -> Double {
        let elapsed = isPlaying ? max(0,hostTime-anchorHostTime) : 0
        let raw = max(0,anchorTime+elapsed)
        guard duration.isFinite, duration > 0 else { return raw }
        return loop && isPlaying ? raw.truncatingRemainder(dividingBy:duration) : min(raw,duration)
    }
    public func play(at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard !isPlaying, hostTime.isFinite else { return }
        if duration > 0, anchorTime >= duration { anchorTime = 0 }
        anchorHostTime = hostTime
        isPlaying = true
    }
    public func pause(at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard hostTime.isFinite else { return }
        anchorTime = time(at:hostTime)
        anchorHostTime = hostTime
        isPlaying = false
    }
    public func seek(to time: Double, at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard time.isFinite, hostTime.isFinite else { return }
        anchorTime = duration.isFinite && duration > 0 ? min(max(0,time),duration) : max(0,time)
        anchorHostTime = hostTime
    }
    /// Call from the UI timer to latch the stopped state at the non-looping end.
    public func update(at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        if isPlaying, !loop, duration > 0, time(at:hostTime) >= duration { pause(at:hostTime) }
    }
}

/// Interpolates cue snapshots using the same host-monotonic seconds as TransportClock.
public final class CueEngine {
    private var source: [Surface] = []
    private var target: [Surface] = []
    private var start: Double = 0
    private var duration: Double = 0
    public private(set) var activeCueID: UUID?
    public private(set) var isTransitioning = false
    public private(set) var completedAt: Double?
    public private(set) var followAfter: Double?
    public init() {}
    public func begin(from surfaces: [Surface], cue: Cue, at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        source=surfaces; target=cue.surfaces; start=hostTime; duration=max(0,cue.duration)
        activeCueID=cue.id; isTransitioning=true; completedAt=nil; followAfter=cue.followAfter
    }
    public func sample(at hostTime: Double = ProcessInfo.processInfo.systemUptime) -> [Surface]? {
        guard isTransitioning else { return nil }
        let t = duration <= 0 ? 1 : min(1,max(0,(hostTime-start)/duration))
        if t >= 1 {
            isTransitioning=false; completedAt=start+duration
            return target
        }
        let sourceByID = Dictionary(uniqueKeysWithValues:source.map { ($0.id,$0) })
        let targetIDs = Set(target.map(\.id))
        var result: [Surface] = []
        // Preserve outgoing-only layers until the transition ends, fading them out.
        for var old in source where !targetIDs.contains(old.id) {
            old.opacity *= 1-t; result.append(old)
        }
        for b in target {
            if let a = sourceByID[b.id] { result.append(Self.interpolate(a,b,t:t)) }
            else { var added=b; added.opacity *= t; result.append(added) }
        }
        return result
    }
    public func shouldFollow(at hostTime: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard !isTransitioning, let end=completedAt, let delay=followAfter else { return false }
        return hostTime >= end+delay
    }
    public func cancel() { isTransitioning=false; completedAt=nil; activeCueID=nil; followAfter=nil }
    public static func interpolate(_ a: Surface, _ b: Surface, t: Double) -> Surface {
        let u = min(1,max(0,t))
        if u >= 1 { return b }; if u <= 0 { return a }
        var s = u < 0.5 ? a : b
        func mix(_ x: Double, _ y: Double) -> Double { x+(y-x)*u }
        if a.input.count == b.input.count { s.input=zip(a.input,b.input).map { Point2.interpolate($0,$1,t:u) } }
        // Different parents define different local coordinate frames. Switch the
        // parent and its geometry together rather than interpolating unlike units.
        if a.groupID == b.groupID, a.output.count == b.output.count { s.output=zip(a.output,b.output).map { Point2.interpolate($0,$1,t:u) } }
        if a.groupID == b.groupID, a.meshColumns == b.meshColumns, a.meshRows == b.meshRows, a.mesh.count == b.mesh.count {
            s.mesh=zip(a.mesh,b.mesh).map { Point2.interpolate($0,$1,t:u) }
        }
        if a.groupID == b.groupID,a.shape == b.shape,a.shape.isStroke,
           a.stroke.closed == b.stroke.closed,a.stroke.nodes.count == b.stroke.nodes.count {
            let nodes=zip(a.stroke.nodes,b.stroke.nodes).map { x,y in
                StrokeNode(anchor:Point2.interpolate(x.anchor,y.anchor,t:u),
                           incoming:Point2.interpolate(x.incoming,y.incoming,t:u),
                           outgoing:Point2.interpolate(x.outgoing,y.outgoing,t:u))
            }
            var candidate=s
            candidate.stroke=StrokePath(nodes:nodes,width:mix(a.stroke.width,b.stroke.width),closed:a.stroke.closed)
            // Crossing/reversed centerlines can collapse during interpolation.
            // Keep the midpoint-selected discrete path rather than publish an
            // invalid document or silently drop the surface from the renderer.
            if (try? StrokeGeometry.samples(surface:candidate)) != nil { s.stroke=candidate.stroke }
        }
        s.opacity=mix(a.enabled ? a.opacity : 0,b.enabled ? b.opacity : 0)
        s.enabled=a.enabled || b.enabled
        s.brightness=mix(a.brightness,b.brightness); s.gamma=mix(a.gamma,b.gamma); s.feather=mix(a.feather,b.feather)
        if a.color.count == b.color.count { s.color=zip(a.color,b.color).map(mix) }
        if a.mask.count == b.mask.count { s.mask=zip(a.mask,b.mask).map { Point2.interpolate($0,$1,t:u) } }
        return s
    }
}

public enum AutomationInterpolation:String,Codable,CaseIterable,Sendable { case hold,linear,bezier }

public struct AutomationKeyframe: Codable, Equatable, Sendable {
    public var time: Double
    public var value: Double
    /// Interpolation of the outgoing segment. Exact next-key time uses its value.
    public var interpolation:AutomationInterpolation
    public var control1:Point2
    public var control2:Point2
    public init(time: Double, value: Double, interpolation:AutomationInterpolation = .linear,
                control1:Point2=Point2(1.0/3,1.0/3), control2:Point2=Point2(2.0/3,2.0/3)) {
        self.time=time; self.value=value; self.interpolation=interpolation
        self.control1=control1; self.control2=control2
    }
    private enum CodingKeys:String,CodingKey { case time,value,interpolation,control1,control2 }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        self.init(time:try c.decode(Double.self,forKey:.time),value:try c.decode(Double.self,forKey:.value),
                  interpolation:try c.decodeIfPresent(AutomationInterpolation.self,forKey:.interpolation) ?? .linear,
                  control1:try c.decodeIfPresent(Point2.self,forKey:.control1) ?? Point2(1.0/3,1.0/3),
                  control2:try c.decodeIfPresent(Point2.self,forKey:.control2) ?? Point2(2.0/3,2.0/3))
    }
}

public struct AutomationTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var surfaceID: UUID
    public var parameter: String
    public var keyframes: [AutomationKeyframe]
    public var enabled: Bool
    public init(id:UUID=UUID(),name:String,surfaceID:UUID,parameter:String,keyframes:[AutomationKeyframe],enabled:Bool=true) {
        self.id=id; self.name=name; self.surfaceID=surfaceID; self.parameter=parameter; self.keyframes=keyframes; self.enabled=enabled
    }
    private enum CodingKeys:String,CodingKey { case id,name,surfaceID,parameter,keyframes,enabled }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        self.init(id:try c.decodeIfPresent(UUID.self,forKey:.id) ?? UUID(),
                  name:try c.decodeIfPresent(String.self,forKey:.name) ?? "Automation",
                  surfaceID:try c.decode(UUID.self,forKey:.surfaceID),
                  parameter:try c.decode(String.self,forKey:.parameter),
                  keyframes:try c.decode([AutomationKeyframe].self,forKey:.keyframes),
                  enabled:try c.decodeIfPresent(Bool.self,forKey:.enabled) ?? true)
    }
}

public enum TimelineEngine {
    public static let parameters = ["opacity","brightness","gamma","red","green","blue"]
    public static func validate(tracks:[AutomationTrack],surfaces:[Surface]) throws {
        guard tracks.count <= 4096, Set(tracks.map(\.id)).count == tracks.count else { throw ProjectError.invalid("timeline track count or duplicate IDs") }
        let ids=Set(surfaces.map(\.id))
        var bindings=Set<String>(), total=0
        for track in tracks {
            guard ids.contains(track.surfaceID) else { throw ProjectError.invalid("timeline references nonexistent surface") }
            guard parameters.contains(track.parameter), track.name.utf8.count <= 4096 else { throw ProjectError.invalid("timeline parameter or name") }
            let binding=track.surfaceID.uuidString+":"+track.parameter
            guard bindings.insert(binding).inserted else { throw ProjectError.invalid("duplicate timeline surface/parameter binding") }
            total += track.keyframes.count
            guard !track.keyframes.isEmpty, track.keyframes.count <= 4096, total <= 65536 else { throw ProjectError.invalid("timeline keyframe count") }
            _ = try Automation.value(at:0,keyframes:track.keyframes)
            let range=try parameterRange(track.parameter)
            guard track.keyframes.allSatisfy({ $0.time <= 86400*365 && range.contains($0.value) }) else { throw ProjectError.invalid("timeline value or time outside supported range") }
        }
    }
    public static func parameterRange(_ parameter:String) throws -> ClosedRange<Double> {
        switch parameter {
        case "opacity":return 0...1
        case "gamma":return 0.01...10
        case "brightness","red","green","blue":return 0...16
        default:throw ProjectError.invalid("unknown timeline parameter")
        }
    }
    /// Evaluate against the caller's current transport time. No state accumulates across seeks/loops.
    /// Tracks for surfaces absent from a cue's current snapshot are dormant until that ID returns.
    public static func apply(tracks:[AutomationTrack],time:Double,surfaces:[Surface]) throws -> [Surface] {
        guard time.isFinite, time >= 0 else { throw ProjectError.invalid("timeline time must be finite and nonnegative") }
        var result=surfaces
        var indices:[UUID:Int]=[:]
        for i in result.indices { indices[result[i].id]=i }
        for track in tracks where track.enabled {
            guard let index=indices[track.surfaceID] else { continue }
            guard let value=try Automation.value(at:time,keyframes:track.keyframes) else { continue }
            switch track.parameter {
            case "opacity":result[index].opacity=value
            case "brightness":result[index].brightness=value
            case "gamma":result[index].gamma=value
            case "red","green","blue":
                guard result[index].color.count == 3 else { throw ProjectError.invalid("surface RGB multiplier") }
                let component=track.parameter == "red" ? 0 : track.parameter == "green" ? 1 : 2
                result[index].color[component]=value
            default:throw ProjectError.invalid("unknown timeline parameter")
            }
        }
        return result
    }
}

/// Immutable curve cache for editors. Construction validates once; drawing can
/// sample hundreds of points without rescanning the complete key collection.
public struct AutomationCurve:Sendable {
    private var keyframes:[AutomationKeyframe]
    public init(keyframes:[AutomationKeyframe]) throws {
        if !keyframes.isEmpty { try Automation.validate(keyframes:keyframes) }
        self.keyframes=keyframes
    }
    public func value(at time:Double) throws -> Double? {
        guard time.isFinite else { throw ProjectError.invalid("non-finite automation time") }
        guard !keyframes.isEmpty else { return nil }
        return Automation.evaluated(at:time,keyframes:keyframes)
    }
}

public enum Automation {
    /// Validation is shared by editing/persistence and the compiled runtime.
    public static func validate(keyframes:[AutomationKeyframe]) throws {
        guard !keyframes.isEmpty,keyframes.count<=4096 else { throw ProjectError.invalid("automation requires 1...4096 keys") }
        for i in keyframes.indices {
            let key=keyframes[i]
            guard key.time.isFinite,key.value.isFinite,key.time>=0,key.time<=86400*365,
                  i==0 || key.time>keyframes[i-1].time else { throw ProjectError.invalid("invalid automation keyframes") }
            guard [key.control1,key.control2].allSatisfy({$0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)}),
                  key.control1.x<=key.control2.x else { throw ProjectError.invalid("Bezier easing handles require normalized monotonic x coordinates") }
        }
    }
    /// Stateless public evaluator. Compiled programs validate once and call the
    /// same binary-search/easing implementation without rescanning every key.
    public static func value(at time: Double, keyframes: [AutomationKeyframe]) throws -> Double? {
        guard time.isFinite else { throw ProjectError.invalid("non-finite automation time") }
        guard !keyframes.isEmpty else { return nil }
        try validate(keyframes:keyframes)
        return evaluated(at:time,keyframes:keyframes)
    }
    static func evaluated(at time:Double,keyframes:[AutomationKeyframe]) -> Double {
        if time<=keyframes[0].time { return keyframes[0].value }
        if time>=keyframes.last!.time { return keyframes.last!.value }
        var low=0,high=keyframes.count
        while low<high {
            let mid=(low+high)/2
            if keyframes[mid].time<=time { low=mid+1 } else { high=mid }
        }
        let a=keyframes[low-1],b=keyframes[low]
        let u=(time-a.time)/(b.time-a.time)
        let weight:Double
        switch a.interpolation {
        case .hold:weight=0
        case .linear:weight=u
        case .bezier:
            func cubic(_ t:Double,_ p:Double,_ q:Double) -> Double {
                let v=1-t
                return 3*v*v*t*p+3*v*t*t*q+t*t*t
            }
            var left=0.0,right=1.0
            for _ in 0..<48 {
                let middle=(left+right)/2
                if cubic(middle,a.control1.x,a.control2.x)<u { left=middle } else { right=middle }
            }
            weight=cubic((left+right)/2,a.control1.y,a.control2.y)
        }
        return a.value+(b.value-a.value)*weight
    }
}
