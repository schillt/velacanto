#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$project_root"
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR
worktree_key=$(printf '%s' "$project_root" | cksum | awk '{print $1}')
derived_data_path=${VELACANTO_DERIVED_DATA_PATH:-"${TMPDIR:-/private/tmp}/VelacantoDerivedData-${worktree_key}"}
ios_destination=${VELACANTO_IOS_SIMULATOR_DESTINATION:-}
build_mode=${1:-all}
# Reject hosted-only mode before preflight or any native work when the job
# environment is absent. Destination identity is checked again before iOS.
if [ "$build_mode" = pr-hosted ] && { [ "${GITHUB_ACTIONS:-}" != true ] || [ "${CI:-}" != true ]; }; then
  printf '%s\n' 'pr-hosted is reserved for the GitHub Actions quality job.' >&2
  exit 2
fi
# Optional local resource bound; omit the flag to preserve Xcode's default.
xcode_jobs=${VELACANTO_XCODE_JOBS:-}
if [ -n "$xcode_jobs" ]; then
  case "$xcode_jobs" in
    [1-9]|[1-5][0-9]|6[0-4]) ;;
    *) printf '%s\n' 'VELACANTO_XCODE_JOBS must be a decimal integer from 1 to 64.' >&2; exit 2 ;;
  esac
fi
run_xcode_scheme() {
  selected_scheme=$1
  selected_derived_data=$2
  shift 2
  if [ -n "$xcode_jobs" ]; then set -- -jobs "$xcode_jobs" "$@"; fi
  set -- -project NativeFoundation/VelacantoFoundation.xcodeproj -scheme "$selected_scheme" \
    -derivedDataPath "$selected_derived_data" -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO "$@"
  if [ -n "${VELACANTO_PACKAGES_PATH:-}" ]; then
    set -- -clonedSourcePackagesDirPath "$VELACANTO_PACKAGES_PATH" "$@"
  fi
  "$DEVELOPER_DIR/usr/bin/xcodebuild" "$@"
}
run_xcode() { run_xcode_scheme VelacantoFoundation "$derived_data_path" "$@"; }
run_isolation_xcode() {
  isolation_packages=${VELACANTO_PACKAGES_PATH:-"$derived_data_path/SourcePackages"}
  if [ ! -d "$isolation_packages" ]; then
    printf '%s\n' 'Isolation tests require the existing resolved package cache; set VELACANTO_PACKAGES_PATH.' >&2
    return 2
  fi
  VELACANTO_PACKAGES_PATH=$isolation_packages \
    run_xcode_scheme VelacantoFoundationIsolation "$result_root/DerivedData" "$@"
}
lint() {
  python3 scripts/lint.py
  python3 scripts/test-isolation-inventory.py
}

# Fail if Xcode reports success without executing the critical isolation cases.
verify_isolation_result() {
  result_path=$1
  platform=$2
  "$DEVELOPER_DIR/usr/bin/xcresulttool" get test-results tests \
    --path "$result_path" --format json > "$result_path.tests.json"
  python3 - "$result_path.tests.json" "$platform" <<'PYTHON'
import json
import sys

path, platform = sys.argv[1:]
with open(path, encoding="utf-8") as result_file:
    results = json.load(result_file)
# Reviewed lifecycle inventory; keep platform membership explicit.
required = {
    "testAbandonedPreparedAcceptanceDoesNotPublishAccount",
    "testAccountAlertDismissalDoesNotClearRepublishedMessages",
    "testAccountInspectionRetryRechecksBeforePreparingCaches",
    "testAccountTransactionLockRejectsContentionAndUnsafeInodes",
    "testActionOwnerRejectsPinSyncReplacement",
    "testBackgroundProofRejectsConcurrentManifestPublication",
    "testBackgroundRoutingFenceRetainsAndReplaysCompletions",
    "testBackgroundRoutingReadinessChangesWhenLateEventArrives",
    "testCancelledActionAndPinSyncRequireJoiningBeforeScopedCleanup",
    "testCancelledPreparationWaitsForWrittenMarkerBeforeRetry",
    "testCancelledPreparedAcceptanceDoesNotPublishAccount",
    "testCancelledSignOutAllocatedFinalityRecoveryPreservesData",
    "testCancelledSignOutCleanupFencesSameScopeUntilLeaseRelease",
    "testCancellingStartupWaiterDoesNotCancelSharedIntentInspection",
    "testChangedMarkerDuringAllocatedFinalityRecoveryPreservesData",
    "testCleanupAlertDismissalPreservesIdenticalNewPublication",
    "testColdAllocatedRecoveryReportsActiveAndDelayedStatus",
    "testColdAllocatedRecoveryRequiresSavedCredential",
    "testColdAllocatedRelaunchAfterManifestAuthorization",
    "testColdAllocatedRelaunchAfterManifestPublication",
    "testColdAllocatedRelaunchAfterTombstone",
    "testColdAllocatedRetirementWaitsForDeliveryAndCurrentOwner",
    "testColdAllocatedSignOutCancellationPreservesPendingAccount",
    "testColdAllocatedSignOutCompletesQuiescentPublishedEventWithoutDrain",
    "testColdAllocatedSignOutCompletesQuiescentWaitingEventWithoutDrain",
    "testColdAllocatedSignOutHandlesCallbackAfterPublication",
    "testColdAllocatedSignOutRetainsDataWhenMarkerBecomesUnreadable",
    "testColdAllocatedSignOutSharesCallbackBeforeFinality",
    "testColdAllocatedSignOutSharesDrainBeforeCallback",
    "testColdDiscoveryPublicationReplaysUndrainedEventAfterBusyAttempt",
    "testColdPendingSignOutBindsEarlierExactEventBeforeCleanup",
    "testColdPendingSignOutCleansOnlyItsVerifiedAccount",
    "testColdPendingSignOutRecoversReservedReceipt",
    "testColdPendingSignOutRejectsMismatchedSessionWithoutMutation",
    "testColdTerminalProofRejectsWrongOperationAndTask",
    "testColdTerminalRelaunchAfterManifestAuthorization",
    "testColdTerminalRelaunchAfterManifestPublication",
    "testColdTerminalRetirementHandlesDrainBeforeCallback",
    "testColdTerminalRetirementWithPendingManifestEntry",
    "testColdTerminalRetirementWithoutPendingManifestEntry",
    "testColdTerminalSignOutCompletesQuiescentEventWithoutDrain",
    "testColdTerminalWithoutFinalityRemainsPending",
    "testCompletedColdRecoveryCannotPublishStaleDelayedStatus",
    "testCompletedSignOutPhaseRecoversAfterUncertainCredentialDeletion",
    "testCompletedStoredNativeEventPreservesExactNativeLeaseAndMetadata",
    "testCompletedStoredNativeEventRejectsChangedReceiptWithoutMutation",
    "testCompletedStoredNativeEventRejectsNativeWorkWithoutMutation",
    "testContendedAccountOwnerBlocksStartupAndHeadlessUntilRetry",
    "testCredentialGenerationStampFailuresPreserveSavedAccount",
    "testCredentialReadRetryAllowsConfirmedAbsentOrValidCredential",
    "testCredentialTransactionNeverClearsChangedOrUnmarkedSession",
    "testCredentialTransactionPreservesInterruptedPreparationAndMismatch",
    "testCredentialTransactionPreservesScopeAcrossInterruptedSignOut",
    "testCredentialTransactionRejectsStalePreparedAcceptance",
    "testDefaultAccountLocksUseIsolationHostApplicationSupport",
    "testDifferentAccountRequiresSignOutAndPreservesCurrentAccountData",
    "testDifferentAccountWaitsForSignOutAndHeldLeaseCleanup",
    "testDirectRestoreWaitsForHeadlessNativeReconciliation",
    "testDownloadCleanupPreservesPendingNativeSessionsInScopedRoot",
    "testDownloadHandoffFenceCancelsTransfersWhenPathBecomesForbidden",
    "testDownloadHandoffFenceRejectsAdmissionAndRollsBackWithoutRevival",
    "testDurableSignOutWaitsForActionAndPinSyncBeforeScopedCleanup",
    "testEmptyDownloadCleanupRetainsScopeAndLeavesOtherRootAlone",
    "testEmptyEventCompletesWhileRemovedSessionOwnerStillRetained",
    "testEmptyLateEventCompletesAfterCredentialCommitBeforeMarkerRemoval",
    "testEmptyLateEventCompletesAfterMarkerRemovalBeforeOwnerCommit",
    "testEmptyLateEventRefencesAcrossCredentialCommit",
    "testEmptyLateEventRefencesAcrossMarkerRemoval",
    "testEmptyOldEventAllowsUnrelatedSameScopeDataWithoutMutation",
    "testEmptyOldEventCancellationRetainsCompletionAndData",
    "testEmptyOldEventDoesNotForgetNativeWorkOnOwnerPublicationReplay",
    "testEmptyOldEventDoesNotProbeClaimedCurrentNativeSession",
    "testEmptyOldEventPreservesDifferentCurrentAccountAndLease",
    "testEmptyOldEventPreservesSameCurrentAccountAndLease",
    "testEmptyOldEventPreservesSignedOutAccountSnapshot",
    "testEmptyOldEventRefencesAfterNewOwnerPublication",
    "testEmptyOldEventRejectsNewCredentialDuringObservation",
    "testEmptyOldEventRejectsNewTargetReferenceDuringObservation",
    "testEmptyOldEventRejectsWeakNativeObservations",
    "testEmptySessionAbsenceAllowsUnrelatedCurrentScopeStateWithoutMutation",
    "testEmptySessionAbsenceMustBeRecheckedAfterNewReferenceAppears",
    "testEmptySessionAbsenceRejectsReferencesAndAmbiguousFilesystemState",
    "testEmptySessionEvidenceRefusesWeakOrConflictingObservations",
    "testEmptySessionEvidenceRejectsAcknowledgementWithoutDelivery",
    "testEmptySessionEvidenceRejectsDelegateDrainAfterFinalInvalidation",
    "testEmptySessionEvidenceRequiresActualDrainAndJoinedFinality",
    "testEmptySessionEvidenceRetainsEarlierExactEventDrain",
    "testEmptySessionNamespaceParserRequiresExactAppGrammar",
    "testEmptySessionOutcomeRetainsNativeWorkDespiteCancellationAndFinality",
    "testEmptySessionOutcomeSeparatesUnavailableFromProvedQuiescence",
    "testEmptySessionQuiescenceDoesNotManufactureEventDrain",
    "testEmptySessionQuiescenceRejectsNativeWorkAndFailure",
    "testFailedCredentialClearPreservesModelAndPinsDuringHeldRevocation",
    "testFastCleanupDoesNotPublishStaleDelayedStatus",
    "testFinishSignOutFailureKeepsSavedCredentialAndIntent",
    "testFreshCredentialModelSignOutAdoptsStampedIdentity",
    "testFreshCredentialResumesInterruptedCompletedSignOut",
    "testFreshSignInPreservesOtherScopesBeforeAndAfterAuthentication",
    "testHandoffLeaseWaitCanCancelAndRetryWithoutRetiringOwner",
    "testHandoffOwnerTaskWaitCancelsAndRollsBackWhileTransferIsHeld",
    "testHandoffRollbackRetriesCancelledArtworkDemand",
    "testHandoffWaitsForDetachedRetainedArtworkRead",
    "testHandoffWaitsForEscapedRemoteResourceRelease",
    "testHandoffWaitsForLateRemoteRequestAndItsRelease",
    "testHeldRevocationDoesNotDelayLocalModelSignOut",
    "testHostUsesIsolatedIdentityAndHasNoNativeEntryPoints",
    "testInventoryKeepsVerifiedAudioWithoutRepublishingUnchangedManifest",
    "testInventoryPersistsActualAudioAndArtworkCollection",
    "testInventoryPublishesEmptyManifestOnceAndOtherCollectorsStillSave",
    "testLateRevocationCannotOverwriteReplacementAccount",
    "testLateScopedCacheCleanupPreservesReplacementCache",
    "testLegacyCredentialIsPreservedDuringAmbiguousCompletedRecovery",
    "testLifetimeAccountLeaseRejectsContendingOwnerUntilRelease",
    "testMarkerFirstCommitRetainsLateOldScopeEventUntilReconciled",
    "testMarkerFirstSignOutHoldsCredentialUntilScopedLeaseDrains",
    "testMarkerFirstSignOutKeepsUnverifiableMissingPackagePending",
    "testMarkerFirstSignOutPreservesAllocatedPackageWithoutFinality",
    "testMarkerFirstSignOutPreservesAllocatedPackageWithoutModelDrain",
    "testMarkerFirstSignOutPreservesMismatchedAllocatedNamespace",
    "testMarkerFirstSignOutPreservesMismatchedAllocatedPackage",
    "testMarkerFirstSignOutPreservesMismatchedAllocatedTrack",
    "testMarkerFirstSignOutPreservesMismatchedAllocatedURL",
    "testMarkerFirstSignOutPreservesTerminalReceiptWithoutFinality",
    "testMarkerFirstSignOutRetainsScopeDuringCancelledAllocatedRetirement",
    "testMarkerFirstSignOutRetiresExactAllocatedPackageAfterLeaseDrains",
    "testMarkerFirstSignOutRetiresFinalizedTerminalReceiptAfterLease",
    "testMarkerFirstSignOutRetiresReservedReceiptAfterLeaseDrains",
    "testMarkerFirstSignOutRetriesAfterAllocatedPackageUnlinkBeforeTombstone",
    "testMarkerFirstSignOutRetriesAfterDirectoryRemovalBeforeAdoption",
    "testMarkerFirstSignOutRetriesAfterPartialReceiptConsumption",
    "testMarkerFirstSignOutRetriesAllocatedAfterManifest",
    "testMarkerFirstSignOutRetriesAllocatedAfterReceiptConsumption",
    "testMarkerFirstSignOutRetriesAllocatedAfterTombstone",
    "testMarkerFirstSignOutRetriesFinalizedTerminalAfterReceiptConsumption",
    "testMismatchedAllocatedRecoveryReceiptNeverStartsRetirement",
    "testMissingNativeFinalityRecoveryKeepsCleanupPending",
    "testModelDeinitRejectsEscapedActionWorkAndPreservesLeasedStorage",
    "testModelDeinitRetainsScopedPinsAndPageCache",
    "testModelDeinitRetiresExternallyRetainedConfiguredHandoffContext",
    "testNativeBackgroundDrainAndReconciliationCompleteOnlyOnce",
    "testNativeFinalityWaitsForOrderedModelDeliveryAndCachesFailure",
    "testNativeInvalidationDoesNotSignalBackgroundEventDrain",
    "testNativeRetirementTombstoneRejectsAmbiguousStates",
    "testNativeTaskReportsNetworkFailureSeparatelyFromCancellation",
    "testNoFactoryReceiptCleanupRejectsLegacyCreatingAndUnknownStage",
    "testNoFactoryReceiptCleanupResumesAfterEachPersistenceCheckpoint",
    "testObserverDrainCannotAcknowledgeAdmittedEventBeforeFinality",
    "testObserverDrainCannotAcknowledgeAdmittedEventWithChangedCurrentProof",
    "testObserverDrainCannotAcknowledgeAdmittedEventWithNativeWork",
    "testOrdinaryDownloadCleanupRejectsOpaqueNativeManifest",
    "testPendingOrUnreadableSignOutBlocksStartupHeadlessAndAuthentication",
    "testPendingSignOutHeadlessReconciliationRetiresOnlyMatchingReceipt",
    "testPersistentBackgroundFailureRetriesOnlyOnUserAttempt",
    "testPinSyncCloudEraseRequiresExplicitRetryAfterPriorExchange",
    "testPinSyncSerializesReplacementAndDrainsOnRetirement",
    "testPlayerStopUsesIsolatedSessionLaneAndDiagnosticSink",
    "testPostRemovalReconstructedModelCompletesAlreadyDrainedEmptyNativeEvent",
    "testQueuedRetainedArtworkDeliveryRejectsReplacedSameAccountRuntime",
    "testQueuedRetainedArtworkDeliverySurvivesCancelledReauthentication",
    "testQueuedRetainedArtworkDeliverySurvivesFailedReauthentication",
    "testReadinessInvalidationDoesNotAbortAuthorizedAllocatedSignOut",
    "testRealModelSignsInAndLocallySignsOutWithoutSystemServices",
    "testRecoveredSignOutConsumedProofRejectsChangedMarker",
    "testRecoveredSignOutConsumedProofRejectsReplacementReceiptTask",
    "testRecoveredSignOutRetriesAfterDirectoryRemoval",
    "testRecoveredSignOutRetriesAfterManifest",
    "testRecoveredSignOutRetriesAfterReceiptConsumption",
    "testRecoveredSignOutRetriesAfterTombstone",
    "testRemoveAllDefersNativeRetirementWhilePlaybackLeaseIsHeld",
    "testRestoreDoesNotReplaceActiveOwnerWhileInventoryIsHeld",
    "testRestoredOwnerRetriesExactBackgroundReceiptAfterInventoryRetiresIt",
    "testRetiredOwnerRequiresLiveFinalityAndExactPackageBinding",
    "testSameAccountCallbackReconcilesBeforeHandoffCommit",
    "testSameAccountCallbackRetriesAfterHandoffCommit",
    "testSameScopeRecoveryRetainsSyntheticNativeCallbackOwner",
    "testSandboxScopedRemovalUsesSystemAnchorsWithoutFollowingLinks",
    "testScopedAccountRetentionUsesOnlyItsOwnRootsAndDefaults",
    "testScopedCleanupRejectsNativePackageWithoutResolvingIt",
    "testScopedCleanupRejectsNativeReceiptWithoutOpeningIt",
    "testScopedRecoveredAllocationRejectsReplacementTaskBeforeRemoval",
    "testScopedRemovalRejectsSymlinksNativeAndBudgetBeforeDeleting",
    "testSignInRetriesExactScopedHeadlessEventBeforeAuthentication",
    "testSignOutCleanupPreservesOtherAccountScopes",
    "testSignOutCommitReservationRetainsEventDuringAsyncCommit",
    "testSignOutDoesNotAdmitReplacementWhileInventoryIsHeld",
    "testSignOutDuringCompletedNativeObservationReplaysAfterCleanupAndRetries",
    "testSignOutIntentRejectsInterleavedReplacementAndUncertainWrites",
    "testSignOutIntentRejectsStaleAmbiguousAndLockedItems",
    "testSignOutRecoversAllocatedFinalityAfterPlaybackLeaseDrains",
    "testSignOutReportsMultipleFailuresAcrossDownloadRetry",
    "testSignOutUnverifiedInitialIdentityRequiresRestart",
    "testSignOutWaitsForHeldModelDownloadLease",
    "testSuccessfulDownloadRetryUpdatesEarlierServerNotice",
    "testUncertainRetryKeepsEarlierBackgroundEventWithOldOwner",
    "testUncertainSignOutRetriesExactMarkerAndPreservesData",
    "testUnreadableCredentialsPreserveStoresAndBlockAuthentication",
    "testUnresolvedBackgroundEventWaitsForAdmittedRetry",
}

# Widget account/cleanup contracts share the lifecycle host.
required.update({
    "testWidgetCleanupFailurePreventsActualSignOutCompletionAndRetries",
    "testWidgetCommandsRejectForeignAndReplacedOccurrencesInActualAppOwner",
    "testWidgetRecentStartAdmitsEarlierAdvanceButRejectsQueueAndPauseInterruptions",
    "testWidgetRetiresHeldOptionalArtworkBeforeStructuredClear",
})
# Exact widget-class bindings; do not accept similarly named tests in another suite.
widget_required = {
    "testCollectionContextRestoresWithoutChangingQueueOccurrenceOrOldSnapshotFormat",
    "testWidgetArtworkEnrichmentPreservesNewMetadataAndRejectsRetiredGeneration",
    "testWidgetCommandRejectsForeignAccountAndStaleOccurrenceWithoutToggling",
    "testWidgetLegacyCacheDropsMalformedOptionalRecentPairWithoutLosingCurrent",
    "testWidgetModesKeepCurrentAndRecentReachableDuringActiveQueue",
    "testWidgetRecentCommandsUseTargetIdentityAndOccurrenceOnlyForCurrentControl",
    "testWidgetStorageRejectsRetiredPublisherAndDoesNotOverwriteNewAccount",
    "testWidgetStoreCommitsTwoSlotsAndRecoversBoundedCrashOrphans",
    "testWidgetStorePublishesMatchingBoundedArtworkAndClearsOnlyItsAccount",
    "testWidgetStoreRecoversBoundedCrashOrphansBeforeRepeatedPublication",
    "testWidgetStoreRejectsOversizedAndUnsafeRecords",
    "testWidgetTwoImageFailurePreservesCommittedPairAndMetadataFirstUpdate",
}

if platform == "macos":
    required.update({
        "testMacReauthenticationDefersReentrantSignOutUntilCommit",
        "testUpgradeWithMixedScopesRequiresConfirmationAndPreservesData",
        "testMacSameAccountSaveFailureRestoresOwnerAndData",
        "testMacSameAccountReauthenticationPreservesScopedData",
        "testMacReauthenticationCancellationPreservesAccountDataAndHeldLease",
        "testMacReauthenticationFailurePreservesAccountDataAndHeldLease",
    })
elif platform != "ios":
    raise SystemExit("Unknown isolation test platform")
expected = {"FoundationAppLifecycleIsolationTests/" + name for name in required}
expected.update("FoundationWidgetPlaybackTests/" + name for name in widget_required)
# Search continuation is critical even when a selector silently discovers zero tests.
search_required = {
    "FoundationCatalogSourceTests/testEmptySearchSeedCanContinueFallbackToFirstMatch",
    "FoundationCatalogSourceTests/testFallbackFailureKeepsCursorForExplicitRetry",
    "FoundationCatalogSourceTests/testRetiredFallbackCannotPublishLatePage",
    "FoundationCatalogSourceTests/testSearchFallbackContinuationOwnsItsCursorAndRetainsProviderRows",
    "FoundationComposedCatalogModelTests/testCappedSearchSourceRoundTripCannotExposeAnotherRead",
    "FoundationComposedCatalogModelTests/testSearchFilterRoundTripPreservesSeedCoverage",
    "FoundationComposedCatalogModelTests/testSearchFilterSuspensionDrainsAndRejectsLateFallbackThenRetriesSameCursor",
    "FoundationComposedCatalogModelTests/testSearchSourceRoundTripRetainsContinuedRowsAndCursorWithoutReads",
    "FoundationSearchResolverTests/testEmptyCategoryContinuationEntryVisibility",
    "FoundationSearchResolverTests/testEmptyOriginalSeedWithoutFallbackContinuesExplicitly",
    "FoundationSearchResolverTests/testNativeEmptyFallbackSeedMakesOneExplicitReadAndClearsNotice",
    "FoundationSearchResolverTests/testNativeFilteredPageRetainsContinuationWithoutWalking",
    "FoundationSearchResolverTests/testNativeOriginalAndFallbackCursorsRetryIndependently",
    "FoundationSearchResolverTests/testNativeRetirementRejectsLateFallbackResult",
}
expected.update(search_required)
seen = {}
def visit(node):
    if node.get("nodeType") == "Test Case":
        identifier = node.get("nodeIdentifier", "").removesuffix("()")
        if identifier in expected:
            seen.setdefault(identifier, []).append(node.get("result"))
    for child in node.get("children", []):
        visit(child)
for node in results.get("testNodes", []):
    visit(node)
missing = sorted(name for name in expected if not seen.get(name))
unsuccessful = sorted(name for name in expected if name in seen and (
    len(seen[name]) != 1 or seen[name] != ["Passed"]))
if missing or unsuccessful:
    raise SystemExit(f"Isolation test coverage failure: missing={missing}, not passed={unsuccessful}")
print(f"Verified {platform} isolation coverage: {len(expected)} required tests passed")
PYTHON
}

# Refuse ambiguous or physical-device destinations before running any test.
validate_ios_destination() {
  python3 - "$ios_destination" "$build_mode" <<'PYTHON'
import json
import os
import re
import subprocess
import sys

destination, mode = sys.argv[1:]
pattern = r"platform=iOS Simulator,id=[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}"
if re.fullmatch(pattern, destination) is None:
    raise SystemExit("Set VELACANTO_IOS_SIMULATOR_DESTINATION to platform=iOS Simulator,id=<existing simulator UUID>.")
try:
    inventory = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    raise SystemExit(f"Could not verify the iOS Simulator inventory: {error}")

if mode == "pr-hosted":
    # Match the existing release workflow's exact, preinstalled runner device.
    # Only that explicitly selected mode on a GitHub Actions job may use it;
    # normal local commands retain the single shared simulator restriction.
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("CI") != "true":
        raise SystemExit("pr-hosted is reserved for the GitHub Actions quality job.")
    candidates = inventory.get("devices", {}).get("com.apple.CoreSimulator.SimRuntime.iOS-27-0", [])
    matches = [device for device in candidates
               if device.get("name") == "iPhone Air" and device.get("isAvailable") is True]
    failure = "Select the unique available iPhone Air with iOS 27.0 chosen by the hosted workflow."
else:
    # The coordinator owns exactly one named local iPhone Duo simulator.
    matches = [device for devices in inventory.get("devices", {}).values() for device in devices
               if device.get("name") == "VelaCanto Duo Test Sim" and device.get("isAvailable") is True]
    failure = "Select the unique available iPhone Duo named VelaCanto Duo Test Sim; do not create or use another simulator."
    if len(matches) != 1 or matches[0].get("deviceTypeIdentifier") != "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo":
        raise SystemExit(failure)
if len(matches) != 1 or matches[0].get("udid", "").lower() != destination.split("id=", 1)[1].lower():
    raise SystemExit(failure)
PYTHON
}

# Inspect the freshly built test host before any test is allowed to launch.
verify_isolation_host() {
  app=$1
  host_platform=$2
  /usr/bin/codesign --verify --deep --strict "$app"
  /usr/bin/codesign --display --xml --entitlements - "$app" \
    > "$result_root/host-entitlements.plist" 2> "$result_root/host-signature.log"
  python3 - "$app" "$result_root/host-entitlements.plist" "$host_platform" \
    "$result_root/DerivedData/Build/Products" "$result_root/xctestrun-path" \
    "$result_root/host-signature.log" <<'PYTHON'
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1])
entitlement_path = pathlib.Path(sys.argv[2])
platform = sys.argv[3]
products = pathlib.Path(sys.argv[4])
xctestrun_path_file = pathlib.Path(sys.argv[5])
signature_log = pathlib.Path(sys.argv[6]).read_text(encoding="utf-8")
if "warning:" in signature_log.lower():
    raise SystemExit("Isolation host signature inspection reported a warning")
info_path = app / ("Contents/Info.plist" if platform == "macos" else "Info.plist")
with info_path.open("rb") as file:
    info = plistlib.load(file)
entitlement_data = entitlement_path.read_bytes()
entitlements = plistlib.loads(entitlement_data) if entitlement_data else {}
if info.get("CFBundleIdentifier") != "com.chameleonenterprise.velacanto.isolationtesting":
    raise SystemExit("Isolation host has an unexpected bundle identity")
if info.get("CFBundleExecutable") != "VelacantoIsolation":
    raise SystemExit("Isolation host has an unexpected executable")
expected_platforms = {"macos": ("MacOSX", "macosx"), "ios": ("iPhoneSimulator", "iphonesimulator")}
if platform not in expected_platforms:
    raise SystemExit("Unknown isolation host platform")
supported, platform_name = expected_platforms[platform]
if info.get("CFBundleSupportedPlatforms") != [supported] or info.get("DTPlatformName") != platform_name:
    raise SystemExit("Isolation host was not built for the expected platform")
if any(app.rglob("*.appex")):
    raise SystemExit("Isolation host contains an unexpected app extension")
for key in ("NSUserActivityTypes", "UIBackgroundModes", "UIApplicationSceneManifest", "INIntentsSupported"):
    if key in info:
        raise SystemExit(f"Isolation host exposes a native entry point: {key}")
if platform == "macos":
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        raise SystemExit("Isolation host is not signed with the Mac App Sandbox entitlement")
elif platform != "ios":
    raise SystemExit("Unknown isolation host platform")
allowed = {
    "com.apple.security.app-sandbox", "com.apple.security.get-task-allow", "get-task-allow",
    "application-identifier", "com.apple.application-identifier", "com.apple.developer.team-identifier",
}
# Test-only IPC: runtime denial identifies this one XCTest service. Do not
# inherit Xcode's root-read or other temporary exceptions.
mach_key = "com.apple.security.temporary-exception.mach-lookup.global-name"
if platform == "macos":
    if entitlements.get("com.apple.security.get-task-allow") is not True:
        raise SystemExit("Mac isolation host lacks debugger entitlement")
    if entitlements.get(mach_key) != ["com.apple.testmanagerd"]:
        raise SystemExit("Mac isolation host has unexpected XCTest service access")
    allowed.add(mach_key)
extra = set(entitlements) - allowed
if extra:
    raise SystemExit(f"Isolation host has unexpected entitlements: {sorted(extra)}")
for key in ("application-identifier", "com.apple.application-identifier"):
    value = entitlements.get(key)
    if value is not None and not value.endswith(".com.chameleonenterprise.velacanto.isolationtesting"):
        raise SystemExit("Isolation host entitlement has an unexpected application identity")
runs = list(products.glob("VelacantoFoundationIsolation_*.xctestrun"))
if len(runs) != 1:
    raise SystemExit("Expected exactly one freshly built isolation xctestrun")
with runs[0].open("rb") as file:
    run = plistlib.load(file)
if set(run) != {"__xctestrun_metadata__", "VelacantoIsolationTests"}:
    raise SystemExit("Isolation xctestrun includes unexpected test targets")
target = run["VelacantoIsolationTests"]
if target.get("TestHostBundleIdentifier") != info["CFBundleIdentifier"]:
    raise SystemExit("Isolation xctestrun names an unexpected host identity")
relative_host = target.get("TestHostPath", "")
if not relative_host.startswith("__TESTROOT__/"):
    raise SystemExit("Isolation xctestrun host path is not relative to its build products")
if (products / relative_host.removeprefix("__TESTROOT__/")).resolve() != app.resolve():
    raise SystemExit("Isolation xctestrun does not reference the verified host")
if target.get("IsAppHostedTestBundle") is not True or "-foundationTesting" not in target.get("CommandLineArguments", []):
    raise SystemExit("Isolation xctestrun lacks the expected isolated test-host configuration")
if target.get("SkipTestIdentifiers") or target.get("OnlyTestIdentifiers"):
    raise SystemExit("Isolation xctestrun has unexpected test selections")
expected_bundle = "__TESTHOST__/Contents/PlugIns/VelacantoIsolationTests.xctest" if platform == "macos" else "__TESTHOST__/PlugIns/VelacantoIsolationTests.xctest"
if target.get("TestBundlePath") != expected_bundle:
    raise SystemExit("Isolation xctestrun names an unexpected test bundle")
test_bundle = app / expected_bundle.removeprefix("__TESTHOST__/")
test_info = test_bundle / ("Contents/Info.plist" if platform == "macos" else "Info.plist")
with test_info.open("rb") as file:
    test_identifier = plistlib.load(file).get("CFBundleIdentifier")
if test_identifier != "com.chameleonenterprise.velacanto.isolationtesting.tests":
    raise SystemExit("Isolation test bundle has an unexpected identity")
xctestrun_path_file.write_text(str(runs[0]), encoding="utf-8")
print(f"Verified {platform} isolation host identity, entitlements and test plan")
PYTHON
}

# Xcode injects broad test-host exceptions. Re-sign only the fresh disposable
# Mac fixture with the reviewed exact entitlements before the strict preflight.
normalize_isolation_macos_signature() {
  app=$1
  python3 - "$app" "$result_root" <<'PYTHON'
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2]).resolve()
expected_parent = root / "DerivedData/Build/Products/IsolationTesting"
if app.is_symlink() or app.resolve().parent != expected_parent:
    raise SystemExit("Refusing to re-sign outside the fresh Mac isolation products")
with (app / "Contents/Info.plist").open("rb") as file:
    info = plistlib.load(file)
if (info.get("CFBundleIdentifier") != "com.chameleonenterprise.velacanto.isolationtesting"
        or info.get("CFBundleExecutable") != "VelacantoIsolation"
        or info.get("CFBundleSupportedPlatforms") != ["MacOSX"]
        or info.get("DTPlatformName") != "macosx"):
    raise SystemExit("Refusing to re-sign a non-isolation Mac host")
PYTHON
  /usr/bin/codesign --force --sign - \
    --entitlements "$project_root/NativeFoundation/Resources/IsolationTestHost-macOS.entitlements" \
    "$app" > "$result_root/host-normalize-signature.log" 2>&1
}

isolation_macos_verified=NO
isolation_ios_verified=NO

isolation_macos() {
  result_root=$(mktemp -d "${TMPDIR:-/private/tmp}/velacanto-isolation-macos.XXXXXX")
  result_path="$result_root/Isolation.xcresult"
  printf 'Isolation test evidence: %s\n' "$result_root"
  run_isolation_xcode CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= -configuration IsolationTesting -destination 'platform=macOS' \
    -parallel-testing-enabled NO build-for-testing
  normalize_isolation_macos_signature "$result_root/DerivedData/Build/Products/IsolationTesting/VelacantoIsolation.app"
  verify_isolation_host "$result_root/DerivedData/Build/Products/IsolationTesting/VelacantoIsolation.app" macos
  "$DEVELOPER_DIR/usr/bin/xcodebuild" -xctestrun "$(cat "$result_root/xctestrun-path")" \
    -destination 'platform=macOS' -parallel-testing-enabled NO \
    -resultBundlePath "$result_path" test-without-building
  verify_isolation_result "$result_path" macos
  # The actual RootView/lyrics retirement contract uses an external Mac Scene runner.
  # Do not mark the Mac gate verified until this required UI case has executed and passed.
  root_lyrics_evidence=$(mktemp -d "${TMPDIR:-/private/tmp}/velacanto-root-lyrics-macos.XXXXXX")
  VELACANTO_ROOT_LYRICS_RESULT_ROOT="$root_lyrics_evidence/Run" \
    VELACANTO_PACKAGES_PATH="${VELACANTO_PACKAGES_PATH:-$derived_data_path/SourcePackages}" \
    ./scripts/test-root-lyrics-retirement.sh
  isolation_macos_verified=YES
}

isolation_ios() {
  validate_ios_destination
  result_root=$(mktemp -d "${TMPDIR:-/private/tmp}/velacanto-isolation-ios.XXXXXX")
  result_path="$result_root/Isolation.xcresult"
  printf 'Isolation test evidence: %s\n' "$result_root"
  run_isolation_xcode CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= -configuration IsolationTesting -destination "$ios_destination" \
    -parallel-testing-enabled NO build-for-testing
  verify_isolation_host "$result_root/DerivedData/Build/Products/IsolationTesting-iphonesimulator/VelacantoIsolation.app" ios
  "$DEVELOPER_DIR/usr/bin/xcodebuild" -xctestrun "$(cat "$result_root/xctestrun-path")" \
    -destination "$ios_destination" -parallel-testing-enabled NO \
    -resultBundlePath "$result_path" test-without-building
  verify_isolation_result "$result_path" ios
  isolation_ios_verified=YES
}

macos() { run_xcode -configuration Debug -destination 'generic/platform=macOS' build; }
test_macos() {
  run_xcode -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO test
  isolation_macos
}
ios() { run_xcode -configuration Debug -destination 'generic/platform=iOS Simulator' build; }
test_ios() {
  validate_ios_destination
  # Simulator Keychain tests need the identity entitlements supplied by signing.
  # Ad-hoc signing requires neither a certificate nor a provisioning profile.
  # Keep the unit host on the disposable identity, preserving installed sessions.
  run_xcode CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= -configuration UITesting -destination "$ios_destination" \
    -parallel-testing-enabled NO test
  isolation_ios
}
release() {
  # Standalone release runs both lifecycle gates. Combined commands reuse gates
  # already completed in this shell instead of executing the same suites twice.
  # Explicit overrides must affect every built target as well as verification.
  set --
  if [ "${VELACANTO_BUILD_NUMBER+x}" = x ]; then
    case "$VELACANTO_BUILD_NUMBER" in *[!0-9]*|'') printf 'Build number must be numeric.\n' >&2; return 2 ;; esac
    set -- "$@" "CURRENT_PROJECT_VERSION=$VELACANTO_BUILD_NUMBER"
  fi
  if [ "${VELACANTO_MARKETING_VERSION+x}" = x ]; then
    case "$VELACANTO_MARKETING_VERSION" in 0.6.0|0.7.0) ;; *) printf 'Unsupported marketing version.\n' >&2; return 2 ;; esac
    set -- "$@" "MARKETING_VERSION=$VELACANTO_MARKETING_VERSION"
  fi
  validate_ios_destination
  if [ "$isolation_macos_verified" != YES ]; then isolation_macos; fi
  if [ "$isolation_ios_verified" != YES ]; then isolation_ios; fi
  run_xcode "$@" -configuration Release -destination 'generic/platform=macOS' build
  run_xcode "$@" -configuration Release -destination 'generic/platform=iOS' build
  python3 scripts/verify-release.py "$derived_data_path/Build/Products/Release-iphoneos/Velacanto.app"
  python3 scripts/verify-release.py "$derived_data_path/Build/Products/Release/Velacanto.app"
}
case "$build_mode" in
  lint) lint ;;
  macos) macos ;;
  test) test_macos ;;
  isolation-test) isolation_macos ;;
  ios-simulator) ios ;;
  ios-simulator-test) test_ios ;;
  ios-simulator-isolation-test) isolation_ios ;;
  release) release ;;
  all) ./scripts/preflight.sh --skip-xcode; lint; macos; test_macos; ios ;;
  pr|pr-os27-preview|pr-hosted)
    ./scripts/preflight.sh
    lint
    test_macos
    test_ios
    release
    ;;
  *) printf 'Usage: %s [all|lint|macos|test|isolation-test|ios-simulator|ios-simulator-test|ios-simulator-isolation-test|release|pr]\n' "$0" >&2; exit 2 ;;
esac
