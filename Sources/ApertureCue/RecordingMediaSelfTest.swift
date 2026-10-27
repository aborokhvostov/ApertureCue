#if os(macOS)
import AppKit
import MappingCore

@MainActor enum RecordingMediaSelfTest {
    private struct Failure:LocalizedError {
        var message:String
        var errorDescription:String? {message}
    }
    static func run(editor e:EditorController,directory:URL)throws->[String] {
        func expect(_ condition:@autoclosure()throws->Bool,_ message:String)throws {
            guard try condition() else {throw Failure(message:message)}
        }
        func pump(_ timeout:Double,_ condition:()->Bool)->Bool {
            let deadline=ProcessInfo.processInfo.systemUptime+timeout
            repeat {
                if condition() {return true}
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01))
            } while ProcessInfo.processInfo.systemUptime<deadline
            return condition()
        }
        defer {e.stopAutomationRecording();e.stopShow()}
        e.stopAutomationRecording();e.stopShow();e.dirty=false
        let generated=directory.appendingPathComponent("recording-generated-media",isDirectory:true)
        try DemoGenerator.generate(at:generated)
        var project=try ProjectStore.load(from:generated.appendingPathComponent("Demo.aperturecue.json"))
        guard let movie=project.assets.first(where:{$0.kind=="video"}) else {throw Failure(message:"Generated recording movie missing")}
        project.name="Recording decoder continuity"
        project.surfaces=[Surface(name:"Recording movie",mediaID:movie.id,output:Point2.unitQuad,opacity:0.5)]
        project.cues=[]
        let track=AutomationTrack(name:"Movie opacity",surfaceID:project.surfaces[0].id,parameter:"opacity",keyframes:[AutomationKeyframe(time:0,value:0.25),AutomationKeyframe(time:10,value:0.75)])
        project.timeline=[track]
        let url=directory.appendingPathComponent("recording-movie.aperturecue.json")
        try ProjectStore.save(project,to:url);e.openProject(url)
        try expect(pump(12) {e.media.duration(for:movie.id)>2.9},"Recording H.264 decoder did not become ready")
        e.seekShow(to:0.25);e.playShow()
        try expect(pump(8) {e.media.texture(for:movie.id) != nil && e.media.playbackTime(for:movie.id)>0.35},"Recording H.264 did not decode while playing")
        try e.setRecordingArmed(trackID:track.id,armed:true)
        try e.startAutomationRecording()
        guard let generation=e.media.seekGeneration(for:movie.id) else {throw Failure(message:"Movie seek generation unavailable")}
        let mediaTime=e.media.playbackTime(for:movie.id)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.04))
        e.refresh();e.configureShow()
        try expect(e.media.seekGeneration(for:movie.id)==generation,"No-op runtime configuration rewound a running movie between ticks")
        try expect(e.media.isPlaying && e.showRuntime.isPlaying && e.media.playbackTime(for:movie.id)>=mediaTime-0.08,"No-op refresh stopped the recording clocks")
        let before=e.project
        guard let token=e.beginAutomationGesture(surfaceID:track.surfaceID,parameter:"opacity") else {throw Failure(message:"Native recording adapter did not begin")}
        e.recordAutomationValue(0.7,token:token)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.04))
        e.recordAutomationValue(0.4,token:token)
        try expect(e.renderer.surfaces.first?.opacity==0.4,"Live recording override did not reach the production renderer")
        e.endAutomationGesture(token:token);e.advanceShow(at:ProcessInfo.processInfo.systemUptime)
        try expect(e.project.surfaces==before.surfaces && e.project.timeline != before.timeline,"Recording edited movie base state or did not write keys")
        try expect(e.media.seekGeneration(for:movie.id)==generation,"Recording samples or gesture commit invoked a movie seek")
        try expect(e.media.isPlaying && e.showRuntime.isPlaying && e.media.playbackTime(for:movie.id)>=mediaTime-0.08,"Recording gesture restarted or paused the generated movie")
        let after=e.project
        e.undoEdit();e.advanceShow(at:ProcessInfo.processInfo.systemUptime)
        try expect(e.project==before && e.media.seekGeneration(for:movie.id)==generation,"Recording Undo changed clock/decoder or failed to restore keys")
        e.redoEdit();e.advanceShow(at:ProcessInfo.processInfo.systemUptime)
        try expect(e.project==after && e.media.seekGeneration(for:movie.id)==generation,"Recording Redo changed clock/decoder or failed to restore keys")
        try ProjectStore.validate(e.project)
        return ["no-op show configuration between ticks preserves the running H.264 seek generation",
                "recorded gestures and Undo/Redo keep generated H.264/show clocks and production preview continuous"]
    }
}
#endif
