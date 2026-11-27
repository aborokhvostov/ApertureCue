#if os(macOS)
import AppKit
import MappingCore

@MainActor final class ControlMappingWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var editor: EditorController?
    private let table = NSTableView()
    private let bindAddress = ActionField("127.0.0.1", action: { _ in })
    private let peerAddress = ActionField("", action: { _ in })
    private let oscPort = ActionField("9000", action: { _ in })
    private let queryPort = ActionField("9002", action: { _ in })
    private let advertise = NSButton(checkboxWithTitle: "Local discovery", target: nil, action: nil)
    private let input = ActionPopUp(items: [], action: { _ in })
    private let output = ActionPopUp(items: [], action: { _ in })
    private let oscStatus = label("")
    private let queryStatus = label("")
    private let midiStatus = label("")
    private let learnStatus = label("")
    private var startOSCButton: ActionButton!
    private var stopOSCButton: ActionButton!
    private var startQueryButton: ActionButton!
    private var stopQueryButton: ActionButton!
    private var startMIDIButton: ActionButton!
    private var stopMIDIButton: ActionButton!
    private var editButton: ActionButton!
    private var deleteButton: ActionButton!
    private var learnButton: ActionButton!
    private var useInputButton: ActionButton!
    private var inputUIDs: [Int32?] = []
    private var outputUIDs: [Int32?] = []
    private var displayed: [ControlBinding] = []
    private var names: [UUID: String] = [:]

    init(editor: EditorController) {
        self.editor = editor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Control Mappings"
        window.contentMinSize = NSSize(width: 780, height: 500)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        guard let content = window.contentView else { return }

        startOSCButton = ActionButton("Start OSC") { [weak self] in self?.startOSC() }
        stopOSCButton = ActionButton("Stop OSC") { [weak self] in self?.editor?.stopOSCControls(); self?.refreshStatus() }
        startQueryButton = ActionButton("Start Query") { [weak self] in self?.startQuery() }
        stopQueryButton = ActionButton("Stop Query") { [weak self] in self?.stopQuery() }
        startMIDIButton = ActionButton("Connect MIDI") { [weak self] in self?.startMIDI() }
        stopMIDIButton = ActionButton("Disconnect MIDI") { [weak self] in self?.stopMIDI() }
        editButton = ActionButton("Edit…") { [weak self] in self?.editSelected() }
        deleteButton = ActionButton("Delete") { [weak self] in self?.deleteSelected() }
        learnButton = ActionButton("Learn next input") { [weak self] in self?.beginLearn() }
        useInputButton = ActionButton("Map learned input…") { [weak self] in self?.editBinding(learned: true) }
        input.actionBlock = { [weak self] _ in self?.refreshStatus() }
        output.actionBlock = { [weak self] _ in self?.refreshStatus() }

        for field in [bindAddress, peerAddress] { field.widthAnchor.constraint(equalToConstant: 126).isActive = true }
        peerAddress.placeholderString = "optional on localhost"
        for field in [oscPort, queryPort] { field.widthAnchor.constraint(equalToConstant: 66).isActive = true }
        input.widthAnchor.constraint(equalToConstant: 182).isActive = true
        output.widthAnchor.constraint(equalToConstant: 182).isActive = true

        let osc = stack([label("OSC IPv4"), bindAddress, label("Sender"), peerAddress, label("UDP"), oscPort,
                         startOSCButton, stopOSCButton], vertical: false)
        let query = stack([label("OSCQuery TCP"), queryPort, advertise,
                           startQueryButton, stopQueryButton], vertical: false)
        let midi = stack([label("MIDI input"), input, label("Feedback"), output,
                          startMIDIButton, stopMIDIButton], vertical: false)
        let actions = stack([ActionButton("Add mapping…") { [weak self] in self?.editBinding() },
                             editButton, deleteButton, learnButton, useInputButton], vertical: false)
        let sourceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sourceColumn.title = "Input"
        sourceColumn.width = 270
        let targetColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("target"))
        targetColumn.title = "Target"
        targetColumn.width = 410
        table.addTableColumn(sourceColumn)
        table.addTableColumn(targetColumn)
        table.delegate = self
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let viewport = scroll(table)
        viewport.hasHorizontalScroller = true
        viewport.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let root = stack([osc, oscStatus, query, queryStatus, midi, midiStatus, label("Saved mappings", bold: true),
                          actions, learnStatus, viewport], spacing: 8)
        root.edgeInsets = NSEdgeInsets(top: 15, left: 15, bottom: 15, right: 15)
        fill(root, in: content)
        viewport.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -30).isActive = true
        for status in [oscStatus, queryStatus, midiStatus, learnStatus] {
            status.lineBreakMode = .byTruncatingTail
            status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            status.widthAnchor.constraint(equalTo: viewport.widthAnchor).isActive = true
        }
        refreshEndpointChoices()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func selectedUID(_ picker: NSPopUpButton, ids: [Int32?]) -> Int32? {
        ids.indices.contains(picker.indexOfSelectedItem) ? ids[picker.indexOfSelectedItem] : nil
    }

    func refreshEndpointChoices() {
        guard let editor else { return }
        let oldInput = selectedUID(input, ids: inputUIDs) ?? editor.controlMapping.inputUID
        let oldOutput = selectedUID(output, ids: outputUIDs) ?? editor.controlMapping.outputUID
        func populate(_ picker: NSPopUpButton, endpoints: [MIDIControlAdapter.Endpoint],
                      selected: Int32?, placeholder: String) -> [Int32?] {
            var ids = [nil] + endpoints.map { Optional($0.uid) }
            let labels = [placeholder] + endpoints.enumerated().map { index, endpoint in
                "\(index + 1)  \(endpoint.name.prefix(42))"
            }
            picker.removeAllItems()
            picker.addItems(withTitles: labels)
            if let selected, !ids.contains(selected) {
                ids.append(selected)
                picker.addItem(withTitle: "Selected endpoint unavailable")
            }
            picker.selectItem(at: ids.firstIndex(of: selected) ?? 0)
            return ids
        }
        inputUIDs = populate(input, endpoints: MIDIControlAdapter.inputEndpoints(), selected: oldInput, placeholder: "None")
        outputUIDs = populate(output, endpoints: MIDIControlAdapter.outputEndpoints(), selected: oldOutput, placeholder: "None")
        refreshStatus()
    }

    func refresh() {
        guard let editor else { return }
        var nextNames: [UUID: String] = [:]
        for surface in editor.automationSurfaces { nextNames[surface.id] = surface.name }
        for cue in editor.project.cues { nextNames[cue.id] = cue.name }
        let selected = selectedBinding?.id
        if displayed != editor.project.controlMap.bindings || nextNames != names {
            displayed = editor.project.controlMap.bindings
            names = nextNames
            table.reloadData()
            if let row = displayed.firstIndex(where: { $0.id == selected }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        refreshStatus()
    }

    func refreshStatus() {
        guard let editor, startOSCButton != nil else { return }
        let network = editor.network
        let running = network?.isRunning == true
        let state = editor.controlMapping
        startOSCButton.isEnabled = !running
        stopOSCButton.isEnabled = running
        for field in [bindAddress, peerAddress, oscPort] { field.isEnabled = !running }
        let stats = network?.stats ?? OSCInputStats()
        oscStatus.stringValue = running
            ? "OSC UDP \(network?.boundPort ?? 0) · \(stats.datagrams) received · \(stats.rejected) rejected · \(stats.limited) limited · \(stats.droppedCommands + state.dropped) dropped"
            : "OSC input stopped"
        startQueryButton.isEnabled = running && state.oscIsLoopback && !state.queryEnabled
        stopQueryButton.isEnabled = state.queryEnabled
        queryPort.isEnabled = !state.queryEnabled
        advertise.isEnabled = !state.queryEnabled
        switch state.query.status {
        case .stopped: queryStatus.stringValue = "OSCQuery stopped"
        case .starting: queryStatus.stringValue = "OSCQuery starting"
        case .ready(let port): queryStatus.stringValue = "OSCQuery 127.0.0.1:\(port)" + (editor.project.surfaces.count > 200 ? " · first 200 current surfaces" : "")
        case .failed(let error):
            state.queryEnabled = false
            queryStatus.stringValue = error
        }
        switch state.query.discoveryStatus {
        case .off: break
        case .registering: queryStatus.stringValue += " · advertising locally"
        case .ready(let name): queryStatus.stringValue += " · " + name
        case .failed(let error): queryStatus.stringValue += " · " + error
        }
        if !state.queryStatus.isEmpty { queryStatus.stringValue += " · " + state.queryStatus }
        let midiRunning = editor.midi?.isRunning == true
        input.isEnabled = !midiRunning
        output.isEnabled = !midiRunning
        startMIDIButton.isEnabled = !midiRunning && (selectedUID(input, ids: inputUIDs) != nil || selectedUID(output, ids: outputUIDs) != nil)
        stopMIDIButton.isEnabled = midiRunning
        if midiRunning {
            let inputText = state.inputUID == nil ? "off" : editor.midi?.connectedInputUID == nil ? "waiting" : "connected"
            let outputText = state.outputUID == nil ? "off" : editor.midi?.connectedFeedbackUID == nil ? "waiting" : "connected"
            midiStatus.stringValue = "MIDI input \(inputText) · feedback \(outputText) · \(editor.midi?.droppedInputBatches ?? 0) dropped batches"
        } else { midiStatus.stringValue = "MIDI disconnected" }
        if !state.midiStatus.isEmpty { midiStatus.stringValue += " · " + state.midiStatus }
        learnButton.title = state.learnNext ? "Cancel Learn" : "Learn next input"
        learnButton.isEnabled = running || midiRunning
        useInputButton.isEnabled = state.lastInput != nil && !state.learnNext
        learnStatus.stringValue = state.learnNext ? "Waiting for the next OSC or MIDI input" : state.lastInput.map(formatInput) ?? "No input captured"
        editButton.isEnabled = selectedBinding != nil
        deleteButton.isEnabled = selectedBinding != nil
    }

    private func portValue(_ field: NSTextField) throws -> UInt16 {
        guard let value = UInt16(field.stringValue), value > 0 else {
            throw SystemFailure(message: "Enter a port in 1…65535")
        }
        return value
    }

    private func startOSC() {
        guard let editor else { return }
        do {
            let sender = peerAddress.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = bindAddress.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            editor.controlMapping.clearInput()
            try editor.network?.start(port: portValue(oscPort), address: host, peer: sender.isEmpty ? nil : sender)
            editor.controlMapping.oscIsLoopback = host == "127.0.0.1"
        } catch { editor.showError(error) }
        refreshStatus()
    }

    private func startQuery() {
        guard let editor else { return }
        do { try editor.startQuery(port: portValue(queryPort), advertiseLocally: advertise.state == .on) }
        catch { editor.showError(error) }
        refreshStatus()
    }

    private func stopQuery() {
        guard let editor else { return }
        editor.controlMapping.query.stop()
        editor.controlMapping.queryEnabled = false
        editor.controlMapping.queryStatus = ""
        refreshStatus()
    }

    private func startMIDI() {
        guard let editor else { return }
        let source = selectedUID(input, ids: inputUIDs)
        let destination = selectedUID(output, ids: outputUIDs)
        guard source != nil || destination != nil else { return }
        do {
            editor.controlMapping.clearInput()
            editor.controlMapping.inputUID = source
            editor.controlMapping.outputUID = destination
            try editor.midi?.start(inputUID: source, feedbackUID: destination)
        } catch {
            editor.controlMapping.inputUID = nil
            editor.controlMapping.outputUID = nil
            editor.showError(error)
        }
        refreshStatus()
    }

    private func stopMIDI() {
        guard let editor else { return }
        editor.stopMIDIControls()
        refreshStatus()
    }

    private func beginLearn() {
        guard let editor else { return }
        editor.controlMapping.learnNext.toggle()
        if editor.controlMapping.learnNext { editor.controlMapping.lastInput = nil }
        refreshStatus()
    }

    private var selectedBinding: ControlBinding? {
        displayed.indices.contains(table.selectedRow) ? displayed[table.selectedRow] : nil
    }

    private func editSelected() {
        if let selectedBinding { editBinding(previous: selectedBinding) }
    }

    private func deleteSelected() {
        guard let editor, let selectedBinding else { return }
        do { try editor.editControlBinding(nil, id: selectedBinding.id) }
        catch { editor.showError(error) }
    }

    private func formatInput(_ input: ControlInput) -> String {
        switch input {
        case let .osc(address): return "OSC " + address
        case let .midi(kind, channel, number): return "MIDI \(kind.rawValue) · ch \(channel) · \(number)"
        }
    }

    private func formatTarget(_ target: ControlTarget) -> String {
        switch target {
        case let .surface(id, parameter): return (names[id] ?? "Surface") + " · " + parameter
        case let .scene(id): return "Recall " + (names[id] ?? "Scene")
        case .play: return "Play"
        case .pause: return "Pause"
        case .stop: return "Stop"
        case .togglePlayback: return "Toggle playback"
        case .seek: return "Seek (timeline fraction)"
        case .blackout: return "Blackout"
        }
    }

    private func editBinding(previous: ControlBinding? = nil, learned: Bool = false) {
        guard let editor else { return }
        let token = editor.documentGeneration
        let current = previous?.input ?? (learned ? editor.controlMapping.lastInput : nil) ?? .osc("/controller/fader")
        let address = ActionField("/controller/fader", action: { _ in })
        let channel = ActionField("1", action: { _ in })
        let number = ActionField("1", action: { _ in })
        let kinds = MIDIMapKind.allCases
        let inputType = ActionPopUp(items: ["OSC"] + kinds.map { "MIDI " + $0.rawValue }, action: { _ in })
        switch current {
        case let .osc(path): address.stringValue = path
        case let .midi(kind, ch, n):
            inputType.selectItem(at: (kinds.firstIndex(of: kind) ?? 0) + 1)
            channel.stringValue = String(ch)
            number.stringValue = String(n)
        }
        var used = Set<UUID>()
        let surfaces = editor.automationSurfaces.filter { used.insert($0.id).inserted }
        let targets: [ControlTarget] = [.play, .pause, .stop, .togglePlayback, .seek, .blackout]
            + editor.project.cues.map { .scene($0.id) }
            + surfaces.flatMap { surface in TimelineEngine.parameters.map { .surface(surface.id, parameter: $0) } }
        let target = ActionPopUp(items: targets.enumerated().map { "\($0.offset + 1)  \(formatTarget($0.element).prefix(58))" }, action: { _ in })
        let suggested = previous?.target ?? editor.selectedID.map { .surface($0, parameter: "opacity") } ?? .play
        target.selectItem(at: targets.firstIndex(of: suggested) ?? 0)
        let inversion = NSButton(checkboxWithTitle: "Invert input", target: nil, action: nil)
        let feedback = NSButton(checkboxWithTitle: "Send MIDI feedback to the selected output", target: nil, action: nil)
        inversion.state = previous?.inverted == true ? .on : .off
        feedback.state = previous?.feedback == true ? .on : .off
        func updateFields() {
            let isMIDI = inputType.indexOfSelectedItem > 0
            address.isEnabled = !isMIDI
            channel.isEnabled = isMIDI
            number.isEnabled = isMIDI && inputType.indexOfSelectedItem != kinds.count
            let destination = targets[target.indexOfSelectedItem]
            switch destination {
            case .surface, .blackout, .togglePlayback: feedback.isEnabled = isMIDI
            default: feedback.isEnabled = false
            }
        }
        inputType.actionBlock = { _ in updateFields() }
        target.actionBlock = { _ in updateFields() }
        defer { inputType.actionBlock = nil; target.actionBlock = nil }
        updateFields()

        for field in [address, channel, number] { field.widthAnchor.constraint(equalToConstant: 240).isActive = true }
        target.widthAnchor.constraint(equalToConstant: 340).isActive = true
        let fields = stack([inputType, stack([label("OSC address"), address], vertical: false),
            stack([label("MIDI channel"), channel], vertical: false),
            stack([label("Note / CC"), number], vertical: false), label("Show target"), target, inversion, feedback])
        fields.frame = NSRect(x: 0, y: 0, width: 355, height: fields.fittingSize.height)
        let alert = NSAlert()
        alert.messageText = "Control mapping"
        alert.accessoryView = fields
        alert.addButton(withTitle: "Save mapping")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, editor.documentGeneration == token else { return }
        do {
            let source: ControlInput
            if inputType.indexOfSelectedItem == 0 { source = .osc(address.stringValue) }
            else {
                let kind = kinds[inputType.indexOfSelectedItem - 1]
                guard let ch = Int(channel.stringValue), let n = kind == .pitchBend ? 0 : Int(number.stringValue) else {
                    throw ProjectError.invalid("Enter a MIDI channel and note or controller number")
                }
                source = .midi(kind: kind, channel: ch, number: n)
            }
            let id = previous?.id ?? UUID()
            let binding = ControlBinding(id: id, input: source, target: targets[target.indexOfSelectedItem],
                                         inverted: inversion.state == .on, feedback: feedback.isEnabled && feedback.state == .on)
            try editor.editControlBinding(binding, id: id)
        } catch { editor.showError(error) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard displayed.indices.contains(row) else { return nil }
        let binding = displayed[row]
        if column?.identifier.rawValue == "source" { return label(formatInput(binding.input)) }
        let suffix = (binding.inverted ? " · inverted" : "") + (binding.feedback ? " · feedback" : "")
        return label(formatTarget(binding.target) + suffix)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshStatus() }
}
#endif
