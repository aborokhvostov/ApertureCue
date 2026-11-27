import XCTest
import Foundation
@testable import MappingCore

final class MontageTests:XCTestCase {
    private var scratch:URL!
    override func setUpWithError() throws {
        scratch=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueMontage-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws {try FileManager.default.removeItem(at:scratch)}
    private func asset(_ kind:String="video")->MediaAsset {MediaAsset(name:"Original "+kind,path:scratch.appendingPathComponent(kind+".fixture").path,kind:kind)}
    private func object<T:Encodable>(_ value:T)throws->[String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as? [String:Any])
    }
    private func write(_ object:[String:Any])throws->URL {
        let url=scratch.appendingPathComponent("show.json")
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:url);return url
    }

    func testHalfOpenIntervalsSortedClipsImageAndExplicitGaps() throws {
        let video=asset(),image=asset("image")
        let v=MontageClip(assetID:video.id,start:1,duration:2,sourceIn:2,sourceOut:6,rate:2)
        let i=MontageClip(assetID:image.id,start:3,duration:2)
        let montage=MediaMontage(name:"Cuts",duration:6,gapMode:.skip,clips:[i,v])
        let program=try MontageProgram(montages:[montage],assets:[video,image])
        XCTAssertTrue(try XCTUnwrap(program.sample(id:montage.id,time:0)).isGap)
        XCTAssertEqual(try XCTUnwrap(program.sample(id:montage.id,time:0)).gapMode,.skip)
        XCTAssertEqual(try XCTUnwrap(program.sample(id:montage.id,time:1)).clip?.id,v.id)
        XCTAssertEqual(try XCTUnwrap(program.sample(id:montage.id,time:1)).sourceTime,2)
        XCTAssertEqual(try XCTUnwrap(program.sample(id:montage.id,time:1.5)).sourceTime,3)
        let beforeCut=try XCTUnwrap(program.sample(id:montage.id,time:3.0.nextDown))
        XCTAssertEqual(beforeCut.clip?.id,v.id);XCTAssertTrue(try XCTUnwrap(beforeCut.sourceTime)<6)
        let exactCut=try XCTUnwrap(program.sample(id:montage.id,time:3))
        XCTAssertEqual(exactCut.clip?.id,i.id);XCTAssertEqual(exactCut.asset,image);XCTAssertEqual(exactCut.sourceTime,0)
        XCTAssertTrue(try XCTUnwrap(program.sample(id:montage.id,time:5)).isGap)
        let end=try XCTUnwrap(program.sample(id:montage.id,time:6))
        XCTAssertTrue(end.isGap);XCTAssertNil(end.asset);XCTAssertNil(end.sourceTime);XCTAssertEqual(end.localTime,6)
        XCTAssertTrue(try XCTUnwrap(program.sample(id:montage.id,time:100)).isGap)
        XCTAssertEqual(montage.clips,[i,v],"Compiling must not reorder persisted clip definitions")
        let black=MediaMontage(gapMode:.black)
        XCTAssertEqual(try XCTUnwrap(MontageProgram(montages:[black],assets:[]).sample(id:black.id,time:0)).gapMode,.black)
    }

    func testRateSegmentLoopMontageLoopAndRandomAccessAreStateless() throws {
        let video=asset(),clip=MontageClip(assetID:video.id,start:1,duration:6,sourceIn:2,sourceOut:3,rate:2,loop:true)
        let montage=MediaMontage(duration:8,loop:true,clips:[clip]),program=try MontageProgram(montages:[montage],assets:[video])
        let cases:[(Double,Double,Int,Int)]=[(1,2,0,0),(1.5,2,1,0),(2.25,2.5,2,0),(9,2,0,1),(17.5,2,1,2)]
        for (time,position,clipCycle,montageCycle) in cases.reversed() {
            let sample=try XCTUnwrap(program.sample(id:montage.id,time:time))
            XCTAssertEqual(sample.sourceTime,position);XCTAssertEqual(sample.clipCycle,clipCycle);XCTAssertEqual(sample.montageCycle,montageCycle)
        }
        let wrap=try XCTUnwrap(program.sample(id:montage.id,time:8))
        XCTAssertTrue(wrap.isGap);XCTAssertEqual(wrap.localTime,0);XCTAssertEqual(wrap.montageCycle,1)
        let a=try program.sample(id:montage.id,time:2.25)
        _=try program.sample(id:montage.id,time:ShowRuntime.maximumTime)
        XCTAssertEqual(try program.sample(id:montage.id,time:2.25),a)
        XCTAssertEqual(clip.sourceIn,2);XCTAssertTrue(video.loop,"Compilation must not change ordinary media transport settings")
    }

    func testVideoTrimRateBoundsCanonicalImagesAndOverlapRejectAtomically() throws {
        let video=asset(),image=asset("image")
        let original=MontageClip(assetID:video.id,start:0,duration:1)
        let invalid:[(inout MontageClip)->Void]=[
            {$0.start = -1},{$0.start = .nan},{$0.start = .infinity},{$0.duration=0},{$0.duration=0.0001},{$0.duration = .nan},
            {$0.duration=11},{$0.sourceIn = -1},{$0.sourceIn = .nan},{$0.sourceOut = .infinity},{$0.sourceOut=0},
            {$0.sourceOut=ShowRuntime.maximumTime+1},{$0.rate=0},{$0.rate=0.24},{$0.rate=4.01},{$0.rate = .nan},
            {$0.duration=2},{$0.assetID=UUID()}
        ]
        for mutate in invalid {
            var clip=original;mutate(&clip)
            XCTAssertThrowsError(try MontageProgram(montages:[MediaMontage(clips:[clip])],assets:[video]))
            XCTAssertEqual(original.duration,1)
        }
        var imageClip=MontageClip(assetID:image.id,start:0,duration:10)
        try MontageProgram.validate(montages:[MediaMontage(clips:[imageClip])],assets:[image])
        for mutation in 0..<4 {
            var changed=imageClip
            if mutation==0 {changed.sourceIn=0.1} else if mutation==1 {changed.sourceOut=2}
            else if mutation==2 {changed.rate=2} else {changed.loop=true}
            XCTAssertThrowsError(try MontageProgram.validate(montages:[MediaMontage(clips:[changed])],assets:[image]))
        }
        imageClip.start=1
        let collision=MontageClip(assetID:image.id,start:0,duration:2)
        XCTAssertThrowsError(try MontageProgram.validate(montages:[MediaMontage(duration:12,clips:[imageClip,collision])],assets:[image]))
        let adjacent=MontageClip(assetID:image.id,start:11,duration:1)
        try MontageProgram.validate(montages:[MediaMontage(duration:12,clips:[imageClip,adjacent])],assets:[image])
        let camera=asset("camera")
        XCTAssertThrowsError(try MontageProgram.validate(montages:[MediaMontage(clips:[MontageClip(assetID:camera.id)])],assets:[camera]))
    }

    func testGlobalIdentityAndResourceBudgetsRejectDuplicateOrNestedSources() throws {
        let image=asset("image"),clip=MontageClip(assetID:UUID())
        var source=MediaMontage(clips:[MontageClip(assetID:image.id)])
        var collision=source;collision.id=image.id
        XCTAssertThrowsError(try MontageProgram(montages:[collision],assets:[image]))
        XCTAssertThrowsError(try MontageProgram(montages:[source,source],assets:[image]))
        XCTAssertThrowsError(try MontageProgram(montages:[source],assets:[image,image]))
        XCTAssertThrowsError(try MontageProgram(montages:[],assets:(0..<4097).map {_ in MediaAsset(name:"Bound",path:"image.png",kind:"image")}))
        var duplicate=source;duplicate.id=UUID()
        XCTAssertThrowsError(try MontageProgram(montages:[source,duplicate],assets:[image]))
        var collisionClip=MontageClip(id:image.id,assetID:image.id)
        XCTAssertThrowsError(try MontageProgram(montages:[MediaMontage(clips:[collisionClip])],assets:[image]))
        collisionClip.id=source.id;source.clips=[collisionClip]
        XCTAssertThrowsError(try MontageProgram(montages:[source],assets:[image]))
        let empty=MediaMontage()
        let nested=MediaMontage(clips:[MontageClip(assetID:empty.id)])
        XCTAssertThrowsError(try MontageProgram(montages:[empty,nested],assets:[image]))
        XCTAssertThrowsError(try MontageProgram(montages:[MediaMontage(clips:[clip])],assets:[image]))
        XCTAssertThrowsError(try MontageProgram(montages:(0..<65).map {_ in MediaMontage()},assets:[]))
        func clips(_ count:Int)->[MontageClip] {(0..<count).map {MontageClip(assetID:image.id,start:Double($0),duration:1)}}
        XCTAssertThrowsError(try MontageProgram(montages:[MediaMontage(duration:1025,clips:clips(1025))],assets:[image]))
        let boundary=(0..<4).map {_ in MediaMontage(duration:1024,clips:clips(1024))}
        try MontageProgram.validate(montages:boundary,assets:[image])
        XCTAssertThrowsError(try MontageProgram.validate(montages:boundary+[MediaMontage(clips:clips(1))],assets:[image]))
    }

    func testInvalidSampleTimesAndExtremeRepeatRatiosCannotTrap() throws {
        let video=asset(),image=asset("image"),empty=MediaMontage(duration:0.001,loop:true)
        let program=try MontageProgram(montages:[empty],assets:[video,image])
        for time in [-1.0,Double.nan,Double.infinity,ShowRuntime.maximumTime+1] {
            XCTAssertThrowsError(try program.sample(id:empty.id,time:time))
        }
        XCTAssertNil(try program.sample(id:UUID(),time:0))
        let huge=try XCTUnwrap(program.sample(id:empty.id,time:ShowRuntime.maximumTime))
        XCTAssertTrue(huge.isGap);XCTAssertGreaterThan(huge.montageCycle,0)
        let tiny=MontageClip(assetID:video.id,start:0,duration:10,sourceOut:Double.leastNonzeroMagnitude,loop:true)
        XCTAssertThrowsError(try MontageProgram(montages:[MediaMontage(clips:[tiny])],assets:[video]))
        for duration in [-1.0,0,Double.nan,Double.infinity,ShowRuntime.maximumTime+1] {
            XCTAssertThrowsError(try MontageProgram(montages:[MediaMontage(duration:duration)],assets:[]))
        }
        XCTAssertThrowsError(try MontageProgram(montages:[MediaMontage(name:String(repeating:"x",count:4097))],assets:[]))
        try MontageProgram.validate(montages:[MediaMontage(name:String(repeating:"x",count:4096))],assets:[])
    }

    func testLegacyVersionsIgnoreMalformedMontageExtensionsAndSchemaSevenIsStrict() throws {
        let image=asset("image"),surface=Surface()
        let montage=MediaMontage(clips:[MontageClip(assetID:image.id)])
        for version in 0...6 {
            var legacy=try object(Project(version:version,assets:[image],surfaces:[surface]))
            legacy["montages"]=["unknown":"malformed extension"]
            let loaded=try ProjectStore.load(from:write(legacy))
            XCTAssertEqual(loaded.version,Project.currentVersion);XCTAssertEqual(loaded.montages,[])
            var inMemory=Project(version:version,assets:[image],surfaces:[surface],montages:[montage])
            inMemory.montages[0].duration = .nan
            let saved=scratch.appendingPathComponent("legacy-\(version).json")
            try ProjectStore.save(inMemory,to:saved)
            XCTAssertEqual(try ProjectStore.load(from:saved).montages,[])
            XCTAssertEqual(inMemory.sourceMediaIDs,[image.id])
            legacy["montages"]=NSNull();XCTAssertEqual(try ProjectStore.load(from:write(legacy)).montages,[])
        }
        let current=try object(Project(assets:[image],surfaces:[Surface(mediaID:montage.id)],montages:[montage]))
        XCTAssertEqual(try ProjectStore.load(from:write(current)).montages,[montage])
        for mutation in 0..<5 {
            var broken=current
            if mutation==0 {broken.removeValue(forKey:"montages")}
            else if mutation==1 {broken["montages"]=NSNull()}
            else {
                var definitions=try XCTUnwrap(current["montages"] as? [[String:Any]])
                if mutation==2 {definitions[0]["gapMode"]="unknown"}
                else if mutation==3 {definitions[0].removeValue(forKey:"loop")}
                else {
                    var clips=try XCTUnwrap(definitions[0]["clips"] as? [[String:Any]])
                    clips[0].removeValue(forKey:"rate");definitions[0]["clips"]=clips
                }
                broken["montages"]=definitions
            }
            XCTAssertThrowsError(try ProjectStore.load(from:write(broken)))
        }
        XCTAssertThrowsError(try ProjectStore.load(from:write(["version":999,"montages":NSNull()]))) {
            XCTAssertEqual($0 as? ProjectError,.unsupportedVersion(999))
        }
    }

    func testMontageReferencesAcrossCurrentFullAndSelectiveCueSnapshots() throws {
        let video=asset(),montage=MediaMontage(clips:[MontageClip(assetID:UUID())])
        var validMontage=montage;validMontage.clips[0].assetID=video.id
        let ordinary=Surface(mediaID:video.id),virtual=Surface(mediaID:validMontage.id)
        let full=Cue(name:"Montage source",surfaces:[virtual])
        let partial=try CueSelection.capture(name:"Selective montage",surfaces:[virtual],bindings:[CueBinding(surfaceID:virtual.id,parameters:[.source])])
        let project=Project(assets:[video],surfaces:[ordinary,virtual],cues:[full,partial],montages:[validMontage])
        try ProjectStore.validate(project);XCTAssertEqual(project.sourceMediaIDs,[video.id,validMontage.id])
        var removed=project;removed.montages=[]
        XCTAssertThrowsError(try ProjectStore.validate(removed))
        removed.surfaces=[ordinary];removed.cues=[];try ProjectStore.validate(removed)
        let dormant=try CueSelection.capture(name:"Dormant source",surfaces:[virtual],bindings:[CueBinding(surfaceID:virtual.id,parameters:[.opacity])])
        removed.cues=[dormant];try ProjectStore.validate(removed)
        var legacy=project;legacy.version=6
        XCTAssertThrowsError(try ProjectStore.save(legacy,to:scratch.appendingPathComponent("invalid-legacy-reference.json")))
    }

    func testPersistenceRecoveryCollectAndHistoryRetainOnlyRealAssetFiles() throws {
        let video=asset(),image=asset("image")
        try Data([1,3,5,7]).write(to:URL(fileURLWithPath:video.path))
        try Data([2,4,6]).write(to:URL(fileURLWithPath:image.path))
        let montage=MediaMontage(name:"Portable montage",clips:[MontageClip(assetID:video.id),MontageClip(assetID:image.id,start:2,duration:3)])
        let surface=Surface(mediaID:montage.id),before=Project(assets:[video,image],surfaces:[surface],montages:[montage])
        var after=before;after.montages[0].clips[0].sourceIn=0.2;after.montages[0].clips[0].sourceOut=1.2
        let history=EditHistory();history.commit(before:before,after:after,label:"Edit montage clip")
        XCTAssertEqual(history.undo(current:after),before);XCTAssertEqual(history.redo(current:before),after)
        let saved=scratch.appendingPathComponent("show.json")
        try ProjectStore.save(after,to:saved);XCTAssertEqual(try ProjectStore.load(from:saved),after)
        try ProjectStore.saveRecovery(before,for:saved);XCTAssertEqual(try ProjectStore.loadRecovery(for:saved),before)
        let folder=scratch.appendingPathComponent("portable")
        let collected=try ProjectStore.collect(after,to:folder)
        try FileManager.default.removeItem(at:URL(fileURLWithPath:video.path));try FileManager.default.removeItem(at:URL(fileURLWithPath:image.path))
        let loaded=try ProjectStore.load(from:collected)
        XCTAssertEqual(loaded.montages,after.montages);XCTAssertEqual(loaded.surfaces,after.surfaces)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:folder.appendingPathComponent("media").path).count,2)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:loaded.assets[0].path)),Data([1,3,5,7]))
        XCTAssertFalse(try String(contentsOf:collected,encoding:.utf8).contains(scratch.path))
        XCTAssertEqual(after.assets,[video,image]);XCTAssertEqual(after.montages[0].id,montage.id)
    }

    func testSharedAssetMultipleMontagesHaveIndependentSourcePositions() throws {
        let video=MediaAsset(name:"Ordinary movie",path:scratch.appendingPathComponent("movie.mov").path,kind:"video",loop:false,volume:0.7)
        let first=MediaMontage(name:"First",clips:[MontageClip(assetID:video.id,duration:2,sourceIn:1,sourceOut:3)])
        let second=MediaMontage(name:"Second",clips:[MontageClip(assetID:video.id,duration:2,sourceIn:4,sourceOut:8,rate:2)])
        let ordinary=Surface(mediaID:video.id),one=Surface(mediaID:first.id),two=Surface(mediaID:second.id)
        let project=Project(assets:[video],surfaces:[ordinary,one,two],montages:[first,second])
        try ProjectStore.validate(project)
        let program=try MontageProgram(montages:project.montages,assets:project.assets)
        XCTAssertEqual(try XCTUnwrap(program.sample(id:first.id,time:0.25)).sourceTime,1.25)
        XCTAssertEqual(try XCTUnwrap(program.sample(id:second.id,time:0.25)).sourceTime,4.5)
        _=try program.sample(id:second.id,time:1.5)
        XCTAssertEqual(try XCTUnwrap(program.sample(id:first.id,time:0.25)).sourceTime,1.25)
        XCTAssertEqual(project.assets,[video]);XCTAssertEqual(project.surfaces,[ordinary,one,two])
        XCTAssertFalse(video.loop);XCTAssertEqual(video.volume,0.7)
    }

    func testSignedRateCrossfadeAndIndependentAudioLane() throws {
        let video = asset()
        let wav = asset("audio")
        let a = MontageClip(assetID: video.id, duration: 1, sourceOut: 1, audioEnabled: true)
        let b = MontageClip(assetID: video.id, start: 0.5, duration: 1, sourceIn: 2, sourceOut: 3,
                            rate: -1, crossfadeIn: 0.5)
        let audio = MontageClip(assetID: wav.id, start: 0.25, duration: 1, sourceIn: 2, sourceOut: 4, rate: 0.5)
        let montage = MediaMontage(duration: 2, loop: true, clips: [b, audio, a])
        let program = try MontageProgram(montages: [montage], assets: [video, wav])
        let start = try XCTUnwrap(program.sample(id: montage.id, time: 0.5))
        XCTAssertEqual(start.visual.map(\.weight), [1, 0])
        XCTAssertEqual(start.visual.last?.sourceTime, 3.0.nextDown)
        let mid = try XCTUnwrap(program.sample(id: montage.id, time: 0.75))
        XCTAssertEqual(mid.visual.map(\.weight), [0.5, 0.5])
        XCTAssertEqual(mid.visual.map(\.sourceTime), [0.75, 2.75])
        XCTAssertEqual(mid.audio.map(\.clip.id), [a.id, audio.id])
        XCTAssertEqual(mid.audio.map(\.weight), [0.5, 1])
        XCTAssertEqual(mid.audio.map(\.sourceTime), [0.75, 2.25])
        XCTAssertEqual(mid.audio.map(\.audioEnd), [1, 2.5])
        let end = try XCTUnwrap(program.sample(id: montage.id, time: 1))
        XCTAssertEqual(end.visual.map(\.clip.id), [b.id])
        XCTAssertEqual(end.visual.map(\.sourceTime), [2.5])
        XCTAssertEqual(end.audio.map(\.clip.id), [audio.id])
        let repeatSample = try XCTUnwrap(program.sample(id: montage.id, time: 2.75))
        XCTAssertEqual(repeatSample.visual, mid.visual)
        XCTAssertEqual(repeatSample.audio, mid.audio)
        XCTAssertEqual(repeatSample.montageCycle, 1)

        let looping = MontageClip(assetID: video.id, duration: 2, sourceIn: 1, sourceOut: 2, rate: -2, loop: true)
        let reverse = MediaMontage(duration: 2, clips: [looping])
        let reverseProgram = try MontageProgram(montages: [reverse], assets: [video])
        let wrap = try XCTUnwrap(reverseProgram.sample(id: reverse.id, time: 0.5))
        XCTAssertEqual(wrap.sourceTime, 2.0.nextDown)
        XCTAssertEqual(wrap.clipCycle, 1)
    }

    func testExplicitCrossfadeRejectsTripleOrMismatchedOverlap() throws {
        let video = asset()
        let wav = asset("audio")
        let first = MontageClip(assetID: video.id, duration: 2, sourceOut: 2)
        let good = MontageClip(assetID: video.id, start: 1, duration: 2, sourceOut: 2, crossfadeIn: 1)
        let badThird = MontageClip(assetID: video.id, start: 1.5, duration: 2, sourceOut: 2, crossfadeIn: 1.5)
        let goodThird = MontageClip(assetID: video.id, start: 2, duration: 2, sourceOut: 2, crossfadeIn: 1)
        let audio = MontageClip(assetID: wav.id, duration: 2, sourceOut: 2)
        try MontageProgram.validate(montages: [MediaMontage(clips: [goodThird, audio, first, good])], assets: [video, wav])
        XCTAssertThrowsError(try MontageProgram.validate(montages: [MediaMontage(clips: [first, good, badThird])], assets: [video]))
        for value in [nil, 0.5, 0, Double.nan] as [Double?] {
            var bad = good
            bad.crossfadeIn = value
            XCTAssertThrowsError(try MontageProgram.validate(montages: [MediaMontage(clips: [first, bad])], assets: [video]))
        }

        let dangling = MontageClip(assetID: video.id, start: 2, duration: 1, crossfadeIn: 1)
        let reverseAudio = MontageClip(assetID: wav.id, duration: 1, rate: -1)
        let reverseWithAudio = MontageClip(assetID: video.id, duration: 1, rate: -1, audioEnabled: true)
        for clip in [dangling, reverseAudio, reverseWithAudio] {
            XCTAssertThrowsError(try MontageProgram.validate(montages: [MediaMontage(clips: [clip])], assets: [video, wav]))
        }
    }

    func testSchemaFourteenMontageOptionsRoundTripAndLegacyIsolation() throws {
        let video = asset()
        let audio = asset("audio")
        let first = MontageClip(assetID: video.id, duration: 1, audioEnabled: true)
        let second = MontageClip(assetID: video.id, start: 0.5, duration: 1, rate: -1, crossfadeIn: 0.5)
        let audioClip = MontageClip(assetID: audio.id, duration: 1)
        let montage = MediaMontage(clips: [first, second, audioClip])
        let project = Project(assets: [video, audio], surfaces: [Surface(mediaID: montage.id)], montages: [montage])
        let current = try write(object(project))
        XCTAssertEqual(try ProjectStore.load(from: current).montages, [montage])

        var legacy = try object(Project(assets: [video, audio], montages: [MediaMontage(clips: [first])]))
        legacy["version"] = 13
        var definitions = try XCTUnwrap(legacy["montages"] as? [[String: Any]])
        var clips = try XCTUnwrap(definitions[0]["clips"] as? [[String: Any]])
        clips[0]["crossfadeIn"] = "formerly undefined"
        clips[0]["audioEnabled"] = [1, 2, 3]
        definitions[0]["clips"] = clips
        legacy["montages"] = definitions
        let stripped = try XCTUnwrap(ProjectStore.load(from: write(legacy)).montages.first?.clips.first)
        XCTAssertNil(stripped.audioEnabled)
        XCTAssertNil(stripped.crossfadeIn)

        clips[0]["rate"] = -1
        definitions[0]["clips"] = clips
        legacy["montages"] = definitions
        XCTAssertThrowsError(try ProjectStore.load(from: write(legacy)))

        clips[0]["rate"] = 1
        clips[0]["assetID"] = audio.id.uuidString
        definitions[0]["clips"] = clips
        legacy["montages"] = definitions
        XCTAssertThrowsError(try ProjectStore.load(from: write(legacy)))
        let invalidLegacy = Project(version: 13, assets: [audio], montages: [MediaMontage(clips: [audioClip])])
        XCTAssertThrowsError(try ProjectStore.save(invalidLegacy, to: current))
    }

}
