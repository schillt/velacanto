#if DEBUG
    import Foundation
    import SwiftUI

    /// Internal diagnostics. Callers supply categories and ephemeral IDs only.
    final class FoundationJournal: @unchecked Sendable {
        static let shared = FoundationJournal()
        private let lock = NSLock()
        private let maximumBytes = 1_048_576
        private let file: URL
        private var enabled = true

        init(file: URL? = nil) {
            let directory =
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            self.file = file ?? directory.appendingPathComponent("foundation-journal.log")
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        var isEnabled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return enabled
        }

        func setEnabled(_ enabled: Bool) {
            lock.lock()
            defer { lock.unlock() }
            self.enabled = enabled
        }

        func record(_ event: String) {
            lock.lock()
            defer { lock.unlock() }
            guard enabled else { return }
            let line =
                "time=\(Date().timeIntervalSince1970) \(event.replacingOccurrences(of: "\n", with: " "))\n"
            guard let data = line.data(using: .utf8), data.count < maximumBytes else { return }
            if !FileManager.default.fileExists(atPath: file.path) {
                _ = FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            do {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                if size + UInt64(data.count) > UInt64(maximumBytes) {
                    var retained = ((try? Data(contentsOf: file)) ?? Data()).suffix(
                        maximumBytes / 2)
                    if let newline = retained.firstIndex(of: 10) {
                        retained = retained.suffix(from: retained.index(after: newline))
                    }
                    try handle.truncate(atOffset: 0)
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: retained)
                }
                try handle.write(contentsOf: data)
            } catch {
                // Logging errors do not change playback or request outcomes.
            }

        }

        func snapshot() -> String {
            lock.lock()
            defer { lock.unlock() }
            return (try? String(contentsOf: file, encoding: .utf8)) ?? "No events recorded."
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            try? FileManager.default.removeItem(at: file)
        }
    }

    enum FoundationTraceOrigin: String, Sendable { case library, home, new, search, nowPlaying }
    enum FoundationTracePage: String, Sendable {
        case catalog, tracks, shelf, genreIndex, artwork, nowPlayingArtwork
    }

    enum FoundationTrace {
        struct Context: Sendable {
            let origin: FoundationTraceOrigin
            let page: FoundationTracePage
            let owner = UUID().uuidString
            var fields: String { "origin=\(origin.rawValue) page=\(page.rawValue) owner=\(owner)" }
        }
        @TaskLocal static var context: Context?
        static var fields: String { context?.fields ?? "origin=unscoped page=unscoped owner=none" }
        static func event(_ message: String) { FoundationJournal.shared.record(message) }

        @MainActor
        static func withPage(
            origin: FoundationTraceOrigin, page: FoundationTracePage,
            operation: () async -> Void
        ) async {
            let context = Context(origin: origin, page: page)
            await $context.withValue(context) {
                event("page event=taskStarted " + context.fields)
                await withTaskCancellationHandler {
                    await operation()
                    event(
                        "page event=taskReturned cancelled=\(Task.isCancelled ? 1 : 0) "
                            + context.fields)
                } onCancel: {
                    event("page event=cancellationRequested " + context.fields)
                }
            }
        }
    }

    private struct FoundationTraceOriginKey: EnvironmentKey {
        static let defaultValue = FoundationTraceOrigin.library
    }
    extension EnvironmentValues {
        var foundationTraceOrigin: FoundationTraceOrigin {
            get { self[FoundationTraceOriginKey.self] }
            set { self[FoundationTraceOriginKey.self] = newValue }
        }
    }
#endif
