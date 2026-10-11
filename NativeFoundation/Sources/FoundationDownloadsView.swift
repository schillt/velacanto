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
            ForEach([FoundationItem.Kind.track, .album, .artist, .playlist], id: \.self) { kind in
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
        case .artist: "Artists"
        default: "Playlists"
        }
    }
    private func symbol(_ kind: FoundationItem.Kind) -> String {
        switch kind {
        case .track: "music.note"
        case .album: "opticaldisc"
        case .artist: "music.mic"
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
        case .artist: downloads.downloadedArtists
        case .playlist:
            downloads.downloadedPlaylists
                + downloads.owners.filter { owner in
                    owner.item.kind == .playlist
                        && !downloads.downloadedPlaylists.contains(where: { $0.id == owner.item.id }
                        )
                }.map(\.item)
        default: []
        }
    }
    private var title: String {
        switch kind {
        case .track: "Songs"
        case .album: "Albums"
        case .artist: "Artists"
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
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @Environment(\.colorScheme) private var colorScheme
    var surfaceColor: Color? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                statusLabel
                recoveryAction
            }
            VStack(spacing: 6) {
                statusLabel
                recoveryAction
            }
        }
        .font(.caption).foregroundStyle(.primary)
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 6)
        .background(surfaceColor ?? .clear)
        // Detail artwork sampling already bounds luminance for white text.
        .environment(\.colorScheme, surfaceColor == nil ? colorScheme : .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browsing-offline-status")
    }

    private var statusLabel: some View {
        Label("Browsing offline", systemImage: "wifi.slash")
            .fixedSize(horizontal: false, vertical: true)
    }

    private var recoveryAction: some View {
        HStack(spacing: 6) {
            Button("Retry") { Task { await connectivity.retryOnline() } }
                .disabled(connectivity.isRetrying)
                .accessibilityIdentifier("offline-status-retry")
            if connectivity.isRetrying { ProgressView().controlSize(.mini) }
        }
    }
}
