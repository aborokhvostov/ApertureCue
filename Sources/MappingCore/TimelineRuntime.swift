import Foundation

public enum TimelineMarkerAction:String,Codable,CaseIterable,Sendable { case pause,cue }
public struct TimelineMarker:Codable,Equatable,Identifiable,Sendable {
    public var id:UUID
    public var name:String
    public var time:Double
    public var action:TimelineMarkerAction
    public var cueID:UUID?
    public init(id:UUID=UUID(),name:String="Marker",time:Double,action:TimelineMarkerAction = .pause,cueID:UUID?=nil) {
        self.id=id;self.name=name;self.time=time;self.action=action;self.cueID=cueID
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
        let c=try decoder.container(keyedBy:CodingKeys.self)
        self.init(duration:try c.decode(Double.self,forKey:.duration),
                  loopEnabled:try c.decode(Bool.self,forKey:.loopEnabled),
                  loopStart:try c.decode(Double.self,forKey:.loopStart),
                  loopEnd:try c.decode(Double.self,forKey:.loopEnd),
                  markers:try c.decode([TimelineMarker].self,forKey:.markers),
                  stopAtEnd:try c.decodeIfPresent(Bool.self,forKey:.stopAtEnd) ?? true)
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
            switch marker.action {
            case .pause:guard marker.cueID==nil else { throw ProjectError.invalid("pause marker cannot reference a scene") }
            case .cue:guard let id=marker.cueID,cueIDs.contains(id) else { throw ProjectError.invalid("timeline marker references a missing scene") }
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
            switch track.parameter {
            case "opacity":result[i].opacity=value
            case "brightness":result[i].brightness=value
            case "gamma":result[i].gamma=value
            case "red","green","blue":
                guard result[i].color.count==3 else { throw ProjectError.invalid("sampled surface requires three color components") }
                result[i].color[track.parameter == "red" ? 0 : (track.parameter == "green" ? 1 : 2)]=value
            default:throw ProjectError.invalid("unknown compiled timeline parameter")
            }
        }
        return result
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
    public static let eventBudget=256
    public static let maximumTime=31536000.0
    private struct Event { var markerID:UUID; var cueID:UUID? }
    private var queuedEvents:[Event]=[]
    private var deliveredEvents:[Event]=[]
    private var queuedSkipped=false
    private var anchorHost=0.0
    private var pendingDiscontinuity=false
    private var sourceTracks:[AutomationTrack]=[]
    private var sourceIDs=Set<UUID>()
    private var markers:[TimelineMarker]=[]
    private var pauses:[TimelineMarker]=[]
    private var program=try! TimelineProgram(tracks:[],surfaces:[])
    public init() {}

    public func configure(settings newSettings:TimelineSettings,tracks:[AutomationTrack],surfaces:[Surface],cueIDs:Set<UUID>=[],at hostTime:Double=ProcessInfo.processInfo.systemUptime) throws {
        guard hostTime.isFinite else { throw ProjectError.invalid("timeline host time must be finite") }
        try TimelineSettings.validate(newSettings,tracks:tracks,cueIDs:cueIDs)
        let ids=Set(surfaces.map(\.id))
        // A frame refresh must not move the host anchor or lose elapsed time.
        if newSettings==settings,tracks==sourceTracks,ids==sourceIDs { return }
        let nextProgram=try TimelineProgram(tracks:tracks,surfaces:surfaces)
        // Validate completely before consuming any clock or queued events.
        let previous=tick(at:hostTime)
        let oldEvents=deliveredEvents
        let newTime=min(seekLimit(newSettings),previous.time)
        settings=newSettings;sourceTracks=tracks;sourceIDs=ids;program=nextProgram
        markers=newSettings.markers.sorted {$0.time<$1.time};pauses=markers.filter {$0.action == .pause}
        time=newTime
        isPlaying=previous.isPlaying && (newSettings.loopEnabled || newTime<endBoundary(newSettings))
        anchorHost=max(anchorHost,hostTime);pendingDiscontinuity=true
        queuedEvents=oldEvents;queuedSkipped=previous.eventsSkipped
    }
    public func currentTime(at hostTime:Double=ProcessInfo.processInfo.systemUptime) -> Double { projected(at:hostTime).time }
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
        clearQueuedEvents()
    }
    public func seek(to seconds:Double,at hostTime:Double=ProcessInfo.processInfo.systemUptime) {
        guard seconds.isFinite,hostTime.isFinite else { return }
        time=min(seekLimit(settings),max(0,seconds));anchorHost=hostTime;pendingDiscontinuity=true
        clearQueuedEvents()
    }
    public func apply(surfaces:[Surface]) throws -> [Surface] { try program.apply(time:time,surfaces:surfaces) }

    public func tick(at hostTime:Double=ProcessInfo.processInfo.systemUptime) -> TimelineTick {
        guard hostTime.isFinite else { return TimelineTick(time:time,isPlaying:isPlaying,discontinuity:false,cueIDs:[],firedMarkerIDs:[],eventsSkipped:false) }
        var discontinuity=pendingDiscontinuity,events=queuedEvents,skipped=queuedSkipped
        pendingDiscontinuity=false;queuedEvents=[];queuedSkipped=false
        func result() -> TimelineTick {
            deliveredEvents=events
            return TimelineTick(time:time,isPlaying:isPlaying,discontinuity:discontinuity,cueIDs:events.compactMap(\.cueID),firedMarkerIDs:events.map(\.markerID),eventsSkipped:skipped)
        }
        guard isPlaying else { return result() }
        var remaining=elapsed(at:hostTime),budget=Self.eventBudget-events.count
        anchorHost=max(anchorHost,hostTime)
        func collect(from old:Double,to next:Double) -> Double? {
            let pause=firstPause(after:old,through:next)
            let target=pause?.time ?? next
            let first=upperBound(markers,old),end=upperBound(markers,target)
            let available=max(0,budget),count=min(available,end-first)
            if count>0 {
                for marker in markers[first..<(first+count)] {
                    events.append(Event(markerID:marker.id,cueID:marker.cueID))
                }
                budget-=count
            }
            if end-first>count { skipped=true }
            return pause?.time
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
            if let pause=collect(from:time,to:next) {
                time=pause;isPlaying=false;discontinuity=true;remaining=0;break
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
        var low=0,high=collection.count
        while low<high { let middle=(low+high)/2;if collection[middle].time<=value { low=middle+1 } else { high=middle } }
        return low
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
        let value=advanced(from:time,elapsed:elapsed(at:hostTime))
        return (value.time,value.playing)
    }
}
