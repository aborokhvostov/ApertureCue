import Foundation
#if os(macOS)
import AppKit
import MappingCore

MainActor.assumeIsolated {
if CommandLine.arguments.contains("--conductor-test") {exit(ConductorSelfTest.run())}
if CommandLine.arguments.contains("--show-schedule-test") {exit(ShowScheduleEditorSelfTest.run())}
if CommandLine.arguments.contains("--show-clock-fixture") {exit(ShowControlSelfTest.clockFixture(arguments:CommandLine.arguments))}
if CommandLine.arguments.contains("--show-control-test") {exit(ShowControlSelfTest.run())}
if CommandLine.arguments.contains("--source-editor-test") {exit(MediaSourceEditorSelfTest.runStandalone())}
if CommandLine.arguments.contains("--durability-writer") {exit(MediaDurabilitySelfTest.writer(arguments:CommandLine.arguments))}
if CommandLine.arguments.contains("--durability-test") {exit(MediaDurabilitySelfTest.run())}
if CommandLine.arguments.contains("--media-playback-test") {exit(MediaPlaybackSelfTest.run())}
if CommandLine.arguments.contains("--media-soak-test") {exit(MediaPlaybackSelfTest.run(soakSeconds:120))}
if CommandLine.arguments.contains("--audio-test") {exit(MediaAudioSelfTest.run())}
if CommandLine.arguments.contains("--live-editor-test") {exit(LiveEditorSelfTest.run())}
if CommandLine.arguments.contains("--live-composition-test") {exit(LiveCompositionSelfTest.run())}
if CommandLine.arguments.contains("--composition-test") {exit(CompositionSelfTest.run())}
if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run())
}
if CommandLine.arguments.contains("--protocol-loopback") {
    exit(ProtocolLoopback.run())
}
if CommandLine.arguments.contains("--benchmark") {
    exit(SelfTest.runLiveBenchmark())
}
if CommandLine.arguments.contains("--lighting-test") {
    exit(LightingSelfTest.run())
}
if CommandLine.arguments.contains("--montage-test") {
    exit(MontageSelfTest.run())
}
if CommandLine.arguments.contains("--editor-test") {
    exit(EditorSelfTest.run())
}
if CommandLine.arguments.dropFirst().first == "--generate-show-demo" {
    guard CommandLine.arguments.count == 3 else { fputs("Provide a new project path\n", stderr); exit(1) }
    let destination = URL(fileURLWithPath: CommandLine.arguments[2])
    let model = ConductorSelfTest.fixture()
    do {
        try ProjectStore.validate(model)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(model).write(to: destination, options: [.withoutOverwriting])
        print("Created original Show Control demo")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--generate-media-demo") {
    do {
        let path=CommandLine.arguments.dropFirst(2).first ?? "examples/Media"
        try MediaDemo.generate(at:URL(fileURLWithPath:path,isDirectory:true));print("Created original media demo in \(path)")
    } catch {fputs("\(error)\n",stderr);exit(1)}
} else if CommandLine.arguments.contains("--generate-composition-demo") {
    do {
        let path=CommandLine.arguments.dropFirst(2).first ?? "examples/Demo"
        try DemoGenerator.generateComposition(at:URL(fileURLWithPath:path,isDirectory:true))
        print("Created original composition demo in \(path)")
    } catch {fputs("\(error)\n",stderr);exit(1)}
} else if CommandLine.arguments.contains("--generate-demo") {
    do {
        let target = CommandLine.arguments.dropFirst(2).first ?? "examples/Demo"
        try DemoGenerator.generate(at: URL(fileURLWithPath: target, isDirectory: true))
        print("Created demo in \(target)")
    } catch { fputs("\(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
}
#else
print("ApertureCue's desktop renderer requires macOS 13+. MappingCore is portable.")
#endif
