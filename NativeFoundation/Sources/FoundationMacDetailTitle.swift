import Observation
import SwiftUI

#if os(macOS)
    /// Raw scrolling geometry is not an observable view dependency. Only the title
    /// leaf reads the clamped reveal value, so settled title positions do not
    /// invalidate the surrounding collection content on every scroll sample.
    @MainActor @Observable
    final class FoundationMacTitleReveal {
        private(set) var progress: CGFloat = 0
        @ObservationIgnored private var titleBottom = CGFloat.greatestFiniteMagnitude
        @ObservationIgnored private var toolbarBottom = CGFloat.zero
        @ObservationIgnored private var scrolled = false

        func updateTitleBottom(_ value: CGFloat) {
            titleBottom = value
            updateProgress()
        }

        func updateToolbarBottom(_ value: CGFloat) {
            toolbarBottom = value
            updateProgress()
        }

        func updateScrolled(_ value: Bool) {
            scrolled = value
            updateProgress()
        }

        func reset() {
            titleBottom = .greatestFiniteMagnitude
            scrolled = false
            updateProgress()
        }

        private func updateProgress() {
            let next: CGFloat
            if scrolled, toolbarBottom > 0, titleBottom.isFinite {
                let fraction = min(1, max(0, (toolbarBottom - titleBottom) / 48))
                next = fraction * fraction * (3 - 2 * fraction)
            } else {
                next = 0
            }
            if progress != next { progress = next }
        }
    }

    struct FoundationMacDetailTitle: ViewModifier {
        let item: FoundationItem?
        @State private var reveal = FoundationMacTitleReveal()

        @ViewBuilder func body(content: Content) -> some View {
            let tracked =
                content
                .onPreferenceChange(FoundationDetailTitlePosition.self) { positions in
                    if let item, let bottom = positions[item.id] {
                        reveal.updateTitleBottom(bottom)
                    }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 1
                } action: { _, scrolled in
                    reveal.updateScrolled(scrolled)
                }
                .onChange(of: item?.id) { _, _ in reveal.reset() }
            if let item, item.kind == .artist || item.kind == .album {
                tracked.navigationTitle("")
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            FoundationMacRevealedTitle(item: item, reveal: reveal)
                        }.sharedBackgroundVisibility(.hidden)
                    }
            } else {
                tracked
            }
        }
    }

    private struct FoundationMacRevealedTitle: View {
        let item: FoundationItem
        let reveal: FoundationMacTitleReveal
        @Environment(\.foundationReduceMotion) private var reduceMotion

        var body: some View {
            let progress = reveal.progress
            ZStack {
                title.hidden().accessibilityHidden(true)
                title
                    .opacity(progress)
                    .offset(y: reduceMotion ? 0 : 8 * (1 - progress))
                    .scaleEffect(reduceMotion ? 1 : 0.97 + 0.03 * progress)
                    .accessibilityHidden(progress == 0)
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.frame(in: .global).maxY
            } action: {
                reveal.updateToolbarBottom($0)
            }
            .allowsHitTesting(false)
        }

        private var title: some View {
            VStack(spacing: 1) {
                Text(item.title).font(.headline).lineLimit(1)
                if item.kind == .album, !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }
#endif
