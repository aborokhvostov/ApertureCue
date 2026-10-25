import CoreTestSupport
import Foundation

runCase("Geometry.projective mapping", GeometryTests.self) { try $0.testProjectiveCornerAndInteriorMapping() }
runCase("Geometry.input crop", GeometryTests.self) { try $0.testInputCropIndependentOfOutput() }
runCase("Geometry.degenerate rejection", GeometryTests.self) { $0.testDegenerateAndSelfCrossingQuadsRejected() }
runCase("Geometry.orientation", GeometryTests.self) { try $0.testClockwiseAndCounterclockwiseAccepted() }
runCase("Geometry.mesh", GeometryTests.self) { try $0.testProjectiveRegularMesh() }
runCase("Geometry.mask", GeometryTests.self) { $0.testConcaveMaskAndBoundary() }
runCase("Project.relative atomic round trip", ProjectTests.self) { try $0.testAtomicRoundTripRelativePathsAndMissingMedia() }
runCase("Project.unicode external paths", ProjectTests.self) { try $0.testExternalRelativePathAndUnicode() }
runCase("Project.recovery", ProjectTests.self) { try $0.testRecoveryDoesNotOverwriteSavedProject() }
runCase("Project.version migration", ProjectTests.self) { try $0.testVersionMigrationAndFutureVersionRejection() }
runCase("Project.malformed rejection", ProjectTests.self) { try $0.testMalformedDocumentsAndReferencesRejected() }
runCase("Project.undo redo", ProjectTests.self) { $0.testUndoRedoBranchAndBoundedHistory() }
runCase("Transport.play pause seek loop", ShowTests.self) { $0.testPlayPauseSeekAndLoopWithInjectedHostTime() }
runCase("Transport.nonloop end", ShowTests.self) { $0.testNonLoopingEndAndRestart() }
runCase("Transport.unbounded pause", ShowTests.self) { $0.testPauseFreezesUnboundedGeneratorTime() }
runCase("Cue.transition follow", ShowTests.self) { try $0.testCueInterpolationAndFollow() }
runCase("Cue.removal instant", ShowTests.self) { try $0.testRemovedLayerFadesAndZeroDurationCue() }
runCase("Automation.interpolation", ShowTests.self) { try $0.testAutomationInterpolatesAndRejectsInvalidTimes() }
runCase("OSC.golden bytes", ProtocolTests.self) { try $0.testOSCOfficialGoldenMessageAndTypes() }
runCase("OSC.bundles rejection", ProtocolTests.self) { try $0.testOSCImmediateBundlesAndMalformedInput() }
runCase("OSC.truncation recursion", ProtocolTests.self) { try $0.testOSCTruncationsAndRecursionAreBounded() }
runCase("ArtDMX.golden boundaries", ProtocolTests.self) { try $0.testArtDMXGoldenPacketAndAddressBounds() }
runCase("sACN.offsets lengths", ProtocolTests.self) { try $0.testSACNFieldOffsetsLengthsAndRoundTrip() }
runCase("Fixture.sampling addressing", ProtocolTests.self) { try $0.testFixtureSamplingOrderWhiteExtractionAndAddressing() }
runCase("Timeline.fixture serialization", TimelineTests.self) { try $0.testFixturesAndTimelinePersistWithLegacyDefaults() }
runCase("Timeline.seek loop", TimelineTests.self) { try $0.testTimelineSeekLoopAndDisabledTrack() }
runCase("Timeline.color validation", TimelineTests.self) { try $0.testTimelineColorGammaAndValidation() }
runCase("Fixture.project validation", TimelineTests.self) { try $0.testProjectRejectsFixtureOverlapBeforeSampling() }
runCase("Timeline.dormant cue target", TimelineTests.self) { try $0.testDormantTimelineTargetRetainedByCueCanBeSaved() }
runCase("OBJ.indices texture seams", Scene3DTests.self) { try $0.testOBJNegativeIndicesTextureSeamsAndNormals() }
runCase("OBJ.concave triangulation", Scene3DTests.self) { try $0.testOBJConcaveTriangulationAreaAndReversedWinding() }
runCase("OBJ.invalid rejection", Scene3DTests.self) { try $0.testOBJInvalidIndicesDegeneracyAndUnsupportedGeometry() }
runCase("Camera.projection clipping", Scene3DTests.self) { try $0.testCameraProjectionClippingAndOrientation() }
runCase("OBJ.projection perspective UV", Scene3DTests.self) { try $0.testProjectionBakeUsesPerspectivePhysicalMidpointsAndUVs() }
runCase("OBJ.projection depth clipping", Scene3DTests.self) { try $0.testProjectionBakeConcaveFaceDepthSortAndClipping() }
runCase("Collect.independent media copy", CollectTests.self) { try $0.testCollectedProjectSurvivesOriginalDeletionAndDuplicateNames() }
runCase("Collect.rollback no overwrite", CollectTests.self) { try $0.testMissingMediaRollsBackAndExistingDestinationIsUntouched() }
runCase("Collect.camera symlink", CollectTests.self) { try $0.testCameraIdentitiesAndSymlinkMediaRemainPortable() }
exit(finishTests())
