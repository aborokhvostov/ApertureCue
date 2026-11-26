#if os(macOS)
import AppKit
import MetalKit
import QuartzCore
import MappingCore

/// Production Metal composition, expression, scoped-mask and previous-generation
/// feedback tests. All textures/media are original procedural fixtures. No
/// external display, network, camera, hardware or throughput claim is made.
@MainActor enum CompositionSelfTest {
    private struct Failure: LocalizedError {
        let message:String
        var errorDescription:String? {message}
    }
    static func run() -> Int32 {
        let started=CACurrentMediaTime()
        let directory=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/local",isDirectory:true)
        let url=directory.appendingPathComponent("composition-test.json")
        var checks:[String]=[]
        var report:[String:Any]=[
            "schemaVersion":1,"timestampUTC":ISO8601DateFormatter().string(from:Date()),
            "platform":ProcessInfo.processInfo.operatingSystemVersionString,
            "hardwareVerification":false,"windowsShown":false,
            "scope":"Actual Metal composition, bounded expression/ISF/FX, scoped masks, group isolation, edge attenuation and previous-generation loopback; original procedural sources only.",
            "frameSize":[128,96],"additionalFrameSizes":[[64,64],[320,180]],"feedbackSize":[32,18],"maximumFixtureOutputs":2,"maximumFixtureSurfaces":4,
            "outputMeaning":"Offscreen logical routes only; no physical displays.",
            "codecs":"none; procedural sources only","unmeasured":"Physical devices, optical seams/refresh, throughput, long-run stability, decoder/audio timing and GPU utilization."
        ]
        func save(_ success:Bool,_ error:String?=nil) {
            report["passed"]=success;report["checks"]=checks;report["checkCount"]=checks.count
            report["elapsedSeconds"]=CACurrentMediaTime()-started
            if let error {report["failure"]=error}
            do {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
            } catch {fputs("Composition report error: \(error)\n",stderr)}
        }
        func expect(_ value:Bool,_ message:String) throws {if !value {throw Failure(message:message)}}
        func passed(_ name:String) {checks.append(name);print("PASS composition: \(name)")}
        func pixel(_ image:NSBitmapImageRep,_ x:Int,_ y:Int) -> [Int] {
            guard let data=image.bitmapData else {return []};let offset=y*image.bytesPerRow+x*4
            return (0..<4).map {Int(data[offset+$0])}
        }
        func near(_ a:[Int],_ b:[Int],_ tolerance:Int=2) -> Bool {a.count==b.count && zip(a,b).allSatisfy {abs($0-$1)<=tolerance}}
        func bytes(_ rgba:[Double]) -> [Int] {
            let alpha=min(1,max(0,rgba[3]))
            return rgba.prefix(3).map {Int((min(1,max(0,$0))*alpha*255).rounded())}+[255]
        }
        func coordinate(_ x:Int,_ y:Int,_ width:Int=128,_ height:Int=96) -> Point2 {
            Point2((Double(x)+0.5)/Double(width),(Double(y)+0.5)/Double(height))
        }
        func pump(_ condition:()->Bool,timeout:Double=10) -> Bool {
            let deadline=CACurrentMediaTime()+timeout
            repeat {
                if condition() {return true}
                RunLoop.current.run(until:Date(timeIntervalSinceNow:0.005))
            } while CACurrentMediaTime()<deadline
            return condition()
        }
        do {
            _=NSApplication.shared;NSApplication.shared.setActivationPolicy(.prohibited)
            guard let device=MTLCreateSystemDefaultDevice() else {throw Failure(message:"No Metal device in logged-in session")}
            report["gpu"]=device.name
            let media=MediaPool(device:device)
            defer {media.pause()}
            let view=MTKView(frame:NSRect(x:0,y:0,width:128,height:96),device:device)
            guard let renderer=MetalRenderer(view:view,media:media) else {throw Failure(message:MetalRenderer.lastInitializationError)}
            view.isPaused=true
            func frame(_ surfaces:[Surface],groups:[SurfaceGroup]=[],masks:[CompositionMask]=[],materials:[MaterialDefinition]=[],
                       edge:EdgeBlendSettings = .init(),time:Double=0,feedback:[UUID:MTLTexture]=[:],lease:FeedbackFrame?=nil,
                       width:Int=128,height:Int=96,allowDiagnostic:Bool=false) throws -> NSBitmapImageRep {
                renderer.errorDescription="";renderer.blackout=false;renderer.outputID=nil
                renderer.compositionGroups=groups;renderer.globalMasks=masks;renderer.materialDefinitions=materials
                renderer.edgeBlend=edge;renderer.materialTime=time;renderer.feedbackTextures=feedback;renderer.feedbackFrame=lease
                renderer.surfaces=try GroupEngine.resolveForComposition(surfaces:surfaces,groups:groups)
                guard let image=renderer.snapshot(width:width,height:height) else {throw Failure(message:"Snapshot failed: "+renderer.errorDescription)}
                if !allowDiagnostic {try expect(renderer.errorDescription.isEmpty,"Composition diagnostic: "+renderer.errorDescription)}
                return image
            }
            let unit=Point2.unitQuad
            let white=Surface(name:"White",output:unit,generator:"solid")
            let red=Surface(name:"Red",output:unit,color:[1,0,0],generator:"solid")
            let green=Surface(name:"Green",output:unit,color:[0,1,0],generator:"solid")
            let blue=Surface(name:"Blue",output:unit,color:[0,0,1],generator:"solid")
            let samplePoints=[(19,17),(49,31),(87,51),(105,77)]

            let tint=MaterialInput(name:"tint",kind:.color,defaultValue:[0.9,0.2,0.4,0.8],minimum:[0,0,0,0],maximum:[1,1,1,1])
            let amount=MaterialInput(name:"amount",defaultValue:[0.35])
            let material=MaterialDefinition(name:"Original source mix",expression:"mix(sample(uv),tint,amount)",inputs:[tint,amount])
            let program=try MaterialProgram(definition:material)
            var source=Surface(name:"Material source",input:[Point2(0.1,0.15),Point2(0.85,0.15),Point2(0.85,0.9),Point2(0.1,0.9)],output:unit,generator:"gradient")
            source.materialID=material.id;source.materialValues=["amount":[0.6]]
            let sourceUV=try Homography.solve(from:unit,to:source.input)
            var image=try frame([source],materials:[material])
            for (x,y) in samplePoints {
                let uv=try sourceUV.applying(coordinate(x,y))
                let expected=try program.evaluate(uv:uv,values:source.materialValues,sample:{[$0.x,$0.y,1-$0.x,1]})
                try expect(near(pixel(image,x,y),bytes(expected)),"Material sampled crop/uniform CPU oracle differs")
            }
            passed("material expression samples cropped source and typed uniforms through production Metal")

            let timed=MaterialDefinition(name:"Original clock and size",expression:"vec4(mod(uv.x-time,1),size.x/size.y/2,0.5+0.5*sin(time),1)")
            var timedSurface=white;timedSurface.materialID=timed.id
            image=try frame([timedSurface],materials:[timed],time:0.37)
            for (x,y) in samplePoints {
                let uv=coordinate(x,y),u=uv.x-0.37
                let expected=[u-floor(u),128.0/96/2,0.5+0.5*sin(0.37),1.0]
                try expect(near(pixel(image,x,y),bytes(expected)),"Material time/size/negative-mod differs")
            }
            passed("material show time, render size and negative GLSL modulo have independent numeric pixels")

            let isf=try ISFMaterial.importSource("/*{\"ISFVSN\":\"2\"}*/ void main(){ gl_FragColor=vec4(isf_FragNormCoord,0.25,1); }",name:"Original ISF coordinates")
            var isfSurface=white;isfSurface.materialID=isf.id
            image=try frame([isfSurface],materials:[isf])
            for (x,y) in samplePoints {
                let uv=coordinate(x,y)
                try expect(near(pixel(image,x,y),bytes([uv.x,1-uv.y,0.25,1])),"ISF bottom-left coordinate origin was lost")
            }
            let isfRead=try ISFMaterial.importSource("/*{\"ISFVSN\":\"2\",\"INPUTS\":[{\"NAME\":\"inputImage\",\"TYPE\":\"image\"}]}*/ void main(){gl_FragColor=IMG_NORM_PIXEL(inputImage,vec2(isf_FragNormCoord.x,1-isf_FragNormCoord.y));}",name:"Original ISF flipped source")
            isfSurface.generator="gradient";isfSurface.materialID=isfRead.id
            image=try frame([isfSurface],materials:[isfRead])
            for (x,y) in samplePoints {let uv=coordinate(x,y);try expect(near(pixel(image,x,y),bytes([uv.x,1-uv.y,1-uv.x,1])),"ISF normalized sampler orientation differs")}
            passed("ISF normalized coordinates and image reads preserve y-up semantics without changing native UV")

            let lastGood=try frame([source],materials:[material])
            var invalid=material;invalid.expression="vec4(1); for(;;){}"
            var rejected=false
            do {try renderer.validateMaterial(invalid)} catch {rejected=true}
            try expect(rejected,"Invalid material source was accepted")
            let retained=try frame([source],materials:[invalid],allowDiagnostic:true)
            try expect(!renderer.errorDescription.isEmpty,"Invalid material did not provide a diagnostic")
            for (x,y) in samplePoints {try expect(pixel(retained,x,y)==pixel(lastGood,x,y),"Invalid code replaced last-good material pixels")}
            try expect(renderer.materialCache[material.id]?.definition == material,"Invalid code replaced accepted cache definition")
            passed("invalid material source retains accepted shader/cache and exact last-good pixels")

            let constant=MaterialDefinition(name:"Original RGBA palette",expression:"sourceColor",inputs:[MaterialInput(name:"sourceColor",kind:.color,defaultValue:[0.4,0.6,0.8,0.5],minimum:[0,0,0,0],maximum:[1,1,1,1])])
            var palette=white;palette.materialID=constant.id
            let cases:[([Double],EffectsSettings)]=[
                ([0,1,0,1],EffectsSettings(keyMode:.chroma,threshold:0.1,softness:0.2)),
                ([0.3,1,0,0.8],EffectsSettings(keyMode:.chroma,threshold:0.1,softness:0.2)),
                ([0.2,0.8,0.1,0.75],EffectsSettings(keyMode:.chroma,threshold:0,softness:0,spill:1)),
                ([0.25,0.25,0.25,0.8],EffectsSettings(keyMode:.luma,threshold:0.2,softness:0.1)),
                ([0.2,0.6,0.8,0.7],EffectsSettings(saturation:0,inverted:true,posterizeLevels:3))
            ]
            for (rgba,effects) in cases {
                palette.materialValues=["sourceColor":rgba];palette.effects=effects
                image=try frame([palette],materials:[constant])
                let expected=try Effects.evaluate(rgba,settings:effects)
                try expect(near(pixel(image,64,48),bytes(expected)),"Chroma/luma/spill/color FX differ from CPU oracle")
            }
            palette.materialValues=["sourceColor":[0,1,0,1]];palette.effects=EffectsSettings(keyMode:.chroma,threshold:0.05,softness:0)
            palette.color=[1,0,0]
            image=try frame([blue,palette],materials:[constant])
            try expect(near(pixel(image,64,48),[0,0,255,255]),"Chroma key was evaluated after tint or lost source alpha")
            passed("chroma/luma key, softness, spill, saturation, inversion and posterization match independent CPU values before tint")

            var background=white;background.color=[0.2,0.3,0.4]
            palette.color=[1,1,1];palette.effects = .init();palette.materialValues=["sourceColor":[0.4,0.6,0.8,0.5]]
            let dest=[0.2,0.3,0.4],rgb=[0.4,0.6,0.8],alpha=0.5
            for mode in ["normal","add","multiply","screen"] {
                palette.blendMode=mode;image=try frame([background,palette],materials:[constant])
                let expected=(0..<3).map { i -> Int in
                    let value:Double
                    switch mode {
                    case "add":value=dest[i]+rgb[i]*alpha
                    case "multiply":value=dest[i]*(1-alpha+rgb[i]*alpha)
                    case "screen":value=rgb[i]*alpha+dest[i]*(1-rgb[i]*alpha)
                    default:value=rgb[i]*alpha+dest[i]*(1-alpha)
                    }
                    return Int((min(1,max(0,value))*255).rounded())
                }+[255]
                try expect(near(pixel(image,64,48),expected),"Material \(mode) blend differs")
            }
            passed("accepted material executes normal/add/multiply/screen blend variants with premultiplied pixel oracles")

            var group=SurfaceGroup(name:"Opacity once",opacity:0.5);group.isolated=true
            var groupedRed=red,groupedBlue=blue;groupedRed.groupID=group.id;groupedBlue.groupID=group.id
            image=try frame([green,groupedRed,groupedBlue],groups:[group])
            try expect(near(pixel(image,64,48),[0,128,128,255]),"Isolated group opacity was applied to its children or more than once")
            group.isolated=false
            image=try frame([green,groupedRed,groupedBlue],groups:[group])
            try expect(near(pixel(image,64,48),[64,64,128,255]),"Legacy nonisolated group composition changed")
            passed("isolated group opacity applies once to composition while default groups preserve per-layer alpha")

            var blendGroup=SurfaceGroup(name:"Whole-group blend");blendGroup.isolated=true
            var blendChild=white;blendChild.groupID=blendGroup.id;blendChild.color=rgb;blendChild.opacity=alpha
            for mode in ["normal","add","multiply","screen"] {
                blendGroup.blendMode=mode
                image=try frame([background,blendChild],groups:[blendGroup])
                let expected=(0..<3).map { i -> Int in
                    let value:Double
                    switch mode {
                    case "add":value=dest[i]+rgb[i]*alpha
                    case "multiply":value=dest[i]*(1-alpha+rgb[i]*alpha)
                    case "screen":value=rgb[i]*alpha+dest[i]*(1-rgb[i]*alpha)
                    default:value=rgb[i]*alpha+dest[i]*(1-alpha)
                    }
                    return Int((min(1,max(0,value))*255).rounded())
                }+[255]
                try expect(near(pixel(image,64,48),expected),"Whole-group blend did not use composed alpha/color")
            }
            passed("isolated group normal/add/multiply/screen modes blend the composed item with its background")

            var parent=SurfaceGroup(name:"Outer isolated",opacity:0.5);parent.isolated=true
            var child=SurfaceGroup(name:"Inner isolated",parentID:parent.id,opacity:0.5);child.isolated=true
            groupedBlue.groupID=child.id
            image=try frame([green,groupedBlue],groups:[parent,child])
            try expect(near(pixel(image,64,48),[0,191,64,255]),"Nested isolated opacity was lost or multiplied twice")
            child.enabled=false
            image=try frame([green,groupedBlue],groups:[parent,child])
            try expect(near(pixel(image,64,48),[0,255,0,255]),"Hidden nested group still affected composition")
            passed("nested isolated groups preserve transparent intermediate alpha and inherited visibility")

            var keyedGroup=SurfaceGroup(name:"Composite color key")
            keyedGroup.effects=EffectsSettings(keyMode:.chroma,keyColor:[1.0/3,0,2.0/3],threshold:0.02,softness:0)
            var keyedRed=red,keyedBlue=blue
            keyedRed.groupID=keyedGroup.id;keyedBlue.groupID=keyedGroup.id;keyedRed.opacity=0.5;keyedBlue.opacity=0.5
            image=try frame([green,keyedRed,keyedBlue],groups:[keyedGroup])
            try expect(near(pixel(image,64,48),[0,255,0,255]),"Group chroma key did not evaluate the composed straight color once")
            passed("group FX key the composed color after isolation, rather than independently keying child layers")

            var scoped=SurfaceGroup(name:"Scoped local mask",transform:Affine2D(a:0.6,d:0.8,tx:0.2,ty:0.1))
            scoped.masks=[CompositionMask(points:[Point2(0,0),Point2(0.5,0),Point2(0.5,1),Point2(0,1)],settings:.init(space:.sourceUV))]
            groupedRed.groupID=scoped.id
            image=try frame([blue,groupedRed],groups:[scoped])
            try expect(near(pixel(image,40,48),[255,0,0,255]) && near(pixel(image,80,48),[0,0,255,255]) && near(pixel(image,8,48),[0,0,255,255]),"Group local mask escaped its transform/scope")
            let global=CompositionMask(points:[Point2(0.2,0.2),Point2(0.8,0.2),Point2(0.8,0.8),Point2(0.2,0.8)])
            var halfRed=red;halfRed.output=[Point2(0,0),Point2(0.5,0),Point2(0.5,1),Point2(0,1)]
            image=try frame([blue,halfRed],masks:[global])
            try expect(near(pixel(image,40,48),[255,0,0,255]) && near(pixel(image,90,48),[0,0,255,255]) && near(pixel(image,120,48),[0,0,0,255]),"Global mask was not applied after all layers")
            passed("group-local masks stay in group scope and global masks attenuate the complete composition")

            var holes=white
            holes.masks=[CompositionMask(points:Point2.insetQuad),CompositionMask(points:[Point2(0.3,0.3),Point2(0.7,0.3),Point2(0.7,0.7),Point2(0.3,0.7)],settings:.init(space:.outputCanvas,inverted:true))]
            image=try frame([blue,holes])
            try expect(near(pixel(image,25,20),[255,255,255,255]) && near(pixel(image,64,48),[0,0,255,255]) && near(pixel(image,4,48),[0,0,255,255]),"Multiple masks failed to make an independent layer hole")
            passed("multiple mask intersection and inverted holes reveal underlying layers without masking them")

            var curved=white;curved.masks=[CompositionMask(curve:.ellipse)]
            image=try frame([curved],width:64,height:64)
            var partial=0
            for y in 0..<64 {for x in 0..<64 {
                let point=coordinate(x,y,64,64),dx=point.x-0.5,dy=point.y-0.5,radius=hypot(dx,dy)
                let edge=0.4-radius
                let footprint=radius>0 ? (abs(dx)+abs(dy))/(radius*64) : 1.0/64
                let alpha=min(1,max(0,edge/footprint+0.5))
                let actual=pixel(image,x,y)[0]
                try expect(abs(actual-Int((alpha*255).rounded()))<=8,"Bezier ellipse derivative AA differs from analytic circle bound")
                if actual>0 && actual<255 {partial+=1}
            }}
            try expect(partial>=40,"Bezier mask has no antialiased boundary")
            passed("Bezier ellipse mask coverage and derivative antialias agree with an independent analytic boundary")

            let edge=EdgeBlendSettings(left:0.35,right:0.15,top:0.2,bottom:0.1,power:2,gamma:1.4,blackLevel:0.03)
            image=try frame([background],edge:edge)
            for (x,y) in [(2,2),(15,30),(64,48),(120,80),(70,91)] {
                let point=coordinate(x,y)
                let expected=(0..<3).map { i -> Int in
                    let v=EdgeBlend.channel(dest[i],at:point,settings:edge)
                    return Int((v*255).rounded())
                }+[255]
                try expect(near(pixel(image,x,y),expected,3),"Edge blend power/gamma/black channel differs")
            }
            let leftImage=try frame([white],edge:.init(left:1,power:2.3))
            let rightImage=try frame([white],edge:.init(right:1,power:2.3))
            for x in 0..<128 {try expect(abs(pixel(leftImage,x,48)[0]+pixel(rightImage,x,48)[0]-255)<=1,"Complementary edge ramps do not sum to one")}
            passed("edge blend channel oracle and complementary simulated projector ramps sum to unity")

            var warp=try BezierWarp.regular(quad:unit)
            for index in [5,6,9,10] {warp.controls[index].x+=0.08}
            var warped=Surface(name:"Bezier UV",input:[Point2(0.1,0.15),Point2(0.8,0.15),Point2(0.8,0.8),Point2(0.1,0.8)],output:unit,generator:"gradient")
            warped.bezierWarp=warp
            image=try frame([warped])
            for (x,y) in samplePoints {
                let point=coordinate(x,y),v=point.y
                var u=point.x
                for _ in 0..<12 {let f=u+0.72*u*(1-u)*v*(1-v)-point.x,derivative=1+0.72*(1-2*u)*v*(1-v);u-=f/derivative}
                let s=0.1+0.7*u,t=0.15+0.65*v
                try expect(near(pixel(image,x,y),bytes([s,t,1-s,1]),3),"Bezier warp changed source UV or exceeded its pixel oracle")
            }
            passed("Bezier output deformation preserves independent source crop under an analytic inverse oracle")

            // A diagonal centerline deliberately separates geometric cage UV
            // from arc-length/across-width source UV. The exact analytic line
            // oracle does not use StrokeGeometry.hit/samples or renderer grids.
            let start=Point2(0.2,0.25),end=Point2(0.8,0.75),strokeWidth=0.28,aspect=16.0/9
            let dx=(end.x-start.x)*aspect,dy=end.y-start.y,length=hypot(dx,dy)
            var line=Surface(name:"Stroke source domain",input:[Point2(0.1,0.15),Point2(0.85,0.15),Point2(0.85,0.8),Point2(0.1,0.8)],output:unit,generator:"gradient",shape:.line)
            line.stroke=StrokePath(nodes:[StrokeNode(anchor:start),StrokeNode(anchor:end)],width:strokeWidth)
            for curvedSource in [false,true] {
                var mapped=line
                if curvedSource {
                    mapped.bezierWarp=try BezierWarp.regular(quad:unit)
                    var input=try BezierWarp.regular(quad:mapped.input)
                    for index in [5,6,9,10] {input.controls[index].x+=0.1;input.controls[index].y-=0.07}
                    mapped.inputWarp=input
                } else {
                    mapped.meshColumns=2;mapped.meshRows=2
                    mapped.mesh=try Geometry.regularMesh(quad:unit,columns:2,rows:2)
                    mapped.inputMesh=try Geometry.regularMesh(quad:mapped.input,columns:2,rows:2)
                    mapped.inputMesh[4].x+=0.14;mapped.inputMesh[4].y-=0.08
                }
                let sourceMapping=try SurfaceSourceMapping(surface:mapped)
                image=try frame([mapped],width:320,height:180)
                var count=0
                for y in stride(from:12,to:169,by:6) {for x in stride(from:12,to:309,by:8) {
                    let p=coordinate(x,y,320,180),px=(p.x-start.x)*aspect,py=p.y-start.y
                    let along=min(1,max(0,(px*dx+py*dy)/(length*length)))
                    let ex=px-dx*along,ey=py-dy*along,distance=hypot(ex,ey)
                    let across=0.5+(dx*ey-dy*ex)/(length*strokeWidth)
                    guard distance < strokeWidth*0.5-0.025,along>0.08,along<0.92,across>0.08,across<0.92 else {continue}
                    let uv=try sourceMapping.point(at:Point2(along,across))
                    // Two bytes cover half a source texel (0.71 byte at
                    // 180px), raster/interpolation and UNORM quantization.
                    try expect(near(pixel(image,x,y),bytes([uv.x,uv.y,1-uv.x,1]),2),"Stroke source warp used cage-local instead of arc/across coordinates")
                    count+=1
                }}
                try expect(count>80,"Stroke source-domain oracle has too few full-coverage samples")
                passed(curvedSource ? "Bezier source warp follows stroke arc/across UV after crop, within half-texel/UNORM tolerance" : "regular input mesh follows stroke arc/across UV after crop, independently from geometric cage UV")
            }

            guard let feedback=FeedbackComposition(media:media) else {throw Failure(message:"Feedback queue unavailable")}
            let routeA=OutputConfig(id:UUID(uuidString:"11111111-1111-4111-8111-111111111111")!,name:"Feedback A",width:32,height:18)
            let routeB=OutputConfig(id:UUID(uuidString:"22222222-2222-4222-8222-222222222222")!,name:"Feedback B",width:32,height:18)
            var seedA=red;seedA.outputID=routeA.id
            var selfRead=white;selfRead.outputID=routeA.id;selfRead.feedbackOutputID=routeA.id;selfRead.opacity=0.5
            func advance(_ surfaces:[Surface],_ outputs:[OutputConfig],blackout:Bool=false) {
                feedback.advance(surfaces:surfaces,outputs:outputs,groups:[],masks:[],materials:[],time:0,blackout:blackout)
            }
            func finish(_ count:UInt64) throws {
                try expect(pump({!feedback.pending && feedback.completedFrames>=count}),"Feedback completion timeout: "+feedback.errorDescription)
                try expect(feedback.errorDescription.isEmpty,"Feedback diagnostic: "+feedback.errorDescription)
            }
            func read(_ id:UUID) throws -> [Int] {
                var reader=white;reader.feedbackOutputID=id
                let result=try frame([reader],feedback:feedback.textures,lease:feedback.frame,width:32,height:18)
                return pixel(result,16,9)
            }
            advance([seedA,selfRead],[routeA]);try expect(feedback.pending,"Feedback did not begin asynchronously")
            let skipped=feedback.skippedFrames;advance([seedA,selfRead],[routeA])
            try expect(feedback.skippedFrames==skipped+1,"In-flight feedback input was not coalesced/dropped")
            try finish(1);try expect(near(try read(routeA.id),[128,0,0,255]),"First feedback frame did not start from black history")
            advance([seedA,selfRead],[routeA]);try finish(2);try expect(near(try read(routeA.id),[191,0,0,255]),"Second feedback frame did not read exactly one previous generation")
            advance([seedA,selfRead],[routeA]);try finish(3);try expect(near(try read(routeA.id),[223,0,0,255]),"Self feedback cycle did not converge deterministically")
            passed("self-loopback reads one completed prior generation and drops input while GPU work is pending")

            renderer.feedbackFrame=nil;renderer.feedbackTextures=[:];feedback.reset()
            var crossA=selfRead;crossA.feedbackOutputID=routeB.id
            var seedB=green;seedB.outputID=routeB.id
            var crossB=selfRead;crossB.outputID=routeB.id;crossB.feedbackOutputID=routeA.id
            let cross=[seedA,crossA,seedB,crossB]
            advance(cross,[routeB,routeA]);try finish(1)
            try expect(near(try read(routeA.id),[128,0,0,255]) && near(try read(routeB.id),[0,128,0,255]),"Cross-route initial history differs")
            advance(cross,[routeA,routeB]);try finish(2)
            try expect(near(try read(routeA.id),[128,64,0,255]) && near(try read(routeB.id),[64,128,0,255]),"Cross routes read different generations or depended on output ordering")
            passed("two-route feedback cycles share one immutable previous generation independent of route order")

            renderer.feedbackFrame=nil;renderer.feedbackTextures=[:];feedback.reset()
            advance([seedA,selfRead],[routeA]);try expect(feedback.pending,"Reset fixture did not submit")
            feedback.reset()
            try expect(feedback.frame==nil && feedback.completedFrames==0,"Reset retained a published frame")
            try expect(pump({!feedback.pending}),"Reset did not release in-flight ownership")
            try expect(feedback.frame==nil && feedback.completedFrames==0,"Old GPU completion republished after reset")
            advance([seedA,selfRead],[routeA]);try finish(1)
            passed("feedback reset suppresses stale GPU completion and permits a new generation")

            renderer.feedbackFrame=nil;renderer.feedbackTextures=[:];feedback.reset()
            advance([seedA,selfRead],[routeA]);try expect(feedback.pending,"Invalid topology fixture did not submit")
            advance([seedA,selfRead],[])
            try expect(pump({!feedback.pending}),"Invalid topology failed to release pending work")
            try expect(feedback.frame==nil && feedback.completedFrames==0,"Pending work published textures after its route became invalid")
            advance([seedA,selfRead],[routeA]);try finish(1)
            advance([seedA,selfRead],[routeA],blackout:true);try finish(2)
            try expect(near(try read(routeA.id),[0,0,0,255]),"Blackout feedback generation was not black")
            passed("invalid feedback topology cancels publication; blackout is a new black generation")

            renderer.feedbackFrame=nil;renderer.feedbackTextures=[:];feedback.reset()
            var retainedFrames:[FeedbackFrame]=[]
            for count in 1...4 {
                advance([seedA,selfRead],[routeA]);try finish(UInt64(count))
                guard let lease=feedback.frame else {throw Failure(message:"Feedback frame missing")};retainedFrames.append(lease)
            }
            let bounded=feedback.skippedFrames
            advance([seedA,selfRead],[routeA])
            try expect(!feedback.pending && feedback.completedFrames==4 && feedback.skippedFrames==bounded+1,"Feedback retained-generation budget did not apply backpressure")
            retainedFrames.removeAll()
            advance([seedA,selfRead],[routeA]);try finish(5)
            passed("feedback retains at most four leased generations and resumes after consumers release them")
            renderer.feedbackFrame=nil;renderer.feedbackTextures=[:];feedback.reset()
            for (width,height) in [(-1,18),(32,0),(Int.min,18),(Int.max,18),(32,Int.max)] {
                let invalidRoute=OutputConfig(id:routeA.id,name:"Invalid fixture",width:width,height:height)
                advance([seedA,selfRead],[invalidRoute])
                try expect(!feedback.pending && feedback.frame==nil && feedback.completedFrames==0 && !feedback.errorDescription.isEmpty,"Invalid feedback dimensions reached allocation or published a partial frame")
            }
            advance([seedA,selfRead],[routeA]);try finish(1)
            try expect(near(try read(routeA.id),[128,0,0,255]),"Feedback failed to recover after invalid dimensions")
            passed("feedback rejects negative/zero/overflow dimensions before allocation and recovers atomically")
            renderer.feedbackFrame=nil;renderer.feedbackTextures=[:];feedback.reset()
            media.pause()
            save(true)
            print("PASS composition integration: \(checks.count) checks. \(url.path)")
            return 0
        } catch {
            save(false,error.localizedDescription)
            fputs("COMPOSITION TEST FAILED: \(error.localizedDescription)\n",stderr)
            return 1
        }
    }
}
#endif
