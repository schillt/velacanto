import SwiftUI

struct FoundationPlaylistPermissions: Sendable, Equatable {
    var name: String = ""
    let canEdit: Bool
    let canDelete: Bool
}

/// Local occurrence identity is separate from the server mutation identity.
struct FoundationPlaylistEntry: Identifiable, Sendable, Equatable {
    let id: String
    let mutationID: String
    let item: FoundationItem
}

struct FoundationPlaylistPage: Sendable {
    let entries: [FoundationPlaylistEntry]
    let nextStartIndex: Int?
}

enum FoundationPlaylistError: Error, LocalizedError, Equatable {
    case tooLarge, changed, ambiguousMemberships, alreadyPresent, partialAddition, emptyAlbum,
        readOnly, partialRemoval, partialCreation, partialReorder
    var errorDescription: String? {
        switch self {
        case .readOnly:
            "This playlist is read-only for this account."
        case .tooLarge:
            "This playlist is too large to verify changes here. Manage it on the server."
        case .changed:
            "The playlist changed or the update could not be confirmed. Refresh before trying again."
        case .ambiguousMemberships:
            "This playlist contains repeated tracks that this server cannot edit individually. Track editing is read-only here."
        case .alreadyPresent:
            "These tracks are already in the playlist. This server keeps one copy of each track."
        case .partialAddition:
            "The addition could not be completed. Some tracks may have been added; refresh before trying again."
        case .partialCreation:
            "The playlist was created, but adding its songs could not be confirmed. Select the new playlist below to check or finish adding them."
        case .partialRemoval:
            "The removal could not be completed. Some tracks may have been removed; refresh before trying again."
        case .partialReorder:
            "The order could not be confirmed. Some songs may have moved; refresh before trying again."
        case .emptyAlbum:
            "This album has no tracks to add."
        }
    }
}

/// Explicit reconciliation is finite and cancellable, never a background scan.
enum FoundationPlaylistSnapshot {
    static func hasAmbiguousMemberships(_ entries: [FoundationPlaylistEntry]) -> Bool {
        Set(entries.map(\.mutationID)).count != entries.count
    }

    static func load(id: String, library: any FoundationLibrary, limit: Int = 10_000) async throws
        -> [FoundationPlaylistEntry]
    {
        guard limit > 0 else { throw FoundationPlaylistError.tooLarge }
        var offset = 0
        var pages = 0
        var entries: [FoundationPlaylistEntry] = []
        var seen: Set<String> = []
        while true {
            try Task.checkCancellation()
            guard pages < 100 else { throw FoundationPlaylistError.tooLarge }
            pages += 1
            let page = try await library.playlistEntries(id: id, startIndex: offset)
            try Task.checkCancellation()
            guard page.entries.count <= 100, entries.count + page.entries.count <= limit else {
                throw FoundationPlaylistError.tooLarge
            }
            for entry in page.entries {
                guard seen.insert(entry.id).inserted else { throw FoundationPlaylistError.changed }
            }
            entries.append(contentsOf: page.entries)
            guard let next = page.nextStartIndex else { return entries }
            guard !page.entries.isEmpty, next == offset + page.entries.count else {
                throw FoundationPlaylistError.changed
            }
            guard entries.count < limit else { throw FoundationPlaylistError.tooLarge }
            offset = next
        }
    }
}

enum FoundationPlaylistMutation {
    @MainActor
    static func reorder(
        playlistID: String, entries: [FoundationPlaylistEntry], from source: IndexSet,
        to destination: Int, library: any FoundationLibrary
    ) async throws -> [FoundationPlaylistEntry] {
        let plan = try FoundationPlaylistReorderPlan(
            entries: entries, from: source, to: destination)
        guard !plan.moves.isEmpty else { return entries }
        guard library.supportsPlaylistReordering else {
            throw FoundationLibraryError.unavailable
        }
        try Task.checkCancellation()
        let permissions = try await library.playlistPermissions(id: playlistID)
        try Task.checkCancellation()
        guard permissions.canEdit else { throw FoundationPlaylistError.readOnly }
        let before = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        guard FoundationPlaylistReorderPlan.sameMemberships(before, entries) else {
            throw FoundationPlaylistError.changed
        }
        var attemptedWrite = false
        do {
            for move in plan.moves {
                try Task.checkCancellation()
                attemptedWrite = true
                try await library.moveEntry(
                    in: playlistID, entryID: move.entryID, to: move.destination)
            }
            let after = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
            try Task.checkCancellation()
            guard FoundationPlaylistReorderPlan.sameMemberships(after, plan.entries) else {
                throw FoundationPlaylistError.changed
            }
            return after
        } catch {
            if error is CancellationError || (error as? FoundationLibraryError) == .cancelled {
                throw error
            }
            if attemptedWrite { throw FoundationPlaylistError.partialReorder }
            throw error
        }
    }

    static func create(name: String, library: any FoundationLibrary) async throws {
        let requestedName = try FoundationPlaylistName.validated(name)
        let created = try await library.createPlaylist(name: requestedName)
        let confirmed = try await library.playlistPermissions(id: created.id)
        try Task.checkCancellation()
        guard confirmed.name == requestedName else { throw FoundationPlaylistError.changed }
    }

    static func delete(id: String, library: any FoundationLibrary) async throws {
        try await library.deletePlaylist(id: id)
        var offset = 0
        var seen: Set<String> = []
        for _ in 0..<100 {
            try Task.checkCancellation()
            let page = try await library.playlists(startIndex: offset)
            try Task.checkCancellation()
            guard page.items.count <= 100, seen.count + page.items.count <= 10_000 else {
                throw FoundationPlaylistError.tooLarge
            }
            for item in page.items {
                guard item.kind == .playlist, item.id != id, seen.insert(item.id).inserted else {
                    throw FoundationPlaylistError.changed
                }
            }
            guard let next = page.nextStartIndex else { return }
            guard !page.items.isEmpty, next == offset + page.items.count else {
                throw FoundationPlaylistError.changed
            }
            offset = next
        }
        throw FoundationPlaylistError.tooLarge
    }

    @MainActor
    static func remove(
        playlistID: String, entry: FoundationPlaylistEntry, library: any FoundationLibrary,
        allowsRemoval: @MainActor () -> Bool = { true }
    ) async throws {
        try await remove(
            playlistID: playlistID, entries: [entry], library: library,
            allowsRemoval: { _ in allowsRemoval() })
    }

    @MainActor
    static func remove(
        playlistID: String, entries: [FoundationPlaylistEntry], library: any FoundationLibrary,
        allowsRemoval: @MainActor ([FoundationPlaylistEntry]) -> Bool = { _ in true }
    ) async throws {
        guard !entries.isEmpty, entries.count <= 10_000,
            Set(entries.map(\.mutationID)).count == entries.count,
            entries.allSatisfy({ !$0.mutationID.isEmpty && $0.item.kind == .track })
        else { throw FoundationPlaylistError.changed }
        let before = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        guard !FoundationPlaylistSnapshot.hasAmbiguousMemberships(before) else {
            throw FoundationPlaylistError.ambiguousMemberships
        }
        let selectedIDs = Set(entries.map(\.mutationID))
        let originals = Dictionary(uniqueKeysWithValues: before.map { ($0.mutationID, $0.item.id) })
        guard entries.allSatisfy({ originals[$0.mutationID] == $0.item.id }),
            allowsRemoval(entries)
        else { throw FoundationPlaylistError.changed }
        let retained = before.filter { !selectedIDs.contains($0.mutationID) }
        var attemptedWrite = false
        do {
            for entry in entries {
                try Task.checkCancellation()
                guard allowsRemoval([entry]) else { throw FoundationPlaylistError.changed }
                attemptedWrite = true
                try await library.removeEntry(from: playlistID, entryID: entry.mutationID)
            }
            let after = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
            try Task.checkCancellation()
            guard !FoundationPlaylistSnapshot.hasAmbiguousMemberships(after) else {
                throw FoundationPlaylistError.changed
            }
            let remaining = Dictionary(
                uniqueKeysWithValues: after.map { ($0.mutationID, $0.item.id) })
            guard selectedIDs.allSatisfy({ remaining[$0] == nil }),
                retained.allSatisfy({ remaining[$0.mutationID] == $0.item.id })
            else { throw FoundationPlaylistError.changed }
        } catch {
            if error is CancellationError || (error as? FoundationLibraryError) == .cancelled {
                throw error
            }
            if attemptedWrite { throw FoundationPlaylistError.partialRemoval }
            throw error
        }
    }

    static func add(playlistID: String, track: FoundationItem, library: any FoundationLibrary)
        async throws
    {
        _ = try await add(playlistID: playlistID, source: track, library: library)
    }

    struct Addition: Sendable {
        let added: Int
        let alreadyPresent: Int
        var message: String {
            "Added \(added) tracks. \(alreadyPresent) already in the playlist."
        }
    }

    static func sourceTracks(_ source: FoundationItem, library: any FoundationLibrary)
        async throws -> [FoundationItem]
    {
        if source.kind == .track { return [source] }
        guard source.kind == .album else { throw FoundationLibraryError.invalidResponse }
        var tracks: [FoundationItem] = []
        var offset = 0
        for _ in 0..<100 {
            try Task.checkCancellation()
            let page = try await library.tracks(albumID: source.id, startIndex: offset)
            try Task.checkCancellation()
            guard page.items.count <= 100, tracks.count + page.items.count <= 10_000,
                page.items.allSatisfy({ $0.kind == .track })
            else { throw FoundationPlaylistError.tooLarge }
            tracks.append(contentsOf: page.items)
            guard let next = page.nextStartIndex else {
                guard !tracks.isEmpty else { throw FoundationPlaylistError.emptyAlbum }
                return tracks
            }
            guard !page.items.isEmpty, next == offset + page.items.count else {
                throw FoundationPlaylistError.changed
            }
            offset = next
        }
        throw FoundationPlaylistError.tooLarge
    }

    @MainActor
    static func add(
        playlistID: String, source: FoundationItem, library: any FoundationLibrary,
        projectTracks: @MainActor ([FoundationItem], String?) -> [FoundationItem] = { items, _ in
            items
        }
    ) async throws -> Addition {
        let tracks = try await sourceTracks(source, library: library)
        return try await add(
            playlistID: playlistID, tracks: tracks, library: library,
            albumID: source.kind == .album ? source.id : nil, projectTracks: projectTracks)
    }

    @MainActor
    static func add(
        playlistID: String, tracks: [FoundationItem], library: any FoundationLibrary,
        albumID: String? = nil,
        projectTracks: @MainActor ([FoundationItem], String?) -> [FoundationItem] = { items, _ in
            items
        }
    ) async throws -> Addition {
        guard !tracks.isEmpty, tracks.count <= 10_000,
            tracks.allSatisfy({ $0.kind == .track })
        else { throw FoundationPlaylistError.changed }
        try Task.checkCancellation()
        let permission = try await library.playlistPermissions(id: playlistID)
        try Task.checkCancellation()
        guard permission.canEdit else { throw FoundationPlaylistError.readOnly }
        var snapshot = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        guard !FoundationPlaylistSnapshot.hasAmbiguousMemberships(snapshot) else {
            throw FoundationPlaylistError.ambiguousMemberships
        }
        let visibleTracks = projectTracks(tracks, albumID)
        var knownIDs = Set(snapshot.map { $0.item.id })
        let pending = visibleTracks.filter {
            library.supportsRepeatedPlaylistTracks || knownIDs.insert($0.id).inserted
        }
        guard !pending.isEmpty else { throw FoundationPlaylistError.alreadyPresent }
        guard snapshot.count + pending.count <= 10_000 else {
            throw FoundationPlaylistError.tooLarge
        }
        var attemptedWrite = false
        do {
            for offset in stride(from: 0, to: pending.count, by: 100) {
                try Task.checkCancellation()
                let batch = Array(pending[offset..<min(offset + 100, pending.count)])
                let expected = snapshot.reduce(into: [String: Int]()) {
                    $0[$1.item.id, default: 0] += 1
                }
                guard projectTracks(batch, albumID) == batch else {
                    throw FoundationPlaylistError.changed
                }
                attemptedWrite = true
                try await library.addTracks(to: playlistID, tracks: batch)
                let refreshed = try await FoundationPlaylistSnapshot.load(
                    id: playlistID, library: library)
                guard !FoundationPlaylistSnapshot.hasAmbiguousMemberships(refreshed) else {
                    throw FoundationPlaylistError.changed
                }
                var required = expected
                for track in batch { required[track.id, default: 0] += 1 }
                let actual = refreshed.reduce(into: [String: Int]()) {
                    $0[$1.item.id, default: 0] += 1
                }
                guard required.allSatisfy({ actual[$0.key, default: 0] >= $0.value }) else {
                    throw FoundationPlaylistError.changed
                }
                snapshot = refreshed
            }
            try Task.checkCancellation()
            return Addition(
                added: pending.count, alreadyPresent: visibleTracks.count - pending.count)
        } catch {
            if error is CancellationError { throw error }
            if attemptedWrite { throw FoundationPlaylistError.partialAddition }
            throw error
        }
    }

}

/// Account-owned invalidation; retained details reload only after a relevant edit.
@MainActor
final class FoundationPlaylistChanges: ObservableObject {
    @Published private(set) var revisions: [String: Int] = [:]
    @Published private(set) var catalogRevision = 0

    /// Names and membership in the playlist catalog changed, rather than only its songs.
    func catalogDidChange() { catalogRevision += 1 }
    private var projectTracks: @MainActor ([FoundationItem], String?) -> [FoundationItem]
    private var observeTracks: @MainActor ([FoundationItem], String?) -> Void = { _, _ in }

    init(
        projectTracks: @escaping @MainActor ([FoundationItem], String?) -> [FoundationItem] = {
            items, _ in items
        }
    ) {
        self.projectTracks = projectTracks
    }

    func configureTrackProjection(
        _ projection: @escaping @MainActor ([FoundationItem], String?) -> [FoundationItem],
        observe: @escaping @MainActor ([FoundationItem], String?) -> Void = { _, _ in }
    ) {
        projectTracks = projection
        observeTracks = observe
    }

    func observe(_ items: [FoundationItem], albumID: String? = nil) {
        observeTracks(items, albumID)
    }

    /// Project display only; retain the original occurrence for server mutations.
    func visibleEntries(_ entries: [FoundationPlaylistEntry]) -> [FoundationPlaylistEntry] {
        let items = projectTracks(
            entries.map { entry in
                var item = entry.item
                item.playlistEntryID = entry.mutationID
                return item
            }, nil)
        let occurrences = Set(items.compactMap(\.playlistEntryID))
        return entries.filter { occurrences.contains($0.mutationID) }
    }

    func revision(for id: String) -> Int { revisions[id, default: 0] }

    func reorder(
        playlistID: String, entries: [FoundationPlaylistEntry], from source: IndexSet,
        to destination: Int, library: any FoundationLibrary
    ) async throws -> [FoundationPlaylistEntry] {
        // A sent move may have reached the server even when confirmation fails.
        defer { invalidate(playlistID) }
        return try await FoundationPlaylistMutation.reorder(
            playlistID: playlistID, entries: entries, from: source, to: destination,
            library: library)
    }

    func add(playlistID: String, source: FoundationItem, library: any FoundationLibrary)
        async throws -> FoundationPlaylistMutation.Addition
    {
        try await performAddition(playlistID: playlistID) {
            try await FoundationPlaylistMutation.add(
                playlistID: playlistID, source: source, library: library,
                projectTracks: { items, albumID in
                    self.observeTracks(items, albumID)
                    return self.projectTracks(items, albumID)
                })
        }
    }

    func add(playlistID: String, tracks: [FoundationItem], library: any FoundationLibrary)
        async throws -> FoundationPlaylistMutation.Addition
    {
        try await performAddition(playlistID: playlistID) {
            try await FoundationPlaylistMutation.add(
                playlistID: playlistID, tracks: tracks, library: library,
                projectTracks: { items, albumID in
                    self.observeTracks(items, albumID)
                    return self.projectTracks(items, albumID)
                })
        }
    }

    private func performAddition(
        playlistID: String,
        operation: @MainActor () async throws -> FoundationPlaylistMutation.Addition
    ) async throws -> FoundationPlaylistMutation.Addition {
        do {
            let result = try await operation()
            invalidate(playlistID)
            return result
        } catch {
            // A cancelled or partially completed write may already be on the server.
            // Invalidate without claiming success or automatically retrying a mutation.
            if error is CancellationError || (error as? FoundationLibraryError) == .cancelled
                || (error as? FoundationPlaylistError) == .partialAddition
            {
                invalidate(playlistID)
            }
            throw error
        }
    }

    /// Remove the selected server membership, never every occurrence of the song.
    func remove(playlistID: String, track: FoundationItem, library: any FoundationLibrary)
        async throws
    {
        guard track.kind == .track, let entryID = track.playlistEntryID, !entryID.isEmpty else {
            throw FoundationPlaylistError.changed
        }
        try await remove(
            playlistID: playlistID,
            entries: [.init(id: entryID, mutationID: entryID, item: track)], library: library)
    }

    func remove(
        playlistID: String, entries: [FoundationPlaylistEntry], library: any FoundationLibrary
    ) async throws {
        guard !entries.isEmpty, entries.count <= 10_000,
            Set(entries.map(\.mutationID)).count == entries.count,
            entries.allSatisfy({ $0.item.kind == .track && !$0.mutationID.isEmpty })
        else { throw FoundationPlaylistError.changed }
        try Task.checkCancellation()
        let permissions = try await library.playlistPermissions(id: playlistID)
        try Task.checkCancellation()
        guard permissions.canEdit else { throw FoundationPlaylistError.readOnly }
        guard visibleEntries(entries).count == entries.count else {
            throw FoundationPlaylistError.changed
        }
        // Once reconciliation starts, conservatively refresh on every outcome.
        defer { invalidate(playlistID) }
        try await FoundationPlaylistMutation.remove(
            playlistID: playlistID, entries: entries, library: library,
            allowsRemoval: { self.visibleEntries($0).count == $0.count })
    }

    private func invalidate(_ id: String) {
        revisions[id, default: 0] += 1
    }
}

enum FoundationPlaylistName {
    static func validated(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FoundationLibraryError.invalidResponse }
        return name
    }
}

/// The presenting view owns its operation. Cancellation never claims a server rollback.
@MainActor
final class FoundationPlaylistOperation: ObservableObject {
    @Published private(set) var isPending = false
    @Published private(set) var message: String?
    @Published private(set) var succeeded = false
    private var task: Task<Void, Never>?
    private var revision = UUID()

    func run(
        successMessage: @escaping @MainActor () -> String = { "Completed." },
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isPending else { return }
        let owner = UUID()
        revision = owner
        isPending = true
        succeeded = false
        message = nil
        task = Task { [weak self] in
            do {
                try await operation()
                try Task.checkCancellation()
                guard let self, self.revision == owner else { return }
                self.succeeded = true
                self.message = successMessage()
            } catch {
                guard let self, self.revision == owner else { return }
                if let playlistError = error as? FoundationPlaylistError {
                    self.message = playlistError.errorDescription
                } else {
                    self.message = FoundationLibraryError.category(error).errorDescription
                        .map { $0 + " Refresh before repeating a change." }
                }
            }
            guard let self, self.revision == owner else { return }
            self.isPending = false
            self.task = nil
        }
    }

    func cancel() {
        revision = UUID()
        task?.cancel()
        task = nil
        isPending = false
        succeeded = false
        message =
            "Cancelled. A sent change may have reached the server; refresh before trying again."
    }
}

struct FoundationPlaylistIndex: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    @ObservedObject var model: FoundationBrowseModel
    var usesLibraryIndex = false
    @State private var creating = false
    @State private var refreshRevision = 0
    @State private var refreshPending = false

    private var createPlacement: ToolbarItemPlacement {
        #if os(macOS)
            .primaryAction
        #else
            .automatic
        #endif
    }

    var body: some View {
        Group {
            if usesLibraryIndex {
                FoundationLibraryIndexView(
                    kind: .playlist, model: model, library: library, player: player,
                    isActive: isActive, refreshToken: refreshRevision)
            } else {
                FoundationCatalogView(
                    title: "Playlists", model: model, library: library, player: player,
                    isActive: isActive, localItems: { downloads.downloadedPlaylists },
                    loader: { try await library.playlists(startIndex: $0) }
                )
            }
        }
        .onAppear { refreshPending = !usesLibraryIndex && model.loaded }
        .task(id: "\(isActive && !connectivity.localOnly)-\(refreshRevision)") {
            guard !usesLibraryIndex, isActive, !connectivity.localOnly, refreshPending else {
                return
            }
            refreshPending = false
            await model.load(.refresh, using: library.playlists)
        }
        .toolbar {
            ToolbarItem(placement: createPlacement) {
                Button("Create Playlist", systemImage: "plus") { creating = true }
                    .disabled(connectivity.localOnly || !library.supportsPlaylistManagement)
            }
        }
        .sheet(
            isPresented: $creating,
            onDismiss: {
                guard !connectivity.localOnly else { return }
                refreshPending = true
                refreshRevision += 1
            }, content: { FoundationPlaylistCreate(library: library) }
        )
        .onChange(of: connectivity.localOnly) { _, localOnly in
            if localOnly { creating = false }
        }
    }
}

struct FoundationPlaylistStatus: View {
    @ObservedObject var operation: FoundationPlaylistOperation
    var body: some View {
        if operation.isPending {
            ProgressView()
            Button("Cancel Request") { operation.cancel() }
        }
        if let message = operation.message { Text(message).font(.caption) }
    }
}
