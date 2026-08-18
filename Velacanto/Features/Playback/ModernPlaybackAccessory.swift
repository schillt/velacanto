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
            if let nowPlayingTransitionNamespace {
                accessoryContent.matchedTransitionSource(
                    id: "now-playing-surface",
                    in: nowPlayingTransitionNamespace
                )
            } else {
                accessoryContent
            }
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
        }

        private var inlineAccessory: some View {
            HStack(spacing: 8) {
                nowPlayingArtwork(size: 32)
                trackMetadata
                playbackButton
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
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
                }
            }
            .frame(width: 36, height: 36)
            .buttonStyle(.plain)
            .accessibilityLabel("Show Now Playing")
        }

        private var trackMetadata: some View {
            Button(action: showNowPlaying) {
                VStack(alignment: .leading, spacing: 2) {
                    AutomaticScrollingText(
                        playback.currentItem?.title ?? "Nothing Playing",
                        font: .systemFont(
                            ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize,
                            weight: .medium
                        ),
                        color: .label
                    )
                    AutomaticScrollingText(
                        playback.currentItem?.artist ?? "",
                        font: .preferredFont(forTextStyle: .caption1),
                        color: .secondaryLabel
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

    private struct AutomaticScrollingText: UIViewRepresentable {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        let text: String
        let font: UIFont
        let color: UIColor

        init(_ text: String, font: UIFont, color: UIColor) {
            self.text = text
            self.font = font
            self.color = color
        }

        func makeUIView(context: Context) -> AutomaticScrollingTextView {
            AutomaticScrollingTextView()
        }

        func updateUIView(_ uiView: AutomaticScrollingTextView, context: Context) {
            uiView.update(
                text: text,
                font: font,
                color: color,
                reduceMotion: reduceMotion
            )
        }
    }

    @MainActor
    private final class AutomaticScrollingTextView: UIView {
        private let contentView = UIView()
        private let leadingLabel = UILabel()
        private let trailingLabel = UILabel()
        private let fadeMask = CAGradientLayer()

        private var displayedText = ""
        private var displayedFont: UIFont?
        private var displayedColor: UIColor?
        private var reduceMotion = false
        private var lastAnimationWidth: CGFloat = -1
        private var needsAnimationRestart = true

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            isAccessibilityElement = true
            leadingLabel.numberOfLines = 1
            trailingLabel.numberOfLines = 1
            contentView.addSubview(leadingLabel)
            contentView.addSubview(trailingLabel)
            addSubview(contentView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 0, let font = displayedFont else { return }

            let textWidth = layoutLabels(font: font)
            guard
                needsAnimationRestart
                    || abs(lastAnimationWidth - bounds.width) > 1
            else {
                return
            }
            restartAnimation(textWidth: textWidth)
            lastAnimationWidth = bounds.width
            needsAnimationRestart = false
        }

        func update(text: String, font: UIFont, color: UIColor, reduceMotion: Bool) {
            guard
                displayedText != text
                    || displayedFont != font
                    || displayedColor != color
                    || self.reduceMotion != reduceMotion
            else {
                return
            }

            displayedText = text
            displayedFont = font
            displayedColor = color
            self.reduceMotion = reduceMotion
            accessibilityLabel = text
            needsAnimationRestart = true
            for label in [leadingLabel, trailingLabel] {
                label.text = text
                label.font = font
                label.textColor = color
            }
            setNeedsLayout()
        }

        private func layoutLabels(font: UIFont) -> CGFloat {
            let textSize = leadingLabel.sizeThatFits(
                CGSize(width: .greatestFiniteMagnitude, height: bounds.height)
            )
            let textWidth = ceil(textSize.width)
            let textHeight = min(bounds.height, ceil(font.lineHeight))
            let originY = (bounds.height - textHeight) / 2
            let showsTrailingLabel = textWidth > bounds.width && !reduceMotion
            leadingLabel.frame = CGRect(x: 0, y: originY, width: textWidth, height: textHeight)
            trailingLabel.frame = CGRect(
                x: textWidth + gap,
                y: originY,
                width: textWidth,
                height: textHeight
            )
            trailingLabel.isHidden = !showsTrailingLabel
            contentView.frame = CGRect(
                x: 0,
                y: 0,
                width: showsTrailingLabel ? (textWidth * 2) + gap : textWidth,
                height: bounds.height
            )

            return textWidth
        }

        private func restartAnimation(textWidth: CGFloat) {
            contentView.layer.removeAllAnimations()
            layer.mask = nil

            guard textWidth > bounds.width, !reduceMotion else { return }

            let animation = CABasicAnimation(keyPath: "transform.translation.x")
            animation.fromValue = 0
            animation.toValue = -(textWidth + gap)
            animation.duration = max((textWidth + gap) / 28, 0.5)
            animation.beginTime = CACurrentMediaTime() + 1
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            contentView.layer.add(animation, forKey: "marquee")

            fadeMask.frame = bounds
            fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
            fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
            fadeMask.colors = [
                UIColor.clear.cgColor,
                UIColor.black.cgColor,
                UIColor.black.cgColor,
                UIColor.clear.cgColor,
            ]
            fadeMask.locations = [0, 0.08, 0.92, 1]
            layer.mask = fadeMask
        }

        private var gap: CGFloat { 28 }
    }
#endif

#if os(iOS)
    struct NowPlayingTitleMarquee: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        let text: String
        let color: Color

        @State private var containerWidth: CGFloat = 0
        @State private var textWidth: CGFloat = 0
        @State private var offset: CGFloat = 0
        @State private var isScrolling = false

        private let loopSpacing: CGFloat = 24

        var body: some View {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    truncatedTitle
                        .opacity(isScrolling ? 0 : 1)

                    HStack(spacing: loopSpacing) {
                        fullTitle
                        fullTitle
                            .accessibilityHidden(true)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .opacity(isScrolling ? 1 : 0)
                    .offset(x: offset)
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .leading
                )
                .clipped()
                .onAppear {
                    containerWidth = geometry.size.width
                }
                .onChange(of: geometry.size.width) { _, width in
                    containerWidth = width
                }
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .onPreferenceChange(NowPlayingTitleWidthPreferenceKey.self) { width in
                textWidth = width
            }
            .task(id: animationID) {
                await animateTitle()
            }
        }

        private var truncatedTitle: some View {
            Text(text)
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var fullTitle: some View {
            Text(text)
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: NowPlayingTitleWidthPreferenceKey.self,
                            value: geometry.size.width
                        )
                    }
                }
        }

        private var shouldScroll: Bool {
            textWidth > containerWidth && !reduceMotion
        }

        private var animationID: String {
            "\(text)|\(textWidth)|\(containerWidth)|\(reduceMotion)"
        }

        @MainActor
        private func animateTitle() async {
            offset = 0
            isScrolling = false
            guard shouldScroll else { return }

            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            isScrolling = true
            withAnimation(
                .linear(duration: max((textWidth + loopSpacing) / 12, 0.5))
                    .repeatForever(autoreverses: false)
            ) {
                offset = -(textWidth + loopSpacing)
            }
        }
    }

    private struct NowPlayingTitleWidthPreferenceKey: PreferenceKey {
        static let defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
#endif
