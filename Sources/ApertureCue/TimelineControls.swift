#if os(macOS)
import AppKit
import MappingCore

extension EditorController {
    @objc func showTimelineWindow() {
        if timelineWindow == nil { timelineWindow=TimelineWindowController(editor:self) }
        timelineWindow?.refresh(); timelineWindow?.showWindow(nil); timelineWindow?.window?.makeKeyAndOrderFront(nil)
    }
    /// Rebuild only on document mutations. Playback evaluates the compiled model.
    func configureShow(at hostTime:Double=ProcessInfo.processInfo.systemUptime) {
        let beforeTime=showRuntime.currentTime(at:hostTime), beforePlaying=showRuntime.isPlaying
        do {
            try showRuntime.configure(settings:project.timelineSettings,tracks:project.timeline,
                                      surfaces:automationSurfaces, cueIDs:Set(project.cues.map(\.id)),
                                      controlTracks:project.showControlTracks, at:hostTime)
            try conductorRuntime.configure(project.conductor, surfaces:automationSurfaces)
            showConfigurationError=""
            let stopped=beforePlaying && !showRuntime.isPlaying
            if stopped { media.pause() }
            let afterTime=showRuntime.currentTime(at:hostTime)
            if stopped || abs(afterTime-beforeTime)>1e-9 { montageSerial &+= 1; media.seek(to:afterTime) }
        } catch { showConfigurationError=error.localizedDescription }
    }
    func playShow(at hostTime:Double=ProcessInfo.processInfo.systemUptime) {
        releaseExternalShowClock()
        configureShow(at:hostTime)
        guard showConfigurationError.isEmpty,!showRuntime.isPlaying else { return }
        showRuntime.play(at:hostTime)
        montageSerial &+= 1; media.seek(to:showRuntime.time); media.play()
        updateRender(); timelineWindow?.updatePlayhead()
    }
    func pauseShow(at hostTime:Double=ProcessInfo.processInfo.systemUptime) {
        releaseExternalShowClock()
        advanceShow(at:hostTime)
        flushShowControlNotes()
        stopAutomationRecording(reason:"Paused",at:hostTime)
        showRuntime.pause(at:hostTime); montageSerial &+= 1; media.pause(); media.seek(to:showRuntime.time)
        updateRender(); timelineWindow?.updatePlayhead()
    }
    func stopShow(at hostTime:Double=ProcessInfo.processInfo.systemUptime) {
        releaseExternalShowClock()
        flushShowControlNotes()
        conductorRuntime.stopAll()
        conductorWindow?.updateStatus()
        feedback?.reset()
        stopAutomationRecording(reason:"Stopped",at:hostTime)
        timelineEventWarning=""
        commitInterruptedCue(); showRuntime.stop(at:hostTime); montageSerial &+= 1; media.pause(); media.seek(to:0)
        updateRender(); timelineWindow?.updatePlayhead()
    }
    func seekShow(to seconds:Double,at hostTime:Double=ProcessInfo.processInfo.systemUptime) {
        feedback?.reset()
        guard seconds.isFinite else { return }
        releaseExternalShowClock()
        flushShowControlNotes()
        stopAutomationRecording(reason:"Seek",at:hostTime)
        timelineEventWarning=""
        showRuntime.seek(to:seconds,at:hostTime); montageSerial &+= 1; media.seek(to:showRuntime.time)
        updateRender(); timelineWindow?.updatePlayhead()
    }
    func advanceShow(at hostTime:Double) {
        let result=showRuntime.tick(at:hostTime)
        if recording.enabled && (!result.isPlaying || result.discontinuity || result.time>=project.timelineSettings.duration) {
            stopAutomationRecording(reason:!result.isPlaying ? "Playback paused or ended" : result.discontinuity ? "Playback discontinuity / loop wrap" : "Recording reached graph end",at:hostTime)
        }
        if result.discontinuity {
            flushShowControlNotes()
            feedback?.reset()
            montageSerial &+= 1
            if !result.isPlaying { media.pause() }
            media.seek(to:result.time)
            if result.isPlaying && !media.isPlaying { media.play() }
        }
        if result.eventsSkipped { timelineEventWarning="Timeline event budget reached; excess events skipped" }
        for id in result.cueIDs {
            if let index = project.cues.firstIndex(where: { $0.id == id }),
               goCue(index: index, interactive: false), cueTarget?.duration == 0 {
                // Several scene markers can cross in one host tick. Publish an
                // instant cue before the next marker captures its start state.
                applyCueSample(at: cueStart)
            }
        }
        dispatchShowControlEvents(result.controlEvents)
        if !result.isPlaying { flushShowControlNotes() }
        timelineWindow?.updatePlayhead()
    }
    @discardableResult
    func timelineAddTrack(surfaceID:UUID,parameter:String) throws -> UUID {
        guard TimelineEngine.parameters.contains(parameter),let surface=(project.surfaces+project.cues.filter {$0.scope == .full}.flatMap(\.surfaces)).first(where:{$0.id==surfaceID}) else { throw ProjectError.invalid("select an existing surface and parameter") }
        if let existing=project.timeline.first(where:{$0.surfaceID==surfaceID && $0.parameter==parameter}) { return existing.id }
        let value:Double
        switch parameter {
        case "opacity":value=surface.opacity
        case "brightness":value=surface.brightness
        case "gamma":value=surface.gamma
        default:value=surface.color[parameter == "red" ? 0 : (parameter == "green" ? 1 : 2)]
        }
        let track=AutomationTrack(name:surface.name+" · "+parameter,surfaceID:surfaceID,parameter:parameter,
                                  keyframes:[AutomationKeyframe(time:0,value:value),AutomationKeyframe(time:project.timelineSettings.duration,value:value)])
        var candidate=project; candidate.timeline.append(track); try ProjectStore.validate(candidate)
        mutate("Add timeline track") {$0=candidate}; return track.id
    }
    func timelineRemoveTrack(id:UUID) throws {
        guard project.timeline.contains(where:{$0.id==id}) else { throw ProjectError.invalid("timeline track no longer exists") }
        var candidate=project;candidate.timeline.removeAll {$0.id==id};try ProjectStore.validate(candidate)
        mutate("Remove timeline track") {$0=candidate}
    }
    func timelineSetTrackEnabled(id:UUID,enabled:Bool) throws {
        guard let i=project.timeline.firstIndex(where:{$0.id==id}) else { throw ProjectError.invalid("timeline track no longer exists") }
        var candidate=project;candidate.timeline[i].enabled=enabled;try ProjectStore.validate(candidate)
        mutate("Timeline track enabled") {$0=candidate}
    }
    func timelineEditKey(trackID:UUID,index:Int?,key:AutomationKeyframe) throws {
        guard let i=project.timeline.firstIndex(where:{$0.id==trackID}) else { throw ProjectError.invalid("timeline track no longer exists") }
        var candidate=project
        if let index {
            guard candidate.timeline[i].keyframes.indices.contains(index) else { throw ProjectError.invalid("timeline key no longer exists") }
            candidate.timeline[i].keyframes[index]=key
        } else { candidate.timeline[i].keyframes.append(key) }
        candidate.timeline[i].keyframes.sort {$0.time<$1.time}
        try ProjectStore.validate(candidate);mutate(index == nil ? "Insert timeline key" : "Edit timeline key") {$0=candidate}
    }
    func timelineRetimeKeys(trackID: UUID, from start: Double, through end: Double,
                            to destination: Double, scale: Double) throws {
        guard let index = project.timeline.firstIndex(where: { $0.id == trackID }),
              start.isFinite, end.isFinite, start >= 0, end >= start,
              destination.isFinite, destination >= 0, scale.isFinite, scale > 0 else {
            throw ProjectError.invalid("Select a track and enter a valid range, destination and positive scale")
        }
        var candidate = project
        var moved = false
        for key in candidate.timeline[index].keyframes.indices {
            let time = candidate.timeline[index].keyframes[key].time
            guard time >= start, time <= end else { continue }
            candidate.timeline[index].keyframes[key].time = destination + (time - start) * scale
            moved = true
        }
        guard moved else { throw ProjectError.invalid("No keys lie within the selected range") }
        candidate.timeline[index].keyframes.sort { $0.time < $1.time }
        try ProjectStore.validate(candidate)
        mutate("Retime timeline keys") { $0 = candidate }
    }

    func timelineDeleteKey(trackID:UUID,index:Int) throws {
        guard let i=project.timeline.firstIndex(where:{$0.id==trackID}),project.timeline[i].keyframes.indices.contains(index) else { throw ProjectError.invalid("timeline key no longer exists") }
        guard project.timeline[i].keyframes.count>1 else { throw ProjectError.invalid("a track needs at least one key; remove the track to remove all keys") }
        var candidate=project;candidate.timeline[i].keyframes.remove(at:index);try ProjectStore.validate(candidate)
        mutate("Delete timeline key") {$0=candidate}
    }
    func timelineUpdateSettings(_ settings:TimelineSettings) throws {
        var candidate=project;candidate.timelineSettings=settings;try ProjectStore.validate(candidate)
        mutate("Timeline settings") {$0=candidate}
    }
    @discardableResult
    func timelineAddMarker(name:String,time:Double,action:TimelineMarkerAction,cueID:UUID?,jumpTime:Double?=nil,jumpLimit:Int?=nil) throws -> UUID {
        guard time>0 else { throw ProjectError.invalid("automatic markers must be after 0 seconds; seek forward before adding one") }
        let marker=TimelineMarker(name:name,time:time,action:action,cueID:cueID,jumpTime:jumpTime,jumpLimit:jumpLimit)
        var candidate=project;candidate.timelineSettings.markers.append(marker);candidate.timelineSettings.markers.sort {$0.time<$1.time}
        try ProjectStore.validate(candidate);mutate("Add timeline marker") {$0=candidate};return marker.id
    }
    func timelineDeleteMarker(id:UUID) throws {
        guard project.timelineSettings.markers.contains(where:{$0.id==id}) else { throw ProjectError.invalid("timeline marker no longer exists") }
        var candidate=project;candidate.timelineSettings.markers.removeAll {$0.id==id};try ProjectStore.validate(candidate)
        mutate("Delete timeline marker") {$0=candidate}
    }
}
#endif
