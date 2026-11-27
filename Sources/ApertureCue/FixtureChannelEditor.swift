#if os(macOS)
import AppKit
import MappingCore

@MainActor final class FixtureChannelEditor: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    struct Selection { let definition: FixtureDefinition? }

    private let table = NSTableView()
    private let fixture: Fixture
    private let surfaces: [Surface]
    private var channels: [FixtureChannel]
    private let editRow = ActionButton("Edit…", action: {})
    private let deleteRow = ActionButton("Remove", action: {})
    private let up = ActionButton("Up", action: {})
    private let down = ActionButton("Down", action: {})
    private let status = label("")
    private var selection: Selection?

    init(fixture: Fixture, surfaces: [Surface]) {
        self.fixture = fixture
        self.surfaces = surfaces
        channels = fixture.definition?.channels ?? Self.fromPreset(fixture.channelOrder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Fixture channels · \(fixture.name)"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        for (name, key, width) in [("Name", "name", 150.0), ("Source", "role", 100.0),
                                   ("Slots", "slots", 105.0), ("Value / automation", "value", 290.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = name
            column.width = width
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(editSelected)
        table.setAccessibilityLabel("Channel order")
        let list = scroll(table)
        list.heightAnchor.constraint(greaterThanOrEqualToConstant: 266).isActive = true
        let actions = stack([ActionButton("Add channel…") { [weak self] in self?.change(nil) }, editRow, deleteRow, up, down],
                            vertical: false)
        editRow.actionBlock = { [weak self] in self?.editSelected() }
        deleteRow.actionBlock = { [weak self] in self?.removeSelected() }
        up.actionBlock = { [weak self] in self?.move(-1) }
        down.actionBlock = { [weak self] in self?.move(1) }
        let finish = stack([
            ActionButton("Save channels") { [weak self] in self?.save() },
            ActionButton("Use \(fixture.channelOrder) preset") { [weak self] in self?.finish(Selection(definition: nil)) },
            ActionButton("Cancel") { [weak self] in self?.finish(nil) }
        ], vertical: false)
        let body = stack([actions, list, status, finish], spacing: 9)
        list.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.lineBreakMode = .byTruncatingTail
        if let content = window.contentView { fill(body, in: content, inset: 14) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func edit() -> Selection? {
        guard let window else { return nil }
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return selection
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(nil)
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { channels.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard channels.indices.contains(row), let tableColumn else { return nil }
        let channel = channels[row]
        let text: String
        switch tableColumn.identifier.rawValue {
        case "name": text = channel.name
        case "role": text = channel.source.rawValue
        case "slots": text = Self.encodingTitle(channel.encoding)
        default:
            if let drive = channel.drive {
                let surface = surfaces.first { $0.id == drive.surfaceID }?.name ?? "Unavailable surface"
                text = "\(surface) · \(drive.parameter) · fallback \(channel.value)"
            } else {
                text = channel.source.hasManualValue ? String(channel.value) : "—"
            }
        }
        let result = NSTextField(labelWithString: text)
        result.toolTip = text
        result.lineBreakMode = .byTruncatingTail
        return result
    }

    private func refresh(_ row: Int? = nil) {
        table.reloadData()
        if let row, channels.indices.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        let width = FixtureDefinition(channels: channels).slotCount
        let lastSlot = fixture.address + fixture.points.count * width - 1
        status.stringValue = "\(width) slots per pixel · last address \(lastSlot)"
        updateButtons()
    }

    private func updateButtons() {
        let row = table.selectedRow
        editRow.isEnabled = channels.indices.contains(row)
        deleteRow.isEnabled = editRow.isEnabled
        up.isEnabled = row > 0
        down.isEnabled = row >= 0 && row + 1 < channels.count
    }

    @objc private func editSelected() {
        if channels.indices.contains(table.selectedRow) { change(table.selectedRow) }
    }

    private func removeSelected() {
        let row = table.selectedRow
        guard channels.indices.contains(row) else { return }
        channels.remove(at: row)
        refresh(min(row, channels.count - 1))
    }

    private func move(_ offset: Int) {
        let row = table.selectedRow
        guard channels.indices.contains(row), channels.indices.contains(row + offset) else { return }
        channels.swapAt(row, row + offset)
        refresh(row + offset)
    }

    private func change(_ row: Int?) {
        guard row != nil || channels.count < FixtureDefinition.maximumChannels else {
            status.stringValue = "A fixture definition supports up to \(FixtureDefinition.maximumChannels) channels."
            return
        }
        let original = row.map { channels[$0] } ?? FixtureChannel(name: "Channel \(channels.count + 1)", source: .constant)
        let name = ActionField(original.name, action: { _ in })
        name.widthAnchor.constraint(equalToConstant: 278).isActive = true
        let roles = FixtureChannelSource.allCases
        let encodings = FixtureChannelEncoding.allCases
        let rolePicker = ActionPopUp(items: roles.map(\.rawValue), selected: roles.firstIndex(of: original.source) ?? 0, action: { _ in })
        let encodingPicker = ActionPopUp(items: encodings.map(Self.encodingTitle),
                                         selected: encodings.firstIndex(of: original.encoding) ?? 0, action: { _ in })
        let value = ActionField(String(original.value), action: { _ in })
        value.widthAnchor.constraint(equalToConstant: 75).isActive = true
        let parameters = TimelineEngine.parameters
        var surfaceIDs = surfaces.map(\.id)
        var surfaceTitles = surfaces.enumerated().map { "\($0.offset + 1)  \($0.element.name)" }
        if let missing = original.drive?.surfaceID, !surfaceIDs.contains(missing) {
            surfaceIDs.append(missing)
            surfaceTitles.append("Unavailable surface")
        }
        let chosen = surfaceIDs.firstIndex { $0 == original.drive?.surfaceID }.map { $0 + 1 } ?? 0
        let drivePicker = ActionPopUp(items: ["Manual"] + surfaceTitles, selected: chosen, action: { _ in })
        let parameterPicker = ActionPopUp(items: parameters,
                                          selected: parameters.firstIndex { $0 == original.drive?.parameter } ?? 0,
                                          action: { _ in })
        func refreshFields() {
            let manual = roles[rolePicker.indexOfSelectedItem].hasManualValue
            value.isEnabled = manual
            drivePicker.isEnabled = manual
            parameterPicker.isEnabled = manual && drivePicker.indexOfSelectedItem > 0
        }
        rolePicker.actionBlock = { _ in refreshFields() }
        drivePicker.actionBlock = { _ in refreshFields() }
        defer { rolePicker.actionBlock = nil; drivePicker.actionBlock = nil }
        refreshFields()
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 148))
        let body = stack([
            stack([label("Name"), name], vertical: false),
            stack([label("Source"), rolePicker, label("Encoding"), encodingPicker], vertical: false),
            stack([label("Fallback 0–1"), value], vertical: false),
            stack([label("Driven by"), drivePicker, parameterPicker], vertical: false)
        ])
        fill(body, in: accessory, inset: 1)
        let alert = NSAlert()
        alert.messageText = row == nil ? "Add fixture channel" : "Edit fixture channel"
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = accessory
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let source = roles[rolePicker.indexOfSelectedItem]
        guard let fallback = source.hasManualValue ? Double(value.stringValue) : 0,
              (0...1).contains(fallback) else { status.stringValue = "Enter a value from 0 through 1."; return }
        let surfaceIndex = drivePicker.indexOfSelectedItem - 1
        var drive: FixtureSurfaceDrive?
        if source.hasManualValue, surfaceIDs.indices.contains(surfaceIndex) {
            drive = FixtureSurfaceDrive(surfaceID: surfaceIDs[surfaceIndex], parameter: parameters[parameterPicker.indexOfSelectedItem])
        }
        let channel = FixtureChannel(name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), source: source,
                                     encoding: encodings[encodingPicker.indexOfSelectedItem], value: fallback, drive: drive)
        var next = channels
        if let row { next[row] = channel } else { next.append(channel) }
        do {
            try FixtureDefinition(channels: next).validate()
            channels = next
            refresh(row ?? channels.count - 1)
        } catch { status.stringValue = error.localizedDescription }
    }

    private func save() {
        let definition = FixtureDefinition(channels: channels)
        var candidate = fixture
        candidate.definition = definition
        do {
            try FixtureSampler.validate(fixtures: [candidate])
            finish(Selection(definition: definition))
        } catch { status.stringValue = error.localizedDescription }
    }

    private func finish(_ value: Selection?) {
        selection = value
        NSApp.stopModal()
    }

    private static func fromPreset(_ order: String) -> [FixtureChannel] {
        let sources: [Character: FixtureChannelSource] = ["R": .red, "G": .green, "B": .blue, "W": .white]
        return order.compactMap { letter in
            sources[letter].map { FixtureChannel(name: $0.rawValue.capitalized, source: $0) }
        }
    }

    private static func encodingTitle(_ encoding: FixtureChannelEncoding) -> String {
        switch encoding {
        case .eightBit: return "8-bit"
        case .coarseFine: return "16-bit coarse/fine"
        case .fineCoarse: return "16-bit fine/coarse"
        }
    }
}
#endif
