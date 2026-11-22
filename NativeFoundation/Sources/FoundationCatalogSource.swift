import Foundation

/// Only the two actual catalog sources. The server identity is the existing
/// account-scope digest, never a URL/user ID; local identity never carries a path.
struct FoundationCatalogSource: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case jellyfin, local }
    let kind: Kind
    let identity: String

    private init(kind: Kind, identity: String) {
        self.kind = kind
        self.identity = identity
    }

    static func jellyfin(scope: String) throws -> Self {
        guard scope.utf8.count == 64,
            scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw FoundationCatalogComposition.Failure.invalidSource }
        return .init(kind: .jellyfin, identity: scope)
    }

    static func local(sourceID: UUID) -> Self {
        .init(kind: .local, identity: sourceID.uuidString)
    }

    private enum CodingKeys: String, CodingKey { case kind, identity }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        let identity = try values.decode(String.self, forKey: .identity)
        switch kind {
        case .jellyfin: self = try Self.jellyfin(scope: identity)
        case .local:
            guard let id = UUID(uuidString: identity), id.uuidString == identity else {
                throw FoundationCatalogComposition.Failure.invalidSource
            }
            self = .local(sourceID: id)
        }
    }
}

/// Typed components cannot collide through delimiters embedded in opaque IDs.
struct FoundationCatalogItemKey: Hashable, Sendable {
    let source: FoundationCatalogSource
    let kind: FoundationItem.Kind
    let itemID: String
}

struct FoundationCatalogCapabilities: OptionSet, Sendable {
    let rawValue: UInt16
    static let catalogPresence = Self(rawValue: 1 << 0)
    static let playback = Self(rawValue: 1 << 1)
    static let favorites = Self(rawValue: 1 << 2)
    static let playlistManagement = Self(rawValue: 1 << 3)
    static let downloads = Self(rawValue: 1 << 4)
    static let networkArtwork = Self(rawValue: 1 << 5)
    static let playbackReporting = Self(rawValue: 1 << 6)
    static let handoff = Self(rawValue: 1 << 7)
}

extension FoundationCatalogSource {
    /// Maximum source affordances, not authorization to bypass server permissions.
    /// Local Play remains absent until the scoped resource lease route is integrated.
    func capabilities(for kind: FoundationItem.Kind) -> FoundationCatalogCapabilities {
        guard self.kind == .jellyfin else { return [.catalogPresence] }
        var result: FoundationCatalogCapabilities = [
            .catalogPresence, .playback, .favorites, .networkArtwork,
        ]
        if kind == .track { result.formUnion([.downloads, .playbackReporting, .handoff]) }
        if kind == .playlist { result.insert(.playlistManagement) }
        return result
    }
}

extension FoundationItem {
    /// Legacy nil is meaningful only with an explicit current Jellyfin owner.
    func catalogKey(legacyJellyfinSource: FoundationCatalogSource? = nil) throws
        -> FoundationCatalogItemKey
    {
        guard !id.isEmpty, id.utf8.count <= 4096 else {
            throw FoundationCatalogComposition.Failure.invalidItem
        }
        let source: FoundationCatalogSource
        if let catalogSource {
            source = catalogSource
        } else if let legacyJellyfinSource, legacyJellyfinSource.kind == .jellyfin {
            source = legacyJellyfinSource
        } else {
            throw FoundationCatalogComposition.Failure.invalidSource
        }
        if source.kind == .local {
            let prefix = source.identity + ":"
            guard id.hasPrefix(prefix), id.utf8.count == prefix.utf8.count + 64,
                id.suffix(64).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw FoundationCatalogComposition.Failure.invalidItem }
        }
        return .init(source: source, kind: kind, itemID: id)
    }
}

/// Two independently published, bounded source snapshots. This owner schedules
/// nothing: the caller starts each explicit source operation independently.
actor FoundationCatalogComposition {
    static let pageLimit = 200
    static let itemLimit = 10_000
    enum Failure: Error { case invalidSource, invalidItem, invalidPage, unavailable, stale }
    enum State: Equatable, Sendable {
        case idle, loading, ready, empty, partial, unavailable, failed
    }
    enum Route: Equatable, Sendable {
        case jellyfin(FoundationCatalogItemKey)
        case local(FoundationCatalogItemKey)
    }
    struct Snapshot: Sendable {
        let source: FoundationCatalogSource
        var state: State = .idle
        var items: [FoundationItem] = []
        var nextStartIndex: Int? = 0
        var isSeededSearch = false
        var searchCoverageIncomplete = false
        var fallbackCursor: FoundationSearchResolver.FallbackCursor?
        var seedOverflowCount = 0
        var hasMore: Bool {
            seedOverflowCount > 0 || nextStartIndex != nil || fallbackCursor != nil
        }
        /// Only identities from the most recent provider read, never from a reused seed.
        var freshKeys: Set<FoundationCatalogItemKey> = []
    }
    struct Page: Sendable {
        let page: FoundationPage
        var state: State = .ready
    }
    private struct Slot {
        var snapshot: Snapshot
        var generation: UInt = 0
        /// Only non-provider rows in an admitted search seed may overlap later pages.
        var supplementalKeys: Set<FoundationCatalogItemKey> = []
        var seedOverflow: [FoundationItem] = []
    }
    private let order: [FoundationCatalogSource]
    private var slots: [FoundationCatalogSource: Slot]

    init(jellyfin: FoundationCatalogSource?, local: FoundationCatalogSource?) throws {
        guard jellyfin == nil || jellyfin?.kind == .jellyfin,
            local == nil || local?.kind == .local
        else { throw Failure.invalidSource }
        let sources = [jellyfin, local].compactMap { $0 }
        order = sources
        slots = Dictionary(
            uniqueKeysWithValues: sources.map { ($0, Slot(snapshot: .init(source: $0))) })
    }

    func snapshots() -> [Snapshot] { order.compactMap { slots[$0]?.snapshot } }

    /// Only this owner's exact source may dispatch. Legacy nil items can reach
    /// the current Jellyfin slot only; local items never resolve via that fallback.
    func route(
        for item: FoundationItem, requiring capability: FoundationCatalogCapabilities
    ) throws -> Route {
        let server = order.first { $0.kind == .jellyfin }
        let key = try item.catalogKey(legacyJellyfinSource: server)
        guard !capability.isEmpty, slots[key.source] != nil,
            key.source.capabilities(for: key.kind).contains(capability)
        else { throw Failure.unavailable }
        return key.source.kind == .jellyfin ? .jellyfin(key) : .local(key)
    }

    /// A reset retires that source's late work without touching the other source.
    func reset(_ source: FoundationCatalogSource) throws {
        guard var slot = slots[source] else { throw Failure.invalidSource }
        slot.generation &+= 1
        slot.snapshot = .init(source: source)
        slot.supplementalKeys.removeAll()
        slot.seedOverflow.removeAll()
        slots[source] = slot
    }

    /// Retirement removes both presentation and routing authority. A suspended
    /// request cannot recreate this slot; a new binding is required to reattach it.
    func retire(_ source: FoundationCatalogSource) {
        slots.removeValue(forKey: source)
    }

    /// Admit an already resolved first search snapshot once, retaining the provider cursor.
    func seedSearch(
        _ source: FoundationCatalogSource, page: FoundationPage, supplementalIDs: Set<String>,
        fallbackCursor: FoundationSearchResolver.FallbackCursor? = nil,
        incompleteCoverage: Bool = false
    ) throws {
        guard var slot = slots[source], source.kind == .jellyfin,
            slot.snapshot.state == .idle, slot.snapshot.nextStartIndex == 0
        else { throw Failure.unavailable }
        guard page.items.count <= Self.itemLimit else { throw Failure.invalidPage }
        // The overview snapshot may span several presentation pages. Validate
        // every retained row before atomically admitting any of its membership.
        var items: [FoundationItem] = []
        for offset in stride(from: 0, to: page.items.count, by: Self.pageLimit) {
            items += try Self.validate(
                .init(
                    page: .init(
                        items: Array(
                            page.items[offset..<min(offset + Self.pageLimit, page.items.count)]),
                        nextStartIndex: nil)), source: source, cursor: 0)
        }
        guard page.nextStartIndex.map({ $0 > 0 && $0 <= Self.itemLimit }) ?? true else {
            throw Failure.invalidPage
        }
        let keys = try items.map { try $0.catalogKey() }
        guard Set(keys).count == keys.count,
            items.allSatisfy({ $0.kind == .track }),
            supplementalIDs.isSubset(of: Set(items.map(\.id))),
            fallbackCursor.map({
                !$0.term.isEmpty && $0.nextStartIndex > 0
                    && $0.nextStartIndex <= Self.itemLimit
            }) ?? true
        else { throw Failure.invalidPage }
        slot.supplementalKeys = Set(
            zip(items, keys).compactMap {
                supplementalIDs.contains($0.0.id) ? $0.1 : nil
            })
        slot.snapshot.items = Array(items.prefix(Self.pageLimit))
        slot.seedOverflow = Array(items.dropFirst(Self.pageLimit))
        slot.snapshot.seedOverflowCount = slot.seedOverflow.count
        slot.snapshot.nextStartIndex = page.nextStartIndex
        slot.snapshot.fallbackCursor = fallbackCursor
        slot.snapshot.isSeededSearch = true
        slot.snapshot.searchCoverageIncomplete = incompleteCoverage
        slot.snapshot.state = items.isEmpty ? .empty : .ready
        slots[source] = slot
    }

    /// One explicit demand reveals one retained page without a provider read.
    /// Cancellation is checked before committing; reset/retirement removes this
    /// slot and its immutable overflow together with the other search cursors.
    func loadSeedOverflow(_ source: FoundationCatalogSource) throws {
        try Task.checkCancellation()
        guard var slot = slots[source], slot.snapshot.state != .loading,
            slot.snapshot.isSeededSearch, !slot.seedOverflow.isEmpty
        else { throw Failure.unavailable }
        let page = Array(slot.seedOverflow.prefix(Self.pageLimit))
        guard slot.snapshot.items.count + page.count <= Self.itemLimit else {
            throw Failure.invalidPage
        }
        slot.generation &+= 1
        slot.snapshot.items += page
        slot.seedOverflow.removeFirst(page.count)
        slot.snapshot.seedOverflowCount = slot.seedOverflow.count
        slot.snapshot.freshKeys = []
        slot.snapshot.state = .ready
        slots[source] = slot
    }

    func load(
        _ source: FoundationCatalogSource,
        fetch: @Sendable (Int) async throws -> Page
    ) async throws {
        guard var slot = slots[source], slot.snapshot.state != .loading,
            slot.seedOverflow.isEmpty,
            let cursor = slot.snapshot.nextStartIndex
        else { throw Failure.unavailable }
        slot.generation &+= 1
        let generation = slot.generation
        slot.snapshot.state = .loading
        slots[source] = slot
        do {
            let result = try await fetch(cursor)
            try Task.checkCancellation()
            guard var current = slots[source], current.generation == generation else {
                throw Failure.stale
            }
            let items = try Self.validate(result, source: source, cursor: cursor)
            let previous = current.snapshot.items
            let previousKeys = try Set(previous.map { try $0.catalogKey() })
            let newKeys = try items.map { try $0.catalogKey() }
            let repeated = previousKeys.intersection(newKeys)
            guard Set(newKeys).count == newKeys.count,
                repeated.isSubset(of: current.supplementalKeys),
                previous.count + items.count - repeated.count <= Self.itemLimit
            else { throw Failure.invalidPage }
            var combined = previous
            let offsets = Dictionary(
                uniqueKeysWithValues: try previous.enumerated().map {
                    (try $0.element.catalogKey(), $0.offset)
                })
            for (item, key) in zip(items, newKeys) {
                if let index = offsets[key] {
                    combined[index] = item
                    current.supplementalKeys.remove(key)
                } else {
                    combined.append(item)
                }
            }
            current.snapshot.items = combined
            current.snapshot.nextStartIndex = result.page.nextStartIndex
            current.snapshot.freshKeys = Set(newKeys)
            current.snapshot.state =
                result.state == .ready && current.snapshot.items.isEmpty
                ? .empty : result.state
            slots[source] = current
        } catch {
            guard var current = slots[source], current.generation == generation else {
                throw Failure.stale
            }
            current.snapshot.state =
                error is CancellationError
                ? (current.snapshot.items.isEmpty ? .idle : .partial) : .failed
            slots[source] = current
            throw error
        }
    }

    /// Continue the fallback stream independently, after the original stream is exhausted.
    func loadSearchFallback(
        _ source: FoundationCatalogSource, query: String,
        fetch: @Sendable (Int) async throws -> Page
    ) async throws {
        guard var slot = slots[source], slot.snapshot.state != .loading,
            slot.snapshot.isSeededSearch, slot.seedOverflow.isEmpty,
            slot.snapshot.nextStartIndex == nil,
            let fallback = slot.snapshot.fallbackCursor
        else { throw Failure.unavailable }
        slot.generation &+= 1
        let generation = slot.generation
        slot.snapshot.state = .loading
        slots[source] = slot
        do {
            let result = try await fetch(fallback.nextStartIndex)
            try Task.checkCancellation()
            guard var current = slots[source], current.generation == generation,
                current.snapshot.fallbackCursor == fallback
            else { throw Failure.stale }
            let items = try Self.validate(result, source: source, cursor: fallback.nextStartIndex)
            guard items.allSatisfy({ $0.kind == .track }) else { throw Failure.invalidItem }
            let previousKeys = try Set(current.snapshot.items.map { try $0.catalogKey() })
            let keys = try items.map { try $0.catalogKey() }
            guard Set(keys).count == keys.count else { throw Failure.invalidPage }
            let newItems = zip(items, keys).filter {
                !previousKeys.contains($0.1)
                    && FoundationSearchResolver.titleScore($0.0.title, query: query) >= 60
            }
            guard current.snapshot.items.count + newItems.count <= Self.itemLimit else {
                throw Failure.invalidPage
            }
            current.snapshot.items.append(
                contentsOf: FoundationSearchResolver.ranked(newItems.map(\.0), query: query))
            current.snapshot.freshKeys = Set(newItems.map(\.1))
            current.snapshot.fallbackCursor = result.page.nextStartIndex.map {
                .init(term: fallback.term, nextStartIndex: $0)
            }
            current.snapshot.state =
                result.state == .ready && current.snapshot.items.isEmpty
                ? .empty : result.state
            slots[source] = current
        } catch {
            guard var current = slots[source], current.generation == generation else {
                throw Failure.stale
            }
            current.snapshot.state =
                error is CancellationError
                ? (current.snapshot.items.isEmpty ? .idle : .partial) : .failed
            slots[source] = current
            throw error
        }
    }

    private static func validate(_ result: Page, source: FoundationCatalogSource, cursor: Int)
        throws
        -> [FoundationItem]
    {
        guard [.ready, .partial, .unavailable].contains(result.state),
            result.page.items.count <= pageLimit,
            result.page.nextStartIndex.map({ $0 > cursor && $0 <= itemLimit }) ?? true,
            result.page.nextStartIndex == nil || !result.page.items.isEmpty
        else { throw Failure.invalidPage }
        return try result.page.items.map { item in
            guard
                item.catalogSource == source
                    || (item.catalogSource == nil && source.kind == .jellyfin)
            else { throw Failure.invalidSource }
            var scoped = item
            scoped.catalogSource = source
            _ = try scoped.catalogKey()
            for reference in [item.album, item.artist].compactMap({ $0 }) + item.genres {
                guard reference.catalogSource == nil || reference.catalogSource == source else {
                    throw Failure.invalidSource
                }
            }
            return scoped
        }
    }

    /// This projection carries metadata/opaque IDs only. It cannot start playback,
    /// leak a relative path, or claim that unavailable/missing records are playable.
    static func localPage(
        _ catalog: FoundationLocalCatalog, startIndex: Int, limit: Int,
        query: FoundationCatalogQuery = .songs
    ) throws -> Page {
        guard catalog.isValid, startIndex >= 0, limit > 0, limit <= pageLimit else {
            throw Failure.invalidPage
        }
        let query = try query.normalized()
        let records = catalog.records.filter { !$0.missing && query.includesLocalTitle($0.title) }
            .sorted { $0.id < $1.id }
        guard startIndex <= records.count else { throw Failure.invalidPage }
        let end = min(records.count, startIndex + limit)
        let source = FoundationCatalogSource.local(sourceID: catalog.sourceID)
        let items = records[startIndex..<end].map {
            FoundationItem(
                id: $0.id, title: $0.title, subtitle: "", kind: .track, duration: nil,
                catalogSource: source)
        }
        let state: State
        switch catalog.state {
        case .partial: state = .partial
        case .unavailable, .corrupt: state = .unavailable
        case .ready, .empty: state = .ready
        }
        return .init(
            page: .init(items: items, nextStartIndex: end < records.count ? end : nil), state: state
        )
    }
}
