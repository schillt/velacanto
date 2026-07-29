import SwiftUI
import UniformTypeIdentifiers

struct PrototypeContentView: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @State private var isChoosingLocalFile = false
    @State private var isPreparingTestTone = false
    @State private var selectionError: String?

    private let localFiles = LocalFilePlaybackAdapter()
    private let sources = PrototypeMusicSource.all

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    prototypeNotice
                    sourcesSection
                    nowPlayingCard
                }
                .frame(maxWidth: 920)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(background)
            .navigationTitle("Velacanto")
        }
        #if os(macOS)
            .frame(minWidth: 760, minHeight: 620)
        #endif
        .tint(.cyan)
        .fileImporter(
            isPresented: $isChoosingLocalFile,
            allowedContentTypes: [.audio]
        ) { result in
            handleLocalFileSelection(result)
        }
    }

    private var prototypeNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "hammer.fill")
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 3) {
                Text("0.1.0 interface prototype")
                    .font(.headline)
                Text("Real local playback is available; server connections come next.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("PRE-ALPHA")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.cyan.opacity(0.16), in: Capsule())
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Music sources")
                .font(.title2.bold())

            ForEach(sources) { source in
                sourceRow(source)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private func sourceRow(_ source: PrototypeMusicSource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: source.symbolName)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.cyan.gradient, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text(source.displayName)
                        .font(.headline)
                    Text(source.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(source.availabilityText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(source.isAvailable ? .cyan : .secondary)
            }

            if source.id == .localFiles {
                HStack {
                    Button("Open Audio File…") {
                        selectionError = nil
                        isChoosingLocalFile = true
                    }
                    .buttonStyle(.borderedProminent)

                    Button(isPreparingTestTone ? "Preparing…" : "Play Test Tone") {
                        playTestTone()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isPreparingTestTone)

                    Spacer()
                }

                Label(
                    "Opened in place from its current location — never imported or copied.",
                    systemImage: "hand.raised.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.cyan.opacity(source.isAvailable ? 0.10 : 0.035))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Now playing")
                .font(.title2.bold())

            if let item = playback.currentItem {
                let source = PrototypeMusicSource.presentation(for: item.source)

                HStack(spacing: 14) {
                    Image(systemName: source?.symbolName ?? "music.note")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(.indigo.gradient, in: RoundedRectangle(cornerRadius: 15))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.headline)
                        Text("\(item.artist) • \(source?.displayName ?? item.source.rawValue)")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        playback.togglePlayback()
                    } label: {
                        Image(
                            systemName: playback.showsPauseControl
                                ? "pause.fill"
                                : "play.fill"
                        )
                        .font(.title2)
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    .accessibilityLabel(playback.showsPauseControl ? "Pause" : "Play")

                    Button {
                        playback.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Circle())
                    .accessibilityLabel("Stop and close local file")
                }

                Slider(
                    value: Binding(
                        get: { playback.progress },
                        set: { playback.seek(toProgress: $0) }
                    ),
                    in: 0...1
                )
                .disabled(playback.duration <= 0)

                HStack {
                    Text(PlaybackTimeFormatter.format(seconds: playback.elapsed))
                    Spacer()
                    Text(PlaybackTimeFormatter.format(seconds: playback.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "Nothing Playing",
                    systemImage: "music.note",
                    description: Text("Open a local audio file or use the test tone.")
                )
                .frame(maxWidth: .infinity)
            }

            if let message = selectionError ?? playback.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private func handleLocalFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task { @MainActor in
                do {
                    let request = try await localFiles.playbackRequest(
                        for: LocalFileSelection(url: url)
                    )
                    selectionError = nil
                    playback.play(request)
                } catch {
                    selectionError = error.localizedDescription
                }
            }

        case .failure(let error):
            selectionError = error.localizedDescription
        }
    }

    private func playTestTone() {
        isPreparingTestTone = true
        selectionError = nil

        Task { @MainActor in
            defer {
                isPreparingTestTone = false
            }

            do {
                let url = try await DemoToneFactory.makeURL()
                let request = try await localFiles.playbackRequest(
                    for: LocalFileSelection(
                        url: url,
                        title: "Velacanto playback test",
                        artist: "440 Hz local tone"
                    )
                )
                playback.play(request)
            } catch {
                selectionError = error.localizedDescription
            }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color.indigo.opacity(0.24),
                Color.cyan.opacity(0.10),
                Color.clear,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private struct PrototypeMusicSource: Identifiable {
    let id: MusicSourceID
    let displayName: String
    let symbolName: String
    let summary: String
    let availabilityText: String
    let isAvailable: Bool

    static let all = [
        PrototypeMusicSource(
            id: .localFiles,
            displayName: "Local Files",
            symbolName: "folder.fill",
            summary: "Open one audio file in place. Velacanto never copies it into an app library.",
            availabilityText: "AVAILABLE NOW",
            isAvailable: true
        ),
        PrototypeMusicSource(
            id: .jellyfin,
            displayName: "Jellyfin",
            symbolName: "server.rack",
            summary: "Connect to and stream from a personal Jellyfin music library.",
            availabilityText: "NEXT ADAPTER",
            isAvailable: false
        ),
        PrototypeMusicSource(
            id: MusicSourceID(rawValue: "navidrome"),
            displayName: "Navidrome",
            symbolName: "music.note.list",
            summary: "Use the same player with a Navidrome/Subsonic-compatible library.",
            availabilityText: "PLANNED",
            isAvailable: false
        ),
    ]

    static func presentation(for sourceID: MusicSourceID) -> PrototypeMusicSource? {
        all.first { $0.id == sourceID }
    }
}

#Preview {
    PrototypeContentView(playback: AudioPlaybackCoordinator())
}
