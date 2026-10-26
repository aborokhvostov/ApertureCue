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
        s.opacity=mix(a.enabled ? a.opacity : 0,b.enabled ? b.opacity : 0)
        s.enabled=a.enabled || b.enabled
        s.brightness=mix(a.brightness,b.brightness); s.gamma=mix(a.gamma,b.gamma); s.feather=mix(a.feather,b.feather)
        if a.color.count == b.color.count { s.color=zip(a.color,b.color).map(mix) }
        if a.mask.count == b.mask.count { s.mask=zip(a.mask,b.mask).map { Point2.interpolate($0,$1,t:u) } }
        return s
    }
}

public struct AutomationKeyframe: Codable, Equatable, Sendable {
    public var time: Double
    public var value: Double
    public init(time: Double, value: Double) { self.time=time; self.value=value }
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
            let range:ClosedRange<Double>
            switch track.parameter { case "opacity":range=0...1; case "gamma":range=0.01...10; default:range=0...16 }
            guard track.keyframes.allSatisfy({ $0.time <= 86400*365 && range.contains($0.value) }) else { throw ProjectError.invalid("timeline value or time outside supported range") }
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

public enum Automation {
    /// Piecewise-linear automation. Duplicate or unsorted times are rejected.
    public static func value(at time: Double, keyframes: [AutomationKeyframe]) throws -> Double? {
        guard time.isFinite else { throw ProjectError.invalid("non-finite automation time") }
        guard !keyframes.isEmpty else { return nil }
        for i in keyframes.indices {
            guard keyframes[i].time.isFinite, keyframes[i].value.isFinite, keyframes[i].time >= 0,
                  i == 0 || keyframes[i].time > keyframes[i-1].time else { throw ProjectError.invalid("invalid automation keyframes") }
        }
        if time <= keyframes[0].time { return keyframes[0].value }
        for i in 1..<keyframes.count where time <= keyframes[i].time {
            let a=keyframes[i-1], b=keyframes[i]
            return a.value+(b.value-a.value)*(time-a.time)/(b.time-a.time)
        }
        return keyframes.last!.value
    }
}
