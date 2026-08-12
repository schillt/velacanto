import Combine
import Foundation

struct MusicItemActionFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: String
}

/// Owns optimistic item-action state for exactly one signed-in account.
///
/// Each item has one serialized mutation loop. Repeated taps update the desired
/// state immediately, while completed requests advance the confirmed state in
/// order. Catalog refreshes can reconcile idle items but cannot overwrite a
/// newer optimistic choice.
@MainActor
final class MusicItemActionStateOwner: ObservableObject {
    @Published private(set) var favoriteStates: [MusicCatalogItemID: Bool] = [:]
    @Published private(set) var pendingFavoriteIDs: Set<MusicCatalogItemID> = []
    @Published private(set) var failure: MusicItemActionFailure?

    private var accountScope: String?
    private var provider: (any MusicItemActionProviding)?
    private var confirmedFavoriteStates: [MusicCatalogItemID: Bool] = [:]
    private var desiredFavoriteStates: [MusicCatalogItemID: Bool] = [:]
    private var protectedFavoriteStates: [MusicCatalogItemID: Bool] = [:]
    private var mutationTasks: [MusicCatalogItemID: Task<Void, Never>] = [:]
    private var generation = UUID()

    func configure(
        accountScope: String,
        provider: any MusicItemActionProviding
    ) {
        if self.accountScope != accountScope {
            reset()
            self.accountScope = accountScope
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
    }
}
