#if os(macOS)
import AppKit
import MetalKit
import MappingCore

extension MetalRenderer {
    struct MaskHeader {
        var style:SIMD4<Float>;var flags:SIMD4<Float>
        var mapX:SIMD4<Float>;var mapY:SIMD4<Float>;var mapW:SIMD4<Float>
    }
    struct PostUniforms {
        var frame:SIMD4<Float>;var keyColor:SIMD4<Float>;var keyStyle:SIMD4<Float>;var effects:SIMD4<Float>
        var edgeWidths:SIMD4<Float>;var edgeStyle:SIMD4<Float>
    }
    func validateMaterial(_ definition:MaterialDefinition) throws {
        if materialCache[definition.id]?.definition == definition { return }
        let program=try MaterialProgram(definition:definition)
        let expression=program.metalExpression
            .replacingOccurrences(of:"sampleMaterialISF(",with:"sampleMaterialISF(image,nextImage,u,")
            .replacingOccurrences(of:"sampleMaterial(",with:"sampleMaterial(image,nextImage,u,")
        let body="float2 materialUV=uv;float materialTime=u.misc.w;float2 materialSize=u.frame.xy;color="+expression+";"
        let source=Self.shaderSource.replacingOccurrences(of:"/*MATERIAL_EVALUATION*/",with:body)
        let library=try device.makeLibrary(source:source,options:nil)
        let compiled=try buildPipelines(library:library,fragment:"mappingFragment")
        // Publication is last: failed parser/compiler never replaces good code.
        materialCache[definition.id]=MaterialCache(definition:definition,program:program,pipelines:compiled)
    }
    func buildPipelines(library:MTLLibrary,fragment:String) throws -> [String:MTLRenderPipelineState] {
        var states:[String:MTLRenderPipelineState]=[:]
        for mode in ["normal","add","multiply","screen"] {
            let descriptor=MTLRenderPipelineDescriptor()
            descriptor.vertexFunction=library.makeFunction(name:"mappingVertex")
            descriptor.fragmentFunction=library.makeFunction(name:fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let blend=descriptor.colorAttachments[0]!
            blend.isBlendingEnabled=true;blend.rgbBlendOperation = .add;blend.alphaBlendOperation = .add
            blend.sourceRGBBlendFactor=mode == "multiply" ? .destinationColor : .one
            blend.destinationRGBBlendFactor=mode == "add" ? .one : (mode == "screen" ? .oneMinusSourceColor : .oneMinusSourceAlpha)
            blend.sourceAlphaBlendFactor = .one;blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            states[mode]=try device.makeRenderPipelineState(descriptor:descriptor)
        }
        return states
    }
    func preparedVertices(_ surface:Surface,width:Int,height:Int,sourceWidth:Int,sourceHeight:Int) throws -> [Vertex] {
        func same(_ old:Surface) -> Bool {
            old.shape.isStroke==surface.shape.isStroke && old.input==surface.input && old.output==surface.output && old.mesh==surface.mesh && old.meshColumns==surface.meshColumns && old.meshRows==surface.meshRows && old.meshWeights==surface.meshWeights && old.inputMesh==surface.inputMesh && old.bezierWarp==surface.bezierWarp && old.warpTransform==surface.warpTransform && old.inputWarp==surface.inputWarp && old.inputWarpTransform==surface.inputWarpTransform
        }
        if let cache=geometryCache[surface.id],cache.width==width,cache.height==height,cache.sourceWidth==sourceWidth,cache.sourceHeight==sourceHeight,same(cache.surface) { return cache.vertices }
        let base=try Homography.solve(from:Point2.unitQuad,to:surface.input)
        let mapping=try SurfaceSourceMapping(surface:surface)
        func vertex(_ point:Point2,_ local:Point2,_ weight:Double=1) throws -> Vertex {
            let uv=try mapping.point(at:local),initial=try base.applying(local)
            return Vertex(position:SIMD2(Float(point.x),Float(point.y)),local:SIMD2(Float(local.x),Float(local.y)),inputDelta:SIMD2(surface.shape.isStroke ? 0 : Float(uv.x-initial.x),surface.shape.isStroke ? 0 : Float(uv.y-initial.y)),weight:Float(weight))
        }
        var result:[Vertex]=[]
        if let mesh=try SurfaceWarpGeometry.tessellation(surface:surface,width:width,height:height,sourceWidth:sourceWidth,sourceHeight:sourceHeight) {
            result=try mesh.indices.map { let v=mesh.vertices[$0];return try vertex(v.output,v.local) }
        } else if !surface.mesh.isEmpty {
            let columns=surface.meshColumns,rows=surface.meshRows
            for y in 0..<rows { for x in 0..<columns {
                let a=y*(columns+1)+x,b=a+1,d=a+columns+1,c=d+1
                let u=Double(x)/Double(columns),v=Double(y)/Double(rows),u1=Double(x+1)/Double(columns),v1=Double(y+1)/Double(rows)
                for (i,p) in [(a,Point2(u,v)),(b,Point2(u1,v)),(c,Point2(u1,v1)),(a,Point2(u,v)),(c,Point2(u1,v1)),(d,Point2(u,v1))] {
                    result.append(try vertex(surface.mesh[i],p,surface.meshWeights.isEmpty ? 1 : surface.meshWeights[i]))
                }
            } }
        } else {
            for i in [0,1,2,0,2,3] { result.append(try vertex(surface.output[i],Point2.unitQuad[i])) }
        }
        guard result.count<=393216 else { throw ProjectError.invalid("surface exceeds the render triangle budget") }
        geometryCache.insert(GeometryCache(surface:surface,width:width,height:height,sourceWidth:sourceWidth,sourceHeight:sourceHeight,vertices:result),for:surface.id,bytes:result.count*MemoryLayout<Vertex>.stride+CompositionCPUCachePayload.surface(surface))
        return result
    }
    func preparedInputGrid(_ surface:Surface,width:Int,height:Int,sourceSide:Int) throws -> InputGridCache {
        guard surface.shape.isStroke,(!surface.inputMesh.isEmpty || surface.inputWarp != nil) else {return InputGridCache(surface:surface,width:width,height:height,sourceSide:sourceSide,columns:0,rows:0,values:[.zero])}
        if let c=inputGridCache[surface.id],c.width==width,c.height==height,c.sourceSide==sourceSide,
           c.surface.meshColumns==surface.meshColumns,c.surface.meshRows==surface.meshRows,c.surface.input==surface.input,c.surface.inputMesh==surface.inputMesh,c.surface.inputWarp==surface.inputWarp,c.surface.inputWarpTransform==surface.inputWarpTransform,c.surface.bezierWarp==surface.bezierWarp,c.surface.warpTransform==surface.warpTransform {return c}
        let grid=try SurfaceWarpGeometry.tessellation(surface:surface,width:width,height:height,sourceWidth:sourceSide,sourceHeight:sourceSide)
        let columns=grid?.columns ?? surface.meshColumns,rows=grid?.rows ?? surface.meshRows
        guard columns>0,rows>0,(columns+1)*(rows+1)<=66049 else {throw ProjectError.invalid("source grid exceeds its precision budget")}
        let base=try Homography.solve(from:Point2.unitQuad,to:surface.input),source=try SurfaceSourceMapping(surface:surface)
        var values:[SIMD2<Float>]=[]
        for y in 0...rows {for x in 0...columns {
            let p=Point2(Double(x)/Double(columns),Double(y)/Double(rows)),b=try base.applying(p),v=try source.point(at:p)
            values.append(SIMD2(Float(v.x-b.x),Float(v.y-b.y)))
        }}
        let result=InputGridCache(surface:surface,width:width,height:height,sourceSide:sourceSide,columns:columns,rows:rows,values:values)
        inputGridCache.insert(result,for:surface.id,bytes:values.count*MemoryLayout<SIMD2<Float>>.stride+CompositionCPUCachePayload.surface(surface));return result
    }
    func bindMasks(_ masks:[CompositionMask],encoder:MTLRenderCommandEncoder,worldInverse:Affine2D) throws {
        var headers:[MaskHeader]=[],points:[SIMD2<Float>]=[]
        let m=worldInverse.values
        func row(_ offset:Int) -> SIMD4<Float> { SIMD4(Float(m[offset]),Float(m[offset+1]),Float(m[offset+2]),0) }
        for mask in masks where mask.enabled {
            let polygon=try mask.polygon(tolerance:min(0.00025,0.25/Double(max(encodingSize.x,encodingSize.y))))
            headers.append(MaskHeader(style:SIMD4(Float(polygon.count),Float(points.count),mask.settings.space == .sourceUV ? 0 : 1,Float(mask.settings.feather)),flags:SIMD4(mask.settings.inverted ? 1 : 0,0,0,0),mapX:row(0),mapY:row(3),mapW:row(6)))
            points += polygon.map { SIMD2(Float($0.x),Float($0.y)) }
        }
        if headers.isEmpty {
            headers=[MaskHeader(style:.zero,flags:.zero,mapX:.zero,mapY:.zero,mapW:SIMD4(0,0,1,0))];points=[.zero]
        }
        try encodingLeases?.reserve(headers.count*MemoryLayout<MaskHeader>.stride+points.count*MemoryLayout<SIMD2<Float>>.stride)
        guard headers.count<=8,points.count<=8192,
              let headerBuffer=device.makeBuffer(bytes:headers,length:headers.count*MemoryLayout<MaskHeader>.stride,options:.storageModeShared),
              let pointBuffer=device.makeBuffer(bytes:points,length:points.count*MemoryLayout<SIMD2<Float>>.stride,options:.storageModeShared) else { throw ProjectError.invalid("mask GPU buffer budget exceeded") }
        encoder.setFragmentBuffer(headerBuffer,offset:0,index:3);encoder.setFragmentBuffer(pointBuffer,offset:0,index:4)
    }
    func encodeComposition(descriptor:MTLRenderPassDescriptor,buffer:MTLCommandBuffer) -> MediaFrameResources {
        guard let target=descriptor.colorAttachments[0].texture else { return .empty }
        errorDescription="";encodingVertexCount=0
        let leases=CompositionGPULeases();encodingLeases=leases
        defer {encodingLeases=nil}
        buffer.addCompletedHandler { _ in withExtendedLifetime(leases) {} }
        let feedbackLease=feedbackFrame
        if feedbackLease != nil {buffer.addCompletedHandler { _ in withExtendedLifetime(feedbackLease) {} }}
        encodingSize=SIMD2(Float(target.width),Float(target.height))
        let visible=surfaces.filter { $0.enabled && $0.opacity>0 && (outputID==nil || $0.outputID==nil || $0.outputID==outputID) }
        let ids=Set(visible.map(\.id));geometryCache.retain(keys:ids);inputGridCache.retain(keys:ids)
        let materialIDs=Set(visible.compactMap(\.materialID))
        materialCache=materialCache.filter { materialDefinitions.contains($0.value.definition) || materialIDs.contains($0.key) }
        let resources=media.frameResources(for:Set(visible.compactMap(\.mediaID)))
        do {
            if blackout {
                let pass=descriptor.copy() as! MTLRenderPassDescriptor
                pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1)
                buffer.makeRenderCommandEncoder(descriptor:pass)?.endEncoding();return resources
            }
            try CompositionPlan.validateStack(surfaces:visible,groups:compositionGroups)
            let groups=Dictionary(compositionGroups.map { ($0.id,$0) },uniquingKeysWith:{a,_ in a})
            let compositeCount=compositionGroups.filter(\.composites).count
            guard compositeCount<=16 else { throw ProjectError.invalid("at most sixteen isolated groups can render in one composition") }
            var allocatedPixels=0
            func targetTexture() throws -> MTLTexture {
                allocatedPixels += target.width*target.height
                guard allocatedPixels<=67108864 else { throw ProjectError.invalid("composition intermediate texture budget exceeded") }
                try leases.reserve(target.width*target.height*4)
                let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:target.width,height:target.height,mipmapped:false)
                d.storageMode = .private;d.usage=[.renderTarget,.shaderRead]
                guard let t=device.makeTexture(descriptor:d) else { throw ProjectError.invalid("composition GPU allocation failed") };return t
            }
            func chain(_ s:Surface) -> [UUID] {
                var cursor=s.groupID,visited=Set<UUID>(),result:[UUID]=[]
                while let id=cursor,visited.insert(id).inserted,let group=groups[id] {
                    if group.composites { result.append(id) };cursor=group.parentID
                }
                return result.reversed()
            }
            func pass(_ texture:MTLTexture,_ load:MTLLoadAction,_ opaque:Bool) -> MTLRenderPassDescriptor {
                let p=MTLRenderPassDescriptor();p.colorAttachments[0].texture=texture
                p.colorAttachments[0].loadAction=load;p.colorAttachments[0].storeAction = .store
                p.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,opaque ? 1 : 0);return p
            }
            func render(_ items:[Surface],to texture:MTLTexture,inside:UUID?,opaque:Bool) throws {
                guard var encoder=buffer.makeRenderCommandEncoder(descriptor:pass(texture,.clear,opaque)) else { throw ProjectError.invalid("composition encoder unavailable") }
                var open=true
                defer {if open {encoder.endEncoding()} }
                var i=0
                while i<items.count {
                    let ancestry=chain(items[i])
                    let child:UUID?
                    if let inside,let at=ancestry.firstIndex(of:inside) { child=at+1<ancestry.count ? ancestry[at+1] : nil }
                    else { child=ancestry.first }
                    if let id=child,let group=groups[id] {
                        var end=i+1
                        while end<items.count,chain(items[end]).contains(id) {end+=1}
                        encoder.endEncoding();open=false
                        let intermediate=try targetTexture()
                        try render(Array(items[i..<end]),to:intermediate,inside:id,opaque:false)
                        guard let next=buffer.makeRenderCommandEncoder(descriptor:pass(texture,.load,opaque)) else {throw ProjectError.invalid("composition encoder unavailable")}
                        encoder=next;open=true
                        let inverse=try GroupEngine.worldTransform(for:id,groups:compositionGroups).inverse()
                        try composite(intermediate,encoder:encoder,opacity:group.opacity,blend:group.blendMode,masks:group.masks,inverse:inverse,effects:group.effects,edge:.init())
                        i=end
                    } else {
                        try draw(surface:items[i],encoder:encoder,resources:resources);i+=1
                    }
                }
            }
            if globalMasks.isEmpty && edgeBlend == .init() { try render(visible,to:target,inside:nil,opaque:true) }
            else {
                let intermediate=try targetTexture();try render(visible,to:intermediate,inside:nil,opaque:true)
                guard let encoder=buffer.makeRenderCommandEncoder(descriptor:pass(target,.clear,true)) else { throw ProjectError.invalid("composition post encoder unavailable") }
                defer {encoder.endEncoding()}
                try composite(intermediate,encoder:encoder,opacity:1,blend:"normal",masks:globalMasks,inverse:.identity,effects:.init(),edge:edgeBlend)
            }
        } catch {
            errorDescription=error.localizedDescription
            let p=MTLRenderPassDescriptor();p.colorAttachments[0].texture=target;p.colorAttachments[0].loadAction = .clear;p.colorAttachments[0].storeAction = .store;p.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1)
            buffer.makeRenderCommandEncoder(descriptor:p)?.endEncoding()
        }
        return resources
    }
    func postPipelines() throws -> [String:MTLRenderPipelineState] {
        if let postPipelineCache {return postPipelineCache}
        let library=try device.makeLibrary(source:Self.shaderSource+Self.postShaderSource,options:nil)
        let result=try buildPipelines(library:library,fragment:"compositionFragment")
        postPipelineCache=result;return result
    }
    func composite(_ texture:MTLTexture,encoder:MTLRenderCommandEncoder,opacity:Double,blend:String,masks:[CompositionMask],inverse:Affine2D,effects:EffectsSettings,edge:EdgeBlendSettings) throws {
        let states=try postPipelines()
        guard let state=states[blend] else {throw ProjectError.invalid("unknown composition blend")}
        let vertices=[0,1,2,0,2,3].map { index -> Vertex in let p=Point2.unitQuad[index];return Vertex(position:SIMD2(Float(p.x),Float(p.y)),local:SIMD2(Float(p.x),Float(p.y)),inputDelta:.zero,weight:1) }
        var u=PostUniforms(frame:SIMD4(encodingSize.x,encodingSize.y,Float(masks.filter(\.enabled).count),Float(opacity)),keyColor:SIMD4(Float(effects.keyColor[0]),Float(effects.keyColor[1]),Float(effects.keyColor[2]),0),keyStyle:SIMD4(effects.keyMode == .none ? 0 : (effects.keyMode == .chroma ? 1 : 2),Float(effects.threshold),Float(effects.softness),Float(effects.spill)),effects:SIMD4(Float(effects.saturation),effects.inverted ? 1 : 0,Float(effects.posterizeLevels),0),edgeWidths:SIMD4(Float(edge.left),Float(edge.right),Float(edge.top),Float(edge.bottom)),edgeStyle:SIMD4(Float(edge.power),Float(edge.gamma),Float(edge.blackLevel),0))
        encoder.setRenderPipelineState(state);encoder.setVertexBytes(vertices,length:vertices.count*MemoryLayout<Vertex>.stride,index:0)
        encoder.setFragmentBytes(&u,length:MemoryLayout<PostUniforms>.stride,index:0);encoder.setFragmentTexture(texture,index:0)
        try bindMasks(masks,encoder:encoder,worldInverse:inverse)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:vertices.count)
    }
    static let maskShaderFunctions="""
    struct MaskHeader {float4 style;float4 flags;float4 mapX;float4 mapY;float4 mapW;};
    float scopeMaskAlpha(float2 uv,float2 screen,const device MaskHeader* masks,const device float2* points,int count) {
        float alpha=1.0;
        for (int k=0;k<count;k++) {
            MaskHeader h=masks[k];float2 p=h.style.z>0.5 ? screen : project(uv,h.mapX,h.mapY,h.mapW);
            // A valid group's inverse horizon may cross transparent pixels
            // outside that group. Do not let those unrelated pixels create NaN
            // coverage through project()/fwidth() and contaminate the backdrop.
            if(!all(isfinite(p)))return 0.0;
            bool inside=false;float distance=INFINITY;int n=int(h.style.x),offset=int(h.style.y);
            for(int i=0,j=n-1;i<n;j=i++) {
                float2 a=points[offset+i],b=points[offset+j],d=b-a;
                float squared=dot(d,d),t=squared>0.0 ? clamp(dot(p-a,d)/squared,0.0,1.0) : 0.0;
                distance=min(distance,length(p-a-t*d));
                if ((a.y>p.y)!=(b.y>p.y) && p.x<(b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x) inside=!inside;
            }
            if(!isfinite(distance)) {if(h.flags.x>0.5)continue;return 0.0;}
            if(distance==0.0)inside=true;
            float edge=inside ? distance : -distance;if(h.flags.x>0.5)edge=-edge;
            float coverage=clamp(edge/max(fwidth(edge),1e-7)+0.5,0.0,1.0);
            float feather=h.style.w>0.0 ? smoothstep(0.0,h.style.w,max(edge,0.0)) : 1.0;
            alpha*=coverage*feather;
        }
        return alpha;
    }
    """
    static let postShaderSource="""
    struct PostUniforms {float4 frame;float4 keyColor;float4 keyStyle;float4 effects;float4 edgeWidths;float4 edgeStyle;};
    float edgeRamp(float x,float power) {float t=clamp(x,0.0,1.0);float a=pow(t,power),b=pow(1.0-t,power);return a/(a+b);}
    fragment float4 compositionFragment(Raster in [[stage_in]],constant PostUniforms& u [[buffer(0)]],const device MaskHeader* masks [[buffer(3)]],const device float2* points [[buffer(4)]],texture2d<float> source [[texture(0)]]) {
        float2 screen=in.position.xy/u.frame.xy;
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::nearest);
        float4 premul=source.sample(s,screen);
        float4 color=float4(premul.a>1e-7 ? premul.rgb/premul.a : float3(0.0),premul.a);
        color=apertureEffects(color,u.keyColor,u.keyStyle,u.effects);
        float alpha=clamp(color.a*u.frame.w*scopeMaskAlpha(screen,screen,masks,points,int(u.frame.z)),0.0,1.0);
        float gain=1.0;float4 distance=float4(screen.x,1.0-screen.x,screen.y,1.0-screen.y);
        for(int i=0;i<4;i++) if(u.edgeWidths[i]>0.0)gain*=edgeRamp(distance[i]/u.edgeWidths[i],u.edgeStyle.x);
        float3 rgb=u.edgeStyle.z+(1.0-u.edgeStyle.z)*pow(clamp(color.rgb,0.0,1.0),float3(1.0/u.edgeStyle.y))*gain;
        if(!all(isfinite(rgb)) || !isfinite(alpha))return float4(0.0);
        return float4(rgb*alpha,alpha);
    }
    """
}
#endif
