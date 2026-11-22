import Foundation
import XCTest

@testable import VelacantoFoundation

final class FoundationGenreTests: XCTestCase {
    func testCanonicalGenreIdentitySeparatesSourcesAndCensusGenerations() throws {
        let source = try FoundationCatalogSource.jellyfin(scope: String(repeating: "a", count: 64))
        let other = try FoundationCatalogSource.jellyfin(scope: String(repeating: "b", count: 64))
        let census = UUID()
        let genre = FoundationItem(
            id: "genre", title: "Rock", subtitle: "", kind: .genre, duration: nil,
            primaryGenreCensusID: census, catalogSource: source)
        var anotherSource = genre
        anotherSource.catalogSource = other
        var anotherCensus = genre
        anotherCensus.primaryGenreCensusID = UUID()
        var legacy = genre
        legacy.primaryGenreCensusID = nil
        XCTAssertEqual(
            Set([
                genre.genreIdentity, anotherSource.genreIdentity, anotherCensus.genreIdentity,
                legacy.genreIdentity,
            ]).count, 4)
    }

    func testGenreIdentityPreservesRowsWhenMutableTitleAndArtworkChange() throws {
        let genre = FoundationItem(
            id: "genre", title: "Rock", subtitle: "", kind: .genre, duration: nil,
            primaryGenreCensusID: UUID(),
            catalogSource: try .jellyfin(scope: String(repeating: "a", count: 64)))
        var changed = genre
        changed.title = "Updated Rock"
        changed.primaryImageTag = "new-artwork-revision"
        XCTAssertNotEqual(genre, changed)
        XCTAssertEqual(genre.genreIdentity, changed.genreIdentity)
        XCTAssertEqual(Set([genre.genreIdentity, changed.genreIdentity]).count, 1)
    }

    func testSearchAndLibraryCanonicalRecordUseTheSameGenreIdentity() async throws {
        let source = try FoundationCatalogSource.jellyfin(scope: String(repeating: "a", count: 64))
        let index = FoundationPrimaryGenreIndex()
        let generation = try await index.begin(scope: .init(source: source, libraryID: nil))
        try await index.append(
            .init(
                startIndex: 0, total: 1, songs: [.init(id: "song", genreIDs: ["rock"])],
                nextStartIndex: nil), generation: generation)
        let snapshot = try await index.finish(generation: generation)
        let genre = FoundationItem(
            id: "rock", title: "Rock", subtitle: "", kind: .genre, duration: nil,
            primaryGenreCensusID: snapshot.censusID, catalogSource: source)
        let record = FoundationPrimaryGenreRecord(snapshot: snapshot, descriptors: [genre])
        let search = try XCTUnwrap(record.page(query: "Rock").items.first)
        let library = try XCTUnwrap(record.matchingItems().first)
        XCTAssertEqual(search.genreIdentity, library.genreIdentity)
        XCTAssertEqual(search.genreIdentity.censusID, snapshot.censusID)
        XCTAssertEqual(search.genreIdentity.source, source)
    }

    private let genreID = "00000000000000000000000000000001"
    private var session: FoundationSession {
        FoundationSession(
            serverURL: URL(string: "https://example.invalid/base/")!,
            accessToken: "synthetic-token", userID: "00000000000000000000000000000002",
            deviceID: "synthetic-device")
    }

    func testGenreAndSelectedAlbumPagesAreBoundedAndDoNotSampleArtwork() async throws {
        let recorder = GenreRequests()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let genre = request.url?.path.hasSuffix("MusicGenres") == true
            let type = genre ? "MusicGenre" : "MusicAlbum"
            let body = """
                {"Items":[{"Id":"00000000000000000000000000000001","Type":"\(type)","ImageTags":{"Primary":"synthetic"}}],"StartIndex":50,"TotalRecordCount":100}
                """
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let genres = try await library.genres(startIndex: 50)
        let genre = try XCTUnwrap(genres.items.first)
        XCTAssertEqual(genre.kind, .genre)
        XCTAssertEqual(genre.primaryImageTag, "synthetic")
        XCTAssertNil(genre.isFavorite)
        XCTAssertEqual(genres.nextStartIndex, 51)
        let albums = try await library.albums(genreID: genre.id, startIndex: 50)
        XCTAssertEqual(albums.items.first?.kind, .album)
        let requests = await recorder.values
        XCTAssertEqual(requests.count, 2)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.url?.path, index == 0 ? "/base/MusicGenres" : "/base/Items")
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            func values(_ name: String) -> [String] {
                query.filter { $0.name == name }.compactMap(\.value)
            }
            XCTAssertEqual(values("limit"), ["50"])
            XCTAssertEqual(values("startIndex"), ["50"])
            XCTAssertEqual(values("userId"), [session.userID])
            XCTAssertEqual(values("genreIds"), index == 0 ? [] : [genreID])
            XCTAssertEqual(
                values("includeItemTypes"), index == 0 ? ["MusicAlbum", "Audio"] : ["MusicAlbum"])
            XCTAssertEqual(values("enableImages"), ["true"])
            XCTAssertEqual(values("enableImageTypes"), ["Primary"])
            XCTAssertEqual(values("imageTypeLimit"), ["1"])
        }
    }

    func testSearchAndLibraryUseTheSameScopedPaginatedGenreCatalog() async throws {
        let recorder = GenreRequests()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let body = """
                {"Items":[{"Id":"00000000000000000000000000000001","Name":"Rock","Type":"MusicGenre"}],"StartIndex":0,"TotalRecordCount":1200}
                """
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }.scoped(to: "00000000000000000000000000000003")
        let libraryPage = try await library.genres(startIndex: 0)
        let searchPage = try await library.searchGenres()
        XCTAssertEqual(searchPage.items, libraryPage.items)
        XCTAssertEqual(searchPage.nextStartIndex, libraryPage.nextStartIndex)
        XCTAssertEqual(searchPage.nextStartIndex, 1)
        let requests = await recorder.values
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url, requests[1].url)
        let query = try XCTUnwrap(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(
            query.first { $0.name == "parentId" }?.value,
            "00000000000000000000000000000003")
        XCTAssertEqual(
            query.filter { $0.name == "includeItemTypes" }.compactMap(\.value),
            ["MusicAlbum", "Audio"])
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "50")
    }

    func testTypedGenreSearchKeepsTheCatalogPolicyAndProviderIdentity() async throws {
        let recorder = GenreRequests()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let body = """
                {"Items":[{"Id":"00000000000000000000000000000001","Name":"Rock","Type":"MusicGenre"}],"StartIndex":50,"TotalRecordCount":51}
                """
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }.scoped(to: "00000000000000000000000000000003")
        let page = try await library.search(
            query: " Rock ", kind: .genre, startIndex: 50, limit: 50)
        XCTAssertEqual(page.items.first?.id, genreID)
        XCTAssertEqual(page.items.first?.title, "Rock")
        XCTAssertNil(page.nextStartIndex)
        let requests = await recorder.values
        let query = try XCTUnwrap(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "searchTerm" }?.value, "Rock")
        XCTAssertEqual(
            query.first { $0.name == "parentId" }?.value,
            "00000000000000000000000000000003")
        XCTAssertEqual(
            query.filter { $0.name == "includeItemTypes" }.compactMap(\.value),
            ["MusicAlbum", "Audio"])
        XCTAssertEqual(query.first { $0.name == "startIndex" }?.value, "50")
    }

    func testInvalidGenreAndPageDoNotSendAndGenreFailureDoesNotRetry() async {
        let recorder = GenreRequests()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            throw URLError(.timedOut)
        }
        do {
            _ = try await library.albums(genreID: "../other", startIndex: 0)
            XCTFail("Invalid genre")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        do {
            _ = try await library.genres(startIndex: -1)
            XCTFail("Invalid page")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        let before = await recorder.values.count
        XCTAssertEqual(before, 0)
        do {
            _ = try await library.genres(startIndex: 0)
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .network) }
        let after = await recorder.values.count
        XCTAssertEqual(after, 1)
    }
}

private actor GenreRequests {
    var values: [URLRequest] = []
    func append(_ request: URLRequest) { values.append(request) }
}
