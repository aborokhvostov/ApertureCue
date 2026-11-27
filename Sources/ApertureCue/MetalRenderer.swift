#if os(macOS)
import AppKit
import Metal
import MetalKit
import QuartzCore
import CoreVideo
import MappingCore

/// One renderer per drawable. All views share a MediaPool and its textures.
/// Quad projection is evaluated per fragment from a solved homography; it is
/// independent of the diagonal used to rasterize the quad.
final class MetalRenderer: NSObject, MTKViewDelegate {
    struct Vertex { var position:SIMD2<Float>;var local:SIMD2<Float>;var inputDelta:SIMD2<Float>;var weight:Float }
    private struct StrokeSegment { var endpoints: SIMD4<Float>; var range: SIMD4<Float> }
    private struct StrokeCache { var shape: SurfaceShape; var path: StrokePath; var buffer: MTLBuffer; var count: Int }
    private var strokeCache: [UUID: StrokeCache] = [:]
    struct Uniforms {
        var sourceX: SIMD4<Float>; var sourceY: SIMD4<Float>; var sourceW: SIMD4<Float>
        var localX: SIMD4<Float>; var localY: SIMD4<Float>; var localW: SIMD4<Float>
        var properties: SIMD4<Float>; var tint: SIMD4<Float>; var misc: SIMD4<Float>
        var shape: SIMD4<Float>
        var maskStyle: SIMD4<Float>
        var mediaX:SIMD4<Float>;var mediaY:SIMD4<Float>
        var triangleA: SIMD4<Float>; var triangleB: SIMD4<Float>; var triangleC: SIMD4<Float>
        var effectKeyColor:SIMD4<Float>;var effectKeyStyle:SIMD4<Float>;var effectStyle:SIMD4<Float>
        var frame:SIMD4<Float>;var inputGrid:SIMD4<Float>
        var blendX: SIMD4<Float>; var blendY: SIMD4<Float>
    }

    let device: MTLDevice
    let media: MediaPool
    var surfaces: [Surface] = []
    var outputID: UUID?
    var blackout = false
    let queue: MTLCommandQueue
    var pipelines: [String: MTLRenderPipelineState] = [:]
    private let slots = DispatchSemaphore(value: 3)
    private let drawableQueue=DispatchQueue(label:"org.aperturecue.drawable-acquisition",qos:.userInitiated)
    private let acquireDrawable:(CAMetalLayer)->CAMetalDrawable?
    private(set) var drawableAcquisitionPending=false
    private(set) var drawableRequestCount:UInt64=0
    private(set) var cancelledDrawableRequests:UInt64=0
    private(set) var failedDrawableRequests:UInt64=0
    private(set) var maxDrawableWaitMilliseconds:Double=0
    private(set) var lastDrawableSize=CGSize.zero
    private let snapshotQueue = DispatchQueue(label: "org.aperturecue.frame-readback", qos: .userInitiated)
    private var asyncSnapshotPending = false
    let fallback: MTLTexture
    let blackFallback:MTLTexture
    private var sampleStart = CACurrentMediaTime()
    private var sampleFrames = 0
    private(set) var frameCount: UInt64 = 0
    private(set) var droppedFrames: UInt64 = 0
    private(set) var fps: Double = 0
    private(set) var gpuMilliseconds: Double = 0
    private(set) var cpuMilliseconds: Double = 0
    private(set) var completedFrameCount: UInt64 = 0
    private(set) var totalGPUMilliseconds: Double = 0
    private(set) var totalCPUMilliseconds: Double = 0
    private(set) var maxGPUMilliseconds: Double = 0
    var errorDescription = ""
    var compositionGroups:[SurfaceGroup] = []
    var globalMasks:[CompositionMask] = []
    var materialDefinitions:[MaterialDefinition] = []
    var materialTime:Double? = nil
    var edgeBlend:EdgeBlendSettings = .init()
    var feedbackTextures:[UUID:MTLTexture] = [:]
    var feedbackFrame:FeedbackFrame? = nil
    var encodingLeases:CompositionGPULeases? = nil
    var encodingVertexCount=0
    var encodingSize=SIMD2<Float>(1280,720)
    struct MaterialCache { var definition:MaterialDefinition;var program:MaterialProgram;var pipelines:[String:MTLRenderPipelineState] }
    var materialCache:[UUID:MaterialCache] = [:]
    struct GeometryCache { var surface:Surface;var width:Int;var height:Int;var sourceWidth:Int;var sourceHeight:Int;var vertices:[Vertex] }
    let geometryCache=CompositionCPUCache<GeometryCache>(maximumBytes:12*1024*1024)
    struct InputGridCache {var surface:Surface;var width:Int;var height:Int;var sourceSide:Int;var columns:Int;var rows:Int;var values:[SIMD2<Float>]}
    let inputGridCache=CompositionCPUCache<InputGridCache>(maximumBytes:4*1024*1024)
    var postPipelineCache:[String:MTLRenderPipelineState]? = nil
    static var lastInitializationError = ""
    var statistics: String {
        String(format: "%.1f FPS · CPU %.2f ms · GPU %.2f ms · %llu skipped", fps, cpuMilliseconds, gpuMilliseconds, droppedFrames)
    }

    init?(view: MTKView, media: MediaPool,
          acquireDrawable:@escaping (CAMetalLayer)->CAMetalDrawable? = {$0.nextDrawable()}) {
        self.media = media
        self.acquireDrawable=acquireDrawable
        device = media.device
        guard let queue = device.makeCommandQueue() else {
            Self.lastInitializationError = "Metal command queue unavailable"
            return nil
        }
        self.queue = queue
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            Self.lastInitializationError = "Metal texture allocation failed"
            return nil
        }
        var white: UInt32 = 0xffffffff
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)
        fallback = texture
        guard let black=device.makeTexture(descriptor:descriptor) else { return nil }
        var blackPixel:UInt32=0xff000000
        black.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&blackPixel,bytesPerRow:4)
        blackFallback=black
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        // CAMetalLayer.nextDrawable always blocks. Keep its documented timeout
        // enabled; its wait runs on drawableQueue, never on the AppKit thread.
        if let layer=view.layer as? CAMetalLayer {layer.allowsNextDrawableTimeout=true}
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            for mode in ["normal", "add", "multiply", "screen"] {
                let pipeline = MTLRenderPipelineDescriptor()
                pipeline.vertexFunction = library.makeFunction(name: "mappingVertex")
                pipeline.fragmentFunction = library.makeFunction(name: "mappingFragment")
                pipeline.colorAttachments[0].pixelFormat = .bgra8Unorm
                let blend = pipeline.colorAttachments[0]!
                blend.isBlendingEnabled = true
                blend.rgbBlendOperation = .add
                blend.alphaBlendOperation = .add
                blend.sourceRGBBlendFactor = mode == "multiply" ? .destinationColor : .one
                blend.destinationRGBBlendFactor = mode == "add" ? .one : (mode == "screen" ? .oneMinusSourceColor : .oneMinusSourceAlpha)
                blend.sourceAlphaBlendFactor = .one
                blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                pipelines[mode] = try device.makeRenderPipelineState(descriptor: pipeline)
            }
        } catch {
            Self.lastInitializationError = "Metal shader compile failed: \(error.localizedDescription)"
            return nil
        }
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        precondition(Thread.isMainThread)
        guard !drawableAcquisitionPending else {droppedFrames += 1;return}
        guard let layer=view.layer as? CAMetalLayer,let window=view.window,
              window.isVisible,!view.isHiddenOrHasHiddenAncestor else {return}
        let size=layer.drawableSize,clear=view.clearColor,wasPaused=view.isPaused
        guard size.width>0,size.height>0 else {return}
        guard slots.wait(timeout: .now()) == .success else { droppedFrames += 1; return }
        drawableAcquisitionPending=true;drawableRequestCount &+= 1
        let slots=self.slots,acquire=self.acquireDrawable
        // The worker owns only a layer and the acquisition function. All view,
        // scene, media, cache and statistics access remains on the main queue.
        // A single pending request prevents display ticks queuing further waits.
        drawableQueue.async { [weak self,weak view,weak window] in
            let started=CACurrentMediaTime()
            let drawable=autoreleasepool {acquire(layer)}
            let waited=(CACurrentMediaTime()-started)*1000
            DispatchQueue.main.async { [weak self,weak view,weak window] in
                guard let self else {slots.signal();return}
                self.drawableAcquisitionPending=false
                self.maxDrawableWaitMilliseconds=max(self.maxDrawableWaitMilliseconds,waited)
                guard let view,let window,view.window === window,window.isVisible,
                      view.delegate === self,view.layer === layer,
                      !view.isHiddenOrHasHiddenAncestor,view.isPaused==wasPaused,
                      layer.drawableSize == size,view.drawableSize == size else {
                    self.cancelledDrawableRequests &+= 1;self.droppedFrames &+= 1;slots.signal();return
                }
                guard let drawable else {
                    self.failedDrawableRequests &+= 1;self.droppedFrames &+= 1;slots.signal();return
                }
                guard drawable.texture.width==Int(size.width),drawable.texture.height==Int(size.height),
                      drawable.texture.pixelFormat == .bgra8Unorm else {
                    self.cancelledDrawableRequests &+= 1;self.droppedFrames &+= 1;slots.signal();return
                }
                self.submitLive(drawable:drawable,clear:clear)
            }
        }
    }

    /// Encoding and submission stay serialized with document/media mutations.
    /// An explicit color pass avoids MTKView's blocking currentDrawable getter.
    private func submitLive(drawable:CAMetalDrawable,clear:MTLClearColor) {
        precondition(Thread.isMainThread)
        let started=CACurrentMediaTime()
        guard let buffer=queue.makeCommandBuffer() else {slots.signal();return}
        let descriptor=MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture=drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor=clear
        let videoFrames = encode(descriptor: descriptor, buffer: buffer)
        buffer.present(drawable)
        let slots = self.slots
        buffer.addCompletedHandler { [weak self] command in
            withExtendedLifetime(videoFrames) {}
            withExtendedLifetime(drawable) {}
            slots.signal()
            let milliseconds = (command.gpuEndTime - command.gpuStartTime) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.gpuMilliseconds = milliseconds
                self.completedFrameCount += 1
                self.totalGPUMilliseconds += milliseconds
                self.maxGPUMilliseconds = max(self.maxGPUMilliseconds, milliseconds)
                if command.status == .error {
                    self.errorDescription = command.error?.localizedDescription ?? "Metal command failed"
                }
            }
        }
        buffer.commit()
        lastDrawableSize=CGSize(width:drawable.texture.width,height:drawable.texture.height)
        cpuMilliseconds = (CACurrentMediaTime() - started) * 1000
        totalCPUMilliseconds += cpuMilliseconds
        frameCount += 1
        sampleFrames += 1
        let elapsed = CACurrentMediaTime() - sampleStart
        if elapsed >= 1 {
            fps = Double(sampleFrames) / elapsed
            sampleFrames = 0; sampleStart = CACurrentMediaTime()
        }
    }

    /// Explicit readback for deterministic QA and still export. Live rendering
    /// never waits for the GPU or reads pixels back to CPU memory.
    func snapshot(width: Int = 1280, height: Int = 720) -> NSBitmapImageRep? {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else {
            errorDescription = "Snapshot dimensions must be 1…8192"
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        let videoFrames = encode(descriptor: pass, buffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        withExtendedLifetime(videoFrames) {}
        gpuMilliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
        guard buffer.status == .completed,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let data = bitmap.bitmapData else {
            errorDescription = buffer.error?.localizedDescription ?? "Snapshot readback failed"
            return nil
        }
        texture.getBytes(data, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // Metal render targets use BGRA; NSBitmapImageRep above uses RGBA.
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            let blue = data[offset]; data[offset] = data[offset + 2]; data[offset + 2] = blue
        }
        return bitmap
    }

    func render(width: Int, height: Int) -> NSBitmapImageRep? { snapshot(width: width, height: height) }

    /// Lighting sampling uses a single bounded readback. Excess requests are
    /// dropped immediately, and neither the UI nor the render queue waits.
    func snapshotAsync(width: Int, height: Int, completion: @escaping (NSBitmapImageRep?) -> Void) {
        precondition(Thread.isMainThread)
        guard !asyncSnapshotPending, width > 0, height > 0, width <= 8192, height <= 8192 else { completion(nil); return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else { completion(nil); return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        asyncSnapshotPending = true
        let videoFrames = encode(descriptor: pass, buffer: buffer)
        let worker = snapshotQueue
        buffer.addCompletedHandler { [weak self] command in
            withExtendedLifetime(videoFrames) {}
            worker.async {
                var bitmap: NSBitmapImageRep?
                if command.status == .completed,
                   let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                       colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
                   let data = image.bitmapData {
                    texture.getBytes(data, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                    for pixel in 0..<(width * height) {
                        let offset = pixel * 4
                        let blue = data[offset]; data[offset] = data[offset + 2]; data[offset + 2] = blue
                    }
                    bitmap = image
                }
                let result = bitmap
                DispatchQueue.main.async {
                    self?.asyncSnapshotPending = false
                    if command.status == .error { self?.errorDescription = command.error?.localizedDescription ?? "Async readback failed" }
                    completion(result)
                }
            }
        }
        buffer.commit()
    }

    func encode(descriptor:MTLRenderPassDescriptor,buffer:MTLCommandBuffer) -> MediaFrameResources {
        encodeComposition(descriptor:descriptor,buffer:buffer)
    }

    func draw(surface: Surface, encoder: MTLRenderCommandEncoder, resources: MediaFrameResources) throws {
        guard surface.input.count == 4, surface.output.count == 4 else { return }
        let unit = [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)]
        let columns = surface.meshColumns
        let rows = surface.meshRows
        let hasMesh = surface.bezierWarp != nil || (columns > 0 && rows > 0 && columns <= 64 && rows <= 64 && surface.mesh.count == (columns + 1) * (rows + 1))
        let source = try Homography.solve(from: hasMesh || surface.shape.isStroke ? unit : surface.output, to: surface.input).values
        let local = try Homography.solve(from: surface.output, to: unit).values
        func row(_ values: [Double], _ offset: Int) -> SIMD4<Float> {
            SIMD4(Float(values[offset]), Float(values[offset + 1]), Float(values[offset + 2]), 0)
        }
        let texture = surface.feedbackOutputID.map { feedbackTextures[$0] ?? blackFallback }
            ?? surface.mediaID.flatMap { resources.textures[$0] }
        let blend = surface.feedbackOutputID == nil ? surface.mediaID.flatMap { resources.blends[$0] } : nil
        let sourceSide = texture.map { lhs in
            max(lhs.width, lhs.height, blend?.texture.width ?? 0, blend?.texture.height ?? 0)
        } ?? Int(max(encodingSize.x, encodingSize.y))
        let vertices = try preparedVertices(surface, width: Int(encodingSize.x), height: Int(encodingSize.y),
                                            sourceWidth: sourceSide, sourceHeight: sourceSide)
        encodingVertexCount+=vertices.count
        guard encodingVertexCount<=3145728 else {throw ProjectError.invalid("composition exceeds one million triangles")}
        try encodingLeases?.reserve(vertices.count*MemoryLayout<Vertex>.stride)
        let mediaTransform=surface.mediaID.flatMap {resources.uv[$0]} ?? .identity
        let generators = ["checker": Float(1), "gradient": Float(2), "solid": Float(3), "grid": Float(4)]
        let generator = texture != nil ? Float(0) : (generators[surface.generator] ?? 1)
        let tint = surface.color.count >= 3 ? surface.color : [1, 1, 1]
        let polygon = Array(surface.mask.prefix(128)).map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        let stroke = surface.shape.isStroke ? try strokeResources(surface) : nil
        let planes = surface.shape == .triangle ? try TriangleGeometry(vertices:surface.triangleVertices).planes : []
        func plane(_ index: Int) -> SIMD4<Float> {
            guard !planes.isEmpty else { return .zero }
            let p = planes[index]
            return SIMD4(Float(p.x),Float(p.y),Float(p.z),0)
        }
        let inputGrid=try preparedInputGrid(surface,width:Int(encodingSize.x),height:Int(encodingSize.y),sourceSide:sourceSide)
        var uniforms = Uniforms(
            sourceX: row(source, 0), sourceY: row(source, 3), sourceW: row(source, 6),
            localX: row(local, 0), localY: row(local, 3), localW: row(local, 6),
            properties: SIMD4(Float(max(0, min(1, surface.opacity))), Float(max(0, surface.brightness)),
                              Float(max(0.01, surface.gamma)), Float(max(0, min(0.5, surface.feather)))),
            tint: SIMD4(Float(tint[0]), Float(tint[1]), Float(tint[2]), 1),
            misc: SIMD4(generator, Float(polygon.count), hasMesh ? 1 : 0, Float(materialTime ?? media.currentTime)),
            shape: SIMD4(surface.shape.isStroke ? 3 : (surface.shape == .triangle ? 1 : (surface.shape == .ellipse ? 2 : 0)), Float(surface.stroke.width), Float(stroke?.count ?? 0), 0),
            maskStyle:SIMD4(surface.maskSettings.space == .outputCanvas ? 1 : 0, surface.maskSettings.inverted ? 1 : 0, Float(surface.maskSettings.feather), 0),
            mediaX:mediaTransform.x,mediaY:mediaTransform.y,
            triangleA:plane(0),triangleB:plane(1),triangleC:plane(2),
            effectKeyColor:SIMD4(Float(surface.effects.keyColor[0]),Float(surface.effects.keyColor[1]),Float(surface.effects.keyColor[2]),0),
            effectKeyStyle:SIMD4(surface.effects.keyMode == .none ? 0 : (surface.effects.keyMode == .chroma ? 1 : 2),Float(surface.effects.threshold),Float(surface.effects.softness),Float(surface.effects.spill)),
            effectStyle:SIMD4(Float(surface.effects.saturation),surface.effects.inverted ? 1 : 0,Float(surface.effects.posterizeLevels),0),
            frame:SIMD4(encodingSize.x,encodingSize.y,Float(surface.masks.filter(\.enabled).count),0),inputGrid:SIMD4(Float(inputGrid.columns),Float(inputGrid.rows),inputGrid.columns>0 ? 1 : 0,0),
            blendX: blend?.uv.x ?? .zero, blendY: blend?.uv.y ?? .zero)
        uniforms.blendX.w = blend?.weight ?? 0
        var selectedPipelines=pipelines
        var parameters=Array(repeating:SIMD4<Float>.zero,count:16)
        if let id=surface.materialID {
            if let definition=materialDefinitions.first(where:{$0.id==id}) {
                do { try validateMaterial(definition) } catch { errorDescription=error.localizedDescription }
            }
            guard let cache=materialCache[id] else { throw ProjectError.invalid("material is not compiled") }
            selectedPipelines=cache.pipelines
            parameters=try cache.program.parameterVectors(values:surface.materialValues).map { SIMD4(Float($0[0]),Float($0[1]),Float($0[2]),Float($0[3])) }
        }
        guard let pipeline=selectedPipelines[surface.blendMode] ?? selectedPipelines["normal"] else { return }
        encoder.setRenderPipelineState(pipeline)
        // set*Bytes is limited to 4 KiB; a dense mesh gets an ordinary buffer.
        let bytes = vertices.count * MemoryLayout<Vertex>.stride
        if bytes <= 4096 {
            encoder.setVertexBytes(vertices, length: bytes, index: 0)
        } else {
            guard let buffer = device.makeBuffer(bytes: vertices, length: bytes, options: .storageModeShared) else { return }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        if !polygon.isEmpty {
            encoder.setFragmentBytes(polygon, length: polygon.count * MemoryLayout<SIMD2<Float>>.stride, index: 1)
        } else {
            var zero = SIMD2<Float>(0, 0)
            encoder.setFragmentBytes(&zero, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        }
        if let stroke { encoder.setFragmentBuffer(stroke.buffer, offset:0, index:2) }
        else { var zero = StrokeSegment(endpoints:.zero,range:.zero); encoder.setFragmentBytes(&zero,length:MemoryLayout<StrokeSegment>.stride,index:2) }
        try encodingLeases?.reserve(inputGrid.values.count*MemoryLayout<SIMD2<Float>>.stride)
        guard let gridBuffer=device.makeBuffer(bytes:inputGrid.values,length:inputGrid.values.count*MemoryLayout<SIMD2<Float>>.stride,options:.storageModeShared) else {throw ProjectError.invalid("source grid GPU allocation failed")}
        encoder.setFragmentBuffer(gridBuffer,offset:0,index:6)
        encoder.setFragmentBytes(parameters,length:parameters.count*MemoryLayout<SIMD4<Float>>.stride,index:5)
        try bindMasks(surface.masks,encoder:encoder,worldInverse:.identity)
        encoder.setFragmentTexture(texture ?? fallback, index: 0)
        encoder.setFragmentTexture(blend?.texture ?? fallback, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    /// Geometry is local to the cage; only changed paths are flattened/uploaded.
    private func strokeResources(_ surface:Surface) throws -> StrokeCache {
        if let cached = strokeCache[surface.id], cached.shape == surface.shape, cached.path == surface.stroke { return cached }
        let points = try StrokeGeometry.samples(surface:surface)
        let metric = points.map { Point2($0.x*StrokeGeometry.aspectRatio,$0.y) }
        let lengths = zip(metric,metric.dropFirst()).map { hypot($1.x-$0.x,$1.y-$0.y) }
        let total = lengths.reduce(0,+)
        guard total > 1e-12 else { throw ProjectError.invalid("stroke has no length") }
        var segments:[StrokeSegment] = [], position = 0.0
        for i in lengths.indices {
            let length = lengths[i]
            if length > 1e-12 {
                segments.append(StrokeSegment(endpoints:SIMD4(Float(metric[i].x),Float(metric[i].y),Float((metric[i+1].x-metric[i].x)/length),Float((metric[i+1].y-metric[i].y)/length)),range:SIMD4(Float(position/total),Float(length/total),Float(length),0)))
            }
            position += length
        }
        guard !segments.isEmpty, segments.count <= 256,
              let buffer = device.makeBuffer(bytes:segments,length:segments.count*MemoryLayout<StrokeSegment>.stride,options:.storageModeShared) else { throw ProjectError.invalid("stroke segment allocation failed") }
        let cached = StrokeCache(shape:surface.shape,path:surface.stroke,buffer:buffer,count:segments.count)
        strokeCache[surface.id] = cached; return cached
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float2 position; float2 local; float2 inputDelta; float weight; };
    struct Raster { float4 position [[position]]; float2 screen; float2 local; float2 inputDelta; };
    struct StrokeSegment { float4 endpoints; float4 range; };
    struct Uniforms {
        float4 sourceX; float4 sourceY; float4 sourceW;
        float4 localX; float4 localY; float4 localW;
        float4 properties; float4 tint; float4 misc;
        float4 shape;
        float4 maskStyle;
        float4 mediaX;float4 mediaY;
        float4 triangleA; float4 triangleB; float4 triangleC;
        float4 effectKeyColor;float4 effectKeyStyle;float4 effectStyle;float4 frame;float4 inputGrid;
        float4 blendX; float4 blendY;
    };
    vertex Raster mappingVertex(const device Vertex* vertices [[buffer(0)]], uint id [[vertex_id]]) {
        Raster out;
        out.screen = vertices[id].position;
        out.local = vertices[id].local;out.inputDelta=vertices[id].inputDelta;
        out.position = float4((out.screen.x * 2.0 - 1.0)*vertices[id].weight, (1.0 - out.screen.y * 2.0)*vertices[id].weight, 0.0, vertices[id].weight);
        return out;
    }
    float2 project(float2 p, float4 a, float4 b, float4 c) {
        float3 q = float3(p, 1.0);
        return float2(dot(a.xyz, q), dot(b.xyz, q)) / dot(c.xyz, q);
    }
    \(Effects.metalFunction)
    \(MaterialProgram.metalFunctions)
    \(maskShaderFunctions)
    float4 sampleMaterial(texture2d<float> image, texture2d<float> nextImage, constant Uniforms& u, float2 uv) {
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
        float kind = u.misc.x;
        if (kind < 0.5) {
            float3 p = float3(uv, 1.0);
            float4 first = image.sample(s, float2(dot(u.mediaX.xyz, p), dot(u.mediaY.xyz, p)));
            float weight = u.blendX.w;
            if (weight <= 0.0) return first;
            float4 second = nextImage.sample(s, float2(dot(u.blendX.xyz, p), dot(u.blendY.xyz, p)));
            float alpha = mix(first.a, second.a, weight);
            float3 premultiplied = mix(first.rgb * first.a, second.rgb * second.a, weight);
            return alpha > 0.0 ? float4(premultiplied / alpha, alpha) : float4(0.0);
        }
        if (kind < 2.5 && kind > 1.5) return float4(uv.x,uv.y,1.0-uv.x,1.0);
        if (kind > 2.5 && kind < 3.5) return float4(1.0);
        float2 cell=floor(uv*float2(12.0,8.0));float check=fmod(cell.x+cell.y,2.0);
        float3 rgb=mix(float3(0.035,0.045,0.065),float3(0.82,0.9,0.97),check);
        float2 grid=fract(uv*float2(12.0,8.0));
        if (kind>3.5) rgb=(grid.x<0.025 || grid.y<0.025) ? float3(0.1,0.85,0.75) : float3(0.015);
        if (uv.x<0.055 && uv.y<0.055) rgb=float3(1,0.05,0.03);
        if (uv.x>0.945 && uv.y<0.055) rgb=float3(0.05,1,0.03);
        if (uv.x>0.945 && uv.y>0.945) rgb=float3(0.03,0.15,1);
        if (uv.x<0.055 && uv.y>0.945) rgb=float3(1,1,0.03);
        return float4(rgb,1.0);
    }
    float4 sampleMaterialISF(texture2d<float> image, texture2d<float> nextImage, constant Uniforms& u, float2 uv) {
        return sampleMaterial(image, nextImage, u, float2(uv.x, 1.0 - uv.y));
    }
    float2 sourceGridDelta(float2 uv,float4 grid,const device float2* points) {
        if(grid.z<0.5)return float2(0.0);
        int columns=int(grid.x),rows=int(grid.y);float2 scaled=clamp(uv,0.0,1.0)*float2(columns,rows);
        int x=min(columns-1,int(scaled.x)),y=min(rows-1,int(scaled.y));float u=scaled.x-x,v=scaled.y-y;
        int a=y*(columns+1)+x,b=a+1,d=a+columns+1,c=d+1;
        return v<=u ? points[a]*(1.0-u)+points[b]*(u-v)+points[c]*v : points[a]*(1.0-v)+points[c]*u+points[d]*(v-u);
    }
    fragment float4 mappingFragment(Raster in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                    constant float2* mask [[buffer(1)]], const device StrokeSegment* segments [[buffer(2)]],
                                    const device MaskHeader* masks [[buffer(3)]],const device float2* maskPoints [[buffer(4)]],
                                    constant float4* materialParams [[buffer(5)]],const device float2* inputGrid [[buffer(6)]],
                                    texture2d<float> image [[texture(0)]], texture2d<float> nextImage [[texture(1)]]) {
        float2 screen=in.position.xy/u.frame.xy;
        float2 local = u.misc.z > 0.5 ? in.local : project(screen, u.localX, u.localY, u.localW);
        // Shape is defined in local surface space, independent of source UV crop.
        float edge = min(min(local.x, 1.0 - local.x), min(local.y, 1.0 - local.y));
        float coverage = 1.0;
        float2 strokeUV = local;
        if (u.shape.x > 2.5) {
            float best = INFINITY;
            float2 q = local * float2(16.0/9.0, 1.0);
            for (int i = 0; i < int(u.shape.z); ++i) {
                // Unit direction and length are computed in Double before
                // upload: very short segments must not collapse when their
                // two absolute endpoints round to the same Float coordinate.
                float2 a = segments[i].endpoints.xy, direction = segments[i].endpoints.zw;
                float segmentLength = segments[i].range.z;
                if (segmentLength <= 1e-12) continue;
                float t = clamp(dot(q-a,direction)/segmentLength,0.0,1.0);
                float2 delta = q-(a+t*segmentLength*direction);
                float distance = length(delta);
                // Strict comparison gives the first segment a deterministic tie.
                if (distance < best) {
                    best = distance;
                    float side = (direction.x*delta.y-direction.y*delta.x);
                    strokeUV = float2(segments[i].range.x+t*segments[i].range.y,clamp(0.5+side/u.shape.y,0.0,1.0));
                }
            }
            edge = min(edge,u.shape.y*0.5-best);
            coverage = clamp(edge/max(fwidth(edge),1e-7)+0.5,0.0,1.0);
        } else if (u.shape.x > 0.5) {
            if (u.shape.x < 1.5) {
                float3 p = float3(local, 1.0);
                edge = min(min(dot(u.triangleA.xyz,p),dot(u.triangleB.xyz,p)),dot(u.triangleC.xyz,p));
            } else { edge = 0.5 - length(local - float2(0.5)); }
            // One fragment footprint at the boundary; no fixed-resolution tessellation.
            coverage = clamp(edge / max(fwidth(edge), 1e-7) + 0.5, 0.0, 1.0);
        }
        if (coverage <= 0.0) discard_fragment();
        float2 uv = project(u.shape.x > 2.5 ? strokeUV : (u.misc.z > 0.5 ? local : screen), u.sourceX, u.sourceY, u.sourceW)+(u.shape.x>2.5 ? sourceGridDelta(strokeUV,u.inputGrid,inputGrid) : in.inputDelta);
        if (!all(isfinite(uv)) || any(uv < float2(0.0)) || any(uv > float2(1.0))) discard_fragment();
        int count = int(u.misc.y);
        float maskAlpha = 1.0;
        if (count >= 3) {
            float2 p = u.maskStyle.x > 0.5 ? screen : uv;
            bool inside = false;
            float distance = INFINITY;
            for (int i = 0, j = count - 1; i < count; j = i++) {
                float2 a = mask[i], b = mask[j], delta = b-a;
                float squared = dot(delta,delta);
                float t = squared > 0.0 ? clamp(dot(p-a,delta)/squared,0.0,1.0) : 0.0;
                distance = min(distance,length(p-a-t*delta));
                if ((a.y > p.y) != (b.y > p.y)) {
                    float hit = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x;
                    if (p.x < hit) inside = !inside;
                }
            }
            if (distance == 0.0) inside = true;
            bool kept = u.maskStyle.y > 0.5 ? !inside : inside;
            maskAlpha = kept ? (u.maskStyle.z > 0.0 ? smoothstep(0.0,u.maskStyle.z,distance) : 1.0) : 0.0;
            if (maskAlpha <= 0.0) discard_fragment();
        }
        maskAlpha *= scopeMaskAlpha(uv,screen,masks,maskPoints,int(u.frame.z));
        float4 color = sampleMaterial(image, nextImage, u, uv);
        /*MATERIAL_EVALUATION*/
        if (!all(isfinite(color))) color=float4(0.0);
        color=apertureEffects(clamp(color,0.0,1.0),u.effectKeyColor,u.effectKeyStyle,u.effectStyle);
        float feather = u.properties.w > 0.0 ? smoothstep(0.0, u.properties.w, edge) : 1.0;
        float alpha = clamp(color.a * u.properties.x * feather * coverage * maskAlpha, 0.0, 1.0);
        float3 rgb = pow(max(color.rgb * u.tint.rgb * u.properties.y, float3(0.0)), float3(1.0 / u.properties.z));
        return float4(rgb * alpha, alpha);
    }
    """
}
#endif
