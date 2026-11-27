#if os(macOS)
import AppKit
import MappingCore

@MainActor final class LightingNetworkWindow: NSWindowController {
    private weak var lighting: LightingController?
    private let mode: ActionPopUp
    private let address: ActionField
    private let rate: ActionField
    private let syncAddress: ActionField
    private let firstUniverse = ActionField("1", action: { _ in })
    private let lastUniverse = ActionField("16", action: { _ in })
    private let status = label("")
    private let probeButton = ActionButton("Check Art-Net node", action: {})
    private let reply = NSTextView(frame: .zero)

    init(lighting: LightingController) {
        self.lighting = lighting
        let index = lighting.wireProtocol == .artnet ? 0 : (lighting.multicast ? 2 : 1)
        mode = ActionPopUp(items: ["Art-Net unicast", "sACN unicast", "sACN multicast"], selected: index, action: { _ in })
        address = ActionField(lighting.destination, action: { _ in })
        rate = ActionField(String(lighting.maximumRateHz), action: { _ in })
        syncAddress = ActionField(String(lighting.synchronizationAddress), action: { _ in })

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "ApertureCue · Lighting network"
        window.minSize = NSSize(width: 570, height: 380)
        window.isReleasedWhenClosed = false
        window.center()

        address.widthAnchor.constraint(equalToConstant: 215).isActive = true
        for field in [rate, syncAddress, firstUniverse, lastUniverse] {
            field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        }

        let start = ActionButton("Start network output") { [weak self] in self?.start() }
        let stop = ActionButton("Stop network output") { [weak self] in self?.lighting?.stop() }
        mode.actionBlock = { [weak self] _ in self?.updateStatus() }
        probeButton.actionBlock = { [weak self] in self?.probe() }

        reply.isEditable = false
        reply.isSelectable = true
        reply.isHorizontallyResizable = false
        reply.isVerticallyResizable = true
        reply.textContainer?.widthTracksTextView = true
        reply.textContainerInset = NSSize(width: 6, height: 6)
        reply.autoresizingMask = [.width]
        reply.string = "Check the IPv4 address of an Art-Net node to view the advertised ports."

        let outputRow = stack([mode, label("IPv4 address"), address], vertical: false)
        let rateRow = stack([label("Maximum Hz"), rate, label("Sync universe (0 = off)"), syncAddress], vertical: false)
        let buttonRow = stack([start, stop], vertical: false)
        let probeRow = stack([label("Art-Net range"), firstUniverse, lastUniverse, probeButton], vertical: false)
        let details = scroll(reply, height: 160)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let body = stack([outputRow, rateRow, buttonRow, status, probeRow, details], spacing: 13)
        status.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        details.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        if let content = window.contentView { fill(body, in: content, inset: 16) }
        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateStatus() {
        guard let lighting else { return }
        let next = lighting.errorDescription.isEmpty
            ? (lighting.isSending ? "Network output active · \(lighting.wireProtocol.rawValue)" : "Network output stopped")
            : lighting.errorDescription
        if status.stringValue != next { status.stringValue = next; status.toolTip = next }
        let artNet = mode.indexOfSelectedItem == 0
        address.isEnabled = mode.indexOfSelectedItem != 2
        syncAddress.isEnabled = !artNet
        firstUniverse.isEnabled = artNet
        lastUniverse.isEnabled = artNet
        probeButton.isEnabled = artNet && !lighting.discoveryInFlight
    }

    private func start() {
        guard let lighting else { return }
        do {
            let artNet = mode.indexOfSelectedItem == 0
            guard let hertz = Double(rate.stringValue),
                  let synchronization = artNet ? 0 : Int(syncAddress.stringValue) else {
                throw SystemFailure(message: "Enter a number for output Hz and the sync universe")
            }
            let target = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            try lighting.startNetworkOutput(mode: artNet ? .artnet : .sacn, address: target,
                                            multicast: mode.indexOfSelectedItem == 2,
                                            synchronizationAddress: synchronization, maximumRateHz: hertz)
            updateStatus()
        } catch { status.stringValue = error.localizedDescription }
    }

    private func probe() {
        guard let lighting else { return }
        let target = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = Int(firstUniverse.stringValue), let last = Int(lastUniverse.stringValue),
              (0...32767).contains(first), (first...32767).contains(last) else {
            reply.string = "Enter an inclusive range of Art-Net Port-Addresses (0…32767)."
            return
        }
        do {
            try lighting.discoverArtNet(address: target, range: first...last) { [weak self] result in
                guard let self else { return }
                self.updateStatus()
                switch result {
                case .failure(let failure): self.reply.string = failure.localizedDescription
                case .success(let nodes) where nodes.isEmpty:
                    self.reply.string = "No matching ArtPollReply from \(target). Check the node's address and range, then retry."
                case .success(let nodes):
                    self.reply.string = nodes.map { node in
                        let name = node.longName.isEmpty ? node.shortName : node.longName
                        let addresses = node.subscriptions.sorted().map(String.init).joined(separator: ", ")
                        return "\(node.advertisedAddress) · binding \(node.bindingIndex) · \(name)\nPort-Addresses \(addresses) · advertised limit \(node.refreshRateHz) Hz"
                    }.joined(separator: "\n\n")
                }
            }
            reply.string = "Waiting for targeted reply from \(target)…"
            updateStatus()
        } catch { reply.string = error.localizedDescription }
    }
}
#endif
