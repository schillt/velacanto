import Foundation
import Observation

/// One visible query/account context. The parent must invalidate it synchronously
/// on account/query/catalog-filter replacement and disappearance. No player owner.
@MainActor
@Observable
final class FoundationComposedCatalogModel {
    enum Filter: String, CaseIterable, Sendable {
        case all = "All"
        case jellyfin = "Jellyfin"
        case local = "Local"
    }
    struct Context: Equatable {
        let ownerID: UUID
        let account: String?
        let catalogFilter: String?
        let query: FoundationCatalogQuery
    }
    struct Row: Identifiable, Equatable {
        let id: FoundationCatalogItemKey
        let title: String
        let subtitle: String
        fileprivate let item: FoundationItem
    }
    /// Captured by rendered controls. A filter/replacement cycle cannot revive a
    /// dismissed menu merely because the same opaque item is published again.
    struct JellyfinIntent: Sendable {
        let key: FoundationCatalogItemKey
        fileprivate let owner: UUID
        fileprivate let generation: UInt
    }
    struct SourceSection: Identifiable, Equatable {
        let id: FoundationCatalogSource
        var state: FoundationCatalogComposition.State
        var rows: [Row]
        var hasMore: Bool
        var limitReached: Bool
        var failed: Bool = false
        fileprivate let localRevision: UInt?
        var title: String { id.kind == .local ? "Local Files" : "Jellyfin" }
    }
    /// Deliberately excludes paths, bookmark bytes, URLs and provider identifiers.
    struct Detail: Identifiable, Equatable {
        let id: FoundationCatalogItemKey
        let title: String
        let subtitle: String
        let source: String
        let availability: String
        let byteCount: Int64?
        let modified: Date?
        fileprivate let localRevision: UInt?
    }

    let context: Context
    private(set) var filter: Filter = .all
    @ObservationIgnored private let jellyfin: FoundationJellyfinLibrary?
    @ObservationIgnored private let localLibrary: FoundationLocalLibraryModel
    @ObservationIgnored private weak var actions: FoundationLibraryActions?
    @ObservationIgnored private let allowsNetwork: @MainActor () -> Bool
    @ObservationIgnored private let offlineJellyfinItems: @MainActor () -> [FoundationItem]
    @ObservationIgnored private let isCurrent: @MainActor (Context) -> Bool
    private var active = false
    private var intentGeneration: UInt = 0
    private var published: [SourceSection] = []
    private var selectedDetail: Detail?
    private var detailFailed = false
    private var detailFailureSource: FoundationCatalogSource?
    private var detailFailureRevision: UInt?
    @ObservationIgnored private var remoteBinding: FoundationCatalogFetchBinding?
    @ObservationIgnored private var localBinding: FoundationCatalogFetchBinding?
    @ObservationIgnored private var localBindingSource: FoundationCatalogSource?
    @ObservationIgnored private var remoteTask: Task<Void, Never>?
    @ObservationIgnored private var localTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    private var remoteGeneration: UInt = 0
    private var localGeneration: UInt = 0
    private var detailGeneration: UInt = 0
    private var capturedLocalRevision: UInt?

    init(
        ownerID: UUID, query: FoundationCatalogQuery, jellyfin: FoundationJellyfinLibrary?,
        localLibrary: FoundationLocalLibraryModel,
        actions: FoundationLibraryActions? = nil,
        allowsNetwork: @escaping @MainActor () -> Bool = { true },
        offlineJellyfinItems: @escaping @MainActor () -> [FoundationItem] = { [] },
        isCurrent: @escaping @MainActor (Context) -> Bool
    ) throws {
        let query = try query.normalized()
        context = .init(
            ownerID: ownerID, account: jellyfin?.catalogAccountIdentity,
            catalogFilter: jellyfin?.catalogScopeID, query: query)
        self.jellyfin = jellyfin
        self.localLibrary = localLibrary
        self.actions = actions
        self.allowsNetwork = allowsNetwork
        self.offlineJellyfinItems = offlineJellyfinItems
        self.isCurrent = isCurrent
    }

    var localPresentationRevision: UInt { localLibrary.presentationRevision }
    var hasSelectedLocalFolder: Bool { localLibrary.catalog != nil }
    var localIsUpdating: Bool { localLibrary.activity != nil }
    var hasJellyfinSource: Bool { jellyfin != nil }
    var localNeedsRecovery: Bool {
        localLibrary.corruptSelection || localLibrary.restorationCancelled
    }
    var detailUnavailable: Bool {
        guard active, isCurrent(context), detailFailed else { return false }
        return detailFailureSource?.kind != .local
            || (detailFailureRevision == localLibrary.presentationRevision
                && localLibrary.activity == nil)
    }
    var sections: [SourceSection] {
        guard active, isCurrent(context) else { return [] }
        return published.filter {
            $0.id.kind != .local
                || ($0.localRevision == localLibrary.presentationRevision
                    && localLibrary.activity == nil)
        }
    }
    var detail: Detail? {
        guard active, isCurrent(context), let selectedDetail else { return nil }
        guard
            selectedDetail.id.source.kind != .local
                || (selectedDetail.localRevision == localLibrary.presentationRevision
                    && localLibrary.activity == nil)
        else { return nil }
        return selectedDetail
    }

    var jellyfinItems: [FoundationItem] {
        sections.filter { $0.id.kind == .jellyfin }.flatMap(\.rows).map(\.item)
    }

    func jellyfinIntent(for key: FoundationCatalogItemKey) -> JellyfinIntent? {
        guard currentJellyfinItem(key, requiring: .catalogPresence) != nil else { return nil }
        return .init(key: key, owner: context.ownerID, generation: intentGeneration)
    }

    func canPerform(_ intent: JellyfinIntent, requiring capability: FoundationCatalogCapabilities)
        -> Bool
    {
        guard intent.owner == context.ownerID, intent.generation == intentGeneration else {
            return false
        }
        return currentJellyfinItem(intent.key, requiring: capability) != nil
    }

    /// Dispatch synchronously: the existing player/action owner claims its intent
    /// before any asynchronous collection/resource resolution can suspend.
    @discardableResult
    func withCurrentJellyfinItem(
        _ intent: JellyfinIntent, requiring capability: FoundationCatalogCapabilities,
        perform: (FoundationItem) -> Void
    ) -> Bool {
        guard canPerform(intent, requiring: capability),
            let item = currentJellyfinItem(intent.key, requiring: capability)
        else { return false }
        perform(item)
        return true
    }

    private func currentJellyfinItem(
        _ key: FoundationCatalogItemKey, requiring capability: FoundationCatalogCapabilities
    ) -> FoundationItem? {
        guard active, isCurrent(context), filter != .local, !capability.isEmpty,
            let jellyfin, context.account == jellyfin.catalogAccountIdentity,
            context.catalogFilter == jellyfin.catalogScopeID,
            let source = try? FoundationCatalogSource.jellyfin(
                scope: jellyfin.catalogAccountIdentity),
            key.source == source, source.capabilities(for: key.kind).contains(capability),
            let row = sections.first(where: { $0.id == source })?.rows.first(where: { $0.id == key }
            ),
            (try? row.item.catalogKey()) == key
        else { return nil }
        return row.item
    }

    func activate() {
        guard !active, isCurrent(context) else { return }
        active = true
        if filter != .local, let jellyfin {
            remoteBinding = try? FoundationCatalogFetchBinding(
                query: context.query, jellyfin: jellyfin, local: nil, localID: nil)
            _ = startLoad(.jellyfin)
        }
        synchronizeLocalRevision()
    }

    func setFilter(_ next: Filter, activate: Bool = true) {
        guard next != filter else { return }
        let wasActive = active
        invalidate()
        filter = next
        if wasActive && activate { self.activate() }
    }

    /// Explicit pull-to-refresh starts a new result lifetime. Both sources publish
    /// independently; the refresh indicator alone awaits their already-started tasks.
    func refresh() async {
        guard active, isCurrent(context) else { return }
        invalidate()
        activate()
        let remote = remoteTask
        let local = localTask
        await remote?.value
        await local?.value
    }

    /// Removes presentation and cancels tasks before any asynchronous retirement.
    func invalidate() {
        active = false
        intentGeneration &+= 1
        remoteGeneration &+= 1
        localGeneration &+= 1
        detailGeneration &+= 1
        remoteTask?.cancel()
        localTask?.cancel()
        detailTask?.cancel()
        remoteTask = nil
        localTask = nil
        detailTask = nil
        published = []
        selectedDetail = nil
        detailFailed = false
        if let binding = remoteBinding, let jellyfin,
            let source = try? FoundationCatalogSource.jellyfin(
                scope: jellyfin.catalogAccountIdentity)
        {
            Task { await binding.retire(source) }
        }
        retireLocal()
        remoteBinding = nil
        capturedLocalRevision = nil
    }

    /// UI calls this on revision changes. Getters already hide mismatched local
    /// rows/details synchronously, even before SwiftUI invokes onChange.
    func synchronizeLocalRevision() {
        guard active, isCurrent(context) else { return }
        guard capturedLocalRevision != localLibrary.presentationRevision else { return }
        localGeneration &+= 1
        localTask?.cancel()
        localTask = nil
        published.removeAll { $0.id.kind == .local }
        if selectedDetail?.id.source.kind == .local {
            detailGeneration &+= 1
            detailTask?.cancel()
            detailTask = nil
            selectedDetail = nil
        }
        if detailFailureSource?.kind == .local { dismissDetailFailure() }
        retireLocal()
        capturedLocalRevision = localLibrary.presentationRevision
        guard active, isCurrent(context), filter != .jellyfin,
            localLibrary.activity == nil, localLibrary.catalog != nil,
            !localLibrary.corruptSelection, !localLibrary.restorationCancelled
        else { return }
        localBinding = try? localLibrary.catalogBinding(query: context.query)
        localBindingSource = localLibrary.catalog.map { .local(sourceID: $0.sourceID) }
        _ = startLoad(.local)
    }

    private func retireLocal() {
        if let binding = localBinding, let source = localBindingSource {
            Task { await binding.retire(source) }
        }
        localBinding = nil
        localBindingSource = nil
    }

    @discardableResult
    func loadNext(_ kind: FoundationCatalogSource.Kind) -> Task<Void, Never>? {
        if kind == .local { synchronizeLocalRevision() }
        return startLoad(kind)
    }

    @discardableResult
    func retry(_ kind: FoundationCatalogSource.Kind) -> Task<Void, Never>? {
        if kind == .local {
            capturedLocalRevision = nil
            synchronizeLocalRevision()
        }
        return startLoad(kind)
    }

    /// The app supplies its existing verified-download projection. Reading local
    /// cache metadata never grants a network request or a local-file Play action.
    func refreshOfflineJellyfin() {
        guard active, isCurrent(context), !allowsNetwork(), filter != .local, let jellyfin,
            let source = try? FoundationCatalogSource.jellyfin(
                scope: jellyfin.catalogAccountIdentity)
        else { return }
        intentGeneration &+= 1
        let items = offlineJellyfinItems()
        let bounded = items.prefix(FoundationCatalogComposition.itemLimit)
        let rows = bounded.compactMap { item -> Row? in
            guard let key = try? item.catalogKey(legacyJellyfinSource: source), key.source == source
            else { return nil }
            var scoped = item
            scoped.catalogSource = source
            return .init(id: key, title: item.title, subtitle: item.subtitle, item: scoped)
        }
        replace(
            .init(
                id: source,
                state: rows.count != bounded.count ? .partial : (rows.isEmpty ? .empty : .ready),
                rows: rows, hasMore: false,
                limitReached: items.count > FoundationCatalogComposition.itemLimit,
                localRevision: nil))
    }

    /// Preserve complete provider pages: existing Jellyfin Songs pages contain up
    /// to 100 items; search/local pages contain up to 50. Total bounds come from
    /// FoundationCatalogComposition, not a second UI limit or a clipped prefix.
    private func startLoad(_ kind: FoundationCatalogSource.Kind) -> Task<Void, Never>? {
        guard active, isCurrent(context) else { return nil }
        if kind == .jellyfin, !allowsNetwork() {
            refreshOfflineJellyfin()
            return nil
        }
        if kind == .jellyfin, let remoteTask { return remoteTask }
        if kind == .local, let localTask { return localTask }
        let binding = kind == .jellyfin ? remoteBinding : localBinding
        guard let binding else { return nil }
        let source: FoundationCatalogSource
        if kind == .jellyfin, let jellyfin {
            guard
                let value = try? FoundationCatalogSource.jellyfin(
                    scope: jellyfin.catalogAccountIdentity)
            else { return nil }
            source = value
            remoteGeneration &+= 1
        } else if kind == .local, let catalog = localLibrary.catalog {
            source = .local(sourceID: catalog.sourceID)
            localGeneration &+= 1
        } else {
            return nil
        }
        if let section = published.first(where: { $0.id == source }),
            !section.hasMore && !section.failed
        {
            return nil
        }
        let generation = kind == .jellyfin ? remoteGeneration : localGeneration
        let revision = kind == .local ? localLibrary.presentationRevision : nil
        var section =
            published.first { $0.id == source }
            ?? .init(
                id: source, state: .idle, rows: [], hasMore: true, limitReached: false,
                localRevision: revision)
        section.state = .loading
        section.failed = false
        replace(section)
        let favoriteRead = kind == .jellyfin ? actions?.beginFavoriteRead() : nil
        let previousKeys = Set(section.rows.map(\.id))
        let task = Task { [weak self] in
            do {
                if kind == .jellyfin {
                    try await binding.loadJellyfin()
                } else {
                    try await binding.loadLocal()
                }
                guard self?.current(kind, generation, revision) == true else { return }
                let snapshots = await binding.snapshots()
                guard let self, current(kind, generation, revision), !Task.isCancelled else {
                    return
                }
                guard let snapshot = snapshots.first(where: { $0.source == source }) else {
                    fail(source, revision: revision)
                    finish(kind)
                    return
                }
                let rows = snapshot.items.compactMap { item -> Row? in
                    guard let key = try? item.catalogKey() else { return nil }
                    return Row(id: key, title: item.title, subtitle: item.subtitle, item: item)
                }
                if kind == .jellyfin, let favoriteRead {
                    let freshItems = rows.filter { !previousKeys.contains($0.id) }.map(\.item)
                    actions?.observeFavorites(in: freshItems, read: favoriteRead)
                    actions?.observeTrackCopies(freshItems)
                }
                var state = snapshot.state
                if kind == .local {
                    switch localLibrary.catalog?.state {
                    case .unavailable, .corrupt: state = .unavailable
                    case .partial: state = .partial
                    default: break
                    }
                }
                let capped =
                    rows.count >= FoundationCatalogComposition.itemLimit
                    && snapshot.nextStartIndex != nil
                replace(
                    .init(
                        id: source, state: state, rows: rows,
                        hasMore: snapshot.nextStartIndex != nil && !capped, limitReached: capped,
                        localRevision: revision))
                finish(kind)
            } catch {
                guard let self, current(kind, generation, revision), !Task.isCancelled else {
                    return
                }
                fail(source, revision: revision)
                finish(kind)
            }
        }
        if kind == .jellyfin { remoteTask = task } else { localTask = task }
        return task
    }

    private func current(
        _ kind: FoundationCatalogSource.Kind, _ generation: UInt, _ revision: UInt?
    )
        -> Bool
    {
        guard active, isCurrent(context), !Task.isCancelled else { return false }
        guard kind == .local else { return generation == remoteGeneration }
        guard revision == localLibrary.presentationRevision, localLibrary.activity == nil else {
            synchronizeLocalRevision()
            return false
        }
        return generation == localGeneration
    }

    private func finish(_ kind: FoundationCatalogSource.Kind) {
        if kind == .jellyfin { remoteTask = nil } else { localTask = nil }
    }
    private func replace(_ section: SourceSection) {
        published.removeAll { $0.id == section.id }
        published.append(section)
        published.sort { $0.id.kind == .jellyfin && $1.id.kind == .local }
    }
    private func fail(_ source: FoundationCatalogSource, revision: UInt?) {
        var section =
            published.first { $0.id == source }
            ?? .init(
                id: source, state: .failed, rows: [], hasMore: true, limitReached: false,
                localRevision: revision)
        section.state = .failed
        section.failed = true
        if source.kind == .local {
            section.rows = []
            if selectedDetail?.id.source == source { selectedDetail = nil }
        }
        replace(section)
    }

    @discardableResult
    func open(_ key: FoundationCatalogItemKey) -> Task<Void, Never>? {
        guard let row = sections.flatMap(\.rows).first(where: { $0.id == key }) else { return nil }
        let kind = key.source.kind
        guard let binding = kind == .jellyfin ? remoteBinding : localBinding else { return nil }
        let generation = kind == .jellyfin ? remoteGeneration : localGeneration
        let revision = kind == .local ? localLibrary.presentationRevision : nil
        detailGeneration &+= 1
        detailFailed = false
        let token = detailGeneration
        detailTask?.cancel()
        let task = Task { [weak self] in
            do {
                _ = try await binding.route(for: row.item, requiring: .catalogPresence)
                guard let self, current(kind, generation, revision), token == detailGeneration,
                    !Task.isCancelled
                else { return }
                let record =
                    kind == .local
                    ? localLibrary.catalog?.records.first { $0.id == key.itemID } : nil
                let availability: String
                if kind == .local {
                    switch localLibrary.catalog?.state {
                    case .unavailable: availability = "Folder unavailable. Showing saved metadata."
                    case .corrupt: availability = "Index unavailable. Showing saved metadata."
                    case .partial:
                        availability = "Incomplete index. Saved metadata may be out of date."
                    default: availability = "Read-only saved file metadata"
                    }
                } else {
                    availability = "Catalog metadata"
                }
                selectedDetail = .init(
                    id: key, title: row.title, subtitle: row.subtitle,
                    source: kind == .local ? "Local Files" : "Jellyfin",
                    availability: availability,
                    byteCount: record?.byteCount, modified: record?.modified,
                    localRevision: revision)
                detailTask = nil
            } catch {
                guard let self, current(kind, generation, revision), token == detailGeneration
                else { return }
                if selectedDetail?.id.source == key.source { selectedDetail = nil }
                detailFailed = true
                detailFailureSource = key.source
                detailFailureRevision = revision
                detailTask = nil
            }
        }
        detailTask = task
        return task
    }

    func dismissDetailFailure() {
        detailFailed = false
        detailFailureSource = nil
        detailFailureRevision = nil
    }

    func closeDetail() {
        detailGeneration &+= 1
        detailTask?.cancel()
        detailTask = nil
        selectedDetail = nil
    }
}

/// View-local owner adoption. Replacing a model while a view remains mounted
/// retires the old owner before the replacement can activate; no global registry.
@MainActor
final class FoundationComposedCatalogLifetime {
    private var owner: FoundationComposedCatalogModel?

    func update(_ next: FoundationComposedCatalogModel, isActive: Bool) {
        if owner !== next {
            owner?.invalidate()
            owner = next
        }
        if isActive { next.activate() } else { next.invalidate() }
    }

    func end() {
        owner?.invalidate()
        owner = nil
    }
}
