import Foundation

/// One scalar recording gesture on an existing enabled track. Callers supply the
/// initial evaluated value, publish `track` for live playback, then commit one
/// history entry when the gesture ends and `changed` is true.
///
/// The inclusive sampled interval replaces original keys. Keys outside that
/// interval retain all metadata, but adjacent curve segments can change because
/// their neighboring keys changed. Recorded segments are ordinary linear keys.
public struct AutomationRecording:Sendable {
    private let original:AutomationTrack
    private let duration:Double
    private let range:ClosedRange<Double>
    private let initialValue:Double
    private var samples:[AutomationKeyframe]
    public private(set) var track:AutomationTrack
    /// True after any accepted value differs from the initial value, including
    /// a same-timestamp replacement. Rejected samples never affect this flag.
    public private(set) var changed=false
    public var sampleCount:Int { samples.count }
    public var lastTime:Double { samples.last!.time }
    public var lastValue:Double { samples.last!.value }

    public init(track:AutomationTrack,time:Double,value:Double,duration:Double) throws {
        guard track.enabled else { throw ProjectError.invalid("automation recording requires an enabled track") }
        guard duration.isFinite,(0.001...ShowRuntime.maximumTime).contains(duration) else {
            throw ProjectError.invalid("automation recording duration is invalid")
        }
        // A recording owns one track. The editor validates its existing target
        // and the project's aggregate 65536-key budget before publishing changes.
        try TimelineEngine.validate(tracks:[track],surfaces:[Surface(id:track.surfaceID)])
        guard track.keyframes.allSatisfy({ $0.time <= duration }) else {
            throw ProjectError.invalid("automation recording track exceeds the timeline duration")
        }
        let range=try TimelineEngine.parameterRange(track.parameter)
        try Self.validate(time:time,value:value,duration:duration,range:range)
        let samples=[AutomationKeyframe(time:time,value:value)]
        self.original=track;self.duration=duration;self.range=range;self.initialValue=value;self.samples=samples
        self.track=try Self.merged(original:track,samples:samples)
    }

    public mutating func append(time:Double,value:Double) throws {
        try Self.validate(time:time,value:value,duration:duration,range:range)
        guard time >= lastTime else { throw ProjectError.invalid("automation recording time cannot move backward") }
        var next=samples
        let key=AutomationKeyframe(time:time,value:value)
        if time == lastTime { next[next.count-1]=key }
        else {
            guard next.count < 4096 else { throw ProjectError.invalid("automation recording exceeds 4096 samples") }
            next.append(key)
        }
        // Merge and validate before publishing any session state.
        let recorded=try Self.merged(original:original,samples:next)
        samples=next;track=recorded;changed = changed || value != initialValue
    }

    /// Optionally hold the last recorded value through the gesture's end time.
    /// The caller then discards this session; returned data is an ordinary track.
    public mutating func finish(time:Double?=nil) throws -> AutomationTrack {
        if let time { try append(time:time,value:lastValue) }
        return track
    }

    private static func validate(time:Double,value:Double,duration:Double,range:ClosedRange<Double>) throws {
        guard time.isFinite,time>=0,time<=duration else { throw ProjectError.invalid("automation recording time is outside the timeline") }
        guard value.isFinite,range.contains(value) else { throw ProjectError.invalid("automation recording value is outside the parameter range") }
    }
    private static func merged(original:AutomationTrack,samples:[AutomationKeyframe]) throws -> AutomationTrack {
        let first=samples.first!.time,last=samples.last!.time
        var recorded=original
        recorded.keyframes=original.keyframes.filter { $0.time < first } + samples + original.keyframes.filter { $0.time > last }
        try Automation.validate(keyframes:recorded.keyframes)
        return recorded
    }
}
