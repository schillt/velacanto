import Foundation

/// Resolves an authenticated Jellyfin item into a provider-neutral request.
/// It owns no catalog state; the API client is captured only by the returned
/// lifecycle reporter for as long as playback needs to report progress.
struct JellyfinPlaybackRequestResolver: Sendable {
    private let api: any JellyfinAPIService
    private let userID: String
    private let adapter = JellyfinPlaybackAdapter()

    init(api: any JellyfinAPIService, userID: String) {
        self.api = api
        self.userID = userID
    }

    func playbackRequest(for track: MusicCatalogItem) async throws -> PlaybackRequest {
        let itemID = track.id.opaqueID
        let resolution = try await api.playbackResolution(itemID: itemID, userID: userID)
        return try await adapter.playbackRequest(
            for: JellyfinTrackSelection(
                track: track,
                streamURL: resolution.streamURL,
                transportKind: resolution.playMethod.transportKind,
                reporter: reporter(itemID: itemID, resolution: resolution)
            ))
    }

    func playbackRequest(for item: PlaybackItem) async throws -> PlaybackRequest {
        let resolution = try await api.playbackResolution(itemID: item.id, userID: userID)
        return PlaybackRequest(
            item: item,
            asset: PlaybackAsset(url: resolution.streamURL),
            transportKind: resolution.playMethod.transportKind,
            reporter: reporter(itemID: item.id, resolution: resolution)
        )
    }

    private func reporter(itemID: String, resolution: JellyfinPlaybackResolution)
        -> any PlaybackLifecycleReporting
    {
        JellyfinPlaybackReporter(
            api: api,
            itemID: itemID,
            playSessionID: resolution.playSessionID,
            playMethod: resolution.playMethod
        )
    }
}
