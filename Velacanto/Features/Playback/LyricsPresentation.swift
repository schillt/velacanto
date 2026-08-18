import SwiftUI

enum LyricsLoadState: Equatable {
    case loading
    case unavailable
    case available(MusicLyrics)
    case failed
}

struct LyricsPresentation: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    let state: LyricsLoadState
    let dismiss: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lyrics")
                    .font(.title2.bold())
                Spacer()
                Button("Back to Player", systemImage: "chevron.backward") {
                    dismiss()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Group {
                switch state {
                case .loading:
                    ProgressView("Loading Lyrics")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .unavailable:
                    ContentUnavailableView(
                        "Lyrics Unavailable",
                        systemImage: "quote.bubble",
                        description: Text("Lyrics are not available for this song.")
                    )
                case .available(let lyrics):
                    LyricsLines(playback: playback, lyrics: lyrics)
                case .failed:
                    ContentUnavailableView {
                        Label(
                            "Lyrics Could Not Load",
                            systemImage: "exclamationmark.bubble"
                        )
                    } description: {
                        Text("Check your connection and try again.")
                    } actions: {
                        Button("Try Again", action: retry)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(lyricsBackground)
        .accessibilityElement(children: .contain)
    }

    private var lyricsBackground: Color {
        #if os(iOS)
            Color(uiColor: .systemBackground)
        #else
            Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

struct LyricsControl: View {
    let state: LyricsLoadState
    let isPresented: Bool
    let action: () -> Void

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Loading lyrics")
        case .unavailable:
            Image(systemName: "quote.bubble")
                .frame(width: 44, height: 44)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Lyrics unavailable")
                .accessibilityAddTraits(.isStaticText)
        case .available:
            Button(action: action) {
                Image(
                    systemName: isPresented
                        ? "quote.bubble.fill" : "quote.bubble"
                )
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPresented ? "Hide Lyrics" : "Show Lyrics")
        case .failed:
            Button(action: action) {
                Image(systemName: "exclamationmark.bubble")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Lyrics could not be loaded")
            .accessibilityHint("Shows lyrics and a retry control")
        }
    }
}

private struct LyricsLines: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject var playback: AudioPlaybackCoordinator
    let lyrics: MusicLyrics

    @State private var followsPlayback = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let timingMessage {
                        Label(timingMessage, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                    } else if !followsPlayback {
                        Button("Follow Playback", systemImage: "scope") {
                            followsPlayback = true
                            scrollToActiveLine(using: proxy, animated: true)
                        }
                        .font(.caption.bold())
                        .buttonStyle(.borderless)
                    }

                    ForEach(lyrics.lines) { line in
                        lyricLine(line)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting, lyrics.hasTimedLines {
                    followsPlayback = false
                }
            }
            .onAppear {
                scrollToActiveLine(using: proxy, animated: false)
            }
            .onChange(of: activeLineID) { _, _ in
                guard followsPlayback else { return }
                scrollToActiveLine(using: proxy, animated: true)
            }
        }
        .accessibilityLabel("Lyrics")
    }

    @ViewBuilder
    private func lyricLine(_ line: MusicLyricLine) -> some View {
        if let startTime = line.startTime {
            Button {
                followsPlayback = true
                playback.seek(toTime: startTime)
            } label: {
                lyricText(line)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(line.text)
            .accessibilityHint(
                "Seek to \(PlaybackTimeFormatter.format(seconds: startTime))"
            )
        } else {
            lyricText(line)
        }
    }

    private func lyricText(_ line: MusicLyricLine) -> some View {
        let isActive = line.id == activeLineID
        return Text(line.text)
            .font(.title3.weight(isActive ? .bold : .semibold))
            .foregroundStyle(
                isActive || !lyrics.hasTimedLines
                    ? Color.primary : Color.secondary.opacity(0.72)
            )
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: isActive
            )
    }

    private var activeLineID: Int? {
        lyrics.activeLine(at: playback.elapsed + 0.08)?.id
    }

    private var timingMessage: String? {
        if !lyrics.hasTimedLines {
            return "These lyrics do not include timing information."
        }
        if !lyrics.isFullyTimed {
            return "Some lines are not timed. Timed lines will still follow playback."
        }
        return nil
    }

    private func scrollToActiveLine(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let activeLineID else { return }
        if animated, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.32)) {
                proxy.scrollTo(activeLineID, anchor: .center)
            }
        } else {
            proxy.scrollTo(activeLineID, anchor: .center)
        }
    }
}
