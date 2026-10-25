import AVFoundation
import Combine
import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationOfflinePolicyTests: XCTestCase {
    func testScalarPreferencesPreserveDefaultsAndIndependentExternalChanges() throws {
        let name = "FoundationPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = FoundationPlaybackPreferences(defaults: defaults)
        XCTAssertTrue(preferences.allowsCellularStreaming)
        XCTAssertFalse(preferences.allowsCellularDownloads)
        preferences.setAllowsCellularDownloads(true)
        XCTAssertTrue(preferences.allowsCellularStreaming)
        defaults.set(false, forKey: FoundationPlaybackPreferences.streamingCellularKey)
        preferences.refresh()
        XCTAssertFalse(preferences.allowsCellularStreaming)
        XCTAssertTrue(preferences.allowsCellularDownloads)
        preferences.setAllowsCellularDownloads(false)
        let restored = FoundationPlaybackPreferences(defaults: defaults)
        XCTAssertFalse(restored.allowsCellularStreaming)
        XCTAssertFalse(restored.allowsCellularDownloads)
    }

    func testStreamingProfilesMigrateValidLegacyWithoutChangingItsValue() throws {
        let name = "FoundationStreamingMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for quality in FoundationStreamingQuality.allCases {
            defaults.removePersistentDomain(forName: name)
            defaults.set(
                quality.rawValue, forKey: FoundationPlaybackPreferences.streamingQualityKey)
            let preferences = FoundationPlaybackPreferences(defaults: defaults)
            XCTAssertEqual(preferences.streamingWiFiQuality, quality)
            XCTAssertEqual(preferences.streamingCellularQuality, quality)
            XCTAssertEqual(
                defaults.string(forKey: FoundationPlaybackPreferences.streamingQualityKey),
                quality.rawValue)
            preferences.setStreamingWiFiQuality(.aac128)
            XCTAssertEqual(preferences.streamingCellularQuality, quality)
            let restored = FoundationPlaybackPreferences(defaults: defaults)
            XCTAssertEqual(restored.streamingWiFiQuality, .aac128)
            XCTAssertEqual(restored.streamingCellularQuality, quality)
        }
    }

    func testStreamingProfilesPreserveNewValuesAndUseDeterministicFallbacks() throws {
        let name = "FoundationStreamingProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for legacy in ["", "invalid", "hlsAAC"] {
            defaults.removePersistentDomain(forName: name)
            defaults.set(legacy, forKey: FoundationPlaybackPreferences.streamingQualityKey)
            let fresh = FoundationPlaybackPreferences(defaults: defaults)
            XCTAssertEqual(fresh.streamingWiFiQuality, .original)
            XCTAssertEqual(fresh.streamingCellularQuality, .auto)
        }
        defaults.removePersistentDomain(forName: name)
        defaults.set("aac192", forKey: FoundationPlaybackPreferences.streamingQualityKey)
        defaults.set("aac320", forKey: FoundationPlaybackPreferences.streamingWiFiQualityKey)
        let preferences = FoundationPlaybackPreferences(defaults: defaults)
        XCTAssertEqual(preferences.streamingWiFiQuality, .aac320)
        XCTAssertEqual(preferences.streamingCellularQuality, .aac192)
        defaults.set("original", forKey: FoundationPlaybackPreferences.streamingQualityKey)
        preferences.refresh()
        XCTAssertEqual(preferences.streamingWiFiQuality, .aac320)
        XCTAssertEqual(preferences.streamingCellularQuality, .aac192)
        defaults.set("invalid", forKey: FoundationPlaybackPreferences.streamingWiFiQualityKey)
        defaults.set("invalid", forKey: FoundationPlaybackPreferences.streamingCellularQualityKey)
        preferences.refresh()
        XCTAssertEqual(preferences.streamingWiFiQuality, .original)
        XCTAssertEqual(preferences.streamingCellularQuality, .auto)
        let restored = FoundationPlaybackPreferences(defaults: defaults)
        XCTAssertEqual(restored.streamingWiFiQuality, .original)
        XCTAssertEqual(restored.streamingCellularQuality, .auto)
        XCTAssertTrue(preferences.allowsCellularStreaming)
        XCTAssertFalse(preferences.allowsCellularDownloads)
    }

    func testAutoUsesExistingPathSnapshotAndIndependentConnectionProfiles() throws {
        let name = "FoundationAutoQualityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = FoundationPlaybackPreferences(defaults: defaults)
        let connectivity = FoundationConnectivity(monitorConnectivity: false, retry: {})
        defer { connectivity.invalidate() }
        let unknown = connectivity.streamingPath
        XCTAssertEqual(preferences.resolvedStreamingProfile(for: unknown), .aac192)
        connectivity.update(status: .available, wifiOrWired: true, cellular: false)
        let unmetered = connectivity.streamingPath
        XCTAssertEqual(preferences.resolvedStreamingProfile(for: unmetered), .original)
        preferences.setStreamingWiFiQuality(.auto)
        connectivity.update(
            status: .available, wifiOrWired: true, cellular: false, expensive: true)
        XCTAssertEqual(
            preferences.resolvedStreamingProfile(for: connectivity.streamingPath), .aac192)
        connectivity.update(
            status: .available, wifiOrWired: true, cellular: false, constrained: true)
        XCTAssertEqual(
            preferences.resolvedStreamingProfile(for: connectivity.streamingPath), .aac128)
        XCTAssertEqual(FoundationStreamingQuality.auto.resolved(for: unmetered), .original)
        preferences.setStreamingWiFiQuality(.aac320)
        preferences.setStreamingCellularQuality(.aac128)
        XCTAssertEqual(preferences.resolvedStreamingProfile(for: unmetered), .aac320)
        XCTAssertEqual(preferences.resolvedStreamingProfile(for: unknown), .aac128)
        connectivity.update(status: .available, wifiOrWired: true, cellular: true)
        XCTAssertEqual(
            preferences.resolvedStreamingProfile(for: connectivity.streamingPath), .aac128)
        connectivity.update(status: .connecting, wifiOrWired: true, cellular: false)
        XCTAssertEqual(
            preferences.resolvedStreamingProfile(for: connectivity.streamingPath), .aac128)
        connectivity.update(status: .available, wifiOrWired: false, cellular: true)
        XCTAssertEqual(
            preferences.resolvedStreamingProfile(for: connectivity.streamingPath), .aac128)
        for quality in FoundationStreamingQuality.allCases {
            preferences.setStreamingWiFiQuality(quality)
            preferences.setStreamingCellularQuality(quality)
            XCTAssertEqual(
                preferences.resolvedStreamingProfile(for: unmetered),
                quality.resolved(for: unmetered))
            XCTAssertEqual(
                preferences.resolvedStreamingProfile(for: unknown), quality.resolved(for: unknown))
            let restored = FoundationPlaybackPreferences(defaults: defaults)
            XCTAssertEqual(restored.streamingWiFiQuality, quality)
            XCTAssertEqual(restored.streamingCellularQuality, quality)
        }
    }

    func testExternalStreamingSettingsRefreshKeepsProfilesIndependent() throws {
        let name = "FoundationExternalStreamingSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("aac192", forKey: FoundationPlaybackPreferences.streamingQualityKey)
        let preferences = FoundationPlaybackPreferences(defaults: defaults)
        defaults.set("auto", forKey: FoundationPlaybackPreferences.streamingWiFiQualityKey)
        preferences.refresh()
        XCTAssertEqual(preferences.streamingWiFiQuality, .auto)
        XCTAssertEqual(preferences.streamingCellularQuality, .aac192)
        defaults.set("aac128", forKey: FoundationPlaybackPreferences.streamingCellularQualityKey)
        preferences.refresh()
        XCTAssertEqual(preferences.streamingWiFiQuality, .auto)
        XCTAssertEqual(preferences.streamingCellularQuality, .aac128)
        let restored = FoundationPlaybackPreferences(defaults: defaults)
        XCTAssertEqual(restored.streamingWiFiQuality, .auto)
        XCTAssertEqual(restored.streamingCellularQuality, .aac128)
        XCTAssertEqual(
            defaults.string(forKey: FoundationPlaybackPreferences.streamingQualityKey), "aac192")
        preferences.refresh()
        XCTAssertEqual(preferences.streamingWiFiQuality, .auto)
        XCTAssertEqual(preferences.streamingCellularQuality, .aac128)
    }

    func testProductionStreamingQualityHonorsPlatformBoundary() throws {
        let name = "FoundationProductionQualityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = FoundationPlaybackPreferences(defaults: defaults)
        let wifi = FoundationStreamingPath(isAvailable: true, usesWiFiOrWired: true)
        let cellular = FoundationStreamingPath(isAvailable: true, usesCellular: true)
        for quality in [FoundationStreamingQuality.auto, .aac128] {
            preferences.setStreamingWiFiQuality(quality)
            preferences.setStreamingCellularQuality(quality)
            #if os(macOS)
                XCTAssertEqual(preferences.resolvedStreamingQuality(for: wifi), .original)
                XCTAssertEqual(preferences.resolvedStreamingQuality(for: cellular), .original)
            #else
                XCTAssertEqual(
                    preferences.resolvedStreamingQuality(for: wifi), quality.resolved(for: wifi))
                XCTAssertEqual(
                    preferences.resolvedStreamingQuality(for: cellular),
                    quality.resolved(for: cellular))
            #endif
        }
    }

    func testAutoCostObservationDoesNotDiscardSuccessfulExplicitRetry() async {
        let started = expectation(description: "explicit retry started")
        let (release, continuation) = AsyncStream<Void>.makeStream()
        let connectivity = FoundationConnectivity(monitorConnectivity: false) {
            started.fulfill()
            for await _ in release { break }
        }
        connectivity.update(status: .available, wifiOrWired: true, cellular: false)
        let retry = Task { await connectivity.retryOnline() }
        await fulfillment(of: [started], timeout: 2)
        connectivity.update(
            status: .available, wifiOrWired: true, cellular: false,
            expensive: true, constrained: true)
        XCTAssertEqual(
            FoundationStreamingQuality.auto.resolved(for: connectivity.streamingPath), .aac128)
        continuation.yield(())
        continuation.finish()
        await retry.value
        XCTAssertEqual(connectivity.successfulRetryRevision, 1)
        XCTAssertFalse(connectivity.isRetrying)
        connectivity.invalidate()
        XCTAssertEqual(connectivity.streamingPath, FoundationStreamingPath())
    }

    func testAdvisoryUnavailablePathAllowsSuccessfulExplicitRetryOverride() async {
        let connectivity = FoundationConnectivity(
            monitorConnectivity: false, settleDuration: .zero, retry: {})
        connectivity.update(status: .unavailable, wifiOrWired: false, cellular: false)
        let offline = expectation(description: "settled unavailable")
        let subscription = connectivity.$localOnly.filter { $0 }.prefix(1).sink { _ in
            offline.fulfill()
        }
        await fulfillment(of: [offline], timeout: 2)
        XCTAssertTrue(connectivity.localOnly)
        await connectivity.retryOnline()
        XCTAssertFalse(connectivity.localOnly)
        XCTAssertTrue(connectivity.isConnected)
        // An identical stale observation must not defeat a real request success.
        connectivity.update(status: .unavailable, wifiOrWired: false, cellular: false)
        XCTAssertFalse(connectivity.localOnly)
        withExtendedLifetime(subscription) {}
        connectivity.invalidate()
    }

    func testRequiresConnectionAndServerFailureNeverClaimRadioDisconnection() async {
        let connectivity = FoundationConnectivity(monitorConnectivity: false) {
            throw URLError(.timedOut)
        }
        connectivity.update(status: .connecting, wifiOrWired: false, cellular: false)
        XCTAssertFalse(connectivity.localOnly)
        connectivity.update(status: .available, wifiOrWired: true, cellular: false)
        await connectivity.retryOnline()
        XCTAssertFalse(connectivity.localOnly)
        XCTAssertTrue(connectivity.isConnected)
        XCTAssertEqual(
            connectivity.statusMessage,
            "Server unavailable. Downloaded music is in Library.")
        connectivity.invalidate()
    }

    func testRestoredPathCancelsPendingOfflineTransition() async {
        let connectivity = FoundationConnectivity(
            monitorConnectivity: false, settleDuration: .milliseconds(10), retry: {})
        connectivity.update(status: .unavailable, wifiOrWired: false, cellular: false)
        connectivity.update(status: .available, wifiOrWired: false, cellular: true)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(connectivity.localOnly)
        XCTAssertTrue(connectivity.isConnected)
        XCTAssertTrue(connectivity.usesCellular)
        connectivity.invalidate()
    }
    func testExplicitRetryRefreshesContentEvenWhilePathRemainsAvailable() async {
        let connectivity = FoundationConnectivity(monitorConnectivity: false, retry: {})
        connectivity.update(status: .available, wifiOrWired: true, cellular: false)
        XCTAssertFalse(connectivity.hasConnectionIssue)
        await connectivity.retryOnline()
        XCTAssertEqual(connectivity.successfulRetryRevision, 1)
        await connectivity.retryOnline()
        XCTAssertEqual(connectivity.successfulRetryRevision, 2)
        XCTAssertFalse(connectivity.hasConnectionIssue)
        connectivity.invalidate()
    }

    func testFailedAndCancelledRetryDoNotSignalContentRefresh() async {
        let failed = FoundationConnectivity(monitorConnectivity: false) {
            throw URLError(.notConnectedToInternet)
        }
        failed.update(status: .available, wifiOrWired: true, cellular: false)
        await failed.retryOnline()
        XCTAssertTrue(failed.hasConnectionIssue)
        XCTAssertEqual(failed.successfulRetryRevision, 0)
        XCTAssertFalse(failed.localOnly)
        let cancelled = FoundationConnectivity(monitorConnectivity: false) {
            throw CancellationError()
        }
        cancelled.update(status: .available, wifiOrWired: true, cellular: false)
        await cancelled.retryOnline()
        XCTAssertFalse(cancelled.hasConnectionIssue)
        XCTAssertEqual(cancelled.successfulRetryRevision, 0)
        failed.invalidate()
        cancelled.invalidate()
    }

}
