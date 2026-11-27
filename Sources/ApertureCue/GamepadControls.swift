#if os(macOS)
import AppKit
import GameController
import MappingCore

@MainActor final class GamepadSession {
    enum Button: String, CaseIterable { case a = "A", b = "B", x = "X", y = "Y" }
    private let sources: () -> [GCController]
    private var selected: GCController?
    private var selectedProfile: GCExtendedGamepad?
    private var bindings: [Button: ControlIntent] = [:]
    private var previous = Set<Button>()
    private var needsBaseline = true
    private var nextDiscovery = 0.0
    private(set) var status = "Gamepad off"
    var window: GamepadWindow?
    var isArmed: Bool { selected != nil }

    init(sources: @escaping () -> [GCController] = {
        GCController.controllers().filter { !$0.isSnapshot && $0.extendedGamepad != nil }
    }) {
        self.sources = sources
    }

    func available() -> [GCController] { Array(sources().prefix(32)) }

    static func name(_ pad: GCController) -> String {
        let name = String((pad.vendorName ?? "").prefix(100).filter { character in
            !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        })
        return name.isEmpty ? "Extended gamepad" : name
    }

    func arm(controller: GCController, bindings: [Button: ControlIntent]) throws {
        guard !bindings.isEmpty, available().contains(where: { $0 === controller }),
              let profile = controller.extendedGamepad else {
            throw ProjectError.invalid("select a connected extended gamepad and at least one button action")
        }
        selected = controller
        selectedProfile = profile
        self.bindings = bindings
        previous.removeAll(keepingCapacity: true)
        needsBaseline = true
        nextDiscovery = 0
        status = "Armed · \(Self.name(controller))"
    }

    func disarm(message: String = "Gamepad off") {
        selected = nil
        selectedProfile = nil
        bindings.removeAll(keepingCapacity: true)
        previous.removeAll(keepingCapacity: true)
        needsBaseline = true
        status = message
    }

    func reset() {
        disarm()
        window?.close()
        window = nil
    }

    func poll(at time: Double, acceptsInput: Bool) -> [ControlIntent] {
        guard let selected, let selectedProfile else { return [] }
        if time >= nextDiscovery {
            guard available().contains(where: { $0 === selected }) else {
                disarm(message: "Selected gamepad disconnected")
                return []
            }
            nextDiscovery = time + 0.25
        }
        guard acceptsInput else { needsBaseline = true; return [] }
        let profile = selectedProfile
        let pressed = Set(zip(Button.allCases, [profile.buttonA, profile.buttonB, profile.buttonX, profile.buttonY])
            .compactMap { name, input in input.isPressed ? name : nil })
        defer { previous = pressed; needsBaseline = false }
        guard !needsBaseline else { return [] }
        return Button.allCases.compactMap { pressed.contains($0) && !previous.contains($0) ? bindings[$0] : nil }
    }
}

extension EditorController {
    @objc func showGamepadControls() {
        if gamepadSession.window == nil { gamepadSession.window = GamepadWindow(editor: self) }
        gamepadSession.window?.showAndRefresh()
    }

    func pollGamepad(at time: Double = ProcessInfo.processInfo.systemUptime) {
        for intent in gamepadSession.poll(at: time, acceptsInput: NSApplication.shared.isActive) {
            controlMapping.enqueue(intent)
        }
    }
}

@MainActor final class GamepadWindow: NSWindowController, NSWindowDelegate {
    private weak var editor: EditorController?
    private let device = NSPopUpButton()
    private let arm = ActionButton("Arm gamepad") {}
    private let rescan = ActionButton("Refresh controllers") {}
    private let status = label("Gamepad off")
    private var sourceList: [GCController] = []
    private var targets: [ControlIntent?] = []
    private var targetPickers: [NSPopUpButton] = []
    private var ticker: Timer?

    init(editor: EditorController) {
        self.editor = editor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 270),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Gamepad Show Controls"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        guard let content = window.contentView else { return }
        var rows: [NSView] = [stack([label("Controller"), device], vertical: false)]
        device.target = self
        device.action = #selector(refreshStatus)
        device.widthAnchor.constraint(equalToConstant: 320).isActive = true
        for button in GamepadSession.Button.allCases {
            let picker = NSPopUpButton()
            picker.target = self
            picker.action = #selector(refreshStatus)
            picker.widthAnchor.constraint(equalToConstant: 320).isActive = true
            targetPickers.append(picker)
            rows.append(stack([label(button.rawValue), picker], vertical: false))
        }
        let controls = stack(rows + [status, stack([arm, rescan], vertical: false)])
        status.lineBreakMode = .byTruncatingTail
        fill(controls, in: content, inset: 14)
        arm.actionBlock = { [weak self] in self?.toggleArming() }
        rescan.actionBlock = { [weak self] in self?.refreshOptions() }
        refreshOptions()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showAndRefresh() {
        refreshOptions()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func windowWillClose(_ notification: Notification) {
        ticker?.invalidate()
        ticker = nil
    }

    private var chosenController: GCController? {
        let index = device.indexOfSelectedItem - 1
        return sourceList.indices.contains(index) ? sourceList[index] : nil
    }

    private var chosenBindings: [GamepadSession.Button: ControlIntent] {
        Dictionary(uniqueKeysWithValues: zip(GamepadSession.Button.allCases, targetPickers).compactMap { button, picker in
            let index = picker.indexOfSelectedItem
            guard targets.indices.contains(index), let intent = targets[index] else { return nil }
            return (button, intent)
        })
    }

    private func refreshOptions() {
        guard let editor, !editor.gamepadSession.isArmed else { refreshStatus(); return }
        let previous = chosenController
        let oldTargets = chosenBindings
        sourceList = editor.gamepadSession.available()
        device.removeAllItems()
        device.addItem(withTitle: sourceList.isEmpty ? "No connected extended gamepads" : "Select a controller")
        device.addItems(withTitles: sourceList.enumerated().map { "\($0.offset + 1). \(GamepadSession.name($0.element))" })
        let match = sourceList.firstIndex(where: { $0 === previous })
        device.selectItem(at: match.map { $0 + 1 } ?? 0)
        var options: [(title: String, intent: ControlIntent?)] = [
            ("Unassigned", nil),
            ("Toggle playback", ControlIntent(target: .togglePlayback, value: nil)),
            ("Play", ControlIntent(target: .play, value: nil)),
            ("Pause", ControlIntent(target: .pause, value: nil)),
            ("Stop", ControlIntent(target: .stop, value: nil)),
            ("Blackout on", ControlIntent(target: .blackout, value: 1)),
            ("Blackout off", ControlIntent(target: .blackout, value: 0))
        ]
        options += editor.project.cues.enumerated().map {
            ("Cue \($0.offset + 1) · \($0.element.name)", ControlIntent(target: .scene($0.element.id), value: nil))
        }
        targets = options.map(\.intent)
        for (button, picker) in zip(GamepadSession.Button.allCases, targetPickers) {
            picker.removeAllItems()
            picker.addItems(withTitles: options.map(\.title))
            picker.selectItem(at: targets.firstIndex(of: oldTargets[button]) ?? 0)
        }
        refreshStatus()
    }

    @objc private func refreshStatus() {
        guard let session = editor?.gamepadSession else { return }
        status.stringValue = session.status
        arm.title = session.isArmed ? "Disarm gamepad" : "Arm gamepad"
        arm.isEnabled = session.isArmed || (chosenController != nil && !chosenBindings.isEmpty)
        device.isEnabled = !session.isArmed && !sourceList.isEmpty
        for picker in targetPickers { picker.isEnabled = !session.isArmed }
        rescan.isEnabled = !session.isArmed
    }

    private func toggleArming() {
        guard let editor else { return }
        let session = editor.gamepadSession
        if session.isArmed { session.disarm(); refreshOptions(); return }
        guard let controller = chosenController else { return }
        do { try session.arm(controller: controller, bindings: chosenBindings) }
        catch { editor.showError(error); refreshOptions() }
        refreshStatus()
    }
}
#endif
