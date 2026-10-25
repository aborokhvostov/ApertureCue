import XCTest
import Foundation
@testable import MappingCore

final class CollectTests:XCTestCase {
    private var scratch:URL!
    override func setUpWithError() throws {
        scratch=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueCollect-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:scratch) }

    func testCollectedProjectSurvivesOriginalDeletionAndDuplicateNames() throws {
        let a=scratch.appendingPathComponent("original-a"),b=scratch.appendingPathComponent("original-b")
        try FileManager.default.createDirectory(at:a,withIntermediateDirectories:false)
        try FileManager.default.createDirectory(at:b,withIntermediateDirectories:false)
        let image=a.appendingPathComponent("same.PNG"),video=b.appendingPathComponent("same.PNG")
        let first=Data([1,2,3,4]),second=Data([9,8,7,6,5])
        try first.write(to:image); try second.write(to:video)
        let one=MediaAsset(name:"First",path:image.path,kind:"image"),two=MediaAsset(name:"Second",path:video.path,kind:"image")
        let project=Project(name:"Collected",assets:[one,two],surfaces:[Surface(name:"One",mediaID:one.id),Surface(name:"Two",mediaID:two.id)])
        let folder=scratch.appendingPathComponent("portable",isDirectory:true)
        let saved=try ProjectStore.collect(project,to:folder)
        try FileManager.default.removeItem(at:a); try FileManager.default.removeItem(at:b)
        let loaded=try ProjectStore.load(from:saved)
        XCTAssertEqual(loaded.assets.map(\.id),project.assets.map(\.id))
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:loaded.assets[0].path)),first)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:loaded.assets[1].path)),second)
        XCTAssertFalse(loaded.assets[0].path == loaded.assets[1].path)
        XCTAssertTrue(loaded.assets.allSatisfy { $0.path.hasPrefix(folder.path+"/media/") && $0.path.hasSuffix(".PNG") })
        let json=try String(contentsOf:saved,encoding:.utf8)
        XCTAssertFalse(json.contains(scratch.path)); XCTAssertTrue(json.contains("media/"))
        XCTAssertEqual(project.assets[0].path,image.path)
    }
    func testMissingMediaRollsBackAndExistingDestinationIsUntouched() throws {
        let good=scratch.appendingPathComponent("good.png")
        try Data([1,2,3]).write(to:good)
        let project=Project(assets:[MediaAsset(name:"Good",path:good.path,kind:"image"),MediaAsset(name:"Missing",path:scratch.appendingPathComponent("missing.mp4").path,kind:"video")])
        let folder=scratch.appendingPathComponent("never-created",isDirectory:true)
        XCTAssertThrowsError(try ProjectStore.collect(project,to:folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:scratch.path).contains { $0.contains(".collect-") })
        XCTAssertEqual(try Data(contentsOf:good),Data([1,2,3]))
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        let sentinel=folder.appendingPathComponent("keep.txt"); try Data("Keep".utf8).write(to:sentinel)
        XCTAssertThrowsError(try ProjectStore.collect(Project(),to:folder))
        XCTAssertEqual(try String(contentsOf:sentinel,encoding:.utf8),"Keep")
    }
    func testCameraIdentitiesAndSymlinkMediaRemainPortable() throws {
        let target=scratch.appendingPathComponent("real.png"),link=scratch.appendingPathComponent("alias.png")
        try Data([10,20,30]).write(to:target)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        let camera=MediaAsset(name:"Live camera",path:"camera-unique-id",kind:"camera")
        let image=MediaAsset(name:"Link",path:link.path,kind:"image")
        let folder=scratch.appendingPathComponent("camera-show",isDirectory:true)
        let saved=try ProjectStore.collect(Project(assets:[camera,image]),to:folder)
        try FileManager.default.removeItem(at:target); try FileManager.default.removeItem(at:link)
        let loaded=try ProjectStore.load(from:saved)
        XCTAssertEqual(loaded.assets[0],camera)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:loaded.assets[1].path)),Data([10,20,30]))
        let attributes=try FileManager.default.attributesOfItem(atPath:loaded.assets[1].path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType,.typeRegular)
        XCTAssertThrowsError(try ProjectStore.collect(Project(assets:[MediaAsset(name:"Relative",path:"relative.png",kind:"image")]),to:scratch.appendingPathComponent("relative-copy")))
    }
}
