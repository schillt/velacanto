import SwiftUI

enum MusicGenre: String, CaseIterable, Identifiable {
    case alternative = "Alternative"
    case classical = "Classical"
    case country = "Country"
    case electronic = "Electronic"
    case jazz = "Jazz"
    case pop = "Pop"
    case rock = "Rock"
    case soundtrack = "Soundtrack"

    var id: Self { self }

    var symbolName: String {
        switch self {
        case .alternative: "guitars"
        case .classical: "music.quarternote.3"
        case .country: "music.mic"
        case .electronic: "waveform"
        case .jazz: "music.note"
        case .pop: "music.note"
        case .rock: "guitars"
        case .soundtrack: "film"
        }
    }
}

struct MusicGenreGrid: View {
    let selectGenre: (MusicGenre) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 116), spacing: 12)],
            spacing: 12
        ) {
            ForEach(MusicGenre.allCases) { genre in
                Button {
                    selectGenre(genre)
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: genre.symbolName)
                            .font(.title2.weight(.medium))
                        Text(genre.rawValue)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
                    .padding(14)
                    .background(.quaternary, in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Searches your library for \(genre.rawValue) music")
            }
        }
    }
}

struct MusicQueuePlaybackControls: View {
    let capabilities: MusicItemCapabilities
    let isPreparing: Bool
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                actionButtons
            }

            VStack(spacing: 10) {
                actionButtons
            }
        }
        .disabled(isPreparing)
        .overlay {
            if isPreparing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if capabilities.contains(.play) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }

        if capabilities.contains(.shuffle) {
            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct MusicSongRow: View {
    let song: MusicCatalogItem
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
            } else if playback.currentItem?.id == song.id.opaqueID {
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
        .contextMenu {
            MusicFavoriteButton(item: song)

            Divider()

            if song.capabilities.contains(.playNext) {
                Button {
                    playback.playNext(
                        JellyfinPlaybackAdapter.playbackItem(for: song)
                    )
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .disabled(playback.currentItem == nil)
            }

            if song.capabilities.contains(.playLast) {
                Button {
                    playback.playLast(
                        JellyfinPlaybackAdapter.playbackItem(for: song)
                    )
                } label: {
                    Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                .disabled(playback.currentItem == nil)
            }

            Divider()

            NavigationLink {
                MusicSongDetailView(
                    song: song,
                    jellyfin: jellyfin,
                    playback: playback
                )
            } label: {
                Label("Go to Song", systemImage: "music.note")
            }

            if let album = song.albumNavigationItem {
                NavigationLink {
                    JellyfinTracksView(
                        album: album,
                        jellyfin: jellyfin,
                        playback: playback
                    )
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }

            if let artist = song.artistNavigationItem {
                NavigationLink {
                    MusicArtistView(
                        artist: artist,
                        jellyfin: jellyfin,
                        playback: playback
                    )
                } label: {
                    Label("Go to Artist", systemImage: "music.mic")
                }
            }
        }
    }

    private var songSubtitle: String {
        if let album = song.album, !album.isEmpty {
            return "\(song.displayArtist) · \(album)"
        }
        return song.displayArtist
    }
}

private struct MusicSongDetailView: View {
    let song: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator
    @State private var isPreparing = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MusicDetailHeader(
                    item: song,
                    jellyfin: jellyfin,
                    subtitle: song.displayArtist,
                    detail: song.album
                )

                Button("Play", systemImage: "play.fill") {
                    play()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPreparing)

                if let errorMessage {
                    ErrorMessageView(message: errorMessage)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(song.name)
    }

    private func play() {
        isPreparing = true
        errorMessage = nil
        Task {
            defer { isPreparing = false }
            do {
                let request = try await jellyfin.playbackRequest(for: song)
                playback.play(
                    request,
                    context: .single,
                    account: jellyfin.playbackAccount
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct MusicCatalogErrorView: View {
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

struct MusicPaginationErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Retry", action: retry)
        }
        .padding(.vertical, 8)
    }
}
