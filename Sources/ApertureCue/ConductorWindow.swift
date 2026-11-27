#if os(macOS)
import AppKit
import MappingCore

extension EditorController {
    var automationSurfaces: [Surface] {
        project.surfaces + project.cues.filter { $0.scope == .full }.flatMap(\.surfaces)
    }

    @objc func showConductor() {
        if conductorWindow == nil { conductorWindow = ConductorWindow(editor: self) }
        conductorWindow?.refresh()
        conductorWindow?.showWindow(nil)
        conductorWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openShowSchedule() { showSchedule() }
    @objc func openShowControlTools() { showControls() }

    func resetShowControlSessions() {
        conductorRuntime.reset()
        conductorWindow?.close()
        conductorWindow = nil
        resetShowSchedule()
        resetShowControlSession()
    }

    func modifyConductor(_ label: String, _ body: (inout Conductor) throws -> Void) throws {
        var candidate = project
        try body(&candidate.conductor)
        try ProjectStore.validate(candidate)
        mutate(label) { $0 = candidate }
    }

    func captureConductorCell(bankID: UUID, rowID: UUID, name: String, loops: Bool,
                              surfaceID: UUID? = nil, replacing cellID: UUID? = nil) throws -> UUID {
        let tracks = project.timeline.filter { $0.enabled && (surfaceID == nil || $0.surfaceID == surfaceID) }
        guard !tracks.isEmpty else { throw ProjectError.invalid("Add an enabled timeline track before capturing a cell") }
        let cell = ConductorCell(id: cellID ?? UUID(), name: name, duration: project.timelineSettings.duration,
                                loops: loops, tracks: tracks)
        try modifyConductor(cellID == nil ? "Capture Conductor cell" : "Replace Conductor cell") {
            guard let bank = $0.banks.firstIndex(where: { $0.id == bankID }),
                  let row = $0.banks[bank].rows.firstIndex(where: { $0.id == rowID }) else {
                throw ProjectError.invalid("Conductor bank or row is no longer present")
            }
            if let cellID {
                guard let index = $0.banks[bank].rows[row].cells.firstIndex(where: { $0.id == cellID }) else {
                    throw ProjectError.invalid("Conductor cell is no longer present")
                }
                $0.banks[bank].rows[row].cells[index] = cell
            } else {
                $0.banks[bank].rows[row].cells.append(cell)
            }
        }
        return cell.id
    }

    func launchConductorCell(bankID: UUID, cellID: UUID,
                             at hostTime: Double = ProcessInfo.processInfo.systemUptime) throws {
        configureShow(at: hostTime)
        guard showConfigurationError.isEmpty else { throw ProjectError.invalid(showConfigurationError) }
        try conductorRuntime.launch(bankID: bankID, cellID: cellID, at: hostTime)
        conductorHostTime = hostTime
        updateRender()
        conductorWindow?.updateStatus()
    }
}

@MainActor final class ConductorWindow: NSWindowController {
    private weak var editor: EditorController?
    private let bankPicker = ActionPopUp(items: [], action: { _ in })
    private let rowPicker = ActionPopUp(items: [], action: { _ in })
    private let cellPicker = ActionPopUp(items: [], action: { _ in })
    private let signalPicker = ActionPopUp(items: [], action: { _ in })
    private let status = label("")
    private var bankIDs: [UUID] = []
    private var rowIDs: [UUID] = []
    private var cellIDs: [UUID] = []
    private var signalIDs: [UUID] = []
    private var bankActions: [NSButton] = []
    private var rowActions: [NSButton] = []
    private var cellActions: [NSButton] = []
    private var signalActions: [NSButton] = []
    private var bankID: UUID? { selected(in: bankIDs, picker: bankPicker) }
    private var rowID: UUID? { selected(in: rowIDs, picker: rowPicker) }
    private var cellID: UUID? { selected(in: cellIDs, picker: cellPicker) }
    private var signalID: UUID? { selected(in: signalIDs, picker: signalPicker) }

    init(editor: EditorController) {
        self.editor = editor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 305),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Conductor"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        guard let content = window.contentView else { return }
        bankPicker.actionBlock = { [weak self] _ in self?.refresh() }
        rowPicker.actionBlock = { [weak self] _ in self?.refresh() }
        cellPicker.actionBlock = { [weak self] _ in self?.updateStatus() }

        let addRowButton = ActionButton("Add row…") { [weak self] in self?.addRow() }
        let deleteBankButton = ActionButton("Delete bank") { [weak self] in self?.removeBank() }
        bankActions = [deleteBankButton, addRowButton]
        let deleteRowButton = ActionButton("Delete row") { [weak self] in self?.removeRow() }
        let stopRowButton = ActionButton("Stop row") { [weak self] in self?.stopRow() }
        let captureButton = ActionButton("Capture timeline…") { [weak self] in self?.capture(replace: false) }
        rowActions = [deleteRowButton, stopRowButton, captureButton]
        let launchButton = ActionButton("Launch") { [weak self] in self?.launch() }
        let replaceButton = ActionButton("Replace cell…") { [weak self] in self?.capture(replace: true) }
        let deleteCellButton = ActionButton("Delete cell") { [weak self] in self?.removeCell() }
        cellActions = [launchButton, replaceButton, deleteCellButton]
        let editSignal = ActionButton("Edit…") { [weak self] in self?.editSignal(replace: true) }
        let editBindings = ActionButton("Bindings…") { [weak self] in self?.editBindings() }
        let deleteSignal = ActionButton("Delete") { [weak self] in self?.removeSignal() }
        signalActions = [editSignal, editBindings, deleteSignal]
        let banks = stack([label("Bank"), bankPicker, ActionButton("Add bank…") { [weak self] in self?.addBank() },
                           deleteBankButton], vertical: false)
        let rows = stack([label("Row"), rowPicker, addRowButton, deleteRowButton], vertical: false)
        let cells = stack([label("Cell"), cellPicker, launchButton, stopRowButton,
                           ActionButton("Stop all") { [weak self] in self?.stopAll() }], vertical: false)
        let edit = stack([captureButton, replaceButton, deleteCellButton], vertical: false)
        let signals = stack([label("Signal"), signalPicker,
                             ActionButton("Add signal…") { [weak self] in self?.editSignal(replace: false) },
                             editSignal, editBindings, deleteSignal], vertical: false)
        for picker in [bankPicker, rowPicker, cellPicker, signalPicker] {
            picker.widthAnchor.constraint(equalToConstant: 190).isActive = true
        }
        let help = label("One cell per row can play. Launching in another bank stops the previous bank.", size: 11)
        let root = stack([banks, rows, cells, edit, status, signals, help], spacing: 10)
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        fill(root, in: content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func selected(in ids: [UUID], picker: ActionPopUp) -> UUID? {
        let index = picker.indexOfSelectedItem
        return ids.indices.contains(index) ? ids[index] : nil
    }

    private func populate(_ picker: ActionPopUp, names: [String], ids: [UUID], selection: UUID?) {
        picker.removeAllItems()
        // NSMenu titles are unique in addItems. Include the visible ordinal so
        // two identically named document objects can both be selected.
        picker.addItems(withTitles: names.enumerated().map { "\($0.offset + 1)  \($0.element.prefix(45))" })
        if !ids.isEmpty { picker.selectItem(at: selection.flatMap { ids.firstIndex(of: $0) } ?? 0) }
        picker.isEnabled = !ids.isEmpty
    }

    func refresh() {
        guard let editor else { return }
        let (oldBank, oldRow, oldCell, oldSignal) = (bankID, rowID, cellID, signalID)
        let model = editor.project.conductor
        bankIDs = model.banks.map(\.id)
        populate(bankPicker, names: model.banks.map(\.name), ids: bankIDs, selection: oldBank)
        let rows = model.banks.first { $0.id == bankID }?.rows ?? []
        rowIDs = rows.map(\.id)
        populate(rowPicker, names: rows.map(\.name), ids: rowIDs, selection: oldRow)
        let cells = rows.first { $0.id == rowID }?.cells ?? []
        cellIDs = cells.map(\.id)
        populate(cellPicker, names: cells.map(\.name), ids: cellIDs, selection: oldCell)
        signalIDs = model.signals.map(\.id)
        populate(signalPicker, names: model.signals.map(\.name), ids: signalIDs, selection: oldSignal)
        for (buttons, enabled) in [(bankActions, bankID != nil), (rowActions, rowID != nil),
                                   (cellActions, cellID != nil), (signalActions, signalID != nil)] {
            for button in buttons { button.isEnabled = enabled }
        }
        updateStatus()
    }

    func updateStatus() {
        guard let editor else { return }
        let running = editor.conductorRuntime.activeCellIDs
        let bank = editor.project.conductor.banks.first { $0.id == editor.conductorRuntime.bankID }
        let count = running.count
        if let bank, count > 0 {
            let selection = cellID.map(running.contains) == true ? " · selected cell active" : ""
            status.stringValue = "\(bank.name.prefix(30)) · \(count) active row(s)" + selection
        } else {
            status.stringValue = "No active cells"
        }
    }

    private func run(_ operation: (EditorController) throws -> Void) {
        guard let editor else { return }
        do { try operation(editor); refresh() } catch { editor.showError(error) }
    }

    private func dialog(_ title: String, fields: [NSView], button: String = "Save") -> Bool {
        guard let editor else { return false }
        let token = editor.documentGeneration
        let alert = NSAlert()
        alert.messageText = title
        let content = stack(fields)
        content.frame = NSRect(x: 0, y: 0, width: 350, height: content.fittingSize.height)
        for field in fields {
            if field is ActionField || field is ActionPopUp {
                field.widthAnchor.constraint(equalToConstant: 330).isActive = true
            }
        }
        alert.accessoryView = content
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn && editor.documentGeneration == token
    }

    private func addBank() {
        let name = ActionField("Bank \(bankIDs.count + 1)", action: { _ in })
        guard dialog("Add Conductor bank", fields: [name]) else { return }
        let bank = ConductorBank(name: name.stringValue)
        run { try $0.modifyConductor("Add Conductor bank") { $0.banks.append(bank) } }
        if let index = bankIDs.firstIndex(of: bank.id) { bankPicker.selectItem(at: index); refresh() }
    }

    private func addRow() {
        guard let bankID else { return }
        let name = ActionField("Row \(rowIDs.count + 1)", action: { _ in })
        guard dialog("Add Conductor row", fields: [name]) else { return }
        let row = ConductorRow(name: name.stringValue)
        run { editor in
            try editor.modifyConductor("Add Conductor row") {
                guard let index = $0.banks.firstIndex(where: { $0.id == bankID }) else { return }
                $0.banks[index].rows.append(row)
            }
        }
        if let index = rowIDs.firstIndex(of: row.id) { rowPicker.selectItem(at: index); refresh() }
    }

    private func capture(replace: Bool) {
        guard let editor, let bankID, let rowID, !replace || cellID != nil else { return }
        let old = replace ? cellID.flatMap { id in
            editor.project.conductor.banks.flatMap(\.rows).flatMap(\.cells).first { $0.id == id }
        } : nil
        let name = ActionField(old?.name ?? "Cell \(cellIDs.count + 1)", action: { _ in })
        let loops = NSButton(checkboxWithTitle: "Loop cell", target: nil, action: nil)
        loops.state = old?.loops == true ? .on : .off
        let onlySelected = NSButton(checkboxWithTitle: "Capture tracks for the selected surface only", target: nil, action: nil)
        onlySelected.isEnabled = editor.selectedID != nil
        guard dialog("Capture enabled timeline tracks", fields: [label("Cell name"), name, loops, onlySelected],
                     button: replace ? "Replace" : "Capture") else { return }
        run { controller in
            let id = try controller.captureConductorCell(bankID: bankID, rowID: rowID, name: name.stringValue,
                loops: loops.state == .on, surfaceID: onlySelected.state == .on ? controller.selectedID : nil, replacing: old?.id)
            refresh()
            if let index = cellIDs.firstIndex(of: id) { cellPicker.selectItem(at: index) }
        }
    }

    private func removeBank() {
        guard let bankID else { return }
        run { try $0.modifyConductor("Delete Conductor bank") { $0.banks.removeAll { $0.id == bankID } } }
    }

    private func removeRow() {
        guard let bankID, let rowID else { return }
        run { editor in
            try editor.modifyConductor("Delete Conductor row") {
                guard let bank = $0.banks.firstIndex(where: { $0.id == bankID }) else { return }
                $0.banks[bank].rows.removeAll { $0.id == rowID }
            }
        }
    }

    private func removeCell() {
        guard let bankID, let rowID, let cellID else { return }
        run { editor in
            try editor.modifyConductor("Delete Conductor cell") {
                guard let bank = $0.banks.firstIndex(where: { $0.id == bankID }),
                      let row = $0.banks[bank].rows.firstIndex(where: { $0.id == rowID }) else { return }
                $0.banks[bank].rows[row].cells.removeAll { $0.id == cellID }
            }
        }
    }

    private func launch() {
        guard let bankID, let cellID else { return }
        run { try $0.launchConductorCell(bankID: bankID, cellID: cellID) }
    }

    private func stopRow() {
        guard let editor, let rowID else { return }
        editor.conductorRuntime.stop(rowID: rowID)
        editor.updateRender()
        updateStatus()
    }

    private func stopAll() {
        editor?.conductorRuntime.stopAll()
        editor?.updateRender()
        updateStatus()
    }

    private func editSignal(replace: Bool) {
        guard let editor else { return }
        let signals = editor.project.conductor.signals
        let old = replace ? signals.first { $0.id == signalID } : nil
        guard !replace || old != nil else { return }
        let sources = signals.filter { $0.id != old?.id }
        let labels = ["None"] + sources.enumerated().map { "\($0.offset + 1)  \($0.element.name.prefix(40))" }
        let name = ActionField(old?.name ?? "Signal \(signals.count + 1)", action: { _ in })
        let kinds = ShowSignalKind.allCases
        let kind = ActionPopUp(items: kinds.map(\.rawValue), selected: kinds.firstIndex(of: old?.kind ?? .sine) ?? 0, action: { _ in })
        let frequency = ActionField(String(old?.frequency ?? 1), action: { _ in })
        let phase = ActionField(String(old?.phase ?? 0), action: { _ in })
        let inputs = (0..<2).map { offset in
            let id = old.flatMap { $0.inputs.indices.contains(offset) ? $0.inputs[offset] : nil }
            let index = id.flatMap { id in sources.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
            return ActionPopUp(items: labels, selected: index, action: { _ in })
        }
        guard dialog("Signal generator or combiner", fields: [label("Name"), name, kind,
                     label("Frequency (Hz) and phase (cycles)"), frequency, phase,
                     label("Two input signals for add and multiply"), inputs[0], inputs[1]]) else { return }
        run { editor in
            guard let hz = Double(frequency.stringValue), let cycles = Double(phase.stringValue) else {
                throw ProjectError.invalid("Enter a frequency and phase")
            }
            let selected = kinds[kind.indexOfSelectedItem]
            let ids = inputs.compactMap { field -> UUID? in
                let index = field.indexOfSelectedItem - 1
                return sources.indices.contains(index) ? sources[index].id : nil
            }
            let node = ShowSignal(id: old?.id ?? UUID(), name: name.stringValue, kind: selected,
                frequency: hz, phase: cycles, inputs: selected == .add || selected == .multiply ? ids : [])
            try editor.modifyConductor("Save show signal") {
                if let index = $0.signals.firstIndex(where: { $0.id == node.id }) { $0.signals[index] = node }
                else { $0.signals.append(node) }
            }
        }
    }

    private func editBindings() {
        guard let editor, let signalID, let surfaceID = editor.selectedID else { return }
        let parameters = TimelineEngine.parameters
        let parameter = ActionPopUp(items: parameters, action: { _ in })
        let minimum = ActionField("0", action: { _ in })
        let maximum = ActionField("1", action: { _ in })
        let remove = NSButton(checkboxWithTitle: "Remove this parameter binding", target: nil, action: nil)
        guard dialog("Bind signal to the selected surface", fields: [parameter, label("Minimum and maximum"), minimum, maximum, remove]) else { return }
        run { controller in
            let key = parameters[parameter.indexOfSelectedItem]
            try controller.modifyConductor("Edit signal binding") {
                $0.bindings.removeAll { $0.surfaceID == surfaceID && $0.parameter == key }
                if remove.state != .on {
                    guard let low = Double(minimum.stringValue), let high = Double(maximum.stringValue) else {
                        throw ProjectError.invalid("Enter numeric output limits")
                    }
                    $0.bindings.append(ShowSignalBinding(signalID: signalID, surfaceID: surfaceID, parameter: key,
                                                         minimum: low, maximum: high))
                }
            }
        }
    }

    private func removeSignal() {
        guard let signalID else { return }
        run { editor in
            try editor.modifyConductor("Delete show signal") {
                $0.signals.removeAll { $0.id == signalID }
                $0.bindings.removeAll { $0.signalID == signalID }
                // Validation rejects removal while another combiner uses it.
            }
        }
    }
}
#endif
