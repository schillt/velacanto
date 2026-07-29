import Foundation

struct JellyfinTrackSelection: Sendable {
    let track: JellyfinItem
    let streamURL: URL
}

struct JellyfinPlaybackAdapter: PlaybackSourceAdapter {
    let source = MusicSourceID.jellyfin

    func playbackRequest(for selection: JellyfinTrackSelection) async throws -> PlaybackRequest {
        guard !selection.streamURL.isFileURL else {
            throw JellyfinPlaybackError.invalidStreamURL
        }

        return PlaybackRequest(
            item: PlaybackItem(
                id: selection.track.id,
                title: selection.track.name,
                artist: selection.track.displayArtist,
                albumTitle: selection.track.album,
                source: source
            ),
            asset: PlaybackAsset(url: selection.streamURL)
        )
    }
}

enum JellyfinPlaybackError: LocalizedError {
    case invalidStreamURL

    var errorDescription: String? {
        switch self {
        case .invalidStreamURL:
            "Jellyfin did not provide a valid remote audio stream."
        }
    }
}
