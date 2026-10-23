import AVFoundation
import Combine
import Foundation

/// Immutable policy sampled once when preparing the next remote resource.
enum FoundationStreamingQuality: String, CaseIterable, Sendable {
    case original, auto, aac320, aac192, aac128

    var title: String {
        switch self {
        case .original: "Original"
        case .auto: "Auto"
        case .aac320: "High · 320 kbps"
        case .aac192: "Standard · 192 kbps"
        case .aac128: "Data Saver · 128 kbps"
        }
    }

    var aacBitrate: Int? {
        switch self {
        case .original: nil
        // Defensive ceiling if a caller supplies unresolved Auto without a path snapshot.
        case .auto: 192_000
        case .aac320: 320_000
        case .aac192: 192_000
        case .aac128: 128_000
        }
    }

    /// Auto is path-aware, not a throughput estimate or an adaptive HLS ladder.
    /// Unknown paths use the same conservative ceiling as costly connections.
    func resolved(for path: FoundationStreamingPath) -> Self {
        guard self == .auto else { return self }
        if path.isConstrained { return .aac128 }
        if path.isAvailable && path.usesWiFiOrWired && !path.usesCellular && !path.isExpensive {
            return .original
        }
        return .aac192
    }
}

/// A value copy of the existing account connectivity observation; it never gates requests.
struct FoundationStreamingPath: Equatable, Sendable {
    var isAvailable = false
    var usesWiFiOrWired = false
    var usesCellular = false
    var isExpensive = false
    var isConstrained = false
}

/// App-wide playback and library presentation preferences.
@MainActor
final class FoundationPlaybackPreferences: ObservableObject {
    // Retained only as a migration source and for downgrade compatibility.
    static let streamingQualityKey = "audio.streaming.quality"
    static let streamingWiFiQualityKey = "audio.streaming.wifiQuality"
    static let streamingCellularQualityKey = "audio.streaming.cellularQuality"
    static let streamingCellularKey = "audio.streaming.allowCellular"
    static let downloadQualityKey = "audio.downloads.quality"
    static let downloadsCellularKey = "audio.downloads.allowCellular"
    static let duplicateAlbumTracksKey = "library.showDuplicateAlbumTracks"
    @Published private(set) var streamingWiFiQuality: FoundationStreamingQuality
    @Published private(set) var streamingCellularQuality: FoundationStreamingQuality
    @Published private(set) var downloadQuality: FoundationDownloadQuality
    @Published private(set) var allowsCellularStreaming: Bool
    @Published private(set) var allowsCellularDownloads: Bool
    @Published private(set) var showDuplicateAlbumTracks: Bool
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Self.streamingCellularKey: true, Self.downloadsCellularKey: false,
            Self.duplicateAlbumTracksKey: false,
        ])
        Self.migrateStreamingProfiles(defaults)
        streamingWiFiQuality = Self.readStreamingQuality(
            defaults, key: Self.streamingWiFiQualityKey, fallback: .original)
        streamingCellularQuality = Self.readStreamingQuality(
            defaults, key: Self.streamingCellularQualityKey, fallback: .auto)
        downloadQuality =
            defaults.string(forKey: Self.downloadQualityKey)
            .flatMap(FoundationDownloadQuality.init(rawValue:)) ?? .original
        allowsCellularStreaming = defaults.bool(forKey: Self.streamingCellularKey)
        allowsCellularDownloads = defaults.bool(forKey: Self.downloadsCellularKey)
        showDuplicateAlbumTracks = defaults.bool(forKey: Self.duplicateAlbumTracksKey)
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private static func migrateStreamingProfiles(_ defaults: UserDefaults) {
        let legacy = FoundationStreamingQuality(
            rawValue: defaults.string(forKey: streamingQualityKey) ?? "")
        for (key, fallback) in [
            (streamingWiFiQualityKey, FoundationStreamingQuality.original),
            (streamingCellularQualityKey, FoundationStreamingQuality.auto),
        ] where defaults.object(forKey: key) == nil {
            defaults.set((legacy ?? fallback).rawValue, forKey: key)
        }
    }

    private static func readStreamingQuality(
        _ defaults: UserDefaults, key: String, fallback: FoundationStreamingQuality
    ) -> FoundationStreamingQuality {
        FoundationStreamingQuality(rawValue: defaults.string(forKey: key) ?? "") ?? fallback
    }

    func resolvedStreamingQuality(for path: FoundationStreamingPath) -> FoundationStreamingQuality {
        #if os(macOS)
            return .original
        #else
            return resolvedStreamingProfile(for: path)
        #endif
    }

    func resolvedStreamingProfile(for path: FoundationStreamingPath) -> FoundationStreamingQuality {
        // Mixed and unknown paths use the cellular profile, without probing network speed.
        let usesWiFiProfile = path.isAvailable && path.usesWiFiOrWired && !path.usesCellular
        let quality = usesWiFiProfile ? streamingWiFiQuality : streamingCellularQuality
        return quality.resolved(for: path)
    }

    func setStreamingWiFiQuality(_ value: FoundationStreamingQuality) {
        defaults.set(value.rawValue, forKey: Self.streamingWiFiQualityKey)
        refresh()
    }

    func setStreamingCellularQuality(_ value: FoundationStreamingQuality) {
        defaults.set(value.rawValue, forKey: Self.streamingCellularQualityKey)
        refresh()
    }

    func refresh() {
        let wifi = Self.readStreamingQuality(
            defaults, key: Self.streamingWiFiQualityKey, fallback: .original)
        let cellular = Self.readStreamingQuality(
            defaults, key: Self.streamingCellularQualityKey, fallback: .auto)
        if wifi != streamingWiFiQuality { streamingWiFiQuality = wifi }
        if cellular != streamingCellularQuality { streamingCellularQuality = cellular }
        let quality =
            defaults.string(forKey: Self.downloadQualityKey)
            .flatMap(FoundationDownloadQuality.init(rawValue:)) ?? .original
        if quality != downloadQuality { downloadQuality = quality }
        let streaming = defaults.bool(forKey: Self.streamingCellularKey)
        let downloads = defaults.bool(forKey: Self.downloadsCellularKey)
        if streaming != allowsCellularStreaming { allowsCellularStreaming = streaming }
        if downloads != allowsCellularDownloads { allowsCellularDownloads = downloads }
        let duplicates = defaults.bool(forKey: Self.duplicateAlbumTracksKey)
        if duplicates != showDuplicateAlbumTracks { showDuplicateAlbumTracks = duplicates }
    }

    func setDownloadQuality(_ value: FoundationDownloadQuality) {
        defaults.set(value.rawValue, forKey: Self.downloadQualityKey)
        refresh()
    }

    func setAllowsCellularStreaming(_ value: Bool) {
        defaults.set(value, forKey: Self.streamingCellularKey)
        refresh()
    }

    func setAllowsCellularDownloads(_ value: Bool) {
        defaults.set(value, forKey: Self.downloadsCellularKey)
        refresh()
    }

    func setShowDuplicateAlbumTracks(_ value: Bool) {
        defaults.set(value, forKey: Self.duplicateAlbumTracksKey)
        refresh()
    }

    func makePlayerItem(for url: URL) -> AVPlayerItem {
        guard !url.isFileURL else { return AVPlayerItem(url: url) }
        let asset = AVURLAsset(
            url: url, options: [AVURLAssetAllowsCellularAccessKey: allowsCellularStreaming])
        return AVPlayerItem(asset: asset)
    }
}
