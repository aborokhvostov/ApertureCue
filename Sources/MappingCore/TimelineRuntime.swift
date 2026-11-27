import Foundation

public enum TimelineMarkerAction:String,Codable,CaseIterable,Sendable { case pause,cue,jump }
public struct TimelineMarker:Codable,Equatable,Identifiable,Sendable {
    public var id:UUID
    public var name:String
    public var time:Double
    public var action:TimelineMarkerAction
    public var cueID:UUID?
    public var jumpTime: Double?
    public var jumpLimit: Int?
    public init(id:UUID=UUID(),name:String="Marker",time:Double,action:TimelineMarkerAction = .pause,cueID:UUID?=nil,jumpTime:Double?=nil,jumpLimit:Int?=nil) {
        self.id=id;self.name=name;self.time=time;self.action=action;self.cueID=cueID
        self.jumpTime=jumpTime;self.jumpLimit=jumpLimit
    }
    private enum CodingKeys: String, CodingKey { case id, name, time, action, cueID, jumpTime, jumpLimit }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, legacy: false)
    }

    init(from decoder: Decoder, legacy: Bool) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try fields.decode(UUID.self, forKey: .id),
                  name: try fields.decode(String.self, forKey: .name),
                  time: try fields.decode(Double.self, forKey: .time),
                  action: try fields.decode(TimelineMarkerAction.self, forKey: .action),
                  cueID: try fields.decodeIfPresent(UUID.self, forKey: .cueID),
                  jumpTime: legacy ? nil : try fields.decodeIfPresent(Double.self, forKey: .jumpTime),
                  jumpLimit: legacy ? nil : try fields.decodeIfPresent(Int.self, forKey: .jumpLimit))
        if legacy && action == .jump { throw ProjectError.invalid("Jump markers require schema 14") }
    }

}

public struct TimelineSettings:Codable,Equatable,Sendable {
    public var duration:Double
    /// When false, duration is the graph horizon; non-loop playback continues.
    public var stopAtEnd:Bool
    public var loopEnabled:Bool
    public var loopStart:Double
    public var loopEnd:Double
    public var markers:[TimelineMarker]
    public init(duration:Double=10,loopEnabled:Bool=false,loopStart:Double=0,loopEnd:Double?=nil,markers:[TimelineMarker]=[],stopAtEnd:Bool=true) {
        self.duration=duration;self.stopAtEnd=stopAtEnd;self.loopEnabled=loopEnabled;self.loopStart=loopStart;self.loopEnd=loopEnd ?? duration;self.markers=markers
    }
    private enum CodingKeys:String,CodingKey { case duration,stopAtEnd,loopEnabled,loopStart,loopEnd,markers }
    public init(from decoder:Decoder) throws {
        try self.init(from: decoder, legacy: false)
    }

    init(from decoder: Decoder, legacy: Bool) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        var list = try c.nestedUnkeyedContainer(forKey: .markers)
        var markers: [TimelineMarker] = []
        while !list.isAtEnd {
            guard markers.count < 1024 else { throw ProjectError.invalid("Too many timeline markers") }
            markers.append(try TimelineMarker(from: list.superDecoder(), legacy: legacy))
        }
        self.init(duration:try c.decode(Double.self,forKey:.duration),
                  loopEnabled:try c.decode(Bool.self,forKey:.loopEnabled),
                  loopStart:try c.decode(Double.self,forKey:.loopStart),
                  loopEnd:try c.decode(Double.self,forKey:.loopEnd),
                  markers:markers,
                  stopAtEnd:try c.decodeIfPresent(Bool.self,forKey:.stopAtEnd) ?? true)
    }
    func withoutShowControlExtensions() throws -> TimelineSettings {
        var settings = self
        for index in settings.markers.indices {
            guard settings.markers[index].action != .jump else { throw ProjectError.invalid("Jump markers require schema 14") }
            settings.markers[index].jumpTime = nil
            settings.markers[index].jumpLimit = nil
        }
        return settings
    }

    public static func inferred(from tracks:[AutomationTrack]) -> TimelineSettings {
        let end=max(10,tracks.flatMap(\.keyframes).map(\.time).filter(\.isFinite).max() ?? 0)
        return TimelineSettings(duration:end,loopEnd:end)
    }
    public static func validate(_ settings:TimelineSettings,tracks:[AutomationTrack],cueIDs:Set<UUID>) throws {
        guard settings.duration.isFinite,(0.001...31536000).contains(settings.duration),
              settings.loopStart.isFinite,settings.loopEnd.isFinite,settings.loopStart>=0,
              settings.loopEnd>settings.loopStart,settings.loopEnd<=settings.duration else { throw ProjectError.invalid("timeline duration/loop range is invalid") }
        guard tracks.allSatisfy({$0.keyframes.allSatisfy({$0.time<=settings.duration})}) else { throw ProjectError.invalid("timeline key exceeds its duration") }
        guard settings.markers.count<=1024,Set(settings.markers.map(\.id)).count==settings.markers.count,
              Set(settings.markers.map(\.time)).count==settings.markers.count else { throw ProjectError.invalid("timeline requires at most 1024 markers with unique IDs and times") }
        for marker in settings.markers {
            guard marker.name.utf8.count<=4096,marker.time.isFinite,marker.time>0,marker.time<=settings.duration else { throw ProjectError.invalid("timeline markers must be after 0 seconds, within duration, with a bounded name") }
            if marker.action != .jump, marker.jumpTime != nil || marker.jumpLimit != nil {
                throw ProjectError.invalid("Jump settings belong to a Jump marker")
            }
            switch marker.action {
            case .pause:guard marker.cueID==nil else { throw ProjectError.invalid("pause marker cannot reference a scene") }
            case .cue:guard let id=marker.cueID,cueIDs.contains(id) else { throw ProjectError.invalid("timeline marker references a missing scene") }
            case .jump:
                guard marker.cueID == nil, let target = marker.jumpTime, target.isFinite,
                      (0...settings.duration).contains(target), target != marker.time,
                      let limit = marker.jumpLimit, (1...64).contains(limit) else {
                    throw ProjectError.invalid("Jump requires a different destination within the timeline and a limit of 1…64")
                }
                if settings.loopEnabled, target >= settings.loopEnd {
                    throw ProjectError.invalid("Jump destination must precede the loop end")
                }
            }
        }
    }
}

/// Validated immutable tracks. Scalar evaluation uses binary search and no
/// per-frame parsing, key-array validation or elapsed-time accumulation.
public struct TimelineProgram:Sendable {
    private var tracks:[AutomationTrack]
    public init(tracks:[AutomationTrack],surfaces:[Surface]) throws {
        try TimelineEngine.validate(tracks:tracks,surfaces:surfaces)
        self.tracks=tracks.filter(\.enabled)
    }
    public func apply(time:Double,surfaces:[Surface]) throws -> [Surface] {
        guard time.isFinite,time>=0 else { throw ProjectError.invalid("timeline time must be finite and nonnegative") }
        var result=surfaces,indices:[UUID:Int]=[:]
        for i in result.indices {
            guard indices.updateValue(i,forKey:result[i].id)==nil else { throw ProjectError.invalid("duplicate sampled surface ID") }
        }
        for track in tracks {
            guard let i=indices[track.surfaceID] else { continue }
            let value=Automation.evaluated(at:time,keyframes:track.keyframes)
            try Self.set(value, parameter: track.parameter, on: &result[i])
        }
        return result
    }
    static func set(_ value: Double, parameter: String, on surface: inout Surface) throws {
        switch parameter {
        case "opacity": surface.opacity = value
        case "brightness": surface.brightness = value
        case "gamma": surface.gamma = value
        case "red", "green", "blue":
            guard surface.color.count == 3 else { throw ProjectError.invalid("sampled surface requires three color components") }
            let channel = parameter == "red" ? 0 : (parameter == "green" ? 1 : 2)
            surface.color[channel] = value
        default: throw ProjectError.invalid("unknown compiled timeline parameter")
        }
    }

}

public struct TimelineTick:Equatable,Sendable {
    public var time:Double
    public var isPlaying:Bool
    /// A seek/wrap/pause/end requires the media adapter to reconcile its clock.
    public var discontinuity:Bool
    public var cueIDs:[UUID]
    public var firedMarkerIDs:[UUID]
    /// Traversal exceeded the bounded event budget; later cue events were skipped.
    /// Pause markers are still honored at the first exact crossing.
    public var eventsSkipped:Bool
    public var controlEvents: [ShowControlEvent] = []
}

/// Timeline time is independent of movie duration/decoder loops. All host time
/// arguments are monotonic seconds; fake timestamps make behavior deterministic.
/// The caller applies emitted scene IDs in order, then samples the program once
/// for editor/output/light composition. Seeking never replays markers. A valid
/// configuration edit preserves natural crossings since the last tick and queues
/// them for exactly-once delivery; it does not replay past timeline history.
public final class ShowRuntime {
    public private(set) var settings=TimelineSettings()
    public private(set) var time=0.0
    public private(set) var isPlaying=false
    public var allowsPositionJumps = true
    public static let eventBudget=256
    public static let maximumTime=31536000.0
    private enum Event { case marker(TimelineMarker), control(ShowControlEvent) }
    private var queuedEvents:[Event]=[]
    private var deliveredEvents:[Event]=[]
    private var queuedSkipped=false
    private var anchorHost=0.0
    private var pendingDiscontinuity=false
    private var sourceTracks:[AutomationTrack]=[]
    private var sourceIDs=Set<UUID>()
    private var markers:[TimelineMarker]=[]
    private var pauses:[TimelineMarker]=[]
    private var jumps: [TimelineMarker] = []
    private var jumpCounts: [UUID: Int] = [:]
    private var sourceControlTracks: [ShowControlTrack] = []
    private var controlEvents: [ShowControlEvent] = []
    private var program=try! TimelineProgram(tracks:[],surfaces:[])
    public init() {}

    public func configure(settings newSettings:TimelineSettings,tracks:[AutomationTrack],surfaces:[Surface],cueIDs:Set<UUID>=[],controlTracks:[ShowControlTrack]=[],at hostTime:Double=ProcessInfo.processInfo.systemUptime) throws {
        guard hostTime.isFinite else { throw ProjectError.invalid("timeline host time must be finite") }
        try TimelineSettings.validate(newSettings,tracks:tracks,cueIDs:cueIDs)
        let ids=Set(surfaces.map(\.id))
        // A frame refresh must not move the host anchor or lose elapsed time.
        if newSettings==settings,tracks==sourceTracks,ids==sourceIDs,controlTracks==sourceControlTracks { return }
        let tracksOnly=newSettings==settings && ids==sourceIDs
        let nextProgram=try TimelineProgram(tracks:tracks,surfaces:surfaces)
        try ShowControlTrack.validate(controlTracks, duration: newSettings.duration)
        let nextEvents = ShowControlTrack.events(controlTracks)
        // Validate completely before consuming any clock or queued events.
        let previous=tick(at:hostTime)
        let oldEvents=deliveredEvents
        let newTime=min(seekLimit(newSettings),previous.time)
        if newSettings.markers != settings.markers { jumpCounts.removeAll() }
        settings=newSettings;sourceTracks=tracks;sourceIDs=ids;program=nextProgram
        sourceControlTracks=controlTracks;controlEvents=nextEvents
        markers=newSettings.markers.sorted {$0.time<$1.time};pauses=markers.filter {$0.action == .pause}
        jumps = markers.filter { $0.action == .jump }
        time=newTime
        isPlaying=previous.isPlaying && (newSettings.loopEnabled || newTime<endBoundary(newSettings))
        anchorHost=max(anchorHost,hostTime);pendingDiscontinuity=previous.discontinuity || !tracksOnly
        queuedEvents=oldEvents;queuedSkipped=previous.eventsSkipped
    }
    public func currentTime(at hostTime:Double=ProcessInfo.processInfo.systemUptime) -> Double { projected(at:hostTime).time }
    public func projectedPlaying(at hostTime: Double) -> Bool { projected(at: hostTime).playing }
    public func play(at hostTime:Double=ProcessInfo.processInfo.systemUptime) {
        guard hostTime.isFinite,!isPlaying else { return }
        if (!settings.loopEnabled && time>=endBoundary(settings)) || (settings.loopEnabled && time>=settings.loopEnd) {
            time=settings.loopEnabled ? settings.loopStart : 0;pendingDiscontinuity=true
        }
        anchorHost=hostTime;isPlaying=true
    }
    public func pause(at hostTime:Double=ProcessInfo.processInfo.systemUptime) {
        guard hostTime.isFinite else { return }
        let previous=tick(at:hostTime),oldEvents=deliveredEvents
        isPlaying=false;anchorHost=max(anchorHost,hostTime);pendingDiscontinuity=true
        queuedEvents=oldEvents;queuedSkipped=previous.eventsSkipped
    }
    public func stop(at hostTime:Double=ProcessInfo.processInfo.systemUptime) {
        guard hostTime.isFinite else { return }
        time=0;isPlaying=false;anchorHost=hostTime;pendingDiscontinuity=true
        jumpCounts.removeAll(); clearQueuedEvents()
    }
    public func seek(to seconds:Double,at hostTime:Double=ProcessInfo.processInfo.systemUptime) {
        guard seconds.isFinite,hostTime.isFinite else { return }
        time=min(seekLimit(settings),max(0,seconds));anchorHost=hostTime;pendingDiscontinuity=true
        jumpCounts.removeAll(); clearQueuedEvents()
    }
    public func apply(surfaces:[Surface]) throws -> [Surface] { try program.apply(time:time,surfaces:surfaces) }

    public func tick(at hostTime:Double=ProcessInfo.processInfo.systemUptime) -> TimelineTick {
        guard hostTime.isFinite else { return TimelineTick(time:time,isPlaying:isPlaying,discontinuity:false,cueIDs:[],firedMarkerIDs:[],eventsSkipped:false) }
        var discontinuity=pendingDiscontinuity,events=queuedEvents,skipped=queuedSkipped
        pendingDiscontinuity=false;queuedEvents=[];queuedSkipped=false
        func result() -> TimelineTick {
            deliveredEvents=events
            var markerIDs: [UUID] = []
            var cueIDs: [UUID] = []
            var controls: [ShowControlEvent] = []
            for event in events {
                switch event {
                case .marker(let marker):
                    markerIDs.append(marker.id)
                    if let id = marker.cueID { cueIDs.append(id) }
                case .control(let command): controls.append(command)
                }
            }
            return TimelineTick(time: time, isPlaying: isPlaying, discontinuity: discontinuity,
                                cueIDs: cueIDs, firedMarkerIDs: markerIDs, eventsSkipped: skipped,
                                controlEvents: controls)
        }
        guard isPlaying else { return result() }
        var remaining=elapsed(at:hostTime),budget=Self.eventBudget-events.count
        anchorHost=max(anchorHost,hostTime)
        func collect(from old: Double, to next: Double) -> TimelineMarker? {
            let boundary = firstBoundary(after: old, through: next)
            let target = boundary?.time ?? next
            var markerIndex = upperBound(markers, old)
            let markerEnd = upperBound(markers, target)
            var controlIndex = Self.upperBound(controlEvents, old, time: { $0.time })
            let controlEnd = Self.upperBound(controlEvents, target, time: { $0.time })
            while markerIndex < markerEnd || controlIndex < controlEnd {
                if budget <= 0 { skipped = true; break }
                if markerIndex < markerEnd,
                   controlIndex == controlEnd || markers[markerIndex].time <= controlEvents[controlIndex].time {
                    let marker = markers[markerIndex]
                    markerIndex += 1
                    if marker.action == .jump && marker.id != boundary?.id { continue }
                    events.append(.marker(marker))
                } else {
                    events.append(.control(controlEvents[controlIndex]))
                    controlIndex += 1
                }
                budget -= 1
            }
            return boundary
        }
        if settings.loopEnabled,time>=settings.loopEnd {
            time=settings.loopStart;discontinuity=true;budget-=1
        }
        if !settings.loopEnabled,time>=endBoundary(settings) {
            isPlaying=false;discontinuity=true;remaining=0
        }
        while remaining>0 {
            let boundary=settings.loopEnabled ? settings.loopEnd : endBoundary(settings)
            let distance=max(0,boundary-time),travel=min(remaining,distance),next=time+travel
            if let marker = collect(from: time, to: next) {
                discontinuity = true
                if let destination = marker.jumpTime {
                    jumpCounts[marker.id, default: 0] += 1
                    time = destination
                } else {
                    time = marker.time
                    isPlaying = false
                }
                break
            }
            time=next;remaining=max(0,remaining-travel)
            if time>=boundary {
                if settings.loopEnabled {
                    time=settings.loopStart;discontinuity=true;budget-=1
                } else { isPlaying=false;discontinuity=true;remaining=0;break }
            }
            if budget<=0,remaining>0 {
                let future=advanced(from:time,elapsed:remaining)
                time=future.time;isPlaying=future.playing
                discontinuity=discontinuity || future.discontinuity
                skipped=true;remaining=0
            }
        }
        return result()
    }
    private func clearQueuedEvents() { queuedEvents=[];deliveredEvents=[];queuedSkipped=false }
    private func seekLimit(_ settings:TimelineSettings) -> Double { !settings.stopAtEnd && !settings.loopEnabled ? Self.maximumTime : settings.duration }
    private func endBoundary(_ settings:TimelineSettings) -> Double { settings.stopAtEnd ? settings.duration : Self.maximumTime }
    private func upperBound(_ collection:[TimelineMarker],_ value:Double) -> Int {
        Self.upperBound(collection, value, time: { $0.time })
    }
    private static func upperBound<T>(_ collection: [T], _ value: Double, time: (T) -> Double) -> Int {
        var low = 0, high = collection.count
        while low < high {
            let middle = (low + high) / 2
            if time(collection[middle]) <= value { low = middle + 1 } else { high = middle }
        }
        return low
    }
    private func firstBoundary(after start: Double, through end: Double) -> TimelineMarker? {
        let pause = firstPause(after: start, through: end)
        guard allowsPositionJumps else { return pause }
        let end = pause?.time ?? end
        let jump = jumps.dropFirst(upperBound(jumps, start)).prefix { $0.time <= end }.first {
            jumpCounts[$0.id, default: 0] < ($0.jumpLimit ?? 0)
        }
        return jump ?? pause
    }
    private func firstPause(after start:Double,through end:Double) -> TimelineMarker? {
        let index=upperBound(pauses,start)
        return index<pauses.count && pauses[index].time<=end ? pauses[index] : nil
    }
    /// Constant-time loop projection plus two binary pause searches. Used by
    /// explicit controls/configuration and after the event traversal budget.
    private func advanced(from position:Double,elapsed:Double) -> (time:Double,playing:Bool,discontinuity:Bool) {
        var start=position
        if settings.loopEnabled,start>=settings.loopEnd { start=settings.loopStart }
        let boundary=settings.loopEnabled ? settings.loopEnd : endBoundary(settings)
        let end=min(boundary,start+elapsed)
        if let pause=firstPause(after:start,through:end) { return (pause.time,false,true) }
        if start+elapsed<boundary { return (start+elapsed,true,false) }
        guard settings.loopEnabled else { return (endBoundary(settings),false,true) }
        let after=max(0,elapsed-(settings.loopEnd-start)),length=settings.loopEnd-settings.loopStart
        if let pause=firstPause(after:settings.loopStart,through:settings.loopEnd),after>=pause.time-settings.loopStart { return (pause.time,false,true) }
        return (settings.loopStart+after.truncatingRemainder(dividingBy:length),true,true)
    }
    private func elapsed(at hostTime:Double) -> Double {
        let difference=hostTime-anchorHost
        return difference.isFinite ? max(0,difference) : (difference>0 ? Double.greatestFiniteMagnitude : 0)
    }
    private func projected(at hostTime:Double) -> (time:Double,playing:Bool) {
        guard hostTime.isFinite,isPlaying else { return (time,isPlaying) }
        let elapsed = elapsed(at: hostTime)
        let boundary = settings.loopEnabled ? settings.loopEnd : endBoundary(settings)
        if let marker = firstBoundary(after: time, through: min(boundary, time + elapsed)),
           let jump = marker.jumpTime { return (jump, true) }
        let value=advanced(from:time,elapsed:elapsed)
        return (value.time,value.playing)
    }
}
