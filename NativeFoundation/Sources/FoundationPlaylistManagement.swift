import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

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
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads
    @Environment(\.dismiss) private var dismiss
    @Environment(\.foundationReduceMotion) private var reduceMotion
    let playlist: FoundationItem
    var onDeleted: () -> Void = {}
    var onRenamed: (String) -> Void = { _ in }
    var onUpdated: (FoundationItem) -> Void = { _ in }
    let library: any FoundationLibrary
    var showsDetailsInitially = false
    var startsAddingSongs = false
    @State private var name = ""
    @State private var overview = ""
    @State private var isPublic: Bool?
    @State private var savedName = ""
    @State private var savedOverview = ""
    @State private var savedPublic: Bool?
    @State private var permissions: FoundationPlaylistPermissions?
    @State private var canEditOverview = false
    @State private var canEditCover = false
    @State private var saveSummary = ""
    @State private var addSummary = ""
    @State private var entries: [FoundationPlaylistEntry] = []
    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var confirmSave = false
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @State private var loaded = false
    @State private var requiresRefresh = true
    #if os(iOS)
        @State private var phoneKeyboardVisible = false
    #endif
    @State private var showingCovers = false
    @State private var coverOpeningID = UUID()
    @State private var preparedCoverOpeningID: UUID?
    @State private var covers = FoundationPlaylistCoverPreset.choices(palettes: [.teal])
    @State private var hoveringCover = false
    @State private var selectedCover: FoundationPlaylistCoverPreset?
    @State private var savedCover: FoundationPlaylistCoverPreset?
    @State private var updatedPlaylist: FoundationItem?
    @State private var addingSongs = false
    @State private var addQuery = ""
    @State private var addResultKind: FoundationItem.Kind = .track
    @State private var addVisibleCount = 12
    @State private var addRevision = 0
    @State private var addedSelection: [FoundationItem] = []
    @StateObject private var addModel = FoundationBrowseModel()
    @StateObject private var addAlbums = FoundationBrowseModel()
    @StateObject private var addArtists = FoundationBrowseModel()
    @State private var addCollection: FoundationItem?
    @StateObject private var operation = FoundationPlaylistOperation()

    private var addSearchTerm: String {
        addQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canEditDetails: Bool {
        loaded && !connectivity.localOnly && permissions?.canEdit == true
    }
    private var editable: Bool {
        canEditDetails && !requiresRefresh
            && !FoundationPlaylistSnapshot.hasAmbiguousMemberships(entries)
    }
    private var canMove: Bool {
        editable && !operation.isPending && query.isEmpty && library.supportsPlaylistReordering
    }
    private var rows: [FoundationPlaylistReorderRow] {
        FoundationPlaylistReorderRow.make(entries).filter { row in
            query.isEmpty || row.entry.item.title.localizedStandardContains(query)
                || row.entry.item.subtitle.localizedStandardContains(query)
                || (row.entry.item.album?.title.localizedStandardContains(query) ?? false)
        }
    }
    private var selectedEntries: [FoundationPlaylistEntry] {
        entries.filter { selection.contains($0.mutationID) }
    }
    private var cachedArtwork: FoundationCurrentArtwork.Result? {
        library.immediateArtworkResult(for: updatedPlaylist ?? playlist, size: 160)
    }
    private var dirty: Bool {
        loaded
            && (name != savedName || overview != savedOverview || isPublic != savedPublic
                || selectedCover != nil)
    }

    var body: some View {
        NavigationStack {
            editorPage
                #if os(iOS)
                    .navigationTitle("Manage Playlist")
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        #if os(macOS)
                            if !addingSongs {
                                Button("Close", systemImage: "xmark") {
                                    if dirty { confirmDiscard = true } else { dismiss() }
                                }.disabled(operation.isPending).buttonStyle(.bordered)
                            }
                        #else
                            Button("Close", systemImage: "xmark") {
                                if dirty { confirmDiscard = true } else { dismiss() }
                            }.disabled(operation.isPending)
                        #endif
                    }
                    ToolbarItemGroup(placement: .confirmationAction) {
                        #if os(macOS)
                            if !addingSongs {
                                Button("Save", systemImage: "checkmark") { confirmSave = true }
                                    .disabled(!canEditDetails || operation.isPending || !dirty)
                                    .buttonStyle(.borderedProminent)
                                Button("Add Songs", systemImage: "plus") { openAddMusicSearch() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!editable || operation.isPending)
                                    .accessibilityIdentifier("playlist-manager-add-disclosure")
                            }
                        #else
                            Button("Save", systemImage: "checkmark") { confirmSave = true }
                                .disabled(!canEditDetails || operation.isPending || !dirty)
                                .buttonStyle(.glassProminent)
                        #endif
                    }
                    #if os(iOS)
                        ToolbarItem(placement: .primaryAction) { playlistOptions }
                    #endif
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    #if os(macOS)
                        if !addingSongs && showsManagementFeedback {
                            managementFeedback.padding(16).background(.bar)
                        }
                    #else
                        if !phoneKeyboardVisible { managementBar }
                    #endif
                }
                .overlay(alignment: .bottomTrailing) {
                    #if os(iOS)
                        if phoneKeyboardVisible && !addingSongs { phoneKeyboardDismissButton }
                    #endif
                }
                .modifier(FoundationPlaylistFeedback(operation: operation))
                .alert("Save playlist changes?", isPresented: $confirmSave) {
                    Button("Save Changes", systemImage: "checkmark") { saveDetails() }
                    Button("Keep Editing", role: .cancel) {}
                } message: {
                    Text("Save your playlist details and artwork changes.")
                }
                .confirmationDialog(
                    "Delete this playlist from Jellyfin?", isPresented: $confirmDelete,
                    titleVisibility: .visible
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
                .confirmationDialog(
                    "Discard unsaved changes?", isPresented: $confirmDiscard,
                    titleVisibility: .visible
                ) {
                    Button("Discard Changes", role: .destructive) { dismiss() }
                    Button("Keep Editing", role: .cancel) {}
                }
                #if os(macOS)
                    .onDeleteCommand { if !addingSongs && editable { remove(selectedEntries) } }
                #endif
        }
        .modifier(FoundationPlaylistSheetSize())
        #if os(macOS)
            .background { FoundationPlaylistSheetActivation().frame(width: 0, height: 0) }
        #endif
        #if os(iOS)
            .sheet(isPresented: $addingSongs) { addMusicSheet }
        #endif
        .presentationBackground(.ultraThinMaterial)
        .interactiveDismissDisabled(dirty || operation.isPending)
        .onAppear {
            if !loaded {
                name = playlist.title
                addingSongs = startsAddingSongs
            }
            if !connectivity.localOnly { operation.run { try await refresh() } }
            addModel.configureCatalogPagination()
            addAlbums.configureCatalogPagination()
            addArtists.configureCatalogPagination()
        }
        .task(
            id:
                "\(library.catalogScopeID)-\(showingCovers)-\(coverOpeningID)-\(connectivity.localOnly)"
        ) {
            await prepareCoverChoices()
        }
        #if os(iOS)
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            ) { notification in
                guard
                    notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool != false
                else { return }
                let frame =
                    notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                phoneKeyboardVisible = (frame?.height ?? 0) > 0
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            ) { _ in
                phoneKeyboardVisible = false
            }
            .onChange(of: addingSongs) { _, shown in
                if !shown { phoneKeyboardVisible = false }
            }
        #endif
        .onDisappear { operation.cancel() }
        .onChange(of: library.catalogScopeID) { _, _ in
            operation.cancel()
            permissions = nil
            loaded = false
            requiresRefresh = true
            selectedCover = nil
            addedSelection = []
            selection = []
            dismiss()
        }
        .onChange(of: connectivity.localOnly) { _, offline in
            if offline {
                confirmDelete = false
                confirmSave = false
                operation.cancel()
                requiresRefresh = true
            }
        }
        .onChange(of: entries.map(\.mutationID)) { _, ids in selection.formIntersection(ids) }
        .onChange(of: addResultKind) { _, _ in addVisibleCount = 12 }
        .onChange(of: addQuery) { _, _ in
            addCollection = nil
            addModel.clearRetainedData()
            addAlbums.clearRetainedData()
            addArtists.clearRetainedData()
            addRevision = 0
            addVisibleCount = 12
        }
        .task(
            id:
                "\(library.catalogScopeID)-\(addResultKind)-\(addingSongs)-\(addQuery)-\(addCollection?.sharedArtworkIdentity ?? "search")-\(addRevision)-\(connectivity.localOnly)"
        ) {
            guard addingSongs, !connectivity.localOnly else { return }
            let term = addSearchTerm
            let collection = addCollection
            // An empty search is intentionally inert; never enumerate the catalog here.
            guard collection != nil || !term.isEmpty else { return }
            do {
                if collection == nil { try await Task.sleep(for: .milliseconds(250)) }
                try Task.checkCancellation()
                if let collection {
                    await addModel.loadPending { offset in
                        if collection.kind == .album {
                            return try await library.tracks(
                                albumID: collection.id, startIndex: offset)
                        }
                        return try await library.tracks(artistID: collection.id, startIndex: offset)
                    }
                } else {
                    let model =
                        addResultKind == .track
                        ? addModel : addResultKind == .album ? addAlbums : addArtists
                    await model.loadPending {
                        try await library.search(
                            query: term, kind: addResultKind, startIndex: $0, limit: 12)
                    }
                }
            } catch {}
        }
    }

    private var playlistOptions: some View {
        Menu("Playlist Options", systemImage: "ellipsis") {
            deletePlaylistButton
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("playlist-manager-options")
    }

    private var deletePlaylistButton: some View {
        Button("Delete Playlist", systemImage: "trash", role: .destructive) {
            confirmDelete = true
        }
        .disabled(
            !loaded || connectivity.localOnly || permissions?.canDelete != true
                || operation.isPending
        )
        .accessibilityIdentifier("playlist-manager-delete")
    }

    @ViewBuilder private var editorPage: some View {
        #if os(macOS)
            if addingSongs {
                addMusicSheet
            } else {
                managerSurface
            }
        #else
            managerSurface
        #endif
    }

    private var addMusicSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            FoundationPlaylistAddSearchHeader(
                query: $addQuery, browsingCollection: addCollection != nil,
                isEnabled: editable && !operation.isPending,
                closeDisabled: operation.isPending, close: { addingSongs = false })
            Picker("Search", selection: $addResultKind) {
                Text("Songs").tag(FoundationItem.Kind.track)
                Text("Albums").tag(FoundationItem.Kind.album)
                Text("Artists").tag(FoundationItem.Kind.artist)
            }
            .pickerStyle(.segmented)
            .disabled(addCollection != nil || !editable || operation.isPending)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) { addSection }
            }
            Button("Add \(addedSelection.count) Songs", systemImage: "plus.circle.fill") {
                addSongs()
            }
            #if os(macOS)
                .buttonStyle(.borderedProminent)
            #else
                .buttonStyle(.glassProminent)
            #endif
            .disabled(!editable || operation.isPending || addedSelection.isEmpty)
            if operation.isPending {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Updating playlist…")
                    Spacer()
                    Button("Cancel Request") { operation.cancel() }
                }
            } else if !operation.succeeded, let message = operation.message {
                HStack {
                    Text(message).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry", systemImage: "arrow.clockwise") {
                        operation.run { try await refresh() }
                    }.disabled(connectivity.localOnly)
                }
            } else if !addSummary.isEmpty {
                Text(addSummary).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        #if os(macOS)
            .frame(minWidth: 500, idealWidth: 560, minHeight: 440, idealHeight: 560)
        #else
            .overlay(alignment: .bottomTrailing) {
                if phoneKeyboardVisible { phoneKeyboardDismissButton }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
            .interactiveDismissDisabled(operation.isPending)
        #endif
    }

    @ViewBuilder private var managerContents: some View {
        #if os(macOS)
            GroupBox { detailsSection }
            GroupBox { visibilitySection }
        #else
            detailsSection
                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            visibilitySection
                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
        #endif
        if showingCovers {
            coverSection
                #if os(iOS)
                    .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                #endif
        }
        songsSection
            #if os(iOS)
                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            #endif
    }

    private func openAddMusicSearch() {
        addCollection = nil
        addQuery = ""
        addModel.clearRetainedData()
        addAlbums.clearRetainedData()
        addArtists.clearRetainedData()
        addRevision = 0
        addVisibleCount = 12
        addingSongs = true
    }

    @ViewBuilder private var managerSurface: some View {
        #if os(macOS)
            // Keep the OS27 reorder interaction on the same scroll-host path as Queue.
            // A heterogeneous selection List uses NSOutlineView's separate drag bridge.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    managerContents
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .swipeActionsContainer()
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Text("Manage Playlist").font(.headline)
                    Spacer()
                    deletePlaylistButton
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Delete Playlist")
                }
                .padding(.horizontal, 24).padding(.vertical, 8)
            }
        #else
            List(selection: $selection) {
                managerContents
            }
            .reorderContainer(
                for: FoundationPlaylistReorderRow.self, isEnabled: canMove, move: reorder
            )
            .swipeActionsContainer()
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .foregroundStyle(.primary)
            .listStyle(.insetGrouped)
            .listSectionSpacing(20)
        #endif
    }

    @ViewBuilder private var detailsSection: some View {
        Section {
            HStack(alignment: .top, spacing: 20) {
                Button {
                    if !showingCovers {
                        coverOpeningID = UUID()
                        covers = FoundationPlaylistCoverPreset.choices(
                            palettes: [cachedArtwork?.tint ?? .teal]).map { preset in
                                if let frozen = selectedCover ?? savedCover, frozen.id == preset.id
                                {
                                    return frozen
                                }
                                return preset
                            }
                    }
                    showingCovers.toggle()
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Group {
                            if let cover = selectedCover ?? savedCover {
                                FoundationPlaylistCoverArtwork(preset: cover, playlistTitle: name)
                            } else if let image = cachedArtwork?.image {
                                Image(decorative: image, scale: 1).resizable().scaledToFill()
                            } else {
                                Rectangle().fill(.quaternary).overlay {
                                    Image(systemName: "music.note.list").font(.largeTitle)
                                }
                            }
                        }
                        .frame(width: 104, height: 104).clipShape(.rect(cornerRadius: 16))
                        #if os(macOS)
                            if hoveringCover || showingCovers {
                                Image(systemName: "pencil").padding(9).background(
                                    .regularMaterial, in: .circle
                                ).padding(6)
                            }
                        #else
                            Image(systemName: "pencil").padding(9).background(
                                .regularMaterial, in: .circle
                            ).padding(6)
                        #endif
                    }
                }
                .buttonStyle(.plain)
                .onHover { hoveringCover = $0 }
                .accessibilityLabel("Edit playlist artwork")
                .accessibilityHint("Choose a cover; artwork changes only when you save.")
                .disabled(!canEditDetails || !canEditCover || operation.isPending)
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Playlist name", text: $name).font(.title2.weight(.semibold))
                    TextField("Description", text: $overview, axis: .vertical)
                        .lineLimit(3...6).font(.body).disabled(!canEditOverview)
                    if !canEditOverview || !canEditCover {
                        Text("Your server permissions limit description or artwork editing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!canEditDetails || operation.isPending)
            }.padding(.vertical, 12)
        }
    }

    private var visibilitySection: some View {
        Section {
            Toggle(isOn: Binding(get: { isPublic ?? false }, set: { isPublic = $0 })) {
                Label("Public Playlist", systemImage: "globe")
            }
            .disabled(!canEditDetails || operation.isPending || isPublic == nil)
            if isPublic == nil {
                Text("Visibility isn’t available for this playlist.").font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Visibility")
        }
    }

    private var coverSection: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(covers) { preset in
                        Button {
                            selectedCover = preset
                        } label: {
                            FoundationPlaylistCoverArtwork(preset: preset, playlistTitle: name)
                                .frame(width: 76, height: 76)
                                .clipShape(.rect(cornerRadius: 12))
                                .overlay(alignment: .bottomTrailing) {
                                    if selectedCover?.id == preset.id {
                                        Image(systemName: "checkmark.circle.fill").padding(5)
                                    }
                                }
                        }.buttonStyle(.plain).accessibilityLabel(preset.title)
                    }
                }.padding(.vertical, 4)
            }.scrollIndicators(.hidden)
            Button("Keep Current Artwork", systemImage: "arrow.uturn.backward") {
                selectedCover = nil
            }
        } header: {
            Label("Artwork", systemImage: "photo")
        }
        .disabled(!canEditDetails || !canEditCover || operation.isPending)
    }

    private var songsSection: some View {
        Section {
            TextField("Find in Playlist", text: $query)
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    #if os(macOS)
                        Button {
                            if selection.contains(row.entry.mutationID) {
                                selection.remove(row.entry.mutationID)
                            } else {
                                selection.insert(row.entry.mutationID)
                            }
                        } label: {
                            Image(
                                systemName: selection.contains(row.entry.mutationID)
                                    ? "checkmark.circle.fill" : "circle"
                            )
                            .foregroundStyle(.tint)
                            .frame(minWidth: 28, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Select \(row.entry.item.title)")
                        .accessibilityValue(
                            selection.contains(row.entry.mutationID) ? "Selected" : "Not selected"
                        )
                        .disabled(!editable || operation.isPending)
                    #endif
                    FoundationPlaylistMusicRow(item: row.entry.item, library: library)
                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                        .opacity(canMove ? 1 : 0.35)
                        .accessibilityLabel("Reorder \(row.entry.item.title)")
                }
                #if os(iOS)
                    .tag(row.entry.mutationID)
                #endif
                .accessibilityIdentifier("playlist-reorder-\(row.id)")
                .contextMenu {
                    Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive)
                    { remove([row.entry]) }
                    .disabled(!editable || operation.isPending)
                    Button("Move Up", systemImage: "arrow.up") { move(row, upwards: true) }
                        .disabled(!canMove || row.index == 0)
                    Button("Move Down", systemImage: "arrow.down") { move(row, upwards: false) }
                        .disabled(!canMove || row.index + 1 == entries.count)
                }
                .swipeActions(
                    edge: .trailing, allowsFullSwipe: true,
                    content: {
                        Button("Remove from Playlist", systemImage: "minus", role: .destructive) {
                            remove([row.entry])
                        }
                        .labelStyle(.iconOnly).disabled(!editable || operation.isPending)
                    }, onPresentationChanged: { _ in })
            }
            .reorderable()
            if loaded, entries.isEmpty {
                Text("Add songs to start building this playlist.").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Label("\(entries.count) Songs", systemImage: "music.note.list")
                Spacer()

            }
        } footer: {
            if permissions?.canEdit == false {
                Text("This playlist is read-only for your account.")
            } else if FoundationPlaylistSnapshot.hasAmbiguousMemberships(entries) {
                Text(FoundationPlaylistError.ambiguousMemberships.errorDescription ?? "")
            } else if requiresRefresh {
                Text("Review the latest songs before making another change.")
            } else if !query.isEmpty {
                Text("Clear the search to reorder songs.")
            }
        }
        .accessibilityIdentifier("playlist-management-songs")
        #if os(macOS)
            // Only occurrence rows participate; cover/search/detail sections have no
            // reorder registration and cannot replace this container's collection.
            .reorderContainer(
                for: FoundationPlaylistReorderRow.self, isEnabled: canMove, move: reorder
            )
        #endif
    }

    @ViewBuilder private var addSection: some View {
        Group {
            if let collection = addCollection {
                Button("Back to Search", systemImage: "chevron.left") { browseAddCollection(nil) }
                    .buttonStyle(.borderless)
                Label(
                    collection.title,
                    systemImage: collection.kind == .artist ? "person" : "square.stack"
                )
                .font(.headline)
            } else if addSearchTerm.isEmpty {
                Text("Search your library, then choose songs or open an album or artist.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let collection = addCollection {
                addResults(addModel, title: "Songs in \(collection.title)")
            } else if !addSearchTerm.isEmpty {
                addResults(
                    addResultKind == .track
                        ? addModel : addResultKind == .album ? addAlbums : addArtists,
                    title: addResultKind == .track
                        ? "Songs" : addResultKind == .album ? "Albums" : "Artists")
                if addSearchHasNoResults {
                    Section { ContentUnavailableView.search(text: addSearchTerm) }
                }
            }
        }
        .disabled(!editable || operation.isPending)
    }

    private var addSearchHasNoResults: Bool {
        let models = [
            addResultKind == .track ? addModel : addResultKind == .album ? addAlbums : addArtists
        ]
        return models.allSatisfy { $0.loaded && $0.items.isEmpty && $0.errorMessage == nil }
    }

    @ViewBuilder private func addResults(_ model: FoundationBrowseModel, title: String) -> some View
    {
        if !model.items.isEmpty || model.isLoading || model.errorMessage != nil {
            Section {
                ForEach(visibleAddItems(model)) { item in
                    Button {
                        if item.kind == .track {
                            if addedSelection.contains(where: { $0.id == item.id }) {
                                addedSelection.removeAll { $0.id == item.id }
                            } else {
                                addedSelection.append(item)
                            }
                        } else if item.kind == .album || item.kind == .artist {
                            browseAddCollection(item)
                        }
                    } label: {
                        HStack {
                            FoundationPlaylistMusicRow(item: item, library: library)
                            if item.kind == .track {
                                Image(
                                    systemName: addedSelection.contains(where: { $0.id == item.id })
                                        ? "checkmark.circle.fill" : "plus.circle"
                                )
                                .foregroundStyle(.tint)
                            } else {
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                if model.isLoading { ProgressView("Searching…") }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry", systemImage: "arrow.clockwise") {
                        model.request(model.retryRequest)
                        addRevision += 1
                    }
                }
                if visibleAddItems(model).count < model.items.count || model.nextStartIndex != nil {
                    Button("More \(title)", systemImage: "ellipsis") {
                        let hasHiddenItems = visibleAddItems(model).count < model.items.count
                        addVisibleCount += 12
                        if !hasHiddenItems, model.nextStartIndex != nil {
                            model.request(.more)
                            addRevision += 1
                        }
                    }.disabled(model.isLoading)
                }
            } header: {
                Text(title)
            }
        } else if addCollection != nil, model.loaded {
            Section { Text("No songs are available here.").foregroundStyle(.secondary) }
        }
    }

    private func visibleAddItems(_ model: FoundationBrowseModel) -> [FoundationItem] {
        Array(model.items.prefix(addVisibleCount))
    }

    private func browseAddCollection(_ item: FoundationItem?) {
        addVisibleCount = 12
        addCollection = item
        addModel.clearRetainedData()
        addRevision = 0
    }

    private var showsManagementFeedback: Bool {
        operation.isPending || !saveSummary.isEmpty || !selection.isEmpty
            || (!operation.succeeded && operation.message != nil)
    }

    private var managementBar: some View {
        VStack(spacing: 12) {
            if showsManagementFeedback { managementFeedback }
            Button {
                openAddMusicSearch()
            } label: {
                #if os(macOS)
                    Label("Add Songs", systemImage: "plus").frame(maxWidth: .infinity)
                #else
                    Label("Add Songs", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                #endif
            }
            #if os(macOS)
                .buttonStyle(.borderedProminent)
            #else
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .frame(maxWidth: 320)
                .frame(maxWidth: .infinity)
            #endif
            .disabled(!editable || operation.isPending)
            .accessibilityIdentifier("playlist-manager-add-disclosure")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        #if os(macOS)
            .background(.bar)
        #else
            .background(.ultraThinMaterial)
        #endif
    }

    #if os(iOS)
        private var phoneKeyboardDismissButton: some View {
            Button {
                // An explicit user action follows UIKit's existing responder chain.
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            } label: {
                Image(systemName: "chevron.down").font(.headline)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .frame(width: 52, height: 52)
            .accessibilityLabel("Hide Keyboard")
            .accessibilityIdentifier("playlist-manager-hide-keyboard")
            .padding(.trailing, 16).padding(.bottom, 4)
        }
    #endif

    private var managementFeedback: some View {
        HStack(spacing: 12) {
            if operation.isPending {
                ProgressView().controlSize(.small)
                Text("Updating playlist…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel Request") {
                    requiresRefresh = true
                    operation.cancel()
                }
            } else {
                if !saveSummary.isEmpty {
                    Text(saveSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !selection.isEmpty {
                    Button(
                        "Remove \(selectedEntries.count)", systemImage: "minus.circle",
                        role: .destructive
                    ) { remove(selectedEntries) }
                    .disabled(!editable)
                }
                Spacer()
                if !operation.succeeded, operation.message != nil {
                    Button("Retry", systemImage: "arrow.clockwise") {
                        operation.run { try await refresh() }
                    }
                    .disabled(connectivity.localOnly)
                }
            }
        }
    }

    private func prepareCoverChoices() async {
        guard showingCovers, preparedCoverOpeningID != coverOpeningID else { return }
        let opening = coverOpeningID
        let scope = library.catalogScopeID
        preparedCoverOpeningID = opening
        // Only this editor's already-loaded album references; never enumerate the library.
        var seen: Set<String> = []
        let albums = entries.compactMap { $0.item.relatedAlbum }.filter {
            seen.insert($0.sharedArtworkIdentity).inserted
        }.shuffled().prefix(3)
        var palettes: [Color] = []
        for album in albums {
            guard !Task.isCancelled, showingCovers, coverOpeningID == opening,
                library.catalogScopeID == scope
            else { return }
            do {
                if let result = try await library.artworkResult(
                    for: album, size: 160, allowsNetwork: !connectivity.localOnly)
                {
                    palettes.append(result.tint)
                }
            } catch is CancellationError { return } catch {}
        }
        guard !Task.isCancelled, showingCovers, coverOpeningID == opening,
            library.catalogScopeID == scope
        else { return }
        if palettes.isEmpty { palettes = [cachedArtwork?.tint ?? .teal] }
        covers = FoundationPlaylistCoverPreset.choices(palettes: palettes).map { preset in
            // Preserve the exact palette already selected while late artwork resolves.
            if let frozen = selectedCover ?? savedCover, frozen.id == preset.id { return frozen }
            return preset
        }
    }

    private func saveDetails() {
        guard canEditDetails, !operation.isPending, dirty else { return }
        saveSummary = ""
        operation.run(
            successMessage: { "Playlist saved." },
            {
                guard !connectivity.localOnly else { throw CancellationError() }
                if name != savedName || overview != savedOverview || isPublic != savedPublic {
                    // Nil preserves the fresh server value. Never send an unchanged
                    // draft field back over another client's newer metadata or visibility.
                    let requestedName: String?
                    if name != savedName {
                        requestedName = try FoundationPlaylistName.validated(name)
                    } else {
                        requestedName = nil
                    }
                    let requestedOverview = overview != savedOverview ? overview : nil
                    let requestedPublic = isPublic != savedPublic ? isPublic : nil
                    let details = try await library.updatePlaylistDetails(
                        id: playlist.id, name: requestedName, overview: requestedOverview,
                        isPublic: requestedPublic)
                    try Task.checkCancellation()
                    savedName = details.item.title
                    savedOverview = details.overview
                    savedPublic = details.isPublic
                    name = savedName
                    overview = savedOverview
                    isPublic = savedPublic
                    permissions = details.permissions
                    canEditOverview = details.canEditOverview
                    canEditCover = details.canEditCover
                    onRenamed(savedName)
                    updatedPlaylist = details.item
                    onUpdated(details.item)
                    changes.catalogDidChange()
                    saveSummary = "Playlist details saved."
                }
                if let selectedCover {
                    guard canEditCover else { throw FoundationPlaylistError.readOnly }
                    saveSummary =
                        saveSummary.isEmpty
                        ? "Artwork is still pending." : "Details saved; artwork is still pending."
                    let data = try FoundationPlaylistCoverArtwork.png(
                        selectedCover, playlistTitle: name)
                    let updated = try await library.setPlaylistCover(
                        id: playlist.id, data: data, contentType: "image/png")
                    try Task.checkCancellation()
                    updatedPlaylist = updated
                    onUpdated(updated)
                    savedCover = selectedCover
                    self.selectedCover = nil
                    changes.catalogDidChange()
                }
                saveSummary = "Playlist saved."
                downloads.reconcilePlaylists()
            })
    }
    private func remove(_ selected: [FoundationPlaylistEntry]) {
        guard editable, !operation.isPending, !selected.isEmpty else { return }
        requiresRefresh = true
        operation.run {
            defer { downloads.reconcilePlaylists() }
            try await changes.remove(playlistID: playlist.id, entries: selected, library: library)
            try Task.checkCancellation()
            selection.subtract(selected.map(\.mutationID))
            try await refresh()
        }
    }
    private func reorder(
        _ difference: ReorderDifference<String, ReorderableSingleCollectionIdentifier>
    ) {
        guard canMove else { return }
        let all = FoundationPlaylistReorderRow.make(entries)
        let ids = Set(difference.sources)
        let source = IndexSet(all.filter { ids.contains($0.id) }.map(\.index))
        guard source.count == ids.count else { return }
        switch difference.destination.position {
        case .before(let id):
            guard let destination = all.first(where: { $0.id == id })?.index else { return }
            move(from: source, to: destination)
        case .end: move(from: source, to: entries.count)
        }
    }
    private func move(_ row: FoundationPlaylistReorderRow, upwards: Bool) {
        move(from: IndexSet(integer: row.index), to: upwards ? row.index - 1 : row.index + 2)
    }
    private func move(from source: IndexSet, to destination: Int) {
        guard canMove,
            let plan = try? FoundationPlaylistReorderPlan(
                entries: entries, from: source, to: destination), !plan.moves.isEmpty
        else { return }
        let before = entries
        entries = plan.entries
        requiresRefresh = true
        operation.run {
            defer { downloads.reconcilePlaylists() }
            entries = try await changes.reorder(
                playlistID: playlist.id, entries: before, from: source, to: destination,
                library: library)
            try Task.checkCancellation()
            guard !connectivity.localOnly else { throw CancellationError() }
            requiresRefresh = false
        }
    }
    private func addSongs() {
        guard editable, !operation.isPending, !addedSelection.isEmpty else { return }
        let selected = addedSelection
        requiresRefresh = true
        operation.run(
            successMessage: { addSummary },
            {
                defer { downloads.reconcilePlaylists() }
                let result = try await changes.add(
                    playlistID: playlist.id, tracks: selected, library: library)
                addSummary = result.message
                try Task.checkCancellation()
                addedSelection = []
                try await refresh()
            })
    }
    private func refresh() async throws {
        guard !connectivity.localOnly else { throw CancellationError() }
        let details = try await library.playlistDetails(id: playlist.id)
        try Task.checkCancellation()
        let snapshot = try await FoundationPlaylistSnapshot.load(id: playlist.id, library: library)
        try Task.checkCancellation()
        guard !connectivity.localOnly else { throw CancellationError() }
        if !loaded || name == savedName { name = details.item.title }
        if !loaded || overview == savedOverview { overview = details.overview }
        if !loaded || isPublic == savedPublic { isPublic = details.isPublic }
        savedName = details.item.title
        savedOverview = details.overview
        savedPublic = details.isPublic
        permissions = details.permissions
        updatedPlaylist = details.item
        canEditOverview = details.canEditOverview
        canEditCover = details.canEditCover
        changes.observe(snapshot.map(\.item))
        entries = snapshot
        loaded = true
        requiresRefresh = false
    }
}

private struct FoundationPlaylistCoverPreset: Identifiable, Sendable {
    let id: String
    let title: String
    let asset: String
    let color: Color
    let showsTitle: Bool

    static func choices(palettes: [Color]) -> [Self] {
        let colors = palettes.isEmpty ? [Color.teal] : palettes
        return ["Flow", "Resonance"].flatMap { form in
            (0..<3).map { treatment in
                Self(
                    id: "\(form)-\(treatment)",
                    title: "\(form) \(treatment == 1 ? "Artwork" : "Title") \(treatment + 1)",
                    asset: "PlaylistCover\(form)",
                    color: treatment == 2
                        ? colors[treatment % colors.count].mix(with: .black, by: 0.25)
                        : colors[treatment % colors.count],
                    showsTitle: treatment != 1)
            }
        }
    }
}

private struct FoundationPlaylistCoverArtwork: View {
    let preset: FoundationPlaylistCoverPreset
    let playlistTitle: String

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                Image(preset.asset).resizable().scaledToFill()
                    .colorMultiply(preset.color.mix(with: .white, by: 0.25))
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                if preset.showsTitle {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.8)],
                        startPoint: .center, endPoint: .bottom)
                    Text(playlistTitle.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(
                            .system(
                                size: geometry.size.width * 0.1, weight: .bold, design: .rounded)
                        )
                        .foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.5)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .padding(geometry.size.width * 0.08)
                }
            }
        }.aspectRatio(1, contentMode: .fit)
    }

    @MainActor static func png(_ preset: FoundationPlaylistCoverPreset, playlistTitle: String)
        throws -> Data
    {
        let renderer = ImageRenderer(
            content: Self(preset: preset, playlistTitle: playlistTitle).frame(
                width: 512, height: 512))
        guard let image = renderer.cgImage else { throw FoundationPlaylistError.changed }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { throw FoundationPlaylistError.changed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FoundationPlaylistError.changed }
        return data as Data
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
            #if os(macOS)
                if showingSongs, let createdPlaylist {
                    FoundationPlaylistEditor(
                        playlist: createdPlaylist, library: library, startsAddingSongs: true)
                } else {
                    composer
                }
            #else
                composer
                    .fullScreenCover(isPresented: $showingSongs, onDismiss: { dismiss() }) {
                        if let createdPlaylist {
                            FoundationPlaylistEditor(
                                playlist: createdPlaylist, library: library, startsAddingSongs: true
                            )
                        }
                    }
            #endif
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
                        Toggle("Open Playlist Manager Next", isOn: $addSongsNext)
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

/// The persistent search field owns focus in its presented sheet, outside lazy result content.
private struct FoundationPlaylistAddSearchHeader: View {
    @Binding var query: String
    let browsingCollection: Bool
    let isEnabled: Bool
    let closeDisabled: Bool
    let close: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search songs, albums and artists", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .disabled(!isEnabled)
                .accessibilityLabel("Search songs, albums and artists")
                .accessibilityIdentifier("playlist-manager-add-search")
            #if os(macOS)
                Button("Close", systemImage: "xmark", action: close).disabled(closeDisabled)
            #endif
        }
        .defaultFocus($searchFocused, true)
        .onChange(of: browsingCollection) { _, browsing in searchFocused = !browsing }
    }
}

#if os(macOS)
    /// A user-opened editor must own keyboard input, even when the app was opened in the background.
    private struct FoundationPlaylistSheetActivation: NSViewRepresentable {
        func makeNSView(context: Context) -> FoundationPlaylistSheetActivationView {
            FoundationPlaylistSheetActivationView()
        }

        func updateNSView(_ view: FoundationPlaylistSheetActivationView, context: Context) {}
    }

    private final class FoundationPlaylistSheetActivationView: NSView {
        private weak var activatedWindow: NSWindow?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, activatedWindow !== window else { return }
            // Wait for native sheet attachment, not a timer or a render-driven focus request.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window,
                    self.activatedWindow !== window,
                    let parent = window.sheetParent, parent.attachedSheet === window
                else { return }
                self.activatedWindow = window
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                // Preserve the text field or other responder selected by the user/SwiftUI.
            }
        }
    }
#endif
