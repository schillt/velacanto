import SwiftUI

/// Downloads selects existing catalog identities; every result uses the normal destination.
struct FoundationDownloadsView: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    let library: any FoundationLibrary
    let player: FoundationPlayer
    var isActive = true

    private var horizontalInset: CGFloat {
        #if os(macOS)
            FoundationMacLayout.catalogHorizontalInset
        #else
            16
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("On This Device").font(.title2.bold())
                    Text("Music saved for listening without a connection.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if downloads.isLoading { ProgressView("Verifying downloaded files…") }
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 260),
                            spacing: 16)
                    ], alignment: .leading, spacing: 16
                ) {
                    ForEach([FoundationItem.Kind.track, .album, .artist, .playlist], id: \.self) {
                        kind in
                        NavigationLink {
                            FoundationDownloadFilteredCatalog(
                                kind: kind, library: library, player: player, isActive: isActive)
                        } label: {
                            category(kind)
                        }
                        .accessibilityIdentifier("downloads-category-" + kind.rawValue)
                    }
                }
                NavigationLink {
                    FoundationDownloadManagementView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "internaldrive").font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Manage Downloads").font(.body.weight(.medium))
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: downloads.storageBytes, countStyle: .file)
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 12).contentShape(Rectangle())
                }
                .accessibilityIdentifier("downloads-manage")
                if downloads.owners.isEmpty && downloads.downloadedSongs.isEmpty
                    && !downloads.isLoading
                {
                    ContentUnavailableView(
                        "No Downloads", systemImage: "arrow.down.circle",
                        description: Text("Download music from its Actions menu when online."))
                }
                if let error = downloads.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, horizontalInset).padding(.vertical, 20)
            .foundationBottomChromeEndPadding()
        }
        .foundationBottomChromeScrollClearance()
        .buttonStyle(.plain)
        .foundationCatalogHeader("Downloads")
    }

    private func category(_ kind: FoundationItem.Kind) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol(kind))
                .font(.title2.weight(.medium)).foregroundStyle(.tint)
                .frame(width: 38).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title(kind)).font(.headline)
                Text(count(kind).formatted() + " downloaded")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .padding(20).frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    private func count(_ kind: FoundationItem.Kind) -> Int {
        let items: [FoundationItem]
        switch kind {
        case .track: items = downloads.downloadedSongs
        case .album: items = downloads.downloadedAlbums
        case .artist: items = downloads.downloadedArtists
        default: items = downloads.downloadedPlaylists
        }
        return downloads.itemsWithDownloadedMusic(in: items).count
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
    let kind: FoundationItem.Kind
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    @StateObject private var results = FoundationBrowseModel()

    var body: some View {
        FoundationLibraryIndexView(
            kind: kind, model: results, library: library, player: player,
            isActive: isActive, downloadedOnly: true)
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
