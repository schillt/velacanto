import Foundation
import XCTest

@testable import VelacantoFoundation

final class FoundationGenreTests: XCTestCase {
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
