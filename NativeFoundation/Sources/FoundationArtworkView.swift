import SwiftUI

/// View publication is owned locally; catalog bytes and decoding share the account cache.
struct FoundationCatalogArtwork: View {
    enum Source {
        case catalog
        case current(FoundationCurrentArtwork.Result?)
    }
    @Environment(\.displayScale) private var displayScale
    @Environment(\.foundationReduceMotion) private var reduceMotion
    @State private var isLoadingUpgrade = false
    @State private var loadGeneration = UUID()
    @State private var installedCurrentRevision: UUID?
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    var source: Source = .catalog
    private var currentResultRevision: UUID? {
        if case .current(let result) = source { return result?.revision }
        return nil
    }
    let item: FoundationItem
    let library: any FoundationLibrary
    let isActive: Bool
    var size: CGFloat = 52
    var displayHeight: CGFloat? = nil
    /// Presentation overrides do not change the shared artwork identity or cache.
    var cornerRadius: CGFloat? = nil
    var sampledColor: Binding<Color>? = nil
    var isHero = false
    var loadedImage: Binding<Image?>? = nil
    var upperEdgeColors: Binding<[Color]?>? = nil
    @State private var image: Image?
    @State private var installedDecodedIdentity: ObjectIdentifier?
    @State private var imageRevision = UUID()
    @State private var installedPixels = 0
    @State private var installedIdentity: String?
    #if DEBUG
        @Environment(\.foundationTraceOrigin) private var traceOrigin
    #endif

    private var artworkCornerRadius: CGFloat {
        cornerRadius ?? (item.kind == .artist ? size / 2 : (isHero ? 0 : 6))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: artworkCornerRadius).fill(
                .quaternary)
            ZStack {
                if let displayImage {
                    displayImage.resizable().scaledToFill()
                        .blur(radius: isLoadingUpgrade && !isCurrentArtwork ? min(4, size / 40) : 0)
                        .scaleEffect(item.kind == .genre ? 2 : 1, anchor: .topLeading)
                        .id(imageRevision)
                        .transition(.opacity)
                } else {
                    Image(systemName: item.kind == .artist ? "music.mic" : "music.note")
                        .foregroundStyle(.secondary)
                }
            }
            // Animate decoded-image replacement only; sizing and sampled-color bindings
            // retain their existing publication behavior. Clearing identity is immediate.
            .animation(artworkArrivalAnimation, value: imageRevision)
        }
        .frame(width: size, height: displayHeight ?? size)
        .clipShape(
            RoundedRectangle(cornerRadius: artworkCornerRadius)
        )
        .accessibilityHidden(true)
        .task(id: currentResultRevision) {
            guard !Task.isCancelled else { return }
            if case .current(let result) = source, installedCurrentRevision != result?.revision {
                prepareArtworkIdentity()
                installedCurrentRevision = result?.revision
                installImage(result?.image, precomputedColor: result?.tint)
            }
        }
        .task(id: artworkTaskIdentity) {
            guard isActive, !Task.isCancelled else { return }
            prepareArtworkIdentity()
            if case .current(let result) = source, let result {
                if installedCurrentRevision != result.revision {
                    installedCurrentRevision = result.revision
                    installImage(result.image, precomputedColor: result.tint)
                }
            }
            let generation = UUID()
            loadGeneration = generation
            isLoadingUpgrade = installedPixels < targetPixels
            defer { if loadGeneration == generation { isLoadingUpgrade = false } }
            if let data = await downloads.retainedArtwork(for: item) {
                let pixels = targetPixels
                let result = await Task.detached(priority: .utility) {
                    FoundationCurrentArtwork.decode(data, maximumPixels: pixels)
                }.value
                guard !Task.isCancelled else { return }
                if let result { installImage(result.image) }
            }
            #if DEBUG
                await FoundationTrace.withPage(origin: traceOrigin, page: .artwork) {
                    await loadCatalogArtwork()
                }
            #else
                await loadCatalogArtwork()
            #endif
        }
    }

    // Current artwork is already decoded before presentation. Use it in the first
    // render rather than waiting for the task to copy it into view state.
    private var displayImage: Image? {
        if case .current(let result) = source {
            return (installedCurrentRevision == result?.revision ? image : nil)
                ?? result.map { Image(decorative: $0.image, scale: 1) }
        }
        return image
    }

    private var artworkArrivalAnimation: Animation? {
        if case .current = source { return nil }
        return reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    private func loadCatalogArtwork() async {
        let generation = loadGeneration
        do {
            let result = try await FoundationRequestIntent.$isPlayback.withValue(isCurrentArtwork) {
                try await FoundationArtworkPresentation.load(
                    item: item, library: library, pixels: targetPixels,
                    allowsNetwork: !connectivity.localOnly
                ) { preview in
                    guard !Task.isCancelled, loadGeneration == generation else { return }
                    installImage(preview.image)
                }
            }
            try Task.checkCancellation()
            if let result { installImage(result.image) }
        } catch {
            // Keep any installed preview; explicit retry can reattempt the upgrade.
        }
    }

    private func prepareArtworkIdentity() {
        let identity =
            "\(library.catalogScopeID)-\(FoundationArtworkCache.key(item, pixels: targetPixels).identity)"
        guard installedIdentity != identity else { return }
        installImage(nil)
        installedIdentity = identity
        installedCurrentRevision = nil
    }

    private var isCurrentArtwork: Bool {
        if case .current = source { return true }
        return false
    }

    private var targetPixels: Int {
        let requested = Int(
            ceil(
                max(size, displayHeight ?? size) * max(1, displayScale)
                    * (item.kind == .genre ? 2 : 1)))
        return FoundationArtworkCache.key(item, pixels: requested).pixels
    }

    private var artworkTaskIdentity: String {
        let key = FoundationArtworkCache.key(item, pixels: targetPixels)
        return
            "\(library.catalogScopeID)-\(currentResultRevision?.uuidString ?? "catalog")-\(isActive)-\(key.identity)-\(key.pixels)-\(downloads.retainedArtworkIdentity(for: item) ?? "")-\(connectivity.localOnly)-\(connectivity.successfulRetryRevision)"
    }

    private func installImage(
        _ cgImage: CGImage?, displayImage: Image? = nil, precomputedColor: Color? = nil
    ) {
        if let cgImage {
            let currentPixels: Int
            if case .current(let result) = source, let result {
                currentPixels = max(result.image.width, result.image.height)
            } else {
                currentPixels = 0
            }
            guard max(cgImage.width, cgImage.height) >= max(installedPixels, currentPixels) else {
                return
            }
        }
        let decodedIdentity = cgImage.map { ObjectIdentifier($0) }
        if decodedIdentity != nil, decodedIdentity != installedDecodedIdentity {
            imageRevision = UUID()
        }
        installedDecodedIdentity = decodedIdentity
        installedPixels = cgImage.map { max($0.width, $0.height) } ?? 0
        image = displayImage ?? cgImage.map { Image(decorative: $0, scale: 1) }
        loadedImage?.wrappedValue = image
        guard let cgImage else {
            sampledColor?.wrappedValue = Color(white: 0.12)
            upperEdgeColors?.wrappedValue = nil
            return
        }
        if let upperEdgeColors,
            let border = cgImage.cropping(
                to: CGRect(
                    x: 0, y: 0, width: cgImage.width, height: max(1, cgImage.height / 100)))
        {
            // Downsample the full edge into three broad colors, not stretched image details.
            var pixels = [UInt8](repeating: 0, count: 12)
            upperEdgeColors.wrappedValue = pixels.withUnsafeMutableBytes { bytes in
                guard
                    let context = CGContext(
                        data: bytes.baseAddress, width: 3, height: 1,
                        bitsPerComponent: 8, bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    )
                else { return nil }
                context.interpolationQuality = .high
                context.draw(border, in: CGRect(x: 0, y: 0, width: 3, height: 1))
                let rgba = bytes.bindMemory(to: UInt8.self)
                return stride(from: 0, to: 12, by: 4).map { offset in
                    let alpha = Double(max(1, rgba[offset + 3]))
                    return Color(
                        .sRGB, red: Double(rgba[offset]) / alpha,
                        green: Double(rgba[offset + 1]) / alpha,
                        blue: Double(rgba[offset + 2]) / alpha,
                        opacity: Double(rgba[offset + 3]) / 255)
                }
            }
        }
        guard sampledColor != nil else { return }
        if let precomputedColor {
            sampledColor?.wrappedValue = precomputedColor
            return
        }
        if let color = Self.sampledColor(for: cgImage, isGenre: item.kind == .genre) {
            sampledColor?.wrappedValue = color
        }
    }

    nonisolated static func sampledColor(for cgImage: CGImage, isGenre: Bool = false) -> Color? {
        // Genre artwork displays the top-left tile of the supplied image.
        let source =
            isGenre
            ? cgImage.cropping(
                to: CGRect(
                    x: 0, y: 0, width: max(1, cgImage.width / 2),
                    height: max(1, cgImage.height / 2))) ?? cgImage : cgImage
        var pixels = [UInt8](repeating: 0, count: 64)
        let color: Color? = pixels.withUnsafeMutableBytes { bytes in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: 4, height: 4,
                    bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.draw(source, in: CGRect(x: 0, y: 0, width: 4, height: 4))
            // Prefer a colorful swatch over a random dark or neutral pixel.
            let rgba = bytes.bindMemory(to: UInt8.self)
            var best: (red: Double, green: Double, blue: Double)?
            var bestChroma = -1.0
            for offset in stride(from: 0, to: 64, by: 4) {
                guard rgba[offset + 3] >= 230 else { continue }
                let red = Double(rgba[offset]) / 255
                let green = Double(rgba[offset + 1]) / 255
                let blue = Double(rgba[offset + 2]) / 255
                let chroma = max(red, green, blue) - min(red, green, blue)
                if chroma > bestChroma {
                    bestChroma = chroma
                    best = (red, green, blue)
                }
            }
            guard let best else { return nil }
            // Neutral artwork stays neutral; colorful artwork keeps a stronger hue.
            let neutral = min(best.red, best.green, best.blue) * 0.35
            let peak = max(best.red, best.green, best.blue) - neutral
            guard peak > 0 else { return Color(white: 0.2) }
            var channels = [best.red, best.green, best.blue].map { ($0 - neutral) / peak * 0.62 }
            // Bound luminance so the stronger color still supports white labels.
            let luminance = zip(channels, [0.2126, 0.7152, 0.0722]).reduce(0.0) {
                $0 + pow($1.0, 2.2) * $1.1
            }
            if luminance > 0.16 {
                let scale = pow(0.16 / luminance, 1 / 2.2)
                channels = channels.map { $0 * scale }
            }
            return Color(red: channels[0], green: channels[1], blue: channels[2])
        }
        return color
    }

}
/// Project a supplied album reference for track covers without a metadata lookup.
extension FoundationItem {
    /// Stable across rendition upgrades and missing revision metadata; no provider lookup.
    var sharedArtworkIdentity: String {
        let artwork = catalogArtworkItem
        return FoundationArtworkCache.digest(artwork.artworkCacheBase)
    }

    var catalogArtworkItem: FoundationItem {
        guard kind == .track, let album else { return self }
        return FoundationItem(
            id: album.id, title: album.title, subtitle: "", kind: .album,
            duration: nil, primaryImageTag: album.primaryImageTag)
    }
}

/// Optional artist imagery has no placeholder and never reads the retained primary cover.
struct FoundationArtistRoleArtwork: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    let isActive: Bool
    @Binding var image: FoundationCurrentArtwork.Result?
    var loading: Binding<Bool>? = nil
    var failed: Binding<Bool>? = nil
    var retryRevision = 0
    var requestedPixels = 1280
    @State private var appliedRetryRevision = 0
    @State private var loadGeneration = UUID()
    @State private var installedIdentity: String?
    @EnvironmentObject private var connectivity: FoundationConnectivity

    private var sourceIdentity: String {
        "\(library.catalogScopeID)-\(FoundationArtworkCache.key(item, pixels: 640).identity)"
    }

    var body: some View {
        Color.clear
            .task(
                id:
                    "\(sourceIdentity)-\(isActive)-\(requestedPixels)-\(connectivity.localOnly)-\(connectivity.successfulRetryRevision)-\(retryRevision)"
            ) {
                guard !Task.isCancelled else { return }
                if installedIdentity != sourceIdentity {
                    image = nil
                    installedIdentity = sourceIdentity
                }
                guard isActive, !Task.isCancelled else { return }
                failed?.wrappedValue = false
                let generation = UUID()
                loadGeneration = generation
                let targetSize = FoundationArtworkCache.key(item, pixels: requestedPixels).pixels
                loading?.wrappedValue =
                    image.map { max($0.image.width, $0.image.height) < targetSize } ?? true
                defer { if loadGeneration == generation { loading?.wrappedValue = false } }
                if retryRevision != appliedRetryRevision {
                    appliedRetryRevision = retryRevision
                    await library.retryArtwork(for: item)
                }
                guard !Task.isCancelled else { return }
                do {
                    let upgraded = try await FoundationArtworkPresentation.load(
                        item: item, library: library, pixels: targetSize,
                        allowsNetwork: !connectivity.localOnly
                    ) { preview in
                        guard !Task.isCancelled, loadGeneration == generation else { return }
                        if image == nil { image = preview }
                    }
                    try Task.checkCancellation()
                    if let upgraded {
                        image = upgraded
                    } else if !connectivity.localOnly {
                        failed?.wrappedValue = true
                    }
                } catch {
                    // Failed optional artwork keeps its preview/text fallback and can be retried.
                    if !Task.isCancelled { failed?.wrappedValue = true }
                }
            }
            .accessibilityHidden(true)
    }
}

/// Preview failures are independent of the requested rendition, except authoritative
/// cancellation, credential and transport-security outcomes that apply to both requests.
enum FoundationArtworkLoadRecovery {
    nonisolated static func canAttemptTarget(after error: Error) -> Bool {
        switch FoundationLibraryError.category(error) {
        case .cancelled, .authentication, .credentials, .secureConnection, .invalidServer:
            false
        case .invalidResponse, .unavailable, .network:
            true
        }
    }
}

/// Incoming revisions own hydration reuse; cached details cannot mask refreshed catalog tags.
struct FoundationArtistBrandingMetadata: Sendable {
    let scope: String
    let inputRevision: String
    let detail: FoundationItem

    func resolved(for input: FoundationItem, scope: String) -> FoundationItem? {
        guard self.scope == scope, inputRevision == input.artistBrandingRevision,
            input.kind == .artist, detail.kind == .artist, detail.id == input.id
        else { return nil }
        return detail
    }
}

extension FoundationItem {
    var artistBrandingRevision: String {
        FoundationArtworkCache.digest(
            "\(sharedArtworkIdentity)\0\(primaryImageTag ?? "")\0\(logoImageTag ?? "")\0\(backdropImageTag ?? "")"
        )
    }
}

/// A bounded local-surface estimate guides large-heading contrast; this is not a pixel-perfect
/// native-material or formal accessibility certification. Original artist colors are preferred.
enum FoundationArtistLogoContrast {
    enum Presentation: Equatable, Sendable {
        case original, originalOnLight, originalOnDark, text
    }

    struct Decision: Equatable, Sendable {
        let presentation: Presentation
        let reason: String
    }

    #if VELACANTO_ARTWORK_DIAGNOSTICS
        nonisolated static func diagnosticLabel(_ presentation: Presentation) -> String {
            switch presentation {
            case .original: "Original"
            case .originalOnLight: "Original on light support"
            case .originalOnDark: "Original on dark support"
            case .text: "Text fallback"
            }
        }
    #endif

    struct Surface: Equatable, Sendable {
        let size: CGSize
        let logoFrame: CGRect
        let frostStart: Double
        let frostEnd: Double
        let fadeStart: Double
        var frostOpacity: Double = 0.65
        var readingStart: Double = 1
        var readingEnd: Double = 1
        var readingOpacity: Double = 0
        var smoothPageFade: Bool = false
    }

    nonisolated static func presentation(
        for image: CGImage, dark: Bool, backdrop: CGImage? = nil,
        surface: Surface? = nil, reduceTransparency: Bool = false, increasedContrast: Bool = false
    ) -> Presentation {
        decision(
            for: image, dark: dark, backdrop: backdrop, surface: surface,
            reduceTransparency: reduceTransparency, increasedContrast: increasedContrast
        ).presentation
    }

    nonisolated static func decision(
        for image: CGImage, dark: Bool, backdrop: CGImage? = nil,
        surface: Surface? = nil, reduceTransparency: Bool = false, increasedContrast: Bool = false
    ) -> Decision {
        let width = 96
        let height = max(
            1, min(96, Int(Double(width) * Double(image.height) / Double(image.width))))
        guard let pixels = sample(image, width: width, height: height) else {
            return .init(presentation: .text, reason: "Image sample unavailable")
        }
        let backgrounds = renderedBackgrounds(
            backdrop: backdrop, surface: surface, dark: dark,
            reduceTransparency: reduceTransparency)
        var weight = 0.0
        var normal = 0.0
        var supportedLight = 0.0
        var supportedDark = 0.0
        var transparentPixels = 0
        let minimumContrast = increasedContrast ? 4.5 : 3.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            if alpha < 0.99 { transparentPixels += 1 }
            guard alpha > 0.01 else { continue }
            let rgb = (0..<3).map { min(1, Double(pixels[offset + $0]) / 255 / alpha) }
            let row = offset / 4 / width
            let column = offset / 4 % width
            let background = backgrounds[(row * 12 / height) * 12 + column * 12 / width]
            func passes(_ colors: [Double], on background: [Double]) -> Bool {
                let backgroundLuminance = luminance(background)
                let blended = zip(colors, background).map { $0.0 * alpha + $0.1 * (1 - alpha) }
                let ink = luminance(blended)
                return (max(ink, backgroundLuminance) + 0.05)
                    / (min(ink, backgroundLuminance) + 0.05) >= minimumContrast
            }
            weight += alpha
            if passes(rgb, on: background) { normal += alpha }
            let opacity = supportOpacity(reduceTransparency: reduceTransparency)
            func supported(_ dark: Bool) -> [Double] {
                background.map { $0 * (1 - opacity) + supportTint(dark: dark) * opacity }
            }
            if passes(rgb, on: supported(false)) { supportedLight += alpha }
            if passes(rgb, on: supported(true)) { supportedDark += alpha }
        }
        guard weight > 0 else { return .init(presentation: .text, reason: "No visible ink") }
        let transparent = transparentPixels > width * height / 100
        if !transparent {
            // A supplied opaque logo owns its background. Retain it exactly as authored.
            return .init(presentation: .original, reason: "Original owns its background")
        }
        let requiredCoverage = 0.8
        if normal / weight >= requiredCoverage {
            return .init(
                presentation: .original,
                reason: backdrop == nil || surface == nil
                    ? "Original passes theme-surface estimate" : "Original passes local surface")
        }
        // Only the surface may change. Keep the original artwork even when no support
        // reaches the estimated coverage target; never recolor it or replace visible ink.
        let useLight =
            supportedLight > supportedDark
            || (supportedLight == supportedDark && !dark)
        return .init(
            presentation: useLight ? .originalOnLight : .originalOnDark,
            reason: max(supportedLight, supportedDark) / weight >= requiredCoverage
                ? "Original passes local support" : "Original retained with best local support")
    }

    /// Text uses the same measured backdrop region, frost and fade estimate as logo support.
    /// This chooses a foreground; native material still supplies local readability support.
    nonisolated static func prefersLightText(
        backdrop: CGImage?, surface: Surface?, dark: Bool, reduceTransparency: Bool
    ) -> Bool {
        let backgrounds = renderedBackgrounds(
            backdrop: backdrop, surface: surface, dark: dark,
            reduceTransparency: reduceTransparency)
        var lightScore = 0.0
        var darkScore = 0.0
        for background in backgrounds {
            let level = luminance(background)
            // Log scoring prevents a few extreme pixels dominating a mixed photo region.
            lightScore += log(1.05 / (level + 0.05))
            darkScore += log((level + 0.05) / 0.05)
        }
        return abs(lightScore - darkScore) < 0.001 ? dark : lightScore > darkScore
    }

    nonisolated private static func renderedBackgrounds(
        backdrop: CGImage?, surface: Surface?, dark: Bool, reduceTransparency: Bool
    ) -> [[Double]] {
        let tint = supportTint(dark: dark)
        let fallback = Array(repeating: Array(repeating: tint, count: 3), count: 144)
        guard let backdrop, let surface,
            surface.size.width > 0, surface.size.height > 0,
            surface.logoFrame.width > 0, surface.logoFrame.height > 0
        else { return fallback }
        let scale = max(
            surface.size.width / CGFloat(backdrop.width),
            surface.size.height / CGFloat(backdrop.height))
        let offset = CGPoint(
            x: (surface.size.width - CGFloat(backdrop.width) * scale) / 2,
            y: (surface.size.height - CGFloat(backdrop.height) * scale) / 2)
        let rect = CGRect(
            x: (surface.logoFrame.minX - offset.x) / scale,
            y: (surface.logoFrame.minY - offset.y) / scale,
            width: surface.logoFrame.width / scale, height: surface.logoFrame.height / scale)
        guard let crop = backdrop.cropping(to: rect),
            let pixels = sample(crop, width: 12, height: 12)
        else { return fallback }
        return (0..<144).map { pixel in
            let y =
                Double(
                    surface.logoFrame.minY + surface.logoFrame.height
                        * (CGFloat(pixel / 12) + 0.5) / 12) / Double(surface.size.height)
            let progress = progress(y, from: surface.frostStart, to: surface.frostEnd)
            let frost =
                progress * progress * (3 - 2 * progress)
                * (reduceTransparency ? 1 : surface.frostOpacity)
            let reading =
                FoundationArtistBackdropProfile.eased(
                    y, from: surface.readingStart, to: surface.readingEnd) * surface.readingOpacity
            let fade =
                surface.smoothPageFade
                ? FoundationArtistBackdropProfile.eased(y, from: surface.fadeStart, to: 1)
                : self.progress(y, from: surface.fadeStart, to: 1)
            return (0..<3).map { channel in
                let photo = Double(pixels[pixel * 4 + channel]) / 255
                let frosted = photo * (1 - frost) + tint * frost
                let readable = frosted * (1 - reading) + tint * reading
                return readable * (1 - fade) + tint * fade
            }
        }
    }

    /// Candidate surface values guide the light/dark support choice; the renderer uses a
    /// feathered halo rather than a solid surface, so this is not a rendered contrast guarantee.
    nonisolated static func supportTint(dark: Bool) -> Double { dark ? 0.12 : 0.96 }

    nonisolated static func supportOpacity(reduceTransparency: Bool) -> Double {
        reduceTransparency ? 1 : 0.94
    }

    nonisolated private static func sample(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? pixels : nil
    }

    nonisolated private static func progress(_ value: Double, from start: Double, to end: Double)
        -> Double
    {
        min(1, max(0, (value - start) / max(0.001, end - start)))
    }

    nonisolated private static func luminance(_ rgb: [Double]) -> Double {
        zip(rgb, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + linear($1.0) * $1.1 }
    }

    nonisolated private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

/// Fast targets publish once. A local preview appears only if the target takes perceptibly longer.
enum FoundationArtworkPresentation {
    private enum Phase: Sendable {
        case target(Result<FoundationCurrentArtwork.Result?, Error>)
        case preview(FoundationCurrentArtwork.Result?)
    }

    static func load(
        item: FoundationItem, library: any FoundationLibrary, pixels: Int,
        allowsNetwork: Bool,
        previewDelay: Duration = .milliseconds(180),
        onPreview: @escaping @MainActor @Sendable (FoundationCurrentArtwork.Result) -> Void
    ) async throws -> FoundationCurrentArtwork.Result? {
        try await load(
            target: {
                try await library.artworkResult(
                    for: item, size: pixels, allowsNetwork: allowsNetwork)
            },
            cached: { try await library.cachedArtworkResult(for: item, size: pixels) },
            previewDelay: previewDelay, onPreview: onPreview)
    }

    static func load(
        target: @escaping @Sendable () async throws -> FoundationCurrentArtwork.Result?,
        cached: @escaping @Sendable () async throws -> FoundationCurrentArtwork.Result?,
        previewDelay: Duration,
        onPreview: @escaping @MainActor @Sendable (FoundationCurrentArtwork.Result) -> Void
    ) async throws -> FoundationCurrentArtwork.Result? {
        try await withThrowingTaskGroup(of: Phase.self) { group in
            group.addTask {
                do { return .target(.success(try await target())) } catch {
                    return .target(.failure(error))
                }
            }
            group.addTask {
                try await Task.sleep(for: previewDelay)
                try Task.checkCancellation()
                return .preview(try? await cached())
            }
            var displayedPreview = false
            for try await phase in group {
                try Task.checkCancellation()
                switch phase {
                case .target(let result):
                    group.cancelAll()
                    switch result {
                    case .success(let image?): return image
                    case .success(nil):
                        if !displayedPreview, let fallback = try? await cached() {
                            try Task.checkCancellation()
                            await onPreview(fallback)
                        }
                        return nil
                    case .failure(let error):
                        if !displayedPreview,
                            FoundationArtworkLoadRecovery.canAttemptTarget(after: error),
                            let fallback = try? await cached()
                        {
                            try Task.checkCancellation()
                            await onPreview(fallback)
                        }
                        throw error
                    }
                case .preview(let result):
                    if let result {
                        await onPreview(result)
                        displayedPreview = true
                    }
                }
            }
            return nil
        }
    }
}
