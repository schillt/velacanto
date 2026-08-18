import Foundation

struct JellyfinTrackSelection: Sendable {
    let track: MusicCatalogItem
    let streamURL: URL
    let transportKind: PlaybackTransportKind
    let reporter: (any PlaybackLifecycleReporting)?

    init(
        track: MusicCatalogItem,
        streamURL: URL,
        transportKind: PlaybackTransportKind,
        reporter: (any PlaybackLifecycleReporting)? = nil
    ) {
        self.track = track
        self.streamURL = streamURL
        self.transportKind = transportKind
        self.reporter = reporter
    }
}

struct JellyfinPlaybackAdapter: PlaybackSourceAdapter {
    let source = MusicSourceID.jellyfin

    static func playbackItem(for track: MusicCatalogItem) -> PlaybackItem {
        playbackItem(for: track, fallbackArtistID: nil)
    }

    static func playbackItem(
        for track: MusicCatalogItem,
        fallbackArtistID: String?
    ) -> PlaybackItem {
        PlaybackItem(
            id: track.id.opaqueID,
            title: track.name,
            artist: track.displayArtist,
            albumTitle: track.album,
            albumID: track.albumID,
            artistID: track.artistIDs.first ?? fallbackArtistID,
            source: .jellyfin,
            artworkItemID: track.artworkItemID,
            artworkTag: track.primaryImageTag,
            duration: track.duration,
            isFavorite: track.isFavorite
        )
    }

    func playbackRequest(for selection: JellyfinTrackSelection) async throws -> PlaybackRequest {
        guard !selection.streamURL.isFileURL else {
            throw JellyfinPlaybackError.invalidStreamURL
        }

        return PlaybackRequest(
            item: Self.playbackItem(for: selection.track),
            asset: PlaybackAsset(url: selection.streamURL),
            transportKind: selection.transportKind,
            reporter: selection.reporter
        )
    }
}

struct JellyfinPlaybackReporter: PlaybackLifecycleReporting {
    let api: any JellyfinAPIService
    let itemID: String
    let playSessionID: String
    let playMethod: JellyfinPlaybackMethod

    func reportStarted(at position: TimeInterval) async throws {
        try await api.reportPlaybackStarted(
            itemID: itemID,
            playSessionID: playSessionID,
            positionTicks: ticks(for: position),
            playMethod: playMethod
        )
    }

    func reportProgress(
        at position: TimeInterval,
        isPaused: Bool
    ) async throws {
        try await api.reportPlaybackProgress(
            itemID: itemID,
            playSessionID: playSessionID,
            positionTicks: ticks(for: position),
            isPaused: isPaused,
            playMethod: playMethod
        )
    }

    func reportStopped(at position: TimeInterval) async throws {
        try await api.reportPlaybackStopped(
            itemID: itemID,
            playSessionID: playSessionID,
            positionTicks: ticks(for: position),
            playMethod: playMethod
        )
    }

    private func ticks(for position: TimeInterval) -> Int64 {
        guard position.isFinite, position > 0 else { return 0 }
        let ticks = position * 10_000_000
        return ticks >= Double(Int64.max) ? Int64.max : Int64(ticks)
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
