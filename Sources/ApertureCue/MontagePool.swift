#if os(macOS)
import Foundation
import Metal
import CoreVideo
import MappingCore

/// A fixed decoder slot coalesces requests. Leases invalidate old async work;
/// readers are never cancelled concurrently from the presentation thread.
private final class MontageVideoSlot {
    let decoder=MontageVideoDecoder(),lease=MontageDecodeLease()
    private(set) var owner:UUID?
    private(set) var generation:UInt64=0
    private(set) var frame:MontageDecodedFrame?
    private(set) var message=""
    private(set) var videoEnd=0.0
    private var epoch:MontageVideoEpoch?
    private var serial:UInt64=0
    private var requestedTime=0.0,playing=false
    private var pending:MontageDecodeRequest?
    private var working=false,wantsClear=false,failed=false
    private var resource:MediaFrameResource?
    private var resourceFrame:MontageDecodedFrame?
    func clear() {
        guard owner != nil || epoch != nil else {return}
        generation=lease.advance();owner=nil;epoch=nil;pending=nil;frame=nil;resource=nil;resourceFrame=nil;message="";videoEnd=0;failed=false;wantsClear=true
        drain()
    }
    func request(owner id:UUID,epoch next:MontageVideoEpoch,time:Double,playing:Bool,serial:UInt64) {
        let changed=owner != id || epoch != next || self.serial != serial || (!playing && abs(time-requestedTime)>1e-9) || time<requestedTime-1e-8
        if changed {generation=lease.advance();frame=nil;resource=nil;resourceFrame=nil;failed=false;message="Loading video clip"}
        owner=id;epoch=next;self.serial=serial;self.playing=playing;requestedTime=time;wantsClear=false
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
    func acceptedResource(cache:CVMetalTextureCache)->MediaFrameResource? {
        guard let frame,let epoch else {return nil}
        let exact=requestedTime>=frame.pts-1e-9 && requestedTime<frame.end
        // Continuous decode may lag by at most120ms of show time. Paused frames
        // must cover the exact requested source position; cuts never reuse one.
        let lag=playing && frame.allowLag && requestedTime>=frame.pts && requestedTime-frame.end<=0.12*epoch.clip.rate
        guard (exact || lag),frame.end>epoch.clip.sourceIn,frame.pts<epoch.clip.sourceOut else {return nil}
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

/// Assignable virtual source frames. Decoder count is fixed at eight, with one
/// in-flight operation and one coalesced pending request per slot. Images share
/// the ordinary immutable texture cache. All published frames are main-thread.
final class MontagePool:VirtualMediaFrames {
    static let maximumVideoDecoders=8
    private weak var media:MediaPool?
    private let device:MTLDevice
    private var cache:CVMetalTextureCache?
    private let slots=(0..<maximumVideoDecoders).map {_ in MontageVideoSlot()}
    private var document=UUID()
    private var program:MontageProgram?
    private var definitions:[MediaMontage]=[],assets:[MediaAsset]=[]
    private var known:[UUID:MediaMontage]=[:],fingerprints:[UUID:String]=[:],revisions:[UUID:UUID]=[:]
    private var frames:[UUID:MediaFrameResource]=[:],skipIDs=Set<UUID>()
    private(set) var diagnostics:[UUID:String]=[:]
    private(set) var samples:[UUID:MontageSample]=[:]
    private let black:MTLTexture,transparent:MTLTexture
    init(device:MTLDevice,media:MediaPool) {
        self.device=device;self.media=media
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:1,height:1,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage = .shaderRead
        black=device.makeTexture(descriptor:descriptor)!;transparent=device.makeTexture(descriptor:descriptor)!
        var opaque:[UInt8]=[0,0,0,255],clear:[UInt8]=[0,0,0,0]
        black.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&opaque,bytesPerRow:4)
        transparent.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&clear,bytesPerRow:4)
        CVMetalTextureCacheCreate(kCFAllocatorDefault,nil,device,nil,&cache)
    }
    var activeVideoDecoderCount:Int {slots.filter {$0.owner != nil}.count}
    var decoderSlotCount:Int {slots.count}
    func reset() {
        document=UUID();slots.forEach {$0.clear()};program=nil;definitions=[];assets=[];known=[:];fingerprints=[:];revisions=[:];frames=[:];skipIDs=[];diagnostics=[:];samples=[:]
    }
    func reconcile(montages:[MediaMontage],assets:[MediaAsset],baseURL:URL)throws {
        var keys:[UUID:String]=[:]
        for asset in assets where asset.kind=="image" || asset.kind=="video" {
            let url=asset.path.hasPrefix("/") ? URL(fileURLWithPath:asset.path) : baseURL.appendingPathComponent(asset.path)
            let attributes=try? FileManager.default.attributesOfItem(atPath:url.path)
            keys[asset.id]=url.standardizedFileURL.path+"|"+asset.kind+"|"+String(describing:attributes?[.modificationDate])+"|"+String(describing:attributes?[.size])
        }
        guard montages != definitions || assets != self.assets || keys != fingerprints else {return}
        let next=try MontageProgram(montages:montages,assets:assets)
        for (id,key) in keys where key != fingerprints[id] {revisions[id]=UUID()}
        revisions=revisions.filter {keys[$0.key] != nil}
        program=next;definitions=montages;self.assets=assets;known=Dictionary(uniqueKeysWithValues:montages.map {($0.id,$0)})
        fingerprints=keys;frames=[:];skipIDs=[];diagnostics=[:];samples=[:]
        slots.filter {slot in slot.owner.map {known[$0]==nil} ?? false}.forEach {$0.clear()}
    }
    func invalidateAsset(_ id:UUID) {
        revisions[id]=UUID()
        for montage in definitions where montage.clips.contains(where:{$0.assetID==id}) {frames.removeValue(forKey:montage.id)}
    }
    func update(time:Double,playing:Bool,used:Set<UUID>,serial:UInt64,baseURL:URL) {
        precondition(Thread.isMainThread)
        frames=[:];skipIDs=[];diagnostics=[:];samples=[:]
        guard let program else {return}
        let selected=used.filter {known[$0] != nil}.sorted {$0.uuidString<$1.uuidString}
        for id in selected {
            do {if let sample=try program.sample(id:id,time:time) {samples[id]=sample}}
            catch {diagnostics[id]=error.localizedDescription}
        }
        let videos=selected.filter {samples[$0]?.asset?.kind=="video"}
        let admitted=Set(videos.prefix(Self.maximumVideoDecoders))
        for slot in slots where slot.owner.map({!admitted.contains($0)}) ?? false {slot.clear()}
        for id in selected {
            guard let definition=known[id],let sample=samples[id],let clip=sample.clip,let asset=sample.asset else {
                fallback(id,message:diagnostics[id] ?? "");continue
            }
            if asset.kind=="image" {
                if let resource=media?.frameResources(for:[asset.id]),let texture=resource.textures[asset.id] {
                    frames[id]=MediaFrameResource(texture:texture,wrappers:resource.retained,buffers:resource.buffers)
                } else {fallback(id,message:media?.errorMessages[asset.id] ?? "Loading image clip")}
            } else {
                guard admitted.contains(id),let cache,let target=sample.sourceTime else {fallback(id,message:"Montage video decoder limit (8) reached");continue}
                guard let slot=slots.first(where:{$0.owner==id}) ?? slots.first(where:{$0.owner==nil}) else {fallback(id,message:"Montage decoder unavailable");continue}
                let url=asset.path.hasPrefix("/") ? URL(fileURLWithPath:asset.path) : baseURL.appendingPathComponent(asset.path)
                let epoch=MontageVideoEpoch(document:document,assetRevision:revisions[asset.id] ?? document,url:url,clip:clip,montageCycle:sample.montageCycle,clipCycle:sample.clipCycle)
                slot.request(owner:id,epoch:epoch,time:target,playing:playing,serial:serial)
                if let resource=slot.acceptedResource(cache:cache) {frames[id]=resource}
                else {fallback(id,message:slot.message.isEmpty ? "Waiting for current clip frame" : slot.message)}
            }
            _=definition
        }
    }
    private func fallback(_ id:UUID,message:String) {
        let skip=known[id]?.gapMode == .skip
        if skip {skipIDs.insert(id)}
        frames[id]=MediaFrameResource(texture:skip ? transparent : black)
        if !message.isEmpty {diagnostics[id]=message}
    }
    func apply(to surfaces:[Surface])->[Surface] {
        surfaces.map {surface in
            guard let id=surface.mediaID,skipIDs.contains(id) else {return surface}
            var hidden=surface;hidden.enabled=false;return hidden
        }
    }
    func frameResource(for id:UUID)->MediaFrameResource? {
        guard let montage=known[id] else {return nil}
        return frames[id] ?? MediaFrameResource(texture:montage.gapMode == .skip ? transparent : black)
    }
    func presentationTime(for id:UUID)->Double? {slots.first {$0.owner==id}?.frame?.pts}
    func frameEnd(for id:UUID)->Double? {slots.first {$0.owner==id}?.frame?.end}
    func frameGeneration(for id:UUID)->UInt64? {slots.first {$0.owner==id}?.generation}
    func videoExtent(for id:UUID)->Double? {slots.first {$0.owner==id}?.videoEnd}
}
#endif
