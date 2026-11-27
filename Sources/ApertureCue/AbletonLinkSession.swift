#if os(macOS)
import AppKit
import MappingCore

@MainActor final class AbletonLinkSession {
    private struct Context {
        let document: UUID
        let settings: TimelineSettings
        let tracks: [AutomationTrack]
        let controlTracks: [ShowControlTrack]
        let cue: Cue

        func matches(document: UUID, project: Project) -> Bool {
            self.document == document && settings == project.timelineSettings && tracks == project.timeline
                && controlTracks == project.showControlTracks && project.cues.contains(cue)
        }
    }

    private var bridge: AbletonLinkBridge?
    private var queue = AbletonLinkCueQueue()
    private var queuedContext: Context?
    private(set) var message = ""
    var window: AbletonLinkWindow?
    var bridgeName: String? { bridge?.name }
    var observation: AbletonLinkObservation? { queue.latest }
    var pendingCue: UUID? { queue.pendingCue }

    func connect(_ executable: URL, fixture: Bool = false) throws {
        guard bridge == nil else { throw SystemFailure(message: "Disconnect the current Link bridge first") }
        bridge = try AbletonLinkBridge(executable: executable, testFixture: fixture)
        message = ""
    }

    func disconnect(message: String = "Link disconnected") {
        bridge?.stop()
        bridge = nil
        queue = AbletonLinkCueQueue()
        queuedContext = nil
        self.message = message
    }

    func reset() {
        disconnect(message: "")
        window?.close()
        window = nil
    }

    func queueCue(_ cue: Cue, document: UUID, project: Project) throws {
        guard project.cues.contains(cue) else { throw SystemFailure(message: "Choose a cue from the current project") }
        try queue.enqueue(cue.id, now: AbletonLinkBridge.now)
        queuedContext = Context(document: document, settings: project.timelineSettings, tracks: project.timeline,
                                controlTracks: project.showControlTracks, cue: cue)
        message = "Queued \(cue.name) for the next 4-beat boundary"
    }

    func cancel(message: String = "Queued cue cancelled") {
        guard pendingCue != nil else { return }
        queue.cancel()
        queuedContext = nil
        self.message = message
    }

    func poll(document: UUID, project: Project) -> UUID? {
        guard let bridge else { return nil }
        if let queuedContext, !queuedContext.matches(document: document, project: project) {
            cancel(message: "Queued cue cancelled because the show changed")
        }
        let state = bridge.state
        if let failure = state.failure { disconnect(message: failure); return nil }
        guard let response = queue.observe(state.observation, now: AbletonLinkBridge.now) else { return nil }
        queuedContext = nil
        switch response {
        case .recall(let cue): return cue
        case .signalLost: message = "Queued cue cancelled because Link signal was lost"
        case .clockMoved: message = "Queued cue cancelled because Link phase shifted"
        case .boundaryMissed: message = "Queued cue cancelled because the boundary passed"
        }
        return nil
    }

    func recalled(_ cue: Cue, success: Bool) {
        message = success ? "Recalled \(cue.name) at the Link boundary" : "Could not recall \(cue.name)"
    }
}

extension EditorController {
    @objc func showAbletonLink() {
        if abletonLinkSession.window == nil { abletonLinkSession.window = AbletonLinkWindow(editor: self) }
        abletonLinkSession.window?.showAndRefresh()
    }

    func pollAbletonLink() {
        guard let cue = abletonLinkSession.poll(document: documentGeneration, project: project),
              let index = project.cues.firstIndex(where: { $0.id == cue }) else { return }
        let target = project.cues[index]
        let recalled = goCue(index: index, interactive: false)
        if recalled, cueTarget?.duration == 0 { applyCueSample(at: cueStart) }
        abletonLinkSession.recalled(target, success: recalled)
    }

    func cancelAbletonLinkCue() {
        abletonLinkSession.cancel(message: "Queued Link cue cancelled by the timeline")
    }
}
#endif
