#if os(macOS)
import Foundation
import Metal
import CoreVideo
import MappingCore

/// A fixed decoder slot coalesces requests. Leases invalidate old async work;
/// readers are never cancelled concurrently from the presentation thread.
final class MontageVideoSlot {
    let decoder=MontageVideoDecoder(),lease=MontageDecodeLease()
    private(set) var owner:UUID?
    private(set) var generation:UInt64=0
    private(set) var frame:MontageDecodedFrame?
    private(set) var message=""
    private(set) var videoEnd=0.0
    private var epoch:MontageVideoEpoch?
    private var serial:UInt64=0
    private var requestedTime=0.0,playing=false,backward=false
    private var pending:MontageDecodeRequest?
    private var working=false,wantsClear=false,failed=false
    private var resource:MediaFrameResource?
    private var resourceFrame:MontageDecodedFrame?
    func clear() {
        guard owner != nil || epoch != nil else {return}
        generation=lease.advance();owner=nil;epoch=nil;pending=nil;frame=nil;resource=nil;resourceFrame=nil;message="";videoEnd=0;failed=false;wantsClear=true
        drain()
    }
    func request(owner id:UUID,epoch next:MontageVideoEpoch,time:Double,playing:Bool,serial:UInt64,backward:Bool=false) {
        let changed=owner != id || epoch != next || self.serial != serial || (!playing && abs(time-requestedTime)>1e-9) || self.backward != backward || (!backward && time<requestedTime-1e-8)
        if changed {generation=lease.advance();frame=nil;resource=nil;resourceFrame=nil;failed=false;message="Loading video clip"}
        owner=id;epoch=next;self.serial=serial;self.playing=playing;self.backward=backward;requestedTime=time;wantsClear=false
        if let frame,time>=frame.pts-1e-9,time<frame.end {return}
        if failed && !changed {return}
        pending=MontageDecodeRequest(epoch:next,time:time,generation:generation,lease:lease);drain()
    }
    private func drain() {
        guard !working else {return}
        if let request=pending {
            pending=nil;working=true;let worker=decoder
            Task { @MainActor [weak self] in
                let result=await worker.decode(request)
                guard let self else {return};self.working=false
                if self.owner != nil,self.generation==request.generation,self.epoch==request.epoch {
                    self.frame=result.frame;self.videoEnd=result.videoEnd;self.message=result.message
                    self.resource=nil;self.resourceFrame=nil
                    self.failed=result.frame==nil && !result.needsMore && result.videoEnd==0
                    if result.needsMore,self.pending==nil {self.pending=request}
                }
                self.drain()
            }
        } else if wantsClear {
            wantsClear=false;working=true;let worker=decoder
            Task { @MainActor [weak self] in
                await worker.clear()
                guard let self else {return};self.working=false;self.drain()
            }
        }
    }
    /// A late reverse sample may only extend into its known contiguous PTS run.
    /// It cannot bridge a leading/internal gap, and paused seeks remain exact.
    static func permitsFrame(_ frame:MontageDecodedFrame,time:Double,playing:Bool,backward:Bool,rate:Double)->Bool {
        let exact=time>=frame.pts-1e-9 && time<frame.end
        let forwardLag=playing && !backward && frame.allowLag && time>=frame.pts && time-frame.end<=0.12*rate
        let reverseLag=playing && backward && time>=frame.reverseLagStart-1e-9 && time<frame.end && frame.pts-time<=0.12*rate
        return exact || forwardLag || reverseLag
    }
    func acceptedResource(cache:CVMetalTextureCache)->MediaFrameResource? {
        guard let frame,let epoch else {return nil}
        guard Self.permitsFrame(frame,time:requestedTime,playing:playing,backward:backward,rate:abs(epoch.clip.rate)),frame.end>epoch.clip.sourceIn,frame.pts<epoch.clip.sourceOut else {return nil}
        if resourceFrame === frame {return resource}
        var wrapper:CVMetalTexture?
        let buffer=frame.buffer
        let status=CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,buffer,nil,.bgra8Unorm,
            CVPixelBufferGetWidth(buffer),CVPixelBufferGetHeight(buffer),0,&wrapper)
        guard status==kCVReturnSuccess,let wrapper,let texture=CVMetalTextureGetTexture(wrapper),
              let uv=try? MediaUVTransform.video(frame.transform,size:frame.naturalSize,pixelWidth:CVPixelBufferGetWidth(buffer),pixelHeight:CVPixelBufferGetHeight(buffer)) else {
            message="Video texture/presentation transform unavailable";return nil
        }
        let accepted=MediaFrameResource(texture:texture,wrappers:[wrapper],buffers:[buffer],uv:uv)
        resource=accepted;resourceFrame=frame;return accepted
    }
}

/// A visual decoder lease belongs to a clip, allowing two clips of the same
/// file to coexist without seeking either the other clip or the ordinary player.
final class MontagePool: VirtualMediaFrames {
    static let maximumVideoDecoders = 8
    static let maximumAudioVoices = 8

    private weak var media: MediaPool?
    private var cache: CVMetalTextureCache?
    private let slots = (0..<maximumVideoDecoders).map { _ in MontageVideoSlot() }
    private let audioFactory: () -> MediaAudioPlayer
    private var audioVoices: [UUID: MontageAudioVoice] = [:]
    private var document = UUID()
    private var program: MontageProgram?
    private var definitions: [MediaMontage] = []
    private var assets: [MediaAsset] = []
    private var known: [UUID: MediaMontage] = [:]
    private var fingerprints: [UUID: String] = [:]
    private var revisions: [UUID: UUID] = [:]
    private var frames: [UUID: MediaFrameResource] = [:]
    private var skipIDs = Set<UUID>()
    private(set) var diagnostics: [UUID: String] = [:]
    private(set) var samples: [UUID: MontageSample] = [:]
    private let black: MTLTexture
    private let transparent: MTLTexture

    init(device: MTLDevice, media: MediaPool, audioFactory: @escaping () -> MediaAudioPlayer = { MediaAudioPlayer() }) {
        self.media = media
        self.audioFactory = audioFactory
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        black = device.makeTexture(descriptor: descriptor)!
        transparent = device.makeTexture(descriptor: descriptor)!
        var opaque: [UInt8] = [0, 0, 0, 255]
        var clear: [UInt8] = [0, 0, 0, 0]
        black.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &opaque, bytesPerRow: 4)
        transparent.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &clear, bytesPerRow: 4)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    }

    var activeVideoDecoderCount: Int { slots.filter { $0.owner != nil }.count }
    var decoderSlotCount: Int { slots.count }
    var activeAudioVoiceCount: Int { audioVoices.count }

    func reset() {
        document = UUID()
        slots.forEach { $0.clear() }
        audioVoices.values.forEach { $0.invalidate() }
        audioVoices.removeAll()
        program = nil
        definitions = []
        assets = []
        known = [:]
        fingerprints = [:]
        revisions = [:]
        clearFrames()
    }

    func reconcile(montages: [MediaMontage], assets: [MediaAsset], baseURL: URL) throws {
        var keys: [UUID: String] = [:]
        for asset in assets where ["image", "video", "audio"].contains(asset.kind) {
            let url = sourceURL(asset, baseURL: baseURL)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            keys[asset.id] = url.standardizedFileURL.path + "|" + asset.kind
                + "|" + String(describing: attributes?[.modificationDate])
                + "|" + String(describing: attributes?[.size])
        }
        guard montages != definitions || assets != self.assets || keys != fingerprints else { return }
        let next = try MontageProgram(montages: montages, assets: assets)
        for (id, key) in keys where key != fingerprints[id] { revisions[id] = UUID() }
        revisions = revisions.filter { keys[$0.key] != nil }
        program = next
        definitions = montages
        self.assets = assets
        known = Dictionary(uniqueKeysWithValues: montages.map { ($0.id, $0) })
        fingerprints = keys
        clearFrames()
        let clips = Set(montages.flatMap(\.clips).map(\.id))
        for slot in slots where slot.owner.map({ !clips.contains($0) }) ?? false { slot.clear() }
        releaseAudio(except: clips)
    }

    func invalidateAsset(_ id: UUID) {
        revisions[id] = UUID()
        for montage in definitions where montage.clips.contains(where: { $0.assetID == id }) {
            frames.removeValue(forKey: montage.id)
        }
        for (clipID, voice) in audioVoices where voice.assetID == id {
            voice.invalidate()
            audioVoices.removeValue(forKey: clipID)
        }
    }

    private func clearFrames() {
        frames = [:]
        skipIDs = []
        diagnostics = [:]
        samples = [:]
    }

    func update(time: Double, playing: Bool, used: Set<UUID>, serial: UInt64, baseURL: URL) {
        precondition(Thread.isMainThread)
        clearFrames()
        guard let program else { return }
        let selected = used.filter { known[$0] != nil }.sorted { $0.uuidString < $1.uuidString }
        for id in selected {
            do { samples[id] = try program.sample(id: id, time: time) }
            catch { note(id, error.localizedDescription) }
        }

        let videos = selected.flatMap { id in samples[id]?.visual.filter { $0.asset.kind == "video" } ?? [] }
        let admitted = Set(videos.prefix(Self.maximumVideoDecoders).map(\.clip.id))
        for slot in slots where slot.owner.map({ !admitted.contains($0) }) ?? false { slot.clear() }

        let audio = selected.flatMap { id in samples[id]?.audio ?? [] }
        let audioAdmitted = Set(audio.prefix(Self.maximumAudioVoices).map(\.clip.id))
        releaseAudio(except: audioAdmitted)

        for id in selected {
            guard let sample = samples[id] else { continue }
            publishVisual(sample, admitted: admitted, playing: playing, serial: serial, baseURL: baseURL)
            for leg in sample.audio {
                guard audioAdmitted.contains(leg.clip.id) else {
                    note(id, "Montage audio voice limit (8) reached")
                    continue
                }
                let voice = audioVoices[leg.clip.id] ?? MontageAudioVoice(factory: audioFactory)
                audioVoices[leg.clip.id] = voice
                let revision = revisions[leg.asset.id] ?? document
                if let message = voice.update(leg, url: sourceURL(leg.asset, baseURL: baseURL), revision: revision,
                                              montageCycle: sample.montageCycle, serial: serial, playing: playing) {
                    note(id, message)
                }
            }
        }
    }

    private func publishVisual(_ sample: MontageSample, admitted: Set<UUID>, playing: Bool, serial: UInt64, baseURL: URL) {
        let id = sample.montageID
        let empty = fallbackFrame(sample.gapMode)
        let legs = sample.visual.map {
            visualFrame($0, sample: sample, admitted: admitted, playing: playing, serial: serial, baseURL: baseURL)
        }
        let first = legs.first.flatMap { $0 }
        guard legs.count == 2 else {
            if let frame = first { frames[id] = frame }
            else {
                frames[id] = empty
                if sample.gapMode == .skip { skipIDs.insert(id) }
            }
            return
        }
        // A missing leg contributes the montage gap color. In Skip mode its
        // transparency preserves the other leg and the layer below the montage.
        let weight = sample.visual[1].weight
        let second = legs[1]
        if sample.gapMode == .skip && ((first == nil && second == nil) || (first == nil && weight == 0)) {
            skipIDs.insert(id)
        }
        var combined = first ?? empty
        if weight > 0 {
            let incoming = second ?? empty
            combined.blend = MediaFrameBlend(texture: incoming.texture, uv: incoming.uv, weight: Float(weight))
            combined.wrappers += incoming.wrappers
            combined.buffers += incoming.buffers
            combined.owners += incoming.owners
        }
        frames[id] = combined
    }

    private func visualFrame(_ leg: MontageLeg, sample: MontageSample, admitted: Set<UUID>, playing: Bool,
                             serial: UInt64, baseURL: URL) -> MediaFrameResource? {
        let id = sample.montageID
        let asset = leg.asset
        if asset.kind == "image" {
            guard let resource = media?.frameResources(for: [asset.id]),
                  let texture = resource.textures[asset.id] else {
                note(id, media?.errorMessages[asset.id] ?? "Loading image clip")
                return nil
            }
            return MediaFrameResource(texture: texture, wrappers: resource.retained, buffers: resource.buffers,
                                      uv: resource.uv[asset.id] ?? .identity, owners: resource.owners)
        }
        let clip = leg.clip
        guard admitted.contains(clip.id), let cache else {
            note(id, "Montage video decoder limit (8) reached")
            return nil
        }
        guard let slot = slots.first(where: { $0.owner == clip.id }) ?? slots.first(where: { $0.owner == nil }) else {
            note(id, "Montage decoder unavailable")
            return nil
        }
        let epoch = MontageVideoEpoch(document: document, assetRevision: revisions[asset.id] ?? document,
                                      url: sourceURL(asset, baseURL: baseURL), clip: clip,
                                      montageCycle: sample.montageCycle, clipCycle: leg.clipCycle)
        slot.request(owner: clip.id, epoch: epoch, time: leg.sourceTime, playing: playing,
                     serial: serial, backward: clip.rate < 0)
        if let frame = slot.acceptedResource(cache: cache) { return frame }
        note(id, slot.message.isEmpty ? "Waiting for current clip frame" : slot.message)
        return nil
    }

    private func releaseAudio(except retained: Set<UUID>) {
        for (id, voice) in audioVoices where !retained.contains(id) {
            voice.invalidate()
            audioVoices.removeValue(forKey: id)
        }
    }

    private func note(_ id: UUID, _ message: String) {
        if diagnostics[id] == nil { diagnostics[id] = message }
    }

    private func sourceURL(_ asset: MediaAsset, baseURL: URL) -> URL {
        asset.path.hasPrefix("/") ? URL(fileURLWithPath: asset.path) : baseURL.appendingPathComponent(asset.path)
    }

    private func fallbackFrame(_ gapMode: MontageGapMode) -> MediaFrameResource {
        MediaFrameResource(texture: gapMode == .skip ? transparent : black)
    }

    func apply(to surfaces: [Surface]) -> [Surface] {
        surfaces.map { surface in
            guard let id = surface.mediaID, skipIDs.contains(id) else { return surface }
            var hidden = surface
            hidden.enabled = false
            return hidden
        }
    }

    func frameResource(for id: UUID) -> MediaFrameResource? {
        guard let montage = known[id] else { return nil }
        return frames[id] ?? fallbackFrame(montage.gapMode)
    }

    private func primarySlot(_ id: UUID) -> MontageVideoSlot? {
        guard let clip = samples[id]?.clip else { return nil }
        return slots.first { $0.owner == clip.id }
    }

    func presentationTime(for id: UUID) -> Double? { primarySlot(id)?.frame?.pts }
    func presentationTime(forClip id: UUID) -> Double? { slots.first { $0.owner == id }?.frame?.pts }
    func frameEnd(for id: UUID) -> Double? { primarySlot(id)?.frame?.end }
    func frameGeneration(for id: UUID) -> UInt64? { primarySlot(id)?.generation }
    func videoExtent(for id: UUID) -> Double? { primarySlot(id)?.videoEnd }
}
#endif
