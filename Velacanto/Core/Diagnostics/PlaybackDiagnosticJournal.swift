import Foundation

/// A small privacy-safe journal for diagnosing playback across process exits.
///
/// Callers must record categories, counts, revisions, booleans, and
/// correlation UUIDs only; provider IDs, media metadata, accounts, hosts, and
/// URLs are prohibited.
final class PlaybackDiagnosticJournal: @unchecked Sendable {
    static let shared = PlaybackDiagnosticJournal()
    static let recordingEnabledDefaultsKey = "playbackDiagnosticJournalEnabled"
    static let defaultRecordingEnabled = false

    private let lock = NSLock()
    private let fileURL: URL
    private let maximumByteCount: Int
    private let launchID = UUID().uuidString
    private let recordingEnabledOverride: Bool?

    init(
        fileURL: URL? = nil,
        maximumByteCount: Int = 64 * 1_024,
        fileManager: FileManager = .default,
        recordingEnabled: Bool? = nil
    ) {
        recordingEnabledOverride = recordingEnabled ?? (fileURL == nil ? nil : true)
        self.maximumByteCount = max(maximumByteCount, 1_024)
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory =
                fileManager.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first?
                .appending(
                    path: "VelacantoDiagnostics",
                    directoryHint: .isDirectory
                )
                ?? fileManager.temporaryDirectory.appending(
                    path: "VelacantoDiagnostics",
                    directoryHint: .isDirectory
                )
            try? fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            self.fileURL = directory.appending(
                path: "playback-journal.log",
                directoryHint: .notDirectory
            )
        }
    }

    func beginLaunch() {
        guard isRecordingEnabled else { return }
        record("process phase=started")
    }

    func record(_ event: @autoclosure () -> String) {
        guard isRecordingEnabled else { return }
        let eventValue = event()
        guard !eventValue.isEmpty else { return }
        let safeEvent =
            eventValue
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "?", with: "-")
            .replacingOccurrences(of: "&", with: "-")
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let line = "time_ms=\(timestamp) launch=\(launchID) \(safeEvent)\n"
        guard let lineData = line.data(using: .utf8) else { return }

        lock.withLock {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                _ = FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: nil
                )
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                return
            }
            defer { try? handle.close() }
            let previousByteCount = (try? handle.seekToEnd()) ?? 0
            try? handle.write(contentsOf: lineData)
            guard previousByteCount + UInt64(lineData.count) > maximumByteCount
            else {
                return
            }

            var data = (try? Data(contentsOf: fileURL)) ?? Data()
            data = Data(data.suffix(maximumByteCount))
            if let newline = data.firstIndex(of: 0x0A),
                newline < data.endIndex
            {
                data = Data(data[data.index(after: newline)...])
            }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func entries(limit: Int) -> [String] {
        guard isRecordingEnabled else { return [] }
        guard limit > 0 else { return [] }
        return lock.withLock {
            guard
                let data = try? Data(contentsOf: fileURL),
                let contents = String(data: data, encoding: .utf8)
            else {
                return []
            }
            return Array(
                contents.split(separator: "\n", omittingEmptySubsequences: true)
                    .suffix(limit)
                    .map(String.init)
            )
        }
    }

    private var isRecordingEnabled: Bool {
        recordingEnabledOverride
            ?? (UserDefaults.standard.object(forKey: Self.recordingEnabledDefaultsKey)
                as? Bool
                ?? Self.defaultRecordingEnabled)
    }
}
