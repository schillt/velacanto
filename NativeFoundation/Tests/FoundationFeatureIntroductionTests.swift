import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationFeatureIntroductionTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "IntroductionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testFirstRunHasCurrentFeaturesWithoutWritingHistory() {
        let defaults = defaults()
        let history = FoundationIntroductionHistory(defaults: defaults)
        XCTAssertEqual(history.pending(), FoundationIntroductionFeature.current)
        XCTAssertTrue(history.needsOffer(hasPendingPinChoice: false))
        XCTAssertNil(defaults.object(forKey: FoundationIntroductionHistory.storageKey))
    }

    func testExplicitCompletionSurvivesRelaunchAndDoesNotRepeatForAnotherBuild() {
        let defaults = defaults()
        let history = FoundationIntroductionHistory(defaults: defaults)
        history.acknowledge(history.pending().map(\.id))
        // Version/build preferences have no role in eligibility.
        defaults.set("0.6.0 (999)", forKey: "SyntheticBuild")
        let nextLaunch = FoundationIntroductionHistory(defaults: defaults)
        XCTAssertTrue(nextLaunch.pending().isEmpty)
        XCTAssertFalse(nextLaunch.needsOffer(hasPendingPinChoice: false))
    }

    func testUpgradeOffersOnlyNewStableFeatureIDs() {
        let history = FoundationIntroductionHistory(defaults: defaults())
        let existing = FoundationIntroductionFeature.current
        history.acknowledge(existing.map(\.id))
        let newFeature = FoundationIntroductionFeature(
            id: "synthetic.future.v1", release: "0.7", title: "Future feature",
            symbol: "music.note", detail: "Synthetic test fixture")
        XCTAssertEqual(history.pending(in: existing + [newFeature]), [newFeature])
        XCTAssertTrue(history.pending(in: existing).isEmpty)
    }

    func testPendingAccountActionIsNotSuppressedByGlobalHighlightHistory() {
        let history = FoundationIntroductionHistory(defaults: defaults())
        history.acknowledge(FoundationIntroductionFeature.current.map(\.id))
        history.acknowledge([FoundationIntroductionFeature.pinSyncID])
        XCTAssertTrue(history.needsOffer(hasPendingPinChoice: true))
        XCTAssertFalse(history.needsOffer(hasPendingPinChoice: false))
    }

    func testPartialExplicitAcknowledgementLeavesOtherFeaturesPending() {
        let history = FoundationIntroductionHistory(defaults: defaults())
        let first = FoundationIntroductionFeature.current[0]
        history.acknowledge([first.id])
        XCTAssertEqual(history.pending(), Array(FoundationIntroductionFeature.current.dropFirst()))
    }

    func testAppearanceOrDismissalWithoutDecisionDoesNotConsumeFeatures() {
        let defaults = defaults()
        let firstAppearance = FoundationIntroductionHistory(defaults: defaults)
        let pending = firstAppearance.pending()
        // A new surface reconstructs the same pending list; only acknowledge writes.
        let resumed = FoundationIntroductionHistory(defaults: defaults)
        XCTAssertEqual(resumed.pending(), pending)
        XCTAssertNil(defaults.object(forKey: FoundationIntroductionHistory.storageKey))
    }

    func testSeenHighlightsAndDismissedClaimNeverEnableOrDeclineAccountSync() async {
        let defaults = defaults()
        let history = FoundationIntroductionHistory(defaults: defaults)
        let sync = FoundationPinSync(
            scope: String(repeating: "a", count: 64), containerIdentifier: nil,
            defaults: defaults,
            exchange: { _, _, _, _, _, _ in
                XCTFail("Introduction history must not access cloud records")
                throw CancellationError()
            }, accountAvailable: { true }, currentPins: { [] }, apply: { _, _ in })
        history.acknowledge(FoundationIntroductionFeature.current.map(\.id))
        XCTAssertFalse(sync.enabled)
        await sync.prepareOptInPrompt()
        let owner = UUID()
        XCTAssertTrue(sync.claimOptInPrompt(owner: owner))
        sync.releaseOptInPrompt(owner: owner)
        XCTAssertFalse(sync.enabled)
        XCTAssertTrue(sync.offersOptIn)
        XCTAssertTrue(history.needsOffer(hasPendingPinChoice: sync.offersOptIn))
        let nextOwner = UUID()
        XCTAssertTrue(sync.claimOptInPrompt(owner: nextOwner))
        sync.respondToOptInPrompt(owner: nextOwner, enable: false)
        XCTAssertFalse(sync.offersOptIn)
        XCTAssertFalse(sync.enabled)
        XCTAssertNil(sync.task)
        sync.invalidate()
    }

    func testHistoryContainsOnlyFeatureIDsAndNeverConsentJournal() {
        let defaults = defaults()
        let history = FoundationIntroductionHistory(defaults: defaults)
        let ids = FoundationIntroductionFeature.current.map(\.id)
        history.acknowledge(ids + ids)
        XCTAssertEqual(
            defaults.stringArray(forKey: FoundationIntroductionHistory.storageKey), ids.sorted())
        XCTAssertEqual(history.seen.count, ids.count)
        XCTAssertNil(defaults.object(forKey: FoundationPinSync.storagePrefix + "synthetic"))
    }

    func testSystemStorageUpgradeOfferIsPlatformScopedAndAcknowledgementIsNotConsent() {
        let defaults = defaults()
        let preferences = FoundationPlaybackPreferences(defaults: defaults)
        let history = FoundationIntroductionHistory(defaults: defaults)
        let storageID = FoundationIntroductionFeature.systemStorageID
        // Simulate completion of the highlights shipped before the new storage feature.
        history.acknowledge(
            FoundationIntroductionFeature.current.filter { $0.id != storageID }.map(\.id))
        #if os(iOS)
            XCTAssertEqual(history.pending().map(\.id), [storageID])
        #else
            XCTAssertFalse(FoundationIntroductionFeature.current.contains { $0.id == storageID })
            XCTAssertTrue(history.pending().isEmpty)
        #endif
        XCTAssertEqual(preferences.downloadQuality, .original)
        XCTAssertFalse(preferences.systemManagedDownloads)
        // Finish/Skip records presentation history only; a fresh owner stays opted out.
        history.acknowledge(history.pending().map(\.id))
        let restored = FoundationPlaybackPreferences(defaults: defaults)
        XCTAssertEqual(restored.downloadQuality, .original)
        XCTAssertFalse(restored.systemManagedDownloads)
        XCTAssertTrue(FoundationIntroductionHistory(defaults: defaults).pending().isEmpty)
    }

    func testAutomaticFirstVersionClaimDoesNotAcknowledgeAppearance() {
        let defaults = defaults()
        let history = FoundationIntroductionHistory(defaults: defaults)
        XCTAssertTrue(history.needsAutomaticPresentation(for: "0.6.0"))
        XCTAssertFalse(history.needsAutomaticPresentation(for: nil))
        XCTAssertFalse(history.needsAutomaticPresentation(for: ""))
        XCTAssertTrue(history.claimAutomaticPresentation(version: "0.6.0", owner: UUID()))
        XCTAssertNil(defaults.string(forKey: FoundationIntroductionHistory.versionKey))
        XCTAssertEqual(history.pending(), FoundationIntroductionFeature.current)
    }

    func testExplicitVersionCompletionSurvivesRelaunchAndIgnoresBuildChanges() {
        let defaults = defaults()
        let history = FoundationIntroductionHistory(defaults: defaults)
        let owner = UUID()
        XCTAssertTrue(history.claimAutomaticPresentation(version: "0.6.0", owner: owner))
        history.acknowledgeAutomaticPresentation(version: "0.6.0", owner: owner)
        history.releaseAutomaticPresentation(owner: owner)
        defaults.set("999", forKey: "SyntheticBuild")
        let restored = FoundationIntroductionHistory(defaults: defaults)
        XCTAssertFalse(restored.needsAutomaticPresentation(for: "0.6.0"))
        XCTAssertTrue(restored.needsAutomaticPresentation(for: "0.6.1"))
    }

    func testVersionUpgradeStillOffersWhenEveryFeatureIDWasSeen() {
        let history = FoundationIntroductionHistory(defaults: defaults())
        history.acknowledge(FoundationIntroductionFeature.current.map(\.id))
        XCTAssertTrue(history.pending().isEmpty)
        XCTAssertTrue(history.needsAutomaticPresentation(for: "0.6.0"))
        XCTAssertTrue(history.claimAutomaticPresentation(version: "0.6.0", owner: UUID()))
    }

    func testDismissalReleasesVersionClaimWithoutAcknowledgement() {
        let defaults = defaults()
        let history = FoundationIntroductionHistory(defaults: defaults)
        let first = UUID()
        XCTAssertTrue(history.claimAutomaticPresentation(version: "0.6.0", owner: first))
        history.releaseAutomaticPresentation(owner: first)
        XCTAssertTrue(history.needsAutomaticPresentation(for: "0.6.0"))
        XCTAssertNil(defaults.string(forKey: FoundationIntroductionHistory.versionKey))
        XCTAssertTrue(history.claimAutomaticPresentation(version: "0.6.0", owner: UUID()))
    }

    func testOnlyOneWindowCanClaimOrAcknowledgeAutomaticPresentation() {
        let history = FoundationIntroductionHistory(defaults: defaults())
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(history.claimAutomaticPresentation(version: "0.6.0", owner: first))
        XCTAssertFalse(history.claimAutomaticPresentation(version: "0.6.0", owner: second))
        history.acknowledgeAutomaticPresentation(version: "0.6.0", owner: second)
        history.releaseAutomaticPresentation(owner: second)
        XCTAssertEqual(history.automaticPresentationOwner, first)
        XCTAssertTrue(history.needsAutomaticPresentation(for: "0.6.0"))
        history.acknowledgeAutomaticPresentation(version: "0.7.0", owner: first)
        XCTAssertTrue(history.needsAutomaticPresentation(for: "0.6.0"))
        history.acknowledgeAutomaticPresentation(version: "0.6.0", owner: first)
        XCTAssertFalse(history.needsAutomaticPresentation(for: "0.6.0"))
    }

    func testAutomaticPresentationWaitsForReadyForegroundAndNoConflictingModal() {
        XCTAssertTrue(
            FoundationAutomaticIntroductionEligibility(
                isReady: true, isForeground: true, hasOtherPresentation: false,
                hasAccountAlert: false, hasHandoff: false
            ).canPresent)
        let blocked: [FoundationAutomaticIntroductionEligibility] = [
            .init(
                isReady: false, isForeground: true, hasOtherPresentation: false,
                hasAccountAlert: false, hasHandoff: false),
            .init(
                isReady: true, isForeground: false, hasOtherPresentation: false,
                hasAccountAlert: false, hasHandoff: false),
            .init(
                isReady: true, isForeground: true, hasOtherPresentation: true,
                hasAccountAlert: false, hasHandoff: false),
            .init(
                isReady: true, isForeground: true, hasOtherPresentation: false,
                hasAccountAlert: true, hasHandoff: false),
            .init(
                isReady: true, isForeground: true, hasOtherPresentation: false,
                hasAccountAlert: false, hasHandoff: true),
        ]
        XCTAssertTrue(blocked.allSatisfy { !$0.canPresent })
    }

    #if os(iOS)
        func testStorageWalkthroughExplicitActionsRequireAACWithoutSubstitutingOriginal() {
            let defaults = defaults()
            let preferences = FoundationPlaybackPreferences(defaults: defaults)
            FoundationIntroductionSystemStorageStep.setEnabled(true, preferences: preferences)
            XCTAssertEqual(preferences.downloadQuality, .original)
            XCTAssertFalse(preferences.systemManagedDownloads)
            for quality in [FoundationDownloadQuality.aac320, .aac192, .aac128] {
                FoundationIntroductionSystemStorageStep.chooseQuality(
                    quality, preferences: preferences)
                XCTAssertEqual(preferences.downloadQuality, quality)
                XCTAssertFalse(
                    preferences.systemManagedDownloads, "Quality selection alone is not consent")
                FoundationIntroductionSystemStorageStep.setEnabled(true, preferences: preferences)
                XCTAssertTrue(preferences.systemManagedDownloads)
                let restored = FoundationPlaybackPreferences(defaults: defaults)
                XCTAssertEqual(restored.downloadQuality, quality)
                XCTAssertTrue(restored.systemManagedDownloads)
                FoundationIntroductionSystemStorageStep.chooseQuality(
                    .original, preferences: preferences)
                XCTAssertEqual(preferences.downloadQuality, .original)
                XCTAssertFalse(preferences.systemManagedDownloads)
            }
        }
    #endif
}
