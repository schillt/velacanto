import Combine
import Foundation

enum FoundationPinStorageError: LocalizedError {
    case couldNotRemovePins

    var errorDescription: String? { "Saved pins could not be removed from this device." }
}

/// Pin snapshots are local preferences while signed in, not account history.
enum FoundationPinStorage {
    static let keyPrefix = "Velacanto.Foundation.Pins.v1."

    static func key(for sourceScope: String) -> String { keyPrefix + sourceScope }

    /// Also removes keys left by older sign-outs for other account scopes.
    @discardableResult
    static func removeStoredPins(
        retaining sourceScope: String? = nil, defaults: UserDefaults = .standard
    ) -> Bool {
        let retainedKey = sourceScope.map(key(for:))
        let keys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(keyPrefix) && $0 != retainedKey
        }
        for key in keys { defaults.removeObject(forKey: key) }
        return keys.allSatisfy { defaults.object(forKey: $0) == nil }
    }
}

/// One source's local pins and explicit, pessimistic favorite changes.
@MainActor
final class FoundationLibraryActions: ObservableObject {
    struct FavoriteRead {
        fileprivate let owner: UUID
        fileprivate let sequence: UInt
    }

    private struct Key: Hashable {
        let id: String
        let kind: String
        init(_ item: FoundationItem) {
            id = item.id
            kind = String(describing: item.kind)
        }
    }

    private struct Pin: Codable {
        let id: String
        let kind: String
        let title: String
        let subtitle: String
        let duration: Double?
        let imageTag: String?

        init(_ item: FoundationItem) {
            id = item.id
            kind = String(describing: item.kind)
            title = item.title
            subtitle = item.subtitle
            duration = item.duration
            imageTag = item.primaryImageTag
        }

        var item: FoundationItem? {
            let type: FoundationItem.Kind
            switch kind {
            case "album": type = .album
            case "artist": type = .artist
            case "playlist": type = .playlist
            case "genre": type = .genre
            default: return nil
            }
            return FoundationItem(
                id: id, title: title, subtitle: subtitle, kind: type, duration: duration,
                primaryImageTag: imageTag)
        }
    }

    @Published private(set) var pins: [FoundationItem] = []
    @Published private(set) var favoriteRevision: UInt = 0
    @Published private var favorites: [Key: Bool] = [:]
    @Published private var observedFavorites: [Key: Bool] = [:]
    @Published private var pending: Set<Key> = []
    @Published private var errors: [Key: String] = [:]
    @Published private(set) var pinErrorMessage: String?
    @Published private(set) var isQueueLoading = false
    @Published private(set) var queueErrorMessage: String?
    @Published private(set) var queueLoadedCount = 0
    @Published private(set) var queueNotice: String?
    @Published private(set) var canRetryQueueAddition = false
    private var retryQueueAdditionAction: (() -> Void)?
    static let maximumCollectionPages = 200
    static let maximumCollectionTracks = 10_000
    private let storageKey: String
    private let write: (String, Data) throws -> Void
    private let mutateFavorite: @Sendable (FoundationItem, Bool) async throws -> Void
    private var tasks: [Key: Task<Void, Error>] = [:]
    private var favoriteReads: [UUID: Task<FoundationItem?, Error>] = [:]
    private var active = true
    private let favoriteOwner = UUID()
    private var favoriteSequence: UInt = 0
    private var favoriteVersions: [Key: UInt] = [:]
    private(set) var queueTask: Task<Void, Never>?
    private var playbackPreparation: AnyCancellable?

    init(
        sourceScope: String,
        read: (String) throws -> Data? = { UserDefaults.standard.data(forKey: $0) },
        write: @escaping (String, Data) throws -> Void = {
            UserDefaults.standard.set($1, forKey: $0)
        },
        mutateFavorite: @escaping @Sendable (FoundationItem, Bool) async throws -> Void
    ) {
        // Scope must be an opaque source/account identity, never an origin or credential.
        storageKey = FoundationPinStorage.key(for: sourceScope)
        self.write = write
        self.mutateFavorite = mutateFavorite
        do {
            if let data = try read(storageKey) {
                var seen: Set<Key> = []
                pins = try JSONDecoder().decode([Pin].self, from: data)
                    .compactMap(\.item).filter { seen.insert(Key($0)).inserted }
            }
        } catch {
            pinErrorMessage = "Saved pins could not be read."
        }
    }

    func isPinned(_ item: FoundationItem) -> Bool {
        pins.contains { Key($0) == Key(item) }
    }

    func togglePin(_ item: FoundationItem) {
        guard active, item.kind != .track else { return }
        var updated = pins
        if isPinned(item) {
            updated.removeAll { Key($0) == Key(item) }
        } else {
            updated.append(item)
        }
        do {
            try write(storageKey, JSONEncoder().encode(updated.map(Pin.init)))
            pins = updated
            pinErrorMessage = nil
        } catch {
            pinErrorMessage = "Pins could not be saved. Try again."
        }
    }

    func favoriteState(for item: FoundationItem, initial: Bool?) -> Bool? {
        favorites[Key(item)] ?? observedFavorites[Key(item)] ?? initial
    }

    /// Display membership only; keep raw server pages intact for cursors and budgets.
    func favoriteItems(in items: [FoundationItem]) -> [FoundationItem] {
        items.filter { favoriteState(for: $0, initial: $0.isFavorite) != false }
    }

    func favoriteTrackQueue(in items: [FoundationItem], selecting index: Int)
        -> (items: [FoundationItem], index: Int)?
    {
        guard items.indices.contains(index), items[index].kind == .track,
            favoriteState(for: items[index], initial: items[index].isFavorite) != false
        else { return nil }
        let tracks = favoriteItems(in: items).filter { $0.kind == .track }
        let selected = favoriteItems(in: Array(items.prefix(index))).filter { $0.kind == .track }
            .count
        return (tracks, selected)
    }

    /// Capture before starting a remote read, never when rendering retained items.
    func beginFavoriteRead() -> FavoriteRead {
        favoriteSequence &+= 1
        return FavoriteRead(owner: favoriteOwner, sequence: favoriteSequence)
    }

    /// Only reads begun after the last mutation/observation can reconcile that item.
    /// Absence from a bounded favorites page does not establish nonmembership.
    func observeFavorites(
        in items: [FoundationItem], knownFavorites: Bool = false, read: FavoriteRead
    ) {
        guard active, !Task.isCancelled, read.owner == favoriteOwner else { return }
        var updated = observedFavorites
        for item in items where item.kind != .genre {
            let key = Key(item)
            guard !pending.contains(key), read.sequence >= (favoriteVersions[key] ?? 0),
                let value = item.isFavorite ?? (knownFavorites ? true : nil)
            else { continue }
            updated[key] = value
            favoriteVersions[key] = read.sequence
            favorites[key] = nil
        }
        if updated != observedFavorites { observedFavorites = updated }
    }

    /// A visible metadata-light destination owns one cancellable detail read.
    func resolveFavorite(
        for item: FoundationItem,
        using load: @escaping @Sendable () async throws -> FoundationItem?
    ) async {
        guard active, !Task.isCancelled, item.kind == .album || item.kind == .artist,
            favoriteState(for: item, initial: item.isFavorite) == nil
        else { return }
        let read = beginFavoriteRead()
        let id = UUID()
        let operation = Task { try await load() }
        favoriteReads[id] = operation
        defer { favoriteReads[id] = nil }
        do {
            let detail = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            guard active, !Task.isCancelled, !operation.isCancelled,
                let detail, detail.id == item.id, detail.kind == item.kind,
                favoriteState(for: item, initial: item.isFavorite) == nil
            else { return }
            observeFavorites(in: [detail], read: read)
        } catch {
            // Unknown remains unknown; returning to the destination can retry explicitly.
        }
    }

    func isPending(_ item: FoundationItem) -> Bool { pending.contains(Key(item)) }
    func errorMessage(for item: FoundationItem) -> String? { errors[Key(item)] }

    func setFavorite(for item: FoundationItem, isFavorite: Bool) async {
        let key = Key(item)
        guard active, item.kind != .genre, !pending.contains(key), !Task.isCancelled else { return }
        favoriteSequence &+= 1
        favoriteVersions[key] = favoriteSequence
        pending.insert(key)
        errors[key] = nil
        let mutate = mutateFavorite
        let operation = Task { try await mutate(item, isFavorite) }
        tasks[key] = operation
        defer {
            pending.remove(key)
            tasks[key] = nil
        }
        do {
            try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            guard active, !Task.isCancelled, !operation.isCancelled else { return }
            favoriteSequence &+= 1
            favoriteVersions[key] = favoriteSequence
            favorites[key] = isFavorite
            favoriteRevision &+= 1
        } catch {
            guard active, !Task.isCancelled, !operation.isCancelled else { return }
            errors[key] = FoundationLibraryError.category(error).errorDescription
        }
    }

    /// User-requested collection expansion is sequential and commits only a complete result.
    func enqueue(
        _ item: FoundationItem, position: FoundationPlayer.QueuePosition,
        library: (any FoundationLibrary)? = nil, player: FoundationPlayer
    ) {
        guard active, !isQueueLoading else { return }
        dismissQueueOutcome()
        if item.kind == .track {
            player.enqueue([item], position: position)
            return
        }
        guard let library, item.kind == .album || item.kind == .playlist else {
            queueErrorMessage = "This item cannot be added to the queue."
            return
        }
        playbackPreparation = player.sessionChanged.sink { [weak self] in
            self?.cancelQueueAddition()
        }
        retryQueueAdditionAction = { [weak self, weak player] in
            guard let player else { return }
            self?.enqueue(item, position: position, library: library, player: player)
        }
        loadCollection(item, library: library) { player.enqueue($0, position: position) }
    }

    func play(
        _ item: FoundationItem, shuffled: Bool, library: any FoundationLibrary,
        player: FoundationPlayer
    ) {
        guard active, !isQueueLoading else { return }
        playbackPreparation = player.sessionChanged.sink { [weak self] in
            self?.cancelQueueAddition()
        }
        retryQueueAdditionAction = { [weak self, weak player] in
            guard let player else { return }
            self?.play(item, shuffled: shuffled, library: library, player: player)
        }
        loadCollection(item, library: library) { items in
            player.setQueue(shuffled ? items.shuffled() : items, selectedIndex: 0)
        }
    }

    private func loadCollection(
        _ item: FoundationItem, library: any FoundationLibrary,
        commit: @escaping ([FoundationItem]) -> Void
    ) {
        guard active, !isQueueLoading else { return }
        queueErrorMessage = nil
        queueNotice = nil
        queueLoadedCount = 0
        canRetryQueueAddition = false
        isQueueLoading = true
        queueTask = Task { [weak self] in
            // Cancellation keeps the addition occupied until this task actually finishes.
            defer {
                self?.isQueueLoading = false
                self?.queueTask = nil
                self?.playbackPreparation = nil
            }
            do {
                var items: [FoundationItem] = []
                var offset = 0
                var pages = 0
                while true {
                    guard pages < Self.maximumCollectionPages else {
                        throw CollectionLimit.reached
                    }
                    try Task.checkCancellation()
                    let page: FoundationPage
                    switch item.kind {
                    case .playlist:
                        page = try await library.playlistTracks(
                            playlistID: item.id, startIndex: offset)
                    case .artist:
                        page = try await library.tracks(artistID: item.id, startIndex: offset)
                    case .album:
                        page = try await library.tracks(albumID: item.id, startIndex: offset)
                    default: throw FoundationLibraryError.invalidResponse
                    }
                    try Task.checkCancellation()
                    guard page.items.allSatisfy({ $0.kind == .track }) else {
                        throw FoundationLibraryError.invalidResponse
                    }
                    guard page.items.count <= Self.maximumCollectionTracks - items.count else {
                        throw CollectionLimit.reached
                    }
                    items.append(contentsOf: page.items)
                    pages += 1
                    self?.queueLoadedCount = items.count
                    guard let next = page.nextStartIndex else { break }
                    guard next > offset else { throw FoundationLibraryError.invalidResponse }
                    offset = next
                }
                guard let self, self.active, !Task.isCancelled else { return }
                if items.isEmpty {
                    self.queueNotice = "This collection has no songs."
                    self.retryQueueAdditionAction = nil
                } else {
                    self.playbackPreparation = nil
                    self.retryQueueAdditionAction = nil
                    commit(items)
                }
            } catch {
                guard let self, self.active, !Task.isCancelled else { return }
                self.queueErrorMessage =
                    error is CollectionLimit
                    ? "This collection is too large to load at once. Choose a smaller collection."
                    : FoundationLibraryError.category(error).errorDescription
                self.canRetryQueueAddition = !(error is CollectionLimit)
                if error is CollectionLimit { self.retryQueueAdditionAction = nil }
            }
        }
    }

    private enum CollectionLimit: Error { case reached }

    func cancelQueueAddition() {
        retryQueueAdditionAction = nil
        canRetryQueueAddition = false
        guard isQueueLoading else { return }
        queueTask?.cancel()
        queueNotice = "Collection loading cancelled."
    }

    func retryQueueAddition() {
        guard active, !isQueueLoading, canRetryQueueAddition else { return }
        let retry = retryQueueAdditionAction
        retry?()
    }

    func dismissQueueOutcome() {
        guard !isQueueLoading else { return }
        queueErrorMessage = nil
        queueNotice = nil
        canRetryQueueAddition = false
        retryQueueAdditionAction = nil
    }

    /// Called by the source owner before replacing or dismissing this source.
    func invalidate() {
        active = false
        cancelQueueAddition()
        retryQueueAdditionAction = nil
        for task in tasks.values { task.cancel() }
        for task in favoriteReads.values { task.cancel() }
    }
}
