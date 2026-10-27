import Combine
import SwiftUI

/// Only Songs/See All Songs adopt this owner. Native Jellyfin indexes stay mounted
/// with their query/alphabet state, but their loader is inactive behind All/Local.
struct FoundationComposedSongsView<NativeIndex: View>: View {
    @Environment(\.foundationLocalLibrary) private var localLibrary
    @EnvironmentObject private var actions: FoundationLibraryActions
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let query: FoundationCatalogQuery
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    let openLocalLibrary: () -> Void
    let isCurrent: @MainActor (FoundationComposedCatalogModel.Context) -> Bool
    @ViewBuilder let nativeIndex: (Bool, Bool) -> NativeIndex
    @State private var model: FoundationComposedCatalogModel?
    @State private var ownerID = UUID()
    @State private var failed = false
    // User choice belongs to this mounted query owner; folder/route updates do not reseed it.
    @State private var sourceFilter: FoundationComposedCatalogModel.Filter

    init(
        query: FoundationCatalogQuery, library: any FoundationLibrary, player: FoundationPlayer,
        isActive: Bool, initialFilter: FoundationComposedCatalogModel.Filter,
        openLocalLibrary: @escaping () -> Void,
        isCurrent: @escaping @MainActor (FoundationComposedCatalogModel.Context) -> Bool,
        @ViewBuilder nativeIndex: @escaping (Bool, Bool) -> NativeIndex
    ) {
        self.query = query
        self.library = library
        self.player = player
        self.isActive = isActive
        self.openLocalLibrary = openLocalLibrary
        self.isCurrent = isCurrent
        self.nativeIndex = nativeIndex
        _sourceFilter = State(initialValue: initialFilter)
    }

    private struct Activation: Equatable {
        let query: FoundationCatalogQuery
        let account: String?
        let scope: String
        let localOnly: Bool
        let localOwner: ObjectIdentifier?
    }

    var body: some View {
        let key = Activation(
            query: query, account: (library as? FoundationJellyfinLibrary)?.catalogAccountIdentity,
            scope: library.catalogScopeID, localOnly: connectivity.localOnly,
            localOwner: localLibrary.map(ObjectIdentifier.init))
        Group {
            if let model {
                FoundationComposedCatalogView(
                    model: model, library: library, player: player, isActive: isActive,
                    openLocalLibrary: openLocalLibrary, selectionChanged: { sourceFilter = $0 },
                    nativeIndex: nativeIndex)
            } else if localLibrary == nil || !(library is FoundationJellyfinLibrary) {
                // Unsupported adapter/fixture environments retain their functioning index.
                nativeIndex(isActive, true)
            } else if failed {
                ContentUnavailableView("Songs Unavailable", systemImage: "music.note")
            } else {
                ProgressView("Opening songs…")
            }
        }
        .task(id: key) {
            guard !Task.isCancelled else { return }
            model?.invalidate()
            model = nil
            failed = false
            guard let localLibrary, let jellyfin = library as? FoundationJellyfinLibrary else {
                return
            }
            let capturedLocalOnly = key.localOnly
            let actions = actions
            let connectivity = connectivity
            let downloads = downloads
            let currentQuery = query
            do {
                let next = try FoundationComposedCatalogModel(
                    ownerID: ownerID, query: query,
                    jellyfin: jellyfin, localLibrary: localLibrary,
                    actions: actions,
                    allowsNetwork: { !connectivity.localOnly },
                    offlineJellyfinItems: {
                        switch currentQuery {
                        case .songs: downloads.downloadedSongs
                        case .search(let text, let kind):
                            downloads.localSearchItems(query: text, kind: kind)
                        }
                    },
                    isCurrent: { context in
                        guard let account = context.account, actions.acceptsCatalogAccount(account)
                        else { return false }
                        return connectivity.localOnly == capturedLocalOnly && isCurrent(context)
                    })
                // A choice is seeded once per query/account owner, never by folder refresh.
                next.setFilter(sourceFilter, activate: false)
                guard !Task.isCancelled else {
                    next.invalidate()
                    return
                }
                model = next
            } catch {
                failed = true
            }
        }
        .onDisappear { model?.invalidate() }
    }
}

/// One source picker and one visible scroll surface. Jellyfin-only delegates the
/// complete native index; All/Local use bounded source sections and native rows.
struct FoundationComposedCatalogView<NativeIndex: View>: View {
    let model: FoundationComposedCatalogModel
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    let openLocalLibrary: () -> Void
    let selectionChanged: (FoundationComposedCatalogModel.Filter) -> Void
    @ViewBuilder let nativeIndex: (Bool, Bool) -> NativeIndex
    @EnvironmentObject private var actions: FoundationLibraryActions
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @State private var lifetime = FoundationComposedCatalogLifetime()
    @State private var openedItem: FoundationItem?
    @State private var collectionOwner = UUID()

    private struct Activation: Equatable {
        let owner: ObjectIdentifier
        let context: FoundationComposedCatalogModel.Context
        let isActive: Bool
    }

    var body: some View {
        let composedIsActive = isActive && model.filter != .jellyfin
        VStack(spacing: 0) {
            Picker(
                "Sources",
                selection: Binding(
                    get: { model.filter },
                    set: {
                        model.setFilter($0, activate: isActive && $0 != .jellyfin)
                        selectionChanged($0)
                    })
            ) {
                ForEach(FoundationComposedCatalogModel.Filter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented).accessibilityLabel("Catalog sources")
            .padding(.horizontal).padding(.vertical, 8)
            ZStack {
                nativeIndex(isActive && model.filter == .jellyfin, model.filter == .jellyfin)
                if model.filter != .jellyfin { composedList }
            }
        }
        .task(
            id: Activation(
                owner: ObjectIdentifier(model), context: model.context,
                isActive: composedIsActive)
        ) {
            guard !Task.isCancelled else { return }
            lifetime.update(model, isActive: composedIsActive)
        }
        .onChange(of: model.localPresentationRevision, initial: true) { _, _ in
            model.synchronizeLocalRevision()
        }
        .onReceive(downloads.$verifiedReadyRevision.removeDuplicates()) { _ in
            model.refreshOfflineJellyfin()
        }
        .onDisappear {
            lifetime.end()
            actions.cancelQueueAdditionOwned(by: collectionOwner)
        }
        .onChange(of: model.filter) { _, _ in
            openedItem = nil
            actions.cancelQueueAdditionOwned(by: collectionOwner)
        }
        .foundationCollectionDestination(
            item: $openedItem, library: library, player: player,
            isActive: composedIsActive
        )
        .environment(\.foundationCollectionOperationOwner, collectionOwner)
        .foundationCollectionOutcomePresentation(owner: collectionOwner)
        .alert(
            "Details Unavailable",
            isPresented: Binding(
                get: { model.detailUnavailable },
                set: { if !$0 { model.dismissDetailFailure() } })
        ) {
            Button("OK") { model.dismissDetailFailure() }
        } message: {
            Text("These details could not be opened. Other catalog results remain available.")
        }
        .sheet(item: Binding(get: { model.detail }, set: { if $0 == nil { model.closeDetail() } }))
        {
            FoundationComposedCatalogDetail(detail: $0, close: model.closeDetail)
        }
    }

    private var composedList: some View {
        List {
            if model.filter != .jellyfin {
                Section("Local Files") {
                    if model.localIsUpdating { ProgressView("Updating local library…") }
                    if model.localNeedsRecovery {
                        Text("Saved folder access is unavailable.").foregroundStyle(.secondary)
                    } else if !model.hasSelectedLocalFolder {
                        Text("No folder selected.").foregroundStyle(.secondary)
                    }
                    Button(
                        model.hasSelectedLocalFolder ? "Manage Local Library" : "Choose Folder",
                        systemImage: "folder"
                    ) {
                        model.closeDetail()
                        model.dismissDetailFailure()
                        openLocalLibrary()
                    }
                    .accessibilityIdentifier("composed-manage-local-library")
                }
            }
            if model.filter != .local, !model.hasJellyfinSource {
                Section("Jellyfin") {
                    Text("Sign in to browse Jellyfin music.").foregroundStyle(.secondary)
                }
            }
            ForEach(model.sections) { section in
                Section(section.title) {
                    if section.id.kind == .jellyfin {
                        ForEach(visibleJellyfinItems, id: \.id) { item in
                            if let key = try? item.catalogKey(),
                                let intent = model.jellyfinIntent(for: key)
                            {
                                remoteRow(item, intent: intent)
                            }
                        }
                    } else {
                        ForEach(section.rows) { row in localRow(row) }
                    }
                    sourceStatus(section)
                    if section.failed {
                        Button("Retry \(section.title)") { model.retry(section.id.kind) }
                    } else if section.hasMore, section.state != .loading {
                        Button("Load More") { model.loadNext(section.id.kind) }
                            .accessibilityLabel("Load more \(section.title) results")
                    }
                }
            }
        }
        .foundationBottomChromeListClearance()
        .foundationCatalogHeader(title)
        .refreshable { await model.refresh() }
    }

    private var visibleJellyfinItems: [FoundationItem] {
        actions.visibleTracks(
            model.jellyfinItems,
            isAvailable: {
                !connectivity.localOnly || downloads.isReady($0)
            })
    }

    private func remoteRow(
        _ item: FoundationItem, intent: FoundationComposedCatalogModel.JellyfinIntent
    ) -> some View {
        let model = model
        let actions = actions
        let canPerform: @MainActor @Sendable (FoundationCatalogCapabilities) -> Bool = {
            capability in
            model.canPerform(intent, requiring: capability)
                && actions.acceptsCatalogAccount(intent.key.source.identity)
        }
        return FoundationLibraryItemRow(
            item: item, library: library, isActive: isActive,
            open: { if canPerform(.catalogPresence) { openedItem = item } },
            play: {
                model.withCurrentJellyfinItem(intent, requiring: .playback) { selected in
                    guard canPerform(.playback) else { return }
                    let items = visibleJellyfinItems
                    guard let index = items.firstIndex(where: { $0.id == selected.id }),
                        let selection = FoundationTrackQueueSelection(
                            in: items, selecting: index,
                            isAvailable: { !connectivity.localOnly || downloads.isReady($0) })
                    else { return }
                    player.setQueue(selection.items, selectedIndex: selection.index)
                }
            }, player: player, showsTrackArtwork: true,
            navigate: { if canPerform(.catalogPresence) { openedItem = $0 } },
            canPerform: canPerform
        )
        .foundationLibraryListRow()
    }

    private func localRow(_ row: FoundationComposedCatalogModel.Row) -> some View {
        Button {
            model.open(row.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "music.note").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title).foregroundStyle(.primary).lineLimit(2)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text("Read-only local file").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityElement(children: .combine)
        .foundationLibraryListRow()
    }

    private var title: String {
        switch model.context.query {
        case .songs, .search(_, .track): "Songs"
        case .search: "Search Results"
        }
    }

    @ViewBuilder private func sourceStatus(_ section: FoundationComposedCatalogModel.SourceSection)
        -> some View
    {
        if section.limitReached {
            Text(
                "Showing the first \(FoundationCatalogComposition.itemLimit) items from this source. Narrow your search to find more."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        switch section.state {
        case .loading: ProgressView("Loading \(section.title)…")
        case .empty: Text("No matching items.").foregroundStyle(.secondary)
        case .partial:
            Text("Some results may be missing or out of date.").foregroundStyle(.secondary)
        case .unavailable:
            Text("Source unavailable. Saved metadata may be out of date.").foregroundStyle(
                .secondary)
        case .failed:
            Text("This source could not be loaded. Other results remain available.")
                .foregroundStyle(.secondary)
        case .idle, .ready: EmptyView()
        }
    }
}

private struct FoundationComposedCatalogDetail: View {
    let detail: FoundationComposedCatalogModel.Detail
    let close: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(detail.title).font(.headline)
                    if !detail.subtitle.isEmpty {
                        Text(detail.subtitle).foregroundStyle(.secondary)
                    }
                }
                Section("Source") {
                    Text(detail.source)
                    Text(detail.availability).foregroundStyle(.secondary)
                }
                if let bytes = detail.byteCount {
                    Section("At Last Index Refresh") {
                        LabeledContent("File Size") {
                            Text(bytes, format: .byteCount(style: .file))
                        }
                        if let modified = detail.modified {
                            LabeledContent("File Modified") {
                                Text(
                                    modified, format: .dateTime.year().month().day().hour().minute()
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Details")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
            }
        }
        #if os(macOS)
            .frame(minWidth: 400, idealWidth: 480, minHeight: 320)
        #endif
    }
}
