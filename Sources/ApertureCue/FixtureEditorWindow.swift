#if os(macOS)
import AppKit
import MappingCore
import UniformTypeIdentifiers

@MainActor extension EditorController {
    @objc func configureLighting() {
        let editor = fixtureEditorWindow ?? FixtureEditorWindow(editor: self)
        fixtureEditorWindow = editor
        editor.refresh()
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
    }

    func replaceFixturePatch(_ fixtures: [Fixture], label: String) throws {
        var candidate = project
        candidate.fixtures = fixtures
        try ProjectStore.validate(candidate)
        mutate(label) { $0 = candidate }
    }

    @objc func showDMXMonitor() {
        lighting.fixtures = project.fixtures
        lighting.isSampling = true
        lighting.showSimulator()
    }

    @objc func showDMXSequence() {
        lighting.fixtures = project.fixtures
        lighting.sequenceSession.showWindow()
    }

    @objc func showLightingAdapters() {
        lighting.fixtures = project.fixtures
        lighting.isSampling = true
        lighting.lightingAdapterPreview.show()
    }
}

@MainActor final class FixtureEditorWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var editor: EditorController?
    private let table = NSTableView()
    private let edit = ActionButton("Edit patch…", action: {})
    private let custom = ActionButton("Channels…", action: {})
    private let remove = ActionButton("Remove", action: {})
    private let export = ActionButton("Export JSON…", action: {})
    private let status = label("")
    private var rows: [Fixture] = []
    private var generation: UUID?

    init(editor: EditorController) {
        self.editor = editor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 830, height: 470),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "ApertureCue · Fixture Patch"
        window.minSize = NSSize(width: 770, height: 430)
        window.isReleasedWhenClosed = false
        window.center()

        for (title, key, width) in [("Fixture", "name", 230.0), ("Universe / slots", "patch", 134.0),
                                     ("Pixels / profile", "profile", 160.0), ("Sample from", "output", 190.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(editSelection)
        table.setAccessibilityLabel("Patched fixtures")
        edit.actionBlock = { [weak self] in self?.editSelection() }
        custom.actionBlock = { [weak self] in self?.editChannels() }
        remove.actionBlock = { [weak self] in self?.removeSelection() }
        export.actionBlock = { [weak self] in self?.exportLayout() }
        let add = ActionButton("Add fixture…") { [weak self] in self?.editPatch() }
        let importLayout = ActionButton("Import CSV / JSON…") { [weak self] in self?.importLayout() }
        let svg = ActionButton("Add SVG positions…") { [weak self] in self?.addSVG() }
        let monitor = ActionButton("DMX Monitor…") { [weak editor] in editor?.showDMXMonitor() }
        let output = ActionButton("Network output…") { [weak editor] in editor?.showLightingNetwork() }
        let browser = scroll(table)
        let patchActions = stack([add, edit, custom, remove], vertical: false)
        let layoutActions = stack([importLayout, export, svg], vertical: false)
        let outputActions = stack([monitor, output], vertical: false)
        let body = stack([patchActions, browser, layoutActions, NSBox(), outputActions, status], spacing: 9)
        browser.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        browser.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.lineBreakMode = .byTruncatingTail
        if let content = window.contentView { fill(body, in: content, inset: 14) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh(select: UUID? = nil) {
        guard let editor else { return }
        let id = select ?? (generation == editor.documentGeneration ? selected?.id : nil)
        let next = editor.project.fixtures
        let changedDocument = generation != editor.documentGeneration
        rows = next
        generation = editor.documentGeneration
        if changedDocument { status.stringValue = "" }
        table.reloadData()
        if let id, let index = rows.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        updateButtons()
    }

    private var selected: Fixture? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let tableColumn else { return nil }
        let fixture = rows[row]
        let title: String
        switch tableColumn.identifier.rawValue {
        case "name": title = fixture.name
        case "patch":
            let end = fixture.address + fixture.points.count * fixture.channelCountPerPixel - 1
            title = "\(fixture.universe) / \(fixture.address)–\(end)"
        case "profile":
            title = "\(fixture.points.count) · \(fixture.definition == nil ? fixture.channelOrder : "Custom") · \(fixture.channelCountPerPixel) slots"
        default:
            title = fixture.outputID.flatMap { id in editor?.project.outputs.first { $0.id == id }?.name } ?? "All outputs"
        }
        let view = NSTextField(labelWithString: title)
        view.lineBreakMode = .byTruncatingTail
        view.toolTip = title
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private func updateButtons() {
        edit.isEnabled = selected != nil
        custom.isEnabled = selected != nil
        remove.isEnabled = selected != nil
        export.isEnabled = !rows.isEmpty
    }

    @objc private func editSelection() { if let selected { editPatch(previous: selected) } }

    private func editPatch(previous: Fixture? = nil, importedPoints: [Point2]? = nil) {
        guard let editor, let generation else { return }
        let draft = previous ?? Fixture(name: "Fixture \(rows.count + 1)", points: importedPoints ?? [])
        let outputs = editor.project.outputs
        do {
            guard let fixture = try FixturePatchDialog.edit(draft, outputs: outputs),
                  generation == editor.documentGeneration else { return }
            var candidate = editor.project.fixtures
            if let previous {
                guard let index = candidate.firstIndex(of: previous) else {
                    throw ProjectError.invalid("Fixture changed while the editor was open.")
                }
                candidate[index] = fixture
            } else {
                candidate.append(fixture)
            }
            try editor.replaceFixturePatch(candidate, label: previous == nil ? "Add fixture" : "Edit fixture")
            status.stringValue = "Saved \(fixture.name)"
            refresh(select: fixture.id)
        } catch {
            show(error)
        }
    }

    private func editChannels() {
        guard let editor, let previous = selected, let generation else { return }
        let controller = FixtureChannelEditor(fixture: previous, surfaces: editor.project.surfaces)
        guard let value = controller.edit(), generation == editor.documentGeneration else { return }
        do {
            var candidate = editor.project.fixtures
            guard let row = candidate.firstIndex(of: previous) else { return }
            candidate[row].definition = value.definition
            try editor.replaceFixturePatch(candidate, label: "Edit fixture channels")
            status.stringValue = "Updated \(previous.name) channels"
            refresh(select: previous.id)
        } catch { show(error) }
    }

    private func removeSelection() {
        guard let editor, let fixture = selected else { return }
        do {
            try editor.replaceFixturePatch(editor.project.fixtures.filter { $0.id != fixture.id }, label: "Remove fixture")
            status.stringValue = "Removed \(fixture.name)"
            refresh()
        } catch { show(error) }
    }

    private func importLayout() {
        guard let editor, let generation else { return }
        let panel = NSOpenPanel()
        panel.title = "Import fixture layout"
        panel.allowedContentTypes = [.json, .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url, generation == editor.documentGeneration else { return }
        do {
            let format: FixtureLayoutFormat = url.pathExtension.lowercased() == "csv" ? .csv : .json
            let bytes = try readLayoutFile(url)
            let existing = editor.project.fixtures
            let fixtures = try FixtureLayoutImport.decode(bytes, format: format, appendingTo: existing)
            try editor.replaceFixturePatch(fixtures, label: "Import fixture layout")
            status.stringValue = "Imported \(fixtures.count - existing.count) fixtures"
            refresh(select: fixtures.last?.id)
        } catch { show(error) }
    }

    private func addSVG() {
        let panel = NSOpenPanel()
        panel.title = "Choose an SVG with pixel markers"
        if let type = UTType(filenameExtension: "svg") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { editPatch(importedPoints: try FixtureLayout.svgPositions(readLayoutFile(url))) }
        catch { show(error) }
    }

    private func exportLayout() {
        guard let editor else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "FixtureLayout.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(editor.project.fixtures)
            guard data.count <= FixtureLayoutImport.maximumBytes else {
                throw ProjectError.invalid("This patch exceeds the importable JSON file size.")
            }
            try data.write(to: url, options: .atomic)
            status.stringValue = "Exported fixture layout"
        } catch { show(error) }
    }

    private func readLayoutFile(_ url: URL) throws -> Data {
        let cap = FixtureLayoutImport.maximumBytes
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ProjectError.invalid("Select a regular fixture layout file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: cap + 1) ?? Data()
        guard bytes.count <= cap else { throw ProjectError.invalid("Fixture layout file exceeds 1 MiB.") }
        return bytes
    }

    private func show(_ error: Error) {
        status.stringValue = error.localizedDescription
        editor?.showError(error)
    }
}

@MainActor private enum FixturePatchDialog {
    static func edit(_ fixture: Fixture, outputs: [OutputConfig]) throws -> Fixture? {
        let presets = ["RGB", "GRB", "RGBW"]
        let orders = fixture.definition == nil ? presets : presets + ["Custom"]
        let name = field(fixture.name, width: 370)
        let universe = field(String(fixture.universe))
        let address = field(String(fixture.address))
        let selectedOrder = fixture.definition == nil ? (presets.firstIndex(of: fixture.channelOrder) ?? 0) : presets.count
        let order = ActionPopUp(items: orders, selected: selectedOrder, action: { _ in })
        let outputID = outputs.firstIndex { $0.id == fixture.outputID }.map { $0 + 1 } ?? 0
        let output = ActionPopUp(items: ["All outputs"] + outputs.enumerated().map { "\($0.offset + 1)  \($0.element.name)" },
                                 selected: outputID, action: { _ in })
        let canKeep = !fixture.points.isEmpty
        let choices = canKeep ? ["Keep \(fixture.points.count) points", "Line", "Matrix"] : ["Line", "Matrix"]
        let layout = ActionPopUp(items: choices, action: { _ in })
        let start = field(format(fixture.points.first, fallback: "0.1, 0.3"), width: 138)
        let end = field(format(fixture.points.last, fallback: "0.9, 0.7"), width: 138)
        let rows = field("3")
        let columns = field(canKeep ? String(fixture.points.count) : "16")
        let serpentine = NSButton(checkboxWithTitle: "Serpentine", target: nil, action: nil)
        let skipped = field((fixture.skippedPixels ?? []).map(String.init).joined(separator: ","), width: 190)
        skipped.placeholderString = "Zero-based indices"
        let width = field(fixture.sampling.map { String($0.width) } ?? "")
        let height = field(fixture.sampling.map { String($0.height) } ?? "")
        width.placeholderString = "Width"
        height.placeholderString = "Height"
        let box = NSButton(checkboxWithTitle: "Box average", target: nil, action: nil)
        box.state = fixture.sampling == nil ? .off : .on
        let access = NSView(frame: NSRect(x: 0, y: 0, width: 472, height: 255))
        let content = stack([
            stack([label("Fixture"), name], vertical: false),
            stack([label("Universe"), universe, label("Address"), address, order], vertical: false),
            stack([label("Sample from"), output], vertical: false),
            stack([label("Layout"), layout, label("Rows"), rows, label("Columns"), columns, serpentine], vertical: false),
            stack([label("From x,y"), start, label("To x,y"), end], vertical: false),
            stack([label("Skipped positions"), skipped], vertical: false),
            stack([box, width, height], vertical: false)
        ], spacing: 10)
        fill(content, in: access, inset: 2)
        func refreshLayout() {
            let selected = layout.indexOfSelectedItem - (canKeep ? 1 : 0)
            start.isEnabled = selected >= 0
            end.isEnabled = selected >= 0
            columns.isEnabled = selected >= 0
            rows.isEnabled = selected == 1
            serpentine.isEnabled = selected == 1
        }
        layout.actionBlock = { _ in refreshLayout() }
        defer { layout.actionBlock = nil }
        refreshLayout()

        let alert = NSAlert()
        alert.messageText = canKeep ? "Fixture patch" : "New fixture"
        alert.informativeText = "Addresses start at 1. A fixture stays within one universe."
        alert.accessoryView = access
        alert.addButton(withTitle: "Save fixture")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let u = Int(universe.stringValue), let a = Int(address.stringValue),
              outputs.count >= output.indexOfSelectedItem else { throw ProjectError.invalid("Enter a numeric universe and DMX address.") }
        var result = fixture
        result.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.universe = u; result.address = a
        result.outputID = output.indexOfSelectedItem > 0 ? outputs[output.indexOfSelectedItem - 1].id : nil
        if presets.indices.contains(order.indexOfSelectedItem) {
            result.channelOrder = presets[order.indexOfSelectedItem]
            result.definition = nil
        }
        let layoutMode = layout.indexOfSelectedItem - (canKeep ? 1 : 0)
        if layoutMode >= 0 {
            let from = try parsePoint(start.stringValue), to = try parsePoint(end.stringValue)
            guard let col = Int(columns.stringValue) else { throw ProjectError.invalid("Enter the number of columns.") }
            if layoutMode == 0 {
                result.points = try FixtureLayout.line(from: from, to: to, count: col)
            } else {
                guard let row = Int(rows.stringValue) else { throw ProjectError.invalid("Enter the number of rows.") }
                result.points = try FixtureLayout.matrix(from: from, to: to, rows: row, columns: col, serpentine: serpentine.state == .on)
            }
        }
        let skip = skipped.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.skippedPixels = skip.isEmpty ? nil : try skip.split(separator: ",", omittingEmptySubsequences: false).map {
            guard let number = Int($0.trimmingCharacters(in: .whitespaces)) else {
                throw ProjectError.invalid("Skipped positions require comma-separated zero-based indices.")
            }
            return number
        }
        if box.state == .on {
            guard let w = Double(width.stringValue), let h = Double(height.stringValue) else {
                throw ProjectError.invalid("Enter normalized box width and height.")
            }
            result.sampling = FixtureSampling(width: w, height: h)
        } else {
            result.sampling = nil
        }
        try FixtureSampler.validate(fixtures: [result])
        return result
    }

    private static func field(_ value: String, width: CGFloat = 58) -> ActionField {
        let control = ActionField(value, action: { _ in })
        control.widthAnchor.constraint(equalToConstant: width).isActive = true
        return control
    }

    private static func format(_ point: Point2?, fallback: String) -> String {
        point.map { String(format: "%.6g, %.6g", $0.x, $0.y) } ?? fallback
    }

    private static func parsePoint(_ value: String) throws -> Point2 {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              (0...1).contains(x), (0...1).contains(y) else { throw ProjectError.invalid("Use normalized x,y positions from 0 to 1.") }
        return Point2(x, y)
    }
}
#endif
