import AVFoundation
import Combine
import Foundation

/// App-wide playback and library presentation preferences.
@MainActor
final class FoundationPlaybackPreferences: ObservableObject {
    static let streamingCellularKey = "audio.streaming.allowCellular"
    static let downloadsCellularKey = "audio.downloads.allowCellular"
    static let duplicateAlbumTracksKey = "library.showDuplicateAlbumTracks"
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

    func refresh() {
        let streaming = defaults.bool(forKey: Self.streamingCellularKey)
        let downloads = defaults.bool(forKey: Self.downloadsCellularKey)
        if streaming != allowsCellularStreaming { allowsCellularStreaming = streaming }
        if downloads != allowsCellularDownloads { allowsCellularDownloads = downloads }
        let duplicates = defaults.bool(forKey: Self.duplicateAlbumTracksKey)
        if duplicates != showDuplicateAlbumTracks { showDuplicateAlbumTracks = duplicates }
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
