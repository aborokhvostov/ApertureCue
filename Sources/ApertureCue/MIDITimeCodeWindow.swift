#if os(macOS)
import AppKit
import MappingCore

extension EditorController {
    @objc func showMIDITimeCode() {
        let session = showControlSession
        if session.timeCodeWindow == nil { session.timeCodeWindow = MIDITimeCodeWindow(editor: self) }
        session.timeCodeWindow?.showAndRefresh()
    }

    func armMIDITimeCode(inputUID: Int32, name: String, origin: Double,
                         at hostTime: Double = ProcessInfo.processInfo.systemUptime) throws {
        guard hostTime.isFinite, hostTime >= 0 else { throw ProjectError.invalid("invalid clock host time") }
        let session = showControlSession
        guard !session.isClockArmed else { throw ProjectError.invalid("disarm the current external clock before switching sources") }
        let adapter = try MIDITimeCodeAdapter(inputUID: inputUID, inputName: name, origin: origin) { [weak self] packet, time in
            self?.handleExternalShowClock(packet, receivedAt: time)
        }
        do { try session.clock.arm(source: adapter.sourceKey) }
        catch { adapter.stop(); throw error }
        session.timeCode = adapter
        showRuntime.allowsPositionJumps = false
        externalShowAlign(to: showRuntime.currentTime(at: hostTime), playing: false, at: hostTime)
        session.window?.refreshStatus()
        session.timeCodeWindow?.refreshStatus()
    }
}

@MainActor final class MIDITimeCodeWindow: NSWindowController, NSWindowDelegate {
    private weak var editor: EditorController?
    private var endpoints: [MIDIControlAdapter.Endpoint] = []
    private let input = NSPopUpButton()
    private let origin = ActionField("0", action: { _ in })
    private let status = label("")
    private let arm = ActionButton("Arm time code") {}
    private let rescan = ActionButton("Refresh MIDI sources") {}
    private var timer: Timer?

    init(editor: EditorController) {
        self.editor = editor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 565, height: 205),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MIDI Time Code"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        guard let content = window.contentView else { return }
        input.widthAnchor.constraint(equalToConstant: 340).isActive = true
        input.target = self
        input.action = #selector(refreshStatus)
        origin.widthAnchor.constraint(equalToConstant: 100).isActive = true
        origin.toolTip = "Time code that maps to zero on the show timeline"
        status.lineBreakMode = .byTruncatingTail
        let rows = stack([stack([label("MIDI source"), input], vertical: false),
                          stack([label("Show time zero (source seconds)"), origin], vertical: false),
                          status, stack([arm, rescan], vertical: false)])
        fill(rows, in: content, inset: 14)
        status.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        arm.actionBlock = { [weak self] in self?.toggleClock() }
        rescan.actionBlock = { [weak self] in self?.refreshEndpoints() }
        refreshEndpoints()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showAndRefresh() {
        refreshEndpoints()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        let clock = Timer(timeInterval: 0.20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        timer = clock
        RunLoop.main.add(clock, forMode: .common)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private var selected: MIDIControlAdapter.Endpoint? {
        let index = input.indexOfSelectedItem - 1
        return endpoints.indices.contains(index) ? endpoints[index] : nil
    }

    private func refreshEndpoints() {
        let selectedUID = editor?.showControlSession.timeCode?.inputUID ?? selected?.uid
        endpoints = MIDIControlAdapter.inputEndpoints()
        input.removeAllItems()
        input.addItem(withTitle: endpoints.isEmpty ? "No available MIDI sources" : "Select a MIDI source")
        input.addItems(withTitles: endpoints.map { "\($0.name) · \($0.uid)" })
        if let index = endpoints.firstIndex(where: { $0.uid == selectedUID }) { input.selectItem(at: index + 1) }
        else { input.selectItem(at: 0) }
        refreshStatus()
    }

    @objc func refreshStatus() {
        guard let session = editor?.showControlSession else { return }
        let armed = session.isClockArmed
        let owner = session.timeCode
        arm.title = owner == nil ? "Arm time code" : "Disarm time code"
        arm.isEnabled = owner != nil || (!armed && selected != nil)
        input.isEnabled = !armed && !endpoints.isEmpty
        origin.isEnabled = !armed
        rescan.isEnabled = !armed
        guard let owner else {
            status.stringValue = armed ? "OSC owns the external show clock" : "MIDI time code off"
            status.toolTip = status.stringValue
            return
        }
        let summary: String
        switch session.clock.state {
        case .off: summary = "Off"
        case .waiting: summary = owner.isConnected ? "Waiting for time code" : "Waiting for selected source"
        case .locked: summary = owner.latestEvent?.motion == .forward ? "Locked" : "Located · paused"
        case .held: summary = "Held by marker or show end"
        case .lost: summary = "Lost · playback paused"
        }
        status.stringValue = "\(summary) · \(owner.inputName)"
        status.toolTip = status.stringValue
    }

    private func toggleClock() {
        guard let editor else { return }
        if editor.showControlSession.timeCode != nil {
            editor.disarmExternalShowClock()
            refreshEndpoints()
            return
        }
        guard let selected else { return }
        do {
            let text = origin.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let seconds = Double(text) else { throw ProjectError.invalid("enter the source time at show zero in seconds") }
            try editor.armMIDITimeCode(inputUID: selected.uid, name: selected.name, origin: seconds)
        } catch { editor.showError(error) }
    }
}
#endif
