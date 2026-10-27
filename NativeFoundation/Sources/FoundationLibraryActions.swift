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
            ($0.hasPrefix(keyPrefix) && $0 != retainedKey)
                || ($0.hasPrefix(FoundationPinSync.storagePrefix)
                    && $0 != sourceScope.map { FoundationPinSync.storagePrefix + $0 })
        }
        for key in keys { defaults.removeObject(forKey: key) }
        return keys.allSatisfy { defaults.object(forKey: $0) == nil }
    }
}

/// One source's local pins and explicit, pessimistic favorite changes.
@MainActor
final class FoundationLibraryActions: ObservableObject {
    enum CollectionOperation: Sendable, Equatable { case playback, enqueue }

    /// Native presenters retain a snapshot without discarding its account-owned retry.
    struct CollectionOutcome: Equatable {
        fileprivate let owner: UUID?
        fileprivate let revision: UInt
        let message: String
        let isError: Bool
        let canRetry: Bool
    }

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
    @Published private(set) var queueOperation: CollectionOperation?
    @Published private(set) var isQueueLoading = false
    @Published private(set) var queueErrorMessage: String?
    @Published private(set) var queueLoadedCount = 0
    @Published private(set) var queueNotice: String?
    @Published private(set) var canRetryQueueAddition = false
    private var retryQueueAdditionAction: (() -> Void)?
    static let maximumCollectionPages = 200
    static let maximumCollectionTracks = 10_000
    private let showDuplicateAlbumTracks: @MainActor () -> Bool
    private var canonicalTracks: [FoundationAlbumTrackPolicy.Key: FoundationItem] = [:]
    private var knownTrackKeys: [String: FoundationAlbumTrackPolicy.Key] = [:]
    private var trackPreferenceObservation: AnyCancellable?
    private var trackAvailability: (FoundationItem) -> Bool = { _ in true }
    func refreshTrackVisibility() {
        guard active else { return }
        trackVisibilityRevision += 1
    }
    func configureTrackAvailability(_ availability: @escaping (FoundationItem) -> Bool) {
        trackAvailability = availability
        trackVisibilityRevision += 1
    }
    @Published private(set) var trackVisibilityRevision = 0
    private let storageKey: String
    private let write: (String, Data) throws -> Void
    private let mutateFavorite: @Sendable (FoundationItem, Bool) async throws -> Void
    private var tasks: [Key: Task<Void, Error>] = [:]
    private var favoriteReads: [UUID: Task<FoundationItem?, Error>] = [:]
    private var active = true
    private(set) var pinSync: FoundationPinSync?
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
        showDuplicateAlbumTracks: @escaping @MainActor () -> Bool = { false },
        trackPreferences: FoundationPlaybackPreferences? = nil,
        mutateFavorite: @escaping @Sendable (FoundationItem, Bool) async throws -> Void
    ) {
        // Scope must be an opaque source/account identity, never an origin or credential.
        storageKey = FoundationPinStorage.key(for: sourceScope)
        self.write = write
        self.showDuplicateAlbumTracks =
            trackPreferences.map { preferences in
                { preferences.showDuplicateAlbumTracks }
            } ?? showDuplicateAlbumTracks
        self.mutateFavorite = mutateFavorite
        trackPreferenceObservation = trackPreferences?.$showDuplicateAlbumTracks.dropFirst().sink {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.trackVisibilityRevision += 1 }
        }
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
            pinSync?.pinsChanged()
            pinErrorMessage = nil
        } catch {
            pinErrorMessage = "Pins could not be saved. Try again."
        }
    }

    func canMovePin(_ item: FoundationItem, earlier: Bool) -> Bool {
        guard active, let index = pins.firstIndex(where: { Key($0) == Key(item) }) else {
            return false
        }
        return earlier ? index > 0 : index + 1 < pins.count
    }

    func movePin(_ item: FoundationItem, earlier: Bool) {
        guard canMovePin(item, earlier: earlier),
            let index = pins.firstIndex(where: { Key($0) == Key(item) })
        else { return }
        var updated = pins
        updated.swapAt(index, index + (earlier ? -1 : 1))
        do {
            try write(storageKey, JSONEncoder().encode(updated.map(Pin.init)))
            pins = updated
            pinSync?.pinsChanged()
            pinErrorMessage = nil
        } catch {
            pinErrorMessage = "Pin order could not be saved. Try again."
        }
    }

    func configurePinSync(
        sourceScope: String, containerIdentifier: String?,
        resolve: @escaping (FoundationItem) async throws -> FoundationItem?
    ) {
        pinSync?.invalidate()
        pinSync = FoundationPinSync(
            scope: sourceScope, containerIdentifier: containerIdentifier,
            currentPins: { [weak self] in
                self?.pins.map { .init(id: $0.id, kind: String(describing: $0.kind)) } ?? []
            },
            apply: { [weak self] identities, isCurrent in
                guard let self, self.active, isCurrent() else { return }
                var resolved: [FoundationItem] = []
                for identity in identities {
                    guard self.active, isCurrent() else { return }
                    if let existing = self.pins.first(where: {
                        $0.id == identity.id && String(describing: $0.kind) == identity.kind
                    }) {
                        resolved.append(existing)
                        continue
                    }
                    let kind: FoundationItem.Kind
                    switch identity.kind {
                    case "album": kind = .album
                    case "artist": kind = .artist
                    case "playlist": kind = .playlist
                    case "genre": kind = .genre
                    default: continue
                    }
                    let reference = FoundationItem(
                        id: identity.id, title: "", subtitle: "", kind: kind, duration: nil)
                    if let item = try await resolve(reference),
                        item.id == identity.id, item.kind == kind
                    {
                        resolved.append(item)
                    }
                }
                guard self.active, isCurrent() else { return }
                try self.write(self.storageKey, JSONEncoder().encode(resolved.map(Pin.init)))
                self.pins = resolved
            })
    }

    func favoriteState(for item: FoundationItem, initial: Bool?) -> Bool? {
        favorites[Key(item)] ?? observedFavorites[Key(item)] ?? initial
    }

    /// Display membership only; keep raw server pages intact for cursors and budgets.
    func favoriteItems(in items: [FoundationItem]) -> [FoundationItem] {
        items.filter { favoriteState(for: $0, initial: $0.isFavorite) != false }
    }

    func favoriteTrackQueue(
        in items: [FoundationItem], selecting index: Int,
        isAvailable: (FoundationItem) -> Bool = { _ in true }
    ) -> FoundationTrackQueueSelection? {
        FoundationTrackQueueSelection(in: items, selecting: index) {
            favoriteState(for: $0, initial: $0.isFavorite) != false && isAvailable($0)
        }
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
        guard active, item.kind != .genre, !pending.contains(key), !Task.isCancelled,
            !visibleTracks([item]).isEmpty
        else { return }
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

    /// Learn only supplied, bounded metadata. No catalog fetch or server mutation occurs here.
    func observeTrackCopies(_ items: [FoundationItem], albumID: String? = nil) {
        guard active else { return }
        var changed = false
        for item in items {
            guard let key = FoundationAlbumTrackPolicy.key(for: item, albumID: albumID) else {
                continue
            }
            if canonicalTracks[key] == nil, canonicalTracks.count < Self.maximumCollectionTracks {
                canonicalTracks[key] = item
                changed = true
            }
            if knownTrackKeys[item.id] == nil,
                knownTrackKeys.count < Self.maximumCollectionTracks * 2
            {
                knownTrackKeys[item.id] = key
                changed = true
            }
        }
        if changed { trackVisibilityRevision += 1 }
    }

    /// A reversible read projection; raw pages, mutation identities and saved files stay intact.
    func visibleTracks(
        _ items: [FoundationItem], albumID: String? = nil,
        isAvailable: ((FoundationItem) -> Bool)? = nil
    ) -> [FoundationItem] {
        guard !showDuplicateAlbumTracks() else { return items }
        let isAvailable = isAvailable ?? trackAvailability
        let eligible = items.filter { item in
            guard
                let key = FoundationAlbumTrackPolicy.key(for: item, albumID: albumID)
                    ?? knownTrackKeys[item.id], let canonical = canonicalTracks[key]
            else { return true }
            return canonical.id == item.id || (!isAvailable(canonical) && isAvailable(item))
        }
        return FoundationAlbumTrackPolicy.visibleTracks(
            eligible, albumID: albumID, showDuplicates: false, isAvailable: isAvailable)

    }

    func collectionTracks(
        _ items: [FoundationItem], for collection: FoundationItem,
        isAvailable: ((FoundationItem) -> Bool)? = nil
    ) -> [FoundationItem] {
        let albumID = collection.kind == .album ? collection.id : nil
        observeTrackCopies(items, albumID: albumID)
        return visibleTracks(items, albumID: albumID, isAvailable: isAvailable)
    }

    /// User-requested collection expansion is sequential and commits only a complete result.
    func enqueue(
        _ item: FoundationItem, position: FoundationPlayer.QueuePosition,
        library: (any FoundationLibrary)? = nil, player: FoundationPlayer,
        owner: UUID? = nil
    ) {
        guard active, !isQueueLoading else { return }
        queueActionRevision &+= 1
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
            self?.enqueue(item, position: position, library: library, player: player, owner: owner)
        }
        loadCollection(item, library: library, operation: .enqueue, owner: owner) {
            player.enqueue($0, position: position)
        }
    }

    func play(
        _ item: FoundationItem, shuffled: Bool, library: any FoundationLibrary,
        player: FoundationPlayer, owner: UUID? = nil, shouldCommit: (() -> Bool)? = nil
    ) {
        guard active, !isQueueLoading else { return }
        queueActionRevision &+= 1
        playbackPreparation = player.sessionChanged.sink { [weak self] in
            self?.cancelQueueAddition()
        }
        retryQueueAdditionAction = { [weak self, weak player] in
            guard let player else { return }
            self?.play(
                item, shuffled: shuffled, library: library, player: player, owner: owner,
                shouldCommit: shouldCommit)
        }
        loadCollection(item, library: library, operation: .playback, owner: owner) { items in
            guard shouldCommit?() ?? true else { return }
            player.setQueue(shuffled ? items.shuffled() : items, selectedIndex: 0)
        }
    }

    private func loadCollection(
        _ item: FoundationItem, library: any FoundationLibrary, operation: CollectionOperation,
        owner: UUID?,
        commit: @escaping ([FoundationItem]) -> Void
    ) {
        guard active, !isQueueLoading else { return }
        queueErrorMessage = nil
        queueNotice = nil
        queueLoadedCount = 0
        canRetryQueueAddition = false
        queueOperation = operation
        queueOwner = owner
        isQueueLoading = true
        queueTask = Task { [weak self] in
            // Cancellation keeps the addition occupied until this task actually finishes.
            defer {
                self?.isQueueLoading = false
                self?.queueOperation = nil
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
                    page = try await FoundationRequestIntent.$isPlayback.withValue(
                        operation == .playback
                    ) {
                        switch item.kind {
                        case .playlist:
                            return try await library.playlistTracks(
                                playlistID: item.id, startIndex: offset)
                        case .artist:
                            return try await library.tracks(artistID: item.id, startIndex: offset)
                        case .album:
                            return try await library.tracks(albumID: item.id, startIndex: offset)
                        default: throw FoundationLibraryError.invalidResponse
                        }
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
                    let selected = self.collectionTracks(items, for: item)
                    self.queueLoadedCount = selected.count
                    commit(selected)
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

    private var queueOwner: UUID?
    /// New operations can produce the same message for the same surface owner.
    private var queueActionRevision: UInt = 0

    func collectionOutcome(ownedBy owner: UUID?) -> CollectionOutcome? {
        guard active, queueOwner == owner, !isQueueLoading,
            let message = queueErrorMessage ?? queueNotice
        else { return nil }
        return .init(
            owner: owner, revision: queueActionRevision,
            message: message, isError: queueErrorMessage != nil,
            canRetry: canRetryQueueAddition)
    }

    func retryQueueAddition(matching outcome: CollectionOutcome) {
        guard collectionOutcome(ownedBy: outcome.owner) == outcome else { return }
        retryQueueAddition()
    }

    func dismissQueueOutcome(matching outcome: CollectionOutcome) {
        guard collectionOutcome(ownedBy: outcome.owner) == outcome else { return }
        dismissQueueOutcome()
    }

    /// A departing surface may cancel its own work, never a newer destination's work.
    func cancelQueueAdditionOwned(by owner: UUID?, file: String = #fileID, line: Int = #line) {
        guard queueOwner == owner else { return }
        cancelQueueAddition(file: file, line: line)
    }

    func cancelQueueAddition(file: String = #fileID, line: Int = #line) {
        retryQueueAdditionAction = nil
        canRetryQueueAddition = false
        guard isQueueLoading else { return }
        #if DEBUG
            FoundationTrace.event("collection event=cancel origin=\(file) line=\(line)")
        #endif
        queueTask?.cancel()
        if queueOperation == .enqueue {
            queueNotice = "Collection loading cancelled."
        }
    }

    func retryQueueAddition() {
        guard active, !isQueueLoading, canRetryQueueAddition else { return }
        let retry = retryQueueAdditionAction
        retry?()
    }

    func dismissQueueOutcome() {
        guard !isQueueLoading else { return }
        queueOwner = nil
        queueOperation = nil
        queueErrorMessage = nil
        queueNotice = nil
        canRetryQueueAddition = false
        retryQueueAdditionAction = nil
    }

    /// Read-only authority check for source-aware native controls. Invalidation
    /// remains owned by the account runtime; no new lifetime or cached scope.
    func acceptsCatalogAccount(_ scope: String) -> Bool {
        active && storageKey == FoundationPinStorage.key(for: scope)
    }

    /// Called by the source owner before replacing or dismissing this source.
    func invalidate() {
        pinSync?.invalidate()
        active = false
        canonicalTracks = [:]
        knownTrackKeys = [:]
        trackAvailability = { _ in true }
        trackPreferenceObservation = nil
        cancelQueueAddition()
        retryQueueAdditionAction = nil
        for task in tasks.values { task.cancel() }
        for task in favoriteReads.values { task.cancel() }
    }
}
