import Foundation
import SwiftUI
import WidgetKit

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

private struct PlaybackEntry: TimelineEntry {
    let date: Date
    let mode: FoundationWidgetDisplayMode
    let snapshot: FoundationWidgetSnapshot
    let artwork: Data?
}

private struct PlaybackProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PlaybackEntry { preview(.currentSong) }
    func snapshot(
        for configuration: FoundationWidgetConfigurationIntent,
        in context: Context
    ) async -> PlaybackEntry {
        context.isPreview ? preview(configuration.displayMode) : current(configuration.displayMode)
    }
    func timeline(
        for configuration: FoundationWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<PlaybackEntry> {
        Timeline(entries: [current(configuration.displayMode)], policy: .never)
    }
    private func preview(_ mode: FoundationWidgetDisplayMode) -> PlaybackEntry {
        .init(
            date: .now, mode: mode,
            snapshot: .init(
                version: 1, presentation: .track, scope: String(repeating: "a", count: 64),
                occurrence: UUID(), collection: nil, title: "Your music",
                detail: "VelaCanto", isPlaying: false,
                recentCollection: .init(
                    id: "preview", kind: "album", title: "Your album",
                    subtitle: "VelaCanto", imageTag: nil)), artwork: nil)
    }
    private func current(_ mode: FoundationWidgetDisplayMode) -> PlaybackEntry {
        let store = FoundationWidgetStore(location: FoundationWidgetStore.systemLocation)
        let snapshot = (try? store.load()) ?? .empty
        return .init(
            date: .now, mode: mode, snapshot: snapshot,
            artwork: store.artwork(for: snapshot, mode: mode))
    }
}

private struct PlaybackWidgetView: View {
    let entry: PlaybackEntry

    var body: some View {
        let display = entry.snapshot.display(entry.mode)
        HStack(spacing: 14) {
            artwork
                .frame(width: 104, height: 104)
                .clipShape(.rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(
                    entry.mode == .currentSong
                        ? "CURRENT SONG"
                        : display.collection?.kind == "playlist"
                            ? "RECENT PLAYLIST" : "RECENT ALBUM"
                )
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(display.title).font(.headline).lineLimit(2)
                Text(display.detail).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 1)
                if let action = display.action {
                    Button(
                        intent: FoundationWidgetPlaybackIntent(
                            snapshot: entry.snapshot, mode: entry.mode, action: action)
                    ) {
                        Label(
                            action == .collection
                                ? (display.collection?.kind == "playlist"
                                    ? "Play Playlist" : "Play Album")
                                : action == .pause ? "Pause" : "Play",
                            systemImage: action == .pause ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(
                        entry.mode == .recentCollection && action != .collection
                            ? "\(action == .pause ? "Pause" : "Play") current song from \(display.title)"
                            : "\(action == .pause ? "Pause" : "Play") \(display.title)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .privacySensitive()
    }

    @ViewBuilder private var artwork: some View {
        #if os(macOS)
            if let data = entry.artwork, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
        #else
            if let data = entry.artwork, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
        #endif
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
        }
    }
}

@main
struct VelaCantoPlaybackWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: FoundationWidgetSnapshot.kind,
            intent: FoundationWidgetConfigurationIntent.self, provider: PlaybackProvider()
        ) {
            PlaybackWidgetView(entry: $0)
        }
        .configurationDisplayName("VelaCanto Playback")
        .description("Choose Current Song or Recent Album/Playlist in Edit Widget.")
        .supportedFamilies([.systemMedium])
    }
}
