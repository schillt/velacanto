import Foundation

/// Disposable account-scoped catalog metadata, independent of downloaded media storage.
actor FoundationCatalogPageCache {
    struct Limits: Sendable {
        var diskBytes = 2 * 1_024 * 1_024
        var pages = 32
        var itemsPerPage = 200
        var entryBytes = 256 * 1_024
        var retention: TimeInterval = 7 * 24 * 60 * 60
    }
    struct Record: Codable, Sendable {
        let page: FoundationPage
        let savedAt: Date
    }
    nonisolated let scope: String
    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VelacantoCatalogPages", isDirectory: true)
    }
    private let directory: URL
    private let limits: Limits
    private let now: @Sendable () -> Date
    private var live = true
    private let lease: UUID
    private let registration: Task<Void, Never>

    init(
        scope: String, root: URL? = nil, limits: Limits = Limits(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scope = FoundationArtworkCache.digest(scope)
        directory = (root ?? Self.defaultRoot).appendingPathComponent(self.scope, isDirectory: true)
        self.limits = limits
        self.now = now
        let lease = UUID()
        self.lease = lease
        let directory = self.directory
        registration = Task {
            await FoundationPageDirectoryOwner.shared.protect(directory, lease: lease)
        }
    }

    deinit {
        let directory = directory
        let lease = lease
        let registration = registration
        Task {
            await registration.value
            _ = await FoundationPageDirectoryOwner.shared.release(
                directory, lease: lease, removeDisk: false)
        }
    }

    private func prepare() throws {
        let manager = FileManager.default
        let root = directory.deletingLastPathComponent()
        for folder in [root, directory] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
            else { throw FoundationLibraryError.unavailable }
            var url = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }

    private func file(_ key: String) -> URL {
        directory.appendingPathComponent(FoundationArtworkCache.digest(key) + ".page")
    }

    func read(_ key: String) async -> Record? {
        await registration.value
        guard live, !Task.isCancelled, (try? prepare()) != nil else { return nil }
        let url = file(key)
        guard
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ]), values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size <= max(0, limits.entryBytes),
            let data = try? Data(contentsOf: url),
            let record = try? PropertyListDecoder().decode(Record.self, from: data),
            record.page.items.count <= max(0, limits.itemsPerPage),
            record.savedAt <= now(), now().timeIntervalSince(record.savedAt) < limits.retention,
            record.page.nextStartIndex.map({ $0 >= record.page.items.count }) ?? true
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        trim()
        return record
    }

    func write(_ page: FoundationPage, key: String, permit: FoundationPageWritePermit? = nil) async
    {
        await registration.value
        if let permit {
            permit.ifValid { writeNow(page, key: key) }
        } else {
            writeNow(page, key: key)
        }
    }

    private func writeNow(_ page: FoundationPage, key: String) {
        guard live, !Task.isCancelled, limits.pages > 0, limits.diskBytes > 0,
            page.items.count <= max(0, limits.itemsPerPage), (try? prepare()) != nil
        else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(Record(page: page, savedAt: now())),
            data.count <= limits.entryBytes, data.count <= limits.diskBytes, !Task.isCancelled
        else { return }
        let url = file(key)
        do {
            #if os(iOS)
                try data.write(
                    to: url,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
                try data.write(to: url, options: .atomic)
            #endif
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            trim()
        } catch { try? FileManager.default.removeItem(at: url) }
    }

    func invalidate(removeDisk: Bool = true) async -> Bool {
        live = false
        await registration.value
        return await FoundationPageDirectoryOwner.shared.release(
            directory, lease: lease, removeDisk: removeDisk)
    }

    nonisolated static func clearStoredPages(retaining scope: String? = nil, root: URL? = nil) async
        -> Bool
    {
        await FoundationPageDirectoryOwner.shared.clear(root: root ?? defaultRoot, retaining: scope)
    }

    /// Physical bytes for this account's disposable page files; never creates or trims storage.
    func storageBytes() async -> Int64? {
        await registration.value
        guard live else { return nil }
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return 0 }
        do {
            guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
            else { return nil }
            let urls = try manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            var bytes: Int64 = 0
            for url in urls where url.pathExtension == "page" {
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                    let size = values.fileSize
                else { return nil }
                bytes += Int64(size)
            }
            return bytes
        } catch { return nil }
    }

    private func trim() {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                    .contentModificationDateKey,
                ])) ?? []
        var entries: [(URL, Int, Date)] = []
        for url in urls where url.pathExtension == "page" {
            guard
                let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                    .contentModificationDateKey,
                ]), values.isRegularFile == true, values.isSymbolicLink != true,
                let size = values.fileSize, size <= max(0, limits.entryBytes),
                let date = values.contentModificationDate,
                now().timeIntervalSince(date) < limits.retention
            else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            entries.append((url, size, date))
        }
        entries.sort { $0.2 < $1.2 }
        var bytes = entries.reduce(0) { $0 + $1.1 }
        var count = entries.count
        for (url, size, _) in entries
        where bytes > max(0, limits.diskBytes) || count > max(0, limits.pages) {
            try? FileManager.default.removeItem(at: url)
            bytes -= size
            count -= 1
        }
    }
}

/// Startup/sign-out cleanup cannot remove a directory leased by a newly opened account.
private actor FoundationPageDirectoryOwner {
    static let shared = FoundationPageDirectoryOwner()
    private var leases: [String: Set<UUID>] = [:]

    private func identity(_ directory: URL) -> String {
        directory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func protect(_ directory: URL, lease: UUID) {
        leases[identity(directory), default: []].insert(lease)
    }

    func release(_ directory: URL, lease: UUID, removeDisk: Bool) -> Bool {
        let key = identity(directory)
        leases[key]?.remove(lease)
        if leases[key]?.isEmpty == true { leases.removeValue(forKey: key) }
        guard removeDisk, leases[key] == nil else { return true }
        return remove(directory)
    }

    private func remove(_ directory: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return true }
        do {
            try FileManager.default.removeItem(at: directory)
            return true
        } catch { return false }
    }

    func clear(root: URL, retaining scope: String?) -> Bool {
        guard FileManager.default.fileExists(atPath: root.path) else { return true }
        do {
            guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
            else { return false }
            let urls = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
            var success = true
            for url in urls where url.lastPathComponent != scope {
                let name = url.lastPathComponent
                guard name.count == 64, name.allSatisfy({ $0.isHexDigit }),
                    leases[identity(url)] == nil,
                    try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
                else { continue }
                if !remove(url) { success = false }
            }
            return success
        } catch { return false }
    }
}

/// A superseded model owner revokes disk publication synchronously, across actor hops.
final class FoundationPageWritePermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.withLock { valid } }
    func revoke() { lock.withLock { valid = false } }
    func ifValid(_ body: () -> Void) {
        lock.withLock { if valid { body() } }
    }
}
