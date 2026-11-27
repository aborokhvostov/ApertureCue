#if os(macOS)
import AppKit
import Darwin
import Foundation
import MappingCore

@MainActor enum ControlMappingSelfTest {
    static func fixture() -> Project {
        var project = Project.demo()
        project.name = "ApertureCue Control Mapping"
        project.cues[0].duration = 0
        project.controlMap = ControlMap(bindings: [
            .init(input: .osc("/controller/left"), target: .surface(project.surfaces[0].id, parameter: "opacity")),
            .init(input: .osc("/controller/go"), target: .scene(project.cues[0].id)),
            .init(input: .osc("/controller/toggle"), target: .togglePlayback),
            .init(input: .midi(kind: .cc14, channel: 1, number: 1),
                  target: .surface(project.surfaces[1].id, parameter: "opacity"), feedback: true)
        ])
        return project
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SystemFailure(message: message) }
    }

    private static func pump(_ seconds: Double, until condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        return condition()
    }

    private static func send(_ bytes: Data, fd: Int32, port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let count = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        try expect(count == bytes.count, "Could not send an original loopback fixture")
    }

    static func run() -> Int32 {
        let started = ProcessInfo.processInfo.systemUptime
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("ApertureCueControlFixture-" + UUID().uuidString)
        let reportURL = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("artifacts/local/control-mapping/report.json")
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        var checks: [String] = []
        var details: [String: Any] = [:]
        var problem: String?
        let editor = EditorController()
        editor.timer?.invalidate()
        defer {
            editor.resetControlMappings()
            editor.resetShowControlSessions()
            editor.media?.reset()
            editor.lighting?.stop()
            editor.dirty = false
            editor.window?.delegate = nil
            editor.window?.close()
            try? fm.removeItem(at: folder)
        }

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            let projectPath = folder.appendingPathComponent("Control.aperturecue.json")
            let model = fixture()
            let leftID = model.surfaces[0].id
            let rightID = model.surfaces[1].id
            try ProjectStore.save(model, to: projectPath)
            editor.openProject(projectPath)
            try expect(editor.project.controlMap == model.controlMap && editor.network?.isRunning == false,
                       "Schema 15 mappings or disarmed-open state differ")
            editor.mutate("Move original control target") { $0.surfaces.swapAt(0, 1) }
            guard let network = editor.network else { throw SystemFailure(message: "Missing production OSC listener") }
            try network.start(port: 0)
            guard let port = network.boundPort else { throw SystemFailure(message: "OSC did not bind an ephemeral port") }
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            try expect(fd >= 0, "Could not open test sender")
            defer { close(fd) }
            func deliver(_ messages: [OSCMessage]) throws {
                let before = network.stats.datagrams
                try send(OSCCodec.encodeBundle(messages), fd: fd, port: port)
                try expect(pump(3) { network.stats.datagrams > before && !editor.controlMapping.pending.isEmpty },
                           "Production OSC listener did not enqueue the mapped control")
                editor.flushControlMappings(at: ProcessInfo.processInfo.systemUptime)
            }
            try deliver([OSCMessage(address: "/controller/left", arguments: [.float(0.25)]),
                         OSCMessage(address: "/controller/left", arguments: [.float(0.75)])])
            try expect(editor.project.surfaces[1].id == leftID && editor.project.surfaces[1].opacity == 0.75,
                       "OSC route moved to a different surface after reorder")
            editor.undoEdit()
            try expect(editor.project.surfaces[1].opacity == 1, "A coalesced fader did not produce one Undo")
            editor.redoEdit()
            try expect(editor.project.surfaces[1].opacity == 0.75, "Redo lost the coalesced fader result")
            checks.append("Real UDP maps by UUID across reordering, coalesces faders and supports Undo/Redo")

            let direct = ControlAddressSpace.surface(rightID, "gamma")
            try deliver([OSCMessage(address: direct, arguments: [.float(2.5)])])
            try expect(abs(editor.project.surfaces[0].gamma - 2.5) < 0.00001, "Direct OSC used the wrong units")
            let node = editor.queryControlNodes().first { $0.path == direct }
            try expect(node?.value == [.float(2.5)] && node?.access == .readWrite,
                       "OSCQuery's editor snapshot differs from the mapped property")
            try editor.startQuery(port: 0, advertiseLocally: false)
            try expect(pump(4) {
                if case .ready = editor.controlMapping.query.status { return true }
                return false
            }, "Integrated OSCQuery adapter did not start")
            checks.append("Canonical OSC paths write in displayed units and publish the same value in the live Query tree")

            editor.controlMapping.learnNext = true
            let before = editor.project
            let learnPacket = try OSCCodec.encode(OSCMessage(address: "/controller/left", arguments: [.float(0.4)]))
            try send(learnPacket, fd: fd, port: port)
            try expect(pump(2) { !editor.controlMapping.learnNext }, "Learn did not accept an OSC input")
            editor.flushControlMappings(at: started)
            try expect(editor.controlMapping.lastInput == .osc("/controller/left") && editor.project == before,
                       "Learning an input changed the document")
            editor.receiveMappedMIDI(.controlChange14(channel: 1, controller: 1, value: 8192))
            editor.flushControlMappings(at: started)
            try expect(abs(editor.project.surfaces[0].opacity - 8192.0 / 16383) < 0.000001,
                       "14-bit value lost precision in the editor")
            checks.append("Learn consumes one control without applying it and mapped 14-bit CC keeps its exact resolution")

            let filled = try OSCCodec.encodeBundle(Array(repeating: OSCMessage(address: "/controller/toggle", arguments: [.float(0)]), count: 256))
            let initial = network.stats.datagrams
            for _ in 0..<8 { try send(filled, fd: fd, port: port) }
            // Allow the serial receiver to stage data without draining AppKit's
            // main queue. This timing only checks bounded capacity, not throughput.
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while network.stats.datagrams < initial + 8 && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            try expect(network.stats.droppedCommands > 0, "Late main-queue batches exceeded neither the command bound nor the evidence threshold")
            let prior = editor.project
            editor.stopOSCControls()
            _ = pump(0.15) { false }
            try expect(editor.controlMapping.pending.isEmpty && editor.project == prior,
                       "A stopped OSC generation applied queued controls")
            details["mailboxDroppedCommands"] = network.stats.droppedCommands
            try network.start(port: 0, peer: "127.0.0.2")
            guard let peerPort = network.boundPort else { throw SystemFailure(message: "Peer-filtered OSC did not bind") }
            try send(learnPacket, fd: fd, port: peerPort)
            try expect(pump(2) { network.stats.rejected > 0 } && editor.controlMapping.pending.isEmpty,
                       "Peer-filtered OSC accepted a datagram from a different source")
            checks.append("Main mailbox remains bounded, canceled generations cannot dispatch, and an explicit OSC peer is enforced")

            editor.saveTo(projectPath)
            editor.openProject(projectPath)
            try expect(editor.project.controlMap == model.controlMap && !network.isRunning && !editor.controlMapping.queryEnabled,
                       "Save/Open did not preserve mappings or stop live services")
            checks.append("Save/Open preserves saved maps and stops OSC, MIDI and Query")
        } catch { problem = error.localizedDescription }

        let report: [String: Any] = [
            "schemaVersion": 1, "timestampUTC": ISO8601DateFormatter().string(from: Date()),
            "platform": ProcessInfo.processInfo.operatingSystemVersionString, "passed": problem == nil,
            "checkCount": checks.count, "checks": checks, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "hardwareVerification": false, "details": details, "failure": problem ?? ""
        ]
        do {
            try fm.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        } catch { print("FAIL mapping report: " + error.localizedDescription); return 1 }
        if let problem { print("FAIL control mapping: " + problem); return 1 }
        for check in checks { print("PASS control mapping: " + check) }
        return 0
    }
}
#endif
