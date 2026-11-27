#if os(macOS)
import AppKit
import MappingCore

@MainActor final class PJLinkWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let endpoint = ActionField("", action: { _ in })
    private let auth = ActionPopUp(items: PJLinkAuthentication.allCases.map(\.title), action: { _ in })
    private let password = NSSecureTextField()
    private let readStatus = ActionButton("Read status", action: {})
    private let powerOn = ActionButton("Power on", action: {})
    private let powerOff = ActionButton("Power off", action: {})
    private let mute = ActionButton("AV mute", action: {})
    private let unmute = ActionButton("AV unmute", action: {})
    private let cancel = ActionButton("Cancel request", action: {})
    private let powerValue = label("—")
    private let muteValue = label("—")
    private let classValue = label("—")
    private let faultsValue = label("—")
    private let status = label("Enter one projector's IPv4 address")
    private let worker = DispatchQueue(label: "org.aperturecue.pjlink", qos: .userInitiated)
    private var pending: (id: UUID, request: PJLinkCancellation)?
    private var presentation: UInt64 = 0

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 290),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.title = "ApertureCue · PJLink Projector"
        window.delegate = self
        window.center()
        build()
        bind()
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        updateControls()
    }

    /// Document changes and Quit discard the session's target and credentials.
    func reset() {
        clearSession()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) { clearSession() }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === endpoint { clearValues() }
        updateControls()
    }

    private func build() {
        guard let content = window?.contentView else { return }
        endpoint.placeholderString = "Projector address"
        endpoint.setAccessibilityLabel("Projector IPv4 address")
        endpoint.delegate = self
        password.placeholderString = "PJLink password"
        password.setAccessibilityLabel("PJLink password")
        password.delegate = self
        endpoint.widthAnchor.constraint(equalToConstant: 180).isActive = true
        password.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let addressRow = stack([label("IPv4 address"), endpoint, label("TCP 4352")], vertical: false)
        let securityRow = stack([label("Authentication"), auth, password], vertical: false)
        let commands = stack([readStatus, powerOn, powerOff, mute, unmute, cancel], vertical: false)
        let values = stack([label("Power", bold: true), powerValue, label("Mute", bold: true), muteValue,
                            label("Class", bold: true), classValue], vertical: false, spacing: 10)
        let faults = stack([label("Device diagnostics", bold: true), faultsValue], vertical: false)
        let layout = stack([addressRow, securityRow, commands, values, faults, status], spacing: 10)
        for view in layout.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }
        for field in [powerValue, muteValue, classValue, faultsValue, status] {
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        fill(layout, in: content, inset: 16)
    }

    private func bind() {
        auth.actionBlock = { [weak self] _ in
            guard let self else { return }
            if self.mode == .unprotected { self.password.stringValue = "" }
            self.clearValues()
            self.updateControls()
        }
        readStatus.actionBlock = { [weak self] in self?.request(PJLinkClient.statusCommands) }
        powerOn.actionBlock = { [weak self] in self?.request([.setPower(true)]) }
        powerOff.actionBlock = { [weak self] in self?.request([.setPower(false)]) }
        mute.actionBlock = { [weak self] in self?.request([.setMute(true)]) }
        unmute.actionBlock = { [weak self] in self?.request([.setMute(false)]) }
        cancel.actionBlock = { [weak self] in
            self?.pending?.request.cancel()
            self?.setStatus("Cancelling request…")
            self?.updateControls()
        }
    }

    private var mode: PJLinkAuthentication {
        let index = auth.indexOfSelectedItem
        return PJLinkAuthentication.allCases.indices.contains(index) ? PJLinkAuthentication.allCases[index] : .sha256
    }

    private func updateControls() {
        let idle = pending == nil
        endpoint.isEnabled = idle
        auth.isEnabled = idle
        password.isEnabled = idle && mode != .unprotected
        let targetEntered = !endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = idle && targetEntered && (mode == .unprotected || PJLinkCodec.validPassword(password.stringValue))
        for button in [readStatus, powerOn, powerOff, mute, unmute] { button.isEnabled = canSend }
        cancel.isEnabled = pending?.request.isCancelled == false
    }

    private func request(_ commands: [PJLinkCommand]) {
        guard pending == nil else { return }
        // Commit the field editor before copying these session-only strings.
        window?.makeFirstResponder(nil)
        let host = endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let authentication = mode
        let credential = authentication == .unprotected ? "" : password.stringValue
        guard authentication == .unprotected || PJLinkCodec.validPassword(credential) else {
            setStatus(PJLinkProtocolError.invalidPassword.localizedDescription)
            return
        }
        let request = PJLinkCancellation()
        let id = UUID()
        let openedAt = presentation
        pending = (id, request)
        clearValues()
        setStatus("Contacting projector…")
        updateControls()
        worker.async { [self] in
            let result = Result {
                try NativePJLinkClient.run(host: host, authentication: authentication, password: credential,
                                          commands: commands, cancellation: request)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pending?.id == id else { return }
                self.pending = nil
                defer { self.updateControls() }
                guard self.presentation == openedAt else { return }
                if request.isCancelled {
                    self.setStatus(PJLinkProtocolError.cancelled.localizedDescription)
                    return
                }
                switch result {
                case .success(let replies): self.showResults(commands: commands, replies: replies)
                case .failure(let error): self.setStatus(error.localizedDescription)
                }
            }
        }
    }

    private func clearSession() {
        presentation &+= 1
        pending?.request.cancel()
        window?.makeFirstResponder(nil)
        endpoint.stringValue = ""
        password.stringValue = ""
        auth.selectItem(at: 0)
        clearValues()
        setStatus("Enter one projector's IPv4 address")
        updateControls()
    }

    private func clearValues() {
        for field in [powerValue, muteValue, classValue, faultsValue] {
            field.stringValue = "—"
            field.toolTip = nil
        }
    }

    private func showResults(commands: [PJLinkCommand], replies: [PJLinkReply]) {
        var errors: [String] = []
        for (command, reply) in zip(commands, replies) {
            switch reply {
            case .power(let power): powerValue.stringValue = power.title
            case .mute(let mute): muteValue.stringValue = mute.title
            case .deviceClass(let value): classValue.stringValue = String(value)
            case .faults(let conditions): showFaults(conditions)
            case .acknowledged: setStatus("Command accepted. Read status to verify the current state.")
            case .rejected(let rejection):
                errors.append(command.body + " · " + rejection.title)
            }
        }
        if !errors.isEmpty { setStatus(errors.joined(separator: " · ")) }
        else if !commands.contains(where: \.isWrite) { setStatus("Projector status received") }
    }

    private func showFaults(_ conditions: PJLinkFaults) {
        let labels: [(String, PJLinkCondition)] = [
            ("Fan", conditions.fan), ("Lamp", conditions.lamp), ("Temperature", conditions.temperature),
            ("Cover", conditions.cover), ("Filter", conditions.filter), ("Other", conditions.other)
        ]
        let issues = labels.compactMap { name, condition -> String? in
            switch condition {
            case .clearOrUnsupported: return nil
            case .warning: return name + " warning"
            case .fault: return name + " fault"
            }
        }
        faultsValue.stringValue = issues.isEmpty ? "No reported warnings or faults" : issues.joined(separator: " · ")
        faultsValue.toolTip = faultsValue.stringValue
    }

    private func setStatus(_ value: String) {
        status.stringValue = value
        status.toolTip = value
    }
}
#endif
