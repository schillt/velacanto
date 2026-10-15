import XCTest

@testable import VelacantoFoundation

final class FoundationAlbumTrackPolicyTests: XCTestCase {
    func testSameAlbumDiscTrackAndNormalizedTitleKeepsFirstInStableOrder() {
        let first = item("first", title: "Éclair — Live", track: 2, disc: 1)
        let other = item("other", title: "Other Song", track: 3, disc: 1)
        let duplicate = item("duplicate", title: "eclair live", track: 2, disc: 1)
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleTracks(
                [first, other, duplicate], showDuplicates: false),
            [first, other])
    }

    func testSameTrackNumberOnDifferentDiscsOrAlbumsRemainsVisible() {
        let first = item("first", track: 1, disc: 1)
        let secondDisc = item("second-disc", track: 1, disc: 2)
        let otherAlbum = item("other-album", album: "another-album", track: 1, disc: 1)
        let tracks = [first, secondDisc, otherAlbum]
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleTracks(tracks, showDuplicates: false), tracks)
    }

    func testDifferentTitlesAndUnknownTrackOrDiscNumbersNeverCollapse() {
        let tracks = [
            item("original", title: "Song", track: 1),
            item("different", title: "Song (Live)", track: 1),
            item("untagged-a", track: nil), item("untagged-b", track: nil),
            item("zero-a", track: 0), item("zero-b", track: 0),
            item("invalid-disc-a", track: 2, disc: 0), item("invalid-disc-b", track: 2, disc: 0),
        ]
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleTracks(tracks, showDuplicates: false), tracks)
    }

    func testMissingDiscDefaultsToOneAndToggleRestoresOriginalItems() {
        let missing = item("missing", disc: nil)
        let explicit = item("explicit", disc: 1)
        let tracks = [missing, explicit]
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleTracks(tracks, showDuplicates: false), [missing])
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleTracks(tracks, showDuplicates: true), tracks)
    }

    func testExplicitAlbumContextOverridesItemReferencesWhileNilContextKeepsUnknownTracks() {
        let unknownA = item("unknown-a", album: nil)
        let unknownB = item("unknown-b", album: nil)
        let known = item("known", album: "other-album")
        let tracks = [unknownA, known, unknownB]
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleTracks(tracks, showDuplicates: false), tracks)
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleTracks(
                tracks, albumID: "context-album", showDuplicates: false),
            [unknownA])
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleTracks(
                [unknownA, unknownB], albumID: "", showDuplicates: false),
            [unknownA, unknownB])
    }

    func testFirstAvailableDuplicateReplacesRepresentativeWithoutMovingLogicalSlot() {
        let unavailable = item("unavailable", track: 1)
        let nextSlot = item("next-slot", title: "Other Song", track: 2)
        let ready = item("ready", track: 1)
        let laterReady = item("later-ready", track: 1)
        let tracks = [unavailable, nextSlot, ready, laterReady]
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleTracks(
                tracks, showDuplicates: false,
                isAvailable: { $0.id == "ready" || $0.id == "later-ready" }),
            [ready, nextSlot])
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleTracks(tracks, showDuplicates: false),
            [unavailable, nextSlot])
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleTracks(
                tracks, showDuplicates: true, isAvailable: { _ in false }),
            tracks)
    }

    func testPlaylistOccurrenceIdentityAndEmptyTitlesRemainUntouched() {
        var first = item("same-track")
        first.playlistEntryID = "occurrence-a"
        var repeated = first
        repeated.playlistEntryID = "occurrence-b"
        let unknownA = item("unknown-title-a", title: "")
        let unknownB = item("unknown-title-b", title: "")
        let tracks = [first, repeated, unknownA, unknownB]
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleTracks(tracks, showDuplicates: false), tracks)
    }

    @MainActor
    func testPreferenceIsPersistentAndPlaylistCollectionsHideAlternateCopies() throws {
        let suite = "synthetic-album-policy-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = FoundationPlaybackPreferences(defaults: defaults)
        let actions = FoundationLibraryActions(
            sourceScope: "synthetic", read: { _ in nil }, write: { _, _ in },
            showDuplicateAlbumTracks: { preferences.showDuplicateAlbumTracks },
            mutateFavorite: { _, _ in })
        let tracks = [item("first"), item("copy")]
        let album = FoundationItem(
            id: "album", title: "Album", subtitle: "", kind: .album, duration: nil)
        let playlist = FoundationItem(
            id: "playlist", title: "Playlist", subtitle: "", kind: .playlist, duration: nil)
        XCTAssertFalse(preferences.showDuplicateAlbumTracks)
        XCTAssertEqual(actions.collectionTracks(tracks, for: album), [tracks[0]])
        XCTAssertEqual(actions.collectionTracks(tracks, for: playlist), [tracks[0]])
        preferences.setShowDuplicateAlbumTracks(true)
        XCTAssertEqual(actions.collectionTracks(tracks, for: album), tracks)
        XCTAssertTrue(FoundationPlaybackPreferences(defaults: defaults).showDuplicateAlbumTracks)
        defaults.set(false, forKey: FoundationPlaybackPreferences.duplicateAlbumTracksKey)
        preferences.refresh()
        XCTAssertFalse(preferences.showDuplicateAlbumTracks)
    }

    func testTrackTagsSurviveDownloadRoundTripAndLegacyMetadataRemainsVisible() throws {
        let track = item("tagged", track: 4, disc: 2)
        let stored = FoundationStoredDownloadItem(track)
        let decoded = try JSONDecoder().decode(
            FoundationStoredDownloadItem.self, from: JSONEncoder().encode(stored))
        XCTAssertEqual(decoded.item.trackNumber, 4)
        XCTAssertEqual(decoded.item.discNumber, 2)
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        legacy.removeValue(forKey: "trackNumber")
        legacy.removeValue(forKey: "discNumber")
        let old = try JSONDecoder().decode(
            FoundationStoredDownloadItem.self, from: JSONSerialization.data(withJSONObject: legacy)
        ).item
        XCTAssertNil(old.trackNumber)
        XCTAssertNil(old.discNumber)
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleTracks([old, old], showDuplicates: false).count, 2)
    }

    func testServerAlbumTrackTagsAreMappedWithoutChangingProviderMembership() async throws {
        let library = FoundationJellyfinLibrary(
            session: FoundationSession(
                serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic",
                userID: "00000000000000000000000000000001", deviceID: "synthetic"),
            load: { request in
                let data = Data(
                    "{\"Items\":[{\"Id\":\"00000000000000000000000000000002\",\"Type\":\"Audio\",\"Name\":\"Synthetic\",\"IndexNumber\":4,\"ParentIndexNumber\":2}],\"StartIndex\":0,\"TotalRecordCount\":1}"
                        .utf8)
                return (
                    data,
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            })
        let page = try await library.tracks(
            albumID: "00000000000000000000000000000003", startIndex: 0)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.trackNumber, 4)
        XCTAssertEqual(page.items.first?.discNumber, 2)
    }

    @MainActor
    func testLearnedCopiesAreHiddenAcrossPagesAndManagementReadsAndRestoreWithoutFetch()
        async throws
    {
        let suite = "synthetic-global-duplicates-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = FoundationPlaybackPreferences(defaults: defaults)
        let actions = FoundationLibraryActions(
            sourceScope: "synthetic", read: { _ in nil }, write: { _, _ in },
            trackPreferences: preferences, mutateFavorite: { _, _ in })
        let first = item("canonical")
        let copy = item("copy")
        actions.observeTrackCopies([first])
        actions.observeTrackCopies([copy])
        XCTAssertTrue(actions.visibleTracks([copy]).isEmpty)
        XCTAssertEqual(actions.visibleTracks([copy, first]), [first])
        let model = FoundationBrowseModel()
        model.configureFavoriteObservations(actions)
        model.installSnapshot([copy, first])
        XCTAssertEqual(model.rawItems, [copy, first])
        XCTAssertEqual(model.items, [first])
        preferences.setShowDuplicateAlbumTracks(true)
        await Task.yield()
        XCTAssertEqual(model.items, [copy, first])
        preferences.setShowDuplicateAlbumTracks(false)
        await Task.yield()
        XCTAssertEqual(model.items, [first])
        XCTAssertEqual(actions.visibleTracks([copy], isAvailable: { $0.id == copy.id }), [copy])
        actions.configureTrackAvailability { $0.id == copy.id }
        XCTAssertEqual(model.items, [copy])
        let album = FoundationItem(
            id: "album", title: "Album", subtitle: "", kind: .album, duration: nil)
        XCTAssertEqual(actions.collectionTracks([copy], for: album), [copy])
        actions.configureTrackAvailability { _ in true }
        XCTAssertEqual(model.items, [first])
    }

    func testAlternatePlaylistCopiesHideButCanonicalOccurrencesRetainMembership() {
        var first = item("canonical")
        first.playlistEntryID = "entry-a"
        var repeated = first
        repeated.playlistEntryID = "entry-b"
        var copy = item("copy")
        copy.playlistEntryID = "entry-copy"
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleTracks(
                [first, copy, repeated], showDuplicates: false), [first, repeated])
    }

    @MainActor
    func testQueueProjectionRemapsSelectionAndPersistsRawTagsAndRestoresPaused() throws {
        let actions = FoundationLibraryActions(
            sourceScope: "synthetic", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        let first = item("canonical")
        let copy = item("copy")
        let next = item("next", title: "Next Song", track: 2)
        actions.observeTrackCopies([first])
        let source = FoundationPlayer(resolve: { _ in throw CancellationError() })
        source.configureTrackProjection(
            project: { actions.visibleTracks($0) }, observe: { actions.observeTrackCopies($0) })
        source.setQueue([copy, first, next], selectedIndex: 2)
        XCTAssertEqual(source.queue.map { $0.item.id }, [first.id, next.id])
        XCTAssertEqual(source.queue.first { $0.id == source.selectedEntryID }?.item.id, next.id)
        source.setShuffle(true)
        let snapshot = try JSONDecoder().decode(
            FoundationPlaybackSnapshot.self,
            from: JSONEncoder().encode(FoundationPlaybackSnapshot(player: source)))
        XCTAssertEqual(snapshot.entries.count, 3)
        XCTAssertEqual(snapshot.entries.first?.entry.item.trackNumber, 1)
        let restored = FoundationPlayer(resolve: { _ in
            XCTFail("Restore must not resolve audio")
            throw CancellationError()
        })
        restored.configureTrackProjection(
            project: { actions.visibleTracks($0) }, observe: { actions.observeTrackCopies($0) })
        restored.restoreSession(snapshot)
        XCTAssertEqual(restored.queue.map { $0.item.id }, [first.id, next.id])
        XCTAssertEqual(restored.queue.first { $0.id == restored.selectedEntryID }?.item.id, next.id)
        XCTAssertEqual(restored.state, .paused)
        XCTAssertNil(restored.selectionTask)
        source.stop()
        restored.stop()
    }

    private func item(
        _ id: String, title: String = "Synthetic Song", album: String? = "album",
        track: Int? = 1, disc: Int? = nil
    ) -> FoundationItem {
        var item = FoundationItem(id: id, title: title, subtitle: "", kind: .track, duration: nil)
        item.trackNumber = track
        item.discNumber = disc
        item.album = album.map { .init(id: $0, title: "Synthetic Album") }
        return item
    }
}
