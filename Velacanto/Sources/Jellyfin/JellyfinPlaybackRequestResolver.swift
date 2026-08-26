import Foundation

/// Resolves an authenticated Jellyfin item into a provider-neutral request.
/// It owns no catalog state; the API client is captured only by the returned
/// lifecycle reporter for as long as playback needs to report progress.
struct JellyfinPlaybackRequestResolver: Sendable {
    private let api: any JellyfinAPIService
    private let userID: String
    private let adapter = JellyfinPlaybackAdapter()

    init(
        api: any JellyfinAPIService,
        userID: String
    ) {
        self.api = api
        self.userID = userID
    }

    func playbackRequest(for track: MusicCatalogItem) async throws -> PlaybackRequest {
        let itemID = track.id.opaqueID
        let result = try await resolution(
            itemID: itemID,
            container: track.container
        )
        let fallback: (@Sendable () async throws -> PlaybackRequest)? = nil
        return try await adapter.playbackRequest(
            for: JellyfinTrackSelection(
                track: track,
                streamURL: result.resolution.streamURL,
                transportKind: result.resolution.playMethod.transportKind,
                reporter: reporter(
                    itemID: itemID,
                    resolution: result.resolution
                )
            ),
            forcedPlaybackInfoFallback: fallback
        )
    }

    func playbackRequest(for item: PlaybackItem) async throws -> PlaybackRequest {
        let result = try await resolution(
            itemID: item.id,
            container: item.container
        )
        let fallback: (@Sendable () async throws -> PlaybackRequest)? = nil
        return request(
            for: item,
            resolution: result.resolution,
            forcedPlaybackInfoFallback: fallback
        )
    }

    private struct ResolutionResult {
        let resolution: JellyfinPlaybackResolution
        let usedDirectFile: Bool
    }

    private func resolution(
        itemID: String,
        container: String?
    ) async throws -> ResolutionResult {
        if let container,
            let direct = try await api.directPlaybackResolution(
                itemID: itemID,
                container: container
            )
        {
            return ResolutionResult(
                resolution: direct,
                usedDirectFile: true
            )
        }
        return ResolutionResult(
            resolution: try await api.playbackResolution(
                itemID: itemID,
                userID: userID
            ),
            usedDirectFile: false
        )
    }

    private func playbackInfoRequest(
        for item: PlaybackItem
    ) async throws -> PlaybackRequest {
        let resolution = try await api.playbackResolution(
            itemID: item.id,
            userID: userID
        )
        return request(
            for: item,
            resolution: resolution,
            forcedPlaybackInfoFallback: nil
        )
    }

    private func playbackInfoRequest(
        for track: MusicCatalogItem
    ) async throws -> PlaybackRequest {
        let resolution = try await api.playbackResolution(
            itemID: track.id.opaqueID,
            userID: userID
        )
        let request = try await adapter.playbackRequest(
            for: JellyfinTrackSelection(
                track: track,
                streamURL: resolution.streamURL,
                transportKind: resolution.playMethod.transportKind,
                reporter: reporter(
                    itemID: track.id.opaqueID,
                    resolution: resolution
                )
            )
        )
        guard let container = resolution.container else { return request }
        return PlaybackRequest(
            item: request.item.replacingContainer(container),
            asset: request.asset,
            transportKind: request.transportKind,
            recordsHistory: request.recordsHistory,
            reporter: request.reporter
        )
    }

    private func request(
        for item: PlaybackItem,
        resolution: JellyfinPlaybackResolution,
        forcedPlaybackInfoFallback:
            (@Sendable () async throws -> PlaybackRequest)?
    ) -> PlaybackRequest {
        let enrichedItem: PlaybackItem
        if let container = resolution.container {
            enrichedItem = item.replacingContainer(container)
        } else {
            enrichedItem = item
        }
        return PlaybackRequest(
            item: enrichedItem,
            asset: PlaybackAsset(url: resolution.streamURL),
            transportKind: resolution.playMethod.transportKind,
            reporter: reporter(itemID: item.id, resolution: resolution),
            forcedPlaybackInfoFallback: forcedPlaybackInfoFallback
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
