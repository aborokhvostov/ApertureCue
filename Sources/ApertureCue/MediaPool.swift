#if os(macOS)
import AppKit
import AVFoundation
import CoreVideo
import Metal
import MetalKit
import QuartzCore
import MappingCore

struct MediaFrameBlend {
    let texture: MTLTexture
    let uv: MediaUVTransform
    let weight: Float
}

/// Immutable references retained together through all consuming GPU commands.
struct MediaFrameResource {
    let texture:MTLTexture
    var wrappers:[CVMetalTexture]=[]
    var buffers:[CVPixelBuffer]=[]
    var uv:MediaUVTransform = .identity
    var owners:[AnyObject]=[]
    var blend: MediaFrameBlend?
}
struct MediaFrameResources:@unchecked Sendable {
    let textures:[UUID:MTLTexture]
    let retained:[CVMetalTexture]
    let buffers:[CVPixelBuffer]
    let uv:[UUID:MediaUVTransform]
    var owners:[AnyObject]=[]
    var blends: [UUID: MediaFrameBlend] = [:]
    static let empty=MediaFrameResources(textures:[:],retained:[],buffers:[],uv:[:])
}
protocol MediaCameraSource:AnyObject {
    func start(deviceID:String,onError:@escaping(String)->Void)
    func takeLatest()->CVPixelBuffer?
    func stop()
}

protocol VirtualMediaFrames:AnyObject {
    func frameResource(for id:UUID)->MediaFrameResource?
}

/// Main-thread coordinator. Image I/O and texture creation use a serial worker;
/// AVFoundation owns its bounded decoder queues. Each movie retains one video
/// output frame and each image retains one texture, shared by all output views.
final class MediaPool {
    private final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, MediaCameraSource {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "org.aperturecue.camera", qos: .userInitiated)
        private let lock = NSLock()
        private var latest: CVPixelBuffer?
        private var stopped=false
        private var observers: [NSObjectProtocol] = []

        func start(deviceID: String, onError: @escaping (String) -> Void) {
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    guard let device = AVCaptureDevice(uniqueID: deviceID) else {
                        onError("Camera disconnected or unavailable")
                        return
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    // The Swift spelling changed between Apple SDKs; the notification's
                    // Objective-C name is stable (verified against the local SDK).
                    let disconnected = Notification.Name("AVCaptureDeviceWasDisconnectedNotification")
                    self.observers.append(NotificationCenter.default.addObserver(forName: disconnected, object: device, queue: nil) { _ in
                        onError("Camera disconnected")
                    })
                    let runtimeError = Notification.Name("AVCaptureSessionRuntimeErrorNotification")
                    self.observers.append(NotificationCenter.default.addObserver(forName: runtimeError, object: self.session, queue: nil) { notification in
                        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                        onError("Camera runtime error: \(error?.localizedDescription ?? "capture stopped")")
                    })
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .high
                    guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                        self.session.commitConfiguration()
                        onError("Camera input/output configuration unsupported")
                        return
                    }
                    self.session.addInput(input); self.session.addOutput(output)
                    self.session.commitConfiguration()
                    self.session.startRunning()
                    if !self.session.isRunning { onError("Camera failed to start") }
                } catch { onError("Camera capture failed: \(error.localizedDescription)") }
            }
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            lock.lock(); if !stopped {latest = buffer}; lock.unlock()
        }

        func takeLatest() -> CVPixelBuffer? {
            lock.lock(); defer { lock.unlock() }
            let result = latest; latest = nil
            return result
        }

        func stop() {
            lock.lock();stopped=true;latest=nil;lock.unlock()
            let session=self.session;queue.async {session.stopRunning()}
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            let session = session
            queue.async { session.stopRunning() }
        }
    }

    private final class Entry {
        var asset: MediaAsset
        let url: URL
        var texture: MTLTexture?
        var cvTexture: CVMetalTexture?
        var pixelBuffer:CVPixelBuffer?
        var presentationTransform=CGAffineTransform.identity
        var naturalSize=CGSize.zero
        var player: AVPlayer?
        var videoOutput: AVPlayerItemVideoOutput?
        var endObserver: NSObjectProtocol?
        var statusObserver: NSKeyValueObservation?
        var camera:MediaCameraSource?
        var imageOwner:MediaLoadedImage?
        var imageLoading=false
        var imageRetryAt=0.0
        var lastImagePull=0.0
        var sequence:MediaImageSequence?
        var durationSeconds=0.0
        var metadataStarted=false
        var frameRate=30.0
        var seekPending=false
        var acceptedPTS:Double?
        var decodedFrames=0
        var lastDecodedIdentity:ObjectIdentifier?
        var lastDecodedGeneration:UInt64=0
        var rejectedFrames=0
        var syncCorrections=0
        var decodeSlot:MontageVideoSlot?
        let revision=UUID()
        var decodeClipID=UUID()
        var lastDiscontinuity:UInt64=0
        var transport=SourceTransport()
        var currentManagedResource:MediaFrameResource?
        var routedAudio:MediaAudioPlayer?
        var hasAudio=false
        var audioAttempted=false
        var seekGeneration: UInt64 = 0
        init(_ asset: MediaAsset, url: URL) { self.asset = asset; self.url = url }
        deinit {
            player?.pause();camera?.stop();sequence?.reset();decodeSlot?.clear();routedAudio?.invalidate()
            if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
        }
    }

    let device: MTLDevice
    /// Matches the project's maximum supported automation time. Bounding show
    /// time also keeps remote numeric input representable by CMTime/UI clocks.
    static let maximumTransportTime: Double = 86400 * 365
    private var entries: [UUID: Entry] = [:]
    private var cache: CVMetalTextureCache?
    private let loaderQueue = DispatchQueue(label: "org.aperturecue.image-io", qos: .userInitiated)
    private var clockAnchor = CACurrentMediaTime()
    private var heldTime = 0.0
    private(set) var isPlaying = false
    private(set) var errorMessages: [UUID: String] = [:]
    var onChange: (() -> Void)?
    weak var virtualSources:VirtualMediaFrames?
    var externalTexture: ((String) -> MTLTexture?)?
    private var activeAssetIDs:Set<UUID>?
    private let cameraFactory:(()->MediaCameraSource)?
    private let audioFactory:(()->MediaAudioPlayer)?
    private let managedSlots=(0..<8).map {_ in MontageVideoSlot()}
    private var document=UUID()
    private var videoDemandIDs:Set<UUID>?

    init(device: MTLDevice,cameraFactory:(()->MediaCameraSource)? = nil,audioFactory:(()->MediaAudioPlayer)? = nil) {
        self.device = device;self.cameraFactory=cameraFactory;self.audioFactory=audioFactory
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    }

    var currentTime: Double {
        isPlaying ? heldTime + CACurrentMediaTime() - clockAnchor : heldTime
    }

    var duration: Double {
        entries.values.compactMap { entry -> Double? in
            guard let seconds = entry.player?.currentItem?.duration.seconds,
                  seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        }.max() ?? 0
    }

    var loadedAssetCount: Int { entries.count }

    static func availableCameras() -> [(id: String, name: String)] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { deviceTypes = [.builtInWideAngleCamera, .external] }
        else { deviceTypes = [.builtInWideAngleCamera, .externalUnknown] }
        return AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
            .devices.map { (id: $0.uniqueID, name: $0.localizedName) }
    }
    func diagnosticState(for id:UUID)->String {
        guard let entry=entries[id] else {return "entry missing"}
        return "kind=\(entry.asset.kind), active=\(isActive(id)), metadata=\(entry.metadataStarted), duration=\(entry.durationSeconds), player=\(entry.player?.status.rawValue ?? -1), item=\(entry.player?.currentItem?.status.rawValue ?? -1), seek=\(entry.seekPending), error=\(errorMessages[id] ?? "none")"
    }
    func playbackTime(for id: UUID) -> Double {
        if let entry=entries[id],entry.asset.playback != nil || entry.sequence != nil {return sample(entry)?.position ?? 0}
        let value = entries[id]?.player?.currentTime().seconds ?? 0
        return value.isFinite ? max(0, value) : 0
    }
    /// Internal integration evidence for clock continuity across document edits.
    func seekGeneration(for id:UUID)->UInt64? {entries[id]?.seekGeneration}
    func duration(for id: UUID) -> Double {
        if let entry=entries[id],entry.durationSeconds>0 {return entry.durationSeconds}
        let value = entries[id]?.player?.currentItem?.duration.seconds ?? 0
        return value.isFinite ? value : 0
    }
    /// Nil preserves the standalone pool API. The editor explicitly activates
    /// assigned ordinary sources, so montage-only files cannot leak audio.
    func setActiveAssetIDs(_ ids:Set<UUID>?) {
        precondition(Thread.isMainThread)
        guard ids != activeAssetIDs else {return}
        let previous=activeAssetIDs;activeAssetIDs=ids
        for entry in entries.values {
            let active=isActive(entry.asset.id),wasActive=previous?.contains(entry.asset.id) ?? true
            entry.player?.isMuted = !active || usesRoutedAudio(entry) || entry.asset.playback != nil
            if !active {entry.player?.pause();entry.player=nil;entry.videoOutput=nil;entry.statusObserver=nil;if let observer=entry.endObserver {NotificationCenter.default.removeObserver(observer);entry.endObserver=nil}}
            else if !wasActive {seek(entry:entry,toShowTime:sourceElapsed(entry))}
            if !active {
                entry.routedAudio?.invalidate();entry.routedAudio=nil;entry.audioAttempted=false
                entry.decodeSlot?.clear();entry.decodeSlot=nil;entry.currentManagedResource=nil
                if entry.asset.playback != nil {entry.texture=nil;entry.cvTexture=nil;entry.pixelBuffer=nil}
            }
        }
    }
    func setVideoDemandIDs(_ ids:Set<UUID>?) {
        guard ids != videoDemandIDs else {return};videoDemandIDs=ids
        for entry in entries.values where !(ids?.contains(entry.asset.id) ?? true) {
            entry.decodeSlot?.clear();entry.decodeSlot=nil;entry.currentManagedResource=nil;entry.sequence?.reset()
            if entry.asset.playback != nil {entry.texture=nil;entry.cvTexture=nil;entry.pixelBuffer=nil}
        }
    }
    private func isActive(_ id:UUID)->Bool {activeAssetIDs?.contains(id) ?? true}
    func isSourcePlaying(for id:UUID)->Bool {(entries[id]?.player?.rate ?? 0) != 0}
    func isSourceMuted(for id:UUID)->Bool {entries[id]?.player?.isMuted ?? !isActive(id)}
    func sourceVolume(for id:UUID)->Float? {entries[id].map {Float($0.asset.volume)}}

    /// Acquire each source once for an entire composition. The returned wrappers
    /// belong to exactly these textures and must survive the submitted GPU work.
    func frameResources(for ids: Set<UUID>) -> MediaFrameResources {
        precondition(Thread.isMainThread)
        var textures: [UUID: MTLTexture] = [:]
        var retained: [CVMetalTexture] = []
        var buffers:[CVPixelBuffer]=[]
        var uv:[UUID:MediaUVTransform]=[:]
        var owners:[AnyObject]=[]
        var blends: [UUID: MediaFrameBlend] = [:]
        for id in ids {
            if entries[id] == nil,let frame=virtualSources?.frameResource(for:id) {
                textures[id] = frame.texture
                retained += frame.wrappers
                buffers += frame.buffers
                uv[id] = frame.uv
                owners += frame.owners
                blends[id] = frame.blend
                continue
            }
            if let texture = texture(for: id) {
                textures[id] = texture
                if let owner=entries[id]?.imageOwner {owners.append(owner)}
                if let frame=managedResource(for:id) {owners += frame.owners;uv[id]=frame.uv}
                if let wrapper = entries[id]?.cvTexture { retained.append(wrapper) }
                if let pixelBuffer=entries[id]?.pixelBuffer {buffers.append(pixelBuffer)}
                if let entry=entries[id],let pixel=entry.pixelBuffer,entry.naturalSize.width>0 {
                    uv[id]=try? MediaUVTransform.video(entry.presentationTransform,size:entry.naturalSize,pixelWidth:CVPixelBufferGetWidth(pixel),pixelHeight:CVPixelBufferGetHeight(pixel))
                }
            }
        }
        return MediaFrameResources(textures:textures,retained:retained,buffers:buffers,uv:uv,owners:owners,blends:blends)
    }

    /// Explicit relink can restore a file at the same path as a failed entry.
    func reloadAsset(id: UUID, assets: [MediaAsset], baseURL: URL) {
        precondition(Thread.isMainThread)
        let transport=entries[id]?.transport
        entries.removeValue(forKey:id);errorMessages.removeValue(forKey:id)
        reconcile(assets:assets,baseURL:baseURL)
        if let entry=entries[id],let transport {
            entry.transport=transport;seek(entry:entry,toShowTime:sourceElapsed(entry));update()
        }
    }

    func reconcile(assets: [MediaAsset], baseURL: URL) {
        precondition(Thread.isMainThread)
        let ids = Set(assets.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        errorMessages = errorMessages.filter { ids.contains($0.key) }
        let orderedAssets=assets.filter {isActive($0.id)}+assets.filter {!isActive($0.id)}
        for asset in orderedAssets {
            let url = asset.path.hasPrefix("/") ? URL(fileURLWithPath: asset.path) : baseURL.appendingPathComponent(asset.path)
            if let existing = entries[asset.id], existing.url == url,
               existing.asset.kind == asset.kind,
               existing.asset.loop == asset.loop,existing.asset.playback==asset.playback,existing.asset.sequence==asset.sequence,existing.asset.audioRouting==asset.audioRouting {
                existing.asset=asset
                existing.player?.volume = Float(max(0, min(1, asset.volume)))
                continue
            }
            let previousTransport=entries[asset.id]?.transport
            entries.removeValue(forKey:asset.id)
            let entry = Entry(asset, url: url)
            if let previousTransport {entry.transport=previousTransport}
            entries[asset.id] = entry
            errorMessages.removeValue(forKey: asset.id)
            if asset.kind == "external-video" { continue }
            if asset.kind == "camera" {
                prepareCamera(entry)
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                errorMessages[asset.id] = "Missing media: \(url.lastPathComponent)"
                continue
            }
            switch asset.kind {
            case "video","audio": prepareVideo(entry)
            case "image": break // Pulled lazily; an unused bin image cannot occupy the entire budget.
            case "sequence":
                guard let manifest=asset.sequence else {errorMessages[asset.id]="Missing sequence manifest";continue}
                let sequence=MediaImageSequence(device:device,directory:url,manifest:manifest);entry.sequence=sequence;entry.durationSeconds=Double(manifest.frames.count)/manifest.fps
                sequence.onChange = { [weak self,weak entry,weak sequence] in
                    guard let self,let entry,self.entries[entry.asset.id] === entry else {return}
                    let message=sequence?.message ?? "";self.errorMessages[entry.asset.id]=message.isEmpty ? nil : message;self.onChange?()
                }
            default: errorMessages[asset.id] = "Unsupported source type: \(asset.kind)"
            }
        }
        onChange?()
    }

    private func prepareCamera(_ entry: Entry) {
        guard cameraFactory != nil || AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            errorMessages[entry.asset.id] = "Camera access is not authorized; use Add Camera to grant access"
            return
        }
        let camera:MediaCameraSource = cameraFactory?() ?? CameraCapture()
        entry.camera = camera
        camera.start(deviceID: entry.asset.path) { [weak self, weak entry] message in
            DispatchQueue.main.async {
                guard let self, let entry, self.entries[entry.asset.id] === entry else { return }
                entry.camera?.stop();entry.camera=nil
                entry.texture=nil;entry.cvTexture=nil;entry.pixelBuffer=nil
                self.errorMessages[entry.asset.id] = message
                self.onChange?()
            }
        }
    }

    private func prepareImage(_ entry:Entry) {
        guard !entry.imageLoading,ProcessInfo.processInfo.systemUptime>=entry.imageRetryAt else {return}
        entry.imageLoading=true
        let device=self.device
        loaderQueue.async { [weak self,weak entry] in
            guard let entry else {return}
            let result=Result {try MediaLoadedImage.load(url:entry.url,device:device)}
            DispatchQueue.main.async {
                guard let self,self.entries[entry.asset.id] === entry else {return}
                entry.imageLoading=false
                switch result {
                case .success(let image):entry.imageOwner=image;entry.texture=image.texture;entry.lastImagePull=ProcessInfo.processInfo.systemUptime;self.errorMessages[entry.asset.id]=nil
                case .failure(let error):
                    entry.imageRetryAt=error is MediaImageFailure ? ProcessInfo.processInfo.systemUptime+0.1 : .infinity
                    self.errorMessages[entry.asset.id]="Image decode failed: "+error.localizedDescription
                }
                self.onChange?()
            }
        }
    }

    private func prepareVideo(_ entry: Entry) {
        let source=AVURLAsset(url:entry.url,options:[AVURLAssetPreferPreciseDurationAndTimingKey:true])
        if !entry.metadataStarted {entry.metadataStarted=true;loadMetadata(entry,source:source)}
        guard entry.asset.playback==nil,entry.player==nil else {return}
        guard entries.values.filter({$0.player != nil}).count<8 else {errorMessages[entry.asset.id]="Ordinary AVPlayer source limit (8) reached";return}
        let item = AVPlayerItem(asset:source)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.volume = Float(max(0, min(1, entry.asset.volume)))
        player.isMuted = !isActive(entry.asset.id) || usesRoutedAudio(entry) || entry.asset.playback != nil
        entry.player = player
        entry.videoOutput = output
        entry.statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self, weak entry] item, _ in
            DispatchQueue.main.async {
                guard let self, let entry, self.entries[entry.asset.id] === entry else { return }
                if item.status == .failed {
                    self.errorMessages[entry.asset.id] = "Video decode failed: \(item.error?.localizedDescription ?? "unknown codec")"
                } else if item.status == .readyToPlay {
                    self.seek(entry: entry, toShowTime: self.sourceElapsed(entry))
                }
                self.onChange?()
            }
        }
        entry.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak entry] _ in
            guard let self, let entry, self.entries[entry.asset.id] === entry, entry.asset.playback == nil,entry.asset.loop,self.sourcePlaying(entry),self.isActive(entry.asset.id),
                  let duration = entry.player?.currentItem?.duration.seconds, duration.isFinite, duration > 0,
                  self.playbackTime(for: entry.asset.id) >= duration - 1.0 / 120.0 else { return }
            self.seek(entry: entry, toShowTime: 0)
        }
    }

    private func loadMetadata(_ entry:Entry,source:AVURLAsset) {
        Task { @MainActor [weak self,weak entry] in
            do {
                let duration=try await source.load(.duration)
                let tracks=try await source.loadTracks(withMediaType:.video)
                var matrix=CGAffineTransform.identity,size=CGSize.zero,fps=30.0
                if let track=tracks.first {
                    matrix=try await track.load(.preferredTransform);size=try await track.load(.naturalSize)
                    let nominal=try await track.load(.nominalFrameRate)
                    if nominal>0 {fps=Double(nominal)}
                    guard size.width>0,size.height>0,size.width<=8192,size.height<=8192,size.width*size.height<=16777216 else {throw ProjectError.invalid("video dimensions exceed 8192 per axis or 16 megapixels")}
                }
                let audioTracks=try await source.loadTracks(withMediaType:.audio)
                guard let self,let entry,self.entries[entry.asset.id] === entry else {return}
                entry.durationSeconds=duration.seconds.isFinite ? duration.seconds : 0
                entry.presentationTransform=matrix;entry.naturalSize=size;entry.frameRate=max(1.0/240,min(240,fps))
                entry.hasAudio = !audioTracks.isEmpty
                if entry.hasAudio,self.isActive(entry.asset.id),(self.usesRoutedAudio(entry) || entry.asset.playback != nil) {self.prepareAudio(entry)}
                self.onChange?()
            } catch {
                guard let self,let entry,self.entries[entry.asset.id] === entry else {return}
                self.errorMessages[entry.asset.id]="Media metadata: "+error.localizedDescription
            }
        }
    }

    func play() {
        precondition(Thread.isMainThread)
        guard !isPlaying else {return}
        clockAnchor=CACurrentMediaTime();isPlaying=true;update()
    }
    func pause() {
        precondition(Thread.isMainThread)
        heldTime=currentTime;isPlaying=false;update()
    }
    func seek(to seconds:Double) {
        precondition(Thread.isMainThread)
        guard seconds.isFinite else {return}
        heldTime=max(0,min(Self.maximumTransportTime,seconds));clockAnchor=CACurrentMediaTime()
        for entry in entries.values where entry.transport.mode == .followMaster {seek(entry:entry,toShowTime:heldTime)}
    }
    /// Document changes retire decoder generations even when a new project
    /// happens to reuse a media UUID and path from the preceding document.
    func reset() {
        pause();document=UUID();entries.removeAll();errorMessages.removeAll()
        managedSlots.forEach {$0.clear()};videoDemandIDs=nil;activeAssetIDs=nil;heldTime=0;clockAnchor=CACurrentMediaTime()
    }
    private func sourceElapsed(_ entry:Entry)->Double {
        (try? entry.transport.position(masterTime:min(Self.maximumTransportTime,currentTime),hostTime:CACurrentMediaTime())) ?? 0
    }
    private func sourcePlaying(_ entry:Entry)->Bool {entry.transport.mode == .followMaster ? isPlaying : entry.transport.isPlaying}
    private func sample(_ entry:Entry)->MediaPlaybackSample? {
        guard entry.durationSeconds>0 else {return nil}
        do {return try MediaPlayback.sample(elapsed:sourceElapsed(entry),duration:entry.durationSeconds,settings:MediaPlayback.effectiveSettings(entry.asset),frameRate:entry.asset.sequence?.fps ?? entry.frameRate)}
        catch {errorMessages[entry.asset.id]=error.localizedDescription;return nil}
    }
    func sourceElapsedTime(for id:UUID)->Double {entries[id].map(sourceElapsed) ?? 0}
    func sourceFollowsMaster(for id:UUID)->Bool {entries[id]?.transport.mode == .followMaster}
    func sourcePlay(_ id:UUID) {
        guard let entry=entries[id] else {return};try? entry.transport.play(at:CACurrentMediaTime(),masterTime:currentTime)
        seek(entry:entry,toShowTime:sourceElapsed(entry));update()
    }
    func sourcePause(_ id:UUID) {
        guard let entry=entries[id] else {return};try? entry.transport.pause(at:CACurrentMediaTime(),masterTime:currentTime);update()
    }
    func sourceSeek(_ id:UUID,to seconds:Double) {
        guard let entry=entries[id],seconds.isFinite else {return}
        do {try entry.transport.seek(to:max(0,min(Self.maximumTransportTime,seconds)),at:CACurrentMediaTime())} catch {return}
        seek(entry:entry,toShowTime:sourceElapsed(entry));update()
    }
    func sourceFollowMaster(_ id:UUID) {
        guard let entry=entries[id] else {return};entry.transport.followMaster();seek(entry:entry,toShowTime:currentTime);update()
    }
    func presentationTime(for id:UUID)->Double? {entries[id]?.acceptedPTS}
    func frameEnd(for id:UUID)->Double? {entries[id]?.decodeSlot?.frame?.end}
    func synchronizationCorrectionCount(for id:UUID)->Int {entries[id]?.syncCorrections ?? 0}
    func rejectedFrameCount(for id:UUID)->Int {entries[id]?.rejectedFrames ?? 0}
    func decodedFrameCount(for id:UUID)->Int {entries[id]?.decodedFrames ?? 0}
    var activeManagedDecoderCount:Int {managedSlots.filter {$0.owner != nil}.count}
    private func usesRoutedAudio(_ entry:Entry)->Bool {entry.asset.audioRouting != nil}
    private func prepareAudio(_ entry:Entry) {
        guard !entry.audioAttempted else {return}
        guard MediaAudioPlayer.admittedSourceCount<8 else {errorMessages[entry.asset.id]="Routed audio source limit (8) reached";return}
        entry.audioAttempted=true
        if entry.asset.audioRouting?.enabled == false {return}
        let audio=audioFactory?() ?? MediaAudioPlayer();entry.routedAudio=audio
        audio.prepare(url:entry.url,routing:entry.asset.audioRouting) { [weak self,weak entry] result in
            guard let self,let entry,self.entries[entry.asset.id] === entry else {audio.invalidate();return}
            if case .failure(let error)=result {
                self.errorMessages[entry.asset.id]="Audio: "+error.localizedDescription
                if (error as? MediaAudioFailure)?.isAdmissionLimit == true {entry.audioAttempted=false;entry.routedAudio=nil}
            }
            self.update();self.onChange?()
        }
    }
    func retryAudio(for id:UUID) {
        guard let entry=entries[id],usesRoutedAudio(entry) || entry.asset.playback != nil else {return}
        entry.routedAudio?.invalidate();entry.routedAudio=nil;entry.audioAttempted=false
        errorMessages[id]=nil;update()
    }
    /// Called by the production 30 Hz timer, also by standalone frame pulls.
    func update() {
        for entry in entries.values {
            if entry.imageOwner != nil,ProcessInfo.processInfo.systemUptime-entry.lastImagePull>1 {entry.imageOwner=nil;entry.texture=nil}
            let active=isActive(entry.asset.id),playing=sourcePlaying(entry) && active
            let managed=entry.asset.playback != nil
            if active,!managed,entry.player==nil,["video","audio"].contains(entry.asset.kind) {prepareVideo(entry)}
            if active,entry.hasAudio,(usesRoutedAudio(entry) || managed),entry.routedAudio==nil,!entry.audioAttempted {prepareAudio(entry)}
            if let player=entry.player {
                player.isMuted = !active || usesRoutedAudio(entry) || managed
                if !managed,!entry.seekPending {
                    let position=player.currentTime().seconds
                    if playing,position.isFinite,let expected=sample(entry),!expected.ended {
                        let delta=abs(position-expected.position)
                        let drift=entry.asset.loop ? min(delta,abs(entry.durationSeconds-delta)) : delta
                        if drift>0.12 {entry.syncCorrections+=1;seek(entry:entry,toShowTime:sourceElapsed(entry));continue}
                    }
                    let target:Float=playing && sample(entry)?.ended != true ? 1 : 0
                    if player.rate != target {player.rate=target}
                } else if player.rate != 0 {player.pause()}
            }
            if let audio=entry.routedAudio,let sample=sample(entry) {
                if sample.discontinuityIndex != entry.lastDiscontinuity {entry.lastDiscontinuity=sample.discontinuityIndex;entry.seekGeneration &+= 1}
                let settings=MediaPlayback.effectiveSettings(entry.asset)
                audio.update(positionSeconds:sample.position,playing:playing && !sample.ended && sample.direction>0,
                             rate:abs(settings.rate)*sample.direction,generation:entry.seekGeneration,volume:entry.asset.volume,endSeconds:min(entry.durationSeconds,settings.trimOut ?? entry.durationSeconds))
                if let diagnostic=audio.diagnostic {errorMessages[entry.asset.id]=diagnostic}
            }
        }
    }
    private func seek(entry:Entry,toShowTime seconds:Double) {
        entry.seekGeneration &+= 1;entry.seekPending=false;entry.acceptedPTS=nil
        if entry.asset.kind=="video" {entry.texture=nil;entry.cvTexture=nil;entry.pixelBuffer=nil;entry.currentManagedResource=nil}
        if entry.asset.playback != nil {entry.decodeSlot?.clear();return}
        guard let player=entry.player else {return}
        var position=max(0,min(Self.maximumTransportTime,seconds))
        if let duration=player.currentItem?.duration.seconds,duration.isFinite,duration>0 {
            position=entry.asset.loop ? position.truncatingRemainder(dividingBy:duration) : min(position,duration)
        }
        entry.seekPending=true
        let generation=entry.seekGeneration
        player.pause()
        player.seek(to:CMTime(seconds:position,preferredTimescale:1_000_000),toleranceBefore:.zero,toleranceAfter:.zero) { [weak self,weak entry] finished in
            DispatchQueue.main.async {
                guard let self,let entry,finished,self.entries[entry.asset.id] === entry,entry.seekGeneration==generation else {return}
                entry.seekPending=false;self.update()
            }
        }
    }
    private func managedResource(for id:UUID)->MediaFrameResource? {entries[id]?.currentManagedResource}
    /// Continuous legacy pulls hold one latest frame. Explicit seeks clear it;
    /// managed modes accept only the requested sample generation/PTS interval.
    func texture(for id:UUID)->MTLTexture? {
        guard let entry=entries[id] else {return virtualSources?.frameResource(for:id)?.texture}
        if entry.asset.kind == "external-video" { return externalTexture?(entry.asset.path) }
        if entry.asset.kind=="image" {
            entry.lastImagePull=ProcessInfo.processInfo.systemUptime
            if entry.imageOwner==nil {prepareImage(entry)}
        }
        if entry.sequence != nil || (entry.asset.kind=="video" && entry.asset.playback != nil) {
            if entry.asset.kind=="video",!(videoDemandIDs?.contains(id) ?? true) {return nil}
            guard let sample=sample(entry) else {return nil}
            let resource:MediaFrameResource?
            if let sequence=entry.sequence {resource=sequence.resource(at:sample.position);entry.acceptedPTS=resource == nil ? nil : Double(Int(floor(sample.position*(entry.asset.sequence?.fps ?? 30))))/(entry.asset.sequence?.fps ?? 30)}
            else {
                guard let cache else {return nil}
                if entry.decodeSlot==nil {
                    guard let slot=managedSlots.first(where:{$0.owner==nil}) else {errorMessages[id]="Ordinary source decoder limit (8) reached";return nil}
                    entry.decodeSlot=slot
                }
                var clip=MontageClip(id:entry.decodeClipID,assetID:id,duration:entry.durationSeconds,
                    sourceIn:entry.asset.playback?.trimIn ?? 0,sourceOut:min(entry.durationSeconds,entry.asset.playback?.trimOut ?? entry.durationSeconds),rate:max(0.001,abs(entry.asset.playback?.rate ?? 1)))
                clip.loop=false
                let epoch=MontageVideoEpoch(document:document,assetRevision:entry.revision,url:entry.url,clip:clip,montageCycle:Int(sample.discontinuityIndex),clipCycle:0)
                entry.decodeSlot?.request(owner:id,epoch:epoch,time:sample.position,playing:sourcePlaying(entry),serial:entry.seekGeneration,backward:sample.direction<0)
                resource=entry.decodeSlot?.acceptedResource(cache:cache)
                entry.acceptedPTS=resource == nil ? nil : entry.decodeSlot?.frame?.pts
                if resource==nil {errorMessages[id]=entry.decodeSlot?.message ?? "Waiting for source frame"} else {errorMessages[id]=entry.routedAudio?.diagnostic}
            }
            entry.currentManagedResource=resource;entry.texture=resource?.texture
            entry.cvTexture=resource?.wrappers.first;entry.pixelBuffer=resource?.buffers.first
            if let texture=resource?.texture {
                let identity=ObjectIdentifier(texture)
                if entry.lastDecodedIdentity != identity || entry.lastDecodedGeneration != entry.seekGeneration {
                    entry.decodedFrames+=1;entry.lastDecodedIdentity=identity;entry.lastDecodedGeneration=entry.seekGeneration
                }
            }
            return resource?.texture
        }
        if let pixelBuffer=entry.camera?.takeLatest() {updateTexture(entry:entry,pixelBuffer:pixelBuffer)}
        if let output=entry.videoOutput,!entry.seekPending {
            let time=output.itemTime(forHostTime:CACurrentMediaTime())
            var display=CMTime.invalid
            if output.hasNewPixelBuffer(forItemTime:time),let buffer=output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&display) {
                guard display.isNumeric,display.seconds.isFinite else {entry.rejectedFrames+=1;return entry.texture}
                entry.acceptedPTS=display.seconds;entry.decodedFrames+=1
                updateTexture(entry:entry,pixelBuffer:buffer)
            }
        }
        return entry.texture
    }

    private func updateTexture(entry: Entry, pixelBuffer: CVPixelBuffer) {
        guard let cache else { return }
        let width=CVPixelBufferGetWidth(pixelBuffer),height=CVPixelBufferGetHeight(pixelBuffer)
        guard width>0,height>0,width<=8192,height<=8192,CVPixelBufferGetBytesPerRow(pixelBuffer)*height<=64*1024*1024 else {errorMessages[entry.asset.id]="Decoded frame exceeds 8192 per axis or 64 MiB payload";return}
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        if result == kCVReturnSuccess, let cvTexture {
            entry.cvTexture = cvTexture
            entry.pixelBuffer = pixelBuffer
            entry.texture = CVMetalTextureGetTexture(cvTexture)
        }
    }
}
#endif
