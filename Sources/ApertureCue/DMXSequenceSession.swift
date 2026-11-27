#if os(macOS)
import AppKit
import MappingCore

@MainActor final class DMXSequenceSession {
    static let refreshInterval = 1.0 / 30.0

    private let ensureSampling: () throws -> Void
    private let canOutput: () -> Bool
    private let beginOutput: (Set<Int>) throws -> Void
    private let outputFrame: ([Int: [UInt8]], Bool) throws -> Void
    private let endOutput: () -> Void
    private let fileQueue = DispatchQueue(label: "org.aperturecue.dmx-sequence",
                                          qos: .userInitiated)

    private var window: DMXSequenceWindow?
    private var recorder: DMXSequenceRecorder?
    private var captureAnchor: UInt64?
    private(set) var player: DMXSequencePlayer?
    private var replayTimer: Timer?
    private var fileRequest: UUID?
    private var activeFileWorker: UUID?
    private(set) var sequenceGeneration: UInt64 = 0
    private(set) var replayGeneration: UInt64 = 0
    private(set) var isNetworkReplay = false
    private(set) var status = "Record a live sample or open a sequence"
    private(set) var fileName: String?

    init(ensureSampling: @escaping () throws -> Void,
         canOutput: @escaping () -> Bool,
         beginOutput: @escaping (Set<Int>) throws -> Void,
         outputFrame: @escaping ([Int: [UInt8]], Bool) throws -> Void,
         endOutput: @escaping () -> Void) {
        self.ensureSampling = ensureSampling
        self.canOutput = canOutput
        self.beginOutput = beginOutput
        self.outputFrame = outputFrame
        self.endOutput = endOutput
    }

    var sequence: DMXSequence? { player?.sequence }
    var isRecording: Bool { recorder != nil }
    var isPlaying: Bool { player?.isPlaying == true }
    var isBusy: Bool { activeFileWorker != nil }
    var networkReady: Bool { canOutput() }
    var captureCount: Int { recorder?.frameCount ?? 0 }

    func showWindow() {
        if window == nil { window = DMXSequenceWindow(session: self) }
        window?.refresh()
        window?.showWindow(nil)
        window?.window?.makeKeyAndOrderFront(nil)
    }

    func refreshNetworkState() { window?.refresh() }

    func startCapture(at hostTime: Double = ProcessInfo.processInfo.systemUptime) throws {
        guard !isBusy, !isPlaying, !isRecording, let time = Self.hostMicroseconds(hostTime) else {
            throw DMXSequenceError.invalid("stop replay or file work before recording")
        }
        try ensureSampling()
        captureAnchor = time
        recorder = DMXSequenceRecorder()
        setStatus("Recording live DMX")
    }

    /// Called from the controller only for accepted live samples.
    func capture(_ universes: [Int: [UInt8]], at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard let captureAnchor, let host = Self.hostMicroseconds(hostTime), host >= captureAnchor else { return }
        let elapsed = host - captureAnchor
        if let previous = recorder?.lastObservedMicroseconds, elapsed <= previous { return }
        do {
            try recorder?.capture(universes, at: elapsed)
            window?.refresh()
        } catch {
            finishCapture(at: hostTime, note: error.localizedDescription)
        }
    }

    func finishCapture(at hostTime: Double = ProcessInfo.processInfo.systemUptime, note: String? = nil) {
        guard let captured = recorder, let anchor = captureAnchor else { return }
        recorder = nil
        captureAnchor = nil
        let host = Self.hostMicroseconds(hostTime) ?? anchor
        let elapsed = host >= anchor ? host - anchor : 0
        let final = min(DMXSequence.maximumDurationMicroseconds, max(1, elapsed, captured.lastObservedMicroseconds ?? 0))
        do {
            let next = try captured.finish(at: final)
            install(next)
            let result = "Captured \(next.frames.count) snapshot(s)"
            setStatus(note.map { result + " · " + $0 } ?? result)
        } catch {
            setStatus(note ?? error.localizedDescription)
        }
    }

    func install(_ sequence: DMXSequence, name: String? = nil) {
        stopPlayback()
        player = DMXSequencePlayer(sequence: sequence)
        sequenceGeneration &+= 1
        fileName = name
        window?.refresh()
    }

    func load(from url: URL) {
        guard !isRecording, !isPlaying, !isBusy else { return }
        let request = UUID()
        fileRequest = request
        activeFileWorker = request
        setStatus("Opening sequence…")
        fileQueue.async { [self] in
            let result = Result { try DMXSequence.load(from: url) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeFileWorker == request else { return }
                self.activeFileWorker = nil
                guard self.fileRequest == request else { self.window?.refresh(); return }
                self.fileRequest = nil
                switch result {
                case .success(let sequence):
                    self.install(sequence, name: url.lastPathComponent)
                    self.setStatus("Opened \(sequence.frames.count) snapshot(s)")
                case .failure(let error):
                    self.setStatus(error.localizedDescription)
                }
            }
        }
    }

    func save(to url: URL) {
        guard let sequence, !isRecording, !isPlaying, !isBusy else { return }
        let request = UUID()
        fileRequest = request
        activeFileWorker = request
        setStatus("Saving sequence…")
        fileQueue.async { [self] in
            let result = Result { try sequence.save(to: url) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeFileWorker == request else { return }
                self.activeFileWorker = nil
                guard self.fileRequest == request else { self.window?.refresh(); return }
                self.fileRequest = nil
                switch result {
                case .success:
                    self.fileName = url.lastPathComponent
                    self.setStatus("Saved \(sequence.frames.count) snapshot(s)")
                case .failure(let error):
                    self.setStatus(error.localizedDescription)
                }
            }
        }
    }

    func play(network: Bool, at hostTime: Double = ProcessInfo.processInfo.systemUptime,
              automaticTicks: Bool = true) throws {
        guard let time = Self.hostMicroseconds(hostTime), var player, !isRecording, !isBusy, !isPlaying else {
            throw DMXSequenceError.invalid("open a sequence and stop recording before replay")
        }
        if network {
            guard canOutput() else { throw DMXSequenceError.invalid("arm lighting network output before replaying to it") }
            try beginOutput(player.sequence.universeIDs)
            isNetworkReplay = true
        }
        _ = player.play(at: time)
        replayGeneration &+= 1
        self.player = player
        do {
            try render(player.current, discontinuity: true)
            if automaticTicks { startTimer(generation: replayGeneration) }
            setStatus(network ? "Playing to armed network output" : "Playing in sequence preview")
        } catch {
            stopPlayback()
            throw error
        }
    }

    func seek(to seconds: Double, at hostTime: Double = ProcessInfo.processInfo.systemUptime) throws {
        guard let time = Self.hostMicroseconds(hostTime), let target = Self.hostMicroseconds(seconds), var player,
              !isRecording, !isBusy else { throw DMXSequenceError.invalid("invalid replay position") }
        let hasTimer = replayTimer != nil
        _ = player.seek(to: target, at: time)
        replayGeneration &+= 1
        self.player = player
        do {
            try render(player.current, discontinuity: true)
            if !player.isPlaying {
                let wasNetwork = isNetworkReplay
                stopPlayback()
                if wasNetwork { setStatus("End of sequence · network replay stopped") }
            } else if hasTimer {
                startTimer(generation: replayGeneration)
            }
        } catch {
            stopPlayback()
            throw error
        }
    }

    func advance(at hostTime: Double = ProcessInfo.processInfo.systemUptime, generation: UInt64) {
        guard generation == replayGeneration, let host = Self.hostMicroseconds(hostTime),
              let playerGeneration = player?.generation,
              let tick = player?.tick(at: host, generation: playerGeneration) else { return }
        do {
            try render(tick, discontinuity: false)
            if !tick.isPlaying {
                stopPlayback()
                setStatus("End of sequence")
            }
        } catch {
            stopPlayback()
            setStatus(error.localizedDescription)
        }
    }

    func stopPlayback() {
        let wasPlaying = isPlaying
        stopTimerAndClock()
        let wasNetwork = isNetworkReplay
        isNetworkReplay = false
        if wasNetwork { endOutput() }
        if wasNetwork || wasPlaying { status = "Replay stopped" }
        window?.refresh()
    }

    func networkOutputWasStopped() {
        guard isNetworkReplay else { return }
        isNetworkReplay = false
        stopTimerAndClock()
        setStatus("Network replay stopped")
    }

    func windowWasClosed() {
        stopPlayback()
        if isRecording { finishCapture() }
    }

    func reset() {
        stopPlayback()
        recorder = nil
        captureAnchor = nil
        fileRequest = nil
        player = nil
        sequenceGeneration &+= 1
        fileName = nil
        setStatus("Record a live sample or open a sequence")
        window?.close()
        window = nil
    }

    func showError(_ error: Error) { setStatus(error.localizedDescription) }

    private func render(_ tick: DMXSequenceTick, discontinuity: Bool) throws {
        if isNetworkReplay {
            let frame = tick.frameIndex.flatMap { player?.sequence.frames[$0].universes } ?? [:]
            try outputFrame(frame, discontinuity)
        }
        window?.refresh()
    }

    private func setStatus(_ text: String) {
        status = text
        window?.refresh()
    }

    private func startTimer(generation: UInt64) {
        replayTimer?.invalidate()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(generation: generation) }
        }
        timer.tolerance = 0.004
        replayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimerAndClock() {
        replayGeneration &+= 1
        replayTimer?.invalidate()
        replayTimer = nil
        _ = player?.stop()
    }

    private static func hostMicroseconds(_ seconds: Double) -> UInt64? {
        let value = seconds * 1_000_000
        guard value.isFinite, value >= 0, value < Double(UInt64.max) else { return nil }
        return UInt64(value.rounded(.down))
    }
}
#endif
