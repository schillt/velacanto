import SwiftUI

/// Native drag destinations refer to the original list, before removing its sources.
struct FoundationPlaylistReorderPlan {
    struct Move: Equatable {
        let entryID: String
        let destination: Int
    }

    let entries: [FoundationPlaylistEntry]
    let moves: [Move]

    init(entries original: [FoundationPlaylistEntry], from source: IndexSet, to destination: Int)
        throws
    {
        guard !source.isEmpty, original.count <= 10_000,
            source.allSatisfy({ original.indices.contains($0) }),
            (0...original.count).contains(destination),
            !FoundationPlaylistSnapshot.hasAmbiguousMemberships(original),
            original.allSatisfy({ !$0.mutationID.isEmpty && $0.item.kind == .track })
        else { throw FoundationPlaylistError.changed }
        let positions = Array(source)
        let selected = positions.map { original[$0] }
        let insertion = destination - source.filter { $0 < destination }.count
        var requested = original.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        requested.insert(contentsOf: selected, at: insertion)
        entries = requested

        // Move only selected memberships. Moving preceding sources down in reverse,
        // then following sources up in order also handles noncontiguous selections.
        let numbered = Array(selected.enumerated())
        let before = numbered.filter { positions[$0.offset] < destination }.reversed()
        let after = numbered.filter { positions[$0.offset] >= destination }
        var working = original.map(\.mutationID)
        var requests: [Move] = []
        for (offset, entry) in Array(before) + after {
            let target = insertion + offset
            guard let current = working.firstIndex(of: entry.mutationID) else {
                throw FoundationPlaylistError.changed
            }
            if current != target {
                working.insert(working.remove(at: current), at: target)
                requests.append(Move(entryID: entry.mutationID, destination: target))
            }
        }
        guard working == requested.map(\.mutationID) else { throw FoundationPlaylistError.changed }
        moves = requests
    }

    static func sameMemberships(
        _ first: [FoundationPlaylistEntry], _ second: [FoundationPlaylistEntry]
    ) -> Bool {
        first.count == second.count
            && !FoundationPlaylistSnapshot.hasAmbiguousMemberships(first)
            && zip(first, second).allSatisfy {
                $0.mutationID == $1.mutationID && $0.item.id == $1.item.id
                    && $0.item.kind == .track && $1.item.kind == .track
            }
    }
}

/// Ambiguous server identities stay distinct and read-only instead of collapsing rows.
struct FoundationPlaylistReorderRow: Identifiable, Sendable {
    let id: String
    let index: Int
    let entry: FoundationPlaylistEntry

    static func make(_ entries: [FoundationPlaylistEntry]) -> [Self] {
        let ambiguous = FoundationPlaylistSnapshot.hasAmbiguousMemberships(entries)
        return entries.enumerated().map { index, entry in
            Self(id: ambiguous ? entry.id : entry.mutationID, index: index, entry: entry)
        }
    }
}

/// All occurrences stay visible: search and album projections must not change move indices.
struct FoundationPlaylistReorderSheet: View {
    @EnvironmentObject private var changes: FoundationPlaylistChanges
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads
    @Environment(\.dismiss) private var dismiss
    let playlist: FoundationItem
    let library: any FoundationLibrary
    @State private var entries: [FoundationPlaylistEntry] = []
    @State private var permissions: FoundationPlaylistPermissions?
    @State private var loaded = false
    @State private var requiresRefresh = true
    @StateObject private var operation = FoundationPlaylistOperation()

    private var canMove: Bool {
        loaded && !requiresRefresh && !operation.isPending && !connectivity.localOnly
            && permissions?.canEdit == true && library.supportsPlaylistReordering
            && !FoundationPlaylistSnapshot.hasAmbiguousMemberships(entries)
    }

    var body: some View {
        let rows = FoundationPlaylistReorderRow.make(entries)
        NavigationStack {
            List {
                ForEach(rows) { row in
                    reorderRow(row)
                }
                .reorderable()
                if loaded, entries.isEmpty {
                    ContentUnavailableView("No Songs Yet", systemImage: "music.note.list")
                }
            }
            .reorderContainer(
                for: FoundationPlaylistReorderRow.self, isEnabled: canMove, move: reorder
            )
            .disabled(operation.isPending)
            .navigationTitle("Reorder Songs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        operation.run { try await refresh() }
                    }.disabled(operation.isPending || connectivity.localOnly)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .modifier(FoundationPlaylistFeedback(operation: operation))
        }
        .modifier(FoundationPlaylistSheetSize())
        .onAppear { operation.run { try await refresh() } }
        .onDisappear { operation.cancel() }
        .onChange(of: connectivity.localOnly) { _, offline in
            if offline {
                operation.cancel()
                requiresRefresh = true
            }
        }
    }

    @ViewBuilder
    private func reorderRow(_ row: FoundationPlaylistReorderRow) -> some View {
        #if os(iOS)
            // Keep the row's touch-and-drag interaction separate from its menu.
            HStack(spacing: 8) {
                musicRow(row)
                Menu {
                    movementActions(for: row)
                } label: {
                    Label("Song actions", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("playlist-reorder-actions-\(row.id)")
                .disabled(!canMove)
            }
        #else
            musicRow(row)
                .contextMenu { movementActions(for: row) }
        #endif
    }

    private func musicRow(_ row: FoundationPlaylistReorderRow) -> some View {
        FoundationPlaylistMusicRow(item: row.entry.item, library: library)
            .accessibilityIdentifier("playlist-reorder-\(row.id)")
            .accessibilityActions { movementActions(for: row) }
    }

    private func reorder(
        _ difference: ReorderDifference<String, ReorderableSingleCollectionIdentifier>
    ) {
        guard canMove else { return }
        let rows = FoundationPlaylistReorderRow.make(entries)
        let ids = Set(difference.sources)
        let source = IndexSet(rows.filter { ids.contains($0.id) }.map(\.index))
        guard source.count == ids.count else { return }
        switch difference.destination.position {
        case .before(let id):
            guard let destination = rows.first(where: { $0.id == id })?.index else { return }
            move(from: source, to: destination)
        case .end:
            move(from: source, to: entries.count)
        }
    }

    @ViewBuilder
    private func movementActions(for row: FoundationPlaylistReorderRow) -> some View {
        Button("Move Up", systemImage: "arrow.up") {
            moveOccurrence(row.id, upwards: true)
        }.disabled(!canMove || row.index == 0)
        Button("Move Down", systemImage: "arrow.down") {
            moveOccurrence(row.id, upwards: false)
        }.disabled(!canMove || row.index + 1 == entries.count)
    }

    private func moveOccurrence(_ displayID: String, upwards: Bool) {
        let rows = FoundationPlaylistReorderRow.make(entries)
        guard let index = rows.first(where: { $0.id == displayID })?.index else { return }
        move(from: IndexSet(integer: index), to: upwards ? index - 1 : index + 2)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if operation.isPending {
                    ProgressView().controlSize(.small)
                    Text("Updating playlist…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel Request") { operation.cancel() }
                } else {
                    Text(footerMessage).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }.padding(16)
        }.background(.bar)
    }

    private var footerMessage: String {
        if connectivity.localOnly { return "Reconnect to refresh or reorder this playlist." }
        if permissions?.canEdit == false { return "This playlist is read-only for your account." }
        if !library.supportsPlaylistReordering {
            return "This server does not support playlist reordering."
        }
        if FoundationPlaylistSnapshot.hasAmbiguousMemberships(entries) {
            return FoundationPlaylistError.ambiguousMemberships.errorDescription ?? ""
        }
        if requiresRefresh { return "Refresh to confirm the server's order before moving songs." }
        return "Drag songs to reorder them. Every playlist occurrence is shown."
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard canMove,
            let plan = try? FoundationPlaylistReorderPlan(
                entries: entries, from: source, to: destination), !plan.moves.isEmpty
        else { return }
        let before = entries
        entries = plan.entries
        requiresRefresh = true
        operation.run(
            successMessage: { "Playlist order updated." },
            {
                defer { downloads.reconcilePlaylists() }
                let confirmed = try await changes.reorder(
                    playlistID: playlist.id, entries: before, from: source, to: destination,
                    library: library)
                try Task.checkCancellation()
                guard !connectivity.localOnly else { throw CancellationError() }
                entries = confirmed
                requiresRefresh = false
            })
    }

    private func refresh() async throws {
        guard !connectivity.localOnly else { throw CancellationError() }
        let permission = try await library.playlistPermissions(id: playlist.id)
        try Task.checkCancellation()
        let snapshot = try await FoundationPlaylistSnapshot.load(id: playlist.id, library: library)
        try Task.checkCancellation()
        guard !connectivity.localOnly else { throw CancellationError() }
        permissions = permission
        entries = snapshot
        loaded = true
        requiresRefresh = false
    }
}
