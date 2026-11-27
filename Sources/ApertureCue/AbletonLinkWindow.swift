#if os(macOS)
import AppKit
import MappingCore

@MainActor final class AbletonLinkWindow: NSWindowController, NSWindowDelegate {
    private weak var editor: EditorController?
    private var helperURL: URL?
    private var cues: [Cue] = []
    private let cuePicker = NSPopUpButton()
    private let bridgeLabel = label("No Link helper selected")
    private let status = label("Link off")
    private let queueStatus = label("")
    private let choose = ActionButton("Choose helper…") {}
    private let connect = ActionButton("Connect to Link on LAN") {}
    private let recall = ActionButton("Queue cue on next bar") {}
    private let cancel = ActionButton("Cancel queued cue") {}
    private var timer: Timer?

    init(editor: EditorController) {
        self.editor = editor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 595, height: 225),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Ableton Link"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        guard let content = window.contentView else { return }
        let rows = stack([bridgeLabel,
                          stack([choose, connect], vertical: false),
                          status,
                          stack([label("Scene"), cuePicker], vertical: false),
                          stack([recall, cancel], vertical: false),
                          queueStatus])
        fill(rows, in: content, inset: 14)
        cuePicker.widthAnchor.constraint(equalToConstant: 380).isActive = true
        cuePicker.target = self
        cuePicker.action = #selector(refreshStatus)
        for field in [bridgeLabel, status, queueStatus] {
            field.lineBreakMode = .byTruncatingTail
            field.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        choose.actionBlock = { [weak self] in self?.chooseHelper() }
        connect.actionBlock = { [weak self] in self?.toggleConnection() }
        recall.actionBlock = { [weak self] in self?.queueSelectedCue() }
        cancel.actionBlock = { [weak self] in
            self?.editor?.abletonLinkSession.cancel()
            self?.refreshStatus()
        }
        refreshStatus()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showAndRefresh() {
        refreshStatus()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        let clock = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        timer = clock
        RunLoop.main.add(clock, forMode: .common)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        if let session = editor?.abletonLinkSession, session.bridgeName != nil { session.disconnect() }
    }

    private var selectedCue: Cue? {
        let index = cuePicker.indexOfSelectedItem - 1
        return cues.indices.contains(index) ? cues[index] : nil
    }

    @objc private func refreshStatus() {
        guard let editor else { return }
        if editor.project.cues != cues {
            let selected = selectedCue?.id
            cues = editor.project.cues
            cuePicker.removeAllItems()
            cuePicker.addItem(withTitle: cues.isEmpty ? "No scenes in this project" : "Choose a scene")
            cuePicker.addItems(withTitles: cues.enumerated().map { "\($0.offset + 1). \($0.element.name)" })
            cuePicker.selectItem(at: cues.firstIndex(where: { $0.id == selected }).map { $0 + 1 } ?? 0)
        } else if cuePicker.numberOfItems == 0 {
            cuePicker.addItem(withTitle: "No scenes in this project")
        }
        let session = editor.abletonLinkSession
        let connected = session.bridgeName != nil
        bridgeLabel.stringValue = session.bridgeName.map { "Bridge · \($0)" } ?? helperURL?.lastPathComponent ?? "No Link helper selected"
        bridgeLabel.toolTip = helperURL?.path
        choose.isEnabled = !connected
        connect.title = connected ? "Disconnect Link" : "Connect to Link on LAN"
        connect.isEnabled = connected || helperURL != nil
        cuePicker.isEnabled = !cues.isEmpty
        if let sample = session.observation {
            status.stringValue = "\(sample.peers) peers · "
                + String(format: "%.2f BPM · beat %.2f · phase %.2f / 4 beats", sample.tempo, sample.beat, sample.phase)
        } else {
            status.stringValue = connected ? "Waiting for Link bridge" : "Link off"
        }
        queueStatus.stringValue = session.message
        queueStatus.toolTip = session.message
        recall.isEnabled = connected && (session.observation?.peers ?? 0) > 0 && selectedCue != nil
        cancel.isEnabled = session.pendingCue != nil
    }

    private func chooseHelper() {
        let panel = NSOpenPanel()
        panel.message = "Choose the separately built aperturecue-link executable"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let executable = panel.url else { return }
        helperURL = executable
        refreshStatus()
    }

    private func toggleConnection() {
        guard let editor else { return }
        do {
            if editor.abletonLinkSession.bridgeName != nil { editor.abletonLinkSession.disconnect() }
            else if let helperURL { try editor.abletonLinkSession.connect(helperURL) }
        } catch {
            editor.showError(error)
        }
        refreshStatus()
    }

    private func queueSelectedCue() {
        guard let editor, let cue = selectedCue else { return }
        do { try editor.abletonLinkSession.queueCue(cue, document: editor.documentGeneration, project: editor.project) }
        catch { editor.showError(error) }
        refreshStatus()
    }
}
#endif
