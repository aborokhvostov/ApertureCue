import Foundation

public struct Surface: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var mediaID: UUID?
    public var input: [Point2]
    public var output: [Point2]
    public var opacity: Double
    public var brightness: Double
    public var enabled: Bool
    public var blendMode: String
    public var feather: Double
    public var gamma: Double
    public var color: [Double]
    public var mask: [Point2]
    public var meshColumns: Int
    public var meshRows: Int
    public var mesh: [Point2]
    public var group: String
    public var groupID: UUID?
    public var outputID: UUID?
    public var generator: String
    public var shape: SurfaceShape
    public var stroke: StrokePath

    public init(id: UUID = UUID(), name: String = "Surface", mediaID: UUID? = nil,
                input: [Point2] = Point2.unitQuad, output: [Point2] = Point2.insetQuad,
                opacity: Double = 1, brightness: Double = 1, enabled: Bool = true,
                blendMode: String = "normal", feather: Double = 0, gamma: Double = 1,
                color: [Double] = [1,1,1], mask: [Point2] = [],
                meshColumns: Int = 0, meshRows: Int = 0, mesh: [Point2] = [],
                group: String = "", outputID: UUID? = nil, generator: String = "checker", shape: SurfaceShape = .quad, groupID: UUID? = nil, stroke: StrokePath = .line) {
        self.id=id; self.name=name; self.mediaID=mediaID; self.input=input; self.output=output
        self.opacity=opacity; self.brightness=brightness; self.enabled=enabled; self.blendMode=blendMode
        self.feather=feather; self.gamma=gamma; self.color=color; self.mask=mask
        self.meshColumns=meshColumns; self.meshRows=meshRows; self.mesh=mesh
        self.group=group; self.outputID=outputID; self.generator=generator; self.shape=shape; self.groupID=groupID; self.stroke=stroke
    }
    private enum CodingKeys: String, CodingKey {
        case id,name,mediaID,input,output,opacity,brightness,enabled,blendMode,feather,gamma,color,mask,meshColumns,meshRows,mesh,group,outputID,generator,shape,groupID,stroke
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey:.id) ?? UUID(),
                  name: try c.decodeIfPresent(String.self, forKey:.name) ?? "Surface",
                  mediaID: try c.decodeIfPresent(UUID.self, forKey:.mediaID),
                  input: try c.decodeIfPresent([Point2].self, forKey:.input) ?? Point2.unitQuad,
                  output: try c.decodeIfPresent([Point2].self, forKey:.output) ?? Point2.insetQuad,
                  opacity: try c.decodeIfPresent(Double.self, forKey:.opacity) ?? 1,
                  brightness: try c.decodeIfPresent(Double.self, forKey:.brightness) ?? 1,
                  enabled: try c.decodeIfPresent(Bool.self, forKey:.enabled) ?? true,
                  blendMode: try c.decodeIfPresent(String.self, forKey:.blendMode) ?? "normal",
                  feather: try c.decodeIfPresent(Double.self, forKey:.feather) ?? 0,
                  gamma: try c.decodeIfPresent(Double.self, forKey:.gamma) ?? 1,
                  color: try c.decodeIfPresent([Double].self, forKey:.color) ?? [1,1,1],
                  mask: try c.decodeIfPresent([Point2].self, forKey:.mask) ?? [],
                  meshColumns: try c.decodeIfPresent(Int.self, forKey:.meshColumns) ?? 0,
                  meshRows: try c.decodeIfPresent(Int.self, forKey:.meshRows) ?? 0,
                  mesh: try c.decodeIfPresent([Point2].self, forKey:.mesh) ?? [],
                  group: try c.decodeIfPresent(String.self, forKey:.group) ?? "",
                  outputID: try c.decodeIfPresent(UUID.self, forKey:.outputID),
                  generator: try c.decodeIfPresent(String.self, forKey:.generator) ?? "checker",
                  shape: try c.decodeIfPresent(SurfaceShape.self, forKey:.shape) ?? .quad,
                  groupID: try c.decodeIfPresent(UUID.self, forKey:.groupID),
                  stroke: try c.decodeIfPresent(StrokePath.self, forKey:.stroke) ?? .line)
    }
}

public struct MediaAsset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Absolute while in memory; ProjectStore writes a path relative to the project file.
    public var path: String
    public var kind: String
    public var loop: Bool
    public var volume: Double
    public init(id: UUID = UUID(), name: String, path: String, kind: String, loop: Bool = true, volume: Double = 1) {
        self.id=id; self.name=name; self.path=path; self.kind=kind; self.loop=loop; self.volume=volume
    }
    private enum CodingKeys: String, CodingKey { case id,name,path,kind,loop,volume }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey:.id) ?? UUID(),
                  name: try c.decode(String.self, forKey:.name), path: try c.decode(String.self, forKey:.path),
                  kind: try c.decode(String.self, forKey:.kind), loop: try c.decodeIfPresent(Bool.self, forKey:.loop) ?? true,
                  volume: try c.decodeIfPresent(Double.self, forKey:.volume) ?? 1)
    }
}

public struct OutputConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var screenIndex: Int
    public var width: Int
    public var height: Int
    public init(id: UUID = UUID(), name: String = "Output", screenIndex: Int = 0, width: Int = 1920, height: Int = 1080) {
        self.id=id; self.name=name; self.screenIndex=screenIndex; self.width=width; self.height=height
    }
}

public struct Cue: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var surfaces: [Surface]
    /// Transition duration in seconds.
    public var duration: Double
    /// If set, trigger the next cue this many seconds after this cue's transition completes.
    public var followAfter: Double?
    public init(id: UUID = UUID(), name: String, surfaces: [Surface], duration: Double = 1, followAfter: Double? = nil) {
        self.id=id; self.name=name; self.surfaces=surfaces; self.duration=duration; self.followAfter=followAfter
    }
}

public struct Project: Codable, Equatable, Sendable {
    public static let currentVersion = 4
    public var version: Int
    public var name: String
    public var assets: [MediaAsset]
    /// Back-to-front render order.
    public var surfaces: [Surface]
    public var outputs: [OutputConfig]
    public var cues: [Cue]
    public var fixtures: [Fixture]
    public var timeline: [AutomationTrack]
    public var groups: [SurfaceGroup]
    public init(version: Int = Project.currentVersion, name: String = "Untitled", assets: [MediaAsset] = [],
                surfaces: [Surface] = [], outputs: [OutputConfig] = [], cues: [Cue] = [],
                fixtures: [Fixture] = [], timeline: [AutomationTrack] = [], groups: [SurfaceGroup] = []) {
        self.version=version; self.name=name; self.assets=assets; self.surfaces=surfaces; self.outputs=outputs; self.cues=cues
        self.fixtures=fixtures; self.timeline=timeline; self.groups=groups
    }
    public static func demo() -> Project {
        let output = OutputConfig(name:"Projector 1")
        let left = Surface(name:"Perspective test", output:[Point2(0.04,0.12),Point2(0.49,0.23),Point2(0.46,0.88),Point2(0.09,0.8)], generator:"checker")
        let right = Surface(name:"Color gradient", output:[Point2(0.54,0.16),Point2(0.94,0.08),Point2(0.91,0.88),Point2(0.56,0.82)], generator:"gradient")
        var cueSurfaces = [left,right]
        cueSurfaces[0].output = [Point2(0.04,0.06),Point2(0.48,0.06),Point2(0.48,0.94),Point2(0.04,0.94)]
        cueSurfaces[1].output = [Point2(0.52,0.06),Point2(0.96,0.06),Point2(0.96,0.94),Point2(0.52,0.94)]
        return Project(name:"ApertureCue Demo", surfaces:[left,right], outputs:[output], cues:[
            Cue(name:"Perspective", surfaces:[left,right], duration:1),
            Cue(name:"Aligned", surfaces:cueSurfaces, duration:2)
        ])
    }
    private enum CodingKeys: String, CodingKey { case version,name,assets,surfaces,outputs,cues,fixtures,timeline,groups }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        self.init(version: try c.decodeIfPresent(Int.self, forKey:.version) ?? 0,
                  name: try c.decodeIfPresent(String.self, forKey:.name) ?? "Untitled",
                  assets: try c.decodeIfPresent([MediaAsset].self, forKey:.assets) ?? [],
                  surfaces: try c.decodeIfPresent([Surface].self, forKey:.surfaces) ?? [],
                  outputs: try c.decodeIfPresent([OutputConfig].self, forKey:.outputs) ?? [],
                  cues: try c.decodeIfPresent([Cue].self, forKey:.cues) ?? [],
                  fixtures: try c.decodeIfPresent([Fixture].self, forKey:.fixtures) ?? [],
                  timeline: try c.decodeIfPresent([AutomationTrack].self, forKey:.timeline) ?? [],
                  groups: try c.decodeIfPresent([SurfaceGroup].self, forKey:.groups) ?? [])
    }
}
