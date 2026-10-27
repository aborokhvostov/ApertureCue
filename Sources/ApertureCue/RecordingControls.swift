#if os(macOS)
import AppKit
import MappingCore

/// A token stays attached to the native tracking loop even when a transport or
/// document operation ends recording. Late actions then cannot edit base state.
final class AutomationSlider:NSSlider {
    var beginBlock:(()->UUID?)?
    var valueBlock:((Double,UUID?)->Void)?
    var endBlock:((UUID)->Void)?
    var trackingBlock:((Bool)->Void)?
    private var token:UUID?
    init(value:Double,min:Double,max:Double) {
        super.init(frame:.zero);minValue=min;maxValue=max;doubleValue=value
        isContinuous=false;target=self;action=#selector(invoke)
    }
    required init?(coder:NSCoder) {fatalError()}
    override func mouseDown(with event:NSEvent) {
        trackingBlock?(true);token=beginBlock?();isContinuous=token != nil
        super.mouseDown(with:event)
        if let token {endBlock?(token)}
        token=nil;isContinuous=false;trackingBlock?(false)
    }
    @objc private func invoke() {valueBlock?(doubleValue,token)}
}

@MainActor final class AutomationRecordingState {
    var armed=Set<UUID>(),enabled=false,message="Recording idle"
    var gesture:AutomationRecording?,token:UUID?,before:Project?
    var dirtyBefore=false,nativeTracking=false,pendingInspectorRefresh=false
    var sliders:[String:AutomationSlider]=[:],labels:[String:NSTextField]=[:]
}

extension EditorController {
    var armedRecordingTracks:Set<UUID> {recording.armed}
    var isRecordingAutomation:Bool {recording.enabled}
    var recordingMessage:String {recording.message}
    func setRecordingArmed(trackID:UUID,armed:Bool) throws {
        if armed {
            guard let track=project.timeline.first(where:{$0.id==trackID}),track.enabled,
                  project.surfaces.contains(where:{$0.id==track.surfaceID}) else {
                throw ProjectError.invalid("Arm requires an enabled track on a current surface")
            }
        }
        stopAutomationRecording(reason:"Arming changed")
        if armed {recording.armed.insert(trackID)} else {recording.armed.remove(trackID)}
        refreshInspector();timelineWindow?.refreshRecordingControls()
    }
    func startAutomationRecording(at hostTime:Double=ProcessInfo.processInfo.systemUptime) throws {
        advanceShow(at:hostTime)
        guard showRuntime.isPlaying,showRuntime.time<project.timelineSettings.duration else {
            throw ProjectError.invalid("Play within the timeline duration before recording input")
        }
        // Explicit target check also excludes dormant full-snapshot targets.
        let currentIDs=Set(project.surfaces.map(\.id))
        let targets=Set(project.timeline.filter {$0.enabled && currentIDs.contains($0.surfaceID)}.map(\.id))
        recording.armed.formIntersection(targets)
        guard !recording.armed.isEmpty else {throw ProjectError.invalid("Arm an enabled current-surface track first")}
        try ProjectStore.validate(project)
        commitInterruptedCue();recording.enabled=true;recording.message="Recording input · one Undo per gesture"
        refreshInspector();timelineWindow?.refreshRecordingControls()
    }
    func stopAutomationRecording(reason:String="Stopped",at hostTime:Double=ProcessInfo.processInfo.systemUptime) {
        guard recording.enabled || recording.gesture != nil else {return}
        recording.enabled=false
        finishAutomationGesture(at:hostTime)
        recording.message=reason
        refreshRecordingInspectorWhenSafe();timelineWindow?.refreshRecordingControls()
    }
    func resetAutomationRecording() {
        stopAutomationRecording(reason:"Document changed")
        recording.armed.removeAll();recording.message="Recording idle"
    }
    func recordingTrack(surfaceID:UUID,parameter:String)->AutomationTrack? {
        project.timeline.first {$0.surfaceID==surfaceID && $0.parameter==parameter && $0.enabled && recording.armed.contains($0.id)}
    }
    /// Non-nil means the tracking loop belongs to recording, even if a marker
    /// reached during this call has just ended the mode. That loop is absorbed.
    func beginAutomationGesture(surfaceID:UUID,parameter:String,at hostTime:Double=ProcessInfo.processInfo.systemUptime)->UUID? {
        guard recording.enabled,recordingTrack(surfaceID:surfaceID,parameter:parameter) != nil else {return nil}
        let token=UUID();advanceShow(at:hostTime)
        guard recording.enabled,showRuntime.isPlaying,let track=recordingTrack(surfaceID:surfaceID,parameter:parameter),
              showRuntime.time<project.timelineSettings.duration else {return token}
        finishAutomationGesture(at:hostTime);commitInterruptedCue()
        do {
            let value=try Automation.value(at:showRuntime.time,keyframes:track.keyframes)!
            recording.gesture=try AutomationRecording(track:track,time:showRuntime.time,value:value,duration:project.timelineSettings.duration)
            recording.before=project;recording.dirtyBefore=dirty;recording.token=token
            if let timeline=timelineWindow,timeline.selectedTrackID==track.id {
                timeline.selectedKeyIndex=nil;timeline.canvas.selectedKeyIndex=nil
            }
            recording.message="Recording \(track.parameter) · 1 sample"
        } catch {stopAutomationRecording(reason:error.localizedDescription,at:hostTime)}
        return token
    }
    func recordAutomationValue(_ value:Double,token:UUID,at hostTime:Double=ProcessInfo.processInfo.systemUptime) {
        guard recording.token==token,recording.enabled else {return}
        advanceShow(at:hostTime)
        guard recording.token==token,recording.enabled,var gesture=recording.gesture else {return}
        do {
            try gesture.append(time:showRuntime.time,value:value)
            try publishAutomationGesture(gesture)
            if let timeline=timelineWindow,timeline.selectedTrackID==gesture.track.id {timeline.canvas.track=gesture.track}
            recording.message="Recording \(gesture.track.parameter) · \(gesture.sampleCount) samples"
            updateRender();timelineWindow?.refreshRecordingControls()
        } catch {stopAutomationRecording(reason:"Recording stopped: "+error.localizedDescription,at:hostTime)}
    }
    func endAutomationGesture(token:UUID,at hostTime:Double=ProcessInfo.processInfo.systemUptime) {
        guard recording.token==token else {return}
        advanceShow(at:hostTime)
        guard recording.token==token else {return}
        if var gesture=recording.gesture,gesture.changed {
            do { _=try gesture.finish(time:showRuntime.time);try publishAutomationGesture(gesture) }
            catch {stopAutomationRecording(reason:"Recording stopped: "+error.localizedDescription,at:hostTime);return}
        }
        finishAutomationGesture(at:hostTime)
    }
    private func publishAutomationGesture(_ gesture:AutomationRecording) throws {
        guard let index=project.timeline.firstIndex(where:{$0.id==gesture.track.id}) else {throw ProjectError.invalid("recording track was removed")}
        let count=project.timeline.reduce(0) {$0+$1.keyframes.count}-project.timeline[index].keyframes.count+gesture.track.keyframes.count
        guard count<=65536 else {throw ProjectError.invalid("recording exceeds the project key budget")}
        recording.gesture=gesture
        if gesture.changed {
            project.timeline[index]=gesture.track;dirty=true;window?.isDocumentEdited=true
            window?.title="\(project.name) • — ApertureCue 0.1"
        }
    }
    /// Samples are already part of the valid document, so save/recovery and a
    /// candidate computed before this call cannot lose a separate hidden take.
    private func finishAutomationGesture(at hostTime:Double) {
        guard let before=recording.before else {return}
        let changed=recording.gesture?.changed == true
        recording.gesture=nil;recording.token=nil;recording.before=nil
        do {
            try ProjectStore.validate(project)
            if changed,before != project {
                history.commit(before:before,after:project,label:"Record automation gesture")
                dirty=true;recording.message="Recorded gesture · Undo available"
            } else {dirty=recording.dirtyBefore}
        } catch {project=before;dirty=recording.dirtyBefore;recording.message=error.localizedDescription}
        configureShow(at:hostTime);updateRender();timelineWindow?.refresh()
        window?.isDocumentEdited=dirty;window?.title="\(project.name)\(dirty ? " •" : "") — ApertureCue 0.1"
        refreshRecordingInspectorWhenSafe()
    }
    func applyRecordingOverride(to surfaces:[Surface])->[Surface] {
        guard let gesture=recording.gesture,gesture.changed,let i=surfaces.firstIndex(where:{$0.id==gesture.track.surfaceID}) else {return surfaces}
        var result=surfaces
        Self.setRecordedScalar(&result[i],parameter:gesture.track.parameter,value:gesture.lastValue)
        return result
    }
    static func setRecordedScalar(_ surface:inout Surface,parameter:String,value:Double) {
        switch parameter {
        case "opacity":surface.opacity=value
        case "brightness":surface.brightness=value
        case "gamma":surface.gamma=value
        case "red","green","blue":surface.color[parameter == "red" ? 0 : parameter == "green" ? 1 : 2]=value
        default:break
        }
    }
    func makeAutomationSlider(title:String,parameter:String,surfaceID:UUID,value:Double,min:Double,max:Double)->AutomationSlider {
        let eligible=recordingTrack(surfaceID:surfaceID,parameter:parameter) != nil
        let range=recording.enabled && eligible ? (try? TimelineEngine.parameterRange(parameter)) : nil
        let slider=AutomationSlider(value:value,min:range?.lowerBound ?? min,max:range?.upperBound ?? max)
        slider.identifier=NSUserInterfaceItemIdentifier("automation."+parameter)
        slider.beginBlock={[weak self] in self?.beginAutomationGesture(surfaceID:surfaceID,parameter:parameter)}
        slider.trackingBlock={[weak self] active in
            guard let self else {return};self.recording.nativeTracking=active
            if !active,self.recording.pendingInspectorRefresh {self.recording.pendingInspectorRefresh=false;self.refreshInspector()}
        }
        slider.endBlock={[weak self] token in self?.endAutomationGesture(token:token)}
        slider.valueBlock={[weak self] value,token in
            guard let self else {return}
            if let token {self.recordAutomationValue(value,token:token);return}
            if let token=self.beginAutomationGesture(surfaceID:surfaceID,parameter:parameter) {
                self.recordAutomationValue(value,token:token);self.endAutomationGesture(token:token);return
            }
            self.editSurface(title) {Self.setRecordedScalar(&$0,parameter:parameter,value:value)}
        }
        recording.sliders[parameter]=slider
        return slider
    }
    func refreshRecordingInspectorWhenSafe() {
        if recording.nativeTracking {recording.pendingInspectorRefresh=true} else {refreshInspector()}
    }
    func updateRecordingInspector() {
        guard recording.enabled,let id=selectedID else {return}
        for track in project.timeline where track.surfaceID==id && track.enabled && recording.armed.contains(track.id) {
            let value:Double
            if let gesture=recording.gesture,gesture.track.id==track.id,gesture.changed {value=gesture.lastValue}
            else {value=(try? Automation.value(at:showRuntime.time,keyframes:track.keyframes)) ?? 0}
            if !recording.nativeTracking {recording.sliders[track.parameter]?.doubleValue=value}
            recording.labels[track.parameter]?.stringValue=String(format:"%@ [REC]  %.3f",track.parameter,value)
        }
    }
}
#endif
