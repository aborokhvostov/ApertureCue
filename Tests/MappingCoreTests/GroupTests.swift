import XCTest
import Foundation
@testable import MappingCore

final class GroupTests:XCTestCase {
    private func samePoints(_ a:[Point2],_ b:[Point2],file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertEqual(a.count,b.count,file:file,line:line)
        for (p,q) in zip(a,b) { XCTAssertEqual(p.x,q.x,accuracy:1e-9,file:file,line:line); XCTAssertEqual(p.y,q.y,accuracy:1e-9,file:file,line:line) }
    }
    private func equivalent(_ a:[Surface],_ b:[Surface],file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertEqual(a.map(\.id),b.map(\.id),file:file,line:line)
        for (p,q) in zip(a,b) {
            samePoints(p.output,q.output,file:file,line:line); samePoints(p.mesh,q.mesh,file:file,line:line)
            XCTAssertEqual(p.opacity,q.opacity,accuracy:1e-12,file:file,line:line)
            XCTAssertEqual(p.enabled,q.enabled,file:file,line:line)
            XCTAssertEqual(p.input,q.input,file:file,line:line); XCTAssertEqual(p.mask,q.mask,file:file,line:line); XCTAssertEqual(p.shape,q.shape,file:file,line:line)
        }
    }
    func testAffineCompositionInverseReflectionAndAspectRotation() throws {
        let move=Affine2D.translation(x:0.2,y:-0.1), scale=Affine2D.scale(x:2,y:0.5,around:Point2(0,0))
        let point=Point2(0.3,0.4)
        let first=try move.concatenating(scale).applying(point), second=try scale.concatenating(move).applying(point)
        XCTAssertEqual(first.x,0.8,accuracy:1e-12); XCTAssertEqual(first.y,0.1,accuracy:1e-12)
        XCTAssertEqual(second.x,1,accuracy:1e-12); XCTAssertEqual(second.y,0.15,accuracy:1e-12)
        samePoints([try move.concatenating(scale).inverse().applying(first)],[point])
        let rotation=Affine2D.rotation(degrees:90,around:Point2(0.5,0.5),aspectRatio:2)
        samePoints([try rotation.applying(Point2(0.75,0.5))],[Point2(0.5,1)])
        let reflection=Affine2D.scale(x:-1,y:1)
        samePoints(try Point2.unitQuad.map { try reflection.applying($0) },[Point2(1,0),Point2(0,0),Point2(0,1),Point2(1,1)])
        XCTAssertThrowsError(try Affine2D.scale(x:0,y:1).inverse())
        XCTAssertThrowsError(try Affine2D(tx:.nan).inverse())
    }
    func testHierarchyResolvesMeshAppearanceAndIndependentSource() throws {
        let root=SurfaceGroup(name:"Root",transform:.translation(x:0.2,y:0.1),opacity:0.5)
        let child=SurfaceGroup(name:"Child",parentID:root.id,transform:.scale(x:0.5,y:0.5,around:Point2(0,0)),opacity:0.4)
        var surface=Surface(output:Point2.unitQuad,opacity:0.8,mask:[Point2(0,0),Point2(1,0),Point2(0,1)],meshColumns:1,meshRows:1,shape:.ellipse,groupID:child.id)
        surface.mesh=try Geometry.regularMesh(quad:surface.output,columns:1,rows:1)
        surface.input=[Point2(0.2,0.2),Point2(0.8,0.2),Point2(0.8,0.8),Point2(0.2,0.8)]
        let resolved=try GroupEngine.resolve(surfaces:[surface],groups:[child,root])[0]
        samePoints(resolved.output,[Point2(0.2,0.1),Point2(0.7,0.1),Point2(0.7,0.6),Point2(0.2,0.6)])
        XCTAssertEqual(resolved.opacity,0.16,accuracy:1e-12); XCTAssertEqual(resolved.input,surface.input); XCTAssertEqual(resolved.mask,surface.mask); XCTAssertEqual(resolved.shape,.ellipse)
        var hidden=root; hidden.enabled=false
        XCTAssertFalse(try GroupEngine.resolve(surfaces:[surface],groups:[child,hidden])[0].enabled)
        let project=Project(surfaces:[surface],groups:[child,root])
        let bounds=try XCTUnwrap(GroupEngine.bounds(for:root.id,in:project))
        samePoints([bounds.min,bounds.max,bounds.center],[Point2(0.2,0.1),Point2(0.7,0.6),Point2(0.45,0.35)])
        let empty=SurfaceGroup(name:"unused")
        XCTAssertNil(try GroupEngine.bounds(for:empty.id,in:Project(groups:[empty])))
    }
    func testAssignReparentAndWorldDeltaPreserveLocalGeometry() throws {
        let a=SurfaceGroup(name:"A",transform:.translation(x:0.1,y:0.2))
        let b=SurfaceGroup(name:"B",transform:.rotation(degrees:25),opacity:0.7)
        let child=SurfaceGroup(name:"Child",parentID:a.id,transform:.scale(x:0.8,y:0.6))
        let surface=Surface(groupID:child.id)
        let initial=Project(surfaces:[surface],cues:[Cue(name:"Initial",surfaces:[surface])],groups:[a,b,child])
        let initialRender=try GroupEngine.resolve(surfaces:initial.surfaces,groups:initial.groups)
        let assigned=try GroupEngine.assign(surfaceID:surface.id,to:b.id,in:initial)
        samePoints(try GroupEngine.resolve(surfaces:assigned.surfaces,groups:assigned.groups)[0].output,initialRender[0].output)
        XCTAssertEqual(assigned.cues,initial.cues)
        XCTAssertEqual(assigned.surfaces[0].opacity,surface.opacity)
        XCTAssertEqual(try GroupEngine.assign(surfaceID:surface.id,to:b.id,in:assigned),assigned)
        let moved=try GroupEngine.reparent(groupID:child.id,to:b.id,in:initial)
        XCTAssertEqual(try GroupEngine.reparent(groupID:child.id,to:b.id,in:moved),moved)
        XCTAssertEqual(try GroupEngine.reparent(groupID:a.id,to:nil,in:moved),moved)
        XCTAssertEqual(try GroupEngine.applyWorldTransform(groupID:child.id,transform:.identity,in:moved),moved)
        XCTAssertThrowsError(try GroupEngine.assign(surfaceID:UUID(),to:nil,in:moved))
        XCTAssertThrowsError(try GroupEngine.reparent(groupID:UUID(),to:nil,in:moved))
        XCTAssertThrowsError(try GroupEngine.applyWorldTransform(groupID:UUID(),transform:.identity,in:moved))
        samePoints(try GroupEngine.resolve(surfaces:moved.surfaces,groups:moved.groups)[0].output,initialRender[0].output)
        XCTAssertEqual(moved.surfaces,initial.surfaces)
        let delta=Affine2D.translation(x:0.15,y:-0.05).concatenating(.rotation(degrees:15))
        let transformed=try GroupEngine.applyWorldTransform(groupID:child.id,transform:delta,in:moved)
        samePoints(try GroupEngine.resolve(surfaces:transformed.surfaces,groups:transformed.groups)[0].output,try initialRender[0].output.map { try delta.applying($0) })
        XCTAssertEqual(transformed.surfaces,initial.surfaces)
        let detached=try GroupEngine.assign(surfaceID:surface.id,to:nil,in:assigned)
        samePoints(detached.surfaces[0].output,initialRender[0].output)
        XCTAssertNil(detached.surfaces[0].groupID)
        XCTAssertEqual(try GroupEngine.assign(surfaceID:surface.id,to:nil,in:detached),detached)
    }
    func testDissolvePreservesCurrentAndCueGeometryOpacityAndVisibility() throws {
        let parent=SurfaceGroup(name:"Parent",transform:.rotation(degrees:10),opacity:0.7)
        let removed=SurfaceGroup(name:"Dissolve",parentID:parent.id,transform:.translation(x:0.1,y:0.15),opacity:0.4,enabled:false)
        let child=SurfaceGroup(name:"Child",parentID:removed.id,transform:.scale(x:0.6,y:0.7),opacity:0.8)
        var direct=Surface(name:"Direct",meshColumns:1,meshRows:1,shape:.triangle,groupID:removed.id)
        direct.mesh=try Geometry.regularMesh(quad:direct.output,columns:1,rows:1)
        let nested=Surface(name:"Nested",groupID:child.id)
        let original=Project(surfaces:[direct,nested],cues:[Cue(name:"Saved",surfaces:[nested,direct])],groups:[parent,removed,child])
        let after=try GroupEngine.dissolve(groupID:removed.id,in:original)
        XCTAssertEqual(after.groups.count,2); XCTAssertEqual(after.surfaces.count,2)
        equivalent(try GroupEngine.resolve(surfaces:original.surfaces,groups:original.groups),try GroupEngine.resolve(surfaces:after.surfaces,groups:after.groups))
        equivalent(try GroupEngine.resolve(surfaces:original.cues[0].surfaces,groups:original.groups),try GroupEngine.resolve(surfaces:after.cues[0].surfaces,groups:after.groups))
        XCTAssertEqual(after.surfaces[0].groupID,parent.id)
        XCTAssertEqual(after.groups.first(where:{$0.id==child.id})?.parentID,parent.id)
        var automated=original
        automated.timeline=[AutomationTrack(name:"Opacity",surfaceID:direct.id,parameter:"opacity",keyframes:[AutomationKeyframe(time:0,value:0.1),AutomationKeyframe(time:1,value:0.9)],enabled:false)]
        XCTAssertThrowsError(try GroupEngine.dissolve(groupID:removed.id,in:automated))
        automated.groups[1].opacity=1
        _=try GroupEngine.dissolve(groupID:removed.id,in:automated)
        let noParent=try GroupEngine.dissolve(groupID:parent.id,in:after)
        equivalent(try GroupEngine.resolve(surfaces:after.surfaces,groups:after.groups),try GroupEngine.resolve(surfaces:noParent.surfaces,groups:noParent.groups))
    }
    func testMalformedTreesDepthOverflowAndAtomicCommandRejection() throws {
        let root=SurfaceGroup(name:"Root"), child=SurfaceGroup(name:"Child")
        var duplicate=Project(groups:[root,root]); XCTAssertThrowsError(try ProjectStore.validate(duplicate))
        duplicate.groups=[root,child]; duplicate.groups[1].parentID=UUID(); XCTAssertThrowsError(try ProjectStore.validate(duplicate))
        var cyclic=root; cyclic.parentID=root.id; XCTAssertThrowsError(try ProjectStore.validate(Project(groups:[cyclic])))
        let descendant=SurfaceGroup(name:"Descendant",parentID:root.id)
        let valid=Project(surfaces:[Surface(groupID:descendant.id)],groups:[root,descendant])
        XCTAssertThrowsError(try GroupEngine.reparent(groupID:root.id,to:descendant.id,in:valid))
        XCTAssertEqual(valid.groups[0].parentID,nil)
        XCTAssertThrowsError(try GroupEngine.assign(surfaceID:valid.surfaces[0].id,to:UUID(),in:valid))
        XCTAssertThrowsError(try GroupEngine.applyWorldTransform(groupID:root.id,transform:.scale(x:0,y:1),in:valid))
        XCTAssertThrowsError(try ProjectStore.validate(Project(surfaces:[Surface(groupID:UUID())])))
        var chain:[SurfaceGroup]=[]
        for i in 0..<65 { chain.append(SurfaceGroup(name:"Level \(i)",parentID:chain.last?.id)) }
        XCTAssertThrowsError(try ProjectStore.validate(Project(groups:chain)))
        try ProjectStore.validate(Project(groups:Array(chain.prefix(64))))
        let huge=SurfaceGroup(name:"Too large",transform:.scale(x:10000,y:10000,around:Point2(0,0)))
        let hugeChild=SurfaceGroup(name:"Overflow",parentID:huge.id,transform:.scale(x:2,y:2))
        XCTAssertThrowsError(try ProjectStore.validate(Project(groups:[huge,hugeChild])))
        let outside=SurfaceGroup(name:"Outside",transform:.translation(x:10000,y:0))
        XCTAssertThrowsError(try ProjectStore.validate(Project(surfaces:[Surface(groupID:outside.id)],groups:[outside])))
        XCTAssertThrowsError(try ProjectStore.validate(Project(surfaces:[Surface(group:"Unmigrated label")])))
        var invalidOpacity=root; invalidOpacity.opacity = .nan
        XCTAssertThrowsError(try ProjectStore.validate(Project(groups:[invalidOpacity])))
    }
    func testLegacyMigrationSchemaRoundTripCollectAndHistory() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("ApertureCueGroupTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url=directory.appendingPathComponent("legacy.json")
        for version in 0...2 {
            let surface=Surface(group:"Same label",shape:.ellipse)
            let legacy=Project(version:version,surfaces:[surface],cues:[Cue(name:"Old",surfaces:[surface,Surface(group:"Cue only")])])
            try JSONEncoder().encode(legacy).write(to:url)
            let loaded=try ProjectStore.load(from:url)
            let upgradeURL=directory.appendingPathComponent("saved-legacy-\(version).aperturecue.json")
            try ProjectStore.save(legacy,to:upgradeURL)
            let upgraded=try ProjectStore.load(from:upgradeURL)
            XCTAssertEqual(upgraded.version,Project.currentVersion); XCTAssertEqual(upgraded.groups.count,2)
            XCTAssertEqual(upgraded.surfaces[0].groupID,upgraded.cues[0].surfaces[0].groupID)
            XCTAssertTrue(upgraded.surfaces[0].group.isEmpty)
            XCTAssertEqual(loaded.version,Project.currentVersion); XCTAssertEqual(loaded.groups.count,2)
            XCTAssertEqual(loaded.surfaces[0].groupID,loaded.cues[0].surfaces[0].groupID)
            XCTAssertTrue(loaded.surfaces[0].group.isEmpty)
            XCTAssertEqual(loaded.surfaces[0].shape,version<2 ? .quad : .ellipse)
            try ProjectStore.save(loaded,to:url)
            XCTAssertEqual(try ProjectStore.load(from:url),loaded)
            let portable=try ProjectStore.collect(loaded,to:directory.appendingPathComponent("portable-\(version)"))
            XCTAssertEqual(try ProjectStore.load(from:portable),loaded)
            let after=try GroupEngine.applyWorldTransform(groupID:loaded.groups[0].id,transform:.translation(x:0.1,y:0.1),in:loaded)
            let history=EditHistory(); history.commit(before:loaded,after:after,label:"Group transform")
            XCTAssertEqual(history.undo(current:after),loaded); XCTAssertEqual(history.redo(current:loaded),after)
        }
        try Data("{\"version\":999}".utf8).write(to:url)
        XCTAssertThrowsError(try ProjectStore.load(from:url)) { XCTAssertEqual($0 as? ProjectError,.unsupportedVersion(999)) }
    }
    func testCueCoordinatesSwitchFramesDiscretelyAndStaySavable() throws {
        let a=SurfaceGroup(name:"A",transform:.translation(x:0.2,y:0))
        let b=SurfaceGroup(name:"B",transform:.scale(x:0.7,y:0.6))
        let first=Surface(groupID:a.id)
        var second=first; second.groupID=b.id
        second.output=[Point2(0.2,0.2),Point2(0.7,0.2),Point2(0.7,0.7),Point2(0.2,0.7)]
        second.meshColumns=1; second.meshRows=1; second.mesh=try Geometry.regularMesh(quad:second.output,columns:1,rows:1)
        for (time,expected) in [(0.49,first),(0.5,second)] {
            let sampled=CueEngine.interpolate(first,second,t:time)
            XCTAssertEqual(sampled.groupID,expected.groupID); XCTAssertEqual(sampled.output,expected.output); XCTAssertEqual(sampled.mesh,expected.mesh)
            let project=Project(surfaces:[sampled],cues:[Cue(name:"Target",surfaces:[second])],groups:[a,b])
            try ProjectStore.validate(project)
        }
        var sameFrame=first; sameFrame.output=second.output
        let mid=CueEngine.interpolate(first,sameFrame,t:0.5)
        XCTAssertEqual(mid.groupID,a.id)
        samePoints(mid.output,zip(first.output,sameFrame.output).map { Point2.interpolate($0,$1,t:0.5) })
        let engine=CueEngine(); engine.begin(from:[first],cue:Cue(name:"Move",surfaces:[second]),at:0)
        let sampled=try XCTUnwrap(engine.sample(at:0.75)); engine.cancel()
        try ProjectStore.validate(Project(surfaces:sampled,groups:[a,b]))
        XCTAssertNil(engine.sample(at:1))
    }
}
