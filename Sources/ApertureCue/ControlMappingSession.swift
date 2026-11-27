#if os(macOS)
import AppKit
import MappingCore

@MainActor final class ControlMappingSession {
    var router = ControlRouter()
    var window: ControlMappingWindow?
    let query = OSCQueryServer()
    var queryEnabled = false
    var oscIsLoopback = true
    var lastQuery: [OSCQueryNode] = []
    var nextQuery = 0.0
    var nextFeedback = 0.0
    var midiStatus = ""
    var queryStatus = ""
    var lastInput: ControlInput?
    var inputUID: Int32?
    var outputUID: Int32?
    var lastFeedbackGeneration = 0
    var lastInputGeneration = 0
    var feedbackCache: [UUID: MIDIControlEvent] = [:]
    var feedbackCursor = 0
    var reconciledMap = ControlMap()
    var pending: [ControlIntent] = []
    var dropped = 0
    var learnNext = false

    func enqueue(_ intent: ControlIntent) {
        if case .surface = intent.target, let last = pending.last, last.target == intent.target {
            pending[pending.count - 1] = intent
            return
        }
        if pending.count == 64 {
            pending.removeFirst()
            dropped += 1
        }
        pending.append(intent)
    }

    func clearInput() {
        pending.removeAll()
        router.clearHeldInputs()
        lastInput = nil
        learnNext = false
    }
}

extension EditorController {
    @objc func configureControl() {
        if controlMapping.window == nil { controlMapping.window = ControlMappingWindow(editor: self) }
        controlMapping.window?.refresh()
        controlMapping.window?.showWindow(nil)
        controlMapping.window?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showLightingNetwork() { lighting.showNetworkSettings() }

    func refreshControlMappings() {
        if controlMapping.reconciledMap != project.controlMap {
            releaseControlFeedback()
            controlMapping.reconciledMap = project.controlMap
        }
        do {
            try controlMapping.router.configure(project.controlMap,
                surfaceIDs: Set(automationSurfaces.map(\.id)), cueIDs: Set(project.cues.map(\.id)))
        } catch {
            controlMapping.router = ControlRouter()
            controlMapping.clearInput()
        }
        controlMapping.window?.refresh()
    }

    func editControlBinding(_ binding: ControlBinding?, id: UUID) throws {
        var candidate = project
        if let index = candidate.controlMap.bindings.firstIndex(where: { $0.id == id }) {
            if let binding { candidate.controlMap.bindings[index] = binding }
            else { candidate.controlMap.bindings.remove(at: index) }
        } else if let binding {
            candidate.controlMap.bindings.append(binding)
        }
        try ProjectStore.validate(candidate)
        mutate(binding == nil ? "Delete control mapping" : "Save control mapping") { $0 = candidate }
    }

    func resetControlMappings() {
        network?.stop()
        stopMIDIControls()
        controlMapping.query.stop()
        controlMapping.queryEnabled = false
        controlMapping.lastQuery = []
        controlMapping.nextQuery = 0
        controlMapping.nextFeedback = 0
        controlMapping.inputUID = nil
        controlMapping.outputUID = nil
        controlMapping.feedbackCache.removeAll()
        controlMapping.lastFeedbackGeneration = 0
        controlMapping.lastInputGeneration = 0
        controlMapping.queryStatus = ""
        controlMapping.midiStatus = ""
        controlMapping.dropped = 0
        controlMapping.clearInput()
        controlMapping.router = ControlRouter()
        controlMapping.reconciledMap = ControlMap()
        controlMapping.window?.close()
        controlMapping.window = nil
    }

    func remote(_ command: ControlCommand) {
        if case .rawOSC(let message) = command { receiveMappedOSC(message) }
        else { queueLegacyControl(command) }
    }

    private func releaseControlFeedback() {
        if let midi, midi.connectedFeedbackUID != nil {
            for event in controlMapping.feedbackCache.values {
                if case let .note(channel, number, _, true) = event {
                    try? midi.sendFeedback(.note(channel: channel, note: number, velocity: 0, isOn: false))
                }
            }
        }
        controlMapping.feedbackCache.removeAll()
        controlMapping.feedbackCursor = 0
    }

    func stopMIDIControls() {
        releaseControlFeedback()
        midi?.stop()
        controlMapping.clearInput()
        controlMapping.midiStatus = ""
    }

    func controlEndpointsChanged() {
        if let midi, midi.inputConnectionGeneration != controlMapping.lastInputGeneration {
            controlMapping.router.clearHeldInputs()
            controlMapping.lastInputGeneration = midi.inputConnectionGeneration
        }
        if let midi, midi.feedbackConnectionGeneration != controlMapping.lastFeedbackGeneration {
            controlMapping.feedbackCache.removeAll()
            controlMapping.lastFeedbackGeneration = midi.feedbackConnectionGeneration
        }
        controlMapping.window?.refreshEndpointChoices()
    }

    func receiveMappedOSC(_ message: OSCMessage) {
        guard let value = ControlInputValue(arguments: message.arguments) else { return }
        let input = ControlInput.osc(message.address)
        controlMapping.lastInput = input
        if controlMapping.learnNext {
            controlMapping.learnNext = false
            controlMapping.window?.refreshStatus()
            return
        }
        if ControlAddressSpace.isReserved(message.address) {
            guard case .normalized(let number) = value else { return }
            if let surface = ControlAddressSpace.surfaceTarget(message.address),
               let limits = try? TimelineEngine.parameterRange(surface.parameter) {
                let unit = (number - limits.lowerBound) / (limits.upperBound - limits.lowerBound)
                controlMapping.enqueue(ControlIntent(target: .surface(surface.id, parameter: surface.parameter),
                                                     value: min(1, max(0, unit))))
            } else if message.address == ControlAddressSpace.time {
                controlMapping.enqueue(ControlIntent(target: .seek, value: number, absoluteSeek: true))
            } else if message.address == ControlAddressSpace.blackout {
                controlMapping.enqueue(ControlIntent(target: .blackout, value: number > 0 ? 1 : 0))
            }
            return
        }
        if controlMapping.router.contains(input) {
            if let intent = controlMapping.router.route(input, value: value) { controlMapping.enqueue(intent) }
        } else if let command = ControlCommand.from(message) {
            queueLegacyControl(command)
        }
    }

    func receiveMappedMIDI(_ event: MIDIControlEvent) {
        let input: ControlInput
        let scalar: Double
        switch event {
        case let .note(channel, note, _, isOn):
            input = .midi(kind: .note, channel: channel, number: note)
            scalar = isOn ? 1 : 0
        case let .controlChange(channel, controller, value):
            input = .midi(kind: .cc7, channel: channel, number: controller)
            scalar = Double(value) / 127
        case let .controlChange14(channel, controller, value):
            input = .midi(kind: .cc14, channel: channel, number: controller)
            scalar = Double(value) / 16383
        case let .pitchBend(channel, value):
            input = .midi(kind: .pitchBend, channel: channel, number: 0)
            scalar = Double(value) / 16383
        case .realtime: return
        }
        if controlMapping.learnNext {
            controlMapping.lastInput = input
            controlMapping.learnNext = false
            controlMapping.window?.refreshStatus()
            return
        }
        // Retain the raw CC7 key for Learn when the codec also emits a derived
        // CC14 pair from the same input. Users can choose CC14 in the edit dialog.
        if case .controlChange14 = event {} else { controlMapping.lastInput = input }
        let bound = controlMapping.router.contains(input)
        if bound {
            if let intent = controlMapping.router.route(input, value: .normalized(scalar)) { controlMapping.enqueue(intent) }
        } else if case let .controlChange(channel, controller, _) = event,
                  controlMapping.router.contains(.midi(kind: .cc14, channel: channel, number: controller % 32)) {
            return
        } else if let command = legacyMIDICommand(event) {
            queueLegacyControl(command)
        }
    }

    private func queueLegacyControl(_ command: ControlCommand) {
        let intent: ControlIntent
        switch command {
        case .play: intent = ControlIntent(target: .play, value: nil)
        case .pause: intent = ControlIntent(target: .pause, value: nil)
        case .seek(let time): intent = ControlIntent(target: .seek, value: time, absoluteSeek: true)
        case .blackout(let value): intent = ControlIntent(target: .blackout, value: value ? 1 : 0)
        case .cue(let index):
            guard project.cues.indices.contains(index) else { return }
            intent = ControlIntent(target: .scene(project.cues[index].id), value: nil)
        case .opacity(let index, let value):
            guard project.surfaces.indices.contains(index) else { return }
            intent = ControlIntent(target: .surface(project.surfaces[index].id, parameter: "opacity"), value: value)
        case .rawOSC, .externalClock: return
        }
        controlMapping.enqueue(intent)
    }

    func flushControlMappings(at time: Double) {
        let batch = controlMapping.pending
        controlMapping.pending.removeAll(keepingCapacity: true)
        var edits: [UUID: [String: Double]] = [:]
        func commitEdits() {
            guard !edits.isEmpty else { return }
            var next = project.surfaces
            for index in next.indices {
                guard let values = edits[next[index].id] else { continue }
                for (parameter, value) in values {
                    switch parameter {
                    case "opacity": next[index].opacity = value
                    case "brightness": next[index].brightness = value
                    case "gamma": next[index].gamma = value
                    case "red": next[index].color[0] = value
                    case "green": next[index].color[1] = value
                    case "blue": next[index].color[2] = value
                    default: break
                    }
                }
            }
            edits.removeAll(keepingCapacity: true)
            if next != project.surfaces { mutate("Control surface") { $0.surfaces = next } }
        }

        for intent in batch {
            if case let .surface(id, parameter) = intent.target,
               let value = intent.value, let range = try? TimelineEngine.parameterRange(parameter) {
                edits[id, default: [:]][parameter] = range.lowerBound + (range.upperBound - range.lowerBound) * value
                continue
            }
            commitEdits()
            switch intent.target {
            case .surface: break
            case .play: if !showRuntime.isPlaying { playShow(at: time) }
            case .pause: if showRuntime.isPlaying { pauseShow(at: time) }
            case .togglePlayback: showRuntime.isPlaying ? pauseShow(at: time) : playShow(at: time)
            case .stop: stopShow(at: time)
            case .seek:
                if let value = intent.value {
                    let seconds = intent.absoluteSeek ? value : value * project.timelineSettings.duration
                    seekShow(to: seconds, at: time)
                }
            case .blackout:
                if let value = intent.value, blackout != (value >= 0.5) { toggleBlackout() }
            case .scene(let id):
                if let index = project.cues.firstIndex(where: { $0.id == id }), goCue(index: index, interactive: false) {
                    if cueTarget?.duration == 0 { applyCueSample(at: cueStart) }
                }
            }
        }
        commitEdits()
    }

    private func controlValue(surface: Surface, parameter: String) -> Double {
        TimelineEngine.parameterValue(parameter, on: surface) ?? 0
    }

    private var queryTimeLimit: Double {
        let settings = project.timelineSettings
        return settings.stopAtEnd || settings.loopEnabled ? settings.duration : ShowRuntime.maximumTime
    }

    func queryControlNodes() -> [OSCQueryNode] {
        var nodes = [
            OSCQueryNode(path: ControlAddressSpace.time, description: "Master time in seconds", access: .readWrite,
                         type: "f", value: [.float(Float(showRuntime.time))],
                         range: [OSCQueryRange(min: 0, max: queryTimeLimit)]),
            OSCQueryNode(path: ControlAddressSpace.playing, description: "Master transport", access: .readOnly,
                         type: "i", value: [.int(showRuntime.isPlaying ? 1 : 0)]),
            OSCQueryNode(path: ControlAddressSpace.blackout, description: "Master blackout", access: .readWrite,
                         type: "i", value: [.int(blackout ? 1 : 0)], range: [OSCQueryRange(min: 0, max: 1)])
        ]
        for surface in project.surfaces.prefix(200) {
            let title = String(decoding: surface.name.utf8.prefix(220), as: UTF8.self)
            for parameter in TimelineEngine.parameters {
                guard let range = try? TimelineEngine.parameterRange(parameter) else { continue }
                nodes.append(OSCQueryNode(path: ControlAddressSpace.surface(surface.id, parameter),
                    description: title + " · " + parameter, access: .readWrite, type: "f",
                    value: [.float(Float(controlValue(surface: surface, parameter: parameter)))],
                    range: [OSCQueryRange(min: range.lowerBound, max: range.upperBound)]))
            }
        }
        return nodes
    }

    func startQuery(port: UInt16, advertiseLocally: Bool) throws {
        guard let oscPort = network?.boundPort, controlMapping.oscIsLoopback else {
            throw SystemFailure(message: "Start localhost OSC input before publishing the Query tree")
        }
        let nodes = queryControlNodes()
        try controlMapping.query.publish(nodes)
        try controlMapping.query.start(port: port, oscPort: oscPort, advertiseLocally: advertiseLocally)
        controlMapping.lastQuery = nodes
        controlMapping.queryEnabled = true
        controlMapping.queryStatus = ""
    }

    func stopOSCControls() {
        controlMapping.query.stop()
        controlMapping.queryEnabled = false
        controlMapping.queryStatus = ""
        network?.stop()
        controlMapping.clearInput()
    }

    func pollControlMappingOutputs(at time: Double) {
        if time >= controlMapping.nextQuery {
            controlMapping.nextQuery = time + 0.1
            if controlMapping.queryEnabled {
                let nodes = queryControlNodes()
                if nodes != controlMapping.lastQuery {
                    do {
                        try controlMapping.query.publish(nodes)
                        controlMapping.lastQuery = nodes
                        controlMapping.queryStatus = ""
                    } catch { controlMapping.queryStatus = error.localizedDescription }
                }
            }
            controlMapping.window?.refreshStatus()
        }
        guard time >= controlMapping.nextFeedback else { return }
        controlMapping.nextFeedback = time + 0.05
        guard let midi else { return }
        if midi.inputConnectionGeneration != controlMapping.lastInputGeneration
            || midi.feedbackConnectionGeneration != controlMapping.lastFeedbackGeneration {
            controlEndpointsChanged()
        }
        guard midi.connectedFeedbackUID != nil else { return }
        let byID = Dictionary(uniqueKeysWithValues: project.surfaces.map { ($0.id, $0) })
        let bindings = project.controlMap.bindings.filter(\.feedback)
        guard !bindings.isEmpty else { return }
        var sent = 0
        for _ in bindings.indices {
            let index = controlMapping.feedbackCursor % bindings.count
            controlMapping.feedbackCursor = (index + 1) % bindings.count
            let binding = bindings[index]
            guard case let .midi(kind, channel, number) = binding.input else { continue }
            let value: Double
            switch binding.target {
            case let .surface(id, parameter):
                guard let surface = byID[id], let range = try? TimelineEngine.parameterRange(parameter) else { continue }
                value = (controlValue(surface: surface, parameter: parameter) - range.lowerBound) / (range.upperBound - range.lowerBound)
            case .togglePlayback: value = showRuntime.isPlaying ? 1 : 0
            case .blackout: value = blackout ? 1 : 0
            default: continue
            }
            let normalized = min(1, max(0, binding.inverted ? 1 - value : value))
            let event: MIDIControlEvent
            switch kind {
            case .note: event = .note(channel: channel, note: number, velocity: normalized >= 0.5 ? 127 : 0, isOn: normalized >= 0.5)
            case .cc7: event = .controlChange(channel: channel, controller: number, value: Int((normalized * 127).rounded()))
            case .cc14: event = .controlChange14(channel: channel, controller: number, value: Int((normalized * 16383).rounded()))
            case .pitchBend: event = .pitchBend(channel: channel, value: Int((normalized * 16383).rounded()))
            }
            guard controlMapping.feedbackCache[binding.id] != event else { continue }
            do {
                try midi.sendFeedback(event)
                controlMapping.feedbackCache[binding.id] = event
                controlMapping.midiStatus = ""
                sent += 1
                if sent == 32 { break }
            } catch {
                controlMapping.midiStatus = error.localizedDescription
                break
            }
        }
    }
}
#endif
