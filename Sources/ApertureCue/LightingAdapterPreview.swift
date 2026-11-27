#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import MappingCore

@MainActor final class LightingAdapterPreviewController {
    private(set) var output = LightingAdapterOutput()
    private var sampledUniverses: [Int: [UInt8]] = [:]
    private var lastSampleTime: Double?
    private(set) var usbRoute: LightingAdapterRoute?
    private(set) var generation: UInt64 = 0
    private var window: LightingAdapterWindow?

    var universes: [Int: [UInt8]] {
        guard let lastSampleTime,
              ProcessInfo.processInfo.systemUptime - lastSampleTime <= LightingAdapterOutput.sourceTimeout else { return [:] }
        return sampledUniverses
    }

    func show() {
        if window == nil { window = LightingAdapterWindow(controller: self) }
        window?.showWindow(nil)
        window?.window?.makeKeyAndOrderFront(nil)
        window?.activatePreview()
    }

    func publish(_ next: [Int: [UInt8]]) {
        sampledUniverses = next
        lastSampleTime = ProcessInfo.processInfo.systemUptime
        guard let usbRoute else { return }
        output.offer((try? usbRoute.packet(in: next)) ?? BufferedDMXPro.blackout)
    }

    func startUSB(universe: Int, path: String) throws {
        guard LightingAdapterSerialSink.isDevicePath(path) else {
            throw SystemFailure(message: "Enter one concrete /dev/cu.* buffered USB adapter path")
        }
        let route = try LightingAdapterRoute(universe: universe, encoding: .bufferedDMX)
        let first = try route.packet(in: universes) ?? BufferedDMXPro.blackout
        try output.start(initial: first) { try LightingAdapterSerialSink(path: path) }
        usbRoute = route
    }

    func stopUSB(completion: (() -> Void)? = nil) {
        generation &+= 1
        usbRoute = nil
        output.stop(completion: completion)
    }

    /// Called by shared Stop, document replacement and app termination.
    func stop(completion: (() -> Void)? = nil) {
        sampledUniverses.removeAll()
        lastSampleTime = nil
        stopUSB(completion: completion)
        window?.refreshPreview()
    }
}

@MainActor private final class LightingAdapterWindow: NSWindowController, NSWindowDelegate {
    private weak var controller: LightingAdapterPreviewController?
    private var timer: Timer?
    private let status = label("USB output stopped")
    private let packetDetail = label("")
    private let packetBytes = NSTextView()
    private var mode: ActionPopUp!
    private var universe: ActionField!
    private var address: ActionField!
    private var pixels: ActionField!
    private var openButton: ActionButton!
    private var stopButton: ActionButton!
    private var exportButton: ActionButton!
    private var renderedPacket: Data?

    init(controller: LightingAdapterPreviewController) {
        self.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 352),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Lighting Adapters"
        window.contentMinSize = NSSize(width: 620, height: 310)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        guard let content = window.contentView else { return }
        mode = ActionPopUp(items: ["Buffered USB DMX", "SPI RGB payload"], action: { [weak self] _ in self?.refreshPreview() })
        universe = ActionField("1", action: { [weak self] _ in self?.refreshPreview() })
        address = ActionField("1", action: { [weak self] _ in self?.refreshPreview() })
        pixels = ActionField("15", action: { [weak self] _ in self?.refreshPreview() })
        for field in [universe!, address!, pixels!] { field.widthAnchor.constraint(equalToConstant: 56).isActive = true }
        let controls = stack([mode, label("Universe"), universe, label("SPI start"), address, label("Pixels"), pixels], vertical: false)
        packetBytes.isEditable = false
        packetBytes.isSelectable = true
        packetBytes.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        packetBytes.isVerticallyResizable = true
        packetBytes.isHorizontallyResizable = false
        packetBytes.autoresizingMask = [.width]
        packetBytes.textContainer?.widthTracksTextView = true
        let viewport = NSScrollView()
        viewport.documentView = packetBytes
        viewport.hasVerticalScroller = true
        viewport.borderType = .bezelBorder
        packetBytes.frame = NSRect(x: 0, y: 0, width: 660, height: 180)
        openButton = ActionButton("Start USB output…") { [weak self] in self?.chooseUSBDevice() }
        stopButton = ActionButton("Stop USB output") { [weak self] in self?.controller?.stopUSB(); self?.refreshPreview() }
        exportButton = ActionButton("Export bytes…") { [weak self] in self?.export() }
        let actions = stack([exportButton, openButton, stopButton], vertical: false)
        let rows = stack([controls, status, packetDetail, viewport, actions])
        fill(rows, in: content, inset: 14)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        viewport.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        viewport.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        status.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        refreshPreview()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func activatePreview() {
        refreshPreview()
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPreview() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        controller?.stopUSB()
    }

    private func selectedRoute() throws -> LightingAdapterRoute {
        guard let number = Int(universe.stringValue) else { throw ProjectError.invalid("adapter universe must be an integer") }
        let encoding: LightingAdapterEncoding
        if mode.indexOfSelectedItem == 0 {
            encoding = .bufferedDMX
        } else {
            guard let start = Int(address.stringValue), let count = Int(pixels.stringValue) else {
                throw ProjectError.invalid("SPI start address and pixel count must be integers")
            }
            encoding = .spiRGB(firstAddress: start, pixels: count)
        }
        return try LightingAdapterRoute(universe: number, encoding: encoding)
    }

    func refreshPreview() {
        guard let controller else { return }
        let usbMode = mode.indexOfSelectedItem == 0
        address.isEnabled = !usbMode
        pixels.isEnabled = !usbMode
        switch controller.output.status {
        case .stopped:
            status.stringValue = "USB output stopped • virtual preview"
            openButton.isEnabled = usbMode
            stopButton.isEnabled = false
        case .opening:
            status.stringValue = "Opening selected buffered USB endpoint…"
            openButton.isEnabled = false
            stopButton.isEnabled = true
        case .active:
            let port = controller.usbRoute.map { String($0.universe) } ?? "—"
            status.stringValue = "USB output active • universe \(port) • \(controller.output.sentCount) frame writes"
            openButton.isEnabled = false
            stopButton.isEnabled = true
        case .stopping:
            status.stringValue = "Closing USB output…"
            openButton.isEnabled = false
            stopButton.isEnabled = false
        case .failed(let description):
            status.stringValue = description
            status.toolTip = description
            openButton.isEnabled = usbMode
            stopButton.isEnabled = false
        }
        let packet: Data?
        do {
            let route = try selectedRoute()
            packet = try route.packet(in: controller.universes)
            if let packet { packetDetail.stringValue = "Virtual bytes • \(packet.count) bytes • universe \(route.universe)" }
            else { packetDetail.stringValue = "No sampled frame for universe \(route.universe)" }
        } catch {
            packetDetail.stringValue = error.localizedDescription
            packet = nil
        }
        exportButton.isEnabled = packet != nil
        if packet != renderedPacket {
            renderedPacket = packet
            packetBytes.string = packet.map(Self.hexDump) ?? ""
        }
    }

    private static func hexDump(_ data: Data) -> String {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: 16).map { start in
            let line = bytes[start..<min(bytes.count, start + 16)].map { String(format: "%02X", $0) }.joined(separator: " ")
            return String(format: "%04X  ", start) + line
        }.joined(separator: "\n")
    }

    private func export() {
        guard let controller else { return }
        do {
            let route = try selectedRoute()
            guard let data = try route.packet(in: controller.universes) else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
            panel.nameFieldStringValue = route.encoding == .bufferedDMX ? "Buffered DMX frame.bin" : "SPI RGB payload.bin"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .withoutOverwriting)
        } catch { showError(error) }
    }

    private func chooseUSBDevice() {
        guard let controller else { return }
        let generation = controller.generation
        do {
            let route = try selectedRoute()
            guard route.encoding == .bufferedDMX else { return }
            let path = ActionField("", action: { _ in })
            path.placeholderString = "/dev/cu.usbserial-…"
            path.frame = NSRect(x: 0, y: 0, width: 400, height: 28)
            let alert = NSAlert()
            alert.messageText = "Start Buffered USB DMX Output"
            alert.informativeText = "Select the exact macOS callout path of your buffered DMX-Pro adapter. After Start, universe \(route.universe) is sent to the connected equipment. Stop attempts a zero frame before the port closes."
            alert.accessoryView = path
            alert.addButton(withTitle: "Start USB output")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn, window?.isVisible == true,
                  controller.generation == generation else { return }
            try controller.startUSB(universe: route.universe, path: path.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            refreshPreview()
        } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
#endif
