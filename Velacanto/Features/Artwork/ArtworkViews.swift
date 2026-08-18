import SwiftUI
import os

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

struct JellyfinArtworkView: View {
    let item: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    var cornerRadius: CGFloat = 12
    var maxWidth = 640

    var body: some View {
        JellyfinArtworkReferenceView(
            itemID: item.artworkItemID,
            imageTag: item.primaryImageTag,
            jellyfin: jellyfin,
            cornerRadius: cornerRadius,
            maxWidth: maxWidth
        )
    }
}

/// A cover-derived gradient that keeps collection details legible without
/// rendering the artwork itself behind their controls and metadata.
struct MusicCollectionArtworkBackdrop: View {
    let item: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @Binding var palette: MusicCollectionPalette

    @StateObject private var loader = ArtworkViewLoader()

    var body: some View {
        ZStack {
            // Match the Now Playing treatment: the cover supplies the color and
            // depth, while the system background keeps the content readable.
            // Starting from a derived solid color made light covers look cloudy.
            #if os(iOS)
                Color(uiColor: .systemBackground)
            #else
                palette.secondaryBackground
            #endif

            JellyfinArtworkView(
                item: item,
                jellyfin: jellyfin,
                cornerRadius: 0,
                maxWidth: 1_024
            )
            .scaleEffect(1.5)
            .blur(radius: 72)
            .opacity(0.62)

            LinearGradient(
                gradient: Gradient(stops: contentGradientStops),
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task(id: artworkKey?.identifier ?? "signed-out") {
            guard let artworkKey else { return }
            await loader.load(key: artworkKey) {
                await jellyfin.artworkRequest(
                    itemID: item.artworkItemID,
                    imageTag: item.primaryImageTag,
                    maxWidth: artworkKey.sizeBucket
                )
            }
            if let image = loader.image {
                palette = ArtworkContrast.palette(for: image)
            }
        }
    }

    private var artworkKey: ArtworkKey? {
        guard let session = jellyfin.session else { return nil }
        return ArtworkKey(
            serverID: session.serverID,
            userID: session.userID,
            itemID: item.artworkItemID,
            imageTag: item.primaryImageTag ?? "no-tag",
            sizeBucket: 1_024
        )
    }

    private var contentGradientStops: [Gradient.Stop] {
        #if os(iOS)
            let contentBackground = palette.primaryBackground
            return [
                .init(
                    color: Color(uiColor: .systemBackground).opacity(0.05),
                    location: 0
                ),
                .init(color: contentBackground.opacity(0.18), location: 0.42),
                .init(color: contentBackground.opacity(0.88), location: 0.68),
                .init(color: contentBackground, location: 1),
            ]
        #else
            return [
                .init(color: palette.primaryBackground.opacity(0.08), location: 0),
                .init(color: palette.secondaryBackground.opacity(0.9), location: 1),
            ]
        #endif
    }
}

struct MusicCollectionPalette {
    let primaryBackground: Color
    let secondaryBackground: Color
    let foreground: Color
    let secondaryForeground: Color
    let usesLightForeground: Bool

    var navigationScrim: Color {
        usesLightForeground ? .black.opacity(0.18) : .white.opacity(0.18)
    }

    static let fallback = MusicCollectionPalette(
        primaryBackground: .indigo,
        secondaryBackground: .blue,
        foreground: .white,
        secondaryForeground: .white.opacity(0.72),
        usesLightForeground: true
    )
}

private enum ArtworkContrast {
    static func palette(for image: PlatformImage) -> MusicCollectionPalette {
        #if os(iOS)
            guard let cgImage = image.cgImage else { return .fallback }
            var pixel = [UInt8](repeating: 0, count: 4)
            guard
                let context = CGContext(
                    data: &pixel,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                return .fallback
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let luminance =
                (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1])
                    + 0.0722 * Double(pixel[2])) / 255
            let usesLightForeground = luminance < 0.56
            let sourceColor = UIColor(
                red: CGFloat(pixel[0]) / 255,
                green: CGFloat(pixel[1]) / 255,
                blue: CGFloat(pixel[2]) / 255,
                alpha: 1
            )
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            guard
                sourceColor.getHue(
                    &hue,
                    saturation: &saturation,
                    brightness: &brightness,
                    alpha: &alpha
                )
            else {
                return .fallback
            }
            let adjustedSaturation = max(0.24, saturation * 0.72)
            let primaryBrightness =
                usesLightForeground
                ? min(0.26, max(0.14, brightness * 0.34))
                : min(0.96, max(0.78, brightness))
            let secondaryBrightness =
                usesLightForeground
                ? max(0.12, primaryBrightness * 0.62)
                : max(0.5, primaryBrightness * 0.78)
            return MusicCollectionPalette(
                primaryBackground: Color(
                    uiColor: UIColor(
                        hue: hue,
                        saturation: adjustedSaturation,
                        brightness: primaryBrightness,
                        alpha: 1
                    )),
                secondaryBackground: Color(
                    uiColor: UIColor(
                        hue: hue,
                        saturation: adjustedSaturation * 0.76,
                        brightness: secondaryBrightness,
                        alpha: 1
                    )),
                foreground: usesLightForeground ? .white : .black,
                secondaryForeground: usesLightForeground
                    ? .white.opacity(0.72)
                    : .black.opacity(0.62),
                usesLightForeground: usesLightForeground
            )
        #elseif os(macOS)
            return .fallback
        #endif
    }
}

struct JellyfinArtworkReferenceView: View {
    let itemID: String
    let imageTag: String?
    @ObservedObject var jellyfin: JellyfinSessionController
    var cornerRadius: CGFloat = 12
    var maxWidth = 640

    var body: some View {
        RemoteArtworkView(
            itemID: itemID,
            imageTag: imageTag,
            jellyfin: jellyfin,
            cornerRadius: cornerRadius,
            maxWidth: maxWidth
        )
    }
}

/// Starts bounded background loads for genre artwork so a cached genre list can
/// also reuse its actual cover images on its next presentation.
@MainActor
func prefetchGenreArtwork(_ genres: [MusicGenre], jellyfin: JellyfinSessionController) {
    guard let session = jellyfin.session else { return }
    let references = Array(
        Set(genres.compactMap(\.artwork))
            .prefix(24)
    )
    for artwork in references {
        let key = ArtworkKey(
            serverID: session.serverID,
            userID: session.userID,
            itemID: artwork.opaqueItemID,
            imageTag: artwork.imageTag ?? "no-tag",
            sizeBucket: ArtworkKey.sizeBucket(for: 360)
        )
        Task { @MainActor in
            _ = await ArtworkRepository.shared.image(for: key) {
                await jellyfin.artworkRequest(
                    itemID: artwork.opaqueItemID,
                    imageTag: artwork.imageTag,
                    maxWidth: key.sizeBucket
                )
            }
        }
    }
}

struct ArtworkKey: Hashable, Sendable {
    let serverID: String
    let userID: String
    let itemID: String
    let imageTag: String
    let sizeBucket: Int

    var identifier: String {
        [serverID, userID, itemID, imageTag, String(sizeBucket)]
            .joined(separator: "|")
    }

    static func sizeBucket(for requestedWidth: Int) -> Int {
        for bucket in [128, 256, 512, 1_024] where requestedWidth <= bucket {
            return bucket
        }
        return 1_024
    }
}

actor ArtworkDiskCache {
    private static let logger = Logger(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "ArtworkCache"
    )

    private struct Entry: Codable {
        let fileName: String
        let byteCount: Int
        var lastAccess: Date
        let serverID: String
        let userID: String
    }

    private let limit = 64 * 1_024 * 1_024
    private let directory: URL
    private let indexURL: URL
    private let fileManager: FileManager
    private var entries: [String: Entry]

    init(
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) {
        let caches =
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let defaultDirectory = caches.appendingPathComponent(
            "VelacantoArtwork-v1",
            isDirectory: true
        )
        let resolvedDirectory = directory ?? defaultDirectory
        self.directory = resolvedDirectory
        indexURL = resolvedDirectory.appendingPathComponent("index.json")
        self.fileManager = fileManager
        do {
            try fileManager.createDirectory(
                at: resolvedDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            Self.logger.error("Could not create artwork cache directory")
        }

        guard fileManager.fileExists(atPath: indexURL.path) else {
            entries = [:]
            return
        }
        do {
            entries = try JSONDecoder().decode(
                [String: Entry].self,
                from: Data(contentsOf: indexURL)
            )
        } catch {
            entries = [:]
            do {
                try fileManager.removeItem(at: indexURL)
            } catch {
                Self.logger.error("Could not discard invalid artwork cache index")
            }
            Self.logger.error("Discarded invalid artwork cache index")
        }
    }

    func data(for key: ArtworkKey) -> Data? {
        guard var entry = entries[key.identifier] else { return nil }
        let fileURL = directory.appendingPathComponent(entry.fileName)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            entries[key.identifier] = nil
            persistIndex()
            Self.logger.error("Could not read cached artwork")
            return nil
        }
        entry.lastAccess = Date()
        entries[key.identifier] = entry
        persistIndex()
        return data
    }

    func store(_ data: Data, for key: ArtworkKey) {
        let fileName = encodedFileName(for: key.identifier)
        let fileURL = directory.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL, options: .atomic)
            entries[key.identifier] = Entry(
                fileName: fileName,
                byteCount: data.count,
                lastAccess: Date(),
                serverID: key.serverID,
                userID: key.userID
            )
            evictIfNeeded()
            persistIndex()
        } catch {
            Self.logger.error("Could not write cached artwork")
            return
        }
    }

    func clear(serverID: String, userID: String) {
        let matches = entries.filter {
            $0.value.serverID == serverID && $0.value.userID == userID
        }
        for (identifier, entry) in matches {
            removeCachedFile(named: entry.fileName)
            entries[identifier] = nil
        }
        persistIndex()
    }

    private func evictIfNeeded() {
        var total = entries.values.reduce(0) { $0 + $1.byteCount }
        guard total > limit else { return }
        for (identifier, entry) in entries.sorted(
            by: { $0.value.lastAccess < $1.value.lastAccess }
        ) {
            removeCachedFile(named: entry.fileName)
            entries[identifier] = nil
            total -= entry.byteCount
            if total <= limit {
                break
            }
        }
    }

    private func encodedFileName(for identifier: String) -> String {
        Data(identifier.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
            + ".image"
    }

    private func persistIndex() {
        do {
            try JSONEncoder().encode(entries).write(
                to: indexURL,
                options: .atomic
            )
        } catch {
            Self.logger.error("Could not write artwork cache index")
        }
    }

    private func removeCachedFile(named fileName: String) {
        let fileURL = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            Self.logger.error("Could not remove cached artwork")
        }
    }
}

private actor ArtworkDownloadLimiter {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = max(limit, 1)
    }

    func acquire() async {
        guard availablePermits == 0 else {
            availablePermits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
protocol ArtworkLoading: AnyObject {
    func cachedImage(for key: ArtworkKey) -> PlatformImage?
    func image(
        for key: ArtworkKey,
        request: @escaping @MainActor () async -> URLRequest?
    ) async -> PlatformImage?
    func clear(serverID: String, userID: String) async
}

@MainActor
final class ArtworkRepository: ArtworkLoading {
    static let shared = ArtworkRepository()

    private static let logger = Logger(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "Artwork"
    )
    private static let performanceLog = OSLog(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "Performance"
    )

    private let memoryCache = NSCache<NSString, PlatformImage>()
    private let diskCache = ArtworkDiskCache()
    private let downloadLimiter = ArtworkDownloadLimiter(limit: 4)
    private let session: URLSession
    private var memoryKeys: [ArtworkKey: NSString] = [:]
    private var inFlight: [ArtworkKey: Task<PlatformImage?, Never>] = [:]
    private(set) var requestCounts: [ArtworkKey: Int] = [:]

    init(session: URLSession? = nil) {
        memoryCache.totalCostLimit = 16 * 1_024 * 1_024
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpMaximumConnectionsPerHost = 4
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func cachedImage(for key: ArtworkKey) -> PlatformImage? {
        memoryCache.object(forKey: key.identifier as NSString)
    }

    func image(
        for key: ArtworkKey,
        request: @escaping @MainActor () async -> URLRequest?
    ) async -> PlatformImage? {
        if let cached = cachedImage(for: key) {
            Self.logger.debug("Artwork memory cache hit")
            os_signpost(
                .event,
                log: Self.performanceLog,
                name: "Artwork Cache Hit"
            )
            return cached
        }
        if let existing = inFlight[key] {
            Self.logger.debug("Artwork request coalesced")
            return await existing.value
        }

        let task = Task<PlatformImage?, Never> { [weak self] in
            guard let self else { return nil }
            if let data = await diskCache.data(for: key),
                let decoded = Self.decode(data)
            {
                insert(decoded, for: key)
                Self.logger.debug("Artwork disk cache hit")
                os_signpost(
                    .event,
                    log: Self.performanceLog,
                    name: "Artwork Cache Hit"
                )
                return decoded
            }

            guard let urlRequest = await request() else { return nil }
            await downloadLimiter.acquire()
            defer {
                Task {
                    await self.downloadLimiter.release()
                }
            }
            requestCounts[key, default: 0] += 1
            Self.logger.debug("Artwork network request")
            os_signpost(
                .event,
                log: Self.performanceLog,
                name: "Artwork Request"
            )
            do {
                let (data, response) = try await session.data(for: urlRequest)
                guard
                    let response = response as? HTTPURLResponse,
                    (200...299).contains(response.statusCode),
                    let decoded = Self.decode(data)
                else {
                    return nil
                }
                await diskCache.store(data, for: key)
                insert(decoded, for: key)
                return decoded
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    func clear(serverID: String, userID: String) async {
        for (key, cacheKey) in memoryKeys
        where key.serverID == serverID && key.userID == userID {
            memoryCache.removeObject(forKey: cacheKey)
            memoryKeys[key] = nil
            inFlight[key]?.cancel()
            inFlight[key] = nil
        }
        await diskCache.clear(serverID: serverID, userID: userID)
    }

    private func insert(_ image: PlatformImage, for key: ArtworkKey) {
        let cacheKey = key.identifier as NSString
        let cost = max(Int(image.size.width * image.size.height * 4), 1)
        memoryCache.setObject(image, forKey: cacheKey, cost: cost)
        memoryKeys[key] = cacheKey
    }

    private static func decode(_ data: Data) -> PlatformImage? {
        #if os(iOS)
            UIImage(data: data)
        #elseif os(macOS)
            NSImage(data: data)
        #endif
    }
}

@MainActor
final class ArtworkViewLoader: ObservableObject {
    @Published private(set) var image: PlatformImage?
    @Published private(set) var isLoading = false

    private var key: ArtworkKey?

    func load(
        key newKey: ArtworkKey,
        repository: any ArtworkLoading = ArtworkRepository.shared,
        request: @escaping @MainActor () async -> URLRequest?
    ) async {
        if key != newKey {
            key = newKey
            image = repository.cachedImage(for: newKey)
        } else if image != nil {
            return
        }

        isLoading = image == nil
        let result = await repository.image(for: newKey, request: request)
        guard key == newKey else { return }
        if let result {
            image = result
        }
        isLoading = false
    }
}

struct PlaybackArtworkView: View {
    let item: PlaybackItem
    @ObservedObject var jellyfin: JellyfinSessionController
    var cornerRadius: CGFloat = 18
    var maxWidth = 1_200

    var body: some View {
        Group {
            if item.source == .jellyfin,
                let artworkItemID = item.artworkItemID
            {
                RemoteArtworkView(
                    itemID: artworkItemID,
                    imageTag: item.artworkTag,
                    jellyfin: jellyfin,
                    cornerRadius: cornerRadius,
                    maxWidth: maxWidth
                )
            } else {
                ArtworkPlaceholder(cornerRadius: cornerRadius)
            }
        }
    }
}

struct HomePlaybackArtwork: View {
    let item: PlaybackItem
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        Color.clear
            .aspectRatio(1.55, contentMode: .fit)
            .overlay {
                PlaybackArtworkView(item: item, jellyfin: jellyfin)
            }
            .clipShape(.rect(cornerRadius: 18))
            .contentShape(.rect(cornerRadius: 18))
    }
}

private struct RemoteArtworkView: View {
    let itemID: String
    let imageTag: String?
    @ObservedObject var jellyfin: JellyfinSessionController
    let cornerRadius: CGFloat
    let maxWidth: Int

    @StateObject private var loader = ArtworkViewLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                ArtworkPlaceholder(
                    cornerRadius: cornerRadius,
                    showsProgress: loader.isLoading
                )
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .contentShape(.rect(cornerRadius: cornerRadius))
        .task(id: taskID) {
            guard let key = artworkKey else { return }
            await loader.load(key: key) {
                await jellyfin.artworkRequest(
                    itemID: itemID,
                    imageTag: imageTag,
                    maxWidth: key.sizeBucket
                )
            }
        }
        .accessibilityHidden(true)
    }

    private var artworkKey: ArtworkKey? {
        guard let session = jellyfin.session else { return nil }
        return ArtworkKey(
            serverID: session.serverID,
            userID: session.userID,
            itemID: itemID,
            imageTag: imageTag ?? "no-tag",
            sizeBucket: ArtworkKey.sizeBucket(for: maxWidth)
        )
    }

    private var taskID: String {
        artworkKey?.identifier ?? "signed-out"
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
            self.init(uiImage: platformImage)
        #elseif os(macOS)
            self.init(nsImage: platformImage)
        #endif
    }
}

private struct ArtworkPlaceholder: View {
    let cornerRadius: CGFloat
    var showsProgress = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.velacantoAccent.opacity(0.48),
                    .indigo.opacity(0.30),
                    Color.velacantoAccent.opacity(0.24),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: cornerRadius))
    }
}
