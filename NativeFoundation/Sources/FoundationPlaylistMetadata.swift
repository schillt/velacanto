import Foundation
import ImageIO

struct FoundationPlaylistDetails: Sendable, Equatable {
    let item: FoundationItem
    let overview: String
    let isPublic: Bool?
    let permissions: FoundationPlaylistPermissions
    let canEditOverview: Bool
    let canEditCover: Bool

    init(
        item: FoundationItem, overview: String, isPublic: Bool?,
        permissions: FoundationPlaylistPermissions, canEditOverview: Bool = false,
        canEditCover: Bool = false
    ) {
        self.item = item
        self.overview = overview
        self.isPublic = isPublic
        self.permissions = permissions
        self.canEditOverview = canEditOverview
        self.canEditCover = canEditCover
    }
}

enum FoundationPlaylistMetadataError: Error, LocalizedError, Equatable {
    case overviewReadOnly, sharingUnavailable, invalidOverview, invalidCover, partialUpdate,
        partialCover
    var errorDescription: String? {
        switch self {
        case .overviewReadOnly: "This account cannot edit playlist descriptions on this server."
        case .sharingUnavailable: "This server did not provide the playlist’s public setting."
        case .invalidOverview: "The description is too long or contains unsupported characters."
        case .invalidCover:
            "Choose a JPEG or PNG cover no larger than 8 MB and 4096 pixels per side."
        case .partialUpdate:
            "Some playlist changes may have been saved. Refresh before trying again."
        case .partialCover:
            "The cover update could not be confirmed. Refresh before trying again."
        }
    }
}

/// Bounded payload preparation only. No account, network, artwork cache or UI ownership.
enum FoundationPlaylistMetadata {
    static let maximumItemBytes = 2 * 1_024 * 1_024

    static func validateOverview(_ overview: String) throws {
        guard overview.utf8.count <= 32 * 1_024,
            !overview.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw FoundationPlaylistMetadataError.invalidOverview }
    }

    static func updatedItem(_ data: Data, id: String, name: String?, overview: String?) throws
        -> Data
    {
        guard data.count <= maximumItemBytes,
            var item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            item["Id"] as? String == id, item["Type"] as? String == "Playlist",
            item["Name"] is String, item["LockData"] is Bool
        else { throw FoundationLibraryError.invalidResponse }
        // ItemUpdate is a full metadata write. Preserve ALL returned fields, including
        // unknown fields, locks, providers, tags and dates; never synthesize an empty DTO.
        if let name { item["Name"] = name }
        if let overview { item["Overview"] = overview }
        return try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
    }

    static func publicSetting(_ data: Data) throws -> Bool? {
        if data.isEmpty { return nil }
        guard data.count <= maximumItemBytes,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FoundationLibraryError.invalidResponse }
        // Current GET wire spelling is OpenAccess; updates use IsPublic. Do not turn
        // a missing value into false or rewrite Shares/ItemIds from the GET response.
        let current = object["OpenAccess"] as? Bool
        let legacy = object["IsPublic"] as? Bool
        if let current, let legacy, current != legacy {
            throw FoundationLibraryError.invalidResponse
        }
        return current ?? legacy
    }

    static func validateCover(_ data: Data, contentType: String) throws {
        guard !data.isEmpty, data.count <= 8 * 1_024 * 1_024,
            ["image/jpeg", "image/png"].contains(contentType),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) == 1,
            let type = CGImageSourceGetType(source) as String?,
            type == (contentType == "image/png" ? "public.png" : "public.jpeg"),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            (1...4096).contains(width.intValue), (1...4096).contains(height.intValue)
        else { throw FoundationPlaylistMetadataError.invalidCover }
    }
}
