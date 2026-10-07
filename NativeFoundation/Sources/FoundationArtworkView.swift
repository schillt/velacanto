import SwiftUI

/// One view-owned image read. Failure remains a local placeholder; no retries.
struct FoundationCatalogArtwork: View {
    enum Source {
        case catalog
        case current(FoundationCurrentArtwork.Result?)
    }
    var source: Source = .catalog
    private var currentResultID: UUID? {
        if case .current(let result) = source { return result?.id }
        return nil
    }
    let item: FoundationItem
    let library: any FoundationLibrary
    let isActive: Bool
    var size: CGFloat = 52
    var displayHeight: CGFloat? = nil
    var sampledColor: Binding<Color>? = nil
    var isHero = false
    var loadedImage: Binding<Image?>? = nil
    var upperEdgeColors: Binding<[Color]?>? = nil
    @State private var image: Image?
    @State private var completed = false
    #if DEBUG
        @Environment(\.foundationTraceOrigin) private var traceOrigin
    #endif

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: isHero ? 0 : (item.kind == .artist ? size / 2 : 6)).fill(
                .quaternary)
            if let image {
                image.resizable().scaledToFill()
                    .scaleEffect(item.kind == .genre ? 2 : 1, anchor: .topLeading)
            } else {
                Image(systemName: item.kind == .artist ? "music.mic" : "music.note")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: displayHeight ?? size)
        .clipShape(
            RoundedRectangle(cornerRadius: isHero ? 0 : (item.kind == .artist ? size / 2 : 6))
        )
        .accessibilityHidden(true)
        .task(id: currentResultID) {
            if case .current(let result) = source {
                installImage(result?.image)
            }
        }
        .task(id: isActive) {
            guard case .catalog = source else { return }
            #if DEBUG
                await FoundationTrace.withPage(origin: traceOrigin, page: .artwork) {
                    guard isActive, !completed, !Task.isCancelled else { return }
                    do {
                        let data = try await library.artwork(for: item, size: isHero ? 640 : 160)
                        try Task.checkCancellation()
                        installArtwork(data)
                        completed = true
                    } catch {
                        if !Task.isCancelled { completed = true }
                    }
                }
            #else
                guard isActive, !completed, !Task.isCancelled else { return }
                do {
                    let data = try await library.artwork(for: item, size: isHero ? 640 : 160)
                    try Task.checkCancellation()
                    installArtwork(data)
                    completed = true
                } catch {
                    if !Task.isCancelled { completed = true }
                }
            #endif
        }
    }

    private func installArtwork(_ data: Data?) {
        #if os(iOS)
            let native = data.flatMap { UIImage(data: $0) }
            let cgImage = native?.cgImage
            let displayed = native.map { Image(uiImage: $0) }
        #else
            let native = data.flatMap { NSImage(data: $0) }
            let cgImage = native?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let displayed = native.map { Image(nsImage: $0) }
        #endif
        installImage(cgImage, displayImage: displayed)
    }

    private func installImage(_ cgImage: CGImage?, displayImage: Image? = nil) {
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
        // Genre artwork displays the top-left tile of the supplied image.
        let source =
            item.kind == .genre
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
        if let color { sampledColor?.wrappedValue = color }
    }

}

/// Project a supplied album reference for track covers without a metadata lookup.
extension FoundationItem {
    var catalogArtworkItem: FoundationItem {
        guard kind == .track, let album else { return self }
        return FoundationItem(
            id: album.id, title: album.title, subtitle: "", kind: .album,
            duration: nil, primaryImageTag: album.primaryImageTag)
    }
}
