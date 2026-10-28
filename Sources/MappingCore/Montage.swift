import Foundation

public enum MontageGapMode:String,Codable,CaseIterable,Sendable { case skip,black }

/// One half-open timeline interval on an assignable montage source. Images use
/// the canonical source fields 0/1/1/false; video trims are source seconds.
public struct MontageClip:Codable,Equatable,Identifiable,Sendable {
    public var id:UUID
    public var assetID:UUID
    public var start:Double
    public var duration:Double
    public var sourceIn:Double
    public var sourceOut:Double
    public var rate:Double
    public var loop:Bool
    public init(id:UUID=UUID(),assetID:UUID,start:Double=0,duration:Double=1,
                sourceIn:Double=0,sourceOut:Double=1,rate:Double=1,loop:Bool=false) {
        self.id=id;self.assetID=assetID;self.start=start;self.duration=duration
        self.sourceIn=sourceIn;self.sourceOut=sourceOut;self.rate=rate;self.loop=loop
    }
    public var end:Double {start+duration}
}

/// Definitions are shared project state, outside surface cue snapshots. The
/// montage UUID is a surface source ID; clips reference only real file assets.
public struct MediaMontage:Codable,Equatable,Identifiable,Sendable {
    public var id:UUID
    public var name:String
    public var duration:Double
    public var loop:Bool
    public var gapMode:MontageGapMode
    public var clips:[MontageClip]
    public init(id:UUID=UUID(),name:String="Montage",duration:Double=10,loop:Bool=false,
                gapMode:MontageGapMode = .black,clips:[MontageClip]=[]) {
        self.id=id;self.name=name;self.duration=duration;self.loop=loop;self.gapMode=gapMode;self.clips=clips
    }
}

/// A known montage always returns a sample, including explicit gaps. Runtime
/// decoders use the stable clip/cycle identity and retain their own frame state;
/// the schedule owns no AVFoundation resources and produces no marker events.
public struct MontageSample:Equatable,Sendable {
    public var montageID:UUID
    public var gapMode:MontageGapMode
    public var localTime:Double
    public var montageCycle:Int
    public var clip:MontageClip?
    public var asset:MediaAsset?
    public var sourceTime:Double?
    public var clipCycle:Int
    public var isGap:Bool {clip == nil}
}

/// Immutable validated schedule. Evaluation is a binary search over sorted
/// clip starts and is independent of traversal order, seek history or markers.
public struct MontageProgram:Sendable {
    public static let maximumMontages=64
    public static let maximumClipsPerMontage=1024
    public static let maximumClips=4096
    public static let maximumAssets=4096
    private struct Schedule:Sendable {
        var montage:MediaMontage
        var clips:[MontageClip]
    }
    private var schedules:[UUID:Schedule]
    private var assets:[UUID:MediaAsset]
    public init(montages:[MediaMontage],assets:[MediaAsset]) throws {
        try Self.validate(montages:montages,assets:assets)
        self.assets=Dictionary(uniqueKeysWithValues:assets.map {($0.id,$0)})
        schedules=Dictionary(uniqueKeysWithValues:montages.map { montage in
            (montage.id,Schedule(montage:montage,clips:montage.clips.sorted {$0.start<$1.start}))
        })
    }

    public static func validate(montages:[MediaMontage],assets:[MediaAsset]) throws {
        let assetIDs=Set(assets.map(\.id)),montageIDs=Set(montages.map(\.id))
        guard assets.count<=maximumAssets,assetIDs.count==assets.count else {throw ProjectError.invalid("montage asset count or duplicate IDs")}
        guard montages.count<=maximumMontages,montageIDs.count==montages.count,
              assetIDs.isDisjoint(with:montageIDs) else {
            throw ProjectError.invalid("montage count, duplicate IDs or media ID collision")
        }
        let byID=Dictionary(uniqueKeysWithValues:assets.map {($0.id,$0)})
        var clipIDs=Set<UUID>(),count=0
        for montage in montages {
            guard montage.name.utf8.count<=4096,montage.duration.isFinite,
                  (0.001...ShowRuntime.maximumTime).contains(montage.duration),
                  montage.clips.count<=maximumClipsPerMontage else {
                throw ProjectError.invalid("montage name, duration or clip count")
            }
            count += montage.clips.count
            guard count<=maximumClips else {throw ProjectError.invalid("too many montage clips")}
            guard montage.clips.allSatisfy({$0.start.isFinite && $0.duration.isFinite}) else {
                throw ProjectError.invalid("montage clip timeline coordinates must be finite")
            }
            let sorted=montage.clips.sorted {$0.start<$1.start}
            var previousEnd=0.0
            for clip in sorted {
                guard clipIDs.insert(clip.id).inserted,!assetIDs.contains(clip.id),!montageIDs.contains(clip.id) else {
                    throw ProjectError.invalid("duplicate montage clip ID or source ID collision")
                }
                guard clip.start.isFinite,clip.start>=0,clip.duration.isFinite,clip.duration>=0.001,
                      clip.end.isFinite,clip.end<=montage.duration,clip.end>clip.start,
                      clip.start>=previousEnd else {
                    throw ProjectError.invalid("montage clip range or overlap")
                }
                previousEnd=clip.end
                guard let asset=byID[clip.assetID],["image","video"].contains(asset.kind) else {
                    throw ProjectError.invalid("montage clips require existing image/video assets; cameras and nested sources are unsupported")
                }
                guard clip.sourceIn.isFinite,clip.sourceOut.isFinite,clip.sourceIn>=0,
                      clip.sourceOut>clip.sourceIn,clip.sourceOut<=ShowRuntime.maximumTime,
                      clip.rate.isFinite,(0.25...4).contains(clip.rate) else {
                    throw ProjectError.invalid("montage clip source trim or rate")
                }
                if asset.kind=="image" {
                    guard clip.sourceIn==0,clip.sourceOut==1,clip.rate==1,!clip.loop else {
                        throw ProjectError.invalid("image montage clips use only timeline start/duration")
                    }
                } else {
                    let span=clip.sourceOut-clip.sourceIn
                    if !clip.loop {
                        guard clip.duration<=(span/clip.rate).nextUp else {
                            throw ProjectError.invalid("non-loop video clip outlasts its source trim")
                        }
                    } else {
                        let cycles=clip.duration*clip.rate/span
                        guard cycles.isFinite,cycles<Double(Int.max) else {
                            throw ProjectError.invalid("montage clip repeat count exceeds bounded cycle range")
                        }
                    }
                }
            }
        }
    }

    public func sample(id:UUID,time:Double) throws -> MontageSample? {
        guard time.isFinite,(0...ShowRuntime.maximumTime).contains(time) else {
            throw ProjectError.invalid("montage sample time is outside the finite show range")
        }
        guard let schedule=schedules[id] else {return nil}
        let montage=schedule.montage
        let local=montage.loop ? time.truncatingRemainder(dividingBy:montage.duration) : min(time,montage.duration)
        let montageCycle=montage.loop ? Self.cycle(time/montage.duration) : 0
        var result=MontageSample(montageID:id,gapMode:montage.gapMode,localTime:local,montageCycle:montageCycle,
                                 clip:nil,asset:nil,sourceTime:nil,clipCycle:0)
        guard local<montage.duration,!schedule.clips.isEmpty else {return result}
        var low=0,high=schedule.clips.count
        while low<high {
            let mid=(low+high)/2
            if schedule.clips[mid].start<=local {low=mid+1} else {high=mid}
        }
        guard low>0 else {return result}
        let clip=schedule.clips[low-1]
        guard local<clip.end,let asset=assets[clip.assetID] else {return result}
        result.clip=clip;result.asset=asset
        if asset.kind=="image" {result.sourceTime=0;return result}
        let span=clip.sourceOut-clip.sourceIn,elapsed=(local-clip.start)*clip.rate
        let offset=clip.loop ? elapsed.truncatingRemainder(dividingBy:span) : min(elapsed,span)
        // Floating addition at an endpoint can round to Out. Remain inside the
        // requested half-open source trim, including adjacent Double endpoints.
        result.sourceTime=min(clip.sourceOut.nextDown,max(clip.sourceIn,clip.sourceIn+offset))
        result.clipCycle=clip.loop ? Self.cycle(elapsed/span) : 0
        return result
    }
    private static func cycle(_ value:Double)->Int {
        // Validation bounds repeat ratios. Saturation is a final conversion guard
        // against Double rounding at Int.max rather than an unchecked Int cast.
        value>=Double(Int.max) ? Int.max : Int(max(0,value.rounded(.down)))
    }
}
