#if os(macOS)
import AppKit
import Metal
import MappingCore

@MainActor final class ExternalVideoSession {
    private struct Cached {
        let producer: UUID
        let sequence: UInt64
        let texture: MTLTexture
    }

    let device: MTLDevice
    let black: MTLTexture?
    private var worker: ExternalVideoWorker?
    private var selected: Set<String> = []
    private var frames: [String: Cached] = [:]
    private(set) var observedNames: [String] = []
    private(set) var directory: URL?
    weak var window: ExternalVideoWindow?

    init(device: MTLDevice) {
        self.device = device
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        black = device.makeTexture(descriptor: description)
        var pixel: UInt32 = 0xFF000000
        if let black { withUnsafeBytes(of: &pixel) { if let address = $0.baseAddress {
            black.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: address, bytesPerRow: 4)
        } } }
    }

    @discardableResult func start() throws -> URL {
        if let directory { return directory }
        let root = try ExternalVideoInbox.create()
        directory = root
        let worker = ExternalVideoWorker(root: root)
        worker.observe(selected)
        self.worker = worker
        window?.reflectSession()
        return root
    }

    func stop() {
        worker?.stop()
        worker = nil
        directory = nil
        frames.removeAll()
        observedNames.removeAll()
        window?.reflectSession()
    }

    func bind(_ assets: [MediaAsset]) {
        let names = Set(assets.lazy.filter { $0.kind == "external-video" }.map(\.path))
        guard names != selected else { return }
        selected = names
        worker?.observe(names)
        frames = frames.filter { names.contains($0.key) }
    }

    func isReceiving(_ name: String) -> Bool { frames[name] != nil }

    @discardableResult func update(at now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let worker else { return false }
        let snapshot = worker.snapshot()
        let previous = Set(frames.keys)
        frames = frames.filter {
            guard let live = snapshot.frames[$0.key] else { return false }
            return now - live.arrivedAt < ExternalFrameOrder.timeout
        }
        var changed = frames.count != previous.count
        for (name, input) in snapshot.frames where selected.contains(name) && now - input.arrivedAt < ExternalFrameOrder.timeout {
            let frame = input.frame
            let current = frames[name]
            guard current?.producer != frame.producer || current?.sequence != frame.sequence else { continue }
            let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                       width: frame.width, height: frame.height,
                                                                       mipmapped: false)
            description.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: description) else {
                changed = frames.removeValue(forKey: name) != nil || changed
                continue
            }
            frame.bgra.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                texture.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0,
                                withBytes: base, bytesPerRow: frame.bytesPerRow)
            }
            frames[name] = Cached(producer: frame.producer, sequence: frame.sequence, texture: texture)
            changed = true
        }
        if observedNames != snapshot.names || Set(frames.keys) != previous {
            observedNames = snapshot.names
            window?.reflectSession()
        }
        return changed
    }

    func texture(for name: String) -> MTLTexture? { frames[name]?.texture ?? black }
}

@MainActor extension EditorController {
    @objc func showProjectorControl() {
        let controller = projectorWindow ?? PJLinkWindowController()
        projectorWindow = controller
        controller.present()
    }

    @objc func showExternalVideo() {
        let panel = externalVideoWindow ?? ExternalVideoWindow(editor: self, session: externalVideo)
        externalVideoWindow = panel
        externalVideo.window = panel
        panel.reflectSession()
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
    }

    @discardableResult func addExternalVideo(_ name: String, assign: Bool) throws -> UUID {
        let existing = project.assets.first { $0.kind == "external-video" && $0.path == name }
        let asset = existing ?? MediaAsset(name: "Live · " + name, path: name, kind: "external-video", loop: false, volume: 0)
        var candidate = project
        if existing == nil { candidate.assets.append(asset) }
        if assign, let selectedIndex {
            candidate.surfaces[selectedIndex].mediaID = asset.id
            candidate.surfaces[selectedIndex].feedbackOutputID = nil
        }
        try ProjectStore.validate(candidate)
        mutate("External video source") { $0 = candidate }
        selectedMediaID = asset.id
        refresh()
        return asset.id
    }
}

@MainActor final class ExternalVideoWindow: NSWindowController {
    private weak var editor: EditorController?
    private weak var session: ExternalVideoSession?
    private let feedPicker = ActionPopUp(items: [], action: { _ in })
    private let status = label("")
    private let path = NSTextField(labelWithString: "")
    private let start = ActionButton("Start local inbox", action: {})
    private let copy = ActionButton("Copy inbox path", action: {})
    private let attach = ActionButton("Add feed to Media", action: {})
    private let stop = ActionButton("Stop inbox", action: {})
    private let assign = NSButton(checkboxWithTitle: "Assign to selected surface", target: nil, action: nil)
    private var known: [String] = []

    init(editor: EditorController, session: ExternalVideoSession) {
        self.editor = editor
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 246), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "ApertureCue · External Video"
        window.contentMinSize = NSSize(width: 660, height: 224)
        window.isReleasedWhenClosed = false
        window.center()
        start.actionBlock = { [weak self] in
            do { try self?.session?.start() }
            catch { self?.editor?.showError(error) }
        }
        stop.actionBlock = { [weak self] in self?.session?.stop(); self?.editor?.updateRender() }
        copy.actionBlock = { [weak self] in
            guard let value = self?.session?.directory else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value.path, forType: .string)
        }
        attach.actionBlock = { [weak self] in
            guard let self, known.indices.contains(feedPicker.indexOfSelectedItem) else { return }
            do {
                try self.editor?.addExternalVideo(known[feedPicker.indexOfSelectedItem], assign: assign.state == .on)
                reflectSession()
            } catch { self.editor?.showError(error) }
        }
        feedPicker.actionBlock = { [weak self] _ in self?.reflectSession() }
        path.isSelectable = true
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        feedPicker.widthAnchor.constraint(equalToConstant: 220).isActive = true
        assign.state = .on
        let help = NSTextField(wrappingLabelWithString: "Start an inbox and pass the path to a local frame producer. Choose its feed to use it as a media source.")
        help.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let body = stack([help, stack([start, stop, copy], vertical: false), path,
                          stack([feedPicker, attach, assign], vertical: false), status], spacing: 12)
        path.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        if let content = window.contentView { fill(body, in: content, inset: 16) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func reflectSession() {
        guard let session else { return }
        let old = known.indices.contains(feedPicker.indexOfSelectedItem) ? known[feedPicker.indexOfSelectedItem] : nil
        if known != session.observedNames || feedPicker.numberOfItems == 0 {
            known = session.observedNames
            feedPicker.removeAllItems()
            feedPicker.addItems(withTitles: known.isEmpty ? ["No feeds found"] : known)
            feedPicker.selectItem(at: old.flatMap { known.firstIndex(of: $0) } ?? 0)
        }
        let running = session.directory != nil
        path.stringValue = session.directory?.path ?? "Inbox stopped"
        path.toolTip = session.directory?.path
        start.isEnabled = !running
        stop.isEnabled = running
        copy.isEnabled = running
        feedPicker.isEnabled = running && !known.isEmpty
        attach.isEnabled = feedPicker.isEnabled
        if known.indices.contains(feedPicker.indexOfSelectedItem) {
            let name = known[feedPicker.indexOfSelectedItem]
            status.stringValue = session.isReceiving(name) ? "Receiving \(name)" : "\(name) · attach to receive"
        } else {
            status.stringValue = running ? "Waiting for a local producer" : "Saved feeds stay off until you start an inbox"
        }
    }
}
#endif
