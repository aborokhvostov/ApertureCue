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
runCase("Project.geometry lock persistence and migration", ProjectTests.self) { try $0.testGeometryLocksPersistAndVersionSevenIgnoresLockExtensions() }
runCase("Project.fullscreen display binding and legacy routing", ProjectTests.self) { try $0.testDisplayBindingPersistsAndLegacyOutputsKeepTheirRoutes() }
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
runCase("Shape.distances bounded outline", ShapeTests.self) { try $0.testPrimitiveDistancesBoundariesAndBoundedOutlines() }
runCase("Shape.projective hit input independence", ShapeTests.self) { try $0.testProjectivePrimitiveHitTestingAndIndependentInput() }
runCase("Shape.mesh fold hit", ShapeTests.self) { try $0.testMeshInterpolationAndFoldedPrimitiveHitTesting() }
runCase("Shape.legacy future migration", ShapeTests.self) { try $0.testLegacyQuadMigrationAndFutureShapeRejection() }
runCase("Shape.cue collect history roundtrip", ShapeTests.self) { try $0.testShapesRoundTripCuesCollectAndHistory() }
runCase("Shape.custom triangle persistence and cues", ShapeTests.self) { try $0.testCustomTrianglePersistenceMigrationAndSelectiveCue() }
runCase("Shape.custom triangle winding and validation", ShapeTests.self) { try $0.testCustomTriangleWindingProjectionAndInvalidVertices() }
runCase("Group.affine inverse aspect", GroupTests.self) { try $0.testAffineCompositionInverseReflectionAndAspectRotation() }
runCase("Group.hierarchy mesh appearance", GroupTests.self) { try $0.testHierarchyResolvesMeshAppearanceAndIndependentSource() }
runCase("Group.assign reparent world delta", GroupTests.self) { try $0.testAssignReparentAndWorldDeltaPreserveLocalGeometry() }
runCase("Group.dissolve appearance", GroupTests.self) { try $0.testDissolvePreservesCurrentAndCueGeometryOpacityAndVisibility() }
runCase("Group.malformed atomic bounds", GroupTests.self) { try $0.testMalformedTreesDepthOverflowAndAtomicCommandRejection() }
runCase("Group.migration persistence history", GroupTests.self) { try $0.testLegacyMigrationSchemaRoundTripCollectAndHistory() }
runCase("Group.cue local frames", GroupTests.self) { try $0.testCueCoordinatesSwitchFramesDiscretelyAndStaySavable() }
runCase("Stroke.metric caps UV joins closed", StrokeTests.self) { try $0.testMetricWidthCapsJoinsClosedAndTextureCoordinates() }
runCase("Stroke.cubic bounded flatten", StrokeTests.self) { try $0.testCubicFlatteningAccuracyReversalsAndCoincidentEndpointLoops() }
runCase("Stroke.malformed precision", StrokeTests.self) { try $0.testMalformedBoundsAndExplicitPrecisionBudgetRejection() }
runCase("Stroke.crossing inverse mesh", StrokeTests.self) { try $0.testCrossingTieOwnershipAndProjectedMeshInverse() }
runCase("Stroke.schema four migration", StrokeTests.self) { try $0.testSchemaFourMigrationDefaultsAndMalformedPersistence() }
runCase("Stroke.cue frames collapse", StrokeTests.self) { try $0.testCuePathInterpolationFramesAndCollapseRemainValid() }
runCase("Stroke.group history collect", StrokeTests.self) { try $0.testGroupHistorySaveAndPortableCollectionKeepLocalStroke() }
runCase("TimelineRuntime.easing immutable curve", TimelineRuntimeTests.self) { try $0.testHoldLinearBezierExactKeysAndImmutableCurve() }
runCase("TimelineRuntime.compiled program", TimelineRuntimeTests.self) { try $0.testCompiledProgramBinarySearchDisabledAndDormantTargets() }
runCase("TimelineRuntime.transport finite end", TimelineRuntimeTests.self) { try $0.testIndependentTransportPlayPauseSeekEndAndInvalidHostTime() }
runCase("TimelineRuntime.marker pause seek", TimelineRuntimeTests.self) { try $0.testMarkerCrossingsPauseResumeSeekAndExactBoundaries() }
runCase("TimelineRuntime.loop event budget", TimelineRuntimeTests.self) { try $0.testLoopRangeExactWrapMarkerOrderingAndLongElapsedBudget() }
runCase("TimelineRuntime.pause budget configure", TimelineRuntimeTests.self) { try $0.testEventBudgetStillHonorsPauseAndAtomicConfiguration() }
runCase("TimelineRuntime.settings validation", TimelineRuntimeTests.self) { try $0.testSettingsAndMarkerReferenceValidation() }
runCase("TimelineRuntime.migration persistence", TimelineRuntimeTests.self) { try $0.testLegacyLinearNormalizationSchemaFiveHistoryAndPortableRoundTrip() }
runCase("SelectiveCue.atomic parameter masks", SelectiveCueTests.self) { try $0.testEveryMaskCopiesOnlyItsAtomicFieldsAndPreservesCurrentLayers() }
runCase("SelectiveCue.hidden missing layers", SelectiveCueTests.self) { try $0.testHiddenVisibilityAndMissingTargetsNeverFadeOrRestoreUnselectedLayers() }
runCase("SelectiveCue.numeric discrete follow", SelectiveCueTests.self) { try $0.testSelectedNumericAndDiscreteInterpolationEndpointsAndInstantFollow() }
runCase("SelectiveCue.geometry path masks", SelectiveCueTests.self) { try $0.testGeometryFramesQuadCollapseStrokeAndMaskCompatibility() }
runCase("SelectiveCue.interruption clock", SelectiveCueTests.self) { try $0.testInterruptionUsesActualCurrentStateAndPreservesShowAndMediaClock() }
runCase("SelectiveCue.capture rejection", SelectiveCueTests.self) { try $0.testCaptureAndMaskValidationRejectMalformedSelections() }
runCase("SelectiveCue.schema migration strictness", SelectiveCueTests.self) { try $0.testLegacySchemasIgnoreExtensionsAndSchemaSixIsStrict() }
runCase("SelectiveCue.persistence resource references", SelectiveCueTests.self) { try $0.testPersistenceHistoryCollectionAndDormantResourceReferenceValidation() }
runCase("SelectiveCue.group dissolve masks", SelectiveCueTests.self) { try $0.testGroupDissolveIgnoresUnselectedFramesAndGuardsPartialAppearance() }
runCase("Recording.inclusive span metadata", AutomationRecordingTests.self) { try $0.testInclusiveSpanReplacementPreservesOutsideKeysAndTrackIdentity() }
runCase("Recording.duplicates atomic no-op", AutomationRecordingTests.self) { try $0.testSameTimestampReplacementNoOpAndRejectedSamplesAreAtomic() }
runCase("Recording.parameter ranges validation", AutomationRecordingTests.self) { try $0.testParameterRangesInitialValidationAndDisabledTracks() }
runCase("Recording.session merged bounds", AutomationRecordingTests.self) { try $0.testSessionAndMergedTrackBoundsAllowReplacementAtCapacity() }
runCase("Recording.finish persistence history", AutomationRecordingTests.self) { try $0.testFinishOrdinaryKeysSaveAndSingleHistoryCommit() }
runCase("Recording.track edit clock continuity", AutomationRecordingTests.self) { try $0.testTracksOnlyConfigurePreservesNaturalClockWithoutDiscontinuity() }
runCase("Recording.pause loop exactly once", AutomationRecordingTests.self) { try $0.testTrackEditsRetainPauseLoopCrossingsAndExactlyOnceEvents() }
runCase("Recording.aggregate atomic configure", AutomationRecordingTests.self) { try $0.testProjectAggregateBudgetAndRejectedConfigureRemainAtomic() }
runCase("Montage.half-open sorted gaps", MontageTests.self) { try $0.testHalfOpenIntervalsSortedClipsImageAndExplicitGaps() }
runCase("Montage.rate loop stateless", MontageTests.self) { try $0.testRateSegmentLoopMontageLoopAndRandomAccessAreStateless() }
runCase("Montage.trim overlap validation", MontageTests.self) { try $0.testVideoTrimRateBoundsCanonicalImagesAndOverlapRejectAtomically() }
runCase("Montage.identity resource bounds", MontageTests.self) { try $0.testGlobalIdentityAndResourceBudgetsRejectDuplicateOrNestedSources() }
runCase("Montage.extreme time rejection", MontageTests.self) { try $0.testInvalidSampleTimesAndExtremeRepeatRatiosCannotTrap() }
runCase("Montage.schema seven migration", MontageTests.self) { try $0.testLegacyVersionsIgnoreMalformedMontageExtensionsAndSchemaSevenIsStrict() }
runCase("Montage.current cue references", MontageTests.self) { try $0.testMontageReferencesAcrossCurrentFullAndSelectiveCueSnapshots() }
runCase("Montage.persistence collect history", MontageTests.self) { try $0.testPersistenceRecoveryCollectAndHistoryRetainOnlyRealAssetFiles() }
runCase("Montage.shared asset isolation", MontageTests.self) { try $0.testSharedAssetMultipleMontagesHaveIndependentSourcePositions() }
runCase("PolygonMask.distance inversion feather", PolygonMaskTests.self) { try $0.testConcaveInvertedFeatherAndDegenerateSegments() }
runCase("PolygonMask.atomic cues coordinate frames", PolygonMaskTests.self) { try $0.testMaskCueAtomicityAndCoordinateSwitching() }
runCase("PolygonMask.schema eleven persistence", PolygonMaskTests.self) { try $0.testSchemaElevenMigrationStrictnessSaveCollectAndHistory() }
runCase("PolygonMask.closed edge split coverage", PolygonMaskTests.self) { try $0.testEdgeInsertionPreservesConcaveCoverageAndFeather() }
runCase("PolygonMask.vertex budgets topology", PolygonMaskTests.self) { try $0.testVertexBudgetsInvalidCoordinatesAndSceneTopology() }
runCase("BezierWarpTests.testFlatPatchRationalCageAndDenseCurvedPixelBound", BezierWarpTests.self) { try $0.testFlatPatchRationalCageAndDenseCurvedPixelBound() }
runCase("BezierWarpTests.testSharedPatchEdgesIndependentTangentsAndStableInverse", BezierWarpTests.self) { try $0.testSharedPatchEdgesIndependentTangentsAndStableInverse() }
runCase("BezierWarpTests.testPrecisionBudgetsMalformedDataAndRoundTrip", BezierWarpTests.self) { try $0.testPrecisionBudgetsMalformedDataAndRoundTrip() }
runCase("BezierWarpTests.testExplicitMeshLinkPreservesSourceUntilEnabled", BezierWarpTests.self) { try $0.testExplicitMeshLinkPreservesSourceUntilEnabled() }
runCase("BezierMaskTests.testClosedCurveDenseOracleWindingAndPixelMetric", BezierMaskTests.self) { try $0.testClosedCurveDenseOracleWindingAndPixelMetric() }
runCase("BezierMaskTests.testCubicSplitClosingEdgeHandlesAndNumericAnchor", BezierMaskTests.self) { try $0.testCubicSplitClosingEdgeHandlesAndNumericAnchor() }
runCase("BezierMaskTests.testLoopsCollinearReversalAndPrecisionBudgetsRejectExplicitly", BezierMaskTests.self) { try $0.testLoopsCollinearReversalAndPrecisionBudgetsRejectExplicitly() }
runCase("SurfaceWarpGeometryTests.testPerspectiveWeightedRegularMeshPreservesLocalAndSource", SurfaceWarpGeometryTests.self) { try $0.testPerspectiveWeightedRegularMeshPreservesLocalAndSource() }
runCase("SurfaceWarpGeometryTests.testInputMeshDeltasKeepExactCropAndOnlySelectedSourceChanges", SurfaceWarpGeometryTests.self) { try $0.testInputMeshDeltasKeepExactCropAndOnlySelectedSourceChanges() }
runCase("SurfaceWarpGeometryTests.testBezierPreparedGridPickingContourAndIndependentInputWarp", SurfaceWarpGeometryTests.self) { try $0.testBezierPreparedGridPickingContourAndIndependentInputWarp() }
runCase("SurfaceWarpGeometryTests.testFoldedBezierChecksEveryPreimageAndLegacyBoundaryRemainsStrict", SurfaceWarpGeometryTests.self) { try $0.testFoldedBezierChecksEveryPreimageAndLegacyBoundaryRemainsStrict() }
runCase("SurfaceEditingTests.testWarpCreationNumericActiveControlLinkAndReset", SurfaceEditingTests.self) { try $0.testWarpCreationNumericActiveControlLinkAndReset() }
runCase("SurfaceEditingTests.testWorldTransformPreservesSourceAndLockedCommandsAreAtomic", SurfaceEditingTests.self) { try $0.testWorldTransformPreservesSourceAndLockedCommandsAreAtomic() }
runCase("SurfaceEditingTests.testFreehandFittingToleranceBudgetsAndCreation", SurfaceEditingTests.self) { try $0.testFreehandFittingToleranceBudgetsAndCreation() }
runCase("MaterialTests.testMaterialArithmeticVectorParametersAndUniformPacking", MaterialTests.self) { try $0.testMaterialArithmeticVectorParametersAndUniformPacking() }
runCase("MaterialTests.testMaterialSwizzlesFunctionsBoundsAndMalformedSyntax", MaterialTests.self) { try $0.testMaterialSwizzlesFunctionsBoundsAndMalformedSyntax() }
runCase("MaterialTests.testMaterialInputValidationAndCodableRoundTrip", MaterialTests.self) { try $0.testMaterialInputValidationAndCodableRoundTrip() }
runCase("MaterialTests.testISFTypedInputsOrientationNormalizedSamplingAndPersistence", MaterialTests.self) { try $0.testISFTypedInputsOrientationNormalizedSamplingAndPersistence() }
runCase("MaterialTests.testISFRejectsUnsafeAndUnsupportedFeaturesAtomically", MaterialTests.self) { try $0.testISFRejectsUnsafeAndUnsupportedFeaturesAtomically() }
runCase("MaterialTests.testChromaLumaSpillAndColorEffectsNumericalOracle", MaterialTests.self) { try $0.testChromaLumaSpillAndColorEffectsNumericalOracle() }
runCase("CompositionUtilityTests.testComplementaryEdgeBlendPowerRampsAndColorCalibration", CompositionUtilityTests.self) { try $0.testComplementaryEdgeBlendPowerRampsAndColorCalibration() }
runCase("CompositionUtilityTests.testVideoWallUniqueTilesCoverageBezelsOverlapAndBounds", CompositionUtilityTests.self) { try $0.testVideoWallUniqueTilesCoverageBezelsOverlapAndBounds() }
runCase("CompositionUtilityTests.testSVGPathCommandsQuadraticConversionTransformsAndCompoundFill", CompositionUtilityTests.self) { try $0.testSVGPathCommandsQuadraticConversionTransformsAndCompoundFill() }
runCase("CompositionUtilityTests.testSVGBasicShapesCircleControlPointsAndViewport", CompositionUtilityTests.self) { try $0.testSVGBasicShapesCircleControlPointsAndViewport() }
runCase("CompositionUtilityTests.testSVGMalformedUnsafeUnsupportedAndBudgetsRejectAtomically", CompositionUtilityTests.self) { try $0.testSVGMalformedUnsafeUnsupportedAndBudgetsRejectAtomically() }
runCase("Composition.testSchemaTwelveRoundTripCollectRecoveryAndLegacyExtensions", CompositionTests.self) { try $0.testSchemaTwelveRoundTripCollectRecoveryAndLegacyExtensions() }
runCase("Composition.testProjectiveHierarchyAndIsolatedOpacityStackPolicy", CompositionTests.self) { try $0.testProjectiveHierarchyAndIsolatedOpacityStackPolicy() }
runCase("Composition.testNewSelectiveFieldsAndCurveGeometryRemainAtomic", CompositionTests.self) { try $0.testNewSelectiveFieldsAndCurveGeometryRemainAtomic() }
runCase("Composition.testCompositionBudgetsReferencesAndInvalidTransforms", CompositionTests.self) { try $0.testCompositionBudgetsReferencesAndInvalidTransforms() }
runCase("CompositionTransition.testFullFadeRejectsTransientIsolationOrderButInstantCutPasses", CompositionTransitionTests.self) { try $0.testFullFadeRejectsTransientIsolationOrderButInstantCutPasses() }
runCase("CompositionTransition.testSelectiveVisibilityUsesActualEngineSemanticsAndCurrentScene", CompositionTransitionTests.self) { try $0.testSelectiveVisibilityUsesActualEngineSemanticsAndCurrentScene() }
runCase("CompositionTransition.testRetainsOutgoingLayersAndDoesNotChangeRunningEngineOrProject", CompositionTransitionTests.self) { try $0.testRetainsOutgoingLayersAndDoesNotChangeRunningEngineOrProject() }
runCase("CompositionTransition.testRepresentativeGeometryAndMalformedSnapshotRejectAtomically", CompositionTransitionTests.self) { try $0.testRepresentativeGeometryAndMalformedSnapshotRejectAtomically() }
runCase("MediaPlaybackTests.testTrimForwardReverseLoopAndHalfOpenEndpoints", MediaPlaybackTests.self) { try $0.testTrimForwardReverseLoopAndHalfOpenEndpoints() }
runCase("MediaPlaybackTests.testPingPongHoldZeroRateAndSourceRangeBounds", MediaPlaybackTests.self) { try $0.testPingPongHoldZeroRateAndSourceRangeBounds() }
runCase("MediaPlaybackTests.testRandomCounterTraceIsSeekOrderIndependentAndSeeded", MediaPlaybackTests.self) { try $0.testRandomCounterTraceIsSeekOrderIndependentAndSeeded() }
runCase("MediaPlaybackTests.testSourceClockIndependentPauseSeekAndMasterRejoin", MediaPlaybackTests.self) { try $0.testSourceClockIndependentPauseSeekAndMasterRejoin() }
runCase("MediaPlaybackTests.testSequenceNaturalOrderFrozenGapsFrameIndexAndUnsafeNames", MediaPlaybackTests.self) { try $0.testSequenceNaturalOrderFrozenGapsFrameIndexAndUnsafeNames() }
runCase("MediaPlaybackTests.testSchemaThirteenSettingsRoundTripAndLegacyExtensionsIgnoredBeforeDecode", MediaPlaybackTests.self) { try $0.testSchemaThirteenSettingsRoundTripAndLegacyExtensionsIgnoredBeforeDecode() }
runCase("AudioRoutingTests.testPCMMatrixIdentitySwapDownmixSignedGainAndClipping", AudioRoutingTests.self) { try $0.testPCMMatrixIdentitySwapDownmixSignedGainAndClipping() }
runCase("AudioRoutingTests.testMuteDisabledBoundsNonfiniteAndAtomicFailure", AudioRoutingTests.self) { try $0.testMuteDisabledBoundsNonfiniteAndAtomicFailure() }
runCase("DurabilityTests.testPortableContentDigestVectors", DurabilityTests.self) { try $0.testPortableContentDigestVectors() }
runCase("DurabilityTests.testBoundRecoveryRoundTripsPortablePathsAndNeverChangesSavedBytes", DurabilityTests.self) { try $0.testBoundRecoveryRoundTripsPortablePathsAndNeverChangesSavedBytes() }
runCase("DurabilityTests.testSameSizeAndSameModificationTimeReplacementMakesRecoveryStale", DurabilityTests.self) { try $0.testSameSizeAndSameModificationTimeReplacementMakesRecoveryStale() }
runCase("DurabilityTests.testCopiedRecoveryCannotAttachToSameBytesAtAnotherDocumentPath", DurabilityTests.self) { try $0.testCopiedRecoveryCannotAttachToSameBytesAtAnotherDocumentPath() }
runCase("DurabilityTests.testLegacyCorruptAndSymlinkSidecarsArePreserved", DurabilityTests.self) { try $0.testLegacyCorruptAndSymlinkSidecarsArePreserved() }
runCase("DurabilityTests.testPayloadCorruptionAndFutureEnvelopeAreRejectedWithoutDeletion", DurabilityTests.self) { try $0.testPayloadCorruptionAndFutureEnvelopeAreRejectedWithoutDeletion() }
runCase("DurabilityTests.testOwnedRecoveryUpdatesAndCleanupUsesPreSaveBaseline", DurabilityTests.self) { try $0.testOwnedRecoveryUpdatesAndCleanupUsesPreSaveBaseline() }
runCase("DurabilityTests.testBaselineCapturedBeforeExternalSaveCannotRebindLaterAutosave", DurabilityTests.self) { try $0.testBaselineCapturedBeforeExternalSaveCannotRebindLaterAutosave() }
runCase("DurabilityTests.testOldEditorCannotOverwriteAnotherRevisionAvailableRecovery", DurabilityTests.self) { try $0.testOldEditorCannotOverwriteAnotherRevisionAvailableRecovery() }
runCase("DurabilityTests.testSequenceCollectionFreezesManifestAndSurvivesSourceRemoval", DurabilityTests.self) { try $0.testSequenceCollectionFreezesManifestAndSurvivesSourceRemoval() }
runCase("DurabilityTests.testSequenceCollectionMissingSymlinkAndOversizedFramesRollBack", DurabilityTests.self) { try $0.testSequenceCollectionMissingSymlinkAndOversizedFramesRollBack() }
runCase("DurabilityTests.testSchemaThirteenMediaValidationAndLegacySaveCannotActivateExtensions", DurabilityTests.self) { try $0.testSchemaThirteenMediaValidationAndLegacySaveCannotActivateExtensions() }

runCase("DurabilityTests.testEditorOpenAndSaveReturnBaselineForExactlyTheirProjectBytes", DurabilityTests.self) { try $0.testEditorOpenAndSaveReturnBaselineForExactlyTheirProjectBytes() }
runCase("ConductorTests.testRowExclusivityPriorityBankSwitchAndImmutableCapture", ConductorTests.self) { try $0.testRowExclusivityPriorityBankSwitchAndImmutableCapture() }
runCase("ConductorTests.testSignalClockGraphCycleAndParameterMapping", ConductorTests.self) { try $0.testSignalClockGraphCycleAndParameterMapping() }
runCase("ConductorTests.testJumpLimitsStopSeekAndCueCurve", ConductorTests.self) { try $0.testJumpLimitsStopSeekAndCueCurve() }
runCase("ConductorTests.testSchema14AndIgnoredUndefinedLegacyExtensions", ConductorTests.self) { try $0.testSchema14AndIgnoredUndefinedLegacyExtensions() }
runCase("ShowControlEventTests.testEventEncodingOrderAndBounds", ShowControlEventTests.self) { try $0.testEventEncodingOrderAndBounds() }
runCase("ShowControlEventTests.testExternalClockPacketAndPhaseCorrections", ShowControlEventTests.self) { try $0.testExternalClockPacketAndPhaseCorrections() }
runCase("ShowControlEventTests.testExternalClockLossOrderingAndRestart", ShowControlEventTests.self) { try $0.testExternalClockLossOrderingAndRestart() }
runCase("ShowScheduleTests.testICSImportWeeklyRulesExclusionsAndMetadata", ShowScheduleTests.self) { try $0.testICSImportWeeklyRulesExclusionsAndMetadata() }
runCase("ShowScheduleTests.testLocalDSTGapAndRepeatedHourPolicy", ShowScheduleTests.self) { try $0.testLocalDSTGapAndRepeatedHourPolicy() }
runCase("ShowScheduleTests.testDelayedPollingConflictsAndClockRollback", ShowScheduleTests.self) { try $0.testDelayedPollingConflictsAndClockRollback() }
runCase("ShowScheduleTests.testUnboundedWeeklyIntervalAndInclusiveUntil", ShowScheduleTests.self) { try $0.testUnboundedWeeklyIntervalAndInclusiveUntil() }
runCase("ShowScheduleTests.testInvalidICSAndModelAreRejectedAtomically", ShowScheduleTests.self) { try $0.testInvalidICSAndModelAreRejectedAtomically() }
runCase("ShowScheduleTests.testSavedScheduleAndLegacyVersionIgnoreNewField", ShowScheduleTests.self) { try $0.testSavedScheduleAndLegacyVersionIgnoreNewField() }
runCase("MontageTests.testSignedRateCrossfadeAndIndependentAudioLane", MontageTests.self) { try $0.testSignedRateCrossfadeAndIndependentAudioLane() }
runCase("MontageTests.testExplicitCrossfadeRejectsTripleOrMismatchedOverlap", MontageTests.self) { try $0.testExplicitCrossfadeRejectsTripleOrMismatchedOverlap() }
runCase("MontageTests.testSchemaFourteenMontageOptionsRoundTripAndLegacyIsolation", MontageTests.self) { try $0.testSchemaFourteenMontageOptionsRoundTripAndLegacyIsolation() }
runCase("ConductorTests.testEventsAndMarkersUseOneBudgetAndDoNotReplayAfterSeek", ConductorTests.self) { try $0.testEventsAndMarkersUseOneBudgetAndDoNotReplayAfterSeek() }
exit(finishTests())
