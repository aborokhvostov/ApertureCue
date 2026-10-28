#if os(macOS)
import AppKit
import AVFoundation
import CoreVideo
import MetalKit
import MappingCore

/// Generated fixtures and the production reader/texture/shader path. This is a
/// local integration check, not XCTest, a playback soak or hardware evidence.
@MainActor enum MontageSelfTest {
    private struct Failure:LocalizedError {
        let message:String
        var errorDescription:String? {message}
    }
    static func run()->Int32 {
        let directory=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/local",isDirectory:true)
        var checks:[String]=[],observations:[[String:Any]]=[]
        var report:[String:Any]=[
            "schemaVersion":1,"timestampUTC":ISO8601DateFormatter().string(from:Date()),
            "platform":ProcessInfo.processInfo.operatingSystemVersionString,"hardwareVerification":false,
            "scope":"Generated local H.264 files, production AVAssetReader/MediaPool/MontagePool and offscreen Metal. No external display/projector, audible audio, hardware throughput or long playback soak is verified."
        ]
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let generated=directory.appendingPathComponent("montage-generated-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:generated,withIntermediateDirectories:true)
            let movie=generated.appendingPathComponent("time-colors.mov")
            let low=generated.appendingPathComponent("one-fps.mov")
            let rotated=generated.appendingPathComponent("rotation90.mov")
            let gapMovie=generated.appendingPathComponent("leading-gap.mov")
            let variableMovie=generated.appendingPathComponent("variable-fps.mov")
            try makeMovie(at:movie,fps:30)
            try makeMovie(at:low,fps:1)
            try makeMovie(at:rotated,fps:2,quadrants:true,rotate:true)
            try makeMovie(at:gapMovie,fps:2,leadingGap:1)
            try makeMovie(at:variableMovie,fps:30,presentationTimes:[0,0.1,2.5,3.8])
            checks.append("original generated H.264 temporal, one-fps and rotation-metadata fixtures encoded")
            _=NSApplication.shared
            guard let device=MTLCreateSystemDefaultDevice() else {throw Failure(message:"No Metal device in the logged-in session")}
            report["gpu"]=device.name
            let media=MediaPool(device:device),pool=MontagePool(device:device,media:media)
            media.virtualSources=pool
            defer {media.pause();media.reconcile(assets:[],baseURL:generated);pool.reset()}
            let view=MTKView(frame:NSRect(x:0,y:0,width:128,height:96),device:device)
            guard let renderer=MetalRenderer(view:view,media:media) else {throw Failure(message:MetalRenderer.lastInitializationError)}
            view.isPaused=true
            func expect(_ condition:@autoclosure()throws->Bool,_ message:@autoclosure()->String)throws {
                guard try condition() else {throw Failure(message:message())}
            }
            func pump(_ timeout:Double,_ condition:()->Bool)->Bool {
                let deadline=ProcessInfo.processInfo.systemUptime+timeout
                repeat {
                    if condition() {return true}
                    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01))
                } while ProcessInfo.processInfo.systemUptime<deadline
                return condition()
            }
            func pixel(_ image:NSBitmapImageRep,_ x:Int=64,_ y:Int=48)->[Int] {
                guard let bytes=image.bitmapData else {return []}
                return (0..<4).map {Int(bytes[y*image.bytesPerRow+x*4+$0])}
            }
            // RGB/YUV conversion and lossy H.264 may shift these saturated
            // palette colors. Distinct palettes are separated by210 levels.
            func near(_ got:[Int],_ wanted:[Int],tolerance:Int=32)->Bool {
                got.count==wanted.count && zip(got,wanted).allSatisfy {abs($0-$1)<=tolerance}
            }
            func frame(_ surfaces:[Surface],outputID:UUID?=nil)throws->NSBitmapImageRep {
                renderer.outputID=outputID;renderer.surfaces=pool.apply(to:surfaces)
                guard let result=renderer.snapshot(width:128,height:96) else {throw Failure(message:"Montage Metal readback: "+renderer.errorDescription)}
                return result
            }
            func surface(_ id:UUID)->Surface {Surface(name:"Generated montage surface",mediaID:id,output:Point2.unitQuad,generator:"checker")}
            let asset=MediaAsset(name:"Time colors",path:movie.path,kind:"video",loop:true,volume:0.37)
            let unused=MediaAsset(name:"Unassigned same file",path:movie.path,kind:"video",volume:0.61)
            let slowAsset=MediaAsset(name:"One FPS",path:low.path,kind:"video")
            let rotationAsset=MediaAsset(name:"Rotate90",path:rotated.path,kind:"video")
            let gapAsset=MediaAsset(name:"Initial empty video interval",path:gapMovie.path,kind:"video")
            let variableAsset=MediaAsset(name:"Variable FPS",path:variableMovie.path,kind:"video")
            let assets=[asset,unused,slowAsset,rotationAsset,gapAsset,variableAsset]
            media.setActiveAssetIDs([asset.id]);media.reconcile(assets:assets,baseURL:generated)
            try expect(pump(12) {assets.allSatisfy {media.duration(for:$0.id)>3.9}},"Generated ordinary video players did not become ready")
            media.seek(to:0.35);media.play()
            try expect(pump(8) {media.playbackTime(for:asset.id)>0.45 && media.texture(for:asset.id) != nil},"Assigned ordinary player did not decode")
            try expect(media.isSourcePlaying(for:asset.id) && !media.isSourceMuted(for:asset.id),"Assigned ordinary source did not play unmuted")
            try expect(!media.isSourcePlaying(for:unused.id) && media.isSourceMuted(for:unused.id),"Unassigned movie escaped production audio activation gate")
            let ordinaryGeneration=media.seekGeneration(for:asset.id),ordinaryTime=media.playbackTime(for:asset.id)
            checks.append("explicit ordinary source activation keeps an unassigned same-file player muted and paused after asynchronous readiness/seek")
            var serial:UInt64=0
            func configure(_ montages:[MediaMontage])throws {try pool.reconcile(montages:montages,assets:assets,baseURL:generated)}
            func update(_ time:Double,_ used:Set<UUID>,playing:Bool=false) {
                pool.update(time:time,playing:playing,used:used,serial:serial,baseURL:generated)
            }
            func settle(_ time:Double,_ targets:[UUID:Double],newSeek:Bool=true,playing:Bool=false)throws {
                if newSeek {serial &+= 1}
                let used=Set(targets.keys)
                let ready=pump(12) {
                    update(time,used,playing:playing)
                    return targets.allSatisfy {id,target in
                        guard let pts=pool.presentationTime(for:id),let end=pool.frameEnd(for:id),
                              let resource=pool.frameResource(for:id) else {return false}
                        return pts<=target+1e-8 && end>target && !resource.buffers.isEmpty
                    }
                }
                try expect(ready,"Paused montage frame does not cover requested target: "+String(describing:pool.diagnostics))
                for (id,target) in targets {
                    observations.append(["target":target,"pts":pool.presentationTime(for:id) ?? -1,"end":pool.frameEnd(for:id) ?? -1])
                }
            }
            let first=MediaMontage(name:"Same file at red",duration:1,clips:[MontageClip(assetID:asset.id,duration:1,sourceOut:1)])
            let second=MediaMontage(name:"Same file at blue",duration:1,clips:[MontageClip(assetID:asset.id,duration:1,sourceIn:2,sourceOut:3)])
            try configure([first,second]);try settle(0.25,[first.id:0.25,second.id:2.25])
            let firstPixel=pixel(try frame([surface(first.id)])),secondPixel=pixel(try frame([surface(second.id)]))
            observations.append(["firstRGBA":firstPixel,"secondRGBA":secondPixel])
            try expect(near(firstPixel,[230,20,20,255]),"First independent montage is not the red source position: RGBA \(firstPixel)")
            try expect(near(secondPixel,[20,20,230,255]),"Second independent montage is not the blue source position: RGBA \(secondPixel)")
            try expect(media.seekGeneration(for:asset.id)==ordinaryGeneration && media.playbackTime(for:asset.id)>=ordinaryTime-0.05,"Montage decoding sought or rewound the assigned ordinary same-file player")
            try expect(abs(Double(media.sourceVolume(for:asset.id) ?? -1)-0.37)<0.0001 &&
                       abs(Double(media.sourceVolume(for:unused.id) ?? -1)-0.61)<0.0001 && !media.isSourceMuted(for:asset.id),"Montage changed ordinary player volume/activation")
            checks += ["two independent montage positions of one H.264 file coexist with an ordinary playing source",
                       "paused montage frames carry true PTS intervals covering the requested source time",
                       "montage decode preserves ordinary player seek generation, playback continuity and activation"]
            media.pause()
            let retained=media.frameResources(for:[first.id,second.id])
            let again=media.frameResources(for:[first.id,second.id])
            try expect(retained.buffers.count==2 && retained.retained.count==2,"Virtual source CVPixelBuffer/CVMetalTexture retention is incomplete")
            try expect(retained.textures[first.id] === again.textures[first.id] && retained.textures[second.id] === again.textures[second.id],"Multiple consumers acquired different accepted montage textures")
            let reference=pixel(try frame([surface(first.id)]))
            let output=pixel(try frame([surface(first.id)],outputID:UUID()))
            try expect(near(output,reference,tolerance:0),"Routed output render differs from editor composition")
            var asyncPixel:[Int]?
            renderer.outputID=nil;renderer.surfaces=pool.apply(to:[surface(first.id)])
            renderer.snapshotAsync(width:128,height:96) {image in if let image {asyncPixel=pixel(image)}}
            try expect(pump(5) {asyncPixel != nil},"Asynchronous lighting readback did not complete")
            try expect(near(asyncPixel ?? [],reference,tolerance:0),"Lighting readback differs from accepted editor/output frame")
            withExtendedLifetime(retained) {}
            checks += ["virtual frame resources retain both pixel buffers and Metal wrappers across repeated consumers",
                       "editor, routed output and asynchronous lighting readback consume the same accepted frame"]

            let black=MediaMontage(name:"Black gap",duration:2,gapMode:.black,clips:[MontageClip(assetID:asset.id,duration:1,sourceOut:1)])
            let skip=MediaMontage(name:"Skip gap",duration:2,gapMode:.skip,clips:[MontageClip(assetID:asset.id,duration:1,sourceOut:1)])
            try configure([black,skip]);serial &+= 1;update(1.5,[black.id,skip.id])
            let under=Surface(name:"Green below gap",output:Point2.unitQuad,color:[0,1,0],generator:"solid")
            try expect(near(pixel(try frame([under,surface(black.id)])),[0,0,0,255],tolerance:1),"Black montage gap exposed checker/underlying layer")
            try expect(near(pixel(try frame([under,surface(skip.id)])),[0,255,0,255],tolerance:1),"Skip montage gap failed to reveal underlying layer")
            try expect(pool.apply(to:[surface(black.id)]).first?.enabled==true && pool.apply(to:[surface(skip.id)]).first?.enabled==false,"Black/Skip surface visibility differs")
            checks += ["Black gap is opaque without procedural fallback","Skip gap excludes the surface and exposes lower composition"]
            let missing=MediaAsset(name:"Missing generated file",path:generated.appendingPathComponent("absent.mov").path,kind:"video")
            let missingBlack=MediaMontage(name:"Missing Black",duration:1,clips:[MontageClip(assetID:missing.id,duration:1,sourceOut:1)])
            let missingSkip=MediaMontage(name:"Missing Skip",duration:1,gapMode:.skip,clips:[MontageClip(assetID:missing.id,duration:1,sourceOut:1)])
            try pool.reconcile(montages:[missingBlack,missingSkip],assets:assets+[missing],baseURL:generated)
            serial &+= 1
            try expect(pump(8) {update(0.2,[missingBlack.id,missingSkip.id]);return pool.diagnostics.values.contains(where:{$0.hasPrefix("Montage video:")})},"Missing clip failed to report decode error")
            try expect(near(pixel(try frame([under,surface(missingBlack.id)])),[0,0,0,255],tolerance:1),"Missing Black clip showed stale/fallback image")
            try expect(near(pixel(try frame([under,surface(missingSkip.id)])),[0,255,0,255],tolerance:1),"Missing Skip clip did not reveal composition")
            checks.append("missing video reports a diagnostic and follows Black/Skip composition policy")

            let cuts=MediaMontage(name:"Hard cut",duration:2,clips:[
                MontageClip(assetID:asset.id,duration:1,sourceOut:1),
                MontageClip(assetID:asset.id,start:1,duration:1,sourceIn:2,sourceOut:3)])
            try configure([cuts]);try settle(0.8,[cuts.id:0.8])
            serial &+= 1;update(1,[cuts.id])
            try expect(pool.frameResource(for:cuts.id)?.buffers.isEmpty==true,"Cut reused a decoded frame from the preceding clip")
            try settle(1,[cuts.id:2],newSeek:false)
            try expect(near(pixel(try frame([surface(cuts.id)])),[20,20,230,255]),"Half-open cut did not display the next clip")
            checks.append("hard cut immediately rejects preceding clip frame and then displays the new clip at its In")
            let fast=MediaMontage(name:"Rate2",duration:1,clips:[MontageClip(assetID:asset.id,duration:1,sourceOut:2,rate:2)])
            let slow=MediaMontage(name:"Rate0.5",duration:2,clips:[MontageClip(assetID:asset.id,duration:2,sourceIn:2,sourceOut:3,rate:0.5)])
            let looping=MediaMontage(name:"Trim loop",duration:3,clips:[MontageClip(assetID:asset.id,duration:3,sourceIn:1,sourceOut:2,loop:true)])
            let repeating=MediaMontage(name:"Montage loop",duration:1,loop:true,clips:[MontageClip(assetID:asset.id,duration:1,sourceIn:2,sourceOut:3)])
            try configure([fast,slow,looping,repeating])
            try settle(0.75,[fast.id:1.5,slow.id:2.375,looping.id:1.75,repeating.id:2.75])
            try expect(near(pixel(try frame([surface(fast.id)])),[20,230,20,255]),"Rate2 target color differs")
            try expect(near(pixel(try frame([surface(slow.id)])),[20,20,230,255]),"Rate0.5 target color differs")
            try settle(1.25,[looping.id:1.25,repeating.id:2.25])
            try expect(pool.samples[looping.id]?.clipCycle==1 && pool.samples[repeating.id]?.montageCycle==1,"Trim/montage loop cycle identity differs")
            checks += ["rate0.5 and rate2 source-time mapping reaches independently decoded correct frames",
                       "trim loop and whole montage loop reset decoder identity and preserve source position"]

            let seekable=MediaMontage(name:"Seek stress",duration:4,clips:[MontageClip(assetID:asset.id,duration:4,sourceOut:4)])
            try configure([seekable])
            for target in [0.0,3.5,0.05,2.25,0.05,0.05] {
                try settle(target,[seekable.id:target])
                let expected=Self.color(second:Int(target))
                try expect(near(pixel(try frame([surface(seekable.id)])),expected),"Repeated/backwards seek displayed an incorrect temporal color")
            }
            for index in 0..<60 {serial &+= 1;update(Double(index%4)+0.2,[seekable.id])}
            try settle(2.25,[seekable.id:2.25])
            try expect(near(pixel(try frame([surface(seekable.id)])),[20,20,230,255]),"Rapid seek results overwrote the final requested frame")
            checks += ["PTS zero, large/backward and repeated identical paused seeks display correct temporal colors",
                       "60 coalesced rapid seeks settle on final generation without a stale result"]
            try settle(0.2,[seekable.id:0.2],playing:true)
            let continuousGeneration=pool.frameGeneration(for:seekable.id)
            for target in [0.35,0.5,0.65,0.8] {
                try settle(target,[seekable.id:target],newSeek:false,playing:true)
                try expect(pool.frameGeneration(for:seekable.id)==continuousGeneration,"Forward playing updates reset the decoder generation each tick")
            }
            checks.append("successive playing updates advance decoded PTS with one stable clip generation")
            try configure([looping,repeating])
            try settle(0.85,[looping.id:1.85,repeating.id:2.85],playing:true)
            let trimGeneration=pool.frameGeneration(for:looping.id),montageGeneration=pool.frameGeneration(for:repeating.id)
            try settle(1.05,[looping.id:1.05,repeating.id:2.05],newSeek:false,playing:true)
            try expect(pool.frameGeneration(for:looping.id) != trimGeneration && pool.frameGeneration(for:repeating.id) != montageGeneration,"Playing loop did not advance trim/montage cycle generations")
            let afterTrim=pool.frameGeneration(for:looping.id),afterMontage=pool.frameGeneration(for:repeating.id)
            try settle(1.15,[looping.id:1.15,repeating.id:2.15],newSeek:false,playing:true)
            try expect(pool.frameGeneration(for:looping.id)==afterTrim && pool.frameGeneration(for:repeating.id)==afterMontage,"Playing loop decoder generation did not stabilize after wrap")
            checks.append("playing trim and montage wraps advance cycle generation once and resume stable forward decoding")
            try configure([fast]);try settle(0.25,[fast.id:0.5])
            guard let lateEnd=pool.frameEnd(for:fast.id) else {throw Failure(message:"Missing frame for late-policy test")}
            let insideTime=(lateEnd+0.22)/2
            update(insideTime,[fast.id],playing:true)
            try expect(pool.frameResource(for:fast.id)?.buffers.isEmpty==false,"Rate2 continuous late frame inside120ms show-time allowance was discarded")
            update(insideTime,[fast.id],playing:false)
            try expect(pool.frameResource(for:fast.id)?.buffers.isEmpty==true,"Paused target accepted a late frame without exact source-time coverage")
            try settle(insideTime,[fast.id:insideTime*2],newSeek:false)
            guard let freshEnd=pool.frameEnd(for:fast.id) else {throw Failure(message:"Missing refreshed late-policy frame")}
            let outsideTime=(freshEnd+0.26)/2
            update(outsideTime,[fast.id],playing:true)
            try expect(pool.frameResource(for:fast.id)?.buffers.isEmpty==true,"Rate2 frame outside120ms show-time allowance remained visible")
            try settle(outsideTime,[fast.id:outsideTime*2],newSeek:false)
            checks.append("rate2 playing lag permits110ms show time, rejects130ms, and paused targets always require exact coverage")
            try configure([seekable])
            serial &+= 1;update(3.2,[seekable.id]);pool.reset()
            try expect(pool.activeVideoDecoderCount==0 && pool.frameResource(for:seekable.id)==nil,"Reset retained a virtual source or decoder owner")
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.1))
            try configure([first]);try settle(0.25,[first.id:0.25])
            try expect(pool.frameResource(for:seekable.id)==nil && near(pixel(try frame([surface(first.id)])),[230,20,20,255]),"Retired document result contaminated new source")
            checks.append("reset releases owners and rejects old in-flight document results")

            let slowMontage=MediaMontage(name:"Low FPS predecessor",duration:4,clips:[MontageClip(assetID:slowAsset.id,duration:4,sourceOut:4)])
            try configure([slowMontage]);try settle(1.5,[slowMontage.id:1.5])
            try expect(abs((pool.presentationTime(for:slowMontage.id) ?? -1)-1)<0.001,"One-fps seek chose future frame instead of covering predecessor")
            try expect(near(pixel(try frame([surface(slowMontage.id)])),[20,230,20,255]),"One-fps covering frame color differs")
            checks.append("one-fps non-frame-aligned paused target selects covering preceding frame")
            let leading=MediaMontage(name:"Leading video gap",duration:4,clips:[MontageClip(assetID:gapAsset.id,duration:4,sourceOut:4)])
            try configure([leading]);try settle(0.5,[leading.id:0.5])
            // AVAssetWriter/Reader represents this empty edit by a real black
            // sample at PTS0; that sample is valid coverage, not a decode error.
            try expect(near(pixel(try frame([under,surface(leading.id)])),[0,0,0,255],tolerance:1),"Leading video empty edit exposed an early future image")
            try settle(1.25,[leading.id:1.25])
            try expect(near(pixel(try frame([surface(leading.id)])),[230,20,20,255]),"Video first-frame timestamp was incorrectly rebased to zero")
            checks.append("generated initial empty edit stays black and preserves later source PTS without rebasing")
            let variable=MediaMontage(name:"VFR predecessor",duration:4,clips:[MontageClip(assetID:variableAsset.id,duration:4,sourceOut:4)])
            try configure([variable]);try settle(1.5,[variable.id:1.5])
            try expect(abs((pool.frameEnd(for:variable.id) ?? -1)-2.5)<0.001 && near(pixel(try frame([surface(variable.id)])),[20,230,20,255]),"VFR target failed to preserve the covering sample and interval end")
            try settle(3.2,[variable.id:3.2])
            try expect(abs((pool.presentationTime(for:variable.id) ?? -1)-2.5)<0.001 && near(pixel(try frame([surface(variable.id)])),[20,20,230,255]),"VFR later target used a nominal FPS instead of sample PTS")
            checks.append("variable sample intervals preserve coverage and temporal colors without assuming nominal FPS")
            let beyond=MediaMontage(name:"Out exceeds actual video",duration:5,clips:[MontageClip(assetID:asset.id,duration:5,sourceOut:5)])
            try configure([beyond]);serial &+= 1
            let outRejected=pump(8) {update(0.2,[beyond.id]);return pool.diagnostics[beyond.id]?.contains("Source Out exceeds actual video extent")==true}
            try expect(outRejected && pool.frameResource(for:beyond.id)?.buffers.isEmpty==true && near(pixel(try frame([under,surface(beyond.id)])),[0,0,0,255],tolerance:1),"Out beyond actual video extent did not diagnose and show explicit black")
            checks.append("runtime rejects Source Out beyond actual video-track extent with diagnostic and explicit gap")
            let portrait=MediaMontage(name:"Rotation90",duration:1,clips:[MontageClip(assetID:rotationAsset.id,duration:1,sourceOut:1)])
            try configure([portrait]);try settle(0.25,[portrait.id:0.25])
            let upright=try frame([surface(portrait.id)])
            for (x,y,wanted) in [(32,24,[20,20,230,255]),(96,24,[230,20,20,255]),(32,72,[230,230,20,255]),(96,72,[20,230,20,255])] {
                try expect(near(pixel(upright,x,y),wanted),"Rotation90 metadata did not map encoded quadrant into upright composition")
            }
            checks.append("90-degree preferredTransform rotates all four encoded video quadrants in production shader")
            let rotationGeneration=media.seekGeneration(for:rotationAsset.id)
            try expect(pump(8) {media.texture(for:rotationAsset.id) != nil},"Ordinary rotated movie did not decode its paused zero frame")
            let ordinaryRotated=try frame([surface(rotationAsset.id)])
            for (x,y) in [(32,24),(96,24),(32,72),(96,72)] {
                try expect(near(pixel(ordinaryRotated,x,y),pixel(upright,x,y),tolerance:5),"Ordinary and montage video rotation disagree at quadrant \(x),\(y)")
            }
            try expect(media.seekGeneration(for:rotationAsset.id)==rotationGeneration,"Rotation readback sought the ordinary movie")
            checks.append("ordinary AVPlayer and independent montage paths display identical upright rotation quadrants")

            try configure([first]);try settle(0.25,[first.id:0.25])
            let replacement=generated.appendingPathComponent("replacement.mov")
            try makeMovie(at:replacement,fps:30,phase:1)
            try FileManager.default.removeItem(at:movie)
            try FileManager.default.moveItem(at:replacement,to:movie)
            let beforeInvalidation=pool.frameGeneration(for:first.id)
            pool.invalidateAsset(asset.id)
            try settle(0.25,[first.id:0.25])
            try expect(pool.frameGeneration(for:first.id) != beforeInvalidation,"Same-path invalidation failed to advance decoder generation")
            try expect(near(pixel(try frame([surface(first.id)])),[20,230,20,255]),"Same-path restored/replaced movie retained old bytes")
            try expect(media.seekGeneration(for:asset.id)==ordinaryGeneration,"Explicit montage relink invalidation sought the ordinary player")
            checks.append("explicit same-path asset invalidation decodes replacement bytes without ordinary-player seeks")
            let many=(0..<9).map {index in MediaMontage(name:"Bounded \(index)",duration:1,clips:[MontageClip(assetID:asset.id,duration:1,sourceOut:1)])}
            try configure(many);serial &+= 1;update(0.25,Set(many.map(\.id)))
            let initialGenerations=Dictionary(uniqueKeysWithValues:many.map {($0.id,pool.frameGeneration(for:$0.id) ?? 0)})
            let admitted=many.sorted {$0.id.uuidString<$1.id.uuidString}.prefix(8),excluded=many.sorted {$0.id.uuidString<$1.id.uuidString}.last!
            let eightReady=pump(12) {update(0.25,Set(many.map(\.id)));return admitted.allSatisfy {pool.frameResource(for:$0.id)?.buffers.isEmpty==false}}
            report["decoderBoundObservations"]=many.map {m in ["name":m.name,"diagnostic":pool.diagnostics[m.id] ?? "","pts":pool.presentationTime(for:m.id) ?? -1,
                "initialGeneration":initialGenerations[m.id] ?? 0,"finalGeneration":pool.frameGeneration(for:m.id) ?? 0,"hasFrame":pool.frameResource(for:m.id)?.buffers.isEmpty==false] as [String:Any]}
            try expect(eightReady,"Eight admitted decoder slots failed to produce frames: "+String(describing:pool.diagnostics))
            try expect(pool.decoderSlotCount==8 && pool.activeVideoDecoderCount==8,"Montage decoder slot bound differs from eight")
            try expect(pool.diagnostics[excluded.id]?.contains("limit (8)")==true && pool.frameResource(for:excluded.id)?.buffers.isEmpty==true,"Ninth video source failed bounded diagnostic/fallback")
            update(0.25,[])
            try expect(pool.activeVideoDecoderCount==0 && pool.decoderSlotCount==8,"Unassigned sources retained active decoder leases")
            checks.append("eight fixed decoder slots admit deterministic sources, diagnose the ninth and release inactive owners")
            report["result"]="passed"
            report["fixtureDirectory"]=generated.lastPathComponent
        } catch {report["result"]="failed";report["error"]=error.localizedDescription}
        report["checks"]=checks;report["passedCheckCount"]=checks.count;report["pausedFrameObservations"]=observations
        do {
            let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:directory.appendingPathComponent("montage-test.json"),options:.atomic)
            if let text=String(data:data,encoding:.utf8) {print(text)}
        } catch {print("Montage report write failed: \(error.localizedDescription)");return 1}
        return report["result"] as? String == "passed" ? 0 : 1
    }

    private static func color(second:Int)->[Int] {
        [[230,20,20,255],[20,230,20,255],[20,20,230,255],[230,230,20,255]][((second%4)+4)%4]
    }
    private static func makeMovie(at url:URL,fps:Int,phase:Int=0,quadrants:Bool=false,rotate:Bool=false,leadingGap:Double=0,presentationTimes:[Double]?=nil)throws {
        let width=160,height=96
        let writer=try AVAssetWriter(outputURL:url,fileType:.mov)
        let colorProperties:[String:Any]=[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2]
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoColorPropertiesKey:colorProperties,
            AVVideoCompressionPropertiesKey:[AVVideoMaxKeyFrameIntervalKey:max(1,fps),AVVideoAllowFrameReorderingKey:false]])
        if rotate {input.transform=CGAffineTransform(a:0,b:1,c:-1,d:0,tx:CGFloat(height),ty:0)}
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height])
        guard writer.canAdd(input) else {throw Failure(message:"Cannot add generated H.264 writer input")}
        writer.add(input)
        guard writer.startWriting() else {throw writer.error ?? Failure(message:"Generated H.264 writer failed to start")}
        writer.startSession(atSourceTime:.zero)
        let deadline=ProcessInfo.processInfo.systemUptime+30
        for index in 0..<(presentationTimes?.count ?? Int(Double(fps)*(4-leadingGap))) {
            while !input.isReadyForMoreMediaData {
                guard ProcessInfo.processInfo.systemUptime<deadline,writer.status == .writing else {throw writer.error ?? Failure(message:"Generated H.264 append timeout")}
                Thread.sleep(forTimeInterval:0.002)
            }
            var optional:CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32BGRA,nil,&optional)
            guard let buffer=optional else {throw Failure(message:"Generated video buffer allocation failed")}
            CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
            CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
            CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
            CVPixelBufferLockBaseAddress(buffer,[])
            guard let base=CVPixelBufferGetBaseAddress(buffer) else {throw Failure(message:"Generated video buffer has no data")}
            let bytes=base.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {for x in 0..<width {
                let rgb=color(second:quadrants ? (y<height/2 ? (x<width/2 ? 0:1):(x<width/2 ? 2:3)):(presentationTimes == nil ? index/fps:index)+phase)
                let offset=y*stride+x*4
                bytes[offset]=UInt8(rgb[2]);bytes[offset+1]=UInt8(rgb[1]);bytes[offset+2]=UInt8(rgb[0]);bytes[offset+3]=255
            }}
            CVPixelBufferUnlockBaseAddress(buffer,[])
            guard adaptor.append(buffer,withPresentationTime:CMTime(seconds:presentationTimes?[index] ?? (leadingGap+Double(index)/Double(fps)),preferredTimescale:600)) else {throw writer.error ?? Failure(message:"Generated H.264 append failed")}
        }
        writer.endSession(atSourceTime:CMTime(seconds:4,preferredTimescale:600))
        input.markAsFinished()
        let semaphore=DispatchSemaphore(value:0)
        writer.finishWriting {semaphore.signal()}
        guard semaphore.wait(timeout:.now()+30) == .success,writer.status == .completed else {throw writer.error ?? Failure(message:"Generated H.264 completion failed")}
    }
}
#endif
