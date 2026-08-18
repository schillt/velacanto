import Combine
import Foundation
import os

struct MusicItemActionFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: String
}

/// Stores the device-local, user-curated Library shelf for each account.
protocol MusicLibraryPinStoring {
    func loadPins(accountScope: String) throws -> [MusicCatalogItem]
    func savePins(_ items: [MusicCatalogItem], accountScope: String) throws
}

struct UserDefaultsMusicLibraryPinStore: MusicLibraryPinStoring {
    private struct SavedPins: Codable {
        var accounts: [String: [MusicCatalogItem]]
    }

    private let defaults: UserDefaults
    private let key = "velacanto.library-pins-v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPins(accountScope: String) throws -> [MusicCatalogItem] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode(SavedPins.self, from: data)
            .accounts[accountScope] ?? []
    }

    func savePins(_ items: [MusicCatalogItem], accountScope: String) throws {
        var savedPins: SavedPins
        if let data = defaults.data(forKey: key) {
            savedPins =
                (try? JSONDecoder().decode(SavedPins.self, from: data))
                ?? SavedPins(accounts: [:])
        } else {
            savedPins = SavedPins(accounts: [:])
        }
        savedPins.accounts[accountScope] = items
        defaults.set(try JSONEncoder().encode(savedPins), forKey: key)
    }
}

/// Owns optimistic item-action state for exactly one signed-in account.
///
/// Each item has one serialized mutation loop. Repeated taps update the desired
/// state immediately, while completed requests advance the confirmed state in
/// order. Catalog refreshes can reconcile idle items but cannot overwrite a
/// newer optimistic choice.
@MainActor
final class MusicItemActionStateOwner: ObservableObject {
    private static let logger = Logger(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "LibraryPins"
    )

    @Published private(set) var favoriteStates: [MusicCatalogItemID: Bool] = [:]
    @Published private(set) var pendingFavoriteIDs: Set<MusicCatalogItemID> = []
    @Published private(set) var failure: MusicItemActionFailure?
    @Published private(set) var pinnedItems: [MusicCatalogItem] = []

    private var accountScope: String?
    private var provider: (any MusicItemActionProviding)?
    private let pinStore: any MusicLibraryPinStoring
    private var confirmedFavoriteStates: [MusicCatalogItemID: Bool] = [:]
    private var desiredFavoriteStates: [MusicCatalogItemID: Bool] = [:]
    private var protectedFavoriteStates: [MusicCatalogItemID: Bool] = [:]
    private var mutationTasks: [MusicCatalogItemID: Task<Void, Never>] = [:]
    private var generation = UUID()

    init(pinStore: any MusicLibraryPinStoring = UserDefaultsMusicLibraryPinStore()) {
        self.pinStore = pinStore
    }

    func configure(
        accountScope: String,
        provider: any MusicItemActionProviding
    ) {
        if self.accountScope != accountScope {
            reset()
            self.accountScope = accountScope
            loadPins(accountScope: accountScope)
        }
        self.provider = provider
    }

    func clear() {
        reset()
        accountScope = nil
        provider = nil
    }

    func reconcile(_ items: [MusicCatalogItem]) {
        guard let accountScope else { return }
        for item in items where item.id.accountScope == accountScope {
            guard desiredFavoriteStates[item.id] == nil else { continue }
            if let protectedState = protectedFavoriteStates[item.id] {
                guard item.isFavorite == protectedState else { continue }
                protectedFavoriteStates[item.id] = nil
            }
            confirmedFavoriteStates[item.id] = item.isFavorite
            favoriteStates[item.id] = item.isFavorite
        }

        var didUpdatePins = false
        for item in items where Self.isPinnable(item) {
            guard let index = pinnedItems.firstIndex(where: { $0.id == item.id }) else {
                continue
            }
            guard pinnedItems[index] != item else { continue }
            pinnedItems[index] = item
            didUpdatePins = true
        }
        if didUpdatePins { savePins() }
    }

    func isFavorite(_ item: MusicCatalogItem) -> Bool {
        favoriteStates[item.id] ?? item.isFavorite
    }

    func isFavorite(itemID: MusicCatalogItemID, fallback: Bool = false) -> Bool {
        favoriteStates[itemID] ?? fallback
    }

    func isUpdatingFavorite(_ itemID: MusicCatalogItemID) -> Bool {
        pendingFavoriteIDs.contains(itemID)
    }

    func canPin(_ item: MusicCatalogItem) -> Bool {
        item.id.accountScope == accountScope && Self.isPinnable(item)
    }

    func isPinned(_ item: MusicCatalogItem) -> Bool {
        pinnedItems.contains { $0.id == item.id }
    }

    func togglePin(_ item: MusicCatalogItem) {
        guard canPin(item) else { return }
        if let index = pinnedItems.firstIndex(where: { $0.id == item.id }) {
            pinnedItems.remove(at: index)
        } else {
            pinnedItems.insert(item, at: 0)
        }
        savePins()
    }

    func toggleFavorite(_ item: MusicCatalogItem) {
        guard item.capabilities.contains(.favorite) else { return }
        setFavorite(!isFavorite(item), for: item.id, fallback: item.isFavorite)
    }

    func toggleFavorite(itemID: MusicCatalogItemID, fallback: Bool = false) {
        setFavorite(
            !isFavorite(itemID: itemID, fallback: fallback),
            for: itemID,
            fallback: fallback
        )
    }

    func dismissFailure() {
        failure = nil
    }

    private func setFavorite(
        _ isFavorite: Bool,
        for itemID: MusicCatalogItemID,
        fallback: Bool
    ) {
        guard itemID.accountScope == accountScope, provider != nil else { return }
        if confirmedFavoriteStates[itemID] == nil {
            confirmedFavoriteStates[itemID] = favoriteStates[itemID] ?? fallback
        }
        desiredFavoriteStates[itemID] = isFavorite
        favoriteStates[itemID] = isFavorite
        pendingFavoriteIDs.insert(itemID)

        guard mutationTasks[itemID] == nil else { return }
        let taskGeneration = generation
        mutationTasks[itemID] = Task { [weak self] in
            await self?.drainFavoriteMutations(
                for: itemID,
                generation: taskGeneration
            )
        }
    }

    private func drainFavoriteMutations(
        for itemID: MusicCatalogItemID,
        generation taskGeneration: UUID
    ) async {
        defer {
            if generation == taskGeneration {
                mutationTasks[itemID] = nil
                pendingFavoriteIDs.remove(itemID)
            }
        }

        while generation == taskGeneration,
            let requestedState = desiredFavoriteStates[itemID]
        {
            let confirmedState = confirmedFavoriteStates[itemID] ?? false
            if requestedState == confirmedState {
                desiredFavoriteStates[itemID] = nil
                favoriteStates[itemID] = confirmedState
                return
            }

            guard let provider else { return }
            do {
                try await provider.setFavorite(requestedState, for: itemID)
                guard generation == taskGeneration else { return }
                confirmedFavoriteStates[itemID] = requestedState
                protectedFavoriteStates[itemID] = requestedState
                if desiredFavoriteStates[itemID] == requestedState {
                    desiredFavoriteStates[itemID] = nil
                    favoriteStates[itemID] = requestedState
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == taskGeneration else { return }
                if desiredFavoriteStates[itemID] == requestedState {
                    desiredFavoriteStates[itemID] = nil
                    favoriteStates[itemID] = confirmedState
                    failure = MusicItemActionFailure(
                        message: "Couldn’t update this favorite. Your previous choice was restored."
                    )
                    return
                }
            }
        }
    }

    private func reset() {
        generation = UUID()
        for task in mutationTasks.values {
            task.cancel()
        }
        mutationTasks.removeAll()
        confirmedFavoriteStates.removeAll()
        desiredFavoriteStates.removeAll()
        protectedFavoriteStates.removeAll()
        favoriteStates.removeAll()
        pendingFavoriteIDs.removeAll()
        failure = nil
        pinnedItems = []
    }

    private static func isPinnable(_ item: MusicCatalogItem) -> Bool {
        switch item.kind {
        case .album, .artist, .playlist:
            true
        case .song:
            false
        }
    }

    private func loadPins(accountScope: String) {
        do {
            pinnedItems = try pinStore.loadPins(accountScope: accountScope)
                .filter { $0.id.accountScope == accountScope && Self.isPinnable($0) }
        } catch {
            Self.logger.notice("Could not load Library pins; starting with an empty shelf")
            pinnedItems = []
        }
    }

    private func savePins() {
        guard let accountScope else { return }
        do {
            try pinStore.savePins(pinnedItems, accountScope: accountScope)
        } catch {
            Self.logger.notice(
                "Could not save Library pins; keeping the current shelf for this session"
            )
        }
    }
}
