#if os(macOS)
import Foundation
import AVFoundation
import QuartzCore
import MappingCore

/// Silent local integration: production AVAssetReader -> matrix -> bounded
/// AVAudioPlayerNode/Varispeed graph in AVAudioEngine manual offline mode.
/// It does not select/start a hardware output and cannot certify audible output.
@MainActor enum MediaAudioSelfTest {
    static func run()->Int32 {
        let started=CACurrentMediaTime()
        let directory=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/local/audio-test",isDirectory:true)
        var checks:[String]=[],details:[String:Any]=[:]
        var instances:[MediaAudioPlayer]=[]
        defer {instances.forEach {$0.invalidate()}}
        func expect(_ result:Bool,_ message:String)throws {if !result {throw MediaAudioFailure(message:message)}}
        func pump(_ seconds:Double,_ condition:()->Bool)->Bool {
            let end=CACurrentMediaTime()+seconds
            repeat {if condition() {return true};RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005))} while CACurrentMediaTime()<end
            return condition()
        }
        func pass(_ name:String) {checks.append(name);print("PASS audio: "+name)}
        func save(_ success:Bool,_ failure:String?=nil) {
            var report:[String:Any]=["schemaVersion":1,"timestampUTC":ISO8601DateFormatter().string(from:Date()),"platform":ProcessInfo.processInfo.operatingSystemVersionString,"passed":success,"checks":checks,"checkCount":checks.count,"elapsedSeconds":CACurrentMediaTime()-started,"hardwareVerification":false,"hardwareAudioStarted":false,"scope":"Production AVFoundation PCM extraction, per-source matrix and bounded AVAudioEngine graph in silent manual offline mode; original Float32 WAV/MOV fixtures","details":details,"limitations":"No audible output, physical device routing/hotplug, speaker calibration, optical AV sync or long-show drift claim. Offline sample-clock drift is reported separately from physical output latency; reverse audio is deliberately silent." ]
            if let failure {report["failure"]=failure}
            do {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("report.json"),options:.atomic)} catch {fputs("Audio report write failed: \(error)\n",stderr)}
        }
        func prepare(_ url:URL,_ route:AudioRoutingSettings?)throws->MediaAudioPlayer {
            let player=MediaAudioPlayer(offline:true);instances.append(player)
            var result:Result<Void,Error>?
            player.prepare(url:url,routing:route) {result=$0}
            try expect(pump(20,{result != nil}),"Audio preparation timed out")
            try result!.get()
            try expect(player.ready,"Prepared audio adapter is not ready")
            return player
        }
        func waitForChunks(_ player:MediaAudioPlayer,_ minimum:Int)throws {
            try expect(pump(15,{player.metrics.decodedChunks>=minimum || player.diagnostic != nil}),"Audio PCM prefetch timed out")
            try expect(player.diagnostic==nil,"Audio prefetch diagnostic: "+(player.diagnostic ?? ""))
        }
        func mean(_ buffer:AVAudioPCMBuffer,_ channel:Int,skip:Int=256)->Double {
            guard let values=buffer.floatChannelData else {return .nan}
            let start=min(skip,Int(buffer.frameLength)-1),count=Int(buffer.frameLength)-start
            return (start..<Int(buffer.frameLength)).reduce(0.0) {$0+Double(values[channel][$1])}/Double(count)
        }
        do {
            try expect(MediaAudioPlayer.deviceIDCount(byteCount:0)==0,"Empty CoreAudio device catalog must be representable")
            try expect(MediaAudioPlayer.deviceIDCount(byteCount:1)==nil,"Misaligned CoreAudio catalog size must reject")
            try expect(MediaAudioPlayer.deviceIDCount(byteCount:4)==1 && MediaAudioPlayer.deviceIDCount(byteCount:16384)==4096 && MediaAudioPlayer.deviceIDCount(byteCount:16388)==nil,"CoreAudio device catalog count exceeded its bounded allocation policy")
            pass("empty, malformed and excessive CoreAudio device catalog sizes are handled without borrowing an empty array pointer or changing hardware")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let fixture=directory.appendingPathComponent("fixture-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:false)
            let wav=fixture.appendingPathComponent("original-stereo.wav")
            try writeWave(to:wav,sampleRate:48000,seconds:4)
            var ownership:Result<[String:Any],Error>?
            MediaAudioCancellationFixture.run(url:wav) {ownership=$0}
            try expect(pump(15,{ownership != nil}),"Audio cancellation ownership fixture timed out")
            let ownershipResult=try ownership!.get()
            try expect(ownershipResult["mainProbeRan"] as? Bool == true && ownershipResult["gateEnteredOnWorker"] as? Bool == true && ownershipResult["readerCancellationCount"] as? Int == 1 && ownershipResult["readerCancelledOnMain"] as? Bool == false && ownershipResult["packetsCopiedAfterInvalidation"] as? Int == 0 && ownershipResult["readReturnedCancelled"] as? Bool == true,"Reader cancellation crossed queue ownership or copied stale packets")
            details["readerCancellationOwnership"]=ownershipResult
            pass("main cancellation only invalidates a serial while actual reader cancellation remains on the worker before any stale packet copy")
            let route=AudioRoutingSettings(inputChannels:2,outputChannels:4,gains:[0,1,1,0,0.5,0.5,4,-4])
            let player=try prepare(wav,route)
            player.update(positionSeconds:0,playing:true,rate:1,generation:1)
            try waitForChunks(player,2)
            let rendered=try player.renderOffline(4096)
            let expected=[-0.4,0.2,-0.1,1.0]
            let actual=(0..<4).map {mean(rendered,$0)}
            try expect(zip(actual,expected).allSatisfy({abs($0-$1)<0.002}),"Real engine matrix channel output did not match independent PCM oracle: \(actual)")
            details["matrixConstantChannels"]=actual
            pass("original stereo Float32 WAV decodes through the real four-channel engine matrix with signed gains and one clamp")

            player.update(positionSeconds:player.playbackPosition,playing:true,rate:1,generation:1,volume:0.5)
            _=try player.renderOffline(4096)
            let halfVolume=try player.renderOffline(4096)
            try expect(abs(mean(halfVolume,3)-0.5)<0.002,"Master volume must apply after matrix clipping")
            player.update(positionSeconds:player.playbackPosition,playing:true,rate:1,generation:1,volume:1)
            _=try player.renderOffline(4096)
            pass("post-matrix master fader scales the clipped output after its bounded render-quantum gain ramp")

            let beforePause=player.playbackPosition
            player.update(positionSeconds:beforePause,playing:false,rate:1,generation:1)
            let paused=try player.renderOffline(4096)
            try expect((0..<4).allSatisfy({abs(mean(paused,$0,skip:1024))<0.00001}),"Paused engine retained non-silent source samples")
            try expect(abs(player.playbackPosition-beforePause)<1.0/48000,"Pause advanced the source sample clock")
            pass("Pause is silent and retains the per-source sample position")

            let priorChunks=player.metrics.decodedChunks
            player.update(positionSeconds:0.625,playing:true,rate:1,generation:2)
            try waitForChunks(player,priorChunks+2)
            let sought=try player.renderOffline(4096)
            let soughtMean=(0..<4).map {mean(sought,$0)}
            let soughtExpected=[0.1,-0.3,-0.1,-1.0]
            try expect(zip(soughtMean,soughtExpected).allSatisfy({abs($0-$1)<0.002}),"Seek exposed previous-generation PCM or failed source position: \(soughtMean)")
            pass("generation-tagged seek flushes old PCM and clips after the complete matrix sum")

            let rapidChunks=player.metrics.decodedChunks
            player.update(positionSeconds:0.1,playing:true,rate:1,generation:3)
            player.update(positionSeconds:1.2,playing:true,rate:1,generation:4)
            player.update(positionSeconds:0.625,playing:true,rate:1,generation:5)
            try waitForChunks(player,rapidChunks+2)
            let rapid=try player.renderOffline(4096)
            try expect(abs(mean(rapid,0)-0.1)<0.002 && abs(mean(rapid,1)+0.3)<0.002,"Rapid audio seeks installed stale decoder completions")
            try expect(player.metrics.maximumQueuedBuffers<=2,"Audio PCM scheduled beyond the two-buffer admission bound")
            details["rapidSeekDiscardedCompletions"]=player.metrics.discardedCompletions
            pass("rapid successive seeks cancel stale extraction completions and retain at most two queued PCM chunks")

            player.update(positionSeconds:player.playbackPosition,playing:true,rate:1,generation:5,volume:0)
            // AVAudioMixer ramps a gain change over its next render quantum.
            // Settle that quantum; the following block must be exactly silent.
            _=try player.renderOffline(4096)
            let muted=try player.renderOffline(4096)
            try expect((0..<4).allSatisfy({abs(mean(muted,$0,skip:1024))<0.00001}),"Source volume zero was not silent")
            player.update(positionSeconds:player.playbackPosition,playing:true,rate:-1,generation:5)
            try expect(player.diagnostic?.contains("Reverse") == true,"Unsupported reverse audio did not report its explicit silent state")
            let reverse=try player.renderOffline(4096)
            try expect((0..<4).allSatisfy({abs(mean(reverse,$0,skip:1024))<0.00001}),"Reverse audio emitted stale forward samples")
            pass("per-source zero volume and unsupported reverse direction are silent with an explicit reverse diagnostic")
            player.invalidate()

            let resampledURL=fixture.appendingPathComponent("original-44100.wav")
            try writeWave(to:resampledURL,sampleRate:44100,seconds:4)
            let resampled=try prepare(resampledURL,.identity(inputChannels:2,outputChannels:2))
            resampled.update(positionSeconds:0.625,playing:true,rate:1,generation:1)
            try waitForChunks(resampled,2)
            let converted=try resampled.renderOffline(4096)
            try expect(abs(mean(converted,0)+0.3)<0.002 && abs(mean(converted,1)-0.1)<0.002,"44.1 kHz file did not resample/seek correctly to 48 kHz")
            pass("AVFoundation resamples original 44.1 kHz PCM to the 48 kHz graph without changing the seek region")
            resampled.invalidate()

            let clock=try prepare(wav,.identity(inputChannels:2,outputChannels:2))
            clock.update(positionSeconds:0,playing:true,rate:1,generation:1)
            try waitForChunks(clock,2)
            let initial=clock.playbackPosition
            var frames=0
            for _ in 0..<32 {
                let decoded=clock.metrics.decodedChunks
                _=try clock.renderOffline(2048);frames+=2048
                _=pump(0.01,{false})
                if clock.queuedBufferCount<2 {try waitForChunks(clock,decoded+1)}
            }
            let elapsed=clock.playbackPosition-initial,error=abs(elapsed-Double(frames)/48000)
            details["offlineSampleClock"]=["renderedFrames":frames,"outputSampleRate":48000,"seconds":elapsed,"absoluteErrorSeconds":error,"physicalClock":false]
            try expect(error<0.002,"Offline per-source sample clock accumulated drift: \(error)")
            let beforeRate=clock.playbackPosition
            clock.update(positionSeconds:beforeRate,playing:true,rate:2,generation:1)
            for _ in 0..<4 {_=try clock.renderOffline(2048);_=pump(0.01,{false})}
            let rateDelta=clock.playbackPosition-beforeRate
            details["doubleRateSourceDeltaSeconds"]=rateDelta
            try expect(abs(rateDelta-Double(8192*2)/48000)<0.04,"Positive playback rate did not advance the source sample clock twice as fast")
            pass("real engine offline sample-clock drift is bounded independently of hardware latency and positive double-rate playback advances source time")
            clock.invalidate()

            let mov=fixture.appendingPathComponent("original-audio.mov")
            let audioAsset=AVURLAsset(url:wav)
            guard let exporter=AVAssetExportSession(asset:audioAsset,presetName:AVAssetExportPresetPassthrough) else {throw MediaAudioFailure(message:"Original MOV audio fixture exporter unavailable")}
            exporter.outputURL=mov;exporter.outputFileType = .mov
            var exported=false;exporter.exportAsynchronously {DispatchQueue.main.async {exported=true}}
            try expect(pump(20,{exported}),"MOV audio fixture export timed out")
            try expect(exporter.status == .completed,"Original MOV audio fixture failed: \(String(describing:exporter.error))")
            let movie=try prepare(mov,.identity(inputChannels:2,outputChannels:2))
            movie.update(positionSeconds:0.625,playing:true,rate:1,generation:1)
            try waitForChunks(movie,2)
            let extracted=try movie.renderOffline(4096)
            try expect(abs(mean(extracted,0)+0.3)<0.002 && abs(mean(extracted,1)-0.1)<0.002,"MOV first audio track PCM extraction differs from WAV oracle")
            pass("original MOV first audio track is decoded and seeked through the same production PCM route")
            movie.invalidate()
            let trimmed=try prepare(wav,.identity(inputChannels:2,outputChannels:2))
            trimmed.update(positionSeconds:0.25,playing:true,rate:1,generation:1,endSeconds:0.3)
            try expect(pump(10,{trimmed.metrics.decodedChunks>=1}),"Trimmed PCM did not decode")
            var trimPeakAfterEnd=0.0
            for block in 0..<3 {
                let b=try trimmed.renderOffline(4096)
                if block==2 {trimPeakAfterEnd=abs(mean(b,0,skip:0))}
                _=pump(0.01,{false})
            }
            try expect(trimmed.metrics.scheduledFrames==2400 && trimPeakAfterEnd<0.00001,"Audio queued PCM beyond explicit source trim Out")
            trimmed.invalidate()
            details["trimmedScheduledFrames"]=2400
            pass("explicit source trim Out bounds PCM scheduling before the controller's next tick")

            let eofURL=fixture.appendingPathComponent("original-short.wav")
            try writeWave(to:eofURL,sampleRate:48000,seconds:0.25)
            let finite=try prepare(eofURL,.identity(inputChannels:2,outputChannels:2))
            finite.update(positionSeconds:0,playing:true,rate:1,generation:1)
            try waitForChunks(finite,1)
            for _ in 0..<4 {_=try finite.renderOffline(4096);_=pump(0.01,{false})}
            try expect(abs(finite.playbackPosition-0.25)<=1.0/48000 && finite.queuedBufferCount==0,"Finite audio clock exceeded duration after EOF")
            let eofChunks=finite.metrics.decodedChunks
            finite.update(positionSeconds:0.0625,playing:true,rate:1,generation:2)
            try waitForChunks(finite,eofChunks+1)
            let replay=try finite.renderOffline(4096)
            try expect(abs(mean(replay,0)-0.2)<0.002 && finite.playbackPosition>=0.0625 && finite.playbackPosition<=0.25,"Seek after natural EOF did not resume correct PCM/source clock")
            finite.invalidate()
            pass("natural EOF caps the reported source clock at duration and a new-generation seek resumes the correct PCM")

            let fractional=try prepare(wav,.identity(inputChannels:2,outputChannels:2))
            fractional.update(positionSeconds:0.1,playing:true,rate:1,generation:1,endSeconds:0.200001)
            try waitForChunks(fractional,1)
            for _ in 0..<3 {_=try fractional.renderOffline(4096);_=pump(0.01,{false})}
            try expect(fractional.metrics.scheduledFrames==4801 && abs(fractional.playbackPosition-0.200001)<=1.0/48000,"Fractional trim Out did not preserve half-open sample PTS or cap the reported clock")
            fractional.update(positionSeconds:fractional.playbackPosition,playing:false,rate:1,generation:1,endSeconds:0.200001)
            try expect(fractional.playbackPosition<=0.200001,"Paused held position exceeded fractional trim Out")
            fractional.invalidate()
            details["fractionalTrimScheduledFrames"]=4801
            pass("fractional trim Out admits only samples with PTS before Out and bounds both playing and paused reported positions")

            try expect(pump(5,{MediaAudioPlayer.admittedSourceCount==0}),"Retired audio sources retained admission after completed callbacks")
            var admitted:[MediaAudioPlayer]=[]
            for _ in 0..<8 {admitted.append(try prepare(wav,.identity(inputChannels:2,outputChannels:2)))}
            let excess=MediaAudioPlayer(offline:true);instances.append(excess)
            var excessResult:Result<Void,Error>?
            excess.prepare(url:wav,routing:.identity(inputChannels:2,outputChannels:2)) {excessResult=$0}
            try expect(pump(5,{excessResult != nil}),"Ninth audio source admission did not finish")
            let admissionFailure:Bool
            if case .failure(let error)?=excessResult {admissionFailure=(error as? MediaAudioFailure)?.isAdmissionLimit == true} else {admissionFailure=false}
            try expect(admissionFailure && !excess.ready && excess.diagnostic?.contains("eight") == true && MediaAudioPlayer.admittedSourceCount==8,"Ninth source bypassed the global eight-adapter admission bound")
            admitted.forEach {$0.invalidate()};excess.invalidate()
            try expect(pump(5,{MediaAudioPlayer.admittedSourceCount==0}),"Stopped audio sources did not release all admission leases")
            let resumed=try prepare(wav,.identity(inputChannels:2,outputChannels:2));resumed.invalidate()
            pass("global eight-source admission rejects a ninth without hardware playback, retains leases through asynchronous work and permits reuse after cancellation")

            save(true);print("PASS audio integration: \(checks.count) checks. \(directory.appendingPathComponent("report.json").path)");return 0
        } catch {save(false,error.localizedDescription);fputs("AUDIO TEST FAILED: \(error.localizedDescription)\n",stderr);return 1}
    }
    static func writeWave(to url:URL,sampleRate:Int,seconds:Double)throws {
        let frames=Int((Double(sampleRate)*seconds).rounded()),channels=2,bytes=frames*channels*4
        var data=Data()
        func ascii(_ value:String) {data.append(contentsOf:value.utf8)}
        func u16(_ value:UInt16) {var v=value.littleEndian;withUnsafeBytes(of:&v) {data.append(contentsOf:$0)}}
        func u32(_ value:UInt32) {var v=value.littleEndian;withUnsafeBytes(of:&v) {data.append(contentsOf:$0)}}
        ascii("RIFF");u32(UInt32(36+bytes));ascii("WAVEfmt ");u32(16);u16(3);u16(UInt16(channels));u32(UInt32(sampleRate));u32(UInt32(sampleRate*channels*4));u16(UInt16(channels*4));u16(32);ascii("data");u32(UInt32(bytes))
        for frame in 0..<frames {
            let time=Double(frame)/Double(sampleRate)
            let values:[Float]=time<0.5 ? [0.2,-0.4] : time<1 ? [-0.3,0.1] : [Float(0.25*sin(2*Double.pi*440*time)),Float(0.2*cos(2*Double.pi*220*time))]
            for value in values {u32(value.bitPattern)}
        }
        try data.write(to:url,options:.atomic)
    }
}
#endif
