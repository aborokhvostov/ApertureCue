#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import MappingCore

extension EditorController {
    @objc func showSchedule() {
        if showScheduleWindow == nil { showScheduleWindow = ShowScheduleWindow(editor: self) }
        showScheduleWindow?.refresh()
        showScheduleWindow?.showWindow(nil)
        showScheduleWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func resetShowSchedule() {
        showScheduleRuntime.reset()
        showScheduleWindow?.close()
        showScheduleWindow = nil
    }

    func setShowScheduleArmed(_ armed: Bool, at date: Date) throws {
        if armed {
            try showScheduleRuntime.arm(project.showSchedule, cueIDs: Set(project.cues.map(\.id)), at: date)
        } else {
            showScheduleRuntime.disarm()
        }
        showScheduleWindow?.updateArmedStatus()
    }

    func reconcileShowSchedule(at date: Date = Date()) {
        guard showScheduleRuntime.isArmed, !showScheduleRuntime.isConfigured(for: project.showSchedule) else { return }
        do {
            try showScheduleRuntime.configure(project.showSchedule, cueIDs: Set(project.cues.map(\.id)), at: date)
        } catch {
            showScheduleRuntime.disarm()
            workMessage = "Schedule disarmed • " + error.localizedDescription
        }
    }

    @discardableResult
    func pollShowSchedule(at date: Date) -> ShowScheduleTrigger? {
        guard let trigger = showScheduleRuntime.poll(at: date),
              let index = project.cues.firstIndex(where: { $0.id == trigger.cueID }) else { return nil }
        let success = goCue(index: index, interactive: false)
        if let entry = project.showSchedule.entries.first(where: { $0.id == trigger.entryID }) {
            showScheduleWindow?.recordAttempt(entry: entry.name, at: trigger.time, succeeded: success)
        }
        return success ? trigger : nil
    }

    func saveShowScheduleEntries(_ entries: [ShowScheduleEntry], replacing id: UUID? = nil, at date: Date = Date()) throws {
        var candidate = project
        if let id {
            guard let index = candidate.showSchedule.entries.firstIndex(where: { $0.id == id }) else {
                throw ProjectError.invalid("schedule entry no longer exists")
            }
            candidate.showSchedule.entries.replaceSubrange(index...index, with: entries)
        } else {
            candidate.showSchedule.entries.append(contentsOf: entries)
        }
        try ProjectStore.validate(candidate)
        if showScheduleRuntime.isArmed {
            try showScheduleRuntime.configure(candidate.showSchedule, cueIDs: Set(candidate.cues.map(\.id)), at: date)
        }
        mutate(id == nil ? "Add scheduled scene" : (entries.isEmpty ? "Delete scheduled scene" : "Edit scheduled scene")) { $0 = candidate }
    }
}

@MainActor final class ShowScheduleWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var editor: EditorController?
    private let table = NSTableView()
    private let status = label("")
    private let lastAttempt = label("")
    private var armButton: ActionButton!
    private var addButton: ActionButton!
    private var editButton: ActionButton!
    private var removeButton: ActionButton!
    private var importButton: ActionButton!
    private var displayed: [ShowScheduleEntry] = []
    private var cueNames: [UUID: String] = [:]
    private var importerActive = false
    private let documentToken: UUID

    init(editor: EditorController) {
        self.editor = editor
        documentToken = editor.documentGeneration
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 365),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Show Schedule"
        window.contentMinSize = NSSize(width: 700, height: 270)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        guard let content = window.contentView else { return }

        for (key, title, width) in [("event", "Event", 185.0), ("start", "Local start and zone", 250),
                                     ("repeat", "Repeat", 85), ("scene", "Scene", 135)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Scheduled scenes")
        let viewport = scroll(table)
        let hint = label("Arm this document to recall scheduled scenes. Reopening starts disarmed; missed starts older than 30 seconds are skipped.", size: 11)
        hint.lineBreakMode = .byWordWrapping
        hint.cell?.wraps = true
        hint.maximumNumberOfLines = 0
        hint.preferredMaxLayoutWidth = 610
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lastAttempt.lineBreakMode = .byTruncatingTail
        lastAttempt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        armButton = ActionButton("Arm schedule") { [weak self] in self?.toggleArmed() }
        addButton = ActionButton("Add event…") { [weak self] in self?.editEntry(nil) }
        editButton = ActionButton("Edit event…") { [weak self] in
            guard let self, let entry = self.selectedEntry else { return }
            self.editEntry(entry)
        }
        removeButton = ActionButton("Delete event") { [weak self] in self?.removeEntry() }
        importButton = ActionButton("Import ICS…") { [weak self] in self?.importCalendar() }
        let actions = stack([armButton, addButton, editButton, removeButton, importButton], vertical: false)
        let rows = stack([actions, status, hint, viewport, lastAttempt])
        fill(rows, in: content, inset: 14)
        let fullWidthRows: [NSView] = [hint, viewport, lastAttempt]
        for row in fullWidthRows { row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true }
        viewport.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var selectedEntry: ShowScheduleEntry? {
        displayed.indices.contains(table.selectedRow) ? displayed[table.selectedRow] : nil
    }

    func refresh() {
        guard let editor, editor.documentGeneration == documentToken else { return }
        let entries = editor.project.showSchedule.entries
        let names = editor.project.cues.reduce(into: [UUID: String]()) { $0[$1.id] = $1.name }
        if entries != displayed || names != cueNames {
            let selected = selectedEntry?.id
            displayed = entries
            cueNames = names
            table.reloadData()
            if let index = displayed.firstIndex(where: { $0.id == selected }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        updateArmedStatus()
    }

    func updateArmedStatus() {
        armButton.title = editor?.showScheduleRuntime.isArmed == true ? "Disarm schedule" : "Arm schedule"
        status.stringValue = editor?.showScheduleRuntime.isArmed == true ? "Armed for this session" : "Disarmed"
        updateButtons()
    }

    func recordAttempt(entry: String, at time: Date, succeeded: Bool) {
        let timestamp = ISO8601DateFormatter().string(from: time)
        lastAttempt.stringValue = succeeded ? "Recalled \(entry) · \(timestamp)" : "Could not recall \(entry) · \(timestamp)"
    }

    private func updateButtons() {
        let canAdd = !cueNames.isEmpty && displayed.count < ShowSchedule.maximumEntries
        armButton.isEnabled = !displayed.isEmpty || editor?.showScheduleRuntime.isArmed == true
        addButton.isEnabled = canAdd
        importButton.isEnabled = canAdd && !importerActive
        editButton.isEnabled = selectedEntry != nil
        removeButton.isEnabled = selectedEntry != nil
    }

    private func toggleArmed() {
        guard let editor, editor.documentGeneration == documentToken else { return }
        do { try editor.setShowScheduleArmed(!editor.showScheduleRuntime.isArmed, at: Date()) }
        catch { editor.showError(error) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard displayed.indices.contains(row) else { return nil }
        let entry = displayed[row]
        let text: String
        switch column?.identifier.rawValue {
        case "event": text = entry.name
        case "start": text = "\(entry.localStart) · \(entry.timeZoneID)"
        case "repeat": text = entry.recurrence?.frequency.rawValue.capitalized ?? "Once"
        default: text = cueNames[entry.cueID] ?? "Missing scene"
        }
        let field = label(text)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func removeEntry() {
        guard let editor, editor.documentGeneration == documentToken, let entry = selectedEntry else { return }
        do { try editor.saveShowScheduleEntries([], replacing: entry.id) }
        catch { editor.showError(error) }
    }

    private func cuePicker(_ cues: [Cue], selected: UUID? = nil) -> ActionPopUp {
        let labels = cues.enumerated().map { "\($0.offset + 1). \($0.element.name.prefix(80))" }
        return ActionPopUp(items: labels, selected: cues.firstIndex(where: { $0.id == selected }) ?? 0, action: { _ in })
    }

    private func form(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [label($0.0), $0.1] })
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 304
        let measured = grid.fittingSize
        grid.frame = NSRect(x: 0, y: 0, width: max(440, measured.width),
                            height: max(CGFloat(rows.count * 30), measured.height))
        return grid
    }

    private func editEntry(_ previous: ShowScheduleEntry?) {
        guard let editor, editor.documentGeneration == documentToken, !editor.project.cues.isEmpty else { return }
        let cues = editor.project.cues
        let zoneID = previous?.timeZoneID ?? TimeZone.current.identifier
        let proposed = Date().addingTimeInterval(300)
        let proposedStart = (try? ShowScheduleICS.localStart(for: proposed, timeZoneID: zoneID)) ?? ""
        let name = ActionField(previous?.name ?? "Scheduled scene", action: { _ in })
        let start = ActionField(previous?.localStart ?? proposedStart, action: { _ in })
        let zone = ActionField(zoneID, action: { _ in })
        let rule = ActionField(previous?.recurrence.map(ShowScheduleICS.formatRecurrence) ?? "", action: { _ in })
        let cue = cuePicker(cues, selected: previous?.cueID)
        let alert = NSAlert()
        alert.messageText = previous == nil ? "Add scheduled scene" : "Edit scheduled scene"
        alert.informativeText = "Use YYYYMMDDTHHMMSS for the local start and a named time zone such as Europe/Moscow. Leave Repeat blank for a single event, or enter FREQ=DAILY or FREQ=WEEKLY;INTERVAL=2. Imported exclusions stay with the event."
        alert.accessoryView = form([("Name", name), ("Local start", start), ("Time zone", zone), ("Scene", cue), ("Repeat rule", rule)])
        alert.addButton(withTitle: "Save event")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, editor.documentGeneration == documentToken,
              cues.indices.contains(cue.indexOfSelectedItem) else { return }
        if let previous, !editor.project.showSchedule.entries.contains(previous) {
            editor.showError(ProjectError.invalid("schedule entry changed while the form was open"))
            return
        }
        do {
            let text = rule.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let recurrence = text.isEmpty ? nil : try ShowScheduleICS.parseRecurrence(text)
            let entry = ShowScheduleEntry(id: previous?.id ?? UUID(), name: name.stringValue,
                                          cueID: cues[cue.indexOfSelectedItem].id, localStart: start.stringValue,
                                          timeZoneID: zone.stringValue, recurrence: recurrence,
                                          excludedStarts: previous?.excludedStarts ?? [], sourceUID: previous?.sourceUID)
            try editor.saveShowScheduleEntries([entry], replacing: previous?.id)
        } catch { editor.showError(error) }
    }

    private func importCalendar() {
        guard let editor, editor.documentGeneration == documentToken, !editor.project.cues.isEmpty, !importerActive else { return }
        let cues = editor.project.cues
        let cue = cuePicker(cues)
        let zone = ActionField(TimeZone.current.identifier, action: { _ in })
        let alert = NSAlert()
        alert.messageText = "Import scheduled scenes"
        alert.informativeText = "Every event in the chosen local ICS file will recall the selected scene. A time without TZID or Z uses the floating time zone below."
        alert.accessoryView = form([("Scene", cue), ("Floating time zone", zone)])
        alert.addButton(withTitle: "Choose ICS file…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, editor.documentGeneration == documentToken,
              cues.indices.contains(cue.indexOfSelectedItem) else { return }
        let cueID = cues[cue.indexOfSelectedItem].id
        let zoneID = zone.stringValue
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let ics = UTType(filenameExtension: "ics") { panel.allowedContentTypes = [ics] }
        guard panel.runModal() == .OK, let url = panel.url, editor.documentGeneration == documentToken else { return }
        importerActive = true
        updateButtons()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Self.readCalendar(url, cueID: cueID, zoneID: zoneID) }
            DispatchQueue.main.async { [weak self] in
                guard let self, let editor = self.editor, editor.documentGeneration == self.documentToken else { return }
                self.importerActive = false
                self.updateButtons()
                do { try editor.saveShowScheduleEntries(result.get()) }
                catch { editor.showError(error) }
            }
        }
    }

    nonisolated static func readCalendar(_ url: URL, cueID: UUID, zoneID: String) throws -> [ShowScheduleEntry] {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= ShowScheduleICS.maximumBytes else {
            throw ProjectError.invalid("ICS import requires a regular file at most 256 KiB")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= ShowScheduleICS.maximumBytes {
            guard let chunk = try handle.read(upToCount: min(32_768, ShowScheduleICS.maximumBytes + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return try ShowScheduleICS.parse(data, cueID: cueID, floatingTimeZoneID: zoneID)
    }
}
#endif
