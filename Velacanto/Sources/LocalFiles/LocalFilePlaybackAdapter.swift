import Foundation

struct LocalFileSelection {
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
    let source = MusicSourceKind.localFiles

    func playbackRequest(for selection: LocalFileSelection) throws -> PlaybackRequest {
        guard selection.url.isFileURL else {
            throw LocalFilePlaybackError.notAFileURL
        }

        let title =
            selection.title
            ?? selection.url.deletingPathExtension().lastPathComponent
        let artist = selection.artist ?? "Local file"

        return PlaybackRequest(
            item: PlaybackItem(
                title: title.isEmpty ? "Untitled local audio" : title,
                artist: artist,
                source: source
            ),
            mediaURL: selection.url,
            resourceAccess: SecurityScopedResourceAccess(url: selection.url)
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

final class SecurityScopedResourceAccess {
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
