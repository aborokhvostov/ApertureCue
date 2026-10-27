import Foundation

public enum ProjectError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case tooLarge
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): return "Project version \(v) is unsupported. This build supports versions 0 through \(Project.currentVersion)."
        case .tooLarge: return "The project exceeds the 16 MiB document limit."
        case .invalid(let reason): return "Invalid project: \(reason)"
        }
    }
}

public enum ProjectStore {
    public static let maximumFileSize = 16 * 1024 * 1024

    /// Collect a self-contained copy in a new directory. The in-memory project's media paths
    /// must already be absolute (as returned by load). Camera identifiers remain live identities.
    /// Any missing/non-file media aborts the entire operation; the original project is untouched.
    @discardableResult
    public static func collect(_ project:Project,to directory:URL) throws -> URL {
        try validate(project)
        let fm=FileManager.default
        guard directory.isFileURL else { throw ProjectError.invalid("collection destination must be a local directory") }
        let destination=directory.standardizedFileURL
        let parent=destination.deletingLastPathComponent()
        func exists(_ url:URL) -> Bool { (try? fm.attributesOfItem(atPath:url.path)) != nil }
        guard !exists(destination) else { throw ProjectError.invalid("collection destination already exists; choose a new folder") }
        var isDirectory:ObjCBool=false
        guard fm.fileExists(atPath:parent.path,isDirectory:&isDirectory),isDirectory.boolValue else { throw ProjectError.invalid("collection parent directory does not exist") }
        let staging=parent.appendingPathComponent("."+destination.lastPathComponent+".collect-"+UUID().uuidString,isDirectory:true)
        guard !exists(staging) else { throw ProjectError.invalid("collection staging directory unexpectedly exists") }
        try fm.createDirectory(at:staging,withIntermediateDirectories:false)
        do {
            let mediaDirectory=staging.appendingPathComponent("media",isDirectory:true)
            try fm.createDirectory(at:mediaDirectory,withIntermediateDirectories:false)
            var collected=project
            for i in collected.assets.indices where collected.assets[i].kind != "camera" {
                let asset=collected.assets[i]
                guard NSString(string:asset.path).isAbsolutePath else { throw ProjectError.invalid("collect requires resolved absolute media paths; load or relink \(asset.name) first") }
                let source=URL(fileURLWithPath:asset.path).resolvingSymlinksInPath().standardizedFileURL
                let attributes: [FileAttributeKey:Any]
                do { attributes=try fm.attributesOfItem(atPath:source.path) }
                catch { throw ProjectError.invalid("missing media for collection: \(asset.name) (\(asset.path))") }
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ProjectError.invalid("collection media is not a regular file: \(asset.name)") }
                let originalExtension=URL(fileURLWithPath:asset.path).pathExtension
                guard originalExtension.utf8.count <= 255 else { throw ProjectError.invalid("media filename extension is too long") }
                let filename=asset.id.uuidString+(originalExtension.isEmpty ? "" : "."+originalExtension)
                let target=mediaDirectory.appendingPathComponent(filename)
                try fm.copyItem(at:source,to:target)
                collected.assets[i].path=target.path
            }
            let stagedProject=staging.appendingPathComponent("project.aperturecue.json")
            try save(collected,to:stagedProject)
            // Verify serialization and all local references before publishing the directory.
            let verified=try load(from:stagedProject)
            let prefix=mediaDirectory.path+"/"
            guard verified.assets.allSatisfy({ $0.kind == "camera" || ($0.path.hasPrefix(prefix) && fm.fileExists(atPath:$0.path)) }) else { throw ProjectError.invalid("collected project contains unresolved media") }
            // Staging and destination are siblings, so this is a same-filesystem rename.
            // moveItem rejects an existing destination if another process creates it meanwhile.
            try fm.moveItem(at:staging,to:destination)
            return destination.appendingPathComponent("project.aperturecue.json")
        } catch {
            // Only this invocation's randomly named staging directory is eligible for cleanup.
            // The destination and all source paths are never removed on failure.
            try? fm.removeItem(at:staging)
            throw error
        }
    }

    public static func save(_ project: Project, to url: URL) throws {
        guard project.version >= 0,project.version <= Project.currentVersion else { throw ProjectError.unsupportedVersion(project.version) }
        var portable = project.version < 3 ? GroupEngine.migrateLegacyLabels(project) : project
        if portable.version < 4 { clearLegacyStrokeExtensions(&portable) }
        if portable.version < 5 { migrateLegacyTimeline(&portable) }
        if portable.version < 6 { clearLegacyCueExtensions(&portable) }
        portable.version = Project.currentVersion
        try validate(portable)
        let base = url.deletingLastPathComponent().standardizedFileURL
        portable.assets = portable.assets.map { asset in
            var a = asset
            if a.kind != "camera", !a.path.isEmpty {
                let absolute = absoluteURL(path:a.path, base:base)
                a.path = relativePath(to:absolute, from:base)
            }
            return a
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(portable)
        guard data.count <= maximumFileSize else { throw ProjectError.tooLarge }
        try data.write(to:url, options:.atomic)
    }

    public static func load(from url: URL) throws -> Project {
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > maximumFileSize { throw ProjectError.tooLarge }
        let data = try Data(contentsOf:url)
        guard data.count <= maximumFileSize else { throw ProjectError.tooLarge }
        var p = try JSONDecoder().decode(Project.self, from:data)
        guard p.version >= 0, p.version <= Project.currentVersion else { throw ProjectError.unsupportedVersion(p.version) }
        // Legacy projects always described quad cages. Do not reinterpret an unknown
        // extension named "shape" when migrating a version that did not define it.
        if p.version < 2 {
            for index in p.surfaces.indices { p.surfaces[index].shape = .quad }
            for cueIndex in p.cues.indices {
                for surfaceIndex in p.cues[cueIndex].surfaces.indices { p.cues[cueIndex].surfaces[surfaceIndex].shape = .quad }
            }
        }
        if p.version < 3 { p = GroupEngine.migrateLegacyLabels(p) }
        if p.version < 4 { clearLegacyStrokeExtensions(&p) }
        if p.version < 5 { migrateLegacyTimeline(&p) }
        if p.version < 6 { clearLegacyCueExtensions(&p) }
        p.version = Project.currentVersion
        try validate(p)
        let base = url.deletingLastPathComponent()
        for index in p.assets.indices where p.assets[index].kind != "camera" && !p.assets[index].path.isEmpty {
            p.assets[index].path = absoluteURL(path:p.assets[index].path, base:base).path
        }
        return p
    }

    private static func clearLegacyCueExtensions(_ project:inout Project) {
        for i in project.cues.indices { project.cues[i].scope = .full; project.cues[i].bindings = [] }
    }

    /// Stroke payloads and these two enum values had no meaning in schemas 0...3.
    /// Preserve established primitive/group fields without activating extensions.
    private static func clearLegacyStrokeExtensions(_ project:inout Project) {
        func normalized(_ surface:Surface) -> Surface {
            var result=surface
            result.stroke = .line
            if result.shape.isStroke { result.shape = .quad }
            return result
        }
        project.surfaces=project.surfaces.map(normalized)
        for i in project.cues.indices { project.cues[i].surfaces=project.cues[i].surfaces.map(normalized) }
    }

    /// Versions 0...4 defined linear scalar keys but no timeline settings or
    /// easing payload. Preserve their times/values without activating extensions.
    private static func migrateLegacyTimeline(_ project:inout Project) {
        for track in project.timeline.indices {
            project.timeline[track].keyframes=project.timeline[track].keyframes.map { AutomationKeyframe(time:$0.time,value:$0.value) }
        }
        project.timelineSettings=TimelineSettings.inferred(from:project.timeline)
        project.timelineSettings.stopAtEnd=false
    }

    public static func recoveryURL(for projectURL: URL) -> URL {
        projectURL.deletingLastPathComponent().appendingPathComponent("." + projectURL.lastPathComponent + ".recovery")
    }
    public static func saveRecovery(_ project: Project, for projectURL: URL) throws {
        try save(project, to:recoveryURL(for:projectURL))
    }
    public static func loadRecovery(for projectURL: URL) throws -> Project {
        try load(from:recoveryURL(for:projectURL))
    }

    public static func validate(_ project: Project) throws {
        guard project.version >= 0, project.version <= Project.currentVersion else { throw ProjectError.unsupportedVersion(project.version) }
        guard project.name.utf8.count <= 4096 else { throw ProjectError.invalid("name is too long") }
        guard project.surfaces.count <= 4096, project.assets.count <= 4096, project.outputs.count <= 64, project.cues.count <= 4096 else { throw ProjectError.invalid("too many objects") }
        try unique(project.assets.map(\.id), "media IDs")
        try unique(project.outputs.map(\.id), "output IDs")
        try unique(project.cues.map(\.id), "cue IDs")
        let mediaIDs = Set(project.assets.map(\.id)), outputIDs = Set(project.outputs.map(\.id))
        for asset in project.assets {
            guard ["image","video","camera"].contains(asset.kind) else { throw ProjectError.invalid("unknown media kind \(asset.kind)") }
            guard asset.path.utf8.count <= 32768, !asset.path.contains("\0"), asset.name.utf8.count <= 4096 else { throw ProjectError.invalid("invalid media path or name") }
            guard asset.volume.isFinite, (0...1).contains(asset.volume) else { throw ProjectError.invalid("volume is outside 0...1") }
            if asset.kind != "camera", asset.path.isEmpty { throw ProjectError.invalid("empty media path") }
        }
        for output in project.outputs {
            guard output.screenIndex >= 0, output.screenIndex < 64, (1...16384).contains(output.width), (1...16384).contains(output.height) else { throw ProjectError.invalid("invalid output size or screen index") }
        }
        if project.version >= 3, (project.surfaces + project.cues.flatMap(\.surfaces)).contains(where:{ !$0.group.isEmpty }) {
            throw ProjectError.invalid("schema 3 uses groupID references; legacy group labels must be migrated from a version 0...2 document")
        }
        for cue in project.cues { try CueSelection.validate(cue) }
        try GroupEngine.validate(project)
        try validateSurfaces(project.surfaces, mediaIDs:mediaIDs, outputIDs:outputIDs)
        try FixtureSampler.validate(fixtures:project.fixtures)
        var totalCueSurfaces = 0
        for cue in project.cues {
            totalCueSurfaces += cue.surfaces.count
            guard totalCueSurfaces <= 65536 else { throw ProjectError.invalid("too many cue surface snapshots") }
            guard cue.duration.isFinite, (0...86400).contains(cue.duration) else { throw ProjectError.invalid("invalid cue duration") }
            if let follow = cue.followAfter { guard follow.isFinite, (0...86400).contains(follow) else { throw ProjectError.invalid("invalid cue follow time") } }
            try validateSurfaces(CueSelection.validationSurfaces(cue), mediaIDs:mediaIDs, outputIDs:outputIDs)
        }
        // Only a full cue can restore an absent layer. A partial cue skips missing
        // targets, so its dormant snapshot cannot keep an orphan track alive.
        try TimelineEngine.validate(tracks:project.timeline,surfaces:project.surfaces+project.cues.filter { $0.scope == .full }.flatMap(\.surfaces))
        try TimelineSettings.validate(project.timelineSettings,tracks:project.timeline,cueIDs:Set(project.cues.map(\.id)))
    }

    private static func validateSurfaces(_ surfaces: [Surface], mediaIDs: Set<UUID>, outputIDs: Set<UUID>) throws {
        guard surfaces.count <= 4096 else { throw ProjectError.invalid("too many surfaces") }
        try unique(surfaces.map(\.id), "surface IDs")
        for s in surfaces {
            try Geometry.validateQuad(s.input); try Geometry.validateQuad(s.output)
            try StrokeGeometry.validate(s.stroke)
            if s.shape.isStroke { _ = try StrokeGeometry.samples(surface:s) }
            let allPoints = s.input + s.output + s.mesh + s.mask
            guard allPoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 10000 && abs($0.y) <= 10000 }) else { throw ProjectError.invalid("coordinate outside finite working range") }
            guard s.name.utf8.count <= 4096, s.group.utf8.count <= 4096 else { throw ProjectError.invalid("surface label is too long") }
            guard s.opacity.isFinite, (0...1).contains(s.opacity), s.brightness.isFinite, (0...16).contains(s.brightness), s.feather.isFinite, (0...0.5).contains(s.feather), s.gamma.isFinite, (0.01...10).contains(s.gamma) else { throw ProjectError.invalid("invalid surface color or opacity parameters") }
            guard s.color.count == 3, s.color.allSatisfy({ $0.isFinite && (0...16).contains($0) }) else { throw ProjectError.invalid("invalid RGB multiplier") }
            guard ["normal","add","multiply","screen"].contains(s.blendMode) else { throw ProjectError.invalid("unknown blend mode") }
            guard ["checker","gradient","solid","grid"].contains(s.generator) else { throw ProjectError.invalid("unknown generator") }
            guard s.mask.count <= 128, s.mask.isEmpty || s.mask.count >= 3 else { throw ProjectError.invalid("mask requires 3...128 vertices") }
            guard s.meshColumns >= 0, s.meshColumns <= 64, s.meshRows >= 0, s.meshRows <= 64 else { throw ProjectError.invalid("mesh size outside 0...64") }
            if s.mesh.isEmpty {
                guard s.meshColumns == 0, s.meshRows == 0 else { throw ProjectError.invalid("mesh dimensions without vertices") }
            } else {
                guard s.meshColumns > 0, s.meshRows > 0, s.mesh.count == (s.meshColumns+1)*(s.meshRows+1) else { throw ProjectError.invalid("mesh vertex count does not match dimensions") }
            }
            if let id = s.mediaID, !mediaIDs.contains(id) { throw ProjectError.invalid("surface references nonexistent media") }
            if let id = s.outputID, !outputIDs.contains(id) { throw ProjectError.invalid("surface references nonexistent output") }
        }
    }
    private static func unique(_ ids: [UUID], _ name: String) throws {
        guard Set(ids).count == ids.count else { throw ProjectError.invalid("duplicate \(name)") }
    }
    private static func absoluteURL(path: String, base: URL) -> URL {
        if NSString(string:path).isAbsolutePath { return URL(fileURLWithPath:path).standardizedFileURL }
        return base.appendingPathComponent(path).standardizedFileURL
    }
    private static func relativePath(to destination: URL, from base: URL) -> String {
        let a = base.pathComponents, b = destination.pathComponents
        var common = 0
        while common < min(a.count,b.count), a[common] == b[common] { common += 1 }
        return (Array(repeating:"..", count:a.count-common) + b.dropFirst(common)).joined(separator:"/")
    }
}
