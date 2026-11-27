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
    public var maskSettings: PolygonMaskSettings
    public var masks:[CompositionMask] = []
    public var effects:EffectsSettings = .init()
    public var materialID:UUID? = nil
    public var materialValues:[String:[Double]] = [:]
    public var feedbackOutputID:UUID? = nil
    public var inputMesh:[Point2] = []
    public var meshWeights:[Double] = []
    public var meshLinked:Bool = false
    public var bezierWarp:BezierWarp? = nil
    public var warpTransform:Affine2D = .identity
    public var inputWarp:BezierWarp? = nil
    public var inputWarpTransform:Affine2D = .identity
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
                triangleVertices: [Point2] = TriangleGeometry.canonical, maskSettings: PolygonMaskSettings = .init()) {
        self.id=id; self.name=name; self.mediaID=mediaID; self.input=input; self.output=output
        self.opacity=opacity; self.brightness=brightness; self.enabled=enabled; self.blendMode=blendMode
        self.feather=feather; self.gamma=gamma; self.color=color; self.mask=mask
        self.meshColumns=meshColumns; self.meshRows=meshRows; self.mesh=mesh
        self.group=group; self.outputID=outputID; self.generator=generator; self.shape=shape; self.groupID=groupID; self.stroke=stroke
        self.maskSettings = maskSettings; self.triangleVertices = triangleVertices
    }
    private enum CodingKeys: String, CodingKey {
        case id,name,mediaID,input,output,opacity,brightness,enabled,blendMode,feather,gamma,color,mask,meshColumns,meshRows,mesh,group,outputID,generator,shape,groupID,stroke
        case maskSettings,masks,effects,materialID,materialValues,feedbackOutputID,inputMesh,meshWeights,meshLinked,bezierWarp,warpTransform,inputWarp,inputWarpTransform
        case customTriangleVertices = "triangleVertices"
    }
    public init(from decoder: Decoder) throws { try self.init(from:decoder,legacyTriangle:false,legacyMask:false,legacyComposition:false) }
    init(from decoder: Decoder, legacyTriangle: Bool, legacyMask: Bool, legacyComposition:Bool) throws {
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
                      try c.decodeIfPresent([Point2].self, forKey:.customTriangleVertices) ?? TriangleGeometry.canonical,
                  maskSettings: legacyMask ? .init() : try c.decodeIfPresent(PolygonMaskSettings.self,forKey:.maskSettings) ?? .init())
        if !legacyComposition {
            masks=try c.decodeIfPresent([CompositionMask].self,forKey:.masks) ?? []
            effects=try c.decodeIfPresent(EffectsSettings.self,forKey:.effects) ?? .init()
            materialID=try c.decodeIfPresent(UUID.self,forKey:.materialID)
            materialValues=try c.decodeIfPresent([String:[Double]].self,forKey:.materialValues) ?? [:]
            feedbackOutputID=try c.decodeIfPresent(UUID.self,forKey:.feedbackOutputID)
            inputMesh=try c.decodeIfPresent([Point2].self,forKey:.inputMesh) ?? []
            meshWeights=try c.decodeIfPresent([Double].self,forKey:.meshWeights) ?? []
            meshLinked=try c.decodeIfPresent(Bool.self,forKey:.meshLinked) ?? false
            bezierWarp=try c.decodeIfPresent(BezierWarp.self,forKey:.bezierWarp)
            warpTransform=try c.decodeIfPresent(Affine2D.self,forKey:.warpTransform) ?? .identity
            inputWarp=try c.decodeIfPresent(BezierWarp.self,forKey:.inputWarp)
            inputWarpTransform=try c.decodeIfPresent(Affine2D.self,forKey:.inputWarpTransform) ?? .identity
        }
    }

    static func decodeSurfaces(from entries: inout UnkeyedDecodingContainer, version: Int) throws -> [Surface] {
        var surfaces: [Surface] = []
        while !entries.isAtEnd {
            surfaces.append(try Surface(from:entries.superDecoder(),legacyTriangle:version < 9,legacyMask:version < 11,legacyComposition:version < 12))
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
    public var hasLocalFile: Bool { kind != "camera" && kind != "external-video" }
    public var loop: Bool
    public var volume: Double
    /// Nil retains the pre-schema13 loop flag's exact playback meaning.
    public var playback:MediaPlaybackSettings?
    public var sequence:MediaSequenceSettings?
    /// Nil leaves ordinary AVPlayer system audio active; explicit settings select routed PCM.
    public var audioRouting:AudioRoutingSettings?
    public init(id: UUID = UUID(), name: String, path: String, kind: String, loop: Bool = true, volume: Double = 1,
                playback:MediaPlaybackSettings?=nil,sequence:MediaSequenceSettings?=nil,audioRouting:AudioRoutingSettings?=nil) {
        self.id=id; self.name=name; self.path=path; self.kind=kind; self.loop=loop; self.volume=volume
        self.playback=playback;self.sequence=sequence;self.audioRouting=audioRouting
    }
    private enum CodingKeys: String, CodingKey { case id,name,path,kind,loop,volume,playback,sequence,audioRouting }
    public init(from decoder: Decoder) throws {try self.init(from:decoder,legacy:false)}
    init(from decoder:Decoder,legacy:Bool) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        let kind=try c.decode(String.self,forKey:.kind)
        if legacy && !["image","video","camera"].contains(kind) {throw ProjectError.invalid("media kind requires schema 13")}
        self.init(id: try c.decodeIfPresent(UUID.self, forKey:.id) ?? UUID(),
                  name: try c.decode(String.self, forKey:.name), path: try c.decode(String.self, forKey:.path),
                  kind:kind, loop: try c.decodeIfPresent(Bool.self, forKey:.loop) ?? true,
                  volume: try c.decodeIfPresent(Double.self, forKey:.volume) ?? 1,
                  playback:legacy ? nil : try c.decodeIfPresent(MediaPlaybackSettings.self,forKey:.playback),
                  sequence:legacy ? nil : try c.decodeIfPresent(MediaSequenceSettings.self,forKey:.sequence),
                  audioRouting:legacy ? nil : try c.decodeIfPresent(AudioRoutingSettings.self,forKey:.audioRouting))
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
    public var edgeBlend:EdgeBlendSettings = .init()
    public init(id: UUID = UUID(), name: String = "Output", screenIndex: Int = 0, width: Int = 1920, height: Int = 1080,
                displayUUID: UUID? = nil) {
        self.id=id; self.name=name; self.screenIndex=screenIndex; self.width=width; self.height=height
        self.displayUUID=displayUUID
    }

    private enum CodingKeys: String, CodingKey { case id,name,screenIndex,width,height,displayUUID,edgeBlend }
    public init(from decoder: Decoder) throws { try self.init(from:decoder,legacyDisplay:false,legacyComposition:false) }
    init(from decoder: Decoder, legacyDisplay: Bool,legacyComposition:Bool = true) throws {
        let fields = try decoder.container(keyedBy:CodingKeys.self)
        self.init(id:try fields.decode(UUID.self,forKey:.id),
                  name:try fields.decode(String.self,forKey:.name),
                  screenIndex:try fields.decode(Int.self,forKey:.screenIndex),
                  width:try fields.decode(Int.self,forKey:.width),
                  height:try fields.decode(Int.self,forKey:.height),
                  displayUUID:legacyDisplay ? nil : try fields.decodeIfPresent(UUID.self,forKey:.displayUUID))
        if !legacyComposition { edgeBlend=try fields.decodeIfPresent(EdgeBlendSettings.self,forKey:.edgeBlend) ?? .init() }
    }
}

public enum CueCurve: String, Codable, CaseIterable, Sendable {
    case linear, easeIn, easeOut, easeInOut

    func value(at progress: Double) -> Double {
        switch self {
        case .linear: return progress
        case .easeIn: return progress * progress
        case .easeOut: return 1 - (1 - progress) * (1 - progress)
        case .easeInOut: return progress * progress * (3 - 2 * progress)
        }
    }
}

public struct Cue: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var surfaces: [Surface]
    /// Transition duration in seconds.
    public var duration: Double
    public var curve: CueCurve
    /// If set, trigger the next cue this many seconds after this cue's transition completes.
    public var followAfter: Double?
    public var scope: CueScope
    public var bindings: [CueBinding]
    public init(id: UUID = UUID(), name: String, surfaces: [Surface], duration: Double = 1, followAfter: Double? = nil,
                scope: CueScope = .full, bindings: [CueBinding] = [], curve: CueCurve = .linear) {
        self.id=id; self.name=name; self.surfaces=surfaces; self.duration=duration; self.followAfter=followAfter
        self.scope=scope; self.bindings=bindings; self.curve=curve
    }
    private enum CodingKeys:String,CodingKey { case id,name,surfaces,duration,followAfter,scope,bindings,curve }
    public init(from decoder:Decoder) throws { try self.init(from:decoder,legacy:false,version:Project.currentVersion) }
    /// Extension keys in older schemas have no selective-cue meaning, even when
    /// their values cannot be decoded as the schema-6 types.
    init(from decoder:Decoder,legacy:Bool,version:Int) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        let surfaces: [Surface]
        if version < 12 {
            var entries = try c.nestedUnkeyedContainer(forKey:.surfaces)
            surfaces = try Surface.decodeSurfaces(from:&entries,version:version)
        } else { surfaces = try c.decode([Surface].self,forKey:.surfaces) }
        self.init(id:try c.decode(UUID.self,forKey:.id),name:try c.decode(String.self,forKey:.name),
                  surfaces:surfaces,
                  duration:try c.decode(Double.self,forKey:.duration),
                  followAfter:try c.decodeIfPresent(Double.self,forKey:.followAfter),
                  scope:legacy ? .full : try c.decode(CueScope.self,forKey:.scope),
                  bindings:legacy ? [] : try c.decode([CueBinding].self,forKey:.bindings),
                  curve:version<14 ? .linear : try c.decodeIfPresent(CueCurve.self,forKey:.curve) ?? .linear)
        if version<12,bindings.contains(where:{$0.parameters.contains(.effects) || $0.parameters.contains(.material)}) {
            throw ProjectError.invalid("material/FX cue fields require schema 12")
        }
    }
}

public struct Project: Codable, Equatable, Sendable {
    public static let currentVersion = 17
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
    public var conductor = Conductor()
    public var showSchedule = ShowSchedule()
    public var showControlTracks: [ShowControlTrack] = []
    public var controlMap = ControlMap()
    public var groups: [SurfaceGroup]
    public var materials:[MaterialDefinition] = []
    public var globalMasks:[CompositionMask] = []
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
    private enum CodingKeys: String, CodingKey { case version,name,assets,surfaces,outputs,cues,fixtures,timeline,groups,timelineSettings,montages,geometryLockedSurfaceIDs,materials,globalMasks,conductor,showSchedule,showControlTracks,controlMap }
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
            while !entries.isAtEnd { cues.append(try Cue(from:entries.superDecoder(),legacy:version < 6,version:version)) }
        }
        let surfaces: [Surface]
        if version < 12, c.contains(.surfaces), try !c.decodeNil(forKey:.surfaces) {
            var entries = try c.nestedUnkeyedContainer(forKey:.surfaces)
            surfaces = try Surface.decodeSurfaces(from:&entries,version:version)
        } else { surfaces = try c.decodeIfPresent([Surface].self,forKey:.surfaces) ?? [] }
        var outputs: [OutputConfig] = []
        if version < 12, c.contains(.outputs), try !c.decodeNil(forKey:.outputs) {
            var entries = try c.nestedUnkeyedContainer(forKey:.outputs)
            while !entries.isAtEnd { outputs.append(try OutputConfig(from:entries.superDecoder(),legacyDisplay:version < 10,legacyComposition:true)) }
        } else { outputs = try c.decodeIfPresent([OutputConfig].self,forKey:.outputs) ?? [] }
        var groups:[SurfaceGroup]=[]
        if c.contains(.groups),try !c.decodeNil(forKey:.groups) {
            var entries=try c.nestedUnkeyedContainer(forKey:.groups)
            while !entries.isAtEnd { groups.append(try SurfaceGroup(from:entries.superDecoder(),legacy:version < 12)) }
        }
        var assets:[MediaAsset]=[]
        if c.contains(.assets),try !c.decodeNil(forKey:.assets) {
            var entries=try c.nestedUnkeyedContainer(forKey:.assets)
            while !entries.isAtEnd {assets.append(try MediaAsset(from:entries.superDecoder(),legacy:version<13))}
        }
        var montages: [MediaMontage] = []
        if version >= 7 {
            var entries = try c.nestedUnkeyedContainer(forKey: .montages)
            while !entries.isAtEnd {
                montages.append(try MediaMontage(from: entries.superDecoder(), legacy: version < 14))
            }
        }
        var fixtures: [Fixture] = []
        if c.contains(.fixtures), try !c.decodeNil(forKey: .fixtures) {
            var entries = try c.nestedUnkeyedContainer(forKey: .fixtures)
            while !entries.isAtEnd {
                guard fixtures.count < 4096 else { throw ProjectError.invalid("too many fixtures") }
                fixtures.append(try Fixture(from: entries.superDecoder(), legacy: version < 16))
            }
        }
        self.init(version: version,
                  name: try c.decodeIfPresent(String.self, forKey:.name) ?? "Untitled",
                  assets:assets,
                  surfaces: surfaces,
                  outputs: outputs,
                  cues: cues,
                  fixtures: fixtures,
                  timeline: try c.decodeIfPresent([AutomationTrack].self, forKey:.timeline) ?? [],
                  groups: groups,
                  timelineSettings:try Self.decodeTimelineSettings(c, version: version),
                  montages:montages,
                  geometryLockedSurfaceIDs: locks)
        if version >= 12 {
            materials=try c.decodeIfPresent([MaterialDefinition].self,forKey:.materials) ?? []
            globalMasks=try c.decodeIfPresent([CompositionMask].self,forKey:.globalMasks) ?? []
        }
        if version >= 14 {
            conductor = try c.decodeIfPresent(Conductor.self, forKey: .conductor) ?? Conductor()
            showSchedule = try c.decodeIfPresent(ShowSchedule.self, forKey: .showSchedule) ?? ShowSchedule()
            showControlTracks = try c.decodeIfPresent([ShowControlTrack].self, forKey: .showControlTracks) ?? []
        }
        if version >= 15 { controlMap = try c.decodeIfPresent(ControlMap.self, forKey: .controlMap) ?? ControlMap() }
    }

    private static func decodeTimelineSettings(_ container: KeyedDecodingContainer<CodingKeys>, version: Int) throws -> TimelineSettings? {
        guard container.contains(.timelineSettings), try !container.decodeNil(forKey: .timelineSettings) else { return nil }
        return try TimelineSettings(from: container.superDecoder(forKey: .timelineSettings), legacy: version < 14)
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
        try c.encode(materials,forKey:.materials);try c.encode(globalMasks,forKey:.globalMasks)
        try c.encode(timelineSettings, forKey: .timelineSettings)
        try c.encode(montages, forKey: .montages)
        if version >= 14 {
            try c.encode(conductor, forKey: .conductor)
            try c.encode(showSchedule, forKey: .showSchedule)
            try c.encode(showControlTracks, forKey: .showControlTracks)
        }
        if version >= 15 { try c.encode(controlMap, forKey: .controlMap) }
        if version >= 8 {
            try c.encode(geometryLockedSurfaceIDs.map(\.uuidString).sorted(), forKey: .geometryLockedSurfaceIDs)
        }
    }
}
