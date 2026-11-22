import Foundation

/// Owns one explicitly selected folder independently of any Jellyfin account.
/// Bookmark bytes are private authorization data, never catalog identifiers.
actor FoundationLocalSource {
    struct Selection: Codable, Equatable, Sendable {
        let version: Int
        let sourceID: UUID
        let bookmark: Data
    }

    enum Failure: Error { case corruptSelection, invalidStorage, superseded }
    static let selectionByteLimit = 1024 * 1024
    private let storage: URL
    private let index: FoundationLocalCatalogIndex
    private let makeBookmark: @Sendable (URL) throws -> Data
    private let scan:
        @Sendable (Data, UUID, FoundationLocalCatalogIndex) async throws
            -> FoundationLocalCatalog
    private var revision: UInt = 0
    private var refreshTask: Task<FoundationLocalCatalog, Error>?

    init(
        storage: URL,
        makeBookmark: @escaping @Sendable (URL) throws -> Data = {
            try FoundationLocalFolderAccess.bookmark(for: $0)
        },
        scan:
            @escaping @Sendable (Data, UUID, FoundationLocalCatalogIndex) async throws
            -> FoundationLocalCatalog = { @Sendable bookmark, sourceID, index in
                try await FoundationLocalSource.scanSelectedFolder(
                    bookmark: bookmark, sourceID: sourceID, index: index)
            }
    ) {
        self.storage = storage
        index = FoundationLocalCatalogIndex(storage: storage.appendingPathComponent("catalogs"))
        self.makeBookmark = makeBookmark
        self.scan = scan
    }

    /// Keep default-argument closure isolation inference out of the native scan.
    /// The index actor still owns filesystem work; access stays open until it returns.
    private nonisolated static func scanSelectedFolder(
        bookmark: Data, sourceID: UUID, index: FoundationLocalCatalogIndex
    ) async throws -> FoundationLocalCatalog {
        try await FoundationLocalFolderAccess.withAccess(to: bookmark) { root in
            try await index.refresh(sourceID: sourceID, authorizedRoot: root)
        }
    }

    /// Restore authorization identity without accessing music or exposing a path.
    func selection() throws -> Selection? {
        try validateStorage()
        let file = selectionURL
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, let size = values.fileSize,
            size <= Self.selectionByteLimit
        else { throw Failure.corruptSelection }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.selectionByteLimit + 1) ?? Data()
        guard data.count <= Self.selectionByteLimit,
            let selected = try? JSONDecoder().decode(Selection.self, from: data),
            selected.version == 1, !selected.bookmark.isEmpty
        else { throw Failure.corruptSelection }
        return selected
    }

    /// Called only with a native picker result. Reselection creates a new source:
    /// a different folder must never inherit an old folder's opaque identities.
    @discardableResult
    func select(_ folder: URL) throws -> UUID {
        guard folder.isFileURL, storage.isFileURL else { throw Failure.invalidStorage }
        guard FoundationLocalCatalogIndex.storageIsOutsideRoot(storage, root: folder) else {
            throw Failure.invalidStorage
        }
        let bookmark = try makeBookmark(folder)
        guard !bookmark.isEmpty, bookmark.count <= Self.selectionByteLimit / 2 else {
            throw Failure.corruptSelection
        }
        try validateStorage()
        let source = UUID()
        let data = try JSONEncoder().encode(
            Selection(version: 1, sourceID: source, bookmark: bookmark))
        guard data.count <= Self.selectionByteLimit else { throw Failure.corruptSelection }
        guard FoundationLocalCatalogIndex.storageIsOutsideRoot(storage, root: folder) else {
            throw Failure.invalidStorage
        }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        guard FoundationLocalCatalogIndex.storageIsOutsideRoot(storage, root: folder) else {
            throw Failure.invalidStorage
        }
        try data.write(to: selectionURL, options: [.atomic, .completeFileProtection])
        retireRefresh()
        return source
    }

    /// Cached browsing needs no access grant and never gates server publication.
    func cachedCatalog() async throws -> FoundationLocalCatalog? {
        guard let selected = try selection() else { return nil }
        let token = revision
        let result = await index.restore(sourceID: selected.sourceID)
        guard token == revision else { throw Failure.superseded }
        return result
    }

    /// Explicit refresh only. Denied/stale bookmarks retain cached records and
    /// report unavailable; there is no raw-path fallback or automatic retry.
    func refresh() async throws -> FoundationLocalCatalog? {
        guard let selected = try selection() else { return nil }
        retireRefresh()
        let token = revision
        let index = index
        let scan = scan
        let task = Task {
            try await scan(selected.bookmark, selected.sourceID, index)
        }
        refreshTask = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard token == revision else { throw Failure.superseded }
            refreshTask = nil
            guard result.sourceID == selected.sourceID, result.isValid else {
                throw Failure.corruptSelection
            }
            return result
        } catch {
            guard token == revision else { throw Failure.superseded }
            refreshTask = nil
            if error is CancellationError { throw error }
            let cached = await index.restore(sourceID: selected.sourceID)
            guard token == revision else { throw Failure.superseded }
            return .init(sourceID: selected.sourceID, state: .unavailable, records: cached.records)
        }
    }

    /// Removing authorization does not delete any music. Retired cached records
    /// are not returned or associated with a subsequent selection.
    func removeSelection() throws {
        try validateStorage()
        do {
            try FileManager.default.removeItem(at: selectionURL)
        } catch CocoaError.fileNoSuchFile {
            // Already absent is success; unreadable or invalid paths must fail.
        }
        retireRefresh()
    }

    private func retireRefresh() {
        revision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private var selectionURL: URL { storage.appendingPathComponent("selection.json") }

    private func validateStorage() throws {
        guard storage.isFileURL else { throw Failure.invalidStorage }
        do {
            // URL resource values can retain an earlier directory result after
            // the store is replaced. Inspect the current filesystem entry.
            let attributes = try FileManager.default.attributesOfItem(atPath: storage.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw Failure.invalidStorage
            }
        } catch CocoaError.fileReadNoSuchFile {
            // A new store is allowed; permission and traversal errors are not.
        }
    }
}
