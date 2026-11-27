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
    public static let maximumCollectedBytes:Int64=64*1024*1024*1024
    public static let maximumSequenceFrameBytes:Int64=256*1024*1024

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
            var copiedBytes:Int64=0
            for i in collected.assets.indices where collected.assets[i].kind != "camera" {
                let asset=collected.assets[i]
                guard NSString(string:asset.path).isAbsolutePath else { throw ProjectError.invalid("collect requires resolved absolute media paths; load or relink \(asset.name) first") }
                let source=URL(fileURLWithPath:asset.path).resolvingSymlinksInPath().standardizedFileURL
                if asset.kind == "sequence" {
                    guard let sequence=asset.sequence else {throw ProjectError.invalid("sequence has no frozen frame manifest")}
                    try sequence.validate()
                    let folderBefore=try fm.attributesOfItem(atPath:source.path)
                    guard folderBefore[.type] as? FileAttributeType == .typeDirectory else {throw ProjectError.invalid("sequence source is not a directory: \(asset.name)")}
                    let target=mediaDirectory.appendingPathComponent(asset.id.uuidString,isDirectory:true)
                    try fm.createDirectory(at:target,withIntermediateDirectories:false)
                    for name in sequence.frames {
                        let input=source.appendingPathComponent(name)
                        // A selected folder may itself be an alias, but a frame
                        // cannot silently escape it via a symbolic link.
                        let attributes=try fm.attributesOfItem(atPath:input.path)
                        guard attributes[.type] as? FileAttributeType == .typeRegular else {throw ProjectError.invalid("sequence frame is missing or is not a regular file: \(name)")}
                        try copyStableFile(input,to:target.appendingPathComponent(name),maximumBytes:maximumSequenceFrameBytes,total:&copiedBytes)
                    }
                    let folderAfter=try fm.attributesOfItem(atPath:source.path)
                    guard folderBefore[.systemFileNumber] as? NSNumber == folderAfter[.systemFileNumber] as? NSNumber else {throw ProjectError.invalid("sequence folder changed during collection")}
                    collected.assets[i].path=target.path
                } else {
                    let originalExtension=URL(fileURLWithPath:asset.path).pathExtension
                    guard originalExtension.utf8.count <= 255 else { throw ProjectError.invalid("media filename extension is too long") }
                    let filename=asset.id.uuidString+(originalExtension.isEmpty ? "" : "."+originalExtension)
                    let target=mediaDirectory.appendingPathComponent(filename)
                    try copyStableFile(source,to:target,maximumBytes:maximumCollectedBytes,total:&copiedBytes)
                    collected.assets[i].path=target.path
                }
            }
            let stagedProject=staging.appendingPathComponent("project.aperturecue.json")
            try save(collected,to:stagedProject)
            // Verify serialization and all local references before publishing the directory.
            let verified=try load(from:stagedProject)
            let prefix=mediaDirectory.path+"/"
            guard verified.assets.allSatisfy({ asset in
                if asset.kind == "camera" {return true}
                guard asset.path.hasPrefix(prefix),fm.fileExists(atPath:asset.path) else {return false}
                return asset.sequence?.frames.allSatisfy {fm.fileExists(atPath:URL(fileURLWithPath:asset.path).appendingPathComponent($0).path)} ?? true
            }) else { throw ProjectError.invalid("collected project contains unresolved media") }
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

    /// Copy a bounded regular file and reject ordinary concurrent mutation.
    /// This is metadata stability verification, not a filesystem snapshot/lock.
    private static func copyStableFile(_ source:URL,to destination:URL,maximumBytes:Int64,total:inout Int64) throws {
        let fm=FileManager.default
        let before=try fm.attributesOfItem(atPath:source.path)
        guard before[.type] as? FileAttributeType == .typeRegular,
              let size=(before[.size] as? NSNumber)?.int64Value,size>=0,
              size<=maximumBytes,size<=maximumCollectedBytes-total else {
            throw ProjectError.invalid("collection media is not a regular file or exceeds its byte budget")
        }
        try fm.copyItem(at:source,to:destination)
        let after=try fm.attributesOfItem(atPath:source.path)
        let copied=try fm.attributesOfItem(atPath:destination.path)
        guard after[.type] as? FileAttributeType == .typeRegular,
              copied[.type] as? FileAttributeType == .typeRegular,
              before[.size] as? NSNumber == after[.size] as? NSNumber,
              before[.size] as? NSNumber == copied[.size] as? NSNumber,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date,
              before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber else {
            throw ProjectError.invalid("source media changed during collection")
        }
        total+=size
    }

    public static func save(_ project: Project, to url: URL) throws {
        try encodedProject(project,relativeTo:url).write(to:url,options:.atomic)
    }

    /// Manual Save variant for editors that retain a revision-bound autosave
    /// token. If another writer wins immediately after our atomic write, report
    /// the conflict instead of binding our in-memory project to its new bytes.
    @discardableResult public static func saveWithRecoveryBaseline(_ project:Project,to url:URL) throws -> RecoveryBaseline {
        let data=try encodedProject(project,relativeTo:url)
        try data.write(to:url,options:.atomic)
        let baseline=try captureRecoveryBaseline(for:url)
        guard baseline.sourceByteCount==data.count,baseline.sourceSHA256==ProjectContentDigest.sha256(data) else {
            throw ProjectError.invalid("saved document changed before its recovery baseline could be captured")
        }
        return baseline
    }

    private static func encodedProject(_ project:Project,relativeTo url:URL) throws -> Data {
        guard project.version >= 0,project.version <= Project.currentVersion else { throw ProjectError.unsupportedVersion(project.version) }
        var portable = project.version < 3 ? GroupEngine.migrateLegacyLabels(project) : project
        if portable.version < 4 { clearLegacyStrokeExtensions(&portable) }
        if portable.version < 5 { migrateLegacyTimeline(&portable) }
        if portable.version < 6 { clearLegacyCueExtensions(&portable) }
        if portable.version < 7 { portable.montages=[] }
        if portable.version < 8 { portable.geometryLockedSurfaceIDs = [] }
        if portable.version < 9 {
            for i in portable.surfaces.indices { portable.surfaces[i].triangleVertices = TriangleGeometry.canonical }
            for i in portable.cues.indices {
                for j in portable.cues[i].surfaces.indices { portable.cues[i].surfaces[j].triangleVertices = TriangleGeometry.canonical }
            }
        }
        if portable.version < 10 {
            for i in portable.outputs.indices { portable.outputs[i].displayUUID = nil }
        }
        if portable.version < 11 {
            for i in portable.surfaces.indices { portable.surfaces[i].maskSettings = .init() }
            for i in portable.cues.indices {
                for j in portable.cues[i].surfaces.indices { portable.cues[i].surfaces[j].maskSettings = .init() }
            }
        }
        if portable.version < 12 {
            guard !portable.cues.contains(where:{$0.bindings.contains(where:{$0.parameters.contains(.effects) || $0.parameters.contains(.material)})}) else {throw ProjectError.invalid("material/FX cue fields require schema 12")}
            clearLegacyComposition(&portable)
        }
        if portable.version < 13 {
            guard portable.assets.allSatisfy({["image","video","camera"].contains($0.kind)}) else {throw ProjectError.invalid("media kind requires schema 13")}
            for i in portable.assets.indices {portable.assets[i].playback=nil;portable.assets[i].sequence=nil;portable.assets[i].audioRouting=nil}
        }
        if portable.version < 14 {
            portable.conductor = Conductor()
            portable.showSchedule = ShowSchedule()
            portable.showControlTracks = []
            portable.montages = try portable.montages.map { try $0.withoutShowControlExtensions() }
            try MontageProgram.validate(montages: portable.montages, assets: portable.assets, legacy: true)
            portable.timelineSettings = try portable.timelineSettings.withoutShowControlExtensions()
            for index in portable.cues.indices { portable.cues[index].curve = .linear }
        }
        if portable.version < 15 { portable.controlMap = ControlMap() }
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
        return data
    }

    private static func clearLegacyComposition(_ project:inout Project) {
        func legacy(_ surface:Surface) -> Surface {
            var s=surface
            s.inputMesh=[];s.meshWeights=[];s.meshLinked=false;s.bezierWarp=nil;s.inputWarp=nil
            s.warpTransform = .identity;s.inputWarpTransform = .identity
            s.masks=[];s.effects = .init();s.materialID=nil;s.materialValues=[:];s.feedbackOutputID=nil
            return s
        }
        project.surfaces=project.surfaces.map(legacy)
        for i in project.cues.indices { project.cues[i].surfaces=project.cues[i].surfaces.map(legacy) }
        for i in project.outputs.indices { project.outputs[i].edgeBlend = .init() }
        for i in project.groups.indices {
            var g=project.groups[i];g.isolated=false;g.masks=[];g.effects = .init();g.blendMode="normal"
            g.transform.px=0;g.transform.py=0;g.transform.pw=1;project.groups[i]=g
        }
        project.materials=[];project.globalMasks=[]
    }

    public static func load(from url: URL) throws -> Project {
        try decodedProject(readBoundedFile(url.resolvingSymlinksInPath(),limit:maximumFileSize),at:url)
    }

    private static func readBoundedFile(_ url:URL,limit:Int) throws -> Data {
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ProjectError.invalid("expected a regular document file")
        }
        if let size=attributes[.size] as? NSNumber,size.intValue>limit {throw ProjectError.tooLarge}
        let handle=try FileHandle(forReadingFrom:url)
        defer {try? handle.close()}
        var data=Data()
        // A writer can grow the file after the metadata check. Read at most
        // limit+1 bytes rather than allocate its now-unbounded whole contents.
        while data.count<=limit {
            let count=min(65536,limit+1-data.count)
            let chunk=try handle.read(upToCount:count) ?? Data()
            if chunk.isEmpty {return data}
            data.append(chunk)
        }
        throw ProjectError.tooLarge
    }

    private static func decodedProject(_ data:Data,at url:URL) throws -> Project {
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
        if p.version < 7 { p.montages=[] }
        if p.version < 14 { try MontageProgram.validate(montages: p.montages, assets: p.assets, legacy: true) }
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
    /// Capture when the saved document is opened or manually saved. Passing this
    /// immutable token to autosave prevents a later external save being mistaken
    /// for the revision from which the editor's unsaved changes were derived.
    public static func captureRecoveryBaseline(for projectURL:URL) throws -> RecoveryBaseline {
        try readSavedRevision(for:projectURL).baseline
    }

    /// Decode exactly the same bytes that establish the saved-revision token.
    /// This closes the Open-then-recapture window between two independent reads.
    public static func loadWithRecoveryBaseline(from projectURL:URL) throws -> (project:Project,baseline:RecoveryBaseline) {
        let revision=try readSavedRevision(for:projectURL)
        return (try decodedProject(revision.data,at:projectURL),revision.baseline)
    }

    private static func readSavedRevision(for projectURL:URL) throws -> (data:Data,baseline:RecoveryBaseline) {
        let source=projectURL.resolvingSymlinksInPath().standardizedFileURL
        let before=try FileManager.default.attributesOfItem(atPath:source.path)
        let data=try readBoundedFile(source,limit:maximumFileSize)
        let after=try FileManager.default.attributesOfItem(atPath:source.path)
        let firstTime=(before[.modificationDate] as? Date)?.timeIntervalSince1970
        let lastTime=(after[.modificationDate] as? Date)?.timeIntervalSince1970
        guard let firstTime,let lastTime,firstTime==lastTime,
              (before[.size] as? NSNumber)?.intValue==data.count,
              (before[.size] as? NSNumber)==(after[.size] as? NSNumber),
              (before[.systemFileNumber] as? NSNumber)==(after[.systemFileNumber] as? NSNumber) else {
            throw ProjectError.invalid("saved document changed while capturing recovery baseline")
        }
        let baseline=RecoveryBaseline(sourcePath:source.path,sourceSHA256:ProjectContentDigest.sha256(data),
                                      sourceByteCount:data.count,sourceModificationTime:lastTime)
        return (data,baseline)
    }

    public static func recoveryStatus(for projectURL:URL) -> RecoveryStatus {
        let url=recoveryURL(for:projectURL)
        guard (try? FileManager.default.attributesOfItem(atPath:url.path)) != nil else {
            return RecoveryStatus(state:.missing,diagnostic:"")
        }
        do {
            let data=try readBoundedFile(url,limit:maximumRecoveryFileSize)
            guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {
                return RecoveryStatus(state:.invalid,diagnostic:"Recovery is not a valid object; the file was preserved")
            }
            guard object["format"] != nil else {
                return RecoveryStatus(state:.legacy,diagnostic:"Legacy recovery has no saved-revision binding; the file was preserved")
            }
            let envelope=try JSONDecoder().decode(RecoveryEnvelope.self,from:data)
            guard envelope.format==RecoveryEnvelope.marker,envelope.version==1,
                  envelope.createdAt.isFinite,envelope.payload.count<=maximumFileSize,
                  envelope.payloadSHA256==ProjectContentDigest.sha256(envelope.payload) else {
                return RecoveryStatus(state:.invalid,diagnostic:"Recovery envelope or payload checksum is invalid; the file was preserved")
            }
            let current=try captureRecoveryBaseline(for:projectURL)
            guard envelope.baseline==current else {
                return RecoveryStatus(state:.stale,diagnostic:"Recovery belongs to a different saved revision or document path; the file was preserved")
            }
            _=try decodedProject(envelope.payload,at:projectURL)
            return RecoveryStatus(state:.available,diagnostic:"A recovery snapshot matches this saved document revision")
        } catch {
            return RecoveryStatus(state:.invalid,diagnostic:"Recovery is unavailable: \(error.localizedDescription). The file was preserved")
        }
    }

    public static let maximumRecoveryFileSize=24*1024*1024
    public static func saveRecovery(_ project:Project,for projectURL:URL,baseline:RecoveryBaseline?=nil) throws {
        let baseline=try baseline ?? captureRecoveryBaseline(for:projectURL)
        guard baseline.sourcePath==projectURL.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw ProjectError.invalid("recovery baseline belongs to another document path")
        }
        let status=recoveryStatus(for:projectURL)
        guard status.state == .missing || status.state == .available else {
            throw ProjectError.invalid("existing recovery was preserved: "+status.diagnostic)
        }
        if status.state == .available {
            let existing=try JSONDecoder().decode(RecoveryEnvelope.self,from:readBoundedFile(recoveryURL(for:projectURL),limit:maximumRecoveryFileSize))
            guard existing.baseline==baseline else {throw ProjectError.invalid("existing recovery belongs to another editor revision and was preserved")}
        }
        let payload=try encodedProject(project,relativeTo:projectURL)
        let envelope=RecoveryEnvelope(format:RecoveryEnvelope.marker,version:1,baseline:baseline,
                                      createdAt:Date().timeIntervalSince1970,payloadSHA256:ProjectContentDigest.sha256(payload),payload:payload)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let data=try encoder.encode(envelope)
        guard data.count<=maximumRecoveryFileSize else {throw ProjectError.tooLarge}
        try data.write(to:recoveryURL(for:projectURL),options:.atomic)
    }
    public static func loadRecovery(for projectURL:URL) throws -> Project {
        let status=recoveryStatus(for:projectURL)
        guard status.state == .available else {throw ProjectError.invalid(status.diagnostic.isEmpty ? "no recovery snapshot" : status.diagnostic)}
        let data=try readBoundedFile(recoveryURL(for:projectURL),limit:maximumRecoveryFileSize)
        let envelope=try JSONDecoder().decode(RecoveryEnvelope.self,from:data)
        // Recheck identity after the status read; a concurrently replaced sidecar
        // must not bypass the source or payload checks used to offer recovery.
        guard envelope.format==RecoveryEnvelope.marker,envelope.version==1,
              envelope.baseline == (try captureRecoveryBaseline(for:projectURL)),
              envelope.payload.count<=maximumFileSize,
              envelope.payloadSHA256==ProjectContentDigest.sha256(envelope.payload) else {
            throw ProjectError.invalid("recovery changed while loading; the file was preserved")
        }
        return try decodedProject(envelope.payload,at:projectURL)
    }

    /// Remove only a sidecar owned by the revision held by this editor. Call
    /// after a successful manual Save, passing the token captured before Save.
    /// Stale/legacy/corrupt files and other revisions are left in place.
    @discardableResult public static func removeRecovery(for projectURL:URL,baseline:RecoveryBaseline?) throws -> Bool {
        guard let baseline,baseline.sourcePath==projectURL.resolvingSymlinksInPath().standardizedFileURL.path else {return false}
        let url=recoveryURL(for:projectURL)
        guard (try? FileManager.default.attributesOfItem(atPath:url.path)) != nil else {return false}
        guard let data=try? readBoundedFile(url,limit:maximumRecoveryFileSize),
              let envelope=try? JSONDecoder().decode(RecoveryEnvelope.self,from:data),
              envelope.format==RecoveryEnvelope.marker,envelope.version==1,envelope.baseline==baseline,
              envelope.payloadSHA256==ProjectContentDigest.sha256(envelope.payload) else {return false}
        try FileManager.default.removeItem(at:url)
        return true
    }

    public static func validate(_ project: Project) throws {
        guard project.version >= 0, project.version <= Project.currentVersion else { throw ProjectError.unsupportedVersion(project.version) }
        guard project.name.utf8.count <= 4096 else { throw ProjectError.invalid("name is too long") }
        guard project.surfaces.count <= 4096, project.assets.count <= 4096, project.outputs.count <= 64, project.cues.count <= 4096 else { throw ProjectError.invalid("too many objects") }
        try unique(project.assets.map(\.id), "media IDs")
        try unique(project.outputs.map(\.id), "output IDs")
        try unique(project.cues.map(\.id), "cue IDs")
        let mediaIDs = project.sourceMediaIDs, outputIDs = Set(project.outputs.map(\.id))
        guard project.materials.count<=256,Set(project.materials.map(\.id)).count==project.materials.count else { throw ProjectError.invalid("material count or duplicate IDs") }
        var materialPrograms:[UUID:MaterialProgram]=[:]
        for definition in project.materials { materialPrograms[definition.id]=try MaterialProgram(definition:definition) }
        try CompositionPlan.validateMasks(project.globalMasks,global:true)
        for asset in project.assets {
            let kinds=project.version>=13 ? ["image","video","audio","camera","sequence"] : ["image","video","camera"]
            guard kinds.contains(asset.kind) else { throw ProjectError.invalid("unknown media kind \(asset.kind)") }
            if project.version>=13 {
                try asset.playback?.validate();try asset.audioRouting?.validate()
                if asset.kind == "sequence" {
                    guard let sequence=asset.sequence else {throw ProjectError.invalid("sequence source requires a frozen frame manifest")}
                    try sequence.validate()
                } else if asset.sequence != nil {throw ProjectError.invalid("only sequence sources can contain frame manifests")}
                if asset.playback != nil,!(["video","audio","sequence"].contains(asset.kind)) {throw ProjectError.invalid("source kind does not support playback settings")}
                if asset.audioRouting != nil,!(["video","audio"].contains(asset.kind)) {throw ProjectError.invalid("source kind does not support audio routing")}
            }
            guard asset.path.utf8.count <= 32768, !asset.path.contains("\0"), asset.name.utf8.count <= 4096 else { throw ProjectError.invalid("invalid media path or name") }
            guard asset.volume.isFinite, (0...1).contains(asset.volume) else { throw ProjectError.invalid("volume is outside 0...1") }
            if asset.kind != "camera", asset.path.isEmpty { throw ProjectError.invalid("empty media path") }
        }
        for output in project.outputs {
            try EdgeBlend.validate(output.edgeBlend)
            guard output.screenIndex >= 0, output.screenIndex < 64, (1...16384).contains(output.width), (1...16384).contains(output.height) else { throw ProjectError.invalid("invalid output size or screen index") }
        }
        try MontageProgram.validate(montages:project.version>=7 ? project.montages : [],assets:project.assets,legacy:project.version < 14)
        if project.version >= 3, (project.surfaces + project.cues.flatMap(\.surfaces)).contains(where:{ !$0.group.isEmpty }) {
            throw ProjectError.invalid("schema 3 uses groupID references; legacy group labels must be migrated from a version 0...2 document")
        }
        for cue in project.cues { try CueSelection.validate(cue) }
        try GroupEngine.validate(project)
        try validateSurfaces(project.surfaces, mediaIDs:mediaIDs, outputIDs:outputIDs,materials:materialPrograms)
        if project.version >= 8, !project.geometryLockedSurfaceIDs.isSubset(of: Set(project.surfaces.map(\.id))) {
            throw ProjectError.invalid("geometry lock refers to a missing current surface")
        }
        try validateFeedback(project.surfaces,outputs:project.outputs)
        try FixtureSampler.validate(fixtures:project.fixtures)
        var totalCueSurfaces = 0
        for cue in project.cues {
            totalCueSurfaces += cue.surfaces.count
            guard totalCueSurfaces <= 65536 else { throw ProjectError.invalid("too many cue surface snapshots") }
            guard cue.duration.isFinite, (0...86400).contains(cue.duration) else { throw ProjectError.invalid("invalid cue duration") }
            if let follow = cue.followAfter { guard follow.isFinite, (0...86400).contains(follow) else { throw ProjectError.invalid("invalid cue follow time") } }
            try validateFeedback(CueSelection.validationSurfaces(cue),outputs:project.outputs)
            try validateSurfaces(CueSelection.validationSurfaces(cue), mediaIDs:mediaIDs, outputIDs:outputIDs,materials:materialPrograms)
        }
        // Only a full cue can restore an absent layer. A partial cue skips missing
        // targets, so its dormant snapshot cannot keep an orphan track alive.
        let automationSurfaces = project.surfaces + project.cues.filter { $0.scope == .full }.flatMap(\.surfaces)
        let cueIDs = Set(project.cues.map(\.id))
        try TimelineEngine.validate(tracks: project.timeline, surfaces: automationSurfaces)
        let settings = try project.version < 14 ? project.timelineSettings.withoutShowControlExtensions() : project.timelineSettings
        try TimelineSettings.validate(settings, tracks: project.timeline, cueIDs: cueIDs)
        if project.version >= 14 {
            try project.conductor.validate(surfaces: automationSurfaces)
            try project.showSchedule.validate(cueIDs: cueIDs)
            try ShowControlTrack.validate(project.showControlTracks, duration: settings.duration)
        }
        if project.version >= 15 {
            try project.controlMap.validate(surfaceIDs: Set(automationSurfaces.map(\.id)), cueIDs: cueIDs)
        }
    }

    private static func validateSurfaces(_ surfaces: [Surface], mediaIDs: Set<UUID>, outputIDs: Set<UUID>,materials:[UUID:MaterialProgram]) throws {
        guard surfaces.count <= 4096 else { throw ProjectError.invalid("too many surfaces") }
        try unique(surfaces.map(\.id), "surface IDs")
        for s in surfaces {
            try Geometry.validateQuad(s.input); try Geometry.validateQuad(s.output)
            try StrokeGeometry.validate(s.stroke)
            if s.shape.isStroke { _ = try StrokeGeometry.samples(surface:s) }
            if s.shape == .triangle || s.triangleVertices != TriangleGeometry.canonical {
                _ = try TriangleGeometry(vertices:s.triangleVertices)
            }
            try PolygonMaskGeometry.validate(s.maskSettings)
            try CompositionPlan.validateMasks(s.masks);try Effects.validate(s.effects)
            if let id=s.materialID {
                guard let program=materials[id] else { throw ProjectError.invalid("surface references nonexistent material") }
                _ = try program.parameterVectors(values:s.materialValues)
            } else if !s.materialValues.isEmpty { throw ProjectError.invalid("material values need a material assignment") }
            if let id=s.feedbackOutputID,!outputIDs.contains(id) { throw ProjectError.invalid("loopback references nonexistent output") }
            if let warp=s.bezierWarp {
                guard s.mesh.isEmpty else { throw ProjectError.invalid("choose regular or Bezier output mesh") }
                try warp.validate();try s.warpTransform.validate()
                _ = try warp.tessellated(width:1280,height:720,projection:Homography(values:s.warpTransform.values),maximumTriangles:65536)
            }
            if let input=s.inputWarp {
                guard let output=s.bezierWarp,input.columns==output.columns,input.rows==output.rows else { throw ProjectError.invalid("source Bezier lattice requires matching output topology") }
                try input.validate(projection:Homography(values:s.inputWarpTransform.values));try s.inputWarpTransform.validate()
            }
            if !s.inputMesh.isEmpty {
                guard !s.mesh.isEmpty,s.inputMesh.count==s.mesh.count else { throw ProjectError.invalid("input/output regular meshes require matching topology") }
            }
            if !s.meshWeights.isEmpty {
                guard s.meshWeights.count==s.mesh.count,s.meshWeights.allSatisfy({$0.isFinite && $0>1e-12 && $0<=10000}) else { throw ProjectError.invalid("invalid projective mesh weights") }
            }
            let allPoints = s.input + s.output + s.mesh + s.inputMesh + s.mask
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
    private static func validateFeedback(_ surfaces:[Surface],outputs:[OutputConfig]) throws {
        let ids=Set(surfaces.filter(\.enabled).compactMap(\.feedbackOutputID))
        let referenced=outputs.filter {ids.contains($0.id)}
        guard ids.count<=8,referenced.allSatisfy({$0.width<=4096 && $0.height<=4096}),referenced.reduce(0,{$0+$1.width*$1.height})<=16777216 else {
            throw ProjectError.invalid("feedback supports eight routes, 4096 per axis and 16M total pixels")
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

public struct RecoveryBaseline:Codable,Equatable,Sendable {
    public let sourcePath:String
    public let sourceSHA256:String
    public let sourceByteCount:Int
    public let sourceModificationTime:Double
}

public enum RecoveryState:String,Codable,Sendable {case missing,available,stale,invalid,legacy}
public struct RecoveryStatus:Equatable,Sendable {
    public let state:RecoveryState
    public let diagnostic:String
}

private struct RecoveryEnvelope:Codable {
    static let marker="ApertureCue recovery"
    var format:String
    var version:Int
    var baseline:RecoveryBaseline
    var createdAt:Double
    var payloadSHA256:String
    var payload:Data
}

/// Original portable SHA-256 implementation for bounded document fingerprints.
/// MappingCore remains Foundation-only on macOS and Linux. This digest binds
/// recovery to bytes; it is not an authentication or hostile-file trust boundary.
enum ProjectContentDigest {
    static func sha256(_ data:Data) -> String {
        let constants:[UInt32]=[
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
        func rotate(_ x:UInt32,_ n:UInt32) -> UInt32 {(x>>n)|(x<<(32-n))}
        var bytes=Array(data)
        let bitCount=UInt64(bytes.count)*8
        bytes.append(0x80)
        while bytes.count%64 != 56 {bytes.append(0)}
        for shift in stride(from:56,through:0,by:-8) {bytes.append(UInt8(truncatingIfNeeded:bitCount>>UInt64(shift)))}
        var state:[UInt32]=[0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        var words=Array(repeating:UInt32(0),count:64)
        for offset in stride(from:0,to:bytes.count,by:64) {
            for i in 0..<16 {
                let j=offset+i*4
                words[i]=(UInt32(bytes[j])<<24)|(UInt32(bytes[j+1])<<16)|(UInt32(bytes[j+2])<<8)|UInt32(bytes[j+3])
            }
            for i in 16..<64 {
                let x=words[i-15],y=words[i-2]
                let s0=rotate(x,7)^rotate(x,18)^(x>>3)
                let s1=rotate(y,17)^rotate(y,19)^(y>>10)
                words[i]=words[i-16]&+s0&+words[i-7]&+s1
            }
            var a=state[0],b=state[1],c=state[2],d=state[3],e=state[4],f=state[5],g=state[6],h=state[7]
            for i in 0..<64 {
                let s1=rotate(e,6)^rotate(e,11)^rotate(e,25)
                let choice=(e&f)^((~e)&g)
                let first=h&+s1&+choice&+constants[i]&+words[i]
                let s0=rotate(a,2)^rotate(a,13)^rotate(a,22)
                let majority=(a&b)^(a&c)^(b&c)
                let second=s0&+majority
                h=g;g=f;f=e;e=d&+first;d=c;c=b;b=a;a=first&+second
            }
            let additions=[a,b,c,d,e,f,g,h]
            for i in 0..<8 {state[i]=state[i]&+additions[i]}
        }
        return state.map {String(format:"%08x",$0)}.joined()
    }
}
