#if os(macOS)
import AppKit
import Darwin
import MappingCore

@MainActor enum FirmataSelfTest {
    /// The board side of an anonymous pseudo-terminal. The adapter owns the slave,
    /// uses the same raw serial configuration, and never opens a physical endpoint.
    private final class BoardFixture {
        private var master: Int32 = -1
        private var slave: Int32 = -1
        private var received = Data()

        init() throws {
            guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw error("Could not allocate a pseudo-terminal") }
            let flags = fcntl(master, F_GETFL)
            guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) == 0 else {
                unplug()
                Darwin.close(slave)
                slave = -1
                throw error("Could not configure the pseudo-terminal master")
            }
        }

        deinit {
            unplug()
            if slave >= 0 { Darwin.close(slave) }
        }

        @MainActor func attach(to panel: FirmataWindow) {
            let owned = slave
            slave = -1
            panel.connectVirtual(owning: owned)
        }

        func unplug() {
            guard master >= 0 else { return }
            Darwin.close(master)
            master = -1
        }

        func send(_ bytes: [UInt8]) throws {
            let wrote = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            guard wrote == bytes.count else { throw error("Pseudo-terminal board could not send its fixture bytes") }
        }

        func expect(_ expected: [UInt8]) throws {
            let start = ProcessInfo.processInfo.systemUptime
            while received.count < expected.count, ProcessInfo.processInfo.systemUptime - start < 0.65 {
                try collect()
                if received.count < expected.count { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.008)) }
            }
            guard received.prefix(expected.count).elementsEqual(expected) else {
                throw error("Expected serial bytes \(expected) and received \(Array(received))")
            }
            received.removeFirst(expected.count)
        }

        func expectIdle() throws {
            let start = ProcessInfo.processInfo.systemUptime
            repeat {
                try collect()
                guard received.isEmpty else { throw error("Unexpected automatic pin commands \(Array(received))") }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            } while ProcessInfo.processInfo.systemUptime - start < 0.12
        }

        private func collect() throws {
            var data = [UInt8](repeating: 0, count: 512)
            let count = data.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
            guard count >= 0 else { throw error("Pseudo-terminal fixture could not read queued bytes") }
            received.append(contentsOf: data.prefix(count))
        }

        private func error(_ message: String) -> SystemFailure { SystemFailure(message: message) }
    }

    private static let version: [UInt8] = [0xF9, 2, 8]
    private static let queries: [UInt8] = [0xF0, 0x6B, 0xF7, 0xF0, 0x69, 0xF7]
    private static let discovery: [UInt8] = [
        0xF0, 0x6C, 127, 127, 0, 1, 1, 1, 127, 2, 10, 127, 0xF7,
        0xF0, 0x6A, 127, 127, 127, 0, 0xF7,
    ]

    static func run() -> Int32 {
        let started = ProcessInfo.processInfo.systemUptime
        var checks = [String]()
        var failure: String?
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        func pass(_ message: String) {
            checks.append(message)
            print("PASS Firmata: \(message)")
        }
        do {
            guard ["/dev/null", "/dev/cu.", "/dev/cu.a/../b", "cu.usbserial-board", "/tmp/cu.usbserial-board"]
                .allSatisfy({ !LightingAdapterSerialSink.isDevicePath($0) }),
                  LightingAdapterSerialSink.isDevicePath("/dev/cu.usbserial-test-artifact") else {
                throw SystemFailure(message: "Explicit serial call-out path validation failed")
            }
            let editor = EditorController()
            editor.timer?.invalidate()
            editor.timer = nil
            editor.window?.orderOut(nil)
            editor.metalView.isPaused = true
            editor.lightingView.isPaused = true
            defer {
                editor.closeFirmata()
                editor.media.reset()
                editor.dirty = false
                editor.window?.close()
            }
            let surface = Surface(name: "Firmata fixture", opacity: 0)
            editor.project = Project(name: "Original Firmata fixture", surfaces: [surface])
            guard editor.tableView(editor.layerTable, viewFor: nil, row: 1) == nil,
                  editor.tableView(editor.mediaTable, viewFor: nil, row: 0) == nil else {
                throw SystemFailure(message: "A stale table row rendered after replacing the editor document")
            }
            pass("native editor ignores rows left over from a previous document")
            editor.reconcile()
            editor.refresh()
            editor.showFirmata()
            guard let panel = editor.firmataWindow, panel.window?.isVisible == true else {
                throw SystemFailure(message: "The Firmata panel did not open")
            }
            let first = try BoardFixture()
            first.attach(to: panel)
            try first.expect([0xF9])
            try first.send(Array(version.prefix(2)))
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
            try first.send(Array(version.suffix(1)))
            try first.expect(queries)
            try first.send(discovery)
            try wait("capabilities and analog map did not arrive") { ready(panel) }
            try first.expectIdle()
            pass("original pseudo-terminal discovery opens the native panel without pin writes")

            panel.startInput(.analog(channel: 0), surfaceID: surface.id, parameter: "opacity")
            try first.expect([0xF4, 3, 2, 0xC0, 1])
            try first.send([0xE0, 0, 4])
            try wait("analog sample did not reach the editor") {
                editor.flushControlMappings(at: ProcessInfo.processInfo.systemUptime)
                return abs((editor.project.surfaces.first?.opacity ?? -1) - 512.0 / 1023.0) < 1e-12
            }
            pass("10-bit analog input routes through the normal editor control transaction")

            panel.writeOutput(pin: 2, high: true)
            try first.expect([0xF4, 2, 1, 0xF5, 2, 1, 0xF0, 0x6D, 2, 0xF7])
            try first.send([0xF0, 0x6E, 2, 1, 1, 0xF7])
            try wait("digital output confirmation did not arrive") { panel.connectionState.output == .confirmed(pin: 2, high: true) }
            pass("explicit digital write touches one pin and checks the firmware pin state")

            panel.writeOutput(pin: 2, high: false)
            try first.expect([0xF5, 2, 0, 0xF0, 0x6D, 2, 0xF7])
            try first.send(version + [0xF0, 0x6E, 2, 1, 0, 0xF7, 0xE0, 127, 7])
            try first.expect(queries)
            try first.send(discovery)
            try wait("board reboot did not clear pending output or input") {
                ready(panel) && panel.connectionState.output == .idle && panel.connectionState.input == nil
            }
            try first.expectIdle()
            editor.flushControlMappings(at: ProcessInfo.processInfo.systemUptime)
            guard abs((editor.project.surfaces.first?.opacity ?? -1) - 512.0 / 1023.0) < 1e-12 else {
                throw SystemFailure(message: "A sample sent during reboot reached the document")
            }
            pass("board reboot clears pending write and routing without replay")

            first.unplug()
            try wait("serial hang-up did not reach the panel") {
                panel.connectionState.phase == .disconnected && panel.connectionState.error != nil
            }
            let second = try BoardFixture()
            second.attach(to: panel)
            try second.expect([0xF9])
            try second.send(version)
            try second.expect(queries)
            try second.send(discovery)
            try wait("explicit reconnect did not complete discovery") { ready(panel) && panel.connectionState.input == nil }
            panel.startInput(.digital(pin: 2), surfaceID: surface.id, parameter: "opacity")
            try second.expect([0xF4, 2, 0, 0xD0, 1])
            try second.send([0x90, 4, 0])
            try wait("digital input did not reach the editor after reconnect") {
                editor.flushControlMappings(at: ProcessInfo.processInfo.systemUptime)
                return editor.project.surfaces.first?.opacity == 1
            }
            panel.stopInput()
            try second.expect([0xD0, 0])
            try wait("stop input left the subscription active") { panel.connectionState.input == nil && ready(panel) }
            panel.shutDown()
            try wait("user disconnect did not close the serial session") { panel.connectionState.phase == .disconnected }
            pass("serial hang-up, explicit reconnect, digital input and report shutdown")
        } catch {
            failure = error.localizedDescription
            print("FAIL Firmata: \(error.localizedDescription)")
        }
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/local/firmata-test", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let report: [String: Any] = [
                "checks": checks, "pass": failure == nil, "failure": failure as Any? ?? NSNull(),
                "wallSeconds": ProcessInfo.processInfo.systemUptime - started,
                "platform": ProcessInfo.processInfo.operatingSystemVersionString,
                "connection": "original macOS pseudo-terminal", "physicalDevicesTested": 0,
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("results.json"), options: .atomic)
        } catch {
            print("FAIL Firmata report: \(error.localizedDescription)")
            return 1
        }
        return failure == nil ? 0 : 1
    }

    private static func ready(_ panel: FirmataWindow) -> Bool {
        if case .ready = panel.connectionState.phase { return true }
        return false
    }

    private static func wait(_ message: String, condition: () -> Bool) throws {
        let started = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - started < 1.5 {
            if condition() { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.008))
        }
        throw SystemFailure(message: message)
    }
}
#endif
