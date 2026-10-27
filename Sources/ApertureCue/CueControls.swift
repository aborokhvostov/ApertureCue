#if os(macOS)
import AppKit
import MappingCore

extension EditorController {
    @objc func showCueWindow() {
        if cueWindow == nil { cueWindow=CueWindowController(editor:self) }
        cueWindow?.refresh();cueWindow?.showWindow(nil);cueWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @discardableResult
    func cueCreate(name:String,scope:CueScope,bindings:[CueBinding],duration:Double,followAfter:Double?) throws -> UUID {
        let cue:Cue
        if scope == .full { cue=Cue(name:name,surfaces:project.surfaces,duration:duration,followAfter:followAfter) }
        else { cue=try CueSelection.capture(name:name,surfaces:project.surfaces,bindings:bindings,duration:duration,followAfter:followAfter) }
        var candidate=project;candidate.cues.append(cue);try ProjectStore.validate(candidate)
        mutate("Capture \(scope.rawValue) cue") {$0=candidate};return cue.id
    }
    func cueUpdate(id:UUID,name:String,scope:CueScope,bindings:[CueBinding],duration:Double,followAfter:Double?) throws {
        guard let i=project.cues.firstIndex(where:{$0.id==id}) else { throw ProjectError.invalid("cue no longer exists") }
        guard project.cues[i].scope == scope else { throw ProjectError.invalid("A saved scene keeps its scope. Capture a new full or selective scene to change scope.") }
        var candidate=project, cue=candidate.cues[i]
        cue.name=name;cue.duration=duration;cue.followAfter=followAfter;cue.scope=scope
        if scope == .selective {
            let wanted=Set(bindings.map(\.surfaceID))
            cue.surfaces=cue.surfaces.filter {wanted.contains($0.id)}
            cue.bindings=bindings
        } else {cue.bindings=[]}
        candidate.cues[i]=cue;try ProjectStore.validate(candidate)
        mutate("Edit cue properties / fields") {$0=candidate}
    }
    func cueRecapture(id:UUID,bindings:[CueBinding]) throws {
        guard let i=project.cues.firstIndex(where:{$0.id==id}) else { throw ProjectError.invalid("cue no longer exists") }
        let previous=project.cues[i],cue:Cue
        if previous.scope == .full {cue=Cue(id:previous.id,name:previous.name,surfaces:project.surfaces,duration:previous.duration,followAfter:previous.followAfter)}
        else {cue=try CueSelection.capture(name:previous.name,surfaces:project.surfaces,bindings:bindings,duration:previous.duration,followAfter:previous.followAfter,id:previous.id)}
        var candidate=project;candidate.cues[i]=cue;try ProjectStore.validate(candidate)
        mutate("Recapture cue values") {$0=candidate}
    }
    func cueDelete(id:UUID) throws {
        guard project.cues.contains(where:{$0.id==id}) else {throw ProjectError.invalid("cue no longer exists")}
        var candidate=project
        candidate.cues.removeAll {$0.id==id}
        candidate.timelineSettings.markers.removeAll {$0.cueID==id}
        let targets=Set((candidate.surfaces+candidate.cues.filter {$0.scope == .full}.flatMap(\.surfaces)).map(\.id))
        candidate.timeline.removeAll {!targets.contains($0.surfaceID)}
        try ProjectStore.validate(candidate)
        mutate("Delete scene") {$0=candidate}
    }
}
#endif
