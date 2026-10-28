#if os(macOS)
import AppKit
import MappingCore

/// Edits stored scene properties independently from the explicit capture actions.
@MainActor final class CueWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    weak var editor: EditorController?
    let cueTable = NSTableView(), surfaceTable = NSTableView()
    var selectedCueID: UUID?
    var selectedSurfaceID: UUID?
    let nameField = ActionField("Scene", action: { _ in })
    let durationField = ActionField("1", action: { _ in })
    let followField = ActionField("", action: { _ in })
    let scopePicker = ActionPopUp(items: ["Full surface snapshot", "Selective fields"], selected: 1, action: { _ in })
    let saveButton = ActionButton("Save cue properties / fields", action: {})
    let recaptureButton = ActionButton("Recapture values", action: {})
    let captureFullButton = ActionButton("Capture full", action: {})
    let captureSelectiveButton = ActionButton("Capture selective", action: {})
    let goButton = ActionButton("GO selected", action: {})
    let deleteButton = ActionButton("Delete scene", action: {})
    private(set) var checkboxes: [CueParameter: NSButton] = [:]
    private var storedLabels: [CueParameter: NSTextField] = [:]
    private var currentLabels: [CueParameter: NSTextField] = [:]
    private var fields: [UUID: Set<CueParameter>] = [:]
    private var surfaces: [Surface] = []
    private var loadedCue: Cue?
    private var draftInitialized = false
    private var refreshing = false
    private let heading = label("New scene draft", size: 15, bold: true)
    private let summary = label("", size: 11)
    private let warning = label("", size: 11)
    private let surfaceCaption = label("Select a surface", size: 12, bold: true)
    private let allButton = ActionButton("All fields on surface", action: {})
    private let clearButton = ActionButton("Clear surface", action: {})
    private let clearAllButton = ActionButton("Clear all fields", action: {})

    var draftBindings: [CueBinding] {
        surfaces.compactMap { surface in
            let parameters = CueParameter.allCases.filter { fields[surface.id]?.contains($0) == true }
            return parameters.isEmpty ? nil : CueBinding(surfaceID: surface.id, parameters: parameters)
        }
    }
    private var selectedCue: Cue? { editor?.project.cues.first { $0.id == selectedCueID } }
    private var draftScope: CueScope { scopePicker.indexOfSelectedItem == 0 ? .full : .selective }

    init(editor: EditorController) {
        self.editor = editor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "ApertureCue · Scenes and Selective Cues"
        window.minSize = NSSize(width: 1060, height: 640)
        window.isReleasedWhenClosed = false
        window.center()
        makeUI(); bind(); refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func tableScroll(_ table: NSTableView, height: CGFloat) -> NSScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 250; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 29
        table.delegate = self; table.dataSource = self
        table.backgroundColor = .clear; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        return scroll(table, height: height)
    }
    private func makeUI() {
        guard let content = window?.contentView else { return }
        let cues = tableScroll(cueTable, height: 205)
        let targets = tableScroll(surfaceTable, height: 240)
        let left = FlippedStackView(views: [label("SAVED SCENES", bold: true), cues,
            ActionButton("New draft") { [weak self] in self?.newDraft() },
            stack([goButton, deleteButton], vertical: false), label("SURFACE FIELDS", bold: true), targets])
        left.orientation = .vertical; left.alignment = .leading; left.spacing = 8
        left.translatesAutoresizingMaskIntoConstraints = false
        left.widthAnchor.constraint(equalToConstant: 260).isActive = true
        for view in [cues, targets] { view.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true }
        let leftScroll = scroll(left)
        leftScroll.widthAnchor.constraint(equalToConstant: 275).isActive = true

        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        for view in [durationField, followField] { view.widthAnchor.constraint(equalToConstant: 78).isActive = true }
        let metadata = stack([label("Name"), nameField, label("Scope"), scopePicker], vertical: false)
        let timing = stack([label("Transition s"), durationField, label("Follow s (blank = none)"), followField], vertical: false)
        let fieldActions = stack([allButton, clearButton, clearAllButton], vertical: false)
        let fieldHeader = stack([label("Included field", bold: true), label("Stored snapshot", bold: true), label("Current surface", bold: true)], vertical: false, spacing: 10)
        fieldHeader.arrangedSubviews[0].widthAnchor.constraint(equalToConstant: 165).isActive = true
        for view in fieldHeader.arrangedSubviews.dropFirst() { view.widthAnchor.constraint(equalTo: fieldHeader.widthAnchor, multiplier: 0.5, constant: -92.5).isActive = true }
        var rows: [NSView] = []
        for parameter in CueParameter.allCases {
            let check = NSButton(checkboxWithTitle: title(parameter), target: self, action: #selector(toggleField(_:)))
            check.identifier = NSUserInterfaceItemIdentifier(parameter.rawValue)
            check.widthAnchor.constraint(equalToConstant: 165).isActive = true
            let stored = label("—", size: 11), current = label("—", size: 11)
            for value in [stored, current] {
                value.lineBreakMode = .byTruncatingTail; value.maximumNumberOfLines = 1
                // Long geometry/stroke values belong in the tooltip. Their
                // intrinsic text width must not enlarge the entire window.
                value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                value.setContentHuggingPriority(.defaultLow, for: .horizontal)
            }
            let row = stack([check, stored, current], vertical: false, spacing: 10)
            for value in [stored, current] { value.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.5, constant: -92.5).isActive = true }
            row.heightAnchor.constraint(equalToConstant: 25).isActive = true
            checkboxes[parameter] = check; storedLabels[parameter] = stored; currentLabels[parameter] = current
            rows.append(row)
        }
        let matrix = stack(rows, spacing: 3)
        for row in rows { row.widthAnchor.constraint(equalTo: matrix.widthAnchor).isActive = true }
        let saveRow = stack([saveButton, recaptureButton], vertical: false)
        let captureRow = stack([captureFullButton, captureSelectiveButton], vertical: false)
        let saveHelp = label("Save changes the stored scene’s name, timing and field selection. It keeps its captured values.", size: 11)
        let captureHelp = label("Capture creates a new scene from current values. Recapture replaces the selected scene’s values.", size: 11)
        let timelineHelp = label("GO recalls the saved scene, including its saved mask. Timeline automation remains active and may override fields.", size: 11)
        for value in [summary, warning, saveHelp, captureHelp, timelineHelp] {
            value.maximumNumberOfLines = 0; value.lineBreakMode = .byWordWrapping
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        for value in [heading, surfaceCaption] {
            value.lineBreakMode = .byTruncatingTail
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        warning.textColor = .systemOrange
        let right = FlippedStackView(views: [heading, metadata, timing, summary, warning, surfaceCaption,
                                           fieldActions, fieldHeader, matrix, saveRow, saveHelp, captureRow, captureHelp, timelineHelp])
        right.orientation = .vertical; right.alignment = .leading; right.spacing = 9
        right.translatesAutoresizingMaskIntoConstraints = false
        for view in [metadata, timing, summary, warning, surfaceCaption, fieldActions, fieldHeader, matrix, saveRow, saveHelp, captureRow, captureHelp, timelineHelp] {
            view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        }
        let rightScroll = scroll(right)
        let work = stack([leftScroll, rightScroll], vertical: false, spacing: 16)
        work.alignment = .top
        rightScroll.widthAnchor.constraint(equalTo: work.widthAnchor, constant: -291).isActive = true
        right.widthAnchor.constraint(equalTo: rightScroll.contentView.widthAnchor, constant: -15).isActive = true
        leftScroll.heightAnchor.constraint(equalTo: work.heightAnchor).isActive = true
        rightScroll.heightAnchor.constraint(equalTo: work.heightAnchor).isActive = true
        fill(work, in: content, inset: 14)
    }
    private func bind() {
        scopePicker.actionBlock = { [weak self] _ in self?.updateFields(); self?.reloadSurfaceTable() }
        allButton.actionBlock = { [weak self] in self?.setSurfaceFields(Set(CueParameter.allCases)) }
        clearButton.actionBlock = { [weak self] in self?.setSurfaceFields([]) }
        clearAllButton.actionBlock = { [weak self] in self?.fields.removeAll(); self?.updateFields(); self?.reloadSurfaceTable() }
        saveButton.actionBlock = { [weak self] in self?.save() }
        recaptureButton.actionBlock = { [weak self] in self?.recapture() }
        captureFullButton.actionBlock = { [weak self] in self?.capture(scope: .full) }
        captureSelectiveButton.actionBlock = { [weak self] in self?.capture(scope: .selective) }
        goButton.actionBlock = { [weak self] in
            guard let self, let editor = self.editor, let index = editor.project.cues.firstIndex(where: { $0.id == self.selectedCueID }) else { return }
            editor.goCue(index: index)
        }
        deleteButton.actionBlock = { [weak self] in
            guard let self, let editor = self.editor, let id = self.selectedCueID else { return }
            self.perform { try editor.cueDelete(id: id); self.selectedCueID = nil }
        }
    }
    func newDraft() {
        selectedCueID = nil; loadedCue = nil; fields.removeAll()
        draftInitialized = true
        nameField.stringValue = "Scene \((editor?.project.cues.count ?? 0) + 1)"
        durationField.stringValue = "1"; followField.stringValue = ""; scopePicker.selectItem(at: 1)
        if let id = editor?.selectedID { selectedSurfaceID = id; fields[id] = [.opacity] }
        refresh()
    }
    func selectCue(id: UUID?) {
        guard let id else { newDraft(); return }
        selectedCueID = id; loadedCue = nil; refresh()
    }
    func refresh() {
        guard let editor else { return }
        refreshing = true; defer { refreshing = false }
        if selectedCueID != nil && selectedCue == nil { selectedCueID = nil }
        if let cue = selectedCue {
            if loadedCue != cue {
                nameField.stringValue = cue.name; durationField.stringValue = String(cue.duration)
                followField.stringValue = cue.followAfter.map { String($0) } ?? ""
                scopePicker.selectItem(at: cue.scope == .full ? 0 : 1)
                fields = Dictionary(uniqueKeysWithValues: cue.surfaces.map { ($0.id, Set<CueParameter>()) })
                if cue.scope == .full { for surface in cue.surfaces { fields[surface.id] = Set(CueParameter.allCases) } }
                else { for binding in cue.bindings { fields[binding.surfaceID] = Set(binding.parameters) } }
                loadedCue = cue
            }
            surfaces = cue.surfaces
        } else {
            if loadedCue != nil { loadedCue = nil; fields.removeAll(); draftInitialized = false }
            surfaces = editor.project.surfaces
            if !draftInitialized {
                nameField.stringValue = "Scene \(editor.project.cues.count + 1)"; scopePicker.selectItem(at: 1)
                durationField.stringValue = "1"; followField.stringValue = ""
                if let id = editor.selectedID, surfaces.contains(where: { $0.id == id }) { fields[id] = [.opacity]; selectedSurfaceID = id }
                draftInitialized = true
            }
        }
        if !surfaces.contains(where: { $0.id == selectedSurfaceID }) { selectedSurfaceID = surfaces.first?.id }
        cueTable.reloadData(); reloadSurfaceTable()
        if let index = editor.project.cues.firstIndex(where: { $0.id == selectedCueID }) { cueTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { cueTable.deselectAll(nil) }
        heading.stringValue = selectedCue == nil ? "New scene draft · capture current values" : "Saved scene · edit fields or recapture explicitly"
        scopePicker.isEnabled = selectedCue == nil
        for button in [saveButton, recaptureButton, goButton, deleteButton] { button.isEnabled = selectedCue != nil }
        updateFields()
    }
    private func reloadSurfaceTable() {
        let wasRefreshing = refreshing; refreshing = true
        surfaceTable.reloadData()
        if let index = surfaces.firstIndex(where: { $0.id == selectedSurfaceID }) { surfaceTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { surfaceTable.deselectAll(nil) }
        refreshing = wasRefreshing
    }
    @objc private func toggleField(_ sender: NSButton) {
        guard let id = selectedSurfaceID, let raw = sender.identifier?.rawValue, let parameter = CueParameter(rawValue: raw) else { return }
        var selected = fields[id] ?? []
        if sender.state == .on { selected.insert(parameter) } else { selected.remove(parameter) }
        fields[id] = selected; reloadSurfaceTable(); updateFields()
    }
    private func setSurfaceFields(_ parameters: Set<CueParameter>) {
        guard let id = selectedSurfaceID else { return }
        fields[id] = parameters; reloadSurfaceTable(); updateFields()
    }
    private func updateFields() {
        let stored = selectedCue?.surfaces.first { $0.id == selectedSurfaceID }
        let current = editor?.project.surfaces.first { $0.id == selectedSurfaceID }
        let selected = selectedSurfaceID.flatMap { fields[$0] } ?? []
        let editable = selectedSurfaceID != nil && draftScope == .selective
        for parameter in CueParameter.allCases {
            checkboxes[parameter]?.state = (draftScope == .full || selected.contains(parameter)) ? .on : .off
            checkboxes[parameter]?.isEnabled = editable
            let savedValue = stored.map { value(parameter, on: $0) } ?? "—"
            let liveValue = current.map { value(parameter, on: $0) } ?? "Missing current target"
            storedLabels[parameter]?.stringValue = savedValue; storedLabels[parameter]?.toolTip = savedValue
            currentLabels[parameter]?.stringValue = liveValue; currentLabels[parameter]?.toolTip = liveValue
        }
        allButton.isEnabled = editable; clearButton.isEnabled = editable; clearAllButton.isEnabled = draftScope == .selective
        let target = stored ?? current
        surfaceCaption.stringValue = target.map { "\($0.name) · \($0.id.uuidString.prefix(8))" } ?? "Select a surface"
        let count = draftBindings.reduce(0) { $0 + $1.parameters.count }
        summary.stringValue = draftScope == .full
            ? "Full snapshot: recalls the saved surface list, order and surface fields. Groups, media clocks and timeline are outside the snapshot."
            : "Selective draft: \(count) fields on \(draftBindings.count) surfaces. Unselected fields, surface order, groups and media clocks stay current."
        let currentIDs = Set(editor?.project.surfaces.map(\.id) ?? [])
        let missing = draftBindings.filter { !currentIDs.contains($0.surfaceID) }.count
        let savedMissing = selectedCue.map { cue in cue.scope == .selective ? cue.bindings.filter { !currentIDs.contains($0.surfaceID) }.count : 0 } ?? 0
        if savedMissing > 0 || (draftScope == .selective && missing > 0) {
            warning.stringValue = "Saved scene: \(savedMissing) missing target(s), skipped by GO. Draft: \(missing) missing target(s); Capture/Recapture requires current targets."
        } else if selectedCue != nil {
            warning.stringValue = "Saved scope is fixed. Capture a new full or selective scene to change scope; New draft uses current surface rows. Save keeps captured values."
        } else { warning.stringValue = "Choose surface fields, then Capture selective; Capture full always stores all current surfaces." }
        captureSelectiveButton.isEnabled = !draftBindings.isEmpty
    }
    private func number(_ field: NSTextField, name: String) throws -> Double {
        guard let value = Double(field.stringValue), value.isFinite, (0...86400).contains(value) else {
            throw ProjectError.invalid("\(name) must be a finite number from 0 to 86400 seconds")
        }
        return value
    }
    private func timing() throws -> (Double, Double?) {
        let duration = try number(durationField, name: "Transition")
        let follow = followField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try number(followField, name: "Follow")
        return (duration, follow)
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); loadedCue = nil; refresh() }
        catch { editor?.showError(error) }
    }
    private func save() {
        guard let editor, let id = selectedCueID else { return }
        let bindings = draftScope == .full ? [] : draftBindings
        perform { let (duration, follow) = try timing(); try editor.cueUpdate(id: id, name: nameField.stringValue, scope: draftScope, bindings: bindings, duration: duration, followAfter: follow) }
    }
    private func recapture() {
        guard let editor, let cue = selectedCue else { return }
        guard cue.scope == draftScope else { editor.showError(ProjectError.invalid("Capture a new scene to change scope")); return }
        let bindings = draftBindings
        perform { try editor.cueRecapture(id: cue.id, bindings: bindings) }
    }
    private func capture(scope: CueScope) {
        guard let editor else { return }
        let bindings = scope == .full ? [] : draftBindings
        perform { let (duration, follow) = try timing(); selectedCueID = try editor.cueCreate(name: nameField.stringValue, scope: scope, bindings: bindings, duration: duration, followAfter: follow) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === cueTable ? editor?.project.cues.count ?? 0 : surfaces.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === cueTable {
            guard let cues = editor?.project.cues, cues.indices.contains(row) else { return nil }
            let cue = cues[row]
            return label("\(cue.scope == .full ? "Full" : "Selective") · \(cue.name)", size: 11)
        }
        guard surfaces.indices.contains(row) else { return nil }
        let surface = surfaces[row], count = draftScope == .full ? CueParameter.allCases.count : fields[surface.id]?.count ?? 0
        let missing = editor?.project.surfaces.contains(where: { $0.id == surface.id }) != true
        return label("\(surface.name) · \(count) fields\(missing ? " · missing" : "")", size: 11)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing, let table = notification.object as? NSTableView else { return }
        if table === cueTable {
            let row = cueTable.selectedRow
            guard let cues = editor?.project.cues, cues.indices.contains(row) else { return }
            selectedCueID = cues[row].id; loadedCue = nil; refresh()
        } else if surfaces.indices.contains(surfaceTable.selectedRow) {
            selectedSurfaceID = surfaces[surfaceTable.selectedRow].id; updateFields()
        }
    }
    private func title(_ parameter: CueParameter) -> String {
        switch parameter {
        case .opacity: return "Opacity"
        case .brightness: return "Brightness"
        case .gamma: return "Gamma"
        case .color: return "RGB color"
        case .feather: return "Feather"
        case .blendMode: return "Blend mode"
        case .visibility: return "Visibility"
        case .source: return "Media / generator"
        case .input: return "Input UV"
        case .outputGeometry: return "Output / mesh / parent"
        case .shape: return "Shape / stroke"
        case .mask: return "Source UV mask"
        case .routing: return "Output routing"
        }
    }
    private func value(_ parameter: CueParameter, on surface: Surface) -> String {
        func n(_ number: Double) -> String { String(format: "%.4g", number) }
        func points(_ values: [Point2]) -> String { values.map { "\(n($0.x)),\(n($0.y))" }.joined(separator: " · ") }
        switch parameter {
        case .opacity: return n(surface.opacity)
        case .brightness: return n(surface.brightness)
        case .gamma: return n(surface.gamma)
        case .color: return surface.color.map(n).joined(separator: " / ")
        case .feather: return n(surface.feather)
        case .blendMode: return surface.blendMode
        case .visibility: return surface.enabled ? "Visible" : "Hidden"
        case .source:
            if let id = surface.mediaID { return editor?.sourceName(for:id) ?? "Media \(id.uuidString.prefix(8))" }
            return "Generator: \(surface.generator)"
        case .input: return points(surface.input)
        case .outputGeometry:
            let parent = surface.groupID.map { String($0.uuidString.prefix(8)) } ?? "none"
            return "\(points(surface.output)); mesh \(surface.meshColumns)×\(surface.meshRows): \(points(surface.mesh)); parent \(parent)"
        case .shape:
            let nodes = surface.stroke.nodes.map { "a:\(points([$0.anchor])) in:\(points([$0.incoming])) out:\(points([$0.outgoing]))" }.joined(separator: "; ")
            return "\(surface.shape.rawValue) · width \(n(surface.stroke.width)) · \(surface.stroke.closed ? "closed" : "open"); \(nodes)"
        case .mask: return surface.mask.isEmpty ? "No mask" : points(surface.mask)
        case .routing:
            guard let id = surface.outputID else { return "All outputs" }
            return editor?.project.outputs.first(where: { $0.id == id })?.name ?? "Output \(id.uuidString.prefix(8))"
        }
    }
}
#endif
