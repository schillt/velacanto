import SwiftUI

struct MusicLibraryView: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    let openLocalFile: () -> Void
    let showProfile: () -> Void

    var body: some View {
        List {
            if jellyfin.isSignedIn {
                Section {
                    ForEach(MusicLibraryCategory.allCases) { category in
                        NavigationLink {
                            destination(for: category)
                        } label: {
                            MusicLibraryCategoryRow(category: category)
                        }
                    }
                } header: {
                    Text("Your Music")
                } footer: {
                    if let session = jellyfin.session {
                        Text(
                            "Music from every library available to \(session.username) is combined here."
                        )
                    }
                }
            } else {
                Section {
                    ContentUnavailableView {
                        Label(
                            "Connect Your Music Library",
                            systemImage: "music.note.house"
                        )
                    } description: {
                        Text(
                            jellyfin.phase == .restoring
                                ? "Restoring your saved Jellyfin session…"
                                : "Add a Jellyfin server from your profile to browse albums, artists, songs, and playlists."
                        )
                    } actions: {
                        Button("Open Profile", action: showProfile)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }

            Section("Local Music") {
                Button(action: openLocalFile) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Open Audio File")
                                .foregroundStyle(.primary)
                            Text("Play a file directly from this device")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        SourceIcon(symbolName: "folder")
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: showProfile) {
                    AccountAvatar(jellyfin: jellyfin)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Profile and settings")
            }
        }
    }

    @ViewBuilder
    private func destination(for category: MusicLibraryCategory) -> some View {
        MusicLibraryCategoryView(
            category: category,
            playback: playback,
            jellyfin: jellyfin
        )
    }
}

enum MusicLibraryCategory: String, CaseIterable, Identifiable {
    case albums
    case artists
    case songs
    case playlists

    var id: Self { self }

    var title: String {
        switch self {
        case .albums:
            "Albums"
        case .artists:
            "Artists"
        case .songs:
            "Songs"
        case .playlists:
            "Playlists"
        }
    }

    var subtitle: String {
        switch self {
        case .albums:
            "Browse your collection by album"
        case .artists:
            "Find music by artist"
        case .songs:
            "See every song in your library"
        case .playlists:
            "Collections you’ve created and saved"
        }
    }

    var symbolName: String {
        switch self {
        case .albums:
            "opticaldisc.fill"
        case .artists:
            "music.mic"
        case .songs:
            "music.note"
        case .playlists:
            "music.note.list"
        }
    }
}

struct MusicLibraryCategoryView: View {
    let category: MusicLibraryCategory
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    @ViewBuilder
    var body: some View {
        switch category {
        case .albums:
            MusicAlbumsView(jellyfin: jellyfin, playback: playback)
        case .artists:
            MusicArtistsView(jellyfin: jellyfin, playback: playback)
        case .songs:
            MusicSongsView(jellyfin: jellyfin, playback: playback)
        case .playlists:
            MusicPlaylistsView(
                jellyfin: jellyfin,
                playback: playback
            )
        }
    }
}

private struct MusicLibraryCategoryRow: View {
    let category: MusicLibraryCategory

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(category.title)
                    .foregroundStyle(.primary)
                Text(category.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: category.symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(.cyan)
                .frame(width: 36, height: 36)
                .background(.cyan.opacity(0.10), in: .rect(cornerRadius: 10))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct MusicDetailHeader: View {
    let item: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    let subtitle: String
    let detail: String?

    @ViewBuilder
    var body: some View {
        #if os(macOS)
            HStack(alignment: .bottom, spacing: 26) {
                artwork(size: 220, cornerRadius: 16)
                    .shadow(color: .black.opacity(0.16), radius: 22, y: 10)
                metadata
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        #else
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    artwork(size: 116, cornerRadius: 14)
                    metadata
                }

                VStack(alignment: .leading, spacing: 12) {
                    artwork(size: 116, cornerRadius: 14)
                    metadata
                }
            }
            .padding(.vertical, 6)
        #endif
    }

    private func artwork(size: CGFloat, cornerRadius: CGFloat) -> some View {
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                JellyfinArtworkView(
                    item: item,
                    jellyfin: jellyfin,
                    cornerRadius: cornerRadius,
                    maxWidth: 480
                )
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.name)
                .font(titleFont)
            Text(subtitle)
                .font(subtitleFont)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var titleFont: Font {
        #if os(macOS)
            .largeTitle.weight(.bold)
        #else
            .title2.weight(.semibold)
        #endif
    }

    private var subtitleFont: Font {
        #if os(macOS)
            .title3
        #else
            .body
        #endif
    }
}
