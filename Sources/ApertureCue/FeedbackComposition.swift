#if os(macOS)
import AppKit
import MetalKit
import MappingCore

final class FeedbackFrame:@unchecked Sendable {
    let textures:[UUID:MTLTexture]
    init(_ textures:[UUID:MTLTexture]) {self.textures=textures}
}
private final class WeakFeedbackFrame {
    weak var value:FeedbackFrame?
    init(_ value:FeedbackFrame){self.value=value}
}

/// One generation consists of all referenced routes. Every route reads the same
/// completed previous generation; no encoder ever samples a texture it writes.
@MainActor final class FeedbackComposition {
    private let media:MediaPool
    private let queue:MTLCommandQueue
    private var renderers:[UUID:MetalRenderer]=[:]
    private var generation:UInt64=0
    private var topology:[OutputConfig]=[]
    private(set) var frame:FeedbackFrame?=nil
    private var histories:[WeakFeedbackFrame]=[]
    var textures:[UUID:MTLTexture] {frame?.textures ?? [:]}
    private(set) var pending=false
    private(set) var completedFrames:UInt64=0
    private(set) var skippedFrames:UInt64=0
    private(set) var errorDescription=""
    var onUpdate:(()->Void)?
    init?(media:MediaPool) {
        self.media=media
        guard let q=media.device.makeCommandQueue() else {return nil};queue=q
    }
    func reset() {
        generation &+= 1;frame=nil;topology=[];renderers=[:];completedFrames=0;errorDescription=""
        histories.removeAll {$0.value==nil}
        onUpdate?()
    }
    func advance(surfaces:[Surface],outputs:[OutputConfig],groups:[SurfaceGroup],masks:[CompositionMask],materials:[MaterialDefinition],time:Double,blackout:Bool) {
        let needed=Set(surfaces.filter {$0.enabled && $0.opacity>0}.compactMap(\.feedbackOutputID))
        if needed.isEmpty {if !textures.isEmpty || !renderers.isEmpty {reset()};return}
        let routes=outputs.filter {needed.contains($0.id)}.sorted {$0.id.uuidString<$1.id.uuidString}
        guard routes.count==needed.count,routes.count<=8,routes.allSatisfy({(1...4096).contains($0.width) && (1...4096).contains($0.height)}),routes.reduce(0,{$0+$1.width*$1.height})<=16777216 else {
            reset();errorDescription="loopback supports up to eight existing routes, 4096 per axis and 16M total pixels";return
        }
        if topology != routes {
            reset();topology=routes
        }
        histories.removeAll {$0.value==nil}
        guard !pending,histories.count<4 else {skippedFrames &+= 1;return}
        guard let command=queue.makeCommandBuffer() else {return}
        let token=generation,oldFrame=frame,old=textures
        var next:[UUID:MTLTexture]=[:],retained:[MediaFrameResources]=[]
        do {
            for output in routes {
                let renderer:MetalRenderer
                if let existing=renderers[output.id] {renderer=existing}
                else {
                    let view=MTKView(frame:NSRect(x:0,y:0,width:1,height:1),device:media.device)
                    guard let created=MetalRenderer(view:view,media:media) else {throw ProjectError.invalid(MetalRenderer.lastInitializationError)}
                    view.isPaused=true;renderer=created;renderers[output.id]=created
                }
                renderer.surfaces=surfaces;renderer.outputID=output.id;renderer.compositionGroups=groups
                renderer.globalMasks=masks;renderer.materialDefinitions=materials;renderer.materialTime=time
                renderer.edgeBlend=output.edgeBlend;renderer.feedbackTextures=old;renderer.feedbackFrame=oldFrame;renderer.blackout=blackout
                let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:output.width,height:output.height,mipmapped:false)
                descriptor.storageMode = .private;descriptor.usage=[.renderTarget,.shaderRead]
                guard let texture=media.device.makeTexture(descriptor:descriptor) else {throw ProjectError.invalid("loopback allocation failed")}
                let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=texture
                pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1)
                retained.append(renderer.encode(descriptor:pass,buffer:command));next[output.id]=texture
                if !renderer.errorDescription.isEmpty {throw ProjectError.invalid(renderer.errorDescription)}
            }
            pending=true
            let nextFrame=FeedbackFrame(next);histories.append(WeakFeedbackFrame(nextFrame))
            command.addCompletedHandler { [weak self] completed in
                withExtendedLifetime(retained) {}
                let success=completed.status == .completed,message=completed.error?.localizedDescription
                DispatchQueue.main.async {
                    guard let self else {return}
                    self.pending=false
                    guard self.generation==token else {return}
                    if success {self.frame=nextFrame;self.completedFrames &+= 1;self.errorDescription=""}
                    else {self.frame=nil;self.errorDescription=message ?? "loopback GPU command failed"}
                    self.onUpdate?()
                }
            }
            command.commit()
        } catch {
            errorDescription=error.localizedDescription;frame=nil;onUpdate?()
        }
    }
}
#endif
