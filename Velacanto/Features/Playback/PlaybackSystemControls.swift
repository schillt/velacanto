import AVKit
import SwiftUI

#if os(iOS)
    import MediaPlayer
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

struct PlaybackRoutePicker: View {
    var body: some View {
        #if os(iOS)
            IOSRoutePicker()
        #elseif os(macOS)
            MacOSRoutePicker()
        #endif
    }
}

#if os(iOS)
    final class SystemVolumeContainerView: UIView {
        let volumeView = MPVolumeView()

        private let minimumImageView = UIImageView()
        private let maximumImageView = UIImageView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            let configuration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            minimumImageView.image = UIImage(
                systemName: "speaker.fill",
                withConfiguration: configuration
            )
            maximumImageView.image = UIImage(
                systemName: "speaker.wave.3.fill",
                withConfiguration: configuration
            )
            for imageView in [minimumImageView, maximumImageView] {
                imageView.contentMode = .center
                imageView.tintColor = .secondaryLabel
                addSubview(imageView)
            }
            volumeView.showsVolumeSlider = true
            addSubview(volumeView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let iconWidth: CGFloat = 18
            let spacing: CGFloat = 10
            minimumImageView.frame = CGRect(x: 0, y: 0, width: iconWidth, height: bounds.height)
            maximumImageView.frame = CGRect(
                x: max(0, bounds.width - iconWidth),
                y: 0,
                width: iconWidth,
                height: bounds.height
            )
            volumeView.frame = CGRect(
                x: iconWidth + spacing,
                y: 0,
                width: max(0, bounds.width - ((iconWidth + spacing) * 2)),
                height: bounds.height
            )
            volumeView.layoutIfNeeded()
            alignImagesToSliderTrack()
        }

        private func alignImagesToSliderTrack() {
            guard let slider = allSubviews(of: volumeView).compactMap({ $0 as? UISlider }).first
            else {
                return
            }
            let track = slider.trackRect(forBounds: slider.bounds)
            let trackCenterY = slider.convert(
                CGPoint(x: track.midX, y: track.midY),
                to: self
            ).y
            minimumImageView.center.y = trackCenterY
            maximumImageView.center.y = trackCenterY
        }

        private func allSubviews(of view: UIView) -> [UIView] {
            view.subviews + view.subviews.flatMap(allSubviews)
        }
    }

    private struct IOSRoutePicker: UIViewRepresentable {
        func makeUIView(context: Context) -> AVRoutePickerView {
            let picker = AVRoutePickerView()
            picker.activeTintColor = .systemPink
            picker.tintColor = .secondaryLabel
            return picker
        }

        func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
    }

    struct SystemVolumeControl: UIViewRepresentable {
        let accent: Color

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIView(context: Context) -> SystemVolumeContainerView {
            let containerView = SystemVolumeContainerView()
            DispatchQueue.main.async {
                configureSlider(
                    in: containerView.volumeView,
                    coordinator: context.coordinator
                )
                containerView.setNeedsLayout()
            }
            return containerView
        }

        func updateUIView(_ uiView: SystemVolumeContainerView, context: Context) {
            configureSlider(in: uiView.volumeView, coordinator: context.coordinator)
            uiView.setNeedsLayout()
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: SystemVolumeContainerView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width else { return nil }
            return CGSize(width: max(0, width), height: 44)
        }

        private func configureSlider(
            in volumeView: MPVolumeView,
            coordinator: Coordinator
        ) {
            for button in allSubviews(of: volumeView).compactMap({ $0 as? UIButton }) {
                button.isHidden = true
            }
            guard let slider = allSubviews(of: volumeView).compactMap({ $0 as? UISlider }).first
            else {
                return
            }
            slider.isContinuous = true
            slider.minimumValueImage = nil
            slider.maximumValueImage = nil
            slider.minimumTrackTintColor = UIColor(accent)
            slider.maximumTrackTintColor = UIColor.secondaryLabel.withAlphaComponent(0.22)
            slider.setThumbImage(UIImage(), for: .normal)
            slider.setThumbImage(UIImage(), for: .highlighted)
            coordinator.installTapFeedback(on: slider)
            slider.removeTarget(coordinator, action: nil, for: .allEvents)
            slider.addTarget(
                coordinator,
                action: #selector(Coordinator.handleDrag(_:)),
                for: [.touchDragInside, .touchDragOutside]
            )
            slider.addTarget(
                coordinator,
                action: #selector(Coordinator.endInteraction(_:)),
                for: [.touchUpInside, .touchUpOutside, .touchCancel]
            )
        }

        private func allSubviews(of view: UIView) -> [UIView] {
            view.subviews + view.subviews.flatMap(allSubviews)
        }

        @MainActor
        final class Coordinator: NSObject {
            private weak var tapRecognizer: UITapGestureRecognizer?
            private var tapCollapseTask: Task<Void, Never>?
            private var isInteracting = false

            func installTapFeedback(on slider: UISlider) {
                guard tapRecognizer?.view !== slider else { return }
                if let tapRecognizer {
                    tapRecognizer.view?.removeGestureRecognizer(tapRecognizer)
                }
                let recognizer = UITapGestureRecognizer(
                    target: self,
                    action: #selector(handleRejectedTap(_:))
                )
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                slider.addGestureRecognizer(recognizer)
                tapRecognizer = recognizer
            }

            @objc private func handleRejectedTap(_ recognizer: UITapGestureRecognizer) {
                guard
                    recognizer.state == .ended,
                    let slider = recognizer.view as? UISlider
                else {
                    return
                }
                beginInteraction(slider)
                scheduleTapCollapse(for: slider)
            }

            @objc func handleDrag(_ slider: UISlider) {
                tapCollapseTask?.cancel()
                tapCollapseTask = nil
                beginInteraction(slider)
            }

            private func scheduleTapCollapse(for slider: UISlider) {
                tapCollapseTask?.cancel()
                tapCollapseTask = Task { @MainActor [weak self, weak slider] in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled, let self, let slider else { return }
                    endInteraction(slider)
                }
            }

            @objc func beginInteraction(_ slider: UISlider) {
                guard !isInteracting else { return }
                isInteracting = true
                UIView.animate(
                    withDuration: 0.14,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction]
                ) {
                    slider.transform = CGAffineTransform(scaleX: 1, y: 1.8)
                }
            }

            @objc func endInteraction(_ slider: UISlider) {
                tapCollapseTask?.cancel()
                tapCollapseTask = nil
                isInteracting = false
                UIView.animate(
                    withDuration: 0.24,
                    delay: 0,
                    usingSpringWithDamping: 0.72,
                    initialSpringVelocity: 0.25,
                    options: [.beginFromCurrentState, .allowUserInteraction]
                ) {
                    slider.transform = .identity
                }
            }
        }
    }

#elseif os(macOS)
    private struct MacOSRoutePicker: NSViewRepresentable {
        func makeNSView(context: Context) -> AVRoutePickerView {
            AVRoutePickerView()
        }

        func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
    }
#endif
