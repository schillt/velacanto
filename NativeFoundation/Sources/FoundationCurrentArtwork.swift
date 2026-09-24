import Combine
import Foundation
import ImageIO
import NowPlaying

/// One account-owned result serves the current player and system artwork requests.
@MainActor
final class FoundationCurrentArtwork: ObservableObject {
    struct Result {
        let id: UUID
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
    private var artworkID: UUID?
    private var generation: UInt = 0
    private var subscriptions: Set<AnyCancellable> = []
    private var isLive = true
    #if DEBUG
        var diagnosticCompletionDelay: (@Sendable () async throws -> Void)?
        private var diagnosticIdentityCount = 0
    #endif

    init(player: FoundationPlayer, load: @escaping @Sendable (FoundationItem) async throws -> Data?)
    {
        self.player = player
        self.load = load
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-foundationDelayedArtwork") {
                diagnosticCompletionDelay = { try await Task.sleep(for: .seconds(15)) }
            }
        #endif
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
        artworkID = nextKey == nil ? nil : UUID()
        result = nil
        guard artworkID != nil, let item else { return }
        #if DEBUG
            diagnosticIdentityCount += 1
            let completionDelay = diagnosticIdentityCount == 2 ? diagnosticCompletionDelay : nil
        #endif
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
                #if DEBUG
                    if let completionDelay {
                        FoundationJournal.shared.record("artwork.diagnostic event=delayStarted")
                        do {
                            try await completionDelay()
                            FoundationJournal.shared.record(
                                "artwork.diagnostic event=delayReturned outcome=completed")
                        } catch {
                            FoundationJournal.shared.record(
                                "artwork.diagnostic event=delayReturned outcome=\(error is CancellationError ? "cancelled" : "failed")"
                            )
                            throw error
                        }
                    }
                #endif
                try Task.checkCancellation()
                guard let self, self.isLive, self.generation == requestGeneration else { return }
                self.result = data.flatMap { Self.decode($0) }
                #if DEBUG
                    let outcome =
                        self.result != nil ? "ready" : (data == nil ? "missing" : "rejected")
                    FoundationJournal.shared.record(
                        "artwork.shared generation=\(requestGeneration) outcome=\(outcome)")
                #endif
                self.loadTask = nil
            } catch {
                guard let self, self.isLive, self.generation == requestGeneration else { return }
                self.loadTask = nil
                #if DEBUG
                    FoundationJournal.shared.record(
                        "artwork.shared generation=\(requestGeneration) outcome=\(Task.isCancelled ? "cancelled" : "failed")"
                    )
                #endif
                // Artwork is optional. Keep this identity completed until selection changes.
            }
        }
    }

    /// Reject oversized input before decoding; retain at most one bounded image and payload.
    static func decode(_ data: Data, id: UUID = UUID()) -> Result? {
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
        return Result(id: id, data: data, image: image)
    }

    func result(for item: FoundationItem) -> Result? {
        guard isLive, key == currentSelectionKey, key == identity(item) else { return nil }
        return result
    }

    /// Publish the asynchronous provider immediately; late bytes complete the same system request.
    func artwork(for item: FoundationItem) -> Artwork? {
        guard let artworkID, let provider = provider(for: item) else { return nil }
        // A completed representation gets one cache revision; its load ownership stays unchanged.
        let representationID = result?.id ?? artworkID
        return Artwork(id: representationID.uuidString, artworkProvider: provider)
    }

    /// Size requests share the owned load. Cancelling one consumer never cancels that useful load.
    func provider(for item: FoundationItem)
        -> (@Sendable (CGSize) async throws -> ArtworkRepresentation)?
    {
        guard isLive, key == currentSelectionKey, key == identity(item), let artworkID else {
            return nil
        }
        #if DEBUG
            let providerGeneration = generation
        #endif
        return { [weak self] _ in
            #if DEBUG
                var stage = "admission"
                FoundationJournal.shared.record(
                    "artwork.provider generation=\(providerGeneration) event=entered")
            #endif
            do {
                try Task.checkCancellation()
                let pending = try await self?.pendingLoad(for: artworkID)
                #if DEBUG
                    stage = "waiting"
                    FoundationJournal.shared.record(
                        "artwork.provider generation=\(providerGeneration) event=waitStarted pending=\(pending == nil ? 0 : 1)"
                    )
                #endif
                await pending?.value
                #if DEBUG
                    stage = "currentResult"
                    FoundationJournal.shared.record(
                        "artwork.provider generation=\(providerGeneration) event=waitReturned")
                #endif
                try Task.checkCancellation()
                guard let data = await self?.dataForLoad(artworkID) else {
                    throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable
                }
                try Task.checkCancellation()
                #if DEBUG
                    stage = "representation"
                #endif
                let representation = try ArtworkRepresentation(data: data)
                #if DEBUG
                    FoundationJournal.shared.record(
                        "artwork.provider generation=\(providerGeneration) event=returned outcome=success"
                    )
                #endif
                return representation
            } catch {
                #if DEBUG
                    FoundationJournal.shared.record(
                        "artwork.provider generation=\(providerGeneration) event=returned stage=\(stage) outcome=\(error is CancellationError ? "cancelled" : "unavailable")"
                    )
                #endif
                throw error
            }
        }
    }

    #if DEBUG
        var diagnosticState: String {
            guard isLive, key == currentSelectionKey, artworkID != nil else { return "absent" }
            if result != nil { return "ready" }
            return loadTask == nil ? "unavailable" : "pending"
        }
    #endif

    private func pendingLoad(for id: UUID) throws -> Task<Void, Never>? {
        guard isLive, key == currentSelectionKey, artworkID == id else {
            throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable
        }
        return loadTask
    }

    private func dataForLoad(_ id: UUID) -> Data? {
        guard isLive, key == currentSelectionKey, artworkID == id else { return nil }
        return result?.data
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
        artworkID = nil
        result = nil
    }
}
