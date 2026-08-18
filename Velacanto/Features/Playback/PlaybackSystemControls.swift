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
        let accentColor: UIColor

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
            slider.minimumTrackTintColor = accentColor
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

    enum ArtworkSliderAccent {
        private static let sampleSide = 24
        private static let hueBucketCount = 12

        private struct Sample {
            let hue: CGFloat
            let saturation: CGFloat
            let brightness: CGFloat
        }

        private struct HueBucket {
            var score: CGFloat = 0
            var count = 0

            var meanScore: CGFloat {
                guard count > 0 else { return 0 }
                return score / CGFloat(count)
            }
        }

        static func color(from image: UIImage, colorScheme: ColorScheme) -> UIColor {
            guard let samples = vividSamples(from: image), !samples.isEmpty else {
                return .systemCyan
            }

            let hueCounts = samples.reduce(
                into: [Int](repeating: 0, count: hueBucketCount)
            ) { counts, sample in
                counts[hueBucket(for: sample.hue)] += 1
            }
            let dominantHue =
                hueCounts.indices.max {
                    hueCounts[$0] < hueCounts[$1]
                } ?? 0
            let totalBrightness = samples.reduce(0) { $0 + $1.brightness }
            let dominantBrightness = totalBrightness / CGFloat(samples.count)

            var buckets = [HueBucket](repeating: HueBucket(), count: hueBucketCount)
            for sample in samples {
                let hueDistance = circularHueDistance(
                    sample.hue,
                    CGFloat(dominantHue) / CGFloat(hueBucketCount)
                )
                let brightnessContrast = abs(sample.brightness - dominantBrightness)
                let contrast = hueDistance * 1.5 + brightnessContrast * 0.25
                let score = sample.saturation * (0.4 + contrast)
                let index = hueBucket(for: sample.hue)
                buckets[index].score += score
                buckets[index].count += 1
            }

            guard
                let selected = buckets.enumerated()
                    .filter({ $0.element.count >= 3 })
                    .max(by: { $0.element.meanScore < $1.element.meanScore })
            else {
                return .systemCyan
            }

            let matchingSamples = samples.filter {
                hueBucket(for: $0.hue) == selected.offset
            }
            let totalSaturation = matchingSamples.reduce(0) { $0 + $1.saturation }
            let saturation = totalSaturation / CGFloat(matchingSamples.count)
            let totalSelectedBrightness = matchingSamples.reduce(0) { $0 + $1.brightness }
            let brightness = totalSelectedBrightness / CGFloat(matchingSamples.count)
            let hue = (CGFloat(selected.offset) + 0.5) / CGFloat(hueBucketCount)

            return UIColor(
                hue: hue,
                saturation: max(0.72, saturation),
                brightness: normalizedBrightness(
                    brightness,
                    for: colorScheme
                ),
                alpha: 1
            )
        }

        private static func vividSamples(from image: UIImage) -> [Sample]? {
            guard let cgImage = image.cgImage else { return nil }
            let pixelCount = sampleSide * sampleSide
            var pixels = [UInt8](repeating: 0, count: pixelCount * 4)
            let alphaInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            let byteOrder = CGBitmapInfo.byteOrder32Big.rawValue
            let bitmapInfo = alphaInfo | byteOrder
            let context = CGContext(
                data: &pixels,
                width: sampleSide,
                height: sampleSide,
                bitsPerComponent: 8,
                bytesPerRow: sampleSide * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            )
            guard let context else {
                return nil
            }

            context.interpolationQuality = .medium
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide)
            )

            var samples: [Sample] = []
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let color = UIColor(
                    red: CGFloat(pixels[offset]) / 255,
                    green: CGFloat(pixels[offset + 1]) / 255,
                    blue: CGFloat(pixels[offset + 2]) / 255,
                    alpha: CGFloat(pixels[offset + 3]) / 255
                )
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0
                let hasHue = color.getHue(
                    &hue,
                    saturation: &saturation,
                    brightness: &brightness,
                    alpha: &alpha
                )
                guard hasHue, alpha > 0.5, saturation >= 0.35 else {
                    continue
                }
                samples.append(
                    Sample(
                        hue: hue,
                        saturation: saturation,
                        brightness: brightness
                    )
                )
            }
            return samples
        }

        private static func hueBucket(for hue: CGFloat) -> Int {
            min(hueBucketCount - 1, Int(hue * CGFloat(hueBucketCount)))
        }

        private static func circularHueDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
            let difference = abs(lhs - rhs)
            return min(difference, 1 - difference)
        }

        private static func normalizedBrightness(
            _ brightness: CGFloat,
            for colorScheme: ColorScheme
        ) -> CGFloat {
            switch colorScheme {
            case .dark:
                max(0.8, brightness)
            default:
                min(0.65, max(0.42, brightness))
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
