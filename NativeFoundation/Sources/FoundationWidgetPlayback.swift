import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WidgetKit

extension FoundationWidgetSnapshot.Collection {
    init?(_ item: FoundationItem) {
        guard item.kind == .album || item.kind == .playlist else { return nil }
        self.init(
            id: item.id, kind: item.kind.rawValue,
            title: Self.text(item.title), subtitle: Self.text(item.subtitle),
            imageTag: item.primaryImageTag)
        guard isValid else { return nil }
    }

    var item: FoundationItem {
        FoundationItem(
            id: id, title: title, subtitle: subtitle,
            kind: kind == "album" ? .album : .playlist, duration: nil,
            primaryImageTag: imageTag)
    }

    private static func text(_ value: String) -> String {
        String(
            value.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            }.prefix(64))
    }
}

/// One serialized owner, one bounded metadata value and two independently fenced artwork slots.
actor FoundationWidgetStorage {
    private let store: FoundationWidgetStore
    private let reload: @Sendable () -> Void
    private var owner: UUID?
    private var scope: String?
    private var generation: UInt64 = 0
    private var retired = false
    private var sequence: UInt64 = 0
    private var metadata: FoundationWidgetSnapshot?
    private var currentRevision: UUID?
    private var publishedCurrentRevision: UUID?
    private var publishedRecent: FoundationWidgetSnapshot.Collection?

    init(
        location: FoundationWidgetStore.Location,
        reload: @escaping @Sendable () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: FoundationWidgetSnapshot.kind)
        }
    ) {
        store = .init(location: location)
        if case .disabled = location { self.reload = {} } else { self.reload = reload }
    }

    func activate(owner: UUID, scope: String, generation: UInt64) throws {
        try Task.checkCancellation()
        guard
            generation > self.generation
                || (generation == self.generation && self.owner == owner && !retired)
        else { throw FoundationWidgetStore.Failure.unavailable }
        if generation > self.generation {
            self.generation = generation
            self.owner = owner
            self.scope = scope
            retired = false
            sequence = 0
            metadata = nil
            currentRevision = nil
            publishedCurrentRevision = nil
            publishedRecent = nil
        }
    }

    @discardableResult
    func publishMetadata(
        owner: UUID, sequence: UInt64, snapshot: FoundationWidgetSnapshot,
        currentRevision: UUID?
    ) -> Bool {
        guard self.owner == owner, !retired, !Task.isCancelled,
            snapshot.scope == scope || snapshot.presentation == .empty
        else { return false }
        guard sequence >= self.sequence else { return metadata != nil }
        do {
            let currentChanged =
                metadata?.occurrence != snapshot.occurrence
                || self.currentRevision != currentRevision
            let changed = metadata != snapshot || currentChanged
            if changed {
                try store.save(snapshot, artwork: nil, preservingCurrentArtwork: !currentChanged)
            }
            if currentChanged { publishedCurrentRevision = nil }
            if snapshot.recentCollection?.sameArtwork(as: metadata?.recentCollection) != true {
                publishedRecent = nil
            }
            metadata = snapshot
            self.currentRevision = currentRevision
            self.sequence = sequence
            if changed { reload() }
            return true
        } catch { return false }
    }

    @discardableResult
    func publishCurrentArtwork(owner: UUID, occurrence: UUID, revision: UUID, data: Data) -> Bool {
        guard self.owner == owner, !retired, !Task.isCancelled, let metadata,
            metadata.presentation == .track, metadata.occurrence == occurrence,
            currentRevision == revision
        else { return false }
        if publishedCurrentRevision == revision { return true }
        guard let image = Self.thumbnail(data) else { return false }
        do {
            try store.save(metadata, artwork: image)
            publishedCurrentRevision = revision
            reload()
            return true
        } catch { return false }
    }

    @discardableResult
    func publishRecentArtwork(
        owner: UUID, collection: FoundationWidgetSnapshot.Collection,
        data: Data
    ) -> Bool {
        guard self.owner == owner, !retired, !Task.isCancelled, let metadata,
            metadata.recentCollection?.sameArtwork(as: collection) == true
        else { return false }
        if publishedRecent?.sameArtwork(as: collection) == true { return true }
        guard let image = Self.thumbnail(data) else { return false }
        do {
            try store.save(metadata, artwork: nil, recentArtwork: image)
            publishedRecent = collection
            reload()
            return true
        } catch { return false }
    }

    func retire(owner: UUID, generation: UInt64) {
        guard generation >= self.generation else { return }
        if generation == self.generation, self.owner != owner { return }
        self.generation = generation
        self.owner = owner
        retired = true
    }

    func clear(scope: String) -> Bool {
        if self.scope == scope { retired = true }
        let removed = store.clear(scope: scope)
        reload()
        return removed
    }

    private static func thumbnail(_ data: Data?) -> Data? {
        guard let data, data.count <= FoundationCurrentArtwork.maximumBytes,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 320,
                ] as CFDictionary)
        else { return nil }
        let result = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                result, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
            result.length <= FoundationWidgetSnapshot.maximumArtworkBytes
        else { return nil }
        return result as Data
    }
}

enum FoundationWidgetCommandOutcome: Equatable, Sendable {
    case accepted, acceptedWithPublicationFailure
}

/// One coalesced metadata worker plus one optional recent-art consumer, both exactly retired.
@MainActor
final class FoundationWidgetPlayback {
    let owner = UUID()
    private let ownerGeneration: UInt64
    private let scope: String
    private let player: FoundationPlayer
    private let artwork: FoundationCurrentArtwork
    private let storage: FoundationWidgetStorage
    private let collectionArtwork: @Sendable (FoundationItem) async throws -> Data?
    private var subscriptions: Set<AnyCancellable> = []
    private var task: Task<Void, Never>?
    private var pending = false
    private var live = true
    private var sequence: UInt64 = 0
    private var recentTask: Task<Void, Never>?
    private var recentTaskID: UUID?
    private var recentFinished = false
    private var requestedRecent: FoundationWidgetSnapshot.Collection?
    private var desiredRecent: FoundationWidgetSnapshot.Collection?
    private var attemptedRecent: FoundationWidgetSnapshot.Collection?

    init(
        scope: String, generation: UInt64, player: FoundationPlayer,
        artwork: FoundationCurrentArtwork, storage: FoundationWidgetStorage,
        collectionArtwork: @escaping @Sendable (FoundationItem) async throws -> Data?
    ) {
        ownerGeneration = generation
        self.scope = scope
        self.player = player
        self.artwork = artwork
        self.storage = storage
        self.collectionArtwork = collectionArtwork
        Publishers.MergeMany(
            player.$queue.map { _ in () }.eraseToAnyPublisher(),
            player.$selectedEntryID.map { _ in () }.eraseToAnyPublisher(),
            player.$state.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            player.$wantsPlayback.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            artwork.$result.map { _ in () }.eraseToAnyPublisher()
        ).sink { [weak self] in self?.schedule() }.store(in: &subscriptions)
    }

    isolated deinit {
        task?.cancel()
        recentTask?.cancel()
    }

    @discardableResult
    func invalidate() -> Task<Void, Never> {
        live = false
        subscriptions.removeAll()
        let publication = task
        let recent = recentTask
        publication?.cancel()
        recent?.cancel()
        let storage = storage
        let owner = owner
        let generation = ownerGeneration
        return Task {
            await publication?.value
            await recent?.value
            await storage.retire(owner: owner, generation: generation)
        }
    }

    func refresh() {
        guard live else { return }
        attemptedRecent = nil
        schedule()
    }

    /// Does not join the worker, artwork consumer, queue resolution or audio session.
    func flushMetadata() async -> Bool {
        guard live, !Task.isCancelled else { return false }
        let snapshot = Self.snapshot(scope: scope, player: player)
        desiredRecent = snapshot.recentCollection
        if recentTask != nil, requestedRecent?.sameArtwork(as: desiredRecent) != true {
            recentTask?.cancel()
        }
        sequence &+= 1
        let revision = sequence
        let artworkRevision = currentArtworkResult()?.revision
        do {
            try await storage.activate(owner: owner, scope: scope, generation: ownerGeneration)
        } catch { return false }
        guard live, !Task.isCancelled else { return false }
        let published = await storage.publishMetadata(
            owner: owner, sequence: revision, snapshot: snapshot, currentRevision: artworkRevision)
        return live && published
    }

    private func schedule() {
        guard live else { return }
        pending = true
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            while self.live, !Task.isCancelled, self.pending {
                self.pending = false
                await self.publish()
            }
        }
    }

    private func currentArtworkResult() -> FoundationCurrentArtwork.Result? {
        guard let current = player.queue.first(where: { $0.id == player.selectedEntryID }) else {
            return nil
        }
        return artwork.result(for: current.item)
    }

    private func publish() async {
        let current = Self.snapshot(scope: scope, player: player)
        let result = currentArtworkResult()
        let revision = result?.revision
        let data = result?.data
        guard await flushMetadata(), live, !Task.isCancelled else { return }
        if current == Self.snapshot(scope: scope, player: player),
            let occurrence = current.occurrence, let revision, let data,
            let selected = player.queue.first(where: { $0.id == occurrence }),
            artwork.provider(for: selected.item) != nil
        {
            await storage.publishCurrentArtwork(
                owner: owner, occurrence: occurrence, revision: revision, data: data)
        }
        guard live, !Task.isCancelled else { return }
        await reconcileRecent()
    }

    private func reconcileRecent() async {
        if recentFinished, let completed = recentTask {
            // Only a finished callback admits this join; a held optional consumer never
            // blocks publication. Retain its exact handle until it has actually returned.
            await completed.value
            recentTask = nil
            recentTaskID = nil
            recentFinished = false
            requestedRecent = nil
        }
        guard live, !Task.isCancelled else { return }
        if let recentTask {
            if requestedRecent?.sameArtwork(as: desiredRecent) != true { recentTask.cancel() }
            return
        }
        guard let desiredRecent,
            attemptedRecent?.sameArtwork(as: desiredRecent) != true
        else { return }
        let id = UUID()
        recentTaskID = id
        requestedRecent = desiredRecent
        let load = collectionArtwork
        recentTask = Task { [weak self] in
            let data: Data?
            if Task.isCancelled { data = nil } else { data = try? await load(desiredRecent.item) }
            guard let self else { return }
            if self.live, !Task.isCancelled,
                self.desiredRecent?.sameArtwork(as: desiredRecent) == true, let data
            {
                await self.storage.publishRecentArtwork(
                    owner: self.owner, collection: desiredRecent, data: data)
            }
            guard self.recentTaskID == id else { return }
            if !Task.isCancelled { self.attemptedRecent = desiredRecent }
            self.recentFinished = true
            self.schedule()
        }
    }

    static func snapshot(scope: String, player: FoundationPlayer) -> FoundationWidgetSnapshot {
        if let selected = player.queue.first(where: { $0.id == player.selectedEntryID }) {
            return .init(
                version: 1, presentation: .track, scope: scope, occurrence: selected.id,
                collection: player.playbackCollection, title: text(selected.item.title),
                detail: text(selected.item.subtitle), isPlaying: player.wantsPlayback,
                recentCollection: player.lastPlaybackCollection)
        }
        if let recent = player.lastPlaybackCollection {
            return .init(
                version: 1, presentation: .collection, scope: scope, occurrence: nil,
                collection: recent, title: recent.title, detail: recent.subtitle,
                isPlaying: false, recentCollection: recent)
        }
        return .empty
    }

    private static func text(_ value: String) -> String {
        String(
            value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(128)
        )
    }
}
