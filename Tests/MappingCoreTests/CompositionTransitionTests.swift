import XCTest
import Foundation
@testable import MappingCore

final class CompositionTransitionTests:XCTestCase {
    private func isolationFixture() -> (Project,[Surface]) {
        var group=SurfaceGroup(name:"Isolated")
        group.isolated=true
        let a=Surface(name:"First child",groupID:group.id)
        let b=Surface(name:"Outside",enabled:false)
        let c=Surface(name:"Last child",groupID:group.id)
        var target=[a,b,c]
        target[0].enabled=false;target[1].enabled=true
        return (Project(surfaces:[a,b,c],groups:[group]),target)
    }

    func testFullFadeRejectsTransientIsolationOrderButInstantCutPasses() throws {
        let (project,target)=isolationFixture()
        let before=project
        let cue=Cue(name:"Valid endpoints",surfaces:target,duration:2)
        try ProjectStore.validate(project)
        var destination=project;destination.surfaces=target
        try ProjectStore.validate(destination)
        XCTAssertThrowsError(try CompositionTransition.validate(cue:cue,in:project)) { error in
            XCTAssertTrue(error.localizedDescription.contains("isolated group descendants"))
        }
        var cut=cue;cut.duration=0
        try CompositionTransition.validate(cue:cut,in:project)
        XCTAssertEqual(project,before)
        XCTAssertEqual(cue.duration,2)
    }

    func testSelectiveVisibilityUsesActualEngineSemanticsAndCurrentScene() throws {
        let (project,target)=isolationFixture()
        let cue=try CueSelection.capture(name:"Visibility swap",surfaces:target,bindings:[
            CueBinding(surfaceID:target[0].id,parameters:[.visibility]),
            CueBinding(surfaceID:target[1].id,parameters:[.visibility])],duration:2)
        // Unlike a full fade, selective visibility switches both flags together.
        try CompositionTransition.validate(cue:cue,in:project)
        var currentlyDisplayed=project
        currentlyDisplayed.surfaces[1].enabled=true
        // The actual current scene is checked, rather than an earlier cue snapshot.
        XCTAssertThrowsError(try CompositionTransition.validate(cue:cue,in:currentlyDisplayed))
        XCTAssertEqual(project.surfaces[1].enabled,false)
    }

    func testRetainsOutgoingLayersAndDoesNotChangeRunningEngineOrProject() throws {
        let outgoing=Surface(name:"Outgoing"),incoming=Surface(name:"Incoming")
        let cue=Cue(name:"Replace",surfaces:[incoming],duration:Double.leastNonzeroMagnitude)
        let project=Project(surfaces:[outgoing],geometryLockedSurfaceIDs:[outgoing.id])
        let before=project
        let engine=CueEngine();engine.begin(from:project.surfaces,cue:cue,at:10)
        try CompositionTransition.validate(cue:cue,in:project)
        XCTAssertTrue(engine.isTransitioning)
        XCTAssertEqual(engine.activeCueID,cue.id)
        XCTAssertEqual(project,before)
        XCTAssertEqual(cue.surfaces,[incoming])
        // The original engine is still usable at the same synthetic start time.
        XCTAssertEqual(try XCTUnwrap(engine.sample(at:10)).map(\.id),[outgoing.id,incoming.id])
    }

    func testRepresentativeGeometryAndMalformedSnapshotRejectAtomically() throws {
        let original=Surface(output:Point2.unitQuad)
        var reversed=original
        reversed.output=[Point2(1,1),Point2(0,1),Point2(0,0),Point2(1,0)]
        let cue=Cue(name:"Collapsed midpoint",surfaces:[reversed])
        let project=Project(surfaces:[original])
        var destination=project;destination.surfaces=[reversed]
        try ProjectStore.validate(destination)
        XCTAssertThrowsError(try CompositionTransition.validate(cue:cue,in:project))
        var malformed=cue;malformed.surfaces[0].output[0].x = .nan
        XCTAssertThrowsError(try CompositionTransition.validate(cue:malformed,in:project))
        var safe=original;safe.opacity=0.4;safe.brightness=1.3
        try CompositionTransition.validate(cue:Cue(name:"Ordinary fade",surfaces:[safe]),in:project)
        XCTAssertEqual(project.surfaces,[original])
    }
}
