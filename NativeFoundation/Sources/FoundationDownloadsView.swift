import SwiftUI

/// Downloads selects existing catalog identities; every result uses the normal destination.
struct FoundationDownloadsView: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    let library: any FoundationLibrary
    let player: FoundationPlayer
    var isActive = true

    var body: some View {
        List {
            if downloads.isLoading { ProgressView("Verifying downloaded files…") }
            ForEach([FoundationItem.Kind.track, .album, .playlist], id: \.self) { kind in
                NavigationLink {
                    FoundationDownloadFilteredCatalog(
                        kind: kind, library: library, player: player, isActive: isActive)
                } label: {
                    Label(title(kind), systemImage: symbol(kind))
                }
            }
            if downloads.owners.isEmpty && downloads.downloadedSongs.isEmpty {
                ContentUnavailableView(
                    "No Downloads", systemImage: "arrow.down.circle",
                    description: Text("Download music from its Actions menu when online."))
            }
            if let error = downloads.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .foundationCatalogHeader("Downloads")
    }

    private func title(_ kind: FoundationItem.Kind) -> String {
        switch kind {
        case .track: "Songs"
        case .album: "Albums"
        default: "Playlists"
        }
    }
    private func symbol(_ kind: FoundationItem.Kind) -> String {
        switch kind {
        case .track: "music.note"
        case .album: "opticaldisc"
        default: "music.note.list"
        }
    }
}

/// Only the query is local. Rows, menus, player policy and destinations remain canonical.
private struct FoundationDownloadFilteredCatalog: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    let kind: FoundationItem.Kind
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    @StateObject private var results = FoundationBrowseModel()

    private var items: [FoundationItem] {
        switch kind {
        case .track: downloads.downloadedSongs
        case .album:
            downloads.downloadedAlbums
                + downloads.owners.filter {
                    owner in
                    owner.item.kind == .album
                        && !downloads.downloadedAlbums.contains(where: { $0.id == owner.item.id })
                }.map(\.item)
        case .playlist: downloads.owners.filter { $0.item.kind == .playlist }.map(\.item)
        default: []
        }
    }
    private var title: String {
        switch kind {
        case .track: "Songs"
        case .album: "Albums"
        default: "Playlists"
        }
    }

    var body: some View {
        Group {
            if kind == .track {
                FoundationTrackList(
                    title: title, tracks: results, player: player, library: library,
                    isActive: isActive
                ) { _ in .init(items: items, nextStartIndex: nil) }
            } else {
                FoundationCatalogView(
                    title: title, model: results, library: library, player: player,
                    isActive: isActive
                ) { _ in .init(items: items, nextStartIndex: nil) }
            }
        }
        .onAppear { results.installSnapshot(items) }
        .onReceive(downloads.objectWillChange) {
            Task { @MainActor in results.installSnapshot(items) }
        }
    }
}

/// A status strip occupies layout space above browsing, never covers native navigation.
struct FoundationOfflineStatus: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash").accessibilityHidden(true)
            Text("Browsing offline")
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity).padding(.vertical, 4)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("browsing-offline-status")
    }
}
