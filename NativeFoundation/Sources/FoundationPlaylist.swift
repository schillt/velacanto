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

enum FoundationPlaylistError: Error, LocalizedError {
    case tooLarge, changed, ambiguousMemberships, alreadyPresent
    var errorDescription: String? {
        switch self {
        case .tooLarge:
            "This playlist is too large to verify changes here. Manage it on the server."
        case .changed:
            "The playlist changed or the update could not be confirmed. Refresh before trying again."
        case .ambiguousMemberships:
            "This playlist contains repeated tracks that this server cannot edit individually. Track editing is read-only here."
        case .alreadyPresent:
            "This track is already in the playlist. This server keeps one copy of each track."
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

    static func remove(
        playlistID: String, entry: FoundationPlaylistEntry, library: any FoundationLibrary
    ) async throws {
        let before = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        guard !FoundationPlaylistSnapshot.hasAmbiguousMemberships(before) else {
            throw FoundationPlaylistError.ambiguousMemberships
        }
        guard
            before.contains(where: {
                $0.mutationID == entry.mutationID && $0.item.id == entry.item.id
            })
        else {
            throw FoundationPlaylistError.changed
        }
        let siblingIDs = Set(
            before.filter { $0.item.id == entry.item.id && $0.mutationID != entry.mutationID }.map(
                \.mutationID))
        try await library.removeEntry(from: playlistID, entryID: entry.mutationID)
        let after = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        let remainingIDs = Set(after.map(\.mutationID))
        let remainingSiblingIDs = Set(
            after.filter { $0.item.id == entry.item.id }.map(\.mutationID))
        guard !FoundationPlaylistSnapshot.hasAmbiguousMemberships(after),
            !remainingIDs.contains(entry.mutationID), siblingIDs.isSubset(of: remainingSiblingIDs)
        else {
            throw FoundationPlaylistError.changed
        }
    }

    static func add(playlistID: String, track: FoundationItem, library: any FoundationLibrary)
        async throws
    {
        let permission = try await library.playlistPermissions(id: playlistID)
        guard permission.canEdit else { throw FoundationLibraryError.authentication }
        let before = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        guard !FoundationPlaylistSnapshot.hasAmbiguousMemberships(before) else {
            throw FoundationPlaylistError.ambiguousMemberships
        }
        let beforeCount = before.filter { $0.item.id == track.id }.count
        guard library.supportsRepeatedPlaylistTracks || beforeCount == 0 else {
            throw FoundationPlaylistError.alreadyPresent
        }
        try await library.addTracks(to: playlistID, tracks: [track])
        let after = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        guard !FoundationPlaylistSnapshot.hasAmbiguousMemberships(after),
            after.filter({ $0.item.id == track.id }).count > beforeCount
        else {
            throw FoundationPlaylistError.changed
        }
    }

}

enum FoundationPlaylistName {
    static func validated(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FoundationLibraryError.invalidResponse }
        return name
    }
}

/// A sheet owns its operation. Cancellation never claims the server rolled back a write.
@MainActor
final class FoundationPlaylistOperation: ObservableObject {
    @Published private(set) var isPending = false
    @Published private(set) var message: String?
    @Published private(set) var succeeded = false
    private var task: Task<Void, Never>?
    private var revision = UUID()

    func run(_ operation: @escaping @MainActor () async throws -> Void) {
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
                self.message = "Completed."
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
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    @ObservedObject var model: FoundationBrowseModel
    @State private var creating = false

    var body: some View {
        FoundationCatalogView(
            title: "Playlists", model: model, library: library, player: player,
            isActive: isActive, loader: { try await library.playlists(startIndex: $0) }
        )
        .onAppear {
            if model.loaded { Task { await model.load(.refresh, using: library.playlists) } }
        }
        .toolbar {
            Button("Create Playlist", systemImage: "plus") { creating = true }
                .disabled(!library.supportsPlaylistManagement)
        }
        .sheet(
            isPresented: $creating,
            onDismiss: {
                Task { await model.load(.refresh, using: library.playlists) }
            }, content: { FoundationPlaylistCreate(library: library) })
    }
}

private struct FoundationPlaylistCreate: View {
    let library: any FoundationLibrary
    @State private var name = ""
    @StateObject private var operation = FoundationPlaylistOperation()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("Playlist name", text: $name)
                Button("Create") {
                    operation.run {
                        try await FoundationPlaylistMutation.create(name: name, library: library)
                    }
                }.disabled(
                    operation.isPending || operation.succeeded
                        || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                FoundationPlaylistStatus(operation: operation)
            }.navigationTitle("Create Playlist")
                .toolbar { Button("Done") { dismiss() } }
        }.frame(minWidth: 300, minHeight: 260)
            .onDisappear { operation.cancel() }
    }
}

struct FoundationPlaylistEditor: View {
    let playlist: FoundationItem
    var onDeleted: () -> Void = {}
    var onRenamed: (String) -> Void = { _ in }
    let library: any FoundationLibrary
    @State private var name = ""
    @State private var permissions: FoundationPlaylistPermissions?
    @State private var entries: [FoundationPlaylistEntry] = []
    @State private var visibleCount = 100
    @State private var membershipEditable = false
    @State private var membershipMessage: String?
    @State private var confirmDelete = false
    @State private var deleted = false
    @StateObject private var operation = FoundationPlaylistOperation()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Playlist") {
                    TextField("Name", text: $name)
                    Button("Rename") {
                        operation.run {
                            let requestedName = try FoundationPlaylistName.validated(name)
                            try await library.renamePlaylist(id: playlist.id, name: requestedName)
                            let refreshed = try await library.playlistPermissions(id: playlist.id)
                            try Task.checkCancellation()
                            permissions = refreshed
                            name = refreshed.name
                            guard name == requestedName else {
                                throw FoundationLibraryError.invalidResponse
                            }
                            onRenamed(name)
                        }
                    }.disabled(
                        permissions?.canEdit != true
                            || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Delete Playlist", role: .destructive) { confirmDelete = true }
                        .disabled(permissions?.canDelete != true)
                    if let permissions, !permissions.canEdit {
                        Text("This playlist is read-only for this account.")
                    }
                }
                Section("Tracks") {
                    if let membershipMessage { Text(membershipMessage).font(.caption) }
                    ForEach(Array(entries.prefix(visibleCount))) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.item.title)
                                Text(entry.item.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                operation.run {
                                    try await FoundationPlaylistMutation.remove(
                                        playlistID: playlist.id, entry: entry, library: library)
                                    try await refresh()
                                }
                            }.disabled(permissions?.canEdit != true || !membershipEditable)
                        }
                    }
                    if visibleCount < entries.count {
                        Button("Load More") { visibleCount += 100 }
                    }
                    Text("Add tracks from a song’s Actions menu.").font(.caption)
                }
                FoundationPlaylistStatus(operation: operation)
            }
            .disabled(operation.isPending || deleted)
            .navigationTitle("Manage Playlist")
            .toolbar {
                Button("Refresh") { operation.run { try await refresh() } }.disabled(
                    operation.isPending || deleted)
                Button("Done") { dismiss() }
                if operation.isPending { Button("Cancel Request") { operation.cancel() } }
            }
            .confirmationDialog(
                "Delete this playlist from the server?", isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Playlist", role: .destructive) {
                    operation.run {
                        try await FoundationPlaylistMutation.delete(
                            id: playlist.id, library: library)
                        try Task.checkCancellation()
                        deleted = true
                        dismiss()
                        onDeleted()
                    }
                }
            }
        }.frame(minWidth: 320, minHeight: 400)
            .onAppear {
                name = playlist.title
                operation.run { try await refresh() }
            }
            .onDisappear { operation.cancel() }
    }

    private func refresh() async throws {
        let permission = try await library.playlistPermissions(id: playlist.id)
        try Task.checkCancellation()
        permissions = permission
        name = permission.name
        membershipEditable = false
        do {
            let snapshot = try await FoundationPlaylistSnapshot.load(
                id: playlist.id, library: library)
            try Task.checkCancellation()
            entries = snapshot
            visibleCount = 100
            membershipEditable = !FoundationPlaylistSnapshot.hasAmbiguousMemberships(snapshot)
            membershipMessage =
                membershipEditable
                ? nil : FoundationPlaylistError.ambiguousMemberships.errorDescription
        } catch {
            try Task.checkCancellation()
            membershipMessage = (error as? FoundationPlaylistError)?.errorDescription
            throw error
        }
    }

}

struct FoundationPlaylistPicker: View {
    let track: FoundationItem
    let library: any FoundationLibrary
    @StateObject private var playlists = FoundationBrowseModel()
    @StateObject private var operation = FoundationPlaylistOperation()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(playlists.items) { playlist in
                    Button(playlist.title) {
                        operation.run {
                            try await FoundationPlaylistMutation.add(
                                playlistID: playlist.id, track: track, library: library)
                        }
                    }.disabled(operation.isPending || operation.succeeded)
                }
                if playlists.nextStartIndex != nil {
                    Button("Load More") {
                        Task { await playlists.load(.more, using: library.playlists) }
                    }
                    .disabled(playlists.isLoading)
                }
                if let error = playlists.errorMessage { Text(error).foregroundStyle(.red) }
                if playlists.isLoading { ProgressView() }
                Button("Refresh") {
                    Task { await playlists.load(.refresh, using: library.playlists) }
                }
                FoundationPlaylistStatus(operation: operation)
            }.navigationTitle("Add to Playlist")
                .toolbar { Button("Done") { dismiss() } }
                .task { await playlists.load(.initial, using: library.playlists) }
        }.frame(minWidth: 300, minHeight: 350)
            .onDisappear { operation.cancel() }
    }

}

private struct FoundationPlaylistStatus: View {
    @ObservedObject var operation: FoundationPlaylistOperation
    var body: some View {
        if operation.isPending {
            ProgressView()
            Button("Cancel Request") { operation.cancel() }
        }
        if let message = operation.message { Text(message).font(.caption) }
    }
}
