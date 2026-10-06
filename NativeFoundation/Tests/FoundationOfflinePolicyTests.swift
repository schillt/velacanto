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
            "The server could not be reached. Downloaded music remains available.")
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
}
