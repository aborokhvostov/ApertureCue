#if os(macOS)
import AppKit
import AVFoundation
import Metal
import CoreVideo
import QuartzCore
import MappingCore

@MainActor enum MediaPlaybackSelfTest {
    struct Failure:LocalizedError {let message:String;var errorDescription:String? {message}}
    private final class SimulatedCamera:MediaCameraSource {
        var next:CVPixelBuffer?
        var error:((String)->Void)?
        var stopped=false
        func start(deviceID:String,onError:@escaping(String)->Void) {error=onError}
        func takeLatest()->CVPixelBuffer? {defer {next=nil};return stopped ? nil : next}
        func stop() {stopped=true;next=nil}
    }
    static func run(soakSeconds:Double=0)->Int32 {
        let directory=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/local/media-playback",isDirectory:true)
        var checks:[String]=[],observations:[String:Any]=[:]
        func expect(_ yes:Bool,_ reason:String)throws {if !yes {throw Failure(message:reason)}}
        func passed(_ name:String) {checks.append(name);print("PASS media: "+name)}
        func write(_ passed:Bool,_ error:String?=nil) {
            var r:[String:Any]=["schemaVersion":1,"passed":passed,"checkCount":checks.count,"checks":checks,"observations":observations,"timestampUTC":ISO8601DateFormatter().string(from:Date()),"platform":ProcessInfo.processInfo.operatingSystemVersionString,"scope":"Original H.264 MOV/PNG and simulated camera through production MediaPool, decoder, textures and source transports. No physical camera/audio/output hardware.","hardwareVerification":false]
            if let error {r["failure"]=error}
            try? JSONSerialization.data(withJSONObject:r,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent(soakSeconds>0 ? "soak-report.json":"report.json"),options:.atomic)
        }
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let fixture=directory.appendingPathComponent("fixture-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:false)
            guard let device=MTLCreateSystemDefaultDevice() else {throw Failure(message:"Metal unavailable")}
            let movie=fixture.appendingPathComponent("original-time-colors.mov")
            try MontageSelfTest.makeMovie(at:movie,fps:30)
            let pool=MediaPool(device:device)
            var a=MediaAsset(name:"Independent A",path:movie.path,kind:"video",volume:0)
            let b=MediaAsset(name:"Master B",path:movie.path,kind:"video",volume:0)
            pool.reconcile(assets:[a,b],baseURL:fixture)
            try expect(pump(10) {pool.duration(for:a.id)>3.9 && pool.duration(for:b.id)>3.9},"Movie metadata unavailable")
            pool.seek(to:0.3)
            try expect(pump(8) {pool.texture(for:a.id) != nil && pool.texture(for:b.id) != nil},"Initial ordinary frames unavailable")
            let bGeneration=pool.seekGeneration(for:b.id)
            pool.sourcePlay(a.id)
            try expect(pump(3) {pool.update();return pool.playbackTime(for:a.id)>0.55},"Independent source did not advance with master paused")
            pool.sourcePause(a.id);let held=pool.playbackTime(for:a.id)
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.12));pool.update()
            try expect(abs(pool.playbackTime(for:a.id)-held)<0.06 && pool.seekGeneration(for:b.id)==bGeneration && abs(pool.playbackTime(for:b.id)-0.3)<0.08,"Independent transport changed the other source or failed to pause")
            pool.seek(to:1.4)
            try expect(pump(5) {pool.update();return abs(pool.playbackTime(for:b.id)-1.4)<0.08},"Master did not seek its follower")
            try expect(abs(pool.playbackTime(for:a.id)-held)<0.06,"Master seek moved an independent source")
            pool.sourceFollowMaster(a.id)
            try expect(pump(5) {pool.update();return abs(pool.playbackTime(for:a.id)-1.4)<0.08},"Follow master did not rejoin")
            passed("ordinary sources independently play/pause/seek and explicitly rejoin the master without seeking adjacent sources")
            pool.pause();pool.seek(to:0.1);_ = pool.texture(for:a.id)
            pool.seek(to:3.4)
            try expect(pool.texture(for:a.id)==nil,"Explicit seek exposed the preceding generation texture")
            pool.seek(to:0.2);pool.seek(to:2.3);pool.seek(to:1.2)
            try expect(pump(8) {pool.texture(for:a.id) != nil && abs(pool.playbackTime(for:a.id)-1.2)<0.08},"Latest rapid seek did not settle")
            try assertColor(pool.texture(for:a.id),second:1,device:device)
            passed("ordinary seek hides stale textures immediately and only the final rapid-seek generation publishes")
            a.playback=MediaPlaybackSettings(trimIn:0.2,trimOut:3.8,rate:1,mode:.loop)
            pool.reconcile(assets:[a,b],baseURL:fixture);pool.sourceFollowMaster(a.id)
            let cases:[(MediaPlaybackMode,Double,Double,Double)]=[(.loop,1,0.4,0.6),(.once,1,10,3.799999),(.hold,1,2,0.2),(.pingPong,1,4,3.4),(.loop,-1,0.4,3.4),(.pingPong,-1,4,0.6)]
            for (mode,rate,elapsed,target) in cases {
                a.playback=MediaPlaybackSettings(trimIn:0.2,trimOut:3.8,rate:rate,mode:mode)
                pool.reconcile(assets:[a,b],baseURL:fixture);pool.sourceSeek(a.id,to:elapsed)
                try expect(pump(10) {pool.update();guard pool.texture(for:a.id) != nil,let pts=pool.presentationTime(for:a.id),let end=pool.frameEnd(for:a.id) else {return false};return pts<=target+1e-6 && end>target},"Managed \(mode)/\(rate) did not acquire the covering PTS at \(target)")
                try assertColor(pool.texture(for:a.id),second:Int(floor(target)),device:device)
            }
            passed("trim, once, hold, loop, ping-pong and reverse display independently expected H.264 colors and covering PTS intervals")
            a.playback=MediaPlaybackSettings(mode:.random,randomSeed:7,randomInterval:0.25)
            pool.reconcile(assets:[a,b],baseURL:fixture)
            var trace:[Double]=[]
            for elapsed in [0.0,0.5,1.25,0.5] {
                pool.sourceSeek(a.id,to:elapsed)
                let expected=try MediaPlayback.sample(elapsed:elapsed,duration:4,settings:a.playback!).position
                try expect(pump(10) {pool.update();guard pool.texture(for:a.id) != nil,let pts=pool.presentationTime(for:a.id),let end=pool.frameEnd(for:a.id) else {return false};return pts<=expected+1e-6 && end>expected},"Random seek did not cover its requested frame")
                trace.append(pool.presentationTime(for:a.id)!)
            }
            try expect(trace[1]==trace[3],"Repeated random seek changed deterministic frame")
            observations["randomPresentationTrace"]=trace
            passed("seeded random reader trace is stable across nonmonotonic and repeated seeks")
            let gapFrame=MontageDecodedFrame(buffer:try pixelBuffer(),pts:1.5,end:1.533333333,allowLag:true,transform:.identity,naturalSize:CGSize(width:32,height:16),reverseLagStart:1.5)
            let contiguousFrame=MontageDecodedFrame(buffer:try pixelBuffer(),pts:1.5,end:1.533333333,allowLag:true,transform:.identity,naturalSize:CGSize(width:32,height:16),reverseLagStart:0.5)
            try expect(!MontageVideoSlot.permitsFrame(gapFrame,time:1.49,playing:true,backward:true,rate:1),"Reverse frame bridged a declared PTS gap")
            try expect(MontageVideoSlot.permitsFrame(contiguousFrame,time:1.45,playing:true,backward:true,rate:1),"Bounded reverse continuous lag was rejected")
            try expect(!MontageVideoSlot.permitsFrame(contiguousFrame,time:1.37,playing:true,backward:true,rate:1) && !MontageVideoSlot.permitsFrame(contiguousFrame,time:1.45,playing:false,backward:true,rate:1),"Reverse lag exceeded its time limit or leaked into a paused seek")
            passed("reverse late-frame admission respects contiguous PTS runs, explicit gaps, the 120ms bound and exact paused seeks")
            a.playback=MediaPlaybackSettings(trimIn:10,trimOut:11)
            pool.reconcile(assets:[a],baseURL:fixture)
            try expect(pump(8) { _=pool.texture(for:a.id);return pool.errorMessages[a.id]?.contains("trim") == true},"Out-of-extent trim did not produce a diagnostic")
            passed("syntactically valid trim outside actual media extent produces a visible diagnostic")
            let sequenceURL=fixture.appendingPathComponent("sequence",isDirectory:true)
            try FileManager.default.createDirectory(at:sequenceURL,withIntermediateDirectories:false)
            let names=["frame1.png","frame2.png","frame10.png"]
            for (index,name) in names.enumerated() {try makePNG(at:sequenceURL.appendingPathComponent(name),rgb:colors[index])}
            let manifest=try EditorController.sequenceManifest(at:sequenceURL,fps:2)
            try expect(manifest.frames==names,"Natural numeric sequence sorting differs")
            var sequence=MediaAsset(name:"Sequence",path:sequenceURL.path,kind:"sequence",volume:0);sequence.sequence=manifest
            pool.reconcile(assets:[sequence],baseURL:fixture)
            for index in 0..<3 {
                pool.sourceSeek(sequence.id,to:Double(index)/2)
                try expect(pump(5) {pool.texture(for:sequence.id) != nil},"Sequence frame unavailable")
                try assertColor(pool.texture(for:sequence.id),second:index,device:device,tolerance:3)
            }
            try makePNG(at:sequenceURL.appendingPathComponent("frame3.png"),rgb:colors[3])
            try expect(sequence.sequence?.frames.count==3,"Directory addition changed frozen manifest")
            pool.reloadAsset(id:sequence.id,assets:[sequence],baseURL:fixture)
            try FileManager.default.removeItem(at:sequenceURL.appendingPathComponent(names[1]))
            pool.sourceSeek(sequence.id,to:0.5)
            try expect(pump(5) {_=pool.texture(for:sequence.id);return pool.errorMessages[sequence.id] != nil},"Missing sequence frame had no diagnostic")
            try expect(pool.texture(for:sequence.id)==nil,"Missing sequence frame reused a different frame")
            try makePNG(at:sequenceURL.appendingPathComponent(names[1]),rgb:colors[1])
            pool.reloadAsset(id:sequence.id,assets:[sequence],baseURL:fixture)
            try expect(!pool.sourceFollowsMaster(for:sequence.id) && abs(pool.sourceElapsedTime(for:sequence.id)-0.5)<1e-9,"Same-path reload changed independent paused transport")
            try expect(pump(5) {pool.texture(for:sequence.id) != nil},"Restored same-path sequence frame did not reload")
            passed("frozen naturally sorted folder frames, missing-frame fallback and same-path restoration use exact bounded image resources")
            let repeated=MediaImageSequence(device:device,directory:sequenceURL,manifest:MediaSequenceSettings(frames:[names[0]],fps:2))
            for _ in 0..<100 {_=repeated.resource(at:0)}
            try expect(pump(5) {repeated.resource(at:0) != nil},"Repeated sequence request failed")
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.1))
            try expect(repeated.loads==1,"Pending repeated sequence requests decoded a cached frame twice")
            let bad=sequenceURL.appendingPathComponent("bad.png");try Data("original invalid PNG fixture".utf8).write(to:bad)
            let corrupt=MediaImageSequence(device:device,directory:sequenceURL,manifest:MediaSequenceSettings(frames:["bad.png"]))
            var callbacks=0;corrupt.onChange={callbacks+=1}
            _=corrupt.resource(at:0)
            try expect(pump(3) {!corrupt.message.isEmpty && callbacks>0},"Corrupt frame diagnostic missing")
            for _ in 0..<30 {_=corrupt.resource(at:0);RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005))}
            try expect(callbacks==1,"Corrupt frame retried on every rendering pull")
            passed("sequence requests coalesce during decode and cache failed frames until explicit refresh/relink")
            var occupied=MediaImageBudget.shared.reserve(MediaImageBudget.shared.maximumBytes-MediaImageBudget.shared.usedBytes)
            try expect(occupied != nil,"Could not install bounded image admission fixture")
            let temporarilyBusy=MediaImageSequence(device:device,directory:sequenceURL,manifest:MediaSequenceSettings(frames:[names[0]]))
            _=temporarilyBusy.resource(at:0)
            try expect(pump(3) {temporarilyBusy.message.contains("occupied")},"Busy image budget did not diagnose")
            occupied=nil
            try expect(pump(5) {temporarilyBusy.resource(at:0) != nil},"Transient image budget pressure became a permanently failed frame")
            try expect(MediaImageBudget.shared.usedBytes<=MediaImageBudget.shared.maximumBytes,"Retained image payload exceeded the shared limit")
            passed("transient image admission pressure retries after leases release without permanently poisoning a frame")

            pool.reset()
            var cameras:[SimulatedCamera]=[]
            let cameraPool=MediaPool(device:device,cameraFactory:{let camera=SimulatedCamera();cameras.append(camera);return camera})
            let camera=MediaAsset(name:"Original simulated camera",path:"original-simulator",kind:"camera",volume:0)
            cameraPool.reconcile(assets:[camera],baseURL:fixture)
            cameras[0].next=try pixelBuffer()
            try expect(cameraPool.texture(for:camera.id) != nil,"Simulated camera frame was not published")
            let retained=cameraPool.frameResources(for:[camera.id])
            cameras[0].error?("Camera disconnected · simulated")
            try expect(pump(2) {cameraPool.texture(for:camera.id)==nil && cameras[0].stopped},"Disconnected camera retained image or capture")
            try expect(retained.textures[camera.id] != nil && retained.buffers.count==1,"In-flight camera resource lease was invalidated")
            cameraPool.reloadAsset(id:camera.id,assets:[camera],baseURL:fixture)
            cameras[1].next=try pixelBuffer();_=cameraPool.texture(for:camera.id)
            cameras[0].error?("Late old camera error")
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.03))
            try expect(cameraPool.texture(for:camera.id) != nil && cameraPool.errorMessages[camera.id]==nil,"Late old session error invalidated replacement camera")
            passed("camera simulator disconnect clears capture/latest frame while retained GPU buffers survive; old-session callbacks cannot clear replacement")
            let videos=(0..<9).map {index -> MediaAsset in var v=MediaAsset(name:"Admission \(index)",path:movie.path,kind:"video",volume:0);v.playback=MediaPlaybackSettings();return v}
            pool.setActiveAssetIDs(Set(videos.prefix(8).map(\.id)));pool.reconcile(assets:videos,baseURL:fixture)
            try expect(pump(12) {for v in videos.prefix(8) {_=pool.texture(for:v.id)};return pool.activeManagedDecoderCount==8},"Eight managed slots not admitted")
            pool.setActiveAssetIDs([videos[8].id])
            try expect(pump(10) {pool.texture(for:videos[8].id) != nil},"Inactive decoders blocked ninth source assignment")
            try expect(pool.activeManagedDecoderCount==1,"Inactive managed slots stayed retained")
            passed("eight-reader admission releases inactive assignments and permits the ninth source without document deletion")
            pool.setActiveAssetIDs(Set(videos.map(\.id)));pool.setVideoDemandIDs(Set(videos.prefix(8).map(\.id)))
            for video in videos.prefix(8) {_=pool.texture(for:video.id)}
            pool.setVideoDemandIDs([videos[8].id])
            try expect(pump(10) {pool.texture(for:videos[8].id) != nil},"Hidden assigned sources blocked a newly visible managed source")
            try expect(pool.activeManagedDecoderCount==1,"Hidden managed video leases were not retired independently of audio assignment")
            passed("visible video demand retires hidden-but-assigned readers while preserving ordinary audio assignment semantics")
            let audioURL=fixture.appendingPathComponent("original-route-retry.wav");try MediaDemo.wave().write(to:audioURL)
            var audioInstances:[MediaAudioPlayer]=[]
            let routedPool=MediaPool(device:device,audioFactory:{let player=MediaAudioPlayer(offline:true);audioInstances.append(player);return player})
            let routed=MediaAsset(name:"Original silent routing retry",path:audioURL.path,kind:"audio",volume:0,audioRouting:AudioRoutingSettings())
            routedPool.reconcile(assets:[routed],baseURL:fixture)
            try expect(pump(10) {routedPool.update();return audioInstances.first?.ready==true},"Routed source did not prepare its actual offline backend")
            audioInstances[0].invalidate();routedPool.retryAudio(for:routed.id)
            try expect(pump(10) {routedPool.update();return audioInstances.count==2 && audioInstances[1].ready},"Explicit same-route retry did not replace the stopped backend")
            routedPool.reset();audioInstances.forEach {$0.invalidate()}
            passed("same saved audio route explicitly retries a stopped backend using the actual silent offline engine")
            pool.reset()
            if soakSeconds>0 {try soak(pool:pool,device:device,movie:movie,fixture:fixture,seconds:soakSeconds,observations:&observations);passed("bounded multi-source playback soak records actual PTS age, drops, generations and clock drift")}
            observations["retainedImagePayloadBytes"]=MediaImageBudget.shared.usedBytes
            observations["imagePayloadLimitBytes"]=MediaImageBudget.shared.maximumBytes
            write(true);print("PASS media playback: \(checks.count) checks");return 0
        } catch {write(false,error.localizedDescription);fputs("MEDIA PLAYBACK FAILED: \(error.localizedDescription)\n",stderr);return 1}
    }
    private static let colors:[[UInt8]]=[[230,20,20,255],[20,230,20,255],[20,20,230,255],[230,230,20,255]]
    private static func pump(_ seconds:Double,_ body:()->Bool)->Bool {
        let end=CACurrentMediaTime()+seconds
        repeat {if body() {return true};RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01))} while CACurrentMediaTime()<end
        return body()
    }
    private static func assertColor(_ texture:MTLTexture?,second:Int,device:MTLDevice,tolerance:Int=12)throws {
        guard let texture,let queue=device.makeCommandQueue(),let command=queue.makeCommandBuffer(),let encoder=command.makeBlitCommandEncoder() else {throw Failure(message:"Texture readback unavailable")}
        let stride=((texture.width*4+255)/256)*256
        guard let buffer=device.makeBuffer(length:stride*texture.height,options:.storageModeShared) else {throw Failure(message:"Readback allocation failed")}
        encoder.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:texture.width,height:texture.height,depth:1),to:buffer,destinationOffset:0,destinationBytesPerRow:stride,destinationBytesPerImage:stride*texture.height)
        encoder.endEncoding();command.commit();command.waitUntilCompleted()
        let bytes=buffer.contents().assumingMemoryBound(to:UInt8.self),offset=(texture.height/2)*stride+(texture.width/2)*4
        let bgra=texture.pixelFormat == .bgra8Unorm
        let pixel=[bytes[offset+(bgra ? 2:0)],bytes[offset+1],bytes[offset+(bgra ? 0:2)]]
        guard zip(pixel,colors[((second%4)+4)%4]).allSatisfy({abs(Int($0)-Int($1))<=tolerance}) else {throw Failure(message:"Frame color \(pixel) did not match independently expected second \(second)")}
    }
    private static func makePNG(at url:URL,rgb:[UInt8])throws {
        guard let image=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:32,pixelsHigh:16,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bitmapFormat:.alphaNonpremultiplied,bytesPerRow:128,bitsPerPixel:32),let bytes=image.bitmapData else {throw Failure(message:"PNG allocation failed")}
        for index in 0..<(32*16) {for c in 0..<4 {bytes[index*4+c]=rgb[c]}}
        guard let data=image.representation(using:.png,properties:[:]) else {throw Failure(message:"PNG encoding failed")};try data.write(to:url)
    }
    private static func pixelBuffer()throws->CVPixelBuffer {
        var result:CVPixelBuffer?;CVPixelBufferCreate(kCFAllocatorDefault,32,16,kCVPixelFormatType_32BGRA,[kCVPixelBufferMetalCompatibilityKey:true,kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&result)
        guard let result else {throw Failure(message:"Camera fixture buffer unavailable")};return result
    }
    private static func soak(pool:MediaPool,device:MTLDevice,movie:URL,fixture:URL,seconds:Double,observations:inout [String:Any])throws {
        var sources=(0..<4).map {MediaAsset(name:"Soak \($0)",path:movie.path,kind:"video",volume:0)}
        sources[2].playback=MediaPlaybackSettings(rate:1.5,mode:.loop);sources[3].playback=MediaPlaybackSettings(rate:-1,mode:.pingPong)
        pool.setActiveAssetIDs(Set(sources.map(\.id)));pool.reconcile(assets:sources,baseURL:fixture)
        guard pump(12,{sources.allSatisfy {pool.duration(for:$0.id)>3.9}}) else {throw Failure(message:"Soak sources unavailable")}
        pool.seek(to:0);pool.play()
        let start=CACurrentMediaTime();var polls=0,missing=0,maxDrift=0.0,maxPTSAge=0.0,decoded=0
        var framesBySource=Dictionary(uniqueKeysWithValues:sources.map {($0.id,0)})
        while CACurrentMediaTime()-start<seconds {
            pool.update();polls+=1
            for source in sources {
                if pool.texture(for:source.id)==nil {missing+=1} else {framesBySource[source.id,default:0]+=1}
                if source.playback==nil {
                    let wanted=pool.currentTime.truncatingRemainder(dividingBy:4),actual=pool.playbackTime(for:source.id),delta=abs(actual-wanted)
                    maxDrift=max(maxDrift,min(delta,4-delta))
                } else if let pts=pool.presentationTime(for:source.id) {maxPTSAge=max(maxPTSAge,abs(pool.playbackTime(for:source.id)-pts))}
                decoded+=pool.decodedFrameCount(for:source.id)>0 ? 1:0
            }
            RunLoop.main.run(until:Date(timeIntervalSinceNow:1.0/30))
        }
        pool.pause()
        observations["soak"]=["seconds":CACurrentMediaTime()-start,"sourceCount":sources.count,"logicalOutputs":0,"resolution":[160,96],"codec":"original H.264 MOV 30fps","polls":polls,"sourcePulls":polls*sources.count,"missingFramePulls":missing,"maximumLegacyClockDriftSeconds":maxDrift,"maximumManagedPTSAgeSeconds":maxPTSAge,"successfulDecodedSourcePolls":decoded,"totalDecodedFrames":sources.reduce(0,{$0+pool.decodedFrameCount(for:$1.id)}),"clockResynchronizations":sources.reduce(0,{$0+pool.synchronizationCorrectionCount(for:$1.id)}),"managedDecoderCount":pool.activeManagedDecoderCount,"acceptedPullsBySource":sources.map {framesBySource[$0.id,default:0]},"imagePayloadBytes":MediaImageBudget.shared.usedBytes,"limitations":"No optical output, audible audio, hardware throughput or show-length guarantee; missing pulls include startup and intentional backward-generation resets." ]
        guard sources.allSatisfy({framesBySource[$0.id,default:0]>max(2,polls/10)}) else {throw Failure(message:"Soak did not publish sustained frames for every source: \(sources.map {framesBySource[$0.id,default:0]})") }
        guard maxPTSAge<=0.12*1.5+1.0/30+0.01 else {throw Failure(message:"Managed frame age exceeded its independent 120ms scaled-rate plus frame-interval bound") }
        guard maxDrift<0.25 else {throw Failure(message:"Legacy source clock drift exceeded 250ms during soak")}
        pool.reset();_ = device
    }
}
#endif
