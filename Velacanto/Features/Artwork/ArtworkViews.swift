import ImageIO
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

enum ArtworkLoadIntent: Int, Sendable {
    case speculative
    case nearViewport
    case visible

    var taskPriority: TaskPriority {
        switch self {
        case .visible: .userInitiated
        case .nearViewport: .utility
        case .speculative: .background
        }
    }

    var networkPriority: VelacantoNetworkPriority {
        switch self {
        case .visible: .artwork
        case .nearViewport, .speculative: .speculative
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
    private var indexPersistenceTask: Task<Void, Never>?

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
            scheduleIndexPersistence()
            Self.logger.error("Could not read cached artwork")
            return nil
        }
        entry.lastAccess = Date()
        entries[key.identifier] = entry
        scheduleIndexPersistence()
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
            scheduleIndexPersistence()
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
        scheduleIndexPersistence()
    }

    func flushIndexPersistence() {
        indexPersistenceTask?.cancel()
        indexPersistenceTask = nil
        persistIndex()
    }

    func hasPendingIndexPersistence() -> Bool {
        indexPersistenceTask != nil
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
        indexPersistenceTask = nil
        do {
            try JSONEncoder().encode(entries).write(
                to: indexURL,
                options: .atomic
            )
        } catch {
            Self.logger.error("Could not write artwork cache index")
        }
    }

    private func scheduleIndexPersistence() {
        indexPersistenceTask?.cancel()
        indexPersistenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.persistIndex()
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

protocol ArtworkLoading: AnyObject, Sendable {
    func cachedImage(for key: ArtworkKey) async -> PlatformImage?
    func image(
        for key: ArtworkKey,
        request: @escaping @MainActor @Sendable () async -> URLRequest?
    ) async -> PlatformImage?
    func clear(serverID: String, userID: String) async
}

actor ArtworkRepository: ArtworkLoading {
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
    private let fixedSession: URLSession?
    private let fixedTransport: VelacantoNetworkTransport?
    private var networkSuppressedUntil: Date?
    private var memoryKeys: [ArtworkKey: NSString] = [:]
    private struct InFlight {
        let task: Task<PlatformImage?, Never>
        var consumers: Set<UUID>
    }

    private var inFlight: [ArtworkKey: InFlight] = [:]
    private(set) var requestCounts: [ArtworkKey: Int] = [:]

    init(
        session: URLSession? = nil,
        transport: VelacantoNetworkTransport? = nil
    ) {
        memoryCache.totalCostLimit = 16 * 1_024 * 1_024
        fixedSession = session
        fixedTransport = transport
    }

    func cachedImage(for key: ArtworkKey) -> PlatformImage? {
        memoryCache.object(forKey: key.identifier as NSString)
    }

    func image(
        for key: ArtworkKey,
        request: @escaping @MainActor @Sendable () async -> URLRequest?
    ) async -> PlatformImage? {
        await image(for: key, intent: .visible, request: request)
    }

    func image(
        for key: ArtworkKey,
        intent: ArtworkLoadIntent,
        request: @escaping @MainActor @Sendable () async -> URLRequest?
    ) async -> PlatformImage? {
        if intent == .visible {
            os_signpost(.event, log: Self.performanceLog, name: "Visible Artwork Requested")
        }
        if let cached = cachedImage(for: key) {
            Self.logger.debug("Artwork memory cache hit")
            os_signpost(
                .event,
                log: Self.performanceLog,
                name: "Artwork Cache Hit"
            )
            if intent == .visible {
                os_signpost(.event, log: Self.performanceLog, name: "Visible Artwork Ready")
            }
            return cached
        }
        let consumer = UUID()
        let task: Task<PlatformImage?, Never>
        if var existing = inFlight[key] {
            Self.logger.debug("Artwork request coalesced")
            VelacantoNetworkPolicy.shared.promote(
                key: key.identifier,
                to: intent.networkPriority
            )
            existing.consumers.insert(consumer)
            inFlight[key] = existing
            task = existing.task
        } else {
            task = Task(priority: intent.taskPriority) { [weak self] in
                await self?.load(key: key, intent: intent, request: request)
            }
            inFlight[key] = InFlight(task: task, consumers: [consumer])
        }

        return await withTaskCancellationHandler {
            let image = await task.value
            releaseConsumer(consumer, for: key)
            if intent == .visible, image != nil {
                os_signpost(.event, log: Self.performanceLog, name: "Visible Artwork Ready")
            }
            return image
        } onCancel: {
            Task { await self.releaseConsumer(consumer, for: key) }
        }
    }

    func clear(serverID: String, userID: String) async {
        for (key, cacheKey) in memoryKeys
        where key.serverID == serverID && key.userID == userID {
            memoryCache.removeObject(forKey: cacheKey)
            memoryKeys[key] = nil
            inFlight[key]?.task.cancel()
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

    private func releaseConsumer(_ consumer: UUID, for key: ArtworkKey) {
        guard var request = inFlight[key], request.consumers.remove(consumer) != nil else {
            return
        }
        if request.consumers.isEmpty {
            os_signpost(.event, log: Self.performanceLog, name: "Artwork Cancelled")
            request.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = request
        }
    }

    func consumerCount(for key: ArtworkKey) -> Int {
        inFlight[key]?.consumers.count ?? 0
    }

    private func load(
        key: ArtworkKey,
        intent: ArtworkLoadIntent,
        request: @escaping @MainActor @Sendable () async -> URLRequest?
    ) async -> PlatformImage? {
        if let data = await diskCache.data(for: key),
            let decoded = Self.decode(data, maximumPixelSize: key.sizeBucket)
        {
            insert(decoded, for: key)
            Self.logger.debug("Artwork disk cache hit")
            os_signpost(.event, log: Self.performanceLog, name: "Artwork Cache Hit")
            return decoded
        }

        guard !isNetworkSuppressed else {
            Self.logger.debug("Artwork network request suppressed-after-failure")
            return nil
        }

        guard !Task.isCancelled, var urlRequest = await request() else { return nil }
        urlRequest.timeoutInterval = intent == .visible ? 5 : 4
        urlRequest.networkServiceType = intent == .visible ? .responsiveData : .background
        guard !Task.isCancelled, !isNetworkSuppressed else { return nil }
        let networkRequest = urlRequest
        requestCounts[key, default: 0] += 1
        Self.logger.debug(
            "Artwork network request intent=\(intent.rawValue, privacy: .public)"
        )
        os_signpost(
            .event,
            log: Self.performanceLog,
            name: "Artwork Request"
        )
        do {
            guard let requestURL = networkRequest.url else { return nil }
            let artworkTransport =
                fixedTransport
                ?? (fixedSession == nil
                    ? VelacantoNetworkTransportRegistry.shared.transport(
                        for: requestURL
                    ) : nil)
            let (data, response) = try await VelacantoNetworkPolicy.shared.perform(
                priority: intent.networkPriority,
                key: key.identifier
            ) { @Sendable () async throws -> (Data, URLResponse) in
                guard await self.canStartAdmittedNetworkRequest() else {
                    throw CancellationError()
                }
                if let fixedSession = self.fixedSession {
                    return try await fixedSession.data(for: networkRequest)
                }
                guard let artworkTransport else {
                    throw CancellationError()
                }
                // Artwork owns a short local cooldown, but it must never set
                // or clear the origin breaker used by playback negotiation.
                return try await artworkTransport.data(
                    for: networkRequest,
                    monitorsRouteHealth: false
                )
            }
            guard
                !Task.isCancelled,
                let response = response as? HTTPURLResponse,
                (200...299).contains(response.statusCode),
                let decoded = Self.decode(data, maximumPixelSize: key.sizeBucket)
            else { return nil }
            await diskCache.store(data, for: key)
            insert(decoded, for: key)
            networkSuppressedUntil = nil
            return decoded
        } catch let failure as VelacantoNetworkTransportFailure {
            guard let error = failure.underlying as? URLError else {
                return nil
            }
            return handleNetworkFailure(error)
        } catch is VelacantoNetworkTransportSuppressed {
            return nil
        } catch let error as URLError {
            return handleNetworkFailure(error)
        } catch {
            return nil
        }
    }

    private func handleNetworkFailure(_ error: URLError) -> PlatformImage? {
        guard
            Self.isTransient(error)
                || Self.isTransportSecurityError(error)
        else { return nil }
        networkSuppressedUntil = Date().addingTimeInterval(5)
        let code = error.code.rawValue
        Self.logger.error(
            "Artwork network failure code=\(code, privacy: .public)"
        )
        return nil
    }

    private var isNetworkSuppressed: Bool {
        guard let networkSuppressedUntil else { return false }
        return networkSuppressedUntil > Date()
    }

    private func canStartAdmittedNetworkRequest() -> Bool {
        !isNetworkSuppressed
    }

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .timedOut:
            true
        default:
            false
        }
    }

    private static func isTransportSecurityError(_ error: URLError) -> Bool {
        switch error.code {
        case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
            .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired:
            true
        default:
            false
        }
    }

    private static func decode(
        _ data: Data,
        maximumPixelSize: Int
    ) -> PlatformImage? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: false,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                ] as CFDictionary
            )
        else { return nil }
        #if os(iOS)
            return UIImage(cgImage: image)
        #elseif os(macOS)
            return NSImage(cgImage: image, size: .zero)
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
        request: @escaping @MainActor @Sendable () async -> URLRequest?
    ) async {
        if key != newKey {
            key = newKey
            image = await repository.cachedImage(for: newKey)
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
