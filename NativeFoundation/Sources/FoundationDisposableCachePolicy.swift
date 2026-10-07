import Foundation

/// Runs before account cache owners exist. Retained music and artwork live outside these roots.
actor FoundationDisposableCachePolicy {
    static let shared = FoundationDisposableCachePolicy()
    static let schema = "catalog-artwork-2"
    static var currentVersion: String {
        let bundle = Bundle.main
        return
            "\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")-\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")-\(schema)"
    }

    func prepare(version: String, cachesRoot: URL? = nil) -> Bool {
        let manager = FileManager.default
        let root = cachesRoot ?? manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let markerDirectory = root.appendingPathComponent("VelacantoDisposableCacheGeneration")
        let marker = markerDirectory.appendingPathComponent("generation")
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
            else { return false }
            try manager.createDirectory(
                at: markerDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard
                try markerDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
                    != true
            else { return false }
            if manager.fileExists(atPath: marker.path) {
                guard
                    try marker.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
                else { return false }
                if (try? String(contentsOf: marker, encoding: .utf8)) == version { return true }
            }
            // Delete only the two named disposable directories. Never traverse a download root.
            for name in ["VelacantoArtwork", "VelacantoCatalogPages"] {
                let directory = root.appendingPathComponent(name)
                if manager.fileExists(atPath: directory.path) {
                    try manager.removeItem(at: directory)
                }
            }
            var excluded = markerDirectory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            try Data(version.utf8).write(to: marker, options: .atomic)
            return true
        } catch { return false }
    }
}
