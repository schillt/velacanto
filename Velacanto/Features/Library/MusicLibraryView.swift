import SwiftUI

struct MusicLibraryView: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    let isPreparingTestTone: Bool
    let openLocalFile: () -> Void
    let playTestTone: () -> Void
    let showAccount: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(MusicLibraryCategory.allCases) { category in
                    if jellyfin.isSignedIn {
                        NavigationLink {
                            destination(for: category)
                        } label: {
                            MusicLibraryCategoryRow(category: category)
                        }
                    } else {
                        Button(action: showAccount) {
                            MusicLibraryCategoryRow(category: category)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Your Music")
            } footer: {
                Text(libraryFooter)
            }

            Section("Sources") {
                Button(action: showAccount) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Jellyfin")
                                .foregroundStyle(.primary)
                            Text(jellyfinStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        MusicLibrarySourceIcon(symbolName: "server.rack")
                    }
                }
                .buttonStyle(.plain)

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
                        MusicLibrarySourceIcon(symbolName: "folder")
                    }
                }
                .buttonStyle(.plain)
            }

            Section {
                Button(action: playTestTone) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                isPreparingTestTone
                                    ? "Preparing Playback Check…"
                                    : "Run Playback Check"
                            )
                            .foregroundStyle(.primary)
                            Text("Play a generated 440 Hz diagnostic tone")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        if isPreparingTestTone {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .foregroundStyle(.cyan)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isPreparingTestTone)
            } header: {
                Text("Playback Tools")
            } footer: {
                Text(
                    "The playback check uses the same player and system media controls as your music."
                )
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: showAccount) {
                    MusicLibraryAccountAvatar(username: jellyfin.session?.username)
                }
                .accessibilityLabel(
                    jellyfin.isSignedIn
                        ? "Jellyfin account"
                        : "Connect Jellyfin account"
                )
            }
        }
    }

    @ViewBuilder
    private func destination(for category: MusicLibraryCategory) -> some View {
        switch category {
        case .albums:
            MusicAlbumsView(jellyfin: jellyfin, playback: playback)
        case .artists:
            MusicArtistsView(jellyfin: jellyfin, playback: playback)
        case .songs:
            MusicSongsView(jellyfin: jellyfin, playback: playback)
        case .playlists:
            MusicPlaylistsView(jellyfin: jellyfin, playback: playback)
        }
    }

    private var libraryFooter: String {
        if let session = jellyfin.session {
            return
                "Music from every library available to \(session.username) is combined here."
        }
        if jellyfin.phase == .restoring {
            return "Restoring your saved Jellyfin library…"
        }
        return "Connect Jellyfin to browse albums, artists, songs, and playlists."
    }

    private var jellyfinStatus: String {
        if let session = jellyfin.session {
            return "\(session.username) · \(session.serverName)"
        }
        if jellyfin.phase == .restoring {
            return "Restoring saved session"
        }
        return "Not connected"
    }
}

private enum MusicLibraryCategory: String, CaseIterable, Identifiable {
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

private struct MusicAlbumsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @State private var albums: [JellyfinItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filteredAlbums: [JellyfinItem] {
        guard !searchText.isEmpty else { return albums }
        return albums.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.displayArtist.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView("Loading albums…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if let errorMessage {
                MusicCatalogErrorView(message: errorMessage) {
                    Task {
                        await load()
                    }
                }
            } else if albums.isEmpty {
                ContentUnavailableView(
                    "No Albums",
                    systemImage: "square.stack",
                    description: Text(
                        "Jellyfin did not return any albums from your music libraries."
                    )
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 138, maximum: 210),
                            spacing: 18,
                            alignment: .top
                        )
                    ],
                    alignment: .leading,
                    spacing: 24
                ) {
                    ForEach(filteredAlbums) { album in
                        NavigationLink {
                            JellyfinTracksView(
                                album: album,
                                jellyfin: jellyfin,
                                playback: playback
                            )
                        } label: {
                            MusicAlbumCard(album: album, jellyfin: jellyfin)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Albums")
        .searchable(text: $searchText, prompt: "Albums and artists")
        .task {
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            albums = try await jellyfin.musicAlbums()
        } catch {
            albums = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct MusicAlbumCard: View {
    let album: JellyfinItem
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            JellyfinArtworkView(
                item: album,
                jellyfin: jellyfin,
                cornerRadius: 14,
                maxWidth: 480
            )
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(album.displayArtist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct MusicArtistsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @State private var artists: [JellyfinItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filteredArtists: [JellyfinItem] {
        guard !searchText.isEmpty else { return artists }
        return artists.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading artists…")
                    .frame(maxWidth: .infinity)
            } else if let errorMessage {
                ErrorMessageView(message: errorMessage)
                Button("Retry") {
                    Task {
                        await load()
                    }
                }
            } else if artists.isEmpty {
                ContentUnavailableView(
                    "No Artists",
                    systemImage: "music.mic",
                    description: Text(
                        "Jellyfin did not return any artists from your music libraries."
                    )
                )
            } else {
                ForEach(filteredArtists) { artist in
                    NavigationLink {
                        MusicArtistView(
                            artist: artist,
                            jellyfin: jellyfin,
                            playback: playback
                        )
                    } label: {
                        HStack(spacing: 14) {
                            JellyfinArtworkView(
                                item: artist,
                                jellyfin: jellyfin,
                                cornerRadius: 28,
                                maxWidth: 180
                            )
                            .frame(width: 54, height: 54)
                            .clipShape(Circle())

                            Text(artist.name)
                                .font(.body.weight(.medium))
                        }
                    }
                }
            }
        }
        .navigationTitle("Artists")
        .searchable(text: $searchText, prompt: "Artists")
        .task {
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            artists = try await jellyfin.musicArtists()
        } catch {
            artists = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct MusicArtistView: View {
    let artist: JellyfinItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @State private var albums: [JellyfinItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 14) {
                    JellyfinArtworkView(
                        item: artist,
                        jellyfin: jellyfin,
                        cornerRadius: 90,
                        maxWidth: 420
                    )
                    .frame(width: 172, height: 172)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 8)

                    Text(artist.name)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                if isLoading {
                    ProgressView("Loading albums…")
                        .frame(maxWidth: .infinity)
                } else if let errorMessage {
                    MusicCatalogErrorView(message: errorMessage) {
                        Task {
                            await load()
                        }
                    }
                } else if albums.isEmpty {
                    ContentUnavailableView(
                        "No Albums",
                        systemImage: "square.stack",
                        description: Text(
                            "No albums are currently associated with this artist."
                        )
                    )
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Albums")
                            .font(.title2.weight(.semibold))

                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: 138, maximum: 210),
                                    spacing: 18,
                                    alignment: .top
                                )
                            ],
                            alignment: .leading,
                            spacing: 24
                        ) {
                            ForEach(albums) { album in
                                NavigationLink {
                                    JellyfinTracksView(
                                        album: album,
                                        jellyfin: jellyfin,
                                        playback: playback
                                    )
                                } label: {
                                    MusicAlbumCard(
                                        album: album,
                                        jellyfin: jellyfin
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1_050, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(artist.name)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: artist.id) {
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            albums = try await jellyfin.musicAlbums(for: artist)
        } catch {
            albums = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct MusicSongsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @State private var songs: [JellyfinItem] = []
    @State private var isLoading = true
    @State private var preparingTrackID: String?
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filteredSongs: [JellyfinItem] {
        guard !searchText.isEmpty else { return songs }
        return songs.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.displayArtist.localizedCaseInsensitiveContains(searchText)
                || ($0.album?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading songs…")
                    .frame(maxWidth: .infinity)
            } else if let errorMessage, songs.isEmpty {
                ErrorMessageView(message: errorMessage)
                Button("Retry") {
                    Task {
                        await load()
                    }
                }
            } else if songs.isEmpty {
                ContentUnavailableView(
                    "No Songs",
                    systemImage: "music.note",
                    description: Text(
                        "Jellyfin did not return any songs from your music libraries."
                    )
                )
            } else {
                Section {
                    ForEach(filteredSongs) { song in
                        Button {
                            play(song)
                        } label: {
                            MusicSongRow(
                                song: song,
                                jellyfin: jellyfin,
                                playback: playback,
                                isPreparing: preparingTrackID == song.id
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(preparingTrackID != nil)
                    }
                } header: {
                    Text("\(songs.count.formatted()) Songs")
                }
            }

            if let errorMessage, !songs.isEmpty {
                ErrorMessageView(message: errorMessage)
            }
        }
        .navigationTitle("Songs")
        .searchable(text: $searchText, prompt: "Songs, artists, and albums")
        .task {
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            songs = try await jellyfin.musicSongs()
        } catch {
            songs = []
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

private struct MusicPlaylistsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @State private var playlists: [JellyfinItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filteredPlaylists: [JellyfinItem] {
        guard !searchText.isEmpty else { return playlists }
        return playlists.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading playlists…")
                    .frame(maxWidth: .infinity)
            } else if let errorMessage {
                ErrorMessageView(message: errorMessage)
                Button("Retry") {
                    Task {
                        await load()
                    }
                }
            } else if playlists.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text(
                        "Your Jellyfin playlists will appear here."
                    )
                )
            } else {
                ForEach(filteredPlaylists) { playlist in
                    NavigationLink {
                        MusicPlaylistView(
                            playlist: playlist,
                            jellyfin: jellyfin,
                            playback: playback
                        )
                    } label: {
                        HStack(spacing: 14) {
                            JellyfinArtworkView(
                                item: playlist,
                                jellyfin: jellyfin,
                                cornerRadius: 11,
                                maxWidth: 180
                            )
                            .frame(width: 58, height: 58)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name)
                                    .font(.body.weight(.medium))
                                if let childCount = playlist.childCount {
                                    Text(
                                        "\(childCount) \(childCount == 1 ? "song" : "songs")"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                } else {
                                    Text("Playlist")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .searchable(text: $searchText, prompt: "Playlists")
        .task {
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            playlists = try await jellyfin.musicPlaylists()
        } catch {
            playlists = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct MusicPlaylistView: View {
    let playlist: JellyfinItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @State private var songs: [JellyfinItem] = []
    @State private var isLoading = true
    @State private var preparingTrackID: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if !isLoading {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        JellyfinArtworkView(
                            item: playlist,
                            jellyfin: jellyfin,
                            cornerRadius: 14,
                            maxWidth: 480
                        )
                        .frame(width: 116, height: 116)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(playlist.name)
                                .font(.title2.weight(.semibold))
                            Text("Playlist")
                                .foregroundStyle(.secondary)
                            if !songs.isEmpty {
                                Text(
                                    "\(songs.count) \(songs.count == 1 ? "song" : "songs")"
                                )
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 6)
                }
            }

            if isLoading {
                ProgressView("Loading playlist…")
                    .frame(maxWidth: .infinity)
            } else if let errorMessage, songs.isEmpty {
                ErrorMessageView(message: errorMessage)
                Button("Retry") {
                    Task {
                        await load()
                    }
                }
            } else if songs.isEmpty {
                ContentUnavailableView(
                    "Empty Playlist",
                    systemImage: "music.note.list",
                    description: Text("This playlist does not contain any songs.")
                )
            } else {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    Button {
                        play(song)
                    } label: {
                        MusicSongRow(
                            song: song,
                            leadingNumber: index + 1,
                            jellyfin: jellyfin,
                            playback: playback,
                            isPreparing: preparingTrackID == song.id
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(preparingTrackID != nil)
                }
            }

            if let errorMessage, !songs.isEmpty {
                ErrorMessageView(message: errorMessage)
            }
        }
        .navigationTitle(playlist.name)
        .task(id: playlist.id) {
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            songs = try await jellyfin.tracks(inPlaylist: playlist)
        } catch {
            songs = []
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

private struct MusicSongRow: View {
    let song: JellyfinItem
    var leadingNumber: Int?
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator
    let isPreparing: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let leadingNumber {
                Text(leadingNumber.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            } else {
                JellyfinArtworkView(
                    item: song,
                    jellyfin: jellyfin,
                    cornerRadius: 8,
                    maxWidth: 140
                )
                .frame(width: 46, height: 46)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(song.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(songSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isPreparing {
                ProgressView()
                    .controlSize(.small)
            } else if playback.currentItem?.id == song.id {
                Image(
                    systemName: playback.showsPauseControl
                        ? "speaker.wave.2.fill"
                        : "pause.circle"
                )
                .foregroundStyle(.cyan)
            } else if let duration = song.duration {
                Text(PlaybackTimeFormatter.format(seconds: duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "play.circle")
                    .foregroundStyle(.cyan)
            }
        }
        .contentShape(Rectangle())
    }

    private var songSubtitle: String {
        if let album = song.album, !album.isEmpty {
            return "\(song.displayArtist) · \(album)"
        }
        return song.displayArtist
    }
}

private struct MusicCatalogErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t Load Music", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 40)
    }
}

private struct MusicLibrarySourceIcon: View {
    let symbolName: String

    var body: some View {
        Image(systemName: symbolName)
            .font(.body.weight(.medium))
            .foregroundStyle(.cyan)
            .frame(width: 34, height: 34)
            .background(.cyan.opacity(0.10), in: .rect(cornerRadius: 10))
    }
}

private struct MusicLibraryAccountAvatar: View {
    let username: String?

    var body: some View {
        Text(initials)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.cyan)
            .frame(width: 34, height: 34)
            .background(.cyan.opacity(0.08), in: Circle())
            .overlay {
                Circle()
                    .stroke(.cyan.opacity(0.18), lineWidth: 1)
            }
    }

    private var initials: String {
        let parts = (username ?? "VC")
            .split(whereSeparator: \.isWhitespace)
            .prefix(2)
        let value = parts.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "VC" : value.uppercased()
    }
}
