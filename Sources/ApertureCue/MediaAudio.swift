#if os(macOS)
import Foundation
import AVFoundation
import CoreAudio
import MappingCore

struct MediaAudioDevice:Equatable {
    let id:AudioDeviceID
    let uid:String
    let name:String
    let outputChannels:Int
    let isDefault:Bool
}

private final class MediaAudioAdmission:@unchecked Sendable {
    static let shared=MediaAudioAdmission()
    private let lock=NSLock()
    private var count=0
    final class Lease:@unchecked Sendable {
        private let owner:MediaAudioAdmission
        init(_ owner:MediaAudioAdmission) {self.owner=owner}
        deinit {owner.lock.lock();owner.count-=1;owner.lock.unlock()}
    }
    func reserve()->Lease? {
        lock.lock();defer {lock.unlock()}
        guard count<8 else {return nil};count+=1;return Lease(self)
    }
    var used:Int {lock.lock();defer {lock.unlock()};return count}
}

struct MediaAudioFailure:LocalizedError {
    let message:String
    var isAdmissionLimit:Bool=false
    var errorDescription:String? {message}
}

/// One file-backed source and one explicit output route. Decoder work is serial;
/// the engine receives at most two 1/4-second PCM buffers. It never decodes or
/// reads files on the audio render callback. AVPlayer remains the default audio
/// path when a project's optional audioRouting is nil.
final class MediaAudioPlayer {
    static let sampleRate=48000.0
    static let chunkFrames=12000
    static let maximumChannels=8
    static var admittedSourceCount:Int {MediaAudioAdmission.shared.used}
    let offline:Bool
    private let engine=AVAudioEngine()
    private let player=AVAudioPlayerNode()
    private let speed=AVAudioUnitVarispeed()
    private let worker=DispatchQueue(label:"org.aperturecue.audio-pcm",qos:.userInitiated)
    private var decoder:MediaAudioDecoder?
    private var admission:MediaAudioAdmission.Lease?
    private var preparationTask:Task<Void,Never>?
    private var route:AudioRoutingSettings?
    var preparedRouting:AudioRoutingSettings? {route}
    private(set) var hasAudioTrack:Bool?
    private var format:AVAudioFormat?
    private var epoch:UInt64=0
    private var transportGeneration:UInt64?
    private var requestedPlaying=false
    private var basePosition=0.0
    private var heldPosition=0.0
    private var playerClockOffset=0.0
    private var nextPosition=0.0
    private var lastPosition=0.0
    private var queued=0
    private var decodeInFlight=false
    private var ended=false
    private var endLimit=0.0
    private var configurationObserver:NSObjectProtocol?
    private var configurationGeneration:UInt64=0
    private var activeDeviceUID:String?
    private var lastDeviceCheck=0.0
    private(set) var ready=false
    private(set) var diagnostic:String?
    private(set) var duration=0.0
    private(set) var metrics=Metrics()
    struct Metrics {
        var seekCount=0
        var scheduledFrames:Int64=0
        var decodedChunks=0
        var discardedCompletions=0
        var maximumQueuedBuffers=0
        var unsupportedDirectionCount=0
    }
    var queuedBufferCount:Int {queued}
    private var renderedPlayerTime:AVAudioTime? {
        guard let rendered=player.lastRenderTime,rendered.isSampleTimeValid || rendered.isHostTimeValid else {return nil}
        return player.playerTime(forNodeTime:rendered)
    }
    private func boundedPosition(_ value:Double)->Double {max(0,min(duration,endLimit,value))}
    var playbackPosition:Double {
        guard requestedPlaying else {return boundedPosition(heldPosition)}
        if let time=renderedPlayerTime,time.sampleRate>0 {
            let value=basePosition+max(0,Double(time.sampleTime)-playerClockOffset)/time.sampleRate
            return value.isFinite ? boundedPosition(max(basePosition,value)) : boundedPosition(basePosition)
        }
        return boundedPosition(basePosition)
    }
    init(offline:Bool=false) {self.offline=offline}
    deinit {
        if let configurationObserver {NotificationCenter.default.removeObserver(configurationObserver)}
        engine.stop()
    }
    /// CoreAudio can report an empty catalog during restart/headless operation.
    /// Validate byte counts before allocating or borrowing an array base pointer.
    static func deviceIDCount(byteCount:UInt32)->Int? {
        let stride=MemoryLayout<AudioDeviceID>.stride
        guard Int(byteCount)%stride==0 else {return nil}
        let count=Int(byteCount)/stride
        return count<=4096 ? count : nil
    }
    static func availableDevices()->[MediaAudioDevice] {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var size:UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size)==noErr else {return []}
        guard let count=deviceIDCount(byteCount:size),count>0 else {return []}
        var ids=Array(repeating:AudioDeviceID(0),count:count)
        let status=ids.withUnsafeMutableBytes {storage -> OSStatus in
            guard let pointer=storage.baseAddress else {return kAudioHardwareBadPropertySizeError}
            return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,pointer)
        }
        guard status==noErr,let returnedCount=deviceIDCount(byteCount:size),returnedCount>0,returnedCount<=ids.count else {return []}
        ids=Array(ids.prefix(returnedCount))
        address.mSelector=kAudioHardwarePropertyDefaultOutputDevice;size=UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultID=AudioDeviceID(0)
        _=AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&defaultID)
        func string(_ id:AudioDeviceID,_ selector:AudioObjectPropertySelector)->String? {
            var property=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var value:Unmanaged<CFString>?,bytes=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id,&property,0,nil,&bytes,&value)==noErr else {return nil}
            return value?.takeRetainedValue() as String?
        }
        return ids.compactMap {id in
            var property=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreamConfiguration,mScope:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
            var bytes:UInt32=0
            guard AudioObjectGetPropertyDataSize(id,&property,0,nil,&bytes)==noErr,bytes>=MemoryLayout<AudioBufferList>.size else {return nil}
            let storage=UnsafeMutableRawPointer.allocate(byteCount:Int(bytes),alignment:MemoryLayout<AudioBufferList>.alignment)
            defer {storage.deallocate()}
            guard AudioObjectGetPropertyData(id,&property,0,nil,&bytes,storage)==noErr else {return nil}
            let buffers=UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to:AudioBufferList.self))
            let channels=buffers.reduce(0) {$0+Int($1.mNumberChannels)}
            guard channels>0,let uid=string(id,kAudioDevicePropertyDeviceUID),let name=string(id,kAudioObjectPropertyName) else {return nil}
            return MediaAudioDevice(id:id,uid:uid,name:name,outputChannels:channels,isDefault:id==defaultID)
        }
    }
    func prepare(url:URL,routing requestedRouting:AudioRoutingSettings?,completion:@escaping(Result<Void,Error>)->Void) {
        precondition(Thread.isMainThread)
        invalidate()
        let token=epoch
        do {
            if let routing=requestedRouting {
                try routing.validate()
                guard routing.enabled,routing.inputChannels<=Self.maximumChannels,routing.outputChannels<=Self.maximumChannels else {throw MediaAudioFailure(message:"Audio route supports 1…8 input/output channels and must be enabled")}
            }
            guard url.isFileURL else {throw MediaAudioFailure(message:"Audio routing requires a local media file")}
        } catch {diagnostic=error.localizedDescription;completion(.failure(error));return}
        guard let lease=MediaAudioAdmission.shared.reserve() else {
            let error=MediaAudioFailure(message:"At most eight routed audio sources may be prepared; stop or unassign another source",isAdmissionLimit:true)
            diagnostic=error.localizedDescription;completion(.failure(error));return
        }
        admission=lease
        let asset=AVURLAsset(url:url)
        preparationTask=Task { @MainActor [weak self,lease] in
            defer {withExtendedLifetime(lease) {}}
            do {
                let tracks=try await asset.loadTracks(withMediaType:.audio)
                guard let track=tracks.first else {
                    if let self,self.epoch==token {self.hasAudioTrack=false}
                    throw MediaAudioFailure(message:"This file has no audio track")
                }
                let descriptions=try await track.load(.formatDescriptions)
                guard let description=descriptions.first,let asbd=CMAudioFormatDescriptionGetStreamBasicDescription(description) else {throw MediaAudioFailure(message:"Audio track format description is unavailable")}
                let channels=Int(asbd.pointee.mChannelsPerFrame)
                let outputChannels=requestedRouting?.outputChannels ?? (self?.offline == true ? 2 : Self.availableDevices().first(where:{$0.isDefault})?.outputChannels ?? 2)
                var routing=requestedRouting ?? .identity(inputChannels:channels,outputChannels:outputChannels)
                if requestedRouting==nil,channels==1,outputChannels>=2 {routing.gains[1]=1}
                if requestedRouting==nil,outputChannels==1,channels>1 {routing.gains=Array(repeating:1/Double(channels),count:channels)}
                try routing.validate()
                guard routing.inputChannels==channels,channels<=Self.maximumChannels,outputChannels<=Self.maximumChannels else {throw MediaAudioFailure(message:"Audio route supports 1…8 channels; matrix inputs must match the file's first audio track")}
                let duration=try await asset.load(.duration).seconds
                guard duration.isFinite,duration>0,duration<=MediaPool.maximumTransportTime else {throw MediaAudioFailure(message:"Audio duration is invalid or exceeds the supported transport range")}
                guard let self,self.epoch==token else {return}
                try self.configure(routing:routing)
                self.decoder=MediaAudioDecoder(asset:asset,track:track,channels:routing.inputChannels,duration:duration,admission:lease)
                self.duration=duration;self.endLimit=duration;self.route=routing;self.ready=true;self.hasAudioTrack=true;self.diagnostic=nil
                completion(.success(()))
            } catch {
                guard let self,self.epoch==token else {return}
                self.admission=nil;self.diagnostic=error.localizedDescription;completion(.failure(error))
            }
        }
    }
    private func configure(routing:AudioRoutingSettings)throws {
        if !offline {
            let devices=Self.availableDevices()
            let chosen=routing.deviceUID.flatMap {uid in devices.first {$0.uid==uid}} ?? (routing.deviceUID==nil ? devices.first(where:{$0.isDefault}) : nil)
            guard let chosen else {throw MediaAudioFailure(message:"Selected audio output is unavailable; choose it again explicitly")}
            guard chosen.outputChannels==routing.outputChannels else {throw MediaAudioFailure(message:"Audio matrix output count must match the selected device's channel count")}
            try engine.outputNode.auAudioUnit.setDeviceID(chosen.id)
            activeDeviceUID=chosen.uid
        }
        guard let layout=AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(routing.outputChannels)) else {throw MediaAudioFailure(message:"Audio route layout unavailable")}
        let format=routing.outputChannels<=2 ? AVAudioFormat(standardFormatWithSampleRate:Self.sampleRate,channels:AVAudioChannelCount(routing.outputChannels))! : AVAudioFormat(standardFormatWithSampleRate:Self.sampleRate,channelLayout:layout)
        engine.attach(player);engine.attach(speed)
        engine.connect(player,to:speed,format:format)
        engine.connect(speed,to:engine.mainMixerNode,format:format)
        if offline {try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:4096)}
        engine.connect(engine.mainMixerNode,to:engine.outputNode,format:format)
        self.format=format
        engine.prepare()
        let configurationToken=configurationGeneration
        configurationObserver=NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:engine,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,!self.offline,self.ready,self.configurationGeneration==configurationToken else {return}
                self.stop();self.ready=false;self.diagnostic="Audio device configuration changed; reselect the route before playback"
            }
        }
    }
    /// `generation` is the caller's discontinuity generation, not its frame tick.
    /// Continuous forward transport uses AVAudioPlayerNode's sample clock. A seek,
    /// loop jump or >100 ms clock error flushes old scheduled buffers atomically.
    func update(positionSeconds:Double,playing:Bool,rate:Double,generation:UInt64,volume:Double=1,endSeconds:Double?=nil) {
        precondition(Thread.isMainThread)
        guard ready,positionSeconds.isFinite,rate.isFinite,volume.isFinite else {return}
        if !offline,ProcessInfo.processInfo.systemUptime-lastDeviceCheck>1 {
            lastDeviceCheck=ProcessInfo.processInfo.systemUptime
            let devices=Self.availableDevices()
            let exists=route?.deviceUID.map {uid in devices.contains {$0.uid==uid}} ?? (devices.first(where:{$0.isDefault})?.uid == activeDeviceUID)
            guard exists else {stop();ready=false;diagnostic="Selected audio output disconnected; routing is silent until explicitly reselected";return}
        }
        guard rate>0,rate>=0.125,rate<=8 else {
            heldPosition=playbackPosition;requestedPlaying=false;player.pause();metrics.unsupportedDirectionCount+=1
            diagnostic=rate<0 ? "Reverse/random audio is silent; use forward playback for this route" : "Audio route is held silent at zero or unsupported speed"
            return
        }
        diagnostic=nil
        let observed=playbackPosition,wasPlaying=requestedPlaying
        if !playing {heldPosition=observed}
        if playing && !wasPlaying,let time=renderedPlayerTime {
            playerClockOffset=Double(time.sampleTime)-(heldPosition-basePosition)*time.sampleRate
        }
        requestedPlaying=playing
        speed.rate=Float(rate);engine.mainMixerNode.outputVolume=Float(max(0,min(1,volume)))
        let requestedPosition=max(0,min(duration,positionSeconds))
        let limit=endSeconds ?? duration
        guard limit.isFinite,limit>=0 else {stop();diagnostic="Invalid audio trim end";return}
        let boundedLimit=min(duration,limit),limitChanged=abs(boundedLimit-endLimit)>1.0/48000
        let target=min(boundedLimit,requestedPosition)
        endLimit=boundedLimit
        if transportGeneration != generation || abs(observed-target)>0.1 || limitChanged {
            resetSchedule(at:target,generation:generation)
        }
        lastPosition=target
        if !playing {player.pause();if !offline {engine.pause()}}
        fillQueue()
        if playing {startIfNeeded()}
    }
    private func resetSchedule(at seconds:Double,generation:UInt64) {
        epoch &+= 1;transportGeneration=generation;player.stop();speed.auAudioUnit.reset();queued=0;ended=false
        basePosition=seconds;heldPosition=seconds;playerClockOffset=0;nextPosition=seconds;metrics.seekCount+=1
        decoder?.cancel()
    }
    private func fillQueue() {
        guard ready,!ended,!decodeInFlight,queued<2,nextPosition.isFinite,let decoder,let route,let format else {return}
        let token=epoch,start=nextPosition,limit=endLimit
        decodeInFlight=true
        queued+=1;metrics.maximumQueuedBuffers=max(metrics.maximumQueuedBuffers,queued)
        // Each result requests the next chunk only after the previous one is
        // published, so a short/final decoder packet cannot create a PTS gap.
        nextPosition = .infinity
        worker.async { [weak self] in
            let result=Result {try decoder.read(at:start,epoch:token,routing:route,format:format,endSeconds:limit)}
            DispatchQueue.main.async {
                guard let self else {return}
                self.decodeInFlight=false
                guard self.epoch==token,self.ready else {self.metrics.discardedCompletions+=1;self.fillQueue();return}
                do {
                    guard let chunk=try result.get() else {self.queued-=1;self.ended=true;return}
                    self.metrics.decodedChunks+=1;self.metrics.scheduledFrames+=Int64(chunk.buffer.frameLength)
                    self.nextPosition=chunk.endSeconds
                    self.player.scheduleBuffer(chunk.buffer,completionCallbackType:.dataConsumed) { [weak self] _ in
                        DispatchQueue.main.async {
                            guard let self,self.epoch==token else {return}
                            self.queued=max(0,self.queued-1);self.fillQueue()
                        }
                    }
                    if self.requestedPlaying {self.startIfNeeded()}
                    self.fillQueue()
                } catch {
                    self.stop();self.ready=false;self.diagnostic="Audio decode failed: "+error.localizedDescription
                }
            }
        }
    }
    private func startIfNeeded() {
        guard queued>0,requestedPlaying else {return}
        do {if !engine.isRunning {try engine.start()};if !player.isPlaying {player.play()}}
        catch {stop();ready=false;diagnostic="Audio engine failed: "+error.localizedDescription}
    }
    func stop() {
        precondition(Thread.isMainThread)
        requestedPlaying=false;epoch &+= 1;transportGeneration=nil;player.stop();queued=0;ended=false
        decoder?.cancel();basePosition=0;heldPosition=0;playerClockOffset=0;nextPosition=0;lastPosition=0
        if !offline {engine.pause()}
    }
    func invalidate() {
        configurationGeneration &+= 1
        stop();preparationTask?.cancel();preparationTask=nil;activeDeviceUID=nil;ready=false;hasAudioTrack=nil;duration=0;route=nil;decoder=nil;format=nil;admission=nil
        if let configurationObserver {NotificationCenter.default.removeObserver(configurationObserver);self.configurationObserver=nil}
        engine.stop()
        if engine.manualRenderingMode == .offline {engine.disableManualRenderingMode()}
        if engine.attachedNodes.contains(player) {engine.detach(player)}
        if engine.attachedNodes.contains(speed) {engine.detach(speed)}
    }
    /// The production graph's silent offline mode is used only by the assertion
    /// harness. It never enables an output device or changes system audio settings.
    func renderOffline(_ frames:AVAudioFrameCount)throws->AVAudioPCMBuffer {
        guard offline,let format,frames>0,frames<=4096,let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:frames) else {throw MediaAudioFailure(message:"Invalid offline audio request")}
        guard engine.isRunning else {throw MediaAudioFailure(message:"Offline audio engine has not started")}
        let status=try engine.renderOffline(frames,to:buffer)
        guard status == .success else {throw MediaAudioFailure(message:"Offline audio rendering could not provide frames: \(status.rawValue)")}
        return buffer
    }
}

/// Local AVFoundation extraction at a fixed 48 kHz; worker-only mutable decoder
/// state. Main only advances a cancellation serial. AVAssetReader cancellation,
/// reset and copyNextSampleBuffer all belong to this decoder's serial worker;
/// Apple's SDK forbids concurrent cancelReading/copyNextSampleBuffer calls.
private final class MediaAudioDecoderHooks:@unchecked Sendable {
    var beforePacketRead:(()->Void)?
    var onPacketRead:(()->Void)?
    var onReaderCancelled:(()->Void)?
}

private final class MediaAudioDecoder:@unchecked Sendable {
    struct Chunk {let buffer:AVAudioPCMBuffer;let endSeconds:Double}
    let asset:AVAsset,track:AVAssetTrack,channels:Int,duration:Double
    private let admission:MediaAudioAdmission.Lease
    private let lock=NSLock()
    private var cancellationSerial:UInt64=0
    private let hooks:MediaAudioDecoderHooks?
    private var reader:AVAssetReader?,output:AVAssetReaderTrackOutput?
    private var generation:UInt64?
    private var pending:[Float]=[],pendingOffset=0
    private var pendingFirstFrame:Int64=0
    private var nextFrame:Int64=0
    init(asset:AVAsset,track:AVAssetTrack,channels:Int,duration:Double,admission:MediaAudioAdmission.Lease,hooks:MediaAudioDecoderHooks?=nil) {self.asset=asset;self.track=track;self.channels=channels;self.duration=duration;self.admission=admission;self.hooks=hooks}
    func cancel() {lock.lock();cancellationSerial &+= 1;lock.unlock()}
    private var currentCancellationSerial:UInt64 {lock.lock();defer {lock.unlock()};return cancellationSerial}
    private func cancelReaderOnWorker() {
        precondition(!Thread.isMainThread)
        if let reader {reader.cancelReading();hooks?.onReaderCancelled?()}
    }
    private func cancellationRequested(_ serial:UInt64)->Bool {
        guard currentCancellationSerial != serial else {return false}
        cancelReaderOnWorker();pending=[];pendingOffset=0;return true
    }
    private func reset(at seconds:Double,epoch:UInt64)throws {
        cancelReaderOnWorker();pending=[];pendingOffset=0
        let reader=try AVAssetReader(asset:asset)
        var settings:[String:Any]=[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:MediaAudioPlayer.sampleRate,AVNumberOfChannelsKey:channels,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsBigEndianKey:false,AVLinearPCMIsNonInterleaved:false]
        if channels>2,let layout=AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)) {
            settings[AVChannelLayoutKey]=Data(bytes:layout.layout,count:MemoryLayout<AudioChannelLayout>.size)
        }
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:settings);output.alwaysCopiesSampleData=false
        guard reader.canAdd(output) else {throw MediaAudioFailure(message:"Audio decoder does not support Float32 PCM for this track")}
        reader.add(output)
        let start=max(0,min(duration,seconds))
        reader.timeRange=CMTimeRange(start:CMTime(seconds:start,preferredTimescale:48000),duration:CMTime(seconds:max(0,duration-start),preferredTimescale:48000))
        guard reader.startReading() else {throw reader.error ?? MediaAudioFailure(message:"Audio reader did not start")}
        self.reader=reader;self.output=output;generation=epoch;nextFrame=Int64((start*48000).rounded())
    }
    func read(at seconds:Double,epoch:UInt64,routing:AudioRoutingSettings,format:AVAudioFormat,endSeconds:Double)throws->Chunk? {
        precondition(!Thread.isMainThread)
        let serial=currentCancellationSerial
        guard seconds.isFinite else {throw MediaAudioFailure(message:"Invalid queued audio timestamp")}
        guard endSeconds>seconds else {return nil}
        if generation != epoch {try reset(at:seconds,epoch:epoch)}
        if cancellationRequested(serial) {return nil}
        let remaining=max(0,Int64((endSeconds*48000).rounded(.up))-nextFrame)
        let targetFrames=Int(min(Int64(MediaAudioPlayer.chunkFrames),remaining))
        guard targetFrames>0 else {return nil}
        var input:[Float]=[];input.reserveCapacity(targetFrames*channels)
        var packetsRead=0
        while input.count<targetFrames*channels {
            if cancellationRequested(serial) {return nil}
            if pendingOffset<pending.count {
                let current=nextFrame+Int64(input.count/channels)
                let pendingFrame=pendingFirstFrame+Int64(pendingOffset/channels)
                if pendingFrame>current {
                    let gap=min(Int64(targetFrames-input.count/channels),pendingFrame-current)
                    input.append(contentsOf:repeatElement(Float(0),count:Int(gap)*channels));continue
                }
                if pendingFrame<current {
                    pendingOffset+=min(pending.count-pendingOffset,Int(current-pendingFrame)*channels)
                    if pendingOffset==pending.count {pending=[];pendingOffset=0}
                    continue
                }
                let count=min(pending.count-pendingOffset,targetFrames*channels-input.count)
                input.append(contentsOf:pending[pendingOffset..<pendingOffset+count]);pendingOffset+=count
                if pendingOffset==pending.count {pending=[];pendingOffset=0}
                continue
            }
            guard packetsRead<128 else {throw MediaAudioFailure(message:"Audio reader exceeded its 128-packet work budget")}
            hooks?.beforePacketRead?()
            if cancellationRequested(serial) {return nil}
            packetsRead+=1;hooks?.onPacketRead?()
            guard let sample=output?.copyNextSampleBuffer() else {
                if reader?.status == .failed {throw reader?.error ?? MediaAudioFailure(message:"Audio reader failed")}
                break
            }
            if cancellationRequested(serial) {return nil}
            let frames=CMSampleBufferGetNumSamples(sample)
            guard frames>0,frames<=131072,let data=CMSampleBufferGetDataBuffer(sample) else {throw MediaAudioFailure(message:"Audio decoder packet exceeded its bounded PCM budget")}
            let count=frames*channels,bytes=count*MemoryLayout<Float>.size
            guard CMBlockBufferGetDataLength(data)==bytes else {throw MediaAudioFailure(message:"Unexpected noninterleaved audio decoder format")}
            pending=Array(repeating:0,count:count);pendingOffset=0
            let status=pending.withUnsafeMutableBytes {CMBlockBufferCopyDataBytes(data,atOffset:0,dataLength:bytes,destination:$0.baseAddress!)}
            guard status==kCMBlockBufferNoErr else {throw MediaAudioFailure(message:"Audio sample copy failed")}
            let pts=CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite,abs(pts)<=MediaPool.maximumTransportTime else {throw MediaAudioFailure(message:"Audio packet has invalid PTS")}
            pendingFirstFrame=Int64((pts*48000).rounded())
        }
        let frames=input.count/channels
        guard frames>0 else {return nil}
        if cancellationRequested(serial) {return nil}
        let mixed=try routing.mix(interleaved:input,frameCount:frames)
        guard let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)),let data=buffer.floatChannelData else {throw MediaAudioFailure(message:"Audio PCM allocation failed")}
        buffer.frameLength=AVAudioFrameCount(frames)
        for frame in 0..<frames {for channel in 0..<routing.outputChannels {data[channel][frame]=mixed[frame*routing.outputChannels+channel]}}
        nextFrame+=Int64(frames)
        return Chunk(buffer:buffer,endSeconds:Double(nextFrame)/48000)
    }
}
/// Controlled ownership regression: hold the worker immediately before the
/// real reader's first copy, cancel on main, then release. Actual reader APIs
/// must run on worker and no packet may be copied after the invalidation.
@MainActor enum MediaAudioCancellationFixture {
    static func run(url:URL,completion:@escaping(Result<[String:Any],Error>)->Void) {
        Task { @MainActor in
            do {
                let asset=AVURLAsset(url:url)
                guard let track=try await asset.loadTracks(withMediaType:.audio).first else {throw MediaAudioFailure(message:"Cancellation fixture audio track missing")}
                let duration=try await asset.load(.duration).seconds
                guard let lease=MediaAudioAdmission.shared.reserve() else {throw MediaAudioFailure(message:"Cancellation fixture admission unavailable",isAdmissionLimit:true)}
                let hooks=MediaAudioDecoderHooks()
                let decoder=MediaAudioDecoder(asset:asset,track:track,channels:2,duration:duration,admission:lease,hooks:hooks)
                let release=DispatchSemaphore(value:0)
                var mainProbeRan=false,readerCancelledOnMain=false,cancelCount=0,packetCount=0,gateEntered=false
                hooks.beforePacketRead={ [weak decoder] in
                    gateEntered=true
                    DispatchQueue.main.async {decoder?.cancel();mainProbeRan=true;release.signal()}
                    _=release.wait(timeout:.now()+5)
                }
                hooks.onReaderCancelled={cancelCount+=1;readerCancelledOnMain = readerCancelledOnMain || Thread.isMainThread}
                hooks.onPacketRead={packetCount+=1}
                let route=AudioRoutingSettings.identity(inputChannels:2,outputChannels:2)
                let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
                DispatchQueue(label:"org.aperturecue.audio-cancellation-fixture").async {
                    let result=Result {try decoder.read(at:0,epoch:1,routing:route,format:format,endSeconds:duration)}
                    let cancelled:Bool
                    if case .success(let chunk)=result {cancelled=chunk==nil} else {cancelled=false}
                    let evidence:[String:Any]=["mainProbeRan":mainProbeRan,"gateEnteredOnWorker":gateEntered,"readerCancellationCount":cancelCount,"readerCancelledOnMain":readerCancelledOnMain,"packetsCopiedAfterInvalidation":packetCount,"readReturnedCancelled":cancelled]
                    DispatchQueue.main.async {
                        do {_=try result.get();completion(.success(evidence))}
                        catch {completion(.failure(error))}
                    }
                }
            } catch {completion(.failure(error))}
        }
    }
}
#endif
