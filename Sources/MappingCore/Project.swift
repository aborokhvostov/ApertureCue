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
    private var customTriangleVertices: [Point2]?
    public var triangleVertices: [Point2] {
        get { customTriangleVertices ?? TriangleGeometry.canonical }
        set { customTriangleVertices = newValue == TriangleGeometry.canonical ? nil : newValue }
    }

    public init(id: UUID = UUID(), name: String = "Surface", mediaID: UUID? = nil,
                input: [Point2] = Point2.unitQuad, output: [Point2] = Point2.insetQuad,
                opacity: Double = 1, brightness: Double = 1, enabled: Bool = true,
                blendMode: String = "normal", feather: Double = 0, gamma: Double = 1,
                color: [Double] = [1,1,1], mask: [Point2] = [],
                meshColumns: Int = 0, meshRows: Int = 0, mesh: [Point2] = [],
                group: String = "", outputID: UUID? = nil, generator: String = "checker", shape: SurfaceShape = .quad, groupID: UUID? = nil, stroke: StrokePath = .line,
                triangleVertices: [Point2] = TriangleGeometry.canonical) {
        self.id=id; self.name=name; self.mediaID=mediaID; self.input=input; self.output=output
        self.opacity=opacity; self.brightness=brightness; self.enabled=enabled; self.blendMode=blendMode
        self.feather=feather; self.gamma=gamma; self.color=color; self.mask=mask
        self.meshColumns=meshColumns; self.meshRows=meshRows; self.mesh=mesh
        self.group=group; self.outputID=outputID; self.generator=generator; self.shape=shape; self.groupID=groupID; self.stroke=stroke
        self.triangleVertices = triangleVertices
    }
    private enum CodingKeys: String, CodingKey {
        case id,name,mediaID,input,output,opacity,brightness,enabled,blendMode,feather,gamma,color,mask,meshColumns,meshRows,mesh,group,outputID,generator,shape,groupID,stroke
        case customTriangleVertices = "triangleVertices"
    }
    public init(from decoder: Decoder) throws { try self.init(from:decoder,legacyTriangle:false) }
    init(from decoder: Decoder, legacyTriangle: Bool) throws {
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
                  stroke: try c.decodeIfPresent(StrokePath.self, forKey:.stroke) ?? .line,
                  triangleVertices: legacyTriangle ? TriangleGeometry.canonical :
                      try c.decodeIfPresent([Point2].self, forKey:.customTriangleVertices) ?? TriangleGeometry.canonical)
    }

    static func decodeLegacyTriangles(from entries: inout UnkeyedDecodingContainer) throws -> [Surface] {
        var surfaces: [Surface] = []
        while !entries.isAtEnd {
            surfaces.append(try Surface(from:entries.superDecoder(),legacyTriangle:true))
        }
        return surfaces
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
    /// Legacy display position. Fullscreen routing uses displayUUID.
    public var screenIndex: Int
    public var displayUUID: UUID?
    public var width: Int
    public var height: Int
    public init(id: UUID = UUID(), name: String = "Output", screenIndex: Int = 0, width: Int = 1920, height: Int = 1080,
                displayUUID: UUID? = nil) {
        self.id=id; self.name=name; self.screenIndex=screenIndex; self.width=width; self.height=height
        self.displayUUID=displayUUID
    }

    private enum CodingKeys: String, CodingKey { case id,name,screenIndex,width,height,displayUUID }
    public init(from decoder: Decoder) throws { try self.init(from:decoder,legacyDisplay:false) }
    init(from decoder: Decoder, legacyDisplay: Bool) throws {
        let fields = try decoder.container(keyedBy:CodingKeys.self)
        self.init(id:try fields.decode(UUID.self,forKey:.id),
                  name:try fields.decode(String.self,forKey:.name),
                  screenIndex:try fields.decode(Int.self,forKey:.screenIndex),
                  width:try fields.decode(Int.self,forKey:.width),
                  height:try fields.decode(Int.self,forKey:.height),
                  displayUUID:legacyDisplay ? nil : try fields.decodeIfPresent(UUID.self,forKey:.displayUUID))
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
    public var scope: CueScope
    public var bindings: [CueBinding]
    public init(id: UUID = UUID(), name: String, surfaces: [Surface], duration: Double = 1, followAfter: Double? = nil,
                scope: CueScope = .full, bindings: [CueBinding] = []) {
        self.id=id; self.name=name; self.surfaces=surfaces; self.duration=duration; self.followAfter=followAfter
        self.scope=scope; self.bindings=bindings
    }
    private enum CodingKeys:String,CodingKey { case id,name,surfaces,duration,followAfter,scope,bindings }
    public init(from decoder:Decoder) throws { try self.init(from:decoder,legacy:false,legacyTriangle:false) }
    /// Extension keys in older schemas have no selective-cue meaning, even when
    /// their values cannot be decoded as the schema-6 types.
    init(from decoder:Decoder,legacy:Bool,legacyTriangle:Bool) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        let surfaces: [Surface]
        if legacyTriangle {
            var entries = try c.nestedUnkeyedContainer(forKey:.surfaces)
            surfaces = try Surface.decodeLegacyTriangles(from:&entries)
        } else { surfaces = try c.decode([Surface].self,forKey:.surfaces) }
        self.init(id:try c.decode(UUID.self,forKey:.id),name:try c.decode(String.self,forKey:.name),
                  surfaces:surfaces,
                  duration:try c.decode(Double.self,forKey:.duration),
                  followAfter:try c.decodeIfPresent(Double.self,forKey:.followAfter),
                  scope:legacy ? .full : try c.decode(CueScope.self,forKey:.scope),
                  bindings:legacy ? [] : try c.decode([CueBinding].self,forKey:.bindings))
    }
}

public struct Project: Codable, Equatable, Sendable {
    public static let currentVersion = 10
    public var version: Int
    public var name: String
    public var assets: [MediaAsset]
    /// Back-to-front render order.
    public var surfaces: [Surface]
    public var outputs: [OutputConfig]
    public var cues: [Cue]
    public var fixtures: [Fixture]
    public var timeline: [AutomationTrack]
    public var timelineSettings:TimelineSettings
    public var groups: [SurfaceGroup]
    public var montages:[MediaMontage]
    /// Editor state for current layers, independent of scene snapshots.
    public var geometryLockedSurfaceIDs: Set<UUID>
    public var sourceMediaIDs:Set<UUID> {Set(assets.map(\.id)+(version>=7 ? montages.map(\.id) : []))}
    public init(version: Int = Project.currentVersion, name: String = "Untitled", assets: [MediaAsset] = [],
                surfaces: [Surface] = [], outputs: [OutputConfig] = [], cues: [Cue] = [],
                fixtures: [Fixture] = [], timeline: [AutomationTrack] = [], groups: [SurfaceGroup] = [], timelineSettings:TimelineSettings? = nil,
                montages:[MediaMontage]=[], geometryLockedSurfaceIDs: Set<UUID> = []) {
        self.version=version; self.name=name; self.assets=assets; self.surfaces=surfaces; self.outputs=outputs; self.cues=cues
        self.fixtures=fixtures; self.timeline=timeline; self.groups=groups
        self.timelineSettings=timelineSettings ?? TimelineSettings.inferred(from:timeline)
        self.montages=montages
        self.geometryLockedSurfaceIDs = geometryLockedSurfaceIDs
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
    private enum CodingKeys: String, CodingKey { case version,name,assets,surfaces,outputs,cues,fixtures,timeline,groups,timelineSettings,montages,geometryLockedSurfaceIDs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        let version=try c.decodeIfPresent(Int.self,forKey:.version) ?? 0
        guard version>=0,version<=Self.currentVersion else {throw ProjectError.unsupportedVersion(version)}
        let lockIDs = version < 8 ? [] : try c.decode([UUID].self, forKey: .geometryLockedSurfaceIDs)
        let locks = Set(lockIDs)
        guard locks.count == lockIDs.count else { throw ProjectError.invalid("duplicate geometry lock IDs") }
        var cues:[Cue]=[]
        if c.contains(.cues) {
            var entries=try c.nestedUnkeyedContainer(forKey:.cues)
            while !entries.isAtEnd { cues.append(try Cue(from:entries.superDecoder(),legacy:version < 6,legacyTriangle:version < 9)) }
        }
        let surfaces: [Surface]
        if version < 9, c.contains(.surfaces), try !c.decodeNil(forKey:.surfaces) {
            var entries = try c.nestedUnkeyedContainer(forKey:.surfaces)
            surfaces = try Surface.decodeLegacyTriangles(from:&entries)
        } else { surfaces = try c.decodeIfPresent([Surface].self,forKey:.surfaces) ?? [] }
        var outputs: [OutputConfig] = []
        if version < 10, c.contains(.outputs), try !c.decodeNil(forKey:.outputs) {
            var entries = try c.nestedUnkeyedContainer(forKey:.outputs)
            while !entries.isAtEnd { outputs.append(try OutputConfig(from:entries.superDecoder(),legacyDisplay:true)) }
        } else { outputs = try c.decodeIfPresent([OutputConfig].self,forKey:.outputs) ?? [] }
        self.init(version: version,
                  name: try c.decodeIfPresent(String.self, forKey:.name) ?? "Untitled",
                  assets: try c.decodeIfPresent([MediaAsset].self, forKey:.assets) ?? [],
                  surfaces: surfaces,
                  outputs: outputs,
                  cues: cues,
                  fixtures: try c.decodeIfPresent([Fixture].self, forKey:.fixtures) ?? [],
                  timeline: try c.decodeIfPresent([AutomationTrack].self, forKey:.timeline) ?? [],
                  groups: try c.decodeIfPresent([SurfaceGroup].self, forKey:.groups) ?? [],
                  timelineSettings:try c.decodeIfPresent(TimelineSettings.self,forKey:.timelineSettings),
                  montages:version<7 ? [] : try c.decode([MediaMontage].self,forKey:.montages),
                  geometryLockedSurfaceIDs: locks)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encode(assets, forKey: .assets)
        try c.encode(surfaces, forKey: .surfaces)
        try c.encode(outputs, forKey: .outputs)
        try c.encode(cues, forKey: .cues)
        try c.encode(fixtures, forKey: .fixtures)
        try c.encode(timeline, forKey: .timeline)
        try c.encode(groups, forKey: .groups)
        try c.encode(timelineSettings, forKey: .timelineSettings)
        try c.encode(montages, forKey: .montages)
        if version >= 8 {
            try c.encode(geometryLockedSurfaceIDs.map(\.uuidString).sorted(), forKey: .geometryLockedSurfaceIDs)
        }
    }
}
