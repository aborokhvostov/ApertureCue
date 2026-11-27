#if os(macOS)
import AppKit
import MappingCore

@MainActor final class FirmataWindow: NSWindowController, NSWindowDelegate {
    private struct Route {
        let ticket: UUID
        let input: FirmataInput
        let surfaceID: UUID?
        let parameter: String
    }

    private static let parameterNames = ["opacity", "brightness", "gamma", "red", "green", "blue"]
    private weak var editor: EditorController?
    private let documentID: UUID
    private lazy var adapter = FirmataSerialAdapter { [weak self] update in self?.receive(update) }
    private var controlsBoard: FirmataBoard?
    private var route: Route?
    private var lastRoutedSample: FirmataSample?
    private var connecting = false
    private var disablingInput = false
    private var awaitingOutput = false
    private var targets: [UUID?] = []
    private var inputs: [FirmataInput] = []
    private var outputs: [Int] = []
    private(set) var connectionState = FirmataAdapterSnapshot()

    private let path = NSTextField(string: "")
    private let connectButton = ActionButton("Connect", action: {})
    private let disconnectButton = ActionButton("Disconnect", action: {})
    private let startInputButton = ActionButton("Start Input", action: {})
    private let stopInputButton = ActionButton("Stop Input", action: {})
    private let sendButton = ActionButton("Write Pin", action: {})
    private let inputPicker = ActionPopUp(items: [], action: { _ in })
    private let outputPicker = ActionPopUp(items: [], action: { _ in })
    private let surfacePicker = ActionPopUp(items: [], action: { _ in })
    private let parameterPicker = ActionPopUp(items: FirmataWindow.parameterNames.map { $0.capitalized }, action: { _ in })
    private let levelPicker = ActionPopUp(items: ["LOW", "HIGH"], action: { _ in })
    private let status = label("")
    private let inputValue = label("")
    private let outputValue = label("")

    init(editor: EditorController) {
        self.editor = editor
        documentID = editor.documentGeneration
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 634, height: 320),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "ApertureCue · Arduino / Firmata"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        build(in: window.contentView)
        bind()
        refreshTargets()
        refreshControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func windowWillClose(_ notification: Notification) { shutDown() }

    func shutDown() {
        route = nil
        lastRoutedSample = nil
        connecting = false
        disablingInput = false
        awaitingOutput = false
        adapter.disconnect()
    }

    func refreshTargets() {
        guard let editor else { return }
        let selected = targets.indices.contains(surfacePicker.indexOfSelectedItem)
            ? targets[surfacePicker.indexOfSelectedItem] : nil
        let surfaces = editor.project.surfaces
        targets = [nil] + surfaces.map { Optional($0.id) }
        surfacePicker.removeAllItems()
        surfacePicker.addItem(withTitle: "Monitor only")
        for surface in surfaces {
            surfacePicker.menu?.addItem(NSMenuItem(title: surface.name, action: nil, keyEquivalent: ""))
        }
        surfacePicker.selectItem(at: targets.firstIndex(of: selected) ?? 0)
        refreshControls()
    }

    /// The integration fixture takes this route through the same adapter and editor dispatch.
    func connectVirtual(owning descriptor: Int32) {
        connecting = true
        refreshControls()
        adapter.connectVirtual(owning: descriptor)
    }

    func startInput(_ input: FirmataInput, surfaceID: UUID?, parameter: String) {
        let ticket = UUID()
        route = Route(ticket: ticket, input: input, surfaceID: surfaceID, parameter: parameter)
        lastRoutedSample = nil
        adapter.configureInput(input, ticket: ticket)
        refreshControls()
    }

    func stopInput() {
        route = nil
        lastRoutedSample = nil
        disablingInput = true
        adapter.configureInput(nil, ticket: nil)
        refreshControls()
    }

    func writeOutput(pin: Int, high: Bool) {
        awaitingOutput = true
        refreshControls()
        adapter.writeDigital(pin: pin, high: high)
    }

    private func build(in content: NSView?) {
        guard let content else { return }
        path.placeholderString = "/dev/cu.…"
        path.setAccessibilityLabel("Firmata serial device path")
        path.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        inputPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 122).isActive = true
        surfacePicker.widthAnchor.constraint(equalToConstant: 167).isActive = true
        outputPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 122).isActive = true
        inputPicker.setAccessibilityLabel("Firmata input pin")
        outputPicker.setAccessibilityLabel("Firmata output pin")
        surfacePicker.setAccessibilityLabel("Input target surface")
        parameterPicker.setAccessibilityLabel("Input target parameter")
        levelPicker.setAccessibilityLabel("Digital output level")

        let endpoint = stack([label("Serial device"), path, connectButton, disconnectButton], vertical: false)
        let inputSettings = stack([inputPicker, surfacePicker, parameterPicker], vertical: false)
        let inputActions = stack([startInputButton, stopInputButton, inputValue], vertical: false)
        let outputSettings = stack([outputPicker, levelPicker, sendButton, outputValue], vertical: false)
        let inputSeparator = NSBox()
        inputSeparator.boxType = .separator
        let outputSeparator = NSBox()
        outputSeparator.boxType = .separator
        let body = stack([endpoint, status, inputSeparator, label("Input", bold: true),
                          inputSettings, inputActions, outputSeparator, label("Digital Output", bold: true), outputSettings], spacing: 10)
        for line in [status, inputValue, outputValue] {
            line.lineBreakMode = .byTruncatingTail
            line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for row in body.arrangedSubviews { row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        fill(body, in: content, inset: 16)
    }

    private func bind() {
        connectButton.actionBlock = { [weak self] in
            guard let self else { return }
            let value = self.path.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard LightingAdapterSerialSink.isDevicePath(value) else {
                self.setStatus("Enter the explicit /dev/cu.* path of the Firmata device.")
                return
            }
            self.connecting = true
            self.setStatus("Opening selected serial device…")
            self.adapter.connect(path: value)
            self.refreshControls()
        }
        disconnectButton.actionBlock = { [weak self] in self?.shutDown() }
        startInputButton.actionBlock = { [weak self] in
            guard let self, self.inputs.indices.contains(self.inputPicker.indexOfSelectedItem),
                  self.targets.indices.contains(self.surfacePicker.indexOfSelectedItem),
                  Self.parameterNames.indices.contains(self.parameterPicker.indexOfSelectedItem) else { return }
            self.startInput(self.inputs[self.inputPicker.indexOfSelectedItem],
                            surfaceID: self.targets[self.surfacePicker.indexOfSelectedItem],
                            parameter: Self.parameterNames[self.parameterPicker.indexOfSelectedItem])
        }
        stopInputButton.actionBlock = { [weak self] in self?.stopInput() }
        sendButton.actionBlock = { [weak self] in
            guard let self, self.outputs.indices.contains(self.outputPicker.indexOfSelectedItem) else { return }
            self.writeOutput(pin: self.outputs[self.outputPicker.indexOfSelectedItem], high: self.levelPicker.indexOfSelectedItem == 1)
        }
        surfacePicker.actionBlock = { [weak self] _ in self?.refreshControls() }
        outputPicker.actionBlock = { [weak self] _ in self?.refreshControls() }
    }

    private func receive(_ update: FirmataAdapterSnapshot) {
        guard let editor, editor.documentGeneration == documentID else { return }
        connectionState = update
        connecting = false
        disablingInput = false
        awaitingOutput = false
        let board: FirmataBoard?
        switch update.phase {
        case .disconnected:
            setStatus(update.error ?? "Disconnected")
            board = nil
        case .discovering:
            setStatus(update.error ?? "Discovering Firmata · 57600 8N1")
            board = nil
        case .failed(let error):
            setStatus(update.error ?? error.localizedDescription)
            board = nil
        case .ready(let connected):
            setStatus(update.error ?? "Connected · Firmata \(connected.protocolMajor).\(connected.protocolMinor) · \(connected.pins.count) pins")
            board = connected
        }
        updatePins(board)
        if board == nil {
            route = nil
            lastRoutedSample = nil
        }

        let displayedValue: String
        if let sample = update.sample {
            displayedValue = "\(inputTitle(sample.input)) · \(sample.value) / \(sample.maximum)"
        } else {
            displayedValue = update.input != nil ? "Waiting for input…" : "Input stopped"
        }
        inputValue.stringValue = displayedValue
        if let route, update.ticket == route.ticket, let sample = update.sample, route.input == sample.input,
           let id = route.surfaceID, lastRoutedSample != sample, editor.project.surfaces.contains(where: { $0.id == id }),
           (try? TimelineEngine.parameterRange(route.parameter)) != nil {
            lastRoutedSample = sample
            editor.controlMapping.enqueue(ControlIntent(target: .surface(id, parameter: route.parameter), value: sample.normalized))
        }
        switch update.output {
        case .idle: outputValue.stringValue = "No write requested"
        case .pending(let pin, _): outputValue.stringValue = "Waiting for D\(pin) pin state…"
        case .confirmed(let pin, let high): outputValue.stringValue = "D\(pin) reported \(high ? "HIGH" : "LOW")"
        case .unconfirmed(let pin): outputValue.stringValue = "D\(pin) was unconfirmed"
        }
        refreshControls()
    }

    private func updatePins(_ board: FirmataBoard?) {
        guard controlsBoard != board else { return }
        let oldInput = inputs.indices.contains(inputPicker.indexOfSelectedItem) ? inputs[inputPicker.indexOfSelectedItem] : nil
        let oldOutput = outputs.indices.contains(outputPicker.indexOfSelectedItem) ? outputs[outputPicker.indexOfSelectedItem] : nil
        controlsBoard = board
        let pins = board?.pins ?? []
        inputs = pins.compactMap { $0.analogChannel.map { .analog(channel: $0) } }
        inputs += pins.filter(\.digitalInput).map { .digital(pin: $0.index) }
        outputs = pins.filter(\.digitalOutput).map(\.index)
        inputPicker.removeAllItems()
        inputPicker.addItems(withTitles: inputs.map(inputTitle))
        outputPicker.removeAllItems()
        outputPicker.addItems(withTitles: outputs.map { "D\($0)" })
        if let oldInput, let index = inputs.firstIndex(of: oldInput) { inputPicker.selectItem(at: index) }
        if let oldOutput, let index = outputs.firstIndex(of: oldOutput) { outputPicker.selectItem(at: index) }
    }

    private func inputTitle(_ input: FirmataInput) -> String {
        switch input {
        case .analog(let channel): return "Analog A\(channel)"
        case .digital(let pin): return "Digital D\(pin)"
        }
    }

    private func refreshControls() {
        let ready = controlsBoard != nil
        let busy: Bool
        if case .pending = connectionState.output { busy = true } else { busy = awaitingOutput }
        let opening = connecting || connectionState.phase == .discovering
        connectButton.isEnabled = !ready && !opening
        path.isEnabled = connectButton.isEnabled
        disconnectButton.isEnabled = ready || opening
        inputPicker.isEnabled = ready && !inputs.isEmpty
        startInputButton.isEnabled = inputPicker.isEnabled && !busy && !disablingInput
        stopInputButton.isEnabled = connectionState.input != nil && !busy && !disablingInput
        surfacePicker.isEnabled = ready && targets.count > 1
        parameterPicker.isEnabled = surfacePicker.isEnabled && surfacePicker.indexOfSelectedItem > 0
        outputPicker.isEnabled = ready && !outputs.isEmpty
        levelPicker.isEnabled = outputPicker.isEnabled
        sendButton.isEnabled = outputPicker.isEnabled && !busy && !outputConflictsWithInput
    }

    private var outputConflictsWithInput: Bool {
        guard let input = connectionState.input, outputs.indices.contains(outputPicker.indexOfSelectedItem) else { return false }
        let pin = outputs[outputPicker.indexOfSelectedItem]
        switch input {
        case .digital(let inputPin): return pin == inputPin
        case .analog(let channel): return controlsBoard?.pins.first(where: { $0.analogChannel == channel })?.index == pin
        }
    }

    private func setStatus(_ text: String) { status.stringValue = text; status.toolTip = text }
}

extension EditorController {
    @objc func showFirmata() {
        if firmataWindow == nil { firmataWindow = FirmataWindow(editor: self) }
        firmataWindow?.refreshTargets()
        firmataWindow?.showWindow(nil)
        firmataWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func closeFirmata() {
        firmataWindow?.shutDown()
        firmataWindow?.close()
        firmataWindow = nil
    }
}
#endif
