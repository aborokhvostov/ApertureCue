#if os(macOS)
import AppKit
import MappingCore

@MainActor final class NativeShowControlSession {
    var window: ShowControlWindow?
    var outputsArmed = false
    var outputStatus = "Outputs off"
    var clock = ExternalShowClock()
    var listener: NetworkController?
    let output = ShowControlOutput()

    func reset() {
        listener?.stop()
        listener = nil
        clock.disarm()
        output.stop()
        outputsArmed = false
        outputStatus = "Outputs off"
        window?.close()
        window = nil
    }
}

extension EditorController {
    @objc func showControls() {
        if showControlSession.window == nil { showControlSession.window = ShowControlWindow(editor: self) }
        showControlSession.window?.refresh()
        showControlSession.window?.showWindow(nil)
        showControlSession.window?.window?.makeKeyAndOrderFront(nil)
    }

    func refreshShowControls() { showControlSession.window?.refresh() }

    func setShowControlOutputArmed(_ enabled: Bool) throws {
        let session = showControlSession
        if enabled {
            guard !showRuntime.isPlaying else { throw ProjectError.invalid("pause the show before arming outputs") }
            try session.output.prepareMIDI()
        } else {
            session.output.stop()
        }
        session.outputsArmed = enabled
        session.outputStatus = enabled ? "Armed · OSC localhost and virtual MIDI source" : "Outputs off"
        session.window?.refreshStatus()
    }

    func dispatchShowControlEvents(_ events: [ShowControlEvent]) {
        let session = showControlSession
        guard session.outputsArmed, !events.isEmpty else { return }
        var failures = 0
        var lastError = ""
        for event in events.prefix(ShowRuntime.eventBudget) {
            do {
                try session.output.send(event.command)
            } catch {
                failures += 1
                lastError = error.localizedDescription
            }
        }
        session.outputStatus = failures == 0 ? "Armed · emitted \(min(events.count, ShowRuntime.eventBudget)) event(s)"
            : "Armed · \(failures) send failure(s) · \(lastError)"
        session.window?.refreshStatus()
    }

    func flushShowControlNotes() { showControlSession.output.flushNotes() }

    func resetShowControlSession() {
        showControlSession.reset()
        showRuntime.allowsPositionJumps = true
    }

    func armExternalShowClock(source: String, port: UInt16, at hostTime: Double = ProcessInfo.processInfo.systemUptime) throws {
        guard hostTime.isFinite else { throw ProjectError.invalid("external clock host time must be finite") }
        let session = showControlSession
        guard session.listener == nil else { throw ProjectError.invalid("disarm the current external clock before changing its source") }
        var clock = ExternalShowClock()
        try clock.arm(source: source)
        let listener = NetworkController(clockOnly: true) { [weak self] command in
            if case let .externalClock(packet, receivedAt) = command {
                self?.handleExternalShowClock(packet, receivedAt: receivedAt)
            }
        }
        try listener.start(port: port)
        session.clock = clock
        session.listener = listener
        showRuntime.allowsPositionJumps = false
        externalShowAlign(to: showRuntime.currentTime(at: hostTime), playing: false, at: hostTime)
        session.window?.refreshStatus()
    }

    func releaseExternalShowClock() {
        let session = showControlSession
        session.listener?.stop()
        session.listener = nil
        session.clock.disarm()
        showRuntime.allowsPositionJumps = true
        session.window?.refreshStatus()
    }

    func disarmExternalShowClock(at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard showControlSession.listener != nil else { return }
        releaseExternalShowClock()
        externalShowAlign(to: showRuntime.currentTime(at: hostTime), playing: false, at: hostTime)
    }

    func handleExternalShowClock(_ packet: ExternalShowClockPacket, receivedAt: Double) {
        _ = showControlSession.clock.receive(packet, at: receivedAt)
    }

    func applyExternalShowClock(at hostTime: Double) {
        let session = showControlSession
        guard session.listener != nil else { return }
        let oldState = session.clock.state
        let settings = showRuntime.settings
        let loop = settings.loopEnabled ? settings.loopStart...settings.loopEnd : nil
        let action = session.clock.update(at: hostTime, localPosition: showRuntime.currentTime(at: hostTime),
                                          localPlaying: showRuntime.projectedPlaying(at: hostTime), loop: loop)
        switch action {
        case let .align(position, playing):
            externalShowAlign(to: position, playing: playing, at: hostTime)
        case let .freeze(boundary):
            externalShowAlign(to: showRuntime.currentTime(at: boundary), playing: false, at: hostTime)
        case nil:
            break
        }
        if oldState != session.clock.state { session.window?.refreshStatus() }
    }

    private func externalShowAlign(to position: Double, playing: Bool, at hostTime: Double) {
        stopAutomationRecording(reason: "External clock alignment", at: hostTime)
        guard hostTime.isFinite, position.isFinite else { return }
        feedback?.reset()
        flushShowControlNotes()
        let limit = showRuntime.settings.loopEnabled ? showRuntime.settings.loopEnd
            : showRuntime.settings.stopAtEnd ? showRuntime.settings.duration : ShowRuntime.maximumTime
        // A running packet beyond the local boundary holds at that boundary
        // until the sender changes transport or a manual takeover occurs.
        let shouldPlay = playing && position < limit
        if showRuntime.isPlaying && !shouldPlay { showRuntime.pause(at: hostTime) }
        // Seeking after pause also discards any queued crossings consumed by pause.
        showRuntime.seek(to: min(position, limit), at: hostTime)
        if shouldPlay && !showRuntime.isPlaying { showRuntime.play(at: hostTime) }
        montageSerial &+= 1
        if !shouldPlay { media.pause() }
        media.seek(to: showRuntime.time)
        if shouldPlay && !media.isPlaying { media.play() }
        updateRender()
        timelineWindow?.updatePlayhead()
    }
}
#endif
