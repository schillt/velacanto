import SwiftUI

#if os(iOS)
    @available(iOS 26.0, *)
    struct ModernPlaybackAccessory: View {
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement

        @ObservedObject var playback: AudioPlaybackCoordinator
        @ObservedObject var jellyfin: JellyfinSessionController
        let showNowPlaying: () -> Void
        var nowPlayingTransitionNamespace: Namespace.ID?

        @ViewBuilder
        var body: some View {
            accessoryContent
        }

        @ViewBuilder
        private var accessoryContent: some View {
            if placement == .inline {
                inlineAccessory
            } else {
                expandedAccessory
            }
        }

        private var expandedAccessory: some View {
            HStack(spacing: 10) {
                nowPlayingArtwork(size: 34)
                trackMetadata
                playbackButton
                nextButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .gesture(
                TapGesture().onEnded { showNowPlaying() },
                including: .gesture
            )
        }

        private var inlineAccessory: some View {
            HStack(spacing: 8) {
                nowPlayingArtwork(size: 32)
                trackMetadata
                playbackButton
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .gesture(
                TapGesture().onEnded { showNowPlaying() },
                including: .gesture
            )
        }

        @ViewBuilder
        private func nowPlayingArtwork(size: CGFloat) -> some View {
            Button(action: showNowPlaying) {
                if let item = playback.currentItem {
                    PlaybackArtworkView(
                        item: item,
                        jellyfin: jellyfin,
                        cornerRadius: 6,
                        maxWidth: 128
                    )
                    .frame(width: size, height: size)
                    .matchedNowPlayingArtworkSource(
                        in: nowPlayingTransitionNamespace
                    )
                }
            }
            .frame(width: 36, height: 36)
            .buttonStyle(.plain)
            .accessibilityLabel("Show Now Playing")
        }

        private var trackMetadata: some View {
            Button(action: showNowPlaying) {
                VStack(alignment: .leading, spacing: 2) {
                    CompactPlaybackMetadataMarquee(
                        text: playback.currentItem?.title ?? "Nothing Playing",
                        font: .callout.weight(.medium),
                        color: .primary
                    )
                    CompactPlaybackMetadataMarquee(
                        text: playback.currentItem?.artist ?? "",
                        font: .caption,
                        color: .secondary
                    )
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Now Playing")
            .accessibilityValue(trackAccessibilityValue)
        }

        private var trackAccessibilityValue: String {
            let title = playback.currentItem?.title ?? "Nothing Playing"
            let artist = playback.currentItem?.artist ?? ""
            return artist.isEmpty ? title : "\(title), \(artist)"
        }

        private var playbackButton: some View {
            Button {
                playback.togglePlayback()
            } label: {
                if playback.isWaitingForPlayback {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 36, height: 36)
                } else {
                    Image(
                        systemName: playback.showsPauseControl
                            ? "pause.fill" : "play.fill"
                    )
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                playback.isWaitingForPlayback
                    ? "Loading playback"
                    : playback.showsPauseControl ? "Pause" : "Play"
            )
        }

        private var nextButton: some View {
            Button {
                playback.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(!playback.canGoNext)
            .accessibilityLabel("Next")
        }
    }

    private struct CompactPlaybackMetadataMarquee: View {
        private struct Measurement: Hashable {
            let availableWidth: CGFloat
            let textWidth: CGFloat

            var overflow: CGFloat {
                max(textWidth - availableWidth, 0)
            }
        }

        private struct CycleID: Hashable {
            let text: String
            let measurement: Measurement
            let isVisible: Bool
            let reduceMotion: Bool
        }

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        let text: String
        let font: Font
        let color: Color

        @State private var scrollPosition = ScrollPosition()
        @State private var measurement = Measurement(availableWidth: 0, textWidth: 0)
        @State private var isVisible = false

        private let initialDwell: Duration = .seconds(1)
        private let trailingDwell: Duration = .milliseconds(700)
        private let pointsPerSecond: CGFloat = 24

        var body: some View {
            ScrollView(.horizontal) {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: Measurement.self) { geometry in
                Measurement(
                    availableWidth: geometry.containerSize.width,
                    textWidth: geometry.contentSize.width
                )
            } action: { _, measurement in
                self.measurement = measurement
            }
            .onAppear {
                isVisible = true
            }
            .onDisappear {
                isVisible = false
                resetScrollPosition()
            }
            .task(id: cycleID) {
                await runCycle()
            }
            .accessibilityHidden(true)
        }

        private var cycleID: CycleID {
            CycleID(
                text: text,
                measurement: measurement,
                isVisible: isVisible,
                reduceMotion: reduceMotion
            )
        }

        private var canScroll: Bool {
            isVisible && !reduceMotion && measurement.overflow > 0
        }

        private var scrollDuration: TimeInterval {
            max(measurement.overflow / pointsPerSecond, 0.5)
        }

        @MainActor
        private func runCycle() async {
            resetScrollPosition()
            guard canScroll else { return }

            do {
                try await Task.sleep(for: initialDwell)
                guard canScroll else { return }

                withAnimation(.linear(duration: scrollDuration)) {
                    scrollPosition.scrollTo(x: measurement.overflow)
                }

                try await Task.sleep(for: .milliseconds(Int64((scrollDuration * 1_000).rounded())))
                guard canScroll else { return }

                try await Task.sleep(for: trailingDwell)
                guard canScroll else { return }

                resetScrollPosition()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }

        @MainActor
        private func resetScrollPosition() {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                scrollPosition.scrollTo(x: 0)
            }
        }
    }

    extension View {
        @ViewBuilder
        fileprivate func matchedNowPlayingArtworkSource(
            in namespace: Namespace.ID?
        ) -> some View {
            if let namespace {
                matchedTransitionSource(
                    id: "now-playing-artwork",
                    in: namespace
                )
            } else {
                self
            }
        }
    }

#endif

#if os(iOS)
    struct NowPlayingTitleMarquee: View {
        let text: String
        let color: Color

        var body: some View {
            Text(text)
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(text)
        }
    }
#endif
