import Combine
import CoreGraphics
import Foundation
import ImageIO
import Security
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import VelacantoFoundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

#if FOUNDATION_ISOLATED_TEST_HOST
    @MainActor
    final class FoundationAppLifecycleIsolationTests: XCTestCase {
        func testWidgetCommandsRejectForeignAndReplacedOccurrencesInActualAppOwner() async throws {
            try await withLifecycleFixture { fixture, model in
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let player = try XCTUnwrap(model.player)
                let scope = try XCTUnwrap(model.library).catalogAccountIdentity
                let track = FoundationItem(
                    id: "synthetic-widget-track", title: "Synthetic", subtitle: "", kind: .track,
                    duration: nil)
                let entry = FoundationQueueEntry(item: track)
                player.restoreSession(
                    .init(
                        entries: [entry], selectedEntryID: entry.id, shuffleEnabled: false,
                        repeatMode: .off))
                for command in [
                    FoundationWidgetCommand(
                        scope: String(repeating: "b", count: 64), occurrence: entry.id,
                        collectionID: nil, action: .play),
                    FoundationWidgetCommand(
                        scope: scope, occurrence: UUID(), collectionID: nil, action: .pause),
                ] {
                    do {
                        try await model.performWidgetCommand(command)
                        XCTFail("A stale or foreign widget command reached playback")
                    } catch FoundationWidgetIntentFailure.unavailable {
                    }
                }
                XCTAssertEqual(player.selectedEntryID, entry.id)
                XCTAssertFalse(player.wantsPlayback)
                try await model.performWidgetCommand(
                    .init(
                        scope: scope, occurrence: entry.id, collectionID: nil, action: .pause))
                XCTAssertEqual(player.selectedEntryID, entry.id)
                XCTAssertFalse(player.wantsPlayback)
            }
        }

        func testWidgetCleanupFailurePreventsActualSignOutCompletionAndRetries() async throws {
            try await withLifecycleFixture { fixture, model in
                // A directory cannot be replaced by the publisher's atomic file rename.
                // Install the disposable fault before any account publisher is created.
                let directory = fixture.root.appendingPathComponent("widgets", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                let target = directory.appendingPathComponent("snapshot.json", isDirectory: true)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: false)
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let player = try XCTUnwrap(model.player)
                let track = FoundationItem(
                    id: "widget-fault-song", title: "Synthetic", subtitle: "", kind: .track,
                    duration: nil)
                let occurrence = FoundationQueueEntry(item: track)
                player.restoreSession(
                    .init(
                        entries: [occurrence], selectedEntryID: occurrence.id,
                        shuffleEnabled: false, repeatMode: .off))
                var commands = 0
                let observation = player.playbackCommandReceived.sink { commands += 1 }
                defer { observation.cancel() }
                let outcome = try await model.performWidgetCommand(
                    .init(
                        scope: try XCTUnwrap(model.library).catalogAccountIdentity,
                        occurrence: occurrence.id, collectionID: nil, action: .pause))
                XCTAssertEqual(outcome, .acceptedWithPublicationFailure)
                XCTAssertEqual(
                    commands, 1, "Optional metadata failure must not suppress the accepted command")
                XCTAssertEqual(player.selectedEntryID, occurrence.id)
                model.signOut()
                fixture.captureStop(player)
                fixture.gate.release()
                try await fixture.drain(using: self)
                XCTAssertTrue(model.signOutCleanupError?.contains("Widget playback") == true)
                XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
                try FileManager.default.removeItem(at: target)
                do {
                    _ = try await model.prepareSignIn {
                        XCTFail("Authentication must not start while cleanup is pending")
                        return fixture.session(user: "00000000000000000000000000000001")
                    }
                    XCTFail("Pending cleanup must reject new sign-in")
                } catch FoundationDownloadAccountError.cleanupPending {
                }
                try await fixture.drain(using: self)
                XCTAssertNil(model.signOutCleanupError)
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            }
        }

        func testWidgetRetiresHeldOptionalArtworkBeforeStructuredClear() async throws {
            let entered = XCTestExpectation(description: "optional collection artwork entered")
            let artworkGate = LifecycleGate(entered: entered)
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "revocation entered"))
            let collectionID = "00000000000000000000000000000003"
            let currentAlbumID = "00000000000000000000000000000004"
            let image = try widgetArtworkBytes()
            let model = fixture.makeModel(loadOverride: { request in
                if request.url?.path.contains(collectionID + "/Images/") == true {
                    await artworkGate.hold()
                    try Task.checkCancellation()
                }
                if request.url?.path.contains(currentAlbumID + "/Images/") == true,
                    let url = request.url,
                    let response = HTTPURLResponse(
                        url: url, statusCode: 200,
                        httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"])
                {
                    return (image, response)
                }
                throw URLError(.notConnectedToInternet)
            })
            var progress: Task<Void, Never>?
            do {
                let startup = Task { _ = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForTask(startup, label: "widget artwork startup")
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let player = try XCTUnwrap(model.player)
                let scope = try XCTUnwrap(model.library).catalogAccountIdentity
                var collection = FoundationItem(
                    id: collectionID, title: "Synthetic playlist", subtitle: "Synthetic",
                    kind: .playlist, duration: nil)
                collection.primaryImageTag = "synthetic-revision"
                let directory = fixture.root.appendingPathComponent("widgets", isDirectory: true)
                let store = FoundationWidgetStore(location: .directory(directory))
                var track = FoundationItem(
                    id: "00000000000000000000000000000005",
                    title: "Current song", subtitle: "Artist", kind: .track, duration: nil)
                track.album = .init(
                    id: currentAlbumID, title: "Current album", primaryImageTag: "current-art")
                let occurrence = FoundationQueueEntry(item: track)
                var saved = FoundationPlaybackSnapshot(
                    entries: [occurrence], selectedEntryID: occurrence.id,
                    shuffleEnabled: false, repeatMode: .off)
                saved.lastCollection = FoundationWidgetSnapshot.Collection(collection)
                player.restoreSession(saved)
                model.refreshWidgetPresentation()
                try await waitForEvents([entered], label: "held widget collection artwork")
                XCTAssertTrue(artworkGate.isHeld)
                let currentPublished = Task {
                    let clock = ContinuousClock()
                    let deadline = clock.now.advanced(by: .seconds(5))
                    while !Task.isCancelled, clock.now < deadline {
                        if let record = try? store.load(), record.occurrence == occurrence.id,
                            record.recentCollection?.id == collectionID,
                            store.artwork(for: record) != nil
                        {
                            return
                        }
                        await Task.yield()
                    }
                }
                progress = currentPublished
                fixture.tasks.append(currentPublished)
                try await waitForTask(
                    currentPublished,
                    label: "current metadata and artwork while recent artwork held")
                XCTAssertNotNil(store.artwork(for: try store.load()))
                XCTAssertEqual(try store.load().recentCollection?.id, collectionID)
                XCTAssertNil(store.artwork(for: try store.load(), mode: .recentCollection))
                track.title = "Updated while recent artwork held"
                let updated = FoundationQueueEntry(id: occurrence.id, item: track)
                saved = FoundationPlaybackSnapshot(
                    entries: [updated], selectedEntryID: updated.id,
                    shuffleEnabled: false, repeatMode: .off)
                saved.lastCollection = FoundationWidgetSnapshot.Collection(collection)
                player.restoreSession(saved)
                var flushError: Error?
                var outcome: FoundationWidgetCommandOutcome?
                let flush = Task {
                    do {
                        outcome = try await model.performWidgetCommand(
                            .init(
                                scope: scope, occurrence: occurrence.id, collectionID: nil,
                                action: .pause))
                    } catch { flushError = error }
                }
                fixture.tasks.append(flush)
                try await waitForTask(
                    flush, label: "metadata-only intent flush with optional artwork held")
                if let flushError { throw flushError }
                XCTAssertEqual(outcome, .accepted)
                XCTAssertEqual(try store.load().title, track.title)
                XCTAssertTrue(artworkGate.isHeld)
                model.signOut()
                fixture.captureStop(player)
                let clearing = Task {
                    let clock = ContinuousClock()
                    let deadline = clock.now.advanced(by: .seconds(5))
                    while FileManager.default.fileExists(atPath: directory.path),
                        !Task.isCancelled, clock.now < deadline
                    {
                        await Task.yield()
                    }
                }
                progress = clearing
                fixture.tasks.append(clearing)
                try await waitForTask(clearing, label: "widget retirement and structured clear")
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
                XCTAssertTrue(artworkGate.isHeld)
                // Full cache invalidation still owns and joins the held native producer.
                // Only the cancelled optional widget consumer has retired at this point.
                XCTAssertTrue(model.isCleaningDownloads)
                artworkGate.release()
                fixture.gate.release()
                try await fixture.drain(using: self)
                XCTAssertFalse(model.isCleaningDownloads)
                XCTAssertNil(model.signOutCleanupError)
                guard !model.isCleaningDownloads, model.signOutCleanupError == nil else {
                    throw CancellationError()
                }
                fixture.removeData()
            } catch {
                progress?.cancel()
                artworkGate.release()
                fixture.gate.release()
                fixture.deleteStatus = errSecSuccess
                if let player = model.player {
                    model.signOut()
                    fixture.captureStop(player)
                }
                do {
                    try await fixture.releaseResources(using: self)
                    try await fixture.drain(using: self)
                } catch {
                    XCTFail("Could not drain held widget artwork owners; retaining fixture")
                }
                // Retain failure evidence even after the owned work successfully joins.
                throw error
            }
        }

        private func widgetArtworkBytes() throws -> Data {
            let context = try XCTUnwrap(
                CGContext(
                    data: nil, width: 32, height: 32,
                    bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            let bytes = NSMutableData()
            let destination = try XCTUnwrap(
                CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return bytes as Data
        }

        func testWidgetRecentStartAdmitsEarlierAdvanceButRejectsQueueAndPauseInterruptions()
            async throws
        {
            try await checkWidgetRecentStartInterruption(.queueReplacement)
            try await checkWidgetRecentStartInterruption(.pause)
        }

        private enum WidgetRecentInterruption: Equatable { case queueReplacement, pause }

        private func checkWidgetRecentStartInterruption(_ interruption: WidgetRecentInterruption)
            async throws
        {
            let entered = XCTestExpectation(description: "recent collection fetch held")
            let loadGate = LifecycleGate(entered: entered)
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "revocation entered"))
            let collectionID = "00000000000000000000000000000003"
            let model = fixture.makeModel(loadOverride: { request in
                if request.url?.path.contains("/Playlists/" + collectionID + "/Items") == true {
                    await loadGate.hold()
                    try Task.checkCancellation()
                    let body = Data(
                        "{\"Items\":[{\"Id\":\"00000000000000000000000000000009\",\"Name\":\"Late collection song\",\"Type\":\"Audio\"}],\"StartIndex\":0,\"TotalRecordCount\":1}"
                            .utf8)
                    guard let url = request.url,
                        let response = HTTPURLResponse(
                            url: url, statusCode: 200,
                            httpVersion: nil, headerFields: ["Content-Type": "application/json"])
                    else {
                        throw FoundationLibraryError.invalidResponse
                    }
                    return (body, response)
                }
                throw URLError(.notConnectedToInternet)
            })
            do {
                let startup = Task { _ = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForTask(startup, label: "recent action startup")
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let player = try XCTUnwrap(model.player)
                let actions = try XCTUnwrap(model.actions)
                let scope = try XCTUnwrap(model.library).catalogAccountIdentity
                let recent = FoundationWidgetSnapshot.Collection(
                    id: collectionID, kind: "playlist",
                    title: "Recent playlist", subtitle: "", imageTag: nil)
                let first = FoundationQueueEntry(
                    item: .init(
                        id: "first", title: "First", subtitle: "", kind: .track, duration: nil))
                var saved = FoundationPlaybackSnapshot(
                    entries: [first], selectedEntryID: first.id,
                    shuffleEnabled: false, repeatMode: .off)
                saved.lastCollection = recent
                player.restoreSession(saved)
                let display = FoundationWidgetPlayback.snapshot(scope: scope, player: player)
                    .display(.recentCollection)
                XCTAssertEqual(display.action, .collection)
                let beforeTap = FoundationQueueEntry(
                    item: .init(
                        id: "before-tap", title: "Advanced", subtitle: "", kind: .track,
                        duration: nil))
                saved = FoundationPlaybackSnapshot(
                    entries: [beforeTap], selectedEntryID: beforeTap.id,
                    shuffleEnabled: false, repeatMode: .off)
                saved.lastCollection = recent
                player.restoreSession(saved)
                var failure: Error?
                let command = Task {
                    do {
                        _ = try await model.performWidgetCommand(
                            .init(
                                scope: scope,
                                occurrence: nil, collectionID: recent.id, action: .collection,
                                mode: .recentCollection, collectionKind: recent.kind))
                    } catch { failure = error }
                }
                fixture.tasks.append(command)
                try await waitForEvents(
                    [entered], label: "explicit recent start after earlier advance")
                try await waitForTask(command, label: "recent action metadata flush")
                if let failure { throw failure }
                let collectionTask = try XCTUnwrap(actions.queueTask)
                fixture.tasks.append(collectionTask)
                XCTAssertEqual(player.selectedEntryID, beforeTap.id)
                let expectedSelection: UUID
                if interruption == .queueReplacement {
                    player.setQueue(
                        [
                            .init(
                                id: "newer-ui", title: "Newer UI selection", subtitle: "",
                                kind: .track, duration: nil)
                        ], selectedIndex: 0)
                    if let selection = player.selectionTask { fixture.tasks.append(selection) }
                    expectedSelection = try XCTUnwrap(player.selectedEntryID)
                } else {
                    player.pause()
                    expectedSelection = beforeTap.id
                }
                XCTAssertTrue(
                    collectionTask.isCancelled,
                    "A newer explicit control must retire this widget-owned fetch")
                loadGate.release()
                try await waitForTask(
                    collectionTask, label: "cancelled recent collection fetch joined")
                XCTAssertEqual(player.selectedEntryID, expectedSelection)
                if interruption == .queueReplacement {
                    XCTAssertEqual(player.queue.last?.item.id, "newer-ui")
                } else {
                    XCTAssertEqual(player.queue.last?.item.id, "before-tap")
                    XCTAssertFalse(player.wantsPlayback)
                }
                XCTAssertFalse(
                    player.queue.contains { $0.item.id == "00000000000000000000000000000009" })
                model.signOut()
                fixture.captureStop(player)
                fixture.gate.release()
                let cleanup = Task {
                    let clock = ContinuousClock()
                    let deadline = clock.now.advanced(by: .seconds(5))
                    while !Task.isCancelled, clock.now < deadline {
                        if model.library == nil, !model.isCleaningDownloads { return }
                        await Task.yield()
                    }
                }
                fixture.tasks.append(cleanup)
                try await waitForTask(cleanup, label: "recent-action structured cleanup")
                try await fixture.drain(using: self)
                guard model.library == nil, !model.isCleaningDownloads,
                    model.signOutCleanupError == nil
                else {
                    XCTFail("Recent-action cleanup did not complete; retaining fixture")
                    throw CancellationError()
                }
                fixture.removeData()
            } catch {
                loadGate.release()
                fixture.gate.release()
                if let player = model.player {
                    model.signOut()
                    fixture.captureStop(player)
                }
                do { try await fixture.drain(using: self) } catch {
                    XCTFail("Could not join recent-action owners; retaining fixture")
                }
                throw error
            }
        }

        func testEmptyLateEventRefencesAcrossCredentialCommit() async throws {
            try await exerciseEmptyEventDuringCommit(phase: "record-before")
        }

        func testEmptyLateEventCompletesAfterCredentialCommitBeforeMarkerRemoval() async throws {
            try await exerciseEmptyEventDuringCommit(phase: "record-after")
        }

        func testEmptyLateEventRefencesAcrossMarkerRemoval() async throws {
            try await exerciseEmptyEventDuringCommit(phase: "remove-before")
        }

        func testEmptyLateEventCompletesAfterMarkerRemovalBeforeOwnerCommit() async throws {
            try await exerciseEmptyEventDuringCommit(phase: "remove-after")
        }

        private func exerciseEmptyEventDuringCommit(phase: String) async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "synthetic revocation"))
            let keychain = IntentKeychainFixture()
            keychain.credentialData = nil
            let operations = keychain.operations()
            let transactionRoot = fixture.root.appendingPathComponent(
                "late-commit", isDirectory: true)
            let commitEntered = XCTestExpectation(description: "selected actual transaction phase")
            let nativeEntered = XCTestExpectation(description: "held empty native observation")
            let commitGate = LifecycleGate(entered: commitEntered)
            let nativeGate = LifecycleGate(entered: nativeEntered)
            defer {
                commitGate.release()
                nativeGate.release()
                fixture.gate.release()
            }
            let transactions = FoundationAccountTransactions(
                inspect: {
                    try FoundationAccountCredentialTransaction.inspect(
                        root: transactionRoot, operations: operations)
                },
                prepareSignOut: { value, snapshot, preparation in
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        value, expecting: snapshot, preparation: preparation, root: transactionRoot,
                        operations: operations)
                },
                finishCompletedSignOut: { marker in
                    if phase == "remove-before" { await commitGate.hold() }
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        marker, root: transactionRoot, operations: operations)
                    if phase == "remove-after" { await commitGate.hold() }
                },
                recordSignOut: { value, marker, snapshot in
                    if phase == "record-before" { await commitGate.hold() }
                    let completed =
                        try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                            value, intent: marker, expecting: snapshot, root: transactionRoot,
                            operations: operations)
                    if phase == "record-after" { await commitGate.hold() }
                    return completed
                })
            var nativeCalls = 0
            let model = fixture.makeModel(
                emptyNativeSession: { _, current, _ in
                    nativeCalls += 1
                    guard await current() else { return .unavailable }
                    if nativeCalls == 1 {
                        await nativeGate.hold()
                    } else if nativeCalls > 2 {
                        XCTFail("Repeated a stable commit empty-session probe")
                        return .unavailable
                    }
                    let evidence = FoundationNativeEmptySessionEvidence()
                    evidence.recordInventory(count: 0)
                    evidence.recordInvalidation(succeeded: true)
                    evidence.acknowledgeFinality()
                    return evidence.outcome
                }, useModelBackgroundRouting: true,
                inspectSignOutIntent: {
                    do {
                        return try FoundationSignOutIntentStore.load(operations: operations) == nil
                            ? .absent : .pending
                    } catch { return .unavailable }
                }, accountTransactions: transactions, credentialOperations: operations)
            do {
                let startup = Task { _ = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForTask(startup, label: "late commit model startup")
                let session = fixture.session(user: "00000000000000000000000000000001")
                try await fixture.open(model, user: session.userID)
                let scope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
                    + UUID().uuidString
                let otherKey = FoundationPinStorage.key(for: String(repeating: "b", count: 64))
                let otherBytes = Data("unrelated account late-event sentinel".utf8)
                fixture.defaults.set(otherBytes, forKey: otherKey)
                let attemptEnded = XCTestExpectation(
                    description: "finalization paused on late event")
                let attemptObserver = model.$isFinalizingDurableSignOut.dropFirst().filter { !$0 }
                    .first().sink { _ in attemptEnded.fulfill() }
                defer { attemptObserver.cancel() }
                let player = try XCTUnwrap(model.player)
                model.signOut()
                fixture.captureStop(player)
                try await waitForEvents([commitEntered], label: "held account transaction phase")
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
                var completions = 0
                let acknowledged = XCTestExpectation(
                    description: "late committed event acknowledged")
                model.receiveBackgroundDownloadEvents(identifier) {
                    completions += 1
                    acknowledged.fulfill()
                }
                try await waitForEvents(
                    [nativeEntered], label: "held native observation during transaction")
                XCTAssertEqual(completions, 0)
                let finished = XCTestExpectation(description: "late event sign-out fully finalized")
                let finishedObserver = model.$accountInspectionIssue.filter { $0 == nil }.first()
                    .sink { _ in finished.fulfill() }
                defer { finishedObserver.cancel() }
                commitGate.release()
                try await waitForEvents(
                    [attemptEnded], label: "transaction preserves pending event")
                XCTAssertEqual(completions, 0)
                nativeGate.release()
                try await waitForEvents(
                    [acknowledged, finished], label: "refenced native event and account completion")
                XCTAssertEqual(completions, 1)
                XCTAssertEqual(
                    nativeCalls, phase == "record-before" || phase == "remove-before" ? 2 : 1)
                XCTAssertNil(keychain.credentialData)
                XCTAssertNil(keychain.payload)
                XCTAssertNil(model.signOutCleanupError)
                XCTAssertEqual(fixture.defaults.data(forKey: otherKey), otherBytes)
                fixture.gate.release()
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                commitGate.release()
                nativeGate.release()
                fixture.gate.release()
                do { try await fixture.drain(using: self) } catch {
                    XCTFail("Could not drain late commit fixture; data retained")
                }
                throw error
            }
        }

        func testEmptyOldEventPreservesSignedOutAccountSnapshot() async throws {
            try await exerciseEmptyOldEvent(mode: "signed-out")
        }

        func testEmptyOldEventPreservesDifferentCurrentAccountAndLease() async throws {
            try await exerciseEmptyOldEvent(mode: "current-different")
        }

        func testEmptyOldEventPreservesSameCurrentAccountAndLease() async throws {
            try await exerciseEmptyOldEvent(mode: "current-same")
        }

        func testEmptyOldEventRejectsNewCredentialDuringObservation() async throws {
            try await exerciseEmptyOldEvent(mode: "credential-appears")
        }

        func testEmptyOldEventRejectsNewTargetReferenceDuringObservation() async throws {
            try await exerciseEmptyOldEvent(mode: "target-appears")
        }

        func testEmptyOldEventAllowsUnrelatedSameScopeDataWithoutMutation() async throws {
            try await exerciseEmptyOldEvent(mode: "unrelated-appears")
        }

        func testEmptyOldEventRefencesAfterNewOwnerPublication() async throws {
            try await exerciseEmptyOldEvent(mode: "owner-appears")
        }

        func testEmptyOldEventCancellationRetainsCompletionAndData() async throws {
            try await exerciseEmptyOldEvent(mode: "cancelled")
        }

        func testEmptyOldEventDoesNotProbeClaimedCurrentNativeSession() async throws {
            try await exerciseEmptyOldEvent(mode: "claimed-session")
        }

        func testEmptyOldEventDoesNotForgetNativeWorkOnOwnerPublicationReplay() async throws {
            try await exerciseEmptyOldEvent(mode: "native-work-owner")
        }

        func testEmptyOldEventRejectsWeakNativeObservations() async throws {
            for mode in ["nonempty-native", "native-allocation", "native-error", "drain-only"] {
                try await exerciseEmptyOldEvent(mode: mode)
            }
        }

        private func exerciseEmptyOldEvent(mode: String) async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            let keychain = IntentKeychainFixture()
            let old = fixture.session(user: "00000000000000000000000000000001")
            keychain.credentialData = try JSONEncoder().encode(old)
            let operations = keychain.operations()
            let transactionRoot = fixture.root.appendingPathComponent(
                "old-transaction", isDirectory: true)
            let transactions = FoundationAccountTransactions(
                inspect: {
                    try FoundationAccountCredentialTransaction.inspect(
                        root: transactionRoot, operations: operations)
                },
                prepareSignOut: { value, snapshot, preparation in
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        value, expecting: snapshot, preparation: preparation, root: transactionRoot,
                        operations: operations)
                },
                finishCompletedSignOut: { marker in
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        marker, root: transactionRoot, operations: operations)
                },
                recordSignOut: { value, marker, snapshot in
                    try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                        value, intent: marker, expecting: snapshot, root: transactionRoot,
                        operations: operations)
                })
            let before = try FoundationAccountCredentialTransaction.inspect(
                root: transactionRoot, operations: operations)
            let intent = try FoundationAccountCredentialTransaction.prepareSignOut(
                old, expecting: before, root: transactionRoot, operations: operations)
            let prepared = try FoundationAccountCredentialTransaction.inspect(
                root: transactionRoot, operations: operations)
            let completed = try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                old, intent: intent, expecting: prepared, root: transactionRoot,
                operations: operations)
            try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                completed, root: transactionRoot, operations: operations)
            let entered = XCTestExpectation(description: "empty native observer entered")
            let secondEntered = XCTestExpectation(description: "refenced observer entered")
            let gate = LifecycleGate(entered: entered)
            let secondGate = LifecycleGate(entered: secondEntered)
            defer {
                gate.release()
                secondGate.release()
                fixture.gate.release()
            }
            var nativeCalls = 0
            var drainCalls = 0
            let model = fixture.makeModel(
                leaseWaitStarted: {},
                emptyNativeSession: { _, current, drained in
                    nativeCalls += 1
                    guard await current() else { return .unavailable }
                    if nativeCalls == 1 {
                        await gate.hold()
                    } else if nativeCalls == 2 && mode == "owner-appears" {
                        await secondGate.hold()
                    } else {
                        XCTFail("Unexpected empty-session replay")
                        return .unavailable
                    }
                    let evidence = FoundationNativeEmptySessionEvidence()
                    if mode != "drain-only" {
                        evidence.recordInventory(count: mode == "nonempty-native" ? 1 : 0)
                    }
                    if mode == "native-allocation" || mode == "native-work-owner" {
                        evidence.observeTaskAllocationOrChallenge()
                    }
                    if mode == "drain-only" {
                        evidence.recordDrainDelivery()
                        drained()
                        drainCalls += 1
                        evidence.acknowledgeDrainDelivery()
                    }
                    if Task.isCancelled { evidence.cancel() }
                    evidence.recordInvalidation(succeeded: mode != "native-error")
                    evidence.acknowledgeFinality()
                    // Deliberately do not recheck account current() here: the
                    // actual model must reject stale successful native evidence.
                    return evidence.outcome
                }, useModelBackgroundRouting: true,
                inspectSignOutIntent: {
                    do {
                        return try FoundationSignOutIntentStore.load(operations: operations) == nil
                            ? .absent : .pending
                    } catch { return .unavailable }
                }, accountTransactions: transactions, credentialOperations: operations)
            do {
                let startup = Task { _ = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForTask(startup, label: "empty event model startup")
                let oldScope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + old.serverURL.absoluteString + "\0" + old.userID)
                let oldDirectory = FoundationDownloadStorage.directory(
                    scope: oldScope, root: fixture.storage.downloads)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + oldDirectory.lastPathComponent + "."
                    + UUID().uuidString
                let track = FoundationItem(
                    id: "current-track", title: "Synthetic current", subtitle: "", kind: .track,
                    duration: nil)
                var currentFile: URL?
                var currentFileBytes: Data?
                if mode == "current-different" || mode == "current-same"
                    || mode == "claimed-session"
                {
                    let current = fixture.session(
                        user: mode == "current-different"
                            ? "00000000000000000000000000000002" : old.userID)
                    let acceptance = try await model.prepareSignIn { current }
                    let scope = FoundationMusicLibraryStore.digest(
                        "jellyfin\0" + current.serverURL.absoluteString + "\0" + current.userID)
                    let directory = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads)
                    try FoundationDownloadStorage.prepare(directory)
                    let file = directory.appendingPathComponent("current.audio")
                    let bytes = Data("synthetic current local resource".utf8)
                    try bytes.write(to: file)
                    let stored = FoundationStoredDownloadItem(track)
                    var manifest = FoundationDownloadManifest()
                    manifest.owners = [
                        .init(
                            id: "track:" + track.id, item: stored, tracks: [stored], paused: true,
                            expanded: false)
                    ]
                    manifest.files[track.id] = .init(
                        name: file.lastPathComponent, bytes: Int64(bytes.count),
                        digest: try FoundationDownloadStorage.digest(file))
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    try await acceptance()
                    let owner = try XCTUnwrap(model.downloads)
                    let inventory = XCTestExpectation(description: "current resource inventory")
                    let observer = owner.$isLoading.filter { !$0 }.first().sink { _ in
                        inventory.fulfill()
                    }
                    defer { observer.cancel() }
                    try await waitForEvents([inventory], label: "current account local inventory")
                    try await fixture.acquireResource(from: owner, item: track, using: self)
                    currentFile = file
                    currentFileBytes = bytes
                    if mode == "claimed-session" {
                        try owner.isolatedSeedAllocatedFile(
                            trackID: "current-native",
                            file: .init(
                                name: "claimed.movpkg", bytes: 1, digest: "",
                                nativePackage: .init(
                                    nativeURL: fixture.root.appendingPathComponent(
                                        "never-opened.movpkg"),
                                    bookmark: Data("opaque".utf8), sessionIdentifier: identifier,
                                    namespaceBookmark: Data("opaque-parent".utf8))))
                    }
                }
                let otherKey = FoundationPinStorage.key(for: String(repeating: "b", count: 64))
                let otherBytes = Data("unrelated account sentinel".utf8)
                fixture.defaults.set(otherBytes, forKey: otherKey)
                var completions = 0
                let acknowledged = XCTestExpectation(description: "empty old event acknowledged")
                let settled = XCTestExpectation(description: "first empty route settled")
                let secondSettled = XCTestExpectation(description: "blocked replay route settled")
                var routes = 0
                model.backgroundRoutingSettled = { value in
                    if value == identifier {
                        routes += 1
                        if routes == 1 { settled.fulfill() }
                        if routes == 2 { secondSettled.fulfill() }
                    }
                }
                defer { model.backgroundRoutingSettled = nil }
                model.receiveBackgroundDownloadEvents(identifier) {
                    completions += 1
                    acknowledged.fulfill()
                }
                var expectedPlayer = model.player
                var expectedOwner = model.downloads
                var appearanceFile: URL?
                var appearanceBytes: Data?
                if mode != "claimed-session" {
                    try await waitForEvents([entered], label: "held native empty-session evidence")
                    XCTAssertEqual(completions, 0)
                    if mode == "credential-appears" {
                        try FoundationCredentials.save(
                            fixture.session(user: "00000000000000000000000000000002"),
                            operations: operations)
                    } else if mode == "target-appears" || mode == "unrelated-appears" {
                        try FoundationDownloadStorage.prepare(oldDirectory)
                        var manifest = FoundationDownloadManifest()
                        if mode == "target-appears" {
                            manifest.nativePendingSessions = [identifier]
                        }
                        let file = oldDirectory.appendingPathComponent("arrived.audio")
                        let bytes = Data("new same-scope data".utf8)
                        try bytes.write(to: file)
                        manifest.files["arrived"] = .init(
                            name: file.lastPathComponent, bytes: Int64(bytes.count),
                            digest: try FoundationDownloadStorage.digest(file))
                        try FoundationDownloadStorage.save(manifest, directory: oldDirectory)
                        appearanceFile = file
                        appearanceBytes = bytes
                    } else if mode == "owner-appears" || mode == "native-work-owner" {
                        try FoundationCredentials.save(
                            fixture.session(user: "00000000000000000000000000000002"),
                            operations: operations)
                        model.restoreCredentials()
                        XCTAssertNil(
                            model.player,
                            "Owner publication remains deferred while native evidence is held")
                        XCTAssertNil(model.downloads)
                    } else if mode == "cancelled" {
                        let routing = try XCTUnwrap(model.isolatedBackgroundDownloadTask)
                        routing.cancel()
                    }
                }
                let protectedCredential = keychain.credentialData
                let protectedGeneration = keychain.credentialGeneration
                let protectedMarker = keychain.payload
                let protectedDeletes = keychain.credentialDeletes
                let stopCount = fixture.events.snapshot().filter { $0.contains("command.stop") }
                    .count
                gate.release()
                try await waitForEvents([settled], label: "first empty session route completion")
                if mode == "owner-appears" {
                    try await waitForEvents(
                        [secondEntered], label: "new owner fenced empty-session replay")
                    XCTAssertEqual(completions, 0)
                    expectedPlayer = try XCTUnwrap(model.player)
                    expectedOwner = try XCTUnwrap(model.downloads)
                    secondGate.release()
                }
                if mode == "native-work-owner" {
                    try await waitForEvents(
                        [secondSettled], label: "sticky native work refusal after owner publication"
                    )
                    expectedPlayer = try XCTUnwrap(model.player)
                    expectedOwner = try XCTUnwrap(model.downloads)
                    XCTAssertEqual(
                        nativeCalls, 1, "A replay cannot discard previously observed native work")
                }
                let succeeds = [
                    "signed-out", "current-different", "current-same", "unrelated-appears",
                    "owner-appears",
                ].contains(mode)
                if succeeds {
                    try await waitForEvents(
                        [acknowledged], label: "validated empty event acknowledgement")
                }
                XCTAssertEqual(completions, succeeds ? 1 : 0)
                XCTAssertEqual(
                    nativeCalls, mode == "claimed-session" ? 0 : (mode == "owner-appears" ? 2 : 1))
                XCTAssertEqual(drainCalls, mode == "drain-only" ? 1 : 0)
                XCTAssertTrue(model.player === expectedPlayer)
                XCTAssertTrue(model.downloads === expectedOwner)
                XCTAssertEqual(keychain.credentialData, protectedCredential)
                XCTAssertEqual(keychain.credentialGeneration, protectedGeneration)
                XCTAssertEqual(keychain.payload, protectedMarker)
                XCTAssertEqual(keychain.credentialDeletes, protectedDeletes)
                XCTAssertEqual(
                    fixture.events.snapshot().filter { $0.contains("command.stop") }.count,
                    stopCount)
                XCTAssertEqual(fixture.defaults.data(forKey: otherKey), otherBytes)
                if let currentFile, let currentFileBytes {
                    XCTAssertEqual(try Data(contentsOf: currentFile), currentFileBytes)
                    XCTAssertEqual(fixture.resources.count, 1)
                }
                if let appearanceFile, let appearanceBytes {
                    XCTAssertEqual(try Data(contentsOf: appearanceFile), appearanceBytes)
                }
                try await fixture.releaseResources(using: self)
                fixture.gate.release()
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                gate.release()
                secondGate.release()
                fixture.gate.release()
                do { try await fixture.releaseResources(using: self) } catch {
                    XCTFail("Could not release empty-event fixture resource")
                }
                do { try await fixture.drain(using: self) } catch {
                    XCTFail("Could not drain empty-event fixture; data retained")
                }
                throw error
            }
        }

        func testEmptySessionNamespaceParserRequiresExactAppGrammar() {
            let scope = String(repeating: "a", count: 64)
            let token = UUID().uuidString
            let valid = "dev.novoluxor.velacanto.offline." + scope + "." + token
            XCTAssertEqual(
                FoundationNativeAllocationStore.directoryScope(forSessionIdentifier: valid), scope)
            for invalid in [
                "external." + scope + "." + token,
                "dev.novoluxor.velacanto.offline." + String(repeating: "A", count: 64) + "."
                    + token,
                "dev.novoluxor.velacanto.offline." + String(repeating: "a", count: 63) + "."
                    + token,
                "dev.novoluxor.velacanto.offline." + scope + "/" + token,
                valid + ".extra", String(valid.dropLast()), "../" + valid,
            ] {
                XCTAssertNil(
                    FoundationNativeAllocationStore.directoryScope(forSessionIdentifier: invalid))
            }
        }

        func testEmptySessionAbsenceAllowsUnrelatedCurrentScopeStateWithoutMutation() async throws {
            for mode in ["missing-root", "empty-scope", "ordinary-current", "unrelated-native"] {
                let fixture = try LifecycleFixture(
                    entered: XCTestExpectation(description: "unused revocation"))
                defer { fixture.gate.release() }
                let scope = String(repeating: "a", count: 64)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + scope + "." + UUID().uuidString
                let directory = fixture.storage.downloads.appendingPathComponent(
                    scope, isDirectory: true)
                var manifestBefore: Data?
                var sentinel: URL?
                if mode != "missing-root" {
                    try FoundationDownloadStorage.prepare(directory)
                    var manifest = FoundationDownloadManifest()
                    if mode == "ordinary-current" {
                        let file = directory.appendingPathComponent("current.audio")
                        try Data("current account sentinel".utf8).write(to: file)
                        sentinel = file
                        manifest.files["current"] = .init(
                            name: file.lastPathComponent, bytes: 24,
                            digest: try FoundationDownloadStorage.digest(file))
                    } else if mode == "unrelated-native" {
                        let other =
                            "dev.novoluxor.velacanto.offline." + scope + "." + UUID().uuidString
                        manifest.files["different-current-native"] = .init(
                            name: "unresolved-synthetic.movpkg", bytes: 1, digest: "",
                            nativePackage: .init(
                                nativeURL: fixture.root.appendingPathComponent(
                                    "never-opened.movpkg"),
                                bookmark: Data("opaque-synthetic".utf8), sessionIdentifier: other,
                                namespaceBookmark: Data("opaque-namespace".utf8)))
                    }
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    manifestBefore = try Data(
                        contentsOf: directory.appendingPathComponent("manifest.json"))
                }
                let allowed = await FoundationScopedAccountRemoval.nativeSessionIsUnrepresented(
                    root: fixture.storage.downloads, identifier: identifier)
                XCTAssertTrue(allowed, mode)
                if let manifestBefore {
                    XCTAssertEqual(
                        try Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                        manifestBefore)
                } else {
                    XCTAssertFalse(
                        FileManager.default.fileExists(atPath: fixture.storage.downloads.path))
                }
                if let sentinel {
                    XCTAssertEqual(
                        try Data(contentsOf: sentinel), Data("current account sentinel".utf8))
                }
                fixture.removeData()
            }
        }

        func testEmptySessionAbsenceRejectsReferencesAndAmbiguousFilesystemState() async throws {
            for mode in [
                "pending", "native", "artwork", "receipt", "receipt-symlink", "scope-symlink",
                "malformed-manifest", "manifest-symlink",
            ] {
                let fixture = try LifecycleFixture(
                    entered: XCTestExpectation(description: "unused revocation"))
                defer { fixture.gate.release() }
                let scope = String(repeating: "a", count: 64)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + scope + "." + UUID().uuidString
                let directory = fixture.storage.downloads.appendingPathComponent(
                    scope, isDirectory: true)
                try FoundationDownloadStorage.prepare(directory)
                let store = FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: identifier)
                let file = FoundationDownloadManifest.File(
                    name: "unresolved-synthetic.movpkg", bytes: 1, digest: "",
                    nativePackage: .init(
                        nativeURL: fixture.root.appendingPathComponent("never-opened.movpkg"),
                        bookmark: Data("opaque-synthetic".utf8), sessionIdentifier: identifier,
                        namespaceBookmark: Data("opaque-namespace".utf8)))
                var manifest = FoundationDownloadManifest()
                if mode == "pending" { manifest.nativePendingSessions = [identifier] }
                if mode == "native" { manifest.files["native"] = file }
                if mode == "artwork" {
                    manifest.artwork = ["artwork": .init(item: .init(fixture.album), file: file)]
                }
                try FoundationDownloadStorage.save(manifest, directory: directory)
                let manifestURL = directory.appendingPathComponent("manifest.json")
                if mode == "receipt" {
                    try Data("unreadable synthetic receipt".utf8).write(to: store.receiptURL)
                } else if mode == "receipt-symlink" {
                    try FileManager.default.createSymbolicLink(
                        at: store.receiptURL,
                        withDestinationURL: fixture.root.appendingPathComponent("absent-receipt"))
                } else if mode == "scope-symlink" {
                    let moved = fixture.root.appendingPathComponent(
                        "held-real-scope", isDirectory: true)
                    try FileManager.default.moveItem(at: directory, to: moved)
                    try FileManager.default.createSymbolicLink(
                        at: directory, withDestinationURL: moved)
                } else if mode == "malformed-manifest" {
                    try Data("not a manifest".utf8).write(to: manifestURL)
                } else if mode == "manifest-symlink" {
                    let moved = fixture.root.appendingPathComponent("held-manifest.json")
                    try FileManager.default.moveItem(at: manifestURL, to: moved)
                    try FileManager.default.createSymbolicLink(
                        at: manifestURL, withDestinationURL: moved)
                }
                let protectedManifest = try Data(contentsOf: manifestURL)
                let allowed = await FoundationScopedAccountRemoval.nativeSessionIsUnrepresented(
                    root: fixture.storage.downloads, identifier: identifier)
                XCTAssertFalse(allowed, mode)
                XCTAssertEqual(try Data(contentsOf: manifestURL), protectedManifest)
                fixture.removeData()
            }
        }

        func testEmptySessionAbsenceMustBeRecheckedAfterNewReferenceAppears() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            defer { fixture.gate.release() }
            let scope = String(repeating: "a", count: 64)
            let identifier = "dev.novoluxor.velacanto.offline." + scope + "." + UUID().uuidString
            let before = await FoundationScopedAccountRemoval.nativeSessionIsUnrepresented(
                root: fixture.storage.downloads, identifier: identifier)
            XCTAssertTrue(before)
            let directory = fixture.storage.downloads.appendingPathComponent(
                scope, isDirectory: true)
            try FoundationDownloadStorage.prepare(directory)
            var manifest = FoundationDownloadManifest()
            manifest.nativePendingSessions = [identifier]
            try FoundationDownloadStorage.save(manifest, directory: directory)
            let after = await FoundationScopedAccountRemoval.nativeSessionIsUnrepresented(
                root: fixture.storage.downloads, identifier: identifier)
            XCTAssertFalse(after)
            fixture.removeData()
        }

        func testEmptySessionOutcomeRetainsNativeWorkDespiteCancellationAndFinality() {
            let evidence = FoundationNativeEmptySessionEvidence()
            evidence.recordInventory(count: 0)
            evidence.observeTaskAllocationOrChallenge()
            evidence.cancel()
            evidence.recordInvalidation(succeeded: true)
            evidence.acknowledgeFinality()
            XCTAssertEqual(evidence.outcome, .observedNativeWork)
            XCTAssertFalse(evidence.isQuiescentEmpty)
        }

        func testEmptySessionOutcomeSeparatesUnavailableFromProvedQuiescence() {
            let evidence = FoundationNativeEmptySessionEvidence()
            evidence.recordInventory(count: 0)
            XCTAssertEqual(evidence.outcome, .unavailable)
            evidence.recordInvalidation(succeeded: true)
            evidence.acknowledgeFinality()
            XCTAssertEqual(evidence.outcome, .quiescent)
            XCTAssertFalse(evidence.isSuccessful)
        }

        func testEmptySessionQuiescenceDoesNotManufactureEventDrain() {
            let evidence = FoundationNativeEmptySessionEvidence()
            evidence.recordInventory(count: 0)
            evidence.recordInvalidation(succeeded: true)
            XCTAssertFalse(evidence.isQuiescentEmpty)
            evidence.acknowledgeFinality()
            XCTAssertTrue(evidence.isQuiescentEmpty)
            XCTAssertFalse(
                evidence.isSuccessful, "Actual event drain remains a separate observation")
        }

        func testEmptySessionQuiescenceRejectsNativeWorkAndFailure() {
            for fault in ["nonempty", "task", "error", "cancelled", "no-inventory"] {
                let evidence = FoundationNativeEmptySessionEvidence()
                if fault != "no-inventory" {
                    evidence.recordInventory(count: fault == "nonempty" ? 1 : 0)
                }
                if fault == "task" { evidence.observeTaskAllocationOrChallenge() }
                if fault == "cancelled" { evidence.cancel() }
                evidence.recordInvalidation(succeeded: fault != "error")
                evidence.acknowledgeFinality()
                XCTAssertFalse(evidence.isQuiescentEmpty, fault)
            }
        }

        func testEmptySessionEvidenceRequiresActualDrainAndJoinedFinality() {
            let fresh = FoundationNativeEmptySessionEvidence()
            fresh.recordInventory(count: 0)
            fresh.recordInvalidation(succeeded: true)
            fresh.acknowledgeFinality()
            XCTAssertFalse(
                fresh.isSuccessful, "Fresh empty session finality is not an OS drain callback")
            let delivered = FoundationNativeEmptySessionEvidence()
            delivered.recordInventory(count: 0)
            delivered.recordDrainDelivery()
            delivered.recordInvalidation(succeeded: true)
            delivered.acknowledgeFinality()
            XCTAssertFalse(
                delivered.isSuccessful, "Earlier delegate delivery has not joined its model update")
            delivered.acknowledgeDrainDelivery()
            XCTAssertTrue(delivered.isSuccessful)
        }

        func testEmptySessionEvidenceRejectsDelegateDrainAfterFinalInvalidation() {
            let evidence = FoundationNativeEmptySessionEvidence()
            evidence.recordInventory(count: 0)
            evidence.recordInvalidation(succeeded: true)
            evidence.recordDrainDelivery()
            evidence.acknowledgeDrainDelivery()
            evidence.acknowledgeFinality()
            XCTAssertFalse(evidence.isSuccessful)
        }

        func testEmptySessionEvidenceRetainsEarlierExactEventDrain() {
            let evidence = FoundationNativeEmptySessionEvidence(priorDrainAcknowledged: true)
            evidence.recordInventory(count: 0)
            XCTAssertFalse(evidence.isSuccessful)
            evidence.recordInvalidation(succeeded: true)
            XCTAssertFalse(evidence.isSuccessful)
            evidence.acknowledgeFinality()
            XCTAssertTrue(evidence.isSuccessful)
        }

        func testEmptySessionEvidenceRefusesWeakOrConflictingObservations() {
            for fault in [
                "nonempty", "task-or-allocation", "challenge", "error", "cancelled", "no-inventory",
                "duplicate-inventory", "unacknowledged-drain", "unacknowledged-finality",
            ] {
                let evidence = FoundationNativeEmptySessionEvidence()
                if fault != "no-inventory" {
                    evidence.recordInventory(count: fault == "nonempty" ? 1 : 0)
                }
                if fault == "duplicate-inventory" { evidence.recordInventory(count: 0) }
                evidence.recordDrainDelivery()
                if fault != "unacknowledged-drain" { evidence.acknowledgeDrainDelivery() }
                evidence.recordInvalidation(succeeded: fault != "error")
                if fault != "unacknowledged-finality" { evidence.acknowledgeFinality() }
                if fault == "task-or-allocation" || fault == "challenge" {
                    evidence.observeTaskAllocationOrChallenge()
                }
                if fault == "cancelled" { evidence.cancel() }
                XCTAssertFalse(
                    evidence.isSuccessful, "Weak native empty-session evidence: \(fault)")
            }
        }

        func testEmptySessionEvidenceRejectsAcknowledgementWithoutDelivery() {
            let evidence = FoundationNativeEmptySessionEvidence()
            evidence.recordInventory(count: 0)
            evidence.acknowledgeDrainDelivery()
            evidence.acknowledgeFinality()
            evidence.recordDrainDelivery()
            evidence.recordInvalidation(succeeded: true)
            XCTAssertFalse(evidence.isSuccessful)
        }

        func testSignOutDuringCompletedNativeObservationReplaysAfterCleanupAndRetries() async throws
        {
            try await exerciseAllocatedFinalityRecovery(scenario: "represented-signout")
        }

        func testCompletedStoredNativeEventPreservesExactNativeLeaseAndMetadata() async throws {
            try await exerciseAllocatedFinalityRecovery(scenario: "represented-event")
        }

        func testCompletedStoredNativeEventRejectsNativeWorkWithoutMutation() async throws {
            try await exerciseAllocatedFinalityRecovery(scenario: "represented-native-work")
        }

        func testCompletedStoredNativeEventRejectsChangedReceiptWithoutMutation() async throws {
            try await exerciseAllocatedFinalityRecovery(scenario: "represented-changed-receipt")
        }

        func testEmptyEventCompletesWhileRemovedSessionOwnerStillRetained() async throws {
            try await exerciseAllocatedFinalityRecovery(scenario: "empty-event-after-consumption")
        }

        func testSignOutRecoversAllocatedFinalityAfterPlaybackLeaseDrains() async throws {
            try await exerciseAllocatedFinalityRecovery(scenario: "success")
        }

        func testCancelledSignOutAllocatedFinalityRecoveryPreservesData() async throws {
            try await exerciseAllocatedFinalityRecovery(scenario: "cancelled")
        }

        func testChangedMarkerDuringAllocatedFinalityRecoveryPreservesData() async throws {
            try await exerciseAllocatedFinalityRecovery(scenario: "changed-marker")
        }

        func testMismatchedAllocatedRecoveryReceiptNeverStartsRetirement() async throws {
            try await exerciseAllocatedFinalityRecovery(scenario: "mismatch")
        }

        func testMissingNativeFinalityRecoveryKeepsCleanupPending() async throws {
            try await exerciseAllocatedFinalityRecovery(scenario: "no-finality")
        }

        func testRecoveredSignOutRetriesAfterTombstone() async throws {
            try await exerciseAllocatedFinalityRecovery(
                scenario: "recovered-retry", checkpoint: .afterFirstTombstone)
        }

        func testRecoveredSignOutRetriesAfterManifest() async throws {
            try await exerciseAllocatedFinalityRecovery(
                scenario: "recovered-retry", checkpoint: .afterManifest)
        }

        func testRecoveredSignOutRetriesAfterReceiptConsumption() async throws {
            try await exerciseAllocatedFinalityRecovery(
                scenario: "recovered-retry", checkpoint: .afterFirstReceiptUnlink)
        }

        func testRecoveredSignOutRetriesAfterDirectoryRemoval() async throws {
            try await exerciseAllocatedFinalityRecovery(
                scenario: "recovered-retry", checkpoint: .afterDirectoryRemoval)
        }

        func testRecoveredSignOutConsumedProofRejectsChangedMarker() async throws {
            try await exerciseAllocatedFinalityRecovery(
                scenario: "changed-marker-after-consumption", checkpoint: .afterFirstReceiptUnlink)
        }

        func testRecoveredSignOutConsumedProofRejectsReplacementReceiptTask() async throws {
            try await exerciseAllocatedFinalityRecovery(
                scenario: "replacement-task-after-consumption", checkpoint: .afterFirstReceiptUnlink
            )
        }

        func testScopedRecoveredAllocationRejectsReplacementTaskBeforeRemoval() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            defer { fixture.gate.release() }
            let scope = String(repeating: "a", count: 64)
            let directory = fixture.storage.downloads.appendingPathComponent(
                scope, isDirectory: true)
            try FoundationDownloadStorage.prepare(directory)
            let identifier = "dev.novoluxor.velacanto.offline." + scope + "." + UUID().uuidString
            let packageURL = fixture.root.appendingPathComponent(
                "synthetic-worker.movpkg", isDirectory: true)
            try FileManager.default.createDirectory(
                at: packageURL, withIntermediateDirectories: true)
            let package = FoundationNativeDownloadPackage(
                nativeURL: packageURL, bookmark: Data("synthetic-worker-bookmark".utf8),
                sessionIdentifier: identifier,
                namespaceBookmark: Data("synthetic-worker-namespace".utf8))
            let track = "synthetic-worker-track"
            let operation = UUID()
            let store = FoundationNativeAllocationStore(
                directory: directory, sessionIdentifier: identifier)
            func receipt(task: Int) -> FoundationNativeAllocationStore.Receipt {
                var value = FoundationNativeAllocationStore.Receipt(
                    scope: scope, sessionIdentifier: identifier, taskIdentifier: task)
                value.trackID = track
                value.nativeURL = packageURL
                value.phase = .allocated
                value.namespaceBookmark = package.namespaceBookmark
                value.package = package
                value.retired = true
                value.creationVersion = 1
                value.completionAttempted = true
                return value
            }
            try JSONEncoder().encode(receipt(task: 1)).write(to: store.receiptURL)
            try store.recordColdFinality(
                operation: operation, expectedTrackID: track, expectedPackage: package)
            let expected = try XCTUnwrap(store.load().coldSignOutProof)
            var replacement = receipt(task: 2)
            replacement.coldSignOutProof = expected
            let replacementBytes = try JSONEncoder().encode(replacement)
            try replacementBytes.write(to: store.receiptURL)
            var manifest = FoundationDownloadManifest()
            manifest.files[track] = .init(
                name: "synthetic-worker.movpkg", bytes: 1, digest: "", nativePackage: package)
            try FoundationDownloadStorage.save(manifest, directory: directory)
            let manifestBytes = try Data(
                contentsOf: directory.appendingPathComponent("manifest.json"))
            let outcome = await FoundationScopedAccountRemoval.removeNoFactoryAsync(
                root: fixture.storage.downloads, scope: scope, requiredSessions: [identifier],
                authorizedAllocatedSessions: [
                    identifier: .init(
                        trackID: track, package: package, expectedFinalityProof: expected)
                ],
                retireAllocated: { _ in throw FoundationDownloadError.cleanup })
            XCTAssertFalse(
                outcome.removed, "A new task cannot inherit the captured task's recovery proof")
            if outcome.removed { return }
            XCTAssertTrue(outcome.consumedSessions.isEmpty)
            XCTAssertEqual(try Data(contentsOf: store.receiptURL), replacementBytes)
            XCTAssertEqual(
                try Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                manifestBytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
            fixture.removeData()
        }

        // All native effects below use synthetic paths and an explicit fake
        // retirement owner. Isolated native inventory guards remain unchanged.
        private func exerciseAllocatedFinalityRecovery(
            scenario: String, checkpoint: FoundationScopedAccountRemoval.NoFactoryCheckpoint? = nil
        ) async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "synthetic revocation"))
            let leaseWait = XCTestExpectation(
                description: "sign-out waiting for local playback lease")
            let keychain = IntentKeychainFixture()
            keychain.credentialData = nil
            let operations = keychain.operations()
            let session = fixture.session(user: "00000000000000000000000000000001")
            let transactionRoot = fixture.root.appendingPathComponent(
                "transaction", isDirectory: true)
            let transactions = FoundationAccountTransactions(
                inspect: {
                    try FoundationAccountCredentialTransaction.inspect(
                        root: transactionRoot, operations: operations)
                },
                prepareSignOut: { value, expected, preparation in
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        value, expecting: expected, preparation: preparation,
                        root: transactionRoot, operations: operations)
                },
                finishCompletedSignOut: { marker in
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        marker, root: transactionRoot, operations: operations)
                },
                recordSignOut: { value, marker, expected in
                    try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                        value, intent: marker, expecting: expected,
                        root: transactionRoot, operations: operations)
                })
            let nonemptyRetirements = IsolatedDiagnosticRecorder()
            let finalityEntered = XCTestExpectation(
                description: "owned native finality recovery entered")
            let finalityGate = LifecycleGate(entered: finalityEntered)
            let removalEntered = XCTestExpectation(
                description: "scoped worker removed account directory")
            let removalGate = LifecycleGate(entered: removalEntered)
            let representedEntered = XCTestExpectation(description: "represented observer entered")
            let representedGate = LifecycleGate(entered: representedEntered)
            defer { representedGate.release() }
            var emptyObservations = 0
            var recoveryCalls = 0
            var completions = 0
            weak var callbackModel: FoundationAppModel?
            let model = fixture.makeModel(
                leaseWaitStarted: { leaseWait.fulfill() },
                emptyNativeSession: { _, current, _ in
                    guard
                        scenario == "empty-event-after-consumption"
                            || scenario.hasPrefix("represented-"),
                        await current()
                    else { return .unavailable }
                    emptyObservations += 1
                    if scenario.hasPrefix("represented-") { await representedGate.hold() }
                    let evidence = FoundationNativeEmptySessionEvidence()
                    evidence.recordInventory(count: scenario == "represented-native-work" ? 1 : 0)
                    evidence.recordInvalidation(succeeded: true)
                    evidence.acknowledgeFinality()
                    return evidence.outcome
                },
                nativeRetirement: { identifiers, _ in
                    if !identifiers.isEmpty { nonemptyRetirements.append("requested") }
                    return []
                }, useModelBackgroundRouting: true,
                inspectSignOutIntent: {
                    do {
                        return try FoundationSignOutIntentStore.load(operations: operations) == nil
                            ? .absent : .pending
                    } catch { return .unavailable }
                }, accountTransactions: transactions, credentialOperations: operations,
                coldNativeRetirement: { store, operation, candidate, current in
                    recoveryCalls += 1
                    await finalityGate.hold()
                    guard scenario != "no-finality", await current() else { return false }
                    do {
                        // These fake callbacks stand in for successful native final
                        // invalidation and joined delivery; receipt completion alone
                        // is not accepted as proof by the production owner.
                        try store.recordColdFinality(
                            operation: operation, expectedTrackID: candidate.trackID,
                            expectedPackage: candidate.package)
                        try store.retire(
                            resolve: { package in
                                guard package.sessionIdentifier == candidate.identifier,
                                    package.nativeURL == candidate.package.nativeURL,
                                    package.bookmark == candidate.package.bookmark,
                                    package.namespaceBookmark == candidate.package.namespaceBookmark
                                else {
                                    return .unverifiable
                                }
                                return .available(candidate.package.nativeURL)
                            },
                            remove: { value in
                                guard value == candidate.package.nativeURL else {
                                    throw FoundationDownloadError.cleanup
                                }
                                try FileManager.default.removeItem(at: value)
                            })
                        if scenario == "success" || checkpoint != nil, let model = callbackModel {
                            model.receiveBackgroundDownloadEvents(candidate.identifier) {
                                completions += 1
                            }
                            model.finishBackgroundDownloadEvents(candidate.identifier)
                        }
                        return true
                    } catch { return false }
                })
            callbackModel = model
            defer {
                finalityGate.release()
                removalGate.release()
                fixture.gate.release()
            }
            do {
                let startup = Task { _ = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForTask(startup, label: "restored package signed-out startup")
                let accept = try await model.prepareSignIn { session }
                let scope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(directory)
                let track = FoundationItem(
                    id: "00000000000000000000000000000003", title: "Synthetic local lease",
                    subtitle: "", kind: .track, duration: nil)
                let file = directory.appendingPathComponent("synthetic.audio")
                let bytes = Data("synthetic-ordinary-local-bytes".utf8)
                try bytes.write(to: file)
                let packageURL = fixture.root.appendingPathComponent(
                    "synthetic-restored.movpkg", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: packageURL, withIntermediateDirectories: true)
                let packageSentinel = packageURL.appendingPathComponent("synthetic-content")
                let packageBytes = Data("synthetic-native-package-content".utf8)
                try packageBytes.write(to: packageSentinel)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                    + "." + UUID().uuidString
                let nativeTrack = "00000000000000000000000000000004"
                let package = FoundationNativeDownloadPackage(
                    nativeURL: packageURL, bookmark: Data("synthetic-bookmark".utf8),
                    sessionIdentifier: identifier,
                    namespaceBookmark: Data("synthetic-namespace".utf8))
                let store = FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: identifier)
                var receipt = FoundationNativeAllocationStore.Receipt(
                    scope: directory.lastPathComponent, sessionIdentifier: identifier,
                    taskIdentifier: 1)
                receipt.trackID = nativeTrack
                receipt.nativeURL = packageURL
                receipt.phase = .allocated
                receipt.creationVersion = 1
                receipt.namespaceBookmark = package.namespaceBookmark
                receipt.package = package
                receipt.completionAttempted = true
                let receiptBytes = try JSONEncoder().encode(receipt)
                var manifest = FoundationDownloadManifest()
                let stored = FoundationStoredDownloadItem(track)
                manifest.owners = [
                    .init(
                        id: "track:" + track.id, item: stored, tracks: [stored], paused: true,
                        expanded: false)
                ]
                manifest.files[track.id] = .init(
                    name: file.lastPathComponent, bytes: Int64(bytes.count),
                    digest: try FoundationDownloadStorage.digest(file))
                // This is an already-published completed file, not pending acquisition.
                manifest.nativePendingSessions = []
                try FoundationDownloadStorage.save(manifest, directory: directory)
                let otherKey = FoundationPinStorage.key(for: String(repeating: "b", count: 64))
                let otherBytes = Data("unrelated-scope-sentinel".utf8)
                fixture.defaults.set(otherBytes, forKey: otherKey)
                try await accept()
                let owner = try XCTUnwrap(model.downloads)
                owner.isolatedNoFactoryCheckpoint = checkpoint
                if scenario == "empty-event-after-consumption" {
                    owner.isolatedAfterAccountRemoval = { await removalGate.hold() }
                }
                defer { owner.isolatedAfterAccountRemoval = nil }
                let player = try XCTUnwrap(model.player)
                let inventory = XCTestExpectation(description: "restored inventory finished")
                let inventoryObserver = owner.$isLoading.filter { !$0 }.first().sink { _ in
                    inventory.fulfill()
                }
                defer { inventoryObserver.cancel() }
                try await waitForEvents([inventory], label: "restored allocated inventory")
                // Match the known-session/allocated-manifest state of a restored owner
                // without relaxing FoundationAppModel's isolated native inventory fence.
                // This does not execute the restored model constructor path.
                try receiptBytes.write(to: store.receiptURL)
                try owner.isolatedSeedAllocatedFile(
                    trackID: nativeTrack,
                    file: .init(
                        name: "synthetic-restored.movpkg", bytes: Int64(packageBytes.count),
                        digest: "",
                        nativePackage: package))
                var protectedReceipt = receiptBytes
                if scenario == "mismatch" {
                    receipt.package = FoundationNativeDownloadPackage(
                        nativeURL: packageURL, bookmark: Data("changed-bookmark".utf8),
                        sessionIdentifier: identifier, namespaceBookmark: package.namespaceBookmark)
                    protectedReceipt = try JSONEncoder().encode(receipt)
                    try protectedReceipt.write(to: store.receiptURL)
                }
                if scenario.hasPrefix("represented-") {
                    let credentialBefore = keychain.credentialData
                    let manifestBefore = try Data(
                        contentsOf: directory.appendingPathComponent("manifest.json"))
                    // The same production track lease core is held, without resolving
                    // synthetic bookmarks or publishing a ready native file.
                    let nativeLease = try owner.isolatedAcquireNativePlaybackLease(
                        trackID: nativeTrack)
                    fixture.resources.append(nativeLease)
                    let eventCompleted = XCTestExpectation(
                        description: "represented event completion")
                    model.receiveBackgroundDownloadEvents(identifier) {
                        completions += 1
                        if scenario == "represented-signout" { eventCompleted.fulfill() }
                    }
                    try await waitForEvents(
                        [representedEntered], label: "stored completed native observer")
                    XCTAssertFalse(owner.ownsNativeSessionInCurrentProcess(identifier))
                    XCTAssertEqual(recoveryCalls, 0)
                    if scenario == "represented-changed-receipt" {
                        var replacement = FoundationNativeAllocationStore.Receipt(
                            scope: receipt.scope, sessionIdentifier: identifier, taskIdentifier: 2)
                        replacement.trackID = receipt.trackID
                        replacement.nativeURL = receipt.nativeURL
                        replacement.phase = receipt.phase
                        replacement.namespaceBookmark = receipt.namespaceBookmark
                        replacement.package = receipt.package
                        replacement.creationVersion = receipt.creationVersion
                        replacement.completionAttempted = receipt.completionAttempted
                        protectedReceipt = try JSONEncoder().encode(replacement)
                        try protectedReceipt.write(to: store.receiptURL)
                    }
                    if scenario == "represented-signout" {
                        let cleanupEnded = XCTestExpectation(
                            description: "first cleanup safely refused")
                        let cleanupObserver = model.$isCleaningDownloads.dropFirst().filter { !$0 }
                            .first().sink { _ in cleanupEnded.fulfill() }
                        defer { cleanupObserver.cancel() }
                        model.signOut()
                        fixture.captureStop(player)
                        try await waitForEvents(
                            [leaseWait], label: "signout joins exact native lease")
                        try await fixture.releaseResources(using: self)
                        try await waitForEvents(
                            [cleanupEnded], label: "cleanup releases in-progress fence")
                        XCTAssertNotNil(model.signOutCleanupError)
                        XCTAssertEqual(recoveryCalls, 0)
                        representedGate.release()
                        try await waitForEvents(
                            [eventCompleted], label: "represented event replay after signout")
                        XCTAssertEqual(emptyObservations, 2)
                        XCTAssertEqual(completions, 1)
                        XCTAssertEqual(keychain.credentialData, credentialBefore)
                        XCTAssertEqual(try Data(contentsOf: packageSentinel), packageBytes)
                        let retryEnded = XCTestExpectation(
                            description: "explicit signout retry finished")
                        let retryObserver = model.$isCleaningDownloads.dropFirst().filter { !$0 }
                            .first().sink { _ in retryEnded.fulfill() }
                        defer { retryObserver.cancel() }
                        model.retryAccountInspection()
                        try await waitForEvents(
                            [finalityEntered], label: "retry independently retires native package")
                        finalityGate.release()
                        try await waitForEvents([retryEnded], label: "retry cleanup ended")
                        XCTAssertEqual(recoveryCalls, 1)
                        XCTAssertNil(model.signOutCleanupError)
                        let transactionEnded = XCTestExpectation(
                            description: "retry account transaction committed")
                        let transactionObserver = model.$accountInspectionIssue.filter { $0 == nil }
                            .first().sink { _ in transactionEnded.fulfill() }
                        defer { transactionObserver.cancel() }
                        try await waitForEvents(
                            [transactionEnded], label: "retry transaction finished")
                        XCTAssertNil(keychain.credentialData)
                        XCTAssertNil(keychain.payload)
                        fixture.gate.release()
                        try await fixture.drain(using: self)
                        fixture.removeData()
                        return
                    }
                    representedGate.release()
                    let routing = try XCTUnwrap(model.isolatedBackgroundDownloadTask)
                    try await waitForTask(routing, label: "represented native event settled")
                    XCTAssertEqual(completions, scenario == "represented-event" ? 1 : 0)
                    XCTAssertEqual(emptyObservations, 1)
                    XCTAssertEqual(recoveryCalls, 0)
                    XCTAssertTrue(model.downloads === owner)
                    XCTAssertTrue(model.player === player)
                    XCTAssertEqual(keychain.credentialData, credentialBefore)
                    XCTAssertNil(try FoundationSignOutIntentStore.load(operations: operations))
                    XCTAssertEqual(try Data(contentsOf: store.receiptURL), protectedReceipt)
                    XCTAssertEqual(
                        try Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                        manifestBefore)
                    XCTAssertEqual(try Data(contentsOf: packageSentinel), packageBytes)
                    XCTAssertFalse(owner.backgroundSessionHasDrained(identifier))
                    XCTAssertFalse(owner.ownsNativeSessionInCurrentProcess(identifier))
                    try await fixture.releaseResources(using: self)
                    fixture.gate.release()
                    try await fixture.drain(using: self)
                    fixture.removeData()
                    return
                }
                // The isolated host cannot authorize this fake native bookmark. Its
                // receipt/file is retained; an ordinary downloaded lease models the
                // concurrently playing local resource without AV or native OS calls.
                try await fixture.acquireResource(from: owner, item: track, using: self)
                let originalCredential = try XCTUnwrap(keychain.credentialData)
                let ended = XCTestExpectation(
                    description: "restored sign-out cleanup attempt ended")
                let observer = model.$isCleaningDownloads.dropFirst().filter { !$0 }.first().sink {
                    _ in ended.fulfill()
                }
                defer { observer.cancel() }
                model.signOut()
                fixture.captureStop(player)
                try await waitForEvents(
                    [leaseWait], label: "held local resource during restored sign-out")
                XCTAssertEqual(keychain.credentialData, originalCredential)
                XCTAssertNotNil(try FoundationSignOutIntentStore.load(operations: operations))
                XCTAssertEqual(try Data(contentsOf: file), bytes)
                XCTAssertEqual(try Data(contentsOf: packageSentinel), packageBytes)
                XCTAssertEqual(recoveryCalls, 0)
                try await fixture.releaseResources(using: self)
                if scenario != "mismatch" {
                    try await waitForEvents(
                        [finalityEntered], label: "allocated finality after local lease drain")
                    XCTAssertEqual(keychain.credentialData, originalCredential)
                    XCTAssertEqual(try Data(contentsOf: packageSentinel), packageBytes)
                    XCTAssertEqual(try Data(contentsOf: store.receiptURL), protectedReceipt)
                    if scenario == "cancelled" {
                        let cleanup = try XCTUnwrap(model.isolatedSignOutCleanupTask)
                        cleanup.cancel()
                    } else if scenario == "changed-marker" {
                        let original = try XCTUnwrap(
                            FoundationSignOutIntentStore.load(operations: operations))
                        let replaced = FoundationSignOutIntentStore.Intent(
                            version: original.version, operation: UUID(), scope: original.scope,
                            accessGroup: original.accessGroup,
                            credentialGeneration: original.credentialGeneration)
                        keychain.generic = Data(replaced.operation.uuidString.utf8)
                        keychain.payload = try JSONEncoder().encode(replaced)
                    }
                    finalityGate.release()
                }
                if scenario == "empty-event-after-consumption" {
                    try await waitForEvents(
                        [removalEntered],
                        label: "retained owner after receipt/directory consumption")
                    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
                    XCTAssertNotNil(keychain.credentialData)
                    XCTAssertNotNil(keychain.payload)
                    XCTAssertTrue(model.isCleaningDownloads)
                    let lateAcknowledged = XCTestExpectation(
                        description: "removed-owner late event acknowledged")
                    model.receiveBackgroundDownloadEvents(identifier) {
                        completions += 1
                        lateAcknowledged.fulfill()
                    }
                    try await waitForEvents(
                        [lateAcknowledged],
                        label: "empty event without waiting for its own cleanup task")
                    XCTAssertEqual(emptyObservations, 1)
                    XCTAssertEqual(completions, 1)
                    XCTAssertNotNil(keychain.credentialData)
                    XCTAssertNotNil(keychain.payload)
                    XCTAssertTrue(model.isCleaningDownloads)
                    removalGate.release()
                }
                try await waitForEvents([ended], label: "owned allocated finality cleanup attempt")
                if checkpoint != nil {
                    XCTAssertNotNil(model.signOutCleanupError)
                    XCTAssertEqual(keychain.credentialData, originalCredential)
                    XCTAssertNotNil(keychain.payload)
                    XCTAssertEqual(recoveryCalls, 1)
                    XCTAssertEqual(completions, 1)
                    XCTAssertEqual(fixture.defaults.data(forKey: otherKey), otherBytes)
                    owner.isolatedNoFactoryCheckpoint = nil
                    if scenario == "changed-marker-after-consumption" {
                        let original = try XCTUnwrap(
                            FoundationSignOutIntentStore.load(operations: operations))
                        let replacement = FoundationSignOutIntentStore.Intent(
                            version: original.version, operation: UUID(), scope: original.scope,
                            accessGroup: original.accessGroup,
                            credentialGeneration: original.credentialGeneration)
                        keychain.generic = Data(replacement.operation.uuidString.utf8)
                        keychain.payload = try JSONEncoder().encode(replacement)
                    } else if scenario == "replacement-task-after-consumption" {
                        // Same session/track/package with a NEW task and no matching
                        // finality proof must not inherit the consumed task's authority.
                        var replacementReceipt = FoundationNativeAllocationStore.Receipt(
                            scope: receipt.scope, sessionIdentifier: receipt.sessionIdentifier,
                            taskIdentifier: receipt.taskIdentifier + 1)
                        replacementReceipt.trackID = receipt.trackID
                        replacementReceipt.nativeURL = receipt.nativeURL
                        replacementReceipt.phase = receipt.phase
                        replacementReceipt.namespaceBookmark = receipt.namespaceBookmark
                        replacementReceipt.package = receipt.package
                        replacementReceipt.creationVersion = receipt.creationVersion
                        replacementReceipt.completionAttempted = receipt.completionAttempted
                        protectedReceipt = try JSONEncoder().encode(replacementReceipt)
                        try protectedReceipt.write(to: store.receiptURL)
                    }
                    let retainedMarker = keychain.payload
                    let retryEnded = XCTestExpectation(
                        description: "recovered checkpoint retry finished")
                    let retryObserver = model.$isCleaningDownloads.dropFirst().filter { !$0 }
                        .first().sink { _ in
                            retryEnded.fulfill()
                        }
                    defer { retryObserver.cancel() }
                    model.retryAccountInspection()
                    try await waitForEvents(
                        [retryEnded], label: "recovered allocated partial cleanup retry")
                    XCTAssertEqual(recoveryCalls, 1)
                    if scenario == "changed-marker-after-consumption"
                        || scenario == "replacement-task-after-consumption"
                    {
                        XCTAssertNotNil(model.signOutCleanupError)
                        XCTAssertEqual(keychain.credentialData, originalCredential)
                        XCTAssertEqual(keychain.payload, retainedMarker)
                        XCTAssertEqual(fixture.defaults.data(forKey: otherKey), otherBytes)
                        if scenario == "replacement-task-after-consumption" {
                            XCTAssertEqual(try Data(contentsOf: store.receiptURL), protectedReceipt)
                        }
                        fixture.gate.release()
                        try await fixture.drain(using: self)
                        fixture.removeData()
                        return
                    }
                    XCTAssertNil(
                        model.signOutCleanupError,
                        "Recovered allocated proof must remain usable after owned partial receipt/manifest cleanup"
                    )
                    if model.signOutCleanupError != nil {
                        fixture.gate.release()
                        try await fixture.drain(using: self)
                        // Preserve the bounded red characterization's partial data.
                        return
                    }
                }
                if scenario == "success" || checkpoint != nil
                    || scenario == "empty-event-after-consumption"
                {
                    let finished = XCTestExpectation(
                        description: "recovered allocated sign-out finalized")
                    let finalObserver = model.$accountInspectionIssue.filter { $0 == nil }.first()
                        .sink { _ in finished.fulfill() }
                    defer { finalObserver.cancel() }
                    try await waitForEvents(
                        [finished], label: "recovered sign-out marker finalization")
                    XCTAssertNil(model.signOutCleanupError)
                    XCTAssertNil(keychain.credentialData)
                    XCTAssertNil(keychain.payload)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
                    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
                    XCTAssertEqual(recoveryCalls, 1)
                    XCTAssertEqual(completions, 1)
                } else {
                    XCTAssertEqual(keychain.credentialData, originalCredential)
                    XCTAssertNotNil(try FoundationSignOutIntentStore.load(operations: operations))
                    XCTAssertEqual(try Data(contentsOf: store.receiptURL), protectedReceipt)
                    XCTAssertEqual(try Data(contentsOf: packageSentinel), packageBytes)
                    XCTAssertEqual(try Data(contentsOf: file), bytes)
                    XCTAssertNotNil(model.signOutCleanupError)
                    XCTAssertEqual(completions, 0)
                    XCTAssertEqual(recoveryCalls, scenario == "mismatch" ? 0 : 1)
                }
                XCTAssertEqual(fixture.defaults.data(forKey: otherKey), otherBytes)
                fixture.gate.release()
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                finalityGate.release()
                removalGate.release()
                fixture.gate.release()
                do { try await fixture.releaseResources(using: self) } catch {
                    XCTFail("Could not release restored sign-out fixture resource")
                }
                do { try await fixture.drain(using: self) } catch {
                    XCTFail("Could not drain restored sign-out fixture; data retained")
                }
                throw error
            }
        }

        // Strict red regression against post221 formatted313 behavior. This reconstructs
        // durable state using actual account transactions and fake Keychain only.
        // It is not a process kill or UIKit callback observation. The future
        // positive native factory must be injected explicitly after API review.
        func testPostRemovalReconstructedModelCompletesAlreadyDrainedEmptyNativeEvent() async throws
        {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused synthetic revocation"))
            let keychain = IntentKeychainFixture()
            let session = fixture.session(user: "00000000000000000000000000000001")
            keychain.credentialData = try JSONEncoder().encode(session)
            let operations = keychain.operations()
            let transactionRoot = fixture.root.appendingPathComponent(
                "transaction", isDirectory: true)
            let transactions = FoundationAccountTransactions(
                inspect: {
                    try FoundationAccountCredentialTransaction.inspect(
                        root: transactionRoot, operations: operations)
                },
                prepareSignOut: { value, snapshot, preparation in
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        value, expecting: snapshot, preparation: preparation, root: transactionRoot,
                        operations: operations)
                },
                finishCompletedSignOut: { marker in
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        marker, root: transactionRoot, operations: operations)
                },
                recordSignOut: { value, marker, snapshot in
                    try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                        value, intent: marker, expecting: snapshot, root: transactionRoot,
                        operations: operations)
                })
            let scope = FoundationMusicLibraryStore.digest(
                "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
            let directory = FoundationDownloadStorage.directory(
                scope: scope, root: fixture.storage.downloads)
            let identifier =
                "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                + "." + UUID().uuidString
            let otherKey = FoundationPinStorage.key(for: String(repeating: "b", count: 64))
            let sentinel = Data("unrelated synthetic scope".utf8)
            fixture.defaults.set(sentinel, forKey: otherKey)
            defer { fixture.gate.release() }
            do {
                // Advance the actual fake-Keychain transaction to the exact durable
                // boundary used by live and cold finalization, without an old model.
                let initial = try FoundationAccountCredentialTransaction.inspect(
                    root: transactionRoot, operations: operations)
                let marker = try FoundationAccountCredentialTransaction.prepareSignOut(
                    session, expecting: initial, root: transactionRoot, operations: operations)
                let prepared = try FoundationAccountCredentialTransaction.inspect(
                    root: transactionRoot, operations: operations)
                let completed = try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                    session, intent: marker, expecting: prepared,
                    root: transactionRoot, operations: operations)
                XCTAssertEqual(completed.cleanupComplete, true)
                XCTAssertNil(keychain.credentialData)
                try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                    completed, root: transactionRoot, operations: operations)
                XCTAssertNil(try FoundationSignOutIntentStore.load(operations: operations))
                guard keychain.credentialData == nil, keychain.payload == nil else {
                    throw CancellationError()
                }

                let nativeRetirements = IsolatedDiagnosticRecorder()
                // Do not inject backgroundReconcile: it would bypass the missing
                // account/scope branch that this characterization must exercise.
                let model = fixture.makeModel(
                    emptyNativeSession: { _, current, _ in
                        guard await current() else { return .unavailable }
                        let evidence = FoundationNativeEmptySessionEvidence()
                        evidence.recordInventory(count: 0)
                        evidence.recordInvalidation(succeeded: true)
                        evidence.acknowledgeFinality()
                        return evidence.outcome
                    },
                    nativeRetirement: { _, _ in
                        nativeRetirements.append("retire")
                        return []
                    },
                    useModelBackgroundRouting: true,
                    inspectSignOutIntent: {
                        do {
                            return try FoundationSignOutIntentStore.load(operations: operations)
                                == nil
                                ? .absent : .pending
                        } catch { return .unavailable }
                    }, accountTransactions: transactions, credentialOperations: operations)
                let settled = XCTestExpectation(description: "reconstructed route settled")
                model.backgroundRoutingSettled = { value in
                    if value == identifier { settled.fulfill() }
                }
                defer { model.backgroundRoutingSettled = nil }
                var completions = 0
                model.receiveBackgroundDownloadEvents(identifier) { completions += 1 }
                model.finishBackgroundDownloadEvents(identifier)
                try await waitForEvents([settled], label: "reconstructed old-scope event routing")
                XCTAssertNil(model.library)
                XCTAssertNil(model.downloads)
                model.backgroundRoutingSettled = nil
                XCTAssertEqual(nativeRetirements.snapshot(), [])
                XCTAssertEqual(
                    completions, 1,
                    "An already-drained empty old event must not permanently fence authentication after sign-out"
                )
                XCTAssertNil(keychain.credentialData)
                XCTAssertNil(keychain.payload)
                XCTAssertEqual(fixture.defaults.data(forKey: otherKey), sentinel)
                try await fixture.drain(using: self)
                // On the bounded red run, retain the pending event/fixture without
                // fabricating a teardown callback. A positive implementation will
                // require explicit native evidence injection before this can pass.
                if completions == 1 { fixture.removeData() }
            } catch {
                fixture.gate.release()
                do { try await fixture.drain(using: self) } catch {
                    XCTFail("Could not drain review characterization; data retained")
                }
                throw error
            }
        }

        func testAccountAlertDismissalDoesNotClearRepublishedMessages() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            let model = fixture.makeModel()
            defer { fixture.gate.release() }

            model.credentialError = "Synthetic account error"
            model.signOutNotice = "Synthetic sign-out notice"
            model.dismissAccountAlertAfterUpdate()
            model.credentialError = "Synthetic account error"
            model.signOutNotice = "Synthetic sign-out notice"
            let sameTextSettled = expectation(description: "same-text dismissal settled")
            DispatchQueue.main.async { sameTextSettled.fulfill() }
            try await waitForEvents([sameTextSettled], label: "same-text alert dismissal")
            XCTAssertEqual(model.credentialError, "Synthetic account error")
            XCTAssertEqual(model.signOutNotice, "Synthetic sign-out notice")
            guard model.credentialError == "Synthetic account error",
                model.signOutNotice == "Synthetic sign-out notice"
            else { throw CancellationError() }

            model.dismissAccountAlertAfterUpdate()
            model.credentialError = "Different account error"
            model.signOutNotice = "Different sign-out notice"
            let changedTextSettled = expectation(description: "changed-text dismissal settled")
            DispatchQueue.main.async { changedTextSettled.fulfill() }
            try await waitForEvents([changedTextSettled], label: "changed-text alert dismissal")
            XCTAssertEqual(model.credentialError, "Different account error")
            XCTAssertEqual(model.signOutNotice, "Different sign-out notice")
            guard model.credentialError == "Different account error",
                model.signOutNotice == "Different sign-out notice"
            else { throw CancellationError() }

            model.dismissAccountAlertAfterUpdate()
            let unchangedSettled = expectation(description: "unchanged dismissal settled")
            DispatchQueue.main.async { unchangedSettled.fulfill() }
            try await waitForEvents([unchangedSettled], label: "unchanged alert dismissal")
            XCTAssertNil(model.credentialError)
            XCTAssertNil(model.signOutNotice)
            guard model.credentialError == nil, model.signOutNotice == nil else {
                throw CancellationError()
            }
            fixture.removeData()
        }

        func testHostUsesIsolatedIdentityAndHasNoNativeEntryPoints() {
            XCTAssertEqual(
                Bundle.main.bundleIdentifier, "com.chameleonenterprise.velacanto.isolationtesting")
            XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSUserActivityTypes"))
            XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes"))
            XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest"))
        }

        func testPendingOrUnreadableSignOutBlocksStartupHeadlessAndAuthentication() async throws {
            for status in [FoundationSignOutInspection.pending, .unavailable] {
                let entered = expectation(description: "inspection entered")
                let gate = LifecycleGate(entered: entered)
                let joined = expectation(description: "startup joined inspection")
                let fixture = try LifecycleFixture(
                    entered: XCTestExpectation(description: "unused revocation"))
                var cachePreparations = 0
                var headlessRoutes = 0
                var systemCompletions = 0
                var authenticationStarted = false
                var inspections = 0
                let model = fixture.makeModel(
                    backgroundReconcile: { _ in
                        headlessRoutes += 1
                        return true
                    },
                    useModelBackgroundRouting: true,
                    inspectSignOutIntent: {
                        inspections += 1
                        if inspections == 1 { await gate.hold() }
                        return status
                    },
                    prepareIsolatedCaches: {
                        cachePreparations += 1
                        return true
                    },
                    inspectionJoined: { joined.fulfill() })
                let sentinel = fixture.root.appendingPathComponent("other-account-sentinel")
                try FileManager.default.createDirectory(
                    at: fixture.root, withIntermediateDirectories: true)
                try Data("keep".utf8).write(to: sentinel)
                defer {
                    gate.release()
                    fixture.gate.release()
                }
                model.receiveBackgroundDownloadEvents("synthetic-session") {
                    systemCompletions += 1
                }
                try await waitForEvents([entered], label: "headless intent inspection")
                let startup = Task { _ = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForEvents([joined], label: "shared intent inspection")
                gate.release()
                try await waitForTask(startup, label: "blocked startup")
                var prepared: FoundationSignInView.Acceptance?
                let attempt = Task {
                    prepared = try? await model.prepareSignIn {
                        authenticationStarted = true
                        return fixture.session(user: "synthetic")
                    }
                }
                fixture.tasks.append(attempt)
                try await waitForTask(attempt, label: "blocked authentication")
                try await fixture.drain(using: self)
                XCTAssertNil(prepared)
                XCTAssertFalse(authenticationStarted)
                XCTAssertEqual(cachePreparations, 0)
                XCTAssertEqual(headlessRoutes, 0)
                XCTAssertEqual(systemCompletions, 0)
                XCTAssertGreaterThanOrEqual(inspections, 1)
                XCTAssertNil(model.library)
                XCTAssertNil(model.player)
                XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
                switch status {
                case .pending:
                    XCTAssertTrue(model.accountInspectionMessage?.contains("didn’t finish") == true)
                case .unavailable:
                    XCTAssertTrue(
                        model.accountInspectionMessage?.contains("could not be checked") == true)
                case .absent, .inUse: XCTFail("Unexpected test state")
                }
                fixture.removeData()
            }
        }

        func testCancellingStartupWaiterDoesNotCancelSharedIntentInspection() async throws {
            let entered = expectation(description: "inspection entered")
            let joined = expectation(description: "startup joined inspection")
            let gate = LifecycleGate(entered: entered)
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            var inspections = 0
            var routed = 0
            let model = fixture.makeModel(
                backgroundReconcile: { _ in
                    routed += 1
                    return false
                },
                useModelBackgroundRouting: true,
                inspectSignOutIntent: {
                    inspections += 1
                    await gate.hold()
                    return .absent
                },
                inspectionJoined: { joined.fulfill() })
            defer {
                gate.release()
                fixture.gate.release()
            }
            model.receiveBackgroundDownloadEvents("synthetic-session") {}
            try await waitForEvents([entered], label: "headless intent inspection")
            var readiness: FoundationAppModel.Readiness?
            let startup = Task { readiness = await model.ensureReady() }
            fixture.tasks.append(startup)
            try await waitForEvents([joined], label: "startup inspection join")
            startup.cancel()
            gate.release()
            try await waitForTask(startup, label: "cancelled startup waiter")
            try await fixture.drain(using: self)
            XCTAssertEqual(readiness, .cancelled)
            XCTAssertEqual(inspections, 1)
            XCTAssertEqual(routed, 1)
            let nextReadiness = await model.ensureReady()
            XCTAssertEqual(nextReadiness, .signedOut)
            fixture.removeData()
        }

        func testAccountInspectionRetryRechecksBeforePreparingCaches() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            var pending = true
            var inspections = 0
            var preparations = 0
            let model = fixture.makeModel(
                inspectSignOutIntent: {
                    inspections += 1
                    return pending ? .pending : .absent
                },
                prepareIsolatedCaches: {
                    preparations += 1
                    return true
                })
            var first: FoundationAppModel.Readiness?
            let initial = Task { first = await model.ensureReady() }
            fixture.tasks.append(initial)
            try await waitForTask(initial, label: "pending startup")
            XCTAssertEqual(first, .unavailable)
            XCTAssertEqual(model.accountInspectionIssue, .pending)
            XCTAssertEqual(preparations, 0)
            pending = false
            model.retryAccountInspection()
            var second: FoundationAppModel.Readiness?
            let retry = Task { second = await model.ensureReady() }
            fixture.tasks.append(retry)
            try await waitForTask(retry, label: "inspection retry startup")
            XCTAssertEqual(second, .signedOut)
            XCTAssertNil(model.accountInspectionIssue)
            XCTAssertEqual(inspections, 2)
            XCTAssertEqual(preparations, 1)
            fixture.gate.release()
            try await fixture.drain(using: self)
            fixture.removeData()
        }

        func testDefaultAccountLocksUseIsolationHostApplicationSupport() throws {
            guard
                Bundle.main.bundleIdentifier == "com.chameleonenterprise.velacanto.isolationtesting"
            else {
                XCTFail("This test requires the separate isolated host")
                throw CancellationError()
            }
            let lease = try FoundationAccountLifetimeLease.acquire()
            XCTAssertThrowsError(try FoundationAccountLifetimeLease.acquire()) { error in
                guard let leaseError = error as? FoundationAccountLifetimeLease.LeaseError,
                    case .busy = leaseError
                else {
                    return XCTFail("Expected isolated lifetime-lock contention")
                }
            }
            try FoundationAccountTransactionLock.withLock {
                XCTAssertThrowsError(try FoundationAccountTransactionLock.withLock {}) { error in
                    guard let lockError = error as? FoundationAccountTransactionLock.LockError,
                        case .busy = lockError
                    else {
                        return XCTFail("Expected isolated transaction-lock contention")
                    }
                }
            }
            try FoundationAccountTransactionLock.withLock {}
            withExtendedLifetime(lease) {}
        }

        func testSandboxScopedRemovalUsesSystemAnchorsWithoutFollowingLinks() async throws {
            guard
                Bundle.main.bundleIdentifier == "com.chameleonenterprise.velacanto.isolationtesting"
            else {
                XCTFail("This test requires the separate isolated host")
                throw CancellationError()
            }
            let files = FileManager.default
            let anchors = try [
                XCTUnwrap(files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first),
                XCTUnwrap(files.urls(for: .cachesDirectory, in: .userDomainMask).first),
            ]
            for anchor in anchors {
                let testRoot = anchor.appendingPathComponent(
                    "VelaCantoAnchorTest-" + UUID().uuidString)
                let scope = String(repeating: "a", count: 64)
                let other = String(repeating: "b", count: 64)
                let own = testRoot.appendingPathComponent(scope, isDirectory: true)
                let retained = testRoot.appendingPathComponent(other, isDirectory: true)
                var safeToRemove = false
                defer { if safeToRemove { try? files.removeItem(at: testRoot) } }
                try files.createDirectory(at: own, withIntermediateDirectories: true)
                try files.createDirectory(at: retained, withIntermediateDirectories: true)
                let sentinel = retained.appendingPathComponent("sentinel")
                try Data("other scope".utf8).write(to: sentinel)
                var removed = false
                let task = Task {
                    removed = await FoundationScopedAccountRemoval.removeAsync(
                        root: testRoot, scope: scope)
                }
                try await waitForTask(task, label: "isolated sandbox scoped removal")
                let retainedData = try Data(contentsOf: sentinel)
                XCTAssertTrue(removed)
                XCTAssertFalse(files.fileExists(atPath: own.path))
                XCTAssertEqual(retainedData, Data("other scope".utf8))
                let absent = testRoot.appendingPathComponent("missing", isDirectory: true)
                var missing = false
                let missingTask = Task {
                    missing = await FoundationScopedAccountRemoval.removeAsync(
                        root: absent, scope: scope)
                }
                try await waitForTask(missingTask, label: "isolated missing root")
                XCTAssertTrue(missing)
                XCTAssertFalse(files.fileExists(atPath: absent.path))
                let link = testRoot.appendingPathComponent("link")
                try files.createSymbolicLink(at: link, withDestinationURL: retained)
                var throughLink = true
                let linkTask = Task {
                    throughLink = await FoundationScopedAccountRemoval.removeAsync(
                        root: link, scope: scope)
                }
                try await waitForTask(linkTask, label: "isolated symlink root")
                let nested = link.appendingPathComponent("nested", isDirectory: true)
                var throughIntermediate = true
                let nestedTask = Task {
                    throughIntermediate = await FoundationScopedAccountRemoval.removeAsync(
                        root: nested, scope: scope)
                }
                try await waitForTask(nestedTask, label: "isolated symlink ancestor")
                XCTAssertFalse(throughLink)
                XCTAssertFalse(throughIntermediate)
                XCTAssertEqual(try Data(contentsOf: sentinel), Data("other scope".utf8))
                guard removed, !files.fileExists(atPath: own.path),
                    retainedData == Data("other scope".utf8),
                    missing, !files.fileExists(atPath: absent.path), !throughLink,
                    !throughIntermediate,
                    try Data(contentsOf: sentinel) == Data("other scope".utf8)
                else { throw CancellationError() }
                safeToRemove = true
            }
            let base = URL(fileURLWithPath: "/synthetic/anchor", isDirectory: true)
            let sibling = URL(fileURLWithPath: "/synthetic/anchor-sibling/file", isDirectory: true)
            XCTAssertNil(FoundationTrustedAccountPath.components(sibling, below: base))
        }

        func testLifetimeAccountLeaseRejectsContendingOwnerUntilRelease() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            var first: FoundationAccountLifetimeLease?
            defer {
                first = nil
                try? FileManager.default.removeItem(at: root)
            }
            first = try FoundationAccountLifetimeLease.acquire(root: root)
            XCTAssertNotNil(first)
            XCTAssertThrowsError(try FoundationAccountLifetimeLease.acquire(root: root)) { error in
                guard let leaseError = error as? FoundationAccountLifetimeLease.LeaseError,
                    case .busy = leaseError
                else {
                    return XCTFail("Expected a busy lifetime owner")
                }
            }
            first = nil
            var successor: FoundationAccountLifetimeLease? =
                try FoundationAccountLifetimeLease.acquire(root: root)
            XCTAssertNotNil(successor)
            successor = nil
        }

        func testContendedAccountOwnerBlocksStartupAndHeadlessUntilRetry() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            var busy = true
            var cachePreparations = 0
            var headlessRoutes = 0
            var systemCompletions = 0
            var authenticated = false
            let model = fixture.makeModel(
                backgroundReconcile: { _ in
                    headlessRoutes += 1
                    return false
                },
                useModelBackgroundRouting: true,
                prepareIsolatedCaches: {
                    cachePreparations += 1
                    return true
                },
                acquireAccountOwnership: {
                    if busy { throw FoundationAccountLifetimeLease.LeaseError.busy }
                    return nil
                })
            model.receiveBackgroundDownloadEvents("synthetic-session") { systemCompletions += 1 }
            var initial: FoundationAppModel.Readiness?
            let startup = Task { initial = await model.ensureReady() }
            fixture.tasks.append(startup)
            try await waitForTask(startup, label: "contended account startup")
            var prepared: FoundationSignInView.Acceptance?
            let attempt = Task {
                prepared = try? await model.prepareSignIn {
                    authenticated = true
                    return fixture.session(user: "synthetic")
                }
            }
            fixture.tasks.append(attempt)
            try await waitForTask(attempt, label: "contended account authentication")
            try await fixture.drain(using: self)
            XCTAssertEqual(initial, .unavailable)
            XCTAssertEqual(model.accountInspectionIssue, .inUse)
            XCTAssertNil(prepared)
            XCTAssertFalse(authenticated)
            XCTAssertEqual(cachePreparations, 0)
            XCTAssertEqual(headlessRoutes, 0)
            XCTAssertEqual(systemCompletions, 0)
            guard initial == .unavailable, model.accountInspectionIssue == .inUse,
                prepared == nil, !authenticated, cachePreparations == 0,
                headlessRoutes == 0, systemCompletions == 0
            else { throw CancellationError() }
            busy = false
            model.retryAccountInspection()
            var retried: FoundationAppModel.Readiness?
            let retry = Task { retried = await model.ensureReady() }
            fixture.tasks.append(retry)
            try await waitForTask(retry, label: "account ownership retry")
            try await fixture.drain(using: self)
            XCTAssertEqual(retried, .signedOut)
            XCTAssertEqual(cachePreparations, 1)
            XCTAssertEqual(headlessRoutes, 1)
            XCTAssertEqual(systemCompletions, 0)
            XCTAssertNil(model.accountInspectionIssue)
            guard retried == .signedOut, cachePreparations == 1, headlessRoutes == 1,
                systemCompletions == 0, model.accountInspectionIssue == nil
            else { throw CancellationError() }
            fixture.gate.release()
            try await fixture.drain(using: self)
            fixture.removeData()
        }

        func testMarkerFirstSignOutHoldsCredentialUntilScopedLeaseDrains() async throws {
            try await exerciseMarkerFirstSignOut(reservedReceipt: false)
        }

        func testMarkerFirstSignOutRetiresReservedReceiptAfterLeaseDrains() async throws {
            try await exerciseMarkerFirstSignOut(reservedReceipt: true)
        }

        func testMarkerFirstSignOutRetriesAfterPartialReceiptConsumption() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: true, checkpoint: .afterFirstReceiptUnlink)
        }

        func testMarkerFirstSignOutRetriesAfterDirectoryRemovalBeforeAdoption() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: true, checkpoint: .afterDirectoryRemoval)
        }

        func testMarkerFirstSignOutRetiresExactAllocatedPackageAfterLeaseDrains() async throws {
            try await exerciseMarkerFirstSignOut(reservedReceipt: false, allocatedReceipt: true)
        }

        func testMarkerFirstSignOutRetriesAllocatedAfterTombstone() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, checkpoint: .afterFirstTombstone,
                allocatedReceipt: true)
        }

        func testMarkerFirstSignOutRetriesAllocatedAfterManifest() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, checkpoint: .afterManifest,
                allocatedReceipt: true)
        }

        func testMarkerFirstSignOutRetriesAllocatedAfterReceiptConsumption() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, checkpoint: .afterFirstReceiptUnlink,
                allocatedReceipt: true)
        }

        func testMarkerFirstSignOutPreservesAllocatedPackageWithoutFinality() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, allocatedReceipt: true,
                allocatedFault: "finality")
        }

        func testMarkerFirstSignOutPreservesAllocatedPackageWithoutModelDrain() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, allocatedReceipt: true,
                allocatedFault: "drain")
        }

        func testMarkerFirstSignOutPreservesMismatchedAllocatedPackage() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, allocatedReceipt: true,
                allocatedFault: "bookmark")
        }

        func testMarkerFirstSignOutPreservesMismatchedAllocatedURL() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, allocatedReceipt: true,
                allocatedFault: "url")
        }

        func testMarkerFirstSignOutPreservesMismatchedAllocatedTrack() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, allocatedReceipt: true,
                allocatedFault: "track")
        }

        func testMarkerFirstSignOutPreservesMismatchedAllocatedNamespace() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, allocatedReceipt: true,
                allocatedFault: "namespace")
        }

        func testMarkerFirstSignOutRetriesAfterAllocatedPackageUnlinkBeforeTombstone() async throws
        {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, allocatedReceipt: true,
                allocatedFault: "unlink")
        }

        func testMarkerFirstSignOutKeepsUnverifiableMissingPackagePending() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, allocatedReceipt: true,
                allocatedFault: "unlink-unverifiable")
        }

        func testMarkerFirstSignOutRetainsScopeDuringCancelledAllocatedRetirement() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, allocatedReceipt: true,
                allocatedFault: "stale")
        }

        func testReadinessInvalidationDoesNotAbortAuthorizedAllocatedSignOut() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, allocatedReceipt: true,
                allocatedFault: "readiness")
        }

        func testMarkerFirstSignOutRetiresFinalizedTerminalReceiptAfterLease() async throws {
            try await exerciseMarkerFirstSignOut(reservedReceipt: false, terminalReceipt: true)
        }

        func testMarkerFirstSignOutRetriesFinalizedTerminalAfterReceiptConsumption() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, checkpoint: .afterFirstReceiptUnlink,
                terminalReceipt: true)
        }

        func testMarkerFirstSignOutPreservesTerminalReceiptWithoutFinality() async throws {
            try await exerciseMarkerFirstSignOut(
                reservedReceipt: false, terminalReceipt: true,
                terminalFinality: false)
        }

        private func exerciseMarkerFirstSignOut(
            reservedReceipt: Bool,
            checkpoint: FoundationScopedAccountRemoval.NoFactoryCheckpoint? = nil,
            allocatedReceipt: Bool = false, allocatedFault: String? = nil,
            terminalReceipt: Bool = false, terminalFinality: Bool = true
        ) async throws {
            let leaseWait = expectation(description: "durable sign-out lease wait")
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "synthetic revocation entered"))
            do {
                let retirementEntered = XCTestExpectation(
                    description: "allocated retirement entered")
                let retirementGate = DispatchSemaphore(value: 0)
                defer { retirementGate.signal() }
                let keychain = IntentKeychainFixture()
                let session = fixture.session(user: "00000000000000000000000000000001")
                keychain.credentialData = try JSONEncoder().encode(session)
                let operations = keychain.operations()
                let root = fixture.root.appendingPathComponent("transaction", isDirectory: true)
                let transactions = FoundationAccountTransactions(
                    inspect: {
                        try FoundationAccountCredentialTransaction.inspect(
                            root: root, operations: operations)
                    },
                    prepareSignOut: { value, expected, preparation in
                        try FoundationAccountCredentialTransaction.prepareSignOut(
                            value, expecting: expected, preparation: preparation, root: root,
                            operations: operations)
                    },
                    finishCompletedSignOut: { marker in
                        try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                            marker, root: root, operations: operations)
                    },
                    recordSignOut: { value, marker, expected in
                        try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                            value, intent: marker, expecting: expected, root: root,
                            operations: operations)
                    })
                let model = fixture.makeModel(
                    leaseWaitStarted: { leaseWait.fulfill() },
                    inspectSignOutIntent: {
                        do {
                            return try FoundationSignOutIntentStore.load(operations: operations)
                                == nil ? .absent : .pending
                        } catch { return .unavailable }
                    }, accountTransactions: transactions)
                let startup = Task { _ = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForTask(startup, label: "durable sign-out startup")
                let accept = try await model.prepareSignIn { session }
                let scope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                let track = FoundationItem(
                    id: "00000000000000000000000000000003", title: "Synthetic",
                    subtitle: "", kind: .track, duration: nil)
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(directory)
                let file = directory.appendingPathComponent("synthetic.audio")
                let bytes = Data("synthetic-test-bytes".utf8)
                try bytes.write(to: file)
                var manifest = FoundationDownloadManifest()
                let stored = FoundationStoredDownloadItem(track)
                manifest.owners = [
                    .init(
                        id: "track:" + track.id, item: stored, tracks: [stored],
                        paused: false, expanded: false)
                ]
                manifest.files[track.id] = .init(
                    name: file.lastPathComponent,
                    bytes: Int64(bytes.count), digest: try FoundationDownloadStorage.digest(file))
                if reservedReceipt {
                    var pending: Set<String> = []
                    for _ in 0..<2 {
                        let identifier =
                            "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                            + "." + UUID().uuidString
                        let receipt = FoundationNativeAllocationStore(
                            directory: directory, sessionIdentifier: identifier)
                        try receipt.reserve()
                        pending.insert(identifier)
                    }
                    manifest.nativePendingSessions = pending
                }
                let other = FoundationDownloadStorage.directory(
                    scope: String(repeating: "b", count: 64), root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(other)
                let otherSentinel = other.appendingPathComponent("other-account")
                let sentinelData = Data("preserve other scope".utf8)
                try sentinelData.write(to: otherSentinel)
                try FoundationDownloadStorage.save(manifest, directory: directory)
                try await accept()
                let downloads = try XCTUnwrap(model.downloads)
                downloads.isolatedNoFactoryCheckpoint = checkpoint
                let cleanupAttemptFinished = XCTestExpectation(
                    description: "first cleanup attempt finished")
                let cleanupObservation = model.$isCleaningDownloads.dropFirst().filter { !$0 }
                    .first().sink { _ in
                        cleanupAttemptFinished.fulfill()
                    }
                defer { cleanupObservation.cancel() }
                let inventory = expectation(description: "durable sign-out inventory")
                let inventoryObservation = downloads.$isLoading.filter { !$0 }.first().sink { _ in
                    inventory.fulfill()
                }
                defer {
                    inventoryObservation.cancel()
                    fixture.gate.release()
                }
                try await waitForEvents([inventory], label: "durable sign-out inventory")
                try await fixture.acquireResource(from: downloads, item: track, using: self)
                var terminalStore: FoundationNativeAllocationStore?
                var terminalBytes: Data?
                if terminalReceipt {
                    let identifier =
                        "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                        + "." + UUID().uuidString
                    let terminal = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    try terminal.reserve()
                    try terminal.beginCreating()
                    try terminal.bindCreatedTask(taskIdentifier: 1)
                    try terminal.recordTerminalNoAllocation(taskIdentifier: 1)
                    try terminal.retire()
                    terminalStore = terminal
                    terminalBytes = try Data(contentsOf: terminal.receiptURL)
                    downloads.isolatedTrackTerminalNativeSession(
                        identifier, finalized: terminalFinality)
                }
                let packageURL = fixture.root.appendingPathComponent(
                    "synthetic-owned.movpkg", isDirectory: true)
                let allocatedRetirements = IsolatedDiagnosticRecorder()
                if allocatedReceipt {
                    try FileManager.default.createDirectory(
                        at: packageURL, withIntermediateDirectories: true)
                    try Data("synthetic package".utf8).write(
                        to: packageURL.appendingPathComponent("content"))
                    let identifier =
                        "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                        + "." + UUID().uuidString
                    let nativeTrack = "00000000000000000000000000000004"
                    let package = FoundationNativeDownloadPackage(
                        nativeURL: packageURL, bookmark: Data("synthetic".utf8),
                        sessionIdentifier: identifier,
                        namespaceBookmark: Data("namespace".utf8))
                    let receipt = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    var record = FoundationNativeAllocationStore.Receipt(
                        scope: directory.lastPathComponent, sessionIdentifier: identifier,
                        taskIdentifier: 1)
                    record.trackID = allocatedFault == "track" ? "different-track" : nativeTrack
                    let receiptURL =
                        allocatedFault == "url"
                        ? fixture.root.appendingPathComponent("different.movpkg") : packageURL
                    let receiptNamespace =
                        allocatedFault == "namespace"
                        ? Data("different".utf8) : package.namespaceBookmark
                    record.nativeURL = receiptURL
                    record.phase = .allocated
                    record.creationVersion = 1
                    record.namespaceBookmark = receiptNamespace
                    record.package = FoundationNativeDownloadPackage(
                        nativeURL: receiptURL,
                        bookmark: allocatedFault == "bookmark"
                            ? Data("different".utf8) : package.bookmark,
                        sessionIdentifier: identifier, namespaceBookmark: receiptNamespace)
                    record.completionAttempted = true
                    try JSONEncoder().encode(record).write(to: receipt.receiptURL)
                    try downloads.isolatedSeedAllocatedFile(
                        trackID: nativeTrack,
                        file: .init(
                            name: "synthetic-owned.movpkg", bytes: 1, digest: "",
                            nativePackage: package))
                    if allocatedFault != "finality" {
                        downloads.isolatedRecordNativeFinality(identifier)
                    }
                    if allocatedFault != "drain" {
                        downloads.recordBackgroundSessionDrain(identifier)
                    }
                    downloads.isolatedAllocatedRetirement = { store in
                        allocatedRetirements.append("entered")
                        if allocatedFault == "stale" || allocatedFault == "readiness" {
                            retirementEntered.fulfill()
                            guard retirementGate.wait(timeout: .now() + 5) == .success else {
                                throw FoundationDownloadError.cleanup
                            }
                        }
                        guard store.directory == directory, store.sessionIdentifier == identifier
                        else {
                            throw FoundationDownloadError.cleanup
                        }
                        try store.retire(
                            resolve: { candidate in
                                guard candidate.sessionIdentifier == identifier,
                                    candidate.nativeURL == packageURL
                                else { return .unverifiable }
                                if FileManager.default.fileExists(atPath: packageURL.path) {
                                    return .available(packageURL)
                                }
                                return allocatedFault == "unlink-unverifiable"
                                    ? .unverifiable : .provenMissing
                            },
                            remove: { url in
                                guard url == packageURL else {
                                    throw FoundationDownloadError.cleanup
                                }
                                try FileManager.default.removeItem(at: url)
                                if allocatedFault == "unlink"
                                    || allocatedFault == "unlink-unverifiable",
                                    allocatedRetirements.snapshot().count == 1
                                {
                                    throw FoundationDownloadError.cleanup
                                }
                            })
                    }
                }
                let player = try XCTUnwrap(model.player)
                model.signOut()
                try await waitForEvents([leaseWait], label: "durable held lease")
                fixture.captureStop(player)
                let heldMarker = try FoundationSignOutIntentStore.load(operations: operations)
                let heldCredential = keychain.credentialData
                let heldFile = FileManager.default.fileExists(atPath: file.path)
                let revocationsBeforeRelease = fixture.revocations.count
                XCTAssertNotNil(heldMarker)
                XCTAssertNotNil(heldCredential)
                XCTAssertTrue(heldFile)
                if allocatedReceipt {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
                }
                XCTAssertEqual(revocationsBeforeRelease, 0)
                guard heldMarker != nil, heldCredential != nil, heldFile,
                    !allocatedReceipt || FileManager.default.fileExists(atPath: packageURL.path),
                    revocationsBeforeRelease == 0
                else { throw CancellationError() }
                let finished = XCTestExpectation(description: "durable cleanup finalized")
                let observation = model.$accountInspectionIssue.dropFirst().filter { $0 == nil }
                    .first().sink { _ in
                        finished.fulfill()
                    }
                defer { observation.cancel() }
                try await fixture.releaseResources(using: self)
                if allocatedFault == "stale" || allocatedFault == "readiness" {
                    try await waitForEvents([retirementEntered], label: "held allocated retirement")
                    model.invalidateAccountReadiness()
                    if allocatedFault == "stale" {
                        let cleanup = try XCTUnwrap(model.isolatedSignOutCleanupTask)
                        cleanup.cancel()
                        XCTAssertTrue(cleanup.isCancelled)
                    }
                    var authenticationCalled = false
                    var preparationFailure: Error?
                    let attempt = Task {
                        do {
                            _ = try await model.prepareSignIn {
                                authenticationCalled = true
                                return session
                            }
                        } catch { preparationFailure = error }
                    }
                    fixture.tasks.append(attempt)
                    try await waitForTask(attempt, label: "stale cleanup admission")
                    let marker = try FoundationSignOutIntentStore.load(operations: operations)
                    XCTAssertNotNil(marker)
                    XCTAssertNotNil(preparationFailure)
                    XCTAssertFalse(authenticationCalled)
                    XCTAssertNil(model.library)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
                    guard marker != nil, preparationFailure != nil, !authenticationCalled,
                        model.library == nil,
                        FileManager.default.fileExists(atPath: packageURL.path)
                    else { throw CancellationError() }
                    retirementGate.signal()
                    fixture.gate.release()
                    if allocatedFault == "readiness" {
                        try await waitForEvents(
                            [finished], label: "authorized sign-out finalization")
                    }
                    try await fixture.drain(using: self)
                    let finalMarker = try FoundationSignOutIntentStore.load(operations: operations)
                    if allocatedFault == "stale" {
                        XCTAssertNotNil(finalMarker)
                        XCTAssertNotNil(keychain.credentialData)
                    } else {
                        XCTAssertNil(finalMarker)
                        XCTAssertNil(keychain.credentialData)
                        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
                    }
                    XCTAssertEqual(try Data(contentsOf: otherSentinel), sentinelData)
                    guard
                        allocatedFault == "stale"
                            ? finalMarker != nil && keychain.credentialData != nil
                            : finalMarker == nil && keychain.credentialData == nil
                                && !FileManager.default.fileExists(atPath: packageURL.path),
                        (try? Data(contentsOf: otherSentinel)) == sentinelData
                    else { throw CancellationError() }
                    fixture.removeData()
                    return
                } else if allocatedFault == "unlink" || allocatedFault == "unlink-unverifiable" {
                    try await waitForEvents(
                        [cleanupAttemptFinished], label: "interrupted allocated cleanup")
                    let marker = try FoundationSignOutIntentStore.load(operations: operations)
                    XCTAssertNotNil(marker)
                    XCTAssertNotNil(keychain.credentialData)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
                    XCTAssertEqual(allocatedRetirements.snapshot().count, 1)
                    guard marker != nil, keychain.credentialData != nil,
                        !FileManager.default.fileExists(atPath: packageURL.path),
                        allocatedRetirements.snapshot().count == 1
                    else { throw CancellationError() }
                    if allocatedFault == "unlink-unverifiable" {
                        let retried = XCTestExpectation(description: "unverifiable cleanup retry")
                        let retryObservation = model.$isCleaningDownloads.dropFirst().filter { !$0 }
                            .first().sink { _ in
                                retried.fulfill()
                            }
                        defer { retryObservation.cancel() }
                        model.retryAccountInspection()
                        try await waitForEvents([retried], label: "unverifiable allocated retry")
                        XCTAssertNotNil(
                            try FoundationSignOutIntentStore.load(operations: operations))
                        XCTAssertNotNil(keychain.credentialData)
                        XCTAssertEqual(allocatedRetirements.snapshot().count, 2)
                        XCTAssertEqual(try Data(contentsOf: otherSentinel), sentinelData)
                        guard try FoundationSignOutIntentStore.load(operations: operations) != nil,
                            keychain.credentialData != nil,
                            allocatedRetirements.snapshot().count == 2,
                            (try? Data(contentsOf: otherSentinel)) == sentinelData
                        else { throw CancellationError() }
                        fixture.gate.release()
                        try await fixture.drain(using: self)
                        fixture.removeData()
                        return
                    }
                    model.retryAccountInspection()
                } else if allocatedFault != nil || (terminalReceipt && !terminalFinality) {
                    try await waitForEvents(
                        [cleanupAttemptFinished], label: "unverified native cleanup")
                    let marker = try FoundationSignOutIntentStore.load(operations: operations)
                    let terminalPreserved =
                        !terminalReceipt
                        || terminalStore.map {
                            (try? Data(contentsOf: $0.receiptURL)) == terminalBytes
                        } == true
                    let retained =
                        terminalReceipt || FileManager.default.fileExists(atPath: packageURL.path)
                    XCTAssertNotNil(marker)
                    XCTAssertTrue(terminalPreserved)
                    XCTAssertNotNil(keychain.credentialData)
                    XCTAssertTrue(retained)
                    XCTAssertTrue(allocatedRetirements.snapshot().isEmpty)
                    XCTAssertEqual(try Data(contentsOf: otherSentinel), sentinelData)
                    guard marker != nil, keychain.credentialData != nil, retained,
                        terminalPreserved,
                        allocatedRetirements.snapshot().isEmpty,
                        (try? Data(contentsOf: otherSentinel)) == sentinelData
                    else { throw CancellationError() }
                    fixture.gate.release()
                    try await fixture.drain(using: self)
                    fixture.removeData()
                    return
                }
                if checkpoint != nil {
                    try await waitForEvents(
                        [cleanupAttemptFinished], label: "interrupted cleanup attempt")
                    XCTAssertNotNil(try FoundationSignOutIntentStore.load(operations: operations))
                    XCTAssertNotNil(keychain.credentialData)
                    guard try FoundationSignOutIntentStore.load(operations: operations) != nil,
                        keychain.credentialData != nil
                    else { throw CancellationError() }
                    downloads.isolatedNoFactoryCheckpoint = nil
                    model.retryAccountInspection()
                }
                try await waitForEvents([finished], label: "durable sign-out finalization")
                let marker = try FoundationSignOutIntentStore.load(operations: operations)
                XCTAssertNil(marker)
                XCTAssertNil(keychain.credentialData)
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
                if allocatedReceipt {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
                }
                let preservedOther = try Data(contentsOf: otherSentinel)
                XCTAssertEqual(preservedOther, sentinelData)
                guard marker == nil, keychain.credentialData == nil,
                    !FileManager.default.fileExists(atPath: directory.path),
                    !allocatedReceipt || !FileManager.default.fileExists(atPath: packageURL.path),
                    preservedOther == sentinelData
                else { throw CancellationError() }
                fixture.gate.release()
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                fixture.gate.release()
                do {
                    try await fixture.releaseResources(using: self)
                    try await fixture.drain(using: self)
                } catch {
                    XCTFail("Could not drain durable sign-out fixture; data retained")
                }
                throw error
            }
        }
        func testColdPendingSignOutCleansOnlyItsVerifiedAccount() async throws {
            try await exerciseColdPendingSignOut(reservedReceipt: false)
        }

        func testColdPendingSignOutRecoversReservedReceipt() async throws {
            try await exerciseColdPendingSignOut(reservedReceipt: true)
        }

        private func exerciseColdPendingSignOut(reservedReceipt: Bool) async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "synthetic revocation entered"))
            let keychain = IntentKeychainFixture()
            let session = fixture.session(user: "00000000000000000000000000000001")
            keychain.credentialData = try JSONEncoder().encode(session)
            let operations = keychain.operations()
            let root = fixture.root.appendingPathComponent("transaction", isDirectory: true)
            let snapshot = try FoundationAccountCredentialTransaction.inspect(
                root: root, operations: operations)
            let intent = try FoundationAccountCredentialTransaction.prepareSignOut(
                session, expecting: snapshot, root: root, operations: operations)
            let transactions = FoundationAccountTransactions(
                inspect: {
                    try FoundationAccountCredentialTransaction.inspect(
                        root: root, operations: operations)
                },
                prepareSignOut: { value, expected, preparation in
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        value, expecting: expected, preparation: preparation, root: root,
                        operations: operations)
                },
                finishCompletedSignOut: { marker in
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        marker, root: root, operations: operations)
                },
                recordSignOut: { value, marker, expected in
                    try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                        value, intent: marker, expecting: expected, root: root,
                        operations: operations)
                })
            let model = fixture.makeModel(
                inspectSignOutIntent: {
                    do {
                        return try FoundationSignOutIntentStore.load(operations: operations) == nil
                            ? .absent : .pending
                    } catch { return .unavailable }
                }, accountTransactions: transactions)
            let directory = FoundationDownloadStorage.directory(
                scope: intent.scope, root: fixture.storage.downloads)
            let other = FoundationDownloadStorage.directory(
                scope: String(repeating: "b", count: 64), root: fixture.storage.downloads)
            try FoundationDownloadStorage.prepare(directory)
            try FoundationDownloadStorage.prepare(other)
            var manifest = FoundationDownloadManifest()
            if reservedReceipt {
                let identifier =
                    "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                    + "." + UUID().uuidString
                let receipt = FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: identifier)
                try receipt.reserve()
                manifest.nativePendingSessions = [identifier]
            }
            try FoundationDownloadStorage.save(manifest, directory: directory)
            let ownedFile = directory.appendingPathComponent("track.bin")
            let sentinel = other.appendingPathComponent("other-account")
            try Data("owned".utf8).write(to: ownedFile)
            try Data("untouched".utf8).write(to: sentinel)
            fixture.defaults.set(
                Data("pins".utf8), forKey: FoundationPinStorage.key(for: intent.scope))
            let widgetStore = FoundationWidgetStore(
                location: .directory(
                    fixture.root.appendingPathComponent("widgets", isDirectory: true)))
            let widgetSnapshot = FoundationWidgetSnapshot(
                version: 1, presentation: .track, scope: intent.scope, occurrence: UUID(),
                collection: nil, title: "Synthetic pending account", detail: "", isPlaying: false)
            try widgetStore.save(widgetSnapshot, artwork: nil)
            var readiness: FoundationAppModel.Readiness?
            let startup = Task { readiness = await model.ensureReady() }
            fixture.tasks.append(startup)
            try await waitForTask(startup, label: "pending-intent startup")
            XCTAssertEqual(readiness, .unavailable)
            XCTAssertTrue(FileManager.default.fileExists(atPath: ownedFile.path))
            XCTAssertEqual(try widgetStore.load(), widgetSnapshot)
            let finished = expectation(description: "pending cleanup finished")
            let observer = model.$isCheckingPendingSignOut.dropFirst().filter { !$0 }.first().sink {
                _ in
                finished.fulfill()
            }
            defer {
                observer.cancel()
                fixture.gate.release()
            }
            model.retryAccountInspection()
            try await waitForEvents([finished], label: "scoped pending cleanup")
            let marker = try FoundationSignOutIntentStore.load(operations: operations)
            let retained = try Data(contentsOf: sentinel)
            XCTAssertNil(marker)
            XCTAssertNil(keychain.credentialData)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertNil(fixture.defaults.data(forKey: FoundationPinStorage.key(for: intent.scope)))
            XCTAssertEqual(retained, Data("untouched".utf8))
            XCTAssertEqual(try widgetStore.load(), .empty)
            guard marker == nil, keychain.credentialData == nil,
                !FileManager.default.fileExists(atPath: directory.path),
                fixture.defaults.data(forKey: FoundationPinStorage.key(for: intent.scope)) == nil,
                retained == Data("untouched".utf8)
            else { throw CancellationError() }
            fixture.gate.release()
            var after: FoundationAppModel.Readiness?
            let postCleanupStartup = Task { after = await model.ensureReady() }
            fixture.tasks.append(postCleanupStartup)
            try await waitForTask(postCleanupStartup, label: "post-cleanup startup")
            XCTAssertEqual(after, .signedOut)
            guard after == .signedOut else { throw CancellationError() }
            try await fixture.drain(using: self)
            fixture.removeData()
        }
        func testObserverDrainCannotAcknowledgeAdmittedEventBeforeFinality() async throws {
            try await exerciseColdAllocatedSignOut(
                callbackBeforeDrain: true,
                callbackAfterPublication: true, quiescenceWithoutDrain: true,
                observerDrainFault: "none")
        }

        func testObserverDrainCannotAcknowledgeAdmittedEventWithNativeWork() async throws {
            try await exerciseColdAllocatedSignOut(
                callbackBeforeDrain: true,
                callbackAfterPublication: true, quiescenceWithoutDrain: true,
                observerDrainFault: "native-work")
        }

        func testObserverDrainCannotAcknowledgeAdmittedEventWithChangedCurrentProof() async throws {
            try await exerciseColdAllocatedSignOut(
                callbackBeforeDrain: true,
                callbackAfterPublication: true, quiescenceWithoutDrain: true,
                observerDrainFault: "current-changed")
        }

        func testColdDiscoveryPublicationReplaysUndrainedEventAfterBusyAttempt() async throws {
            try await exerciseColdAllocatedSignOut(
                callbackBeforeDrain: true,
                callbackAfterPublication: true, quiescenceWithoutDrain: true,
                discoveryTraceInterleaving: true)
        }

        func testColdAllocatedSignOutCompletesQuiescentPublishedEventWithoutDrain() async throws {
            try await exerciseColdAllocatedSignOut(
                callbackBeforeDrain: true,
                callbackAfterPublication: true, quiescenceWithoutDrain: true)
        }

        func testColdAllocatedSignOutCompletesQuiescentWaitingEventWithoutDrain() async throws {
            try await exerciseColdAllocatedSignOut(
                callbackBeforeDrain: true,
                quiescenceWithoutDrain: true)
        }

        func testColdAllocatedSignOutSharesCallbackBeforeFinality() async throws {
            try await exerciseColdAllocatedSignOut(callbackBeforeDrain: true)
        }

        func testColdAllocatedSignOutSharesDrainBeforeCallback() async throws {
            try await exerciseColdAllocatedSignOut(callbackBeforeDrain: false)
        }

        func testColdAllocatedSignOutHandlesCallbackAfterPublication() async throws {
            try await exerciseColdAllocatedSignOut(
                callbackBeforeDrain: false, callbackAfterPublication: true)
        }

        func testColdAllocatedSignOutCancellationPreservesPendingAccount() async throws {
            try await exerciseColdAllocatedSignOut(callbackBeforeDrain: false, cancelFlight: true)
        }

        func testColdAllocatedSignOutRetainsDataWhenMarkerBecomesUnreadable() async throws {
            try await exerciseColdAllocatedSignOut(callbackBeforeDrain: false, staleMarker: true)
        }

        func testColdAllocatedRelaunchAfterTombstone() async throws {
            try await exerciseColdAllocatedSignOut(
                callbackBeforeDrain: false, stopAfterRetire: true)
        }

        func testColdAllocatedRelaunchAfterManifestAuthorization() async throws {
            try await exerciseColdAllocatedSignOut(
                callbackBeforeDrain: false, checkpoint: .afterAuthorization)
        }

        func testColdAllocatedRelaunchAfterManifestPublication() async throws {
            try await exerciseColdAllocatedSignOut(
                callbackBeforeDrain: false, checkpoint: .afterManifest)
        }

        func testColdAllocatedRecoveryReportsActiveAndDelayedStatus() async throws {
            try await exerciseColdAllocatedSignOut(callbackBeforeDrain: true, statusTracking: true)
        }

        func testCompletedColdRecoveryCannotPublishStaleDelayedStatus() async throws {
            try await exerciseColdAllocatedSignOut(
                callbackBeforeDrain: true, staleStatusDelay: true)
        }

        private func exerciseColdAllocatedSignOut(
            callbackBeforeDrain: Bool, callbackAfterPublication: Bool = false,
            cancelFlight: Bool = false, staleMarker: Bool = false,
            stopAfterRetire: Bool = false,
            checkpoint: FoundationScopedAccountRemoval.ColdPublicationCheckpoint? = nil,
            statusTracking: Bool = false, staleStatusDelay: Bool = false,
            quiescenceWithoutDrain: Bool = false, observerDrainFault: String? = nil,
            discoveryTraceInterleaving: Bool = false
        ) async throws {
            let entered = expectation(description: "cold allocated retirement entered")
            let gate = LifecycleGate(entered: entered)
            let discoveryBeforeEntered = XCTestExpectation(
                description: "second discovery waits before busy fence")
            let discoveryBeforeGate = LifecycleGate(entered: discoveryBeforeEntered)
            let discoveryBegan = XCTestExpectation(
                description: "second discovery acquired busy fence")
            let discoveryReadEntered = XCTestExpectation(
                description: "second discovery read complete")
            let discoveryReadGate = LifecycleGate(entered: discoveryReadEntered)
            let secureProofEntered = XCTestExpectation(
                description: "exact retired proof read before busy fence")
            let secureProofGate = LifecycleGate(entered: secureProofEntered)
            let metadataRefusedEntered = XCTestExpectation(
                description: "replayed route observed actual absent-metadata refusal")
            let metadataRefusedGate = LifecycleGate(entered: metadataRefusedEntered)
            var discoveries = 0
            var firstSecureProofHeld = false
            var busyDiscoveryBegan = false
            var metadataRefusalHeld = false
            let observerEntered = XCTestExpectation(
                description: "observer drain held before finality")
            let observerGate = LifecycleGate(entered: observerEntered)
            let firstRoutingSettled = XCTestExpectation(
                description: "metadata admitted without drain")
            let statusEntered = XCTestExpectation(description: "cold status delay entered")
            let statusGate = LifecycleGate(entered: statusEntered)
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            defer {
                gate.release()
                discoveryBeforeGate.release()
                discoveryReadGate.release()
                secureProofGate.release()
                metadataRefusedGate.release()
                observerGate.release()
                statusGate.release()
                fixture.gate.release()
            }
            do {
                let keychain = IntentKeychainFixture()
                let session = fixture.session(user: "00000000000000000000000000000001")
                keychain.credentialData = try JSONEncoder().encode(session)
                let operations = keychain.operations()
                let transactionRoot = fixture.root.appendingPathComponent(
                    "transaction", isDirectory: true)
                let snapshot = try FoundationAccountCredentialTransaction.inspect(
                    root: transactionRoot, operations: operations)
                let intent = try FoundationAccountCredentialTransaction.prepareSignOut(
                    session, expecting: snapshot, root: transactionRoot, operations: operations)
                let transactions = FoundationAccountTransactions(
                    inspect: {
                        try FoundationAccountCredentialTransaction.inspect(
                            root: transactionRoot, operations: operations)
                    },
                    prepareSignOut: { value, expected, preparation in
                        try FoundationAccountCredentialTransaction.prepareSignOut(
                            value, expecting: expected, preparation: preparation,
                            root: transactionRoot, operations: operations)
                    },
                    finishCompletedSignOut: { marker in
                        try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                            marker, root: transactionRoot, operations: operations)
                    },
                    recordSignOut: { value, marker, expected in
                        try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                            value, intent: marker, expecting: expected, root: transactionRoot,
                            operations: operations)
                    })
                let directory = FoundationDownloadStorage.directory(
                    scope: intent.scope, root: fixture.storage.downloads)
                let other = FoundationDownloadStorage.directory(
                    scope: String(repeating: "b", count: 64), root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(directory)
                try FoundationDownloadStorage.prepare(other)
                let otherSentinel = other.appendingPathComponent("other-account")
                let sentinelData = Data("untouched".utf8)
                try sentinelData.write(to: otherSentinel)
                let packageURL = fixture.root.appendingPathComponent(
                    "synthetic-cold.movpkg", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: packageURL, withIntermediateDirectories: true)
                try Data("synthetic".utf8).write(to: packageURL.appendingPathComponent("content"))
                let identifier =
                    "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
                    + UUID().uuidString
                let track = "00000000000000000000000000000004"
                let package = FoundationNativeDownloadPackage(
                    nativeURL: packageURL, bookmark: Data("bookmark".utf8),
                    sessionIdentifier: identifier, namespaceBookmark: Data("namespace".utf8))
                let store = FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: identifier)
                var receipt = FoundationNativeAllocationStore.Receipt(
                    scope: directory.lastPathComponent, sessionIdentifier: identifier,
                    taskIdentifier: 1)
                receipt.trackID = track
                receipt.nativeURL = packageURL
                receipt.phase = .allocated
                receipt.creationVersion = 1
                receipt.namespaceBookmark = package.namespaceBookmark
                receipt.package = package
                receipt.completionAttempted = true
                try JSONEncoder().encode(receipt).write(to: store.receiptURL)
                var manifest = FoundationDownloadManifest()
                manifest.files[track] = .init(
                    name: "synthetic-cold.movpkg", bytes: 1, digest: "", nativePackage: package)
                try FoundationDownloadStorage.save(manifest, directory: directory)
                var retirements = 0
                let fakeRetirement:
                    @MainActor (
                        FoundationNativeAllocationStore, UUID,
                        FoundationScopedAccountRemoval.ColdAllocatedCandidate,
                        @escaping @MainActor @Sendable () async -> Bool
                    ) async -> Bool = { selected, operation, candidate, verifyCurrent in
                        retirements += 1
                        await gate.hold()
                        guard !Task.isCancelled, await verifyCurrent() else { return false }
                        do {
                            guard selected.directory == directory,
                                selected.sessionIdentifier == identifier,
                                operation == intent.operation, candidate.trackID == track
                            else { return false }
                            try selected.recordColdFinality(
                                operation: operation,
                                expectedTrackID: track, expectedPackage: package)
                            try selected.retire(
                                resolve: { candidate in
                                    guard candidate.sessionIdentifier == identifier,
                                        candidate.nativeURL == packageURL
                                    else { return .unverifiable }
                                    return FileManager.default.fileExists(atPath: packageURL.path)
                                        ? .available(packageURL) : .provenMissing
                                },
                                remove: { url in
                                    guard url == packageURL else {
                                        throw FoundationDownloadError.cleanup
                                    }
                                    try FileManager.default.removeItem(at: url)
                                })
                            return !(stopAfterRetire && retirements == 1)
                        } catch { return false }
                    }
                var quiescentObservations = 0
                func makeColdModel() -> FoundationAppModel {
                    fixture.makeModel(
                        emptyNativeSession: { _, current, drained in
                            guard quiescenceWithoutDrain, await current() else {
                                return .unavailable
                            }
                            quiescentObservations += 1
                            if observerDrainFault != nil {
                                // First pass admits published metadata without native
                                // quiescence. Replay must preserve that admitted state.
                                if quiescentObservations == 1 { return .unavailable }
                                let earlierTasks = fixture.tasks.count
                                drained()
                                // Join only acknowledgements synchronously spawned
                                // by this drain, never this routing/finality task.
                                // Thus the held-boundary assertion cannot race the
                                // serial sign-out lane's queued completion callback.
                                let acknowledgements = Array(fixture.tasks.dropFirst(earlierTasks))
                                for acknowledgement in acknowledgements {
                                    do {
                                        try await self.waitForTask(
                                            acknowledgement,
                                            label: "observer drain delivery acknowledgement")
                                    } catch {
                                        // The bounded helper records the failure;
                                        // retain the event and expose unavailable.
                                        return .unavailable
                                    }
                                }
                                await observerGate.hold()
                            }
                            let evidence = FoundationNativeEmptySessionEvidence()
                            if observerDrainFault == "native-work" {
                                evidence.observeTaskAllocationOrChallenge()
                            }

                            evidence.recordInventory(count: 0)
                            evidence.recordInvalidation(succeeded: true)
                            evidence.acknowledgeFinality()
                            return evidence.outcome
                        },
                        useModelBackgroundRouting: true, inspectSignOutIntent: { .pending },
                        accountTransactions: transactions, coldNativeRetirement: fakeRetirement)
                }
                let model = makeColdModel()
                if discoveryTraceInterleaving {
                    model.isolatedColdDiscoveryPhase = { phase in
                        switch phase {
                        case .willBegin:
                            discoveries += 1
                            if discoveries == 2 { await discoveryBeforeGate.hold() }
                        case .began:
                            if discoveries == 2 {
                                busyDiscoveryBegan = true
                                discoveryBegan.fulfill()
                            }
                        case .didRead:
                            if discoveries == 2 { await discoveryReadGate.hold() }
                        }
                    }
                    model.isolatedQuiescentProofSelected = { exactRetiredProof in
                        if exactRetiredProof && !firstSecureProofHeld {
                            firstSecureProofHeld = true
                            await secureProofGate.hold()
                        }
                    }
                    model.isolatedQuiescentMetadataChecked = { matches in
                        if !matches && busyDiscoveryBegan && !metadataRefusalHeld {
                            metadataRefusalHeld = true
                            await metadataRefusedGate.hold()
                        }
                    }
                }
                defer {
                    model.isolatedColdDiscoveryPhase = nil
                    model.isolatedQuiescentProofSelected = nil
                    model.isolatedQuiescentMetadataChecked = nil
                }
                if observerDrainFault != nil {
                    model.backgroundRoutingSettled = { selected in
                        if selected == identifier && quiescentObservations == 1 {
                            firstRoutingSettled.fulfill()
                        }
                    }
                }
                defer { model.backgroundRoutingSettled = nil }
                if statusTracking || staleStatusDelay {
                    model.isolatedColdStatusDelay = { await statusGate.hold() }
                }
                model.isolatedColdPublicationCheckpoint = checkpoint
                let firstFlightFinished = XCTestExpectation(
                    description: "interrupted cold flight finished")
                var firstFlightSucceeded: Bool?
                if checkpoint != nil || stopAfterRetire {
                    model.isolatedColdFlightFinished = { succeeded in
                        firstFlightSucceeded = succeeded
                        firstFlightFinished.fulfill()
                    }
                }
                let startup = Task { _ = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForTask(startup, label: "cold allocated startup")
                let completed = XCTestExpectation(description: "system completion")
                let finished = XCTestExpectation(description: "cold allocated cleanup finished")
                let observer = model.$accountInspectionIssue.dropFirst().filter { $0 == nil }
                    .first().sink { _ in finished.fulfill() }
                defer {
                    observer.cancel()
                    model.isolatedColdPublicationFinished = nil
                    model.isolatedColdFlightFinished = nil
                }
                var completions = 0
                if callbackAfterPublication {
                    model.isolatedColdPublicationFinished = { published in
                        guard published == identifier else { return }
                        if !quiescenceWithoutDrain {
                            model.finishBackgroundDownloadEvents(identifier)
                        }
                        model.receiveBackgroundDownloadEvents(identifier) {
                            completions += 1
                            completed.fulfill()
                        }
                    }
                }
                model.retryAccountInspection()
                try await waitForEvents([entered], label: "cold allocated task")
                XCTAssertTrue(model.isColdNativeRecovering)
                XCTAssertFalse(model.coldNativeTakingLonger)
                if staleStatusDelay {
                    try await waitForEvents([statusEntered], label: "held stale status delay")
                }
                if statusTracking {
                    try await waitForEvents([statusEntered], label: "cold status delay")
                    let delayed = XCTestExpectation(description: "cold delayed status")
                    let delayedObserver = model.$coldNativeTakingLonger.filter { $0 }.first().sink {
                        _ in delayed.fulfill()
                    }
                    defer { delayedObserver.cancel() }
                    model.retryAccountInspection()
                    XCTAssertEqual(retirements, 1)
                    statusGate.release()
                    try await waitForEvents([delayed], label: "cold delayed status")
                    XCTAssertTrue(model.isColdNativeRecovering)
                    XCTAssertTrue(model.coldNativeTakingLonger)
                }
                if !callbackAfterPublication && !cancelFlight && !staleMarker
                    && checkpoint == nil && !stopAfterRetire
                {
                    if !callbackBeforeDrain && !quiescenceWithoutDrain {
                        model.finishBackgroundDownloadEvents(identifier)
                    }
                    model.receiveBackgroundDownloadEvents(identifier) {
                        completions += 1
                        completed.fulfill()
                    }
                    if callbackBeforeDrain && !quiescenceWithoutDrain {
                        model.finishBackgroundDownloadEvents(identifier)
                    }
                }
                XCTAssertEqual(completions, 0)
                XCTAssertEqual(retirements, 1)
                XCTAssertNotNil(try FoundationSignOutIntentStore.load(operations: operations))
                XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
                if cancelFlight { model.isolatedCancelColdNativeFlight() }
                if staleMarker { keychain.readStatus = errSecInteractionNotAllowed }
                gate.release()
                if discoveryTraceInterleaving {
                    try await waitForEvents(
                        [discoveryBeforeEntered, secureProofEntered],
                        label: "actual retired proof read before second discovery busy fence")
                    discoveryBeforeGate.release()
                    try await waitForEvents([discoveryBegan], label: "second discovery busy fence")
                    secureProofGate.release()
                    try await waitForEvents(
                        [metadataRefusedEntered, discoveryReadEntered],
                        label:
                            "published replay refuses actual absent metadata while discovery busy")
                    XCTAssertEqual(completions, 0)
                    XCTAssertEqual(discoveries, 2)
                    let credentialBefore = keychain.credentialData
                    let receiptBefore = try Data(contentsOf: store.receiptURL)
                    let manifestBefore = try Data(
                        contentsOf: directory.appendingPathComponent("manifest.json"))
                    let discoveryEnded = XCTestExpectation(
                        description: "second discovery publishes while failed route held")
                    let discoveryObserver = model.$isCheckingPendingSignOut.dropFirst().filter {
                        !$0
                    }.first().sink {
                        _ in discoveryEnded.fulfill()
                    }
                    defer { discoveryObserver.cancel() }
                    discoveryReadGate.release()
                    try await waitForEvents(
                        [discoveryEnded], label: "actual discovery completion publication")
                    XCTAssertEqual(completions, 0)
                    XCTAssertEqual(quiescentObservations, 0)
                    XCTAssertEqual(keychain.credentialData, credentialBefore)
                    XCTAssertNotNil(keychain.payload)
                    XCTAssertEqual(try Data(contentsOf: store.receiptURL), receiptBefore)
                    XCTAssertEqual(
                        try Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                        manifestBefore)
                    metadataRefusedGate.release()
                    let completionResult = await XCTWaiter.fulfillment(
                        of: [completed, finished], timeout: 5)
                    XCTAssertEqual(
                        completionResult, .completed,
                        "Discovery completion must replay after the exact in-flight metadata refusal"
                    )
                    if completionResult == .completed {
                        XCTAssertEqual(completions, 1)
                        XCTAssertEqual(quiescentObservations, 1)
                        XCTAssertNil(keychain.credentialData)
                        XCTAssertNil(keychain.payload)
                    }
                    fixture.gate.release()
                    try await fixture.drain(using: self)
                    fixture.removeData()
                    return
                }
                if let observerDrainFault {
                    try await waitForEvents(
                        [firstRoutingSettled], label: "admitted but undrained metadata")
                    XCTAssertEqual(completions, 0)
                    guard completions == 0 else {
                        observerGate.release()
                        fixture.gate.release()
                        try await fixture.drain(using: self)
                        fixture.removeData()
                        return
                    }
                    // Publication can be consumed by an earlier admission-blocked
                    // route. Join that first attempt, then use the actual user
                    // Try Again action to rediscover and route this pending event.
                    try await fixture.drain(using: self)
                    XCTAssertFalse(model.isCheckingPendingSignOut)
                    XCTAssertFalse(model.isColdNativeRecovering)
                    XCTAssertEqual(quiescentObservations, 1)
                    let credentialBefore = keychain.credentialData
                    let receiptBefore = try Data(contentsOf: store.receiptURL)
                    let manifestBefore = try Data(
                        contentsOf: directory.appendingPathComponent("manifest.json"))
                    model.retryAccountInspection()
                    try await waitForEvents(
                        [observerEntered], label: "provisional observer drain after Try Again")
                    // This is the critical assertion: native final invalidation is
                    // still held, even if didFinishEvents was observed locally.
                    XCTAssertEqual(completions, 0)
                    guard completions == 0 else {
                        observerGate.release()
                        fixture.gate.release()
                        try await fixture.drain(using: self)
                        fixture.removeData()
                        return
                    }
                    XCTAssertEqual(keychain.credentialData, credentialBefore)
                    XCTAssertNotNil(keychain.payload)
                    if observerDrainFault == "current-changed" {
                        keychain.readStatus = errSecInteractionNotAllowed
                    }
                    let routing = try XCTUnwrap(model.isolatedBackgroundDownloadTask)
                    observerGate.release()
                    try await waitForTask(routing, label: "observer result refenced")
                    if observerDrainFault == "none" {
                        try await waitForEvents(
                            [completed, finished], label: "validated observer completion")
                        XCTAssertEqual(completions, 1)
                        XCTAssertNil(keychain.credentialData)
                        XCTAssertNil(keychain.payload)
                    } else {
                        XCTAssertEqual(completions, 0)
                        guard completions == 0 else {
                            keychain.readStatus = errSecSuccess
                            fixture.gate.release()
                            try await fixture.drain(using: self)
                            fixture.removeData()
                            return
                        }
                        XCTAssertEqual(keychain.credentialData, credentialBefore)
                        XCTAssertNotNil(keychain.payload)
                        XCTAssertEqual(try Data(contentsOf: store.receiptURL), receiptBefore)
                        XCTAssertEqual(
                            try Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                            manifestBefore)
                    }
                    XCTAssertEqual(quiescentObservations, 2)
                    keychain.readStatus = errSecSuccess
                    fixture.gate.release()
                    try await fixture.drain(using: self)
                    fixture.removeData()
                    return
                }
                if checkpoint != nil || stopAfterRetire {
                    try await waitForEvents([firstFlightFinished], label: "interrupted cold flight")
                    XCTAssertNotNil(try FoundationSignOutIntentStore.load(operations: operations))
                    XCTAssertNotNil(keychain.credentialData)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
                    let savedReceipt = try store.load()
                    let savedManifest = try FoundationDownloadStorage.load(directory: directory)
                    let expectedAuthorization = checkpoint != nil
                    let expectedEntry = checkpoint != .afterManifest
                    XCTAssertEqual(firstFlightSucceeded, false)
                    XCTAssertEqual(retirements, 1)
                    XCTAssertEqual(savedReceipt.retired, true)
                    XCTAssertEqual(
                        savedReceipt.coldSignOutProof?.manifestRemovalAuthorized,
                        expectedAuthorization)
                    XCTAssertEqual(savedManifest.files[track] != nil, expectedEntry)
                    guard try FoundationSignOutIntentStore.load(operations: operations) != nil,
                        keychain.credentialData != nil,
                        !FileManager.default.fileExists(atPath: packageURL.path),
                        firstFlightSucceeded == false, retirements == 1,
                        savedReceipt.retired == true,
                        savedReceipt.coldSignOutProof?.manifestRemovalAuthorized
                            == expectedAuthorization,
                        (savedManifest.files[track] != nil) == expectedEntry
                    else { throw CancellationError() }
                    let relaunched = makeColdModel()
                    let restarted = Task { _ = await relaunched.ensureReady() }
                    fixture.tasks.append(restarted)
                    try await waitForTask(restarted, label: "relaunch with pending sign-out")
                    let relaunchedFinished = XCTestExpectation(
                        description: "relaunched cold cleanup finished")
                    let relaunchedObserver = relaunched.$accountInspectionIssue.dropFirst().filter {
                        $0 == nil
                    }.first()
                        .sink { _ in relaunchedFinished.fulfill() }
                    defer { relaunchedObserver.cancel() }
                    relaunched.retryAccountInspection()
                    try await waitForEvents(
                        [relaunchedFinished], label: "relaunched allocated cleanup")
                    let marker = try FoundationSignOutIntentStore.load(operations: operations)
                    XCTAssertNil(marker)
                    XCTAssertNil(keychain.credentialData)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
                    XCTAssertEqual(try Data(contentsOf: otherSentinel), sentinelData)
                    guard marker == nil, keychain.credentialData == nil,
                        !FileManager.default.fileExists(atPath: directory.path),
                        (try? Data(contentsOf: otherSentinel)) == sentinelData
                    else { throw CancellationError() }
                    fixture.gate.release()
                    try await fixture.drain(using: self)
                    fixture.removeData()
                    return
                }
                if cancelFlight || staleMarker {
                    try await fixture.drain(using: self)
                    keychain.readStatus = errSecSuccess
                    let persisted = try FoundationSignOutIntentStore.load(operations: operations)
                    let currentReceipt = try store.load()
                    XCTAssertNotNil(persisted)
                    XCTAssertNotNil(keychain.credentialData)
                    XCTAssertNil(currentReceipt.coldSignOutProof)
                    XCTAssertFalse(model.isColdNativeRecovering)
                    XCTAssertFalse(model.coldNativeTakingLonger)
                    XCTAssertEqual(model.accountInspectionIssue, .pending)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
                    XCTAssertEqual(try Data(contentsOf: otherSentinel), sentinelData)
                    guard persisted != nil, keychain.credentialData != nil,
                        currentReceipt.coldSignOutProof == nil,
                        !model.isColdNativeRecovering, !model.coldNativeTakingLonger,
                        model.accountInspectionIssue == .pending,
                        FileManager.default.fileExists(atPath: packageURL.path),
                        (try? Data(contentsOf: otherSentinel)) == sentinelData
                    else { throw CancellationError() }
                    fixture.removeData()
                    return
                }
                try await waitForEvents(
                    [completed, finished], label: "cold allocated event and cleanup")
                XCTAssertEqual(completions, 1)
                if quiescenceWithoutDrain { XCTAssertEqual(quiescentObservations, 1) }
                XCTAssertEqual(retirements, 1)
                XCTAssertFalse(model.isColdNativeRecovering)
                XCTAssertFalse(model.coldNativeTakingLonger)
                XCTAssertNil(try FoundationSignOutIntentStore.load(operations: operations))
                XCTAssertNil(keychain.credentialData)
                XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
                XCTAssertEqual(try Data(contentsOf: otherSentinel), sentinelData)
                guard completions == 1, retirements == 1,
                    !model.isColdNativeRecovering, !model.coldNativeTakingLonger,
                    try FoundationSignOutIntentStore.load(operations: operations) == nil,
                    keychain.credentialData == nil,
                    !FileManager.default.fileExists(atPath: packageURL.path),
                    (try? Data(contentsOf: otherSentinel)) == sentinelData
                else { throw CancellationError() }
                fixture.gate.release()
                statusGate.release()
                try await fixture.drain(using: self)
                XCTAssertFalse(model.isColdNativeRecovering)
                XCTAssertFalse(model.coldNativeTakingLonger)
                guard !model.isColdNativeRecovering, !model.coldNativeTakingLonger
                else { throw CancellationError() }
                fixture.removeData()
            } catch {
                gate.release()
                discoveryBeforeGate.release()
                discoveryReadGate.release()
                secureProofGate.release()
                metadataRefusedGate.release()
                observerGate.release()
                statusGate.release()
                fixture.gate.release()
                do { try await fixture.drain(using: self) } catch {
                    XCTFail("Could not drain cold native fixture; data retained")
                }
                throw error
            }
        }

        func testColdTerminalRetirementWithPendingManifestEntry() async throws {
            try await exerciseColdTerminalRetirement(pendingEntry: true)
        }

        func testColdTerminalRetirementWithoutPendingManifestEntry() async throws {
            try await exerciseColdTerminalRetirement(pendingEntry: false)
        }

        func testColdTerminalWithoutFinalityRemainsPending() async throws {
            try await exerciseColdTerminalRetirement(pendingEntry: false, failFinality: true)
        }

        func testColdTerminalRelaunchAfterManifestAuthorization() async throws {
            try await exerciseColdTerminalRetirement(
                pendingEntry: true, checkpoint: .afterAuthorization)
        }

        func testColdTerminalRelaunchAfterManifestPublication() async throws {
            try await exerciseColdTerminalRetirement(pendingEntry: true, checkpoint: .afterManifest)
        }

        func testColdTerminalSignOutCompletesQuiescentEventWithoutDrain() async throws {
            try await exerciseColdTerminalRetirement(
                pendingEntry: true, quiescenceWithoutDrain: true)
        }

        func testColdTerminalRetirementHandlesDrainBeforeCallback() async throws {
            try await exerciseColdTerminalRetirement(pendingEntry: false, drainBeforeCallback: true)
        }

        private func exerciseColdTerminalRetirement(
            pendingEntry: Bool, failFinality: Bool = false,
            checkpoint: FoundationScopedAccountRemoval.ColdPublicationCheckpoint? = nil,
            drainBeforeCallback: Bool = false, quiescenceWithoutDrain: Bool = false
        ) async throws {
            let entered = expectation(description: "cold terminal reconnection entered")
            let gate = LifecycleGate(entered: entered)
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            defer {
                gate.release()
                fixture.gate.release()
            }
            do {
                let keychain = IntentKeychainFixture()
                let session = fixture.session(user: "00000000000000000000000000000001")
                keychain.credentialData = try JSONEncoder().encode(session)
                let operations = keychain.operations()
                let root = fixture.root.appendingPathComponent("transaction", isDirectory: true)
                let snapshot = try FoundationAccountCredentialTransaction.inspect(
                    root: root, operations: operations)
                let intent = try FoundationAccountCredentialTransaction.prepareSignOut(
                    session, expecting: snapshot, root: root, operations: operations)
                let transactions = FoundationAccountTransactions(
                    inspect: {
                        try FoundationAccountCredentialTransaction.inspect(
                            root: root, operations: operations)
                    },
                    prepareSignOut: { value, expected, preparation in
                        try FoundationAccountCredentialTransaction.prepareSignOut(
                            value, expecting: expected, preparation: preparation, root: root,
                            operations: operations)
                    },
                    finishCompletedSignOut: { marker in
                        try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                            marker, root: root, operations: operations)
                    },
                    recordSignOut: { value, marker, expected in
                        try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                            value, intent: marker, expecting: expected, root: root,
                            operations: operations)
                    })
                let directory = FoundationDownloadStorage.directory(
                    scope: intent.scope, root: fixture.storage.downloads)
                let other = FoundationDownloadStorage.directory(
                    scope: String(repeating: "b", count: 64), root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(directory)
                try FoundationDownloadStorage.prepare(other)
                let otherSentinel = other.appendingPathComponent("other-account")
                let sentinelData = Data("untouched".utf8)
                try sentinelData.write(to: otherSentinel)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
                    + UUID().uuidString
                let store = FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: identifier)
                try store.reserve()
                try store.beginCreating()
                try store.bindCreatedTask(taskIdentifier: 1)
                try store.recordTerminalNoAllocation(taskIdentifier: 1)
                // Historical tombstone does not imply this operation's finality.
                try store.retire()
                var manifest = FoundationDownloadManifest()
                if pendingEntry { manifest.nativePendingSessions = [identifier] }
                try FoundationDownloadStorage.save(manifest, directory: directory)
                var retirements = 0
                let fake:
                    @MainActor (
                        FoundationNativeAllocationStore, UUID,
                        FoundationScopedAccountRemoval.ColdTerminalCandidate,
                        @escaping @MainActor @Sendable () async -> Bool
                    ) async -> Bool = { selected, operation, candidate, verify in
                        retirements += 1
                        await gate.hold()
                        guard !Task.isCancelled, await verify(), !failFinality,
                            selected.directory == directory,
                            selected.sessionIdentifier == identifier,
                            candidate.taskIdentifier == 1, operation == intent.operation
                        else { return false }
                        do {
                            try selected.recordColdTerminalFinality(operation: operation)
                            try selected.retire()
                            return true
                        } catch { return false }
                    }
                func makeModel() -> FoundationAppModel {
                    fixture.makeModel(
                        useModelBackgroundRouting: true, inspectSignOutIntent: { .pending },
                        accountTransactions: transactions, coldTerminalRetirement: fake)
                }
                let model = makeModel()
                model.isolatedColdPublicationCheckpoint = checkpoint
                let flightFinished = XCTestExpectation(description: "cold terminal flight finished")
                var flightSucceeded: Bool?
                if failFinality || checkpoint != nil {
                    model.isolatedColdFlightFinished = { result in
                        flightSucceeded = result
                        flightFinished.fulfill()
                    }
                }
                defer { model.isolatedColdFlightFinished = nil }
                let startup = Task { _ = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForTask(startup, label: "cold terminal startup")
                let finished = XCTestExpectation(description: "terminal cleanup completed")
                let observation = model.$accountInspectionIssue.dropFirst().filter { $0 == nil }
                    .first()
                    .sink { _ in finished.fulfill() }
                defer { observation.cancel() }
                model.retryAccountInspection()
                try await waitForEvents([entered], label: "terminal session reconnection")
                XCTAssertEqual(retirements, 1)
                XCTAssertNotNil(try FoundationSignOutIntentStore.load(operations: operations))
                XCTAssertNil(try store.load().coldSignOutProof)
                let completion = XCTestExpectation(description: "terminal UIKit completion")
                var completions = 0
                if !failFinality && checkpoint == nil {
                    if drainBeforeCallback { model.finishBackgroundDownloadEvents(identifier) }
                    model.receiveBackgroundDownloadEvents(identifier) {
                        completions += 1
                        completion.fulfill()
                    }
                    if !drainBeforeCallback { model.finishBackgroundDownloadEvents(identifier) }
                }
                gate.release()
                if failFinality || checkpoint != nil {
                    try await waitForEvents([flightFinished], label: "terminal pending flight")
                    XCTAssertEqual(flightSucceeded, false)
                    XCTAssertEqual(retirements, 1)
                    XCTAssertNotNil(try FoundationSignOutIntentStore.load(operations: operations))
                    XCTAssertNotNil(keychain.credentialData)
                    let savedReceipt = try store.load()
                    if failFinality {
                        XCTAssertNil(savedReceipt.coldSignOutProof)
                        guard savedReceipt.coldSignOutProof == nil, keychain.credentialData != nil,
                            try FoundationSignOutIntentStore.load(operations: operations) != nil
                        else { throw CancellationError() }
                        fixture.gate.release()
                        try await fixture.drain(using: self)
                        fixture.removeData()
                        return
                    }
                    let savedManifest = try FoundationDownloadStorage.load(directory: directory)
                    XCTAssertEqual(savedReceipt.coldSignOutProof?.manifestRemovalAuthorized, true)
                    XCTAssertEqual(
                        savedManifest.nativePendingSessions?.contains(identifier) == true,
                        checkpoint == .afterAuthorization)
                    guard savedReceipt.coldSignOutProof?.manifestRemovalAuthorized == true,
                        (savedManifest.nativePendingSessions?.contains(identifier) == true)
                            == (checkpoint == .afterAuthorization)
                    else { throw CancellationError() }
                    let relaunched = makeModel()
                    let restart = Task { _ = await relaunched.ensureReady() }
                    fixture.tasks.append(restart)
                    try await waitForTask(restart, label: "terminal relaunch startup")
                    let restartedFinished = XCTestExpectation(
                        description: "terminal relaunch finished")
                    let restartedObservation = relaunched.$accountInspectionIssue.dropFirst().filter
                    { $0 == nil }.first()
                        .sink { _ in restartedFinished.fulfill() }
                    defer { restartedObservation.cancel() }
                    relaunched.retryAccountInspection()
                    try await waitForEvents([restartedFinished], label: "terminal relaunch cleanup")
                    XCTAssertEqual(retirements, 1)
                } else {
                    try await waitForEvents(
                        [completion, finished], label: "terminal event and cleanup")
                    XCTAssertEqual(completions, 1)
                }
                let marker = try FoundationSignOutIntentStore.load(operations: operations)
                XCTAssertNil(marker)
                XCTAssertNil(keychain.credentialData)
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
                XCTAssertEqual(try Data(contentsOf: otherSentinel), sentinelData)
                guard marker == nil, keychain.credentialData == nil,
                    !FileManager.default.fileExists(atPath: directory.path),
                    (try? Data(contentsOf: otherSentinel)) == sentinelData
                else { throw CancellationError() }
                fixture.gate.release()
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                gate.release()
                fixture.gate.release()
                do { try await fixture.drain(using: self) } catch {
                    XCTFail("Could not drain terminal fixture; data retained")
                }
                throw error
            }
        }

        func testColdTerminalProofRejectsWrongOperationAndTask() async throws {
            try await withLifecycleFixture { fixture, _ in
                let directory = fixture.storage.downloads.appendingPathComponent(
                    String(repeating: "a", count: 64), isDirectory: true)
                try FoundationDownloadStorage.prepare(directory)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                    + "." + UUID().uuidString
                let store = FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: identifier)
                try store.reserve()
                try store.beginCreating()
                try store.bindCreatedTask(taskIdentifier: 1)
                try store.recordTerminalNoAllocation(taskIdentifier: 1)
                let operation = UUID()
                try store.recordColdTerminalFinality(operation: operation)
                XCTAssertTrue(try store.coldTerminalFinalityMatches(operation: operation))
                XCTAssertFalse(try store.coldTerminalFinalityMatches(operation: UUID()))
                let saved = try store.load()
                var changed = FoundationNativeAllocationStore.Receipt(
                    scope: saved.scope, sessionIdentifier: saved.sessionIdentifier,
                    taskIdentifier: 2)
                changed.trackID = saved.trackID
                changed.phase = .terminalNoAllocation
                changed.creationVersion = 1
                changed.coldSignOutProof = saved.coldSignOutProof
                try JSONEncoder().encode(changed).write(to: store.receiptURL)
                XCTAssertFalse(try store.coldTerminalFinalityMatches(operation: operation))
                guard !(try store.coldTerminalFinalityMatches(operation: operation))
                else { throw CancellationError() }
            }
        }

        func testColdPendingSignOutRejectsMismatchedSessionWithoutMutation() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            let keychain = IntentKeychainFixture()
            let original = fixture.session(user: "00000000000000000000000000000001")
            keychain.credentialData = try JSONEncoder().encode(original)
            let operations = keychain.operations()
            let root = fixture.root.appendingPathComponent("transaction", isDirectory: true)
            let before = try FoundationAccountCredentialTransaction.inspect(
                root: root, operations: operations)
            let intent = try FoundationAccountCredentialTransaction.prepareSignOut(
                original, expecting: before, root: root, operations: operations)
            let wrong = fixture.session(user: "00000000000000000000000000000002")
            let mismatched = FoundationAccountCredentialTransaction.Snapshot(
                intent: intent, session: wrong, accessGroup: intent.accessGroup,
                credentialGeneration: intent.credentialGeneration)
            var finalizations = 0
            let transactions = FoundationAccountTransactions(
                inspect: { mismatched },
                prepareSignOut: { _, _, _ in intent },
                finishCompletedSignOut: { _ in finalizations += 1 },
                recordSignOut: { _, marker, _ in marker })
            let model = fixture.makeModel(
                inspectSignOutIntent: { .pending }, accountTransactions: transactions)
            let directory = FoundationDownloadStorage.directory(
                scope: intent.scope, root: fixture.storage.downloads)
            try FoundationDownloadStorage.prepare(directory)
            let sentinel = directory.appendingPathComponent("sentinel")
            try Data("keep".utf8).write(to: sentinel)
            fixture.defaults.set(
                Data("pins".utf8), forKey: FoundationPinStorage.key(for: intent.scope))
            var readiness: FoundationAppModel.Readiness?
            let startup = Task { readiness = await model.ensureReady() }
            fixture.tasks.append(startup)
            try await waitForTask(startup, label: "mismatched intent startup")
            XCTAssertEqual(readiness, .unavailable)
            let finished = expectation(description: "mismatched recovery refused")
            let observer = model.$isCheckingPendingSignOut.dropFirst().filter { !$0 }.first().sink {
                _ in
                finished.fulfill()
            }
            defer {
                observer.cancel()
                fixture.gate.release()
            }
            model.retryAccountInspection()
            try await waitForEvents([finished], label: "mismatched recovery")
            let retained = try Data(contentsOf: sentinel)
            let pins = fixture.defaults.data(forKey: FoundationPinStorage.key(for: intent.scope))
            XCTAssertEqual(retained, Data("keep".utf8))
            XCTAssertEqual(pins, Data("pins".utf8))
            XCTAssertEqual(finalizations, 0)
            XCTAssertNotNil(keychain.credentialData)
            XCTAssertEqual(model.accountInspectionIssue, .pending)
            guard retained == Data("keep".utf8), pins == Data("pins".utf8),
                finalizations == 0, keychain.credentialData != nil,
                model.accountInspectionIssue == .pending
            else { throw CancellationError() }
            try await fixture.drain(using: self)
            fixture.removeData()
        }
        func testColdAllocatedRecoveryRequiresSavedCredential() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            let keychain = IntentKeychainFixture()
            let original = fixture.session(user: "00000000000000000000000000000001")
            keychain.credentialData = try JSONEncoder().encode(original)
            let operations = keychain.operations()
            let root = fixture.root.appendingPathComponent("transaction", isDirectory: true)
            let before = try FoundationAccountCredentialTransaction.inspect(
                root: root, operations: operations)
            let intent = try FoundationAccountCredentialTransaction.prepareSignOut(
                original, expecting: before, root: root, operations: operations)
            let mismatched = FoundationAccountCredentialTransaction.Snapshot(
                intent: intent, session: nil, accessGroup: intent.accessGroup,
                credentialGeneration: intent.credentialGeneration)
            var finalizations = 0
            let transactions = FoundationAccountTransactions(
                inspect: { mismatched },
                prepareSignOut: { _, _, _ in intent },
                finishCompletedSignOut: { _ in finalizations += 1 },
                recordSignOut: { _, marker, _ in marker })
            var retirements = 0
            let model = fixture.makeModel(
                inspectSignOutIntent: { .pending }, accountTransactions: transactions,
                coldNativeRetirement: { _, _, _, _ in
                    retirements += 1
                    return false
                })
            let directory = FoundationDownloadStorage.directory(
                scope: intent.scope, root: fixture.storage.downloads)
            try FoundationDownloadStorage.prepare(directory)
            let identifier =
                "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
                + UUID().uuidString
            let track = "synthetic-track"
            let package = FoundationNativeDownloadPackage(
                nativeURL: fixture.root.appendingPathComponent("synthetic.movpkg"),
                bookmark: Data("bookmark".utf8),
                sessionIdentifier: identifier, namespaceBookmark: Data("namespace".utf8))
            let store = FoundationNativeAllocationStore(
                directory: directory, sessionIdentifier: identifier)
            var receipt = FoundationNativeAllocationStore.Receipt(
                scope: directory.lastPathComponent, sessionIdentifier: identifier, taskIdentifier: 1
            )
            receipt.trackID = track
            receipt.nativeURL = package.nativeURL
            receipt.phase = .allocated
            receipt.creationVersion = 1
            receipt.namespaceBookmark = package.namespaceBookmark
            receipt.package = package
            receipt.completionAttempted = true
            try JSONEncoder().encode(receipt).write(to: store.receiptURL)
            var manifest = FoundationDownloadManifest()
            manifest.files[track] = .init(
                name: "synthetic.movpkg", bytes: 1, digest: "", nativePackage: package)
            try FoundationDownloadStorage.save(manifest, directory: directory)
            let savedReceipt = try Data(contentsOf: store.receiptURL)
            let sentinel = directory.appendingPathComponent("sentinel")
            try Data("keep".utf8).write(to: sentinel)
            fixture.defaults.set(
                Data("pins".utf8), forKey: FoundationPinStorage.key(for: intent.scope))
            var readiness: FoundationAppModel.Readiness?
            let startup = Task { readiness = await model.ensureReady() }
            fixture.tasks.append(startup)
            try await waitForTask(startup, label: "mismatched intent startup")
            XCTAssertEqual(readiness, .unavailable)
            let finished = expectation(description: "mismatched recovery refused")
            let observer = model.$isCheckingPendingSignOut.dropFirst().filter { !$0 }.first().sink {
                _ in
                finished.fulfill()
            }
            defer {
                observer.cancel()
                fixture.gate.release()
            }
            model.retryAccountInspection()
            try await waitForEvents([finished], label: "mismatched recovery")
            let retained = try Data(contentsOf: sentinel)
            let pins = fixture.defaults.data(forKey: FoundationPinStorage.key(for: intent.scope))
            XCTAssertEqual(retained, Data("keep".utf8))
            XCTAssertEqual(pins, Data("pins".utf8))
            XCTAssertEqual(finalizations, 0)
            XCTAssertEqual(retirements, 0)
            XCTAssertEqual(try Data(contentsOf: store.receiptURL), savedReceipt)
            XCTAssertNotNil(keychain.credentialData)
            XCTAssertEqual(model.accountInspectionIssue, .pending)
            guard retained == Data("keep".utf8), pins == Data("pins".utf8),
                finalizations == 0, retirements == 0,
                (try? Data(contentsOf: store.receiptURL)) == savedReceipt,
                keychain.credentialData != nil,
                model.accountInspectionIssue == .pending
            else { throw CancellationError() }
            try await fixture.drain(using: self)
            fixture.removeData()
        }
        func testOrdinaryDownloadCleanupRejectsOpaqueNativeManifest() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            let scope = String(repeating: "a", count: 64)
            let directory = fixture.storage.downloads.appendingPathComponent(
                scope, isDirectory: true)
            try FoundationDownloadStorage.prepare(directory)
            let package = FoundationNativeDownloadPackage(
                nativeURL: fixture.root.appendingPathComponent("synthetic.movpkg"),
                bookmark: Data("synthetic".utf8), sessionIdentifier: "synthetic")
            var manifest = FoundationDownloadManifest()
            manifest.files["track"] = .init(
                name: "ordinary.bin", bytes: 1, digest: "", nativePackage: package)
            try FoundationDownloadStorage.save(manifest, directory: directory)
            let sentinel = directory.appendingPathComponent("ordinary.bin")
            try Data([42]).write(to: sentinel)
            var removed = true
            let task = Task {
                removed = await FoundationScopedAccountRemoval.removeAsync(
                    root: fixture.storage.downloads, scope: scope,
                    requireOrdinaryDownloadManifest: true)
            }
            fixture.tasks.append(task)
            try await waitForTask(task, label: "native manifest preflight")
            XCTAssertFalse(removed)
            XCTAssertEqual(try Data(contentsOf: sentinel), Data([42]))
            guard !removed, try Data(contentsOf: sentinel) == Data([42]) else {
                throw CancellationError()
            }
            fixture.removeData()
        }

        func testSignOutCommitReservationRetainsEventDuringAsyncCommit() async throws {
            let lane = FoundationSignOutCommitLane()
            let oldScope = String(repeating: "a", count: 64)
            let newScope = String(repeating: "b", count: 64)
            var completions = 0
            let earlier = lane.register(identifier: "earlier-old-session", scope: oldScope) {
                completions += 1
            }
            var blockedBeforeCommit = false
            do { _ = try await lane.beginCommit() } catch FoundationSignOutCommitLane.LaneError
                .pending
            { blockedBeforeCommit = true }
            XCTAssertTrue(blockedBeforeCommit)
            XCTAssertEqual(completions, 0)
            let earlierResolved = await lane.resolve(earlier, scope: oldScope)
            XCTAssertTrue(earlierResolved)
            XCTAssertEqual(completions, 1)
            let commitToken = try await lane.beginCommit()
            let eventToken = lane.register(identifier: "old-session", scope: oldScope) {
                completions += 1
            }
            let result = await lane.endCommit(commitToken)
            let queued = try XCTUnwrap(result)
            XCTAssertEqual(queued.count, 1)
            XCTAssertEqual(queued.first?.scope, oldScope)
            XCTAssertEqual(queued.first?.identifier, "old-session")
            XCTAssertEqual(completions, 1)
            var blocked = false
            do { _ = try await lane.beginCommit() } catch FoundationSignOutCommitLane.LaneError
                .pending
            { blocked = true }
            XCTAssertTrue(blocked)
            let wrong = await lane.resolve(eventToken, scope: newScope)
            XCTAssertFalse(wrong)
            XCTAssertEqual(completions, 1)
            let correct = await lane.resolve(eventToken, scope: oldScope)
            XCTAssertTrue(correct)
            XCTAssertEqual(completions, 2)
            let retry = try await lane.beginCommit()
            let remaining = await lane.endCommit(retry)
            XCTAssertEqual(remaining, [])
        }

        func testMarkerFirstCommitRetainsLateOldScopeEventUntilReconciled() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "synthetic revocation entered"))
            let keychain = IntentKeychainFixture()
            let session = fixture.session(user: "00000000000000000000000000000001")
            keychain.credentialData = try JSONEncoder().encode(session)
            let operations = keychain.operations()
            let root = fixture.root.appendingPathComponent("transaction", isDirectory: true)
            let commitEntered = expectation(description: "credential phase entered")
            let routeEntered = expectation(description: "old-scope route entered")
            let commitGate = LifecycleGate(entered: commitEntered)
            let routeGate = LifecycleGate(entered: routeEntered)
            let transactions = FoundationAccountTransactions(
                inspect: {
                    try FoundationAccountCredentialTransaction.inspect(
                        root: root, operations: operations)
                },
                prepareSignOut: { value, expected, preparation in
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        value, expecting: expected, preparation: preparation, root: root,
                        operations: operations)
                },
                finishCompletedSignOut: { marker in
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        marker, root: root, operations: operations)
                },
                recordSignOut: { value, marker, expected in
                    await commitGate.hold()
                    return try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                        value, intent: marker, expecting: expected, root: root,
                        operations: operations)
                })
            var completions = 0
            let model = fixture.makeModel(
                backgroundReconcile: { _ in
                    await routeGate.hold()
                    return true
                },
                useModelBackgroundRouting: true,
                inspectSignOutIntent: {
                    do {
                        return try FoundationSignOutIntentStore.load(operations: operations) == nil
                            ? .absent : .pending
                    } catch { return .unavailable }
                }, accountTransactions: transactions)
            do {
                let startup = Task { _ = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForTask(startup, label: "late-event startup")
                try await fixture.open(model, user: session.userID)
                let player = try XCTUnwrap(model.player)
                let finishedAttempt = expectation(description: "credential phase paused on event")
                let attemptObservation = model.$isFinalizingDurableSignOut.dropFirst().filter {
                    !$0
                }.first().sink { _ in
                    finishedAttempt.fulfill()
                }
                defer { attemptObservation.cancel() }
                model.signOut()
                fixture.captureStop(player)
                try await waitForEvents([commitEntered], label: "held credential phase")
                let scope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                    + "." + UUID().uuidString
                let acknowledged = expectation(description: "old-scope completion")
                model.receiveBackgroundDownloadEvents(identifier) {
                    completions += 1
                    acknowledged.fulfill()
                }
                model.finishBackgroundDownloadEvents(identifier)
                try await waitForEvents([routeEntered], label: "held old-scope route")
                commitGate.release()
                try await waitForEvents([finishedAttempt], label: "pending credential phase")
                let pending = try FoundationSignOutIntentStore.load(operations: operations)
                XCTAssertEqual(pending?.cleanupComplete, true)
                XCTAssertEqual(completions, 0)
                XCTAssertEqual(model.accountInspectionIssue, .pending)
                guard pending?.cleanupComplete == true, completions == 0,
                    model.accountInspectionIssue == .pending
                else { throw CancellationError() }
                let finished = expectation(description: "sign-out finalization")
                let observation = model.$accountInspectionIssue.dropFirst().filter { $0 == nil }
                    .first().sink { _ in
                        finished.fulfill()
                    }
                defer { observation.cancel() }
                // This fake route models reconciliation; it does not prove real native finality.
                routeGate.release()
                try await waitForEvents(
                    [acknowledged, finished], label: "old-scope completion and finalization")
                XCTAssertEqual(completions, 1)
                XCTAssertNil(try FoundationSignOutIntentStore.load(operations: operations))
                fixture.gate.release()
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                commitGate.release()
                routeGate.release()
                fixture.gate.release()
                do { try await fixture.drain(using: self) } catch {
                    XCTFail("Could not drain late-event fixture; data retained")
                }
                throw error
            }
        }

        func testColdPendingSignOutBindsEarlierExactEventBeforeCleanup() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            let keychain = IntentKeychainFixture()
            let session = fixture.session(user: "00000000000000000000000000000001")
            keychain.credentialData = try JSONEncoder().encode(session)
            let operations = keychain.operations()
            let root = fixture.root.appendingPathComponent("transaction", isDirectory: true)
            let before = try FoundationAccountCredentialTransaction.inspect(
                root: root, operations: operations)
            let intent = try FoundationAccountCredentialTransaction.prepareSignOut(
                session, expecting: before, root: root, operations: operations)
            let transactions = FoundationAccountTransactions(
                inspect: {
                    try FoundationAccountCredentialTransaction.inspect(
                        root: root, operations: operations)
                },
                prepareSignOut: { value, expected, preparation in
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        value, expecting: expected, preparation: preparation, root: root,
                        operations: operations)
                },
                finishCompletedSignOut: { marker in
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        marker, root: root, operations: operations)
                },
                recordSignOut: { value, marker, expected in
                    try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                        value, intent: marker, expecting: expected, root: root,
                        operations: operations)
                })
            var routes = 0
            var completions = 0
            let model = fixture.makeModel(
                backgroundReconcile: { _ in
                    routes += 1
                    return true
                },
                useModelBackgroundRouting: true,
                inspectSignOutIntent: { .pending }, accountTransactions: transactions)
            let cleanupEntered = expectation(description: "cold cleanup held before mutation")
            let cleanupGate = LifecycleGate(entered: cleanupEntered)
            model.isolatedBeforeColdCleanup = { await cleanupGate.hold() }
            defer {
                cleanupGate.release()
                fixture.gate.release()
                model.isolatedBeforeColdCleanup = nil
            }
            do {
                let directory = FoundationDownloadStorage.directory(
                    scope: intent.scope, root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(directory)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                    + "." + UUID().uuidString
                let receipt = FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: identifier)
                try receipt.reserve()
                var manifest = FoundationDownloadManifest()
                manifest.nativePendingSessions = [identifier]
                try FoundationDownloadStorage.save(manifest, directory: directory)
                let acknowledged = expectation(description: "old-scope event acknowledged")
                model.receiveBackgroundDownloadEvents(identifier) {
                    completions += 1
                    acknowledged.fulfill()
                }
                model.finishBackgroundDownloadEvents(identifier)
                var readiness: FoundationAppModel.Readiness?
                let startup = Task { readiness = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForTask(startup, label: "cold pending event startup")
                XCTAssertEqual(readiness, .unavailable)
                XCTAssertEqual(routes, 0)
                XCTAssertEqual(completions, 0)
                model.retryAccountInspection()
                try await waitForEvents(
                    [acknowledged, cleanupEntered], label: "old-scope routing and held cleanup")
                XCTAssertEqual(routes, 1)
                XCTAssertEqual(completions, 1)
                XCTAssertNotNil(try FoundationSignOutIntentStore.load(operations: operations))
                XCTAssertNotNil(keychain.credentialData)
                XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.receiptURL.path))
                guard routes == 1, completions == 1, keychain.credentialData != nil,
                    try FoundationSignOutIntentStore.load(operations: operations) != nil,
                    FileManager.default.fileExists(atPath: receipt.receiptURL.path)
                else { throw CancellationError() }
                let finished = XCTestExpectation(description: "cold cleanup finalized")
                let observation = model.$accountInspectionIssue.dropFirst().filter { $0 == nil }
                    .first()
                    .sink { _ in finished.fulfill() }
                defer { observation.cancel() }
                cleanupGate.release()
                try await waitForEvents([finished], label: "cold cleanup after event")
                XCTAssertNil(try FoundationSignOutIntentStore.load(operations: operations))
                XCTAssertNil(keychain.credentialData)
                XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.receiptURL.path))
                guard try FoundationSignOutIntentStore.load(operations: operations) == nil,
                    keychain.credentialData == nil,
                    !FileManager.default.fileExists(atPath: receipt.receiptURL.path)
                else { throw CancellationError() }
                fixture.gate.release()
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                cleanupGate.release()
                fixture.gate.release()
                do { try await fixture.drain(using: self) } catch {
                    XCTFail("Could not drain cold-event fixture; data retained")
                }
                throw error
            }
        }

        #if DEBUG
            func testRestoredOwnerRetriesExactBackgroundReceiptAfterInventoryRetiresIt()
                async throws
            {
                let entered = expectation(description: "restored native inventory entered")
                let gate = LifecycleGate(entered: entered)
                defer { gate.release() }
                try await withLifecycleFixture(
                    leaseWaitStarted: {},
                    nativeRetirement: { identifiers, directory in
                        await gate.hold()
                        var retired: Set<String> = []
                        for identifier in identifiers {
                            do {
                                try FoundationNativeAllocationStore(
                                    directory: directory, sessionIdentifier: identifier
                                ).retire()
                                retired.insert(identifier)
                            } catch {}
                        }
                        return retired
                    }, useModelBackgroundRouting: true,
                    { fixture, model in
                        defer { gate.release() }
                        let session = fixture.session(user: "00000000000000000000000000000001")
                        let accept = try await model.prepareSignIn { session }
                        let scope = FoundationMusicLibraryStore.digest(
                            "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                        let directory = FoundationDownloadStorage.directory(
                            scope: scope, root: fixture.storage.downloads)
                        try FoundationDownloadStorage.prepare(directory)
                        let identifier =
                            "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                            + "." + UUID().uuidString
                        let receipt = FoundationNativeAllocationStore(
                            directory: directory, sessionIdentifier: identifier)
                        try receipt.reserve()
                        var manifest = FoundationDownloadManifest()
                        manifest.nativePendingSessions = [identifier]
                        try FoundationDownloadStorage.save(manifest, directory: directory)
                        try await accept()
                        try await self.waitForEvents([entered], label: "held restored inventory")
                        let initial = self.expectation(
                            description: "initial background route settled")
                        let completed = self.expectation(
                            description: "restored background event completed")
                        model.backgroundRoutingSettled = { _ in initial.fulfill() }
                        defer { model.backgroundRoutingSettled = nil }
                        var completions = 0
                        model.receiveBackgroundDownloadEvents(identifier) {
                            completions += 1
                            completed.fulfill()
                        }
                        model.finishBackgroundDownloadEvents(identifier)
                        try await self.waitForEvents([initial], label: "initial restored route")
                        model.backgroundRoutingSettled = nil
                        XCTAssertEqual(completions, 0)
                        XCTAssertTrue(
                            try FoundationDownloadStorage.load(directory: directory)
                                .nativePendingSessions?.contains(identifier) == true)
                        gate.release()
                        try await self.waitForEvents([completed], label: "proven restored route")
                        let remaining =
                            try FoundationDownloadStorage.load(directory: directory)
                            .nativePendingSessions?.contains(identifier) == true
                        let proven = try receipt.load().hasProvenRetirement
                        XCTAssertEqual(completions, 1)
                        XCTAssertFalse(remaining)
                        XCTAssertTrue(proven)
                        guard completions == 1, !remaining, proven else {
                            throw CancellationError()
                        }
                    })
            }
        #endif

        func testNoFactoryReceiptCleanupResumesAfterEachPersistenceCheckpoint() async throws {
            for afterManifest in [false, true] {
                let fixture = try LifecycleFixture(
                    entered: XCTestExpectation(description: "unused revocation"))
                let scope = String(repeating: "a", count: 64)
                let otherScope = String(repeating: "b", count: 64)
                let directory = fixture.storage.downloads.appendingPathComponent(
                    scope, isDirectory: true)
                let other = fixture.storage.downloads.appendingPathComponent(
                    otherScope, isDirectory: true)
                try FoundationDownloadStorage.prepare(directory)
                try FoundationDownloadStorage.prepare(other)
                let sentinel = other.appendingPathComponent("sentinel")
                let sentinelData = Data("other account".utf8)
                try sentinelData.write(to: sentinel)
                var identifiers: Set<String> = []
                for _ in 0..<2 {
                    let identifier =
                        "dev.novoluxor.velacanto.offline." + scope + "." + UUID().uuidString
                    try FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier
                    ).reserve()
                    identifiers.insert(identifier)
                }
                var manifest = FoundationDownloadManifest()
                manifest.nativePendingSessions = identifiers
                try FoundationDownloadStorage.save(manifest, directory: directory)
                let interrupted = FoundationScopedAccountRemoval.isolatedRemoveNoFactory(
                    root: fixture.storage.downloads, scope: scope, requiredSessions: identifiers,
                    stopAfterFirstTombstone: !afterManifest, stopAfterManifest: afterManifest)
                XCTAssertFalse(interrupted.removed)
                let saved = try FoundationDownloadStorage.load(directory: directory)
                let tombstoneCount = try identifiers.filter {
                    try FoundationNativeAllocationStore(directory: directory, sessionIdentifier: $0)
                        .load().hasProvenRetirement
                }.count
                if afterManifest {
                    XCTAssertEqual(saved.nativePendingSessions ?? [], [])
                    XCTAssertEqual(tombstoneCount, 2)
                } else {
                    XCTAssertEqual(saved.nativePendingSessions, identifiers)
                    XCTAssertEqual(tombstoneCount, 1)
                }
                guard !interrupted.removed,
                    afterManifest
                        ? (saved.nativePendingSessions?.isEmpty == true && tombstoneCount == 2)
                        : (saved.nativePendingSessions == identifiers && tombstoneCount == 1)
                else { throw CancellationError() }
                var removed = false
                let retry = Task {
                    let outcome = await FoundationScopedAccountRemoval.removeNoFactoryAsync(
                        root: fixture.storage.downloads, scope: scope, requiredSessions: identifiers
                    )
                    removed = outcome.removed
                }
                fixture.tasks.append(retry)
                try await waitForTask(retry, label: "interrupted no-factory cleanup retry")
                let otherData = try Data(contentsOf: sentinel)
                XCTAssertTrue(removed)
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
                XCTAssertEqual(otherData, sentinelData)
                guard removed, !FileManager.default.fileExists(atPath: directory.path),
                    otherData == sentinelData
                else { throw CancellationError() }
                try await fixture.drain(using: self)
                fixture.removeData()
            }
        }

        func testNoFactoryReceiptCleanupRejectsLegacyCreatingAndUnknownStage() async throws {
            for mode in 0..<3 {
                let fixture = try LifecycleFixture(
                    entered: XCTestExpectation(description: "unused revocation"))
                let scope = String(repeating: "a", count: 64)
                let directory = fixture.storage.downloads.appendingPathComponent(
                    scope, isDirectory: true)
                try FoundationDownloadStorage.prepare(directory)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + scope + "." + UUID().uuidString
                let store = FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: identifier)
                var receipt = FoundationNativeAllocationStore.Receipt(
                    scope: scope, sessionIdentifier: identifier, taskIdentifier: 0)
                receipt.phase = mode == 1 ? .creating : .reserved
                receipt.creationVersion = mode == 0 ? nil : 1
                let data = try JSONEncoder().encode(receipt)
                try data.write(to: store.receiptURL)
                if mode == 2 {
                    try Data("unknown".utf8).write(
                        to: directory.appendingPathComponent("stage-native-unknown"))
                }
                var manifest = FoundationDownloadManifest()
                manifest.nativePendingSessions = [identifier]
                try FoundationDownloadStorage.save(manifest, directory: directory)
                var removed = true
                let task = Task {
                    let outcome = await FoundationScopedAccountRemoval.removeNoFactoryAsync(
                        root: fixture.storage.downloads, scope: scope,
                        requiredSessions: [identifier])
                    removed = outcome.removed
                }
                fixture.tasks.append(task)
                try await waitForTask(task, label: "ambiguous no-factory cleanup")
                let retained = try Data(contentsOf: store.receiptURL)
                XCTAssertFalse(removed)
                XCTAssertEqual(retained, data)
                XCTAssertTrue(
                    try FoundationDownloadStorage.load(directory: directory)
                        .nativePendingSessions?.contains(identifier) == true)
                guard !removed, retained == data,
                    try FoundationDownloadStorage.load(directory: directory)
                        .nativePendingSessions?.contains(identifier) == true
                else { throw CancellationError() }
                try await fixture.drain(using: self)
                fixture.removeData()
            }
        }

        func testRealModelSignsInAndLocallySignsOutWithoutSystemServices() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let suite = "VelaCanto.Isolation." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            var safeToRemove = false
            defer {
                if safeToRemove {
                    defaults.removePersistentDomain(forName: suite)
                    try? FileManager.default.removeItem(at: root)
                }
            }
            defaults.set("data-protection-ready", forKey: FoundationAppModel.credentialBackendKey)
            let storage = FoundationScopedAccountStorage(root: root, defaults: defaults)
            let credentials = FoundationCredentials.Operations(
                update: { _, _ in errSecSuccess }, add: { _ in errSecSuccess },
                copy: { _ in (errSecItemNotFound, nil) }, delete: { _ in errSecSuccess })
            let events = IsolatedDiagnosticRecorder()
            var tasks: [Task<Void, Never>] = []
            var revocations: [Task<Bool, Never>] = []
            let isolation = FoundationAppRuntimeIsolation(
                storage: storage, credentials: credentials,
                load: { _ in throw URLError(.notConnectedToInternet) },
                revoke: { _ in Task { false } }, diagnostic: { events.append($0) },
                taskStarted: { tasks.append($0) },
                revocationStarted: { revocations.append($0) })
            let model = FoundationAppModel(
                restoreAccount: { $0.restoreCredentials() }, isolation: isolation)
            var readiness: FoundationAppModel.Readiness?
            let startup = Task { readiness = await model.ensureReady() }
            try await waitForTask(startup, label: "isolated model startup")
            XCTAssertEqual(readiness, .signedOut)
            let session = FoundationSession(
                serverURL: URL(string: "https://synthetic.invalid")!, accessToken: "synthetic",
                userID: "00000000000000000000000000000001",
                deviceID: "00000000-0000-0000-0000-000000000002")
            let accept = try await model.prepareSignIn { session }
            try await accept()
            let player = try XCTUnwrap(model.player)
            XCTAssertNotNil(model.library)
            XCTAssertNotNil(model.downloads)
            let accountCleanup = Task { await model.waitForAccountCleanup() }
            try await waitForTask(accountCleanup, label: "isolated account cleanup")
            model.signOut()
            XCTAssertNil(model.player)
            XCTAssertNil(model.library)
            let playerTask = try XCTUnwrap(player.sessionTask)
            try await waitForTask(playerTask, label: "isolated audio session stop")
            for task in tasks {
                try await waitForTask(task, label: "isolated lifecycle task")
            }
            for revocation in revocations {
                let drain = Task { _ = await revocation.value }
                try await waitForTask(drain, label: "isolated revocation task")
            }
            XCTAssertEqual(model.signOutNotice?.contains("Server sign-out unconfirmed."), true)
            safeToRemove = true
        }

        func testQueuedRetainedArtworkDeliveryRejectsReplacedSameAccountRuntime() async throws {
            try await checkQueuedRetainedArtworkDelivery(.commit)
        }

        func testQueuedRetainedArtworkDeliverySurvivesFailedReauthentication() async throws {
            try await checkQueuedRetainedArtworkDelivery(.failure)
        }

        func testQueuedRetainedArtworkDeliverySurvivesCancelledReauthentication() async throws {
            try await checkQueuedRetainedArtworkDelivery(.cancel)
        }

        private enum QueuedArtworkTransition {
            case commit, failure, cancel
        }

        private func checkQueuedRetainedArtworkDelivery(_ transition: QueuedArtworkTransition)
            async throws
        {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused artwork revocation"))
            let deliveryEntered = XCTestExpectation(description: "actual old artwork delivery held")
            let deliveryGate = LifecycleGate(entered: deliveryEntered)
            let deliveryFinished = XCTestExpectation(
                description: "actual old artwork delivery ended")
            let authenticationEntered = XCTestExpectation(
                description: "artwork authentication held")
            let authenticationGate = LifecycleGate(entered: authenticationEntered)
            var model: FoundationAppModel? = fixture.makeModel(leaseWaitStarted: {})
            var originalFailure: Error?
            var currentRefreshes = 0
            var currentArtwork: FoundationCurrentArtwork?
            var artworks: [FoundationCurrentArtwork] = []
            var players: [FoundationPlayer] = []
            do {
                let ready = Task { [weak model] in _ = await model?.ensureReady() }
                fixture.tasks.append(ready)
                try await waitForTask(ready, label: "queued artwork startup")
                let active = try XCTUnwrap(model)
                let session = fixture.session(user: "00000000000000000000000000000001")
                let scope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                let album = FoundationItem(
                    id: "00000000000000000000000000000003", title: "Synthetic artwork",
                    subtitle: "", kind: .album, duration: nil)
                var track = FoundationItem(
                    id: "00000000000000000000000000000004", title: "Paused synthetic selection",
                    subtitle: "", kind: .track, duration: nil)
                track.album = .init(id: album.id, title: album.title)
                let entry = FoundationQueueEntry(item: track)
                let snapshot = FoundationPlaybackSnapshot(
                    entries: [entry], selectedEntryID: entry.id, shuffleEnabled: false,
                    repeatMode: .off)
                let store = FoundationPlaybackSessionStore(
                    scope: scope, root: fixture.storage.playback)
                XCTAssertTrue(store.save(snapshot))
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(directory)
                let file = directory.appendingPathComponent("synthetic-retained-artwork")
                let bytes = Data("synthetic-nonmedia-artwork-bytes".utf8)
                try bytes.write(to: file)
                var manifest = FoundationDownloadManifest()
                manifest.owners = [
                    .init(
                        id: "album:" + album.id, item: FoundationStoredDownloadItem(album),
                        tracks: [FoundationStoredDownloadItem(track)], paused: true, expanded: true)
                ]
                manifest.artwork = [
                    "album:" + album.id: .init(
                        item: FoundationStoredDownloadItem(album),
                        file: .init(
                            name: file.lastPathComponent, bytes: Int64(bytes.count),
                            digest: try FoundationDownloadStorage.digest(file)))
                ]
                try FoundationDownloadStorage.save(manifest, directory: directory)
                active.isolatedBeforeRetainedArtworkDelivery = { await deliveryGate.hold() }
                active.isolatedRetainedArtworkDeliveryFinished = { deliveryFinished.fulfill() }
                active.isolatedRetainedArtworkRefreshed = { artwork in
                    if artwork === currentArtwork { currentRefreshes += 1 }
                }
                try await fixture.open(active, user: session.userID)
                let owner = try XCTUnwrap(active.downloads)
                let oldPlayer = try XCTUnwrap(active.player)
                let oldArtwork = try XCTUnwrap(active.currentArtwork)
                currentArtwork = oldArtwork
                players.append(oldPlayer)
                artworks.append(oldArtwork)
                if let task = oldArtwork.updateTask { fixture.tasks.append(task) }
                if let task = oldArtwork.loadTask { fixture.tasks.append(task) }
                try await waitForEvents([deliveryEntered], label: "real inventory artwork delivery")
                XCTAssertTrue(deliveryGate.isHeld)
                XCTAssertEqual(owner.retainedArtworkIdentity(for: album), file.lastPathComponent)
                XCTAssertEqual(oldPlayer.selectedEntryID, entry.id)
                XCTAssertNil(oldPlayer.nativePlayer.currentItem)
                XCTAssertNil(active.isolatedCurrentRetainedArtworkIdentity)
                let initialWrites = fixture.credentialWrites
                let initialDeletes = fixture.credentialDeletes
                var acceptance: FoundationSignInView.Acceptance?
                var authenticationFailure: Error?
                let authentication = Task {
                    do {
                        acceptance = try await active.prepareSignIn {
                            await authenticationGate.hold()
                            if case .failure = transition {
                                throw FoundationLibraryError.unavailable
                            }
                            return session
                        }
                    } catch { authenticationFailure = error }
                }
                fixture.tasks.append(authentication)
                try await waitForEvents(
                    [authenticationEntered], label: "pending artwork reauthentication")
                XCTAssertTrue(authenticationGate.isHeld)
                XCTAssertTrue(active.downloads === owner)
                let identity = album.id + ":" + file.lastPathComponent
                if case .commit = transition {
                    authenticationGate.release()
                    try await waitForTask(
                        authentication, label: "successful artwork authentication")
                    if let authenticationFailure { throw authenticationFailure }
                    let accept = try XCTUnwrap(acceptance)
                    var commitFailure: Error?
                    let commit = Task {
                        do { try await accept() } catch { commitFailure = error }
                    }
                    fixture.tasks.append(commit)
                    try await waitForTask(commit, label: "same-account artwork commit")
                    if let commitFailure { throw commitFailure }
                    let successor = try XCTUnwrap(active.currentArtwork)
                    let successorPlayer = try XCTUnwrap(active.player)
                    currentArtwork = successor
                    artworks.append(successor)
                    players.append(successorPlayer)
                    if let task = successor.updateTask { fixture.tasks.append(task) }
                    if let task = successor.loadTask { fixture.tasks.append(task) }
                    XCTAssertTrue(active.downloads === owner)
                    XCTAssertFalse(successor === oldArtwork)
                    XCTAssertFalse(successorPlayer === oldPlayer)
                    XCTAssertNil(successorPlayer.nativePlayer.currentItem)
                    XCTAssertTrue(deliveryGate.isHeld)
                    XCTAssertNil(active.isolatedCurrentRetainedArtworkIdentity)
                    deliveryGate.release()
                    try await waitForEvents([deliveryFinished], label: "old delivery after commit")
                    XCTAssertNil(
                        active.isolatedCurrentRetainedArtworkIdentity,
                        "A queued retired artwork subscriber must not change successor bookkeeping")
                    XCTAssertEqual(currentRefreshes, 0)
                    let currentFinished = XCTestExpectation(
                        description: "actual current artwork delivery ended")
                    active.isolatedBeforeRetainedArtworkDelivery = nil
                    active.isolatedRetainedArtworkDeliveryFinished = { currentFinished.fulfill() }
                    owner.isolatedPublishRetainedArtworkRevision()
                    try await waitForEvents(
                        [currentFinished], label: "current artwork publisher delivery")
                    XCTAssertEqual(active.isolatedCurrentRetainedArtworkIdentity, identity)
                    XCTAssertEqual(
                        currentRefreshes, 1,
                        "A current subscriber must refresh after the retired delivery is rejected")
                } else {
                    // Authentication is still held: the existing runtime retains
                    // publication authority, independent of authentication generation.
                    deliveryGate.release()
                    try await waitForEvents(
                        [deliveryFinished], label: "valid delivery during authentication")
                    XCTAssertEqual(active.isolatedCurrentRetainedArtworkIdentity, identity)
                    XCTAssertEqual(currentRefreshes, 1)
                    XCTAssertTrue(active.currentArtwork === oldArtwork)
                    XCTAssertEqual(fixture.credentialWrites, initialWrites)
                    if case .cancel = transition { authentication.cancel() }
                    authenticationGate.release()
                    try await waitForTask(
                        authentication, label: "failed or cancelled artwork authentication")
                    XCTAssertNotNil(authenticationFailure)
                    XCTAssertNil(acceptance)
                    XCTAssertTrue(active.downloads === owner)
                    XCTAssertTrue(active.currentArtwork === oldArtwork)
                    XCTAssertEqual(active.isolatedCurrentRetainedArtworkIdentity, identity)
                    XCTAssertEqual(currentRefreshes, 1)
                    XCTAssertEqual(fixture.credentialWrites, initialWrites)
                }
                XCTAssertEqual(fixture.credentialDeletes, initialDeletes)
                XCTAssertEqual(try Data(contentsOf: file), bytes)
            } catch {
                originalFailure = error
            }
            // Release every held operation before independently attempting each
            // owned drain. Never let a failed join skip subsequent release attempts.
            deliveryGate.release()
            authenticationGate.release()
            fixture.gate.release()
            model?.isolatedBeforeRetainedArtworkDelivery = nil
            model?.isolatedRetainedArtworkDeliveryFinished = nil
            model?.isolatedRetainedArtworkRefreshed = nil
            var artworkTasks: [Task<Void, Never>] = []
            for artwork in artworks {
                if let task = artwork.updateTask { artworkTasks.append(task) }
                if let task = artwork.loadTask { artworkTasks.append(task) }
                artwork.invalidate()
            }
            for player in players {
                player.stop()
                fixture.captureStop(player)
            }
            let actionDrain = model?.actions?.invalidateAndDrain()
            model = nil
            var cleanupFailures: [Error] = []
            if let actionDrain {
                do { try await waitForTask(actionDrain, label: "artwork action cleanup") } catch {
                    cleanupFailures.append(error)
                }
            }
            for task in artworkTasks {
                do { try await waitForTask(task, label: "artwork provider cleanup") } catch {
                    cleanupFailures.append(error)
                }
            }
            do { try await fixture.releaseResources(using: self) } catch {
                cleanupFailures.append(error)
            }
            do { try await fixture.drain(using: self) } catch { cleanupFailures.append(error) }
            if originalFailure == nil, cleanupFailures.isEmpty { fixture.removeData() }
            if !cleanupFailures.isEmpty {
                XCTFail("Required queued-artwork cleanup did not finish; retained isolated data")
            }
            if let originalFailure { throw originalFailure }
            if let failure = cleanupFailures.first { throw failure }
        }

        func testModelDeinitRejectsEscapedActionWorkAndPreservesLeasedStorage() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            let favoriteEntered = XCTestExpectation(description: "model favorite request held")
            let favoriteGate = LifecycleGate(entered: favoriteEntered)
            let exchangeEntered = XCTestExpectation(description: "fake pin exchange held")
            let exchangeGate = LifecycleGate(entered: exchangeEntered)
            let album = FoundationItem(
                id: "00000000000000000000000000000003", title: "Synthetic album",
                subtitle: "", kind: .album, duration: nil)
            let lateAlbum = FoundationItem(
                id: "00000000000000000000000000000004", title: "Escaped action",
                subtitle: "", kind: .album, duration: nil)
            let requestClasses = IsolatedDiagnosticRecorder()
            let acceptedFavorite = IsolatedDiagnosticRecorder()
            var escapedActions: FoundationLibraryActions?
            var originalFailure: Error?
            var leasedFile: URL?
            var leasedBytes: Data?
            var syncApplies = 0
            var model: FoundationAppModel? = fixture.makeModel(
                leaseWaitStarted: {},
                loadOverride: { request in
                    let methodClass =
                        request.httpMethod == "POST"
                        ? "POST"
                        : request.httpMethod == "GET" ? "GET" : "OTHER"
                    let endpointClass =
                        request.url?.path.hasSuffix("/UserFavoriteItems/" + album.id) == true
                        ? "favorite" : "other"
                    requestClasses.append(methodClass + "/" + endpointClass, maximum: 16)
                    guard methodClass == "POST", endpointClass == "favorite",
                        let url = request.url
                    else { throw URLError(.notConnectedToInternet) }
                    acceptedFavorite.append("POST/favorite", maximum: 1)
                    await favoriteGate.hold()
                    // Ignore cancellation here deliberately: owner retirement must
                    // reject a successful late transport result independently.
                    guard
                        let response = HTTPURLResponse(
                            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
                    else { throw FoundationLibraryError.invalidResponse }
                    return (Data(#"{"Key":"synthetic","IsFavorite":true}"#.utf8), response)
                })
            defer {
                print(
                    "DEINIT_FAKE_REQUEST_CLASSES \(requestClasses.snapshot()) accepted=\(acceptedFavorite.snapshot())"
                )
                favoriteGate.release()
                exchangeGate.release()
                fixture.gate.release()
            }
            do {
                let startup = Task { [weak model] in _ = await model?.ensureReady() }
                try await waitForTask(startup, label: "deinit characterization startup")
                let session = fixture.session(user: "00000000000000000000000000000001")
                let scope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(directory)
                let track = FoundationItem(
                    id: "00000000000000000000000000000005", title: "Leased fixture bytes",
                    subtitle: "", kind: .track, duration: nil)
                let file = directory.appendingPathComponent("deinit.audio")
                let bytes = Data("synthetic-deinit-ordinary-file".utf8)
                try bytes.write(to: file)
                var manifest = FoundationDownloadManifest()
                let storedTrack = FoundationStoredDownloadItem(track)
                manifest.owners = [
                    .init(
                        id: "track:" + track.id, item: storedTrack, tracks: [storedTrack],
                        paused: true, expanded: false)
                ]
                manifest.files[track.id] = .init(
                    name: file.lastPathComponent, bytes: Int64(bytes.count),
                    digest: try FoundationDownloadStorage.digest(file))
                try FoundationDownloadStorage.save(manifest, directory: directory)
                try await fixture.open(try XCTUnwrap(model), user: session.userID)
                let owner = try XCTUnwrap(model?.downloads)
                let inventoryFinished = XCTestExpectation(
                    description: "ordinary inventory finished")
                let inventoryObserver = owner.$isLoading.filter { !$0 }.first().sink { _ in
                    inventoryFinished.fulfill()
                }
                defer { inventoryObserver.cancel() }
                try await waitForEvents([inventoryFinished], label: "deinit ordinary inventory")
                try await fixture.acquireResource(from: owner, item: track, using: self)
                leasedFile = file
                leasedBytes = bytes
                let actions = try XCTUnwrap(model?.actions)
                escapedActions = actions
                actions.togglePin(album)
                let pinKey = FoundationPinStorage.key(for: scope)
                let pinsBefore = try XCTUnwrap(fixture.defaults.data(forKey: pinKey))
                let otherKey = FoundationPinStorage.key(for: String(repeating: "b", count: 64))
                let otherBytes = Data("unrelated-pins".utf8)
                fixture.defaults.set(otherBytes, forKey: otherKey)
                let credentialsBefore = fixture.credentialWrites
                let deletesBefore = fixture.credentialDeletes
                let revisionBefore = actions.favoriteRevision
                let syncState = FoundationPinSyncState(scope: scope)
                let sync = FoundationPinSync(
                    scope: scope, containerIdentifier: nil, defaults: fixture.defaults,
                    exchange: { _, _, _, _, _, _ in
                        await exchangeGate.hold()
                        return .init(state: syncState, account: "synthetic", reset: false)
                    }, currentPins: { [] },
                    apply: { _, current in
                        if current() { syncApplies += 1 }
                    })
                actions.isolatedInstallPinSync(sync)
                // Drain construction before admitting the work that deinit must
                // retire; a held operation must never make this setup wait hang.
                try await fixture.drain(using: self)
                let visible = !actions.visibleTracks([album]).isEmpty
                let pending = actions.isPending(album)
                let currentActions = model?.actions === actions
                print(
                    "DEINIT_ADMISSION visible=\(visible) pending=\(pending) current=\(currentActions) cancelled=\(Task.isCancelled)"
                )
                XCTAssertTrue(visible, "Synthetic favorite must be visible before admission")
                XCTAssertFalse(pending, "Synthetic favorite must not already be pending")
                XCTAssertTrue(currentActions, "Synthetic actions must belong to the current model")
                XCTAssertFalse(
                    Task.isCancelled, "Fixture must not admit work from a cancelled caller")
                guard visible, !pending, currentActions, !Task.isCancelled else {
                    throw CancellationError()
                }
                let favorite = Task { await actions.setFavorite(for: album, isFavorite: true) }
                fixture.tasks.append(favorite)
                sync.setEnabled(true)
                let exchange = try XCTUnwrap(sync.task)
                fixture.tasks.append(exchange)
                try await waitForEvents(
                    [favoriteEntered, exchangeEntered],
                    label: "actual model action and fake exchange held")
                XCTAssertTrue(
                    acceptedFavorite.snapshot().contains("POST/favorite"),
                    "Favorite gate must be acknowledged by the exact fake endpoint class")
                let retiredModel = { [weak model] in model }
                model = nil
                XCTAssertNil(retiredModel(), "Escaped action work must not retain the app model")
                guard retiredModel() == nil else { throw CancellationError() }
                // Deinit preserves storage and does not consume a caller-owned
                // escaped ordinary playback lease. No AVPlayer/native URL is used.
                XCTAssertEqual(try Data(contentsOf: file), bytes)
                XCTAssertEqual(fixture.defaults.data(forKey: pinKey), pinsBefore)
                XCTAssertEqual(fixture.credentialWrites, credentialsBefore)
                XCTAssertEqual(fixture.credentialDeletes, deletesBefore)
                XCTAssertTrue(favoriteGate.isHeld)
                XCTAssertTrue(exchangeGate.isHeld)
                favoriteGate.release()
                exchangeGate.release()
                try await waitForTask(favorite, label: "late favorite result after model deinit")
                try await waitForTask(exchange, label: "late fake exchange after model deinit")
                XCTAssertEqual(
                    actions.favoriteRevision, revisionBefore,
                    "A retired model's action must reject its late favorite result")
                XCTAssertEqual(
                    syncApplies, 0,
                    "A retired model's pin owner must reject its late exchange result")
                // Check new admission after held-result publication assertions so
                // a new local edit cannot invalidate the exchange's own revision.
                actions.togglePin(lateAlbum)
                XCTAssertEqual(
                    fixture.defaults.data(forKey: pinKey), pinsBefore,
                    "Escaped actions must reject new mutations after their model retires")
                XCTAssertEqual(try Data(contentsOf: file), bytes)
                XCTAssertEqual(fixture.defaults.data(forKey: otherKey), otherBytes)
            } catch {
                originalFailure = error
                let pending = escapedActions?.isPending(album) == true
                let visible = escapedActions.map { !$0.visibleTracks([album]).isEmpty } ?? false
                let favoriteError = escapedActions?.errorMessage(for: album) != nil
                print(
                    "DEINIT_SETUP_STATE favoriteHeld=\(favoriteGate.isHeld) exchangeHeld=\(exchangeGate.isHeld) visible=\(visible) pending=\(pending) error=\(favoriteError) cancelled=\(Task.isCancelled)"
                )
            }
            // Every held operation is released before any cleanup await. Each
            // retirement attempt is independent, even if the caller is cancelled
            // or an earlier deadline fails; preserve the original failure.
            favoriteGate.release()
            exchangeGate.release()
            fixture.gate.release()
            model = nil
            var cleanupFailures: [Error] = []
            var actionRetired = escapedActions == nil
            var resourcesRetired = false
            var fixtureRetired = false
            if let escapedActions {
                do {
                    let drain = escapedActions.invalidateAndDrain()
                    try await waitForTask(drain, label: "deinit action fixture cleanup")
                    actionRetired = true
                } catch {
                    cleanupFailures.append(error)
                }
            }
            do {
                try await fixture.releaseResources(using: self)
                resourcesRetired = true
            } catch {
                cleanupFailures.append(error)
            }
            do {
                try await fixture.drain(using: self)
                fixtureRetired = true
            } catch {
                cleanupFailures.append(error)
            }
            var leasedStoragePreserved = true
            if resourcesRetired, let leasedFile, let leasedBytes {
                do {
                    let retained = try Data(contentsOf: leasedFile)
                    leasedStoragePreserved = retained == leasedBytes
                    XCTAssertEqual(retained, leasedBytes)
                } catch {
                    leasedStoragePreserved = false
                    cleanupFailures.append(error)
                }
            }
            // Failure evidence is retained. Neither a cancellation request nor a
            // later successful phase overrides an unjoined required resource.
            if actionRetired && resourcesRetired && fixtureRetired && leasedStoragePreserved,
                originalFailure == nil, cleanupFailures.isEmpty
            {
                fixture.removeData()
            }
            if !cleanupFailures.isEmpty {
                XCTFail("Required fixture cleanup did not finish; retained isolated data")
            }
            if let originalFailure { throw originalFailure }
            if let cleanupFailure = cleanupFailures.first { throw cleanupFailure }
        }

        func testInventoryPublishesEmptyManifestOnceAndOtherCollectorsStillSave() throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused inventory revocation"))
            var safeToRemove = false
            defer {
                fixture.gate.release()
                if safeToRemove { fixture.removeData() }
            }
            let storageRoot = fixture.storage.downloads
            let library = FoundationJellyfinLibrary(session: fixture.session(user: "inventory")) {
                _ in
                XCTFail("Local inventory must not request server data")
                throw URLError(.notConnectedToInternet)
            }
            let scope = "empty-inventory-save"
            let track = FoundationItem(
                id: "later", title: "Synthetic", subtitle: "Fixture", kind: .track, duration: 1)
            let downloads = FoundationDownloads(
                scope: scope, library: library, root: storageRoot,
                monitorConnectivity: false)
            defer { downloads.invalidate() }
            XCTAssertEqual(
                downloads.isolatedManifestRevision, 1,
                "A fresh empty inventory must publish its manifest only once")
            let directory = FoundationDownloadStorage.directory(scope: scope, root: storageRoot)
            let saved = try FoundationDownloadStorage.load(directory: directory)
            XCTAssertTrue(saved.files.isEmpty)
            XCTAssertTrue(saved.owners.isEmpty)
            XCTAssertEqual(
                try directory.appendingPathComponent("manifest.json")
                    .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
                true)

            safeToRemove = true
            downloads.download(track)
            let beforeRemoval = downloads.isolatedManifestRevision
            downloads.remove(ownerID: "track:" + track.id)
            XCTAssertEqual(downloads.isolatedManifestRevision, beforeRemoval + 2)
            XCTAssertTrue(try FoundationDownloadStorage.load(directory: directory).owners.isEmpty)
            XCTAssertNil(downloads.errorMessage)
        }

        func testInventoryKeepsVerifiedAudioWithoutRepublishingUnchangedManifest() async throws {
            try await checkInventoryManifestPublication(removingUnusedResources: false)
        }

        func testInventoryPersistsActualAudioAndArtworkCollection() async throws {
            try await checkInventoryManifestPublication(removingUnusedResources: true)
        }

        private func checkInventoryManifestPublication(removingUnusedResources: Bool) async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused inventory revocation"))
            var safeToRemove = false
            defer {
                fixture.gate.release()
                if safeToRemove { fixture.removeData() }
            }
            let storageRoot = fixture.storage.downloads
            let library = FoundationJellyfinLibrary(session: fixture.session(user: "inventory")) {
                _ in
                XCTFail("Local inventory must not request server data")
                throw URLError(.notConnectedToInternet)
            }
            let scope = "verified-inventory-save"
            let directory = FoundationDownloadStorage.directory(scope: scope, root: storageRoot)
            try FoundationDownloadStorage.prepare(directory)
            let retained = FoundationItem(
                id: "retained", title: "Synthetic", subtitle: "Fixture", kind: .track, duration: 1)
            var manifest = FoundationDownloadManifest()
            manifest.owners = [
                .init(
                    id: "track:" + retained.id, item: FoundationStoredDownloadItem(retained),
                    tracks: [FoundationStoredDownloadItem(retained)], paused: true, expanded: true)
            ]
            let bytes = Data("verified retained audio".utf8)
            let retainedURL = directory.appendingPathComponent("retained.mp3")
            try bytes.write(to: retainedURL)
            try FoundationDownloadStorage.protect(retainedURL)
            manifest.files[retained.id] = .init(
                name: retainedURL.lastPathComponent, bytes: Int64(bytes.count),
                digest: try FoundationDownloadStorage.digest(retainedURL))
            let unusedURL = directory.appendingPathComponent("unused.mp3")
            let artworkURL = directory.appendingPathComponent("unused.jpg")
            if removingUnusedResources {
                for url in [unusedURL, artworkURL] {
                    try bytes.write(to: url)
                    try FoundationDownloadStorage.protect(url)
                }
                manifest.files["unused"] = .init(
                    name: unusedURL.lastPathComponent, bytes: Int64(bytes.count),
                    digest: try FoundationDownloadStorage.digest(unusedURL))
                manifest.artwork = [
                    "album:unused": .init(
                        item: FoundationStoredDownloadItem(
                            FoundationItem(
                                id: "unused", title: "Synthetic", subtitle: "Fixture",
                                kind: .album, duration: nil)),
                        file: .init(
                            name: artworkURL.lastPathComponent, bytes: Int64(bytes.count),
                            digest: try FoundationDownloadStorage.digest(artworkURL)))
                ]
            }
            try FoundationDownloadStorage.save(manifest, directory: directory)
            let downloads = FoundationDownloads(
                scope: scope, library: library, root: storageRoot,
                monitorConnectivity: false)
            defer { downloads.invalidate() }
            let inventoryFinished = XCTestExpectation(description: "inventory publication finished")
            let inventoryObserver = downloads.$artworkRevision.filter { $0 > 0 }.first().sink { _ in
                inventoryFinished.fulfill()
            }
            defer { inventoryObserver.cancel() }
            try await waitForEvents([inventoryFinished], label: "inventory publication")
            safeToRemove = true
            XCTAssertEqual(
                downloads.isolatedManifestRevision, removingUnusedResources ? 2 : 1,
                "An unchanged verified inventory must publish its manifest only once")
            XCTAssertTrue(downloads.isReady(retained))
            XCTAssertEqual(try Data(contentsOf: retainedURL), bytes)
            let saved = try FoundationDownloadStorage.load(directory: directory)
            XCTAssertEqual(Set(saved.files.keys), [retained.id])
            XCTAssertEqual(saved.files[retained.id]?.digest, manifest.files[retained.id]?.digest)
            XCTAssertEqual(saved.owners.map(\.id), ["track:" + retained.id])
            XCTAssertEqual(saved.owners.first?.paused, true)
            XCTAssertTrue(saved.artwork?.isEmpty ?? true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: unusedURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: artworkURL.path))
            XCTAssertEqual(
                try directory.appendingPathComponent("manifest.json")
                    .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
                true)
            XCTAssertNil(downloads.errorMessage)
        }

        func testModelDeinitRetiresExternallyRetainedConfiguredHandoffContext() throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            var model: FoundationAppModel? = fixture.makeModel()
            let controller = try XCTUnwrap(model).handoff
            let player = FoundationPlayer(resolve: { _ in throw FoundationLibraryError.unavailable }
            )
            defer {
                model = nil
                controller.invalidate()
                player.stop()
                fixture.gate.release()
                fixture.removeData()
            }
            var contextOwner: NSObject? = NSObject()
            weak let retainedContextOwner = contextOwner
            controller.configure(
                scope: String(repeating: "a", count: 64), player: player,
                resolve: { [contextOwner] item in
                    withExtendedLifetime(contextOwner) { item }
                }, navigate: { _ in })
            contextOwner = nil
            XCTAssertNotNil(
                retainedContextOwner, "Configured context must own the resolver capture")
            XCTAssertNil(controller.activity, "Empty playback must not publish a native activity")
            weak let retiredModel = model
            model = nil
            XCTAssertNil(retiredModel, "The model must actually deinitialize")
            XCTAssertNil(
                retainedContextOwner,
                "Model destruction must retire its externally retained configured Handoff context")
        }

        func testModelDeinitRetainsScopedPinsAndPageCache() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation entry"))
            var safeToRemove = false
            defer {
                fixture.gate.release()
                if safeToRemove { fixture.removeData() }
            }
            var model: FoundationAppModel? = fixture.makeModel()
            var readiness: FoundationAppModel.Readiness?
            let startup = Task { [weak model] in readiness = await model?.ensureReady() }
            try await waitForTask(startup, label: "isolated startup")
            XCTAssertEqual(readiness, .signedOut)
            try await fixture.open(try XCTUnwrap(model), user: "00000000000000000000000000000001")
            let library = try XCTUnwrap(model?.library)
            let actions = try XCTUnwrap(model?.actions)
            actions.togglePin(fixture.album)
            let pinKey = FoundationPinStorage.key(for: library.catalogAccountIdentity)
            let pins = try XCTUnwrap(fixture.defaults.data(forKey: pinKey))
            let cache = try XCTUnwrap(library.catalogPageCache)
            let cacheKey = "deinit-retained-sentinel"
            let page = FoundationPage(items: [fixture.album], nextStartIndex: nil)
            let write = Task { await cache.write(page, key: cacheKey) }
            try await waitForTask(write, label: "deinit sentinel write")
            var itemIDs: [String]?
            let read = Task { itemIDs = await cache.read(cacheKey)?.page.items.map(\.id) }
            try await waitForTask(read, label: "deinit sentinel read")
            XCTAssertEqual(itemIDs, [fixture.album.id])
            let file = fixture.storage.pages.appendingPathComponent(cache.scope, isDirectory: true)
                .appendingPathComponent(FoundationArtworkCache.digest(cacheKey) + ".page")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            try await fixture.drain(using: self)
            weak var retired: FoundationAppModel?
            retired = model
            model = nil
            guard retired == nil else {
                XCTFail("Model did not deinitialize; retained isolated data")
                return
            }
            try await fixture.drain(using: self)
            XCTAssertEqual(fixture.defaults.data(forKey: pinKey), pins)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            safeToRemove = true
        }

        func testDownloadHandoffFenceRejectsAdmissionAndRollsBackWithoutRevival() async throws {
            try await withLifecycleFixture { fixture, model in
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let downloads = try XCTUnwrap(model.downloads)
                let track = FoundationItem(
                    id: "00000000000000000000000000000003", title: "Synthetic",
                    subtitle: "", kind: .track, duration: nil)
                downloads.download(track)
                let token = try XCTUnwrap(downloads.beginAccountHandoff())
                XCTAssertNil(downloads.beginAccountHandoff())
                downloads.cancel(ownerID: "track:" + track.id)
                XCTAssertEqual(downloads.owners.first?.state, .cancelled)
                downloads.remove(ownerID: "track:" + track.id)
                XCTAssertNotNil(downloads.errorMessage)
                XCTAssertEqual(downloads.owners.count, 1)
                let revision = downloads.catalogRevision
                downloads.refreshPresentation()
                XCTAssertEqual(downloads.catalogRevision, revision)
                downloads.setAllowsCellular(true)
                XCTAssertFalse(downloads.allowsCellular)
                var admissionFailure: Error?
                let admission = Task {
                    do {
                        let unexpected = try await downloads.playbackResource(
                            for: track, allowsRemoteFallback: false)
                        await unexpected.release()
                    } catch { admissionFailure = error }
                }
                fixture.tasks.append(admission)
                try await self.waitForTask(admission, label: "fenced playback admission")
                XCTAssertTrue(admissionFailure is CancellationError)
                XCTAssertFalse(downloads.cancelAccountHandoff(UUID()))
                XCTAssertTrue(downloads.cancelAccountHandoff(token))
                XCTAssertTrue(downloads.allowsCellular)
                XCTAssertGreaterThan(downloads.catalogRevision, revision)
                downloads.download(track)
                XCTAssertEqual(downloads.owners.map(\.id), ["track:" + track.id])
                let second = try XCTUnwrap(downloads.beginAccountHandoff())
                downloads.invalidate()
                XCTAssertFalse(downloads.cancelAccountHandoff(second))
                XCTAssertNil(downloads.beginAccountHandoff())
                let other = FoundationItem(
                    id: "00000000000000000000000000000004", title: "Other synthetic",
                    subtitle: "", kind: .track, duration: nil)
                downloads.download(other)
                XCTAssertEqual(downloads.owners.map(\.id), ["track:" + track.id])
            }
        }

        func testDownloadHandoffFenceCancelsTransfersWhenPathBecomesForbidden() async throws {
            try await withLifecycleFixture { fixture, model in
                try await fixture.open(model, user: "00000000000000000000000000000001")
                for restrictPreference in [false, true] {
                    let entered = self.expectation(description: "synthetic transfer entered")
                    let stopped = self.expectation(description: "synthetic transfer stopped")
                    let gate = LifecycleGate(entered: entered)
                    let manager = FoundationDownloads(
                        scope: UUID().uuidString, library: HandoffTransferLibrary(),
                        root: fixture.storage.downloads,
                        transfer: { _, _, _, _ in
                            defer { stopped.fulfill() }
                            try await withTaskCancellationHandler {
                                await gate.hold()
                                try Task.checkCancellation()
                            } onCancel: {
                                Task { @MainActor in gate.release() }
                            }
                        }, monitorConnectivity: false, allowNativeCleanup: false)
                    defer {
                        gate.release()
                        manager.invalidate()
                    }
                    if restrictPreference { manager.setAllowsCellular(true) }
                    manager.updateConnectivity(isConnected: true, usesWiFi: !restrictPreference)
                    let initialReconciliation = Task {
                        await manager.waitForCurrentReconciliationForTesting()
                    }
                    fixture.tasks.append(initialReconciliation)
                    try await self.waitForTask(
                        initialReconciliation, label: "initial reconciliation")
                    let track = FoundationItem(
                        id: UUID().uuidString, title: "Synthetic", subtitle: "", kind: .track,
                        duration: nil)
                    manager.download(track)
                    let worker = try XCTUnwrap(manager.isolatedWorkerTask)
                    fixture.tasks.append(worker)
                    try await self.waitForEvents([entered], label: "transfer admission")
                    _ = try XCTUnwrap(manager.beginAccountHandoff())
                    XCTAssertTrue(gate.isHeld)
                    if restrictPreference {
                        manager.setAllowsCellular(false)
                    } else {
                        manager.updateConnectivity(isConnected: true, usesWiFi: false)
                    }
                    try await self.waitForEvents([stopped], label: "restrictive cancellation")
                    manager.invalidate()
                    try await self.waitForTask(worker, label: "restricted transfer worker")
                }
            }
        }

        func testAbandonedPreparedAcceptanceDoesNotPublishAccount() async throws {
            try await withLifecycleFixture { fixture, model in
                let session = fixture.session(user: "00000000000000000000000000000001")
                var prepared: FoundationSignInView.Acceptance?
                var preparationError: Error?
                let preparation = Task {
                    do { prepared = try await model.prepareSignIn { session } } catch {
                        preparationError = error
                    }
                }
                fixture.tasks.append(preparation)
                try await self.waitForTask(preparation, label: "abandoned acceptance preparation")
                if let preparationError { throw preparationError }
                XCTAssertNotNil(prepared)
                let writes = fixture.credentialWrites
                prepared = nil
                XCTAssertNil(model.library)
                XCTAssertNil(model.player)
                XCTAssertEqual(fixture.credentialWrites, writes)
            }
        }

        func testCancelledPreparedAcceptanceDoesNotPublishAccount() async throws {
            try await withLifecycleFixture { fixture, model in
                let session = fixture.session(user: "00000000000000000000000000000001")
                var prepared: FoundationSignInView.Acceptance?
                var preparationError: Error?
                let preparation = Task {
                    do { prepared = try await model.prepareSignIn { session } } catch {
                        preparationError = error
                    }
                }
                fixture.tasks.append(preparation)
                try await self.waitForTask(preparation, label: "acceptance preparation")
                if let preparationError { throw preparationError }
                let accept = try XCTUnwrap(prepared)
                let writes = fixture.credentialWrites
                var failure: Error?
                let cancelled = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    do { try await accept() } catch { failure = error }
                }
                fixture.tasks.append(cancelled)
                try await self.waitForTask(cancelled, label: "cancelled prepared acceptance")
                XCTAssertTrue(failure is CancellationError)
                XCTAssertNil(model.library)
                XCTAssertNil(model.player)
                XCTAssertEqual(fixture.credentialWrites, writes)
            }
        }

        func testSameAccountCallbackReconcilesBeforeHandoffCommit() async throws {
            try await checkSameAccountCallbackDuringHandoff(holdAcrossCommit: false)
        }

        func testSameAccountCallbackRetriesAfterHandoffCommit() async throws {
            try await checkSameAccountCallbackDuringHandoff(holdAcrossCommit: true)
        }

        private func checkSameAccountCallbackDuringHandoff(holdAcrossCommit: Bool) async throws {
            let readEntered = expectation(description: "retained artwork read held")
            let handoffEntered = expectation(description: "handoff waits for artwork read")
            let proofEntered = expectation(description: "native reconciliation proof held")
            let completion = expectation(description: "synthetic native completion")
            let readGate = LifecycleGate(entered: readEntered)
            let proofGate = LifecycleGate(entered: proofEntered)
            weak var routingModel: FoundationAppModel?
            weak var expectedOwner: FoundationDownloads?
            var routeResults: [Bool] = []
            var completionCount = 0
            try await withLifecycleFixture(
                leaseWaitStarted: {},
                backgroundReconcile: { identifier in
                    guard let owner = routingModel?.downloads, owner === expectedOwner else {
                        return false
                    }
                    let result = await owner.reconcileBackgroundSession(identifier)
                    routeResults.append(result)
                    return result
                },
                nativeRetirement: { identifiers, directory in
                    var retired: Set<String> = []
                    for identifier in identifiers {
                        do {
                            try FoundationNativeAllocationStore(
                                directory: directory,
                                sessionIdentifier: identifier
                            ).retire()
                            retired.insert(identifier)
                        } catch {}
                    }
                    return retired
                },
                { fixture, model in
                    routingModel = model
                    defer {
                        readGate.release()
                        proofGate.release()
                        routingModel = nil
                        expectedOwner = nil
                    }
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    var firstAcceptance: FoundationSignInView.Acceptance?
                    var preparationError: Error?
                    let firstPreparation = Task {
                        do { firstAcceptance = try await model.prepareSignIn { session } } catch {
                            preparationError = error
                        }
                    }
                    fixture.tasks.append(firstPreparation)
                    try await self.waitForTask(
                        firstPreparation, label: "initial handoff preparation")
                    if let preparationError { throw preparationError }
                    let scope = FoundationMusicLibraryStore.digest(
                        "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                    let directory = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads)
                    try FoundationDownloadStorage.prepare(directory)
                    let identifier =
                        "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
                        + UUID().uuidString
                    let receipt = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    try receipt.reserve()
                    let album = FoundationItem(
                        id: "handoff-album", title: "Synthetic", subtitle: "", kind: .album,
                        duration: nil)
                    let stored = FoundationStoredDownloadItem(album)
                    let file = directory.appendingPathComponent("synthetic-artwork")
                    let bytes = Data("synthetic-artwork-bytes".utf8)
                    try bytes.write(to: file)
                    var manifest = FoundationDownloadManifest()
                    manifest.nativePendingSessions = [identifier]
                    manifest.owners = [
                        .init(
                            id: "album:" + album.id, item: stored, tracks: [], paused: true,
                            expanded: true)
                    ]
                    manifest.artwork = [
                        "album:" + album.id: .init(
                            item: stored,
                            file: .init(
                                name: file.lastPathComponent, bytes: Int64(bytes.count),
                                digest: try FoundationDownloadStorage.digest(file)))
                    ]
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    let initial = try XCTUnwrap(firstAcceptance)
                    var initialError: Error?
                    let initialCommit = Task {
                        do { try await initial() } catch { initialError = error }
                    }
                    fixture.tasks.append(initialCommit)
                    try await self.waitForTask(initialCommit, label: "initial handoff commit")
                    if let initialError { throw initialError }
                    let owner = try XCTUnwrap(model.downloads)
                    expectedOwner = owner
                    let inventory = self.expectation(
                        description: "synthetic native inventory settled")
                    let inventoryObservation = owner.$isLoading.filter { !$0 }.first().sink { _ in
                        inventory.fulfill()
                    }
                    defer { inventoryObservation.cancel() }
                    try await self.waitForEvents([inventory], label: "synthetic native inventory")
                    let oldPlayer = try XCTUnwrap(model.player)
                    let actions = try XCTUnwrap(model.actions)
                    actions.togglePin(fixture.album)
                    let pinKey = FoundationPinStorage.key(for: scope)
                    let pins = try XCTUnwrap(fixture.defaults.data(forKey: pinKey))
                    let playbackStore = FoundationPlaybackSessionStore(
                        scope: scope, root: fixture.storage.playback)
                    XCTAssertTrue(playbackStore.save(FoundationPlaybackSnapshot(player: oldPlayer)))
                    let playback = try Data(contentsOf: playbackStore.file)
                    owner.isolatedArtworkReadStarted = { await readGate.hold() }
                    owner.isolatedHandoffOperationsWaitStarted = { handoffEntered.fulfill() }
                    owner.isolatedBackgroundProofDelay = { await proofGate.hold() }
                    let read = Task { _ = await owner.retainedArtwork(for: album) }
                    fixture.tasks.append(read)
                    try await self.waitForEvents([readEntered], label: "retained artwork read")
                    let refreshed = FoundationSession(
                        serverURL: session.serverURL,
                        accessToken: "refreshed-synthetic-token", userID: session.userID,
                        deviceID: session.deviceID)
                    var acceptance: FoundationSignInView.Acceptance?
                    var reauthError: Error?
                    let preparation = Task {
                        do { acceptance = try await model.prepareSignIn { refreshed } } catch {
                            reauthError = error
                        }
                    }
                    fixture.tasks.append(preparation)
                    try await self.waitForTask(
                        preparation, label: "same-account handoff preparation")
                    if let reauthError { throw reauthError }
                    let commitAction = try XCTUnwrap(acceptance)
                    let writes = fixture.credentialWrites
                    var commitError: Error?
                    var committed = false
                    let commit = Task {
                        do {
                            try await commitAction()
                            committed = true
                        } catch { commitError = error }
                    }
                    fixture.tasks.append(commit)
                    try await self.waitForEvents([handoffEntered], label: "handoff operation drain")
                    model.receiveBackgroundDownloadEvents(identifier) {
                        completionCount += 1
                        if completionCount == 1 { completion.fulfill() }
                    }
                    model.finishBackgroundDownloadEvents(identifier)
                    try await self.waitForEvents([proofEntered], label: "held native proof")
                    XCTAssertEqual(completionCount, 0)
                    XCTAssertFalse(committed)
                    guard completionCount == 0, !committed else { throw CancellationError() }
                    if holdAcrossCommit {
                        readGate.release()
                        try await self.waitForTask(read, label: "released artwork read")
                        try await self.waitForTask(commit, label: "same-account commit")
                        if let commitError { throw commitError }
                        XCTAssertEqual(completionCount, 0)
                        guard completionCount == 0 else { throw CancellationError() }
                        proofGate.release()
                        try await self.waitForEvents(
                            [completion], label: "retried native completion")
                        XCTAssertEqual(routeResults, [false, true])
                    } else {
                        proofGate.release()
                        try await self.waitForEvents(
                            [completion], label: "pre-commit native completion")
                        XCTAssertEqual(routeResults, [true])
                        readGate.release()
                        try await self.waitForTask(read, label: "released artwork read")
                        try await self.waitForTask(commit, label: "same-account commit")
                        if let commitError { throw commitError }
                    }
                    fixture.captureStop(oldPlayer)
                    let expectedRoutes = holdAcrossCommit ? [false, true] : [true]
                    let persistedPins = fixture.defaults.data(forKey: pinKey)
                    let persistedPlayback = try Data(contentsOf: playbackStore.file)
                    let persistedFile = try Data(contentsOf: file)
                    XCTAssertEqual(completionCount, 1)
                    XCTAssertTrue(model.downloads === owner)
                    XCTAssertNotNil(model.player)
                    XCTAssertEqual(model.library?.session.accessToken, refreshed.accessToken)
                    XCTAssertEqual(fixture.credentialWrites, writes + 1)
                    XCTAssertEqual(persistedPins, pins)
                    XCTAssertEqual(persistedPlayback, playback)
                    XCTAssertEqual(persistedFile, bytes)
                    guard completionCount == 1, routeResults == expectedRoutes,
                        model.downloads === owner, model.player != nil,
                        model.library?.session.accessToken == refreshed.accessToken,
                        fixture.credentialWrites == writes + 1, persistedPins == pins,
                        persistedPlayback == playback, persistedFile == bytes
                    else { throw CancellationError() }
                    try await fixture.drain(using: self)
                })
        }

        func testSameScopeRecoveryRetainsSyntheticNativeCallbackOwner() async throws {
            let authEntered = expectation(description: "same-account authentication held")
            let firstCompletion = expectation(description: "old native event completed")
            let lateCompletion = expectation(description: "late native event completed")
            let gate = LifecycleGate(entered: authEntered)
            defer { gate.release() }
            weak var routingModel: FoundationAppModel?
            var expectedOwner: FoundationDownloads?
            var routeResults: [Bool] = []
            try await withLifecycleFixture(
                leaseWaitStarted: {},
                backgroundReconcile: { identifier in
                    guard let owner = routingModel?.downloads, owner === expectedOwner else {
                        routeResults.append(false)
                        return false
                    }
                    let admitted = await owner.reconcileBackgroundSession(identifier)
                    routeResults.append(admitted)
                    return admitted
                },
                nativeRetirement: { identifiers, directory in
                    var retired: Set<String> = []
                    for identifier in identifiers {
                        do {
                            try FoundationNativeAllocationStore(
                                directory: directory, sessionIdentifier: identifier
                            ).retire()
                            retired.insert(identifier)
                        } catch {}
                    }
                    return retired
                },
                { fixture, model in
                    routingModel = model
                    defer {
                        gate.release()
                        expectedOwner = nil
                        routingModel = nil
                    }
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    var initial: FoundationSignInView.Acceptance?
                    var initialError: Error?
                    let preparation = Task {
                        do { initial = try await model.prepareSignIn { session } } catch {
                            initialError = error
                        }
                    }
                    fixture.tasks.append(preparation)
                    try await self.waitForTask(preparation, label: "native fixture preparation")
                    if let initialError { throw initialError }
                    let scope = FoundationMusicLibraryStore.digest(
                        "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                    let directory = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads)
                    try FoundationDownloadStorage.prepare(directory)
                    let identifier =
                        "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                        + "." + UUID().uuidString
                    let store = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    try store.reserve()
                    var manifest = FoundationDownloadManifest()
                    manifest.nativePendingSessions = [identifier]
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    let accept = try XCTUnwrap(initial)
                    var initialCommitError: Error?
                    let initialCommit = Task {
                        do { try await accept() } catch { initialCommitError = error }
                    }
                    fixture.tasks.append(initialCommit)
                    try await self.waitForTask(initialCommit, label: "native fixture acceptance")
                    if let initialCommitError { throw initialCommitError }
                    let owner = try XCTUnwrap(model.downloads)
                    expectedOwner = owner
                    let inventory = self.expectation(description: "native fixture inventory")
                    let observation = owner.$isLoading.filter { !$0 }.first().sink { _ in
                        inventory.fulfill()
                    }
                    defer { observation.cancel() }
                    try await self.waitForEvents([inventory], label: "native fixture inventory")
                    var authFailure: Error?
                    let authentication = Task {
                        do {
                            _ = try await model.prepareSignIn {
                                await gate.hold()
                                try Task.checkCancellation()
                                return session
                            }
                        } catch { authFailure = error }
                    }
                    fixture.tasks.append(authentication)
                    try await self.waitForEvents([authEntered], label: "held authentication")
                    model.receiveBackgroundDownloadEvents(identifier) { firstCompletion.fulfill() }
                    model.finishBackgroundDownloadEvents(identifier)
                    try await self.waitForEvents([firstCompletion], label: "old native event")
                    authentication.cancel()
                    gate.release()
                    try await self.waitForTask(
                        authentication, label: "cancelled native authentication")
                    XCTAssertTrue(authFailure is CancellationError)
                    XCTAssertTrue(model.downloads === owner)
                    let refreshed = FoundationSession(
                        serverURL: session.serverURL, accessToken: "new-synthetic-token",
                        userID: session.userID, deviceID: session.deviceID)
                    var next: FoundationSignInView.Acceptance?
                    var nextError: Error?
                    let nextPreparation = Task {
                        do { next = try await model.prepareSignIn { refreshed } } catch {
                            nextError = error
                        }
                    }
                    fixture.tasks.append(nextPreparation)
                    try await self.waitForTask(nextPreparation, label: "native reauth preparation")
                    if let nextError { throw nextError }
                    let nextAccept = try XCTUnwrap(next)
                    var commitError: Error?
                    let commit = Task {
                        do { try await nextAccept() } catch { commitError = error }
                    }
                    fixture.tasks.append(commit)
                    try await self.waitForTask(commit, label: "native reauth acceptance")
                    if let commitError { throw commitError }
                    XCTAssertTrue(model.downloads === owner)
                    model.receiveBackgroundDownloadEvents(identifier) { lateCompletion.fulfill() }
                    model.finishBackgroundDownloadEvents(identifier)
                    try await self.waitForEvents([lateCompletion], label: "late native event")
                    XCTAssertEqual(routeResults, [true, true])
                    XCTAssertTrue(FileManager.default.fileExists(atPath: store.receiptURL.path))
                    guard authFailure is CancellationError, model.downloads === owner,
                        routeResults == [true, true],
                        FileManager.default.fileExists(atPath: store.receiptURL.path)
                    else { throw CancellationError() }
                    try await fixture.drain(using: self)
                })
        }

        func testBackgroundRoutingReadinessChangesWhenLateEventArrives() async throws {
            let completed = expectation(description: "late background completion")
            try await withLifecycleFixture(
                backgroundReconcile: { _ in true },
                { fixture, model in
                    let token = try XCTUnwrap(model.beginBackgroundRoutingHandoff())
                    defer { _ = model.cancelBackgroundRoutingHandoff(token) }
                    let ready = await model.waitForBackgroundRoutingHandoff(token)
                    XCTAssertTrue(ready)
                    XCTAssertTrue(model.backgroundRoutingHandoffIsReady(token))
                    var count = 0
                    model.receiveBackgroundDownloadEvents("late") {
                        count += 1
                        completed.fulfill()
                    }
                    XCTAssertFalse(model.backgroundRoutingHandoffIsReady(token))
                    XCTAssertEqual(count, 0)
                    XCTAssertTrue(model.cancelBackgroundRoutingHandoff(token))
                    model.finishBackgroundDownloadEvents("late")
                    try await self.waitForEvents([completed], label: "late background completion")
                    XCTAssertEqual(count, 1)
                    try await fixture.drain(using: self)
                })
        }

        func testCredentialTransactionPreservesScopeAcrossInterruptedSignOut() async throws {
            try await withLifecycleFixture { fixture, _ in
                let root = fixture.root.appendingPathComponent(
                    "credential-transaction", isDirectory: true)
                let keychain = IntentKeychainFixture()
                let operations = keychain.operations()
                let session = fixture.session(user: "00000000000000000000000000000001")
                keychain.credentialData = try JSONEncoder().encode(session)
                let snapshot = try FoundationAccountCredentialTransaction.inspect(
                    root: root, operations: operations)
                XCTAssertNil(snapshot.intent)
                XCTAssertEqual(snapshot.session?.userID, session.userID)
                let intent = try FoundationAccountCredentialTransaction.prepareSignOut(
                    session, expecting: snapshot, root: root, operations: operations)
                XCTAssertEqual(keychain.credentialDeletes, 0)
                XCTAssertNotNil(keychain.credentialData)
                let afterRestart = try FoundationAccountCredentialTransaction.inspect(
                    root: root, operations: operations)
                XCTAssertEqual(afterRestart.intent, intent)
                XCTAssertEqual(afterRestart.session?.userID, session.userID)
                let different = fixture.session(user: "00000000000000000000000000000002")
                XCTAssertThrowsError(
                    try FoundationAccountCredentialTransaction.commitSignIn(
                        different, expecting: snapshot, root: root, operations: operations))
                XCTAssertNotNil(keychain.credentialData)
                XCTAssertEqual(
                    try FoundationSignOutIntentStore.load(operations: operations), intent)
                try FoundationAccountTransactionLock.withLock(root: root) {
                    XCTAssertThrowsError(
                        try FoundationAccountCredentialTransaction.inspect(
                            root: root, operations: operations))
                }
                let stamped = try FoundationAccountCredentialTransaction.inspect(
                    root: root, operations: operations)
                XCTAssertEqual(stamped.credentialGeneration, intent.credentialGeneration)
                XCTAssertNotNil(stamped.credentialGeneration)
                try FoundationAccountCredentialTransaction.finishSignOut(
                    session, intent: intent, expecting: stamped, root: root, operations: operations)
                XCTAssertEqual(keychain.credentialDeletes, 1)
                XCTAssertNil(keychain.credentialData)
                XCTAssertNil(try FoundationSignOutIntentStore.load(operations: operations))
            }
        }

        func testFinishSignOutFailureKeepsSavedCredentialAndIntent() async throws {
            try await withLifecycleFixture { fixture, _ in
                let root = fixture.root.appendingPathComponent(
                    "credential-transaction", isDirectory: true)
                let keychain = IntentKeychainFixture()
                let operations = keychain.operations()
                keychain.credentialGeneration = Data(UUID().uuidString.utf8)
                let session = fixture.session(user: "00000000000000000000000000000001")
                let bytes = try JSONEncoder().encode(session)
                keychain.credentialData = bytes
                let snapshot = try FoundationAccountCredentialTransaction.inspect(
                    root: root, operations: operations)
                let intent = try FoundationAccountCredentialTransaction.prepareSignOut(
                    session, expecting: snapshot, root: root, operations: operations)
                keychain.credentialDeleteStatus = errSecInteractionNotAllowed
                XCTAssertThrowsError(
                    try FoundationAccountCredentialTransaction.finishSignOut(
                        session, intent: intent, expecting: snapshot, root: root,
                        operations: operations))
                XCTAssertEqual(keychain.credentialData, bytes)
                XCTAssertEqual(keychain.credentialDeletes, 0)
                let completed = try XCTUnwrap(
                    FoundationSignOutIntentStore.load(operations: operations))
                XCTAssertEqual(completed.operation, intent.operation)
                XCTAssertEqual(completed.cleanupComplete, true)
                keychain.credentialDeleteStatus = errSecSuccess
                let originalGeneration = keychain.credentialGeneration
                keychain.credentialGeneration = Data(UUID().uuidString.utf8)
                XCTAssertThrowsError(
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        completed, root: root, operations: operations))
                XCTAssertEqual(keychain.credentialData, bytes)
                XCTAssertEqual(
                    try FoundationSignOutIntentStore.load(operations: operations), completed)
                keychain.credentialGeneration = originalGeneration
                try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                    completed, root: root, operations: operations)
                XCTAssertNil(keychain.credentialData)
                XCTAssertNil(try FoundationSignOutIntentStore.load(operations: operations))
            }
        }

        func testFreshCredentialResumesInterruptedCompletedSignOut() async throws {
            try await withLifecycleFixture { fixture, _ in
                let keychain = IntentKeychainFixture()
                keychain.credentialData = nil
                let operations = keychain.operations()
                let session = fixture.session(user: "00000000000000000000000000000001")
                let transactionRoot = fixture.root.appendingPathComponent(
                    "credential-transaction", isDirectory: true)
                let sentinel = fixture.root.appendingPathComponent("other-account-sentinel")
                let sentinelBytes = Data("unrelated-synthetic-data".utf8)
                try FileManager.default.createDirectory(
                    at: fixture.root, withIntermediateDirectories: true)
                try sentinelBytes.write(to: sentinel)
                // Match the current ordinary sign-in save, including its default generation argument.
                try FoundationCredentials.save(session, operations: operations)
                let snapshot = try FoundationAccountCredentialTransaction.inspect(
                    root: transactionRoot, operations: operations)
                XCTAssertNil(snapshot.credentialGeneration)
                XCTAssertEqual(snapshot.session?.userID, session.userID)
                let intent = try FoundationAccountCredentialTransaction.prepareSignOut(
                    session, expecting: snapshot, root: transactionRoot, operations: operations)
                let stamped = try FoundationAccountCredentialTransaction.inspect(
                    root: transactionRoot, operations: operations)
                XCTAssertNotNil(stamped.credentialGeneration)
                XCTAssertEqual(stamped.credentialGeneration, intent.credentialGeneration)
                XCTAssertEqual(stamped.session?.accessToken, session.accessToken)
                // Fail the credential deletion only after the cleanup-complete marker is written.
                keychain.credentialDeleteStatus = errSecInteractionNotAllowed
                XCTAssertThrowsError(
                    try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                        session, intent: intent, expecting: stamped, root: transactionRoot,
                        operations: operations))
                let completed = try XCTUnwrap(
                    FoundationSignOutIntentStore.load(operations: operations))
                XCTAssertEqual(completed.cleanupComplete, true)
                XCTAssertEqual(
                    try FoundationCredentials.load(operations: operations)?.accessToken,
                    session.accessToken)
                guard snapshot.credentialGeneration == nil, completed.cleanupComplete == true,
                    try FoundationCredentials.load(operations: operations)?.accessToken
                        == session.accessToken
                else { throw CancellationError() }
                keychain.credentialDeleteStatus = errSecSuccess
                do {
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        completed, root: transactionRoot, operations: operations)
                } catch {
                    // Retain the fixture and show the observed pending state without disclosing credentials.
                    XCTAssertEqual(
                        try FoundationSignOutIntentStore.load(operations: operations), completed)
                    XCTAssertEqual(
                        try FoundationCredentials.load(operations: operations)?.accessToken,
                        session.accessToken)
                    XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
                    XCTFail("Fresh credential could not resume the completed local sign-out")
                    throw error
                }
                XCTAssertNil(try FoundationSignOutIntentStore.load(operations: operations))
                XCTAssertNil(try FoundationCredentials.load(operations: operations))
                XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
                guard try FoundationSignOutIntentStore.load(operations: operations) == nil,
                    try FoundationCredentials.load(operations: operations) == nil,
                    try Data(contentsOf: sentinel) == sentinelBytes
                else { throw CancellationError() }
            }
        }

        func testFreshCredentialModelSignOutAdoptsStampedIdentity() async throws {
            let entered = expectation(description: "sign-out finalization held")
            let cleanupGate = LifecycleGate(entered: entered)
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "synthetic revocation entered"))
            let keychain = IntentKeychainFixture()
            keychain.credentialData = nil
            let operations = keychain.operations()
            let root = fixture.root.appendingPathComponent("generation-model", isDirectory: true)
            let session = fixture.session(user: "00000000000000000000000000000001")
            let transactions = FoundationAccountTransactions(
                inspect: {
                    try FoundationAccountCredentialTransaction.inspect(
                        root: root, operations: operations)
                },
                prepareSignOut: { value, expected, preparation in
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        value, expecting: expected, preparation: preparation, root: root,
                        operations: operations)
                },
                finishCompletedSignOut: { marker in
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        marker, root: root, operations: operations)
                },
                recordSignOut: { value, marker, expected in
                    await cleanupGate.hold()
                    return try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                        value, intent: marker, expecting: expected, root: root,
                        operations: operations)
                })
            do {
                let model = fixture.makeModel(
                    inspectSignOutIntent: {
                        do {
                            return try FoundationSignOutIntentStore.load(operations: operations)
                                == nil ? .absent : .pending
                        } catch { return .unavailable }
                    }, accountTransactions: transactions, credentialOperations: operations)
                let startup = Task { _ = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForTask(startup, label: "fresh credential startup")
                try await fixture.open(model, user: session.userID)
                let original = try XCTUnwrap(keychain.credentialData)
                XCTAssertNil(keychain.credentialGeneration)
                let player = try XCTUnwrap(model.player)
                let finished = XCTestExpectation(description: "sign-out finished")
                let observation = model.$isFinalizingDurableSignOut.dropFirst().filter { !$0 }
                    .first().sink { _ in
                        finished.fulfill()
                    }
                defer {
                    observation.cancel()
                    cleanupGate.release()
                    fixture.gate.release()
                }
                model.signOut()
                fixture.captureStop(player)
                try await waitForEvents([entered], label: "fresh credential finalization")
                let marker = try XCTUnwrap(
                    FoundationSignOutIntentStore.load(operations: operations))
                XCTAssertNotNil(marker.credentialGeneration)
                XCTAssertEqual(marker.credentialGeneration, keychain.credentialGeneration)
                XCTAssertEqual(keychain.credentialData, original)
                XCTAssertEqual(keychain.credentialDeletes, 0)
                guard marker.credentialGeneration != nil,
                    marker.credentialGeneration == keychain.credentialGeneration,
                    keychain.credentialData == original, keychain.credentialDeletes == 0
                else { throw CancellationError() }
                cleanupGate.release()
                try await waitForEvents([finished], label: "fresh credential completion")
                XCTAssertNil(try FoundationSignOutIntentStore.load(operations: operations))
                XCTAssertNil(keychain.credentialData)
                fixture.gate.release()
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                cleanupGate.release()
                fixture.gate.release()
                try await fixture.drain(using: self)
                throw error
            }
        }

        func testSignOutUnverifiedInitialIdentityRequiresRestart() async throws {
            for scenario in ["locked", "replacement", "handoff-invalidated"] {
                let fixture = try LifecycleFixture(
                    entered: XCTestExpectation(description: "synthetic revocation"))
                let inspectEntered = XCTestExpectation(description: "held initial inspection")
                let inspectGate = LifecycleGate(entered: inspectEntered)
                defer {
                    inspectGate.release()
                    fixture.gate.release()
                }
                let keychain = IntentKeychainFixture()
                keychain.credentialData = nil
                let operations = keychain.operations()
                let root = fixture.root.appendingPathComponent(
                    "initial-unverified", isDirectory: true)
                let session = fixture.session(user: "00000000000000000000000000000001")
                var holdInspection = false
                let transactions = FoundationAccountTransactions(
                    inspect: {
                        if holdInspection { await inspectGate.hold() }
                        return try FoundationAccountCredentialTransaction.inspect(
                            root: root, operations: operations)
                    },
                    prepareSignOut: { value, expected, preparation in
                        try FoundationAccountCredentialTransaction.prepareSignOut(
                            value, expecting: expected, preparation: preparation, root: root,
                            operations: operations)
                    },
                    finishCompletedSignOut: { marker in
                        try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                            marker, root: root, operations: operations)
                    },
                    recordSignOut: { value, marker, expected in
                        try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                            value, intent: marker, expecting: expected, root: root,
                            operations: operations)
                    })
                do {
                    let model = fixture.makeModel(
                        inspectSignOutIntent: {
                            do {
                                return try FoundationSignOutIntentStore.load(operations: operations)
                                    == nil ? .absent : .pending
                            } catch { return .unavailable }
                        }, accountTransactions: transactions, credentialOperations: operations)
                    let startup = Task { _ = await model.ensureReady() }
                    fixture.tasks.append(startup)
                    try await waitForTask(startup, label: "unverified initial startup")
                    try await fixture.open(model, user: session.userID)
                    let owner = try XCTUnwrap(model.downloads)
                    let player = try XCTUnwrap(model.player)
                    if scenario == "locked" { keychain.readStatus = errSecInteractionNotAllowed }
                    if scenario == "replacement" {
                        keychain.credentialData = try JSONEncoder().encode(
                            fixture.session(user: "00000000000000000000000000000002"))
                    }
                    let protectedCredential = keychain.credentialData
                    let unavailable = XCTestExpectation(description: "unverified initial status")
                    let observer = model.$accountInspectionIssue.filter { $0 == .unavailable }
                        .first().sink { _ in unavailable.fulfill() }
                    defer { observer.cancel() }
                    holdInspection = scenario == "handoff-invalidated"
                    model.signOut()
                    if holdInspection {
                        try await waitForEvents([inspectEntered], label: "held initial inspection")
                        owner.invalidate()
                        inspectGate.release()
                    }
                    try await waitForEvents([unavailable], label: "unverified initial status")
                    fixture.captureStop(player)
                    XCTAssertTrue(model.downloads === owner)
                    XCTAssertTrue(model.uncertainSignOutRequiresRestart)
                    XCTAssertTrue(model.isolatedAccountTransitionHeld)
                    XCTAssertEqual(keychain.credentialData, protectedCredential)
                    XCTAssertNil(keychain.payload)
                    XCTAssertEqual(keychain.credentialDeletes, 0)
                    model.retryAccountInspection()
                    XCTAssertEqual(model.accountInspectionIssue, .unavailable)
                    guard model.uncertainSignOutRequiresRestart,
                        model.isolatedAccountTransitionHeld,
                        model.downloads === owner, model.accountInspectionIssue == .unavailable,
                        keychain.credentialData == protectedCredential,
                        keychain.payload == nil, keychain.credentialDeletes == 0
                    else { throw CancellationError() }
                    inspectGate.release()
                    fixture.gate.release()
                    try await fixture.drain(using: self)
                    fixture.removeData()
                } catch {
                    inspectGate.release()
                    fixture.gate.release()
                    try await fixture.drain(using: self)
                    throw error
                }
            }
        }

        func testUncertainSignOutRetriesExactMarkerAndPreservesData() async throws {
            for scenario in [
                "present", "absent", "locked", "replacement", "wrong-marker", "generation-only",
            ] {
                let fixture = try LifecycleFixture(
                    entered: XCTestExpectation(description: "synthetic revocation"))
                let keychain = IntentKeychainFixture()
                keychain.credentialData = nil
                let operations = keychain.operations()
                let root = fixture.root.appendingPathComponent("uncertain-retry", isDirectory: true)
                let session = fixture.session(user: "00000000000000000000000000000001")
                let transactions = FoundationAccountTransactions(
                    inspect: {
                        try FoundationAccountCredentialTransaction.inspect(
                            root: root, operations: operations)
                    },
                    prepareSignOut: { value, expected, preparation in
                        try FoundationAccountCredentialTransaction.prepareSignOut(
                            value, expecting: expected, preparation: preparation, root: root,
                            operations: operations)
                    },
                    finishCompletedSignOut: { marker in
                        try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                            marker, root: root, operations: operations)
                    },
                    recordSignOut: { value, marker, expected in
                        try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                            value, intent: marker, expecting: expected, root: root,
                            operations: operations)
                    })
                do {
                    let model = fixture.makeModel(
                        inspectSignOutIntent: {
                            do {
                                return try FoundationSignOutIntentStore.load(operations: operations)
                                    == nil ? .absent : .pending
                            } catch { return .unavailable }
                        }, accountTransactions: transactions, credentialOperations: operations)
                    let startup = Task { _ = await model.ensureReady() }
                    fixture.tasks.append(startup)
                    try await waitForTask(startup, label: "uncertain retry startup")
                    try await fixture.open(model, user: session.userID)
                    let original = try XCTUnwrap(keychain.credentialData)
                    let owner = try XCTUnwrap(model.downloads)
                    let player = try XCTUnwrap(model.player)
                    let unavailable = XCTestExpectation(description: "uncertain sign-out")
                    let observer = model.$accountInspectionIssue.filter { $0 == .unavailable }
                        .first().sink { _ in unavailable.fulfill() }
                    defer {
                        observer.cancel()
                        fixture.gate.release()
                    }
                    if scenario == "absent" {
                        keychain.addStatus = errSecInteractionNotAllowed
                    } else {
                        keychain.readbackStatusAfterAdd = errSecInteractionNotAllowed
                    }
                    model.signOut()
                    try await waitForEvents([unavailable], label: "uncertain sign-out")
                    XCTAssertTrue(model.downloads === owner)
                    XCTAssertTrue(model.player === player)
                    XCTAssertEqual(keychain.credentialData, original)
                    XCTAssertEqual(keychain.credentialDeletes, 0)
                    guard model.downloads === owner, model.player === player,
                        keychain.credentialData == original, keychain.credentialDeletes == 0
                    else { throw CancellationError() }
                    if scenario == "locked" {
                        let checked = XCTestExpectation(
                            description: "locked reinspection completed")
                        let checkObserver = model.$isCheckingPendingSignOut.dropFirst().filter {
                            !$0
                        }.first().sink { _ in checked.fulfill() }
                        model.retryAccountInspection()
                        model.retryAccountInspection()
                        try await waitForEvents([checked], label: "locked reinspection")
                        checkObserver.cancel()
                        XCTAssertEqual(model.accountInspectionIssue, .unavailable)
                        XCTAssertEqual(keychain.credentialData, original)
                    }
                    keychain.readStatus = errSecSuccess
                    if scenario == "replacement" || scenario == "wrong-marker"
                        || scenario == "generation-only"
                    {
                        if scenario == "replacement" {
                            let replacement = fixture.session(
                                user: "00000000000000000000000000000002")
                            keychain.credentialData = try JSONEncoder().encode(replacement)
                        } else if scenario == "generation-only" {
                            let first = Data("00000000-0000-4000-8000-000000000000".utf8)
                            let second = Data("00000000-0000-4000-8000-000000000001".utf8)
                            keychain.credentialGeneration =
                                keychain.credentialGeneration == first ? second : first
                        } else {
                            let existing = try XCTUnwrap(
                                FoundationSignOutIntentStore.load(operations: operations))
                            let other = FoundationSignOutIntentStore.Intent(
                                version: existing.version, operation: UUID(), scope: existing.scope,
                                accessGroup: existing.accessGroup,
                                credentialGeneration: existing.credentialGeneration)
                            keychain.generic = Data(other.operation.uuidString.utf8)
                            keychain.payload = try JSONEncoder().encode(other)
                        }
                        let protectedCredential = keychain.credentialData
                        let protectedMarker = keychain.payload
                        let protectedGroup = keychain.group
                        let protectedGeneration = keychain.credentialGeneration
                        if scenario == "generation-only" {
                            XCTAssertEqual(protectedCredential, original)
                        }
                        let checked = XCTestExpectation(
                            description: "replacement reinspection completed")
                        let checkObserver = model.$isCheckingPendingSignOut.dropFirst().filter {
                            !$0
                        }.first().sink { _ in checked.fulfill() }
                        model.retryAccountInspection()
                        model.retryAccountInspection()
                        try await waitForEvents([checked], label: "replacement reinspection")
                        checkObserver.cancel()
                        XCTAssertEqual(model.accountInspectionIssue, .unavailable)
                        XCTAssertTrue(model.downloads === owner)
                        XCTAssertNotNil(keychain.payload)
                        XCTAssertEqual(keychain.credentialData, protectedCredential)
                        XCTAssertEqual(keychain.payload, protectedMarker)
                        XCTAssertEqual(keychain.group, protectedGroup)
                        XCTAssertEqual(keychain.credentialGeneration, protectedGeneration)
                        XCTAssertEqual(keychain.credentialDeletes, 0)
                        guard model.accountInspectionIssue == .unavailable,
                            model.downloads === owner,
                            keychain.payload != nil, keychain.payload == protectedMarker,
                            keychain.credentialData == protectedCredential,
                            keychain.group == protectedGroup,
                            keychain.credentialGeneration == protectedGeneration,
                            keychain.credentialDeletes == 0,
                            scenario != "generation-only" || protectedCredential == original
                        else { throw CancellationError() }
                    } else {
                        let finished = XCTestExpectation(description: "exact retry finished")
                        let finishedObserver = model.$accountInspectionIssue.dropFirst().filter {
                            $0 == nil
                        }.first().sink { _ in finished.fulfill() }
                        defer { finishedObserver.cancel() }
                        model.retryAccountInspection()
                        model.retryAccountInspection()
                        try await waitForEvents([finished], label: "exact retry finished")
                        if scenario == "absent" {
                            XCTAssertTrue(model.downloads === owner)
                            XCTAssertTrue(model.player === player)
                            XCTAssertEqual(keychain.credentialData, original)
                            XCTAssertNil(keychain.payload)
                            XCTAssertEqual(keychain.credentialDeletes, 0)
                            guard model.downloads === owner, model.player === player,
                                keychain.credentialData == original, keychain.payload == nil,
                                keychain.credentialDeletes == 0
                            else { throw CancellationError() }
                        } else {
                            XCTAssertNil(keychain.credentialData)
                            XCTAssertNil(keychain.payload)
                            guard keychain.credentialData == nil, keychain.payload == nil else {
                                throw CancellationError()
                            }
                        }
                    }
                    fixture.gate.release()
                    try await fixture.drain(using: self)
                    fixture.removeData()
                } catch {
                    fixture.gate.release()
                    try await fixture.drain(using: self)
                    throw error
                }
            }
        }

        func testCancelledPreparationWaitsForWrittenMarkerBeforeRetry() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "synthetic revocation"))
            let written = XCTestExpectation(description: "marker written before cancellation")
            let writeGate = LifecycleGate(entered: written)
            defer {
                writeGate.release()
                fixture.gate.release()
            }
            let keychain = IntentKeychainFixture()
            keychain.credentialData = nil
            let operations = keychain.operations()
            let root = fixture.root.appendingPathComponent(
                "cancelled-preparation", isDirectory: true)
            let session = fixture.session(user: "00000000000000000000000000000001")
            let transactions = FoundationAccountTransactions(
                inspect: {
                    try FoundationAccountCredentialTransaction.inspect(
                        root: root, operations: operations)
                },
                prepareSignOut: { value, expected, preparation in
                    let marker = try FoundationAccountCredentialTransaction.prepareSignOut(
                        value, expecting: expected, preparation: preparation, root: root,
                        operations: operations)
                    await writeGate.hold()
                    return marker
                },
                finishCompletedSignOut: { marker in
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        marker, root: root, operations: operations)
                },
                recordSignOut: { value, marker, expected in
                    try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                        value, intent: marker, expecting: expected, root: root,
                        operations: operations)
                })
            do {
                let model = fixture.makeModel(
                    inspectSignOutIntent: {
                        do {
                            return try FoundationSignOutIntentStore.load(operations: operations)
                                == nil ? .absent : .pending
                        } catch { return .unavailable }
                    }, accountTransactions: transactions, credentialOperations: operations)
                let startup = Task { _ = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForTask(startup, label: "cancelled preparation startup")
                try await fixture.open(model, user: session.userID)
                let owner = try XCTUnwrap(model.downloads)
                let original = try XCTUnwrap(keychain.credentialData)
                let unavailable = XCTestExpectation(description: "cancelled preparation pending")
                let unavailableObserver = model.$accountInspectionIssue.filter {
                    $0 == .unavailable
                }.first().sink { _ in unavailable.fulfill() }
                defer { unavailableObserver.cancel() }
                model.signOut()
                try await waitForEvents([written], label: "held marker write")
                let marker = try XCTUnwrap(
                    FoundationSignOutIntentStore.load(operations: operations))
                let preparationTask = try XCTUnwrap(model.isolatedSignOutPreparationTask)
                preparationTask.cancel()
                model.retryAccountInspection()
                XCTAssertTrue(writeGate.isHeld)
                XCTAssertTrue(model.downloads === owner)
                XCTAssertEqual(keychain.credentialData, original)
                XCTAssertEqual(
                    try FoundationSignOutIntentStore.load(operations: operations), marker)
                guard writeGate.isHeld, model.downloads === owner,
                    keychain.credentialData == original,
                    try FoundationSignOutIntentStore.load(operations: operations) == marker
                else { throw CancellationError() }
                writeGate.release()
                try await waitForEvents([unavailable], label: "cancelled preparation pending")
                let finished = XCTestExpectation(description: "cancelled marker retry finished")
                let finishedObserver = model.$accountInspectionIssue.dropFirst().filter {
                    $0 == nil
                }.first().sink { _ in finished.fulfill() }
                defer { finishedObserver.cancel() }
                model.retryAccountInspection()
                try await waitForEvents([finished], label: "cancelled marker retry")
                XCTAssertNil(keychain.credentialData)
                XCTAssertNil(keychain.payload)
                guard keychain.credentialData == nil, keychain.payload == nil else {
                    throw CancellationError()
                }
                fixture.gate.release()
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                writeGate.release()
                fixture.gate.release()
                try await fixture.drain(using: self)
                throw error
            }
        }

        func testUncertainRetryKeepsEarlierBackgroundEventWithOldOwner() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "synthetic revocation"))
            let entered = XCTestExpectation(description: "old event routing entered")
            let routeGate = LifecycleGate(entered: entered)
            defer {
                routeGate.release()
                fixture.gate.release()
            }
            let keychain = IntentKeychainFixture()
            keychain.credentialData = nil
            let operations = keychain.operations()
            let root = fixture.root.appendingPathComponent("uncertain-event", isDirectory: true)
            let session = fixture.session(user: "00000000000000000000000000000001")
            let transactions = FoundationAccountTransactions(
                inspect: {
                    try FoundationAccountCredentialTransaction.inspect(
                        root: root, operations: operations)
                },
                prepareSignOut: { value, expected, preparation in
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        value, expecting: expected, preparation: preparation, root: root,
                        operations: operations)
                },
                finishCompletedSignOut: { marker in
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        marker, root: root, operations: operations)
                },
                recordSignOut: { value, marker, expected in
                    try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                        value, intent: marker, expecting: expected, root: root,
                        operations: operations)
                })
            do {
                let model = fixture.makeModel(
                    backgroundReconcile: { _ in
                        await routeGate.hold()
                        return true
                    },
                    useModelBackgroundRouting: true,
                    inspectSignOutIntent: {
                        do {
                            return try FoundationSignOutIntentStore.load(operations: operations)
                                == nil ? .absent : .pending
                        } catch { return .unavailable }
                    }, accountTransactions: transactions, credentialOperations: operations)
                let startup = Task { _ = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForTask(startup, label: "old event startup")
                try await fixture.open(model, user: session.userID)
                let owner = try XCTUnwrap(model.downloads)
                let scope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
                    + UUID().uuidString
                let completed = XCTestExpectation(description: "old event completion")
                var completions = 0
                model.receiveBackgroundDownloadEvents(identifier) {
                    completions += 1
                    completed.fulfill()
                }
                model.finishBackgroundDownloadEvents(identifier)
                try await waitForEvents([entered], label: "held old event")
                let unavailable = XCTestExpectation(description: "uncertain marker")
                let unavailableObserver = model.$accountInspectionIssue.filter {
                    $0 == .unavailable
                }.first().sink { _ in unavailable.fulfill() }
                defer { unavailableObserver.cancel() }
                keychain.readbackStatusAfterAdd = errSecInteractionNotAllowed
                model.signOut()
                try await waitForEvents([unavailable], label: "uncertain marker")
                XCTAssertTrue(model.downloads === owner)
                XCTAssertEqual(completions, 0)
                keychain.readStatus = errSecSuccess
                let cleanupStarted = XCTestExpectation(description: "adopted cleanup")
                let cleanupObserver = model.$isCleaningDownloads.dropFirst().filter { $0 }.first()
                    .sink { _ in cleanupStarted.fulfill() }
                let finished = XCTestExpectation(description: "sign-out finished")
                let finishedObserver = model.$accountInspectionIssue.dropFirst().filter {
                    $0 == nil
                }.first().sink { _ in finished.fulfill() }
                defer {
                    cleanupObserver.cancel()
                    finishedObserver.cancel()
                }
                model.retryAccountInspection()
                try await waitForEvents([cleanupStarted], label: "adopted cleanup")
                XCTAssertEqual(completions, 0)
                XCTAssertNotNil(keychain.credentialData)
                guard completions == 0, keychain.credentialData != nil, routeGate.isHeld else {
                    throw CancellationError()
                }
                routeGate.release()
                try await waitForEvents([completed, finished], label: "old event and sign-out")
                XCTAssertEqual(completions, 1)
                XCTAssertNil(keychain.credentialData)
                XCTAssertNil(keychain.payload)
                guard completions == 1, keychain.credentialData == nil, keychain.payload == nil
                else { throw CancellationError() }
                fixture.gate.release()
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                routeGate.release()
                fixture.gate.release()
                try await fixture.drain(using: self)
                throw error
            }
        }

        func testDurableSignOutWaitsForActionAndPinSyncBeforeScopedCleanup() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            let actionEntered = XCTestExpectation(description: "held favorite mutation")
            let cloudEntered = XCTestExpectation(description: "held synthetic pin exchange")
            let actionGate = LifecycleGate(entered: actionEntered)
            let cloudGate = LifecycleGate(entered: cloudEntered)
            defer {
                actionGate.release()
                cloudGate.release()
                fixture.gate.release()
            }
            let keychain = IntentKeychainFixture()
            keychain.credentialData = nil
            let operations = keychain.operations()
            let root = fixture.root.appendingPathComponent(
                "owner-drain-transaction", isDirectory: true)
            let session = fixture.session(user: "00000000000000000000000000000001")
            let transactions = FoundationAccountTransactions(
                inspect: {
                    try FoundationAccountCredentialTransaction.inspect(
                        root: root, operations: operations)
                },
                prepareSignOut: { value, expected, preparation in
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        value, expecting: expected, preparation: preparation, root: root,
                        operations: operations)
                },
                finishCompletedSignOut: { marker in
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        marker, root: root, operations: operations)
                },
                recordSignOut: { value, marker, expected in
                    try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                        value, intent: marker, expecting: expected, root: root,
                        operations: operations)
                })
            do {
                let model = fixture.makeModel(
                    inspectSignOutIntent: {
                        do {
                            return try FoundationSignOutIntentStore.load(operations: operations)
                                == nil ? .absent : .pending
                        } catch { return .unavailable }
                    }, accountTransactions: transactions, credentialOperations: operations)
                let startup = Task { _ = await model.ensureReady() }
                fixture.tasks.append(startup)
                try await waitForTask(startup, label: "action-drain startup")
                try await fixture.open(model, user: session.userID)
                let actions = try XCTUnwrap(model.actions)
                actions.isolatedSetFavoriteMutation { _, _ in await actionGate.hold() }
                actions.togglePin(fixture.album)
                let scope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                let key = FoundationPinStorage.key(for: scope)
                let originalPins = try XCTUnwrap(fixture.defaults.data(forKey: key))
                let otherKey = FoundationPinStorage.key(for: String(repeating: "b", count: 64))
                let otherBytes = Data("unrelated scope".utf8)
                fixture.defaults.set(otherBytes, forKey: otherKey)
                let state = FoundationPinSyncState(scope: scope)
                let sync = FoundationPinSync(
                    scope: scope, containerIdentifier: nil, defaults: fixture.defaults,
                    exchange: { _, _, _, _, _, _ in
                        await cloudGate.hold()
                        return .init(state: state, account: "synthetic", reset: false)
                    }, currentPins: { [] }, apply: { _, _ in XCTFail("Retired sync applied data") })
                actions.isolatedInstallPinSync(sync)
                sync.setEnabled(true)
                let exchange = try XCTUnwrap(sync.task)
                fixture.tasks.append(exchange)
                let favorite = Task {
                    await actions.setFavorite(for: fixture.album, isFavorite: true)
                }
                fixture.tasks.append(favorite)
                try await waitForEvents([actionEntered, cloudEntered], label: "held account work")
                let originalCredential = try XCTUnwrap(keychain.credentialData)
                let player = try XCTUnwrap(model.player)
                let cleaning = XCTestExpectation(description: "cleanup started")
                let joining = XCTestExpectation(description: "action drain started")
                model.isolatedActionDrainStarted = { joining.fulfill() }
                let finished = XCTestExpectation(description: "cleanup completed")
                let startedObserver = model.$isCleaningDownloads.dropFirst().filter { $0 }.first()
                    .sink { _ in cleaning.fulfill() }
                let finishedObserver = model.$isFinalizingDurableSignOut.dropFirst().filter { !$0 }
                    .first().sink { _ in finished.fulfill() }
                defer {
                    startedObserver.cancel()
                    finishedObserver.cancel()

                    model.isolatedActionDrainStarted = nil
                }
                model.signOut()
                fixture.captureStop(player)
                try await waitForEvents(
                    [cleaning, joining], label: "cleanup and action drain started")
                let marker = try XCTUnwrap(
                    FoundationSignOutIntentStore.load(operations: operations))
                XCTAssertNotEqual(marker.cleanupComplete, true)
                XCTAssertEqual(fixture.defaults.data(forKey: key), originalPins)
                XCTAssertEqual(keychain.credentialData, originalCredential)
                XCTAssertTrue(actionGate.isHeld)
                XCTAssertTrue(cloudGate.isHeld)
                guard marker.cleanupComplete != true,
                    fixture.defaults.data(forKey: key) == originalPins,
                    keychain.credentialData == originalCredential, actionGate.isHeld,
                    cloudGate.isHeld
                else { throw CancellationError() }
                actionGate.release()
                try await waitForTask(favorite, label: "favorite operation drained")
                XCTAssertTrue(cloudGate.isHeld)
                XCTAssertEqual(fixture.defaults.data(forKey: key), originalPins)
                XCTAssertEqual(keychain.credentialData, originalCredential)
                guard cloudGate.isHeld, fixture.defaults.data(forKey: key) == originalPins,
                    keychain.credentialData == originalCredential
                else { throw CancellationError() }
                cloudGate.release()
                try await waitForEvents([finished], label: "cleanup completed")
                XCTAssertNil(fixture.defaults.data(forKey: key))
                XCTAssertEqual(fixture.defaults.data(forKey: otherKey), otherBytes)
                XCTAssertNil(keychain.credentialData)
                XCTAssertNil(try FoundationSignOutIntentStore.load(operations: operations))
                guard fixture.defaults.data(forKey: key) == nil,
                    fixture.defaults.data(forKey: otherKey) == otherBytes,
                    keychain.credentialData == nil,
                    try FoundationSignOutIntentStore.load(operations: operations) == nil
                else { throw CancellationError() }
                fixture.gate.release()
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                actionGate.release()
                cloudGate.release()
                fixture.gate.release()
                try await fixture.drain(using: self)
                throw error
            }
        }

        func testActionOwnerRejectsPinSyncReplacement() async throws {
            try await withLifecycleFixture { fixture, _ in
                let scope = String(repeating: "a", count: 64)
                let actions = FoundationLibraryActions(
                    sourceScope: scope, read: { fixture.defaults.data(forKey: $0) },
                    write: { fixture.defaults.set($1, forKey: $0) }, mutateFavorite: { _, _ in })
                actions.configurePinSync(
                    sourceScope: scope, containerIdentifier: nil, resolve: { _ in nil })
                let original = try XCTUnwrap(actions.pinSync)
                actions.configurePinSync(
                    sourceScope: scope, containerIdentifier: nil, resolve: { _ in nil })
                XCTAssertTrue(actions.pinSync === original)
                XCTAssertEqual(
                    actions.pinErrorMessage, "Pin sync is already configured for this library.")
                actions.invalidate()
            }
        }

        func testPinSyncCloudEraseRequiresExplicitRetryAfterPriorExchange() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            let firstEntered = XCTestExpectation(description: "first exchange")
            let secondEntered = XCTestExpectation(description: "replacement sync")
            let eraseEntered = XCTestExpectation(description: "explicit erase retry")
            let firstGate = LifecycleGate(entered: firstEntered)
            let secondGate = LifecycleGate(entered: secondEntered)
            defer {
                firstGate.release()
                secondGate.release()
                fixture.gate.release()
            }
            let counter = IsolatedExchangeCounter()
            let scope = String(repeating: "a", count: 64)
            let state = FoundationPinSyncState(scope: scope)
            let sync = FoundationPinSync(
                scope: scope, containerIdentifier: nil, defaults: fixture.defaults,
                exchange: { _, _, _, _, _, erase in
                    let call = await counter.next()
                    if call == 1, !erase {
                        await firstGate.hold()
                    } else if call == 2, !erase {
                        await secondGate.hold()
                    } else if call == 3, erase {
                        eraseEntered.fulfill()
                    } else {
                        throw CancellationError()
                    }
                    return .init(state: state, account: "synthetic", reset: false)
                }, currentPins: { [] }, apply: { _, _ in })
            do {
                sync.setEnabled(true)
                let first = try XCTUnwrap(sync.task)
                fixture.tasks.append(first)
                try await waitForEvents([firstEntered], label: "first exchange")
                sync.setEnabled(false)
                sync.setEnabled(true)
                sync.deleteCloudPins()
                XCTAssertEqual(sync.message, "A previous sync is still finishing. Try again.")
                let firstCount = await counter.count()
                XCTAssertEqual(firstCount, 1)
                firstGate.release()
                try await waitForEvents([secondEntered], label: "replacement sync")
                let second = try XCTUnwrap(sync.task)
                fixture.tasks.append(second)
                secondGate.release()
                try await waitForTask(second, label: "replacement sync completed")
                let beforeRetry = await counter.count()
                XCTAssertEqual(beforeRetry, 2)
                sync.deleteCloudPins()
                let erase = try XCTUnwrap(sync.task)
                fixture.tasks.append(erase)
                try await waitForEvents([eraseEntered], label: "explicit erase retry")
                try await waitForTask(erase, label: "synthetic erase")
                let afterRetry = await counter.count()
                XCTAssertEqual(afterRetry, 3)
                guard firstCount == 1, beforeRetry == 2, afterRetry == 3 else {
                    throw CancellationError()
                }
                sync.invalidate()
                fixture.gate.release()
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                sync.invalidate()
                firstGate.release()
                secondGate.release()
                fixture.gate.release()
                try await fixture.drain(using: self)
                throw error
            }
        }

        func testPinSyncSerializesReplacementAndDrainsOnRetirement() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            let firstEntered = XCTestExpectation(description: "first exchange")
            let secondEntered = XCTestExpectation(description: "replacement exchange")
            let firstGate = LifecycleGate(entered: firstEntered)
            let secondGate = LifecycleGate(entered: secondEntered)
            defer {
                firstGate.release()
                secondGate.release()
                fixture.gate.release()
            }
            let counter = IsolatedExchangeCounter()
            let scope = String(repeating: "a", count: 64)
            let state = FoundationPinSyncState(scope: scope)
            let sync = FoundationPinSync(
                scope: scope, containerIdentifier: nil, defaults: fixture.defaults,
                exchange: { _, _, _, _, _, erase in
                    guard !erase else { throw CancellationError() }
                    let call = await counter.next()
                    if call == 1 {
                        await firstGate.hold()
                    } else if call == 2 {
                        await secondGate.hold()
                    } else {
                        throw CancellationError()
                    }
                    return .init(state: state, account: "synthetic", reset: false)
                }, currentPins: { [] }, apply: { _, _ in })
            do {
                sync.setEnabled(true)
                let first = try XCTUnwrap(sync.task)
                fixture.tasks.append(first)
                try await waitForEvents([firstEntered], label: "first exchange")
                sync.setEnabled(false)
                sync.setEnabled(true)
                XCTAssertNil(sync.task)
                XCTAssertTrue(firstGate.isHeld)
                sync.deleteCloudPins()
                XCTAssertEqual(sync.message, "A previous sync is still finishing. Try again.")
                let count = await counter.count()
                XCTAssertEqual(count, 1)
                firstGate.release()
                try await waitForEvents([secondEntered], label: "replacement exchange")
                let second = try XCTUnwrap(sync.task)
                fixture.tasks.append(second)
                let retained = try XCTUnwrap(sync.invalidateAndCaptureExchange())
                let joining = XCTestExpectation(description: "retirement join started")
                let joined = XCTestExpectation(description: "retirement joined")
                var completed = false
                let join = Task {
                    joining.fulfill()
                    await retained.value
                    completed = true
                    joined.fulfill()
                }
                fixture.tasks.append(join)
                try await waitForEvents([joining], label: "retirement join start")
                XCTAssertFalse(completed)
                XCTAssertTrue(secondGate.isHeld)
                guard !completed, secondGate.isHeld else { throw CancellationError() }
                secondGate.release()
                try await waitForEvents([joined], label: "retirement join")
                XCTAssertTrue(completed)
                XCTAssertNil(sync.task)
                fixture.gate.release()
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                sync.invalidate()
                firstGate.release()
                secondGate.release()
                fixture.gate.release()
                try await fixture.drain(using: self)
                throw error
            }
        }

        func testCancelledActionAndPinSyncRequireJoiningBeforeScopedCleanup() async throws {
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "unused revocation"))
            let actionEntered = XCTestExpectation(description: "favorite operation entered")
            let cloudEntered = XCTestExpectation(description: "fake cloud exchange entered")
            let actionGate = LifecycleGate(entered: actionEntered)
            let cloudGate = LifecycleGate(entered: cloudEntered)
            defer {
                actionGate.release()
                cloudGate.release()
                fixture.gate.release()
            }
            let scope = String(repeating: "a", count: 64)
            let other = String(repeating: "b", count: 64)
            let otherKey = FoundationPinStorage.key(for: other)
            let otherBytes = Data("unrelated-scoped-sentinel".utf8)
            fixture.defaults.set(otherBytes, forKey: otherKey)
            let actions = FoundationLibraryActions(
                sourceScope: scope,
                read: { fixture.defaults.data(forKey: $0) },
                write: { fixture.defaults.set($1, forKey: $0) },
                mutateFavorite: { _, _ in await actionGate.hold() })
            let album = fixture.album
            actions.togglePin(album)
            let mutation = Task { await actions.setFavorite(for: album, isFavorite: true) }
            fixture.tasks.append(mutation)
            let state = FoundationPinSyncState(scope: scope)
            let sync = FoundationPinSync(
                scope: scope, containerIdentifier: nil, defaults: fixture.defaults,
                exchange: { _, _, _, _, _, _ in
                    await cloudGate.hold()
                    return .init(state: state, account: "synthetic", reset: false)
                }, currentPins: { [] }, apply: { _, _ in XCTFail("Invalidated sync applied data") })
            do {
                sync.setEnabled(true)
                let exchange = try XCTUnwrap(sync.task)
                fixture.tasks.append(exchange)
                try await waitForEvents(
                    [actionEntered, cloudEntered], label: "held account operations")
                XCTAssertTrue(actionGate.isHeld)
                XCTAssertTrue(cloudGate.isHeld)
                actions.invalidate()
                sync.invalidate()
                // The cancellation request has returned, but both captured tasks remain held.
                XCTAssertTrue(actionGate.isHeld)
                XCTAssertTrue(cloudGate.isHeld)
                XCTAssertNil(sync.task)
                XCTAssertNotNil(fixture.defaults.data(forKey: FoundationPinStorage.key(for: scope)))
                let joining = XCTestExpectation(description: "captured operations join started")
                let joined = XCTestExpectation(description: "captured operations joined")
                var didJoin = false
                let join = Task {
                    joining.fulfill()
                    await mutation.value
                    await exchange.value
                    didJoin = true
                    joined.fulfill()
                }
                fixture.tasks.append(join)
                try await waitForEvents([joining], label: "captured operations join start")
                // No scoped cleanup is authorized by cancellation alone.
                XCTAssertFalse(didJoin)
                guard actionGate.isHeld, cloudGate.isHeld, !didJoin else {
                    throw CancellationError()
                }
                actionGate.release()
                cloudGate.release()
                try await waitForEvents([joined], label: "captured account operations")
                XCTAssertTrue(didJoin)
                XCTAssertTrue(
                    FoundationPinStorage.removeStoredPins(for: scope, defaults: fixture.defaults))
                XCTAssertNil(fixture.defaults.data(forKey: FoundationPinStorage.key(for: scope)))
                XCTAssertEqual(fixture.defaults.data(forKey: otherKey), otherBytes)
                guard didJoin, fixture.defaults.data(forKey: otherKey) == otherBytes else {
                    throw CancellationError()
                }
                fixture.gate.release()
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                actionGate.release()
                cloudGate.release()
                fixture.gate.release()
                try await fixture.drain(using: self)
                throw error
            }
        }

        func testCredentialGenerationStampFailuresPreserveSavedAccount() async throws {
            for failure in 0..<5 {
                try await withLifecycleFixture { fixture, _ in
                    let root = fixture.root.appendingPathComponent(
                        "generation-stamp", isDirectory: true)
                    let keychain = IntentKeychainFixture()
                    let operations = keychain.operations()
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    let original = try JSONEncoder().encode(session)
                    keychain.credentialData = original
                    let snapshot = try FoundationAccountCredentialTransaction.inspect(
                        root: root, operations: operations)
                    XCTAssertNil(snapshot.credentialGeneration)
                    let replacement = fixture.session(user: "00000000000000000000000000000002")
                    let replacementBytes = try JSONEncoder().encode(replacement)
                    switch failure {
                    case 0: keychain.generationUpdateStatus = errSecInteractionNotAllowed
                    case 1:
                        keychain.afterGenerationUpdate = {
                            keychain.readStatus = errSecInteractionNotAllowed
                        }
                    case 2:
                        keychain.afterGenerationUpdate = {
                            keychain.credentialData = replacementBytes
                        }
                    case 3: keychain.addStatus = errSecInteractionNotAllowed
                    default: keychain.readbackStatusAfterAdd = errSecInteractionNotAllowed
                    }
                    XCTAssertThrowsError(
                        try FoundationAccountCredentialTransaction.prepareSignOut(
                            session, expecting: snapshot, root: root, operations: operations))
                    keychain.readStatus = errSecSuccess
                    keychain.afterGenerationUpdate = nil
                    let marker = try FoundationSignOutIntentStore.load(operations: operations)
                    if failure == 4 {
                        XCTAssertNotNil(marker)
                        XCTAssertEqual(marker?.credentialGeneration, keychain.credentialGeneration)
                        XCTAssertNotEqual(marker?.cleanupComplete, true)
                    } else {
                        XCTAssertNil(marker)
                    }
                    XCTAssertEqual(keychain.credentialDeletes, 0)
                    XCTAssertEqual(
                        keychain.credentialData, failure == 2 ? replacementBytes : original)
                    if failure == 0 {
                        XCTAssertNil(keychain.credentialGeneration)
                    } else {
                        XCTAssertNotNil(keychain.credentialGeneration)
                    }
                    // A verified, unchanged credential can retry after an uncertain stamp or marker add.
                    if failure == 1 || failure == 3 {
                        keychain.addStatus = errSecSuccess
                        let retry = try FoundationAccountCredentialTransaction.inspect(
                            root: root, operations: operations)
                        let intent = try FoundationAccountCredentialTransaction.prepareSignOut(
                            session, expecting: retry, root: root, operations: operations)
                        XCTAssertEqual(intent.credentialGeneration, retry.credentialGeneration)
                        XCTAssertEqual(keychain.credentialData, original)
                    }
                }
            }
        }

        func testLegacyCredentialIsPreservedDuringAmbiguousCompletedRecovery() async throws {
            try await withLifecycleFixture { fixture, _ in
                let root = fixture.root.appendingPathComponent(
                    "credential-transaction", isDirectory: true)
                let keychain = IntentKeychainFixture()
                let operations = keychain.operations()
                let session = fixture.session(user: "00000000000000000000000000000001")
                let bytes = try JSONEncoder().encode(session)
                keychain.credentialData = bytes
                let snapshot = try FoundationAccountCredentialTransaction.inspect(
                    root: root, operations: operations)
                XCTAssertNil(snapshot.credentialGeneration)
                // Recreate an older completed marker which did not bind a credential generation.
                let scope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                let intent = try FoundationSignOutIntentStore.create(
                    scope: scope, operations: operations)
                let completed = try FoundationSignOutIntentStore.markCleanupComplete(
                    intent, operations: operations)
                XCTAssertNil(completed.credentialGeneration)
                XCTAssertEqual(completed.cleanupComplete, true)
                XCTAssertThrowsError(
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        completed, root: root, operations: operations))
                XCTAssertEqual(keychain.credentialData, bytes)
                XCTAssertEqual(
                    try FoundationSignOutIntentStore.load(operations: operations), completed)
            }
        }

        func testCompletedSignOutPhaseRecoversAfterUncertainCredentialDeletion() async throws {
            for interruptAfterDelete in [false, true] {
                try await withLifecycleFixture { fixture, _ in
                    let root = fixture.root.appendingPathComponent(
                        "credential-transaction", isDirectory: true)
                    let keychain = IntentKeychainFixture()
                    let operations = keychain.operations()
                    keychain.credentialGeneration = Data(UUID().uuidString.utf8)
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    keychain.credentialData = try JSONEncoder().encode(session)
                    let snapshot = try FoundationAccountCredentialTransaction.inspect(
                        root: root, operations: operations)
                    let intent = try FoundationAccountCredentialTransaction.prepareSignOut(
                        session, expecting: snapshot, root: root, operations: operations)
                    if interruptAfterDelete {
                        keychain.readbackStatusAfterCredentialDelete = errSecInteractionNotAllowed
                    } else {
                        keychain.readbackStatusAfterIntentUpdate = errSecInteractionNotAllowed
                    }
                    XCTAssertThrowsError(
                        try FoundationAccountCredentialTransaction.finishSignOut(
                            session, intent: intent, expecting: snapshot, root: root,
                            operations: operations))
                    if interruptAfterDelete {
                        XCTAssertNil(keychain.credentialData)
                    } else {
                        XCTAssertNotNil(keychain.credentialData)
                    }
                    keychain.readStatus = errSecSuccess
                    let completed = try XCTUnwrap(
                        FoundationSignOutIntentStore.load(operations: operations))
                    XCTAssertEqual(completed.cleanupComplete, true)
                    XCTAssertEqual(completed.operation, intent.operation)
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(
                        completed, root: root, operations: operations)
                    XCTAssertNil(keychain.credentialData)
                    XCTAssertNil(try FoundationSignOutIntentStore.load(operations: operations))
                }
            }
        }

        func testCredentialTransactionRejectsStalePreparedAcceptance() async throws {
            try await withLifecycleFixture { fixture, _ in
                let root = fixture.root.appendingPathComponent(
                    "credential-transaction", isDirectory: true)
                let keychain = IntentKeychainFixture()
                let operations = keychain.operations()
                let original = fixture.session(user: "00000000000000000000000000000001")
                keychain.credentialData = try JSONEncoder().encode(original)
                let prepared = try FoundationAccountCredentialTransaction.inspect(
                    root: root, operations: operations)
                let first = FoundationSession(
                    serverURL: original.serverURL, accessToken: "synthetic-first",
                    userID: original.userID, deviceID: original.deviceID)
                let stale = FoundationSession(
                    serverURL: original.serverURL, accessToken: "synthetic-stale",
                    userID: original.userID, deviceID: original.deviceID)
                try FoundationAccountCredentialTransaction.commitSignIn(
                    original, expecting: prepared, root: root, operations: operations)
                let identicalBytes = try XCTUnwrap(keychain.credentialData)
                XCTAssertNotNil(keychain.credentialGeneration)
                XCTAssertThrowsError(
                    try FoundationAccountCredentialTransaction.commitSignIn(
                        original, expecting: prepared, root: root, operations: operations))
                XCTAssertEqual(keychain.credentialData, identicalBytes)
                XCTAssertThrowsError(
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        original, expecting: prepared, root: root, operations: operations))
                XCTAssertNil(keychain.payload)
                XCTAssertEqual(keychain.credentialData, identicalBytes)
                let refreshed = try FoundationAccountCredentialTransaction.inspect(
                    root: root, operations: operations)
                try FoundationAccountCredentialTransaction.commitSignIn(
                    first, expecting: refreshed, root: root, operations: operations)
                let firstBytes = try XCTUnwrap(keychain.credentialData)
                XCTAssertThrowsError(
                    try FoundationAccountCredentialTransaction.commitSignIn(
                        stale, expecting: refreshed, root: root, operations: operations))
                XCTAssertEqual(keychain.credentialData, firstBytes)
                keychain.credentialData = nil
                let absent = try FoundationAccountCredentialTransaction.inspect(
                    root: root, operations: operations)
                try FoundationAccountCredentialTransaction.commitSignIn(
                    first, expecting: absent, root: root, operations: operations)
                let newBytes = try XCTUnwrap(keychain.credentialData)
                XCTAssertThrowsError(
                    try FoundationAccountCredentialTransaction.commitSignIn(
                        stale, expecting: absent, root: root, operations: operations))
                XCTAssertEqual(keychain.credentialData, newBytes)
            }
        }

        func testCredentialTransactionPreservesInterruptedPreparationAndMismatch() async throws {
            try await withLifecycleFixture { fixture, _ in
                let root = fixture.root.appendingPathComponent(
                    "credential-transaction", isDirectory: true)
                let keychain = IntentKeychainFixture()
                let operations = keychain.operations()
                let first = fixture.session(user: "00000000000000000000000000000001")
                let second = fixture.session(user: "00000000000000000000000000000002")
                let scope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + first.serverURL.absoluteString + "\0" + first.userID)
                let firstBytes = try JSONEncoder().encode(first)
                keychain.credentialData = firstBytes
                let intent = try FoundationSignOutIntentStore.create(
                    scope: scope, operations: operations)
                let interrupted = try FoundationAccountCredentialTransaction.inspect(
                    root: root, operations: operations)
                XCTAssertEqual(interrupted.intent, intent)
                XCTAssertEqual(interrupted.session?.userID, first.userID)
                XCTAssertEqual(keychain.credentialData, firstBytes)
                XCTAssertEqual(keychain.credentialDeletes, 0)
                let secondBytes = try JSONEncoder().encode(second)
                keychain.credentialData = secondBytes
                XCTAssertThrowsError(
                    try FoundationAccountCredentialTransaction.inspect(
                        root: root, operations: operations))
                XCTAssertThrowsError(
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        first, expecting: interrupted, root: root, operations: operations))
                XCTAssertEqual(keychain.credentialData, secondBytes)
                XCTAssertEqual(
                    try FoundationSignOutIntentStore.load(operations: operations), intent)
                keychain.readStatus = errSecInteractionNotAllowed
                XCTAssertThrowsError(
                    try FoundationAccountCredentialTransaction.inspect(
                        root: root, operations: operations))
                XCTAssertEqual(keychain.credentialData, secondBytes)
                XCTAssertNotNil(keychain.payload)
            }
        }

        func testCredentialTransactionNeverClearsChangedOrUnmarkedSession() async throws {
            try await withLifecycleFixture { fixture, _ in
                let root = fixture.root.appendingPathComponent(
                    "credential-transaction", isDirectory: true)
                let keychain = IntentKeychainFixture()
                let operations = keychain.operations()
                let current = fixture.session(user: "00000000000000000000000000000001")
                let stale = fixture.session(user: "00000000000000000000000000000002")
                let bytes = try JSONEncoder().encode(current)
                keychain.credentialData = bytes
                let snapshot = try FoundationAccountCredentialTransaction.inspect(
                    root: root, operations: operations)
                XCTAssertThrowsError(
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        stale, expecting: snapshot, root: root, operations: operations))
                XCTAssertEqual(keychain.credentialData, bytes)
                XCTAssertEqual(keychain.credentialDeletes, 0)
                XCTAssertNil(keychain.payload)
                keychain.addStatus = errSecInteractionNotAllowed
                XCTAssertThrowsError(
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        current, expecting: snapshot, root: root, operations: operations))
                XCTAssertEqual(keychain.credentialData, bytes)
                XCTAssertEqual(keychain.credentialDeletes, 0)
                XCTAssertNil(keychain.payload)
            }
        }

        func testSignOutIntentRejectsStaleAmbiguousAndLockedItems() throws {
            let keychain = IntentKeychainFixture()
            let operations = keychain.operations()
            let scope = String(repeating: "a", count: 64)
            XCTAssertNil(try FoundationSignOutIntentStore.load(operations: operations))
            let first = try FoundationSignOutIntentStore.create(
                scope: scope, operations: operations)
            XCTAssertEqual(try FoundationSignOutIntentStore.load(operations: operations), first)
            XCTAssertThrowsError(
                try FoundationSignOutIntentStore.create(scope: scope, operations: operations))
            try FoundationSignOutIntentStore.remove(first, operations: operations)
            let second = try FoundationSignOutIntentStore.create(
                scope: scope, operations: operations)
            XCTAssertNotEqual(first.operation, second.operation)
            XCTAssertThrowsError(
                try FoundationSignOutIntentStore.remove(first, operations: operations))
            XCTAssertEqual(try FoundationSignOutIntentStore.load(operations: operations), second)
            keychain.duplicateGroup = true
            XCTAssertThrowsError(try FoundationSignOutIntentStore.load(operations: operations))
            keychain.duplicateGroup = false
            keychain.generic = Data(UUID().uuidString.utf8)
            XCTAssertThrowsError(try FoundationSignOutIntentStore.load(operations: operations))
            keychain.generic = Data(second.operation.uuidString.utf8)
            keychain.readStatus = errSecInteractionNotAllowed
            XCTAssertThrowsError(try FoundationSignOutIntentStore.load(operations: operations))
            XCTAssertThrowsError(
                try FoundationSignOutIntentStore.remove(second, operations: operations))
            keychain.readStatus = errSecSuccess
            XCTAssertEqual(try FoundationSignOutIntentStore.load(operations: operations), second)
            let ambiguous = IntentKeychainFixture()
            ambiguous.duplicateCredentialGroup = true
            XCTAssertThrowsError(
                try FoundationSignOutIntentStore.create(
                    scope: scope, operations: ambiguous.operations()))
            XCTAssertNil(ambiguous.payload)
            let failed = IntentKeychainFixture()
            failed.addStatus = errSecInteractionNotAllowed
            XCTAssertThrowsError(
                try FoundationSignOutIntentStore.create(
                    scope: scope, operations: failed.operations()))
            XCTAssertNil(failed.payload)
        }

        func testAccountTransactionLockRejectsContentionAndUnsafeInodes() async throws {
            try await withLifecycleFixture { fixture, _ in
                let root = fixture.root.appendingPathComponent(
                    "transaction-lock", isDirectory: true)
                try FoundationAccountTransactionLock.withLock(root: root) {
                    XCTAssertThrowsError(
                        try FoundationAccountTransactionLock.withLock(root: root) {}
                    ) {
                        guard let failure = $0 as? FoundationAccountTransactionLock.LockError,
                            case .busy = failure
                        else { return XCTFail("Expected nonblocking contention") }
                    }
                }
                XCTAssertNoThrow(try FoundationAccountTransactionLock.withLock(root: root) {})
                XCTAssertThrowsError(
                    try FoundationAccountTransactionLock.withLock(root: root) {
                        throw URLError(.unknown)
                    })
                XCTAssertNoThrow(try FoundationAccountTransactionLock.withLock(root: root) {})
                let lock = root.appendingPathComponent("account-ownership.lock")
                let hardlink = fixture.root.appendingPathComponent("lock-hardlink")
                try FileManager.default.linkItem(at: lock, to: hardlink)
                XCTAssertThrowsError(try FoundationAccountTransactionLock.withLock(root: root) {})
                try FileManager.default.removeItem(at: hardlink)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: lock.path)
                XCTAssertThrowsError(try FoundationAccountTransactionLock.withLock(root: root) {})
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: lock.path)
                XCTAssertNoThrow(try FoundationAccountTransactionLock.withLock(root: root) {})
                let link = fixture.root.appendingPathComponent(
                    "linked-lock-root", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
                XCTAssertThrowsError(try FoundationAccountTransactionLock.withLock(root: link) {})
            }
        }

        func testSignOutIntentRejectsInterleavedReplacementAndUncertainWrites() throws {
            let scope = String(repeating: "a", count: 64)
            let keychain = IntentKeychainFixture()
            let operations = keychain.operations()
            let first = try FoundationSignOutIntentStore.create(
                scope: scope, operations: operations)
            let replacement = FoundationSignOutIntentStore.Intent(
                version: 1, operation: UUID(), scope: scope, accessGroup: keychain.group)
            keychain.beforeDelete = {
                keychain.generic = Data(replacement.operation.uuidString.utf8)
                keychain.payload = try? JSONEncoder().encode(replacement)
            }
            XCTAssertThrowsError(
                try FoundationSignOutIntentStore.remove(first, operations: operations))
            XCTAssertEqual(
                try FoundationSignOutIntentStore.load(operations: operations), replacement)
            XCTAssertEqual(keychain.deleteAttempts, 1)

            let added = IntentKeychainFixture()
            added.readbackStatusAfterAdd = errSecInteractionNotAllowed
            let addOperations = added.operations()
            XCTAssertThrowsError(
                try FoundationSignOutIntentStore.create(scope: scope, operations: addOperations))
            XCTAssertNotNil(added.payload)
            added.readStatus = errSecSuccess
            XCTAssertNotNil(try FoundationSignOutIntentStore.load(operations: addOperations))

            let deleted = IntentKeychainFixture()
            let deleteOperations = deleted.operations()
            let intent = try FoundationSignOutIntentStore.create(
                scope: scope, operations: deleteOperations)
            deleted.readbackStatusAfterDelete = errSecInteractionNotAllowed
            XCTAssertThrowsError(
                try FoundationSignOutIntentStore.remove(intent, operations: deleteOperations))
            XCTAssertNil(deleted.payload)
            deleted.readStatus = errSecSuccess
            XCTAssertNil(try FoundationSignOutIntentStore.load(operations: deleteOperations))
        }

        func testPendingSignOutHeadlessReconciliationRetiresOnlyMatchingReceipt() async throws {
            let entered = expectation(description: "synthetic retirement entered")
            let gate = LifecycleGate(entered: entered)
            defer { gate.release() }
            try await withLifecycleFixture { fixture, _ in
                defer { gate.release() }
                let session = fixture.session(user: "00000000000000000000000000000001")
                let keychain = IntentKeychainFixture()
                keychain.credentialData = try JSONEncoder().encode(session)
                let operations = keychain.operations()
                let lockRoot = fixture.root.appendingPathComponent(
                    "account-lock", isDirectory: true)
                let snapshot = try FoundationAccountCredentialTransaction.inspect(
                    root: lockRoot, operations: operations)
                let intent = try FoundationAccountCredentialTransaction.prepareSignOut(
                    session, expecting: snapshot, root: lockRoot, operations: operations)
                let scope = intent.scope
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                let unrelated = FoundationDownloadStorage.directory(
                    scope: String(repeating: "b", count: 64), root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(directory)
                try FoundationDownloadStorage.prepare(unrelated)
                let sentinel = unrelated.appendingPathComponent("sentinel")
                let sentinelData = Data("unrelated account".utf8)
                try sentinelData.write(to: sentinel)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                    + "." + UUID().uuidString
                let receipt = FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: identifier)
                try receipt.reserve()
                var manifest = FoundationDownloadManifest()
                manifest.nativePendingSessions = [identifier]
                try FoundationDownloadStorage.save(manifest, directory: directory)
                var reconciled = false
                let task = Task {
                    reconciled = await FoundationDownloads.reconcileBackgroundSession(
                        identifier, scope: scope, root: fixture.storage.downloads,
                        retirement: { identifiers, root in
                            await gate.hold()
                            guard identifiers == [identifier], root == directory else { return [] }
                            do {
                                try FoundationNativeAllocationStore(
                                    directory: root, sessionIdentifier: identifier
                                ).retire()
                                return [identifier]
                            } catch { return [] }
                        },
                        mayCommit: {
                            (try? FoundationSignOutIntentStore.load(operations: operations))
                                == intent
                        })
                }
                fixture.tasks.append(task)
                try await self.waitForEvents([entered], label: "held synthetic retirement")
                let pendingWhileHeld =
                    try FoundationDownloadStorage.load(directory: directory)
                    .nativePendingSessions?.contains(identifier) == true
                let sentinelWhileHeld = try Data(contentsOf: sentinel)
                XCTAssertTrue(pendingWhileHeld)
                XCTAssertEqual(sentinelWhileHeld, sentinelData)
                gate.release()
                try await self.waitForTask(task, label: "headless reconciliation")
                XCTAssertTrue(reconciled)
                XCTAssertTrue(try receipt.load().hasProvenRetirement)
                XCTAssertFalse(
                    try FoundationDownloadStorage.load(directory: directory)
                        .nativePendingSessions?.contains(identifier) == true)
                XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
                XCTAssertEqual(
                    try FoundationSignOutIntentStore.load(operations: operations), intent)
                XCTAssertNotNil(keychain.credentialData)
                XCTAssertEqual(keychain.credentialDeletes, 0)
                guard pendingWhileHeld, sentinelWhileHeld == sentinelData,
                    reconciled, try receipt.load().hasProvenRetirement,
                    try FoundationDownloadStorage.load(directory: directory)
                        .nativePendingSessions?.contains(identifier) != true,
                    try Data(contentsOf: sentinel) == sentinelData,
                    try FoundationSignOutIntentStore.load(operations: operations) == intent,
                    keychain.credentialData != nil, keychain.credentialDeletes == 0
                else { throw CancellationError() }
            }
        }

        func testNativeRetirementTombstoneRejectsAmbiguousStates() async throws {
            try await withLifecycleFixture { fixture, _ in
                let directory = fixture.storage.downloads.appendingPathComponent(
                    String(repeating: "a", count: 64), isDirectory: true)
                try FoundationDownloadStorage.prepare(directory)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                    + "." + UUID().uuidString
                let store = FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: identifier)
                var receipt = FoundationNativeAllocationStore.Receipt(
                    scope: directory.lastPathComponent, sessionIdentifier: identifier,
                    taskIdentifier: 1)
                receipt.retired = true
                for phase in [
                    FoundationNativeAllocationStore.Receipt.Phase.reserved, .creating, .resuming,
                ] {
                    receipt.phase = phase
                    receipt.creationVersion = phase == .reserved ? nil : 1
                    try JSONEncoder().encode(receipt).write(to: store.receiptURL)
                    XCTAssertFalse(try store.load().hasProvenRetirement)
                    XCTAssertThrowsError(try store.retire())
                }
                receipt.phase = .allocated
                receipt.nativeURL = fixture.root.appendingPathComponent("synthetic.movpkg")
                receipt.namespaceBookmark = Data("synthetic namespace".utf8)
                receipt.creationVersion = nil
                try JSONEncoder().encode(receipt).write(to: store.receiptURL)
                XCTAssertFalse(try store.load().hasProvenRetirement)
                XCTAssertThrowsError(try store.retire())
                receipt.creationVersion = 1
                try JSONEncoder().encode(receipt).write(to: store.receiptURL)
                XCTAssertTrue(try store.load().hasProvenRetirement)
                XCTAssertNoThrow(try store.retire())

                let target = fixture.root.appendingPathComponent(
                    "synthetic.movpkg", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: true)
                receipt.retired = nil
                receipt.creationVersion = nil
                try JSONEncoder().encode(receipt).write(to: store.receiptURL)
                let before = try Data(contentsOf: store.receiptURL)
                var resolved = false
                var removed = false
                XCTAssertThrowsError(
                    try store.retire(
                        resolve: { _ in
                            resolved = true
                            return .available(target)
                        },
                        remove: { url in
                            removed = true
                            try FileManager.default.removeItem(at: url)
                        }))
                XCTAssertFalse(resolved)
                XCTAssertFalse(removed)
                XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
                XCTAssertEqual(try Data(contentsOf: store.receiptURL), before)
                receipt.creationVersion = 1
                try JSONEncoder().encode(receipt).write(to: store.receiptURL)
                try store.retire(
                    resolve: { _ in .available(target) },
                    remove: { url in
                        try FileManager.default.removeItem(at: url)
                    })
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
                XCTAssertTrue(try store.load().hasProvenRetirement)
            }
        }

        func testBackgroundProofRejectsConcurrentManifestPublication() async throws {
            let entered = expectation(description: "synthetic background proof entered")
            let gate = LifecycleGate(entered: entered)
            defer { gate.release() }
            try await withLifecycleFixture(
                leaseWaitStarted: {},
                nativeRetirement: { identifiers, directory in
                    var retired: Set<String> = []
                    for identifier in identifiers {
                        do {
                            try FoundationNativeAllocationStore(
                                directory: directory, sessionIdentifier: identifier
                            ).retire()
                            retired.insert(identifier)
                        } catch {}
                    }
                    return retired
                },
                { fixture, model in
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    let scope = FoundationMusicLibraryStore.digest(
                        "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                    let directory = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads)
                    try FoundationDownloadStorage.prepare(directory)
                    let identifier =
                        "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                        + "." + UUID().uuidString
                    let store = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    try store.reserve()
                    var manifest = FoundationDownloadManifest()
                    manifest.nativePendingSessions = [identifier]
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    try await fixture.open(model, user: session.userID)
                    let owner = try XCTUnwrap(model.downloads)
                    let inventory = self.expectation(description: "synthetic retirement inventory")
                    let observation = owner.$isLoading.filter { !$0 }.first().sink { _ in
                        inventory.fulfill()
                    }
                    defer {
                        observation.cancel()
                        gate.release()
                    }
                    try await self.waitForEvents(
                        [inventory], label: "synthetic retirement inventory")
                    owner.recordBackgroundSessionDrain(identifier)
                    owner.isolatedBackgroundProofDelay = { await gate.hold() }
                    var first: Bool?
                    let proof = Task { first = await owner.reconcileBackgroundSession(identifier) }
                    fixture.tasks.append(proof)
                    try await self.waitForEvents([entered], label: "held background proof")
                    owner.setAllowsCellular(!owner.allowsCellular)
                    gate.release()
                    try await self.waitForTask(proof, label: "stale background proof")
                    XCTAssertEqual(first, false)
                    owner.isolatedBackgroundProofDelay = nil
                    var retried: Bool?
                    let retry = Task {
                        retried = await owner.reconcileBackgroundSession(identifier)
                    }
                    fixture.tasks.append(retry)
                    try await self.waitForTask(retry, label: "fresh background proof")
                    XCTAssertEqual(retried, true)
                })
        }

        func testRestoreDoesNotReplaceActiveOwnerWhileInventoryIsHeld() async throws {
            let entered = expectation(description: "active owner inventory entered")
            let gate = LifecycleGate(entered: entered)
            defer { gate.release() }
            try await withLifecycleFixture(
                nativeRetirement: { _, _ in
                    await gate.hold()
                    return []
                },
                { fixture, model in
                    defer { gate.release() }
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    let accept = try await model.prepareSignIn { session }
                    let scope = FoundationMusicLibraryStore.digest(
                        "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                    let directory = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads)
                    try FoundationDownloadStorage.prepare(directory)
                    let identifier =
                        "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                        + "." + UUID().uuidString
                    let receipt = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    try receipt.reserve()
                    var manifest = FoundationDownloadManifest()
                    manifest.nativePendingSessions = [identifier]
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    try await accept()
                    try await self.waitForEvents([entered], label: "active inventory")
                    let owner = try XCTUnwrap(model.downloads)
                    let library = try XCTUnwrap(model.library)
                    let cache = try XCTUnwrap(library.artworkCache)
                    let player = try XCTUnwrap(model.player)
                    fixture.copyStatus = errSecSuccess
                    fixture.copiedCredential = try JSONEncoder().encode(session)
                    model.restoreCredentials()
                    XCTAssertTrue(model.downloads === owner)
                    XCTAssertTrue(model.library?.artworkCache === cache)
                    XCTAssertEqual(
                        model.library?.catalogAccountIdentity, library.catalogAccountIdentity)
                    XCTAssertTrue(model.player === player)
                    XCTAssertFalse(try receipt.load().retired == true)
                    guard model.downloads === owner, model.library?.artworkCache === cache,
                        model.player === player,
                        model.library?.catalogAccountIdentity == library.catalogAccountIdentity,
                        try receipt.load().retired != true
                    else { throw CancellationError() }
                    let finished = self.expectation(description: "active inventory finished")
                    let observation = owner.$isLoading.filter { !$0 }.first().sink { _ in
                        finished.fulfill()
                    }
                    defer { observation.cancel() }
                    gate.release()
                    try await self.waitForEvents([finished], label: "active inventory completion")
                    XCTAssertTrue(model.downloads === owner)
                    XCTAssertTrue(model.library?.artworkCache === cache)
                    XCTAssertEqual(
                        model.library?.catalogAccountIdentity, library.catalogAccountIdentity)
                    XCTAssertTrue(model.player === player)
                })
        }

        func testSignOutDoesNotAdmitReplacementWhileInventoryIsHeld() async throws {
            let entered = expectation(description: "active owner inventory entered")
            let gate = LifecycleGate(entered: entered)
            defer { gate.release() }
            try await withLifecycleFixture(
                nativeRetirement: { _, _ in
                    await gate.hold()
                    return []
                },
                { fixture, model in
                    defer { gate.release() }
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    let accept = try await model.prepareSignIn { session }
                    let scope = FoundationMusicLibraryStore.digest(
                        "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                    let directory = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads)
                    try FoundationDownloadStorage.prepare(directory)
                    let identifier =
                        "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                        + "." + UUID().uuidString
                    let receipt = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    try receipt.reserve()
                    var manifest = FoundationDownloadManifest()
                    manifest.nativePendingSessions = [identifier]
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    try await accept()
                    try await self.waitForEvents([entered], label: "active inventory")
                    let owner = try XCTUnwrap(model.downloads)
                    let player = try XCTUnwrap(model.player)
                    model.signOut()
                    fixture.captureStop(player)
                    var preparationError: Error?
                    var authenticationCalled = false
                    let preparation = Task {
                        do {
                            _ = try await model.prepareSignIn {
                                authenticationCalled = true
                                return session
                            }
                        } catch { preparationError = error }
                    }
                    fixture.tasks.append(preparation)
                    try await self.waitForTask(preparation, label: "sign-in during held inventory")
                    XCTAssertNotNil(preparationError)
                    XCTAssertFalse(authenticationCalled)
                    XCTAssertTrue(model.isCleaningDownloads)
                    XCTAssertNil(model.downloads)
                    XCTAssertNil(model.library)
                    XCTAssertFalse(try receipt.load().retired == true)
                    guard preparationError != nil, !authenticationCalled, model.isCleaningDownloads,
                        model.downloads == nil, model.library == nil,
                        try receipt.load().retired != true
                    else { throw CancellationError() }
                    let completed = self.expectation(description: "sign-out cleanup returned")
                    let observation = model.$isCleaningDownloads.filter { !$0 }.first().sink { _ in
                        completed.fulfill()
                    }
                    defer { observation.cancel() }
                    gate.release()
                    try await self.waitForEvents([completed], label: "sign-out after inventory")
                    XCTAssertNil(model.library)
                    _ = owner
                })
        }

        func testRemoveAllDefersNativeRetirementWhilePlaybackLeaseIsHeld() async throws {
            let retirements = IsolatedDiagnosticRecorder()
            try await withLifecycleFixture(
                leaseWaitStarted: {},
                nativeRetirement: { _, _ in
                    retirements.append("entered")
                    return []
                },
                { fixture, model in
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    let accept = try await model.prepareSignIn { session }
                    let scope = FoundationMusicLibraryStore.digest(
                        "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                    let directory = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads)
                    try FoundationDownloadStorage.prepare(directory)
                    let track = FoundationItem(
                        id: "00000000000000000000000000000003", title: "Synthetic",
                        subtitle: "", kind: .track, duration: nil)
                    let file = directory.appendingPathComponent("synthetic.audio")
                    let bytes = Data("synthetic-held-resource".utf8)
                    try bytes.write(to: file)
                    let identifier =
                        "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                        + "." + UUID().uuidString
                    let receipt = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    try receipt.reserve(taskIdentifier: 1)
                    try receipt.beginResuming(taskIdentifier: 1)
                    let savedReceipt = try Data(contentsOf: receipt.receiptURL)
                    let stored = FoundationStoredDownloadItem(track)
                    var manifest = FoundationDownloadManifest()
                    manifest.owners = [
                        .init(
                            id: "track:" + track.id, item: stored, tracks: [stored],
                            paused: false, expanded: false)
                    ]
                    manifest.files[track.id] = .init(
                        name: file.lastPathComponent, bytes: Int64(bytes.count),
                        digest: try FoundationDownloadStorage.digest(file))
                    manifest.nativePendingSessions = [identifier]
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    try await accept()
                    let owner = try XCTUnwrap(model.downloads)
                    let inventory = self.expectation(description: "initial inventory completed")
                    let observation = owner.$isLoading.filter { !$0 }.first().sink { _ in
                        inventory.fulfill()
                    }
                    defer { observation.cancel() }
                    try await self.waitForEvents([inventory], label: "initial inventory")
                    XCTAssertEqual(retirements.snapshot().count, 1)
                    try await fixture.acquireResource(from: owner, item: track, using: self)
                    var removed: Bool?
                    let removal = Task { removed = await owner.removeAll() }
                    fixture.tasks.append(removal)
                    try await self.waitForTask(removal, label: "remove all with held playback")
                    XCTAssertEqual(removed, false)
                    XCTAssertEqual(retirements.snapshot().count, 1)
                    XCTAssertEqual(try Data(contentsOf: file), bytes)
                    XCTAssertEqual(try Data(contentsOf: receipt.receiptURL), savedReceipt)
                    XCTAssertTrue(owner.errorMessage?.contains("Stop playback") == true)
                    guard removed == false, retirements.snapshot().count == 1,
                        (try? Data(contentsOf: file)) == bytes,
                        (try? Data(contentsOf: receipt.receiptURL)) == savedReceipt,
                        owner.errorMessage?.contains("Stop playback") == true
                    else { throw CancellationError() }
                    try await fixture.releaseResources(using: self)
                    XCTAssertTrue(owner.hasPendingNativeCleanup)
                    var retryResult: Bool?
                    let retry = Task { retryResult = await owner.removeAll() }
                    fixture.tasks.append(retry)
                    try await self.waitForTask(retry, label: "remove all retry")
                    XCTAssertEqual(retryResult, false)
                    XCTAssertTrue(owner.hasPendingNativeCleanup)
                    XCTAssertEqual(retirements.snapshot().count, 2)
                    XCTAssertEqual(try Data(contentsOf: receipt.receiptURL), savedReceipt)
                    guard retryResult == false, owner.hasPendingNativeCleanup,
                        retirements.snapshot().count == 2,
                        (try? Data(contentsOf: receipt.receiptURL)) == savedReceipt
                    else { throw CancellationError() }
                })
        }

        func testDirectRestoreWaitsForHeadlessNativeReconciliation() async throws {
            let entered = expectation(description: "synthetic headless retirement entered")
            let gate = LifecycleGate(entered: entered)
            defer { gate.release() }
            try await withLifecycleFixture(
                nativeRetirement: { identifiers, directory in
                    await gate.hold()
                    var retired: Set<String> = []
                    for identifier in identifiers {
                        do {
                            try FoundationNativeAllocationStore(
                                directory: directory, sessionIdentifier: identifier
                            ).retire()
                            retired.insert(identifier)
                        } catch {}
                    }
                    return retired
                }, useModelBackgroundRouting: true,
                { fixture, model in
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    let scope = FoundationMusicLibraryStore.digest(
                        "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                    let directory = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads)
                    try FoundationDownloadStorage.prepare(directory)
                    let identifier =
                        "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                        + "." + UUID().uuidString
                    let store = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    try store.reserve()
                    var manifest = FoundationDownloadManifest()
                    manifest.nativePendingSessions = [identifier]
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    fixture.copyStatus = errSecSuccess
                    fixture.copiedCredential = try JSONEncoder().encode(session)
                    let completed = self.expectation(description: "headless event completed")
                    let restored = self.expectation(description: "deferred account restored")
                    let restoreObservation = model.$library.compactMap { $0 }.first().sink { _ in
                        restored.fulfill()
                    }
                    defer {
                        restoreObservation.cancel()
                        gate.release()
                    }
                    model.receiveBackgroundDownloadEvents(identifier) { completed.fulfill() }
                    try await self.waitForEvents([entered], label: "headless retirement")
                    model.restoreCredentials()
                    XCTAssertNil(model.library)
                    XCTAssertNil(model.player)
                    model.finishBackgroundDownloadEvents(identifier)
                    gate.release()
                    try await self.waitForEvents([completed, restored], label: "headless restore")
                    XCTAssertNotNil(model.library)
                    XCTAssertEqual(try store.load().retired, true)
                    XCTAssertTrue(
                        try FoundationDownloadStorage.load(directory: directory)
                            .nativePendingSessions?.isEmpty == true)
                })
        }

        func testRetiredOwnerRequiresLiveFinalityAndExactPackageBinding() async throws {
            try await withLifecycleFixture(useModelBackgroundRouting: true) { fixture, model in
                let session = fixture.session(user: "00000000000000000000000000000001")
                let scope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(directory)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                    + "." + UUID().uuidString
                let trackID = "00000000000000000000000000000003"
                let url = fixture.root.appendingPathComponent("synthetic.movpkg")
                let package = FoundationNativeDownloadPackage(
                    nativeURL: url, bookmark: Data("synthetic bookmark".utf8),
                    sessionIdentifier: identifier,
                    namespaceBookmark: Data("synthetic namespace".utf8))
                let store = FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: identifier)
                var receipt = FoundationNativeAllocationStore.Receipt(
                    scope: directory.lastPathComponent, sessionIdentifier: identifier,
                    taskIdentifier: 1)
                receipt.trackID = trackID
                receipt.nativeURL = url
                receipt.phase = .allocated
                receipt.namespaceBookmark = package.namespaceBookmark
                receipt.package = package
                receipt.creationVersion = 1
                receipt.completionAttempted = true
                try JSONEncoder().encode(receipt).write(to: store.receiptURL)
                var manifest = FoundationDownloadManifest()
                manifest.files[trackID] = .init(
                    name: "synthetic.movpkg", bytes: 1, digest: "", nativePackage: package)
                try FoundationDownloadStorage.save(manifest, directory: directory)
                try await fixture.open(model, user: session.userID)
                let owner = try XCTUnwrap(model.downloads)
                let player = try XCTUnwrap(model.player)
                let inventory = self.expectation(description: "synthetic native inventory finished")
                let inventoryObservation = owner.$isLoading.filter { !$0 }.first().sink { _ in
                    inventory.fulfill()
                }
                defer { inventoryObservation.cancel() }
                try await self.waitForEvents([inventory], label: "synthetic native inventory")
                let cleanup = self.expectation(description: "native sign-out remains pending")
                let cleanupObservation = model.$isCleaningDownloads.dropFirst().filter { !$0 }
                    .first()
                    .sink { _ in cleanup.fulfill() }
                defer { cleanupObservation.cancel() }
                model.signOut()
                fixture.captureStop(player)
                try await self.waitForEvents([cleanup], label: "native sign-out attempt")
                XCTAssertNil(model.downloads)
                XCTAssertNotNil(model.signOutCleanupError)
                let first = self.expectation(description: "no finality route settled")
                let second = self.expectation(description: "mismatched binding route settled")
                let completed = self.expectation(description: "verified retained event completed")
                var routes = 0
                model.backgroundRoutingSettled = { _ in
                    routes += 1
                    if routes == 1 { first.fulfill() }
                    if routes == 2 { second.fulfill() }
                }
                var completions = 0
                model.receiveBackgroundDownloadEvents(identifier) {
                    completions += 1
                    completed.fulfill()
                }
                model.finishBackgroundDownloadEvents(identifier)
                try await self.waitForEvents([first], label: "missing live finality")
                XCTAssertEqual(completions, 0)
                owner.isolatedRecordNativeFinality(identifier)
                let mismatch = FoundationNativeDownloadPackage(
                    nativeURL: url, bookmark: Data("different bookmark".utf8),
                    sessionIdentifier: identifier, namespaceBookmark: package.namespaceBookmark)
                manifest.files[trackID] = .init(
                    name: "synthetic.movpkg", bytes: 1, digest: "", nativePackage: mismatch)
                try FoundationDownloadStorage.save(manifest, directory: directory)
                model.finishBackgroundDownloadEvents(identifier)
                try await self.waitForEvents([second], label: "mismatched package binding")
                XCTAssertEqual(completions, 0)
                manifest.files[trackID] = .init(
                    name: "synthetic.movpkg", bytes: 1, digest: "", nativePackage: package)
                try FoundationDownloadStorage.save(manifest, directory: directory)
                model.finishBackgroundDownloadEvents(identifier)
                try await self.waitForEvents([completed], label: "verified retired owner event")
                XCTAssertEqual(completions, 1)
                XCTAssertTrue(FileManager.default.fileExists(atPath: store.receiptURL.path))
                fixture.gate.release()
                try await fixture.drain(using: self)
            }
        }

        func testUnresolvedBackgroundEventWaitsForAdmittedRetry() async throws {
            let firstSettled = expectation(description: "unresolved background route settled")
            let completed = expectation(description: "reconciled background completion")
            let retryEntered = expectation(description: "explicit retry entered")
            let retryGate = LifecycleGate(entered: retryEntered)
            defer { retryGate.release() }
            var canReconcile = false
            var attempts = 0
            try await withLifecycleFixture(
                backgroundReconcile: { _ in
                    attempts += 1
                    if attempts == 2 { await retryGate.hold() }
                    return canReconcile
                },
                { fixture, model in
                    defer { retryGate.release() }
                    model.backgroundRoutingSettled = { _ in firstSettled.fulfill() }
                    var completions = 0
                    model.receiveBackgroundDownloadEvents("synthetic") {
                        completions += 1
                        completed.fulfill()
                    }
                    model.finishBackgroundDownloadEvents("synthetic")
                    try await self.waitForEvents(
                        [firstSettled], label: "unresolved background route")
                    model.backgroundRoutingSettled = nil
                    XCTAssertEqual(attempts, 1)
                    XCTAssertEqual(completions, 0)
                    canReconcile = true
                    var authenticationStarted = false
                    var prepared: FoundationSignInView.Acceptance?
                    var failure: Error?
                    let retry = Task {
                        do {
                            prepared = try await model.prepareSignIn {
                                authenticationStarted = true
                                return fixture.session(user: "00000000000000000000000000000001")
                            }
                        } catch { failure = error }
                    }
                    fixture.tasks.append(retry)
                    try await self.waitForEvents(
                        [retryEntered], label: "held explicit background retry")
                    XCTAssertFalse(authenticationStarted)
                    XCTAssertEqual(completions, 0)
                    guard !authenticationStarted, completions == 0 else {
                        throw CancellationError()
                    }
                    retryGate.release()
                    try await self.waitForTask(retry, label: "explicit sign-in retry")
                    try await self.waitForEvents([completed], label: "background retry completion")
                    XCTAssertNil(failure)
                    XCTAssertTrue(authenticationStarted)
                    let acceptance = try XCTUnwrap(prepared)
                    try await acceptance()
                    XCTAssertEqual(attempts, 2)
                    XCTAssertEqual(completions, 1)
                    model.finishBackgroundDownloadEvents("synthetic")
                    XCTAssertEqual(completions, 1)
                })
        }

        func testSignInRetriesExactScopedHeadlessEventBeforeAuthentication() async throws {
            let firstSettled = expectation(description: "initial exact route settled")
            let retryEntered = expectation(description: "exact retry entered")
            let gate = LifecycleGate(entered: retryEntered)
            let attempts = IsolatedDiagnosticRecorder()
            defer { gate.release() }
            try await withLifecycleFixture(
                nativeRetirement: { identifiers, directory in
                    attempts.append("retirement")
                    if attempts.snapshot().count == 1 { return [] }
                    await gate.hold()
                    var retired: Set<String> = []
                    for identifier in identifiers {
                        do {
                            try FoundationNativeAllocationStore(
                                directory: directory, sessionIdentifier: identifier
                            ).retire()
                            retired.insert(identifier)
                        } catch {}
                    }
                    return retired
                }, useModelBackgroundRouting: true,
                { fixture, model in
                    defer { gate.release() }
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    fixture.copyStatus = errSecSuccess
                    fixture.copiedCredential = try JSONEncoder().encode(session)
                    let scope = FoundationMusicLibraryStore.digest(
                        "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                    let directory = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads)
                    try FoundationDownloadStorage.prepare(directory)
                    let identifier =
                        "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                        + "." + UUID().uuidString
                    let receipt = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    try receipt.reserve()
                    var manifest = FoundationDownloadManifest()
                    manifest.nativePendingSessions = [identifier]
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    let completion = XCTestExpectation(description: "exact background completion")
                    var completions = 0
                    model.backgroundRoutingSettled = { _ in firstSettled.fulfill() }
                    defer { model.backgroundRoutingSettled = nil }
                    model.receiveBackgroundDownloadEvents(identifier) {
                        completions += 1
                        completion.fulfill()
                    }
                    model.finishBackgroundDownloadEvents(identifier)
                    try await self.waitForEvents([firstSettled], label: "initial exact route")
                    model.backgroundRoutingSettled = nil
                    XCTAssertEqual(attempts.snapshot().count, 1)
                    XCTAssertEqual(completions, 0)
                    var authenticated = false
                    var preparation: FoundationSignInView.Acceptance?
                    var failure: Error?
                    let retry = Task {
                        do {
                            preparation = try await model.prepareSignIn {
                                authenticated = true
                                return session
                            }
                        } catch { failure = error }
                    }
                    fixture.tasks.append(retry)
                    try await self.waitForEvents([retryEntered], label: "held exact retry")
                    XCTAssertFalse(authenticated)
                    XCTAssertEqual(completions, 0)
                    XCTAssertNil(try receipt.load().retired)
                    guard !authenticated, completions == 0, try receipt.load().retired == nil
                    else { throw CancellationError() }
                    gate.release()
                    try await self.waitForTask(retry, label: "exact headless retry")
                    try await self.waitForEvents([completion], label: "exact event completion")
                    XCTAssertNil(failure)
                    XCTAssertTrue(authenticated)
                    XCTAssertNotNil(preparation)
                    XCTAssertEqual(attempts.snapshot().count, 2)
                    XCTAssertEqual(completions, 1)
                    XCTAssertTrue(try receipt.load().hasProvenRetirement)
                    XCTAssertFalse(
                        try FoundationDownloadStorage.load(directory: directory)
                            .nativePendingSessions?.contains(identifier) == true)
                    guard failure == nil, authenticated, preparation != nil,
                        attempts.snapshot().count == 2,
                        completions == 1, try receipt.load().hasProvenRetirement,
                        try FoundationDownloadStorage.load(directory: directory)
                            .nativePendingSessions?.contains(identifier) != true
                    else { throw CancellationError() }
                })
        }

        func testPersistentBackgroundFailureRetriesOnlyOnUserAttempt() async throws {
            let settled = expectation(description: "initial unresolved route settled")
            var attempts = 0
            try await withLifecycleFixture(
                backgroundReconcile: { _ in
                    attempts += 1
                    return false
                },
                { fixture, model in
                    model.backgroundRoutingSettled = { _ in settled.fulfill() }
                    defer { model.backgroundRoutingSettled = nil }
                    var completions = 0
                    model.receiveBackgroundDownloadEvents("synthetic") { completions += 1 }
                    model.finishBackgroundDownloadEvents("synthetic")
                    try await self.waitForEvents([settled], label: "initial unresolved route")
                    model.backgroundRoutingSettled = nil
                    var authenticationStarted = false
                    var failure: Error?
                    let retry = Task {
                        do {
                            _ = try await model.prepareSignIn {
                                authenticationStarted = true
                                return fixture.session(user: "00000000000000000000000000000001")
                            }
                        } catch { failure = error }
                    }
                    fixture.tasks.append(retry)
                    try await self.waitForTask(retry, label: "failed explicit retry")
                    XCTAssertEqual(attempts, 2)
                    XCTAssertFalse(authenticationStarted)
                    XCTAssertEqual(completions, 0)
                    XCTAssertTrue(failure is FoundationDownloadAccountError)
                    guard attempts == 2, !authenticationStarted, completions == 0,
                        failure is FoundationDownloadAccountError
                    else { throw CancellationError() }
                })
        }

        func testBackgroundRoutingFenceRetainsAndReplaysCompletions() async throws {
            let routeEntered = expectation(description: "first background route entered")
            let firstComplete = expectation(description: "first background completion")
            let queuedRoute = expectation(description: "queued background route entered")
            let queuedComplete = expectation(description: "both queued completions")
            queuedComplete.expectedFulfillmentCount = 2
            let waitEntered = expectation(description: "background routing wait registered")
            let gate = LifecycleGate(entered: routeEntered)
            defer { gate.release() }
            try await withLifecycleFixture(
                backgroundReconcile: { identifier in
                    if identifier == "first" {
                        await gate.hold()
                    } else if identifier == "queued" {
                        queuedRoute.fulfill()
                    }
                    return true
                },
                { fixture, model in
                    try await fixture.open(model, user: "00000000000000000000000000000001")
                    var activeToken: UUID?
                    defer {
                        gate.release()
                        if let activeToken { _ = model.cancelBackgroundRoutingHandoff(activeToken) }
                    }
                    var firstCount = 0
                    var queuedCount = 0
                    model.receiveBackgroundDownloadEvents("first") {
                        firstCount += 1
                        firstComplete.fulfill()
                    }
                    try await self.waitForEvents([routeEntered], label: "initial background route")
                    let token = try XCTUnwrap(model.beginBackgroundRoutingHandoff())
                    activeToken = token
                    model.isolatedBackgroundRoutingWaitStarted = { waitEntered.fulfill() }
                    var result: Bool?
                    let waiter = Task {
                        result = await model.waitForBackgroundRoutingHandoff(token)
                    }
                    fixture.tasks.append(waiter)
                    try await self.waitForEvents([waitEntered], label: "background routing wait")
                    model.receiveBackgroundDownloadEvents("queued") {
                        queuedCount += 1
                        queuedComplete.fulfill()
                    }
                    model.receiveBackgroundDownloadEvents("queued") {
                        queuedCount += 1
                        queuedComplete.fulfill()
                    }
                    try await self.waitForTask(waiter, label: "blocked background routing wait")
                    XCTAssertEqual(result, false)
                    model.finishBackgroundDownloadEvents("queued")
                    XCTAssertEqual(queuedCount, 0)
                    model.finishBackgroundDownloadEvents("first")
                    gate.release()
                    try await self.waitForEvents(
                        [firstComplete], label: "initial background completion")
                    XCTAssertEqual(firstCount, 1)
                    XCTAssertTrue(model.cancelBackgroundRoutingHandoff(token))
                    activeToken = nil
                    try await self.waitForEvents(
                        [queuedRoute, queuedComplete], label: "queued background replay")
                    XCTAssertEqual(queuedCount, 2)
                    XCTAssertFalse(model.cancelBackgroundRoutingHandoff(token))
                    try await fixture.drain(using: self)
                })
        }

        func testHandoffRollbackRetriesCancelledArtworkDemand() async throws {
            try await withLifecycleFixture { fixture, model in
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let entered = self.expectation(description: "first artwork request entered")
                let retried = self.expectation(description: "artwork request retried")
                let waitEntered = self.expectation(description: "artwork task wait registered")
                let gate = LifecycleGate(entered: entered)
                let scope = UUID().uuidString
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(directory)
                let album = FoundationItem(
                    id: UUID().uuidString, title: "Synthetic", subtitle: "", kind: .album,
                    duration: nil)
                var manifest = FoundationDownloadManifest()
                manifest.owners = [
                    .init(
                        id: "album:" + album.id, item: FoundationStoredDownloadItem(album),
                        tracks: [], paused: true, expanded: true)
                ]
                try FoundationDownloadStorage.save(manifest, directory: directory)
                let manager = FoundationDownloads(
                    scope: scope, library: HandoffArtworkLibrary(gate: gate, retried: retried),
                    root: fixture.storage.downloads, monitorConnectivity: false,
                    nativeRetirement: { _, _ in [] }, allowNativeCleanup: false)
                defer {
                    gate.release()
                    manager.invalidate()
                }
                manager.updateConnectivity(isAllowed: true)
                let artwork = try XCTUnwrap(manager.artworkTask)
                fixture.tasks.append(artwork)
                try await self.waitForEvents([entered], label: "first artwork request")
                let token = try XCTUnwrap(manager.beginAccountHandoff())
                manager.isolatedHandoffWorkWaitStarted = { waitEntered.fulfill() }
                var result: Bool?
                let waiter = Task { result = await manager.waitForHandoffOwnerTasks(token) }
                fixture.tasks.append(waiter)
                try await self.waitForEvents([waitEntered], label: "artwork task wait")
                gate.release()
                try await self.waitForTask(waiter, label: "artwork task drain")
                XCTAssertEqual(result, true)
                XCTAssertTrue(manager.cancelAccountHandoff(token))
                let retryTask = try XCTUnwrap(manager.artworkTask)
                fixture.tasks.append(retryTask)
                let reconciliation = Task { await manager.waitForCurrentReconciliationForTesting() }
                fixture.tasks.append(reconciliation)
                try await self.waitForEvents([retried], label: "artwork retry")
                try await self.waitForTask(retryTask, label: "artwork retry task")
                try await self.waitForTask(reconciliation, label: "artwork retry reconciliation")
                manager.invalidate()
            }
        }

        func testHandoffOwnerTaskWaitCancelsAndRollsBackWhileTransferIsHeld() async throws {
            try await withLifecycleFixture { fixture, model in
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let entered = self.expectation(description: "held transfer entered")
                let firstWait = self.expectation(description: "first owner task wait registered")
                let secondWait = self.expectation(description: "second owner task wait registered")
                let thirdWait = self.expectation(description: "third owner task wait registered")
                let gate = LifecycleGate(entered: entered)
                let manager = FoundationDownloads(
                    scope: UUID().uuidString, library: HandoffTransferLibrary(),
                    root: fixture.storage.downloads,
                    transfer: { _, _, _, _ in
                        await gate.hold()
                        try Task.checkCancellation()
                    }, monitorConnectivity: false, nativeRetirement: { _, _ in [] },
                    allowNativeCleanup: false)
                defer {
                    gate.release()
                    manager.invalidate()
                }
                manager.updateConnectivity(isAllowed: true)
                let reconciliation = Task { await manager.waitForCurrentReconciliationForTesting() }
                fixture.tasks.append(reconciliation)
                try await self.waitForTask(reconciliation, label: "initial task reconciliation")
                let track = FoundationItem(
                    id: UUID().uuidString, title: "Synthetic", subtitle: "", kind: .track,
                    duration: nil)
                manager.download(track)
                let worker = try XCTUnwrap(manager.isolatedWorkerTask)
                fixture.tasks.append(worker)
                try await self.waitForEvents([entered], label: "held transfer")
                var registrations = 0
                manager.isolatedHandoffWorkWaitStarted = {
                    registrations += 1
                    if registrations == 1 { firstWait.fulfill() }
                    if registrations == 2 { secondWait.fulfill() }
                    if registrations == 3 { thirdWait.fulfill() }
                }
                let token = try XCTUnwrap(manager.beginAccountHandoff())
                var firstResult: Bool?
                let first = Task { firstResult = await manager.waitForHandoffOwnerTasks(token) }
                fixture.tasks.append(first)
                try await self.waitForEvents([firstWait], label: "first owner task wait")
                first.cancel()
                try await self.waitForTask(first, label: "cancelled owner task wait")
                XCTAssertEqual(firstResult, false)
                var secondResult: Bool?
                let second = Task { secondResult = await manager.waitForHandoffOwnerTasks(token) }
                fixture.tasks.append(second)
                try await self.waitForEvents([secondWait], label: "second owner task wait")
                XCTAssertTrue(manager.cancelAccountHandoff(token))
                try await self.waitForTask(second, label: "rolled back owner task wait")
                XCTAssertEqual(secondResult, false)
                let retryToken = try XCTUnwrap(manager.beginAccountHandoff())
                var thirdResult: Bool?
                let third = Task {
                    thirdResult = await manager.waitForHandoffOwnerTasks(retryToken)
                }
                fixture.tasks.append(third)
                try await self.waitForEvents([thirdWait], label: "third owner task wait")
                XCTAssertNil(thirdResult)
                gate.release()
                try await self.waitForTask(worker, label: "held transfer worker")
                try await self.waitForTask(third, label: "completed owner task wait")
                XCTAssertEqual(thirdResult, true)
                manager.invalidate()
                XCTAssertFalse(manager.cancelAccountHandoff(retryToken))
            }
        }

        func testHandoffWaitsForEscapedRemoteResourceRelease() async throws {
            try await withLifecycleFixture { fixture, model in
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let releaseEntered = self.expectation(description: "remote release entered")
                let waitEntered = self.expectation(description: "remote operation wait registered")
                let secondJoined = self.expectation(description: "second release joined")
                let gate = LifecycleGate(entered: releaseEntered)
                let manager = FoundationDownloads(
                    scope: UUID().uuidString, library: HandoffRemoteLibrary(gate: gate),
                    root: fixture.storage.downloads, monitorConnectivity: false,
                    allowNativeCleanup: false)
                defer {
                    gate.release()
                    manager.invalidate()
                }
                manager.isolatedHandoffOperationsWaitStarted = { waitEntered.fulfill() }
                manager.isolatedRemoteReleaseJoined = { secondJoined.fulfill() }
                let track = FoundationItem(
                    id: UUID().uuidString, title: "Synthetic", subtitle: "", kind: .track,
                    duration: nil)
                var acquired: FoundationPlaybackResource?
                var acquisitionError: Error?
                let acquisition = Task {
                    do {
                        let resource = try await manager.playbackResource(for: track)
                        fixture.resources.append(resource)
                        acquired = resource
                    } catch { acquisitionError = error }
                }
                fixture.tasks.append(acquisition)
                try await self.waitForTask(acquisition, label: "remote resource acquisition")
                if let acquisitionError { throw acquisitionError }
                let resource = try XCTUnwrap(acquired)
                let token = try XCTUnwrap(manager.beginAccountHandoff())
                var result: Bool?
                let waiter = Task { result = await manager.waitForHandoffOperations(token) }
                fixture.tasks.append(waiter)
                try await self.waitForEvents([waitEntered], label: "remote operation wait")
                fixture.resources.removeAll()
                let release = Task { await resource.release() }
                fixture.tasks.append(release)
                try await self.waitForEvents([releaseEntered], label: "remote resource release")
                var secondFinished = false
                let secondRelease = Task {
                    await resource.release()
                    secondFinished = true
                }
                fixture.tasks.append(secondRelease)
                try await self.waitForEvents([secondJoined], label: "second release join")
                XCTAssertFalse(secondFinished)
                XCTAssertNil(result)
                gate.release()
                try await self.waitForTask(release, label: "remote resource release")
                try await self.waitForTask(secondRelease, label: "second remote release")
                try await self.waitForTask(waiter, label: "remote operation wait")
                XCTAssertEqual(result, true)
                XCTAssertTrue(manager.cancelAccountHandoff(token))
            }
        }

        func testHandoffWaitsForLateRemoteRequestAndItsRelease() async throws {
            try await withLifecycleFixture { fixture, model in
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let requestEntered = self.expectation(description: "remote request entered")
                let releaseEntered = self.expectation(description: "late remote release entered")
                let firstWait = self.expectation(description: "first remote drain registered")
                let secondWait = self.expectation(description: "second remote drain registered")
                let thirdWait = self.expectation(description: "third remote drain registered")
                let requestGate = LifecycleGate(entered: requestEntered)
                let releaseGate = LifecycleGate(entered: releaseEntered)
                let manager = FoundationDownloads(
                    scope: UUID().uuidString,
                    library: HandoffRemoteLibrary(gate: releaseGate, requestGate: requestGate),
                    root: fixture.storage.downloads, monitorConnectivity: false,
                    allowNativeCleanup: false)
                defer {
                    requestGate.release()
                    releaseGate.release()
                    manager.invalidate()
                }
                var registrations = 0
                manager.isolatedHandoffOperationsWaitStarted = {
                    registrations += 1
                    if registrations == 1 { firstWait.fulfill() }
                    if registrations == 2 { secondWait.fulfill() }
                    if registrations == 3 { thirdWait.fulfill() }
                }
                let track = FoundationItem(
                    id: UUID().uuidString, title: "Synthetic", subtitle: "", kind: .track,
                    duration: nil)
                var acquisitionError: Error?
                let acquisition = Task {
                    do {
                        let resource = try await manager.playbackResource(for: track)
                        fixture.resources.append(resource)
                    } catch { acquisitionError = error }
                }
                fixture.tasks.append(acquisition)
                try await self.waitForEvents([requestEntered], label: "remote request")
                let token = try XCTUnwrap(manager.beginAccountHandoff())
                var cancelled: Bool?
                let first = Task { cancelled = await manager.waitForHandoffOperations(token) }
                fixture.tasks.append(first)
                try await self.waitForEvents([firstWait], label: "first remote drain")
                first.cancel()
                try await self.waitForTask(first, label: "cancelled remote drain")
                XCTAssertEqual(cancelled, false)
                var rolledBack: Bool?
                let second = Task { rolledBack = await manager.waitForHandoffOperations(token) }
                fixture.tasks.append(second)
                try await self.waitForEvents([secondWait], label: "second remote drain")
                XCTAssertTrue(manager.cancelAccountHandoff(token))
                try await self.waitForTask(second, label: "rolled back remote drain")
                XCTAssertEqual(rolledBack, false)
                let retryToken = try XCTUnwrap(manager.beginAccountHandoff())
                var result: Bool?
                let waiter = Task { result = await manager.waitForHandoffOperations(retryToken) }
                fixture.tasks.append(waiter)
                try await self.waitForEvents([thirdWait], label: "third remote drain")
                requestGate.release()
                try await self.waitForEvents([releaseEntered], label: "late remote release")
                XCTAssertNil(result)
                releaseGate.release()
                try await self.waitForTask(acquisition, label: "late remote request")
                try await self.waitForTask(waiter, label: "late remote drain")
                XCTAssertTrue(acquisitionError is CancellationError)
                XCTAssertTrue(fixture.resources.isEmpty)
                XCTAssertEqual(result, true)
                XCTAssertTrue(manager.cancelAccountHandoff(retryToken))
            }
        }

        func testHandoffWaitsForDetachedRetainedArtworkRead() async throws {
            try await withLifecycleFixture { fixture, model in
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let readEntered = self.expectation(description: "detached artwork read entered")
                let waiterEntered = self.expectation(description: "artwork drain registered")
                let gate = LifecycleGate(entered: readEntered)
                let scope = UUID().uuidString
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(directory)
                let file = directory.appendingPathComponent("synthetic-artwork")
                let bytes = Data("synthetic-artwork-bytes".utf8)
                try bytes.write(to: file)
                let album = FoundationItem(
                    id: UUID().uuidString, title: "Synthetic", subtitle: "", kind: .album,
                    duration: nil)
                let stored = FoundationStoredDownloadItem(album)
                var manifest = FoundationDownloadManifest()
                manifest.owners = [
                    .init(
                        id: "album:" + album.id, item: stored, tracks: [], paused: true,
                        expanded: true)
                ]
                manifest.artwork = [
                    "album:" + album.id: .init(
                        item: stored,
                        file: .init(
                            name: file.lastPathComponent, bytes: Int64(bytes.count),
                            digest: try FoundationDownloadStorage.digest(file)))
                ]
                try FoundationDownloadStorage.save(manifest, directory: directory)
                let manager = FoundationDownloads(
                    scope: scope, library: HandoffTransferLibrary(),
                    root: fixture.storage.downloads,
                    monitorConnectivity: false, nativeRetirement: { _, _ in [] },
                    allowNativeCleanup: false)
                defer {
                    gate.release()
                    manager.invalidate()
                }
                let inventory = self.expectation(description: "artwork inventory verified")
                let observation = manager.$isLoading.filter { !$0 }.first().sink { _ in
                    inventory.fulfill()
                }
                defer { observation.cancel() }
                try await self.waitForEvents([inventory], label: "artwork inventory")
                XCTAssertNotNil(manager.retainedArtworkIdentity(for: album))
                manager.isolatedArtworkReadStarted = { await gate.hold() }
                manager.isolatedHandoffOperationsWaitStarted = { waiterEntered.fulfill() }
                var image: Data?
                let read = Task { image = await manager.retainedArtwork(for: album) }
                fixture.tasks.append(read)
                try await self.waitForEvents([readEntered], label: "detached artwork read")
                let token = try XCTUnwrap(manager.beginAccountHandoff())
                var result: Bool?
                let waiter = Task { result = await manager.waitForHandoffOperations(token) }
                fixture.tasks.append(waiter)
                try await self.waitForEvents([waiterEntered], label: "artwork drain")
                XCTAssertNil(result)
                gate.release()
                try await self.waitForTask(read, label: "detached artwork read")
                try await self.waitForTask(waiter, label: "artwork drain")
                XCTAssertNil(image)
                XCTAssertEqual(result, true)
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                XCTAssertTrue(manager.cancelAccountHandoff(token))
            }
        }

        func testHandoffLeaseWaitCanCancelAndRetryWithoutRetiringOwner() async throws {
            let firstWait = expectation(description: "first handoff lease wait registered")
            let secondWait = expectation(description: "second handoff lease wait registered")
            let thirdWait = expectation(description: "third handoff lease wait registered")
            let fourthWait = expectation(description: "fourth handoff lease wait registered")
            var registrations = 0
            try await withLifecycleFixture(
                leaseWaitStarted: {
                    registrations += 1
                    if registrations == 1 { firstWait.fulfill() }
                    if registrations == 2 { secondWait.fulfill() }
                    if registrations == 3 { thirdWait.fulfill() }
                    if registrations == 4 { fourthWait.fulfill() }
                },
                { fixture, model in
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    let accept = try await model.prepareSignIn { session }
                    let scope = FoundationMusicLibraryStore.digest(
                        "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                    let track = FoundationItem(
                        id: "00000000000000000000000000000003", title: "Synthetic",
                        subtitle: "", kind: .track, duration: nil)
                    let directory = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads)
                    try FoundationDownloadStorage.prepare(directory)
                    let file = directory.appendingPathComponent("synthetic.audio")
                    let bytes = Data("synthetic-test-bytes".utf8)
                    try bytes.write(to: file)
                    var manifest = FoundationDownloadManifest()
                    let stored = FoundationStoredDownloadItem(track)
                    manifest.owners = [
                        .init(
                            id: "track:" + track.id, item: stored, tracks: [stored],
                            paused: false, expanded: false)
                    ]
                    manifest.files[track.id] = .init(
                        name: file.lastPathComponent, bytes: Int64(bytes.count),
                        digest: try FoundationDownloadStorage.digest(file))
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    try await accept()
                    let downloads = try XCTUnwrap(model.downloads)
                    let inventory = self.expectation(description: "handoff inventory verified")
                    let observation = downloads.$isLoading.filter { !$0 }.first().sink { _ in
                        inventory.fulfill()
                    }
                    defer { observation.cancel() }
                    try await self.waitForEvents([inventory], label: "handoff inventory")
                    try await fixture.acquireResource(from: downloads, item: track, using: self)
                    let token = try XCTUnwrap(downloads.beginAccountHandoff())
                    let refreshed = FoundationSession(
                        serverURL: session.serverURL, accessToken: "new-synthetic-token",
                        userID: session.userID, deviceID: session.deviceID)
                    let refreshedLibrary = FoundationJellyfinLibrary(session: refreshed) { _ in
                        throw URLError(.notConnectedToInternet)
                    }
                    let otherSession = fixture.session(user: "00000000000000000000000000000002")
                    let otherLibrary = FoundationJellyfinLibrary(session: otherSession) { _ in
                        throw URLError(.notConnectedToInternet)
                    }
                    XCTAssertFalse(downloads.rebindSameAccountLibrary(otherLibrary, token: token))
                    XCTAssertFalse(
                        downloads.rebindSameAccountLibrary(refreshedLibrary, token: UUID()))
                    XCTAssertEqual(
                        downloads.isolatedLibrarySession?.accessToken, session.accessToken)
                    XCTAssertTrue(
                        downloads.rebindSameAccountLibrary(refreshedLibrary, token: token))
                    XCTAssertEqual(
                        downloads.isolatedLibrarySession?.accessToken, refreshed.accessToken)
                    XCTAssertFalse(
                        downloads.rebindSameAccountLibrary(refreshedLibrary, token: token))
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                    var firstResult: Bool?
                    let first = Task {
                        firstResult = await downloads.waitForHandoffPlaybackLeases(token)
                    }
                    fixture.tasks.append(first)
                    try await self.waitForEvents([firstWait], label: "first lease wait")
                    let staleResult = await downloads.waitForHandoffPlaybackLeases(UUID())
                    let overlapResult = await downloads.waitForHandoffPlaybackLeases(token)
                    XCTAssertFalse(staleResult)
                    XCTAssertFalse(overlapResult)
                    first.cancel()
                    try await self.waitForTask(first, label: "cancelled lease wait")
                    XCTAssertEqual(firstResult, false)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                    var secondResult: Bool?
                    let second = Task {
                        secondResult = await downloads.waitForHandoffPlaybackLeases(token)
                    }
                    fixture.tasks.append(second)
                    try await self.waitForEvents([secondWait], label: "second lease wait")
                    XCTAssertFalse(downloads.cancelAccountHandoff(UUID()))
                    XCTAssertTrue(downloads.cancelAccountHandoff(token))
                    try await self.waitForTask(second, label: "rolled back lease wait")
                    XCTAssertEqual(secondResult, false)
                    XCTAssertEqual(
                        downloads.isolatedLibrarySession?.accessToken, session.accessToken)
                    let nextToken = try XCTUnwrap(downloads.beginAccountHandoff())
                    XCTAssertTrue(
                        downloads.rebindSameAccountLibrary(refreshedLibrary, token: nextToken))
                    var thirdResult: Bool?
                    let third = Task {
                        thirdResult = await downloads.waitForHandoffPlaybackLeases(nextToken)
                    }
                    fixture.tasks.append(third)
                    try await self.waitForEvents([thirdWait], label: "third lease wait")
                    try await fixture.releaseResources(using: self)
                    try await self.waitForTask(third, label: "released lease wait")
                    XCTAssertEqual(thirdResult, true)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                    XCTAssertFalse(downloads.commitSameAccountRebind(token))
                    XCTAssertTrue(downloads.commitSameAccountRebind(nextToken))
                    XCTAssertEqual(
                        downloads.isolatedLibrarySession?.accessToken, refreshed.accessToken)
                    try await fixture.acquireResource(from: downloads, item: track, using: self)
                    let lastToken = try XCTUnwrap(downloads.beginAccountHandoff())
                    var fourthResult: Bool?
                    let fourth = Task {
                        fourthResult = await downloads.waitForHandoffPlaybackLeases(lastToken)
                    }
                    fixture.tasks.append(fourth)
                    try await self.waitForEvents([fourthWait], label: "fourth lease wait")
                    downloads.invalidate()
                    try await self.waitForTask(fourth, label: "retired lease wait")
                    XCTAssertEqual(fourthResult, false)
                    XCTAssertFalse(downloads.cancelAccountHandoff(lastToken))
                    try await fixture.releaseResources(using: self)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                })
        }

        func testCancelledSignOutCleanupFencesSameScopeUntilLeaseRelease() async throws {
            let firstWait = expectation(description: "sign-out lease wait registered")
            let retryWait = expectation(description: "cleanup retry lease wait registered")
            var registrations = 0
            try await withLifecycleFixture(
                leaseWaitStarted: {
                    registrations += 1
                    if registrations == 1 { firstWait.fulfill() }
                    if registrations == 2 { retryWait.fulfill() }
                },
                { fixture, model in
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    var prepared: FoundationSignInView.Acceptance?
                    var preparationError: Error?
                    let preparation = Task {
                        do { prepared = try await model.prepareSignIn { session } } catch {
                            preparationError = error
                        }
                    }
                    fixture.tasks.append(preparation)
                    try await self.waitForTask(preparation, label: "initial sign-in preparation")
                    if let preparationError { throw preparationError }
                    let accept = try XCTUnwrap(prepared)
                    let scope = FoundationMusicLibraryStore.digest(
                        "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                    let track = FoundationItem(
                        id: "00000000000000000000000000000003", title: "Synthetic",
                        subtitle: "", kind: .track, duration: nil)
                    let directory = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads)
                    try FoundationDownloadStorage.prepare(directory)
                    let file = directory.appendingPathComponent("synthetic.audio")
                    let bytes = Data("synthetic-test-bytes".utf8)
                    try bytes.write(to: file)
                    var manifest = FoundationDownloadManifest()
                    let stored = FoundationStoredDownloadItem(track)
                    manifest.owners = [
                        .init(
                            id: "track:" + track.id, item: stored, tracks: [stored],
                            paused: false, expanded: false)
                    ]
                    manifest.files[track.id] = .init(
                        name: file.lastPathComponent, bytes: Int64(bytes.count),
                        digest: try FoundationDownloadStorage.digest(file))
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    try await accept()
                    let downloads = try XCTUnwrap(model.downloads)
                    let inventory = self.expectation(description: "sign-out inventory verified")
                    let inventoryObservation = downloads.$isLoading.filter { !$0 }.first().sink {
                        _ in
                        inventory.fulfill()
                    }
                    defer { inventoryObservation.cancel() }
                    try await self.waitForEvents([inventory], label: "sign-out inventory")
                    try await fixture.acquireResource(from: downloads, item: track, using: self)
                    let player = try XCTUnwrap(model.player)
                    let oldDelayEntered = self.expectation(
                        description: "old cleanup status delay entered")
                    let oldDelay = LifecycleGate(entered: oldDelayEntered)
                    let retryDelayEntered = self.expectation(
                        description: "retry cleanup status delay entered")
                    let retryDelay = LifecycleGate(entered: retryDelayEntered)
                    defer {
                        oldDelay.release()
                        retryDelay.release()
                    }
                    model.isolatedCleanupStatusDelay = { await oldDelay.hold() }
                    model.signOut()
                    let oldStatusTask = try XCTUnwrap(model.isolatedCleanupStatusTask)
                    fixture.captureStop(player)
                    let firstFinished = self.expectation(description: "cancelled cleanup finished")
                    let firstObservation = model.$isCleaningDownloads.dropFirst().filter { !$0 }
                        .first()
                        .sink { _ in firstFinished.fulfill() }
                    defer { firstObservation.cancel() }
                    try await self.waitForEvents(
                        [firstWait, oldDelayEntered], label: "sign-out lease and status wait")
                    try XCTUnwrap(model.isolatedSignOutCleanupTask).cancel()
                    try await self.waitForEvents([firstFinished], label: "cancelled cleanup")
                    XCTAssertNotNil(model.credentialError)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                    let retryFinished = self.expectation(description: "cleanup retry finished")
                    let retryObservation = model.$isCleaningDownloads.dropFirst().filter { !$0 }
                        .first()
                        .sink { _ in retryFinished.fulfill() }
                    defer { retryObservation.cancel() }
                    model.isolatedCleanupStatusDelay = { await retryDelay.hold() }
                    let delayed = self.expectation(
                        description: "retry cleanup status became delayed")
                    let delayObservation = model.$cleanupTakingLonger.dropFirst().filter { $0 }
                        .first()
                        .sink { _ in delayed.fulfill() }
                    defer { delayObservation.cancel() }
                    var authenticated = false
                    var pendingError: Error?
                    let pendingAttempt = Task {
                        do {
                            _ = try await model.prepareSignIn {
                                authenticated = true
                                return session
                            }
                            XCTFail("Sign-in was admitted before retired cleanup")
                        } catch { pendingError = error }
                    }
                    fixture.tasks.append(pendingAttempt)
                    try await self.waitForTask(pendingAttempt, label: "fenced sign-in preparation")
                    guard let downloadError = pendingError as? FoundationDownloadAccountError,
                        case .cleanupPending = downloadError
                    else {
                        XCTFail("Expected pending cleanup error; retained fixture")
                        throw CancellationError()
                    }
                    XCTAssertFalse(authenticated)
                    try await self.waitForEvents(
                        [retryWait, retryDelayEntered], label: "cleanup retry lease and status wait"
                    )
                    oldDelay.release()
                    try await self.waitForTask(oldStatusTask, label: "old cleanup status task")
                    XCTAssertFalse(model.cleanupTakingLonger)
                    retryDelay.release()
                    try await self.waitForEvents([delayed], label: "retry cleanup delayed status")
                    XCTAssertTrue(model.cleanupTakingLonger)
                    let writesBeforeRestore = fixture.credentialWrites
                    model.restoreCredentials()
                    XCTAssertNil(model.library)
                    XCTAssertNil(model.player)
                    XCTAssertEqual(fixture.credentialWrites, writesBeforeRestore)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                    try await fixture.releaseResources(using: self)
                    try await self.waitForEvents([retryFinished], label: "cleanup retry")
                    XCTAssertFalse(model.cleanupTakingLonger)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
                    XCTAssertNil(model.credentialError)
                    fixture.gate.release()
                    try await fixture.drain(using: self)
                    var nextPrepared: FoundationSignInView.Acceptance?
                    var nextError: Error?
                    let nextAttempt = Task {
                        do { nextPrepared = try await model.prepareSignIn { session } } catch {
                            nextError = error
                        }
                    }
                    fixture.tasks.append(nextAttempt)
                    try await self.waitForTask(nextAttempt, label: "same-scope sign-in preparation")
                    if let nextError { throw nextError }
                    let next = try XCTUnwrap(nextPrepared)
                    try await next()
                    let current = try XCTUnwrap(model.downloads)
                    let sentinel = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads
                    )
                    .appendingPathComponent("new-owner-sentinel")
                    try Data("replacement".utf8).write(to: sentinel)
                    try await fixture.drain(using: self)
                    XCTAssertTrue(model.downloads === current)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
                })
        }

        func testSignOutWaitsForHeldModelDownloadLease() async throws {
            let leaseWait = expectation(description: "sign-out registered playback lease wait")
            let acknowledgeLeaseWait = { leaseWait.fulfill() }
            try await withLifecycleFixture(leaseWaitStarted: acknowledgeLeaseWait) {
                fixture, model in
                let session = fixture.session(user: "00000000000000000000000000000001")
                let accept = try await model.prepareSignIn { session }
                let scope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                let track = FoundationItem(
                    id: "00000000000000000000000000000003", title: "Synthetic",
                    subtitle: "", kind: .track, duration: nil)
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(directory)
                let file = directory.appendingPathComponent("synthetic.audio")
                let bytes = Data("synthetic-test-bytes".utf8)
                try bytes.write(to: file)
                var manifest = FoundationDownloadManifest()
                let stored = FoundationStoredDownloadItem(track)
                manifest.owners = [
                    .init(
                        id: "track:" + track.id, item: stored, tracks: [stored], paused: false,
                        expanded: false)
                ]
                manifest.files[track.id] = .init(
                    name: file.lastPathComponent, bytes: Int64(bytes.count),
                    digest: try FoundationDownloadStorage.digest(file))
                try FoundationDownloadStorage.save(manifest, directory: directory)
                try await accept()
                let downloads = try XCTUnwrap(model.downloads)
                let inventory = self.expectation(description: "synthetic inventory verified")
                let observation = downloads.$isLoading.filter { !$0 }.first().sink { _ in
                    inventory.fulfill()
                }
                defer { observation.cancel() }
                try await self.waitForEvents([inventory], label: "download inventory")
                XCTAssertTrue(downloads.isReady(track))
                try await fixture.acquireResource(from: downloads, item: track, using: self)
                let player = try XCTUnwrap(model.player)
                let delayEntered = self.expectation(description: "cleanup status delay entered")
                let delayGate = LifecycleGate(entered: delayEntered)
                defer { delayGate.release() }
                model.isolatedCleanupStatusDelay = { await delayGate.hold() }
                let delayed = self.expectation(description: "cleanup status became delayed")
                let statusObservation = model.$cleanupTakingLonger.dropFirst().filter { $0 }.first()
                    .sink { _ in delayed.fulfill() }
                defer { statusObservation.cancel() }
                model.signOut()
                fixture.captureStop(player)
                try await self.waitForEvents(
                    [leaseWait, delayEntered], label: "sign-out lease and status delay")
                delayGate.release()
                try await self.waitForEvents([delayed], label: "delayed cleanup status")
                XCTAssertTrue(model.cleanupTakingLonger)
                XCTAssertNil(model.player)
                XCTAssertTrue(model.isCleaningDownloads)
                XCTAssertNil(model.signOutNotice)
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                fixture.gate.release()
                try await fixture.releaseResources(using: self)
                try await fixture.drain(using: self)
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
                XCTAssertFalse(model.isCleaningDownloads)
                XCTAssertFalse(model.cleanupTakingLonger)
                XCTAssertEqual(model.signOutNotice?.contains("Downloads removed."), true)
            }
        }

        func testFastCleanupDoesNotPublishStaleDelayedStatus() async throws {
            try await withLifecycleFixture { fixture, model in
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let player = try XCTUnwrap(model.player)
                let delay = LifecycleGate(
                    entered: XCTestExpectation(description: "cleanup delay entered"))
                defer { delay.release() }
                model.isolatedCleanupStatusDelay = { await delay.hold() }
                let finished = self.expectation(description: "fast cleanup finished")
                let observation = model.$isCleaningDownloads.dropFirst().filter { !$0 }.first()
                    .sink { _ in finished.fulfill() }
                defer { observation.cancel() }
                model.signOut()
                fixture.captureStop(player)
                try await self.waitForEvents([finished], label: "fast cleanup")
                XCTAssertFalse(model.isCleaningDownloads)
                XCTAssertFalse(model.cleanupTakingLonger)
                delay.release()
                fixture.gate.release()
                try await fixture.drain(using: self)
                XCTAssertFalse(model.cleanupTakingLonger)
            }
        }

        #if os(macOS)
            func testMacReauthenticationDefersReentrantSignOutUntilCommit() async throws {
                try await withLifecycleFixture { fixture, model in
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    try await fixture.open(model, user: session.userID)
                    let owner = try XCTUnwrap(model.downloads)
                    let player = try XCTUnwrap(model.player)
                    model.requireMacSignIn()
                    fixture.captureStop(player)
                    let observed = self.expectation(description: "reentrant sign-out requested")
                    var deferredSafely = false
                    let observation = model.$requiresSignIn.dropFirst().filter { !$0 }.first().sink
                    { _ in
                        let writes = fixture.credentialWrites
                        model.retryCachePreparation()
                        model.cancelCredentialUpgrade()
                        model.restoreCredentials()
                        model.signOut()
                        deferredSafely =
                            model.downloads === owner && model.library != nil
                            && !model.isPreparingCaches && fixture.credentialWrites == writes
                        observed.fulfill()
                    }
                    defer { observation.cancel() }
                    var prepared: FoundationSignInView.Acceptance?
                    var preparationError: Error?
                    let preparation = Task {
                        do { prepared = try await model.prepareSignIn { session } } catch {
                            preparationError = error
                        }
                    }
                    fixture.tasks.append(preparation)
                    try await self.waitForTask(preparation, label: "reentrant preparation")
                    if let preparationError { throw preparationError }
                    let accept = try XCTUnwrap(prepared)
                    var commitError: Error?
                    let commit = Task {
                        do { try await accept() } catch { commitError = error }
                    }
                    fixture.tasks.append(commit)
                    try await self.waitForEvents([observed], label: "reentrant sign-out")
                    try await self.waitForTask(commit, label: "reentrant acceptance")
                    if let commitError { throw commitError }
                    XCTAssertTrue(deferredSafely)
                    XCTAssertNil(model.library)
                    XCTAssertNil(model.downloads)
                    fixture.gate.release()
                    try await fixture.drain(using: self)
                }
            }

            func testMacSameAccountSaveFailureRestoresOwnerAndData() async throws {
                try await withLifecycleFixture { fixture, model in
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    try await fixture.open(model, user: session.userID)
                    let downloads = try XCTUnwrap(model.downloads)
                    let player = try XCTUnwrap(model.player)
                    let scope = try XCTUnwrap(model.library).catalogAccountIdentity
                    let actions = try XCTUnwrap(model.actions)
                    actions.togglePin(fixture.album)
                    let pinKey = FoundationPinStorage.key(for: scope)
                    let pins = try XCTUnwrap(fixture.defaults.data(forKey: pinKey))
                    let directory = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads)
                    let file = directory.appendingPathComponent("synthetic-preservation")
                    let bytes = Data("synthetic-preserved-bytes".utf8)
                    try bytes.write(to: file)
                    model.requireMacSignIn()
                    fixture.captureStop(player)
                    let refreshed = FoundationSession(
                        serverURL: session.serverURL, accessToken: "new-synthetic-token",
                        userID: session.userID, deviceID: session.deviceID)
                    var prepared: FoundationSignInView.Acceptance?
                    var preparationError: Error?
                    let preparation = Task {
                        do { prepared = try await model.prepareSignIn { refreshed } } catch {
                            preparationError = error
                        }
                    }
                    fixture.tasks.append(preparation)
                    try await self.waitForTask(preparation, label: "save-failure preparation")
                    if let preparationError { throw preparationError }
                    let accept = try XCTUnwrap(prepared)
                    fixture.saveStatus = errSecAuthFailed
                    defer { fixture.saveStatus = errSecSuccess }
                    var commitError: Error?
                    let commit = Task {
                        do { try await accept() } catch { commitError = error }
                    }
                    fixture.tasks.append(commit)
                    try await self.waitForTask(commit, label: "save-failure acceptance")
                    XCTAssertNotNil(commitError)
                    XCTAssertTrue(model.downloads === downloads)
                    XCTAssertTrue(model.player === player)
                    XCTAssertTrue(model.requiresSignIn)
                    XCTAssertEqual(
                        downloads.isolatedLibrarySession?.accessToken, session.accessToken)
                    XCTAssertEqual(fixture.defaults.data(forKey: pinKey), pins)
                    XCTAssertEqual(try? Data(contentsOf: file), bytes)
                    guard commitError != nil, model.downloads === downloads,
                        model.player === player,
                        fixture.defaults.data(forKey: pinKey) == pins,
                        (try? Data(contentsOf: file)) == bytes
                    else { throw CancellationError() }
                }
            }

            func testMacSameAccountReauthenticationPreservesScopedData() async throws {
                let enableOrdinaryInventory = {}
                try await withLifecycleFixture(leaseWaitStarted: enableOrdinaryInventory) {
                    fixture, model in
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    let initial = try await model.prepareSignIn { session }
                    let scope = FoundationMusicLibraryStore.digest(
                        "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                    var track = FoundationItem(
                        id: "00000000000000000000000000000003", title: "Synthetic",
                        subtitle: "", kind: .track, duration: nil)
                    track.album = .init(id: "owner-album", title: "Synthetic album")
                    track.trackNumber = 1
                    var alternate = FoundationItem(
                        id: "00000000000000000000000000000004", title: "Synthetic",
                        subtitle: "", kind: .track, duration: nil)
                    alternate.album = track.album
                    alternate.trackNumber = 1
                    let collection = FoundationItem(
                        id: "collection-album", title: "Collection", subtitle: "", kind: .album,
                        duration: nil)
                    var collectionTrack = FoundationItem(
                        id: "00000000000000000000000000000005", title: "Collection track",
                        subtitle: "", kind: .track, duration: nil)
                    collectionTrack.album = .init(id: collection.id, title: collection.title)
                    collectionTrack.trackNumber = 1
                    var collectionAlternate = FoundationItem(
                        id: "00000000000000000000000000000006", title: "Collection track",
                        subtitle: "", kind: .track, duration: nil)
                    collectionAlternate.album = collectionTrack.album
                    collectionAlternate.trackNumber = 1
                    let directory = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads)
                    try FoundationDownloadStorage.prepare(directory)
                    let file = directory.appendingPathComponent("synthetic.audio")
                    let bytes = Data("synthetic-test-bytes".utf8)
                    try bytes.write(to: file)
                    let stored = FoundationStoredDownloadItem(track)
                    var manifest = FoundationDownloadManifest()
                    manifest.owners = [
                        .init(
                            id: "track:" + track.id, item: stored,
                            tracks: [stored, FoundationStoredDownloadItem(alternate)],
                            paused: false, expanded: false)
                    ]
                    manifest.collections = [
                        .init(
                            item: FoundationStoredDownloadItem(collection),
                            tracks: [
                                FoundationStoredDownloadItem(collectionTrack),
                                FoundationStoredDownloadItem(collectionAlternate),
                            ], complete: true)
                    ]
                    manifest.files[track.id] = .init(
                        name: file.lastPathComponent, bytes: Int64(bytes.count),
                        digest: try FoundationDownloadStorage.digest(file))
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    try await initial()
                    let downloads = try XCTUnwrap(model.downloads)
                    let inventory = self.expectation(description: "same-account inventory verified")
                    let observation = downloads.$isLoading.filter { !$0 }.first().sink { _ in
                        inventory.fulfill()
                    }
                    defer { observation.cancel() }
                    try await self.waitForEvents([inventory], label: "same-account inventory")
                    try await fixture.acquireResource(from: downloads, item: track, using: self)
                    let player = try XCTUnwrap(model.player)
                    model.requireMacSignIn()
                    fixture.captureStop(player)
                    let actions = try XCTUnwrap(model.actions)
                    XCTAssertTrue(
                        actions.visibleTracks([alternate], isAvailable: { _ in true }).isEmpty)
                    XCTAssertTrue(
                        actions.visibleTracks([collectionAlternate], isAvailable: { _ in true })
                            .isEmpty)
                    actions.togglePin(fixture.album)
                    let pinKey = FoundationPinStorage.key(for: scope)
                    let pins = try XCTUnwrap(fixture.defaults.data(forKey: pinKey))
                    let store = FoundationPlaybackSessionStore(
                        scope: scope, root: fixture.storage.playback)
                    XCTAssertTrue(store.save(FoundationPlaybackSnapshot(player: player)))
                    let savedSession = try Data(contentsOf: store.file)
                    let entered = self.expectation(
                        description: "same-account authentication entered")
                    let gate = LifecycleGate(entered: entered)
                    var acceptance: FoundationSignInView.Acceptance?
                    var failure: Error?
                    let authentication = Task {
                        do {
                            acceptance = try await model.prepareSignIn {
                                await gate.hold()
                                try Task.checkCancellation()
                                return session
                            }
                        } catch { failure = error }
                    }
                    fixture.tasks.append(authentication)
                    defer {
                        authentication.cancel()
                        gate.release()
                    }
                    try await self.waitForEvents([entered], label: "same-account authentication")
                    XCTAssertTrue(gate.isHeld)
                    let pinsDuring = fixture.defaults.data(forKey: pinKey)
                    let sessionDuring = try? Data(contentsOf: store.file)
                    let downloadDuring = try? Data(contentsOf: file)
                    XCTAssertEqual(pinsDuring, pins)
                    XCTAssertEqual(sessionDuring, savedSession)
                    XCTAssertEqual(downloadDuring, bytes)
                    gate.release()
                    try await self.waitForTask(
                        authentication, label: "same-account authentication completion")
                    if let failure { throw failure }
                    guard pinsDuring == pins, sessionDuring == savedSession, downloadDuring == bytes
                    else {
                        // Preserve the fixture if recovery already deleted data.
                        throw CancellationError()
                    }
                    let commit = try XCTUnwrap(acceptance)
                    var commitFailure: Error?
                    let commitTask = Task {
                        do { try await commit() } catch { commitFailure = error }
                    }
                    fixture.tasks.append(commitTask)
                    try await self.waitForTask(commitTask, label: "same-account acceptance")
                    if let commitFailure { throw commitFailure }
                    fixture.captureStop(player)
                    try await fixture.drain(using: self)
                    let pinsAfter = fixture.defaults.data(forKey: pinKey)
                    let sessionAfter = try? Data(contentsOf: store.file)
                    let downloadAfter = try? Data(contentsOf: file)
                    let pinVisible = try XCTUnwrap(model.actions).isPinned(fixture.album)
                    let ownerProjection = try XCTUnwrap(model.actions).visibleTracks(
                        [alternate], isAvailable: { _ in true })
                    let collectionProjection = try XCTUnwrap(model.actions).visibleTracks(
                        [collectionAlternate], isAvailable: { _ in true })
                    XCTAssertFalse(model.requiresSignIn)
                    XCTAssertEqual(model.library?.catalogAccountIdentity, scope)
                    XCTAssertEqual(pinsAfter, pins)
                    XCTAssertEqual(sessionAfter, savedSession)
                    XCTAssertEqual(downloadAfter, bytes)
                    XCTAssertTrue(model.downloads === downloads)
                    XCTAssertTrue(ownerProjection.isEmpty)
                    XCTAssertTrue(collectionProjection.isEmpty)
                    XCTAssertTrue(pinVisible)
                    guard !model.requiresSignIn, model.library?.catalogAccountIdentity == scope,
                        pinsAfter == pins, sessionAfter == savedSession,
                        downloadAfter == bytes, pinVisible, model.downloads === downloads,
                        ownerProjection.isEmpty, collectionProjection.isEmpty
                    else {
                        // Preserve the fixture when post-acceptance ownership or data differs.
                        throw CancellationError()
                    }
                    try await fixture.releaseResources(using: self)
                }
            }

            func testMacReauthenticationCancellationPreservesAccountDataAndHeldLease() async throws
            {
                try await checkMacReauthenticationPreservesData(cancelAuthentication: true)
            }

            func testMacReauthenticationFailurePreservesAccountDataAndHeldLease() async throws {
                try await checkMacReauthenticationPreservesData(cancelAuthentication: false)
            }

            private func checkMacReauthenticationPreservesData(cancelAuthentication: Bool)
                async throws
            {
                let enableOrdinaryInventory = {}
                try await withLifecycleFixture(leaseWaitStarted: enableOrdinaryInventory) {
                    fixture, model in
                    let session = fixture.session(user: "00000000000000000000000000000001")
                    let accept = try await model.prepareSignIn { session }
                    let scope = FoundationMusicLibraryStore.digest(
                        "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                    let track = FoundationItem(
                        id: "00000000000000000000000000000003", title: "Synthetic",
                        subtitle: "", kind: .track, duration: nil)
                    let directory = FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads)
                    try FoundationDownloadStorage.prepare(directory)
                    let downloadFile = directory.appendingPathComponent("synthetic.audio")
                    let bytes = Data("synthetic-test-bytes".utf8)
                    try bytes.write(to: downloadFile)
                    let stored = FoundationStoredDownloadItem(track)
                    var manifest = FoundationDownloadManifest()
                    manifest.owners = [
                        .init(
                            id: "track:" + track.id, item: stored, tracks: [stored],
                            paused: false, expanded: false)
                    ]
                    manifest.files[track.id] = .init(
                        name: downloadFile.lastPathComponent, bytes: Int64(bytes.count),
                        digest: try FoundationDownloadStorage.digest(downloadFile))
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    try await accept()
                    let downloads = try XCTUnwrap(model.downloads)
                    let inventory = self.expectation(description: "reauth inventory verified")
                    let observation = downloads.$isLoading.filter { !$0 }.first().sink { _ in
                        inventory.fulfill()
                    }
                    defer { observation.cancel() }
                    try await self.waitForEvents([inventory], label: "reauth inventory")
                    XCTAssertTrue(downloads.isReady(track))
                    try await fixture.acquireResource(from: downloads, item: track, using: self)
                    let player = try XCTUnwrap(model.player)
                    model.requireMacSignIn()
                    fixture.captureStop(player)
                    XCTAssertTrue(model.requiresSignIn)
                    XCTAssertTrue(model.player === player)
                    XCTAssertNotNil(model.library)
                    let actions = try XCTUnwrap(model.actions)
                    actions.togglePin(fixture.album)
                    let pinKey = FoundationPinStorage.key(for: scope)
                    let pins = try XCTUnwrap(fixture.defaults.data(forKey: pinKey))
                    let initialWrites = fixture.credentialWrites
                    let initialDeletes = fixture.credentialDeletes
                    let playbackStore = FoundationPlaybackSessionStore(
                        scope: scope, root: fixture.storage.playback)
                    XCTAssertTrue(playbackStore.save(FoundationPlaybackSnapshot(player: player)))
                    let playbackBytes = try Data(contentsOf: playbackStore.file)
                    XCTAssertEqual(try Data(contentsOf: downloadFile), bytes)

                    let entered = self.expectation(
                        description: "same-account reauthentication entered")
                    let authGate = LifecycleGate(entered: entered)
                    var authenticationFailure: Error?
                    let authentication = Task {
                        do {
                            _ = try await model.prepareSignIn {
                                await authGate.hold()
                                try Task.checkCancellation()
                                throw URLError(.userAuthenticationRequired)
                            }
                            XCTFail("Synthetic reauthentication unexpectedly succeeded")
                        } catch { authenticationFailure = error }
                    }
                    fixture.tasks.append(authentication)
                    defer {
                        authentication.cancel()
                        authGate.release()
                    }
                    try await self.waitForEvents([entered], label: "same-account reauthentication")
                    XCTAssertTrue(authGate.isHeld)
                    let pinsDuring = fixture.defaults.data(forKey: pinKey)
                    let playbackDuring = try? Data(contentsOf: playbackStore.file)
                    let downloadDuring = try? Data(contentsOf: downloadFile)
                    XCTAssertEqual(
                        pinsDuring, pins, "Reauthentication must retain current-account pins")
                    XCTAssertEqual(
                        playbackDuring, playbackBytes,
                        "Reauthentication must retain the playback session")
                    XCTAssertEqual(
                        downloadDuring, bytes, "Reauthentication must not remove a held download")
                    XCTAssertEqual(fixture.credentialWrites, initialWrites)
                    XCTAssertEqual(fixture.credentialDeletes, initialDeletes)
                    if cancelAuthentication { authentication.cancel() }
                    authGate.release()
                    try await self.waitForTask(authentication, label: "reauthentication completion")
                    if cancelAuthentication {
                        XCTAssertTrue(authenticationFailure is CancellationError)
                    } else {
                        XCTAssertEqual(
                            (authenticationFailure as? URLError)?.code, .userAuthenticationRequired)
                    }
                    let pinsAfter = fixture.defaults.data(forKey: pinKey)
                    let playbackAfter = try? Data(contentsOf: playbackStore.file)
                    let downloadAfter = try? Data(contentsOf: downloadFile)
                    XCTAssertEqual(pinsAfter, pins)
                    XCTAssertEqual(playbackAfter, playbackBytes)
                    XCTAssertEqual(downloadAfter, bytes)
                    XCTAssertEqual(fixture.credentialWrites, initialWrites)
                    XCTAssertEqual(fixture.credentialDeletes, initialDeletes)
                    XCTAssertTrue(model.player === player)
                    XCTAssertTrue(model.actions === actions)
                    guard pinsDuring == pins, playbackDuring == playbackBytes,
                        downloadDuring == bytes,
                        pinsAfter == pins, playbackAfter == playbackBytes, downloadAfter == bytes
                    else {
                        throw CancellationError()  // Keep the disposable fixture for investigation.
                    }
                }
            }
        #endif

        func testColdAllocatedRetirementWaitsForDeliveryAndCurrentOwner() async throws {
            for outcome in 0..<5 {
                try await withLifecycleFixture { fixture, _ in
                    let directory = fixture.storage.downloads.appendingPathComponent(
                        String(repeating: "a", count: 64), isDirectory: true)
                    try FoundationDownloadStorage.prepare(directory)
                    let identifier =
                        "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                        + "." + UUID().uuidString
                    let store = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    let package = fixture.root.appendingPathComponent(
                        "synthetic.movpkg", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: package, withIntermediateDirectories: true)
                    let sentinel = package.appendingPathComponent("synthetic")
                    try Data("preserve".utf8).write(to: sentinel)
                    var receipt = FoundationNativeAllocationStore.Receipt(
                        scope: directory.lastPathComponent, sessionIdentifier: identifier,
                        taskIdentifier: 1)
                    receipt.phase = .allocated
                    receipt.creationVersion = 1
                    receipt.nativeURL = package
                    receipt.namespaceBookmark = Data("synthetic".utf8)
                    try JSONEncoder().encode(receipt).write(to: store.receiptURL)
                    let registration = XCTestExpectation(
                        description: "cold retirement waiter registered")
                    let deliveryEntered = self.expectation(
                        description: "cold finality barrier entered")
                    let finalityRegistered = XCTestExpectation(
                        description: "cold finality waiter registered")
                    let gate = LifecycleGate(entered: deliveryEntered)
                    let permission = NativeRetirementPermission()
                    let actions = IsolatedDiagnosticRecorder()
                    let delegate = FoundationNativeDownloadDelegate(
                        progress: { _, _ in }, store: store, backgroundEventsFinished: { _ in },
                        deferLiveRetirementUntilFinality: true,
                        acknowledgedFinality: { _ in
                            await permission.recordDelivery()
                            await gate.hold()
                        },
                        retireAllocation: {
                            actions.append("retire")
                            try store.retire(
                                resolve: { _ in .available(package) },
                                remove: { url in
                                    try FileManager.default.removeItem(at: url)
                                })
                        })
                    let session = URLSession(configuration: .ephemeral)
                    defer {
                        gate.release()
                        delegate.activateDelegateQueue()

                        session.invalidateAndCancel()
                    }
                    delegate.isolatedRetirementWaitStarted = { registration.fulfill() }
                    delegate.isolatedFinalityWaitStarted = { finalityRegistered.fulfill() }
                    if outcome == 4 {
                        delegate.urlSession(session, didBecomeInvalidWithError: nil)
                        try await self.waitForEvents(
                            [deliveryEntered], label: "early cold delivery")
                    }
                    var failure: Error?
                    let retirement = Task {
                        do {
                            try await delegate.retire(session, mayRetire: { permission.allowed })
                        } catch { failure = error }
                    }
                    fixture.tasks.append(retirement)
                    if outcome == 4 {
                        try await self.waitForEvents(
                            [finalityRegistered], label: "early cold finality waiter")
                    } else {
                        try await self.waitForEvents(
                            [registration], label: "cold retirement registration")
                        let invalidationError: Error? = outcome == 3 ? URLError(.unknown) : nil
                        delegate.urlSession(session, didBecomeInvalidWithError: invalidationError)
                        try await self.waitForEvents(
                            [deliveryEntered], label: "held cold model delivery")
                    }
                    XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
                    XCTAssertNil(try store.load().retired)
                    XCTAssertTrue(actions.snapshot().isEmpty)
                    if outcome == 1 { retirement.cancel() }
                    if outcome == 2 { permission.allowed = false }
                    gate.release()
                    try await self.waitForTask(retirement, label: "cold finality and retirement")
                    XCTAssertEqual(permission.deliveries, 1)
                    if outcome == 0 || outcome == 4 {
                        XCTAssertNil(failure)
                        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
                        XCTAssertTrue(try store.load().hasProvenRetirement)
                        XCTAssertEqual(actions.snapshot(), ["retire"])
                        guard failure == nil, !FileManager.default.fileExists(atPath: package.path),
                            try store.load().hasProvenRetirement, actions.snapshot() == ["retire"]
                        else { throw CancellationError() }
                    } else {
                        XCTAssertNotNil(failure)
                        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
                        XCTAssertNil(try store.load().retired)
                        XCTAssertTrue(actions.snapshot().isEmpty)
                        guard failure != nil,
                            try Data(contentsOf: sentinel) == Data("preserve".utf8),
                            try store.load().retired == nil, actions.snapshot().isEmpty
                        else { throw CancellationError() }
                        permission.allowed = true
                        var retryFailure: Error?
                        let retry = Task {
                            do {
                                try await delegate.retire(
                                    session, mayRetire: { permission.allowed })
                            } catch { retryFailure = error }
                        }
                        fixture.tasks.append(retry)
                        try await self.waitForTask(retry, label: "cold retirement retry")
                        if outcome == 3 {
                            XCTAssertNotNil(retryFailure)
                            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
                            XCTAssertTrue(actions.snapshot().isEmpty)
                            guard retryFailure != nil,
                                FileManager.default.fileExists(atPath: sentinel.path),
                                actions.snapshot().isEmpty
                            else { throw CancellationError() }
                        } else {
                            XCTAssertNil(retryFailure)
                            XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
                            XCTAssertTrue(try store.load().hasProvenRetirement)
                            XCTAssertEqual(actions.snapshot(), ["retire"])
                            guard retryFailure == nil,
                                !FileManager.default.fileExists(atPath: package.path),
                                try store.load().hasProvenRetirement,
                                actions.snapshot() == ["retire"]
                            else { throw CancellationError() }
                        }
                        XCTAssertEqual(permission.deliveries, 1)
                    }
                }
            }
        }

        func testNativeTaskReportsNetworkFailureSeparatelyFromCancellation() async throws {
            for cancelled in [false, true] {
                try await withLifecycleFixture { fixture, _ in
                    let directory = fixture.storage.downloads.appendingPathComponent(
                        String(repeating: "a", count: 64), isDirectory: true)
                    try FoundationDownloadStorage.prepare(directory)
                    let identifier =
                        "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                        + "." + UUID().uuidString
                    let store = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    try store.reserve()
                    try store.beginCreating()
                    let session = URLSession(configuration: .ephemeral)
                    defer { session.invalidateAndCancel() }
                    let delegate = FoundationNativeDownloadDelegate(
                        progress: { _, _ in }, store: store, backgroundEventsFinished: { _ in },
                        deferLiveRetirementUntilFinality: true, acknowledgedDelivery: { _ in })
                    defer { delegate.activateDelegateQueue() }
                    let task = try delegate.makeTask(session: session) {
                        let task = session.dataTask(with: URL(string: "https://synthetic.invalid")!)
                        task.cancel()
                        return task
                    }
                    delegate.urlSession(
                        session, task: task,
                        didCompleteWithError: URLError(cancelled ? .cancelled : .timedOut))
                    let expected: FoundationDownloadError = cancelled ? .cancelled : .network
                    XCTAssertEqual(delegate.isolatedTerminalFailure, expected)
                    XCTAssertEqual(try store.load().phase, .terminalNoAllocation)
                    XCTAssertNil(try store.load().retired)
                    guard delegate.isolatedTerminalFailure == expected,
                        try store.load().phase == .terminalNoAllocation,
                        try store.load().retired == nil
                    else { throw CancellationError() }
                    _ = fixture
                }
            }
        }

        func testNativeInvalidationDoesNotSignalBackgroundEventDrain() async throws {
            for failed in [false, true] {
                try await withLifecycleFixture(
                    backgroundReconcile: { _ in true }, useModelBackgroundRouting: true,
                    {
                        fixture, model in
                        let directory = fixture.storage.downloads.appendingPathComponent(
                            String(repeating: "a", count: 64), isDirectory: true)
                        try FoundationDownloadStorage.prepare(directory)
                        let identifier =
                            "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                            + "." + UUID().uuidString
                        let store = FoundationNativeAllocationStore(
                            directory: directory, sessionIdentifier: identifier)
                        let drains = IsolatedDiagnosticRecorder()
                        let session = URLSession(configuration: .ephemeral)
                        defer { session.invalidateAndCancel() }
                        let delegate = FoundationNativeDownloadDelegate(
                            progress: { _, _ in }, store: store, backgroundEventsFinished: { _ in },
                            acknowledgedDelivery: { id in
                                drains.append("drain")
                                await MainActor.run { model.finishBackgroundDownloadEvents(id) }
                            })
                        let routed = self.expectation(description: "background event reconciled")
                        model.backgroundRoutingSettled = { _ in routed.fulfill() }
                        defer { model.backgroundRoutingSettled = nil }
                        let completed = XCTestExpectation(
                            description: "actual drain completed event")
                        var completions = 0
                        model.receiveBackgroundDownloadEvents(identifier) {
                            completions += 1
                            completed.fulfill()
                        }
                        try await self.waitForEvents(
                            [routed], label: "synthetic event reconciliation")
                        model.backgroundRoutingSettled = nil
                        delegate.urlSession(
                            session, didBecomeInvalidWithError: failed ? URLError(.unknown) : nil)
                        var finality: Bool?
                        let waiter = Task {
                            finality = await delegate.finishAndAwaitFinality(session)
                        }
                        fixture.tasks.append(waiter)
                        try await self.waitForTask(waiter, label: "invalidation-only finality")
                        XCTAssertEqual(finality, !failed)
                        XCTAssertTrue(drains.snapshot().isEmpty)
                        XCTAssertEqual(completions, 0)
                        guard finality == !failed, drains.snapshot().isEmpty, completions == 0
                        else { throw CancellationError() }
                        // Supply the actual event-drain signal after verifying invalidation alone
                        // did not consume the stored completion.
                        model.finishBackgroundDownloadEvents(identifier)
                        try await self.waitForEvents([completed], label: "actual event drain")
                        XCTAssertEqual(completions, 1)
                    })
            }
        }

        func testNativeBackgroundDrainAndReconciliationCompleteOnlyOnce() async throws {
            try await withLifecycleFixture(
                backgroundReconcile: { _ in true }, useModelBackgroundRouting: true,
                {
                    fixture, model in
                    let directory = fixture.storage.downloads.appendingPathComponent(
                        String(repeating: "a", count: 64), isDirectory: true)
                    try FoundationDownloadStorage.prepare(directory)
                    let identifier =
                        "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                        + "." + UUID().uuidString
                    let store = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier)
                    let session = URLSession(configuration: .ephemeral)
                    defer { session.invalidateAndCancel() }
                    let delegate = FoundationNativeDownloadDelegate(
                        progress: { _, _ in }, store: store, backgroundEventsFinished: { _ in },
                        acknowledgedDelivery: { id in
                            await MainActor.run { model.finishBackgroundDownloadEvents(id) }
                        })
                    let routed = self.expectation(description: "background route reconciled")
                    model.backgroundRoutingSettled = { _ in routed.fulfill() }
                    defer { model.backgroundRoutingSettled = nil }
                    let completed = self.expectation(
                        description: "actual native event drain completed")
                    var completions = 0
                    model.receiveBackgroundDownloadEvents(identifier) {
                        completions += 1
                        completed.fulfill()
                    }
                    try await self.waitForEvents([routed], label: "background event reconciliation")
                    model.backgroundRoutingSettled = nil
                    XCTAssertEqual(completions, 0)
                    delegate.urlSessionDidFinishEvents(forBackgroundURLSession: session)
                    try await self.waitForEvents([completed], label: "native event drain")
                    delegate.urlSessionDidFinishEvents(forBackgroundURLSession: session)
                    delegate.urlSession(session, didBecomeInvalidWithError: nil)
                    var finality: Bool?
                    let waiter = Task { finality = await delegate.finishAndAwaitFinality(session) }
                    fixture.tasks.append(waiter)
                    try await self.waitForTask(waiter, label: "native finality after drain")
                    XCTAssertEqual(finality, true)
                    XCTAssertEqual(completions, 1)
                    guard finality == true, completions == 1 else { throw CancellationError() }
                })
        }

        func testNativeFinalityWaitsForOrderedModelDeliveryAndCachesFailure() async throws {
            try await withLifecycleFixture { fixture, _ in
                let directory = fixture.storage.downloads.appendingPathComponent(
                    String(repeating: "a", count: 64), isDirectory: true)
                try FoundationDownloadStorage.prepare(directory)
                let identifier =
                    "dev.novoluxor.velacanto.offline." + directory.lastPathComponent
                    + "." + UUID().uuidString
                let store = FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: identifier)
                let entered = self.expectation(description: "first native delivery entered")
                let gate = LifecycleGate(entered: entered)
                let delegate = FoundationNativeDownloadDelegate(
                    progress: { _, _ in }, store: store, backgroundEventsFinished: { _ in },
                    acknowledgedDelivery: { _ in await gate.hold() })
                let session = URLSession(configuration: .ephemeral)
                defer {
                    gate.release()
                    session.invalidateAndCancel()
                }
                delegate.urlSessionDidFinishEvents(forBackgroundURLSession: session)
                try await self.waitForEvents([entered], label: "first native delivery")
                delegate.urlSession(session, didBecomeInvalidWithError: nil)
                let registered = self.expectation(description: "native finality waiter registered")
                delegate.isolatedFinalityWaitStarted = { registered.fulfill() }
                var completed = false
                var result: Bool?
                let waiter = Task {
                    result = await delegate.finishAndAwaitFinality(session)
                    completed = true
                }
                fixture.tasks.append(waiter)
                try await self.waitForEvents([registered], label: "native finality waiter")
                XCTAssertFalse(completed, "Finality cannot precede acknowledged delivery")
                gate.release()
                try await self.waitForTask(waiter, label: "native finality")
                XCTAssertEqual(result, true)
                delegate.urlSession(session, didBecomeInvalidWithError: URLError(.unknown))
                let repeated = Task { result = await delegate.finishAndAwaitFinality(session) }
                fixture.tasks.append(repeated)
                try await self.waitForTask(repeated, label: "cached native finality")
                XCTAssertEqual(result, true)
                XCTAssertFalse(FileManager.default.fileExists(atPath: store.receiptURL.path))

                let failed = FoundationNativeDownloadDelegate(
                    progress: { _, _ in }, store: store, backgroundEventsFinished: { _ in },
                    acknowledgedDelivery: { _ in })
                let failedSession = URLSession(configuration: .ephemeral)
                defer { failedSession.invalidateAndCancel() }
                failed.urlSession(failedSession, didBecomeInvalidWithError: URLError(.unknown))
                var failureResult: Bool?
                let failedWaiter = Task {
                    failureResult = await failed.finishAndAwaitFinality(failedSession)
                }
                fixture.tasks.append(failedWaiter)
                failedWaiter.cancel()
                try await self.waitForTask(failedWaiter, label: "failed native finality")
                XCTAssertEqual(failureResult, false)
                XCTAssertFalse(FileManager.default.fileExists(atPath: store.receiptURL.path))

                let liveIdentifier =
                    "dev.novoluxor.velacanto.offline."
                    + directory.lastPathComponent + "." + UUID().uuidString
                let liveStore = FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: liveIdentifier)
                try liveStore.reserve()
                try liveStore.beginCreating()
                let live = FoundationNativeDownloadDelegate(
                    progress: { _, _ in }, store: liveStore, backgroundEventsFinished: { _ in },
                    deferLiveRetirementUntilFinality: true, acknowledgedDelivery: { _ in })
                let liveSession = URLSession(configuration: .ephemeral)
                defer {
                    live.activateDelegateQueue()
                    liveSession.invalidateAndCancel()
                }
                let nativeTask = try live.makeTask(session: liveSession) {
                    let task = liveSession.dataTask(with: URL(string: "https://synthetic.invalid")!)
                    task.cancel()
                    return task
                }
                live.urlSession(
                    liveSession, task: nativeTask, didCompleteWithError: URLError(.cancelled))
                XCTAssertEqual(try liveStore.load().phase, .terminalNoAllocation)
                XCTAssertNil(try liveStore.load().retired)
                live.urlSession(liveSession, didBecomeInvalidWithError: nil)
                var liveFinality: Bool?
                let liveWaiter = Task {
                    liveFinality = await live.finishAndAwaitFinality(liveSession)
                }
                fixture.tasks.append(liveWaiter)
                try await self.waitForTask(liveWaiter, label: "live native finality")
                XCTAssertEqual(liveFinality, true)
                XCTAssertNil(try liveStore.load().retired)
                try liveStore.retire()
                XCTAssertEqual(try liveStore.load().retired, true)
            }
        }

        func testUnreadableCredentialsPreserveStoresAndBlockAuthentication() async throws {
            for quarantined in [false, true] {
                #if !os(macOS)
                    if quarantined { continue }
                #endif
                for corrupt in [false, true] {
                    try await withLifecycleFixture { fixture, model in
                        #if os(macOS)
                            if quarantined {
                                fixture.defaults.removeObject(
                                    forKey: FoundationAppModel.credentialBackendKey)
                            }
                        #endif
                        let pinKey = FoundationPinStorage.key(for: "synthetic-scope")
                        let bytes = Data("retained synthetic account data".utf8)
                        fixture.defaults.set(bytes, forKey: pinKey)
                        let roots = [
                            fixture.storage.playback, fixture.storage.selections,
                            fixture.storage.downloads, fixture.storage.artwork,
                            fixture.storage.pages,
                        ]
                        for root in roots {
                            try FileManager.default.createDirectory(
                                at: root, withIntermediateDirectories: true)
                            try bytes.write(to: root.appendingPathComponent("sentinel"))
                        }
                        fixture.copyStatus = corrupt ? errSecSuccess : errSecInteractionNotAllowed
                        fixture.copiedCredential = corrupt ? Data("invalid credential".utf8) : nil
                        model.restoreCredentials()
                        XCTAssertNotNil(model.credentialError)
                        var authenticated = false
                        var failure: Error?
                        let attempt = Task {
                            do {
                                _ = try await model.prepareSignIn {
                                    authenticated = true
                                    return fixture.session(user: "00000000000000000000000000000001")
                                }
                            } catch { failure = error }
                        }
                        fixture.tasks.append(attempt)
                        try await self.waitForTask(
                            attempt, label: "unreadable credential admission")
                        XCTAssertFalse(authenticated)
                        XCTAssertTrue(failure is FoundationCredentialReadError)
                        XCTAssertEqual(fixture.defaults.data(forKey: pinKey), bytes)
                        let preserved = roots.allSatisfy {
                            (try? Data(contentsOf: $0.appendingPathComponent("sentinel"))) == bytes
                        }
                        XCTAssertTrue(preserved)
                        guard !authenticated, failure is FoundationCredentialReadError,
                            fixture.defaults.data(forKey: pinKey) == bytes, preserved
                        else { throw CancellationError() }
                    }
                }
            }
        }

        func testCredentialReadRetryAllowsConfirmedAbsentOrValidCredential() async throws {
            for quarantined in [false, true] {
                #if !os(macOS)
                    if quarantined { continue }
                #endif
                for valid in [false, true] {
                    try await withLifecycleFixture { fixture, model in
                        #if os(macOS)
                            if quarantined {
                                fixture.defaults.removeObject(
                                    forKey: FoundationAppModel.credentialBackendKey)
                            }
                        #endif
                        let session = fixture.session(user: "00000000000000000000000000000001")
                        fixture.copyStatus = errSecInteractionNotAllowed
                        model.restoreCredentials()
                        XCTAssertNotNil(model.credentialError)
                        fixture.copyStatus = valid ? errSecSuccess : errSecItemNotFound
                        if valid {
                            fixture.copiedCredential = try JSONEncoder().encode(session)
                        } else {
                            fixture.copiedCredential = nil
                        }
                        var authenticated = false
                        var failure: Error?
                        let attempt = Task {
                            do {
                                _ = try await model.prepareSignIn {
                                    authenticated = true
                                    return session
                                }
                            } catch { failure = error }
                        }
                        fixture.tasks.append(attempt)
                        try await self.waitForTask(attempt, label: "credential read retry")
                        XCTAssertNil(failure)
                        XCTAssertTrue(authenticated)
                        if valid { XCTAssertNotNil(model.library) }
                        XCTAssertNil(model.credentialError)
                    }
                }
            }
        }

        func testCleanupAlertDismissalPreservesIdenticalNewPublication() async throws {
            try await withLifecycleFixture { _, model in
                model.isolatedUpdateDownloadCleanupFailure(failed: true)
                let first = try XCTUnwrap(model.signOutCleanupError)
                model.dismissAccountAlertAfterUpdate()
                model.isolatedUpdateDownloadCleanupFailure(failed: true)
                let dismissed = self.expectation(description: "queued dismissal processed")
                DispatchQueue.main.async { dismissed.fulfill() }
                try await self.waitForEvents([dismissed], label: "queued dismissal")
                XCTAssertEqual(model.signOutCleanupError, first)
            }
        }

        func testSignOutReportsMultipleFailuresAcrossDownloadRetry() async throws {
            try await withLifecycleFixture { fixture, model in
                let session = fixture.session(user: "00000000000000000000000000000001")
                try await fixture.open(model, user: session.userID)
                let player = try XCTUnwrap(model.player)
                let scope = try XCTUnwrap(model.library).catalogAccountIdentity
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(directory)
                let receipt = directory.appendingPathComponent("native-receipt-synthetic")
                try Data("synthetic receipt".utf8).write(to: receipt)
                try FileManager.default.createDirectory(
                    at: fixture.storage.selections, withIntermediateDirectories: true)
                let invalidSelection = fixture.storage.selections.appendingPathComponent(scope)
                try Data("synthetic selection".utf8).write(to: invalidSelection)
                let completed = self.expectation(description: "failed sign-out cleanup completed")
                let observation = model.$isCleaningDownloads.dropFirst().filter { !$0 }.first()
                    .sink { _ in completed.fulfill() }
                defer { observation.cancel() }
                model.signOut()
                fixture.captureStop(player)
                try await self.waitForEvents([fixture.entered, completed], label: "failed cleanup")
                XCTAssertTrue(
                    model.credentialError?.contains("Downloaded music could not be removed") == true
                )
                XCTAssertTrue(
                    model.credentialError?.contains("music-library selections could not be removed")
                        == true)
                let dismissed = self.expectation(description: "cleanup alert dismissed")
                model.dismissAccountAlertAfterUpdate()
                DispatchQueue.main.async { dismissed.fulfill() }
                try await self.waitForEvents([dismissed], label: "cleanup alert dismissal")
                XCTAssertNil(model.signOutCleanupError)
                let failedRetry = self.expectation(description: "failed download retry completed")
                let failedRetryObservation = model.$isCleaningDownloads.dropFirst().filter { !$0 }
                    .first()
                    .sink { _ in failedRetry.fulfill() }
                defer { failedRetryObservation.cancel() }
                let failedAttempt = Task { _ = try? await model.prepareSignIn { session } }
                fixture.tasks.append(failedAttempt)
                try await self.waitForTask(failedAttempt, label: "failed cleanup retry admission")
                try await self.waitForEvents([failedRetry], label: "failed cleanup retry")
                XCTAssertTrue(
                    model.signOutCleanupError?.contains("Downloaded music could not be removed")
                        == true)
                XCTAssertTrue(
                    model.signOutCleanupError?.contains(
                        "music-library selections could not be removed") == true)
                try FileManager.default.removeItem(at: receipt)
                let retried = self.expectation(description: "download cleanup retry completed")
                let retryObservation = model.$isCleaningDownloads.dropFirst().filter { !$0 }.first()
                    .sink { _ in retried.fulfill() }
                defer { retryObservation.cancel() }
                var pending: Error?
                let attempt = Task {
                    do { _ = try await model.prepareSignIn { session } } catch { pending = error }
                }
                fixture.tasks.append(attempt)
                try await self.waitForTask(attempt, label: "cleanup retry admission")
                guard let pending = pending as? FoundationDownloadAccountError,
                    case .cleanupPending = pending
                else { throw CancellationError() }
                try await self.waitForEvents([retried], label: "download cleanup retry")
                XCTAssertFalse(
                    model.signOutCleanupError?.contains("Downloaded music could not be removed")
                        == true)
                XCTAssertTrue(
                    model.signOutCleanupError?.contains(
                        "music-library selections could not be removed") == true)
                XCTAssertTrue(FileManager.default.fileExists(atPath: invalidSelection.path))
                let failedSelectionFinished = self.expectation(
                    description: "failed selection retry finished")
                let failedSelectionObservation = model.$isCleaningDownloads.dropFirst().filter {
                    !$0
                }.first()
                    .sink { _ in failedSelectionFinished.fulfill() }
                defer { failedSelectionObservation.cancel() }
                var rejectedAuthentication = false
                var rejectedError: Error?
                let blockedAttempt = Task {
                    do {
                        _ = try await model.prepareSignIn {
                            rejectedAuthentication = true
                            return session
                        }
                    } catch { rejectedError = error }
                }
                fixture.tasks.append(blockedAttempt)
                try await self.waitForTask(blockedAttempt, label: "selection cleanup admission")
                XCTAssertFalse(rejectedAuthentication)
                guard let rejectedError = rejectedError as? FoundationDownloadAccountError,
                    case .cleanupPending = rejectedError
                else { throw CancellationError() }
                try await self.waitForEvents(
                    [failedSelectionFinished], label: "failed selection retry")
                try FileManager.default.removeItem(at: invalidSelection)
                let resolved = self.expectation(description: "all cleanup components resolved")
                let resolvedObservation = model.$isCleaningDownloads.dropFirst().filter { !$0 }
                    .first()
                    .sink { _ in resolved.fulfill() }
                defer { resolvedObservation.cancel() }
                let finalAttempt = Task { _ = try? await model.prepareSignIn { session } }
                fixture.tasks.append(finalAttempt)
                try await self.waitForTask(finalAttempt, label: "selection cleanup retry admission")
                try await self.waitForEvents([resolved], label: "all cleanup components")
                XCTAssertNil(model.signOutCleanupError)
                fixture.gate.release()
                try await fixture.drain(using: self)
                XCTAssertTrue(model.signOutNotice?.contains("Downloads removed.") == true)
                XCTAssertTrue(model.signOutNotice?.contains("Server sign-out unconfirmed.") == true)
            }
        }

        func testScopedRemovalRejectsSymlinksNativeAndBudgetBeforeDeleting() async throws {
            try await withLifecycleFixture { fixture, _ in
                let root = fixture.root.appendingPathComponent("scoped-removal", isDirectory: true)
                let first = String(repeating: "a", count: 64)
                let other = String(repeating: "b", count: 64)
                let directory = root.appendingPathComponent(first, isDirectory: true)
                let otherDirectory = root.appendingPathComponent(other, isDirectory: true)
                let nested = directory.appendingPathComponent("nested", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: nested, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(
                    at: otherDirectory, withIntermediateDirectories: true)
                let firstFile = nested.appendingPathComponent("track")
                let secondFile = directory.appendingPathComponent("manifest.json")
                let otherFile = otherDirectory.appendingPathComponent("sentinel")
                let bytes = Data("synthetic".utf8)
                try bytes.write(to: firstFile)
                try bytes.write(to: secondFile)
                try bytes.write(to: otherFile)
                XCTAssertFalse(
                    FoundationScopedAccountRemoval.remove(root: root, scope: first, entryLimit: 1))
                XCTAssertThrowsError(
                    try FoundationScopedAccountRemoval.inventory(
                        root: root, retained: first, limit: 1))
                XCTAssertEqual(try Data(contentsOf: firstFile), bytes)
                XCTAssertEqual(try Data(contentsOf: secondFile), bytes)
                let link = directory.appendingPathComponent("link")
                try FileManager.default.createSymbolicLink(
                    at: link, withDestinationURL: otherDirectory)
                XCTAssertFalse(FoundationScopedAccountRemoval.remove(root: root, scope: first))
                XCTAssertEqual(try Data(contentsOf: otherFile), bytes)
                try FileManager.default.removeItem(at: link)
                let receipt = directory.appendingPathComponent("native-receipt-synthetic")
                try bytes.write(to: receipt)
                XCTAssertFalse(FoundationScopedAccountRemoval.remove(root: root, scope: first))
                XCTAssertEqual(try Data(contentsOf: firstFile), bytes)
                XCTAssertEqual(try Data(contentsOf: receipt), bytes)
                try FileManager.default.removeItem(at: receipt)
                let stage = directory.appendingPathComponent("stage-native-synthetic")
                try bytes.write(to: stage)
                XCTAssertFalse(FoundationScopedAccountRemoval.remove(root: root, scope: first))
                XCTAssertEqual(try Data(contentsOf: stage), bytes)
                try FileManager.default.removeItem(at: stage)
                let package = directory.appendingPathComponent(
                    "synthetic.movpkg", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: package, withIntermediateDirectories: true)
                XCTAssertFalse(FoundationScopedAccountRemoval.remove(root: root, scope: first))
                XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
                try FileManager.default.removeItem(at: package)
                var cancelledResult: Bool?
                let cancelled = Task {
                    cancelledResult = await FoundationScopedAccountRemoval.removeAsync(
                        root: root, scope: first)
                }
                fixture.tasks.append(cancelled)
                cancelled.cancel()
                try await self.waitForTask(cancelled, label: "cancelled scoped removal")
                XCTAssertEqual(cancelledResult, false)
                XCTAssertEqual(try Data(contentsOf: firstFile), bytes)
                XCTAssertTrue(FoundationScopedAccountRemoval.remove(root: root, scope: first))
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
                XCTAssertEqual(try Data(contentsOf: otherFile), bytes)
                XCTAssertTrue(FoundationScopedAccountRemoval.remove(root: root, scope: first))
                let rootLink = fixture.root.appendingPathComponent("linked-root", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: root)
                XCTAssertFalse(FoundationScopedAccountRemoval.remove(root: rootLink, scope: other))
                XCTAssertThrowsError(
                    try FoundationScopedAccountRemoval.inventory(root: rootLink, retained: other))
                XCTAssertEqual(try Data(contentsOf: otherFile), bytes)
                let leafLink = root.appendingPathComponent(first)
                try FileManager.default.createSymbolicLink(
                    at: leafLink, withDestinationURL: otherDirectory)
                XCTAssertFalse(FoundationScopedAccountRemoval.remove(root: root, scope: first))
                XCTAssertThrowsError(
                    try FoundationScopedAccountRemoval.inventory(root: root, retained: first))
                XCTAssertEqual(try Data(contentsOf: otherFile), bytes)
                let nonDirectory = fixture.root.appendingPathComponent("not-a-directory")
                try bytes.write(to: nonDirectory)
                XCTAssertFalse(
                    FoundationScopedAccountRemoval.remove(root: nonDirectory, scope: first))
                XCTAssertThrowsError(
                    try FoundationScopedAccountRemoval.inventory(
                        root: nonDirectory, retained: first))
                XCTAssertEqual(try Data(contentsOf: nonDirectory), bytes)
            }
        }

        #if os(macOS)
            func testUpgradeWithMixedScopesRequiresConfirmationAndPreservesData() async throws {
                try await withLifecycleFixture { fixture, model in
                    let first = fixture.session(user: "00000000000000000000000000000001")
                    let second = fixture.session(user: "00000000000000000000000000000002")
                    func key(_ session: FoundationSession) -> String {
                        let scope = FoundationMusicLibraryStore.digest(
                            "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
                        return FoundationPinStorage.key(for: scope)
                    }
                    let firstKey = key(first)
                    let secondKey = key(second)
                    let bytes = Data("synthetic retained pins".utf8)
                    fixture.defaults.set(bytes, forKey: firstKey)
                    fixture.defaults.set(bytes, forKey: secondKey)
                    fixture.defaults.removeObject(forKey: FoundationAppModel.credentialBackendKey)
                    fixture.copyStatus = errSecSuccess
                    fixture.copiedCredential = try JSONEncoder().encode(first)
                    model.restoreCredentials()
                    XCTAssertNil(model.library)
                    XCTAssertNotNil(model.credentialError)
                    XCTAssertEqual(fixture.defaults.data(forKey: firstKey), bytes)
                    XCTAssertEqual(fixture.defaults.data(forKey: secondKey), bytes)
                    let writes = fixture.credentialWrites
                    var acceptance: FoundationSignInView.Acceptance?
                    var prepareError: Error?
                    let preparation = Task {
                        do { acceptance = try await model.prepareSignIn { first } } catch {
                            prepareError = error
                        }
                    }
                    fixture.tasks.append(preparation)
                    try await self.waitForTask(
                        preparation, label: "mixed-scope upgrade authentication")
                    if let prepareError { throw prepareError }
                    var result: Error?
                    let commit = Task {
                        do { try await XCTUnwrap(acceptance)() } catch { result = error }
                    }
                    fixture.tasks.append(commit)
                    try await self.waitForTask(commit, label: "mixed-scope upgrade acceptance")
                    guard let upgrade = result as? FoundationCredentialUpgradeError,
                        case .confirmationRequired = upgrade
                    else {
                        XCTFail("Mixed scopes must require explicit confirmation")
                        throw CancellationError()
                    }
                    XCTAssertNil(model.library)
                    XCTAssertEqual(fixture.credentialWrites, writes)
                    XCTAssertEqual(fixture.defaults.data(forKey: firstKey), bytes)
                    XCTAssertEqual(fixture.defaults.data(forKey: secondKey), bytes)
                    guard fixture.defaults.data(forKey: firstKey) == bytes,
                        fixture.defaults.data(forKey: secondKey) == bytes
                    else { throw CancellationError() }
                }
            }
        #endif

        func testFreshSignInPreservesOtherScopesBeforeAndAfterAuthentication() async throws {
            try await withLifecycleFixture { fixture, model in
                let old = fixture.session(user: "00000000000000000000000000000001")
                let next = fixture.session(user: "00000000000000000000000000000002")
                let scope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + old.serverURL.absoluteString + "\0" + old.userID)
                let cacheScope = FoundationArtworkCache.digest(scope)
                let pinKey = FoundationPinStorage.key(for: scope)
                let bytes = Data("unrelated synthetic account".utf8)
                fixture.defaults.set(bytes, forKey: pinKey)
                let directories = [
                    fixture.storage.playback.appendingPathComponent(scope),
                    fixture.storage.selections.appendingPathComponent(scope),
                    FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads),
                    fixture.storage.artwork.appendingPathComponent(cacheScope),
                    fixture.storage.pages.appendingPathComponent(cacheScope),
                ]
                for directory in directories {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    try bytes.write(to: directory.appendingPathComponent("sentinel"))
                }
                @MainActor func preserved() -> Bool {
                    fixture.defaults.data(forKey: pinKey) == bytes
                        && directories.allSatisfy {
                            (try? Data(contentsOf: $0.appendingPathComponent("sentinel"))) == bytes
                        }
                }
                model.restoreCredentials()
                XCTAssertTrue(preserved())
                var failure: Error?
                let failed = Task {
                    do {
                        _ = try await model.prepareSignIn {
                            throw URLError(.userAuthenticationRequired)
                        }
                    } catch { failure = error }
                }
                fixture.tasks.append(failed)
                try await self.waitForTask(failed, label: "failed fresh authentication")
                XCTAssertEqual((failure as? URLError)?.code, .userAuthenticationRequired)
                XCTAssertTrue(preserved())
                var acceptance: FoundationSignInView.Acceptance?
                var preparationError: Error?
                let preparation = Task {
                    do { acceptance = try await model.prepareSignIn { next } } catch {
                        preparationError = error
                    }
                }
                fixture.tasks.append(preparation)
                try await self.waitForTask(preparation, label: "fresh authentication")
                if let preparationError { throw preparationError }
                var commitError: Error?
                let commit = Task {
                    do { try await XCTUnwrap(acceptance)() } catch { commitError = error }
                }
                fixture.tasks.append(commit)
                try await self.waitForTask(commit, label: "fresh account acceptance")
                if let commitError { throw commitError }
                try await fixture.drain(using: self)
                XCTAssertNotEqual(model.library?.catalogAccountIdentity, scope)
                XCTAssertTrue(preserved())
                guard preserved() else { throw CancellationError() }
            }
        }

        func testSignOutCleanupPreservesOtherAccountScopes() async throws {
            try await withLifecycleFixture { fixture, model in
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let player = try XCTUnwrap(model.player)
                let other = fixture.session(user: "00000000000000000000000000000002")
                let scope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + other.serverURL.absoluteString + "\0" + other.userID)
                let pinKey = FoundationPinStorage.key(for: scope)
                let bytes = Data("other synthetic account".utf8)
                fixture.defaults.set(bytes, forKey: pinKey)
                let cacheScope = FoundationArtworkCache.digest(scope)
                let paths = [
                    fixture.storage.playback.appendingPathComponent(scope),
                    fixture.storage.selections.appendingPathComponent(scope),
                    FoundationDownloadStorage.directory(
                        scope: scope, root: fixture.storage.downloads),
                    fixture.storage.artwork.appendingPathComponent(cacheScope),
                    fixture.storage.pages.appendingPathComponent(cacheScope),
                ]
                for directory in paths {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    try bytes.write(to: directory.appendingPathComponent("sentinel"))
                }
                let finished = self.expectation(description: "scoped sign-out completed")
                let observation = model.$isCleaningDownloads.dropFirst().filter { !$0 }.first()
                    .sink { _ in finished.fulfill() }
                defer { observation.cancel() }
                model.signOut()
                fixture.captureStop(player)
                try await self.waitForEvents([finished], label: "scoped sign-out cleanup")
                let preserved = paths.allSatisfy {
                    (try? Data(contentsOf: $0.appendingPathComponent("sentinel"))) == bytes
                }
                XCTAssertTrue(preserved)
                XCTAssertEqual(fixture.defaults.data(forKey: pinKey), bytes)
                guard preserved, fixture.defaults.data(forKey: pinKey) == bytes else {
                    throw CancellationError()
                }
            }
        }

        func testSuccessfulDownloadRetryUpdatesEarlierServerNotice() async throws {
            try await withLifecycleFixture { fixture, model in
                let session = fixture.session(user: "00000000000000000000000000000001")
                try await fixture.open(model, user: session.userID)
                let player = try XCTUnwrap(model.player)
                let scope = try XCTUnwrap(model.library).catalogAccountIdentity
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                try FoundationDownloadStorage.prepare(directory)
                let receipt = directory.appendingPathComponent("native-receipt-synthetic")
                try Data("synthetic receipt".utf8).write(to: receipt)
                let completed = self.expectation(description: "failed sign-out cleanup completed")
                let observation = model.$isCleaningDownloads.dropFirst().filter { !$0 }.first()
                    .sink { _ in completed.fulfill() }
                defer { observation.cancel() }
                model.signOut()
                fixture.captureStop(player)
                try await self.waitForEvents([fixture.entered, completed], label: "failed cleanup")
                fixture.gate.release()
                try await fixture.drain(using: self)
                XCTAssertTrue(
                    model.signOutNotice?.contains("Downloads couldn’t be removed.") == true)
                XCTAssertTrue(model.signOutNotice?.contains("Server sign-out unconfirmed.") == true)
                try FileManager.default.removeItem(at: receipt)
                let retried = self.expectation(description: "download cleanup retry completed")
                let retryObservation = model.$isCleaningDownloads.dropFirst().filter { !$0 }.first()
                    .sink { _ in retried.fulfill() }
                defer { retryObservation.cancel() }
                let attempt = Task { _ = try? await model.prepareSignIn { session } }
                fixture.tasks.append(attempt)
                try await self.waitForTask(attempt, label: "cleanup retry admission")
                try await self.waitForEvents([retried], label: "download cleanup retry")
                XCTAssertTrue(model.signOutNotice?.contains("Downloads removed.") == true)
                XCTAssertTrue(model.signOutNotice?.contains("Server sign-out unconfirmed.") == true)
                XCTAssertNil(model.signOutCleanupError)
            }
        }

        func testDifferentAccountRequiresSignOutAndPreservesCurrentAccountData() async throws {
            try await withLifecycleFixture { fixture, model in
                let oldSession = fixture.session(user: "00000000000000000000000000000001")
                let newSession = fixture.session(user: "00000000000000000000000000000002")
                try await fixture.open(model, user: oldSession.userID)
                let owner = try XCTUnwrap(model.downloads)
                let player = try XCTUnwrap(model.player)
                let scope = try XCTUnwrap(model.library).catalogAccountIdentity
                let actions = try XCTUnwrap(model.actions)
                actions.togglePin(fixture.album)
                let pinKey = FoundationPinStorage.key(for: scope)
                let pins = try XCTUnwrap(fixture.defaults.data(forKey: pinKey))
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: fixture.storage.downloads)
                let file = directory.appendingPathComponent("synthetic-preservation")
                let bytes = Data("synthetic-old-account".utf8)
                try bytes.write(to: file)
                var prepared: FoundationSignInView.Acceptance?
                var preparationError: Error?
                let preparation = Task {
                    do { prepared = try await model.prepareSignIn { newSession } } catch {
                        preparationError = error
                    }
                }
                fixture.tasks.append(preparation)
                try await self.waitForTask(preparation, label: "replacement preparation")
                if let preparationError { throw preparationError }
                let accept = try XCTUnwrap(prepared)
                var failure: Error?
                let commit = Task {
                    do { try await accept() } catch { failure = error }
                }
                fixture.tasks.append(commit)
                try await self.waitForTask(commit, label: "different-account acceptance")
                guard let downloadError = failure as? FoundationDownloadAccountError,
                    case .signOutRequired = downloadError
                else {
                    XCTFail("Expected an explicit sign-out requirement; retained fixture")
                    throw CancellationError()
                }
                XCTAssertEqual(
                    downloadError.errorDescription,
                    "This is a different account. Sign out of your current account and wait for local cleanup to finish before signing in again."
                )
                XCTAssertTrue(model.downloads === owner)
                XCTAssertTrue(model.player === player)
                XCTAssertEqual(model.library?.catalogAccountIdentity, scope)
                XCTAssertEqual(fixture.defaults.data(forKey: pinKey), pins)
                XCTAssertEqual(try? Data(contentsOf: file), bytes)
                guard model.downloads === owner, model.player === player,
                    model.library?.catalogAccountIdentity == scope,
                    fixture.defaults.data(forKey: pinKey) == pins,
                    (try? Data(contentsOf: file)) == bytes
                else { throw CancellationError() }
            }
        }

        func testDifferentAccountWaitsForSignOutAndHeldLeaseCleanup() async throws {
            let leaseWait = expectation(description: "sign-out waits for held lease")
            try await withLifecycleFixture(
                leaseWaitStarted: { leaseWait.fulfill() },
                {
                    fixture, model in
                    let sessionA = fixture.session(user: "00000000000000000000000000000001")
                    let acceptA = try await model.prepareSignIn { sessionA }
                    let scopeA = FoundationMusicLibraryStore.digest(
                        "jellyfin\0" + sessionA.serverURL.absoluteString + "\0" + sessionA.userID)
                    let track = FoundationItem(
                        id: "00000000000000000000000000000003", title: "Synthetic",
                        subtitle: "", kind: .track, duration: nil)
                    let directory = FoundationDownloadStorage.directory(
                        scope: scopeA, root: fixture.storage.downloads)
                    try FoundationDownloadStorage.prepare(directory)
                    let file = directory.appendingPathComponent("synthetic.audio")
                    let bytes = Data("synthetic-test-bytes".utf8)
                    try bytes.write(to: file)
                    let stored = FoundationStoredDownloadItem(track)
                    var manifest = FoundationDownloadManifest()
                    manifest.owners = [
                        .init(
                            id: "track:" + track.id, item: stored, tracks: [stored],
                            paused: false, expanded: false)
                    ]
                    manifest.files[track.id] = .init(
                        name: file.lastPathComponent, bytes: Int64(bytes.count),
                        digest: try FoundationDownloadStorage.digest(file))
                    try FoundationDownloadStorage.save(manifest, directory: directory)
                    try await acceptA()
                    let oldPlayer = try XCTUnwrap(model.player)
                    let oldDownloads = try XCTUnwrap(model.downloads)
                    let inventory = self.expectation(description: "old account inventory verified")
                    let observation = oldDownloads.$isLoading.filter { !$0 }.first().sink { _ in
                        inventory.fulfill()
                    }
                    defer { observation.cancel() }
                    try await self.waitForEvents([inventory], label: "old account inventory")
                    XCTAssertTrue(oldDownloads.isReady(track))
                    try await fixture.acquireResource(from: oldDownloads, item: track, using: self)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

                    let sessionB = fixture.session(user: "00000000000000000000000000000002")
                    let authentication = self.expectation(
                        description: "replacement authentication entered")
                    var filePresentAtAuthentication: Bool?
                    var acceptB: FoundationSignInView.Acceptance?
                    var preparationFailure: Error?
                    let preparation = Task {
                        do {
                            acceptB = try await model.prepareSignIn {
                                filePresentAtAuthentication = FileManager.default.fileExists(
                                    atPath: file.path)
                                authentication.fulfill()
                                return sessionB
                            }
                        } catch { preparationFailure = error }
                    }
                    fixture.tasks.append(preparation)
                    try await self.waitForTask(preparation, label: "replacement preparation")
                    if let preparationFailure { throw preparationFailure }
                    try await self.waitForEvents(
                        [authentication], label: "replacement authentication")
                    guard filePresentAtAuthentication == true else {
                        XCTFail(
                            "Pre-auth cleanup removed an active playback lease; retained fixture for review"
                        )
                        throw CancellationError()
                    }
                    var mismatch: Error?
                    let acceptance = Task {
                        do { try await XCTUnwrap(acceptB)() } catch { mismatch = error }
                    }
                    fixture.tasks.append(acceptance)
                    try await self.waitForTask(acceptance, label: "different-account acceptance")
                    guard let mismatch = mismatch as? FoundationDownloadAccountError,
                        case .signOutRequired = mismatch
                    else {
                        XCTFail(
                            "Different-account recovery must require sign-out; retained fixture")
                        throw CancellationError()
                    }
                    XCTAssertTrue(model.player === oldPlayer)
                    XCTAssertTrue(model.downloads === oldDownloads)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

                    let localCleanup = self.expectation(
                        description: "local sign-out cleanup completed")
                    let cleanupObservation = model.$isCleaningDownloads.dropFirst().filter { !$0 }
                        .first()
                        .sink { _ in localCleanup.fulfill() }
                    defer { cleanupObservation.cancel() }
                    model.signOut()
                    fixture.captureStop(oldPlayer)
                    try await self.waitForEvents(
                        [leaseWait, fixture.entered], label: "held lease sign-out")
                    XCTAssertTrue(fixture.gate.isHeld)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                    var authenticated = false
                    var pending: Error?
                    let pendingAttempt = Task {
                        do {
                            _ = try await model.prepareSignIn {
                                authenticated = true
                                return sessionB
                            }
                        } catch { pending = error }
                    }
                    fixture.tasks.append(pendingAttempt)
                    try await self.waitForTask(pendingAttempt, label: "pending cleanup sign-in")
                    guard let pending = pending as? FoundationDownloadAccountError,
                        case .cleanupPending = pending
                    else {
                        XCTFail("Sign-in must wait for local cleanup; retained fixture")
                        throw CancellationError()
                    }
                    XCTAssertFalse(authenticated)
                    try await fixture.releaseResources(using: self)
                    try await self.waitForEvents([localCleanup], label: "local cleanup")
                    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
                    XCTAssertTrue(
                        fixture.gate.isHeld, "Server revocation must not gate local sign-in")
                    try await fixture.open(model, user: sessionB.userID)
                    XCTAssertNotEqual(model.library?.catalogAccountIdentity, scopeA)
                    XCTAssertFalse(model.player === oldPlayer)
                    XCTAssertFalse(model.downloads === oldDownloads)
                    fixture.gate.release()
                    try await fixture.drain(using: self)

                })
        }

        func testHeldRevocationDoesNotDelayLocalModelSignOut() async throws {
            try await withLifecycleFixture { fixture, model in
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let actions = try XCTUnwrap(model.actions)
                let scope = try XCTUnwrap(model.library).catalogAccountIdentity
                actions.togglePin(fixture.album)
                XCTAssertNotNil(fixture.defaults.data(forKey: FoundationPinStorage.key(for: scope)))
                let player = try XCTUnwrap(model.player)
                let localCleanup = self.expectation(description: "local sign-out cleanup completed")
                let observation = model.$isCleaningDownloads.dropFirst().filter { !$0 }.sink { _ in
                    localCleanup.fulfill()
                }
                defer { observation.cancel() }
                model.signOut()
                fixture.captureStop(player)
                XCTAssertNil(model.library)
                XCTAssertNil(model.player)
                XCTAssertNil(fixture.defaults.data(forKey: FoundationPinStorage.key(for: scope)))
                try await self.waitForEvents(
                    [fixture.entered, localCleanup], label: "held revocation and local cleanup")
                XCTAssertTrue(fixture.gate.isHeld)
                XCTAssertNil(model.signOutNotice)
                fixture.gate.release()
                try await fixture.drain(using: self)
                XCTAssertEqual(model.signOutNotice?.contains("Server sign-out unconfirmed."), true)
            }
        }

        func testFailedCredentialClearPreservesModelAndPinsDuringHeldRevocation() async throws {
            try await withLifecycleFixture { fixture, model in
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let library = try XCTUnwrap(model.library)
                let player = try XCTUnwrap(model.player)
                let actions = try XCTUnwrap(model.actions)
                actions.togglePin(fixture.album)
                let key = FoundationPinStorage.key(for: library.catalogAccountIdentity)
                let pins = try XCTUnwrap(fixture.defaults.data(forKey: key))
                fixture.deleteStatus = errSecInteractionNotAllowed
                model.signOut()
                fixture.captureStop(player)
                try await self.waitForEvents([fixture.entered], label: "failed sign-out revocation")
                XCTAssertTrue(fixture.gate.isHeld)
                XCTAssertTrue(model.player === player)
                XCTAssertEqual(
                    model.library?.catalogAccountIdentity, library.catalogAccountIdentity)
                XCTAssertTrue(model.actions === actions)
                XCTAssertTrue(actions.isPinned(fixture.album))
                XCTAssertEqual(fixture.defaults.data(forKey: key), pins)
                XCTAssertNotNil(model.credentialError)
                fixture.gate.release()
                try await fixture.drain(using: self)
                XCTAssertFalse(fixture.gate.isHeld)
            }
        }

        func testLateScopedCacheCleanupPreservesReplacementCache() async throws {
            try await withLifecycleFixture { fixture, model in
                let old = fixture.session(user: "00000000000000000000000000000001")
                let next = fixture.session(user: "00000000000000000000000000000002")
                try await fixture.open(model, user: old.userID)
                let oldPlayer = try XCTUnwrap(model.player)
                let oldScope = try XCTUnwrap(model.library).catalogAccountIdentity
                let nextScope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0" + next.serverURL.absoluteString + "\0" + next.userID)
                let cache = FoundationCatalogPageCache(
                    scope: nextScope, root: fixture.storage.pages)
                let page = FoundationPage(items: [fixture.album], nextStartIndex: nil)
                await cache.write(page, key: "replacement-cache-sentinel")
                let before = await cache.read("replacement-cache-sentinel")
                XCTAssertEqual(before?.page.items.map(\.id), [fixture.album.id])
                let cleanup = self.expectation(description: "old account cleanup completed")
                let observation = model.$isCleaningDownloads.dropFirst().filter { !$0 }.first()
                    .sink { _ in cleanup.fulfill() }
                defer { observation.cancel() }
                model.signOut()
                fixture.captureStop(oldPlayer)
                try await self.waitForEvents(
                    [fixture.entered, cleanup], label: "old account cleanup")
                XCTAssertTrue(fixture.gate.isHeld)
                let during = await cache.read("replacement-cache-sentinel")
                XCTAssertEqual(during?.page.items.map(\.id), [fixture.album.id])
                _ = await cache.invalidate(removeDisk: false)
                try await fixture.open(model, user: next.userID)
                let player = try XCTUnwrap(model.player)
                let library = try XCTUnwrap(model.library)
                let replacement = try XCTUnwrap(library.catalogPageCache)
                XCTAssertNotEqual(library.catalogAccountIdentity, oldScope)
                XCTAssertFalse(player === oldPlayer)
                let after = await replacement.read("replacement-cache-sentinel")
                XCTAssertEqual(after?.page.items.map(\.id), [fixture.album.id])
                fixture.gate.release()
                try await fixture.drain(using: self)
                XCTAssertTrue(model.player === player)
                XCTAssertEqual(
                    model.library?.catalogAccountIdentity, library.catalogAccountIdentity)
                XCTAssertNil(model.credentialError)
            }
        }

        func testLateRevocationCannotOverwriteReplacementAccount() async throws {
            try await withLifecycleFixture { fixture, model in
                try await fixture.open(model, user: "00000000000000000000000000000001")
                let oldPlayer = try XCTUnwrap(model.player)
                let oldScope = try XCTUnwrap(model.library).catalogAccountIdentity
                let localCleanup = self.expectation(description: "old account cleanup completed")
                let observation = model.$isCleaningDownloads.dropFirst().filter { !$0 }.sink { _ in
                    localCleanup.fulfill()
                }
                defer { observation.cancel() }
                model.signOut()
                fixture.captureStop(oldPlayer)
                try await self.waitForEvents(
                    [fixture.entered, localCleanup], label: "old account revocation")
                XCTAssertTrue(fixture.gate.isHeld)
                try await fixture.open(model, user: "00000000000000000000000000000002")
                let replacementPlayer = try XCTUnwrap(model.player)
                let replacementLibrary = try XCTUnwrap(model.library)
                let replacementActions = try XCTUnwrap(model.actions)
                XCTAssertFalse(replacementPlayer === oldPlayer)
                XCTAssertNotEqual(replacementLibrary.catalogAccountIdentity, oldScope)
                replacementActions.togglePin(fixture.album)
                let key = FoundationPinStorage.key(for: replacementLibrary.catalogAccountIdentity)
                let pins = try XCTUnwrap(fixture.defaults.data(forKey: key))
                fixture.gate.release()
                try await fixture.drain(using: self)
                XCTAssertTrue(model.player === replacementPlayer)
                XCTAssertEqual(
                    model.library?.catalogAccountIdentity, replacementLibrary.catalogAccountIdentity
                )
                XCTAssertTrue(replacementActions.isPinned(fixture.album))
                XCTAssertEqual(fixture.defaults.data(forKey: key), pins)
                XCTAssertNil(model.signOutNotice)
                XCTAssertNil(model.credentialError)
            }
        }

        private func waitForEvents(_ events: [XCTestExpectation], label: String) async throws {
            let result = await XCTWaiter.fulfillment(of: events, timeout: 5)
            guard result == .completed else {
                XCTFail("Timed out waiting for \(label)")
                throw CancellationError()
            }
        }

        private func withLifecycleFixture(
            pageCleanupGate: LifecycleGate? = nil, cleanupReturned: XCTestExpectation? = nil,
            leaseWaitStarted: (() -> Void)? = nil,
            backgroundReconcile: (@MainActor (String) async -> Bool)? = nil,
            nativeRetirement: FoundationDownloads.NativeRetirement? = nil,
            useModelBackgroundRouting: Bool = false,
            _ body: (LifecycleFixture, FoundationAppModel) async throws -> Void
        ) async throws {
            // Only revocation tests wait on this event; direct creation avoids registering an
            // unused expectation in the cache-only replacement test.
            let fixture = try LifecycleFixture(
                entered: XCTestExpectation(description: "revocation entered"))
            let model = fixture.makeModel(
                pageCleanupGate: pageCleanupGate, cleanupReturned: cleanupReturned,
                leaseWaitStarted: leaseWaitStarted, backgroundReconcile: backgroundReconcile,
                nativeRetirement: nativeRetirement,
                useModelBackgroundRouting: useModelBackgroundRouting)
            do {
                var readiness: FoundationAppModel.Readiness?
                let startup = Task { readiness = await model.ensureReady() }
                try await waitForTask(startup, label: "isolated startup")
                XCTAssertEqual(readiness, .signedOut)
                try await body(fixture, model)
                pageCleanupGate?.release()
                fixture.gate.release()
                try await fixture.releaseResources(using: self)
                fixture.deleteStatus = errSecSuccess
                if let player = model.player {
                    model.signOut()
                    fixture.captureStop(player)
                }
                try await fixture.drain(using: self)
                fixture.removeData()
            } catch {
                pageCleanupGate?.release()
                fixture.gate.release()
                do {
                    try await fixture.releaseResources(using: self)
                } catch {
                    XCTFail("Could not finish isolated playback-resource release")
                }
                fixture.deleteStatus = errSecSuccess
                if let player = model.player {
                    model.signOut()
                    fixture.captureStop(player)
                }
                do {
                    try await fixture.drain(using: self)
                } catch {
                    XCTFail("Could not drain isolated lifecycle tasks")
                }
                // A timed-out shared startup may outlive its waiter, even if the current
                // observed-task snapshot drained. Retain this fixture on every failure.
                throw error
            }
        }

        fileprivate func waitForTask(_ task: Task<Void, Never>, label: String) async throws {
            let done = expectation(description: label)
            let observer = Task {
                await task.value
                done.fulfill()
            }
            let result = await XCTWaiter.fulfillment(of: [done], timeout: 5)
            guard result == .completed else {
                task.cancel()
                observer.cancel()
                XCTFail("Timed out waiting for \(label); retained its isolated data for inspection")
                throw CancellationError()
            }
            await observer.value
        }

        func testScopedAccountRetentionUsesOnlyItsOwnRootsAndDefaults() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let suite = "VelaCanto.Isolation." + UUID().uuidString
            let otherSuite = "VelaCanto.Isolation." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
            defer {
                defaults.removePersistentDomain(forName: suite)
                otherDefaults.removePersistentDomain(forName: otherSuite)
                try? FileManager.default.removeItem(at: container)
            }
            let first = FoundationScopedAccountStorage(
                root: container.appendingPathComponent("a"), defaults: defaults)
            let second = FoundationScopedAccountStorage(
                root: container.appendingPathComponent("b"), defaults: otherDefaults)
            let keep = String(repeating: "a", count: 64)
            let remove = String(repeating: "b", count: 64)
            let retained = FoundationDownloadStorage.directory(scope: keep, root: first.downloads)
            let removed = FoundationDownloadStorage.directory(scope: remove, root: first.downloads)
            let other = FoundationDownloadStorage.directory(scope: remove, root: second.downloads)
            for directory in [retained, removed, other] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            }
            defaults.set(Data([1]), forKey: FoundationPinStorage.key(for: keep))
            defaults.set(Data([2]), forKey: FoundationPinStorage.key(for: remove))
            otherDefaults.set(Data([3]), forKey: FoundationPinStorage.key(for: remove))
            let retention = first.retention
            XCTAssertTrue(retention.pins(keep))
            XCTAssertTrue(retention.downloads(keep))
            XCTAssertNotNil(defaults.data(forKey: FoundationPinStorage.key(for: keep)))
            XCTAssertNil(defaults.data(forKey: FoundationPinStorage.key(for: remove)))
            XCTAssertNotNil(otherDefaults.data(forKey: FoundationPinStorage.key(for: remove)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
            XCTAssertEqual(try retention.inventory(keep), .matching)
        }

        func testEmptyDownloadCleanupRetainsScopeAndLeavesOtherRootAlone() throws {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let firstRoot = container.appendingPathComponent("first", isDirectory: true)
            let secondRoot = container.appendingPathComponent("second", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: container) }
            let keep = FoundationDownloadStorage.directory(scope: "account-a", root: firstRoot)
            let remove = FoundationDownloadStorage.directory(scope: "account-b", root: firstRoot)
            let other = FoundationDownloadStorage.directory(scope: "account-b", root: secondRoot)
            for directory in [keep, remove, other] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            }

            XCTAssertTrue(
                FoundationDownloads.clearStoredDownloads(retaining: "account-a", root: firstRoot))
            XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: remove.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
            XCTAssertTrue(FoundationDownloads.clearStoredDownloads(root: firstRoot))
            XCTAssertFalse(FileManager.default.fileExists(atPath: keep.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        }

        func testDownloadCleanupPreservesPendingNativeSessionsInScopedRoot() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = FoundationDownloadStorage.directory(scope: "account-a", root: root)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            var manifest = FoundationDownloadManifest()
            manifest.nativePendingSessions = ["held-session"]
            try JSONEncoder().encode(manifest).write(
                to: directory.appendingPathComponent("manifest.json"))

            XCTAssertFalse(FoundationDownloads.clearStoredDownloads(root: root))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertEqual(
                try FoundationDownloadStorage.load(directory: directory).nativePendingSessions,
                ["held-session"])
        }

        func testScopedCleanupRejectsNativePackageWithoutResolvingIt() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = FoundationDownloadStorage.directory(scope: "account-a", root: root)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let package = FoundationNativeDownloadPackage(
                nativeURL: URL(fileURLWithPath: "/do-not-resolve-synthetic.movpkg"),
                bookmark: Data("synthetic".utf8), sessionIdentifier: "synthetic")
            var manifest = FoundationDownloadManifest()
            manifest.files["track"] = .init(
                name: "synthetic.movpkg", bytes: 1, digest: "", nativePackage: package)
            try JSONEncoder().encode(manifest).write(
                to: directory.appendingPathComponent("manifest.json"))
            let cleared = FoundationDownloads.clearStoredDownloads(root: root)
            XCTAssertFalse(cleared)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        }

        func testScopedCleanupRejectsNativeReceiptWithoutOpeningIt() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = FoundationDownloadStorage.directory(scope: "account-a", root: root)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let receipt = directory.appendingPathComponent("native-receipt-synthetic")
            let sentinel = Data("unread synthetic receipt".utf8)
            try sentinel.write(to: receipt)
            XCTAssertFalse(
                FoundationDownloads.clearStoredDownloads(root: root))
            XCTAssertEqual(try Data(contentsOf: receipt), sentinel)
        }

        func testPlayerStopUsesIsolatedSessionLaneAndDiagnosticSink() async {
            let lane = FoundationPlayer.SessionLane()
            var deactivations = 0
            let diagnostics = IsolatedDiagnosticRecorder()
            let player = FoundationPlayer(
                resolve: { _ in URL(fileURLWithPath: "/synthetic") },
                activateSession: {},
                deactivateSession: { deactivations += 1 },
                sessionLane: lane,
                observeSystemEvents: false,
                diagnostic: { diagnostics.append($0) })
            player.stop()
            await player.sessionTask?.value
            XCTAssertEqual(deactivations, 1)
            #if DEBUG
                XCTAssertTrue(diagnostics.snapshot().contains { $0.contains("command.stop") })
            #endif
        }
    }

    private final class IntentKeychainFixture {
        var group = "fixture.access-group"
        var generic: Data?
        var payload: Data?
        var credentialData: Data? = Data("fixture credential".utf8)
        var credentialGeneration: Data?
        var generationUpdateStatus: OSStatus = errSecSuccess
        var generationUpdateCount = 0
        var afterGenerationUpdate: (() -> Void)?
        var credentialDeletes = 0
        var credentialDeleteStatus: OSStatus = errSecSuccess
        var duplicateGroup = false
        var duplicateCredentialGroup = false
        var addStatus: OSStatus = errSecSuccess
        var readStatus: OSStatus = errSecSuccess
        var readbackStatusAfterAdd: OSStatus?
        var readbackStatusAfterDelete: OSStatus?
        var readbackStatusAfterIntentUpdate: OSStatus?
        var readbackStatusAfterCredentialDelete: OSStatus?
        var beforeDelete: (() -> Void)?
        var deleteAttempts = 0

        func operations() -> FoundationCredentials.Operations {
            FoundationCredentials.Operations(
                update: { [self] query, attributes in
                    if query[kSecAttrAccount as String] as? String == "pending-sign-out" {
                        guard query[kSecAttrAccessGroup as String] as? String == group,
                            query[kSecAttrGeneric as String] as? Data == generic,
                            payload != nil, let data = attributes[kSecValueData as String] as? Data
                        else { return errSecItemNotFound }
                        payload = data
                        if let readbackStatusAfterIntentUpdate {
                            readStatus = readbackStatusAfterIntentUpdate
                        }
                        return errSecSuccess
                    }
                    if query[kSecAttrAccount as String] as? String == "current-session",
                        attributes[kSecValueData as String] == nil,
                        let generation = attributes[kSecAttrGeneric as String] as? Data
                    {
                        guard generationUpdateStatus == errSecSuccess else {
                            return generationUpdateStatus
                        }
                        guard query[kSecAttrAccessGroup as String] as? String == group,
                            credentialData != nil
                        else { return errSecItemNotFound }
                        credentialGeneration = generation
                        generationUpdateCount += 1
                        afterGenerationUpdate?()
                        return errSecSuccess
                    }
                    guard query[kSecAttrAccount as String] as? String == "current-session",
                        credentialData != nil,
                        let data = attributes[kSecValueData as String] as? Data
                    else { return errSecItemNotFound }
                    if let selected = query[kSecAttrAccessGroup as String] as? String,
                        selected != group
                    {
                        return errSecItemNotFound
                    }
                    credentialData = data
                    if let generation = attributes[kSecAttrGeneric as String] as? Data {
                        credentialGeneration = generation
                    }
                    return errSecSuccess
                },
                add: { [self] query in
                    guard addStatus == errSecSuccess else { return addStatus }
                    if query[kSecAttrAccount as String] as? String == "current-session" {
                        guard credentialData == nil,
                            let data = query[kSecValueData as String] as? Data
                        else {
                            return errSecDuplicateItem
                        }
                        credentialData = data
                        credentialGeneration = query[kSecAttrGeneric as String] as? Data
                        return errSecSuccess
                    }
                    guard payload == nil else { return errSecDuplicateItem }
                    guard query[kSecAttrAccount as String] as? String == "pending-sign-out",
                        query[kSecAttrAccessGroup as String] as? String == group,
                        query[kSecAttrSynchronizable as String] as? Bool == false,
                        let generic = query[kSecAttrGeneric as String] as? Data,
                        let payload = query[kSecValueData as String] as? Data
                    else { return errSecParam }
                    self.generic = generic
                    self.payload = payload
                    if let readbackStatusAfterAdd { readStatus = readbackStatusAfterAdd }
                    return errSecSuccess
                },
                copy: { [self] query in
                    guard readStatus == errSecSuccess else { return (readStatus, nil) }
                    let account = query[kSecAttrAccount as String] as? String
                    if query[kSecReturnAttributes as String] as? Bool == true {
                        if account == "current-session" {
                            guard credentialData != nil else { return (errSecItemNotFound, nil) }
                            var first: [String: Any] = [kSecAttrAccessGroup as String: group]
                            if let credentialGeneration {
                                first[kSecAttrGeneric as String] = credentialGeneration
                            }
                            if duplicateCredentialGroup {
                                return (
                                    errSecSuccess,
                                    NSArray(array: [
                                        first, [kSecAttrAccessGroup as String: "different.group"],
                                    ])
                                )
                            }
                            return (errSecSuccess, NSArray(array: [first]))
                        }
                        guard account == "pending-sign-out", let generic, payload != nil else {
                            return (errSecItemNotFound, nil)
                        }
                        let first: [String: Any] = [
                            kSecAttrAccessGroup as String: group,
                            kSecAttrGeneric as String: generic,
                        ]
                        if duplicateGroup {
                            var second = first
                            second[kSecAttrAccessGroup as String] = "different.group"
                            return (errSecSuccess, NSArray(array: [first, second]))
                        }
                        return (errSecSuccess, NSArray(array: [first]))
                    }
                    if account == "current-session" {
                        if let selected = query[kSecAttrAccessGroup as String] as? String,
                            selected != group
                        {
                            return (errSecItemNotFound, nil)
                        }
                        guard let credentialData else { return (errSecItemNotFound, nil) }
                        return (errSecSuccess, credentialData as CFData)
                    }
                    guard account == "pending-sign-out",
                        query[kSecAttrAccessGroup as String] as? String == group,
                        query[kSecAttrGeneric as String] as? Data == generic,
                        let payload
                    else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, payload as CFData)
                },
                delete: { [self] query in
                    if query[kSecAttrAccount as String] as? String == "current-session" {
                        guard credentialDeleteStatus == errSecSuccess else {
                            return credentialDeleteStatus
                        }
                        guard query[kSecAttrAccessGroup as String] as? String == group,
                            credentialData != nil
                        else { return errSecItemNotFound }
                        credentialData = nil
                        credentialGeneration = nil
                        credentialDeletes += 1
                        if let readbackStatusAfterCredentialDelete {
                            readStatus = readbackStatusAfterCredentialDelete
                        }
                        return errSecSuccess
                    }
                    deleteAttempts += 1
                    let interleave = beforeDelete
                    beforeDelete = nil
                    interleave?()
                    guard query[kSecAttrAccount as String] as? String == "pending-sign-out",
                        query[kSecAttrAccessGroup as String] as? String == group,
                        query[kSecAttrGeneric as String] as? Data == generic, payload != nil
                    else { return errSecItemNotFound }
                    payload = nil
                    generic = nil
                    if let readbackStatusAfterDelete { readStatus = readbackStatusAfterDelete }
                    return errSecSuccess
                })
        }
    }

    @MainActor
    private final class NativeRetirementPermission {
        var allowed = true
        var deliveries = 0
        func recordDelivery() { deliveries += 1 }
    }

    private actor IsolatedExchangeCounter {
        private var calls = 0
        func next() -> Int {
            calls += 1
            return calls
        }
        func count() -> Int { calls }
    }

    @MainActor
    private final class LifecycleGate {
        private let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        var isHeld: Bool { continuation != nil }

        init(entered: XCTestExpectation) { self.entered = entered }

        func hold() async {
            guard !released else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }

        func release() {
            guard !released else { return }
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class LifecycleFixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let storage: FoundationScopedAccountStorage
        let entered: XCTestExpectation
        let gate: LifecycleGate
        let events = IsolatedDiagnosticRecorder()
        var tasks: [Task<Void, Never>] = []
        var stops: [Task<Void, Never>] = []
        var revocations: [Task<Bool, Never>] = []
        var resources: [FoundationPlaybackResource] = []
        var deleteStatus: OSStatus = errSecSuccess
        var copyStatus: OSStatus = errSecItemNotFound
        var copiedCredential: Data?
        var saveStatus: OSStatus = errSecSuccess
        var credentialWrites = 0
        var credentialDeletes = 0
        var oldCleanupCancelled: Bool?
        var oldCleanupSucceeded: Bool?
        let album = FoundationItem(
            id: "album", title: "Synthetic", subtitle: "", kind: .album, duration: nil)

        init(entered: XCTestExpectation) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true)
            suite = "VelaCanto.Isolation." + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            storage = FoundationScopedAccountStorage(root: root, defaults: defaults)
            self.entered = entered
            gate = LifecycleGate(entered: entered)
            defaults.set("data-protection-ready", forKey: FoundationAppModel.credentialBackendKey)
        }

        func makeModel(
            pageCleanupGate: LifecycleGate? = nil, cleanupReturned: XCTestExpectation? = nil,
            leaseWaitStarted: (() -> Void)? = nil,
            loadOverride: FoundationJellyfinLibrary.Load? = nil,
            backgroundReconcile: (@MainActor (String) async -> Bool)? = nil,
            emptyNativeSession: (
                @MainActor (
                    String, @escaping @MainActor @Sendable () async -> Bool,
                    @escaping @MainActor @Sendable () -> Void
                ) async -> FoundationNativeEmptySessionOutcome
            )? = nil,
            nativeRetirement: FoundationDownloads.NativeRetirement? = nil,
            useModelBackgroundRouting: Bool = false,
            inspectSignOutIntent: (@MainActor () async -> FoundationSignOutInspection)? = nil,
            prepareIsolatedCaches: (@MainActor () async -> Bool)? = nil,
            inspectionJoined: (() -> Void)? = nil,
            acquireAccountOwnership: (
                @MainActor () async throws -> FoundationAccountLifetimeLease?
            )? = nil,
            accountTransactions: FoundationAccountTransactions? = nil,
            credentialOperations: FoundationCredentials.Operations? = nil,
            coldNativeRetirement: (
                @MainActor (
                    FoundationNativeAllocationStore, UUID,
                    FoundationScopedAccountRemoval.ColdAllocatedCandidate,
                    @escaping @MainActor @Sendable () async -> Bool
                ) async -> Bool
            )? = nil,
            coldTerminalRetirement: (
                @MainActor (
                    FoundationNativeAllocationStore, UUID,
                    FoundationScopedAccountRemoval.ColdTerminalCandidate,
                    @escaping @MainActor @Sendable () async -> Bool
                ) async -> Bool
            )? = nil
        ) -> FoundationAppModel {
            var retention = storage.retention
            let actualPages = retention.pages
            var didHoldPageCleanup = false
            if let pageCleanupGate {
                retention.pages = { scope in
                    if scope != nil, !didHoldPageCleanup {
                        didHoldPageCleanup = true
                        await pageCleanupGate.hold()
                        self.oldCleanupCancelled = Task.isCancelled
                        let result = await actualPages(scope)
                        self.oldCleanupSucceeded = result
                        cleanupReturned?.fulfill()
                        return result
                    }
                    return await actualPages(scope)
                }
            }
            let credentials = FoundationCredentials.Operations(
                update: { [self] _, _ in
                    credentialWrites += 1
                    return saveStatus
                },
                add: { [self] _ in
                    credentialWrites += 1
                    return saveStatus
                },
                copy: { [self] _ in (copyStatus, copiedCredential as CFTypeRef?) },
                delete: { [self] _ in
                    credentialDeletes += 1
                    return deleteStatus
                })
            let inventoryVerifier: FoundationDownloads.FileVerifier?
            if leaseWaitStarted == nil {
                inventoryVerifier = nil
            } else {
                inventoryVerifier = { @Sendable files, directory in
                    try await FoundationDownloadStorage.verifiedFiles(files, directory: directory)
                }
            }
            let isolation = FoundationAppRuntimeIsolation(
                storage: storage, credentials: credentialOperations ?? credentials,
                load: loadOverride ?? { _ in throw URLError(.notConnectedToInternet) },
                revoke: { [gate] _ in
                    Task {
                        await gate.hold()
                        return false
                    }
                },
                diagnostic: { [events] in events.append($0) },
                taskStarted: { [self] in tasks.append($0) },
                revocationStarted: { [self] in revocations.append($0) },
                retention: pageCleanupGate == nil ? nil : retention,
                verifyInventoryFiles: inventoryVerifier, leaseWaitStarted: leaseWaitStarted,
                backgroundReconcile: backgroundReconcile, emptyNativeSession: emptyNativeSession,
                nativeRetirement: nativeRetirement,
                useModelBackgroundRouting: useModelBackgroundRouting,
                inspectSignOutIntent: inspectSignOutIntent,
                prepareIsolatedCaches: prepareIsolatedCaches,
                inspectionJoined: inspectionJoined,
                acquireAccountOwnership: acquireAccountOwnership,
                accountTransactions: accountTransactions,
                coldNativeRetirement: coldNativeRetirement,
                coldTerminalRetirement: coldTerminalRetirement)
            return FoundationAppModel(
                restoreAccount: { $0.restoreCredentials() }, isolation: isolation)
        }

        func session(user: String) -> FoundationSession {
            FoundationSession(
                serverURL: URL(string: "https://synthetic.invalid")!, accessToken: "synthetic",
                userID: user, deviceID: "00000000-0000-0000-0000-000000000002")
        }

        func open(_ model: FoundationAppModel, user: String) async throws {
            let session = session(user: user)
            let accept = try await model.prepareSignIn { session }
            try await accept()
        }

        func acquireResource(
            from downloads: FoundationDownloads, item: FoundationItem,
            using test: FoundationAppLifecycleIsolationTests
        ) async throws {
            var failure: Error?
            var acquired = false
            let task = Task {
                do {
                    let resource = try await downloads.playbackResource(
                        for: item, allowsRemoteFallback: false)
                    if Task.isCancelled {
                        await resource.release()
                        return
                    }
                    self.resources.append(resource)
                    acquired = true
                } catch {
                    failure = error
                }
            }
            tasks.append(task)
            try await test.waitForTask(task, label: "isolated playback-resource acquisition")
            if let failure { throw failure }
            guard acquired else { throw CancellationError() }
        }

        func releaseResources(using test: FoundationAppLifecycleIsolationTests) async throws {
            let releasing = resources
            resources.removeAll()
            guard !releasing.isEmpty else { return }
            let task = Task {
                for resource in releasing { await resource.release() }
            }
            tasks.append(task)
            try await test.waitForTask(task, label: "isolated playback-resource release")
        }

        func captureStop(_ player: FoundationPlayer) {
            if let task = player.sessionTask { stops.append(task) }
        }

        func drain(using test: FoundationAppLifecycleIsolationTests) async throws {
            for task in tasks + stops {
                try await test.waitForTask(task, label: "isolated lifecycle task")
            }
            for revocation in revocations {
                let drain = Task { _ = await revocation.value }
                try await test.waitForTask(drain, label: "isolated revocation")
            }
        }

        func removeData() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class IsolatedDiagnosticRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []

        func append(_ event: String) {
            lock.lock()
            defer { lock.unlock() }
            events.append(event)
        }

        func append(_ event: String, maximum: Int) {
            lock.lock()
            defer { lock.unlock() }
            if events.count < maximum { events.append(event) }
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private actor HandoffTransferLibrary: FoundationLibrary {
        func albums(startIndex: Int) async throws -> FoundationPage {
            .init(items: [], nextStartIndex: nil)
        }

        func tracks(albumID: String, startIndex: Int) async throws -> FoundationPage {
            .init(items: [], nextStartIndex: nil)
        }

        func playbackURL(for item: FoundationItem) async throws -> URL {
            URL(string: "https://example.invalid/stream")!
        }

        func downloadSource(for item: FoundationItem) async throws -> FoundationDownloadSource {
            let request = URLRequest(url: URL(string: "https://example.invalid/original")!)
            return FoundationDownloadSource(
                request: request, fileExtension: "mp3", expectedBytes: nil)
        }
    }

    private actor HandoffRemoteLibrary: FoundationLibrary {
        let gate: LifecycleGate
        let requestGate: LifecycleGate?
        init(gate: LifecycleGate, requestGate: LifecycleGate? = nil) {
            self.gate = gate
            self.requestGate = requestGate
        }
        func albums(startIndex: Int) async throws -> FoundationPage {
            .init(items: [], nextStartIndex: nil)
        }
        func tracks(albumID: String, startIndex: Int) async throws -> FoundationPage {
            .init(items: [], nextStartIndex: nil)
        }
        func playbackURL(for item: FoundationItem) async throws -> URL {
            URL(string: "https://example.invalid/stream")!
        }
        func playbackResource(for item: FoundationItem) async throws -> FoundationPlaybackResource {
            await requestGate?.hold()
            let gate = gate
            return FoundationPlaybackResource(url: try await playbackURL(for: item)) {
                await gate.hold()
            }
        }
    }

    private actor HandoffArtworkLibrary: FoundationLibrary {
        let gate: LifecycleGate
        let retried: XCTestExpectation
        private var requests = 0
        init(gate: LifecycleGate, retried: XCTestExpectation) {
            self.gate = gate
            self.retried = retried
        }
        func albums(startIndex: Int) async throws -> FoundationPage {
            .init(items: [], nextStartIndex: nil)
        }
        func tracks(albumID: String, startIndex: Int) async throws -> FoundationPage {
            .init(items: [], nextStartIndex: nil)
        }
        func playbackURL(for item: FoundationItem) async throws -> URL {
            URL(string: "https://example.invalid/stream")!
        }
        func downloadArtwork(for item: FoundationItem, size: Int, allowsCellular: Bool)
            async throws -> Data?
        {
            requests += 1
            if requests == 1 { await gate.hold() } else { retried.fulfill() }
            return nil
        }
    }

#endif
