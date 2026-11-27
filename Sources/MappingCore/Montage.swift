import Foundation

public enum MontageGapMode: String, Codable, CaseIterable, Sendable { case skip, black }

/// One half-open interval. Audio files use their own lane, while a movie can
/// opt into using its first audio track alongside its visual frames.
public struct MontageClip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var assetID: UUID
    public var start: Double
    public var duration: Double
    public var sourceIn: Double
    public var sourceOut: Double
    public var rate: Double
    public var loop: Bool
    public var crossfadeIn: Double?
    public var audioEnabled: Bool?

    public init(id: UUID = UUID(), assetID: UUID, start: Double = 0, duration: Double = 1,
                sourceIn: Double = 0, sourceOut: Double = 1, rate: Double = 1, loop: Bool = false,
                crossfadeIn: Double? = nil, audioEnabled: Bool? = nil) {
        self.id = id
        self.assetID = assetID
        self.start = start
        self.duration = duration
        self.sourceIn = sourceIn
        self.sourceOut = sourceOut
        self.rate = rate
        self.loop = loop
        self.crossfadeIn = crossfadeIn
        self.audioEnabled = audioEnabled
    }

    public var end: Double { start + duration }

    private enum CodingKeys: String, CodingKey {
        case id, assetID, start, duration, sourceIn, sourceOut, rate, loop, crossfadeIn, audioEnabled
    }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, legacy: false)
    }

    init(from decoder: Decoder, legacy: Bool) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            assetID: try values.decode(UUID.self, forKey: .assetID),
            start: try values.decode(Double.self, forKey: .start),
            duration: try values.decode(Double.self, forKey: .duration),
            sourceIn: try values.decode(Double.self, forKey: .sourceIn),
            sourceOut: try values.decode(Double.self, forKey: .sourceOut),
            rate: try values.decode(Double.self, forKey: .rate),
            loop: try values.decode(Bool.self, forKey: .loop),
            crossfadeIn: legacy ? nil : try values.decodeIfPresent(Double.self, forKey: .crossfadeIn),
            audioEnabled: legacy ? nil : try values.decodeIfPresent(Bool.self, forKey: .audioEnabled)
        )
        if legacy, rate < 0 { throw ProjectError.invalid("legacy montage clips require positive rates") }
    }
}

/// Shared project state. A surface can reference this UUID as its source.
public struct MediaMontage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var duration: Double
    public var loop: Bool
    public var gapMode: MontageGapMode
    public var clips: [MontageClip]

    public init(id: UUID = UUID(), name: String = "Montage", duration: Double = 10, loop: Bool = false,
                gapMode: MontageGapMode = .black, clips: [MontageClip] = []) {
        self.id = id
        self.name = name
        self.duration = duration
        self.loop = loop
        self.gapMode = gapMode
        self.clips = clips
    }

    private enum CodingKeys: String, CodingKey { case id, name, duration, loop, gapMode, clips }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, legacy: false)
    }

    public init(from decoder: Decoder, legacy: Bool) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var raw = try values.nestedUnkeyedContainer(forKey: .clips)
        var clips: [MontageClip] = []
        while !raw.isAtEnd {
            guard clips.count < MontageProgram.maximumClipsPerMontage else {
                throw ProjectError.invalid("too many clips in a montage")
            }
            clips.append(try MontageClip(from: raw.superDecoder(), legacy: legacy))
        }
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            duration: try values.decode(Double.self, forKey: .duration),
            loop: try values.decode(Bool.self, forKey: .loop),
            gapMode: try values.decode(MontageGapMode.self, forKey: .gapMode),
            clips: clips
        )
    }

    public func withoutShowControlExtensions() throws -> MediaMontage {
        guard clips.allSatisfy({ $0.rate >= 0 }) else {
            throw ProjectError.invalid("legacy montage clips require positive rates")
        }
        var copy = self
        for i in copy.clips.indices {
            copy.clips[i].crossfadeIn = nil
            copy.clips[i].audioEnabled = nil
        }
        return copy
    }
}

public struct MontageLeg: Equatable, Sendable {
    public let clip: MontageClip
    public let asset: MediaAsset
    public let sourceTime: Double
    public let clipCycle: Int
    public let weight: Double
    /// Forward audio never queues past the earlier of Out or the clip's end,
    /// even when the editor's next clock tick arrives late.
    public let audioEnd: Double
}

/// Each lane independently selects at most two legs. The primary visual leg is
/// the incoming clip, including at a fade start where its weight is zero.
public struct MontageSample: Equatable, Sendable {
    public let montageID: UUID
    public let gapMode: MontageGapMode
    public let localTime: Double
    public let montageCycle: Int
    public let visual: [MontageLeg]
    public let audio: [MontageLeg]
    public var clip: MontageClip? { visual.last?.clip }
    public var asset: MediaAsset? { visual.last?.asset }
    public var sourceTime: Double? { visual.last?.sourceTime }
    public var clipCycle: Int { visual.last?.clipCycle ?? 0 }
    public var isGap: Bool { visual.isEmpty }
}

public struct MontageProgram: Sendable {
    public static let maximumMontages = 64
    public static let maximumClipsPerMontage = 1024
    public static let maximumClips = 4096
    public static let maximumAssets = 4096
    private static let timeTolerance = 1e-8

    private struct Schedule: Sendable {
        let montage: MediaMontage
        let visual: [MontageClip]
        let audio: [MontageClip]
    }
    private let schedules: [UUID: Schedule]
    private let assets: [UUID: MediaAsset]

    public init(montages: [MediaMontage], assets: [MediaAsset]) throws {
        try Self.validate(montages: montages, assets: assets)
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        self.assets = byID
        schedules = Dictionary(uniqueKeysWithValues: montages.map { montage in
            let clips = montage.clips.sorted { $0.start < $1.start }
            let visual = clips.filter { byID[$0.assetID]?.kind != "audio" }
            let audio = clips.filter { byID[$0.assetID]?.kind == "audio" }
            return (montage.id, Schedule(montage: montage, visual: visual, audio: audio))
        })
    }

    public static func validate(montages: [MediaMontage], assets: [MediaAsset], legacy: Bool = false) throws {
        let assetIDs = Set(assets.map(\.id))
        let montageIDs = Set(montages.map(\.id))
        guard assets.count <= maximumAssets, assetIDs.count == assets.count else {
            throw ProjectError.invalid("montage asset count or duplicate IDs")
        }
        guard montages.count <= maximumMontages, montageIDs.count == montages.count,
              assetIDs.isDisjoint(with: montageIDs) else {
            throw ProjectError.invalid("montage count, duplicate IDs or media ID collision")
        }
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var clipIDs = Set<UUID>()
        var count = 0
        for montage in montages {
            guard montage.name.utf8.count <= 4096, montage.duration.isFinite,
                  (0.001...ShowRuntime.maximumTime).contains(montage.duration),
                  montage.clips.count <= maximumClipsPerMontage else {
                throw ProjectError.invalid("montage name, duration or clip count")
            }
            count += montage.clips.count
            guard count <= maximumClips else { throw ProjectError.invalid("too many montage clips") }
            var visual: [MontageClip] = []
            var audio: [MontageClip] = []
            for input in montage.clips {
                let clip = legacy ? try legacyClip(input) : input
                guard clipIDs.insert(clip.id).inserted, !assetIDs.contains(clip.id), !montageIDs.contains(clip.id) else {
                    throw ProjectError.invalid("duplicate montage clip ID or source ID collision")
                }
                guard clip.start.isFinite, clip.start >= 0, clip.duration.isFinite, clip.duration >= 0.001,
                      clip.end.isFinite, clip.end <= montage.duration, clip.end > clip.start else {
                    throw ProjectError.invalid("montage clip range is invalid")
                }
                guard let asset = byID[clip.assetID], ["image", "video", "audio"].contains(asset.kind),
                      !(legacy && asset.kind == "audio") else {
                    throw ProjectError.invalid("montage clips require an existing supported image, video or audio file")
                }
                try validateSource(clip, kind: asset.kind)
                if asset.kind == "audio" { audio.append(clip) }
                else { visual.append(clip) }
            }
            try validateLane(visual)
            try validateLane(audio)
        }
    }

    private static func legacyClip(_ clip: MontageClip) throws -> MontageClip {
        guard clip.rate >= 0 else { throw ProjectError.invalid("legacy montage clips require positive rates") }
        var legacy = clip
        legacy.crossfadeIn = nil
        legacy.audioEnabled = nil
        return legacy
    }

    private static func validateSource(_ clip: MontageClip, kind: String) throws {
        let speed = abs(clip.rate)
        guard clip.sourceIn.isFinite, clip.sourceOut.isFinite, clip.sourceIn >= 0,
              clip.sourceOut > clip.sourceIn, clip.sourceOut <= ShowRuntime.maximumTime,
              speed.isFinite, (0.25...4).contains(speed) else {
            throw ProjectError.invalid("montage clip source trim or rate")
        }
        if kind == "image" {
            guard clip.sourceIn == 0, clip.sourceOut == 1, clip.rate == 1, !clip.loop, clip.audioEnabled == nil else {
                throw ProjectError.invalid("image montage clips use placement and crossfade settings")
            }
            return
        }
        if kind == "audio" {
            guard clip.rate > 0, clip.audioEnabled == nil else {
                throw ProjectError.invalid("audio clips require positive rate; movie audio is a separate option")
            }
        }
        if clip.rate < 0, clip.audioEnabled == true {
            throw ProjectError.invalid("movie audio requires forward playback")
        }
        let span = clip.sourceOut - clip.sourceIn
        if clip.loop {
            let cycles = clip.duration * speed / span
            guard cycles.isFinite, cycles < Double(Int.max) else {
                throw ProjectError.invalid("montage clip repeat count exceeds bounded cycle range")
            }
        } else {
            guard clip.duration <= (span / speed).nextUp else {
                throw ProjectError.invalid("non-loop montage clip outlasts its source trim")
            }
        }
    }

    private static func validateLane(_ clips: [MontageClip]) throws {
        var previous: MontageClip?
        var earlierEnd = 0.0
        for clip in clips.sorted(by: { $0.start < $1.start }) {
            let overlap = (previous?.end ?? 0) - clip.start
            if let fade = clip.crossfadeIn {
                guard let previous, fade.isFinite, fade >= 0.001, abs(overlap - fade) <= timeTolerance,
                      clip.start > previous.start, clip.end > previous.end, clip.start >= earlierEnd else {
                    throw ProjectError.invalid("crossfade must match an adjacent overlap without nesting or a third clip")
                }
            } else if overlap > 0 {
                throw ProjectError.invalid("overlapping montage clips need an explicit incoming crossfade")
            }
            earlierEnd = previous?.end ?? 0
            previous = clip
        }
    }

    public func sample(id: UUID, time: Double) throws -> MontageSample? {
        guard time.isFinite, (0...ShowRuntime.maximumTime).contains(time) else {
            throw ProjectError.invalid("montage sample time is outside the finite show range")
        }
        guard let schedule = schedules[id] else { return nil }
        let montage = schedule.montage
        let local = montage.loop ? time.truncatingRemainder(dividingBy: montage.duration) : min(time, montage.duration)
        let cycle = montage.loop ? Self.cycle(time / montage.duration) : 0
        let visual = legs(in: schedule.visual, at: local)
        let movieAudio = visual.filter { $0.clip.audioEnabled == true }
        let audio = movieAudio + legs(in: schedule.audio, at: local)
        return MontageSample(montageID: id, gapMode: montage.gapMode, localTime: local, montageCycle: cycle,
                             visual: visual, audio: audio)
    }

    private func legs(in clips: [MontageClip], at time: Double) -> [MontageLeg] {
        var lower = 0
        var upper = clips.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if clips[middle].start <= time { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower > 0 else { return [] }
        let current = clips[lower - 1]
        guard time < current.end else { return [] }
        if lower > 1, current.crossfadeIn != nil {
            let outgoing = clips[lower - 2]
            if time < outgoing.end {
                let weight = (time - current.start) / (outgoing.end - current.start)
                return [leg(outgoing, at: time, weight: 1 - weight), leg(current, at: time, weight: weight)]
            }
        }
        return [leg(current, at: time, weight: 1)]
    }

    private func leg(_ clip: MontageClip, at local: Double, weight: Double) -> MontageLeg {
        let asset = assets[clip.assetID]! // The compiled schedule keeps validated IDs.
        if asset.kind == "image" {
            return MontageLeg(clip: clip, asset: asset, sourceTime: 0, clipCycle: 0, weight: weight, audioEnd: 0)
        }
        let speed = abs(clip.rate)
        let span = clip.sourceOut - clip.sourceIn
        let elapsed = (local - clip.start) * speed
        let offset = clip.loop ? elapsed.truncatingRemainder(dividingBy: span) : min(elapsed, span)
        let clipCycle = clip.loop ? Self.cycle(elapsed / span) : 0
        let position = clip.rate < 0 ? clip.sourceOut - offset : clip.sourceIn + offset
        let sourceTime = min(clip.sourceOut.nextDown, max(clip.sourceIn, position))
        let audioEnd = min(clip.sourceOut, clip.sourceIn + max(0, clip.duration * speed - Double(clipCycle) * span))
        return MontageLeg(clip: clip, asset: asset, sourceTime: sourceTime, clipCycle: clipCycle,
                          weight: weight, audioEnd: audioEnd)
    }

    private static func cycle(_ value: Double) -> Int {
        value >= Double(Int.max) ? Int.max : Int(max(0, value.rounded(.down)))
    }
}
