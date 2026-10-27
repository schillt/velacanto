import SwiftUI

enum FoundationPlaylistSheet: String, Identifiable {
    case manage, addSongs, reorderSongs
    var id: String { rawValue }
}

struct FoundationPlaylistSheetSize: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
            content.frame(minWidth: 560, idealWidth: 640, minHeight: 500, idealHeight: 640)
        #else
            content
        #endif
    }
}

/// A shared row keeps the editor and song picker aligned with the library's artwork and type.
struct FoundationPlaylistMusicRow: View {
    let item: FoundationItem
    let library: any FoundationLibrary

    var body: some View {
        HStack(spacing: 12) {
            FoundationCatalogArtwork(item: item, library: library, isActive: true, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(1).truncationMode(.tail)
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let duration = item.duration, duration.isFinite, duration > 0 {
                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Progress belongs to the sheet; failures use a native alert rather than a custom panel.
struct FoundationPlaylistFeedback: ViewModifier {
    @ObservedObject var operation: FoundationPlaylistOperation
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: operation.isPending) { _, pending in
                if !pending, !operation.succeeded { error = operation.message }
            }
            .alert(
                "Playlist Update",
                isPresented: Binding(
                    get: { error != nil }, set: { if !$0 { error = nil } }
                )
            ) {
                Button("OK", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
    }
}

struct FoundationPlaylistEditor: View {
    @EnvironmentObject private var changes: FoundationPlaylistChanges
    @EnvironmentObject private var preferences: FoundationPlaybackPreferences
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads
    @Environment(\.dismiss) private var dismiss
    let playlist: FoundationItem
    var onDeleted: () -> Void = {}
    var onRenamed: (String) -> Void = { _ in }
    let library: any FoundationLibrary
    var showsDetailsInitially = false
    @State private var name = ""
    @State private var permissions: FoundationPlaylistPermissions?
    @State private var entries: [FoundationPlaylistEntry] = []
    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var detailsExpanded = false
    private enum RelatedSheet: String, Identifiable {
        case addSongs, reorderSongs
        var id: String { rawValue }
    }
    @State private var relatedSheet: RelatedSheet?
    @State private var confirmDelete = false
    @State private var loaded = false
    @StateObject private var operation = FoundationPlaylistOperation()

    private var visibleEntries: [FoundationPlaylistEntry] {
        let _ = preferences.showDuplicateAlbumTracks
        return changes.visibleEntries(entries)
    }
    private var filteredEntries: [FoundationPlaylistEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ambiguous = FoundationPlaylistSnapshot.hasAmbiguousMemberships(entries)
        return visibleEntries.filter {
            text.isEmpty || $0.item.title.localizedStandardContains(text)
                || $0.item.subtitle.localizedStandardContains(text)
                || ($0.item.album?.title.localizedStandardContains(text) ?? false)
        }.map {
            FoundationPlaylistEntry(
                id: ambiguous ? $0.id : $0.mutationID, mutationID: $0.mutationID, item: $0.item)
        }
    }
    private var canEditDetails: Bool {
        !connectivity.localOnly && permissions?.canEdit == true
    }
    private var editable: Bool {
        canEditDetails && !FoundationPlaylistSnapshot.hasAmbiguousMemberships(entries)
    }
    private var selectedEntries: [FoundationPlaylistEntry] {
        visibleEntries.filter { selection.contains($0.mutationID) }
    }

    var body: some View {
        NavigationStack {
            songList
                .navigationTitle(name.isEmpty ? playlist.title : name)
                .searchable(text: $query, prompt: "Find in Playlist")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Add Songs", systemImage: "plus") { relatedSheet = .addSongs }
                            .disabled(!editable || operation.isPending)
                        Button("Reorder Songs", systemImage: "arrow.up.arrow.down") {
                            relatedSheet = .reorderSongs
                        }
                        .disabled(
                            !editable || !library.supportsPlaylistReordering || operation.isPending
                        )
                        .accessibilityIdentifier("playlist-editor-reorder-songs")
                        Button("Playlist Details", systemImage: "pencil") {
                            detailsExpanded.toggle()
                        }.disabled(operation.isPending)
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            operation.run { try await refresh() }
                        }.disabled(connectivity.localOnly || operation.isPending)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { managementFooter }
                .modifier(FoundationPlaylistFeedback(operation: operation))
                .confirmationDialog(
                    "Delete this playlist from Jellyfin?",
                    isPresented: $confirmDelete, titleVisibility: .visible
                ) {
                    Button("Delete Playlist", role: .destructive) {
                        operation.run {
                            guard !connectivity.localOnly else { throw CancellationError() }
                            try await FoundationPlaylistMutation.delete(
                                id: playlist.id, library: library)
                            try Task.checkCancellation()
                            downloads.reconcilePlaylists()
                            changes.catalogDidChange()
                            dismiss()
                            onDeleted()
                        }
                    }
                } message: {
                    Text("The songs will stay in your Jellyfin library.")
                }
                .sheet(
                    item: $relatedSheet,
                    onDismiss: {
                        if !connectivity.localOnly { operation.run { try await refresh() } }
                    }
                ) { destination in
                    switch destination {
                    case .addSongs:
                        FoundationPlaylistSongPicker(playlist: playlist, library: library)
                    case .reorderSongs:
                        FoundationPlaylistReorderSheet(playlist: playlist, library: library)
                    }
                }
        }
        .modifier(FoundationPlaylistSheetSize())
        .onAppear {
            name = playlist.title
            if !loaded { detailsExpanded = showsDetailsInitially }
            if !connectivity.localOnly { operation.run { try await refresh() } }
        }
        .onDisappear { operation.cancel() }
        .onChange(of: visibleEntries.map(\.mutationID)) { _, ids in
            selection.formIntersection(ids)
        }
        .onChange(of: connectivity.localOnly) { _, offline in
            if offline {
                confirmDelete = false
                relatedSheet = nil
                operation.cancel()
            }
        }
    }

    private var songList: some View {
        List(selection: $selection) {
            if detailsExpanded { detailsSection }
            Section {
                ForEach(filteredEntries) { entry in
                    FoundationPlaylistMusicRow(item: entry.item, library: library)
                        .tag(entry.mutationID)
                        .contextMenu {
                            Button(
                                "Remove from Playlist", systemImage: "minus.circle",
                                role: .destructive
                            ) {
                                let selected =
                                    selection.contains(entry.mutationID)
                                    ? selectedEntries : [entry]
                                remove(selected)
                            }.disabled(!editable || operation.isPending)
                        }
                        #if os(iOS)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                    remove([entry])
                                }.disabled(!editable || operation.isPending)
                            }
                        #endif
                }
                if loaded, filteredEntries.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No Songs Yet" : "No Matching Songs",
                        systemImage: "music.note.list",
                        description: Text(
                            query.isEmpty
                                ? "Add songs to start building this playlist."
                                : "Try another title, artist or album.")
                    )
                }
            } header: {
                HStack {
                    Text("\(visibleEntries.count) Songs")
                    Spacer()
                    if !filteredEntries.isEmpty {
                        Button(
                            selection.isSuperset(of: filteredEntries.map(\.mutationID))
                                ? "Deselect All" : "Select All"
                        ) {
                            let ids = Set(filteredEntries.map(\.mutationID))
                            if selection.isSuperset(of: ids) {
                                selection.subtract(ids)
                            } else {
                                selection.formUnion(ids)
                            }
                        }.buttonStyle(.borderless)
                    }
                }
            } footer: {
                if permissions?.canEdit == false {
                    Text("This playlist is read-only for your account.")
                } else if FoundationPlaylistSnapshot.hasAmbiguousMemberships(entries) {
                    Text(FoundationPlaylistError.ambiguousMemberships.errorDescription ?? "")
                }
            }
        }
        .disabled(operation.isPending)
        #if os(iOS)
            .environment(\.editMode, .constant(.active))
        #else
            .onDeleteCommand { if editable { remove(selectedEntries) } }
        #endif
        .accessibilityIdentifier("playlist-management-songs")
    }

    private var detailsSection: some View {
        Section("Playlist Details") {
            TextField("Playlist name", text: $name)
            Button("Save Name") {
                operation.run {
                    let requested = try FoundationPlaylistName.validated(name)
                    guard !connectivity.localOnly else { throw CancellationError() }
                    try await library.renamePlaylist(id: playlist.id, name: requested)
                    try Task.checkCancellation()
                    try await refresh()
                    guard name == requested else { throw FoundationPlaylistError.changed }
                    downloads.reconcilePlaylists()
                    onRenamed(name)
                    changes.catalogDidChange()
                    detailsExpanded = false
                }
            }.disabled(
                !canEditDetails || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                confirmDelete = true
            }
            .disabled(connectivity.localOnly || permissions?.canDelete != true)
        }
    }

    private var managementFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if operation.isPending {
                    ProgressView().controlSize(.small)
                    Text("Updating playlist…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel Request") { operation.cancel() }
                } else {
                    Text(
                        selection.isEmpty
                            ? "Select songs to manage" : "\(selectedEntries.count) selected"
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle", role: .destructive) {
                        remove(selectedEntries)
                    }.disabled(!editable || selectedEntries.isEmpty)
                }
            }
            .padding(16)
        }.background(.bar)
    }

    private func remove(_ selected: [FoundationPlaylistEntry]) {
        guard editable, !selected.isEmpty else { return }
        operation.run(
            successMessage: { "Removed \(selected.count) songs from the playlist." },
            {
                guard !connectivity.localOnly else { throw CancellationError() }
                do {
                    try await changes.remove(
                        playlistID: playlist.id, entries: selected, library: library)
                } catch {
                    downloads.reconcilePlaylists()
                    throw error
                }
                downloads.reconcilePlaylists()
                selection.subtract(selected.map(\.mutationID))
                try await refresh()
            })
    }

    private func refresh() async throws {
        guard !connectivity.localOnly else { throw CancellationError() }
        let permission = try await library.playlistPermissions(id: playlist.id)
        try Task.checkCancellation()
        let snapshot = try await FoundationPlaylistSnapshot.load(id: playlist.id, library: library)
        try Task.checkCancellation()
        guard !connectivity.localOnly else { throw CancellationError() }
        changes.observe(snapshot.map(\.item))
        permissions = permission
        name = permission.name
        entries = snapshot
        loaded = true
    }
}

/// Add from inside a playlist: selection survives queries and pages until Add is pressed.
struct FoundationPlaylistSongPicker: View {
    @EnvironmentObject private var changes: FoundationPlaylistChanges
    @EnvironmentObject private var actions: FoundationLibraryActions
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads
    @Environment(\.dismiss) private var dismiss
    let playlist: FoundationItem
    let library: any FoundationLibrary
    var dismissTitle: String? = nil
    @StateObject private var songs = FoundationBrowseModel()
    @StateObject private var operation = FoundationPlaylistOperation()
    @State private var query = ""
    @State private var selected: [FoundationItem] = []
    @State private var revision = 0
    @State private var summary = ""

    private var selectedIDs: Set<String> { Set(selected.map(\.id)) }
    private var visibleSelection: [FoundationItem] { actions.visibleTracks(selected) }
    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(songs.items) { song in
                    Button {
                        summary = ""
                        if selectedIDs.contains(song.id) {
                            selected.removeAll { $0.id == song.id }
                        } else {
                            selected.append(song)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            FoundationPlaylistMusicRow(item: song, library: library)
                            Image(
                                systemName: selectedIDs.contains(song.id)
                                    ? "checkmark.circle.fill" : "plus.circle"
                            )
                            .font(.title3).foregroundStyle(.tint)
                        }
                    }.buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(selectedIDs.contains(song.id) ? "Deselect" : "Select") \(song.title), \(song.subtitle)"
                        )
                }
                if songs.isLoading { ProgressView("Loading songs…") }
                if songs.loaded, songs.items.isEmpty {
                    ContentUnavailableView.search(text: searchTerm)
                }
                if let error = songs.errorMessage {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") {
                        songs.request(songs.retryRequest)
                        revision += 1
                    }
                }
                if songs.nextStartIndex != nil {
                    Button("Load More Songs") {
                        songs.request(.more)
                        revision += 1
                    }.disabled(songs.isLoading)
                }
            }
            .disabled(operation.isPending || connectivity.localOnly)
            .navigationTitle("Add Songs")
            .searchable(text: $query, prompt: "Search Songs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(dismissTitle ?? (operation.succeeded ? "Done" : "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(visibleSelection.count)") { addSelection() }
                        .disabled(
                            visibleSelection.isEmpty || operation.isPending
                                || connectivity.localOnly)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        if operation.isPending { ProgressView().controlSize(.small) }
                        Text(
                            summary.isEmpty
                                ? "\(visibleSelection.count) selected for \(playlist.title)"
                                : summary
                        )
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        if operation.isPending {
                            Button("Cancel Request") { operation.cancel() }
                        } else if !selected.isEmpty {
                            Button("Clear") {
                                selected = []
                                summary = ""
                            }
                        }
                    }.padding(16)
                }.background(.bar)
            }
            .modifier(FoundationPlaylistFeedback(operation: operation))
            .task(id: "\(searchTerm)-\(revision)-\(connectivity.localOnly)") {
                guard !connectivity.localOnly else { return }
                if revision == 0 { songs.clearRetainedData() }
                do {
                    if !searchTerm.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
                    try Task.checkCancellation()
                    await songs.loadPending(using: loadSongs)
                } catch {}
            }
        }
        .modifier(FoundationPlaylistSheetSize())
        .onAppear {
            songs.configureFavoriteObservations(actions)
            songs.configureCatalogPagination()
        }
        .onChange(of: searchTerm) { _, _ in
            songs.clearRetainedData()
            revision = 0
        }
        .onChange(of: connectivity.localOnly) { _, offline in
            if offline { operation.cancel() }
        }
        .onDisappear { operation.cancel() }
    }

    private func loadSongs(_ offset: Int) async throws -> FoundationPage {
        if searchTerm.isEmpty { return try await library.songs(startIndex: offset) }
        return try await library.search(
            query: searchTerm, kind: .track, startIndex: offset, limit: 50)
    }

    private func addSelection() {
        let tracks = visibleSelection
        guard !tracks.isEmpty, !connectivity.localOnly else { return }
        operation.run(
            successMessage: { summary },
            {
                do {
                    let result = try await changes.add(
                        playlistID: playlist.id, tracks: tracks, library: library)
                    try Task.checkCancellation()
                    summary = result.message
                    downloads.reconcilePlaylists()
                    selected = []
                } catch {
                    downloads.reconcilePlaylists()
                    throw error
                }
            })
    }
}

/// Add from elsewhere: the same destination picker is reached by song and album menus.
struct FoundationPlaylistPicker: View {
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var changes: FoundationPlaylistChanges
    @EnvironmentObject private var downloads: FoundationDownloads
    @Environment(\.dismiss) private var dismiss
    let source: FoundationItem
    let library: any FoundationLibrary
    @StateObject private var playlists = FoundationBrowseModel()
    @StateObject private var operation = FoundationPlaylistOperation()
    @State private var query = ""
    @State private var revision = 0
    @State private var creating = false
    @State private var newName = ""
    @State private var summary = ""
    @State private var createdDestination: FoundationItem?

    private var filtered: [FoundationItem] {
        playlists.items.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(
                        source.title,
                        systemImage: source.kind == .album ? "square.stack" : "music.note"
                    )
                    .lineLimit(1).foregroundStyle(.secondary)
                } header: {
                    Text("Add to Playlist")
                }
                if let createdDestination, !operation.succeeded {
                    Section {
                        Button {
                            addTo(createdDestination)
                        } label: {
                            Label(createdDestination.title, systemImage: "music.note.list")
                        }
                    } header: {
                        Text("New Playlist")
                    } footer: {
                        Text(
                            "This playlist was created. Select it to finish adding your music; some songs may already be present."
                        )
                    }
                }
                ForEach(filtered.filter { $0.id != createdDestination?.id }) { playlist in
                    Button {
                        addTo(playlist)
                    } label: {
                        HStack {
                            FoundationCatalogArtwork(
                                item: playlist, library: library, isActive: true, size: 44)
                            Text(playlist.title).lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Image(systemName: "plus").foregroundStyle(.tint)
                        }.padding(.vertical, 3).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if playlists.loaded, filtered.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No Playlists Yet" : "No Matching Playlists",
                        systemImage: "music.note.list",
                        description: Text(
                            "Create a playlist or load more to find another destination."))
                }
                if playlists.isLoading { ProgressView("Loading playlists…") }
                if let error = playlists.errorMessage {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") {
                        playlists.request(.refresh)
                        revision += 1
                    }
                }
                if playlists.nextStartIndex != nil {
                    Button("Load More Playlists") {
                        playlists.request(.more)
                        revision += 1
                    }
                    .disabled(playlists.isLoading)
                }
            }
            .disabled(connectivity.localOnly || operation.isPending || operation.succeeded)
            .navigationTitle("Add to Playlist")
            .searchable(text: $query, prompt: "Filter Playlists")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(operation.succeeded ? "Done" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Playlist", systemImage: "plus") { creating = true }
                        .disabled(
                            connectivity.localOnly || operation.isPending || operation.succeeded)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if operation.isPending || operation.succeeded {
                    HStack {
                        if operation.isPending { ProgressView().controlSize(.small) }
                        Text(operation.succeeded ? summary : "Updating playlist…")
                        Spacer()
                        if operation.isPending { Button("Cancel Request") { operation.cancel() } }
                    }.padding(16).background(.bar)
                }
            }
            .modifier(FoundationPlaylistFeedback(operation: operation))
            .alert("New Playlist", isPresented: $creating) {
                TextField("Playlist name", text: $newName)
                Button("Cancel", role: .cancel) { newName = "" }
                Button("Create and Add") { createAndAdd() }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Create a playlist and add this music to it.")
            }
            .task(id: "\(revision)-\(connectivity.localOnly)") {
                await playlists.loadPending(
                    ifActive: !connectivity.localOnly, using: library.playlists)
            }
        }
        .modifier(FoundationPlaylistSheetSize())
        .onDisappear { operation.cancel() }
        .onChange(of: connectivity.localOnly) { _, offline in
            if offline {
                creating = false
                operation.cancel()
            }
        }
    }

    private func addTo(_ playlist: FoundationItem) {
        operation.run(
            successMessage: { summary },
            {
                guard !connectivity.localOnly else { throw CancellationError() }
                do {
                    let result = try await changes.add(
                        playlistID: playlist.id, source: source, library: library)
                    try Task.checkCancellation()
                    downloads.reconcilePlaylists()
                    summary = result.message
                } catch {
                    downloads.reconcilePlaylists()
                    throw error
                }
            })
    }

    private func createAndAdd() {
        let requested = newName
        operation.run(
            successMessage: { summary },
            {
                guard !connectivity.localOnly else { throw CancellationError() }
                let name = try FoundationPlaylistName.validated(requested)
                let created = try await library.createPlaylist(name: name)
                try Task.checkCancellation()
                createdDestination = created
                changes.catalogDidChange()
                newName = ""
                playlists.request(.refresh)
                revision += 1
                do {
                    let permission = try await library.playlistPermissions(id: created.id)
                    try Task.checkCancellation()
                    guard permission.name == name, permission.canEdit else {
                        throw FoundationPlaylistError.changed
                    }
                    let result = try await changes.add(
                        playlistID: created.id, source: source, library: library)
                    try Task.checkCancellation()
                    downloads.reconcilePlaylists()
                    summary = result.message
                } catch {
                    downloads.reconcilePlaylists()
                    if error is CancellationError { throw error }
                    throw FoundationPlaylistError.partialCreation
                }
            })
    }
}

/// Standalone creation uses the same native sheet language as the other playlist paths.
struct FoundationPlaylistCreate: View {
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var changes: FoundationPlaylistChanges
    @EnvironmentObject private var downloads: FoundationDownloads
    @Environment(\.dismiss) private var dismiss
    let library: any FoundationLibrary
    @State private var name = ""
    @State private var addSongsNext = true
    @State private var createdPlaylist: FoundationItem?
    @State private var showingSongs = false
    @State private var creationAttempt: UUID?
    @State private var creationRequestPending = false
    @StateObject private var operation = FoundationPlaylistOperation()
    @FocusState private var nameFocused: Bool

    private var canCreate: Bool {
        !connectivity.localOnly && !operation.isPending && !creationRequestPending
            && createdPlaylist == nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if showingSongs, let createdPlaylist {
                FoundationPlaylistSongPicker(
                    playlist: createdPlaylist, library: library, dismissTitle: "Done")
            } else {
                composer
            }
        }
        .onDisappear {
            creationAttempt = nil
            creationRequestPending = false
            operation.cancel()
        }
        .onChange(of: connectivity.localOnly) { _, offline in
            if offline { operation.cancel() }
        }
    }

    private var composer: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 112, height: 112)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                    if let createdPlaylist {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(createdPlaylist.title).font(.title2.bold())
                            Text(
                                "Your playlist was created. Add songs now, or choose Done to finish. If a request failed, refresh its details before making changes."
                            )
                            .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Playlist Name").font(.subheadline.weight(.medium))
                            TextField("Name your playlist", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .font(.title3)
                                .focused($nameFocused)
                                .accessibilityIdentifier("playlist-create-name")
                                .onSubmit { if canCreate { create() } }
                        }
                        .disabled(operation.isPending)
                        Toggle("Add Songs Next", isOn: $addSongsNext)
                            .disabled(operation.isPending)
                        Text(
                            "Create a playlist in your Jellyfin library, then choose the songs you want to add."
                        )
                        .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(createdPlaylist == nil ? "New Playlist" : "Playlist Created")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(createdPlaylist == nil ? "Cancel" : "Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if createdPlaylist != nil {
                        Button("Add Songs") { showingSongs = true }
                            .disabled(operation.isPending || connectivity.localOnly)
                    } else {
                        Button("Create", action: create)
                            .disabled(!canCreate)
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("playlist-create-confirm")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if creationRequestPending {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(
                            operation.isPending ? "Creating playlist…" : "Checking request outcome…"
                        )
                        .foregroundStyle(.secondary)
                        Spacer()
                        if operation.isPending { Button("Cancel Request") { operation.cancel() } }
                    }.padding(16).background(.bar)
                }
            }
            .modifier(FoundationPlaylistFeedback(operation: operation))
            .task { if createdPlaylist == nil { nameFocused = true } }
        }
        #if os(macOS)
            .frame(
                minWidth: 480, idealWidth: 520, maxWidth: 600,
                minHeight: 420, idealHeight: 500, maxHeight: 640)
        #endif
    }

    private func create() {
        guard canCreate else { return }
        let requested = name
        let attempt = UUID()
        creationAttempt = attempt
        creationRequestPending = true
        nameFocused = false
        operation.run {
            defer {
                if creationAttempt == attempt {
                    creationAttempt = nil
                    creationRequestPending = false
                }
            }
            guard !connectivity.localOnly else { throw CancellationError() }
            let validName = try FoundationPlaylistName.validated(requested)
            let created = try await library.createPlaylist(name: validName)
            guard creationAttempt == attempt else { throw CancellationError() }
            // Retain a known acknowledgment even when Cancel Request raced with its return.
            createdPlaylist = created
            changes.catalogDidChange()
            downloads.reconcilePlaylists()
            try Task.checkCancellation()
            let permission = try await library.playlistPermissions(id: created.id)
            try Task.checkCancellation()
            guard creationAttempt == attempt else { throw CancellationError() }
            guard permission.name == validName else { throw FoundationPlaylistError.changed }
            if addSongsNext { showingSongs = true } else { dismiss() }
        }
    }
}
