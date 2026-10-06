import SwiftUI

/// Browsing downloads never expands a collection or requests a remote catalog page.
struct FoundationDownloadsView: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let player: FoundationPlayer

    var body: some View {
        List {
            if connectivity.localOnly {
                Section {
                    Label("Downloaded Music", systemImage: "wifi.slash").font(.headline)
                    Text(
                        connectivity.statusMessage
                            ?? "Online browsing is unavailable. Showing downloaded music."
                    )
                    .foregroundStyle(.secondary)
                    Button("Retry Online", systemImage: "arrow.clockwise") {
                        Task { await connectivity.retryOnline() }
                    }.disabled(connectivity.isRetrying)
                }
            }
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
        .navigationTitle("Downloads")
        #if os(iOS)
            .toolbar(.visible, for: .navigationBar)
        #endif
    }
}

private struct FoundationDownloadTransferRow: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let owner: FoundationDownloadOwner
    let player: FoundationPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                FoundationDownloadedCollectionView(item: owner.item, player: player)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(owner.item.title).font(.headline)
                    Text(owner.state == .ready ? "Saved download" : owner.status).font(.subheadline)
                        .foregroundStyle(.secondary)
                    if downloads.availability(for: owner.item) != .unavailable
                        || owner.state == .ready
                    {
                        FoundationDownloadBadge(item: owner.item, showsTransferStatus: false)
                    }
                    if downloads.readyTracks(ownerID: owner.id).isEmpty {
                        Text("No tracks available offline yet").font(.caption).foregroundStyle(
                            .secondary)
                    }
                }
            }
            switch owner.state {
            case .queued, .expanding, .waitingForWiFi, .downloading:
                ProgressView(value: min(1, max(0, owner.progress))) {
                    Text("Download progress")
                }
                Button("Cancel") { downloads.cancel(ownerID: owner.id) }
                    .buttonStyle(.borderless)
            case .cancelled, .failed:
                Button("Retry Download") { downloads.retry(ownerID: owner.id) }
                    .buttonStyle(.borderless).disabled(connectivity.localOnly)
            case .ready:
                EmptyView()
            }
        }.padding(.vertical, 4)
    }
}

private struct FoundationDownloadedSongsView: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    let player: FoundationPlayer

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
                    Button {
                        player.setQueue(downloads.downloadedSongs, selectedIndex: index)
                    } label: {
                        FoundationDownloadedTrackLabel(item: item, available: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }.navigationTitle("Songs")
    }
}

private struct FoundationDownloadedCollectionsView: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    let kind: FoundationItem.Kind
    let player: FoundationPlayer
    private var items: [FoundationItem] {
        kind == .album ? downloads.downloadedAlbums : downloads.downloadedPlaylists
    }

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView(
                    kind == .album ? "No Downloaded Albums" : "No Downloaded Playlists",
                    systemImage: kind == .album ? "opticaldisc" : "music.note.list")
            }
            ForEach(items, id: \.id) { item in
                NavigationLink {
                    FoundationDownloadedCollectionView(item: item, player: player)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline)
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                        FoundationDownloadBadge(item: item)
                    }
                }
            }
        }.navigationTitle(kind == .album ? "Albums" : "Playlists")
    }
}

struct FoundationDownloadedCollectionView: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let item: FoundationItem
    let player: FoundationPlayer
    private var owner: FoundationDownloadOwner? {
        downloads.owners.first { $0.item.id == item.id && $0.item.kind == item.kind }
    }
    private var tracks: [FoundationItem] { owner?.tracks ?? downloads.browseTracks(for: item) }

    var body: some View {
        List {
            Section {
                FoundationDownloadBadge(item: item, showsTransferStatus: false)
                if let owner {
                    Text(owner.state == .ready ? "Saved download" : owner.status).foregroundStyle(
                        .secondary)
                }
                Button("Play Available Tracks", systemImage: "play.fill") {
                    let ready = downloads.browseTracks(for: item)
                    guard !ready.isEmpty else { return }
                    player.setQueue(ready, selectedIndex: 0)
                }.disabled(downloads.browseTracks(for: item).isEmpty)
                if downloads.availability(for: item) != .ready {
                    Button("Download Again", systemImage: "arrow.down.circle") {
                        downloads.downloadAgain(item)
                    }.disabled(connectivity.localOnly)
                }
                Text(
                    "Only downloaded tracks play here. Collection order is the last saved snapshot; online changes may not be included."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tracks") {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    Button {
                        let ready = tracks.filter { downloads.isReady($0) }
                        let selected = tracks.prefix(index).filter { downloads.isReady($0) }.count
                        guard downloads.isReady(track), ready.indices.contains(selected) else {
                            return
                        }
                        player.setQueue(ready, selectedIndex: selected)
                    } label: {
                        FoundationDownloadedTrackLabel(
                            item: track, available: downloads.isReady(track))
                    }.buttonStyle(.plain).disabled(!downloads.isReady(track))
                }
                if tracks.isEmpty { Text("No saved tracks available.").foregroundStyle(.secondary) }
            }
        }.navigationTitle(item.title)
    }
}

private struct FoundationDownloadedTrackLabel: View {
    let item: FoundationItem
    let available: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.body)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            if available {
                FoundationDownloadBadge(item: item)
            } else {
                Label("Not available offline", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}
