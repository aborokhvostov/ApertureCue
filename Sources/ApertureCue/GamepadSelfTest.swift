#if os(macOS)
import AppKit
import GameController
import MetalKit
import MappingCore

@MainActor enum GamepadSelfTest {
    static func run() -> Int32 {
        let began = ProcessInfo.processInfo.systemUptime
        var checks: [String] = []
        var failure: String?
        func pass(_ text: String) { checks.append(text); print("PASS gamepad: " + text) }
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let selected = GCController.withExtendedGamepad()
            let other = GCController.withExtendedGamepad()
            guard let profile = selected.extendedGamepad, let otherProfile = other.extendedGamepad,
                  selected.isSnapshot, other.isSnapshot else {
                throw SystemFailure(message: "GameController did not supply virtual extended snapshots")
            }
            var devices = [selected, other]
            let session = GamepadSession { devices }
            let blackoutOn = ControlIntent(target: .blackout, value: 1)
            let blackoutOff = ControlIntent(target: .blackout, value: 0)
            let playback = ControlIntent(target: .togglePlayback, value: nil)
            let cue = Cue(name: "Original gamepad scene", surfaces: [Surface(name: "Original mapped surface")], duration: 0)
            let recall = ControlIntent(target: .scene(cue.id), value: nil)
            let bindings: [GamepadSession.Button: ControlIntent] = [.a: recall, .b: playback, .x: blackoutOn, .y: blackoutOff]

            profile.buttonA.setValue(1)
            try session.arm(controller: selected, bindings: bindings)
            try expect(session.poll(at: 1, acceptsInput: true).isEmpty, "Held button fired during arming")
            otherProfile.buttonA.setValue(1)
            try expect(session.poll(at: 1.01, acceptsInput: true).isEmpty, "Unselected controller produced an action")
            profile.buttonA.setValue(0)
            try expect(session.poll(at: 1.02, acceptsInput: true).isEmpty, "Button release produced an action")
            profile.buttonA.setValue(1)
            let selectedActions = session.poll(at: 1.03, acceptsInput: true)
            try expect(selectedActions == [recall], "Selected controller did not produce the cue intent")
            try expect(session.poll(at: 1.04, acceptsInput: true).isEmpty, "A held button repeated")
            pass("two native virtual snapshots isolate the selected controller and produce one rising-edge action")

            profile.buttonB.setValue(1)
            try expect(session.poll(at: 1.05, acceptsInput: false).isEmpty, "Background controller input was delivered")
            try expect(session.poll(at: 1.06, acceptsInput: true).isEmpty, "Foreground return fired a held button")
            profile.buttonB.setValue(0)
            _ = session.poll(at: 1.07, acceptsInput: true)
            profile.buttonB.setValue(1)
            profile.buttonX.setValue(1)
            let playAndBlackout = session.poll(at: 1.08, acceptsInput: true)
            try expect(playAndBlackout == [playback, blackoutOn], "Simultaneous mapped buttons lost their stable binding order")
            profile.buttonY.setValue(1)
            let clearBlackout = session.poll(at: 1.09, acceptsInput: true)
            try expect(clearBlackout == [blackoutOff], "Alternate button did not produce blackout off")
            pass("focus loss clears edges and simultaneous actions retain a fixed order")

            try expect(MTLCreateSystemDefaultDevice() != nil, "Gamepad editor test needs a logged-in Metal session")
            let editor = EditorController()
            editor.timer?.invalidate()
            editor.timer = nil
            editor.window?.orderOut(nil)
            editor.metalView.isPaused = true
            editor.lightingView.isPaused = true
            editor.network?.stop()
            editor.midi?.stop()
            editor.lighting.stop()
            defer {
                editor.closeOutputs()
                editor.media.reset()
                editor.dirty = false
                editor.window?.close()
            }
            let baseline = Surface(id: cue.surfaces[0].id, name: "Original starting surface")
            editor.project = Project(name: "Original gamepad test show", surfaces: [baseline], cues: [cue])
            editor.reconcile()
            editor.refresh()
            let host = ProcessInfo.processInfo.systemUptime
            for intent in selectedActions + playAndBlackout { editor.controlMapping.enqueue(intent) }
            editor.flushControlMappings(at: host)
            try expect(editor.project.surfaces == cue.surfaces && editor.showRuntime.isPlaying && editor.blackout,
                       "Native cue, transport and blackout handlers did not apply the gamepad intents")
            clearBlackout.forEach { editor.controlMapping.enqueue($0) }
            editor.flushControlMappings(at: host + 0.01)
            try expect(!editor.blackout, "Native blackout off handler did not apply the gamepad intent")
            pass("queued gamepad intents use the same native cue, playback and blackout paths as other inputs")

            devices = [other]
            try expect(session.poll(at: 1.4, acceptsInput: true).isEmpty && !session.isArmed,
                       "Disconnect kept the old controller armed")
            devices = [selected, other]
            try expect(session.poll(at: 1.70, acceptsInput: true).isEmpty && !session.isArmed,
                       "Reconnect armed without operator selection")
            try session.arm(controller: selected, bindings: bindings)
            session.reset()
            try expect(!session.isArmed && session.poll(at: 1.99, acceptsInput: true).isEmpty,
                       "Project reset retained the controller or its bindings")
            pass("disconnection and project reset disarm the session and reconnect requires explicit arming")
        } catch {
            failure = error.localizedDescription
            fputs("FAIL gamepad: \(error.localizedDescription)\n", stderr)
        }
        var report: [String: Any] = [
            "schemaVersion": 1, "passed": failure == nil, "checkCount": checks.count, "checks": checks,
            "timestampUTC": ISO8601DateFormatter().string(from: Date()),
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began, "hardwareVerification": false,
            "scope": "Native tests with GameController extended snapshots and existing show control intent actions"
        ]
        if let failure { report["failure"] = failure }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/local/gamepad", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        } catch {
            fputs("Gamepad report failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
        return failure == nil ? 0 : 1
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
        guard condition() else { throw SystemFailure(message: reason) }
    }
}
#endif
