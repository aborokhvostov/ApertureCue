#if os(macOS)
import Foundation
import MappingCore

extension DemoGenerator {
    /// Original GPL-3.0-or-later procedural composition. No external media,
    /// shader assets, display bindings, network or hardware setup is required.
    static func generateComposition(at directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        func quad(_ x:Double,_ y:Double,_ width:Double,_ height:Double)->[Point2] {
            [Point2(x,y),Point2(x+width,y),Point2(x+width,y+height),Point2(x,y+height)]
        }
        let left=OutputConfig(name:"Composition A · warped color",width:1280,height:720)
        let right=OutputConfig(name:"Composition B · posterized color",width:1280,height:720)
        let material=MaterialDefinition(name:"Original animated spectrum",
            expression:"vec4(0.15+0.75*uv.x,0.25+0.55*uv.y,0.55+0.2*sin(time*speed),1)",
            inputs:[MaterialInput(name:"speed",label:"Spectrum clock speed",defaultValue:[0.8],minimum:[0],maximum:[3])],
            credit:"ApertureCue contributors; GPL-3.0-or-later; original procedural expression")

        var group=SurfaceGroup(name:"Isolated color lens",opacity:0.82)
        group.isolated=true
        group.transform=try .perspective(to:[Point2(0.01,0.02),Point2(0.99,0),Point2(0.97,0.98),Point2(0.02,1)])
        func lensPoint(_ p:Point2)->Point2 {Point2(0.02+p.x*0.64,0.06+p.y*0.82)}
        let lens=BezierMask(nodes:BezierMask.ellipse.nodes.map {
            StrokeNode(anchor:lensPoint($0.anchor),incoming:lensPoint($0.incoming),outgoing:lensPoint($0.outgoing))
        })
        group.masks=[CompositionMask(name:"Cubic group lens",curve:lens,settings:.init(space:.sourceUV,feather:0.012))]

        let background=Surface(name:"01 · shared navy grid",output:Point2.unitQuad,brightness:0.35,color:[0.25,0.35,0.55],generator:"grid")
        var card=Surface(name:"02 · output + source Bezier",input:quad(0.05,0.05,0.9,0.9),output:quad(0.07,0.15,0.49,0.61),
                         outputID:left.id,generator:"gradient",groupID:group.id)
        card.materialID=material.id;card.materialValues=["speed":[0.8]]
        var outputWarp=try BezierWarp.regular(quad:Point2.unitQuad,columns:1,rows:1)
        outputWarp.controls[1].y = -0.12;outputWarp.controls[2].y = -0.12
        outputWarp.controls[13].y = 1.08;outputWarp.controls[14].y = 1.08
        card.bezierWarp=outputWarp;card.warpTransform=try .perspective(to:card.output)
        var inputWarp=try BezierWarp.regular(quad:Point2.unitQuad,columns:1,rows:1)
        inputWarp.controls[5]=Point2(0.46,0.26);inputWarp.controls[10]=Point2(0.56,0.76)
        card.inputWarp=inputWarp;card.inputWarpTransform=try .perspective(to:card.input)
        // Start unlinked: changing the output controls must preserve this source.
        card.meshLinked=false

        var circle=Surface(name:"03 · overlapping screen ellipse",output:quad(0.29,0.3,0.34,0.49),opacity:0.72,
                           blendMode:"screen",color:[0.1,0.85,1],outputID:left.id,generator:"gradient",shape:.ellipse,groupID:group.id)
        circle.effects=EffectsSettings(saturation:1.35)
        var poster=Surface(name:"04 · material + posterize FX",input:quad(0.1,0,0.85,1),output:quad(0.67,0.17,0.27,0.58),
                           feather:0.025,outputID:right.id,generator:"gradient")
        poster.materialID=material.id;poster.materialValues=["speed":[1.4]]
        poster.effects=EffectsSettings(saturation:0.35,posterizeLevels:5)
        poster.masks=[CompositionMask(name:"Layer cubic aperture",curve:.ellipse,settings:.init(space:.sourceUV,feather:0.015))]
        var line=Surface(name:"05 · shared original cubic accent",output:quad(0.08,0.78,0.85,0.16),
                         color:[1,0.58,0.16],generator:"solid",shape:.bezier)
        line.stroke=StrokePath(nodes:[
            StrokeNode(anchor:Point2(0.03,0.65),outgoing:Point2(0.3,0.08)),
            StrokeNode(anchor:Point2(0.97,0.35),incoming:Point2(0.7,0.92))
        ],width:0.065)
        let layers=[background,card,circle,poster,line]
        var variant=layers
        variant[1].materialValues=["speed":[1.8]]
        variant[3].effects=EffectsSettings(saturation:1.3,inverted:true,posterizeLevels:8)
        var project=Project(name:"ApertureCue Composition · original procedural demo",surfaces:layers,outputs:[left,right],
                            cues:[Cue(name:"Original spectrum",surfaces:layers,duration:0),Cue(name:"Alternate layer FX",surfaces:variant,duration:0.5)],
                            groups:[group],timelineSettings:TimelineSettings(duration:12,loopEnabled:true,loopStart:0,loopEnd:12))
        project.materials=[material]
        project.globalMasks=[CompositionMask(name:"Global canvas inset",points:quad(0.015,0.025,0.97,0.95),settings:.init(space:.outputCanvas,feather:0.008))]
        try ProjectStore.save(project,to:directory.appendingPathComponent("Composition.aperturecue.json"))
    }
}
#endif
