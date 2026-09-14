import Foundation
import XCTest

@testable import VelacantoFoundation

final class FoundationLibraryTests: XCTestCase {
    private let itemID = "00000000000000000000000000000001"
    private var session: FoundationSession {
        FoundationSession(
            serverURL: URL(string: "https://example.invalid/proxy/jellyfin/")!,
            accessToken: "synthetic-token", userID: "00000000000000000000000000000002",
            deviceID: "00000000-0000-0000-0000-000000000003")
    }

    func testAlbumAndTrackPagesUseOneRequestEachAndExplicitBounds() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let url = try XCTUnwrap(request.url)
            let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = try XCTUnwrap(parts.queryItems)
            // Generated array parameters repeat keys, notably track sortBy.
            let startText = try XCTUnwrap(query.first { $0.name == "startIndex" }?.value)
            let start = try XCTUnwrap(Int(startText))
            let kind = try XCTUnwrap(query.first { $0.name == "includeItemTypes" }?.value)
            let body = """
                {"Items":[{"Id":"00000000000000000000000000000001","Name":"Synthetic","Type":"\(kind)","ImageTags":{"Primary":"synthetic-tag"}}],"StartIndex":\(start),"TotalRecordCount":200}
                """
            return (Data(body.utf8), Self.response(request))
        }
        let albums = try await library.albums(startIndex: 0)
        let tracks = try await library.tracks(albumID: itemID, startIndex: 100)
        XCTAssertEqual(albums.items.first?.primaryImageTag, "synthetic-tag")
        XCTAssertNil(tracks.items.first?.primaryImageTag)
        XCTAssertEqual(albums.nextStartIndex, 1)
        XCTAssertEqual(tracks.nextStartIndex, 101)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        for (index, request) in requests.enumerated() {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/proxy/jellyfin/Items")
            let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = try XCTUnwrap(parts.queryItems)
            XCTAssertEqual(
                query.filter { $0.name == "limit" }.compactMap(\.value),
                [index == 0 ? "50" : "100"])
            XCTAssertEqual(
                query.filter { $0.name == "startIndex" }.compactMap(\.value),
                [index == 0 ? "0" : "100"])
            XCTAssertEqual(
                query.filter { $0.name == "includeItemTypes" }.compactMap(\.value),
                [index == 0 ? "MusicAlbum" : "Audio"])
            XCTAssertEqual(
                query.filter { $0.name == "sortBy" }.compactMap(\.value),
                index == 0 ? ["SortName"] : ["ParentIndexNumber", "IndexNumber", "SortName"])
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testArtistPagesAndSelectedArtistAlbumsUseExplicitSinglePageRequests() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let url = try XCTUnwrap(request.url)
            let query = try XCTUnwrap(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let start = try XCTUnwrap(query.first { $0.name == "startIndex" }?.value)
            let kind = url.path.hasSuffix("AlbumArtists") ? "MusicArtist" : "MusicAlbum"
            return (
                Data(
                    """
                    {"Items":[{"Id":"00000000000000000000000000000001","Name":"Synthetic","Type":"\(kind)","ImageTags":{"Primary":"synthetic-tag"}}],"StartIndex":\(start),"TotalRecordCount":51}
                    """.utf8), Self.response(request)
            )
        }
        let first = try await library.artists(startIndex: 0)
        XCTAssertEqual(first.items.first?.kind, .artist)
        XCTAssertEqual(first.items.first?.primaryImageTag, "synthetic-tag")
        XCTAssertEqual(first.nextStartIndex, 1)
        let last = try await library.artists(startIndex: 50)
        XCTAssertNil(last.nextStartIndex)
        let albums = try await library.albums(artistID: itemID, startIndex: 0)
        XCTAssertEqual(albums.items.first?.kind, .album)
        XCTAssertEqual(albums.items.first?.primaryImageTag, "synthetic-tag")
        XCTAssertEqual(albums.nextStartIndex, 1)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
        for (index, request) in requests.enumerated() {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(
                url.path,
                index < 2 ? "/proxy/jellyfin/Artists/AlbumArtists" : "/proxy/jellyfin/Items")
            let query = try XCTUnwrap(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            func values(_ key: String) -> [String] {
                query.filter { $0.name == key }.compactMap(\.value)
            }
            XCTAssertEqual(values("limit"), ["50"])
            XCTAssertEqual(values("startIndex"), [index == 1 ? "50" : "0"])
            XCTAssertEqual(values("sortBy"), ["SortName"])
            XCTAssertEqual(values("sortOrder"), ["Ascending"])
            XCTAssertEqual(values("userId"), [session.userID])
            XCTAssertEqual(values("enableTotalRecordCount"), ["true"])
            XCTAssertEqual(values("enableImages"), ["true"])
            XCTAssertEqual(values("enableImageTypes"), ["Primary"])
            XCTAssertEqual(values("imageTypeLimit"), ["1"])
            XCTAssertEqual(values("enableUserData"), ["true"])
            XCTAssertEqual(values("albumArtistIds"), index < 2 ? [] : [itemID])
            XCTAssertTrue(values("parentId").isEmpty)
            XCTAssertEqual(values("includeItemTypes"), index < 2 ? [] : ["MusicAlbum"])
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testInvalidArtistScopeAndNegativeArtistPageStartNoTransport() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            throw URLError(.timedOut)
        }
        do {
            _ = try await library.albums(artistID: "../other", startIndex: 0)
            XCTFail("Expected invalid artist rejection")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        do {
            _ = try await library.artists(startIndex: -1)
            XCTFail("Expected invalid page rejection")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        let count = await recorder.requests.count
        XCTAssertEqual(count, 0)
    }

    func testArtistPageFailureDoesNotRetryAndLaterAlbumReadSucceeds() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            if request.url?.path.hasSuffix("AlbumArtists") == true { throw URLError(.timedOut) }
            return (
                Data(#"{"Items":[],"StartIndex":0,"TotalRecordCount":0}"#.utf8),
                Self.response(request)
            )
        }
        do {
            _ = try await library.artists(startIndex: 0)
            XCTFail("Expected artist failure")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .network) }
        let page = try await library.albums(artistID: itemID, startIndex: 0)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextStartIndex)
        let count = await recorder.requests.count
        XCTAssertEqual(count, 2)
    }

    func testAlbumAndArtistArtworkUseOneTaggedBoundedAuthenticatedImageRequestEach() async throws {
        for kind in [FoundationItem.Kind.album, .artist, .playlist] {
            let recorder = Recorder()
            let library = FoundationJellyfinLibrary(session: session) { request in
                await recorder.append(request)
                return (Data([1, 2, 3]), Self.response(request))
            }
            let item = FoundationItem(
                id: itemID, title: "Synthetic", subtitle: "", kind: kind, duration: nil,
                primaryImageTag: "synthetic-tag")
            let data = try await library.artwork(for: item)
            XCTAssertEqual(data, Data([1, 2, 3]))
            let requests = await recorder.requests
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.url?.path, "/proxy/jellyfin/Items/\(itemID)/Images/Primary")
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            for expected in [
                URLQueryItem(name: "maxWidth", value: "160"),
                URLQueryItem(name: "maxHeight", value: "160"),
                URLQueryItem(name: "tag", value: "synthetic-tag"),
            ] {
                XCTAssertTrue(query.contains(expected))
            }
            XCTAssertFalse(query.contains { $0.name.lowercased() == "apikey" })
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "image/jpeg")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testArtistAndAlbumReferencesWithoutImageTagsMakeOneBoundedImageRequestEach() async throws {
        for kind in [FoundationItem.Kind.artist, .album] {
            let recorder = Recorder()
            let library = FoundationJellyfinLibrary(session: session) { request in
                await recorder.append(request)
                return (Data([1, 2, 3]), Self.response(request))
            }
            let item = FoundationItem(
                id: itemID, title: "Synthetic", subtitle: "", kind: kind, duration: nil)
            let data = try await library.artwork(for: item, size: 640)
            XCTAssertEqual(data, Data([1, 2, 3]))
            let requests = await recorder.requests
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.url?.path, "/proxy/jellyfin/Items/\(itemID)/Images/Primary")
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertFalse(query.contains { $0.name == "tag" })
            XCTAssertTrue(query.contains(URLQueryItem(name: "maxWidth", value: "640")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "maxHeight", value: "640")))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testUntaggedPlaylistsAndTracksMakeNoImageRequest() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            throw URLError(.timedOut)
        }
        for kind in [FoundationItem.Kind.playlist, .track] {
            let item = FoundationItem(
                id: itemID, title: "Synthetic", subtitle: "", kind: kind, duration: nil,
                primaryImageTag: kind == .track ? "synthetic-tag" : nil)
            let data = try await library.artwork(for: item)
            XCTAssertNil(data)
        }
        let count = await recorder.requests.count
        XCTAssertEqual(count, 0)
    }

    func testImageFailureDoesNotRetryOrPreventLaterCatalogRead() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            if request.url?.path.contains("Images") == true { throw URLError(.timedOut) }
            return (
                Data(#"{"Items":[],"StartIndex":0,"TotalRecordCount":0}"#.utf8),
                Self.response(request)
            )
        }
        let item = FoundationItem(
            id: itemID, title: "Synthetic", subtitle: "", kind: .album, duration: nil,
            primaryImageTag: "synthetic-tag")
        do {
            _ = try await library.artwork(for: item)
            XCTFail("Expected image failure")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .network) }
        let page = try await library.albums(startIndex: 0)
        XCTAssertTrue(page.items.isEmpty)
        let count = await recorder.requests.count
        XCTAssertEqual(count, 2)
    }

    func testPlaybackURLUsesNoTransportAndPreservesBasePath() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            throw URLError(.unsupportedURL)
        }
        let item = FoundationItem(
            id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
        let url = try await library.playbackURL(for: item)
        let count = await recorder.requests.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(url.path, "/proxy/jellyfin/Audio/\(itemID)/universal")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(query.contains(URLQueryItem(name: "ApiKey", value: "synthetic-token")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "audioCodec", value: "aac")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "transcodingProtocol", value: "hls")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "transcodingContainer", value: "ts")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "enableRedirection", value: "false")))
        XCTAssertEqual(
            query.filter { $0.name == "container" }.compactMap(\.value),
            [
                "mp3", "aac", "mp4|aac|alac", "m4a|aac|alac", "flac",
                "wav|pcm_s16le|pcm_s24le", "aiff|pcm_s16be|pcm_s24be",
            ])
        XCTAssertFalse(query.contains { $0.name == "static" || $0.name == "allowAudioStreamCopy" })
    }

    func testSignInIsOnePostWithGeneratedBodyAndFractionalDates() async throws {
        let recorder = Recorder()
        let result = try await FoundationJellyfinLibrary.signIn(
            serverURL: session.serverURL,
            username: "synthetic", password: "synthetic"
        ) { request in
            await recorder.append(request)
            let body = """
                {"AccessToken":"synthetic-token","User":{"Id":"00000000000000000000000000000002","LastLoginDate":"2026-01-01T00:00:00.1234567Z"}}
                """
            return (Data(body.utf8), Self.response(request))
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url!.path, "/proxy/jellyfin/Users/AuthenticateByName")
        let body =
            try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: String]
        XCTAssertEqual(body["Username"], "synthetic")
        XCTAssertEqual(body["Pw"], "synthetic")
        XCTAssertEqual(result.accessToken, "synthetic-token")
    }

    func testFailureIsCategorizedAndNeverRetried() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            throw URLError(.timedOut)
        }
        do {
            _ = try await library.albums(startIndex: 0)
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .network) }
        let count = await recorder.requests.count
        XCTAssertEqual(count, 1)
    }

    func testUnauthorizedAndRedirectResponsesAreFiniteErrors() async {
        for (status, expected) in [
            (401, FoundationLibraryError.authentication), (302, .secureConnection),
        ] {
            let library = FoundationJellyfinLibrary(session: session) { request in
                (Data(), Self.response(request, status: status))
            }
            do {
                _ = try await library.albums(startIndex: 0)
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(error as? FoundationLibraryError, expected) }
        }
    }

    func testCancelledCallerStartsNoRequest() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (Data(), Self.response(request))
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await library.albums(startIndex: 0)
                XCTFail("Expected cancellation")
            } catch { XCTAssertEqual(error as? FoundationLibraryError, .cancelled) }
        }
        await task.value
        let count = await recorder.requests.count
        XCTAssertEqual(count, 0)
    }

    func testInvalidServerAndInjectedPathAreRejectedWithoutTransport() async throws {
        for text in [
            "http://example.invalid", "https://user:pass@example.invalid",
            "https://example.invalid/?token=x",
        ] {
            XCTAssertThrowsError(
                try FoundationJellyfinLibrary.validatedServerURL(URL(string: text)!))
        }
        let library = FoundationJellyfinLibrary(session: session) { _ in
            XCTFail("Invalid IDs must not start requests")
            throw URLError(.unsupportedURL)
        }
        do {
            _ = try await library.tracks(albumID: "../other", startIndex: 0)
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
    }

    func testEmptyPageHasNoContinuation() async throws {
        let library = FoundationJellyfinLibrary(session: session) { request in
            (
                Data("{\"Items\":[],\"StartIndex\":0,\"TotalRecordCount\":0}".utf8),
                Self.response(request)
            )
        }
        let page = try await library.albums(startIndex: 0)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextStartIndex)
    }

    func testSongsPlaylistsAndFavoritesEachUseOneBoundedScopedPage() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            let types = query.filter { $0.name == "includeItemTypes" }.compactMap(\.value)
            let entries = types.enumerated().map { index, type in
                "{\"Id\":\"0000000000000000000000000000000\(index + 1)\",\"Type\":\"\(type)\",\"ImageTags\":{\"Primary\":\"synthetic-tag\"}}"
            }.joined(separator: ",")
            return (
                Data("{\"Items\":[\(entries)],\"StartIndex\":50,\"TotalRecordCount\":200}".utf8),
                Self.response(request)
            )
        }
        let songs = try await library.songs(startIndex: 50)
        let playlists = try await library.playlists(startIndex: 50)
        let favorites = try await library.favorites(startIndex: 50)
        XCTAssertEqual(songs.items.map(\.kind), [.track])
        XCTAssertNil(songs.items.first?.primaryImageTag)
        XCTAssertEqual(playlists.items.map(\.kind), [.playlist])
        XCTAssertEqual(playlists.items.first?.primaryImageTag, "synthetic-tag")
        XCTAssertEqual(favorites.items.map(\.kind), [.track, .album, .artist, .playlist])
        XCTAssertEqual(favorites.nextStartIndex, 54)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/proxy/jellyfin/Items")
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            func values(_ name: String) -> [String] {
                query.filter { $0.name == name }.compactMap(\.value)
            }
            XCTAssertEqual(values("limit"), [index == 0 ? "100" : "50"])
            XCTAssertEqual(values("startIndex"), ["50"])
            XCTAssertEqual(values("recursive"), ["true"])
            XCTAssertEqual(values("userId"), [session.userID])
            XCTAssertEqual(values("isFavorite"), index == 2 ? ["true"] : [])
            XCTAssertEqual(values("sortBy"), ["SortName"])
            XCTAssertEqual(values("enableImages"), ["true"])
            XCTAssertEqual(values("enableTotalRecordCount"), ["true"])
        }
    }

    func testPlaylistItemsPreserveServerOrderAndDuplicatesWithOneExplicitPage() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (
                Data(
                    #"{"Items":[{"Id":"00000000000000000000000000000002","Type":"Audio"},{"Id":"00000000000000000000000000000001","Type":"Audio"},{"Id":"00000000000000000000000000000002","Type":"Audio"}],"StartIndex":100,"TotalRecordCount":200}"#
                        .utf8), Self.response(request)
            )
        }
        let page = try await library.playlistTracks(playlistID: itemID, startIndex: 100)
        XCTAssertEqual(
            page.items.map(\.id),
            ["00000000000000000000000000000002", itemID, "00000000000000000000000000000002"])
        XCTAssertEqual(page.nextStartIndex, 103)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/proxy/jellyfin/Playlists/\(itemID)/Items")
        let query = try XCTUnwrap(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "userId", value: session.userID)))
        XCTAssertTrue(query.contains(URLQueryItem(name: "startIndex", value: "100")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "limit", value: "100")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "enableImages", value: "true")))
        XCTAssertFalse(query.contains { $0.name == "sortBy" })
    }

    func testInvalidPlaylistIDStartsNoRequestAndFavoritesFailureDoesNotRetry() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            throw URLError(.timedOut)
        }
        do {
            _ = try await library.playlistTracks(playlistID: "../other", startIndex: 0)
            XCTFail("Expected invalid playlist rejection")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        let before = await recorder.requests.count
        XCTAssertEqual(before, 0)
        do {
            _ = try await library.favorites(startIndex: 0)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .network) }
        let after = await recorder.requests.count
        XCTAssertEqual(after, 1)
    }

    func testMixedFavoritesRejectUnsupportedServerTypes() async {
        let library = FoundationJellyfinLibrary(session: session) { request in
            (
                Data(
                    #"{"Items":[{"Id":"00000000000000000000000000000001","Type":"Movie"}],"StartIndex":0,"TotalRecordCount":1}"#
                        .utf8), Self.response(request)
            )
        }
        do {
            _ = try await library.favorites(startIndex: 0)
            XCTFail("Expected unsupported type rejection")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
    }

    func testFavoriteMutationUsesOneExplicitPostOrDeleteAndChecksServerResult() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let favorite = request.httpMethod == "POST"
            return (
                Data("{\"Key\":\"synthetic-key\",\"IsFavorite\":\(favorite)}".utf8),
                Self.response(request)
            )
        }
        let item = FoundationItem(
            id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
        try await library.setFavorite(for: item, isFavorite: true)
        try await library.setFavorite(for: item, isFavorite: false)
        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "DELETE"])
        for request in requests {
            XCTAssertEqual(request.url?.path, "/proxy/jellyfin/UserFavoriteItems/\(itemID)")
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertTrue(query.contains(URLQueryItem(name: "userId", value: session.userID)))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testFavoriteMutationFailureIsNotRetriedOrReportedAsSuccess() async {
        let item = FoundationItem(
            id: itemID, title: "Synthetic", subtitle: "", kind: .album, duration: nil)
        for timeout in [true, false] {
            let recorder = Recorder()
            let library = FoundationJellyfinLibrary(session: session) { request in
                await recorder.append(request)
                if timeout { throw URLError(.timedOut) }
                return (
                    Data(#"{"Key":"synthetic-key","IsFavorite":false}"#.utf8),
                    Self.response(request)
                )
            }
            do {
                try await library.setFavorite(for: item, isFavorite: true)
                XCTFail("Expected failure")
            } catch {
                XCTAssertEqual(
                    error as? FoundationLibraryError, timeout ? .network : .invalidResponse)
            }
            let count = await recorder.requests.count
            XCTAssertEqual(count, 1)
        }
    }

    func testCatalogHydratesOptionalFavoriteWithoutExtraRequests() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (
                Data(
                    #"{"Items":[{"Id":"00000000000000000000000000000001","Type":"Audio","UserData":{"Key":"synthetic-key","IsFavorite":true}},{"Id":"00000000000000000000000000000002","Type":"Audio"}],"StartIndex":0,"TotalRecordCount":2}"#
                        .utf8), Self.response(request)
            )
        }
        let page = try await library.songs(startIndex: 0)
        XCTAssertEqual(page.items.map(\.isFavorite), [true, nil])
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        let query = try XCTUnwrap(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "enableUserData", value: "true")))
    }

    func testMostPlayedAlbumsGroupsOneBoundedTrackSampleWithoutPaging() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            for (name, value) in [
                ("limit", "100"), ("startIndex", "0"), ("includeItemTypes", "Audio"),
                ("sortBy", "PlayCount"), ("sortOrder", "Descending"), ("isPlayed", "true"),
            ] {
                XCTAssertTrue(query.contains(URLQueryItem(name: name, value: value)))
            }
            var items: [[String: Any]] = (1...14).map { index in
                [
                    "Id": String(format: "%032d", index), "Type": "Audio",
                    "AlbumId": String(format: "%032d", index + 100), "Album": "Synthetic \(index)",
                    "UserData": ["Key": "synthetic", "PlayCount": 20 - index],
                ]
            }
            // Two occurrences from the same album combine, without duplicate cards.
            items.append([
                "Id": String(format: "%032d", 30), "Type": "Audio",
                "AlbumId": String(format: "%032d", 102), "Album": "Synthetic 2",
                "UserData": ["Key": "synthetic", "PlayCount": 18],
            ])
            items.append([
                "Id": String(format: "%032d", 31), "Type": "Audio",
                "UserData": ["Key": "synthetic", "PlayCount": 100],
            ])
            let data = try JSONSerialization.data(withJSONObject: [
                "Items": items, "StartIndex": 0, "TotalRecordCount": 1000,
            ])
            return (data, Self.response(request))
        }
        let page = try await library.mostPlayedAlbums()
        XCTAssertEqual(page.items.count, 12)
        XCTAssertEqual(page.items.first?.title, "Synthetic 2")
        XCTAssertEqual(page.items.first?.playCount, 36)
        XCTAssertTrue(page.items.allSatisfy { $0.kind == .album })
        XCTAssertEqual(Set(page.items.map(\.id)).count, 12)
        XCTAssertNil(page.nextStartIndex)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testRecentAlbumsAndTracksUseOneDateDescendingPageEachAndServerCursor() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            let type = try XCTUnwrap(query.first { $0.name == "includeItemTypes" }?.value)
            let start = try XCTUnwrap(query.first { $0.name == "startIndex" }?.value)
            return (
                Data(
                    """
                    {"Items":[{"Id":"00000000000000000000000000000001","Type":"\(type)","ImageTags":{"Primary":"synthetic"},"GenreItems":[{"Id":"00000000000000000000000000000009","Name":"Synthetic Genre"}],"UserData":{"Key":"synthetic","IsFavorite":true}}],"StartIndex":\(start),"TotalRecordCount":25}
                    """.utf8), Self.response(request)
            )
        }
        let albums = try await library.recentAlbums(startIndex: 0)
        let tracks = try await library.recentTracks(startIndex: 24)
        XCTAssertEqual(albums.items.first?.kind, .album)
        XCTAssertEqual(albums.items.first?.primaryImageTag, "synthetic")
        XCTAssertEqual(albums.nextStartIndex, 1)
        XCTAssertEqual(albums.items.first?.genres.first?.title, "Synthetic Genre")
        XCTAssertEqual(tracks.items.first?.kind, .track)
        XCTAssertNil(tracks.items.first?.primaryImageTag)
        XCTAssertNil(tracks.nextStartIndex)
        XCTAssertEqual(tracks.items.first?.isFavorite, true)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/proxy/jellyfin/Items")
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            func values(_ name: String) -> [String] {
                query.filter { $0.name == name }.compactMap(\.value)
            }
            XCTAssertEqual(values("limit"), ["24"])
            XCTAssertEqual(values("startIndex"), [index == 0 ? "0" : "24"])
            XCTAssertEqual(values("includeItemTypes"), [index == 0 ? "MusicAlbum" : "Audio"])
            XCTAssertEqual(values("fields"), index == 0 ? ["Genres"] : [])
            XCTAssertEqual(values("sortBy"), ["DateCreated"])
            XCTAssertEqual(values("sortOrder"), ["Descending"])
            XCTAssertEqual(values("recursive"), ["true"])
            XCTAssertEqual(values("userId"), [session.userID])
            XCTAssertEqual(values("enableTotalRecordCount"), ["true"])
            XCTAssertEqual(values("enableUserData"), ["true"])
        }
    }

    func testRecentInvalidOffsetsMakeNoRequestsAndFailureDoesNotRetry() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            throw URLError(.timedOut)
        }
        do {
            _ = try await library.recentAlbums(startIndex: -1)
            XCTFail("Expected invalid offset")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        do {
            _ = try await library.recentTracks(startIndex: -1)
            XCTFail("Expected invalid offset")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        let before = await recorder.requests.count
        XCTAssertEqual(before, 0)
        do {
            _ = try await library.recentAlbums(startIndex: 0)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .network) }
        let after = await recorder.requests.count
        XCTAssertEqual(after, 1)
    }

    private static func response(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

private actor Recorder {
    var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}
