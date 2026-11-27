#if os(macOS)
import AppKit
import MappingCore

@MainActor final class LightingMonitorWindow: NSWindowController, NSWindowDelegate {
    private weak var lighting: LightingController?
    private let source = ActionPopUp(items: ["Engine output", "Incoming UDP"], action: { _ in })
    private let displayedUniverse = ActionPopUp(items: [], action: { _ in })
    private let inputWire = ActionPopUp(items: ["Art-Net", "sACN"], action: { _ in })
    private let inputUniverse = ActionField("1", action: { _ in })
    private let inputPort = ActionField("16454", action: { _ in })
    private let channelNumber = ActionField("1", action: { _ in })
    private let start = ActionButton("Receive", action: {})
    private let stop = ActionButton("Stop reception", action: {})
    private let route = ActionButton("Route to armed output", action: {})
    private let readout = label("")
    private let receiveStatus = label("")
    private let routingStatus = label("")
    private let grid = DMXSlotGrid(frame: .zero)
    private var universes: [Int] = []
    private var receiverPort: UInt16?
    private var message = ""

    init(lighting: LightingController) {
        self.lighting = lighting
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 570),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "ApertureCue · DMX Monitor"
        window.minSize = NSSize(width: 750, height: 530)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        for field in [inputUniverse, inputPort, channelNumber] {
            field.widthAnchor.constraint(equalToConstant: 68).isActive = true
        }
        displayedUniverse.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        source.actionBlock = { [weak self] _ in self?.update() }
        displayedUniverse.actionBlock = { [weak self] _ in self?.update() }
        channelNumber.actionBlock = { [weak self] _ in self?.update() }
        start.actionBlock = { [weak self] in self?.startListening() }
        stop.actionBlock = { [weak self] in self?.stopListening() }
        route.actionBlock = { [weak self] in self?.toggleRoute() }

        let sources = stack([source, label("Universe"), displayedUniverse, label("Slot"), channelNumber, readout],
                            vertical: false)
        let receiver = stack([inputWire, label("Universe"), inputUniverse, label("Local UDP port"), inputPort,
                              start, stop], vertical: false)
        let output = stack([route, routingStatus], vertical: false)
        let body = stack([sources, grid, NSBox(), receiver, receiveStatus, output], spacing: 9)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        grid.heightAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
        for status in [readout, receiveStatus, routingStatus] {
            status.lineBreakMode = .byTruncatingTail
            status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        if let content = window.contentView { fill(body, in: content, inset: 14) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { stopListening() }

    func update(at time: Double = ProcessInfo.processInfo.systemUptime) {
        guard let lighting, let window, window.isVisible else { return }
        let active = lighting.monitorInput.listenUniverse
        let snapshot = lighting.monitorInput.snapshot(at: time)
        let incoming = source.indexOfSelectedItem == 1
        let frames = incoming ? snapshot.frame.map { [$0.universe: $0.channels] } ?? [:] : lighting.lastUniverses
        let newUniverses = frames.keys.sorted()
        if newUniverses != universes || displayedUniverse.numberOfItems == 0 {
            let previous = universes.indices.contains(displayedUniverse.indexOfSelectedItem)
                ? universes[displayedUniverse.indexOfSelectedItem] : nil
            universes = newUniverses
            displayedUniverse.removeAllItems()
            displayedUniverse.addItems(withTitles: universes.isEmpty ? ["None"] : universes.map(String.init))
            displayedUniverse.selectItem(at: previous.flatMap { universes.firstIndex(of: $0) } ?? 0)
        }
        displayedUniverse.isEnabled = !universes.isEmpty
        let index = displayedUniverse.indexOfSelectedItem
        let channels = universes.indices.contains(index) ? frames[universes[index]] ?? [] : []
        if grid.channels != channels { grid.channels = channels }
        let slot = Int(channelNumber.stringValue).flatMap { (1...512).contains($0) ? $0 : nil }
        if let slot, channels.indices.contains(slot - 1) {
            let value = channels[slot - 1]
            set(readout, String(format: "%d   0x%02X", Int(value), Int(value)))
        } else {
            set(readout, "—")
        }
        let routing = lighting.isRoutingIncoming
        route.title = routing ? "End route" : "Route to armed output"
        route.isEnabled = routing || (lighting.canRouteIncoming && active != nil)
        set(routingStatus, message.isEmpty ? (routing ? "Incoming universe owns network output" : "Route off") : message)
        if let active {
            let state = snapshot.isStale ? "timed out" : (snapshot.frame == nil ? "waiting for frame" : "receiving")
            let port = receiverPort.map { String($0) } ?? inputPort.stringValue
            set(receiveStatus, "127.0.0.1:\(port) · universe \(active) · \(state) · \(snapshot.received) accepted · \(snapshot.discarded) ignored")
        } else {
            receiverPort = nil
            set(receiveStatus, "Receiver stopped")
        }
        for input: NSControl in [inputWire, inputUniverse, inputPort] { input.isEnabled = active == nil }
        start.isEnabled = active == nil
        stop.isEnabled = active != nil
    }

    private func startListening() {
        guard let lighting, let port = UInt16(inputPort.stringValue), port != 0,
              let universe = Int(inputUniverse.stringValue) else {
            message = "Enter a numeric UDP port and universe."
            update()
            return
        }
        do {
            let wire: LightingController.WireProtocol = inputWire.indexOfSelectedItem == 0 ? .artnet : .sacn
            receiverPort = try lighting.monitorInput.start(port: port, universe: universe, wire: wire)
            source.selectItem(at: 1)
            message = ""
        } catch {
            message = error.localizedDescription
        }
        update()
    }

    private func stopListening() {
        lighting?.stopRoutingIncoming()
        lighting?.monitorInput.stop()
        message = ""
        update()
    }

    private func toggleRoute() {
        do {
            if lighting?.isRoutingIncoming == true { lighting?.stopRoutingIncoming() }
            else { try lighting?.routeIncoming() }
            message = ""
        } catch { message = error.localizedDescription }
        update()
    }

    private func set(_ control: NSTextField, _ value: String) {
        if control.stringValue != value { control.stringValue = value; control.toolTip = value }
    }
}

private final class DMXSlotGrid: NSView {
    var channels: [UInt8] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        let columns = 32
        let rows = 16
        let stepX = bounds.width / CGFloat(columns)
        let stepY = bounds.height / CGFloat(rows)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                                                         .foregroundColor: NSColor.labelColor]
        for index in 0..<512 {
            let x = CGFloat(index % columns) * stepX
            let y = CGFloat(index / columns) * stepY
            let cell = NSRect(x: x, y: y, width: stepX, height: stepY)
            guard cell.intersects(dirtyRect) else { continue }
            let level = channels.indices.contains(index) ? CGFloat(channels[index]) / 255 : 0
            NSColor.controlBackgroundColor.setFill()
            cell.insetBy(dx: 1, dy: 1).fill()
            NSColor.systemCyan.withAlphaComponent(0.18 + 0.62 * level).setFill()
            NSRect(x: x + 2, y: y + stepY - 5, width: max(0, stepX - 4) * level, height: 3).fill()
            (String(index + 1) as NSString).draw(at: NSPoint(x: x + 2, y: y + 2), withAttributes: attributes)
        }
    }
}
#endif
