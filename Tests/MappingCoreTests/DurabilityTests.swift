import XCTest
import Foundation
@testable import MappingCore

final class DurabilityTests:XCTestCase {
    private var scratch:URL!
    override func setUpWithError() throws {
        scratch=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueDurability-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws {try FileManager.default.removeItem(at:scratch)}
    private func saved(_ name:String="show.aperturecue.json") throws -> (URL,Project) {
        let url=scratch.appendingPathComponent(name),project=Project(name:"Saved original")
        try ProjectStore.save(project,to:url);return (url,project)
    }
    private func writeObject(_ object:[String:Any],to url:URL) throws {
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:url,options:.atomic)
    }
    func testPortableContentDigestVectors() {
        XCTAssertEqual(ProjectContentDigest.sha256(Data()),"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ProjectContentDigest.sha256(Data("abc".utf8)),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(ProjectContentDigest.sha256(Data(repeating:97,count:1000)),"41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }
    func testEditorOpenAndSaveReturnBaselineForExactlyTheirProjectBytes() throws {
        let url=scratch.appendingPathComponent("revision.aperturecue.json")
        let original=Project(name:"Single revision read")
        let savedBaseline=try ProjectStore.saveWithRecoveryBaseline(original,to:url)
        let opened=try ProjectStore.loadWithRecoveryBaseline(from:url)
        XCTAssertEqual(opened.project,original);XCTAssertEqual(opened.baseline,savedBaseline)
        XCTAssertEqual(opened.baseline.sourceSHA256,ProjectContentDigest.sha256(try Data(contentsOf:url)))
        var edited=original;edited.name="Changed revision"
        try ProjectStore.saveRecovery(edited,for:url,baseline:opened.baseline)
        let updatedBaseline=try ProjectStore.saveWithRecoveryBaseline(edited,to:url)
        XCTAssertFalse(updatedBaseline==opened.baseline)
        XCTAssertTrue(try ProjectStore.removeRecovery(for:url,baseline:opened.baseline))
        XCTAssertEqual(try ProjectStore.loadWithRecoveryBaseline(from:url).project,edited)
    }
    func testBoundRecoveryRoundTripsPortablePathsAndNeverChangesSavedBytes() throws {
        let (url,original)=try saved("сцена.aperturecue.json")
        let baseline=try ProjectStore.captureRecoveryBaseline(for:url),savedBytes=try Data(contentsOf:url)
        let image=MediaAsset(name:"Own missing frame",path:scratch.appendingPathComponent("frames/素材.png").path,kind:"image")
        var edited=original;edited.assets=[image];edited.surfaces=[Surface(mediaID:image.id)]
        XCTAssertEqual(ProjectStore.recoveryStatus(for:url).state,.missing)
        try ProjectStore.saveRecovery(edited,for:url,baseline:baseline)
        XCTAssertEqual(ProjectStore.recoveryStatus(for:url).state,.available)
        XCTAssertEqual(try ProjectStore.loadRecovery(for:url),edited)
        XCTAssertEqual(try Data(contentsOf:url),savedBytes)
        let sidecar=try String(contentsOf:ProjectStore.recoveryURL(for:url),encoding:.utf8)
        XCTAssertTrue(sidecar.contains("ApertureCue recovery"))
        XCTAssertEqual(try ProjectStore.load(from:url),original)
    }
    func testSameSizeAndSameModificationTimeReplacementMakesRecoveryStale() throws {
        let (url,original)=try saved(),baseline=try ProjectStore.captureRecoveryBaseline(for:url)
        var edited=original;edited.name="Unsaved edit"
        try ProjectStore.saveRecovery(edited,for:url,baseline:baseline)
        let sidecar=ProjectStore.recoveryURL(for:url),snapshot=try Data(contentsOf:sidecar)
        let before=try Data(contentsOf:url),oldDate=Date(timeIntervalSince1970:baseline.sourceModificationTime)
        let text=try XCTUnwrap(String(data:before,encoding:.utf8))
        let replaced=Data(text.replacingOccurrences(of:"Saved original",with:"Other original").utf8)
        XCTAssertEqual(before.count,replaced.count)
        try replaced.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.modificationDate:oldDate],ofItemAtPath:url.path)
        XCTAssertEqual(ProjectStore.recoveryStatus(for:url).state,.stale)
        XCTAssertThrowsError(try ProjectStore.loadRecovery(for:url))
        XCTAssertThrowsError(try ProjectStore.saveRecovery(edited,for:url,baseline:baseline))
        XCTAssertEqual(try Data(contentsOf:url),replaced)
        XCTAssertEqual(try Data(contentsOf:sidecar),snapshot)
    }
    func testCopiedRecoveryCannotAttachToSameBytesAtAnotherDocumentPath() throws {
        let (url,original)=try saved(),other=scratch.appendingPathComponent("other.aperturecue.json")
        try FileManager.default.copyItem(at:url,to:other)
        var edited=original;edited.name="Own pending changes"
        try ProjectStore.saveRecovery(edited,for:url)
        let first=ProjectStore.recoveryURL(for:url),second=ProjectStore.recoveryURL(for:other)
        try FileManager.default.copyItem(at:first,to:second)
        XCTAssertEqual(ProjectStore.recoveryStatus(for:other).state,.stale)
        XCTAssertThrowsError(try ProjectStore.loadRecovery(for:other))
        XCTAssertFalse(try ProjectStore.removeRecovery(for:other,baseline:ProjectStore.captureRecoveryBaseline(for:other)))
        XCTAssertEqual(try Data(contentsOf:first),try Data(contentsOf:second))
    }
    func testLegacyCorruptAndSymlinkSidecarsArePreserved() throws {
        let (url,project)=try saved(),baseline=try ProjectStore.captureRecoveryBaseline(for:url)
        let sidecar=ProjectStore.recoveryURL(for:url)
        try ProjectStore.save(project,to:sidecar)
        let legacy=try Data(contentsOf:sidecar)
        XCTAssertEqual(ProjectStore.recoveryStatus(for:url).state,.legacy)
        XCTAssertThrowsError(try ProjectStore.saveRecovery(project,for:url,baseline:baseline))
        XCTAssertThrowsError(try ProjectStore.loadRecovery(for:url))
        XCTAssertFalse(try ProjectStore.removeRecovery(for:url,baseline:baseline))
        XCTAssertEqual(try Data(contentsOf:sidecar),legacy)
        try Data("{broken recovery".utf8).write(to:sidecar,options:.atomic)
        let broken=try Data(contentsOf:sidecar)
        XCTAssertEqual(ProjectStore.recoveryStatus(for:url).state,.invalid)
        XCTAssertThrowsError(try ProjectStore.saveRecovery(project,for:url,baseline:baseline))
        XCTAssertFalse(try ProjectStore.removeRecovery(for:url,baseline:baseline))
        XCTAssertEqual(try Data(contentsOf:sidecar),broken)
        try FileManager.default.removeItem(at:sidecar)
        let foreign=scratch.appendingPathComponent("keep.txt");try Data("Keep original".utf8).write(to:foreign)
        try FileManager.default.createSymbolicLink(at:sidecar,withDestinationURL:foreign)
        XCTAssertEqual(ProjectStore.recoveryStatus(for:url).state,.invalid)
        XCTAssertThrowsError(try ProjectStore.saveRecovery(project,for:url,baseline:baseline))
        XCTAssertEqual(try String(contentsOf:foreign,encoding:.utf8),"Keep original")
    }
    func testPayloadCorruptionAndFutureEnvelopeAreRejectedWithoutDeletion() throws {
        let (url,project)=try saved(),sidecar=ProjectStore.recoveryURL(for:url)
        try ProjectStore.saveRecovery(project,for:url)
        let original=try Data(contentsOf:sidecar)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:original) as? [String:Any])
        object["payload"]=Data("different bytes".utf8).base64EncodedString();try writeObject(object,to:sidecar)
        XCTAssertEqual(ProjectStore.recoveryStatus(for:url).state,.invalid)
        XCTAssertThrowsError(try ProjectStore.loadRecovery(for:url))
        XCTAssertTrue(FileManager.default.fileExists(atPath:sidecar.path))
        object=try XCTUnwrap(JSONSerialization.jsonObject(with:original) as? [String:Any]);object["version"]=999
        try writeObject(object,to:sidecar)
        XCTAssertEqual(ProjectStore.recoveryStatus(for:url).state,.invalid)
        XCTAssertThrowsError(try ProjectStore.loadRecovery(for:url))
    }
    func testOwnedRecoveryUpdatesAndCleanupUsesPreSaveBaseline() throws {
        let (url,project)=try saved(),baseline=try ProjectStore.captureRecoveryBaseline(for:url)
        var edited=project;edited.name="First pending"
        try ProjectStore.saveRecovery(edited,for:url,baseline:baseline)
        edited.name="Latest pending";try ProjectStore.saveRecovery(edited,for:url,baseline:baseline)
        XCTAssertEqual(try ProjectStore.loadRecovery(for:url).name,"Latest pending")
        try ProjectStore.save(edited,to:url)
        XCTAssertEqual(ProjectStore.recoveryStatus(for:url).state,.stale)
        XCTAssertFalse(try ProjectStore.removeRecovery(for:url,baseline:ProjectStore.captureRecoveryBaseline(for:url)))
        XCTAssertTrue(try ProjectStore.removeRecovery(for:url,baseline:baseline))
        XCTAssertEqual(ProjectStore.recoveryStatus(for:url).state,.missing)
        XCTAssertEqual(try ProjectStore.load(from:url),edited)
    }
    func testBaselineCapturedBeforeExternalSaveCannotRebindLaterAutosave() throws {
        let (url,project)=try saved(),oldBaseline=try ProjectStore.captureRecoveryBaseline(for:url)
        var external=project;external.name="External revision";try ProjectStore.save(external,to:url)
        let externalBytes=try Data(contentsOf:url)
        var edited=project;edited.name="Still editing old revision"
        try ProjectStore.saveRecovery(edited,for:url,baseline:oldBaseline)
        XCTAssertEqual(ProjectStore.recoveryStatus(for:url).state,.stale)
        XCTAssertThrowsError(try ProjectStore.loadRecovery(for:url))
        XCTAssertEqual(try Data(contentsOf:url),externalBytes)
    }
    func testOldEditorCannotOverwriteAnotherRevisionAvailableRecovery() throws {
        let (url,original)=try saved(),oldBaseline=try ProjectStore.captureRecoveryBaseline(for:url)
        var external=original;external.name="New saved revision";try ProjectStore.save(external,to:url)
        let currentBaseline=try ProjectStore.captureRecoveryBaseline(for:url)
        var currentEdit=external;currentEdit.name="New editor pending edit"
        try ProjectStore.saveRecovery(currentEdit,for:url,baseline:currentBaseline)
        let bytes=try Data(contentsOf:ProjectStore.recoveryURL(for:url))
        var oldEdit=original;oldEdit.name="Old editor autosave"
        XCTAssertThrowsError(try ProjectStore.saveRecovery(oldEdit,for:url,baseline:oldBaseline))
        XCTAssertEqual(try Data(contentsOf:ProjectStore.recoveryURL(for:url)),bytes)
        XCTAssertEqual(try ProjectStore.loadRecovery(for:url),currentEdit)
        let other=scratch.appendingPathComponent("copy.aperturecue.json")
        try FileManager.default.copyItem(at:url,to:other)
        try FileManager.default.copyItem(at:ProjectStore.recoveryURL(for:url),to:ProjectStore.recoveryURL(for:other))
        XCTAssertFalse(try ProjectStore.removeRecovery(for:other,baseline:currentBaseline))
    }
    func testSequenceCollectionFreezesManifestAndSurvivesSourceRemoval() throws {
        let folder=scratch.appendingPathComponent("source-sequence",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        let frames=["own1.png","own003.png","own10.png"],payloads=[Data([1,2]),Data([3,4]),Data([9,10])]
        for (name,bytes) in zip(frames,payloads) {try bytes.write(to:folder.appendingPathComponent(name))}
        try Data([99]).write(to:folder.appendingPathComponent("added-later.png"))
        let settings=MediaSequenceSettings(frames:frames,fps:12.5)
        let asset=MediaAsset(name:"Original frames",path:folder.path,kind:"sequence",playback:.init(rate:-0.5,mode:.pingPong),sequence:settings)
        let project=Project(assets:[asset],surfaces:[Surface(mediaID:asset.id)])
        let destination=scratch.appendingPathComponent("portable",isDirectory:true)
        let saved=try ProjectStore.collect(project,to:destination)
        try FileManager.default.removeItem(at:folder)
        let loaded=try ProjectStore.load(from:saved),copied=try XCTUnwrap(loaded.assets.first)
        XCTAssertEqual(copied.sequence,settings);XCTAssertEqual(copied.playback,asset.playback)
        XCTAssertEqual(loaded.surfaces,project.surfaces)
        for (name,bytes) in zip(frames,payloads) {XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:copied.path).appendingPathComponent(name)),bytes)}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:copied.path).sorted(),frames.sorted())
        XCTAssertFalse(try String(contentsOf:saved,encoding:.utf8).contains(scratch.path))
    }
    func testSequenceCollectionMissingSymlinkAndOversizedFramesRollBack() throws {
        let folder=scratch.appendingPathComponent("source",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        let frame=folder.appendingPathComponent("one.png")
        var asset=MediaAsset(name:"Sequence",path:folder.path,kind:"sequence",sequence:.init(frames:["missing.png"]))
        let missing=scratch.appendingPathComponent("missing-copy")
        XCTAssertThrowsError(try ProjectStore.collect(Project(assets:[asset]),to:missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath:missing.path))
        let external=scratch.appendingPathComponent("external.png");try Data([1,2,3]).write(to:external)
        try FileManager.default.createSymbolicLink(at:frame,withDestinationURL:external)
        asset.sequence = .init(frames:["one.png"])
        XCTAssertThrowsError(try ProjectStore.collect(Project(assets:[asset]),to:scratch.appendingPathComponent("symlink-copy")))
        XCTAssertEqual(try Data(contentsOf:external),Data([1,2,3]))
        try FileManager.default.removeItem(at:frame)
        XCTAssertTrue(FileManager.default.createFile(atPath:frame.path,contents:Data()))
        let handle=try FileHandle(forWritingTo:frame);defer {try? handle.close()}
        try handle.truncate(atOffset:UInt64(ProjectStore.maximumSequenceFrameBytes)+1)
        let large=scratch.appendingPathComponent("large-copy")
        XCTAssertThrowsError(try ProjectStore.collect(Project(assets:[asset]),to:large))
        XCTAssertFalse(FileManager.default.fileExists(atPath:large.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:scratch.path).contains {$0.contains(".collect-")})
        asset.sequence = .init(frames:["../external.png"])
        XCTAssertThrowsError(try ProjectStore.validate(Project(assets:[asset])))
    }
    func testSchemaThirteenMediaValidationAndLegacySaveCannotActivateExtensions() throws {
        let video=MediaAsset(name:"Own missing movie",path:scratch.appendingPathComponent("own.mov").path,kind:"video",playback:.init(rate:2,mode:.once),audioRouting:.identity(inputChannels:2,outputChannels:2))
        let url=scratch.appendingPathComponent("media.aperturecue.json")
        var project=Project(assets:[video]);try ProjectStore.save(project,to:url)
        XCTAssertEqual(try ProjectStore.load(from:url),project)
        try ProjectStore.saveRecovery(project,for:url)
        XCTAssertEqual(try ProjectStore.loadRecovery(for:url),project)
        project.version=12;try ProjectStore.save(project,to:url)
        let migrated=try ProjectStore.load(from:url)
        XCTAssertNil(migrated.assets[0].playback);XCTAssertNil(migrated.assets[0].sequence);XCTAssertNil(migrated.assets[0].audioRouting)
        var invalid=Project(assets:[MediaAsset(name:"Image",path:"own.png",kind:"image",audioRouting:.init())])
        XCTAssertThrowsError(try ProjectStore.validate(invalid))
        invalid.assets[0].audioRouting=nil;invalid.assets[0].sequence = .init(frames:["one.png"])
        XCTAssertThrowsError(try ProjectStore.validate(invalid))
        invalid.assets[0].sequence=nil;invalid.assets[0].playback = .init()
        XCTAssertThrowsError(try ProjectStore.validate(invalid))
    }
}
