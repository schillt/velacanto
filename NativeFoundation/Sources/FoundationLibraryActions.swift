import Combine
import Foundation

/// One source's local pins and explicit, pessimistic favorite changes.
@MainActor
final class FoundationLibraryActions: ObservableObject {
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
    @Published private var pending: Set<Key> = []
    @Published private var errors: [Key: String] = [:]
    @Published private(set) var pinErrorMessage: String?
    @Published private(set) var isQueueLoading = false
    @Published private(set) var queueErrorMessage: String?
    private let storageKey: String
    private let write: (String, Data) throws -> Void
    private let mutateFavorite: @Sendable (FoundationItem, Bool) async throws -> Void
    private var tasks: [Key: Task<Void, Error>] = [:]
    private var active = true
    private var queueTask: Task<Void, Never>?
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
        storageKey = "Velacanto.Foundation.Pins.v1." + sourceScope
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
        favorites[Key(item)] ?? initial
    }

    func isPending(_ item: FoundationItem) -> Bool { pending.contains(Key(item)) }
    func errorMessage(for item: FoundationItem) -> String? { errors[Key(item)] }

    func setFavorite(for item: FoundationItem, isFavorite: Bool) async {
        let key = Key(item)
        guard active, item.kind != .genre, !pending.contains(key), !Task.isCancelled else { return }
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
        queueErrorMessage = nil
        if item.kind == .track {
            player.enqueue([item], position: position)
            return
        }
        guard let library, item.kind == .album || item.kind == .playlist else {
            queueErrorMessage = "This item cannot be added to the queue."
            return
        }
        loadCollection(item, library: library) { player.enqueue($0, position: position) }
    }

    func play(
        _ item: FoundationItem, shuffled: Bool, library: any FoundationLibrary,
        player: FoundationPlayer
    ) {
        guard active, !isQueueLoading else { return }
        playbackPreparation = player.$selectedEntryID.dropFirst().sink { [weak self] _ in
            self?.queueTask?.cancel()
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
                while true {
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
                    items.append(contentsOf: page.items)
                    guard let next = page.nextStartIndex else { break }
                    guard next > offset else { throw FoundationLibraryError.invalidResponse }
                    offset = next
                }
                guard let self, self.active, !Task.isCancelled else { return }
                if items.isEmpty {
                    self.queueErrorMessage = "This collection has no songs."
                } else {
                    self.playbackPreparation = nil
                    commit(items)
                }
            } catch {
                guard let self, self.active, !Task.isCancelled else { return }
                self.queueErrorMessage = FoundationLibraryError.category(error).errorDescription
            }
        }
    }

    func cancelQueueAddition() { queueTask?.cancel() }

    /// Called by the source owner before replacing or dismissing this source.
    func invalidate() {
        active = false
        cancelQueueAddition()
        for task in tasks.values { task.cancel() }
    }
}
