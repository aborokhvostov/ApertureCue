#if os(macOS)
import AppKit
import MappingCore
import UniformTypeIdentifiers

@MainActor final class DMXSequenceWindow: NSWindowController, NSWindowDelegate {
    private weak var session: DMXSequenceSession?
    private let record = ActionButton("Record live", action: {})
    private let open = ActionButton("Open…", action: {})
    private let save = ActionButton("Save as…", action: {})
    private let play = ActionButton("Play preview", action: {})
    private let send = ActionButton("Play to armed output", action: {})
    private let stop = ActionButton("Stop replay", action: {})
    private let seek = ActionSlider(value: 0, min: 0, max: 1, action: { _ in })
    private let file = label("", bold: true)
    private let status = label("")
    private let time = label("")
    private let universePicker = ActionPopUp(items: [], action: { _ in })
    private let raw = NSTextView()
    private var universes: [Int] = []
    private var lastRender: RenderKey?

    private struct RenderKey: Equatable {
        let generation: UInt64
        let frame: Int?
        let universe: Int?
    }

    init(session: DMXSequenceSession) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 440),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "ApertureCue · DMX Sequence"
        window.minSize = NSSize(width: 620, height: 350)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        build()
        bind()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func windowWillClose(_ notification: Notification) { session?.windowWasClosed() }

    private func build() {
        guard let content = window?.contentView else { return }
        raw.isEditable = false
        raw.isSelectable = true
        raw.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        raw.textContainerInset = NSSize(width: 8, height: 8)
        raw.isVerticallyResizable = true
        raw.autoresizingMask = [.width]
        raw.textContainer?.widthTracksTextView = true
        let rawScroll = scroll(raw)
        rawScroll.borderType = .bezelBorder
        rawScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        rawScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let toolbar = stack([record, open, save], vertical: false)
        let transport = stack([play, send, stop], vertical: false)
        let timeline = stack([seek, time], vertical: false)
        let monitor = stack([label("Raw slots"), universePicker], vertical: false)
        let rows = stack([toolbar, file, transport, timeline, status, monitor, rawScroll])
        for row in rows.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        for line in [file, status] {
            line.lineBreakMode = .byTruncatingTail
            line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        fill(rows, in: content, inset: 16)
    }

    private func bind() {
        record.actionBlock = { [weak self] in
            self?.perform { session in
                if session.isRecording { session.finishCapture() }
                else { try session.startCapture() }
            }
        }
        open.actionBlock = { [weak self] in self?.openPanel() }
        save.actionBlock = { [weak self] in self?.savePanel() }
        play.actionBlock = { [weak self] in self?.perform { try $0.play(network: false) } }
        send.actionBlock = { [weak self] in self?.perform { try $0.play(network: true) } }
        stop.actionBlock = { [weak self] in self?.session?.stopPlayback() }
        seek.actionBlock = { [weak self] value in self?.perform { try $0.seek(to: value) } }
        universePicker.actionBlock = { [weak self] _ in self?.updatePreview() }
    }

    func refresh() {
        guard let session else { return }
        let idle = !session.isBusy && !session.isPlaying
        let fileActions = idle && !session.isRecording
        record.title = session.isRecording ? "Finish recording" : "Record live"
        record.isEnabled = idle
        open.isEnabled = fileActions
        save.isEnabled = fileActions && session.sequence != nil
        play.isEnabled = fileActions && session.sequence != nil
        send.isEnabled = play.isEnabled && session.networkReady
        stop.isEnabled = session.isPlaying
        seek.isEnabled = session.sequence != nil && !session.isRecording && !session.isBusy
        let duration = Double(session.sequence?.durationMicroseconds ?? 0) / 1_000_000
        let elapsed = Double(session.player?.microseconds ?? 0) / 1_000_000
        seek.maxValue = max(duration, 0.000_001)
        seek.doubleValue = elapsed
        time.stringValue = String(format: "%.3f / %.3f s", elapsed, duration)
        file.stringValue = session.fileName ?? (session.sequence != nil ? "Unsaved DMX sequence" : "No sequence open")
        status.stringValue = session.isRecording ? "Recording · \(session.captureCount) changed snapshot(s)" : session.status
        updateUniverses(session.sequence?.universeIDs ?? [])
        updatePreview()
    }

    private func updateUniverses(_ ids: Set<Int>) {
        let next = ids.sorted()
        guard universes != next || universePicker.itemArray.isEmpty else { return }
        let selected = selectedUniverse
        universes = next
        universePicker.removeAllItems()
        universePicker.addItems(withTitles: next.isEmpty ? ["No universe"] : next.map { "Universe \($0)" })
        universePicker.selectItem(at: next.firstIndex(where: { $0 == selected }) ?? 0)
        universePicker.isEnabled = !next.isEmpty
    }

    private var selectedUniverse: Int? {
        let index = universePicker.indexOfSelectedItem
        return universes.indices.contains(index) ? universes[index] : nil
    }

    private func updatePreview() {
        guard let session else { return }
        let frame = session.player?.current.frameIndex
        let universe = selectedUniverse
        let key = RenderKey(generation: session.sequenceGeneration, frame: frame, universe: universe)
        guard key != lastRender else { return }
        lastRender = key
        guard let frame, let universe, let slots = session.sequence?.frames[frame].universes[universe] else {
            raw.string = session.sequence == nil ? "" : "No active slots at this time."
            return
        }
        let columns = 16
        var lines: [String] = []
        for start in stride(from: 0, to: slots.count, by: columns) {
            let end = min(slots.count, start + columns)
            let values = slots[start..<end].map { String(format: "%3d", Int($0)) }.joined(separator: " ")
            lines.append(String(format: "%03d  %@", start + 1, values))
        }
        raw.string = lines.joined(separator: "\n")
    }

    private func perform(_ operation: (DMXSequenceSession) throws -> Void) {
        guard let session else { return }
        do { try operation(session) }
        catch { session.showError(error) }
    }

    private var fileType: UTType { UTType(filenameExtension: DMXSequence.fileExtension) ?? .data }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [fileType]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { session?.load(from: url) }
    }

    private func savePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [fileType]
        panel.nameFieldStringValue = session?.fileName ?? "Recording.acdmx"
        if panel.runModal() == .OK, let url = panel.url {
            let chosen = url.pathExtension.isEmpty ? url.appendingPathExtension(DMXSequence.fileExtension) : url
            session?.save(to: chosen)
        }
    }
}
#endif
