import SwiftUI

struct HomeView: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    let openLocalFile: () -> Void
    let playRecentItem: (PlaybackItem) -> Void
    let showProfile: () -> Void
    let showNowPlaying: () -> Void
    let showLibrary: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                continueListening

                if !playback.recentItems.isEmpty {
                    recentlyPlayed
                }

                librarySources
            }
            .frame(maxWidth: 1_050, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
        .toolbar {
            #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Button(action: showProfile) {
                        AccountAvatar(jellyfin: jellyfin)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profile and settings")
                }
            #endif
        }
    }

    @ViewBuilder
    private var continueListening: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionEyebrow("Continue Listening")

            if let item = playback.currentItem {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) {
                        Button(action: showNowPlaying) {
                            HomePlaybackArtwork(item: item, jellyfin: jellyfin)
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 260, maxWidth: 600)

                        NowPlayingSummary(playback: playback, showsTransportButton: true)
                            .frame(minWidth: 230, idealWidth: 290)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Button(action: showNowPlaying) {
                            HomePlaybackArtwork(item: item, jellyfin: jellyfin)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)

                        NowPlayingSummary(playback: playback, showsTransportButton: true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 18) {
                        Image(systemName: "waveform")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.cyan)
                            .frame(width: 58, height: 58)
                            .background(.cyan.opacity(0.12), in: .rect(cornerRadius: 16))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your music, ready when you are")
                                .font(.title3.weight(.semibold))
                            Text(emptyStateDescription)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Open Audio File", systemImage: "folder") { openLocalFile() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color.secondary.opacity(0.07), in: .rect(cornerRadius: 22))
            }
        }
    }

    private var recentlyPlayed: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played").font(.title2.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(playback.recentItems.prefix(8)) { item in
                        RecentItemCard(
                            item: item,
                            jellyfin: jellyfin,
                            canReplay: item.source == .jellyfin && jellyfin.isSignedIn,
                            action: { playRecentItem(item) }
                        )
                    }
                }
            }
        }
    }

    private var librarySources: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("From Your Library").font(.title2.weight(.semibold))
            VStack(spacing: 0) {
                if let session = jellyfin.session {
                    Button(action: showLibrary) {
                        SourceRow(
                            title: "Jellyfin", subtitle: "Browse music on \(session.serverName)",
                            symbolName: "server.rack")
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 58)
                }
                Button(action: openLocalFile) {
                    SourceRow(
                        title: "Local Files", subtitle: "Play audio directly from this device",
                        symbolName: "folder")
                }
                .buttonStyle(.plain)
            }
            .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 18))
        }
    }

    private var emptyStateDescription: String {
        jellyfin.isSignedIn
            ? "Choose music from your library or open a local audio file."
            : "Open a local audio file, or add a music server from your profile."
    }
}

private struct SourceRow: View {
    let title: String
    let subtitle: String
    let symbolName: String

    var body: some View {
        HStack(spacing: 12) {
            SourceIcon(symbolName: symbolName)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(
                .tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct SourceIcon: View {
    let symbolName: String

    var body: some View {
        Image(systemName: symbolName)
            .font(.body.weight(.medium))
            .foregroundStyle(.cyan)
            .frame(width: 34, height: 34)
            .background(.cyan.opacity(0.10), in: .rect(cornerRadius: 10))
    }
}

private struct SectionEyebrow: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(.cyan)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NowPlayingSummary: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    let showsTransportButton: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(playback.currentItem?.title ?? "Nothing Playing").font(.title2.weight(.semibold))
                .lineLimit(2)
            Text(playback.currentItem?.artist ?? "").foregroundStyle(.secondary).lineLimit(1)
            if let albumTitle = playback.currentItem?.albumTitle {
                Text(albumTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            ProgressView(value: playback.progress).tint(.cyan).padding(.top, 5)
            HStack {
                Text(PlaybackTimeFormatter.format(seconds: playback.elapsed))
                Spacer()
                Text(PlaybackTimeFormatter.format(seconds: playback.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if showsTransportButton {
                Button {
                    playback.togglePlayback()
                } label: {
                    Label(
                        playback.showsPauseControl ? "Pause" : "Play",
                        systemImage: playback.showsPauseControl ? "pause.fill" : "play.fill"
                    )
                    .frame(minWidth: 82)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
            }
        }
        .multilineTextAlignment(.leading)
    }
}

private struct RecentItemCard: View {
    let item: PlaybackItem
    @ObservedObject var jellyfin: JellyfinSessionController
    let canReplay: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                PlaybackArtworkView(item: item, jellyfin: jellyfin).frame(width: 142, height: 142)
                Text(item.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(
                    1)
                Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 142, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canReplay)
        .opacity(canReplay || item.source == .localFiles ? 1 : 0.65)
        .accessibilityHint(
            canReplay ? "Plays this item again" : "Open this item again from its source to play it")
    }
}
