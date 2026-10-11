import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationLibraryActionsTests: XCTestCase {
    private let album = FoundationItem(
        id: "synthetic", title: "Synthetic", subtitle: "", kind: .album, duration: nil)

    func testDelayedCollectionPlayAndEnqueueCannotOverwriteExplicitUpcomingEdits() async throws {
        for startsPlayback in [true, false] {
            for removesEntry in [true, false] {
                let gate = CollectionGate()
                let session = FoundationSession(
                    serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic",
                    userID: "00000000000000000000000000000001", deviceID: "synthetic")
                let library = FoundationJellyfinLibrary(session: session) { request in
                    await gate.hold()
                    let body = """
                        {"Items":[{"Id":"00000000000000000000000000000002","Type":"Audio"}],"TotalRecordCount":1}
                        """
                    return (
                        Data(body.utf8),
                        HTTPURLResponse(
                            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                }
                let player = FoundationPlayer(resolve: { _ in throw CancellationError() })
                let track = FoundationItem(
                    id: "synthetic-track", title: "", subtitle: "", kind: .track, duration: nil)
                player.setQueue([track, track, track, track], selectedIndex: 1)
                await player.selectionTask?.value
                let actions = FoundationLibraryActions(
                    sourceScope: "synthetic", read: { _ in nil }, write: { _, _ in },
                    mutateFavorite: { _, _ in })
                let collection = FoundationItem(
                    id: "00000000000000000000000000000003", title: "", subtitle: "", kind: .album,
                    duration: nil)
                if startsPlayback {
                    actions.play(collection, shuffled: false, library: library, player: player)
                } else {
                    actions.enqueue(collection, position: .last, library: library, player: player)
                }
                let expansion = try XCTUnwrap(actions.queueTask)
                try await gate.waitUntilStarted()
                let selected = player.selectedEntryID
                if removesEntry {
                    player.removeUpcoming(player.upcoming[0].id)
                } else {
                    player.reorderUpcoming([player.upcoming[0].id], before: nil)
                }
                let edited = player.queue
                XCTAssertTrue(expansion.isCancelled)
                await gate.release()
                await expansion.value
                XCTAssertEqual(player.queue, edited)
                XCTAssertEqual(player.selectedEntryID, selected)
                XCTAssertFalse(actions.isQueueLoading)
                XCTAssertNil(actions.queueErrorMessage)
            }
        }
    }

    func testCollectionFailureCanRetryExplicitlyWithoutReplacingQueueUntilSuccess() async throws {
        let responses = CollectionResponses()
        let library = makeCollectionLibrary { request in
            if await responses.next() == 1 { throw URLError(.timedOut) }
            return selfContainedResponse(
                request, items: "{\"Id\":\"00000000000000000000000000000002\",\"Type\":\"Audio\"}")
        }
        let player = FoundationPlayer(resolve: { _ in throw CancellationError() })
        let track = FoundationItem(
            id: "existing", title: "", subtitle: "", kind: .track, duration: nil)
        player.setQueue([track], selectedIndex: 0)
        await player.selectionTask?.value
        let original = player.queue
        let actions = makeCollectionActions()
        actions.enqueue(collectionItem, position: .last, library: library, player: player)
        await actions.queueTask?.value
        XCTAssertNotNil(actions.queueErrorMessage)
        XCTAssertTrue(actions.canRetryQueueAddition)
        XCTAssertEqual(player.queue, original)
        let calls = await responses.count()
        XCTAssertEqual(calls, 1)
        actions.retryQueueAddition()
        await actions.queueTask?.value
        XCTAssertNil(actions.queueErrorMessage)
        XCTAssertFalse(actions.canRetryQueueAddition)
        XCTAssertEqual(player.queue.count, 2)
        player.stop()
    }

    func testOwnershipChangeDiscardsRetryFromFailedCollection() async {
        let responses = CollectionResponses()
        let library = makeCollectionLibrary { _ in
            _ = await responses.next()
            throw URLError(.timedOut)
        }
        let player = FoundationPlayer(resolve: { _ in throw CancellationError() })
        let actions = makeCollectionActions()
        actions.play(collectionItem, shuffled: false, library: library, player: player)
        await actions.queueTask?.value
        XCTAssertTrue(actions.canRetryQueueAddition)
        actions.cancelQueueAddition()
        XCTAssertFalse(actions.canRetryQueueAddition)
        actions.retryQueueAddition()
        let calls = await responses.count()
        XCTAssertEqual(calls, 1)
        XCTAssertNil(actions.queueTask)
        XCTAssertTrue(player.queue.isEmpty)
    }

    func testEmptyCollectionHasVisibleOutcomeWithoutChangingQueue() async {
        let library = makeCollectionLibrary { request in selfContainedResponse(request, items: "") }
        let player = FoundationPlayer(resolve: { _ in throw CancellationError() })
        let actions = makeCollectionActions()
        actions.play(collectionItem, shuffled: false, library: library, player: player)
        await actions.queueTask?.value
        XCTAssertEqual(actions.queueNotice, "This collection has no songs.")
        XCTAssertNil(actions.queueErrorMessage)
        XCTAssertFalse(actions.canRetryQueueAddition)
        XCTAssertTrue(player.queue.isEmpty)
        actions.dismissQueueOutcome()
        XCTAssertNil(actions.queueNotice)
    }

    func testExplicitCancellationRejectsLateSuccessAndAllowsLaterAction() async throws {
        let gate = CollectionGate()
        let library = makeCollectionLibrary { request in
            await gate.hold()
            return selfContainedResponse(
                request, items: "{\"Id\":\"00000000000000000000000000000002\",\"Type\":\"Audio\"}")
        }
        let player = FoundationPlayer(resolve: { _ in throw CancellationError() })
        let actions = makeCollectionActions()
        actions.enqueue(collectionItem, position: .last, library: library, player: player)
        let task = try XCTUnwrap(actions.queueTask)
        try await gate.waitUntilStarted()
        actions.cancelQueueAddition()
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(actions.isQueueLoading)
        await gate.release()
        await task.value
        XCTAssertFalse(actions.isQueueLoading)
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertEqual(actions.queueNotice, "Collection loading cancelled.")
        XCTAssertFalse(actions.canRetryQueueAddition)
        let empty = makeCollectionLibrary { request in selfContainedResponse(request, items: "") }
        actions.play(collectionItem, shuffled: false, library: empty, player: player)
        await actions.queueTask?.value
        XCTAssertEqual(actions.queueNotice, "This collection has no songs.")
    }

    func testCollectionPageBudgetFailsWithoutCommittingPartialQueue() async {
        let responses = CollectionResponses()
        let library = makeCollectionLibrary { request in
            let index = await responses.next() - 1
            let body =
                "{\"Items\":[{\"Id\":\"00000000000000000000000000000002\",\"Type\":\"Audio\"}],\"StartIndex\":\(index),\"TotalRecordCount\":1000}"
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let player = FoundationPlayer(resolve: { _ in throw CancellationError() })
        let actions = makeCollectionActions()
        actions.enqueue(collectionItem, position: .last, library: library, player: player)
        await actions.queueTask?.value
        let calls = await responses.count()
        XCTAssertEqual(calls, FoundationLibraryActions.maximumCollectionPages)
        XCTAssertEqual(actions.queueLoadedCount, calls)
        XCTAssertNotNil(actions.queueErrorMessage)
        XCTAssertFalse(actions.canRetryQueueAddition)
        XCTAssertTrue(player.queue.isEmpty)
    }

    private var collectionItem: FoundationItem {
        FoundationItem(
            id: "00000000000000000000000000000003", title: "", subtitle: "", kind: .album,
            duration: nil)
    }

    private func makeCollectionActions() -> FoundationLibraryActions {
        FoundationLibraryActions(
            sourceScope: "synthetic", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
    }

    private func makeCollectionLibrary(
        send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) -> FoundationJellyfinLibrary {
        FoundationJellyfinLibrary(
            session: FoundationSession(
                serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic",
                userID: "00000000000000000000000000000001", deviceID: "synthetic"), load: send)
    }

    private actor CollectionResponses {
        private var calls = 0
        func next() -> Int {
            calls += 1
            return calls
        }
        func count() -> Int { calls }
    }

    private actor CollectionGate {
        private var held: CheckedContinuation<Void, Never>?
        func hold() async { await withCheckedContinuation { held = $0 } }
        func waitUntilStarted() async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while held == nil {
                guard clock.now < deadline else { throw Failure.synthetic }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func release() {
            held?.resume()
            held = nil
        }
    }

    func testPinsPersistWithinSourceAndSeparateKindsWithoutNetwork() {
        var storage: [String: Data] = [:]
        let make: (String) -> FoundationLibraryActions = { scope in
            FoundationLibraryActions(
                sourceScope: scope, read: { storage[$0] }, write: { storage[$0] = $1 },
                mutateFavorite: { _, _ in XCTFail("Pinning must not call the provider") })
        }
        let first = make("source-a")
        let artist = FoundationItem(
            id: album.id, title: "Synthetic", subtitle: "", kind: .artist, duration: nil)
        first.togglePin(album)
        first.togglePin(artist)
        XCTAssertEqual(make("source-a").pins, [album, artist])
        XCTAssertTrue(make("source-b").pins.isEmpty)
        first.togglePin(album)
        XCTAssertEqual(make("source-a").pins, [artist])
    }

    func testLegacyScopedPinsAreRemovedWithoutTouchingCurrentAccountOrOtherPreferences() {
        let defaults = UserDefaults(suiteName: "Velacanto.PinTests.\(UUID().uuidString)")!
        let currentKey = FoundationPinStorage.key(for: "current")
        let oldKey = FoundationPinStorage.key(for: "old-account")
        let unrelatedKey = "Velacanto.Foundation.OtherPreference"
        defer {
            for key in [currentKey, oldKey, unrelatedKey] { defaults.removeObject(forKey: key) }
        }
        let make: (String) -> FoundationLibraryActions = { scope in
            FoundationLibraryActions(
                sourceScope: scope, read: { defaults.data(forKey: $0) },
                write: { defaults.set($1, forKey: $0) },
                mutateFavorite: { _, _ in XCTFail("Pinning must not call the provider") })
        }
        make("current").togglePin(album)
        defaults.set(Data("synthetic-old-pin".utf8), forKey: oldKey)
        defaults.set("keep", forKey: unrelatedKey)

        // Relaunch with a saved session keeps only its own pins.
        XCTAssertTrue(
            FoundationPinStorage.removeStoredPins(retaining: "current", defaults: defaults))
        XCTAssertEqual(make("current").pins, [album])
        XCTAssertNil(defaults.object(forKey: oldKey))
        XCTAssertEqual(defaults.string(forKey: unrelatedKey), "keep")

        // Sign-out (including offline sign-out) leaves no scoped pin snapshots.
        XCTAssertTrue(FoundationPinStorage.removeStoredPins(defaults: defaults))
        XCTAssertTrue(make("current").pins.isEmpty)
        XCTAssertNil(defaults.object(forKey: currentKey))
        XCTAssertEqual(defaults.string(forKey: unrelatedKey), "keep")
    }

    func testAccountSwitchRemovesPreviousPinSnapshotBeforeNewScopeLoads() {
        let defaults = UserDefaults(suiteName: "Velacanto.PinTests.\(UUID().uuidString)")!
        let previousKey = FoundationPinStorage.key(for: "previous")
        let nextKey = FoundationPinStorage.key(for: "next")
        defer {
            defaults.removeObject(forKey: previousKey)
            defaults.removeObject(forKey: nextKey)
        }
        let previous = FoundationLibraryActions(
            sourceScope: "previous", read: { defaults.data(forKey: $0) },
            write: { defaults.set($1, forKey: $0) }, mutateFavorite: { _, _ in })
        previous.togglePin(album)
        XCTAssertNotNil(defaults.object(forKey: previousKey))

        XCTAssertTrue(FoundationPinStorage.removeStoredPins(defaults: defaults))
        previous.invalidate()
        let next = FoundationLibraryActions(
            sourceScope: "next", read: { defaults.data(forKey: $0) },
            write: { defaults.set($1, forKey: $0) }, mutateFavorite: { _, _ in })
        XCTAssertNil(defaults.object(forKey: previousKey))
        XCTAssertTrue(next.pins.isEmpty)
    }

    func testFailedLocalSignOutKeepsActivePinsAndStoredPinsCoherent() {
        var storage: [String: Data] = [:]
        let key = FoundationPinStorage.key(for: "current")
        let make: () -> FoundationLibraryActions = {
            FoundationLibraryActions(
                sourceScope: "current", read: { storage[$0] },
                write: { storage[$0] = $1 }, mutateFavorite: { _, _ in })
        }
        let actions = make()
        actions.togglePin(album)
        let savedBeforeAttempt = storage[key]
        var cleanupCalls = 0

        let attempt = FoundationSignOutPolicy.begin {
            Task { false }
        } clear: {
            throw FoundationLibraryError.credentials
        } clearPins: {
            cleanupCalls += 1
            storage.removeValue(forKey: key)
            return true
        }
        XCTAssertFalse(attempt.localCleared)
        XCTAssertFalse(attempt.pinsCleared)
        XCTAssertEqual(cleanupCalls, 0)
        XCTAssertEqual(storage[key], savedBeforeAttempt)
        XCTAssertEqual(actions.pins, [album])

        let artist = FoundationItem(
            id: "synthetic-artist", title: "Synthetic", subtitle: "", kind: .artist,
            duration: nil)
        actions.togglePin(artist)
        XCTAssertEqual(make().pins, [album, artist])
    }

    func testPinWriteFailureRetainsPriorStateAndTrackCannotPin() {
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil },
            write: { _, _ in throw Failure.synthetic }, mutateFavorite: { _, _ in })
        actions.togglePin(album)
        XCTAssertTrue(actions.pins.isEmpty)
        XCTAssertNotNil(actions.pinErrorMessage)
        let track = FoundationItem(
            id: "track", title: "Synthetic", subtitle: "", kind: .track, duration: nil)
        actions.togglePin(track)
        XCTAssertTrue(actions.pins.isEmpty)
    }

    func testExplicitFalseInFavoritesResponseOverridesMembershipAndSuccessfulMutation() async {
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        var item = album
        item.isFavorite = false
        await actions.setFavorite(for: item, isFavorite: true)
        XCTAssertEqual(actions.favoriteItems(in: [item]).count, 1)
        actions.observeFavorites(
            in: [item], knownFavorites: true, read: actions.beginFavoriteRead())
        XCTAssertEqual(actions.favoriteState(for: item, initial: nil), false)
        XCTAssertTrue(actions.favoriteItems(in: [item]).isEmpty)
        await actions.setFavorite(for: item, isFavorite: false)
        actions.observeFavorites(
            in: [item], knownFavorites: true, read: actions.beginFavoriteRead())
        XCTAssertTrue(actions.favoriteItems(in: [item]).isEmpty)
        item.isFavorite = true
        actions.observeFavorites(
            in: [item], knownFavorites: true, read: actions.beginFavoriteRead())
        XCTAssertEqual(actions.favoriteItems(in: [item]).count, 1)
        XCTAssertEqual(actions.favoriteState(for: item, initial: nil), true)
        let unknown = FoundationItem(
            id: "unknown", title: "Unknown", subtitle: "", kind: .album,
            duration: nil, isFavorite: nil)
        actions.observeFavorites(
            in: [unknown], knownFavorites: true, read: actions.beginFavoriteRead())
        XCTAssertEqual(actions.favoriteState(for: unknown, initial: nil), true)
    }

    func testFavoriteDisplayFilteringPreservesRawPagingAndDuplicateTrackSelection() async {
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        let hidden = FoundationItem(
            id: "hidden", title: "Hidden", subtitle: "", kind: .track,
            duration: nil, isFavorite: false)
        let track = FoundationItem(
            id: "same", title: "Same", subtitle: "", kind: .track,
            duration: nil, isFavorite: true)
        let items = [hidden, track, album, track]
        let selection = actions.favoriteTrackQueue(in: items, selecting: 3)
        XCTAssertEqual(selection?.items.map(\.id), ["same", "same"])
        XCTAssertEqual(selection?.index, 1)
        XCTAssertNil(actions.favoriteTrackQueue(in: items, selecting: 0))
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        model.configureFavoriteObservations(actions, knownFavorites: true)
        await model.load(.initial) { _ in FoundationPage(items: [hidden], nextStartIndex: 1) }
        XCTAssertTrue(actions.favoriteItems(in: model.items).isEmpty)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.nextStartIndex, 1)
        await model.loadNextPage { offset in
            XCTAssertEqual(offset, 1)
            return FoundationPage(items: [track], nextStartIndex: nil)
        }
        XCTAssertEqual(actions.favoriteItems(in: model.items).map(\.id), ["same"])
        XCTAssertEqual(model.items.count, 2)
    }

    func testFavoriteFailureKeepsInitialStateWithoutRetry() async {
        let gate = MutationGate()
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in
                await gate.countCall()
                throw Failure.synthetic
            })
        await actions.setFavorite(for: album, isFavorite: true)
        XCTAssertEqual(actions.favoriteState(for: album, initial: false), false)
        XCTAssertNotNil(actions.errorMessage(for: album))
        XCTAssertFalse(actions.isPending(album))
        XCTAssertEqual(actions.favoriteRevision, 0)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
    }

    func testFavoriteMembershipHydratesRelatedAlbumWithoutOverwritingMutation() async {
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        XCTAssertNil(actions.favoriteState(for: album, initial: nil))
        actions.observeFavorites(
            in: [album], knownFavorites: true, read: actions.beginFavoriteRead())
        XCTAssertEqual(actions.favoriteState(for: album, initial: nil), true)
        XCTAssertEqual(actions.favoriteRevision, 0)
        let staleRead = actions.beginFavoriteRead()
        await actions.setFavorite(for: album, isFavorite: false)
        actions.observeFavorites(in: [album], knownFavorites: true, read: staleRead)
        var stale = album
        stale.isFavorite = true
        actions.observeFavorites(in: [stale], read: staleRead)
        XCTAssertEqual(actions.favoriteState(for: album, initial: true), false)
        XCTAssertEqual(actions.favoriteRevision, 1)
    }

    func testAuthoritativeReadReconcilesMutationAndRejectsOlderResponses() async {
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        for mutatedValue in [true, false] {
            let beforeMutation = actions.beginFavoriteRead()
            await actions.setFavorite(for: album, isFavorite: mutatedValue)
            var external = album
            external.isFavorite = !mutatedValue
            actions.observeFavorites(in: [external], read: beforeMutation)
            XCTAssertEqual(actions.favoriteState(for: album, initial: nil), mutatedValue)
            let older = actions.beginFavoriteRead()
            let newer = actions.beginFavoriteRead()
            actions.observeFavorites(in: [external], read: newer)
            XCTAssertEqual(actions.favoriteState(for: album, initial: nil), !mutatedValue)
            external.isFavorite = mutatedValue
            actions.observeFavorites(in: [external], read: older)
            XCTAssertEqual(actions.favoriteState(for: album, initial: nil), !mutatedValue)
        }
        XCTAssertEqual(actions.favoriteRevision, 2)
    }

    func testReadsStartedDuringMutationCannotUndoSuccess() async {
        let gate = MutationGate()
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in await gate.hold() })
        let item = album
        let mutation = Task { await actions.setFavorite(for: item, isFavorite: true) }
        await gate.waitUntilStarted()
        let duringMutation = actions.beginFavoriteRead()
        var external = album
        external.isFavorite = false
        actions.observeFavorites(in: [external], read: duringMutation)
        XCTAssertNil(actions.favoriteState(for: album, initial: nil))
        await gate.release()
        await mutation.value
        actions.observeFavorites(in: [external], read: duringMutation)
        XCTAssertEqual(actions.favoriteState(for: album, initial: nil), true)
        actions.observeFavorites(in: [external], read: actions.beginFavoriteRead())
        XCTAssertEqual(actions.favoriteState(for: album, initial: nil), false)
    }

    func testReadOwnershipAndUnknownMetadataPreserveState() async {
        let old = FoundationLibraryActions(
            sourceScope: "old", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        let actions = FoundationLibraryActions(
            sourceScope: "new", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        await actions.setFavorite(for: album, isFavorite: false)
        actions.observeFavorites(in: [album], knownFavorites: true, read: old.beginFavoriteRead())
        actions.observeFavorites(in: [album], read: actions.beginFavoriteRead())
        actions.observeFavorites(in: [], knownFavorites: true, read: actions.beginFavoriteRead())
        XCTAssertEqual(actions.favoriteState(for: album, initial: nil), false)
        let read = actions.beginFavoriteRead()
        actions.invalidate()
        actions.observeFavorites(in: [album], knownFavorites: true, read: read)
        XCTAssertEqual(actions.favoriteState(for: album, initial: nil), false)
    }

    func testFavoriteFailureAllowsAuthoritativeRefreshAndExplicitRetry() async {
        let gate = MutationGate()
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in
                await gate.countCall()
                if await gate.calls == 1 { throw Failure.synthetic }
            })
        await actions.setFavorite(for: album, isFavorite: true)
        XCTAssertNotNil(actions.errorMessage(for: album))
        actions.observeFavorites(
            in: [album], knownFavorites: true, read: actions.beginFavoriteRead())
        XCTAssertEqual(actions.favoriteState(for: album, initial: nil), true)
        await actions.setFavorite(for: album, isFavorite: false)
        XCTAssertNil(actions.errorMessage(for: album))
        XCTAssertEqual(actions.favoriteState(for: album, initial: nil), false)
        let calls = await gate.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(actions.favoriteRevision, 1)
    }

    func testBrowseRefreshPublishesFavoriteMetadataEvenWhenRowsAreUnchanged() async {
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        let model = FoundationBrowseModel()
        model.configureFavoriteObservations(actions, knownFavorites: true)
        let item = album
        await model.load(.initial) { _ in FoundationPage(items: [item], nextStartIndex: nil) }
        await actions.setFavorite(for: album, isFavorite: false)
        await model.load(.refresh) { _ in FoundationPage(items: [item], nextStartIndex: nil) }
        XCTAssertEqual(actions.favoriteState(for: album, initial: nil), true)
        XCTAssertEqual(actions.favoriteRevision, 1)
        model.installSnapshot([item])
        await actions.setFavorite(for: album, isFavorite: false)
        await model.loadPending(allowsNetwork: false) { _ in
            XCTFail("An offline retained snapshot must not fetch or reconcile favorites")
            return FoundationPage(items: [item], nextStartIndex: nil)
        }
        XCTAssertEqual(actions.favoriteState(for: album, initial: nil), false)
    }

    func testSupersededAndCancelledBrowsePagesCannotPublishFavoriteMetadata() async {
        for cancels in [false, true] {
            let gate = MutationGate()
            let actions = FoundationLibraryActions(
                sourceScope: "source", read: { _ in nil }, write: { _, _ in },
                mutateFavorite: { _, _ in })
            let model = FoundationBrowseModel()
            model.configureFavoriteObservations(actions, knownFavorites: true)
            let item = album
            let task = Task {
                await model.load(.initial) { _ in
                    await gate.hold()
                    return FoundationPage(items: [item], nextStartIndex: nil)
                }
            }
            await gate.waitUntilStarted()
            if cancels { task.cancel() } else { model.request(.refresh) }
            await gate.release()
            await task.value
            XCTAssertTrue(model.items.isEmpty)
            XCTAssertNil(actions.favoriteState(for: album, initial: nil))
        }
    }

    func testCompleteFavoritesRefreshReconcilesMissingRowsOnlyAfterFinalPage() async {
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        let model = FoundationBrowseModel()
        model.configureFavoriteObservations(actions, knownFavorites: true)
        let item = album
        let other = FoundationItem(
            id: "other", title: "Other", subtitle: "", kind: .album, duration: nil)
        await model.load(.initial) { _ in FoundationPage(items: [item], nextStartIndex: nil) }
        await model.load(.refresh) { _ in FoundationPage(items: [other], nextStartIndex: 1) }
        XCTAssertEqual(actions.favoriteState(for: album, initial: nil), true)
        await model.loadNextPage { offset in
            XCTAssertEqual(offset, 1)
            return FoundationPage(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(actions.favoriteState(for: album, initial: nil), false)
        XCTAssertEqual(actions.favoriteState(for: other, initial: nil), true)
        XCTAssertEqual(actions.favoriteRevision, 0)
    }

    func testCompleteEmptyFavoritesRefreshReconcilesPreviousMembership() async {
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        let model = FoundationBrowseModel()
        model.configureFavoriteObservations(actions, knownFavorites: true)
        let item = album
        await model.load(.initial) { _ in FoundationPage(items: [item], nextStartIndex: nil) }
        await model.load(.refresh) { _ in FoundationPage(items: [], nextStartIndex: nil) }
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(actions.favoriteState(for: album, initial: nil), false)
        XCTAssertEqual(actions.favoriteRevision, 0)
    }

    func testIncompleteFavoritesRefreshCannotUndoLaterMutationOrAccountScopeReset() async {
        for resetsScope in [false, true] {
            let actions = FoundationLibraryActions(
                sourceScope: "source", read: { _ in nil }, write: { _, _ in },
                mutateFavorite: { _, _ in })
            let model = FoundationBrowseModel()
            model.configureCatalogPagination()
            model.configureFavoriteObservations(actions, knownFavorites: true)
            let item = album
            let other = FoundationItem(
                id: "other", title: "Other", subtitle: "", kind: .album, duration: nil)
            await model.load(.initial) { _ in FoundationPage(items: [item], nextStartIndex: nil) }
            await model.load(.refresh) { _ in FoundationPage(items: [other], nextStartIndex: 1) }
            if resetsScope {
                model.clearRetainedData()
                await model.load(.initial) { _ in FoundationPage(items: [], nextStartIndex: nil) }
            } else {
                await actions.setFavorite(for: album, isFavorite: true)
                await model.loadNextPage { _ in FoundationPage(items: [], nextStartIndex: nil) }
            }
            XCTAssertEqual(actions.favoriteState(for: album, initial: nil), true)
        }
    }

    func testRelatedArtistHydratesSharedStateAndKnownStateSkipsAnotherRead() async throws {
        var source = album
        source.artist = .init(id: "artist", title: "Artist", primaryImageTag: nil)
        let artist = try XCTUnwrap(source.relatedArtist)
        XCTAssertNil(artist.isFavorite)
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        var detail = artist
        detail.isFavorite = false
        let response = detail
        await actions.resolveFavorite(for: artist) { response }
        XCTAssertEqual(actions.favoriteState(for: artist, initial: nil), false)
        await actions.resolveFavorite(for: artist) {
            XCTFail("Known shared artist state must not trigger another detail read")
            return nil
        }
    }

    func testCollectionDetailHydrationPreservesUnknownAndExplicitFalse() async {
        let artist = FoundationItem(
            id: "artist", title: "Artist", subtitle: "", kind: .artist, duration: nil)
        for item in [album, artist] {
            for state: Bool? in [nil, false, true] {
                let actions = FoundationLibraryActions(
                    sourceScope: "source", read: { _ in nil }, write: { _, _ in },
                    mutateFavorite: { _, _ in })
                var detail = item
                detail.isFavorite = state
                let response = detail
                await actions.resolveFavorite(for: item) { response }
                XCTAssertEqual(actions.favoriteState(for: item, initial: nil), state)
                XCTAssertEqual(actions.favoriteRevision, 0)
            }
        }
    }

    func testLateCollectionDetailCannotOverwriteMutationOrNewObservation() async {
        let artist = FoundationItem(
            id: "artist", title: "Artist", subtitle: "", kind: .artist, duration: nil)
        for item in [album, artist] {
            for mutates in [false, true] {
                let gate = MutationGate()
                let actions = FoundationLibraryActions(
                    sourceScope: "source", read: { _ in nil }, write: { _, _ in },
                    mutateFavorite: { _, _ in })
                var detail = item
                detail.isFavorite = false
                let response = detail
                let task = Task {
                    await actions.resolveFavorite(for: item) {
                        await gate.hold()
                        return response
                    }
                }
                await gate.waitUntilStarted()
                if mutates {
                    await actions.setFavorite(for: item, isFavorite: true)
                } else {
                    actions.observeFavorites(
                        in: [item], knownFavorites: true, read: actions.beginFavoriteRead())
                }
                await gate.release()
                await task.value
                XCTAssertEqual(actions.favoriteState(for: item, initial: nil), true)
            }
        }
    }

    func testCollectionDetailCancellationAndAccountInvalidationDiscardLateMetadata() async {
        let artist = FoundationItem(
            id: "artist", title: "Artist", subtitle: "", kind: .artist, duration: nil)
        for item in [album, artist] {
            for invalidates in [false, true] {
                let gate = MutationGate()
                let actions = FoundationLibraryActions(
                    sourceScope: "source", read: { _ in nil }, write: { _, _ in },
                    mutateFavorite: { _, _ in })
                var detail = item
                detail.isFavorite = true
                let response = detail
                let task = Task {
                    await actions.resolveFavorite(for: item) {
                        await gate.hold()
                        return response
                    }
                }
                await gate.waitUntilStarted()
                if invalidates { actions.invalidate() } else { task.cancel() }
                await gate.release()
                await task.value
                actions.observeFavorites(in: [], read: actions.beginFavoriteRead())
                XCTAssertNil(actions.favoriteState(for: item, initial: nil))
            }
        }
    }

    func testCollectionDetailReadUsesCanonicalIDAndPreservesFavoriteMetadata() async throws {
        for (kind, serverType) in [
            (FoundationItem.Kind.album, "MusicAlbum"), (.artist, "MusicArtist"),
        ] {
            let item = FoundationItem(
                id: "00000000000000000000000000000002", title: "Album", subtitle: "",
                kind: kind, duration: nil)
            let session = FoundationSession(
                serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic",
                userID: "00000000000000000000000000000001", deviceID: "synthetic")
            let library = FoundationJellyfinLibrary(session: session) { request in
                XCTAssertTrue(request.url!.path.hasSuffix("/Items/" + item.id))
                let body = """
                    {"Id":"00000000000000000000000000000002","Type":"\(serverType)","UserData":{"Key":"synthetic-key","IsFavorite":true}}
                    """
                return (
                    Data(body.utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            let result = try await library.itemDetails(for: item)
            XCTAssertEqual(result?.id, item.id)
            XCTAssertEqual(result?.isFavorite, true)
        }
    }

    func testPendingFavoriteDeduplicatesAndPublishesOnlyAfterSuccess() async {
        let gate = MutationGate()
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in await gate.hold() })
        let item = album
        let task = Task { await actions.setFavorite(for: item, isFavorite: true) }
        await gate.waitUntilStarted()
        XCTAssertTrue(actions.isPending(item))
        XCTAssertEqual(actions.favoriteState(for: item, initial: false), false)
        await actions.setFavorite(for: item, isFavorite: false)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        await gate.release()
        await task.value
        XCTAssertEqual(actions.favoriteState(for: item, initial: false), true)
        XCTAssertFalse(actions.isPending(item))
        XCTAssertEqual(actions.favoriteRevision, 1)
    }

    func testSourceInvalidationDiscardsLateFavoriteCompletion() async {
        let gate = MutationGate()
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in await gate.hold() })
        let item = album
        let task = Task { await actions.setFavorite(for: item, isFavorite: true) }
        await gate.waitUntilStarted()
        actions.invalidate()
        await gate.release()
        await task.value
        XCTAssertEqual(actions.favoriteState(for: item, initial: false), false)
        XCTAssertEqual(actions.favoriteRevision, 0)
        XCTAssertNil(actions.errorMessage(for: item))
        XCTAssertFalse(actions.isPending(item))
    }

    func testSourceInvalidationCancelsUnderlyingFavoriteOperation() async {
        let gate = CancellationGate()
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in await gate.holdUntilCancelled() })
        let item = album
        let task = Task { await actions.setFavorite(for: item, isFavorite: true) }
        await gate.waitUntilStarted()
        XCTAssertTrue(actions.isPending(item))
        actions.invalidate()
        await gate.waitUntilCancelled()
        await task.value
        XCTAssertFalse(actions.isPending(item))
        XCTAssertEqual(actions.favoriteState(for: item, initial: false), false)
        XCTAssertEqual(actions.favoriteRevision, 0)
        XCTAssertNil(actions.errorMessage(for: item))
    }

    func testCallerCancellationCancelsUnderlyingFavoriteOperation() async {
        let gate = CancellationGate()
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in await gate.holdUntilCancelled() })
        let item = album
        let task = Task { await actions.setFavorite(for: item, isFavorite: true) }
        await gate.waitUntilStarted()
        XCTAssertTrue(actions.isPending(item))
        task.cancel()
        await gate.waitUntilCancelled()
        await task.value
        XCTAssertFalse(actions.isPending(item))
        XCTAssertEqual(actions.favoriteState(for: item, initial: false), false)
        XCTAssertEqual(actions.favoriteRevision, 0)
        XCTAssertNil(actions.errorMessage(for: item))
    }

    /// Only the actual provider task's cancellation handler can release this gate.
    private actor CancellationGate {
        private var didStart = false
        private var didCancel = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var cancelWaiter: CheckedContinuation<Void, Never>?
        private var held: CheckedContinuation<Void, Never>?

        func holdUntilCancelled() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    didStart = true
                    startWaiter?.resume()
                    startWaiter = nil
                    if didCancel { continuation.resume() } else { held = continuation }
                }
            } onCancel: {
                Task { await self.observeCancellation() }
            }
        }

        func waitUntilStarted() async {
            if didStart { return }
            await withCheckedContinuation { startWaiter = $0 }
        }

        func waitUntilCancelled() async {
            if didCancel { return }
            await withCheckedContinuation { cancelWaiter = $0 }
        }

        private func observeCancellation() {
            didCancel = true
            held?.resume()
            held = nil
            cancelWaiter?.resume()
            cancelWaiter = nil
        }
    }

    private enum Failure: Error { case synthetic }

    private actor MutationGate {
        private(set) var calls = 0
        private var started: CheckedContinuation<Void, Never>?
        private var held: CheckedContinuation<Void, Never>?

        func countCall() { calls += 1 }

        func hold() async {
            calls += 1
            await withCheckedContinuation { continuation in
                held = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if held != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func release() {
            held?.resume()
            held = nil
        }
    }
}

private func selfContainedResponse(_ request: URLRequest, items: String) -> (Data, HTTPURLResponse)
{
    let count = items.isEmpty ? 0 : 1
    return (
        Data("{\"Items\":[\(items)],\"StartIndex\":0,\"TotalRecordCount\":\(count)}".utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
}
