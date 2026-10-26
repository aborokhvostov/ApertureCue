#if os(macOS)
import AppKit
import AVFoundation
import CoreVideo
import Metal
import MetalKit
import QuartzCore
import MappingCore

/// Main-thread coordinator. Image I/O and texture creation use a serial worker;
/// AVFoundation owns its bounded decoder queues. Each movie retains one video
/// output frame and each image retains one texture, shared by all output views.
final class MediaPool {
    private final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "org.aperturecue.camera", qos: .userInitiated)
        private let lock = NSLock()
        private var latest: CVPixelBuffer?
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
            lock.lock(); latest = buffer; lock.unlock()
        }

        func takeLatest() -> CVPixelBuffer? {
            lock.lock(); defer { lock.unlock() }
            let result = latest; latest = nil
            return result
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            let session = session
            queue.async { session.stopRunning() }
        }
    }

    private final class Entry {
        let asset: MediaAsset
        let url: URL
        var texture: MTLTexture?
        var cvTexture: CVMetalTexture?
        var player: AVPlayer?
        var videoOutput: AVPlayerItemVideoOutput?
        var endObserver: NSObjectProtocol?
        var statusObserver: NSKeyValueObservation?
        var camera: CameraCapture?
        var seekGeneration: UInt64 = 0
        init(_ asset: MediaAsset, url: URL) { self.asset = asset; self.url = url }
        deinit {
            player?.pause()
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

    init(device: MTLDevice) {
        self.device = device
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
    func playbackTime(for id: UUID) -> Double {
        let value = entries[id]?.player?.currentTime().seconds ?? 0
        return value.isFinite ? max(0, value) : 0
    }
    func duration(for id: UUID) -> Double {
        let value = entries[id]?.player?.currentItem?.duration.seconds ?? 0
        return value.isFinite ? value : 0
    }

    /// Acquire each source once for an entire composition. The returned wrappers
    /// belong to exactly these textures and must survive the submitted GPU work.
    func frameResources(for ids: Set<UUID>) -> (textures: [UUID: MTLTexture], retained: [CVMetalTexture]) {
        precondition(Thread.isMainThread)
        var textures: [UUID: MTLTexture] = [:]
        var retained: [CVMetalTexture] = []
        for id in ids {
            if let texture = texture(for: id) {
                textures[id] = texture
                if let wrapper = entries[id]?.cvTexture { retained.append(wrapper) }
            }
        }
        return (textures, retained)
    }

    /// Explicit relink can restore a file at the same path as a failed entry.
    func reloadAsset(id: UUID, assets: [MediaAsset], baseURL: URL) {
        precondition(Thread.isMainThread)
        entries.removeValue(forKey: id)
        errorMessages.removeValue(forKey: id)
        reconcile(assets: assets, baseURL: baseURL)
    }

    func reconcile(assets: [MediaAsset], baseURL: URL) {
        precondition(Thread.isMainThread)
        let ids = Set(assets.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        errorMessages = errorMessages.filter { ids.contains($0.key) }
        for asset in assets {
            let url = asset.path.hasPrefix("/") ? URL(fileURLWithPath: asset.path) : baseURL.appendingPathComponent(asset.path)
            if let existing = entries[asset.id], existing.url == url,
               existing.asset.kind == asset.kind,
               existing.asset.loop == asset.loop {
                existing.player?.volume = Float(max(0, min(1, asset.volume)))
                continue
            }
            let entry = Entry(asset, url: url)
            entries[asset.id] = entry
            errorMessages.removeValue(forKey: asset.id)
            if asset.kind == "camera" {
                prepareCamera(entry)
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                errorMessages[asset.id] = "Missing media: \(url.lastPathComponent)"
                continue
            }
            switch asset.kind {
            case "video": prepareVideo(entry)
            case "image": prepareImage(entry)
            default: errorMessages[asset.id] = "Unsupported source type: \(asset.kind)"
            }
        }
        onChange?()
    }

    private func prepareCamera(_ entry: Entry) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            errorMessages[entry.asset.id] = "Camera access is not authorized; use Add Camera to grant access"
            return
        }
        let camera = CameraCapture()
        entry.camera = camera
        camera.start(deviceID: entry.asset.path) { [weak self, weak entry] message in
            DispatchQueue.main.async {
                guard let self, let entry, self.entries[entry.asset.id] === entry else { return }
                self.errorMessages[entry.asset.id] = message
                self.onChange?()
            }
        }
    }

    private func prepareImage(_ entry: Entry) {
        let loader = MTKTextureLoader(device: device)
        loaderQueue.async { [weak self, weak entry] in
            guard let entry else { return }
            do {
                let texture = try loader.newTexture(URL: entry.url, options: [
                    .origin: MTKTextureLoader.Origin.topLeft,
                    .SRGB: false,
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
                ])
                DispatchQueue.main.async {
                    guard let self, self.entries[entry.asset.id] === entry else { return }
                    entry.texture = texture
                    self.onChange?()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.entries[entry.asset.id] === entry else { return }
                    self.errorMessages[entry.asset.id] = "Image decode failed: \(error.localizedDescription)"
                    self.onChange?()
                }
            }
        }
    }

    private func prepareVideo(_ entry: Entry) {
        let item = AVPlayerItem(url: entry.url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.volume = Float(max(0, min(1, entry.asset.volume)))
        entry.player = player
        entry.videoOutput = output
        entry.statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self, weak entry] item, _ in
            DispatchQueue.main.async {
                guard let self, let entry, self.entries[entry.asset.id] === entry else { return }
                if item.status == .failed {
                    self.errorMessages[entry.asset.id] = "Video decode failed: \(item.error?.localizedDescription ?? "unknown codec")"
                } else if item.status == .readyToPlay {
                    self.seek(entry: entry, toShowTime: self.currentTime)
                }
                self.onChange?()
            }
        }
        entry.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak entry] _ in
            guard let self, let entry, self.entries[entry.asset.id] === entry, entry.asset.loop,
                  let duration = entry.player?.currentItem?.duration.seconds, duration.isFinite, duration > 0,
                  self.playbackTime(for: entry.asset.id) >= duration - 1.0 / 120.0 else { return }
            self.seek(entry: entry, toShowTime: 0)
        }
    }

    func play() {
        precondition(Thread.isMainThread)
        guard !isPlaying else { return }
        clockAnchor = CACurrentMediaTime()
        isPlaying = true
        for entry in entries.values { entry.player?.play() }
    }

    func pause() {
        precondition(Thread.isMainThread)
        heldTime = currentTime
        isPlaying = false
        for entry in entries.values { entry.player?.pause() }
    }

    func seek(to seconds: Double) {
        precondition(Thread.isMainThread)
        guard seconds.isFinite else { return }
        heldTime = max(0, min(Self.maximumTransportTime, seconds))
        clockAnchor = CACurrentMediaTime()
        for entry in entries.values { seek(entry: entry, toShowTime: heldTime) }
    }

    private func seek(entry: Entry, toShowTime seconds: Double) {
        guard let player = entry.player else { return }
        var position = max(0, min(Self.maximumTransportTime, seconds))
        if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            position = entry.asset.loop ? position.truncatingRemainder(dividingBy: duration) : min(position, duration)
        }
        entry.seekGeneration &+= 1
        let generation = entry.seekGeneration
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak entry] finished in
            DispatchQueue.main.async {
                guard let self, let entry, finished, self.entries[entry.asset.id] === entry,
                      entry.seekGeneration == generation else { return }
                if self.isPlaying { entry.player?.play() } else { entry.player?.pause() }
            }
        }
    }

    /// Retains the latest texture if a decoder frame is late; no queue grows.
    func texture(for id: UUID) -> MTLTexture? {
        guard let entry = entries[id] else { return nil }
        if let pixelBuffer = entry.camera?.takeLatest() { updateTexture(entry: entry, pixelBuffer: pixelBuffer) }
        if let output = entry.videoOutput {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: time),
               let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                updateTexture(entry: entry, pixelBuffer: pixelBuffer)
            }
        }
        return entry.texture
    }

    private func updateTexture(entry: Entry, pixelBuffer: CVPixelBuffer) {
        guard let cache else { return }
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        if result == kCVReturnSuccess, let cvTexture {
            entry.cvTexture = cvTexture
            entry.texture = CVMetalTextureGetTexture(cvTexture)
        }
    }
}
#endif
