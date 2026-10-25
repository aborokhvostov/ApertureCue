import Foundation
#if os(macOS)
import AppKit

MainActor.assumeIsolated {
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
if CommandLine.arguments.contains("--editor-test") {
    exit(EditorSelfTest.run())
}
if CommandLine.arguments.contains("--generate-demo") {
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
