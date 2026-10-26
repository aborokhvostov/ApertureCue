import XCTest
import Foundation
@testable import MappingCore

final class ProjectTests: XCTestCase {
    private var scratch: URL!
    override func setUpWithError() throws {
        scratch=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:scratch) }

    func testAtomicRoundTripRelativePathsAndMissingMedia() throws {
        let projectURL=scratch.appendingPathComponent("show.aperturecue")
        let mediaURL=scratch.appendingPathComponent("media/missing.png")
        let asset=MediaAsset(name:"Missing is recoverable",path:mediaURL.path,kind:"image")
        var p=Project.demo(); p.assets=[asset]; p.surfaces[0].mediaID=asset.id
        try ProjectStore.save(p,to:projectURL)
        let data=try Data(contentsOf:projectURL)
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        let assets=try XCTUnwrap(json["assets"] as? [[String:Any]])
        XCTAssertEqual(assets[0]["path"] as? String,"media/missing.png")
        let restored=try ProjectStore.load(from:projectURL)
        XCTAssertEqual(restored,p)
        p.name="Replaced atomically"; try ProjectStore.save(p,to:projectURL)
        XCTAssertEqual(try ProjectStore.load(from:projectURL).name,p.name)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:scratch.path).filter { $0 == projectURL.lastPathComponent }.count,1)
    }

    func testExternalRelativePathAndUnicode() throws {
        let folder=scratch.appendingPathComponent("shows")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let url=folder.appendingPathComponent("тест.aperturecue")
        let asset=MediaAsset(name:"тест",path:scratch.appendingPathComponent("素材.png").path,kind:"image")
        let p=Project(name:"Сцена",assets:[asset])
        try ProjectStore.save(p,to:url)
        XCTAssertEqual(try ProjectStore.load(from:url),p)
        XCTAssertTrue(try String(contentsOf:url,encoding:.utf8).contains("../素材.png"))
    }

    func testRecoveryDoesNotOverwriteSavedProject() throws {
        let url=scratch.appendingPathComponent("show.aperturecue")
        var p=Project.demo(); try ProjectStore.save(p,to:url)
        p.name="Unsaved edit"; try ProjectStore.saveRecovery(p,for:url)
        XCTAssertEqual(try ProjectStore.loadRecovery(for:url).name,"Unsaved edit")
        XCTAssertEqual(try ProjectStore.load(from:url).name,"ApertureCue Demo")
    }

    func testVersionMigrationAndFutureVersionRejection() throws {
        let url=scratch.appendingPathComponent("legacy.aperturecue")
        try Data("{\"name\":\"Legacy\",\"surfaces\":[{\"name\":\"Quad\"}]}".utf8).write(to:url)
        let p=try ProjectStore.load(from:url)
        XCTAssertEqual(p.version,Project.currentVersion); XCTAssertEqual(p.surfaces[0].opacity,1)
        try Data("{\"version\":999,\"name\":\"Future\"}".utf8).write(to:url)
        XCTAssertThrowsError(try ProjectStore.load(from:url)) { XCTAssertEqual($0 as? ProjectError,.unsupportedVersion(999)) }
    }

    func testMalformedDocumentsAndReferencesRejected() throws {
        var p=Project.demo(); p.surfaces.append(p.surfaces[0])
        XCTAssertThrowsError(try ProjectStore.validate(p))
        p=Project.demo(); p.surfaces[0].mediaID=UUID()
        XCTAssertThrowsError(try ProjectStore.validate(p))
        p=Project.demo(); p.surfaces[0].opacity=2
        XCTAssertThrowsError(try ProjectStore.validate(p))
        p=Project.demo(); p.surfaces[0].meshColumns=4
        XCTAssertThrowsError(try ProjectStore.validate(p))
        p=Project.demo(); p.outputs[0].width=0
        XCTAssertThrowsError(try ProjectStore.validate(p))
        let url=scratch.appendingPathComponent("oversized.aperturecue")
        try Data(repeating:32,count:ProjectStore.maximumFileSize+1).write(to:url)
        XCTAssertThrowsError(try ProjectStore.load(from:url)) { XCTAssertEqual($0 as? ProjectError,.tooLarge) }
    }

    func testUndoRedoBranchAndBoundedHistory() {
        let h=EditHistory(capacity:2)
        var a=Project(name:"A"), b=a; b.name="B"
        h.commit(before:a,after:b,label:"Rename")
        XCTAssertTrue(h.canUndo); XCTAssertEqual(h.undoLabel,"Rename")
        XCTAssertEqual(h.undo(current:b),a); XCTAssertTrue(h.canRedo)
        XCTAssertEqual(h.redo(current:a),b)
        var c=b; c.name="C"; h.commit(before:b,after:c,label:"Rename C")
        var d=c; d.name="D"; h.commit(before:c,after:d,label:"Rename D")
        XCTAssertEqual(h.undo(current:d),c); XCTAssertEqual(h.undo(current:c),b)
        XCTAssertNil(h.undo(current:b))
        a.name="Branch"; h.commit(before:b,after:a,label:"Branch")
        XCTAssertFalse(h.canRedo)
    }
}
