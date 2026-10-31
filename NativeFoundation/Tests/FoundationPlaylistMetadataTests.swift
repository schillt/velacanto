import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import VelacantoFoundation

final class FoundationPlaylistMetadataTests: XCTestCase {
    private let id = "00000000000000000000000000000001"
    private let userID = "00000000000000000000000000000002"
    private func library(_ server: PlaylistMetadataServer) -> FoundationJellyfinLibrary {
        FoundationJellyfinLibrary(
            session: .init(
                serverURL: URL(string: "https://example.invalid/jf")!, accessToken: "synthetic",
                userID: userID, deviceID: "fixture")
        ) { request in try await server.respond(request) }
    }
    private func image() throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testDetailsUsesOpenAccessAndSeparatesElevatedMetadataCapabilities() async throws {
        let server = PlaylistMetadataServer(id: id, userID: userID)
        let details = try await library(server).playlistDetails(id: id)
        XCTAssertEqual(details.overview, "Old overview")
        XCTAssertEqual(details.isPublic, true)
        XCTAssertTrue(details.permissions.canEdit)
        XCTAssertTrue(details.canEditOverview)
        XCTAssertTrue(details.canEditCover)
        XCTAssertEqual(details.item.primaryImageTag, "before")
        XCTAssertNotNil(details.item.catalogSource)
    }

    func testUpdatePreservesFullMetadataSharesAndMembershipsAndReadsBack() async throws {
        let server = PlaylistMetadataServer(id: id, userID: userID)
        let updated = try await library(server).updatePlaylistDetails(
            id: id, name: "  New name  ", overview: "New overview", isPublic: false)
        XCTAssertEqual(updated.item.title, "New name")
        XCTAssertEqual(updated.overview, "New overview")
        XCTAssertEqual(updated.isPublic, false)
        let writes = await server.writes()
        XCTAssertEqual(writes.count, 2)
        let metadata = try XCTUnwrap(writes.first { $0.url?.path == "/jf/Items/" + id })
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(metadata.httpBody)) as? [String: Any])
        XCTAssertEqual(body["LockData"] as? Bool, true)
        XCTAssertEqual(body["Tags"] as? [String], ["keep"])
        XCTAssertEqual(body["Genres"] as? [String], ["Rock"])
        XCTAssertEqual((body["ProviderIds"] as? [String: String])?["Fixture"], "preserve")
        XCTAssertEqual((body["UnknownFutureField"] as? [String: Int])?["nested"], 17)
        let sharing = try XCTUnwrap(writes.first { $0.url?.path == "/jf/Playlists/" + id })
        let sharingBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(sharing.httpBody)) as? [String: Any])
        XCTAssertEqual(sharingBody["IsPublic"] as? Bool, false)
        XCTAssertNil(sharingBody["Users"])
        XCTAssertNil(sharingBody["Ids"])
        XCTAssertNil(sharingBody["Name"])
        XCTAssertTrue(
            writes.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("MediaBrowser ") == true
            })
        XCTAssertTrue(writes.allSatisfy { $0.url?.absoluteString.contains("synthetic") == false })
        let cleared = try await library(server).updatePlaylistDetails(
            id: id, name: nil, overview: "", isPublic: nil)
        XCTAssertEqual(cleared.overview, "")
        XCTAssertEqual(cleared.item.title, "New name")
        XCTAssertEqual(cleared.isPublic, false)
    }

    func testNameOnlyPreservesUnknownSharingAndDoesNotRequireAdministrator() async throws {
        let server = PlaylistMetadataServer(
            id: id, userID: userID, administrator: false, sharingVisible: false)
        let result = try await library(server).updatePlaylistDetails(
            id: id, name: "Owner name", overview: nil, isPublic: nil)
        XCTAssertEqual(result.item.title, "Owner name")
        XCTAssertNil(result.isPublic)
        XCTAssertFalse(result.canEditOverview)
        XCTAssertFalse(result.canEditCover)
        let writes = await server.writes()
        XCTAssertEqual(writes.count, 1)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(writes[0].httpBody)) as? [String: Any])
        XCTAssertEqual(body["Name"] as? String, "Owner name")
        for field in ["IsPublic", "Users", "Ids", "Overview"] { XCTAssertNil(body[field]) }
        let publicValue = await server.publicValue()
        XCTAssertTrue(publicValue)
    }

    func testNameOnlyUpdatePreservesConcurrentPublicAndOverviewChanges() async throws {
        let server = PlaylistMetadataServer(id: id, userID: userID, concurrentEdit: true)
        let updated = try await library(server).updatePlaylistDetails(
            id: id, name: "Only requested name", overview: nil, isPublic: nil)
        XCTAssertEqual(updated.item.title, "Only requested name")
        XCTAssertEqual(updated.overview, "External overview")
        XCTAssertEqual(updated.isPublic, false)
        let writes = await server.writes()
        XCTAssertEqual(writes.count, 1)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(writes[0].httpBody)) as? [String: Any])
        XCTAssertEqual(body["Name"] as? String, "Only requested name")
        XCTAssertNil(body["IsPublic"])
        XCTAssertNil(body["Overview"])
    }

    func testReadOnlyOverviewAndUnknownSharingRejectBeforeAnyMutation() async throws {
        let restricted = PlaylistMetadataServer(id: id, userID: userID, administrator: false)
        do {
            _ = try await library(restricted).updatePlaylistDetails(
                id: id, name: "Before", overview: "Changed", isPublic: nil)
            XCTFail("Nonadministrator updated overview")
        } catch { XCTAssertEqual(error as? FoundationPlaylistMetadataError, .overviewReadOnly) }
        let restrictedWrites = await restricted.writes()
        XCTAssertTrue(restrictedWrites.isEmpty)
        let unknown = PlaylistMetadataServer(id: id, userID: userID, sharingVisible: false)
        do {
            _ = try await library(unknown).updatePlaylistDetails(
                id: id, name: "Before", overview: "Old overview", isPublic: false)
            XCTFail("Unknown public state was reset")
        } catch { XCTAssertEqual(error as? FoundationPlaylistMetadataError, .sharingUnavailable) }
        let unknownWrites = await unknown.writes()
        XCTAssertTrue(unknownWrites.isEmpty)
        let foreign = PlaylistMetadataServer(id: id, userID: userID, foreignPermission: true)
        do {
            _ = try await library(foreign).playlistDetails(id: id)
            XCTFail("Mismatched account permission accepted")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        let foreignWrites = await foreign.writes()
        XCTAssertTrue(foreignWrites.isEmpty)
    }

    func testFailureOrCancellationAfterMetadataWriteReportsPartialAndStopsLaterWrites() async throws
    {
        for cancel in [false, true] {
            let server = PlaylistMetadataServer(
                id: id, userID: userID, failSharing: !cancel, cancelAfterMetadata: cancel)
            let backend = library(server)
            let playlistID = id
            let operation = Task {
                try await backend.updatePlaylistDetails(
                    id: playlistID, name: "Saved name", overview: "Saved overview", isPublic: false)
            }
            do {
                _ = try await operation.value
                XCTFail("Partial update reported complete")
            } catch { XCTAssertEqual(error as? FoundationPlaylistMetadataError, .partialUpdate) }
            let writes = await server.writes()
            XCTAssertEqual(writes.count, cancel ? 1 : 2)
            let saved = await server.savedOverview()
            XCTAssertEqual(saved, "Saved overview")
        }
    }

    func testPrimaryCoverUsesRawBase64MIMEAndReturnsRefreshedTag() async throws {
        let server = PlaylistMetadataServer(id: id, userID: userID)
        let bytes = try image()
        let updated = try await library(server).setPlaylistCover(
            id: id, data: bytes, contentType: "image/png")
        XCTAssertEqual(updated.primaryImageTag, "after")
        let writes = await server.writes()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0].url?.path, "/jf/Items/" + id + "/Images/Primary")
        XCTAssertEqual(writes[0].value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(writes[0].httpBody, bytes.base64EncodedData())
        let unchanged = PlaylistMetadataServer(id: id, userID: userID, refreshImage: false)
        do {
            _ = try await library(unchanged).setPlaylistCover(
                id: id, data: bytes, contentType: "image/png")
            XCTFail("Unconfirmed cover reported saved")
        } catch { XCTAssertEqual(error as? FoundationPlaylistMetadataError, .partialCover) }
        let invalid = PlaylistMetadataServer(id: id, userID: userID)
        do {
            _ = try await library(invalid).setPlaylistCover(
                id: id, data: bytes, contentType: "image/jpeg")
            XCTFail("Mismatched image MIME uploaded")
        } catch { XCTAssertEqual(error as? FoundationPlaylistMetadataError, .invalidCover) }
        let invalidWrites = await invalid.writes()
        XCTAssertTrue(invalidWrites.isEmpty)
    }
}

private actor PlaylistMetadataServer {
    let id: String
    let userID: String
    let administrator: Bool
    let sharingVisible: Bool
    let failSharing: Bool
    let cancelAfterMetadata: Bool
    let refreshImage: Bool
    let concurrentEdit: Bool
    let foreignPermission: Bool
    private var name = "Before"
    private var overview = "Old overview"
    private var isPublic = true
    private var imageTag = "before"
    private var requests: [URLRequest] = []
    init(
        id: String, userID: String, administrator: Bool = true, sharingVisible: Bool = true,
        failSharing: Bool = false, cancelAfterMetadata: Bool = false, refreshImage: Bool = true,
        concurrentEdit: Bool = false, foreignPermission: Bool = false
    ) {
        self.id = id
        self.userID = userID
        self.administrator = administrator
        self.sharingVisible = sharingVisible
        self.failSharing = failSharing
        self.cancelAfterMetadata = cancelAfterMetadata
        self.refreshImage = refreshImage
        self.concurrentEdit = concurrentEdit
        self.foreignPermission = foreignPermission
    }
    func writes() -> [URLRequest] { requests.filter { $0.httpMethod == "POST" } }
    func publicValue() -> Bool { isPublic }
    func savedOverview() -> String { overview }
    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url!.path
        var value: [String: Any] = [:]
        var status = 200
        if request.httpMethod == "POST" {
            if path.hasSuffix("/Images/Primary") {
                if refreshImage { imageTag = "after" }
            } else if path == "/jf/Items/" + id {
                let body =
                    try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                name = body["Name"] as! String
                overview = body["Overview"] as! String
                if cancelAfterMetadata { withUnsafeCurrentTask { $0?.cancel() } }
            } else if path == "/jf/Playlists/" + id {
                if failSharing {
                    status = 500
                } else {
                    let body =
                        try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                    if concurrentEdit {
                        overview = "External overview"
                        isPublic = false
                    }
                    if let changed = body["Name"] as? String { name = changed }
                    if let changed = body["IsPublic"] as? Bool { isPublic = changed }
                }
            }
            if status == 200 { status = 204 }
        } else if path == "/jf/Items/" + id {
            value = [
                "Id": id, "Type": "Playlist", "Name": name, "Overview": overview,
                "CanDelete": true, "LockData": true, "Tags": ["keep"], "Genres": ["Rock"],
                "ProviderIds": ["Fixture": "preserve"], "UnknownFutureField": ["nested": 17],
                "ImageTags": ["Primary": imageTag],
            ]
        } else if path == "/jf/Playlists/" + id {
            value = ["ItemIds": [], "Shares": [["UserId": userID, "CanEdit": true]]]
            if sharingVisible { value["OpenAccess"] = isPublic }
        } else if path == "/jf/Users/Me" {
            value = ["Id": userID, "Policy": ["IsAdministrator": administrator]]
        } else if path == "/jf/Playlists/" + id + "/Users/" + userID {
            value = ["UserId": foreignPermission ? id : userID, "CanEdit": true]
        } else {
            throw FoundationLibraryError.invalidResponse
        }
        return (
            try JSONSerialization.data(withJSONObject: value),
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}
