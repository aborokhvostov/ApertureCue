#if os(macOS)
import AppKit
import MetalKit
import QuartzCore
import MappingCore

/// The real editor, its production timer and its AppKit/CALayer overlay stay
/// visible. This supplements offscreen/renderer checks; it is not external
/// display, accessibility-client or physical projector verification.
@MainActor enum LiveEditorSelfTest {
    private struct Failure:LocalizedError {let message:String;var errorDescription:String? {message}}
    static func run()->Int32 {
        let started=CACurrentMediaTime()
        let directory=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/local/live-editor",isDirectory:true)
        let reportURL=directory.appendingPathComponent("report.json")
        var report:[String:Any]=[
            "schemaVersion":1,"timestampUTC":ISO8601DateFormatter().string(from:Date()),
            "platform":ProcessInfo.processInfo.operatingSystemVersionString,
            "hardwareVerification":false,"windowsShown":true,"modalDialogs":false,
            "requestedWindowContentSize":[1280,800],"drawableSizing":"Production MTKView.autoResizeDrawable; actual view size and acquired texture dimensions are reported.",
            "scope":"Actual EditorController, generated original Composition project, production 30 Hz timer, live materials, AppKit overlay layers and native mode picker actions.",
            "limitations":"Local graphics session may use a virtual display. Main-queue response and submitted commands are measured; accessibility clients, optical refresh, physical devices, GPU utilization and long-show behavior are unmeasured. Static layer identity is a regression gate for time-only ticks, not a frame-rate claim."
        ]
        var editor:EditorController?,checks:[String]=[]
        let probe=CompositionMainQueueProbe()
        defer {
            probe.stop()
            if let e=editor {
                e.timer?.invalidate();e.timer=nil;e.showRuntime.stop();e.media.pause()
                e.network?.stop();e.midi?.stop();e.lighting?.stop();e.feedback?.reset();e.closeOutputs()
                e.montagePool.reset();e.media.reconcile(assets:[],baseURL:directory)
                e.metalView.isPaused=true;e.timelineWindow?.close();e.cueWindow?.close();e.montageWindow?.close()
                e.dirty=false;e.window?.close()
            }
        }
        func expect(_ value:Bool,_ message:String)throws {if !value {throw Failure(message:message)}}
        func pump(timeout:Double,_ condition:()->Bool)->Bool {
            let end=CACurrentMediaTime()+timeout
            repeat {if condition() {return true};RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005))} while CACurrentMediaTime()<end
            return condition()
        }
        func pass(_ name:String) {checks.append(name);print("PASS live editor: "+name)}
        func save(_ success:Bool,_ failure:String?=nil) {
            report["passed"]=success;report["checks"]=checks;report["checkCount"]=checks.count;report["elapsedSeconds"]=CACurrentMediaTime()-started
            if let failure {report["failure"]=failure}
            do {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL,options:.atomic)
            } catch {fputs("Live editor report error: \(error)\n",stderr)}
        }
        do {
            let app=NSApplication.shared;app.setActivationPolicy(.accessory)
            NSApp.appearance=NSAppearance(named:.darkAqua)
            let fixture=directory.appendingPathComponent("original-fixture-"+UUID().uuidString,isDirectory:true)
            try DemoGenerator.generateComposition(at:fixture)
            let e=EditorController();editor=e
            e.openProject(fixture.appendingPathComponent("Composition.aperturecue.json"))
            try expect(e.project.materials.count>0 && e.project.surfaces.count==5,"Original Composition fixture did not open in the editor")
            e.selectedID=e.project.surfaces.first(where:{$0.bezierWarp != nil})?.id;e.refresh()
            guard let window=e.window else {throw Failure(message:"Editor window unavailable")}
            window.setContentSize(NSSize(width:1280,height:800));window.center()
            e.metalView.autoResizeDrawable=true
            e.showWindow(nil);window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded();e.overlay.displayIfNeeded()
            let warmup=CACurrentMediaTime()
            try expect(pump(timeout:30,{
                e.renderer.completedFrameCount>=3 && e.overlay.layer?.sublayers?.first != nil && window.isVisible
            }),"Actual editor warmup lacked live frames or overlay layers")
            _=pump(timeout:0.3,{false})
            report["startupMainQueueProbe"]=probe.statistics.json
            report["warmupSeconds"]=CACurrentMediaTime()-warmup
            report["gpu"]=e.renderer.device.name
            report["actualWindowContentSize"]=[Int(window.contentView?.bounds.width ?? 0),Int(window.contentView?.bounds.height ?? 0)]
            report["overlayLogicalSize"]=[Double(e.overlay.bounds.width),Double(e.overlay.bounds.height)]
            guard let originalLayer=e.overlay.layer?.sublayers?.first else {throw Failure(message:"Overlay shape layer missing after warmup")}
            let model=e.project,beforeFrames=e.renderer.completedFrameCount
            e.playShow()
            let beforeClock=e.showRuntime.time,interval=CACurrentMediaTime()
            probe.reset()
            _=pump(timeout:6,{false})
            let measured=probe.statistics
            try expect(e.timer?.isValid == true && abs((e.timer?.timeInterval ?? 0)-1.0/30)<1e-9,"Production editor timer stopped or changed cadence")
            try expect(e.showRuntime.isPlaying && e.showRuntime.time>beforeClock+0.5 && (e.renderer.materialTime ?? -1)>beforeClock+0.5,"Production show/material clock did not advance")
            try expect(e.renderer.completedFrameCount>beforeFrames && measured.count>=5,"Visible editor interval lacked completed drawables or main-queue samples")
            try expect(e.renderer.lastDrawableSize.width>0 && e.renderer.lastDrawableSize.height>0,"Live editor did not acquire a drawable")
            try expect(e.overlay.layer?.sublayers?.first === originalLayer,"Material-time-only ticks rebuilt the static overlay layers")
            try expect(e.project==model && e.renderer.errorDescription.isEmpty && e.renderError.isEmpty,"Time-only editor playback mutated the model or produced a diagnostic")
            report["interval"]=[
                "seconds":CACurrentMediaTime()-interval,"showClockDelta":e.showRuntime.time-beforeClock,
                "completedCommands":e.renderer.completedFrameCount-beforeFrames,
                "mainQueueProbe":measured.json,"staticOverlayLayerIdentityPreserved":true,
                "actualViewDrawableSize":[Double(e.metalView.drawableSize.width),Double(e.metalView.drawableSize.height)],
                "lastTextureSize":[Int(e.renderer.lastDrawableSize.width),Int(e.renderer.lastDrawableSize.height)],
                "maximumDrawableWaitMilliseconds":e.renderer.maxDrawableWaitMilliseconds
            ]
            pass("actual visible Composition editor keeps static overlay layers while its production timer, material clock and drawables advance")

            e.modePicker.selectItem(at:1)
            try expect(e.modePicker.sendAction(e.modePicker.action,to:e.modePicker.target),"Input mode native action was not delivered")
            try expect(pump(timeout:3,{
                e.inputMode && e.overlay.inputMode && e.overlay.layer?.sublayers?.first != nil && e.overlay.layer?.sublayers?.first !== originalLayer
            }),"Input mode did not invalidate and redraw the overlay")
            try expect(e.project==model && e.renderer.surfaces.count==1 && e.renderer.compositionGroups.isEmpty && e.renderer.globalMasks.isEmpty,"Input mode changed saved source geometry or retained output composition settings")
            guard let inputLayer=e.overlay.layer?.sublayers?.first else {throw Failure(message:"Input overlay layer missing")}
            pass("native Input mode action redraws the overlay without changing saved source/output geometry")

            e.modePicker.selectItem(at:0)
            try expect(e.modePicker.sendAction(e.modePicker.action,to:e.modePicker.target),"Output mode native action was not delivered")
            try expect(pump(timeout:3,{
                !e.inputMode && !e.overlay.inputMode && e.overlay.layer?.sublayers?.first != nil && e.overlay.layer?.sublayers?.first !== inputLayer
            }),"Output mode did not invalidate and redraw the overlay")
            try expect(e.project==model && e.renderer.compositionGroups==model.groups && e.renderer.globalMasks==model.globalMasks,"Output mode failed to restore composition or changed source/output geometry")
            let beforeResize=e.renderer.completedFrameCount
            window.setContentSize(NSSize(width:1279,height:801));window.contentView?.layoutSubtreeIfNeeded()
            try expect(pump(timeout:5,{e.renderer.completedFrameCount>=beforeResize+3}),"Production auto-resize did not resume completed drawables")
            try expect(e.project==model,"Window resize changed saved source/output geometry")
            report["modeActions"]=["inputOverlayRedrawn":true,"outputOverlayRedrawn":true,"modelPreserved":true,
                                   "resizedWindowRequestedContentSize":[1279,801],
                                   "resizedViewDrawableSize":[Double(e.metalView.drawableSize.width),Double(e.metalView.drawableSize.height)],
                                   "resizedLastTextureSize":[Int(e.renderer.lastDrawableSize.width),Int(e.renderer.lastDrawableSize.height)]]
            pass("native Output mode action restores composition and ordinary auto-resize resumes frames without changing the model")
            save(true);print("PASS live editor report: \(reportURL.path)");return 0
        } catch {
            report["failureMainQueueProbe"]=probe.statistics.json
            if let e=editor {
                report["failureRendererState"]=["requests":e.renderer.drawableRequestCount,"cancelledRequests":e.renderer.cancelledDrawableRequests,
                                                "failedRequests":e.renderer.failedDrawableRequests,"submittedCommands":e.renderer.frameCount,
                                                "completedCommands":e.renderer.completedFrameCount,
                                                "viewDrawableSize":[Double(e.metalView.drawableSize.width),Double(e.metalView.drawableSize.height)],
                                                "lastTextureSize":[Int(e.renderer.lastDrawableSize.width),Int(e.renderer.lastDrawableSize.height)]]
            }
            save(false,error.localizedDescription);fputs("LIVE EDITOR FAILED: \(error.localizedDescription)\n",stderr);return 1
        }
    }
}
#endif
