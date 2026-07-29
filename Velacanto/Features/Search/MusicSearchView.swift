import SwiftUI

struct MusicSearchView: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    let showProfile: () -> Void

    @State private var searchText = ""
    @State private var results: [JellyfinItem] = []
    @State private var isLoading = false
    @State private var preparingTrackID: String?
    @State private var errorMessage: String?

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var albums: [JellyfinItem] {
        results.filter { $0.type?.lowercased() == "musicalbum" }
    }

    private var artists: [JellyfinItem] {
        results.filter { $0.type?.lowercased() == "musicartist" }
    }

    private var songs: [JellyfinItem] {
        results.filter { $0.type?.lowercased() == "audio" }
    }

    private var playlists: [JellyfinItem] {
        results.filter { $0.type?.lowercased() == "playlist" }
    }

    var body: some View {
        Group {
            if !jellyfin.isSignedIn {
                ContentUnavailableView {
                    Label("Search Needs a Music Server", systemImage: "magnifyingglass")
                } description: {
                    Text("Add a Jellyfin server from your profile to search your library.")
                } actions: {
                    Button("Open Profile", action: showProfile)
                        .buttonStyle(.borderedProminent)
                }
            } else if query.count < 2 {
                ContentUnavailableView(
                    "Search Your Library",
                    systemImage: "magnifyingglass",
                    description: Text("Enter at least two characters to find music.")
                )
            } else if isLoading {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Search Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        Task {
                            await search()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                resultsList
            }
        }
        .navigationTitle("Search")
        .searchable(text: $searchText, prompt: "Albums, artists, songs, and playlists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: showProfile) {
                    AccountAvatar(username: jellyfin.session?.username)
                }
                .accessibilityLabel("Profile and settings")
            }
        }
        .task(id: searchTaskID) {
            await search()
        }
    }

    private var resultsList: some View {
        List {
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { album in
                        NavigationLink {
                            JellyfinTracksView(
                                album: album,
                                jellyfin: jellyfin,
                                playback: playback
                            )
                        } label: {
                            SearchResultRow(item: album, jellyfin: jellyfin)
                        }
                    }
                }
            }

            if !artists.isEmpty {
                Section("Artists") {
                    ForEach(artists) { artist in
                        NavigationLink {
                            MusicArtistView(
                                artist: artist,
                                jellyfin: jellyfin,
                                playback: playback
                            )
                        } label: {
                            SearchResultRow(item: artist, jellyfin: jellyfin)
                        }
                    }
                }
            }

            if !songs.isEmpty {
                Section("Songs") {
                    ForEach(songs) { song in
                        Button {
                            play(song)
                        } label: {
                            SearchResultRow(
                                item: song,
                                jellyfin: jellyfin,
                                isPreparing: preparingTrackID == song.id
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(preparingTrackID != nil)
                    }
                }
            }

            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            MusicPlaylistView(
                                playlist: playlist,
                                jellyfin: jellyfin,
                                playback: playback
                            )
                        } label: {
                            SearchResultRow(item: playlist, jellyfin: jellyfin)
                        }
                    }
                }
            }
        }
    }

    private var searchTaskID: String {
        "\(jellyfin.session?.serverID ?? "signed-out")|\(query)"
    }

    @MainActor
    private func search() async {
        guard jellyfin.isSignedIn, query.count >= 2 else {
            results = []
            errorMessage = nil
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            results = try await jellyfin.searchMusic(query: query)
        } catch is CancellationError {
            return
        } catch {
            results = []
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func play(_ song: JellyfinItem) {
        preparingTrackID = song.id
        errorMessage = nil

        Task {
            do {
                let request = try await jellyfin.playbackRequest(for: song)
                playback.play(request)
            } catch {
                errorMessage = error.localizedDescription
            }
            preparingTrackID = nil
        }
    }
}

private struct SearchResultRow: View {
    let item: JellyfinItem
    @ObservedObject var jellyfin: JellyfinSessionController
    var isPreparing = false

    var body: some View {
        HStack(spacing: 12) {
            JellyfinArtworkView(
                item: item,
                jellyfin: jellyfin,
                cornerRadius: 9,
                maxWidth: 180
            )
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isPreparing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        switch item.type?.lowercased() {
        case "audio":
            if let album = item.album, !album.isEmpty {
                return "\(item.displayArtist) · \(album)"
            }
            return item.displayArtist
        case "musicalbum":
            return item.displayArtist
        case "musicartist":
            return "Artist"
        case "playlist":
            if let childCount = item.childCount {
                return "\(childCount) \(childCount == 1 ? "song" : "songs")"
            }
            return "Playlist"
        default:
            return "Music"
        }
    }
}
