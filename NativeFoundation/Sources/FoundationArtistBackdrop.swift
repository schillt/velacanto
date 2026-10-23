import SwiftUI

/// Measured controls anchor the feather; the remaining hero is one continuous surface.
struct FoundationArtistBackdropProfile: Equatable, Sendable {
    let start: Double
    let blurEnd: Double
    let frostEnd: Double
    let fadeStart: Double
    let frostOpacity: Double
    let readingStart: Double
    let readingEnd: Double
    let readingOpacity: Double
    let smoothPageFade: Bool

    init(
        height: CGFloat, controlsBottom: CGFloat?, increasedContrast: Bool,
        overviewTop: CGFloat? = nil, controlsMidpoint: CGFloat? = nil
    ) {
        smoothPageFade = controlsMidpoint?.isFinite == true
        guard height.isFinite, height > 0, let controlsBottom, controlsBottom.isFinite else {
            start = 1
            blurEnd = 1
            frostEnd = 1
            fadeStart = 1
            frostOpacity = increasedContrast ? 0.42 : 0.28
            readingStart = 1
            readingEnd = 1
            readingOpacity = 0
            return
        }
        let boundary = controlsMidpoint.flatMap { $0.isFinite ? $0 : nil } ?? (controlsBottom + 10)
        start = min(1, max(0, Double(boundary / height)))
        let remaining = 1 - start
        blurEnd = start + remaining * 0.55
        frostEnd = start + remaining * 0.75
        fadeStart = start + remaining * 0.62
        frostOpacity = increasedContrast ? 0.42 : 0.28
        if let overviewTop, overviewTop.isFinite, overviewTop > controlsBottom + 10 {
            readingEnd = min(1, Double(overviewTop / height))
            // Use the entire available gap below controls, rather than a short fixed band.
            // Wide desktop branding rows can otherwise compress this into a visible stripe.
            readingStart = start
            readingOpacity = increasedContrast ? 0.86 : 0.72
        } else {
            readingStart = 1
            readingEnd = 1
            readingOpacity = 0
        }
    }

    static func eased(_ position: Double, from start: Double, to end: Double) -> Double {
        guard position > start, end > start else { return 0 }
        let progress = min(1, max(0, (position - start) / (end - start)))
        return progress * progress * (3 - 2 * progress)
    }
}

/// Presentation only: consumes the existing decoded backdrop, with no fetching or image copies.
/// Public SwiftUI blur layers cross-fade into stronger diffusion beneath native content material.
struct FoundationArtistBackdrop: View {
    @Environment(\.foundationReduceMotion) private var reduceMotion
    let image: CGImage?
    let tint: Color
    let profile: FoundationArtistBackdropProfile
    let reduceTransparency: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                tint
                #if os(macOS)
                    macArtwork(size: geometry.size)
                #else
                    photo(size: geometry.size)
                    if !reduceTransparency {
                        photo(size: geometry.size).blur(radius: 6, opaque: true)
                            .mask { ramp(from: profile.start, to: profile.blurEnd) }
                        photo(size: geometry.size).blur(radius: 18, opaque: true)
                            .mask {
                                ramp(
                                    from: profile.start + (profile.blurEnd - profile.start) * 0.35,
                                    to: profile.frostEnd)
                            }
                    }
                #endif
                Group {
                    if reduceTransparency {
                        tint
                    } else {
                        Rectangle().fill(.ultraThinMaterial)
                    }
                }
                .mask {
                    ramp(
                        from: profile.start, to: profile.frostEnd,
                        strength: reduceTransparency ? 1 : profile.frostOpacity)
                }
                // A full-width, feathered reading surface removes photo contrast changes
                // beneath the overview without adding a card or obscuring the controls.
                tint.mask {
                    ramp(
                        from: profile.readingStart, to: profile.readingEnd,
                        strength: profile.readingOpacity)
                }
                // Resolve into the page surface only below the branding, leaving color visible.
                if profile.smoothPageFade {
                    tint.mask { ramp(from: profile.fadeStart, to: 1) }
                } else {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: profile.fadeStart),
                            .init(color: tint, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom)
                }
            }
            .clipped()
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    #if os(macOS)
        private func macArtwork(size: CGSize) -> some View {
            ZStack {
                if let image {
                    ZStack {
                        let photo = Image(decorative: image, scale: 1).resizable().scaledToFill()
                            .frame(width: size.width, height: size.height).clipped()
                        photo
                        if !reduceTransparency {
                            photo.blur(radius: 6, opaque: true)
                                .mask { ramp(from: profile.start, to: profile.blurEnd) }
                            photo.blur(radius: 18, opaque: true)
                                .mask {
                                    ramp(
                                        from: profile.start
                                            + (profile.blurEnd - profile.start) * 0.35,
                                        to: profile.frostEnd)
                                }
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    // One opacity transition over the combined photo layers avoids
                    // unequal fades through their different vertical feather masks.
                    .compositingGroup()
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height).clipped()
            .animation(
                reduceMotion || image == nil ? nil : .easeOut(duration: 0.3),
                value: image.map(ObjectIdentifier.init))
        }
    #endif

    private func photo(size: CGSize) -> some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            }
        }
        // Keep material, feather masks and geometry outside this animation scope.
        .animation(
            reduceMotion || image == nil ? nil : .easeInOut(duration: 0.2),
            value: image.map(ObjectIdentifier.init)
        )
        .frame(width: size.width, height: size.height).clipped()
    }

    private func ramp(from start: Double, to end: Double, strength: Double = 1) -> LinearGradient {
        let stops: [Gradient.Stop] =
            [.init(color: .clear, location: 0), .init(color: .clear, location: start)]
            + (1...32).map { step in
                let position = start + (end - start) * Double(step) / 32
                return .init(
                    color: .black.opacity(
                        FoundationArtistBackdropProfile.eased(position, from: start, to: end)
                            * strength),
                    location: position)
            }
            + [
                .init(
                    color: .black.opacity(
                        FoundationArtistBackdropProfile.eased(1, from: start, to: end) * strength),
                    location: 1)
            ]
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }
}
