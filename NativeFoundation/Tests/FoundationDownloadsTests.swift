import Foundation
import ImageIO
import QuartzCore
import SwiftUI
import XCTest

@testable import VelacantoFoundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@MainActor
final class FoundationDownloadsTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func item(_ id: String, kind: FoundationItem.Kind = .track) -> FoundationItem {
        FoundationItem(id: id, title: "Synthetic", subtitle: "Fixture", kind: kind, duration: 1)
    }

    private func waitUntil(
        timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Download state did not settle before the deadline")
    }

    private func waitUntilAsync(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let settled = await condition()
        XCTAssertTrue(settled, "Download work did not settle before the deadline")
    }

    private func artworkData(width: Int = 1024, height: Int = 512) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func artworkTrack(_ id: String, tag: String = "first") -> FoundationItem {
        var track = item(id)
        track.album = .init(id: "album", title: "Synthetic album", primaryImageTag: tag)
        return track
    }

    private var transfer: FoundationDownloads.Transfer {
        { _, destination, _, progress in
            try Data("synthetic audio".utf8).write(to: destination)
            progress(15, 15)
        }
    }

    func testDownloadQualityPreferenceDefaultsPersistsAndRejectsUnknownValues() throws {
        let name = "DownloadQuality-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = FoundationPlaybackPreferences(defaults: defaults)
        XCTAssertEqual(preferences.downloadQuality, .original)
        for quality in FoundationDownloadQuality.allCases {
            preferences.setDownloadQuality(quality)
            XCTAssertEqual(
                FoundationPlaybackPreferences(defaults: defaults).downloadQuality, quality)
        }
        defaults.set("future-value", forKey: FoundationPlaybackPreferences.downloadQualityKey)
        preferences.refresh()
        XCTAssertEqual(preferences.downloadQuality, .original)
        XCTAssertTrue(preferences.allowsCellularStreaming)
    }

    func testSystemManagementPreferenceDefaultsOffAndSnapshotsOnlyNewOwners() throws {
        let name = "SystemDownloadManagement-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = FoundationPlaybackPreferences(defaults: defaults)
        XCTAssertFalse(preferences.systemManagedDownloads)
        let downloadRoot = try root()
        let library = DownloadsLibrary(tracks: [item("one"), item("two")])
        let downloads = FoundationDownloads(
            scope: "management-intent", library: library, root: downloadRoot,
            transfer: transfer, monitorConnectivity: false,
            systemManagedDownloads: { preferences.systemManagedDownloads })
        downloads.download(item("one"))
        preferences.setSystemManagedDownloads(true)
        downloads.download(item("two"))
        XCTAssertEqual(downloads.owners.map(\.systemManaged), [false, true])
        preferences.setSystemManagedDownloads(false)
        downloads.retry(ownerID: "track:two")
        XCTAssertEqual(downloads.owners.map(\.systemManaged), [false, true])
        let persisted = try FoundationDownloadStorage.load(
            directory: FoundationDownloadStorage.directory(
                scope: "management-intent", root: downloadRoot))
        XCTAssertNil(persisted.owners[0].systemManaged)
        XCTAssertEqual(persisted.owners[1].systemManaged, true)
        XCTAssertFalse(FoundationPlaybackPreferences(defaults: defaults).systemManagedDownloads)
        downloads.invalidate()
    }

    func testSystemManagedOriginalRejectsWithoutProgressiveOrNativeFallback() async throws {
        let track = item("original-no-substitution")
        let downloads = FoundationDownloads(
            scope: "native-original", library: DownloadsLibrary(tracks: [track]), root: try root(),
            transfer: { _, _, _, _ in XCTFail("No progressive fallback") },
            monitorConnectivity: false,
            systemManagedDownloads: { true },
            nativeTransfer: { _, _, _, _ in
                XCTFail("Original must not enter the HLS transport")
                throw FoundationDownloadError.response
            })
        downloads.download(track)
        downloads.updateConnectivity(isConnected: true, usesWiFi: true)
        try await waitUntil { downloads.owners.first?.state == .failed }
        XCTAssertFalse(downloads.isReady(track))
        XCTAssertEqual(
            downloads.errorMessage,
            FoundationDownloadError.originalSystemManagementUnavailable.errorDescription)
        downloads.invalidate()
    }

    func testPrivateReceiptBindingRejectsCopiedContentAtWrongResource() throws {
        let directory = try root()
        try FoundationDownloadStorage.prepare(directory)
        let identifier =
            "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
            + UUID().uuidString
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: identifier)
        try store.reserve(taskIdentifier: 1)
        let copiedDirectory = try root()
        let copied = copiedDirectory.appendingPathComponent(store.receiptURL.lastPathComponent)
        try FileManager.default.copyItem(at: store.receiptURL, to: copied)
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: store.receiptURL))
        let identity = FoundationManagedPackageMetadata.comparison(
            try FoundationManagedPackageMetadata.resources(store.receiptURL),
            try FoundationManagedPackageMetadata.resources(copied))
        XCTAssertEqual(identity.file, .different)
        XCTAssertThrowsError(
            try FoundationNativeAllocationStore.existingReceipt(at: copied, directory: directory))
        let linkedDirectory = try root()
        let linked = linkedDirectory.appendingPathComponent(store.receiptURL.lastPathComponent)
        try FileManager.default.linkItem(at: store.receiptURL, to: linked)
        let linkedIdentity = FoundationManagedPackageMetadata.comparison(
            try FoundationManagedPackageMetadata.resources(store.receiptURL),
            try FoundationManagedPackageMetadata.resources(linked))
        XCTAssertEqual(linkedIdentity.file, .equal)
        XCTAssertEqual(linkedIdentity.volume, .equal)
        XCTAssertThrowsError(
            try FoundationNativeAllocationStore.existingReceipt(at: linked, directory: directory))
        let wrongName = directory.appendingPathComponent("native-receipt-wrong-hash.json")
        try FileManager.default.copyItem(at: store.receiptURL, to: wrongName)
        XCTAssertEqual(try Data(contentsOf: wrongName), try Data(contentsOf: store.receiptURL))
        XCTAssertThrowsError(
            try FoundationNativeAllocationStore.existingReceipt(at: wrongName, directory: directory)
        )
        XCTAssertNoThrow(
            try FoundationNativeAllocationStore.existingReceipt(
                at: store.receiptURL, directory: directory))
        // Rejected copies must not retire the owned receipt.
        XCTAssertNil(try store.load().retired)
    }

    func testQuarantineThenSuccessfulRemoveAllAllowsSameIDNewDownload() async throws {
        try await checkQuarantineRemovalAndNewAcquisition(holdingOtherLease: false)
    }

    func testQuarantineRemovalPreservesLeaseAndClearsOnlyProvedRetiredResource() async throws {
        try await checkQuarantineRemovalAndNewAcquisition(holdingOtherLease: true)
    }

    private func checkQuarantineRemovalAndNewAcquisition(holdingOtherLease: Bool) async throws {
        let storageRoot = try root()
        let scope = "remove-all-quarantine"
        let directory = FoundationDownloadStorage.directory(scope: scope, root: storageRoot)
        try FoundationDownloadStorage.prepare(directory)
        let track = item("same-id")
        let playing = item("leased-other-id")
        let oldFileURL = directory.appendingPathComponent("leased.mp3")
        let bytes = Data("synthetic retained audio".utf8)
        try bytes.write(to: oldFileURL)
        try FoundationDownloadStorage.protect(oldFileURL)
        var manifest = FoundationDownloadManifest()
        manifest.owners = [track, playing].map { item in
            .init(
                id: "track:" + item.id, item: FoundationStoredDownloadItem(item),
                tracks: [FoundationStoredDownloadItem(item)], paused: false, expanded: true)
        }
        manifest.files[playing.id] = .init(
            name: "leased.mp3", bytes: Int64(bytes.count),
            digest: try FoundationDownloadStorage.digest(oldFileURL))
        manifest.files[track.id] = .init(
            name: "native.movpkg", bytes: 1, digest: "",
            nativePackage:
                .init(
                    nativeURL: directory.appendingPathComponent("issued.movpkg"),
                    bookmark: Data("unverified identity".utf8), sessionIdentifier: "synthetic"))
        try FoundationDownloadStorage.save(manifest, directory: directory)
        let resolution = NativeDownloadVerificationFixture()
        let transfers = NativeDownloadVerificationFixture()
        let manager = FoundationDownloads(
            scope: scope, library: DownloadsLibrary(tracks: [track, playing]), root: storageRoot,
            transfer: { _, destination, _, progress in
                transfers.recordVerification()
                try bytes.write(to: destination)
                progress(Int64(bytes.count), Int64(bytes.count))
            }, monitorConnectivity: false,
            nativeResolution: { _, _ in resolution.available ? .provenMissing : .unverifiable },
            verifyInventoryFiles: { files, _ in files.filter { $0.value.nativePackage == nil } })
        try await waitUntil { !manager.isLoading }
        XCTAssertFalse(manager.isReady(track))
        var lease: FoundationPlaybackResource?
        if holdingOtherLease {
            lease = try await manager.playbackResource(for: playing, allowsRemoteFallback: false)
        }
        let failedRemoval = await manager.removeAll()
        XCTAssertFalse(failedRemoval)
        XCTAssertNotNil(try FoundationDownloadStorage.load(directory: directory).files[track.id])
        XCTAssertFalse(
            try FoundationDownloadStorage.load(directory: directory).excludedTrackIDs?.contains(
                track.id) == true)
        XCTAssertEqual(transfers.verifications, 0)
        if holdingOtherLease {
            XCTAssertTrue(FileManager.default.fileExists(atPath: oldFileURL.path))
            manager.download(track)
            manager.updateConnectivity(isAllowed: true)
            try await waitUntil {
                manager.owners.first(where: { $0.item.id == track.id })?.state == .failed
            }
            // Failed cleanup must retain the quarantine.
            XCTAssertEqual(transfers.verifications, 0)
        }
        // Fixture now supplies affirmative proof of prior allocation absence.
        resolution.makeAvailable()
        let removed = await manager.removeAll()
        XCTAssertTrue(removed)
        XCTAssertNil(try FoundationDownloadStorage.load(directory: directory).files[track.id])
        if holdingOtherLease {
            XCTAssertTrue(FileManager.default.fileExists(atPath: oldFileURL.path))
        }
        manager.download(track)
        manager.updateConnectivity(isAllowed: true)
        try await waitUntil { manager.isReady(track) }
        // Prove a fresh acquisition, rather than a stale ready flag/file.
        XCTAssertEqual(transfers.verifications, 1)
        let saved = try FoundationDownloadStorage.load(directory: directory)
        XCTAssertNil(saved.files[track.id]?.nativePackage)
        XCTAssertFalse(saved.excludedTrackIDs?.contains(track.id) == true)
        if let lease {
            await lease.release()
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldFileURL.path))
            XCTAssertTrue(manager.isReady(track))
        }
        manager.invalidate()
    }

    private enum RemovalRecoveryFailure: Sendable { case none, verification, publication }

    private func removalFailureFixture(
        failure: RemovalRecoveryFailure = .none, pendingNative: Bool = true,
        recoveryGate: DownloadGate? = nil
    ) async throws -> (
        manager: FoundationDownloads, directory: URL, storageRoot: URL,
        good: FoundationItem, unknown: FoundationItem, file: URL,
        store: FoundationNativeAllocationStore, checks: NativeDownloadVerificationFixture,
        transfers: NativeDownloadVerificationFixture, retirements: NativeDownloadVerificationFixture
    ) {
        let storageRoot = try root()
        let scope = "remove-failure"
        let directory = FoundationDownloadStorage.directory(scope: scope, root: storageRoot)
        try FoundationDownloadStorage.prepare(directory)
        let good = item("verified-survivor")
        let unknown = item("unknown-native")
        let bytes = Data([1, 2, 3])
        let file = directory.appendingPathComponent("verified.mp3")
        try bytes.write(to: file)
        try FoundationDownloadStorage.protect(file)
        let store = FoundationNativeAllocationStore(
            directory: directory,
            sessionIdentifier: "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                + "." + UUID().uuidString,
            trackID: unknown.id)
        if pendingNative {
            try store.reserve(taskIdentifier: 1)
            try store.beginResuming(taskIdentifier: 1)
        }
        var manifest = FoundationDownloadManifest()
        manifest.owners = [good, unknown].map {
            .init(
                id: "track:" + $0.id, item: FoundationStoredDownloadItem($0),
                tracks: [FoundationStoredDownloadItem($0)], paused: $0.id == unknown.id,
                expanded: true)
        }
        manifest.files[good.id] = .init(
            name: file.lastPathComponent, bytes: 3,
            digest: try FoundationDownloadStorage.digest(file))
        manifest.nativePendingSessions = pendingNative ? [store.sessionIdentifier] : nil
        try FoundationDownloadStorage.save(manifest, directory: directory)
        let checks = NativeDownloadVerificationFixture()
        let transfers = NativeDownloadVerificationFixture()
        let retirements = NativeDownloadVerificationFixture()
        let manager = FoundationDownloads(
            scope: scope, library: DownloadsLibrary(tracks: [good, unknown]), root: storageRoot,
            transfer: { _, destination, _, _ in
                transfers.recordVerification()
                try bytes.write(to: destination)
            },
            monitorConnectivity: false,
            nativeRetirement: { _, _ in
                retirements.recordVerification()
                return []
            },
            verifyInventoryFiles: { files, directory in
                checks.recordVerification()
                if checks.verifications == 3, let recoveryGate { await recoveryGate.wait() }
                if checks.verifications > 2 {
                    switch failure {
                    case .verification: throw CocoaError(.fileReadNoPermission)
                    case .publication:
                        if !files.isEmpty {
                            let manifest = directory.appendingPathComponent("manifest.json")
                            try FileManager.default.removeItem(at: manifest)
                            try FileManager.default.createDirectory(
                                at: manifest, withIntermediateDirectories: false)
                        }
                    case .none: break
                    }
                }
                return try await FoundationDownloadStorage.verifiedFiles(
                    files, directory: directory)
            })
        try await waitUntil { !manager.isLoading }
        XCTAssertTrue(manager.isReady(good))
        XCTAssertFalse(manager.isReady(unknown))
        return (
            manager, directory, storageRoot, good, unknown, file, store, checks, transfers,
            retirements
        )
    }

    func testFailedRemoveAllReverifiesUnrelatedFileAndPersistsPausedIntentAcrossRelaunch()
        async throws
    {
        let fixture = try await removalFailureFixture()
        let receipt = try Data(contentsOf: fixture.store.receiptURL)
        let removed = await fixture.manager.removeAll()
        XCTAssertFalse(removed)
        XCTAssertTrue(fixture.manager.isReady(fixture.good))
        XCTAssertFalse(fixture.manager.isReady(fixture.unknown))
        // One files/artwork pass before and after failure.
        XCTAssertEqual(fixture.checks.verifications, 4)
        XCTAssertEqual(try Data(contentsOf: fixture.store.receiptURL), receipt)
        let saved = try FoundationDownloadStorage.load(directory: fixture.directory)
        XCTAssertTrue(saved.owners.allSatisfy(\.paused))
        XCTAssertTrue(
            saved.nativePendingSessions?.contains(fixture.store.sessionIdentifier) == true)
        fixture.manager.updateConnectivity(isAllowed: true)
        await Task.yield()
        XCTAssertEqual(fixture.transfers.verifications, 0)
        fixture.manager.invalidate()
        let relaunched = FoundationDownloads(
            scope: "remove-failure",
            library: DownloadsLibrary(tracks: [fixture.good, fixture.unknown]),
            root: fixture.storageRoot,
            transfer: { _, _, _, _ in XCTFail("Removal intent silently reacquired music") },
            monitorConnectivity: false, nativeRetirement: { _, _ in [] })
        try await waitUntil { !relaunched.isLoading }
        relaunched.updateConnectivity(isAllowed: true)
        await Task.yield()
        XCTAssertTrue(relaunched.isReady(fixture.good))
        XCTAssertTrue(relaunched.owners.allSatisfy { $0.state == .cancelled })
        relaunched.invalidate()
    }

    func testFailedRemoveAllDoesNotReenableBeforeRecoveryVerificationAndPublication() async throws {
        for failure in [RemovalRecoveryFailure.verification, .publication] {
            let fixture = try await removalFailureFixture(failure: failure)
            let before = try Data(contentsOf: fixture.store.receiptURL)
            let removed = await fixture.manager.removeAll()
            XCTAssertFalse(removed)
            XCTAssertFalse(fixture.manager.isReady(fixture.good))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
            XCTAssertEqual(try Data(contentsOf: fixture.store.receiptURL), before)
            let oldOwners = fixture.manager.owners.map(\.id)
            fixture.manager.download(item("must-not-start"))
            fixture.manager.updateConnectivity(isAllowed: true)
            await Task.yield()
            XCTAssertEqual(fixture.manager.owners.map(\.id), oldOwners)
            XCTAssertEqual(fixture.transfers.verifications, 0)
            fixture.manager.invalidate()
        }
    }

    func testLeasedRemoveAllReportsPendingNativeFailureAndPreservesLeaseUntilRelease() async throws
    {
        let fixture = try await removalFailureFixture()
        let receipt = try Data(contentsOf: fixture.store.receiptURL)
        let lease = try await fixture.manager.playbackResource(
            for: fixture.good, allowsRemoteFallback: false)
        let removed = await fixture.manager.removeAll()
        XCTAssertFalse(removed)
        XCTAssertNotNil(fixture.manager.errorMessage)
        XCTAssertTrue(fixture.manager.owners.isEmpty)
        XCTAssertFalse(fixture.manager.isReady(fixture.good))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.url.path))
        XCTAssertEqual(try Data(contentsOf: fixture.store.receiptURL), receipt)
        await lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.url.path))
        XCTAssertEqual(try Data(contentsOf: fixture.store.receiptURL), receipt)
        XCTAssertTrue(
            try FoundationDownloadStorage.load(directory: fixture.directory).nativePendingSessions?
                .contains(fixture.store.sessionIdentifier) == true)
        fixture.manager.invalidate()
    }

    func testLeaseReleasedDuringRemovalRecoveryDeletesOnlyVerifiedPendingFileAfterPublication()
        async throws
    {
        let gate = DownloadGate()
        let fixture = try await removalFailureFixture(recoveryGate: gate)
        let receipt = try Data(contentsOf: fixture.store.receiptURL)
        let lease = try await fixture.manager.playbackResource(
            for: fixture.good, allowsRemoteFallback: false)
        let removal = Task { await fixture.manager.removeAll() }
        try await waitUntilAsync { await gate.started }
        XCTAssertTrue(fixture.manager.isLoading)
        await lease.release()
        // The loading guard defers cleanup until verification/publication completes.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertEqual(try Data(contentsOf: fixture.store.receiptURL), receipt)
        await gate.resume()
        let removed = await removal.value
        XCTAssertFalse(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        let saved = try FoundationDownloadStorage.load(directory: fixture.directory)
        XCTAssertNil(saved.files[fixture.good.id])
        XCTAssertTrue(
            saved.nativePendingSessions?.contains(fixture.store.sessionIdentifier) == true)
        XCTAssertEqual(try Data(contentsOf: fixture.store.receiptURL), receipt)
        XCTAssertEqual(fixture.transfers.verifications, 0)
        XCTAssertEqual(fixture.checks.verifications, 4)
        XCTAssertFalse(fixture.manager.isReady(fixture.good))
        fixture.manager.invalidate()
    }

    func testHealthyLeasedRemoveAllStillSucceedsAndDeletesOnlyAfterRelease() async throws {
        let fixture = try await removalFailureFixture(pendingNative: false)
        let lease = try await fixture.manager.playbackResource(
            for: fixture.good, allowsRemoteFallback: false)
        let removed = await fixture.manager.removeAll()
        XCTAssertTrue(removed)
        XCTAssertTrue(fixture.manager.owners.isEmpty)
        XCTAssertNil(fixture.manager.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.url.path))
        XCTAssertEqual(fixture.checks.verifications, 2)
        XCTAssertFalse(fixture.manager.isReady(fixture.good))
        await lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.url.path))
        fixture.manager.invalidate()
    }

    func testRemoveAllPauseSaveFailureAbortsBeforeDestructionOrRecovery() async throws {
        let fixture = try await removalFailureFixture()
        let manifest = fixture.directory.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        let receipt = try Data(contentsOf: fixture.store.receiptURL)
        let retirementsBefore = fixture.retirements.verifications
        let removed = await fixture.manager.removeAll()
        XCTAssertFalse(removed)
        XCTAssertEqual(fixture.retirements.verifications, retirementsBefore)
        XCTAssertEqual(fixture.checks.verifications, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertEqual(try Data(contentsOf: fixture.store.receiptURL), receipt)
        XCTAssertTrue(fixture.manager.isReady(fixture.good))
        fixture.manager.updateConnectivity(isAllowed: true)
        await Task.yield()
        XCTAssertEqual(fixture.transfers.verifications, 0)
        fixture.manager.invalidate()
    }

    func testRemoveAllWithUnreadableManifestCannotEnableStorageThroughFailureRecovery() async throws
    {
        let storageRoot = try root()
        let directory = FoundationDownloadStorage.directory(
            scope: "unreadable-removal", root: storageRoot)
        try FoundationDownloadStorage.prepare(directory)
        let manifest = directory.appendingPathComponent("manifest.json")
        let corrupt = Data("not a manifest".utf8)
        try corrupt.write(to: manifest)
        let store = FoundationNativeAllocationStore(
            directory: directory,
            sessionIdentifier: "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                + "." + UUID().uuidString)
        try store.reserve(taskIdentifier: 1)
        try store.beginResuming(taskIdentifier: 1)
        let manager = FoundationDownloads(
            scope: "unreadable-removal", library: DownloadsLibrary(tracks: []), root: storageRoot,
            monitorConnectivity: false,
            verifyInventoryFiles: { _, _ in
                XCTFail("Unreadable account entered usable recovery")
                return [:]
            })
        let removed = await manager.removeAll()
        XCTAssertFalse(removed)
        manager.download(item("blocked"))
        XCTAssertTrue(manager.owners.isEmpty)
        XCTAssertEqual(try Data(contentsOf: manifest), corrupt)
        XCTAssertNil(try store.load().retired)
        manager.invalidate()
    }

    func testPartialNativeRemovalReconcilesMissingAndUnverifiableWithoutStaleReady() async throws {
        let storageRoot = try root()
        let scope = "partial-native-removal"
        let directory = FoundationDownloadStorage.directory(scope: scope, root: storageRoot)
        try FoundationDownloadStorage.prepare(directory)
        let tracks = [item("native-a"), item("native-b"), item("private-survivor")]
        var manifest = FoundationDownloadManifest()
        manifest.owners = tracks.map {
            .init(
                id: "track:" + $0.id, item: FoundationStoredDownloadItem($0),
                tracks: [FoundationStoredDownloadItem($0)], paused: false, expanded: true)
        }
        for track in tracks {
            let native = track.id.hasPrefix("native-")
            let url = directory.appendingPathComponent(track.id + (native ? ".movpkg" : ".mp3"))
            if native {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try Data([1, 2, 3]).write(to: url)
            }
            manifest.files[track.id] = .init(
                name: url.lastPathComponent, bytes: 3,
                digest: native ? "" : try FoundationDownloadStorage.digest(url),
                nativePackage: native
                    ? .init(
                        nativeURL: url, bookmark: Data("synthetic proof".utf8),
                        sessionIdentifier: track.id) : nil)
        }
        try FoundationDownloadStorage.save(manifest, directory: directory)
        let checks = NativeDownloadVerificationFixture()
        let nativeChecks = NativeDownloadVerificationFixture()
        let manager = FoundationDownloads(
            scope: scope, library: DownloadsLibrary(tracks: tracks), root: storageRoot,
            transfer: { _, _, _, _ in XCTFail("Failed removal reacquired music") },
            monitorConnectivity: false,
            nativeResolution: { package, _ in
                if !FileManager.default.fileExists(atPath: package.nativeURL.path) {
                    return .provenMissing
                }
                nativeChecks.recordVerification()
                return nativeChecks.verifications == 1
                    ? .available(package.nativeURL) : .unverifiable
            },
            verifyInventoryFiles: { files, _ in
                checks.recordVerification()
                return checks.verifications <= 2
                    ? files : files.filter { $0.value.nativePackage == nil }
            })
        try await waitUntil { !manager.isLoading }
        XCTAssertTrue(tracks.allSatisfy { manager.isReady($0) })
        let removed = await manager.removeAll()
        XCTAssertFalse(removed)
        XCTAssertTrue(manager.isReady(tracks[2]))
        XCTAssertFalse(manager.isReady(tracks[0]))
        XCTAssertFalse(manager.isReady(tracks[1]))
        let saved = try FoundationDownloadStorage.load(directory: directory)
        XCTAssertEqual(saved.files.values.filter { $0.nativePackage != nil }.count, 1)
        XCTAssertEqual(saved.excludedTrackIDs?.count, 1)
        XCTAssertTrue(saved.owners.allSatisfy(\.paused))
        manager.invalidate()
    }

    func testNativeProtectionStrengthensOnlyExplicitNoneWithSameCompletedProof() throws {
        let f = try NativeProtectionFixture()
        defer { f.remove() }
        let saved = f.package.bookmark
        f.classes[f.rootIdentity] = "NSFileProtectionNone"
        try f.strengthen()
        XCTAssertEqual(f.writes, [f.rootIdentity, f.leafIdentity])
        XCTAssertEqual(
            f.classes[f.leafIdentity], "NSFileProtectionCompleteUntilFirstUserAuthentication")
        XCTAssertEqual(f.package.bookmark, saved)
        XCTAssertEqual(try Data(contentsOf: f.leaf), Data([1, 2, 3]))
        XCTAssertGreaterThan(f.resolutions, 2)
    }

    func testNativeProtectionPreservesCompleteAndClassCWithoutSetter() throws {
        for protection in [
            "NSFileProtectionComplete", "NSFileProtectionCompleteUntilFirstUserAuthentication",
        ] {
            let f = try NativeProtectionFixture()
            defer { f.remove() }
            f.classes[f.leafIdentity] = protection
            // Directory B is preserved; regular-file policy is not extended to directories.
            f.classes[f.rootIdentity] = "NSFileProtectionCompleteUnlessOpen"
            try f.strengthen()
            XCTAssertTrue(f.writes.isEmpty)
            XCTAssertEqual(f.classes[f.leafIdentity], protection)
            XCTAssertEqual(f.classes[f.rootIdentity], "NSFileProtectionCompleteUnlessOpen")
        }
    }

    func testNativeProtectionNeverDowngradesOtherRegularClasses() throws {
        for protection in [
            "NSFileProtectionCompleteUnlessOpen", "NSFileProtectionCompleteWhenUserInactive",
            "unrecognized", "missing",
        ] {
            let f = try NativeProtectionFixture()
            defer { f.remove() }
            f.classes[f.leafIdentity] = protection == "missing" ? nil : protection
            XCTAssertThrowsError(try f.strengthen()) {
                XCTAssertEqual($0 as? FoundationDownloadError, .nativeProtection)
            }
            XCTAssertTrue(f.writes.isEmpty)
        }
    }

    func testNativeProtectionRejectsSymlinkAndReplacementBeforeOutsideWrite() throws {
        let f = try NativeProtectionFixture()
        defer { f.remove() }
        try FileManager.default.removeItem(at: f.leaf)
        try FileManager.default.createSymbolicLink(at: f.leaf, withDestinationURL: f.outside)
        XCTAssertThrowsError(try f.strengthen())
        XCTAssertTrue(f.writes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.outside), Data([9]))
        try FileManager.default.removeItem(at: f.leaf)
        try Data([1, 2, 3]).write(to: f.leaf)
        f.replaceBeforeWrite = true
        XCTAssertThrowsError(try f.strengthen())
        XCTAssertTrue(f.writes.isEmpty)
    }

    func testNativeProtectionRejectsIgnoredSetterAndPartialFailure() throws {
        for mode in [NativeProtectionFixture.Failure.ignored, .throwAfterWrite, .generation] {
            let f = try NativeProtectionFixture()
            defer { f.remove() }
            f.failure = mode
            let saved = f.package.bookmark
            XCTAssertThrowsError(try f.strengthen())
            XCTAssertEqual(f.writes.count, 1)
            XCTAssertEqual(f.package.bookmark, saved)
            XCTAssertEqual(try Data(contentsOf: f.leaf), Data([1, 2, 3]))
        }
    }

    func testNativeProtectionCancellationAfterPartialMutationCannotReturnSuccess() async throws {
        let f = try NativeProtectionFixture()
        defer { f.remove() }
        f.failure = .cancel
        let operation = Task { try f.strengthen() }
        do {
            try await operation.value
            XCTFail("Cancelled metadata pass succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(f.writes.count, 1)
        XCTAssertEqual(
            f.classes[f.leafIdentity], "NSFileProtectionCompleteUntilFirstUserAuthentication")
    }

    func testNativeProtectionRechecksChangedClassWithUnchangedResourceIdentity() throws {
        for changed in [
            "NSFileProtectionComplete", "NSFileProtectionCompleteUntilFirstUserAuthentication",
            "NSFileProtectionCompleteUnlessOpen",
        ] {
            let f = try NativeProtectionFixture()
            defer { f.remove() }
            f.classAtMutationGate = changed
            if changed == "NSFileProtectionCompleteUnlessOpen" {
                XCTAssertThrowsError(try f.strengthen()) {
                    XCTAssertEqual($0 as? FoundationDownloadError, .nativeProtection)
                }
            } else {
                try f.strengthen()
            }
            XCTAssertTrue(f.writes.isEmpty)
            XCTAssertEqual(f.classes[f.leafIdentity], changed)
            XCTAssertEqual(f.leafReads, changed == "NSFileProtectionCompleteUnlessOpen" ? 2 : 3)
        }
    }

    func testNativeProtectionAcceptsCompleteFreshReadbackWithoutRefreshingProof() throws {
        let f = try NativeProtectionFixture()
        defer { f.remove() }
        let proof = f.package.bookmark
        f.failure = .completeReadback
        try f.strengthen()
        XCTAssertEqual(f.writes, [f.leafIdentity])
        XCTAssertEqual(f.classes[f.leafIdentity], "NSFileProtectionComplete")
        XCTAssertEqual(f.package.bookmark, proof)
    }

    func testNativeProtectionChecksChangedAncestorBeforeFirstDescendantRead() throws {
        let f = try NativeProtectionFixture()
        defer { f.remove() }
        f.replaceRootAtResolution = 4  // The first descendant's proof gate.
        XCTAssertThrowsError(try f.strengthen())
        XCTAssertEqual(f.resolutions, 4)
        XCTAssertEqual(f.leafReads, 0)
        XCTAssertTrue(f.writes.isEmpty)
    }

    func testNativeProtectionTraversesRawAliasOnlyAfterSameResourceBinding() throws {
        let f = try NativeProtectionFixture(aliased: true)
        defer { f.remove() }
        XCTAssertNotEqual(f.root.path, f.rootIdentity)
        let proof = f.package.bookmark
        try f.strengthen()
        XCTAssertEqual(f.writes, [f.leafIdentity])
        XCTAssertEqual(
            f.classes[f.leafIdentity], "NSFileProtectionCompleteUntilFirstUserAuthentication")
        // Retain the raw authority, not the traversal address.
        XCTAssertEqual(f.package.nativeURL, f.root)
        XCTAssertEqual(f.package.bookmark, proof)
        XCTAssertGreaterThan(f.leafReads, 0)
    }

    func testNativeProtectionRejectsCanonicalAddressIdentityMismatchBeforeTargetRead() throws {
        let f = try NativeProtectionFixture(aliased: true)
        defer { f.remove() }
        XCTAssertNotEqual(f.root.path, f.rootIdentity)
        f.mismatchCanonicalRoot = true
        XCTAssertThrowsError(try f.strengthen()) {
            XCTAssertEqual($0 as? FoundationDownloadError, .nativeProtection)
        }
        XCTAssertEqual(f.leafReads, 0)
        XCTAssertTrue(f.writes.isEmpty)
    }

    func testNativeProtectionPartialFailureNeverPublishesManagerReady() async throws {
        let f = try NativeProtectionFixture()
        defer { f.remove() }
        f.failure = .ignored
        let track = item("protection-failure")
        let storageRoot = try root()
        let scope = "protection-failure"
        let manager = FoundationDownloads(
            scope: scope, library: DownloadsLibrary(tracks: [track]), root: storageRoot,
            monitorConnectivity: false, requestedQuality: { .aac192 },
            systemManagedDownloads: { true },
            nativeTransfer: { _, _, _, _ in
                try f.strengthen()
                XCTFail("Ignored protection setter returned success")
                return .init(name: "never-ready.movpkg", bytes: 1, digest: "")
            })
        defer { manager.invalidate() }
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .failed }
        XCTAssertEqual(f.writes.count, 1)
        XCTAssertFalse(manager.isReady(track))
        let saved = try FoundationDownloadStorage.load(
            directory: FoundationDownloadStorage.directory(scope: scope, root: storageRoot))
        XCTAssertNil(saved.files[track.id])
        XCTAssertEqual(saved.owners.first?.paused, true)
    }

    private func firstCompletionFixture() throws -> (
        store: FoundationNativeAllocationStore, proof: NativeFirstCompletionProof,
        delegate: FoundationNativeDownloadDelegate, session: URLSession, task: URLSessionTask
    ) {
        let directory = try root()
        try FoundationDownloadStorage.prepare(directory)
        let store = FoundationNativeAllocationStore(
            directory: directory,
            sessionIdentifier: "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                + "." + UUID().uuidString)
        try store.reserve()
        try store.beginCreating()
        let proof = try NativeFirstCompletionProof(directory: directory)
        let delegate = FoundationNativeDownloadDelegate(
            progress: { _, _ in }, store: store,
            announceAllocation: { try proof.announce($0, url: $1, task: $2) },
            sealAllocation: { try proof.seal($0, url: $1, task: $2) },
            backgroundEventsFinished: { _ in })
        let session = URLSession(configuration: .ephemeral)
        let task = try delegate.makeTask(session: session) {
            let task = session.dataTask(with: URL(string: "https://example.invalid/never-started")!)
            task.cancel()
            return task
        }
        return (store, proof, delegate, session, task)
    }

    func testAnnouncementAllowsAbsentTargetAndFirstSuccessfulCompletionSealsOnce() async throws {
        let f = try firstCompletionFixture()
        defer {
            f.delegate.activateDelegateQueue()
            f.session.invalidateAndCancel()
        }
        let run = Task { try await f.delegate.run(f.task) }
        try await waitUntil { (try? f.store.load().phase) == .resuming }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.proof.target.path))
        try f.delegate.recordAnnouncement(f.proof.target, session: f.session, task: f.task)
        try f.delegate.recordAnnouncement(f.proof.target, session: f.session, task: f.task)
        XCTAssertEqual(f.proof.parentSnapshots, 1)
        XCTAssertEqual(f.proof.targetReads, 0)
        XCTAssertNil(try f.store.load().package)
        let parentPin = try f.store.load().namespaceBookmark
        try f.proof.materialize()  // Parent generation changes legitimately across child creation.
        f.delegate.urlSession(f.session, task: f.task, didCompleteWithError: nil)
        let result = try await run.value
        XCTAssertEqual(result, f.proof.target)
        let sealed = try f.store.completedPackage(taskIdentifier: f.task.taskIdentifier)
        XCTAssertEqual(sealed.namespaceBookmark, parentPin)
        XCTAssertEqual(f.proof.packageSnapshots, 1)
        let receipt = try Data(contentsOf: f.store.receiptURL)
        f.delegate.urlSession(f.session, task: f.task, didCompleteWithError: nil)
        XCTAssertEqual(f.proof.packageSnapshots, 1)
        XCTAssertEqual(try Data(contentsOf: f.store.receiptURL), receipt)
        XCTAssertEqual(f.task.countOfBytesSent, 0)
    }

    func testFirstCompletionRejectsForeignSessionAndTaskBeforeTargetAccess() async throws {
        let f = try firstCompletionFixture()
        let foreignSession = URLSession(configuration: .ephemeral)
        defer {
            f.delegate.activateDelegateQueue()
            f.session.invalidateAndCancel()
            foreignSession.invalidateAndCancel()
        }
        let run = Task { try await f.delegate.run(f.task) }
        try await waitUntil { (try? f.store.load().phase) == .resuming }
        try f.delegate.recordAnnouncement(f.proof.target, session: f.session, task: f.task)
        let foreignTask = f.session.dataTask(
            with: URL(string: "https://example.invalid/never-started")!)
        foreignTask.cancel()
        f.delegate.urlSession(foreignSession, task: f.task, didCompleteWithError: nil)
        f.delegate.urlSession(f.session, task: foreignTask, didCompleteWithError: nil)
        XCTAssertEqual(f.proof.targetReads, 0)
        XCTAssertNil(try f.store.load().completionAttempted)
        try f.proof.materialize()
        f.delegate.urlSession(f.session, task: f.task, didCompleteWithError: nil)
        _ = try await run.value
        XCTAssertEqual(f.proof.packageSnapshots, 1)
    }

    func testFirstCompletionRejectsNamespaceReplacementBeforeAnyTargetRead() async throws {
        let f = try firstCompletionFixture()
        defer {
            f.delegate.activateDelegateQueue()
            f.session.invalidateAndCancel()
        }
        let run = Task { try await f.delegate.run(f.task) }
        try await waitUntil { (try? f.store.load().phase) == .resuming }
        try f.delegate.recordAnnouncement(f.proof.target, session: f.session, task: f.task)
        try f.proof.materialize()
        f.proof.replaceParent()
        f.delegate.urlSession(f.session, task: f.task, didCompleteWithError: nil)
        do {
            _ = try await run.value
            XCTFail("Replacement parent sealed")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .cleanup) }
        XCTAssertEqual(f.proof.targetReads, 0)
        XCTAssertEqual(f.proof.packageSnapshots, 0)
        XCTAssertEqual(try f.store.load().completionAttempted, true)
        XCTAssertNil(try f.store.load().package)
        f.delegate.urlSession(f.session, task: f.task, didCompleteWithError: nil)
        XCTAssertEqual(f.proof.targetReads, 0)
    }

    func testFailedFirstCompletionCannotResnapshotThroughDuplicateOrColdOwner() async throws {
        let f = try firstCompletionFixture()
        defer {
            f.delegate.activateDelegateQueue()
            f.session.invalidateAndCancel()
        }
        let run = Task { try await f.delegate.run(f.task) }
        try await waitUntil { (try? f.store.load().phase) == .resuming }
        try f.delegate.recordAnnouncement(f.proof.target, session: f.session, task: f.task)
        try f.proof.materialize()
        f.proof.failPackageSnapshot()
        f.delegate.urlSession(f.session, task: f.task, didCompleteWithError: nil)
        do {
            _ = try await run.value
            XCTFail("Failed bookmark sealed")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .cleanup) }
        let receipt = try Data(contentsOf: f.store.receiptURL)
        let cold = FoundationNativeDownloadDelegate(
            progress: { _, _ in }, store: f.store,
            announceAllocation: { try f.proof.announce($0, url: $1, task: $2) },
            sealAllocation: { try f.proof.seal($0, url: $1, task: $2) },
            backgroundEventsFinished: { _ in })
        defer { cold.activateDelegateQueue() }
        f.delegate.urlSession(f.session, task: f.task, didCompleteWithError: nil)
        cold.urlSession(f.session, task: f.task, didCompleteWithError: nil)
        XCTAssertThrowsError(
            try f.proof.seal(f.store, url: f.proof.target, task: f.task.taskIdentifier))
        XCTAssertThrowsError(
            try f.store.capture(f.proof.target, taskIdentifier: f.task.taskIdentifier))
        XCTAssertEqual(f.proof.packageSnapshots, 1)
        XCTAssertEqual(try Data(contentsOf: f.store.receiptURL), receipt)
        XCTAssertNil(try f.store.load().package)
    }

    func testFirstCompletionRejectsResourceGenerationChangeWithoutPublishingOrRefreshing()
        async throws
    {
        let f = try firstCompletionFixture()
        defer {
            f.delegate.activateDelegateQueue()
            f.session.invalidateAndCancel()
        }
        let run = Task { try await f.delegate.run(f.task) }
        try await waitUntil { (try? f.store.load().phase) == .resuming }
        try f.delegate.recordAnnouncement(f.proof.target, session: f.session, task: f.task)
        try f.proof.materialize()
        f.proof.changeTargetDuringSnapshot()
        f.delegate.urlSession(f.session, task: f.task, didCompleteWithError: nil)
        do {
            _ = try await run.value
            XCTFail("Changing resource identity sealed")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .cleanup) }
        XCTAssertEqual(f.proof.packageSnapshots, 1)
        XCTAssertNil(try f.store.load().package)
        XCTAssertEqual(try f.store.load().completionAttempted, true)
        let receipt = try Data(contentsOf: f.store.receiptURL)
        f.delegate.urlSession(f.session, task: f.task, didCompleteWithError: nil)
        XCTAssertEqual(f.proof.packageSnapshots, 1)
        XCTAssertEqual(try Data(contentsOf: f.store.receiptURL), receipt)
    }

    func testCancelledFatalAndRetiredAcquisitionsCannotCreateFirstCompletionProof() async throws {
        for mode in 0..<3 {
            let f = try firstCompletionFixture()
            defer {
                f.delegate.activateDelegateQueue()
                f.session.invalidateAndCancel()
            }
            let run = Task { try await f.delegate.run(f.task) }
            try await waitUntil { (try? f.store.load().phase) == .resuming }
            try f.delegate.recordAnnouncement(f.proof.target, session: f.session, task: f.task)
            if mode == 0 { run.cancel() }
            if mode == 1 {
                f.delegate.urlSession(f.session, didBecomeInvalidWithError: URLError(.unknown))
            }
            if mode == 2 {
                var receipt = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: f.store.receiptURL))
                        as? [String: Any])
                receipt["retired"] = true
                try JSONSerialization.data(withJSONObject: receipt).write(to: f.store.receiptURL)
            }
            f.delegate.urlSession(f.session, task: f.task, didCompleteWithError: nil)
            do {
                _ = try await run.value
                XCTFail("Ineligible acquisition sealed")
            } catch { XCTAssertEqual(error as? FoundationDownloadError, .cleanup) }
            XCTAssertEqual(f.proof.targetReads, 0)
            XCTAssertEqual(f.proof.packageSnapshots, 0)
            XCTAssertNil(try f.store.load().package)
        }
    }

    private func creationFixture() throws -> (FoundationNativeAllocationStore, URL) {
        let directory = try root()
        try FoundationDownloadStorage.prepare(directory)
        let store = FoundationNativeAllocationStore(
            directory: directory,
            sessionIdentifier: "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                + "." + UUID().uuidString,
            trackID: "synthetic-track")
        try store.reserve()
        return (store, directory)
    }

    func testFactoryQueuedAllocationRunsOnlyAfterExactBindingContinuationAndResuming() async throws
    {
        let (store, directory) = try creationFixture()
        try store.beginCreating()
        let delegate = FoundationNativeDownloadDelegate(
            progress: { _, _ in }, store: store,
            backgroundEventsFinished: { _ in })
        let session = URLSession(configuration: .ephemeral)
        defer {
            delegate.activateDelegateQueue()
            session.invalidateAndCancel()
        }
        let target = directory.appendingPathComponent("synthetic.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let observation = NativeDownloadVerificationFixture()
        let task = try delegate.makeTask(session: session) {
            let task = session.dataTask(with: URL(string: "https://example.invalid/never-started")!)
            task.cancel()
            // Simulate the OS enqueueing its location callback inside task creation.
            delegate.delegateQueue.addOperation {
                do {
                    let before = try store.load()
                    XCTAssertEqual(before.taskIdentifier, task.taskIdentifier)
                    XCTAssertEqual(before.phase, .resuming)
                    try store.capture(
                        target, taskIdentifier: task.taskIdentifier,
                        snapshot: { _ in Data("pinned synthetic identity".utf8) },
                        prove: { _ in true }, namespaceProof: { _ in true })
                    observation.recordVerification()
                } catch { XCTFail("Gated allocation did not retain strict binding") }
                // Fatal final delivery exercises the attached real run continuation.
                delegate.urlSession(session, didBecomeInvalidWithError: URLError(.unknown))
            }
            return task
        }
        XCTAssertTrue(delegate.delegateQueue.isSuspended)
        XCTAssertEqual(observation.verifications, 0)
        XCTAssertEqual(try store.load().phase, .creating)
        do {
            _ = try await delegate.run(task)
            XCTFail("Synthetic failure succeeded")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .cleanup) }
        XCTAssertFalse(delegate.delegateQueue.isSuspended)
        XCTAssertEqual(observation.verifications, 1)
        let receipt = try store.load()
        XCTAssertEqual(receipt.phase, .allocated)
        XCTAssertEqual(receipt.nativeURL, target)
        XCTAssertNotNil(receipt.package)
        XCTAssertNil(receipt.retired)
        XCTAssertThrowsError(try store.beginResuming(taskIdentifier: task.taskIdentifier))
        XCTAssertEqual(try store.load().package?.bookmark, receipt.package?.bookmark)
        XCTAssertEqual(task.countOfBytesSent, 0)
    }

    func testCreatingPhaseSurvivesFactoryCrashAndCannotBeRetiredOrReset() throws {
        let (store, directory) = try creationFixture()
        try store.beginCreating()
        let before = try Data(contentsOf: store.receiptURL)
        let relaunched = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: store.sessionIdentifier)
        XCTAssertEqual(try relaunched.load().phase, .creating)
        XCTAssertEqual(try relaunched.load().taskIdentifier, 0)
        XCTAssertThrowsError(try relaunched.retire())
        XCTAssertThrowsError(try relaunched.reserve())
        XCTAssertThrowsError(
            try relaunched.capture(
                directory.appendingPathComponent("foreign.movpkg"), taskIdentifier: 99))
        XCTAssertEqual(try Data(contentsOf: store.receiptURL), before)
    }

    func testBindingWriteFailureCancelsFactoryTaskAndReleasesQueuedEventsWithoutAdoptingID()
        async throws
    {
        let (store, directory) = try creationFixture()
        try store.beginCreating()
        let before = try Data(contentsOf: store.receiptURL)
        let delegate = FoundationNativeDownloadDelegate(
            progress: { _, _ in }, store: store,
            backgroundEventsFinished: { _ in })
        let session = URLSession(configuration: .ephemeral)
        let observation = NativeDownloadVerificationFixture()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            delegate.activateDelegateQueue()
            session.invalidateAndCancel()
        }
        let task = session.dataTask(with: URL(string: "https://example.invalid/never-started")!)
        XCTAssertThrowsError(
            try delegate.makeTask(session: session) {
                delegate.delegateQueue.addOperation { observation.finish() }
                // The existing protected receipt stays readable; its replacement write fails.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o500], ofItemAtPath: directory.path)
                return task
            })
        try await waitUntil { observation.finished }
        XCTAssertFalse(delegate.delegateQueue.isSuspended)
        XCTAssertTrue(task.state == .canceling || task.state == .completed)
        XCTAssertEqual(task.countOfBytesSent, 0)
        XCTAssertEqual(try Data(contentsOf: store.receiptURL), before)
        XCTAssertEqual(try store.load().taskIdentifier, 0)
        XCTAssertThrowsError(try store.retire())
    }

    func testFactoryBindingRejectsForeignCallbackAndNeverOverwritesCapturedAuthority() throws {
        let (store, directory) = try creationFixture()
        try store.beginCreating()
        let delegate = FoundationNativeDownloadDelegate(
            progress: { _, _ in }, store: store,
            backgroundEventsFinished: { _ in })
        let session = URLSession(configuration: .ephemeral)
        defer {
            delegate.activateDelegateQueue()
            session.invalidateAndCancel()
        }
        let task = try delegate.makeTask(session: session) {
            let task = session.dataTask(with: URL(string: "https://example.invalid/never-started")!)
            task.cancel()
            return task
        }
        let target = directory.appendingPathComponent("synthetic.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.capture(target, taskIdentifier: task.taskIdentifier + 1))
        XCTAssertEqual(try store.load().phase, .creating)
        try store.capture(
            target, taskIdentifier: task.taskIdentifier,
            snapshot: { _ in Data("unchanged pinned identity".utf8) },
            prove: { _ in true }, namespaceProof: { _ in true })
        let before = try Data(contentsOf: store.receiptURL)
        XCTAssertThrowsError(try store.bindCreatedTask(taskIdentifier: task.taskIdentifier))
        XCTAssertThrowsError(try store.reserve(taskIdentifier: task.taskIdentifier))
        XCTAssertThrowsError(try store.beginResuming(taskIdentifier: task.taskIdentifier))
        XCTAssertThrowsError(
            try store.capture(
                directory.appendingPathComponent("different.movpkg"),
                taskIdentifier: task.taskIdentifier))
        XCTAssertEqual(try Data(contentsOf: store.receiptURL), before)
        try store.retire(resolve: { _ in .available(target) })
        let retired = try Data(contentsOf: store.receiptURL)
        XCTAssertThrowsError(try store.capture(target, taskIdentifier: task.taskIdentifier))
        XCTAssertEqual(try Data(contentsOf: store.receiptURL), retired)
    }

    func testLegacyReservedIncludingRetiredRemainsUnknownButTerminalProofStillRetires() throws {
        for retired in [false, true] {
            let (store, _) = try creationFixture()
            var json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: store.receiptURL))
                    as? [String: Any])
            json.removeValue(forKey: "creationVersion")
            json["retired"] = retired
            let legacy = try JSONSerialization.data(withJSONObject: json)
            try legacy.write(to: store.receiptURL)
            XCTAssertNil(try store.load().creationVersion)
            XCTAssertThrowsError(try store.retire())
            XCTAssertThrowsError(try store.reserve())
            XCTAssertThrowsError(try store.beginCreating())
            XCTAssertEqual(try Data(contentsOf: store.receiptURL), legacy)
        }
        let (terminal, _) = try creationFixture()
        try terminal.reserve(taskIdentifier: 7)
        try terminal.recordTerminalNoAllocation(taskIdentifier: 7)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: terminal.receiptURL))
                as? [String: Any])
        json.removeValue(forKey: "creationVersion")
        try JSONSerialization.data(withJSONObject: json).write(to: terminal.receiptURL)
        XCTAssertNoThrow(try terminal.retire())
        XCTAssertEqual(try terminal.load().retired, true)
    }

    #if DEBUG
        func testBindingFailureDiagnosticEmitsOnlyFixedFlagsAndPhase() throws {
            let input = URL(string: "file:///private/tmp/synthetic-secret.movpkg")!
            let flags = FoundationNativeDownloadErrorFields.Binding(
                taskZero: true, taskMatches: false, urlPresent: false, urlMatches: false,
                retired: false, phase: .creating)
            let event = FoundationNativeDownloadErrorFields.capture(
                stage: .binding, location: input, binding: flags)
            XCTAssertEqual(
                event,
                "download.native stage=allocation.capture substage=binding outcome=failed fileURL=1 basePresent=0 plain=1 taskZero=1 taskMatches=0 urlPresent=0 urlMatches=0 retired=0 phase=creating"
            )
            XCTAssertFalse(event.contains("secret"))
            XCTAssertFalse(event.contains("file:"))
        }
    #endif

    func testActualNativeDelegateCancellationBeforeAllocationSurvivesRelaunchAndClearsAccount()
        async throws
    {
        let storageRoot = try root()
        let scope = "delegate-preallocation-cancel"
        let directory = FoundationDownloadStorage.directory(scope: scope, root: storageRoot)
        try FoundationDownloadStorage.prepare(directory)
        let identifier =
            "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
            + UUID().uuidString
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: identifier, trackID: "track")
        try store.reserve()
        try store.beginCreating()
        let delegate = FoundationNativeDownloadDelegate(progress: { _, _ in }, store: store)
        let session = URLSession(
            configuration: .ephemeral, delegate: delegate, delegateQueue: delegate.delegateQueue)
        defer {
            delegate.activateDelegateQueue()
            session.invalidateAndCancel()
        }
        let task = try delegate.makeTask(session: session) {
            session.dataTask(with: URL(string: "https://example.invalid/must-never-resume")!)
        }
        let gate = DownloadGate()
        let observation = NativeDownloadVerificationFixture()
        let operation = Task {
            await gate.wait()
            do {
                _ = try await delegate.run(task)
                XCTFail("Cancelled task succeeded")
            } catch { observation.finish() }
        }
        try await waitUntilAsync { await gate.started }
        operation.cancel()  // Already cancelled before run attaches/resumes its URLSession task.
        await gate.resume()
        try await waitUntil { observation.finished }
        XCTAssertEqual(task.countOfBytesSent, 0)
        let receipt = try store.load()
        XCTAssertEqual(receipt.taskIdentifier, task.taskIdentifier)
        XCTAssertEqual(receipt.phase, .terminalNoAllocation)
        XCTAssertNil(receipt.nativeURL)
        XCTAssertEqual(receipt.retired, true)
        // Simulate cold account inventory using the actual delegate's durable terminal record.
        var manifest = FoundationDownloadManifest()
        manifest.nativePendingSessions = [identifier]
        try FoundationDownloadStorage.save(manifest, directory: directory)
        let manager = FoundationDownloads(
            scope: scope, library: DownloadsLibrary(tracks: []), root: storageRoot,
            monitorConnectivity: false,
            nativeRetirement: { identifiers, directory in
                var retired: Set<String> = []
                for identifier in identifiers {
                    let store = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    do {
                        try store.retire()
                        retired.insert(identifier)
                    } catch {}
                }
                return retired
            })
        try await waitUntil { !manager.isLoading }
        XCTAssertTrue(
            try FoundationDownloadStorage.load(directory: directory).nativePendingSessions?.isEmpty
                == true)
        XCTAssertNoThrow(try store.load(), "Fixture receipt remained readable after inventory")
        let enumeratedReceipt = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasPrefix("native-receipt-") }))
        let expectedURL = store.receiptURL
        let identity = FoundationManagedPackageMetadata.comparison(
            try FoundationManagedPackageMetadata.resources(expectedURL),
            try FoundationManagedPackageMetadata.resources(enumeratedReceipt))
        let flags =
            "rawEqual=\(expectedURL == enumeratedReceipt) "
            + "absoluteEqual=\(expectedURL.absoluteURL == enumeratedReceipt.absoluteURL) "
            + "canonicalEqual=\(FoundationManagedPackageMetadata.equalPath(FoundationManagedPackageMetadata.canonical(expectedURL), FoundationManagedPackageMetadata.canonical(enumeratedReceipt))) "
            + "expectedHasBase=\(expectedURL.baseURL != nil) enumeratedHasBase=\(enumeratedReceipt.baseURL != nil) "
            + "file=\(identity.file.rawValue) volume=\(identity.volume.rawValue)"
        XCTAssertNoThrow(
            try FoundationNativeAllocationStore.existingReceipt(
                at: enumeratedReceipt, directory: directory),
            "Fixture receipt sweep binding: " + flags)
        let cleared = await manager.clearAccount()
        XCTAssertTrue(cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testBackgroundEventsReuseExistingInventoryWithoutOpeningAnotherNativeSession() async throws
    {
        let storageRoot = try root()
        let scope = "background-inventory"
        let directory = FoundationDownloadStorage.directory(scope: scope, root: storageRoot)
        try FoundationDownloadStorage.prepare(directory)
        let identifier =
            "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
            + UUID().uuidString
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: identifier)
        try store.reserve()
        var manifest = FoundationDownloadManifest()
        manifest.nativePendingSessions = [identifier]
        try FoundationDownloadStorage.save(manifest, directory: directory)
        let gate = DownloadGate()
        let observation = NativeDownloadVerificationFixture()
        let manager = FoundationDownloads(
            scope: scope, library: DownloadsLibrary(tracks: []), root: storageRoot,
            monitorConnectivity: false,
            nativeTransfer: { _, _, _, _ in
                XCTFail("Callback acquired a new asset")
                throw FoundationDownloadError.network
            },
            nativeRetirement: { identifiers, directory in
                observation.recordVerification()
                await gate.wait()
                for identifier in identifiers {
                    try? FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier
                    ).retire()
                }
                return identifiers
            })
        try await waitUntilAsync { await gate.started }
        var completed = false
        let callback = Task {
            let admitted = await manager.reconcileBackgroundSession(identifier)
            completed = true
            return admitted
        }
        let unknown = await manager.reconcileBackgroundSession(identifier + ".unknown")
        XCTAssertFalse(unknown)
        XCTAssertFalse(completed)
        XCTAssertEqual(observation.verifications, 1)
        await gate.resume()
        let admitted = await callback.value
        XCTAssertTrue(admitted)
        XCTAssertEqual(observation.verifications, 1)
        XCTAssertEqual(try store.load().retired, true)
        XCTAssertTrue(
            try FoundationDownloadStorage.load(directory: directory).nativePendingSessions?.isEmpty
                == true)
        let historical = await manager.reconcileBackgroundSession(identifier)
        XCTAssertFalse(historical)
        manager.recordBackgroundSessionDrain(identifier)
        let alreadyDrainedHistorical = await manager.reconcileBackgroundSession(identifier)
        XCTAssertFalse(alreadyDrainedHistorical)
        manager.invalidate()
    }

    func testBackgroundEventsWaitForLiveAcquisitionWithoutCancellingOrDuplicatingIt() async throws {
        let storageRoot = try root()
        let scope = "background-live-acquisition"
        let track = item("live-native")
        let directory = FoundationDownloadStorage.directory(scope: scope, root: storageRoot)
        let gate = DownloadGate()
        let observation = NativeDownloadVerificationFixture()
        let terminalDelivery = NativeDownloadVerificationFixture()
        let manager = FoundationDownloads(
            scope: scope, library: DownloadsLibrary(tracks: [track]), root: storageRoot,
            monitorConnectivity: false, requestedQuality: { .aac192 },
            systemManagedDownloads: { true },
            nativeTransfer: { _, store, _, _ in
                observation.recordVerification()
                let delegate = FoundationNativeDownloadDelegate(
                    progress: { _, _ in }, store: store,
                    backgroundEventsFinished: { incoming in
                        XCTAssertEqual(incoming, store.sessionIdentifier)
                        terminalDelivery.recordVerification()
                    })
                // A pre-cancelled task cannot issue network requests. The test drives
                // the actual delegate's run continuation and fatal callback directly.
                try store.reserve()
                try store.beginCreating()
                let session = URLSession(configuration: .ephemeral)
                let task = try delegate.makeTask(session: session) {
                    session.dataTask(with: URL(string: "https://example.invalid/never-started")!)
                }
                task.cancel()
                defer {
                    session.invalidateAndCancel()
                    XCTAssertEqual(task.countOfBytesSent, 0)
                }
                let failure = Task {
                    await gate.wait()
                    delegate.urlSession(
                        session,
                        didBecomeInvalidWithError: URLError(.backgroundSessionWasDisconnected))
                    delegate.urlSession(
                        session,
                        didBecomeInvalidWithError: URLError(.backgroundSessionWasDisconnected))
                }
                defer { failure.cancel() }
                _ = try await delegate.run(task)
                XCTFail("Systemic invalidation returned a successful allocation")
                throw FoundationDownloadError.incomplete
            },
            nativeRetirement: { _, _ in
                XCTFail("Live task opened a duplicate recovery session")
                return []
            })
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntilAsync { await gate.started }
        let identifier = try XCTUnwrap(
            FoundationDownloadStorage.load(directory: directory).nativePendingSessions?.first)
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: identifier)
        try await waitUntil { (try? store.load().phase) == .resuming }
        manager.recordBackgroundSessionDrain(identifier)
        XCTAssertTrue(manager.backgroundSessionHasDrained(identifier))
        var completed = false
        let callback = Task {
            let admitted = await manager.reconcileBackgroundSession(identifier)
            completed = true
            return admitted
        }
        await Task.yield()
        XCTAssertFalse(completed)
        XCTAssertEqual(observation.verifications, 1)
        XCTAssertFalse(manager.isReady(track))
        await gate.resume()
        let admitted = await callback.value
        XCTAssertTrue(admitted)
        XCTAssertEqual(terminalDelivery.verifications, 1)
        XCTAssertEqual(observation.verifications, 1)
        let saved = try FoundationDownloadStorage.load(directory: directory)
        XCTAssertTrue(saved.nativePendingSessions?.contains(identifier) == true)
        XCTAssertEqual(saved.owners.first?.paused, true)
        XCTAssertEqual(manager.owners.first?.state, .failed)
        let retained = try FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: identifier
        ).load()
        XCTAssertEqual(retained.phase, .resuming)
        XCTAssertNil(retained.retired)
        XCTAssertFalse(manager.isReady(track))
        manager.invalidate()
    }

    func testNativeBackgroundDelegateForwardsEventDrainAtBothEstablishedSessionBoundaries() throws {
        let directory = try root()
        let identifier =
            "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
            + UUID().uuidString
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: identifier)
        let observation = NativeDownloadVerificationFixture()
        let delegate = FoundationNativeDownloadDelegate(
            progress: { _, _ in }, store: store,
            backgroundEventsFinished: { incoming in
                XCTAssertEqual(incoming, identifier)
                observation.recordVerification()
            })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        delegate.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        XCTAssertEqual(observation.verifications, 1)
        delegate.urlSession(session, didBecomeInvalidWithError: nil)
        XCTAssertEqual(observation.verifications, 2)
        delegate.urlSession(session, didBecomeInvalidWithError: URLError(.unknown))
        XCTAssertEqual(observation.verifications, 2)
        // Merely draining callbacks cannot invent a receipt, retire a file or mark ready.
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.receiptURL.path))
    }

    func testFatalSessionInvalidationBeforeRunIsLatchedWithoutAllocationOrRetirementProof()
        async throws
    {
        let directory = try root()
        try FoundationDownloadStorage.prepare(directory)
        let identifier =
            "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
            + UUID().uuidString
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: identifier)
        try store.reserve()
        let deliveries = NativeDownloadVerificationFixture()
        let delegate = FoundationNativeDownloadDelegate(
            progress: { _, _ in }, store: store,
            backgroundEventsFinished: { _ in deliveries.recordVerification() })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://example.invalid/never-started")!)
        task.cancel()
        delegate.urlSession(
            session, didBecomeInvalidWithError: URLError(.backgroundSessionWasDisconnected))
        delegate.urlSession(session, didBecomeInvalidWithError: URLError(.unknown))
        XCTAssertEqual(deliveries.verifications, 1)
        do {
            _ = try await delegate.run(task)
            XCTFail("Fatal session resumed its task")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .cleanup) }
        let beforeLateTask = try Data(contentsOf: store.receiptURL)
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        XCTAssertEqual(try Data(contentsOf: store.receiptURL), beforeLateTask)
        let receipt = try store.load()
        XCTAssertTrue(delegate.failedSession)
        XCTAssertEqual(receipt.phase, .reserved)
        XCTAssertNil(receipt.nativeURL)
        XCTAssertNil(receipt.retired)
        XCTAssertEqual(task.countOfBytesSent, 0)
    }

    func testFatalSessionInvalidationBeforeColdRetirementPreservesReceiptAndCompletesOnce()
        async throws
    {
        let directory = try root()
        try FoundationDownloadStorage.prepare(directory)
        let identifier =
            "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
            + UUID().uuidString
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: identifier)
        try store.reserve(taskIdentifier: 1)
        try store.beginResuming(taskIdentifier: 1)
        let before = try Data(contentsOf: store.receiptURL)
        let deliveries = NativeDownloadVerificationFixture()
        let delegate = FoundationNativeDownloadDelegate(
            progress: { _, _ in }, store: store,
            backgroundEventsFinished: { _ in deliveries.recordVerification() })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        delegate.urlSession(
            session, didBecomeInvalidWithError: URLError(.backgroundSessionInUseByAnotherProcess))
        delegate.urlSession(session, didBecomeInvalidWithError: URLError(.unknown))
        do {
            try await delegate.retire(session)
            XCTFail("Failed reconnection invented retirement proof")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .cleanup) }
        XCTAssertEqual(deliveries.verifications, 1)
        XCTAssertEqual(try Data(contentsOf: store.receiptURL), before)
        XCTAssertEqual(try store.load().phase, .resuming)
        XCTAssertNil(try store.load().retired)
    }

    func testReservedReceiptAndUnknownColdResumingReceiptHaveDifferentRetirementAuthority() throws {
        let directory = try root()
        try FoundationDownloadStorage.prepare(directory)
        func store() -> FoundationNativeAllocationStore {
            .init(
                directory: directory,
                sessionIdentifier: "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                    + "." + UUID().uuidString)
        }
        let reserved = store()
        try reserved.reserve(taskIdentifier: 1)
        try reserved.retire()  // Durable ordering proves no resume was issued.
        XCTAssertEqual(try reserved.load().retired, true)
        let unknown = store()
        try unknown.reserve(taskIdentifier: 2)
        try unknown.beginResuming(taskIdentifier: 2)
        let relaunched = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: unknown.sessionIdentifier)
        XCTAssertThrowsError(try relaunched.retire())
        XCTAssertEqual(try relaunched.load().phase, .resuming)
        XCTAssertNil(try relaunched.load().retired)
        let missing = store()
        XCTAssertThrowsError(try missing.retire())  // Missing receipt is never "no allocation".
    }

    func testColdDelegateTerminalWithoutEarlierAllocationCallbackDoesNotInventNoAllocationProof()
        throws
    {
        let directory = try root()
        try FoundationDownloadStorage.prepare(directory)
        let identifier =
            "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
            + UUID().uuidString
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: identifier)
        let coldDelegate = FoundationNativeDownloadDelegate(progress: { _, _ in }, store: store)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://example.invalid/never-started")!)
        try store.reserve(taskIdentifier: task.taskIdentifier)
        try store.beginResuming(taskIdentifier: task.taskIdentifier)
        // This delegate never owned the original live run, so a terminal callback in
        // the new process cannot prove that no earlier allocation callback occurred.
        coldDelegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        XCTAssertEqual(try store.load().phase, .resuming)
        XCTAssertNil(try store.load().retired)
        XCTAssertThrowsError(try store.retire())
    }

    func testExplicitRetryRevalidatesQuarantinedNativeWithoutReacquiringOrFalseReady() async throws
    {
        try await checkNativeRevalidation(useRetry: true)
    }

    func testForegroundRevalidatesQuarantinedNativeWithoutReacquiringOrFalseReady() async throws {
        try await checkNativeRevalidation(useRetry: false)
    }

    private func checkNativeRevalidation(useRetry: Bool) async throws {
        let storageRoot = try root()
        let scope = "native-revalidation"
        let directory = FoundationDownloadStorage.directory(scope: scope, root: storageRoot)
        try FoundationDownloadStorage.prepare(directory)
        let track = item("recoverable-native")
        let package = FoundationNativeDownloadPackage(
            nativeURL: directory.appendingPathComponent("issued.movpkg"),
            bookmark: Data("unchanged pinned bookmark".utf8), sessionIdentifier: "synthetic")
        var manifest = FoundationDownloadManifest()
        manifest.owners = [
            .init(
                id: "track:" + track.id, item: FoundationStoredDownloadItem(track),
                tracks: [FoundationStoredDownloadItem(track)], paused: false, expanded: true,
                requestedQuality: .aac192, systemManaged: true)
        ]
        manifest.files[track.id] = .init(
            name: "pinned.movpkg", bytes: 1, digest: "", nativePackage: package)
        try FoundationDownloadStorage.save(manifest, directory: directory)
        let fixture = NativeDownloadVerificationFixture()
        let manager = FoundationDownloads(
            scope: scope, library: DownloadsLibrary(tracks: [track]), root: storageRoot,
            transfer: { _, _, _, _ in XCTFail("Revalidation must not download progressive bytes") },
            monitorConnectivity: false,
            nativeTransfer: { _, _, _, _ in
                XCTFail("Revalidation must not reacquire native media")
                throw FoundationDownloadError.response
            },
            nativeResolution: { _, _ in
                fixture.available ? .available(package.nativeURL) : .unverifiable
            },
            verifyInventoryFiles: { files, _ in
                if !files.isEmpty { fixture.recordVerification() }
                return fixture.available ? files : [:]
            })
        try await waitUntil { !manager.isLoading }
        manager.updateConnectivity(isAllowed: true)
        XCTAssertFalse(manager.isReady(track))
        XCTAssertEqual(manager.owners.first?.state, .failed)
        let before = fixture.verifications
        fixture.makeAvailable()
        if useRetry {
            manager.retry(ownerID: "track:" + track.id)
        } else {
            manager.refreshPresentation()
        }
        // Ownership alone doesn't publish ready synchronously; full verifier must finish.
        XCTAssertFalse(manager.isReady(track))
        try await waitUntil { manager.isReady(track) }
        XCTAssertEqual(manager.owners.first?.state, .ready)
        XCTAssertEqual(fixture.verifications, before + 1)
        let persisted = try FoundationDownloadStorage.load(directory: directory)
        XCTAssertEqual(persisted.files[track.id]?.nativePackage?.bookmark, package.bookmark)
        XCTAssertFalse(persisted.excludedTrackIDs?.contains(track.id) == true)
        manager.invalidate()
    }

    func testNativeCallbackAcceptsOnlySuppliedLocalFileBaseResolution() throws {
        let base = URL(
            fileURLWithPath: "/private/tmp/com.apple.UserManagedAssets.synthetic/",
            isDirectory: true)
        let based = try XCTUnwrap(URL(string: "asset%20one.movpkg", relativeTo: base))
        XCTAssertNotNil(based.baseURL)
        let result = try FoundationNativeDownloadDelegate.validatedCallbackURL(based)
        XCTAssertEqual(result, based.absoluteURL)
        XCTAssertNil(result.baseURL)
        XCTAssertTrue(FoundationManagedPackageMetadata.plain(result))
        // No normalization of the issued spelling or symlink-style prefix is allowed.
        let issued = try XCTUnwrap(URL(string: "file:///private/tmp/.nofollow/asset%20two.movpkg"))
        XCTAssertEqual(try FoundationNativeDownloadDelegate.validatedCallbackURL(issued), issued)
        let localhost = try XCTUnwrap(URL(string: "file://localhost/private/tmp/asset.movpkg"))
        XCTAssertEqual(
            try FoundationNativeDownloadDelegate.validatedCallbackURL(localhost),
            localhost.absoluteURL)
    }

    func testNativeCallbackRejectsNonlocalOrCredentialedSuppliedComponents() throws {
        for raw in [
            "https://foreign.invalid/asset.movpkg", "relative.movpkg", "file:relative.movpkg",
            "file://foreign.invalid/private/tmp/asset.movpkg",
            "file://user:password@localhost/private/tmp/asset.movpkg",
            "file:///private/tmp/asset.movpkg?ApiKey=synthetic",
            "file:///private/tmp/asset.movpkg#fragment",
        ] {
            let invalid = try XCTUnwrap(URL(string: raw))
            XCTAssertThrowsError(try FoundationNativeDownloadDelegate.validatedCallbackURL(invalid))
        }
        // The child itself can hide a base query/fragment. Every supplied base node
        // must be validated before taking Foundation's absolute resolution.
        for rawBase in [
            "https://foreign.invalid/root/", "file://foreign.invalid/private/tmp/root/",
            "file:///private/tmp/root/?ApiKey=synthetic", "file:///private/tmp/root/#fragment",
        ] {
            let base = try XCTUnwrap(URL(string: rawBase))
            let child = try XCTUnwrap(URL(string: "asset.movpkg", relativeTo: base))
            XCTAssertNotNil(child.baseURL)
            XCTAssertThrowsError(try FoundationNativeDownloadDelegate.validatedCallbackURL(child))
        }
    }

    func testNormalizedNativeCallbackPinsTheSameAbsoluteURLThroughStoreCapture() throws {
        let directory = try root()
        try FoundationDownloadStorage.prepare(directory)
        let base = directory.appendingPathComponent("synthetic-namespace", isDirectory: true)
        let supplied = try XCTUnwrap(URL(string: "asset.movpkg", relativeTo: base))
        let absolute = try FoundationNativeDownloadDelegate.validatedCallbackURL(supplied)
        try FileManager.default.createDirectory(at: absolute, withIntermediateDirectories: true)
        let store = FoundationNativeAllocationStore(
            directory: directory,
            sessionIdentifier: "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                + "." + UUID().uuidString)
        try store.reserve(taskIdentifier: 7)
        try store.beginResuming(taskIdentifier: 7)
        var snapshots: [URL] = []
        try store.capture(
            absolute, taskIdentifier: 7,
            snapshot: { url in
                XCTAssertNil(url.baseURL)
                XCTAssertTrue(FoundationManagedPackageMetadata.plain(url))
                snapshots.append(url)
                return Data("synthetic pinned snapshot".utf8)
            },
            prove: { package in
                XCTAssertEqual(package.nativeURL, absolute)
                return true
            },
            namespaceProof: { url in
                XCTAssertEqual(url, absolute)
                return true
            })
        XCTAssertEqual(snapshots, [absolute.deletingLastPathComponent(), absolute])
        let package = try store.completedPackage(taskIdentifier: 7)
        XCTAssertEqual(package.nativeURL, absolute)
        XCTAssertEqual(package.nativeURL, supplied.absoluteURL)
        XCTAssertNil(package.nativeURL.baseURL)
        // Durable storage still refuses the raw based representation directly.
        XCTAssertThrowsError(try store.capture(supplied, taskIdentifier: 7))
        XCTAssertEqual(try store.completedPackage(taskIdentifier: 7).bookmark, package.bookmark)
    }

    func testNativeDiagnosticFollowupPreservesEarlyURLAndTaskBindingRejection() throws {
        let directory = try root()
        try FoundationDownloadStorage.prepare(directory)
        let identifier =
            "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
            + UUID().uuidString
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: identifier, trackID: "track")
        try store.reserve(taskIdentifier: 1)
        try store.beginResuming(taskIdentifier: 1)
        let based = try XCTUnwrap(
            URL(string: "asset.movpkg", relativeTo: directory))
        XCTAssertNotNil(based.baseURL)
        let plain = based.absoluteURL
        for (url, task) in [(based, 1), (plain, 2)] {
            XCTAssertThrowsError(
                try store.capture(
                    url, taskIdentifier: task,
                    snapshot: { _ in
                        XCTFail("Early rejection reached bookmark access")
                        return Data()
                    },
                    prove: { _ in
                        XCTFail("Early rejection reached ownership proof")
                        return false
                    },
                    namespaceProof: { _ in
                        XCTFail("Early rejection reached namespace access")
                        return false
                    }))
            let retained = try store.load()
            XCTAssertEqual(retained.phase, .resuming)
            XCTAssertEqual(retained.taskIdentifier, 1)
            XCTAssertNil(retained.nativeURL)
            XCTAssertNil(retained.package)
            XCTAssertNil(retained.namespaceBookmark)
            XCTAssertNil(retained.retired)
        }
    }

    func testNativeCallbackBookmarkFailureRetainsDurableObservedAuthority() throws {
        let directory = try root()
        try FoundationDownloadStorage.prepare(directory)
        let session =
            "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
            + UUID().uuidString
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: session, trackID: "track")
        let target = directory.appendingPathComponent("synthetic.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var calls = 0
        XCTAssertThrowsError(
            try store.capture(
                target, taskIdentifier: 7,
                snapshot: { _ in
                    // Synchronous ordering: authority is on disk before either bookmark call.
                    XCTAssertEqual(try store.load().nativeURL, target)
                    calls += 1
                    if calls == 2 { throw CocoaError(.fileReadNoPermission) }
                    return Data("namespace snapshot".utf8)
                },
                prove: { _ in
                    XCTFail("Failed snapshot cannot authorize reuse")
                    return true
                }, namespaceProof: { _ in true }))
        let relaunched = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: session)
        let receipt = try relaunched.load()
        XCTAssertEqual(receipt.taskIdentifier, 7)
        XCTAssertEqual(receipt.trackID, "track")
        XCTAssertNil(receipt.package)
        XCTAssertNotNil(receipt.namespaceBookmark)
        XCTAssertThrowsError(
            try relaunched.retire(
                resolve: { _ in .unverifiable },
                remove: { _ in XCTFail("Unproved target must survive") }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNil(try relaunched.load().retired)
    }

    func testNativeDurableReceiptSurvivesCancellationAndRetiresIdempotentlyAfterRelaunch() throws {
        let directory = try root()
        try FoundationDownloadStorage.prepare(directory)
        let session =
            "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
            + UUID().uuidString
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: session, trackID: "track")
        let target = directory.appendingPathComponent("synthetic.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try store.capture(
            target, taskIdentifier: 8, snapshot: { _ in Data("pinned identity".utf8) },
            prove: { _ in true }, namespaceProof: { _ in true })
        let pinned = try store.completedPackage(taskIdentifier: 8)
        // Replayed callback must reuse the pinned snapshot, never refresh it from a path.
        try store.capture(
            target, taskIdentifier: 8,
            snapshot: { _ in
                XCTFail("Snapshot refreshed")
                return Data()
            })
        XCTAssertEqual(try store.completedPackage(taskIdentifier: 8).bookmark, pinned.bookmark)
        XCTAssertThrowsError(try store.capture(target, taskIdentifier: 9))
        let relaunched = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: session)
        try relaunched.retire(resolve: { _ in .available(target) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try relaunched.load().retired, true)
        // A crash before manifest publication leaves a protected tombstone, not a bare ID.
        try relaunched.retire(resolve: { _ in
            XCTFail("Retired allocation re-opened")
            return .unverifiable
        })
        XCTAssertEqual(try relaunched.load().retired, true)
    }

    func testOwnedNativeResourceRejectsGenerationChangeReplacementAndDistinguishesConfirmedAbsence()
        throws
    {
        typealias Metadata = FoundationManagedPackageMetadata
        let home = try root()
        let namespace = home.appendingPathComponent(
            "Library/com.apple.UserManagedAssets.synthetic", isDirectory: true)
        let target = namespace.appendingPathComponent("asset.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let bookmark = try target.bookmarkData(
            options: [], includingResourceValuesForKeys: Set(Metadata.keys), relativeTo: nil)
        let namespaceBookmark = try namespace.bookmarkData(
            options: [], includingResourceValuesForKeys: Set(Metadata.keys), relativeTo: nil)
        let package = FoundationNativeDownloadPackage(
            nativeURL: target, bookmark: bookmark,
            sessionIdentifier: "synthetic", namespaceBookmark: namespaceBookmark)
        func stable(_ url: URL) throws -> [URLResourceKey: Any] {
            var values = try Metadata.resources(url)
            values[.generationIdentifierKey] = Data([1]) as NSData
            return values
        }
        func inspect(_ read: (URL) throws -> [URLResourceKey: Any]) -> Metadata.Result {
            var report = Metadata.Report()
            report.bound = true
            return Metadata.inspectResult(
                .init(nativeURL: target, canonicalURL: target, completedBookmark: bookmark),
                home: home, initial: report, readResources: read)
        }
        XCTAssertNotNil(inspect(stable).resolvedURL)
        let canonicalTarget = Metadata.canonical(target)
        func isSyntheticTarget(_ url: URL) -> Bool {
            Metadata.equalPath(Metadata.canonical(url), canonicalTarget)
        }
        var reads = 0
        let changing = inspect { url in
            var values = try stable(url)
            if isSyntheticTarget(url) {
                reads += 1
                values[.generationIdentifierKey] = Data([UInt8(reads)]) as NSData
            }
            return values
        }
        XCTAssertGreaterThanOrEqual(
            reads, 2, "Changing reader must reach the same canonical synthetic target twice")
        XCTAssertNil(changing.resolvedURL)
        try FileManager.default.removeItem(at: target)
        XCTAssertTrue(package.provesMissing(home: home, resources: stable))
        if case .provenMissing = package.resolution(
            home: home, inspect: { _ in inspect(stable) },
            missing: { $0.provesMissing(home: home, resources: stable) })
        {
        } else {
            XCTFail("Confirmed owned namespace absence was not recognized")
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // Deterministically model an already-replaced resource with different file identity.
        let replaced = inspect { url in
            var values = try stable(url)
            if isSyntheticTarget(url) {
                values[.fileResourceIdentifierKey] = Data("different file".utf8) as NSData
            }
            return values
        }
        XCTAssertNil(replaced.resolvedURL)
        if case .unverifiable = package.resolution(
            home: home, inspect: { _ in replaced },
            missing: { $0.provesMissing(home: home, resources: stable) })
        {
        } else {
            XCTFail("Replacement became absence or availability")
        }
        XCTAssertFalse(
            package.provesMissing(
                home: home, resources: { _ in throw CocoaError(.fileReadNoPermission) }))
    }

    func testUnverifiableNativeInventoryPreservesAuthorityAndOtherVerifiedDownloads() async throws {
        try await checkNativeInventoryResolution(provenMissing: false)
    }

    func testProvenNativeAbsenceAloneExcludesTrackAndPreservesOtherDownloads() async throws {
        try await checkNativeInventoryResolution(provenMissing: true)
    }

    private func checkNativeInventoryResolution(provenMissing: Bool) async throws {
        let storageRoot = try root()
        let scope = "native-inventory"
        let directory = FoundationDownloadStorage.directory(scope: scope, root: storageRoot)
        try FoundationDownloadStorage.prepare(directory)
        let good = item("regular")
        let native = item("native")
        let next = item("next")
        let bytes = Data("regular verified audio".utf8)
        let url = directory.appendingPathComponent("regular.mp3")
        try bytes.write(to: url)
        try FoundationDownloadStorage.protect(url)
        var manifest = FoundationDownloadManifest()
        manifest.owners = [good, native].map { track in
            .init(
                id: "track:" + track.id, item: FoundationStoredDownloadItem(track),
                tracks: [FoundationStoredDownloadItem(track)], paused: false, expanded: true)
        }
        manifest.files[good.id] = .init(
            name: "regular.mp3", bytes: Int64(bytes.count),
            digest: try FoundationDownloadStorage.digest(url))
        let package = FoundationNativeDownloadPackage(
            nativeURL: directory.appendingPathComponent("issued.movpkg"),
            bookmark: Data("saved identity".utf8), sessionIdentifier: "synthetic")
        manifest.files[native.id] = .init(
            name: "native.movpkg", bytes: 1, digest: "", nativePackage: package)
        if !provenMissing {
            let session =
                "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
                + UUID().uuidString
            manifest.nativePendingSessions = [session]
            let pending = FoundationNativeAllocationStore(
                directory: directory, sessionIdentifier: session, trackID: native.id)
            XCTAssertThrowsError(
                try pending.capture(
                    package.nativeURL, taskIdentifier: 10,
                    snapshot: { _ in Data("namespace identity".utf8) }, prove: { _ in false },
                    namespaceProof: { _ in true }))
        }
        try FoundationDownloadStorage.save(manifest, directory: directory)
        let downloads = FoundationDownloads(
            scope: scope, library: DownloadsLibrary(tracks: [good, native, next]),
            root: storageRoot,
            transfer: transfer, monitorConnectivity: false,
            nativeRetirement: { identifiers, directory in
                for identifier in identifiers {
                    let store = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    do { try store.retire(resolve: { _ in .unverifiable }) } catch {
                        // Preserve unknown authority without starting an OS session in this fixture.
                    }
                }
                return []
            },
            nativeResolution: { _, _ in provenMissing ? .provenMissing : .unverifiable },
            verifyInventoryFiles: { files, _ in files.filter { $0.value.nativePackage == nil } })
        try await waitUntil { !downloads.isLoading }
        XCTAssertTrue(downloads.isReady(good))
        XCTAssertFalse(downloads.isReady(native))
        downloads.refreshPresentation()
        let saved = try FoundationDownloadStorage.load(directory: directory)
        XCTAssertEqual(saved.files[native.id] == nil, provenMissing)
        XCTAssertEqual(saved.excludedTrackIDs?.contains(native.id) == true, provenMissing)
        XCTAssertEqual(saved.nativePendingSessions?.isEmpty == false, !provenMissing)
        downloads.download(next)
        downloads.updateConnectivity(isAllowed: true)
        try await waitUntil { downloads.isReady(next) }
        if !provenMissing {
            let cleared = await downloads.clearAccount()
            XCTAssertFalse(cleared)
            XCTAssertNotNil(
                try FoundationDownloadStorage.load(directory: directory).files[native.id])
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        } else {
            downloads.invalidate()
        }
    }

    func testNativeFinitePlaylistRejectsLiveForeignAndCredentialResources() throws {
        let base = URL(string: "https://example.invalid/Audio/synthetic/main.m3u8")!
        let finite = "#EXTM3U\n#EXTINF:1,\nsegment.mp4\n#EXT-X-ENDLIST\n"
        XCTAssertNoThrow(
            try FoundationNativeDownloadTransport.validateFinitePlaylist(
                finite, base: base, expectedDuration: 1))
        for invalid in [
            finite.replacingOccurrences(of: "#EXT-X-ENDLIST\n", with: ""),
            finite.replacingOccurrences(
                of: "segment.mp4", with: "https://foreign.invalid/segment.mp4"),
            finite.replacingOccurrences(
                of: "segment.mp4", with: "segment.mp4?api_key=synthetic-secret"),
            finite.replacingOccurrences(of: "#EXTINF:1,", with: "#EXTINF:0.1,"),
            finite.replacingOccurrences(
                of: "#EXTINF:1,", with: "#EXT-X-KEY:METHOD=AES-128\n#EXTINF:1,"),
        ] {
            XCTAssertThrowsError(
                try FoundationNativeDownloadTransport.validateFinitePlaylist(
                    invalid, base: base, expectedDuration: 1))
        }
    }

    func testManagedManifestDecodesLegacyIntentAndRejectsMalformedBookmarkBeforeNativeUse() throws {
        let owner = FoundationDownloadManifest.Owner(
            id: "track:legacy", item: FoundationStoredDownloadItem(item("legacy")), tracks: [],
            paused: false, expanded: false)
        let encoded = try JSONEncoder().encode(owner)
        let decoded = try JSONDecoder().decode(FoundationDownloadManifest.Owner.self, from: encoded)
        XCTAssertNil(decoded.systemManaged)
        XCTAssertNil(decoded.requestedQuality)
        let package = FoundationNativeDownloadPackage(
            nativeURL: URL(string: "https://example.invalid/not-a-local-allocation")!,
            bookmark: Data("not a bookmark".utf8), sessionIdentifier: "synthetic")
        XCTAssertNil(package.resolveOwnedURL())
        let file = FoundationDownloadManifest.File(
            name: "synthetic.movpkg", bytes: 1, digest: "", nativePackage: package)
        XCTAssertFalse(FoundationDownloadStorage.valid(file, directory: try root()))
        XCTAssertNil(FoundationDownloadStorage.fileURL(file, directory: try root()))
    }

    func testConvertedOwnerSnapshotsQualityAndPublishesActualRenditionWithoutReplacingReadyFile()
        async throws
    {
        let root = try root()
        let track = item("converted")
        let library = DownloadsLibrary(tracks: [track])
        var quality = FoundationDownloadQuality.aac128
        let manager = FoundationDownloads(
            scope: "converted", library: library, root: root,
            transfer: { _, _, _, _ in XCTFail("AAC intent must not use Original transport") },
            monitorConnectivity: false,
            convertedTransfer: Self.syntheticConvertedTransfer,
            requestedQuality: { quality })
        manager.download(track)
        quality = .aac320  // An existing owner keeps the original intent, even before starting.
        XCTAssertEqual(manager.owners.first?.requestedQuality, .aac128)
        manager.updateConnectivity(isAllowed: true)
        try await waitUntil { manager.isReady(track) }
        let directory = FoundationDownloadStorage.directory(scope: "converted", root: root)
        let manifest = try FoundationDownloadStorage.load(directory: directory)
        let file = try XCTUnwrap(manifest.files[track.id])
        XCTAssertEqual(manifest.owners.first?.requestedQuality, .aac128)
        XCTAssertEqual(file.convertedRendition?.codec, "aac")
        XCTAssertEqual(file.convertedRendition?.duration, 1)
        XCTAssertEqual(
            file.digest,
            try FoundationDownloadStorage.digest(
                directory.appendingPathComponent(file.name)))
        let requests = await library.requestedQualities
        XCTAssertEqual(requests, [.aac128])
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .ready }
        let reused = try FoundationDownloadStorage.load(directory: directory)
        XCTAssertEqual(reused.files[track.id]?.name, file.name)
        let afterReuse = await library.requestedQualities
        XCTAssertEqual(afterReuse, [.aac128])
        _ = await manager.clearAccount()
    }

    func testCancelledConvertedOwnerRetainsQualityAcrossRetry() async throws {
        let track = item("retry-converted")
        let library = DownloadsLibrary(tracks: [track])
        let gate = DownloadGate()
        await library.setConversionGate(gate)
        var quality = FoundationDownloadQuality.aac192
        let manager = FoundationDownloads(
            scope: "retry-converted", library: library, root: try root(),
            monitorConnectivity: false, convertedTransfer: Self.syntheticConvertedTransfer,
            requestedQuality: { quality })
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntilAsync { await gate.started }
        manager.cancel(ownerID: "track:" + track.id)
        quality = .aac320
        await gate.resume()
        // A subsequent retry retains the cancelled owner's choice. The old proposal
        // cannot publish because its cancelled worker must pass ownership checks.
        manager.retry(ownerID: "track:" + track.id)
        try await waitUntil { manager.isReady(track) }
        XCTAssertEqual(manager.owners.first?.requestedQuality, .aac192)
        let qualities = await library.requestedQualities
        XCTAssertTrue(qualities.allSatisfy { $0 == .aac192 })
        _ = await manager.clearAccount()
    }

    func testRetiredAccountRejectsLateConvertedCompletionAndRemovesStagedBytes() async throws {
        let root = try root()
        let track = item("late-converted")
        let gate = DownloadGate()
        let manager = FoundationDownloads(
            scope: "late-converted", library: DownloadsLibrary(tracks: [track]), root: root,
            monitorConnectivity: false,
            convertedTransfer: { proposal, target, cellular, progress in
                await gate.wait()  // Deliberately ignores cancellation to emulate a late result.
                return try await Self.syntheticConvertedTransfer(
                    proposal, target, cellular, progress)
            }, requestedQuality: { .aac128 })
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntilAsync { await gate.started }
        let cleanup = Task { await manager.clearAccount() }
        for _ in 0..<10 { await Task.yield() }
        await gate.resume()
        let removed = await cleanup.value
        XCTAssertTrue(removed)
        XCTAssertFalse(manager.isReady(track))
        XCTAssertTrue(manager.owners.isEmpty)
        let directory = FoundationDownloadStorage.directory(scope: "late-converted", root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFailedConvertedCleanupDoesNotPublishOrLeavePartialFile() async throws {
        let root = try root()
        let track = item("failed-converted")
        let manager = FoundationDownloads(
            scope: "failed-converted", library: DownloadsLibrary(tracks: [track]), root: root,
            monitorConnectivity: false,
            convertedTransfer: { _, target, _, _ in
                try Data("unpublished bytes".utf8).write(to: target)
                throw FoundationDownloadError.conversionCleanup
            }, requestedQuality: { .aac128 })
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .failed }
        XCTAssertFalse(manager.isReady(track))
        let directory = FoundationDownloadStorage.directory(scope: "failed-converted", root: root)
        let saved = try FoundationDownloadStorage.load(directory: directory)
        XCTAssertTrue(saved.files.isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(remaining.contains { $0.lastPathComponent.hasPrefix("stage-") })
        XCTAssertEqual(saved.owners.first?.requestedQuality, .aac128)
        _ = await manager.clearAccount()
    }

    private nonisolated static var syntheticConvertedTransfer: FoundationDownloads.ConvertedTransfer
    {
        { _, target, _, progress in
            let data = Data("inspected synthetic AAC".utf8)
            try data.write(to: target)
            progress(Int64(data.count), nil)
            return FoundationVerifiedConvertedDownload(
                bytes: Int64(data.count), digest: try FoundationDownloadStorage.digest(target),
                rendition: .init(
                    container: "m4a", codec: "aac", sampleRate: 48_000,
                    channels: 2, duration: 1))
        }
    }

    func testPersistedDownloadQualitySurvivesRetryAndReusesExistingVerifiedFile() async throws {
        let root = try root()
        let directory = FoundationDownloadStorage.directory(scope: "quality-fixture", root: root)
        try FoundationDownloadStorage.prepare(directory)
        let track = item("quality-track")
        let fileURL = directory.appendingPathComponent("existing.m4a")
        let original = Data("verified original fixture".utf8)
        try original.write(to: fileURL)
        let file = FoundationDownloadManifest.File(
            name: "existing.m4a", bytes: Int64(original.count),
            digest: try FoundationDownloadStorage.digest(fileURL))
        var manifest = FoundationDownloadManifest()
        manifest.owners = [
            .init(
                id: "track:quality-track", item: FoundationStoredDownloadItem(track),
                tracks: [FoundationStoredDownloadItem(track)], paused: true, expanded: true,
                requestedQuality: .aac128)
        ]
        manifest.files = [track.id: file]
        try FoundationDownloadStorage.save(manifest, directory: directory)
        let manager = FoundationDownloads(
            scope: "quality-fixture", library: DownloadsLibrary(tracks: [track]), root: root,
            transfer: { _, _, _, _ in XCTFail("Existing ready bytes must not be replaced") },
            monitorConnectivity: false)
        try await waitUntil { !manager.isLoading }
        XCTAssertTrue(manager.isReady(track))
        XCTAssertEqual(manager.owners.first?.requestedQuality, .aac128)
        manager.download(track)  // Existing ownership is retry, not a new quality snapshot.
        manager.setAllowsCellular(false)  // A normal manifest save must retain quality.
        let saved = try FoundationDownloadStorage.load(directory: directory)
        XCTAssertEqual(saved.owners.first?.requestedQuality, .aac128)
        XCTAssertEqual(saved.files[track.id]?.name, "existing.m4a")
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        manager.invalidate()
    }

    func testMetadataPreparationDoesNotCreateAdditionalOwnedPlaylistReconciliation() async throws {
        let ready = item("ready")
        let playlist = item("owned", kind: .playlist)
        let library = DownloadsLibrary(tracks: [ready], preparesOfflinePlaylists: true)
        await library.setOfflinePlaylistFixture(
            candidates: [playlist], memberships: [playlist.id: [ready]])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil {
            manager.offlinePlaylistPreparationMessage
                == "Playlist availability saved for offline browsing."
        }
        let ownedOffsets = await library.playlistOffsets
        XCTAssertEqual(
            ownedOffsets, [0],
            "Ready files may trigger optional metadata only, not an owned playlist refresh")
        let optionalOffsets = await library.offlinePlaylistOffsets
        XCTAssertTrue(
            optionalOffsets.isEmpty, "The already-owned playlist needs no duplicate optional read")
        let requestedTracks = await library.downloadSourceIDs
        XCTAssertEqual(requestedTracks, [ready.id])
        XCTAssertTrue(manager.isReady(ready))
        _ = await manager.clearAccount()
    }

    func testNeverOpenedPlaylistsArePreparedAcrossPagesAndSurviveColdOfflineRelaunch() async throws
    {
        let directory = try root()
        let ready = item("ready")
        let target = item("playlist-7", kind: .playlist)
        let remote = (0..<110).map { item("remote-\($0)") }
        let contents = remote + [ready, ready]
        let library = DownloadsLibrary(tracks: [], preparesOfflinePlaylists: true)
        let candidates = (0..<7).map { item("playlist-\($0 + 1)", kind: .playlist) }
        await library.setOfflinePlaylistFixture(
            candidates: candidates, memberships: [target.id: contents], pageSize: 2)
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(ready)
        try await waitUntil {
            manager.offlinePlaylistPreparationMessage
                == "Playlist availability saved for offline browsing."
        }
        XCTAssertEqual(manager.downloadedPlaylists.map(\.id), [target.id])
        XCTAssertEqual(manager.knownCollectionTracks(for: target).map(\.id), contents.map(\.id))
        XCTAssertEqual(manager.browseTracks(for: target).map(\.id), ["ready", "ready"])
        XCTAssertEqual(manager.owners.map { $0.item.kind }, [.track])
        let offsets = await library.offlinePlaylistOffsets
        XCTAssertEqual(offsets[target.id], [0, 100])
        let candidateOffsets = await library.offlineCandidateOffsets
        XCTAssertEqual(candidateOffsets, [0, 2, 4, 6])
        let sourceIDs = await library.downloadSourceIDs
        XCTAssertEqual(
            sourceIDs, [ready.id], "Metadata preparation must not download playlist songs")
        manager.invalidate()
        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        try await waitUntil { !restored.isLoading }
        XCTAssertEqual(restored.downloadedPlaylists.map(\.id), [target.id])
        XCTAssertEqual(restored.browseTracks(for: target).map(\.id), ["ready", "ready"])
        let offlineCandidateOffsets = await library.offlineCandidateOffsets
        XCTAssertEqual(
            offlineCandidateOffsets, candidateOffsets,
            "Cold offline launch must not prepare remotely")
        restored.removeTrack(ready)
        XCTAssertTrue(restored.itemsWithDownloadedMusic(in: restored.downloadedPlaylists).isEmpty)
        XCTAssertEqual(restored.knownCollectionTracks(for: target).map(\.id), contents.map(\.id))
        _ = await restored.clearAccount()
    }

    func testFailedAutomaticPlaylistPreparationPreservesKnownMembership() async throws {
        let ready = item("ready")
        let target = item("playlist", kind: .playlist)
        let library = DownloadsLibrary(tracks: [], preparesOfflinePlaylists: true)
        await library.setOfflinePlaylistFixture(
            candidates: [target], memberships: [target.id: [ready, ready]])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(ready)
        try await waitUntil {
            manager.offlinePlaylistPreparationMessage
                == "Playlist availability saved for offline browsing."
        }
        await library.setFailure(true)
        manager.reconcilePlaylists()
        await manager.waitForCurrentReconciliationForTesting()
        XCTAssertEqual(manager.browseTracks(for: target).map(\.id), [ready.id, ready.id])
        XCTAssertEqual(
            manager.offlinePlaylistPreparationMessage,
            "Some playlist availability is not saved yet. Refresh online to try again.")
        XCTAssertNil(
            manager.errorMessage, "Optional metadata failure must not fail a ready download")
        XCTAssertTrue(manager.isReady(ready))
        _ = await manager.clearAccount()
    }

    func testOfflineOrRetiredPreparationRejectsLateMembershipResponse() async throws {
        for retire in [false, true] {
            let ready = item("ready")
            let target = item("playlist", kind: .playlist)
            let gate = DownloadGate()
            let library = DownloadsLibrary(tracks: [], preparesOfflinePlaylists: true)
            await library.setOfflinePlaylistFixture(
                candidates: [target], memberships: [target.id: [ready]])
            await library.setOfflinePlaylistGate(gate)
            let directory = try root()
            let manager = FoundationDownloads(
                scope: "fixture", library: library, root: directory, transfer: transfer,
                monitorConnectivity: false)
            manager.updateConnectivity(isAllowed: true)
            manager.download(ready)
            try await waitUntilAsync { await gate.started }
            XCTAssertTrue(manager.isReady(ready), "Optional preparation must not delay ready files")
            if retire { manager.invalidate() } else { manager.updateConnectivity(isAllowed: false) }
            await gate.resume()
            await manager.waitForCurrentReconciliationForTesting()
            XCTAssertTrue(manager.downloadedPlaylists.isEmpty)
            XCTAssertTrue(manager.knownCollectionTracks(for: target).isEmpty)
            let stored = try FoundationDownloadStorage.load(
                directory: FoundationDownloadStorage.directory(scope: "fixture", root: directory))
            XCTAssertTrue(
                stored.collections?.isEmpty ?? true,
                "A retired response must not write membership to disk")
            _ = await manager.clearAccount()
        }
    }

    func testPreparationRefreshesUnchangedLoadedCanonicalMembershipBeforeOfflineFiltering()
        async throws
    {
        let ready = item("ready")
        let remote = item("remote")
        let target = item("playlist", kind: .playlist)
        let gate = DownloadGate()
        let directory = try root()
        let library = DownloadsLibrary(tracks: [], preparesOfflinePlaylists: true)
        await library.setOfflinePlaylistFixture(
            candidates: [target], memberships: [target.id: [ready, ready]])
        await library.setOfflinePlaylistGate(gate)
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        let canonical = manager.collectionModel(for: target)
        await canonical.load(.refresh) { _ in .init(items: [remote], nextStartIndex: nil) }
        XCTAssertTrue(canonical.loaded)
        XCTAssertFalse(canonical.isRetainedSnapshot)
        manager.updateConnectivity(isAllowed: true)
        manager.download(ready)
        try await waitUntilAsync { await gate.started }
        await gate.resume()
        await manager.waitForCurrentReconciliationForTesting()
        XCTAssertEqual(canonical.rawItems.map(\.id), [ready.id, ready.id])
        XCTAssertEqual(manager.availability(for: target), .ready)
        XCTAssertEqual(
            manager.itemsWithDownloadedMusic(in: manager.downloadedPlaylists).map(\.id), [target.id]
        )
        manager.updateConnectivity(isAllowed: false)
        XCTAssertEqual(manager.browseTracks(for: target).map(\.id), [ready.id, ready.id])
        manager.invalidate()
        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        try await waitUntil { !restored.isLoading }
        XCTAssertEqual(restored.browseTracks(for: target).map(\.id), [ready.id, ready.id])
        _ = await restored.clearAccount()
    }

    func testNewOrIndependentlyChangedCanonicalPageWinsPendingPreparation() async throws {
        for existedBeforeRequest in [false, true] {
            let ready = item("ready")
            let remote = item("remote")
            let target = item("playlist", kind: .playlist)
            let gate = DownloadGate()
            let directory = try root()
            let library = DownloadsLibrary(tracks: [], preparesOfflinePlaylists: true)
            await library.setOfflinePlaylistFixture(
                candidates: [target], memberships: [target.id: []])
            await library.setOfflinePlaylistGate(gate)
            let manager = FoundationDownloads(
                scope: "fixture", library: library, root: directory, transfer: transfer,
                monitorConnectivity: false)
            if existedBeforeRequest {
                let old = manager.collectionModel(for: target)
                await old.load(.refresh) { _ in .init(items: [remote], nextStartIndex: nil) }
            }
            manager.updateConnectivity(isAllowed: true)
            manager.download(ready)
            try await waitUntilAsync { await gate.started }
            let current = manager.collectionModel(for: target)
            await current.load(.refresh) { _ in .init(items: [ready, ready], nextStartIndex: nil) }
            await gate.resume()
            await manager.waitForCurrentReconciliationForTesting()
            XCTAssertEqual(current.rawItems.map(\.id), [ready.id, ready.id])
            XCTAssertEqual(
                manager.knownCollectionTracks(for: target).map(\.id), [ready.id, ready.id])
            XCTAssertEqual(
                manager.offlinePlaylistPreparationMessage,
                "Some playlist availability is not saved yet. Refresh online to try again.")
            let stored = try FoundationDownloadStorage.load(
                directory: FoundationDownloadStorage.directory(scope: "fixture", root: directory))
            XCTAssertTrue(
                stored.collections?.isEmpty ?? true,
                "An older preparation must not persist over a newly opened or independently changed page"
            )
            _ = await manager.clearAccount()
        }
    }

    func testExplicitNewerMembershipWinsOverPendingAutomaticPreparation() async throws {
        let ready = item("ready")
        let target = item("playlist", kind: .playlist)
        let gate = DownloadGate()
        let library = DownloadsLibrary(tracks: [], preparesOfflinePlaylists: true)
        await library.setOfflinePlaylistFixture(candidates: [target], memberships: [target.id: []])
        await library.setOfflinePlaylistGate(gate)
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(ready)
        try await waitUntilAsync { await gate.started }
        manager.rememberCollection(target, tracks: [ready, ready], complete: true)
        await gate.resume()
        await manager.waitForCurrentReconciliationForTesting()
        XCTAssertEqual(manager.knownCollectionTracks(for: target).map(\.id), [ready.id, ready.id])
        XCTAssertEqual(manager.downloadedPlaylists.map(\.id), [target.id])
        _ = await manager.clearAccount()
    }

    func testAutomaticPlaylistPreparationReportsCandidateBudgetWithoutFalseCompletion() async throws
    {
        let ready = item("ready")
        let candidates = (0..<129).map { item("playlist-\($0)", kind: .playlist) }
        let library = DownloadsLibrary(tracks: [], preparesOfflinePlaylists: true)
        await library.setOfflinePlaylistFixture(candidates: candidates, memberships: [:])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(ready)
        try await waitUntil {
            manager.offlinePlaylistPreparationMessage
                == "Offline preparation reached its limit. Some playlists may not appear offline."
        }
        let offsets = await library.offlinePlaylistOffsets
        XCTAssertEqual(offsets.count, 128)
        XCTAssertNil(offsets[candidates.last!.id])
        XCTAssertTrue(manager.isReady(ready))
        _ = await manager.clearAccount()
    }

    func testOfflinePresentationHidesCachedContainersWithoutPlayableMusic() async throws {
        var ready = item("ready")
        ready.album = .init(id: "album", title: "Synthetic album")
        ready.artist = .init(id: "artist", title: "Synthetic artist")
        let remote = item("remote")
        let album = item("album", kind: .album)
        let playlist = item("playlist", kind: .playlist)
        let emptyPlaylist = item("empty", kind: .playlist)
        let artist = item("artist", kind: .artist)
        let cachedItems = [remote, playlist, ready, ready, album, emptyPlaylist, artist]
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [ready, remote]),
            root: try root(), transfer: transfer, monitorConnectivity: false)
        manager.rememberCollection(album, tracks: [remote, ready], complete: true)
        manager.rememberCollection(playlist, tracks: [remote, ready, ready], complete: true)
        manager.rememberCollection(emptyPlaylist, tracks: [remote], complete: true)
        manager.updateConnectivity(isAllowed: true)
        manager.download(ready)
        try await waitUntil { manager.isReady(ready) }
        XCTAssertEqual(
            manager.itemsWithDownloadedMusic(in: cachedItems).map(\.id),
            ["playlist", "ready", "ready", "album", "artist"])
        let selection = try XCTUnwrap(
            FoundationTrackQueueSelection(
                in: manager.itemsWithDownloadedMusic(in: [remote, ready, ready]), selecting: 1))
        XCTAssertEqual(selection.items.map(\.id), ["ready", "ready"])
        XCTAssertEqual(selection.index, 1)
        manager.removeTrack(ready)
        XCTAssertTrue(manager.itemsWithDownloadedMusic(in: cachedItems).isEmpty)
        XCTAssertTrue(manager.localCatalogItems().isEmpty)
        // Presentation filtering never erases cached membership or repeated occurrences.
        XCTAssertEqual(
            manager.knownCollectionTracks(for: playlist).map(\.id), ["remote", "ready", "ready"])
        _ = await manager.clearAccount()
    }

    func testTrackDownloadDiscoversRelatedCollectionsAcrossColdOfflineRelaunch() async throws {
        var first = item("first")
        first.album = .init(id: "album", title: "Synthetic album")
        first.artist = .init(id: "artist", title: "Synthetic artist")
        var unavailable = item("unavailable")
        unavailable.album = first.album
        unavailable.artist = first.artist
        let album = item("album", kind: .album)
        let playlist = item("playlist", kind: .playlist)
        let directory = try root()
        let library = DownloadsLibrary(tracks: [first, unavailable])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.rememberCollection(album, tracks: [first, unavailable], complete: true)
        manager.rememberCollection(playlist, tracks: [unavailable, first, first], complete: true)
        manager.updateConnectivity(isAllowed: true)
        manager.download(first)
        try await waitUntil { manager.isReady(first) }
        XCTAssertEqual(manager.downloadedAlbums.map(\.id), ["album"])
        XCTAssertEqual(manager.downloadedArtists.map(\.id), ["artist"])
        XCTAssertEqual(manager.downloadedPlaylists.map(\.id), ["playlist"])
        XCTAssertEqual(manager.availability(for: album), .partial(ready: 1, total: 2))
        manager.invalidate()
        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        try await waitUntil { !restored.isLoading }
        XCTAssertEqual(
            restored.knownCollectionTracks(for: playlist).map(\.id),
            ["unavailable", "first", "first"])
        XCTAssertEqual(restored.browseTracks(for: playlist).map(\.id), ["first", "first"])
        XCTAssertEqual(restored.downloadedAlbums(artistID: "artist").map(\.id), ["album"])
        XCTAssertEqual(restored.downloadedArtists.map(\.id), ["artist"])
        let artist = item("artist", kind: .artist)
        XCTAssertEqual(restored.browseTracks(for: artist).map(\.id), ["first"])
        XCTAssertFalse(restored.hasCompleteCollectionSnapshot(for: artist))
        XCTAssertEqual(restored.availability(for: artist), .partial(ready: 1, total: 1))
        XCTAssertFalse(restored.isReady(unavailable))
        let other = FoundationDownloads(
            scope: "other-account-server", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        XCTAssertTrue(other.downloadedAlbums.isEmpty)
        XCTAssertTrue(other.knownCollectionTracks(for: playlist).isEmpty)
        _ = await other.clearAccount()
        _ = await restored.clearAccount()
    }

    func testRememberedPlaylistDoesNotOwnAudioAfterAlbumRemoval() async throws {
        let track = item("track")
        let album = item("album", kind: .album)
        let playlist = item("playlist", kind: .playlist)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: try root(),
            transfer: transfer, monitorConnectivity: false)
        manager.rememberCollection(playlist, tracks: [track], complete: true)
        manager.updateConnectivity(isAllowed: true)
        manager.download(album)
        try await waitUntil { manager.isReady(track) }
        XCTAssertEqual(manager.downloadedPlaylists.map(\.id), ["playlist"])
        XCTAssertEqual(manager.owners.count, 1)
        manager.removeDownloads(for: album)
        XCTAssertFalse(manager.isReady(track))
        XCTAssertTrue(manager.downloadedPlaylists.isEmpty)
        XCTAssertEqual(manager.knownCollectionTracks(for: playlist).map(\.id), ["track"])
        XCTAssertEqual(manager.audioBytes, 0)
        _ = await manager.clearAccount()
    }

    func testLocalSearchMatchesRelatedContainersAndOnlyPlayableSongs() async throws {
        var track = item("ready")
        track.album = .init(id: "album", title: "Synthetic album")
        track.artist = .init(id: "artist", title: "Synthetic artist")
        let unavailable = item("unavailable")
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: try root(),
            transfer: transfer, monitorConnectivity: false)
        manager.rememberCollection(
            item("playlist", kind: .playlist), tracks: [track, unavailable], complete: true)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.isReady(track) }
        let first = manager.localSearch(query: " synthetic ", limit: 2)
        XCTAssertEqual(first.items.count, 2)
        XCTAssertEqual(first.nextStartIndex, 2)
        let second = manager.localSearch(query: "SYNTHETIC", startIndex: 2, limit: 2)
        XCTAssertEqual(second.items.count, 2)
        XCTAssertNil(second.nextStartIndex)
        XCTAssertEqual(
            Set((first.items + second.items).map(\.id)), ["ready", "album", "artist", "playlist"])
        XCTAssertEqual(
            manager.localSearch(query: "fixture", kind: .track).items.map(\.id), ["ready"])
        XCTAssertEqual(
            Set(manager.localCatalogItems().map(\.id)), ["ready", "album", "artist", "playlist"])
        XCTAssertEqual(manager.localCatalogItems(kind: .track).map(\.id), ["ready"])
        XCTAssertTrue(manager.localSearch(query: " ").items.isEmpty)
        XCTAssertTrue(manager.localSearch(query: "synthetic", startIndex: Int.max).items.isEmpty)
        _ = await manager.clearAccount()
        XCTAssertTrue(manager.localSearch(query: "synthetic").items.isEmpty)
        XCTAssertTrue(manager.localCatalogItems().isEmpty)
    }

    func testIncompleteRefreshPreservesLastCompleteMembershipAndPublishesOnlyChanges() throws {
        let directory = try root()
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: []), root: directory,
            transfer: transfer, monitorConnectivity: false)
        let playlist = item("playlist", kind: .playlist)
        let first = item("first")
        let second = item("second")
        manager.rememberCollection(playlist, tracks: [first, second], complete: true)
        let revision = manager.catalogRevision
        manager.rememberCollection(playlist, tracks: [first], complete: false)
        XCTAssertEqual(manager.catalogRevision, revision)
        XCTAssertEqual(manager.knownCollectionTracks(for: playlist).map(\.id), ["first", "second"])
        XCTAssertTrue(manager.hasCompleteCollectionSnapshot(for: playlist))
        manager.rememberCollection(playlist, tracks: [second], complete: true)
        XCTAssertEqual(manager.catalogRevision, revision + 1)
        XCTAssertEqual(manager.knownCollectionTracks(for: playlist).map(\.id), ["second"])
        manager.rememberCollection(playlist, tracks: [second], complete: true)
        XCTAssertEqual(manager.catalogRevision, revision + 1)
        let saved = try FoundationDownloadStorage.load(
            directory: FoundationDownloadStorage.directory(scope: "fixture", root: directory))
        XCTAssertEqual(saved.collections?.first?.tracks.map(\.id), ["second"])
        XCTAssertTrue(manager.owners.isEmpty)
        manager.invalidate()
    }

    func testRememberedCollectionMetadataHasBoundedRecordRetention() throws {
        let directory = try root()
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: []), root: directory,
            transfer: transfer, monitorConnectivity: false)
        for index in 0..<140 {
            manager.rememberCollection(
                item("playlist-\(index)", kind: .playlist), tracks: [], complete: true)
        }
        let saved = try FoundationDownloadStorage.load(
            directory: FoundationDownloadStorage.directory(scope: "fixture", root: directory))
        XCTAssertEqual(saved.collections?.count, 128)
        XCTAssertEqual(saved.collections?.first?.item.id, "playlist-12")
        manager.invalidate()
    }

    func testSharedTransferProgressUsesMeasuredCurrentTrackAndRejectsCancelledCallback()
        async throws
    {
        let first = item("first")
        let second = item("second")
        let gate = DownloadGate()
        let reporter = DownloadProgressReporter()
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [first, second]), root: try root(),
            transfer: { _, destination, _, progress in
                await reporter.install(progress)
                await gate.wait()
                try Task.checkCancellation()
                try Data("synthetic audio".utf8).write(to: destination)
            }, monitorConnectivity: false)
        let playlist = item("playlist", kind: .playlist)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        XCTAssertEqual(manager.transferOwner(for: playlist)?.state, .queued)
        try await waitUntilAsync { await gate.started }
        XCTAssertEqual(manager.transferOwner(for: first)?.activeTrackID, "first")
        XCTAssertNil(manager.transferOwner(for: first)?.activeTrackProgress)
        XCTAssertEqual(manager.transferOwner(for: second)?.activeTrackID, "first")
        await reporter.report(5, nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(manager.transferOwner(for: first)?.activeTrackProgress)
        await reporter.report(5, 20)
        try await waitUntil { manager.transferOwner(for: first)?.activeTrackProgress == 0.25 }
        // Cancelling a different queued owner must not revoke the active owner's progress callbacks.
        manager.download(second)
        XCTAssertEqual(manager.transferOwner(for: second)?.state, .queued)
        manager.cancel(ownerID: "track:second")
        await reporter.report(10, 20)
        try await waitUntil { manager.transferOwner(for: first)?.activeTrackProgress == 0.5 }
        manager.cancel(ownerID: "playlist:playlist")
        await reporter.report(20, 20)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(manager.transferOwner(for: first)?.activeTrackID)
        XCTAssertNil(manager.transferOwner(for: first)?.activeTrackProgress)
        XCTAssertEqual(manager.transferOwner(for: first)?.state, .cancelled)
        await gate.resume()
        _ = await manager.clearAccount()
    }

    func testSharedRetentionDuplicatesAndPlaybackLeaseDelayDeletion() async throws {
        let track = item("track")
        let library = DownloadsLibrary(tracks: [track, track])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(item("playlist", kind: .playlist))
        try await waitUntil { manager.owners.first?.state == .ready }
        let playlistID = try XCTUnwrap(manager.owners.first?.id)
        XCTAssertEqual(manager.readyTracks(ownerID: playlistID).map(\.id), ["track", "track"])
        manager.download(track)
        try await waitUntil {
            manager.owners.count == 2 && manager.owners.allSatisfy { $0.state == .ready }
        }
        let resource = try await manager.playbackResource(for: track)
        manager.remove(ownerID: playlistID)
        XCTAssertTrue(manager.isReady(track))
        manager.remove(ownerID: "track:track")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resource.url.path))
        await resource.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: resource.url.path))
        XCTAssertFalse(manager.isReady(track))
        _ = await manager.clearAccount()
    }

    func testAccountCleanupWaitsForAllPlaybackLeasesBeforeReportingSuccess() async throws {
        let track = item("track")
        let directory = try root()
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: directory,
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.isReady(track) }
        let first = try await manager.playbackResource(for: track)
        let second = try await manager.playbackResource(for: track)
        var result: Bool?
        let cleanup = Task { result = await manager.clearAccount(waitForPlayback: true) }
        // The account is retired immediately, while native items still own both files leases.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        await first.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        await second.release()
        await cleanup.value
        XCTAssertEqual(result, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: account.path))
        XCTAssertTrue(manager.owners.isEmpty)
        XCTAssertEqual(manager.storageBytes, 0)
    }

    func testCancelledAccountCleanupWaitDoesNotHangOrDeleteLeasedAudio() async throws {
        let track = item("track")
        let directory = try root()
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: directory,
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.isReady(track) }
        let resource = try await manager.playbackResource(for: track)
        let cleanup = Task { await manager.clearAccount(waitForPlayback: true) }
        for _ in 0..<20 { await Task.yield() }
        cleanup.cancel()
        let cleared = await cleanup.value
        XCTAssertFalse(cleared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resource.url.path))
        await resource.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: account.path))
    }

    func testCancellationRacingFinalLeaseReleaseStillRemovesAccountFiles() async throws {
        let track = item("track")
        let directory = try root()
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: directory,
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.isReady(track) }
        let resource = try await manager.playbackResource(for: track)
        let cleanup = Task { await manager.clearAccount(waitForPlayback: true) }
        for _ in 0..<20 { await Task.yield() }
        cleanup.cancel()
        // Deliberately release before joining cleanup, unlike the retained-lease cancellation case.
        await resource.release()
        _ = await cleanup.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: account.path))
    }

    func testCellularDefaultCancellationAndExplicitRetry() async throws {
        let track = item("track")
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: try root(),
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isConnected: true, usesWiFi: false)
        manager.download(track)
        XCTAssertEqual(manager.owners.first?.state, .waitingForWiFi)
        manager.cancel(ownerID: "track:track")
        manager.setAllowsCellular(true)
        XCTAssertEqual(manager.owners.first?.state, .cancelled)
        XCTAssertFalse(manager.isReady(track))
        manager.retry(ownerID: "track:track")
        try await waitUntil { manager.owners.first?.state == .ready }
        _ = await manager.clearAccount()
    }

    func testFailedPlaylistRefreshPreservesSnapshotAndSharedFile() async throws {
        let track = item("track")
        let library = DownloadsLibrary(tracks: [track, track])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(item("playlist", kind: .playlist))
        try await waitUntil { manager.owners.first?.state == .ready }
        await library.setFailure(true)
        manager.reconcilePlaylists()
        try await waitUntil { manager.errorMessage != nil }
        XCTAssertEqual(manager.owners.first?.tracks.map(\.id), ["track", "track"])
        XCTAssertTrue(manager.isReady(track))
        _ = await manager.clearAccount()
    }

    func testRelaunchRejectsSameLengthCorruptionAndRemovesStaging() async throws {
        let track = item("track")
        let directory = try root()
        let library = DownloadsLibrary(tracks: [track])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .ready }
        let resource = try await manager.playbackResource(for: track)
        await resource.release()
        manager.invalidate()
        let bytes = try Data(contentsOf: resource.url).count
        try Data(repeating: 0, count: bytes).write(to: resource.url)
        let staging = resource.url.deletingLastPathComponent().appendingPathComponent(
            "stage-interrupted")
        try Data("partial".utf8).write(to: staging)
        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        try await waitUntil { !restored.isLoading }
        XCTAssertFalse(restored.isReady(track))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(restored.owners.first?.state, .waitingForWiFi)
        _ = await restored.clearAccount()
    }

    func testOfflineRelaunchRetainsReadyOccurrencesWithoutAnotherTransfer() async throws {
        let track = item("track")
        let directory = try root()
        let library = DownloadsLibrary(tracks: [track, track])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(item("playlist", kind: .playlist))
        try await waitUntil { manager.owners.first?.state == .ready }
        manager.invalidate()
        await library.setFailure(true)

        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory,
            transfer: { _, _, _, _ in
                XCTFail("Offline restoration must not start another transfer")
                throw FoundationLibraryError.unavailable
            }, monitorConnectivity: false)
        try await waitUntil { !restored.isLoading }
        XCTAssertEqual(restored.owners.first?.state, .ready)
        XCTAssertEqual(
            restored.readyTracks(ownerID: "playlist:playlist").map(\.id), ["track", "track"])
        XCTAssertFalse(restored.allowsCellular)
        let resource = try await restored.playbackResource(for: track)
        XCTAssertTrue(resource.url.isFileURL)
        XCTAssertEqual(try Data(contentsOf: resource.url), Data("synthetic audio".utf8))
        await resource.release()
        let cleared = await restored.clearAccount()
        XCTAssertTrue(cleared)
    }

    func testStoredFilesRetainProtectionAfterManifestReplacement() async throws {
        let track = item("track")
        let directory = try root()
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: directory,
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .ready }
        let resource = try await manager.playbackResource(for: track)
        let manifest = account.appendingPathComponent("manifest.json")
        for cellular in [true, false] {
            // Each settings save atomically replaces the manifest, so verify the resulting inode.
            manager.setAllowsCellular(cellular)
            XCTAssertEqual(
                try FoundationDownloadStorage.load(directory: account).allowsCellular, cellular)
            for url in [account, manifest, resource.url] {
                XCTAssertEqual(
                    try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
                        .isExcludedFromBackup,
                    true)
                #if os(macOS)
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    XCTAssertEqual(
                        (attributes[.posixPermissions] as? NSNumber)?.intValue,
                        url == account ? 0o700 : 0o600)
                #endif
            }
        }
        await resource.release()
        let cleared = await manager.clearAccount()
        XCTAssertTrue(cleared)
    }

    #if os(iOS)
        func testPhysicalIOSStorageProtection() async throws {
            #if targetEnvironment(simulator)
                throw XCTSkip(
                    "Simulator does not expose iOS Data Protection; requires a signed device run")
            #else
                let track = item("track")
                let directory = try root()
                let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
                let manager = FoundationDownloads(
                    scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: directory,
                    transfer: transfer, monitorConnectivity: false)
                manager.updateConnectivity(isAllowed: true)
                manager.download(track)
                try await waitUntil { manager.isReady(track) }
                let resource = try await manager.playbackResource(for: track)
                for cellular in [true, false] {
                    manager.setAllowsCellular(cellular)
                    for url in [
                        account, account.appendingPathComponent("manifest.json"), resource.url,
                    ] {
                        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                        XCTAssertEqual(
                            attributes[.protectionKey] as? FileProtectionType,
                            .completeUntilFirstUserAuthentication)
                    }
                }
                await resource.release()
                let cleared = await manager.clearAccount()
                XCTAssertTrue(cleared)
            #endif
        }
    #endif

    func testAccountCleanupDoesNotRemoveAnotherScopesReadyFile() async throws {
        let track = item("track")
        let directory = try root()
        let library = DownloadsLibrary(tracks: [track])
        let first = FoundationDownloads(
            scope: "first-account", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        let second = FoundationDownloads(
            scope: "second-account", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        first.updateConnectivity(isAllowed: true)
        first.download(track)
        try await waitUntil { first.isReady(track) }
        XCTAssertFalse(second.isReady(track))
        second.updateConnectivity(isAllowed: true)
        second.download(track)
        try await waitUntil { second.isReady(track) }
        let resource = try await second.playbackResource(for: track)
        let cleared = await first.clearAccount()
        XCTAssertTrue(cleared)
        XCTAssertTrue(second.isReady(track))
        XCTAssertEqual(try Data(contentsOf: resource.url), Data("synthetic audio".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: FoundationDownloadStorage.directory(
                    scope: "first-account", root: directory
                ).path))
        await resource.release()
        let secondCleared = await second.clearAccount()
        XCTAssertTrue(secondCleared)
    }

    func testStorageFailureStaysUnavailableAndCanBeExplicitlyRetried() async throws {
        let track = item("track")
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: try root(),
            transfer: { _, destination, _, _ in
                try Data("partial".utf8).write(to: destination)
                throw CocoaError(.fileWriteOutOfSpace)
            }, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .failed }
        XCTAssertFalse(manager.isReady(track))
        XCTAssertNotNil(manager.errorMessage)
        let cleared = await manager.clearAccount()
        XCTAssertTrue(cleared)
    }

    func testLateTransferAfterAccountInvalidationCannotPublish() async throws {
        let track = item("track")
        let gate = DownloadGate()
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: try root(),
            transfer: { _, destination, _, _ in
                await gate.wait()
                try Data("late result".utf8).write(to: destination)
            }, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .downloading }
        // Ensure the transfer reached its suspension seam, then invalidate its account.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.started), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await gate.started else {
            XCTFail("Transfer did not start")
            return
        }
        manager.invalidate()
        await gate.resume()
        let cleared = await manager.clearAccount()
        XCTAssertTrue(cleared)
        XCTAssertFalse(manager.isReady(track))
        XCTAssertEqual(manager.owners.count, 0)
    }

    func testPlaylistReconciliationAddsAndReordersWithoutDroppingExplicitRetention() async throws {
        let first = item("first")
        let second = item("second")
        let library = DownloadsLibrary(tracks: [first, first])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(item("playlist", kind: .playlist))
        manager.download(first)
        try await waitUntil {
            manager.owners.count == 2 && manager.owners.allSatisfy { $0.state == .ready }
        }
        await library.setTracks([second, second])
        manager.reconcilePlaylists()
        try await waitUntil {
            manager.owners.first?.tracks.map(\.id) == ["second", "second"]
                && manager.isReady(second)
        }
        XCTAssertTrue(manager.isReady(first))
        XCTAssertEqual(
            manager.readyTracks(ownerID: "playlist:playlist").map(\.id), ["second", "second"])
        _ = await manager.clearAccount()
    }

    #if DEBUG

        func testRecreatedCoverKeepsRenderedLeafWhileReleasedPreviewUpgradesToFull() async throws {
            let directory = try root()
            let data = try artworkData(width: 640, height: 640)
            // Match production's independent artwork-cache and downloaded-media owners.
            let cacheRoot = directory.appendingPathComponent("artwork-cache", isDirectory: true)
            let cache = FoundationArtworkCache(scope: "recreated-view", root: cacheRoot)
            addTeardownBlock { _ = await cache.invalidate(removeDisk: true) }
            let gate = RecreatedArtworkReadGate()
            addTeardownBlock { await gate.release() }
            let library = FoundationJellyfinLibrary(
                session: .init(
                    serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic",
                    userID: "user", deviceID: "device"),
                load: { _ in
                    await gate.recordGET()
                    XCTFail("Recreated warm covers must not need another artwork GET")
                    throw FoundationLibraryError.unavailable
                }, artworkCache: cache)
            let album = FoundationItem(
                id: "11111111111111111111111111111111", title: "Synthetic cover", subtitle: "",
                kind: .album, duration: nil, primaryImageTag: "first")
            _ = try await cache.result(
                for: album, pixels: 640, allowsNetwork: true, load: { _, _ in data })
            // Real Home-sized pressure evicts the full rendition while retaining its preview.
            for index in 0..<23 {
                let sibling = FoundationItem(
                    id: String(format: "%032x", index + 1), title: "Sibling", subtitle: "",
                    kind: .album, duration: nil, primaryImageTag: "first")
                _ = try await cache.result(
                    for: sibling, pixels: 640, allowsNetwork: true, load: { _, _ in data })
            }
            await cache.flushPersistence()
            let preview = try XCTUnwrap(cache.immediateResult(for: album, pixels: 640))
            XCTAssertEqual(preview.image.width, 160)
            let expectedPreview = Image(decorative: preview.image, scale: 1)
            let manager = FoundationDownloads(
                scope: "recreated-view", library: library, root: directory,
                monitorConnectivity: false)
            defer { manager.invalidate() }
            let records =
                FileManager.default.enumerator(
                    at: cacheRoot, includingPropertiesForKeys: nil)?.allObjects
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "art" } ?? []
            XCTAssertEqual(records.count, 24, "Download inventory must not remove artwork records")
            XCTAssertTrue(records.allSatisfy { $0.lastPathComponent.hasSuffix("-640.art") })
            let connectivity = FoundationConnectivity(monitorConnectivity: false, retry: {})
            let state = RecreatedArtworkState()
            let content = RecreatedArtworkHost(
                state: state, item: album, library: library, gate: gate
            )
            .environmentObject(manager).environmentObject(connectivity)
            .environment(\.displayScale, 3)
            #if os(macOS)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: content)
                window.orderFront(nil)
                defer { window.close() }
            #else
                let scene = try XCTUnwrap(
                    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene)
                window.rootViewController = UIHostingController(rootView: content)
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
            #endif
            let initial = state.incarnation
            try await waitUntil { state.leafFrames[initial]?.last?.image == expectedPreview }
            try await waitUntilAsync { await gate.begun >= 1 }
            state.incarnation = UUID()
            let recreated = state.incarnation
            try await waitUntil { state.leafFrames[recreated]?.last?.image == expectedPreview }
            try await waitUntilAsync { await gate.begun >= 2 }
            XCTAssertNotEqual(
                state.leafFrames[initial]?.first?.lifetime,
                state.leafFrames[recreated]?.first?.lifetime,
                "This check must actually recreate the artwork node")
            XCTAssertEqual(state.firstFrames[recreated]?.image, expectedPreview)
            XCTAssertNil(state.completed[recreated], "The upgrade has not been released")
            await gate.release()
            // Await an actual leaf update with the full bitmap, not just task completion or
            // a held first-body observation. No animation-duration sleep is needed.
            try await waitUntil {
                guard state.completed[recreated] == true,
                    let full = cache.immediateResult(for: album, pixels: 640),
                    full.image.width == 640
                else { return false }
                return state.leafFrames[recreated]?.last?.image
                    == Image(decorative: full.image, scale: 1)
            }
            let frames = try XCTUnwrap(state.leafFrames[recreated])
            XCTAssertEqual(
                Set(frames.map(\.lifetime)).count, 1,
                "A same-cover resolution upgrade must not replace the rendered image leaf")
            XCTAssertTrue(frames.allSatisfy { $0.image != nil })
            XCTAssertTrue(state.renderedImages[recreated]?.allSatisfy { $0 != nil } == true)
            XCTAssertEqual(cache.immediateResult(for: album, pixels: 640)?.image.width, 640)
            let requests = await gate.requests
            XCTAssertEqual(requests, 0)
            let pending = await gate.pending
            XCTAssertEqual(pending, 0)
        }
        func testTwentyFourCoverWorkingSetRecreationDrawsBeforeAsyncDiskRead() async throws {
            let directory = try root()
            let data = try artworkData(width: 640, height: 640)
            let cache = FoundationArtworkCache(scope: "recreated-view", root: directory)
            addTeardownBlock { _ = await cache.invalidate(removeDisk: true) }
            let gate = RecreatedArtworkReadGate()
            addTeardownBlock { await gate.release() }
            let library = FoundationJellyfinLibrary(
                session: .init(
                    serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic",
                    userID: "user", deviceID: "device"),
                load: { _ in
                    await gate.recordGET()
                    XCTFail("Recreated warm covers must not need another artwork GET")
                    throw FoundationLibraryError.unavailable
                }, artworkCache: cache)
            let album = FoundationItem(
                id: "11111111111111111111111111111111", title: "Synthetic cover", subtitle: "",
                kind: .album, duration: nil, primaryImageTag: "first")
            let albums = (0..<24).map { index in
                FoundationItem(
                    id: String(format: "%032x", index + 1), title: "Synthetic cover", subtitle: "",
                    kind: .album, duration: nil, primaryImageTag: "first")
            }
            for entry in albums {
                _ = try await cache.result(
                    for: entry, pixels: 640, allowsNetwork: true, load: { _, _ in data })
                let usage = await cache.usage()
                XCTAssertLessThanOrEqual(usage.memory, 16 * 1_024 * 1_024)
            }
            let expected = albums.map { entry in
                cache.immediateResult(for: entry, pixels: 640).map {
                    Image(decorative: $0.image, scale: 1)
                }
            }
            XCTAssertEqual(cache.immediateResult(for: albums[0], pixels: 640)?.image.width, 160)
            let manager = FoundationDownloads(
                scope: "recreated-view", library: library, root: directory,
                monitorConnectivity: false)
            defer { manager.invalidate() }
            let connectivity = FoundationConnectivity(monitorConnectivity: false, retry: {})
            let state = RecreatedArtworkState()
            state.select(albums[0])
            let content = RecreatedArtworkHost(
                state: state, item: album, library: library, gate: gate
            )
            .environmentObject(manager).environmentObject(connectivity)
            .environment(\.displayScale, 3)
            #if os(macOS)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: content)
                window.orderFront(nil)
                defer { window.close() }
            #else
                let scene = try XCTUnwrap(
                    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene)
                window.rootViewController = UIHostingController(rootView: content)
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
            #endif
            for index in albums.indices {
                if index > 0 {
                    state.select(albums[index])
                }
                let identity = state.incarnation
                try await waitUntil { state.firstFrames[identity] != nil }
                try await waitUntilAsync { await gate.begun >= index + 1 }
                let first = try XCTUnwrap(state.firstFrames[identity])
                XCTAssertNotNil(
                    first.image, "A recreated loaded cover must never start as a placeholder")
                XCTAssertEqual(
                    first.image, expected[index],
                    "Every cover must draw its retained preview or full image before async load")
                XCTAssertNil(state.completed[identity], "The asynchronous disk path is still held")
            }
            await gate.release()
            try await waitUntil { state.completed[state.incarnation] == true }
            let requests = await gate.requests
            XCTAssertEqual(requests, 0)
            let pending = await gate.pending
            XCTAssertEqual(pending, 0)
        }
        func testRecreatedArtworkFirstDrawUsesWarmDecodedCoverWhileAsyncReadIsHeld() async throws {
            let directory = try root()
            let data = try artworkData()
            let cache = FoundationArtworkCache(scope: "recreated-view", root: directory)
            addTeardownBlock { _ = await cache.invalidate(removeDisk: true) }
            let gate = RecreatedArtworkReadGate()
            addTeardownBlock { await gate.release() }
            let library = FoundationJellyfinLibrary(
                session: .init(
                    serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic",
                    userID: "user", deviceID: "device"),
                load: { _ in
                    await gate.recordGET()
                    XCTFail("Recreated warm covers must not need another artwork GET")
                    throw FoundationLibraryError.unavailable
                }, artworkCache: cache)
            let album = FoundationItem(
                id: "11111111111111111111111111111111", title: "Synthetic cover", subtitle: "",
                kind: .album, duration: nil, primaryImageTag: "first")
            let cached = try await cache.result(
                for: album, pixels: 160, allowsNetwork: true, load: { _, _ in data })
            let expected = Image(decorative: try XCTUnwrap(cached).image, scale: 1)
            let manager = FoundationDownloads(
                scope: "recreated-view", library: library, root: directory,
                monitorConnectivity: false)
            defer { manager.invalidate() }
            let connectivity = FoundationConnectivity(monitorConnectivity: false, retry: {})
            let state = RecreatedArtworkState()
            let content = RecreatedArtworkHost(
                state: state, item: album, library: library, gate: gate
            )
            .environmentObject(manager).environmentObject(connectivity)
            .environment(\.displayScale, 1)
            #if os(macOS)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: content)
                window.orderFront(nil)
                defer { window.close() }
            #else
                let scene = try XCTUnwrap(
                    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene)
                window.rootViewController = UIHostingController(rootView: content)
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
            #endif
            for incarnation in 1...3 {
                if incarnation > 1 { state.incarnation = UUID() }
                let identity = state.incarnation
                try await waitUntil { state.firstFrames[identity] != nil }
                try await waitUntilAsync { await gate.begun >= incarnation }
                let first = try XCTUnwrap(state.firstFrames[identity])
                XCTAssertEqual(
                    first.image, expected,
                    "Recreated view \(incarnation) must draw its warm cover before any asynchronous read"
                )
                XCTAssertNil(state.completed[identity], "The asynchronous read is still held")
            }
            await gate.release()
            try await waitUntil { state.completed[state.incarnation] == true }
            let requests = await gate.requests
            XCTAssertEqual(requests, 0)
            let pending = await gate.pending
            XCTAssertEqual(pending, 0)
        }
        func testRemovedAndRecreatedPlaylistRejectsOldReconciliationSnapshot() async throws {
            let oldTrack = item("old-owner-track")
            let newTrack = item("new-owner-track")
            let playlist = item("recreated-playlist", kind: .playlist)
            let library = DownloadsLibrary(tracks: [oldTrack])
            let manager = FoundationDownloads(
                scope: "recreated-owner", library: library, root: try root(), transfer: transfer,
                monitorConnectivity: false)
            manager.updateConnectivity(isAllowed: true)
            manager.download(playlist)
            try await waitUntil { manager.owners.first?.state == .ready }
            let canonical = manager.collectionModel(for: playlist)
            XCTAssertEqual(canonical.items.map(\.id), [oldTrack.id])

            // Snapshot A has completed before the real manager awaits permissions.
            let gate = DownloadGate()
            await library.setPermissionGate(gate)
            manager.reconcilePlaylists()
            try await waitUntilAsync { await gate.started }
            manager.remove(ownerID: "playlist:" + playlist.id)
            await library.setTracks([newTrack])
            manager.download(playlist)
            try await waitUntil {
                manager.owners.first?.state == .ready && manager.isReady(newTrack)
            }
            let resource = try await manager.playbackResource(
                for: newTrack, allowsRemoteFallback: false)
            let newFile = resource.url
            await resource.release()
            XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path))
            XCTAssertEqual(canonical.items.map(\.id), [newTrack.id])

            // Join actual reconciliation, without a sleep or synthetic publication callback.
            await gate.resume()
            await manager.waitForCurrentReconciliationForTesting()
            XCTAssertEqual(manager.owners.first?.tracks.map(\.id), [newTrack.id])
            XCTAssertEqual(canonical.items.map(\.id), [newTrack.id])
            XCTAssertEqual(manager.knownCollectionTracks(for: playlist).map(\.id), [newTrack.id])
            XCTAssertTrue(manager.isReady(newTrack))
            XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path))
            let requestedTracks = await library.downloadSourceIDs
            XCTAssertEqual(requestedTracks, [oldTrack.id, newTrack.id])
            _ = await manager.clearAccount()
        }
        func testExplicitPlaylistReacquisitionRejectsOlderReconciliationSnapshot() async throws {
            let oldTrack = item("old-owner-track")
            let newTrack = item("new-owner-track")
            let playlist = item("reacquired-playlist", kind: .playlist)
            let library = DownloadsLibrary(tracks: [oldTrack])
            let manager = FoundationDownloads(
                scope: "reacquired-owner", library: library, root: try root(), transfer: transfer,
                monitorConnectivity: false)
            manager.updateConnectivity(isAllowed: true)
            manager.download(playlist)
            try await waitUntil { manager.owners.first?.state == .ready }
            let canonical = manager.collectionModel(for: playlist)
            XCTAssertEqual(canonical.items.map(\.id), [oldTrack.id])

            // Snapshot A has completed before the real manager awaits permissions.
            let gate = DownloadGate()
            await library.setPermissionGate(gate)
            manager.reconcilePlaylists()
            try await waitUntilAsync { await gate.started }
            await library.setTracks([newTrack])
            // The same retained owner receives a newer explicit Download Again intent.
            manager.downloadAgain(playlist)
            try await waitUntil {
                manager.owners.first?.state == .ready && manager.isReady(newTrack)
            }
            let resource = try await manager.playbackResource(
                for: newTrack, allowsRemoteFallback: false)
            let newFile = resource.url
            await resource.release()
            XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path))
            XCTAssertEqual(canonical.items.map(\.id), [newTrack.id])

            // Join actual reconciliation, without a sleep or synthetic publication callback.
            await gate.resume()
            await manager.waitForCurrentReconciliationForTesting()
            XCTAssertEqual(manager.owners.first?.tracks.map(\.id), [newTrack.id])
            XCTAssertEqual(canonical.items.map(\.id), [newTrack.id])
            XCTAssertEqual(manager.knownCollectionTracks(for: playlist).map(\.id), [newTrack.id])
            XCTAssertTrue(manager.isReady(newTrack))
            XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path))
            let requestedTracks = await library.downloadSourceIDs
            XCTAssertEqual(requestedTracks, [oldTrack.id, newTrack.id])
            _ = await manager.clearAccount()
        }
        func testFailedExplicitPlaylistReacquisitionPreservesCurrentReconciliation() async throws {
            let directory = try root()
            let first = item("original-track")
            let refreshed = item("valid-refresh-track")
            let rejected = item("failed-intent-track")
            let playlist = item("failed-reacquisition", kind: .playlist)
            let library = DownloadsLibrary(tracks: [first])
            let manager = FoundationDownloads(
                scope: "failed-reacquisition", library: library, root: directory,
                transfer: transfer,
                monitorConnectivity: false)
            manager.updateConnectivity(isAllowed: true)
            manager.download(playlist)
            try await waitUntil { manager.owners.first?.state == .ready }
            let canonical = manager.collectionModel(for: playlist)

            // B is a valid in-flight refresh of the retained owner A.
            await library.setTracks([refreshed])
            let gate = DownloadGate()
            await library.setPermissionGate(gate)
            manager.reconcilePlaylists()
            try await waitUntilAsync { await gate.started }

            // C's newer explicit intent cannot commit because its real manifest save fails.
            await library.setTracks([rejected])
            let target = FoundationDownloadStorage.directory(
                scope: "failed-reacquisition", root: directory
            ).appendingPathComponent("manifest.json")
            let saved = try Data(contentsOf: target)
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            manager.downloadAgain(playlist)
            XCTAssertNotNil(manager.errorMessage)
            XCTAssertEqual(manager.owners.first?.tracks.map(\.id), [first.id])
            XCTAssertEqual(canonical.items.map(\.id), [first.id])
            XCTAssertTrue(manager.isReady(first))
            try FileManager.default.removeItem(at: target)
            try saved.write(to: target)

            await gate.resume()
            await manager.waitForCurrentReconciliationForTesting()
            try await waitUntil { manager.isReady(refreshed) }
            XCTAssertEqual(manager.owners.first?.tracks.map(\.id), [refreshed.id])
            XCTAssertEqual(canonical.items.map(\.id), [refreshed.id])
            XCTAssertEqual(manager.knownCollectionTracks(for: playlist).map(\.id), [refreshed.id])
            let resource = try await manager.playbackResource(
                for: refreshed, allowsRemoteFallback: false)
            XCTAssertTrue(FileManager.default.fileExists(atPath: resource.url.path))
            await resource.release()
            XCTAssertFalse(manager.isReady(rejected))
            let requestedTracks = await library.downloadSourceIDs
            XCTAssertEqual(requestedTracks, [first.id, refreshed.id])
            _ = await manager.clearAccount()
        }
    #endif

    func testUnreadableManifestOffersExplicitLiveRecovery() async throws {
        let directory = try root()
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        try FoundationDownloadStorage.prepare(account)
        try Data("broken JSON".utf8).write(to: account.appendingPathComponent("manifest.json"))
        let track = item("track")
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: directory,
            transfer: transfer, monitorConnectivity: false)
        XCTAssertNotNil(manager.errorMessage)
        let removed = await manager.removeAll()
        XCTAssertTrue(removed)
        XCTAssertNil(manager.errorMessage)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .ready }
        _ = await manager.clearAccount()
    }

    func testRemoveAllPreservesInstalledFileUntilLeaseRelease() async throws {
        let track = item("track")
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: try root(),
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .ready }
        let resource = try await manager.playbackResource(for: track)
        let removed = await manager.removeAll()
        XCTAssertTrue(removed)
        XCTAssertTrue(manager.owners.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resource.url.path))
        await resource.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: resource.url.path))
        _ = await manager.clearAccount()
    }

    func testProjectionsAndFootprintsDeduplicateSharedOccurrences() async throws {
        var first = item("first")
        first.album = FoundationItemReference(
            id: "album", title: "Synthetic album", primaryImageTag: nil)
        let second = item("second")
        let playlist = item("playlist", kind: .playlist)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [first, first, second]),
            root: try root(), transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        manager.download(first)
        try await waitUntil {
            manager.owners.count == 2 && manager.owners.allSatisfy { $0.state == .ready }
        }
        XCTAssertEqual(manager.downloadedSongs.map(\.id), ["first", "second"])
        XCTAssertEqual(manager.browseTracks(for: playlist).map(\.id), ["first", "first", "second"])
        XCTAssertEqual(manager.downloadedPlaylists.map(\.id), ["playlist"])
        XCTAssertEqual(manager.downloadedAlbums.map(\.id), ["album"])
        XCTAssertEqual(manager.availability(for: playlist), .ready)
        XCTAssertEqual(
            manager.availability(for: item("album", kind: .album)), .partial(ready: 1, total: 1))
        let bytes = Int64(Data("synthetic audio".utf8).count)
        XCTAssertEqual(manager.itemBytes(playlist), 2 * bytes)
        XCTAssertEqual(manager.itemBytes(first), bytes)
        XCTAssertEqual(
            manager.reclaimableBytes(ownerIDs: ["playlist:playlist"], trackIDs: []), bytes)
        XCTAssertEqual(
            manager.reclaimableBytes(ownerIDs: ["playlist:playlist", "track:first"], trackIDs: []),
            2 * bytes)
        let lease = try await manager.playbackResource(for: first)
        XCTAssertEqual(manager.reclaimableBytes(ownerIDs: [], trackIDs: ["first"]), 0)
        await lease.release()
        XCTAssertEqual(manager.reclaimableBytes(ownerIDs: [], trackIDs: ["first"]), bytes)
        _ = await manager.clearAccount()
    }

    func testTrackExclusionPreservesSnapshotsAcrossRefreshAndRelaunchUntilDownloadAgain()
        async throws
    {
        let first = item("first")
        let second = item("second")
        let playlist = item("playlist", kind: .playlist)
        let library = DownloadsLibrary(tracks: [first, first, second])
        let directory = try root()
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        manager.download(first)
        try await waitUntil {
            manager.owners.count == 2 && manager.owners.allSatisfy { $0.state == .ready }
        }
        let lease = try await manager.playbackResource(for: first)
        manager.removeTrack(first)
        XCTAssertEqual(manager.owners.count, 1)
        XCTAssertEqual(manager.owners.first?.tracks.map(\.id), ["first", "first", "second"])
        XCTAssertFalse(manager.isReady(first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.url.path))
        let fallback = try await manager.playbackResource(for: first)
        XCTAssertFalse(fallback.url.isFileURL)
        await fallback.release()
        XCTAssertEqual(manager.availability(for: playlist), .partial(ready: 1, total: 3))
        XCTAssertEqual(manager.owners.first?.status, "Partially On Device")
        await library.setTracks([second, first, first])
        manager.reconcilePlaylists()
        try await waitUntil {
            manager.owners.first?.tracks.map(\.id) == ["second", "first", "first"]
        }
        XCTAssertFalse(manager.isReady(first))
        await lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.url.path))
        manager.invalidate()
        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        try await waitUntil { !restored.isLoading }
        restored.updateConnectivity(isAllowed: true)
        restored.reconcilePlaylists()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(restored.isReady(first))
        XCTAssertEqual(restored.browseTracks(for: playlist).map(\.id), ["second"])
        restored.downloadAgain(first)
        try await waitUntil { restored.isReady(first) }
        XCTAssertEqual(restored.availability(for: playlist), .ready)
        XCTAssertEqual(
            restored.browseTracks(for: playlist).map(\.id), ["second", "first", "first"])
        _ = await restored.clearAccount()
    }

    func testAllExcludedSavedCollectionsRemainReachableAfterRelaunchAndRedownload() async throws {
        let directory = try root()
        let track = item("track")
        let playlist = item("playlist", kind: .playlist)
        let album = item("album", kind: .album)
        let library = DownloadsLibrary(tracks: [track, track])
        let original = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        original.updateConnectivity(isAllowed: true)
        original.download(playlist)
        original.download(album)
        try await waitUntil {
            original.owners.count == 2 && original.owners.allSatisfy { $0.state == .ready }
        }
        original.removeTrack(track)
        XCTAssertTrue(original.downloadedSongs.isEmpty)
        XCTAssertEqual(original.downloadedPlaylists.map(\.id), ["playlist"])
        XCTAssertEqual(original.downloadedAlbums.map(\.id), ["album"])
        XCTAssertEqual(original.availability(for: playlist), .unavailable)
        XCTAssertEqual(original.availability(for: album), .unavailable)
        original.invalidate()
        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        try await waitUntil { !restored.isLoading }
        XCTAssertTrue(restored.downloadedSongs.isEmpty)
        XCTAssertEqual(restored.downloadedPlaylists.map(\.id), ["playlist"])
        XCTAssertEqual(restored.downloadedAlbums.map(\.id), ["album"])
        XCTAssertEqual(restored.owners.first?.tracks.map(\.id), ["track", "track"])
        XCTAssertTrue(restored.browseTracks(for: playlist).isEmpty)
        XCTAssertEqual(restored.availability(for: playlist), .unavailable)
        restored.updateConnectivity(isAllowed: true)
        restored.downloadAgain(playlist)
        try await waitUntil { restored.isReady(track) }
        XCTAssertEqual(restored.browseTracks(for: playlist).map(\.id), ["track", "track"])
        XCTAssertEqual(restored.availability(for: playlist), .ready)
        XCTAssertEqual(restored.availability(for: album), .ready)
        XCTAssertEqual(restored.downloadedSongs.map(\.id), ["track"])
        _ = await restored.clearAccount()
    }

    func testVersionOneManifestMigratesWithoutChangingRetainedMediaOrOccurrences() async throws {
        let directory = try root()
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        try FoundationDownloadStorage.prepare(account)
        let track = item("track")
        let fileURL = account.appendingPathComponent("fixture.mp3")
        let data = Data("synthetic audio".utf8)
        try data.write(to: fileURL)
        var manifest = FoundationDownloadManifest()
        manifest.version = 1
        manifest.owners = [
            .init(
                id: "playlist:playlist",
                item: FoundationStoredDownloadItem(item("playlist", kind: .playlist)),
                tracks: [FoundationStoredDownloadItem(track), FoundationStoredDownloadItem(track)],
                paused: false, expanded: true)
        ]
        manifest.files = [
            track.id: .init(
                name: "fixture.mp3", bytes: Int64(data.count),
                digest: try FoundationDownloadStorage.digest(fileURL))
        ]
        try FoundationDownloadStorage.save(manifest, directory: account)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: []), root: directory,
            transfer: transfer, monitorConnectivity: false)
        try await waitUntil { !manager.isLoading }
        XCTAssertTrue(manager.isReady(track))
        XCTAssertEqual(manager.readyTracks(ownerID: "playlist:playlist").count, 2)
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
        let migrated = try FoundationDownloadStorage.load(directory: account)
        XCTAssertEqual(migrated.version, 2)
        XCTAssertNotEqual(migrated.owners.first?.reacquiresExcludedTracks, true)
        XCTAssertTrue(migrated.excludedTrackIDs?.isEmpty ?? true)
        _ = await manager.clearAccount()
    }

    func testFailedRemovalAndRedownloadManifestWritesRollBackIntentAndReadiness() async throws {
        let directory = try root()
        let track = item("track")
        let playlist = item("playlist", kind: .playlist)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track, track]), root: directory,
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        manager.updateConnectivity(isAllowed: false)
        let target = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
            .appendingPathComponent("manifest.json")
        let saved = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        manager.removeSelected(ownerIDs: ["playlist:playlist"], trackIDs: ["track"])
        XCTAssertTrue(manager.isReady(track))
        XCTAssertEqual(manager.owners.first?.tracks.count, 2)
        XCTAssertNotNil(manager.errorMessage)
        try FileManager.default.removeItem(at: target)
        try saved.write(to: target)
        manager.removeTrack(track)
        XCTAssertFalse(manager.isReady(track))
        let excluded = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        manager.downloadAgain(track)
        XCTAssertFalse(manager.isReady(track))
        XCTAssertEqual(manager.owners.count, 1)
        try FileManager.default.removeItem(at: target)
        try excluded.write(to: target)
        manager.updateConnectivity(isAllowed: true)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(manager.isReady(track))
        _ = await manager.clearAccount()
    }

    func testTrackRemovalRejectsLateTransferDespitePreservedSnapshot() async throws {
        let gate = DownloadGate()
        let track = item("track")
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track, track]), root: try root(),
            transfer: { _, destination, _, _ in
                await gate.wait()
                try Data("late result".utf8).write(to: destination)
            }, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(item("playlist", kind: .playlist))
        try await waitUntilAsync { await gate.started }
        manager.removeTrack(track)
        await gate.resume()
        try await waitUntil { manager.owners.first?.state == .ready }
        XCTAssertFalse(manager.isReady(track))
        XCTAssertEqual(manager.owners.first?.tracks.count, 2)
        XCTAssertTrue(manager.downloadedSongs.isEmpty)
        _ = await manager.clearAccount()
    }

    #if DEBUG
        func
            testArtworkVisibilityReentryKeepsEquivalentRetainedCoverWithoutAnotherDecodePublication()
            async throws
        {
            var track = artworkTrack("track")
            track.album = .init(
                id: "11111111111111111111111111111111", title: "Synthetic album",
                primaryImageTag: "first")
            let data = try artworkData()
            let downloadLibrary = DownloadsLibrary(tracks: [track])
            await downloadLibrary.setArtwork(data)
            let directory = try root()
            let manager = FoundationDownloads(
                scope: "fixture", library: downloadLibrary, root: directory, transfer: transfer,
                monitorConnectivity: false)
            defer { manager.invalidate() }
            manager.updateConnectivity(isAllowed: true)
            manager.download(track)
            try await waitUntil(timeout: .seconds(15)) {
                manager.artworkBytes > 0 && manager.owners.allSatisfy { $0.state == .ready }
            }
            XCTAssertNotNil(manager.retainedArtworkIdentity(for: track))
            let cache = FoundationArtworkCache(scope: "hosted", root: directory)
            addTeardownBlock { _ = await cache.invalidate(removeDisk: true) }
            let cached = try await cache.result(
                for: track, pixels: 160, allowsNetwork: true, load: { _, _ in data })
            let expected = Image(decorative: try XCTUnwrap(cached).image, scale: 1)
            let library = FoundationJellyfinLibrary(
                session: .init(
                    serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic",
                    userID: "user", deviceID: "device"),
                load: { _ in
                    XCTFail("Visibility reentry must reuse the warm cache, never issue another GET")
                    throw FoundationLibraryError.unavailable
                }, artworkCache: cache)
            let connectivity = FoundationConnectivity(monitorConnectivity: false, retry: {})
            let state = HostedArtworkVisibilityState()
            let content = HostedArtworkVisibilityView(state: state, item: track, library: library)
                .environmentObject(manager).environmentObject(connectivity)
                .environment(\.displayScale, 1)
            #if os(macOS)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: content)
                window.orderFront(nil)
                defer { window.close() }
            #else
                let scene = try XCTUnwrap(
                    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene)
                window.rootViewController = UIHostingController(rootView: content)
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
            #endif
            try await waitUntil { state.image == expected && state.completed[state.phase] == true }
            XCTAssertEqual(
                state.completed[state.phase], true,
                "Initial artwork phase \(state.phase) not completed; observed \(state.completed)")
            let frameBoundary = HostedArtworkFrameBoundary()
            defer { frameBoundary.invalidate() }
            func awaitAppliedFrame(_ phase: UUID) async throws {
                // The task's synchronous defer acknowledges application, not presentation.
                // Do not feed another task identity into the same SwiftUI render frame.
                #if os(macOS)
                    frameBoundary.arm(phase, view: try XCTUnwrap(window.contentView))
                #else
                    frameBoundary.arm(phase)
                #endif
                try await waitUntil { frameBoundary.completed == phase }
                XCTAssertEqual(
                    frameBoundary.completed, phase, "Artwork phase must cross a display frame")
            }
            try await awaitAppliedFrame(state.phase)
            let initial = state.images.count
            for (index, active) in [false, true, false, true].enumerated() {
                // Observe the actual artwork task epoch, not a SwiftUI body callback or image count.
                // A late canceled task carries its old phase and cannot acknowledge this boundary.
                let phase = UUID()
                state.selection = .init(phase: phase, active: active)
                try await waitUntil { state.completed[phase] == active }
                XCTAssertEqual(
                    state.completed[phase], active,
                    "Artwork boundary \(index) expected \(active) for phase \(phase); observed \(state.completed)"
                )
                XCTAssertEqual(
                    state.image, expected, "A visibility change keeps the installed cover")
                XCTAssertTrue(
                    state.images.dropFirst(initial).allSatisfy { $0 == expected },
                    "No nil or newly decoded retained cover may replace the equivalent cached image"
                )
                try await awaitAppliedFrame(phase)
                XCTAssertEqual(state.image, expected, "The applied frame keeps the installed cover")
                XCTAssertTrue(
                    state.images.dropFirst(initial).allSatisfy { $0 == expected },
                    "The display boundary must not publish a nil or newly decoded retained cover")
            }
        }

    #endif

    func testArtworkSharesBoundedRenditionPersistsOfflineAndDeletesAfterFinalReference()
        async throws
    {
        let first = artworkTrack("first")
        let second = artworkTrack("second")
        let playlist = item("playlist", kind: .playlist)
        let library = DownloadsLibrary(tracks: [first, first, second])
        await library.setArtwork(try artworkData())
        let directory = try root()
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        manager.download(first)
        try await waitUntil(timeout: .seconds(15)) {
            manager.artworkBytes > 0 && manager.owners.allSatisfy { $0.state == .ready }
        }
        let retained = await manager.retainedArtwork(for: first)
        let data = try XCTUnwrap(retained)
        let decoded = try XCTUnwrap(FoundationCurrentArtwork.decode(data))
        XCTAssertEqual(decoded.image.width, 640)
        XCTAssertEqual(decoded.image.height, 320)
        XCTAssertLessThanOrEqual(data.count, FoundationCurrentArtwork.maximumBytes)
        let secondArtwork = await manager.retainedArtwork(for: second)
        XCTAssertEqual(secondArtwork, data)
        let policies = await library.artworkPolicies
        XCTAssertEqual(policies, [false])
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        let manifest = try FoundationDownloadStorage.load(directory: account)
        XCTAssertEqual(manifest.artwork?.count, 1)
        let record = try XCTUnwrap(manifest.artwork?.values.first)
        let artURL = try XCTUnwrap(
            FoundationDownloadStorage.fileURL(record.file, directory: account))
        XCTAssertTrue(
            try artURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
                == true)
        XCTAssertEqual(
            manager.itemBytes(first), Int64(Data("synthetic audio".utf8).count + data.count))
        manager.invalidate()
        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        try await waitUntil { !restored.isLoading }
        let restoredData = await restored.retainedArtwork(for: first)
        XCTAssertEqual(restoredData, data)
        let policiesAfterRelaunch = await library.artworkPolicies
        XCTAssertEqual(policiesAfterRelaunch, [false])
        restored.removeTrack(first)
        XCTAssertEqual(restored.artworkBytes, Int64(data.count))
        restored.removeTrack(second)
        XCTAssertEqual(restored.artworkBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artURL.path))
        let removedData = await restored.retainedArtwork(for: first)
        XCTAssertNil(removedData)
        _ = await restored.clearAccount()
    }

    func testRestoredReadyAudioSchedulesMissingArtworkAfterInitialInventoryCompletes() async throws
    {
        let directory = try root()
        let track = artworkTrack("track")
        let library = DownloadsLibrary(tracks: [track])
        let original = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        original.updateConnectivity(isAllowed: true)
        original.download(track)
        try await waitUntil { original.isReady(track) }
        await original.artworkTask?.value
        XCTAssertEqual(original.artworkBytes, 0)
        let originalPolicies = await library.artworkPolicies
        XCTAssertEqual(originalPolicies, [false])
        original.invalidate()
        await library.setArtwork(try artworkData())
        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory,
            transfer: { _, _, _, _ in
                XCTFail("Restored complete audio must not be downloaded again")
                throw FoundationLibraryError.unavailable
            }, monitorConnectivity: false)
        XCTAssertTrue(restored.isLoading)
        restored.updateConnectivity(isAllowed: true)
        try await waitUntil { !restored.isLoading && restored.artworkBytes > 0 }
        await restored.artworkTask?.value
        XCTAssertTrue(restored.isReady(track))
        let policies = await library.artworkPolicies
        XCTAssertEqual(policies, [false, false])
        let retained = await restored.retainedArtwork(for: track)
        XCTAssertNotNil(retained)
        _ = await restored.clearAccount()
    }

    func testManifestPublicationRejectsInvalidTargetAndLeavesNoStagingFiles() throws {
        let directory = try root()
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        try FoundationDownloadStorage.prepare(account)
        var initial = FoundationDownloadManifest()
        try FoundationDownloadStorage.save(initial, directory: account)
        let target = account.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: target)
        initial.allowsCellular = true
        try FoundationDownloadStorage.save(initial, directory: account)
        XCTAssertTrue(try FoundationDownloadStorage.load(directory: account).allowsCellular)
        XCTAssertTrue(
            try target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
                == true)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let sentinel = target.appendingPathComponent("sentinel")
        try original.write(to: sentinel)
        XCTAssertThrowsError(try FoundationDownloadStorage.save(initial, directory: account))
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: account.path), ["manifest.json"])
    }

    func testFailedArtworkTagRefreshRetainsPreviousImageWithoutBlockingAudio() async throws {
        let first = artworkTrack("track")
        let library = DownloadsLibrary(tracks: [first])
        await library.setArtwork(try artworkData())
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(item("playlist", kind: .playlist))
        try await waitUntil { manager.artworkBytes > 0 }
        let oldImage = await manager.retainedArtwork(for: first)
        let changed = artworkTrack("track", tag: "second")
        await library.setArtworkFailure(true)
        await library.setTracks([changed])
        manager.reconcilePlaylists()
        try await waitUntil {
            manager.owners.first?.tracks.first?.album?.primaryImageTag == "second"
        }
        try await waitUntilAsync { await library.artworkPolicies.count >= 2 }
        await manager.artworkTask?.value
        XCTAssertTrue(manager.isReady(changed))
        let fallback = await manager.retainedArtwork(for: changed)
        XCTAssertEqual(fallback, oldImage)
        manager.reconcilePlaylists()
        for _ in 0..<30 { await Task.yield() }
        let policies = await library.artworkPolicies
        XCTAssertEqual(policies.count, 2)
        _ = await manager.clearAccount()
    }

    func testFailedArtworkPublicationKeepsPreviousFileAndRemovesStagedReplacement() async throws {
        let directory = try root()
        let track = artworkTrack("track")
        let library = DownloadsLibrary(tracks: [track])
        await library.setArtwork(try artworkData())
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(item("playlist", kind: .playlist))
        // Artwork and audio have independent workers. Finish audio before corrupting
        // the manifest so the injected failure exercises only artwork publication.
        try await waitUntil(timeout: .seconds(15)) {
            manager.artworkBytes > 0 && manager.isReady(track)
                && manager.owners.allSatisfy { $0.state == .ready }
        }
        await manager.artworkTask?.value
        let oldData = await manager.retainedArtwork(for: track)
        let revision = manager.artworkRevision
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        let oldManifest = try FoundationDownloadStorage.load(directory: account)
        let originalFiles = Set(try FileManager.default.contentsOfDirectory(atPath: account.path))
        let gate = DownloadGate()
        await library.setArtworkGate(gate)
        let changed = artworkTrack("track", tag: "second")
        await library.setTracks([changed])
        manager.reconcilePlaylists()
        try await waitUntilAsync { await gate.started }
        let task = manager.artworkTask
        let target = account.appendingPathComponent("manifest.json")
        let saved = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        await gate.resume()
        await task?.value
        XCTAssertEqual(manager.artworkRevision, revision)
        let retained = await manager.retainedArtwork(for: changed)
        XCTAssertEqual(retained, oldData)
        XCTAssertTrue(manager.isReady(changed))
        try FileManager.default.removeItem(at: target)
        try saved.write(to: target)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: account.path)), originalFiles)
        let restored = try FoundationDownloadStorage.load(directory: account)
        XCTAssertEqual(
            restored.artwork?.values.first?.file.name, oldManifest.artwork?.values.first?.file.name)
        _ = await manager.clearAccount()
    }

    func testRemovedArtworkReferenceRejectsLateOptionalResponse() async throws {
        let gate = DownloadGate()
        let track = artworkTrack("track")
        let library = DownloadsLibrary(tracks: [track])
        await library.setArtwork(try artworkData())
        await library.setArtworkGate(gate)
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntilAsync { await gate.started }
        // A held artwork response does not imply the separate audio transfer committed.
        try await waitUntil(timeout: .seconds(15)) { manager.isReady(track) }
        XCTAssertTrue(manager.isReady(track))
        let task = manager.artworkTask
        manager.removeTrack(track)
        await gate.resume()
        await task?.value
        XCTAssertEqual(manager.artworkBytes, 0)
        let data = await manager.retainedArtwork(for: track)
        XCTAssertNil(data)
        _ = await manager.clearAccount()
    }

    func testAutoStreamingDoesNotSampleQualityOrNetworkForRetainedLocalPlayback() async throws {
        let track = item("track")
        let directory = try root()
        let original = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: directory,
            transfer: transfer, monitorConnectivity: false)
        original.updateConnectivity(isAllowed: true)
        original.download(track)
        try await waitUntil { original.isReady(track) }
        original.invalidate()
        let remote = FoundationJellyfinLibrary(
            session: FoundationSession(
                serverURL: URL(string: "https://example.invalid/")!, accessToken: "synthetic-token",
                userID: "00000000000000000000000000000002",
                deviceID: "00000000-0000-0000-0000-000000000003"),
            streamingQuality: {
                XCTFail("Retained local audio must not sample Auto streaming quality")
                return .auto
            },
            load: { _ in
                XCTFail("Retained local audio must not negotiate a remote stream")
                throw FoundationLibraryError.unavailable
            })
        let restored = FoundationDownloads(
            scope: "fixture", library: remote, root: directory,
            transfer: { _, _, _, _ in
                XCTFail("Streaming quality must not replace an existing download")
                throw FoundationLibraryError.unavailable
            }, monitorConnectivity: false)
        try await waitUntil { !restored.isLoading }
        restored.updateConnectivity(isAllowed: false)
        for allowsFallback in [false, true] {
            let resource = try await restored.playbackResource(
                for: track, allowsRemoteFallback: allowsFallback)
            XCTAssertTrue(resource.url.isFileURL)
            XCTAssertEqual(try Data(contentsOf: resource.url), Data("synthetic audio".utf8))
            await resource.release()
        }
        let cleared = await restored.clearAccount()
        XCTAssertTrue(cleared)
    }

    func testLocalOnlyResolverRevalidatesMissingFileWithoutStartingRemoteRequest() async throws {
        let track = item("track")
        let library = DownloadsLibrary(tracks: [track])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.isReady(track) }
        let local = try await manager.playbackResource(for: track, allowsRemoteFallback: false)
        XCTAssertTrue(local.url.isFileURL)
        await local.release()
        manager.updateConnectivity(isAllowed: false)
        try FileManager.default.removeItem(at: local.url)
        XCTAssertTrue(
            manager.isReady(track), "The cached projection is revalidated by the resolver")
        do {
            _ = try await manager.playbackResource(for: track, allowsRemoteFallback: false)
            XCTFail("A missing local file must fail in local-only mode")
        } catch {
            XCTAssertTrue(error is FoundationLibraryError)
        }
        XCTAssertFalse(manager.isReady(track))
        let requests = await library.playbackRequests
        XCTAssertEqual(requests, 0)
        _ = await manager.clearAccount()
    }

    func testCanonicalCollectionModelSharesNormalCatalogDataByKindAndAccountIdentity() async throws
    {
        let directory = try root()
        let library = DownloadsLibrary(tracks: [])
        let manager = FoundationDownloads(
            scope: "first-account", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        let album = item("collection", kind: .album)
        var renamedAlbum = album
        renamedAlbum.title = "Changed synthetic title"
        let model = manager.collectionModel(for: album)
        XCTAssertTrue(model === manager.collectionModel(for: renamedAlbum))
        XCTAssertFalse(model === manager.collectionModel(for: item("collection", kind: .playlist)))
        let track = item("track")
        await model.load(.initial) { _ in .init(items: [track, track], nextStartIndex: nil) }
        XCTAssertEqual(
            manager.knownCollectionTracks(for: renamedAlbum).map(\.id), ["track", "track"])
        XCTAssertTrue(manager.hasCompleteCollectionSnapshot(for: album))
        XCTAssertFalse(manager.hasDownloadedData(for: album))
        let secondAccount = FoundationDownloads(
            scope: "second-account", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        XCTAssertFalse(model === secondAccount.collectionModel(for: album))
        manager.invalidate()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.loaded)
        XCTAssertTrue(manager.knownCollectionTracks(for: album).isEmpty)
        _ = await manager.clearAccount()
        _ = await secondAccount.clearAccount()
    }

    func testCanonicalSavedSnapshotIncludesExcludedOccurrencesAndRemovalKeepsBrowseData()
        async throws
    {
        let track = item("track")
        let playlist = item("playlist", kind: .playlist)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track, track]), root: try root(),
            transfer: transfer, monitorConnectivity: false)
        let model = manager.collectionModel(for: playlist)
        XCTAssertFalse(model.loaded)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        XCTAssertTrue(model === manager.collectionModel(for: playlist))
        XCTAssertEqual(model.items.map(\.id), ["track", "track"])
        XCTAssertTrue(manager.hasCompleteCollectionSnapshot(for: playlist))
        manager.removeTrack(track)
        XCTAssertEqual(manager.knownCollectionTracks(for: playlist).map(\.id), ["track", "track"])
        XCTAssertTrue(manager.browseTracks(for: playlist).isEmpty)
        XCTAssertTrue(manager.hasDownloadedData(for: playlist))
        manager.removeDownloads(for: playlist)
        XCTAssertFalse(manager.hasDownloadedData(for: playlist))
        XCTAssertEqual(model.items.map(\.id), ["track", "track"])
        XCTAssertEqual(manager.knownCollectionTracks(for: playlist).count, 2)
        _ = await manager.clearAccount()
    }

    func testDerivedAlbumSeedsPartialRowsButAllowsNormalFullServerMembershipLoad() async throws {
        let first = artworkTrack("first")
        let second = artworkTrack("second")
        let album = item("album", kind: .album)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [first]), root: try root(),
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(first)
        try await waitUntil { manager.isReady(first) }
        let model = manager.collectionModel(for: album)
        XCTAssertEqual(model.items.map(\.id), ["first"])
        XCTAssertFalse(model.loaded)
        XCTAssertFalse(manager.hasCompleteCollectionSnapshot(for: album))
        XCTAssertTrue(manager.hasDownloadedData(for: album))
        await model.load(.initial) { _ in .init(items: [first, second, first], nextStartIndex: nil)
        }
        XCTAssertEqual(
            manager.knownCollectionTracks(for: album).map(\.id), ["first", "second", "first"])
        XCTAssertEqual(manager.browseTracks(for: album).map(\.id), ["first", "first"])
        XCTAssertTrue(manager.hasCompleteCollectionSnapshot(for: album))
        XCTAssertTrue(model === manager.collectionModel(for: album))
        _ = await manager.clearAccount()
    }

    func testCanonicalCollectionKeepsNewServerDataUntilSuccessfulPlaylistReconciliation()
        async throws
    {
        let first = item("first")
        let second = item("second")
        let playlist = item("playlist", kind: .playlist)
        let library = DownloadsLibrary(tracks: [first, first])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        let model = manager.collectionModel(for: playlist)
        await model.load(.refresh) { _ in .init(items: [second, first], nextStartIndex: nil) }
        XCTAssertTrue(model === manager.collectionModel(for: playlist))
        XCTAssertEqual(manager.knownCollectionTracks(for: playlist).map(\.id), ["second", "first"])
        await library.setTracks([second, second, first])
        manager.reconcilePlaylists()
        try await waitUntil { model.items.map(\.id) == ["second", "second", "first"] }
        XCTAssertTrue(model === manager.collectionModel(for: playlist))
        _ = await manager.clearAccount()
    }

    func testLatestCanonicalMembershipChangesAvailabilityAndFullDerivedAlbumCanBecomeReady()
        async throws
    {
        let first = artworkTrack("first")
        let second = artworkTrack("second")
        let album = item("album", kind: .album)
        let playlist = item("playlist", kind: .playlist)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [first, first]), root: try root(),
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        let playlistModel = manager.collectionModel(for: playlist)
        XCTAssertEqual(manager.availability(for: playlist), .ready)
        await playlistModel.load(.refresh) { _ in
            .init(items: [first, second, first], nextStartIndex: nil)
        }
        XCTAssertEqual(manager.availability(for: playlist), .partial(ready: 2, total: 3))
        let albumModel = manager.collectionModel(for: album)
        XCTAssertEqual(manager.availability(for: album), .partial(ready: 1, total: 1))
        await albumModel.load(.initial) { _ in
            .init(items: [first, second], nextStartIndex: nil)
        }
        XCTAssertEqual(manager.availability(for: album), .partial(ready: 1, total: 2))
        manager.download(second)
        try await waitUntil { manager.isReady(second) }
        XCTAssertEqual(manager.availability(for: album), .ready)
        XCTAssertEqual(manager.availability(for: playlist), .ready)
        XCTAssertFalse(manager.owners.contains { $0.item.kind == .album })
        _ = await manager.clearAccount()
    }

    func testRefreshedCanonicalPageRemainsPartialDespiteOlderExpandedOwner() async throws {
        let track = item("track")
        let playlist = item("playlist", kind: .playlist)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track, track]), root: try root(),
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        let model = manager.collectionModel(for: playlist)
        XCTAssertTrue(manager.hasCompleteCollectionSnapshot(for: playlist))
        await model.load(.refresh) { _ in
            .init(items: [track, track], nextStartIndex: 2)
        }
        XCTAssertTrue(manager.owners.first?.tracks.allSatisfy { manager.isReady($0) } == true)
        XCTAssertFalse(manager.hasCompleteCollectionSnapshot(for: playlist))
        XCTAssertEqual(manager.availability(for: playlist), .partial(ready: 2, total: 2))
        _ = await manager.clearAccount()
    }

    func testExplicitRedownloadUsesCanonicalMembershipAfterSavedOwnerRemoval() async throws {
        let track = item("track")
        let playlist = item("playlist", kind: .playlist)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track, track]), root: try root(),
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        let model = manager.collectionModel(for: playlist)
        manager.removeTrack(track)
        manager.removeDownloads(for: playlist)
        XCTAssertTrue(manager.owners.isEmpty)
        XCTAssertFalse(manager.isReady(track))
        XCTAssertEqual(manager.knownCollectionTracks(for: playlist).map(\.id), ["track", "track"])
        XCTAssertFalse(manager.hasDownloadedData(for: playlist))
        manager.downloadAgain(playlist)
        try await waitUntil { manager.isReady(track) }
        XCTAssertTrue(model === manager.collectionModel(for: playlist))
        XCTAssertEqual(manager.browseTracks(for: playlist).map(\.id), ["track", "track"])
        XCTAssertEqual(manager.availability(for: playlist), .ready)
        _ = await manager.clearAccount()
    }

    func testRedownloadExpansionReplacesRetainedCanonicalSnapshotAfterOwnerRemoval() async throws {
        let first = item("first")
        let second = item("second")
        let playlist = item("playlist", kind: .playlist)
        let library = DownloadsLibrary(tracks: [first, first])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        let model = manager.collectionModel(for: playlist)
        XCTAssertTrue(model.isRetainedSnapshot)
        manager.removeTrack(first)
        manager.removeDownloads(for: playlist)
        XCTAssertEqual(model.items.map(\.id), ["first", "first"])
        await library.setTracks([first, second, first])
        manager.downloadAgain(playlist)
        try await waitUntil { manager.isReady(first) && manager.isReady(second) }
        XCTAssertTrue(model === manager.collectionModel(for: playlist))
        XCTAssertEqual(model.items.map(\.id), ["first", "second", "first"])
        XCTAssertEqual(
            manager.knownCollectionTracks(for: playlist).map(\.id), ["first", "second", "first"])
        XCTAssertEqual(manager.availability(for: playlist), .ready)
        _ = await manager.clearAccount()
    }

    func testNonownedPlaylistRemovalRemovesSharedSongsWithWarningAndLeaseProtection() async throws {
        let track = item("track")
        let retainedPlaylist = item("retained", kind: .playlist)
        let normalPlaylist = item("normal", kind: .playlist)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track, track]), root: try root(),
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(retainedPlaylist)
        try await waitUntil { manager.owners.first?.state == .ready }
        let model = manager.collectionModel(for: normalPlaylist)
        await model.load(.initial) { _ in .init(items: [track, track], nextStartIndex: nil) }
        XCTAssertTrue(manager.hasDownloadedData(for: normalPlaylist))
        XCTAssertTrue(manager.removalAffectsPlaylist(for: normalPlaylist))
        let lease = try await manager.playbackResource(for: track)
        manager.removeDownloads(for: normalPlaylist)
        XCTAssertFalse(manager.isReady(track))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.url.path))
        XCTAssertEqual(manager.owners.count, 1)
        XCTAssertEqual(
            manager.knownCollectionTracks(for: retainedPlaylist).map(\.id), ["track", "track"])
        XCTAssertEqual(
            manager.knownCollectionTracks(for: normalPlaylist).map(\.id), ["track", "track"])
        XCTAssertTrue(
            manager.hasDownloadedData(for: normalPlaylist), "The lease still retains physical bytes"
        )
        await lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.url.path))
        XCTAssertFalse(manager.hasDownloadedData(for: normalPlaylist))
        XCTAssertTrue(
            manager.hasDownloadedData(for: retainedPlaylist),
            "Explicit saved intent remains removable")
        _ = await manager.clearAccount()
    }

    func testSharedTrackRemovalAndDerivedAlbumRemovalPreserveOtherCollectionSnapshotsAndLeases()
        async throws
    {
        let first = artworkTrack("first")
        let second = artworkTrack("second")
        let unrelated = item("unrelated")
        let playlist = item("playlist", kind: .playlist)
        let album = item("album", kind: .album)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [first, first, second, unrelated]),
            root: try root(), transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        XCTAssertTrue(manager.hasDownloadedData(for: first))
        XCTAssertTrue(manager.removalAffectsPlaylist(for: first))
        XCTAssertTrue(manager.hasDownloadedData(for: album))
        XCTAssertTrue(manager.removalAffectsPlaylist(for: album))
        let lease = try await manager.playbackResource(for: first)
        manager.removeDownloads(for: album)
        XCTAssertFalse(manager.isReady(first))
        XCTAssertFalse(manager.isReady(second))
        XCTAssertTrue(manager.isReady(unrelated))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.url.path))
        XCTAssertTrue(
            manager.hasDownloadedData(for: first), "Leased audio remains physical downloaded data")
        XCTAssertEqual(
            manager.knownCollectionTracks(for: playlist).map(\.id),
            ["first", "first", "second", "unrelated"])
        await lease.release()
        XCTAssertFalse(manager.hasDownloadedData(for: first))
        XCTAssertFalse(manager.hasDownloadedData(for: album))
        XCTAssertTrue(manager.hasDownloadedData(for: playlist))
        _ = await manager.clearAccount()
    }

    func testExplicitCollectionRemovalPreservesSharedTrackAndFailedWritePreservesRemovalIntent()
        async throws
    {
        let directory = try root()
        let track = item("track")
        let playlist = item("playlist", kind: .playlist)
        let album = item("album", kind: .album)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track, track]), root: directory,
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        manager.download(album)
        try await waitUntil {
            manager.owners.count == 2 && manager.owners.allSatisfy { $0.state == .ready }
        }
        XCTAssertFalse(manager.removalAffectsPlaylist(for: album))
        manager.removeDownloads(for: album)
        XCTAssertTrue(manager.isReady(track))
        XCTAssertTrue(manager.hasDownloadedData(for: playlist))
        let target = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
            .appendingPathComponent("manifest.json")
        let saved = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        manager.removeDownloads(for: playlist)
        XCTAssertTrue(manager.hasDownloadedData(for: playlist))
        XCTAssertTrue(manager.isReady(track))
        try FileManager.default.removeItem(at: target)
        try saved.write(to: target)
        _ = await manager.clearAccount()
    }

    func testQueuedReacquisitionSurvivesColdRelaunchAndClearsUnknownPaginatedExcludedMember()
        async throws
    {
        let directory = try root()
        let first = item("first")
        let excluded = item("excluded")
        let playlist = item("playlist", kind: .playlist)
        let library = DownloadsLibrary(tracks: [first, excluded, excluded])
        await library.setPlaylistPageSize(1)
        let original = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        original.updateConnectivity(isAllowed: true)
        original.download(playlist)
        try await waitUntil { original.owners.first?.state == .ready }
        original.removeTrack(excluded)
        original.removeDownloads(for: playlist)
        original.invalidate()
        let queued = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        // Discovery metadata survives owner removal, without retaining audio or acquisition intent.
        XCTAssertEqual(
            queued.knownCollectionTracks(for: playlist).map(\.id),
            ["first", "excluded", "excluded"])
        XCTAssertTrue(queued.owners.isEmpty)
        XCTAssertTrue(queued.downloadedSongs.isEmpty)
        XCTAssertTrue(queued.browseTracks(for: playlist).isEmpty)
        queued.downloadAgain(playlist)
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        let intent = try FoundationDownloadStorage.load(directory: account)
        XCTAssertEqual(intent.owners.first?.reacquiresExcludedTracks, true)
        XCTAssertEqual(intent.owners.first?.expanded, false)
        XCTAssertTrue(intent.excludedTrackIDs?.contains(excluded.id) == true)
        queued.invalidate()
        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        restored.updateConnectivity(isAllowed: true)
        try await waitUntil { restored.isReady(first) && restored.isReady(excluded) }
        XCTAssertEqual(
            restored.knownCollectionTracks(for: playlist).map(\.id),
            ["first", "excluded", "excluded"])
        let finished = try FoundationDownloadStorage.load(directory: account)
        XCTAssertNotEqual(finished.owners.first?.reacquiresExcludedTracks, true)
        XCTAssertFalse(finished.excludedTrackIDs?.contains(excluded.id) == true)
        let offsets = await library.playlistOffsets
        XCTAssertTrue(offsets.contains(2), "The complete snapshot must include later pages")
        _ = await restored.clearAccount()
    }

    func testOrdinaryCollectionDownloadPreservesUnknownExclusionUntilExplicitReacquisition()
        async throws
    {
        let directory = try root()
        let first = item("first")
        let excluded = item("excluded")
        let playlist = item("playlist", kind: .playlist)
        let library = DownloadsLibrary(tracks: [first, excluded])
        let original = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        original.updateConnectivity(isAllowed: true)
        original.download(playlist)
        try await waitUntil { original.owners.first?.state == .ready }
        original.removeTrack(excluded)
        original.removeDownloads(for: playlist)
        original.invalidate()
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        XCTAssertTrue(manager.isReady(first))
        XCTAssertFalse(manager.isReady(excluded))
        XCTAssertEqual(manager.availability(for: playlist), .partial(ready: 1, total: 2))
        manager.downloadAgain(playlist)
        try await waitUntil { manager.isReady(excluded) }
        XCTAssertEqual(manager.availability(for: playlist), .ready)
        _ = await manager.clearAccount()
    }

    func testFailedReacquisitionExpansionPreservesSnapshotExclusionsAndRetryableIntent()
        async throws
    {
        let directory = try root()
        let first = item("first")
        let excluded = item("excluded")
        let playlist = item("playlist", kind: .playlist)
        let library = DownloadsLibrary(tracks: [first, excluded])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        manager.removeTrack(excluded)
        await library.setPlaylistPageSize(1)
        await library.setFailingPlaylistOffset(1)
        manager.downloadAgain(playlist)
        try await waitUntil { manager.owners.first?.state == .failed }
        XCTAssertTrue(manager.isReady(first))
        XCTAssertFalse(manager.isReady(excluded))
        XCTAssertEqual(
            manager.knownCollectionTracks(for: playlist).map(\.id), ["first", "excluded"])
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        let failed = try FoundationDownloadStorage.load(directory: account)
        XCTAssertEqual(failed.owners.first?.reacquiresExcludedTracks, true)
        XCTAssertTrue(failed.excludedTrackIDs?.contains(excluded.id) == true)
        await library.setFailingPlaylistOffset(nil)
        manager.retry(ownerID: "playlist:playlist")
        try await waitUntil { manager.isReady(excluded) }
        _ = await manager.clearAccount()
    }

    func testReacquisitionPublicationFailureRollsBackFetchedMembershipAndExclusionClearing()
        async throws
    {
        let directory = try root()
        let first = item("first")
        let excluded = item("excluded")
        let added = item("added")
        let playlist = item("playlist", kind: .playlist)
        let library = DownloadsLibrary(tracks: [first, excluded])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        manager.removeTrack(excluded)
        let gate = DownloadGate()
        await library.setPlaylistGate(gate)
        await library.setTracks([first, excluded, added])
        manager.downloadAgain(playlist)
        try await waitUntilAsync { await gate.started }
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        let target = account.appendingPathComponent("manifest.json")
        let saved = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        await gate.resume()
        try await waitUntil { manager.owners.first?.state == .failed }
        XCTAssertEqual(manager.owners.first?.tracks.map(\.id), ["first", "excluded"])
        XCTAssertTrue(manager.isReady(first))
        XCTAssertFalse(manager.isReady(excluded))
        XCTAssertFalse(manager.isReady(added))
        try FileManager.default.removeItem(at: target)
        try saved.write(to: target)
        manager.retry(ownerID: "playlist:playlist")
        try await waitUntil { manager.isReady(excluded) && manager.isReady(added) }
        _ = await manager.clearAccount()
    }

    func testLaterTrackRemovalCancelsPendingReacquisitionAndPreservesNewestExclusion() async throws
    {
        let track = item("track")
        let playlist = item("playlist", kind: .playlist)
        let library = DownloadsLibrary(tracks: [track, track])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        let gate = DownloadGate()
        await library.setPlaylistGate(gate)
        manager.downloadAgain(playlist)
        try await waitUntilAsync { await gate.started }
        manager.removeTrack(track)
        await gate.resume()
        try await waitUntil { manager.owners.first?.state == .ready }
        XCTAssertFalse(manager.isReady(track))
        XCTAssertEqual(manager.knownCollectionTracks(for: playlist).map(\.id), ["track", "track"])
        _ = await manager.clearAccount()
    }

    func testExplicitReacquisitionReusesVerifiedLeasedFileWithoutReplacement() async throws {
        let directory = try root()
        let track = item("track")
        let playlist = item("playlist", kind: .playlist)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track, track]), root: directory,
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        let lease = try await manager.playbackResource(for: track)
        manager.removeTrack(track)
        XCTAssertFalse(manager.isReady(track))
        manager.downloadAgain(playlist)
        try await waitUntil { manager.isReady(track) }
        let reacquired = try await manager.playbackResource(for: track)
        XCTAssertEqual(reacquired.url, lease.url)
        await reacquired.release()
        await lease.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.url.path))
        _ = await manager.clearAccount()
    }

    func testLeaseReleasedDuringReacquisitionVerificationTransfersCollectedFileAgain() async throws
    {
        let track = item("track")
        let playlist = item("playlist", kind: .playlist)
        let gate = DownloadGate()
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: try root(),
            transfer: transfer, monitorConnectivity: false,
            verifyReacquisitionFiles: { files, directory in
                let verified = try await FoundationDownloadStorage.verifiedFiles(
                    files, directory: directory)
                if !files.isEmpty { await gate.wait() }
                return verified
            })
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        let lease = try await manager.playbackResource(for: track)
        manager.removeTrack(track)
        manager.downloadAgain(playlist)
        try await waitUntilAsync { await gate.started }
        await lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.url.path))
        await gate.resume()
        try await waitUntil { manager.isReady(track) }
        let replacement = try await manager.playbackResource(for: track)
        XCTAssertNotEqual(replacement.url, lease.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.url.path))
        await replacement.release()
        _ = await manager.clearAccount()
    }

    func testCollectionTransferProjectionUsesCurrentPreferenceAndKeepsCanonicalOccurrences()
        async throws
    {
        var first = item("first")
        first.album = .init(id: "album", title: "Album")
        first.trackNumber = 1
        first.discNumber = 1
        var alternate = item("alternate")
        alternate.album = first.album
        alternate.trackNumber = first.trackNumber
        alternate.discNumber = first.discNumber
        var next = item("next")
        next.album = first.album
        next.discNumber = first.discNumber
        next.title = "Next Song"
        next.trackNumber = 2
        for kind in [FoundationItem.Kind.album, .playlist] {
            for showDuplicates in [false, true] {
                let source = item(kind.rawValue, kind: kind)
                let library = DownloadsLibrary(tracks: [first, first, alternate, next])
                let manager = FoundationDownloads(
                    scope: "fixture", library: library, root: try root(), transfer: transfer,
                    monitorConnectivity: false,
                    projectTracks: { items, albumID in
                        FoundationAlbumTrackPolicy.visibleTracks(
                            items, albumID: albumID, showDuplicates: showDuplicates)
                    })
                manager.download(source)
                manager.updateConnectivity(isAllowed: true)
                try await waitUntil { manager.owners.first?.state == .ready }
                let expected =
                    showDuplicates
                    ? ["first", "first", "alternate", "next"] : ["first", "first", "next"]
                XCTAssertEqual(
                    manager.owners.first?.tracks.map(\.id), ["first", "first", "alternate", "next"])
                XCTAssertEqual(manager.browseTracks(for: source).map(\.id), expected)
                XCTAssertEqual(manager.isReady(alternate), showDuplicates)
                XCTAssertTrue(manager.isReady(first))
                XCTAssertTrue(manager.isReady(next))
                _ = await manager.clearAccount()
            }
        }
    }

    func testDownloadedVisibilityToggleDoesNotDeleteRetainedPhysicalCopies() async throws {
        var first = item("first")
        first.album = .init(id: "album", title: "Album")
        first.trackNumber = 1
        var alternate = item("alternate")
        alternate.album = first.album
        alternate.trackNumber = first.trackNumber
        alternate.discNumber = first.discNumber
        var showDuplicates = true
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [first, alternate]),
            root: try root(),
            transfer: transfer, monitorConnectivity: false,
            projectTracks: { items, albumID in
                FoundationAlbumTrackPolicy.visibleTracks(
                    items, albumID: albumID, showDuplicates: showDuplicates)
            })
        manager.updateConnectivity(isAllowed: true)
        let album = item("album", kind: .album)
        manager.download(album)
        try await waitUntil { manager.owners.first?.state == .ready }
        let bytes = manager.storageBytes
        showDuplicates = false
        XCTAssertEqual(manager.downloadedSongs.map(\.id), ["first"])
        XCTAssertEqual(manager.localCatalogItems(kind: .track).map(\.id), ["first"])
        XCTAssertEqual(manager.browseTracks(for: album).map(\.id), ["first"])
        XCTAssertEqual(manager.owners.first?.tracks.count, 2)
        XCTAssertTrue(manager.isReady(alternate))
        XCTAssertEqual(manager.storageBytes, bytes)
        showDuplicates = true
        XCTAssertEqual(manager.downloadedSongs.map(\.id), ["first", "alternate"])
        _ = await manager.clearAccount()
    }

    func testManifestContainsNoTransientRequestSecretsAndScopesAreOpaque() async throws {
        let track = item("track")
        let directory = try root()
        let manager = FoundationDownloads(
            scope: "https://account.invalid/private", library: DownloadsLibrary(tracks: [track]),
            root: directory, transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .ready }
        let folders = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        let folder = try XCTUnwrap(folders.first)
        XCTAssertEqual(folder.lastPathComponent.count, 64)
        let text = try String(
            contentsOf: folder.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("fixture-secret"))
        XCTAssertFalse(text.contains("example.invalid"))
        XCTAssertFalse(text.contains("account.invalid"))
        _ = await manager.clearAccount()
    }
}

private actor DownloadsLibrary: FoundationLibrary {
    nonisolated let supportsOfflinePlaylistPreparation: Bool
    private var offlineCandidates: [FoundationItem] = []
    private var offlineMemberships: [String: [FoundationItem]] = [:]
    private var offlineCandidatePageSize = 50
    private var offlinePlaylistGate: DownloadGate?
    private(set) var offlineCandidateOffsets: [Int] = []
    private(set) var offlinePlaylistOffsets: [String: [Int]] = [:]
    func setOfflinePlaylistGate(_ gate: DownloadGate) { offlinePlaylistGate = gate }
    func setOfflinePlaylistFixture(
        candidates: [FoundationItem], memberships: [String: [FoundationItem]], pageSize: Int = 50
    ) {
        offlineCandidates = candidates
        offlineMemberships = memberships
        offlineCandidatePageSize = pageSize
    }
    func playlists(startIndex: Int) async throws -> FoundationPage {
        offlineCandidateOffsets.append(startIndex)
        let end = min(offlineCandidates.count, startIndex + offlineCandidatePageSize)
        return .init(
            items: Array(offlineCandidates[startIndex..<end]),
            nextStartIndex: end < offlineCandidates.count ? end : nil)
    }
    func playlistTracks(playlistID: String, startIndex: Int) async throws -> FoundationPage {
        offlinePlaylistOffsets[playlistID, default: []].append(startIndex)
        if let gate = offlinePlaylistGate {
            offlinePlaylistGate = nil
            await gate.wait()
        }
        if fails { throw FoundationLibraryError.unavailable }
        let tracks = offlineMemberships[playlistID] ?? []
        let end = min(tracks.count, startIndex + 100)
        return .init(
            items: Array(tracks[startIndex..<end]), nextStartIndex: end < tracks.count ? end : nil)
    }
    private var conversionGate: DownloadGate?
    private(set) var requestedQualities: [FoundationDownloadQuality] = []
    func setConversionGate(_ gate: DownloadGate) { conversionGate = gate }
    func downloadPreparation(for item: FoundationItem, quality: FoundationDownloadQuality)
        async throws -> FoundationDownloadPreparation
    {
        if quality == .original { return .original(try await downloadSource(for: item)) }
        requestedQualities.append(quality)
        if let gate = conversionGate {
            conversionGate = nil
            await gate.wait()
        }
        let plan = try FoundationDownloadConversionPlan(
            quality: quality, duration: 1, sourceID: "fixture-source", audioStreamIndex: 0)
        let base = URL(string: "https://example.invalid")!
        let request = URLRequest(url: base)
        return .converted(
            .init(
                request: request, cleanupRequest: request, plan: plan,
                base: base, itemID: item.id, deviceID: "fixture-device"))
    }
    func nativeDownloadProposal(
        for item: FoundationItem, quality: FoundationDownloadQuality, allowsCellular: Bool
    ) async throws -> FoundationNativeDownloadProposal {
        // This fixture's nativeTransfer is injected; no URL is loaded or passed to AVFoundation.
        let plan = try FoundationDownloadConversionPlan(
            quality: quality, duration: 1, sourceID: "fixture-source", audioStreamIndex: 0)
        let request = URLRequest(url: URL(string: "https://example.invalid/master.m3u8")!)
        return .init(
            request: request, authenticatedMasterURL: request.url!, expectedToken: "fixture-token",
            expectedDeviceID: "fixture-device", cleanupRequest: request, plan: plan,
            title: "Synthetic", artwork: nil)
    }

    private var tracks: [FoundationItem]
    private var fails = false
    private var playlistPageSize: Int?
    private var failingPlaylistOffset: Int?
    func setFailingPlaylistOffset(_ offset: Int?) { failingPlaylistOffset = offset }
    private var playlistGate: DownloadGate?
    private var permissionGate: DownloadGate?
    func setPermissionGate(_ gate: DownloadGate) { permissionGate = gate }
    private(set) var downloadSourceIDs: [String] = []
    private(set) var playlistOffsets: [Int] = []
    func setPlaylistPageSize(_ size: Int) { playlistPageSize = size }
    func setPlaylistGate(_ gate: DownloadGate) { playlistGate = gate }
    private var artwork: Data?
    private var artworkFails = false
    private var artworkGate: DownloadGate?
    private(set) var artworkPolicies: [Bool] = []
    private(set) var playbackRequests = 0
    func setArtwork(_ data: Data?) { artwork = data }
    func setArtworkFailure(_ value: Bool) { artworkFails = value }
    func setArtworkGate(_ gate: DownloadGate) { artworkGate = gate }
    func downloadArtwork(for item: FoundationItem, size: Int, allowsCellular: Bool) async throws
        -> Data?
    {
        guard item.kind == .album else { return nil }
        artworkPolicies.append(allowsCellular)
        if let gate = artworkGate {
            artworkGate = nil
            await gate.wait()
        }
        if artworkFails { throw FoundationLibraryError.unavailable }
        return artwork
    }
    init(tracks: [FoundationItem], preparesOfflinePlaylists: Bool = false) {
        self.tracks = tracks
        self.supportsOfflinePlaylistPreparation = preparesOfflinePlaylists
    }
    func setFailure(_ value: Bool) { fails = value }
    func setTracks(_ value: [FoundationItem]) { tracks = value }
    func albums(startIndex: Int) async throws -> FoundationPage {
        .init(items: [], nextStartIndex: nil)
    }
    func tracks(albumID: String, startIndex: Int) async throws -> FoundationPage {
        .init(items: tracks, nextStartIndex: nil)
    }
    func playlistEntries(id: String, startIndex: Int) async throws -> FoundationPlaylistPage {
        playlistOffsets.append(startIndex)
        if let gate = playlistGate {
            playlistGate = nil
            await gate.wait()
        }
        if fails || failingPlaylistOffset == startIndex { throw FoundationLibraryError.unavailable }
        let end = min(tracks.count, startIndex + (playlistPageSize ?? tracks.count))
        return .init(
            entries: tracks.enumerated().filter { $0.offset >= startIndex && $0.offset < end }.map {
                FoundationPlaylistEntry(
                    id: "\($0.offset)", mutationID: "\($0.offset)", item: $0.element)
            }, nextStartIndex: end < tracks.count ? end : nil)
    }
    func playlistPermissions(id: String) async throws -> FoundationPlaylistPermissions {
        if let gate = permissionGate {
            permissionGate = nil
            await gate.wait()
        }
        if fails { throw FoundationLibraryError.unavailable }
        return .init(name: "Synthetic playlist", canEdit: true, canDelete: true)
    }
    func playbackURL(for item: FoundationItem) async throws -> URL {
        playbackRequests += 1
        return URL(string: "https://example.invalid/stream")!
    }
    func downloadSource(for item: FoundationItem) async throws -> FoundationDownloadSource {
        downloadSourceIDs.append(item.id)
        var request = URLRequest(url: URL(string: "https://example.invalid/original")!)
        request.setValue("fixture-secret", forHTTPHeaderField: "Authorization")
        return FoundationDownloadSource(request: request, fileExtension: "mp3", expectedBytes: nil)
    }
}

nonisolated private final class NativeFirstCompletionProof: @unchecked Sendable {
    let parent: URL
    let target: URL
    private let lock = NSLock()
    private var parentGeneration = 1
    private var replaced = false
    private var failSnapshot = false
    private var mutateTarget = false
    private var targetGeneration = 1
    private var parentCount = 0
    private var packageCount = 0
    private var targetCount = 0
    var parentSnapshots: Int { lock.withLock { parentCount } }
    var packageSnapshots: Int { lock.withLock { packageCount } }
    var targetReads: Int { lock.withLock { targetCount } }
    init(directory: URL) throws {
        parent = directory.appendingPathComponent(
            "com.apple.UserManagedAssets.synthetic", isDirectory: true)
        target = parent.appendingPathComponent("asset.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    }
    func materialize() throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        lock.withLock { parentGeneration = 2 }
    }
    func replaceParent() { lock.withLock { replaced = true } }
    func failPackageSnapshot() { lock.withLock { failSnapshot = true } }
    func changeTargetDuringSnapshot() { lock.withLock { mutateTarget = true } }
    private func values(file: String, generation: Int) -> [URLResourceKey: Any] {
        [
            .fileResourceIdentifierKey: NSString(string: file),
            .volumeIdentifierKey: NSString(string: "volume"),
            .generationIdentifierKey: NSNumber(value: generation), .isDirectoryKey: true,
            .isSymbolicLinkKey: false,
        ]
    }
    private func resources(_ url: URL) throws -> [URLResourceKey: Any] {
        if url == parent {
            return lock.withLock {
                values(file: replaced ? "replacement" : "parent", generation: parentGeneration)
            }
        }
        guard url == target else { throw FoundationDownloadError.cleanup }
        lock.withLock { targetCount += 1 }
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return lock.withLock { values(file: "package", generation: targetGeneration) }
    }
    private func snapshot(_ url: URL) throws -> Data {
        if url == parent {
            lock.withLock { parentCount += 1 }
            return Data("parent-pin".utf8)
        }
        guard url == target else { throw FoundationDownloadError.cleanup }
        let fails = lock.withLock { () -> Bool in
            packageCount += 1
            if mutateTarget { targetGeneration = 2 }
            return failSnapshot
        }
        if fails { throw CocoaError(.fileReadNoSuchFile) }
        return Data("package-pin".utf8)
    }
    private func embedded(_ data: Data) -> [URLResourceKey: Any]? {
        if data == Data("parent-pin".utf8) { return values(file: "parent", generation: 1) }
        if data == Data("package-pin".utf8) { return values(file: "package", generation: 1) }
        return nil
    }
    func announce(_ store: FoundationNativeAllocationStore, url: URL, task: Int) throws {
        try store.announce(
            url, taskIdentifier: task, snapshot: snapshot,
            namespaceProof: { $0 == self.target }, resources: resources, embedded: embedded)
    }
    func seal(_ store: FoundationNativeAllocationStore, url: URL, task: Int) throws {
        try store.sealAnnouncement(
            url, taskIdentifier: task, snapshot: snapshot,
            namespaceProof: { $0 == self.target }, resources: resources, embedded: embedded,
            prove: { $0.nativeURL == self.target && $0.bookmark == Data("package-pin".utf8) })
    }
}

nonisolated private final class NativeDownloadVerificationFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var isAvailable = false
    private var count = 0
    private var isFinished = false
    var available: Bool { lock.withLock { isAvailable } }
    var verifications: Int { lock.withLock { count } }
    var finished: Bool { lock.withLock { isFinished } }
    func makeAvailable() { lock.withLock { isAvailable = true } }
    func recordVerification() { lock.withLock { count += 1 } }
    func finish() { lock.withLock { isFinished = true } }
}

private actor DownloadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor DownloadProgressReporter {
    private var callback: (@Sendable (Int64, Int64?) -> Void)?
    func install(_ callback: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.callback = callback
    }
    func report(_ bytes: Int64, _ total: Int64?) { callback?(bytes, total) }
}

#if DEBUG
    @MainActor
    private final class HostedArtworkVisibilityState: ObservableObject {
        struct Selection {
            let phase: UUID
            let active: Bool
        }
        @Published var selection = Selection(phase: UUID(), active: true)
        var active: Bool { selection.active }
        var phase: UUID { selection.phase }
        var image: Image?
        var images: [Image?] = []
        var completed: [UUID: Bool] = [:]
    }

    /// One-shot display-clock acknowledgement, armed only after an artwork task completes.
    /// It does not drive the artwork or change the test's existing bounded wait deadline.
    @MainActor
    private final class HostedArtworkFrameBoundary: NSObject {
        private var link: CADisplayLink?
        private var armedAt: CFTimeInterval = 0
        private var phase: UUID?
        private(set) var completed: UUID?

        #if os(macOS)
            func arm(_ phase: UUID, view: NSView) {
                invalidate()
                self.phase = phase
                armedAt = CACurrentMediaTime()
                link = view.displayLink(target: self, selector: #selector(frame(_:)))
                link?.add(to: .main, forMode: .common)
            }
        #else
            func arm(_ phase: UUID) {
                invalidate()
                self.phase = phase
                armedAt = CACurrentMediaTime()
                link = CADisplayLink(target: self, selector: #selector(frame(_:)))
                link?.add(to: .main, forMode: .common)
            }
        #endif

        @objc private func frame(_ sender: CADisplayLink) {
            // A callback already in flight when armed may describe the previous frame.
            guard sender.timestamp > armedAt else { return }
            completed = phase
            invalidate()
        }

        func invalidate() {
            link?.invalidate()
            link = nil
        }
    }

    @MainActor
    private struct HostedArtworkVisibilityView: View {
        @ObservedObject var state: HostedArtworkVisibilityState
        let item: FoundationItem
        let library: any FoundationLibrary

        var body: some View {
            FoundationCatalogArtwork(
                item: item, library: library, isActive: state.active, size: 144,
                loadedImage: Binding(
                    get: { state.image },
                    set: {
                        state.image = $0
                        state.images.append($0)
                    })
            )
            .environment(
                \.foundationArtworkTaskObservation,
                .init(phase: state.phase) { phase, active in state.completed[phase] = active })
        }
    }

    @MainActor
    private final class RecreatedArtworkState: ObservableObject {
        struct Frame { let image: Image? }
        struct LeafFrame {
            let lifetime: UUID
            let image: Image?
        }
        struct Selection {
            let incarnation: UUID
            let item: FoundationItem?
        }
        @Published var selection = Selection(incarnation: UUID(), item: nil)
        var incarnation: UUID {
            get { selection.incarnation }
            set { selection = Selection(incarnation: newValue, item: selection.item) }
        }
        func select(_ item: FoundationItem) {
            selection = Selection(incarnation: UUID(), item: item)
        }
        var firstFrames: [UUID: Frame] = [:]
        var renderedImages: [UUID: [Image?]] = [:]
        var leafFrames: [UUID: [LeafFrame]] = [:]
        var completed: [UUID: Bool] = [:]
    }

    @MainActor
    private struct RecreatedArtworkHost: View {
        @ObservedObject var state: RecreatedArtworkState
        let item: FoundationItem
        let library: any FoundationLibrary
        let gate: RecreatedArtworkReadGate

        var body: some View {
            let selection = state.selection
            FoundationCatalogArtwork(
                item: selection.item ?? item, library: library, isActive: true, size: 144
            )
            .environment(
                \.foundationArtworkTaskObservation,
                .init(
                    phase: selection.incarnation,
                    rendered: { phase, image in
                        if state.firstFrames[phase] == nil {
                            state.firstFrames[phase] = .init(image: image)
                        }
                        state.renderedImages[phase, default: []].append(image)
                    },
                    beforeLoad: { try await gate.wait() },
                    leafUpdated: { phase, lifetime, image in
                        state.leafFrames[phase, default: []].append(
                            .init(lifetime: lifetime, image: image))
                    }
                ) { phase, active in state.completed[phase] = active }
            )
            .id(selection.incarnation)
        }
    }

    private actor RecreatedArtworkReadGate {
        private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        private(set) var begun = 0
        private(set) var requests = 0
        var pending: Int { waiters.count }

        func recordGET() { requests += 1 }

        func wait() async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters[id] = continuation
                        begun += 1
                    }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        private func cancel(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }

        func release() {
            let pending = waiters.values
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

#endif

/// Real bounded fixture traversal with injected platform protection metadata. No native cache.
nonisolated private final class NativeProtectionFixture: @unchecked Sendable {
    enum Failure: Equatable { case ignored, throwAfterWrite, generation, cancel, completeReadback }
    let container: URL
    let root: URL
    let leaf: URL
    let outside: URL
    let package: FoundationNativeDownloadPackage
    var classes: [String: String] = [:]
    var writes: [String] = []
    var resolutions = 0
    var replaceBeforeWrite = false
    var failure: Failure?
    var rootIdentity: String { FoundationManagedPackageMetadata.canonical(root).path }
    var leafIdentity: String { FoundationManagedPackageMetadata.canonical(leaf).path }
    var mismatchCanonicalRoot = false
    var classAtMutationGate: String?
    var replaceRootAtResolution: Int?
    private(set) var leafReads = 0
    private var changed = false

    init(aliased: Bool = false) throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let parent =
            aliased ? container.appendingPathComponent("alias", isDirectory: true) : container
        root = parent.appendingPathComponent("allocation", isDirectory: true)
        leaf = root.appendingPathComponent("synthetic")
        outside = container.appendingPathComponent("outside")
        package = FoundationNativeDownloadPackage(
            nativeURL: root, bookmark: Data("immutable-completed-proof".utf8),
            sessionIdentifier: "synthetic", namespaceBookmark: Data("immutable-parent".utf8))
        if aliased {
            let actual = container.appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: actual)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: leaf)
        try Data([9]).write(to: outside)
        classes[rootIdentity] = "NSFileProtectionCompleteUntilFirstUserAuthentication"
        classes[leafIdentity] = "NSFileProtectionNone"
    }
    func remove() { try? FileManager.default.removeItem(at: container) }
    func strengthen() throws {
        try FoundationNativeDownloadTransport.strengthenAllocationProtection(
            package,
            resolve: { package in
                self.resolutions += 1
                return package.bookmark == self.package.bookmark ? self.root : nil
            },
            resources: { url in
                let identity = FoundationManagedPackageMetadata.canonical(url).path
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let type = attrs[.type] as? FileAttributeType
                if identity == self.leafIdentity {
                    self.leafReads += 1
                    if self.leafReads == 2, let changed = self.classAtMutationGate {
                        self.classes[identity] = changed
                    }
                }
                let replacement =
                    (self.replaceBeforeWrite && self.leafReads > 1 && identity == self.leafIdentity)
                    || (self.replaceRootAtResolution.map { self.resolutions >= $0 } == true
                        && identity == self.rootIdentity)
                    || (self.mismatchCanonicalRoot && url.path == self.rootIdentity)
                // Use actual resource/volume identity for both raw and canonical aliases.
                // Only the deliberate replacement and generation-failure seams alter it.
                var values = try FoundationManagedPackageMetadata.resources(url)
                if replacement { values[.fileResourceIdentifierKey] = "replacement" as NSString }
                values[.generationIdentifierKey] = NSNumber(
                    value: self.changed && identity == self.leafIdentity ? 2 : 1)
                values[.isDirectoryKey] = type == .typeDirectory
                values[.isRegularFileKey] = type == .typeRegular
                values[.isSymbolicLinkKey] = type == .typeSymbolicLink
                return values
            },
            protection: { self.classes[FoundationManagedPackageMetadata.canonical($0).path] },
            setProtection: { url in
                self.writes.append(url.path)
                if self.failure != .ignored {
                    self.classes[FoundationManagedPackageMetadata.canonical(url).path] =
                        "NSFileProtectionCompleteUntilFirstUserAuthentication"
                }
                if self.failure == .completeReadback {
                    self.classes[FoundationManagedPackageMetadata.canonical(url).path] =
                        "NSFileProtectionComplete"
                }
                if self.failure == .throwAfterWrite { throw CocoaError(.fileWriteUnknown) }
                if self.failure == .generation { self.changed = true }
                if self.failure == .cancel { withUnsafeCurrentTask { $0?.cancel() } }
            })
    }
}
