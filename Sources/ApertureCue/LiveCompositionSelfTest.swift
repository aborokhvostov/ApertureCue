#if os(macOS)
import AppKit
import MetalKit
import QuartzCore
import MappingCore

/// At most one probe is waiting on main. A blocked AppKit thread cannot create
/// an unbounded queue of measurement callbacks or hide the delay by timer drift.
final class CompositionMainQueueProbe: @unchecked Sendable {
    struct Statistics {
        let count:Int,meanMilliseconds:Double,maximumMilliseconds:Double
        var json:[String:Any] {["count":count,"meanMilliseconds":meanMilliseconds,"maximumMilliseconds":maximumMilliseconds]}
    }
    private let lock=NSLock()
    private let timer=DispatchSource.makeTimerSource(queue:DispatchQueue(label:"org.aperturecue.main-queue-probe",qos:.userInitiated))
    private var pending=false,stopped=false
    private var generation:UInt64=0
    private var count=0,total=0.0,maximum=0.0
    init() {
        timer.schedule(deadline:.now(),repeating:.milliseconds(20))
        timer.setEventHandler { [weak self] in self?.request() };timer.resume()
    }
    func reset() {lock.lock();generation &+= 1;count=0;total=0;maximum=0;lock.unlock()}
    func stop() {lock.lock();stopped=true;lock.unlock();timer.cancel()}
    var statistics:Statistics {
        lock.lock();defer {lock.unlock()}
        return Statistics(count:count,meanMilliseconds:count>0 ? total/Double(count)*1000 : 0,maximumMilliseconds:maximum*1000)
    }
    private func request() {
        lock.lock()
        guard !pending,!stopped else {lock.unlock();return}
        pending=true;let token=generation;lock.unlock()
        let requested=CACurrentMediaTime()
        DispatchQueue.main.async { [weak self] in
            guard let self else {return}
            let delay=CACurrentMediaTime()-requested
            self.lock.lock();defer {self.lock.unlock()};self.pending=false
            guard !self.stopped,self.generation==token else {return}
            self.count+=1;self.total+=delay;self.maximum=max(self.maximum,delay)
        }
    }
    deinit {timer.cancel()}
}

/// Only the first acquisition waits, controlled by the main test. This makes
/// the starvation check deterministic without relying on refresh/FPS timing.
private final class CompositionDrawableGate: @unchecked Sendable {
    private let lock=NSLock(),release=DispatchSemaphore(value:0)
    private var first=true,entered=false,returned=false,mainThread=false
    var didEnter:Bool {lock.lock();defer {lock.unlock()};return entered}
    var enteredOnMain:Bool {lock.lock();defer {lock.unlock()};return mainThread}
    var didReturn:Bool {lock.lock();defer {lock.unlock()};return returned}
    func acquire(_ layer:CAMetalLayer)->CAMetalDrawable? {
        lock.lock();let wait=first;first=false;entered=true;mainThread=mainThread || Thread.isMainThread;lock.unlock()
        if wait {_=release.wait(timeout:.now()+5)}
        let drawable=layer.nextDrawable()
        lock.lock();returned=true;lock.unlock();return drawable
    }
    func open() {release.signal()}
}

private final class CompositionDrawableFailures: @unchecked Sendable {
    // The renderer's serial acquisition queue is the sole owner of this state.
    private var remaining=3
    func acquire(_ layer:CAMetalLayer)->CAMetalDrawable? {
        if remaining>0 {remaining-=1;return nil};return layer.nextDrawable()
    }
}

@MainActor enum LiveCompositionSelfTest {
    private struct Failure:LocalizedError {let message:String;var errorDescription:String? {message}}
    static func run()->Int32 {
        let started=CACurrentMediaTime()
        let directory=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/local/live-composition",isDirectory:true)
        let reportURL=directory.appendingPathComponent("report.json")
        var report:[String:Any]=[
            "schemaVersion":1,"timestampUTC":ISO8601DateFormatter().string(from:Date()),
            "platform":ProcessInfo.processInfo.operatingSystemVersionString,
            "hardwareVerification":false,"windowsShown":true,"requestedDrawableSize":[1920,1080],
            "source":"Original Composition demo: five procedural layers, two logical routes combined in one editor-style view, isolated/projective group, cubic masks, materials and color FX; no decoder or network.",
            "limitations":"Local graphics session may use a virtual display. Measures command submissions and main-queue response, not optical refresh or hardware compatibility. No long-show, throughput, decoder/audio or GPU-utilization claim. The gate fixture injects an acquisition wait; it is separate from the real Composition interval."
        ]
        var checks:[String]=[],windows:[NSWindow]=[],views:[MTKView]=[]
        let probe=CompositionMainQueueProbe(),gate=CompositionDrawableGate()
        defer {gate.open();probe.stop();views.forEach {$0.isPaused=true};windows.forEach {$0.close()}}
        func expect(_ value:Bool,_ message:String)throws {if !value {throw Failure(message:message)}}
        func pump(timeout:Double,_ condition:()->Bool)->Bool {
            let end=CACurrentMediaTime()+timeout
            repeat {if condition() {return true};RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005))} while CACurrentMediaTime()<end
            return condition()
        }
        func pass(_ name:String) {checks.append(name);print("PASS live composition: "+name)}
        func save(_ success:Bool,_ failure:String?=nil) {
            report["passed"]=success;report["checks"]=checks;report["checkCount"]=checks.count;report["elapsedSeconds"]=CACurrentMediaTime()-started
            if let failure {report["failure"]=failure}
            do {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL,options:.atomic)
            } catch {fputs("Live composition report error: \(error)\n",stderr)}
        }
        func show(_ view:MTKView,_ title:String)->NSWindow {
            let window=NSWindow(contentRect:view.frame,styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.title=title;window.contentView=view
            windows.append(window);views.append(view);window.center();window.makeKeyAndOrderFront(nil);return window
        }
        do {
            let app=NSApplication.shared;app.setActivationPolicy(.accessory)
            guard let device=MTLCreateSystemDefaultDevice() else {throw Failure(message:"No Metal device in logged-in graphics session")}
            report["gpu"]=device.name
            let media=MediaPool(device:device);defer {media.pause()}
            let fixtureDirectory=directory.appendingPathComponent("original-fixture",isDirectory:true)
            try DemoGenerator.generateComposition(at:fixtureDirectory)
            let project=try ProjectStore.load(from:fixtureDirectory.appendingPathComponent("Composition.aperturecue.json"))
            let view=MTKView(frame:NSRect(x:0,y:0,width:960,height:540),device:device)
            guard let renderer=MetalRenderer(view:view,media:media) else {throw Failure(message:MetalRenderer.lastInitializationError)}
            view.isPaused=true;view.autoResizeDrawable=false;view.drawableSize=CGSize(width:1920,height:1080)
            renderer.surfaces=try GroupEngine.resolveForComposition(surfaces:project.surfaces,groups:project.groups)
            renderer.compositionGroups=project.groups;renderer.globalMasks=project.globalMasks;renderer.materialDefinitions=project.materials;renderer.materialTime=0
            let compositionWindow=show(view,"ApertureCue · Composition drawable responsiveness")
            let warmup=CACurrentMediaTime()
            repeat {
                view.draw();RunLoop.main.run(until:Date(timeIntervalSinceNow:1.0/60))
            } while renderer.completedFrameCount<3 && CACurrentMediaTime()-warmup<30
            try expect(renderer.completedFrameCount>=3 && renderer.errorDescription.isEmpty,"Composition warmup did not submit/complete: "+renderer.errorDescription)
            report["warmupSeconds"]=CACurrentMediaTime()-warmup
            report["startupMainQueueProbe"]=probe.statistics.json
            probe.reset()
            let before=renderer.frameCount,completedBefore=renderer.completedFrameCount,interval=CACurrentMediaTime()
            repeat {
                renderer.materialTime=CACurrentMediaTime()-interval
                view.draw();RunLoop.main.run(until:Date(timeIntervalSinceNow:1.0/60))
            } while CACurrentMediaTime()-interval<6
            try expect(pump(timeout:3,{!renderer.drawableAcquisitionPending && renderer.completedFrameCount>=renderer.frameCount}),"Composition live submissions did not drain")
            let measuredProbe=probe.statistics
            try expect(renderer.frameCount>before && renderer.completedFrameCount>completedBefore && measuredProbe.count>=5,"Composition interval lacked completed drawables or main-queue samples")
            try expect(renderer.lastDrawableSize==CGSize(width:1920,height:1080) && renderer.errorDescription.isEmpty,"Composition drawable size/diagnostic differs: "+renderer.errorDescription)
            report["compositionInterval"]=[
                "seconds":CACurrentMediaTime()-interval,"submittedCommands":renderer.frameCount-before,
                "completedCommands":renderer.completedFrameCount-completedBefore,
                "drawableSize":[Int(renderer.lastDrawableSize.width),Int(renderer.lastDrawableSize.height)],
                "mainQueueProbe":measuredProbe.json,"maximumDrawableWaitMilliseconds":renderer.maxDrawableWaitMilliseconds,
                "maximumGPUExecutionMilliseconds":renderer.maxGPUMilliseconds,
                "meanEncodeSubmissionMilliseconds":renderer.totalCPUMilliseconds/Double(max(1,renderer.frameCount)),
                "droppedRequests":renderer.droppedFrames,"failedDrawableRequests":renderer.failedDrawableRequests
            ]
            pass("real 1920×1080 Composition drawables complete while bounded main-queue probes are measured")
            compositionWindow.orderOut(nil)

            let faultView=MTKView(frame:NSRect(x:0,y:0,width:320,height:180),device:device)
            guard let fault=MetalRenderer(view:faultView,media:media,acquireDrawable:{gate.acquire($0)}) else {throw Failure(message:MetalRenderer.lastInitializationError)}
            faultView.isPaused=true;faultView.autoResizeDrawable=false;faultView.drawableSize=CGSize(width:320,height:180)
            fault.surfaces=[Surface(name:"Original wait fixture",output:Point2.unitQuad,generator:"solid")]
            let faultWindow=show(faultView,"ApertureCue · bounded acquisition wait fixture")
            probe.reset();faultView.draw()
            try expect(pump(timeout:2,{gate.didEnter}),"Acquisition gate was not reached")
            let hold=CACurrentMediaTime(),requests=fault.drawableRequestCount
            repeat {
                fault.draw(in:faultView)
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01))
            } while CACurrentMediaTime()-hold<0.5
            let gatedProbe=probe.statistics
            try expect(!gate.enteredOnMain && fault.drawableAcquisitionPending && requests==1 && fault.drawableRequestCount==requests,"Acquisition ran on main or display ticks queued additional waits")
            try expect(gatedProbe.count>=5,"Main-queue probes could not execute while drawable acquisition was held")
            // Resize while the first drawable is outstanding. Its completion
            // must be rejected; the next request must still have a free slot.
            faultView.drawableSize=CGSize(width:400,height:225)
            let heldSeconds=CACurrentMediaTime()-hold;gate.open()
            try expect(pump(timeout:3,{!fault.drawableAcquisitionPending}),"Resized acquisition did not finish")
            try expect(fault.frameCount==0 && fault.cancelledDrawableRequests==1,"Stale-size drawable reached composition encoding")
            faultView.draw()
            try expect(pump(timeout:3,{fault.completedFrameCount>=1}),"Rendering did not resume after cancelled acquisition")
            try expect(fault.lastDrawableSize==CGSize(width:400,height:225),"Resumed drawable retained the old dimensions")
            pass("held drawable acquisition leaves main responsive, coalesces ticks and cancels a stale resize before resuming")
            let submitted=fault.frameCount,cancelled=fault.cancelledDrawableRequests
            faultView.draw();faultWindow.orderOut(nil)
            try expect(pump(timeout:3,{!fault.drawableAcquisitionPending}),"Hidden-window acquisition did not finish")
            try expect(fault.frameCount==submitted && fault.cancelledDrawableRequests==cancelled+1,"Hidden-window drawable reached encoding")
            report["acquisitionWaitFixture"]=["controlledWaitSeconds":heldSeconds,"mainQueueProbe":gatedProbe.json,"maximumQueuedAcquisitions":1,"cancelledRequests":fault.cancelledDrawableRequests,"resumedDrawableSize":[400,225],"acquisitionEnteredOnMain":gate.enteredOnMain]
            pass("hidden-window completion cancels without submitting or retaining an extra queued request")

            let failures=CompositionDrawableFailures(),nilView=MTKView(frame:NSRect(x:0,y:0,width:320,height:180),device:device)
            guard let nilRenderer=MetalRenderer(view:nilView,media:media,acquireDrawable:{failures.acquire($0)}) else {throw Failure(message:MetalRenderer.lastInitializationError)}
            nilView.isPaused=true;nilView.autoResizeDrawable=false;nilView.drawableSize=CGSize(width:320,height:180)
            nilRenderer.surfaces=[Surface(name:"Original nil fixture",output:Point2.unitQuad,generator:"solid")]
            let nilWindow=show(nilView,"ApertureCue · drawable failure recovery fixture")
            for expected in 1...3 {
                nilView.draw()
                try expect(pump(timeout:2,{!nilRenderer.drawableAcquisitionPending && nilRenderer.failedDrawableRequests==UInt64(expected)}),"Nil acquisition did not release its GPU slot")
            }
            nilView.draw()
            try expect(pump(timeout:3,{nilRenderer.completedFrameCount>=1}),"Three nil acquisitions exhausted slots or prevented recovery")
            nilWindow.orderOut(nil)
            pass("three nil drawable results release every reserved slot and permit the next real presentation")

            let releaseGate=CompositionDrawableGate(),releaseView=MTKView(frame:NSRect(x:0,y:0,width:320,height:180),device:device)
            defer {releaseGate.open()}
            var releasedRenderer=MetalRenderer(view:releaseView,media:media,acquireDrawable:{releaseGate.acquire($0)})
            guard releasedRenderer != nil else {throw Failure(message:MetalRenderer.lastInitializationError)}
            releaseView.isPaused=true;releaseView.autoResizeDrawable=false;releaseView.drawableSize=CGSize(width:320,height:180)
            _=show(releaseView,"ApertureCue · renderer lifetime fixture")
            weak var weakRenderer=releasedRenderer
            releaseView.draw()
            try expect(pump(timeout:2,{releaseGate.didEnter}),"Renderer lifetime fixture did not enter acquisition")
            releasedRenderer=nil
            try expect(weakRenderer==nil,"Pending acquisition retained the renderer")
            releaseGate.open()
            try expect(pump(timeout:3,{releaseGate.didReturn}),"Drawable provider did not return after renderer destruction")
            _=pump(timeout:0.05,{false})
            pass("pending acquisition permits renderer destruction and provider return without retaining the renderer")
            save(true);print("PASS live composition report: \(reportURL.path)");return 0
        } catch {report["failureMainQueueProbe"]=probe.statistics.json;save(false,error.localizedDescription);fputs("LIVE COMPOSITION FAILED: \(error.localizedDescription)\n",stderr);return 1}
    }
}
#endif
