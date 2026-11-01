#if os(iOS)
    import Intents
    import XCTest

    @testable import VelacantoFoundation

    @MainActor
    final class FoundationSiriTests: XCTestCase {
        private func withAuthorizationDefaults(_ body: (UserDefaults) -> Void) throws {
            let suite = "FoundationSiriStartupTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            body(defaults)
        }

        func testStartupAuthorizationNeverRequestsForDecidedOrRestrictedOSStatus() throws {
            for status: INSiriAuthorizationStatus in [.authorized, .denied, .restricted] {
                try withAuthorizationDefaults { defaults in
                    let owner = FoundationSiriStartupAuthorization(
                        defaults: defaults, status: { status },
                        request: { _ in XCTFail("The OS permission decision must be respected") },
                        notify: {})
                    owner.foreground(isActive: true)
                    XCTAssertFalse(
                        defaults.bool(forKey: FoundationSiriStartupAuthorization.requestedKey))
                }
            }
        }

        func testStartupAuthorizationRequestsOnceAcrossReentryAndOwnerRecreation() throws {
            try withAuthorizationDefaults { defaults in
                var requests = 0
                var completion: (@MainActor @Sendable (INSiriAuthorizationStatus) -> Void)?
                let owner = FoundationSiriStartupAuthorization(
                    defaults: defaults, status: { .notDetermined },
                    request: { callback in
                        XCTAssertTrue(
                            defaults.bool(forKey: FoundationSiriStartupAuthorization.requestedKey))
                        requests += 1
                        completion = callback
                    }, notify: {})
                owner.foreground(isActive: true)
                owner.foreground(isActive: true)
                XCTAssertEqual(requests, 1, "An outstanding request must not be duplicated")
                completion?(.notDetermined)
                owner.foreground(isActive: true)
                let recreated = FoundationSiriStartupAuthorization(
                    defaults: defaults, status: { .notDetermined },
                    request: { _ in requests += 1 }, notify: {})
                recreated.foreground(isActive: true)
                XCTAssertEqual(
                    requests, 1, "A prior attempt must not be repeated on another launch")
            }
        }

        func testStartupAuthorizationDefersWhileInactiveOrAccountAlertIsPresented() throws {
            try withAuthorizationDefaults { defaults in
                var requests = 0
                let owner = FoundationSiriStartupAuthorization(
                    defaults: defaults, status: { .notDetermined },
                    request: { _ in requests += 1 }, notify: {})
                owner.foreground(isActive: false)
                owner.foreground(isActive: true, canPrompt: false)
                XCTAssertEqual(requests, 0)
                XCTAssertFalse(
                    defaults.bool(forKey: FoundationSiriStartupAuthorization.requestedKey))
                owner.foreground(isActive: true)
                XCTAssertEqual(requests, 1)
            }
        }

        func testStartupAuthorizationDisabledHostNeverRequestsOrRecordsHistory() throws {
            try withAuthorizationDefaults { defaults in
                let owner = FoundationSiriStartupAuthorization(
                    defaults: defaults,
                    status: {
                        XCTFail("Disabled hosts must not query entitlement-protected Siri status")
                        return .notDetermined
                    },
                    request: { _ in XCTFail("Unit test hosts must not request system permission") },
                    notify: {}, requestsAllowed: { false })
                owner.foreground(isActive: true)
                XCTAssertFalse(
                    defaults.bool(forKey: FoundationSiriStartupAuthorization.requestedKey))
            }
        }

        func testStartupAuthorizationPublishesCompletionUsingCurrentOSStatus() throws {
            try withAuthorizationDefaults { defaults in
                var status = INSiriAuthorizationStatus.notDetermined
                var notifications = 0
                var completion: (@MainActor @Sendable (INSiriAuthorizationStatus) -> Void)?
                let owner = FoundationSiriStartupAuthorization(
                    defaults: defaults, status: { status }, request: { completion = $0 },
                    notify: { notifications += 1 })
                owner.foreground(isActive: true)
                status = .denied
                completion?(.authorized)
                XCTAssertEqual(notifications, 1)
                owner.foreground(isActive: true)
                XCTAssertEqual(notifications, 1, "Unchanged OS status needs no notification")
            }
        }

        func testStartupAuthorizationRefreshesChangesFromSettingsWithoutReprompting() throws {
            try withAuthorizationDefaults { defaults in
                var status = INSiriAuthorizationStatus.denied
                var notifications = 0
                let owner = FoundationSiriStartupAuthorization(
                    defaults: defaults, status: { status },
                    request: { _ in XCTFail("Settings changes must not request authorization") },
                    notify: { notifications += 1 })
                status = .authorized
                owner.foreground(isActive: false)
                XCTAssertEqual(notifications, 0)
                owner.foreground(isActive: true, canPrompt: false)
                XCTAssertEqual(notifications, 1)
                owner.foreground(isActive: true)
                XCTAssertEqual(notifications, 1)
                status = .denied
                owner.foreground(isActive: true)
                XCTAssertEqual(notifications, 2)
            }
        }

        private func intent(
            title: String? = "Synthetic Song", type: INMediaItemType = .song,
            resume: Bool = false, location: INPlaybackQueueLocation = .now,
            repeatMode: INPlaybackRepeatMode = .unknown, mediaSearch: INMediaSearch? = nil
        ) -> INPlayMediaIntent {
            INPlayMediaIntent(
                mediaItems: title.map {
                    [
                        INMediaItem(
                            identifier: "untrusted-old-account-id", title: $0, type: type,
                            artwork: nil)
                    ]
                },
                mediaContainer: nil, playShuffled: false, playbackRepeatMode: repeatMode,
                resumePlayback: resume, playbackQueueLocation: location, playbackSpeed: nil,
                mediaSearch: mediaSearch)
        }

        private func item(
            _ id: String, title: String = "Synthetic Song", kind: FoundationItem.Kind = .track
        ) -> FoundationItem {
            .init(id: id, title: title, subtitle: "Synthetic Artist", kind: kind, duration: nil)
        }

        func testKnownSiriKindPerformsOneProtectedDirectReadAndNoRelationships() async throws {
            let requested = try XCTUnwrap(FoundationSiriRequest(intent: intent()))
            let library = SiriDirectLibrary(pages: [
                .track: .init(items: [item("real")], nextStartIndex: nil)
            ])
            let snapshot = try await FoundationSiriCatalog.resolve(
                request: requested, library: library, localOnly: false)
            XCTAssertEqual(snapshot.outcome, .unique)
            XCTAssertEqual(snapshot.prompt, .accept)
            XCTAssertEqual(snapshot.matches.map(\.id), ["real"])
            let calls = await library.calls
            XCTAssertEqual(calls, [.init(kind: .track, offset: 0, limit: 50, protected: true)])
            let relationships = await library.relationshipCalls
            XCTAssertEqual(relationships, 0)
            XCTAssertFalse(FoundationRequestIntent.isPlayback)
        }

        func testUnknownMusicKindUsesOnlyFourBoundedDirectReads() async throws {
            let requested = try XCTUnwrap(FoundationSiriRequest(intent: intent(type: .music)))
            let library = SiriDirectLibrary(pages: [
                .track: .init(items: [item("real")], nextStartIndex: nil)
            ])
            let snapshot = try await FoundationSiriCatalog.resolve(
                request: requested, library: library, localOnly: false)
            XCTAssertEqual(snapshot.outcome, .unique)
            let calls = await library.calls
            XCTAssertEqual(Set(calls.map(\.kind)), Set([.track, .album, .artist, .playlist]))
            XCTAssertEqual(calls.count, 4)
            XCTAssertTrue(calls.allSatisfy { $0.offset == 0 && $0.limit == 50 && $0.protected })
            let relationships = await library.relationshipCalls
            XCTAssertEqual(relationships, 0)
        }

        func testLocalSiriLookupNeverContactsProviderAndRespectsProjection() async throws {
            let requested = try XCTUnwrap(FoundationSiriRequest(intent: intent()))
            let library = SiriDirectLibrary(pages: [:])
            let snapshot = try await FoundationSiriCatalog.resolve(
                request: requested, library: library,
                localOnly: true, localItems: [item("ready"), item("hidden-copy")],
                project: { $0.filter { $0.id != "hidden-copy" } })
            XCTAssertEqual(snapshot.matches.map(\.id), ["ready"])
            XCTAssertEqual(snapshot.outcome, .unique)
            let calls = await library.calls
            XCTAssertTrue(calls.isEmpty)
        }

        func testSpokenPunctuationWhitespaceAndAccentsMatchButFuzzyNamesDoNot() throws {
            let requested = try XCTUnwrap(
                FoundationSiriRequest(intent: intent(title: "  SYNTHÉTIC—Song!  ")))
            let snapshot = FoundationSiriCatalog.match(
                request: requested, items: [item("real")], incomplete: false)
            XCTAssertEqual(snapshot.outcome, .unique)
            let typo = FoundationSiriCatalog.match(
                request: requested, items: [item("typo", title: "Synthetic Sung")],
                incomplete: false)
            XCTAssertEqual(typo.outcome, .titleMismatch)
            XCTAssertTrue(typo.matches.isEmpty)
            XCTAssertNil(FoundationSiriRequest(intent: intent(title: "?!")))
        }

        func testSiriDistinguishesEmptyWrongKindTitleArtistAndAlbumFailures() throws {
            let search = INMediaSearch(
                mediaType: .song, sortOrder: .unknown, mediaName: "Synthetic Song",
                artistName: "Desired Artist", albumName: "Desired Album", genreNames: nil,
                moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil)
            let requested = try XCTUnwrap(
                FoundationSiriRequest(intent: intent(title: nil, mediaSearch: search)))
            func snapshot(_ items: [FoundationItem]) -> FoundationSiriCatalog.Snapshot {
                FoundationSiriCatalog.match(request: requested, items: items, incomplete: false)
            }
            XCTAssertEqual(snapshot([]).outcome, .empty)
            XCTAssertEqual(snapshot([item("wrong-kind", kind: .album)]).outcome, .kindMismatch)
            XCTAssertEqual(
                snapshot([item("wrong-title", title: "Other Song")]).outcome, .titleMismatch)
            let wrongArtist = snapshot([item("wrong-artist")])
            XCTAssertEqual(wrongArtist.outcome, .artistMismatch)
            XCTAssertEqual(
                [
                    wrongArtist.candidateCount, wrongArtist.kindCount, wrongArtist.titleCount,
                    wrongArtist.artistCount,
                ], [1, 1, 1, 0])
            var wrongAlbum = item("wrong-album")
            wrongAlbum.artist = .init(id: "artist", title: "Desired Artist")
            XCTAssertEqual(snapshot([wrongAlbum]).outcome, .albumMismatch)
            wrongAlbum.album = .init(id: "album", title: "Desired Album")
            XCTAssertEqual(snapshot([wrongAlbum]).outcome, .unique)
        }

        func testGenuineDuplicateTitlesRequireDisambiguationAndOfferAtMostFive() throws {
            let requested = try XCTUnwrap(FoundationSiriRequest(intent: intent()))
            let two = FoundationSiriCatalog.match(
                request: requested,
                items: [item("first"), item("second"), item("first")], incomplete: false)
            XCTAssertEqual(two.outcome, .ambiguous)
            XCTAssertEqual(two.prompt, .choose)
            XCTAssertEqual(two.offeredMatches.map(\.id), ["first", "second"])
            let many = FoundationSiriCatalog.match(
                request: requested,
                items: (0..<8).map { item("actual-\($0)") }, incomplete: false)
            XCTAssertEqual(many.outcome, .tooMany)
            XCTAssertEqual(many.prompt, .choose)
            XCTAssertEqual(many.matches.count, 8)
            XCTAssertEqual(many.offeredMatches.count, 5)
        }

        func testIncompleteDirectPageRequiresConfirmationInsteadOfClaimingUnique() async throws {
            let requested = try XCTUnwrap(FoundationSiriRequest(intent: intent()))
            let library = SiriDirectLibrary(pages: [
                .track: .init(items: [item("known")], nextStartIndex: 50)
            ])
            let snapshot = try await FoundationSiriCatalog.resolve(
                request: requested, library: library, localOnly: false)
            XCTAssertEqual(snapshot.outcome, .incomplete)
            XCTAssertEqual(snapshot.prompt, .confirm)
            XCTAssertEqual(snapshot.offeredMatches.map(\.id), ["known"])
            let calls = await library.calls
            XCTAssertEqual(calls.count, 1)
            let noMatch = FoundationSiriCatalog.match(
                request: requested, items: [], incomplete: true)
            XCTAssertEqual(noMatch.prompt, .refine)
        }

        func testUnknownKindPartialFailureOffersRealMatchOnlyAfterConfirmation() async throws {
            let requested = try XCTUnwrap(FoundationSiriRequest(intent: intent(type: .music)))
            let library = SiriDirectLibrary(
                pages: [.track: .init(items: [item("actual")], nextStartIndex: nil)],
                failKinds: [.album])
            let snapshot = try await FoundationSiriCatalog.resolve(
                request: requested, library: library, localOnly: false)
            XCTAssertEqual(snapshot.matches.map(\.id), ["actual"])
            XCTAssertEqual(snapshot.outcome, .incomplete)
            XCTAssertEqual(snapshot.prompt, .confirm)
            XCTAssertEqual(snapshot.failedKindCount, 1)
            let calls = await library.calls
            XCTAssertEqual(calls.count, 4)
        }

        func testEveryDisambiguationChoiceRejectsTheSameNewUserCommand() throws {
            let player = FoundationPlayer(resolve: { _ in throw CancellationError() })
            let actions = FoundationLibraryActions(
                sourceScope: "synthetic", read: { _ in nil }, write: { _, _ in },
                mutateFavorite: { _, _ in })
            var cancellations = 0
            let commandGuard = FoundationSiriCommandGuard(player: player) { cancellations += 1 }
            let owner = UUID()
            let now = Date(timeIntervalSince1970: 1000)
            let choices = ["one", "two"].map {
                FoundationSiriResolvedMedia(
                    item: item($0), player: player, actions: actions,
                    scope: "scope", localOnly: false, now: now, resolutionID: owner,
                    commandGuard: commandGuard)
            }
            XCTAssertEqual(Set(choices.map(\.identifier)).count, 2)
            XCTAssertTrue(choices.allSatisfy { $0.resolutionID == owner })
            player.pause()
            XCTAssertEqual(cancellations, 1)
            XCTAssertTrue(
                choices.allSatisfy {
                    !$0.accepts(
                        identifier: $0.identifier, player: player, actions: actions, scope: "scope",
                        localOnly: false, now: now)
                })
        }

        func testDirectProviderFailureAndCancellationCannotBecomeUniquePlayback() async throws {
            let requested = try XCTUnwrap(FoundationSiriRequest(intent: intent()))
            for cancellation in [false, true] {
                let library = SiriDirectLibrary(pages: [:], fail: true, cancellation: cancellation)
                do {
                    _ = try await FoundationSiriCatalog.resolve(
                        request: requested, library: library, localOnly: false)
                    XCTFail("Provider failure must not produce a playable snapshot")
                } catch {
                    XCTAssertEqual(error is CancellationError, cancellation)
                }
            }
        }

        func testRequiredMediaResolutionSelectorIsImplementedByMainAppHandler() {
            let handler = FoundationSiriPlayback(authorized: { false })
            XCTAssertTrue(
                handler.responds(
                    to: NSSelectorFromString("resolveMediaItemsForPlayMedia:withCompletion:")))
            var resolutions = 0
            handler.resolveMediaItems(for: intent()) { result in
                resolutions += 1
                XCTAssertEqual(result.count, 1)
            }
            XCTAssertEqual(resolutions, 1)
        }

        func testSiriNoRepeatValueAndNamedMediaSearchAreAccepted() throws {
            for type in [INMediaItemType.song, .album, .artist] {
                let search = INMediaSearch(
                    mediaType: type, sortOrder: .unknown, mediaName: "Synthetic Name",
                    artistName: nil, albumName: nil, genreNames: nil, moodNames: nil,
                    releaseDate: nil, reference: .unknown, mediaIdentifier: nil)
                let request = try XCTUnwrap(
                    FoundationSiriRequest(
                        intent: intent(title: nil, repeatMode: .none, mediaSearch: search)))
                XCTAssertEqual(request.query, "Synthetic Name")
                XCTAssertEqual(
                    request.kind, type == .song ? .track : type == .album ? .album : .artist)
            }
        }

        func testNoRepeatArtistOnlyAndAlbumOnlySpokenSearchShapesAreAccepted() throws {
            for isAlbum in [false, true] {
                let search = INMediaSearch(
                    mediaType: .music, sortOrder: .unknown, mediaName: nil,
                    artistName: "Synthetic Artist", albumName: isAlbum ? "Synthetic Album" : nil,
                    genreNames: nil, moodNames: nil, releaseDate: nil, reference: .unknown,
                    mediaIdentifier: nil)
                let request = try XCTUnwrap(
                    FoundationSiriRequest(
                        intent: intent(title: nil, repeatMode: .none, mediaSearch: search)))
                XCTAssertEqual(request.query, isAlbum ? "Synthetic Album" : "Synthetic Artist")
                XCTAssertEqual(request.kind, isAlbum ? .album : .artist)
                let candidate = FoundationItem(
                    id: "actual", title: request.query,
                    subtitle: "Synthetic Artist", kind: isAlbum ? .album : .artist, duration: nil)
                XCTAssertEqual(request.uniqueMatch(in: [candidate])?.id, "actual")
            }
        }

        func testResolvedMediaUsesActualCatalogMetadataAndOpaqueAccountBoundIdentity() {
            let player = FoundationPlayer(resolve: { _ in throw CancellationError() })
            let otherPlayer = FoundationPlayer(resolve: { _ in throw CancellationError() })
            let actions = FoundationLibraryActions(
                sourceScope: "synthetic", read: { _ in nil }, write: { _, _ in },
                mutateFavorite: { _, _ in })
            let now = Date(timeIntervalSince1970: 1000)
            let resolved = FoundationSiriResolvedMedia(
                item: item("private-provider-id"), player: player, actions: actions,
                scope: "scope", localOnly: false, now: now)
            XCTAssertEqual(resolved.mediaItem.title, "Synthetic Song")
            XCTAssertEqual(resolved.mediaItem.type, .song)
            XCTAssertEqual(resolved.mediaItem.artist, "Synthetic Artist")
            XCTAssertTrue(
                resolved.identifier.hasPrefix(FoundationSiriResolvedMedia.identifierPrefix))
            XCTAssertFalse(resolved.identifier.contains("private-provider-id"))
            XCTAssertTrue(
                resolved.isCurrent(
                    player: player, actions: actions, scope: "scope", localOnly: false, now: now))
            XCTAssertFalse(
                resolved.isCurrent(
                    player: otherPlayer, actions: actions, scope: "scope", localOnly: false,
                    now: now))
            XCTAssertFalse(
                resolved.isCurrent(
                    player: player, actions: actions, scope: "new-scope", localOnly: false, now: now
                ))
            XCTAssertFalse(
                resolved.isCurrent(
                    player: player, actions: actions, scope: "scope", localOnly: true, now: now))
            XCTAssertFalse(
                resolved.isCurrent(
                    player: player, actions: actions, scope: "scope", localOnly: false,
                    now: now.addingTimeInterval(60)))
        }

        func testResolvedTokenRejectsPauseOrSelectionBeforeHandlingAndCancelsOnlyOnce() {
            for pause in [false, true] {
                let player = FoundationPlayer(resolve: { _ in throw CancellationError() })
                player.setQueue([item("prior")], selectedIndex: 0)
                let actions = FoundationLibraryActions(
                    sourceScope: "synthetic", read: { _ in nil }, write: { _, _ in },
                    mutateFavorite: { _, _ in })
                var cancellations = 0
                var guardState: FoundationSiriCommandGuard? = FoundationSiriCommandGuard(
                    player: player
                ) { cancellations += 1 }
                let now = Date(timeIntervalSince1970: 1000)
                let resolved = FoundationSiriResolvedMedia(
                    item: item("resolved"), player: player,
                    actions: actions, scope: "scope", localOnly: false, now: now,
                    commandGuard: guardState)
                // The resolved handoff itself must retain observation while Siri is speaking.
                guardState = nil
                XCTAssertTrue(
                    resolved.accepts(
                        identifier: resolved.identifier, player: player, actions: actions,
                        scope: "scope", localOnly: false, now: now))
                if pause {
                    player.pause()
                } else {
                    player.setQueue([item("new")], selectedIndex: 0)
                }
                XCTAssertFalse(
                    resolved.accepts(
                        identifier: resolved.identifier, player: player, actions: actions,
                        scope: "scope", localOnly: false, now: now))
                player.pause()
                XCTAssertEqual(cancellations, 1)
                player.stop()
            }
        }

        func testResolvedHandoffCanDisarmForItsOwnCommitButRejectsAnUnknownToken() {
            let player = FoundationPlayer(resolve: { _ in throw CancellationError() })
            let actions = FoundationLibraryActions(
                sourceScope: "synthetic", read: { _ in nil }, write: { _, _ in },
                mutateFavorite: { _, _ in })
            var cancellations = 0
            let guardState = FoundationSiriCommandGuard(player: player) { cancellations += 1 }
            let now = Date(timeIntervalSince1970: 1000)
            let resolved = FoundationSiriResolvedMedia(
                item: item("resolved"), player: player,
                actions: actions, scope: "scope", localOnly: false, now: now,
                commandGuard: guardState)
            XCTAssertFalse(
                resolved.accepts(
                    identifier: "unknown", player: player, actions: actions, scope: "scope",
                    localOnly: false, now: now))
            guardState.disarm()
            player.setQueue([resolved.item], selectedIndex: 0)
            XCTAssertEqual(cancellations, 0)
            XCTAssertTrue(
                resolved.accepts(
                    identifier: resolved.identifier, player: player, actions: actions,
                    scope: "scope", localOnly: false, now: now))
            player.stop()
        }

        func testEmptyAssistantPromptRequestsAValueWithoutCatalogWork() {
            let handler = FoundationSiriPlayback(authorized: { true })
            var replies = 0
            handler.resolveMediaItems(for: intent(title: nil)) { result in
                replies += 1
                XCTAssertEqual(result.count, 1)
            }
            XCTAssertEqual(replies, 1)
        }

        func testNewPauseAndSelectionInvalidatePendingSiriOwnershipOnce() {
            for pause in [false, true] {
                let player = FoundationPlayer(resolve: { _ in throw CancellationError() })
                player.setQueue([item("prior")], selectedIndex: 0)
                var cancellations = 0
                let guardState = FoundationSiriCommandGuard(player: player) { cancellations += 1 }
                if pause {
                    player.pause()
                } else {
                    player.setQueue([item("new")], selectedIndex: 0)
                }
                XCTAssertFalse(guardState.isCurrent)
                XCTAssertEqual(cancellations, 1)
                player.stop()
            }
        }

        func testDisarmedSiriGuardAllowsItsOwnQueueAndPlaybackCommands() {
            let player = FoundationPlayer(resolve: { _ in throw CancellationError() })
            var cancellations = 0
            let guardState = FoundationSiriCommandGuard(player: player) { cancellations += 1 }
            guardState.disarm()
            player.setQueue([item("own")], selectedIndex: 0)
            player.pause()
            XCTAssertTrue(guardState.isCurrent)
            XCTAssertEqual(cancellations, 0)
            player.stop()
        }

        func testExplicitPauseCancelsPendingSiriEvenWhenPlaybackWasAlreadyPaused() {
            let player = FoundationPlayer(resolve: { _ in throw CancellationError() })
            var cancellations = 0
            let guardState = FoundationSiriCommandGuard(player: player) { cancellations += 1 }
            XCTAssertTrue(guardState.isCurrent)
            player.pause()
            XCTAssertFalse(guardState.isCurrent)
            XCTAssertEqual(cancellations, 1)
            player.pause()
            XCTAssertEqual(cancellations, 1)
        }

        func testOldAccountIdentifierDoesNotSelectUnmatchedOrWrongKindMedia() throws {
            let request = try XCTUnwrap(FoundationSiriRequest(intent: intent()))
            XCTAssertNil(
                request.uniqueMatch(in: [item("untrusted-old-account-id", title: "Other Song")]))
            XCTAssertNil(request.uniqueMatch(in: [item("album", kind: .album)]))
            XCTAssertEqual(
                request.uniqueMatch(in: [item("current-account-song")])?.id, "current-account-song")
        }

        func testAmbiguousTitleFailsInsteadOfPlayingArbitraryResult() throws {
            let request = try XCTUnwrap(FoundationSiriRequest(intent: intent()))
            XCTAssertNil(request.uniqueMatch(in: [item("first"), item("second")]))
            XCTAssertEqual(request.uniqueMatch(in: [item("first"), item("first")])?.id, "first")
        }

        func testBoundedNormalizedTitleSupportsAccentsAndRejectsControlCharacters() throws {
            let request = try XCTUnwrap(
                FoundationSiriRequest(intent: intent(title: "  SYNTHÉTIC SONG  ")))
            XCTAssertEqual(request.uniqueMatch(in: [item("song")])?.id, "song")
            XCTAssertNil(FoundationSiriRequest(intent: intent(title: "bad\u{0000}query")))
            XCTAssertNil(
                FoundationSiriRequest(intent: intent(title: String(repeating: "x", count: 257))))
        }

        func testUnsupportedIntentTypesAndQueueMutationsAreRejected() {
            XCTAssertNil(FoundationSiriRequest(intent: intent(type: .podcastEpisode)))
            XCTAssertNil(FoundationSiriRequest(intent: intent(location: .next)))
            XCTAssertNil(FoundationSiriRequest(intent: intent(location: .later)))
            XCTAssertNil(FoundationSiriRequest(intent: intent(title: nil)))
            XCTAssertTrue(
                FoundationSiriRequest(intent: intent(title: nil, resume: true))?.resume == true)
        }

        func testDeniedAuthorizationCompletesBeforeLoadingAccountOrCatalog() {
            let handler = FoundationSiriPlayback(authorized: { false })
            var responses: [INPlayMediaIntentResponseCode] = []
            handler.handle(intent: intent()) { responses.append($0.code) }
            XCTAssertEqual(responses, [.failureRequiringAppLaunch])
        }
    }

    private actor SiriDirectLibrary: FoundationLibrary {
        struct Call: Equatable, Sendable {
            let kind: FoundationItem.Kind
            let offset: Int
            let limit: Int
            let protected: Bool
        }
        let pages: [FoundationItem.Kind: FoundationPage]
        let fail: Bool
        let failKinds: Set<FoundationItem.Kind>
        let cancellation: Bool
        private(set) var calls: [Call] = []
        private(set) var relationshipCalls = 0

        init(
            pages: [FoundationItem.Kind: FoundationPage], fail: Bool = false,
            cancellation: Bool = false, failKinds: Set<FoundationItem.Kind> = []
        ) {
            self.pages = pages
            self.fail = fail
            self.failKinds = failKinds
            self.cancellation = cancellation
        }
        func search(query: String, kind: FoundationItem.Kind, startIndex: Int, limit: Int)
            async throws -> FoundationPage
        {
            calls.append(
                .init(
                    kind: kind, offset: startIndex, limit: limit,
                    protected: FoundationRequestIntent.isPlayback))
            if cancellation { throw CancellationError() }
            if fail || failKinds.contains(kind) { throw FoundationLibraryError.network }
            return pages[kind] ?? .init(items: [], nextStartIndex: nil)
        }
        func albums(startIndex: Int) async throws -> FoundationPage {
            relationshipCalls += 1
            throw FoundationLibraryError.unavailable
        }
        func albums(artistID: String, startIndex: Int) async throws -> FoundationPage {
            relationshipCalls += 1
            throw FoundationLibraryError.unavailable
        }
        func tracks(albumID: String, startIndex: Int) async throws -> FoundationPage {
            relationshipCalls += 1
            throw FoundationLibraryError.unavailable
        }
        func mostPlayed(artistID: String) async throws -> FoundationPage {
            relationshipCalls += 1
            throw FoundationLibraryError.unavailable
        }
        func similarItems(for item: FoundationItem) async throws -> FoundationPage {
            relationshipCalls += 1
            throw FoundationLibraryError.unavailable
        }
        func playbackURL(for item: FoundationItem) async throws -> URL {
            throw FoundationLibraryError.unavailable
        }
    }
#endif
