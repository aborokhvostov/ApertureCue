#if os(macOS)
import Foundation
import ImageIO
import Metal
import MetalKit
import MappingCore

/// Shared retained image payload budget, including in-flight GPU owners.
/// Decode/transient framework overhead is not represented as resident memory.
final class MediaImageBudget: @unchecked Sendable {
    static let shared=MediaImageBudget()
    let maximumBytes=64*1024*1024
    private let lock=NSLock()
    private var used=0
    var usedBytes:Int {lock.lock();defer {lock.unlock()};return used}
    final class Lease {
        let bytes:Int
        private let budget:MediaImageBudget
        init(bytes:Int,budget:MediaImageBudget) {self.bytes=bytes;self.budget=budget}
        deinit {budget.release(bytes)}
    }
    func reserve(_ bytes:Int)->Lease? {
        lock.lock();defer {lock.unlock()}
        guard bytes>0,bytes<=maximumBytes-used else {return nil}
        used+=bytes;return Lease(bytes:bytes,budget:self)
    }
    private func release(_ bytes:Int) {lock.lock();used-=bytes;lock.unlock()}
}
enum MediaImageFailure:LocalizedError {
    case budgetOccupied
    var errorDescription:String? {"Retained image payload budget (64 MiB) is occupied"}
}
final class MediaLoadedImage: @unchecked Sendable {
    let texture:MTLTexture
    let lease:MediaImageBudget.Lease
    init(texture:MTLTexture,lease:MediaImageBudget.Lease) {self.texture=texture;self.lease=lease}
    static func load(url:URL,device:MTLDevice)throws->MediaLoadedImage {
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 128*1024*1024 else {throw ProjectError.invalid("image must be a regular file of at most 128 MiB")}
        guard let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary) else {throw ProjectError.invalid("unsupported or corrupt image data")}
        guard let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any] else {throw ProjectError.invalid("image header is unavailable or corrupt")}
        guard let width=(properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height=(properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width>0,height>0,width<=8192,height<=8192,width*height<=16777216 else {throw ProjectError.invalid("image dimensions exceed 8192 per axis or 16 megapixels")}
        guard let lease=MediaImageBudget.shared.reserve(width*height*4) else {throw MediaImageFailure.budgetOccupied}
        let texture=try MTKTextureLoader(device:device).newTexture(URL:url,options:[.origin:MTKTextureLoader.Origin.topLeft,.SRGB:false,.textureUsage:NSNumber(value:MTLTextureUsage.shaderRead.rawValue)])
        guard texture.width==width,texture.height==height,texture.pixelFormat == .rgba8Unorm || texture.pixelFormat == .bgra8Unorm else {throw ProjectError.invalid("image needs an 8-bit RGBA/BGRA decode")}
        return MediaLoadedImage(texture:texture,lease:lease)
    }
}

/// One worker operation and one coalesced request per source. At most three
/// exact frame images are cached; all sequences share the 64 MiB lease budget.
final class MediaImageSequence {
    private let device:MTLDevice
    private let directory:URL
    private let manifest:MediaSequenceSettings
    private let worker=DispatchQueue(label:"org.aperturecue.sequence",qos:.userInitiated)
    private var cache:[Int:MediaLoadedImage]=[:],order:[Int]=[]
    private var requested:Int?,pending:Int?,working=false
    private var generation:UInt64=0
    private var failures:[Int:String]=[:]
    private var retryAfter:[Int:Double]=[:]
    private(set) var message=""
    private(set) var loads=0
    private(set) var cacheHits=0
    private(set) var discardedCompletions=0
    var onChange:(()->Void)?
    init(device:MTLDevice,directory:URL,manifest:MediaSequenceSettings) {self.device=device;self.directory=directory;self.manifest=manifest}
    func reset() {generation &+= 1;requested=nil;pending=nil;cache.removeAll();order=[];failures=[:];retryAfter=[:];message=""}
    func resource(at seconds:Double)->MediaFrameResource? {
        guard seconds.isFinite,!manifest.frames.isEmpty else {return nil}
        let index=max(0,min(manifest.frames.count-1,Int(floor(seconds*manifest.fps))))
        if requested != index {requested=index;message="Loading sequence frame \(index+1)"}
        if let frame=cache[index] {
            order.removeAll {$0==index};order.append(index);cacheHits+=1;message=""
            return MediaFrameResource(texture:frame.texture,owners:[frame])
        }
        if let error=failures[index] {message=error;return nil}
        guard ProcessInfo.processInfo.systemUptime >= retryAfter[index,default:0] else {return nil}
        pending=index;drain();return nil
    }
    private func drain() {
        guard !working,let index=pending else {return};pending=nil
        guard cache[index]==nil,failures[index]==nil,ProcessInfo.processInfo.systemUptime>=retryAfter[index,default:0] else {return}
        while order.count>=3 {let first=order.removeFirst();cache.removeValue(forKey:first)}
        // Leave room for the next frame before reserving a large payload.
        if MediaImageBudget.shared.usedBytes>48*1024*1024 {cache.removeAll();order=[]}
        let serial=generation,url=directory.appendingPathComponent(manifest.frames[index]),device=self.device
        working=true
        worker.async { [weak self] in
            let result=Result {try MediaLoadedImage.load(url:url,device:device)}
            DispatchQueue.main.async { [weak self] in
                guard let self else {return};self.working=false
                if self.generation==serial {
                    switch result {
                    case .success(let image): self.cache[index]=image;self.order.removeAll {$0==index};self.order.append(index);self.loads+=1;if self.requested==index {self.message=""}
                    case .failure(let error):
                        if error is MediaImageFailure {self.retryAfter[index]=ProcessInfo.processInfo.systemUptime+0.1}
                        else {self.failures[index]=error.localizedDescription}
                        if self.requested==index {self.message=error.localizedDescription}
                    }
                } else {self.discardedCompletions+=1}
                self.onChange?()
                if self.pending != nil {self.drain()}
            }
        }
    }
}
#endif
