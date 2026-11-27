#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import MappingCore

/// Small original calibration capture shared by the example command and the
/// document/editor integration test. Each slot has a diffuse three by three spot.
enum LEDScanExample {
    static let foci = [(5, 8), (26, 21), (41, 28)]

    static func capture() -> LEDScanCapture {
        let width = 48
        let height = 36
        let frames = foci.enumerated().map { order, focus -> LEDScanFrameSet in
            var before = Data()
            var flash = Data()
            var after = Data()
            for y in 0..<height {
                for x in 0..<width {
                    let baseline = 26 + (x + 2 * y) / 4
                    let dx = abs(x - focus.0)
                    let dy = abs(y - focus.1)
                    let delta = dx <= 1 && dy <= 1 ? 106 - 16 * (dx + dy) : 0
                    before.append(UInt8(baseline))
                    after.append(UInt8(baseline + 12))
                    flash.append(UInt8(baseline + 19 + delta))
                }
            }
            return LEDScanFrameSet(slot: order + 1, darkBefore: before, flash: flash, darkAfter: after)
        }
        return LEDScanCapture(width: width, height: height, frames: frames)
    }

    static func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(capture()).write(to: url, options: .withoutOverwriting)
    }
}

@MainActor private enum LEDScanPanel {
    static var busy = false
    static let queue = DispatchQueue(label: "org.aperturecue.led-scan", qos: .userInitiated)
}

extension EditorController {
    @objc func showLEDScanImport() {
        guard !LEDScanPanel.busy else { return }
        LEDScanPanel.busy = true
        let alert = NSAlert()
        alert.messageText = "LED Scan Capture"
        alert.informativeText = "Decode a file of grayscale flash frames into fixture points. Save an original example to try the scan offline."
        alert.addButton(withTitle: "Import capture…")
        alert.addButton(withTitle: "Save example…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: chooseLEDScanCapture()
        case .alertSecondButtonReturn:
            defer { LEDScanPanel.busy = false }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Original LED Scan Example.acledscan.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try LEDScanExample.save(to: url) }
            catch { showError(error) }
        default: LEDScanPanel.busy = false
        }
    }

    private func chooseLEDScanCapture() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { LEDScanPanel.busy = false; return }
        let generation = documentGeneration
        workMessage = "Decoding LED scan…"
        LEDScanPanel.queue.async { [weak self] in
            let result = Result { try LEDScanner.decode(LEDScanCapture.load(from: url)) }
            DispatchQueue.main.async { [weak self] in
                LEDScanPanel.busy = false
                guard let self, self.documentGeneration == generation else { return }
                self.workMessage = ""
                do { try self.confirmLEDScanPatch(result.get(), documentToken: generation) }
                catch { self.showError(error) }
            }
        }
    }

    private func confirmLEDScanPatch(_ result: LEDScanResult, documentToken: UUID) throws {
        let missing = result.unresolvedSlots
        guard missing.count < result.detections.count else {
            throw ProjectError.invalid("LED scan found no unambiguous slot positions")
        }
        let name = ActionField("Scanned LEDs", action: { _ in })
        let universe = ActionField("1", action: { _ in })
        let address = ActionField("1", action: { _ in })
        let order = ActionPopUp(items: ["RGB", "GRB", "RGBW"], action: { _ in })
        universe.widthAnchor.constraint(equalToConstant: 90).isActive = true
        address.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let settings = stack([label("Fixture name"), name, label("Universe / first address / color order"),
                              stack([universe, address, order], vertical: false)])
        name.widthAnchor.constraint(equalToConstant: 310).isActive = true
        settings.frame = NSRect(x: 0, y: 0, width: 320, height: max(93, settings.fittingSize.height))
        let alert = NSAlert()
        alert.messageText = "Patch decoded LED positions"
        if missing.isEmpty {
            alert.informativeText = "Found \(result.detections.count) addressed LED positions in a \(result.width) × \(result.height) capture."
        } else {
            let display = missing.prefix(12).map(String.init).joined(separator: ", ")
            let remainder = missing.count > 12 ? " and \(missing.count - 12) more" : ""
            alert.informativeText = "Unresolved slots \(display)\(remainder). Importing with gaps keeps their DMX addresses reserved and sends zero to those slots."
        }
        alert.accessoryView = settings
        alert.addButton(withTitle: missing.isEmpty ? "Add fixture" : "Add fixture with gaps")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, documentGeneration == documentToken else { return }
        guard let universeNumber = Int(universe.stringValue), let firstAddress = Int(address.stringValue) else {
            throw ProjectError.invalid("LED scan patch requires integer universe and start address")
        }
        _ = try installLEDScan(result, name: name.stringValue, universe: universeNumber, address: firstAddress,
                               channelOrder: order.titleOfSelectedItem ?? "RGB", skippingUnresolved: !missing.isEmpty)
    }

    @discardableResult
    func installLEDScan(_ result: LEDScanResult, name: String, universe: Int, address: Int,
                        channelOrder: String, skippingUnresolved: Bool = false) throws -> Fixture {
        let fixture = try result.makeFixture(name: name, universe: universe, address: address,
                                             channelOrder: channelOrder, skippingUnresolved: skippingUnresolved)
        var candidate = project
        candidate.fixtures.append(fixture)
        try ProjectStore.validate(candidate)
        mutate("Import LED scan fixture") { $0 = candidate }
        return fixture
    }
}
#endif
