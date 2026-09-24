import Combine
import Foundation
import ImageIO
import NowPlaying

/// One account-owned result serves the current player and system artwork requests.
@MainActor
final class FoundationCurrentArtwork: ObservableObject {
    struct Result {
        let id = UUID()
        let data: Data
        let image: CGImage
    }
    private struct Key: Equatable {
        let account: UUID
        let item: String
        let tag: String?
    }
    static let maximumBytes = 2 * 1_024 * 1_024
    static let requestedPixels = 640
    @Published private(set) var result: Result?
    private(set) var updateTask: Task<Void, Never>?
    private(set) var loadTask: Task<Void, Never>?
    private let player: FoundationPlayer
    private let load: @Sendable (FoundationItem) async throws -> Data?
    private let account = UUID()
    private var key: Key?
    private var generation: UInt = 0
    private var subscriptions: Set<AnyCancellable> = []
    private var isLive = true

    init(player: FoundationPlayer, load: @escaping @Sendable (FoundationItem) async throws -> Data?)
    {
        self.player = player
        self.load = load
        Publishers.Merge(
            player.$queue.map { _ in () },
            player.$selectedEntryID.removeDuplicates().map { _ in () }
        ).sink { [weak self] in self?.scheduleUpdate() }.store(in: &subscriptions)
        refreshSelection()
    }

    isolated deinit {
        updateTask?.cancel()
        loadTask?.cancel()
    }

    /// Coalesce will-change notifications before reading the selected occurrence.
    private func scheduleUpdate() {
        guard isLive, updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.updateTask = nil
            self.refreshSelection()
        }
    }

    private func identity(_ item: FoundationItem) -> Key? {
        let imageItem = item.catalogArtworkItem
        guard imageItem.kind != .track else { return nil }
        return Key(
            account: account, item: imageItem.id,
            tag: imageItem.primaryImageTag.flatMap { $0.isEmpty ? nil : $0 })
    }

    private func refreshSelection() {
        guard isLive else { return }
        let item = player.queue.first { $0.id == player.selectedEntryID }?.item
        let nextKey = item.flatMap(identity)
        guard nextKey != key else { return }
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        key = nextKey
        result = nil
        guard nextKey != nil, let item else { return }
        let requestGeneration = generation
        let load = load
        let imageItem = item.catalogArtworkItem
        loadTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let data: Data?
                #if DEBUG
                    data = try await FoundationTrace.$context.withValue(
                        .init(origin: .nowPlaying, page: .nowPlayingArtwork)
                    ) { try await load(imageItem) }
                #else
                    data = try await load(imageItem)
                #endif
                try Task.checkCancellation()
                guard let self, self.isLive, self.generation == requestGeneration else { return }
                self.result = data.flatMap(Self.decode)
                self.loadTask = nil
            } catch {
                guard let self, self.isLive, self.generation == requestGeneration else { return }
                self.loadTask = nil
                // Artwork is optional. Keep this identity completed until selection changes.
            }
        }
    }

    /// Reject oversized input before decoding; retain at most one bounded image and payload.
    static func decode(_ data: Data) -> Result? {
        guard !data.isEmpty, data.count <= maximumBytes,
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 2_048, height <= 2_048,
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: requestedPixels,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return nil }
        return Result(data: data, image: image)
    }

    func result(for item: FoundationItem) -> Result? {
        guard isLive, key == currentSelectionKey, key == identity(item) else { return nil }
        return result
    }

    /// System size requests read the accepted result and never start or restart a download.
    func artwork(for item: FoundationItem) -> Artwork? {
        guard let result = result(for: item) else { return nil }
        let id = result.id
        return Artwork(id: id.uuidString) { [weak self] _ in
            try Task.checkCancellation()
            guard let data = await self?.data(for: id) else {
                throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable
            }
            try Task.checkCancellation()
            return try ArtworkRepresentation(data: data)
        }
    }

    private var currentSelectionKey: Key? {
        player.queue.first { $0.id == player.selectedEntryID }.flatMap { identity($0.item) }
    }

    func data(for id: UUID) -> Data? {
        guard isLive, key == currentSelectionKey, result?.id == id else { return nil }
        return result?.data
    }

    func invalidate() {
        isLive = false
        generation &+= 1
        updateTask?.cancel()
        updateTask = nil
        loadTask?.cancel()
        loadTask = nil
        subscriptions.removeAll()
        key = nil
        result = nil
    }
}
