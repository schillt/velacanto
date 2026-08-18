import SwiftUI

struct BufferedPlaybackSlider: View {
    @Binding var value: Double
    let bufferedProgress: Double
    let isEnabled: Bool
    var accent = Color.velacantoAccent
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false
    @State private var isShowingTapFeedback = false

    var body: some View {
        GeometryReader { geometry in
            let progress = min(1, max(0, value))
            let buffered = min(1, max(0, bufferedProgress))
            let trackWidth = geometry.size.width
            let trackHeight: CGFloat = isDragging || isShowingTapFeedback ? 15 : 6

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.22))

                Capsule()
                    .fill(.secondary.opacity(0.48))
                    .frame(width: trackWidth * buffered)

                Capsule()
                    .fill(accent)
                    .frame(width: trackWidth * progress)
            }
            .frame(height: trackHeight)
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if !isDragging {
                            withAnimation(.easeOut(duration: 0.12)) {
                                isDragging = true
                            }
                            onEditingChanged(true)
                        }
                        value = progressForLocation(
                            gesture.location.x,
                            width: trackWidth
                        )
                    }
                    .onEnded { gesture in
                        guard isEnabled, isDragging else { return }
                        value = progressForLocation(
                            gesture.location.x,
                            width: trackWidth
                        )
                        withAnimation(.easeOut(duration: 0.12)) {
                            isDragging = false
                        }
                        onEditingChanged(false)
                    }
            )
            .simultaneousGesture(
                TapGesture()
                    .onEnded {
                        showTapFeedback()
                    }
            )
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(Int(progress * 100)) percent")
            .accessibilityAdjustableAction { direction in
                guard isEnabled else { return }
                switch direction {
                case .increment:
                    value = min(1, value + 0.05)
                case .decrement:
                    value = max(0, value - 0.05)
                @unknown default:
                    break
                }
            }
        }
        .frame(height: 30)
    }

    private func progressForLocation(_ location: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, location / width))
    }

    private func showTapFeedback() {
        guard isEnabled else { return }
        withAnimation(.easeOut(duration: 0.1)) {
            isShowingTapFeedback = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.spring(duration: 0.24, bounce: 0.28)) {
                isShowingTapFeedback = false
            }
        }
    }
}
