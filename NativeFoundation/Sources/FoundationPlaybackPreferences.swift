import AVFoundation
import Combine
import Foundation

/// App-wide audio policies. System Settings writes the same scalar defaults.
@MainActor
final class FoundationPlaybackPreferences: ObservableObject {
    static let streamingCellularKey = "audio.streaming.allowCellular"
    static let downloadsCellularKey = "audio.downloads.allowCellular"
    @Published private(set) var allowsCellularStreaming: Bool
    @Published private(set) var allowsCellularDownloads: Bool
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Self.streamingCellularKey: true, Self.downloadsCellularKey: false,
        ])
        allowsCellularStreaming = defaults.bool(forKey: Self.streamingCellularKey)
        allowsCellularDownloads = defaults.bool(forKey: Self.downloadsCellularKey)
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
    }

    func setAllowsCellularStreaming(_ value: Bool) {
        defaults.set(value, forKey: Self.streamingCellularKey)
        refresh()
    }

    func setAllowsCellularDownloads(_ value: Bool) {
        defaults.set(value, forKey: Self.downloadsCellularKey)
        refresh()
    }

    func makePlayerItem(for url: URL) -> AVPlayerItem {
        guard !url.isFileURL else { return AVPlayerItem(url: url) }
        let asset = AVURLAsset(
            url: url, options: [AVURLAssetAllowsCellularAccessKey: allowsCellularStreaming])
        return AVPlayerItem(asset: asset)
    }
}
