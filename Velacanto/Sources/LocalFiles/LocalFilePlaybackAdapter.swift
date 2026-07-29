import Foundation

struct LocalFileSelection: Sendable {
    let url: URL
    let title: String?
    let artist: String?

    init(url: URL, title: String? = nil, artist: String? = nil) {
        self.url = url
        self.title = title
        self.artist = artist
    }
}

struct LocalFilePlaybackAdapter: PlaybackSourceAdapter {
    let source = MusicSourceID.localFiles

    func playbackRequest(for selection: LocalFileSelection) async throws -> PlaybackRequest {
        guard selection.url.isFileURL else {
            throw LocalFilePlaybackError.notAFileURL
        }

        let title =
            selection.title
            ?? selection.url.deletingPathExtension().lastPathComponent
        let artist = selection.artist ?? "Local file"
        let resourceLease = SecurityScopedResourceAccess(url: selection.url)

        return PlaybackRequest(
            item: PlaybackItem(
                title: title.isEmpty ? "Untitled local audio" : title,
                artist: artist,
                source: source
            ),
            asset: PlaybackAsset(
                url: selection.url,
                resourceLease: resourceLease
            )
        )
    }
}

enum LocalFilePlaybackError: LocalizedError {
    case notAFileURL

    var errorDescription: String? {
        switch self {
        case .notAFileURL:
            "Local Files can only open an audio file stored on this device."
        }
    }
}

final class SecurityScopedResourceAccess: PlaybackResourceLease, @unchecked Sendable {
    private let url: URL
    private let didStartAccessing: Bool

    init(url: URL) {
        self.url = url
        didStartAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
