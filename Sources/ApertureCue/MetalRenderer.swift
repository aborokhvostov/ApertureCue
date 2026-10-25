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
    private struct Vertex { var position: SIMD2<Float>; var local: SIMD2<Float> }
    private struct Uniforms {
        var sourceX: SIMD4<Float>; var sourceY: SIMD4<Float>; var sourceW: SIMD4<Float>
        var localX: SIMD4<Float>; var localY: SIMD4<Float>; var localW: SIMD4<Float>
        var properties: SIMD4<Float>; var tint: SIMD4<Float>; var misc: SIMD4<Float>
    }

    let device: MTLDevice
    let media: MediaPool
    var surfaces: [Surface] = []
    var outputID: UUID?
    var blackout = false
    private let queue: MTLCommandQueue
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private let slots = DispatchSemaphore(value: 3)
    private let snapshotQueue = DispatchQueue(label: "org.aperturecue.frame-readback", qos: .userInitiated)
    private var asyncSnapshotPending = false
    private let fallback: MTLTexture
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
    private(set) var errorDescription = ""
    static var lastInitializationError = ""
    var statistics: String {
        String(format: "%.1f FPS · CPU %.2f ms · GPU %.2f ms · %llu skipped", fps, cpuMilliseconds, gpuMilliseconds, droppedFrames)
    }

    init?(view: MTKView, media: MediaPool) {
        self.media = media
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
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
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
        let started = CACurrentMediaTime()
        guard slots.wait(timeout: .now()) == .success else { droppedFrames += 1; return }
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = queue.makeCommandBuffer() else { slots.signal(); return }
        encode(descriptor: descriptor, buffer: buffer)
        let videoFrames = media.retainedVideoFrames()
        buffer.present(drawable)
        let slots = self.slots
        buffer.addCompletedHandler { [weak self] command in
            withExtendedLifetime(videoFrames) {}
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
        encode(descriptor: pass, buffer: buffer)
        let videoFrames = media.retainedVideoFrames()
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
        encode(descriptor: pass, buffer: buffer)
        let videoFrames = media.retainedVideoFrames()
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

    private func encode(descriptor: MTLRenderPassDescriptor, buffer: MTLCommandBuffer) {
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        defer { encoder.endEncoding() }
        guard !blackout else { return }
        for surface in surfaces where surface.enabled && surface.opacity > 0 {
            if let outputID, let assigned = surface.outputID, assigned != outputID { continue }
            do { try draw(surface: surface, encoder: encoder) }
            catch { errorDescription = "\(surface.name): \(error.localizedDescription)" }
        }
    }

    private func draw(surface: Surface, encoder: MTLRenderCommandEncoder) throws {
        guard surface.input.count == 4, surface.output.count == 4 else { return }
        let unit = [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)]
        let columns = surface.meshColumns
        let rows = surface.meshRows
        let hasMesh = columns > 0 && rows > 0 && columns <= 64 && rows <= 64 && surface.mesh.count == (columns + 1) * (rows + 1)
        let source = try Homography.solve(from: hasMesh ? unit : surface.output, to: surface.input).values
        let local = try Homography.solve(from: surface.output, to: unit).values
        func row(_ values: [Double], _ offset: Int) -> SIMD4<Float> {
            SIMD4(Float(values[offset]), Float(values[offset + 1]), Float(values[offset + 2]), 0)
        }
        var vertices: [Vertex] = []
        func vertex(_ point: Point2, _ u: Double, _ v: Double) -> Vertex {
            Vertex(position: SIMD2(Float(point.x), Float(point.y)), local: SIMD2(Float(u), Float(v)))
        }
        if hasMesh {
            for y in 0..<rows {
                for x in 0..<columns {
                    let a = y * (columns + 1) + x
                    let b = a + 1; let d = a + columns + 1; let c = d + 1
                    let u = Double(x) / Double(columns), v = Double(y) / Double(rows)
                    let u1 = Double(x + 1) / Double(columns), v1 = Double(y + 1) / Double(rows)
                    vertices += [vertex(surface.mesh[a], u, v), vertex(surface.mesh[b], u1, v), vertex(surface.mesh[c], u1, v1),
                                 vertex(surface.mesh[a], u, v), vertex(surface.mesh[c], u1, v1), vertex(surface.mesh[d], u, v1)]
                }
            }
        } else {
            let points = surface.output
            vertices = [vertex(points[0], 0, 0), vertex(points[1], 1, 0), vertex(points[2], 1, 1),
                        vertex(points[0], 0, 0), vertex(points[2], 1, 1), vertex(points[3], 0, 1)]
        }
        let texture = surface.mediaID.flatMap { media.texture(for: $0) }
        let generators = ["checker": Float(1), "gradient": Float(2), "solid": Float(3), "grid": Float(4)]
        let generator = texture != nil ? Float(0) : (generators[surface.generator] ?? 1)
        let tint = surface.color.count >= 3 ? surface.color : [1, 1, 1]
        let polygon = Array(surface.mask.prefix(128)).map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        var uniforms = Uniforms(
            sourceX: row(source, 0), sourceY: row(source, 3), sourceW: row(source, 6),
            localX: row(local, 0), localY: row(local, 3), localW: row(local, 6),
            properties: SIMD4(Float(max(0, min(1, surface.opacity))), Float(max(0, surface.brightness)),
                              Float(max(0.01, surface.gamma)), Float(max(0, min(0.5, surface.feather)))),
            tint: SIMD4(Float(tint[0]), Float(tint[1]), Float(tint[2]), 1),
            misc: SIMD4(generator, Float(polygon.count), hasMesh ? 1 : 0, Float(media.currentTime)))
        guard let pipeline = pipelines[surface.blendMode] ?? pipelines["normal"] else { return }
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
        encoder.setFragmentTexture(texture ?? fallback, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float2 position; float2 local; };
    struct Raster { float4 position [[position]]; float2 screen; float2 local; };
    struct Uniforms {
        float4 sourceX; float4 sourceY; float4 sourceW;
        float4 localX; float4 localY; float4 localW;
        float4 properties; float4 tint; float4 misc;
    };
    vertex Raster mappingVertex(const device Vertex* vertices [[buffer(0)]], uint id [[vertex_id]]) {
        Raster out;
        out.screen = vertices[id].position;
        out.local = vertices[id].local;
        out.position = float4(out.screen.x * 2.0 - 1.0, 1.0 - out.screen.y * 2.0, 0.0, 1.0);
        return out;
    }
    float2 project(float2 p, float4 a, float4 b, float4 c) {
        float3 q = float3(p, 1.0);
        return float2(dot(a.xyz, q), dot(b.xyz, q)) / dot(c.xyz, q);
    }
    fragment float4 mappingFragment(Raster in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                    constant float2* mask [[buffer(1)]], texture2d<float> image [[texture(0)]]) {
        float2 local = u.misc.z > 0.5 ? in.local : project(in.screen, u.localX, u.localY, u.localW);
        float2 uv = project(u.misc.z > 0.5 ? local : in.screen, u.sourceX, u.sourceY, u.sourceW);
        if (!all(isfinite(uv)) || any(uv < float2(0.0)) || any(uv > float2(1.0))) discard_fragment();
        int count = int(u.misc.y);
        if (count >= 3) {
            bool inside = false;
            for (int i = 0, j = count - 1; i < count; j = i++) {
                float2 a = mask[i], b = mask[j];
                if ((a.y > uv.y) != (b.y > uv.y)) {
                    float hit = (b.x - a.x) * (uv.y - a.y) / (b.y - a.y) + a.x;
                    if (uv.x < hit) inside = !inside;
                }
            }
            if (!inside) discard_fragment();
        }
        constexpr sampler sampleFilter(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 color;
        int kind = int(u.misc.x);
        if (kind == 0) { color = image.sample(sampleFilter, uv); }
        else if (kind == 2) { color = float4(uv.x, uv.y, 1.0 - uv.x, 1.0); }
        else if (kind == 3) { color = float4(1.0); }
        else {
            float2 cell = floor(uv * float2(12.0, 8.0));
            float check = fmod(cell.x + cell.y, 2.0);
            float3 rgb = mix(float3(0.035, 0.045, 0.065), float3(0.82, 0.9, 0.97), check);
            float2 grid = fract(uv * float2(12.0, 8.0));
            if (kind == 4) rgb = (grid.x < 0.025 || grid.y < 0.025) ? float3(0.1, 0.85, 0.75) : float3(0.015);
            if (uv.x < 0.055 && uv.y < 0.055) rgb = float3(1, 0.05, 0.03);
            if (uv.x > 0.945 && uv.y < 0.055) rgb = float3(0.05, 1, 0.03);
            if (uv.x > 0.945 && uv.y > 0.945) rgb = float3(0.03, 0.15, 1);
            if (uv.x < 0.055 && uv.y > 0.945) rgb = float3(1, 1, 0.03);
            color = float4(rgb, 1.0);
        }
        float edge = min(min(local.x, 1.0 - local.x), min(local.y, 1.0 - local.y));
        float feather = u.properties.w > 0.0 ? smoothstep(0.0, u.properties.w, edge) : 1.0;
        float alpha = clamp(color.a * u.properties.x * feather, 0.0, 1.0);
        float3 rgb = pow(max(color.rgb * u.tint.rgb * u.properties.y, float3(0.0)), float3(1.0 / u.properties.z));
        return float4(rgb * alpha, alpha);
    }
    """
}
#endif
