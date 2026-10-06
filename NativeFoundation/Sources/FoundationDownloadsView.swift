import SwiftUI

/// A read-only presentation adapter: artwork is supplied by the shared retained-artwork view.
/// It cannot request remote catalog data, metadata, or audio when Downloads is browsed online.
private struct FoundationDownloadedCatalogLibrary: FoundationLibrary {
    func albums(startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func tracks(albumID: String, startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func playbackURL(for item: FoundationItem) async throws -> URL {
        throw FoundationLibraryError.unavailable
    }
}

/// Browsing downloads never expands a collection or requests a remote catalog page.
struct FoundationDownloadsView: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let player: FoundationPlayer

    var body: some View {
        List {
            if downloads.isLoading {
                Section { ProgressView("Verifying downloaded files…") }
            }
            Section {
                NavigationLink {
                    FoundationDownloadedSongsView(player: player)
                } label: {
                    Label("Songs", systemImage: "music.note")
                }
                NavigationLink {
                    FoundationDownloadedCollectionsView(kind: .album, player: player)
                } label: {
                    Label("Albums", systemImage: "opticaldisc")
                }
                NavigationLink {
                    FoundationDownloadedCollectionsView(kind: .playlist, player: player)
                } label: {
                    Label("Playlists", systemImage: "music.note.list")
                }
            }
            if downloads.owners.isEmpty && downloads.downloadedSongs.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Downloads", systemImage: "arrow.down.circle",
                        description: Text(
                            "Choose Download from a song, album, or playlist’s Actions menu when online."
                        ))
                }
            }
            if !downloads.owners.isEmpty {
                Section("Downloads") {
                    ForEach(downloads.owners) { owner in
                        FoundationDownloadTransferRow(owner: owner, player: player)
                    }
                }
            }
            if let error = downloads.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .foundationCatalogHeader("Downloads")
        .environment(\.foundationDownloadedBrowsing, true)
    }
}

private struct FoundationDownloadTransferRow: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let owner: FoundationDownloadOwner
    let player: FoundationPlayer
    @State private var openedItem: FoundationItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FoundationLibraryItemRow(
                item: owner.item, library: FoundationDownloadedCatalogLibrary(), isActive: true,
                open: { openedItem = owner.item }, player: player, showsTrackArtwork: true,
                navigate: { openedItem = $0 },
                subtitleOverride: owner.state == .ready ? nil : owner.status)
            switch owner.state {
            case .queued, .expanding, .waitingForWiFi, .downloading:
                ProgressView(value: min(1, max(0, owner.progress))) { Text("Download progress") }
                Button("Cancel") { downloads.cancel(ownerID: owner.id) }.buttonStyle(.borderless)
            case .cancelled, .failed:
                Button("Retry Download") { downloads.retry(ownerID: owner.id) }
                    .buttonStyle(.borderless).disabled(connectivity.localOnly)
            case .ready:
                EmptyView()
            }
        }.padding(.vertical, 4)
            .navigationDestination(isPresented: destinationPresented) {
                if let openedItem {
                    FoundationDownloadedCollectionView(item: openedItem, player: player)
                }
            }
    }

    private var destinationPresented: Binding<Bool> {
        Binding(get: { openedItem != nil }, set: { if !$0 { openedItem = nil } })
    }
}

private struct FoundationDownloadedSongsView: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    let player: FoundationPlayer
    @State private var openedItem: FoundationItem?

    var body: some View {
        List {
            if downloads.downloadedSongs.isEmpty {
                ContentUnavailableView("No Downloaded Songs", systemImage: "music.note")
            } else {
                Button("Play All", systemImage: "play.fill") {
                    player.setQueue(downloads.downloadedSongs, selectedIndex: 0)
                }
                ForEach(Array(downloads.downloadedSongs.enumerated()), id: \.element.id) {
                    index, item in
                    FoundationLibraryItemRow(
                        item: item, library: FoundationDownloadedCatalogLibrary(), isActive: true,
                        open: {},
                        play: { player.setQueue(downloads.downloadedSongs, selectedIndex: index) },
                        player: player, showsTrackArtwork: true, navigate: { openedItem = $0 })
                }
            }
        }
        .listStyle(.plain)
        .foundationCatalogHeader("Songs")
        .environment(\.foundationDownloadedBrowsing, true)
        .navigationDestination(
            isPresented: Binding(
                get: { openedItem != nil }, set: { if !$0 { openedItem = nil } })
        ) {
            if let openedItem {
                FoundationDownloadedCollectionView(item: openedItem, player: player)
            }
        }
    }
}

private struct FoundationDownloadedCollectionsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var downloads: FoundationDownloads
    let kind: FoundationItem.Kind
    let player: FoundationPlayer
    @State private var openedItem: FoundationItem?
    private var items: [FoundationItem] {
        kind == .album ? downloads.downloadedAlbums : downloads.downloadedPlaylists
    }

    var body: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView(
                    kind == .album ? "No Downloaded Albums" : "No Downloaded Playlists",
                    systemImage: kind == .album ? "opticaldisc" : "music.note.list")
            } else {
                LazyVGrid(
                    columns: foundationCollectionColumns(for: dynamicTypeSize),
                    alignment: .leading, spacing: 22
                ) {
                    ForEach(items, id: \.id) { item in
                        FoundationCollectionCard(
                            item: item, library: FoundationDownloadedCatalogLibrary(),
                            player: player,
                            isActive: true, open: { openedItem = item },
                            navigate: { openedItem = $0 })
                    }
                }.padding()
            }
        }
        .foundationCatalogHeader(kind == .album ? "Albums" : "Playlists")
        .environment(\.foundationDownloadedBrowsing, true)
        .navigationDestination(
            isPresented: Binding(
                get: { openedItem != nil }, set: { if !$0 { openedItem = nil } })
        ) {
            if let openedItem {
                FoundationDownloadedCollectionView(item: openedItem, player: player)
            }
        }
    }
}

struct FoundationDownloadedCollectionView: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let item: FoundationItem
    let player: FoundationPlayer
    @State private var detailTint = Color(white: 0.12)
    @State private var openedItem: FoundationItem?
    private var owner: FoundationDownloadOwner? {
        downloads.owners.first { $0.item.id == item.id && $0.item.kind == item.kind }
    }
    private var tracks: [FoundationItem] {
        if let owner { return owner.tracks }
        if item.kind == .track { return [item] }
        // A derived album is only the known local subset; include unavailable saved occurrences.
        var seen: Set<String> = []
        return downloads.owners.flatMap(\.tracks).filter {
            $0.album?.id == item.id && seen.insert($0.id).inserted
        }
    }

    var body: some View {
        List {
            FoundationDetailHero(
                item: item, library: FoundationDownloadedCatalogLibrary(), isActive: true,
                tint: $detailTint
            ) {
                FoundationDetailActions(
                    item: item, library: FoundationDownloadedCatalogLibrary(), player: player)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            Section {
                if let owner, owner.state != .ready {
                    Text(owner.status).foregroundStyle(.secondary)
                    transferControls(owner)
                }
                if downloads.availability(for: item) != .ready {
                    Button("Download Again", systemImage: "arrow.down.circle") {
                        downloads.downloadAgain(item)
                    }.disabled(connectivity.localOnly)
                }
                Text("Showing the saved collection on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }.listRowBackground(Color.clear)
            Section("Tracks") {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    FoundationLibraryItemRow(
                        item: track, library: FoundationDownloadedCatalogLibrary(), isActive: true,
                        open: {}, play: { play(index) }, player: player, showsTrackArtwork: true,
                        navigate: { openedItem = $0 }, currentPageKind: item.kind,
                        isPlayable: downloads.isReady(track),
                        availabilityMessage: downloads.isReady(track)
                            ? nil : "Not available offline"
                    )
                    .listRowBackground(Color.clear)
                }
                if tracks.isEmpty { Text("No saved tracks available.").foregroundStyle(.secondary) }
            }
        }
        .listStyle(.plain)
        .foundationDetailPresentation(title: item.title, immersive: true, tint: detailTint)
        .modifier(FoundationDetailTitle(item: item))
        .environment(\.foundationDownloadedBrowsing, true)
        .navigationDestination(
            isPresented: Binding(
                get: { openedItem != nil }, set: { if !$0 { openedItem = nil } })
        ) {
            if let openedItem {
                FoundationDownloadedCollectionView(item: openedItem, player: player)
            }
        }
    }

    @ViewBuilder private func transferControls(_ owner: FoundationDownloadOwner) -> some View {
        switch owner.state {
        case .queued, .expanding, .waitingForWiFi, .downloading:
            ProgressView(value: min(1, max(0, owner.progress))) { Text("Download progress") }
            Button("Cancel") { downloads.cancel(ownerID: owner.id) }.buttonStyle(.borderless)
        case .cancelled, .failed:
            Button("Retry Download") { downloads.retry(ownerID: owner.id) }
                .buttonStyle(.borderless).disabled(connectivity.localOnly)
        case .ready:
            EmptyView()
        }
    }

    private func play(_ index: Int) {
        let snapshot = tracks
        guard snapshot.indices.contains(index), downloads.isReady(snapshot[index]) else { return }
        let ready = snapshot.filter { downloads.isReady($0) }
        let selected = snapshot.prefix(index).filter { downloads.isReady($0) }.count
        guard ready.indices.contains(selected) else { return }
        player.setQueue(ready, selectedIndex: selected)
    }
}
