#if os(macOS)
import AppKit
import MappingCore

@MainActor final class ShowControlWindow: NSWindowController {
    private weak var editor: EditorController?
    private var tracks: [ShowControlTrack] = []
    private var selectedTrackID: UUID?
    private var selectedEventID: UUID?
    private var events: [ShowControlEvent] = []
    private var loadedEvent: ShowControlEvent?

    private let trackPicker = ActionPopUp(items: [], action: { _ in })
    private let eventPicker = ActionPopUp(items: [], action: { _ in })
    private let trackName = ActionField("", action: { _ in })
    private let trackEnabled = NSButton(checkboxWithTitle: "Track enabled", target: nil, action: nil)
    private let saveTrack = ActionButton("Save track", action: {})
    private let deleteTrack = ActionButton("Delete track", action: {})

    private let eventTime = ActionField("", action: { _ in })
    private let kind = ActionPopUp(items: ["OSC", "MIDI Note On", "MIDI Note Off", "MIDI Control Change"], action: { _ in })
    private let oscPort = ActionField("9002", action: { _ in })
    private let oscAddress = ActionField("/show/cue", action: { _ in })
    private let oscType = ActionPopUp(items: ["No argument", "Integer", "Float", "Text", "Boolean"], action: { _ in })
    private let oscValue = ActionField("", action: { _ in })
    private let midiChannel = ActionField("1", action: { _ in })
    private let midiNumber = ActionField("60", action: { _ in })
    private let midiValue = ActionField("100", action: { _ in })
    private let oscRows = NSStackView()
    private let midiRows = NSStackView()
    private let newEvent = ActionButton("New event", action: {})
    private let saveEvent = ActionButton("Save event", action: {})
    private let deleteEvent = ActionButton("Delete event", action: {})

    private let outputButton = ActionButton("Arm outputs", action: {})
    private let clockButton = ActionButton("Arm external clock", action: {})
    private let outputStatus = label("")
    private let clockStatus = label("")
    private let sourceField = ActionField("show", action: { _ in })
    private let clockPort = ActionField("9001", action: { _ in })
    private let feedback = label("")

    init(editor: EditorController) {
        self.editor = editor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Show Control · OSC, MIDI and Clock"
        window.minSize = NSSize(width: 660, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        buildUI()
        bindActions()
        loadEvent(nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        func width(_ view: NSView, _ points: CGFloat) { view.widthAnchor.constraint(equalToConstant: points).isActive = true }
        for field in [eventTime, oscPort, midiChannel, midiNumber, midiValue, clockPort] { width(field, 70) }
        for field in [trackName, oscValue, oscAddress] { width(field, 226) }
        width(sourceField, 170)
        for picker in [trackPicker, eventPicker] { width(picker, 400) }
        let oscDestination = stack([label("Local UDP port"), oscPort, label("Address"), oscAddress], vertical: false)
        let oscArgument = stack([label("Argument"), oscType, oscValue], vertical: false)
        oscRows.orientation = .vertical
        oscRows.alignment = .leading
        oscRows.addArrangedSubview(oscDestination)
        oscRows.addArrangedSubview(oscArgument)
        midiRows.orientation = .horizontal
        for view in [label("Channel"), midiChannel, label("Note / CC"), midiNumber, label("Value"), midiValue] {
            midiRows.addArrangedSubview(view)
        }

        let rows = FlippedStackView(views: [
            label("Timed output tracks", bold: true),
            stack([trackPicker, ActionButton("Add track") { [weak self] in self?.createTrack() }], vertical: false),
            stack([label("Name"), trackName, trackEnabled], vertical: false),
            stack([saveTrack, deleteTrack], vertical: false),
            NSBox(),
            stack([eventPicker, newEvent], vertical: false),
            stack([label("Timeline seconds"), eventTime, kind], vertical: false),
            oscRows, midiRows,
            stack([saveEvent, deleteEvent], vertical: false),
            NSBox(),
            label("Output and external clock for this session", bold: true),
            stack([outputButton, outputStatus], vertical: false),
            stack([label("Clock source"), sourceField, label("UDP port"), clockPort], vertical: false),
            stack([clockButton, clockStatus], vertical: false),
            feedback
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        for status in [outputStatus, clockStatus, feedback] {
            status.lineBreakMode = .byTruncatingTail
            status.maximumNumberOfLines = 1
            status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        feedback.textColor = .systemOrange
        let viewport = scroll(rows)
        fill(viewport, in: content, inset: 16)
        rows.widthAnchor.constraint(equalTo: viewport.contentView.widthAnchor, constant: -15).isActive = true
        for row in rows.arrangedSubviews where row !== oscRows && row !== midiRows {
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            if let box = row as? NSBox { box.boxType = .separator }
        }
    }

    private func bindActions() {
        trackPicker.actionBlock = { [weak self] index in
            guard let self, self.tracks.indices.contains(index) else { return }
            self.selectedTrackID = self.tracks[index].id
            self.selectTrack()
        }
        eventPicker.actionBlock = { [weak self] index in
            guard let self else { return }
            self.loadEvent(index > 0 && self.events.indices.contains(index - 1) ? self.events[index - 1] : nil)
            self.updateAvailability()
        }
        kind.actionBlock = { [weak self] _ in self?.updateAvailability() }
        oscType.actionBlock = { [weak self] _ in self?.updateAvailability() }
        newEvent.actionBlock = { [weak self] in self?.loadEvent(nil); self?.updateAvailability() }
        saveTrack.actionBlock = { [weak self] in self?.updateTrack() }
        deleteTrack.actionBlock = { [weak self] in self?.removeTrack() }
        saveEvent.actionBlock = { [weak self] in self?.updateEvent() }
        deleteEvent.actionBlock = { [weak self] in self?.removeEvent() }
        outputButton.actionBlock = { [weak self] in
            self?.perform { editor in try editor.setShowControlOutputArmed(!editor.showControlSession.outputsArmed) }
        }
        clockButton.actionBlock = { [weak self] in
            self?.perform { editor in
                guard let self else { return }
                if editor.showControlSession.listener != nil { editor.disarmExternalShowClock(); return }
                guard let port = UInt16(self.clockPort.stringValue), port > 0 else { throw ProjectError.invalid("enter a clock port in 1…65535") }
                try editor.armExternalShowClock(source: self.sourceField.stringValue, port: port)
            }
        }
    }

    func refresh() {
        guard let editor else { return }
        if tracks != editor.project.showControlTracks {
            let previous = tracks.first { $0.id == selectedTrackID }
            tracks = editor.project.showControlTracks
            if !tracks.contains(where: { $0.id == selectedTrackID }) { selectedTrackID = tracks.first?.id }
            let current = tracks.first { $0.id == selectedTrackID }
            refreshTrackPicker()
            if previous?.id != current?.id {
                selectTrack()
            } else {
                if previous?.name != current?.name || previous?.enabled != current?.enabled { loadTrackFields() }
                if previous?.events != current?.events {
                    loadEvents()
                    if let id = selectedEventID {
                        let updated = events.first { $0.id == id }
                        if updated != loadedEvent { loadEvent(updated) }
                    }
                }
            }
        }
        updateAvailability()
        refreshStatus()
    }

    func refreshStatus() {
        guard let session = editor?.showControlSession else { return }
        let armed = session.listener != nil
        outputButton.title = session.outputsArmed ? "Disarm outputs" : "Arm outputs"
        outputStatus.stringValue = session.outputStatus
        clockButton.title = armed ? "Disarm external clock" : "Arm external clock"
        sourceField.isEnabled = !armed
        clockPort.isEnabled = !armed
        switch session.clock.state {
        case .off: clockStatus.stringValue = "Local show clock"
        case .waiting: clockStatus.stringValue = "Waiting for \(session.clock.source ?? "")"
        case .locked: clockStatus.stringValue = "External clock locked"
        case .held: clockStatus.stringValue = "Held by marker or show end"
        case .lost: clockStatus.stringValue = "Clock lost · playback paused"
        }
    }

    private var activeTrack: ShowControlTrack? { tracks.first { $0.id == selectedTrackID } }

    private func refreshTrackPicker() {
        trackPicker.removeAllItems()
        trackPicker.addItems(withTitles: tracks.enumerated().map { index, track in
            "\(index + 1). \(track.name)\(track.enabled ? "" : " (disabled)")"
        })
        if let index = tracks.firstIndex(where: { $0.id == selectedTrackID }) { trackPicker.selectItem(at: index) }
    }

    private func loadTrackFields() {
        trackName.stringValue = activeTrack?.name ?? ""
        trackEnabled.state = activeTrack?.enabled == true ? .on : .off
    }

    private func loadEvents() {
        events = ShowControlTrack.events(activeTrack.map { track in
            var visibleTrack = track
            visibleTrack.enabled = true
            return [visibleTrack]
        } ?? [])
        updateEventPicker()
    }

    private func updateEventPicker() {
        eventPicker.removeAllItems()
        eventPicker.addItem(withTitle: "New event draft")
        eventPicker.addItems(withTitles: events.enumerated().map { index, event in
            let name: String
            switch event.command {
            case .osc(_, let address, _): name = address
            case .midi(let kind, let channel, let number, _): name = "\(kind.rawValue) ch \(channel) · \(number)"
            }
            return "\(index + 1). \(String(format: "%.3f", event.time)) s · \(name)"
        })
        eventPicker.selectItem(at: events.firstIndex(where: { $0.id == selectedEventID }).map { $0 + 1 } ?? 0)
    }

    private func selectTrack() {
        loadTrackFields()
        loadEvents()
        loadEvent(nil)
        updateAvailability()
    }

    private func loadEvent(_ event: ShowControlEvent?) {
        loadedEvent = event
        selectedEventID = event?.id
        eventPicker.selectItem(at: events.firstIndex(where: { $0.id == selectedEventID }).map { $0 + 1 } ?? 0)
        eventTime.stringValue = event.map { String($0.time) } ?? ""
        switch event?.command {
        case let .osc(port, address, value):
            kind.selectItem(at: 0)
            oscPort.stringValue = String(port)
            oscAddress.stringValue = address
            switch value {
            case .integer(let value): setOSCValue(String(value), type: 1)
            case .float(let value): setOSCValue(String(value), type: 2)
            case .string(let value): setOSCValue(value, type: 3)
            case .boolean(let value): setOSCValue(String(value), type: 4)
            case nil: setOSCValue("", type: 0)
            }
        case let .midi(midiKind, channel, number, value):
            kind.selectItem(at: (ShowMIDIKind.allCases.firstIndex(of: midiKind) ?? 0) + 1)
            midiChannel.stringValue = String(channel)
            midiNumber.stringValue = String(number)
            midiValue.stringValue = String(value)
        case nil:
            kind.selectItem(at: 0)
            oscPort.stringValue = "9002"
            oscAddress.stringValue = "/show/cue"
            setOSCValue("", type: 0)
            midiChannel.stringValue = "1"
            midiNumber.stringValue = "60"
            midiValue.stringValue = "100"
        }
    }

    private func setOSCValue(_ value: String, type: Int) {
        oscType.selectItem(at: type)
        oscValue.stringValue = value
    }

    private func updateAvailability() {
        let hasTrack = activeTrack != nil
        for control in [trackPicker, trackName, trackEnabled, saveTrack, deleteTrack, eventPicker,
                        newEvent, eventTime, kind, saveEvent, oscPort, oscAddress, oscType,
                        midiChannel, midiNumber, midiValue] as [NSControl] { control.isEnabled = hasTrack }
        oscValue.isEnabled = hasTrack && oscType.indexOfSelectedItem > 0
        deleteEvent.isEnabled = hasTrack && selectedEventID != nil
        oscRows.isHidden = kind.indexOfSelectedItem != 0
        midiRows.isHidden = kind.indexOfSelectedItem == 0
    }

    private func perform(_ change: (EditorController) throws -> Void) {
        guard let editor else { return }
        do {
            try change(editor)
            feedback.stringValue = ""
            refresh()
        } catch {
            feedback.stringValue = error.localizedDescription
            feedback.toolTip = error.localizedDescription
        }
    }

    private func commit(_ tracks: [ShowControlTrack], editor: EditorController, action: String) throws {
        var project = editor.project
        project.showControlTracks = tracks
        try ProjectStore.validate(project)
        editor.mutate(action) { $0 = project }
    }

    private func createTrack() {
        perform { editor in
            let track = ShowControlTrack(name: "Control track \(tracks.count + 1)")
            try commit(tracks + [track], editor: editor, action: "Add show control track")
            selectedTrackID = track.id
            tracks = editor.project.showControlTracks
            refreshTrackPicker()
            selectTrack()
        }
    }

    private func updateTrack() {
        perform { editor in
            guard let index = tracks.firstIndex(where: { $0.id == selectedTrackID }) else { return }
            var edited = tracks
            edited[index].name = trackName.stringValue
            edited[index].enabled = trackEnabled.state == .on
            try commit(edited, editor: editor, action: "Edit show control track")
        }
    }

    private func removeTrack() {
        perform { editor in
            guard let id = selectedTrackID else { return }
            try commit(tracks.filter { $0.id != id }, editor: editor, action: "Delete show control track")
        }
    }

    private func commandDraft() throws -> ShowControlCommand {
        if kind.indexOfSelectedItem != 0 {
            let index = kind.indexOfSelectedItem - 1
            guard ShowMIDIKind.allCases.indices.contains(index), let channel = Int(midiChannel.stringValue),
                  let number = Int(midiNumber.stringValue), let value = Int(midiValue.stringValue) else {
                throw ProjectError.invalid("enter integer MIDI channel, note/CC and value")
            }
            return .midi(kind: ShowMIDIKind.allCases[index], channel: channel, number: number, value: value)
        }
        guard let port = UInt16(oscPort.stringValue) else { throw ProjectError.invalid("enter a valid OSC port") }
        let text = oscValue.stringValue
        let value: ShowOSCValue?
        switch oscType.indexOfSelectedItem {
        case 1:
            guard let integer = Int32(text) else { throw ProjectError.invalid("enter a 32-bit OSC integer") }
            value = .integer(integer)
        case 2:
            guard let float = Float(text), float.isFinite else { throw ProjectError.invalid("enter a finite OSC float") }
            value = .float(float)
        case 3:
            value = .string(text)
        case 4:
            switch text.lowercased() {
            case "true": value = .boolean(true)
            case "false": value = .boolean(false)
            default: throw ProjectError.invalid("enter true or false for an OSC Boolean")
            }
        default:
            value = nil
        }
        return .osc(port: port, address: oscAddress.stringValue, value: value)
    }

    private func updateEvent() {
        perform { editor in
            guard let trackIndex = tracks.firstIndex(where: { $0.id == selectedTrackID }) else { return }
            guard let time = Double(eventTime.stringValue) else { throw ProjectError.invalid("enter the event time in seconds") }
            let event = ShowControlEvent(id: selectedEventID ?? UUID(), time: time, command: try commandDraft())
            var edited = tracks
            if let index = edited[trackIndex].events.firstIndex(where: { $0.id == event.id }) {
                edited[trackIndex].events[index] = event
            } else {
                edited[trackIndex].events.append(event)
            }
            try commit(edited, editor: editor, action: "Save show control event")
            loadEvents()
            loadEvent(event)
        }
    }

    private func removeEvent() {
        perform { editor in
            guard let trackIndex = tracks.firstIndex(where: { $0.id == selectedTrackID }), let id = selectedEventID else { return }
            var edited = tracks
            edited[trackIndex].events.removeAll { $0.id == id }
            try commit(edited, editor: editor, action: "Delete show control event")
            loadEvent(nil)
        }
    }
}
#endif
