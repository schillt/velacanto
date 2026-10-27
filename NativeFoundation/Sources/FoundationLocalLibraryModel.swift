import Foundation
import Observation

/// App-owned local state. No Jellyfin dependency, startup barrier or automatic scan.
@MainActor
@Observable
final class FoundationLocalLibraryModel {
    enum Activity: Equatable { case restoring, selecting, refreshing, forgetting }

    private(set) var catalog: FoundationLocalCatalog?
    /// Changes before selection/forget/refresh work can suspend, and when it settles.
    private(set) var presentationRevision: UInt = 0
    private(set) var activity: Activity?
    private(set) var corruptSelection = false
    private(set) var restorationCancelled = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let source: FoundationLocalSource
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var revision: UInt = 0
    @ObservationIgnored private var restored = false

    init(source: FoundationLocalSource) { self.source = source }

    static func appOwned() -> FoundationLocalLibraryModel {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FoundationLocalLibraryModel(
            source: FoundationLocalSource(
                storage: support.appendingPathComponent("VelaCantoLocalLibrary", isDirectory: true))
        )
    }

    /// Captures only a settled selected source. Consumers must also gate publication
    /// on presentationRevision; a cached UUID check alone is not a lifetime token.
    func catalogBinding(query: FoundationCatalogQuery) throws -> FoundationCatalogFetchBinding {
        let available = activity == nil && !corruptSelection && !restorationCancelled
        let id = available ? catalog?.sourceID : nil
        return try FoundationCatalogFetchBinding(
            query: query, jellyfin: nil, local: id == nil ? nil : source, localID: id)
    }

    /// Cache restoration neither opens the selected folder nor starts indexing.
    @discardableResult
    func restore() -> Task<Void, Never> {
        guard !restored, activity == nil else { return Task {} }
        restored = true
        return begin(.restoring) { owner in
            try await owner.source.cachedCatalog()
        }
    }

    /// Called only with a native importer grant. Keep that grant alive while the
    /// source actor creates its bookmark; indexing needs a separate explicit action.
    @discardableResult
    func select(_ folder: URL) -> Task<Void, Never> {
        guard activity == nil else { return Task {} }
        return begin(.selecting) { owner in
            guard folder.startAccessingSecurityScopedResource() else {
                throw FoundationLocalFolderAccess.AccessFailure.unavailable
            }
            defer { folder.stopAccessingSecurityScopedResource() }
            let id = try await owner.source.select(folder)
            return .init(sourceID: id, state: .empty)
        }
    }

    @discardableResult
    func refresh() -> Task<Void, Never> {
        guard activity == nil, catalog != nil else { return Task {} }
        return begin(.refreshing) { owner in
            let result = try await owner.source.refresh()
            try Task.checkCancellation()
            return result
        }
    }

    /// Forget revokes the bookmark and retires visible records. Historical private
    /// snapshots remain on disk; neither this method nor the index deletes music.
    @discardableResult
    func forget() -> Task<Void, Never> {
        guard activity != .selecting, activity != .forgetting else { return Task {} }
        cancel()
        return begin(.forgetting) { owner in
            try await owner.source.removeSelection()
            return nil
        }
    }

    func cancel() {
        guard activity == .refreshing || activity == .restoring else { return }
        if activity == .restoring {
            restored = false
            restorationCancelled = true
        }
        revision &+= 1
        presentationRevision &+= 1
        operation?.cancel()
        operation = nil
        activity = nil
        errorMessage = "Index loading was cancelled. Previously displayed records are retained."
    }

    func importerFailed() {
        errorMessage = "The folder could not be selected. Try choosing it again."
    }

    private func begin(
        _ next: Activity,
        work:
            @escaping @MainActor (FoundationLocalLibraryModel) async throws ->
            FoundationLocalCatalog?
    ) -> Task<Void, Never> {
        revision &+= 1
        presentationRevision &+= 1
        let token = revision
        activity = next
        errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let update = try await work(self)
                try Task.checkCancellation()
                guard token == revision else { return }
                catalog = update
                corruptSelection = false
                restorationCancelled = false
                restored = true
            } catch {
                guard token == revision else { return }
                if next == .restoring {
                    corruptSelection = true
                    restorationCancelled = false
                }
                if !(error is CancellationError) {
                    errorMessage =
                        next == .forgetting
                        ? "Folder access could not be forgotten. The selection is retained."
                        : "The local library could not be loaded. Choose the folder again or refresh explicitly."
                }
            }
            guard token == revision else { return }
            activity = nil
            presentationRevision &+= 1
            operation = nil
        }
        operation = task
        return task
    }
}
