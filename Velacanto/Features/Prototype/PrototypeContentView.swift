import SwiftUI
import UniformTypeIdentifiers

struct PrototypeContentView: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @State private var isChoosingLocalFile = false
    @State private var isPreparingTestTone = false
    @State private var selectionError: String?

    private let localFiles = LocalFilePlaybackAdapter()

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

            ForEach(MusicSourceKind.allCases) { source in
                sourceRow(source)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private func sourceRow(_ source: MusicSourceKind) -> some View {
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
                    .foregroundStyle(source == .localFiles ? .cyan : .secondary)
            }

            if source == .localFiles {
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
        .background(.cyan.opacity(source == .localFiles ? 0.10 : 0.035))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Now playing")
                .font(.title2.bold())

            if let item = playback.currentItem {
                HStack(spacing: 14) {
                    Image(systemName: item.source.symbolName)
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(.indigo.gradient, in: RoundedRectangle(cornerRadius: 15))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.headline)
                        Text("\(item.artist) • \(item.source.displayName)")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        playback.togglePlayback()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

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
        do {
            let url = try result.get()
            let request = try localFiles.playbackRequest(
                for: LocalFileSelection(url: url)
            )
            selectionError = nil
            playback.play(request)
        } catch {
            selectionError = error.localizedDescription
        }
    }

    private func playTestTone() {
        isPreparingTestTone = true
        selectionError = nil

        do {
            let url = try DemoToneFactory.makeURL()
            let request = try localFiles.playbackRequest(
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

        isPreparingTestTone = false
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

#Preview {
    PrototypeContentView(playback: AudioPlaybackCoordinator())
}
