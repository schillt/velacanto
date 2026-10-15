import CryptoKit
import Foundation

/// Account-owned optional artwork reuse. This owner never resolves or schedules audio.
actor FoundationArtworkCache {
    struct Limits: Sendable {
        var memoryBytes = 16 * 1_024 * 1_024
        var diskBytes = 64 * 1_024 * 1_024
        var concurrentLoads = 4
        var pendingKeys = 128
    }
    struct Key: Hashable, Sendable {
        let identity: String
        let pixels: Int
    }
    private struct Entry {
        let result: FoundationCurrentArtwork.Result
        let expiry: Date
        var access: UInt
        var cost: Int { result.data.count + result.image.bytesPerRow * result.image.height }
    }
    private struct Job {
        let id = UUID()
        let item: FoundationItem
        let load: @Sendable (FoundationItem, Int) async throws -> Data?
        var waiters: [UUID: CheckedContinuation<FoundationCurrentArtwork.Result?, Error>]
        var task: Task<Void, Never>?
        var playback = false
    }
    nonisolated let scope: String
    private let now: @Sendable () -> Date
    private let limits: Limits
    private let disk: FoundationArtworkDisk
    private let networkAdmission: FoundationNetworkAdmission?
    private var protectedWorkers: Set<UUID> = []
    private var entries: [Key: Entry] = [:]
    private var failures: [Key: Date] = [:]
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var jobs: [Key: Job] = [:]
    private var persisting: Set<UUID> = []
    private var pendingImages:
        [Key: (id: UUID, image: FoundationCurrentArtwork.Result, expiry: Date)] = [:]
    #if DEBUG
        private var persistenceBarrier: (@Sendable () async -> Void)?

        func setPersistenceBarrier(_ barrier: @escaping @Sendable () async -> Void) {
            persistenceBarrier = barrier
        }

        private func waitBeforePersistence() async { await persistenceBarrier?() }
    #endif
    private var queue: [Key] = []
    private var revisions: [String: Revision] = [:]
    private struct Revision {
        let identity: String
        let tag: String
        let expiry: Date
    }
    private struct PreviewJob {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<FoundationCurrentArtwork.Result?, Error>]
    }
    private var previews: [Key: PreviewJob] = [:]
    private var clock: UInt = 0
    private var live = true
    private var active = 0

    init(
        scope: String, root: URL? = nil, limits: Limits = Limits(),
        networkAdmission: FoundationNetworkAdmission? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        self.networkAdmission = networkAdmission
        self.scope = Self.digest(scope)
        self.limits = limits
        let root =
            root
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VelacantoArtwork", isDirectory: true)
        disk = FoundationArtworkDisk(
            directory: root.appendingPathComponent(Self.digest(scope), isDirectory: true),
            limit: max(0, limits.diskBytes), now: now)
    }

    deinit {
        for task in activeTasks.values { task.cancel() }
        for job in previews.values { job.task.cancel() }
        let disk = disk
        Task { _ = await disk.invalidate(removeFiles: false) }
    }

    nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func key(_ item: FoundationItem, pixels: Int) -> Key {
        let item = item.catalogArtworkItem
        return Key(
            identity: digest("\(item.artworkCacheBase)\0\(item.primaryImageTag ?? "")"),
            pixels: pixels <= 160 ? 160 : (pixels <= 640 ? 640 : (pixels <= 1280 ? 1280 : 2048)))
    }

    /// Completed loads accept only equal/larger renditions; previews may include smaller ones.
    nonisolated static func renditionCandidates(_ key: Key, allowsSmaller: Bool) -> [Key] {
        [key]
            + [2048, 1280, 640, 160].filter {
                $0 != key.pixels && ($0 > key.pixels || allowsSmaller)
            }.map { Key(identity: key.identity, pixels: $0) }
    }

    /// Missing tags mean unknown revision, not a new revision. Explicit tags never alias.
    private func resolvedArtwork(_ item: FoundationItem, pixels: Int) async
        -> (key: Key, item: FoundationItem)
    {
        let key = Self.key(item, pixels: pixels)
        let base = Self.digest(item.artworkCacheBase)
        revisions = revisions.filter { $0.value.expiry > now() }
        if let tag = item.primaryImageTag, !tag.isEmpty {
            if let revision = revisions[base], revision.identity == key.identity {
                return (key, item)
            }
            if tag.utf8.count > 256 { return (key, item) }
            let expiry = now().addingTimeInterval(30 * 86_400)
            revisions[base] = Revision(identity: key.identity, tag: tag, expiry: expiry)
            if revisions.count > max(1, limits.pendingKeys),
                let oldest = revisions.min(by: { $0.value.expiry < $1.value.expiry })?.key
            {
                revisions.removeValue(forKey: oldest)
            }
            await disk.rememberRevision(
                base: base, identity: key.identity, tag: tag, expiry: expiry)
            return (key, item)
        }
        if let revision = revisions[base] {
            var canonical = item
            canonical.primaryImageTag = revision.tag
            return (Key(identity: revision.identity, pixels: key.pixels), canonical)
        }
        if let revision = await disk.revision(base: base) {
            var canonical = item
            canonical.primaryImageTag = revision.tag
            guard Self.key(canonical, pixels: pixels).identity == revision.identity else {
                return (key, item)
            }
            return (Key(identity: revision.identity, pixels: key.pixels), canonical)
        }
        return (key, item)
    }

    /// Local preview may use a smaller rendition while the caller owns a bounded upgrade.
    func cachedResult(for item: FoundationItem, pixels: Int) async throws
        -> FoundationCurrentArtwork.Result?
    {
        try Task.checkCancellation()
        guard live else { throw CancellationError() }
        let key = await resolvedArtwork(item.catalogArtworkItem, pixels: pixels).key
        try Task.checkCancellation()
        guard live else { throw CancellationError() }
        for candidate in Self.renditionCandidates(key, allowsSmaller: true) {
            if var entry = entries[candidate], entry.expiry > now() {
                clock &+= 1
                entry.access = clock
                entries[candidate] = entry
                return entry.result
            }
        }
        for candidate in Self.renditionCandidates(key, allowsSmaller: true) {
            if let pending = pendingImages[candidate], pending.expiry > now() {
                return pending.image
            }
        }
        guard previews[key] != nil || previews.count < max(1, limits.pendingKeys) else {
            return nil
        }
        let waiter = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if var job = previews[key] {
                    job.waiters[waiter] = continuation
                    previews[key] = job
                } else {
                    let id = UUID()
                    let disk = disk
                    let task = Task.detached(priority: .utility) { [weak self] in
                        let record = await disk.read(key, allowsSmaller: true)
                        let decoded =
                            Task.isCancelled
                            ? nil
                            : record.flatMap {
                                FoundationCurrentArtwork.decode(
                                    $0.data, maximumPixels: $0.key.pixels)
                            }
                        await self?.finishPreview(key: key, id: id, record: record, result: decoded)
                    }
                    previews[key] = PreviewJob(
                        id: id, task: task, waiters: [waiter: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancelPreview(key: key, waiter: waiter) }
        }
        try Task.checkCancellation()
        return result
    }

    private func finishPreview(
        key: Key, id: UUID, record: FoundationArtworkDisk.CachedRecord?,
        result: FoundationCurrentArtwork.Result?
    ) {
        guard let job = previews[key], job.id == id else { return }
        previews.removeValue(forKey: key)
        if live, let record, let result {
            remember(result, key: record.key, expiry: record.record.expiry)
        }
        for waiter in job.waiters.values {
            if live {
                waiter.resume(returning: result)
            } else {
                waiter.resume(throwing: CancellationError())
            }
        }
    }

    private func cancelPreview(key: Key, waiter: UUID) {
        guard var job = previews[key], let continuation = job.waiters.removeValue(forKey: waiter)
        else { return }
        continuation.resume(throwing: CancellationError())
        if job.waiters.isEmpty {
            job.task.cancel()
            previews.removeValue(forKey: key)
        } else {
            previews[key] = job
        }
    }

    /// Only an explicit user retry bypasses negative caching for this artwork identity.
    func clearFailures(for item: FoundationItem) async {
        let key = await resolvedArtwork(item.catalogArtworkItem, pixels: 640).key
        failures = failures.filter { $0.key.identity != key.identity }
    }

    func result(
        for item: FoundationItem, pixels: Int, allowsNetwork: Bool,
        load: @escaping @Sendable (FoundationItem, Int) async throws -> Data?
    ) async throws -> FoundationCurrentArtwork.Result? {
        try Task.checkCancellation()
        guard live else { throw CancellationError() }
        let resolved = await resolvedArtwork(item.catalogArtworkItem, pixels: pixels)
        let item = resolved.item
        let key = resolved.key
        try Task.checkCancellation()
        guard live else { throw CancellationError() }
        let now = now()
        for candidate in Self.renditionCandidates(key, allowsSmaller: false) {
            if var entry = entries[candidate], entry.expiry > now {
                clock &+= 1
                entry.access = clock
                entries[candidate] = entry
                return entry.result
            }
        }
        for candidate in Self.renditionCandidates(key, allowsSmaller: false) {
            if let pending = pendingImages[candidate], pending.expiry > now { return pending.image }
        }
        let id = UUID()
        // Offline readers never join a pending remote fetch. A disk read remains local.
        if !allowsNetwork {
            return try await cachedResult(for: item, pixels: pixels)
        }
        failures = failures.filter { $0.value > now }
        if failures[key] != nil { return nil }
        let playback = FoundationRequestIntent.isPlayback
        let pendingLimit = max(1, limits.pendingKeys - (playback ? 0 : 1))
        guard jobs[key] != nil || jobs.count < pendingLimit else { return nil }
        #if DEBUG
            let context = FoundationTrace.context
            let scopedLoad: @Sendable (FoundationItem, Int) async throws -> Data? = {
                item, pixels in
                try await FoundationTrace.$context.withValue(context) {
                    try await load(item, pixels)
                }
            }
        #else
            let scopedLoad = load
        #endif
        if playback, var job = jobs[key], !job.playback {
            job.playback = true
            jobs[key] = job
            // Queued jobs carry intent into their worker; only an existing worker can
            // already be waiting at network admission and require external promotion.
            if job.task != nil {
                protectedWorkers.insert(job.id)
                await networkAdmission?.promoteArtwork(job.id)
                if jobs[key]?.id != job.id { await networkAdmission?.finishArtwork(job.id) }
            }
            try Task.checkCancellation()
            guard live else { throw CancellationError() }
        }
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if var job = jobs[key] {
                    job.waiters[id] = continuation
                    jobs[key] = job
                } else {
                    jobs[key] = Job(
                        item: item, load: scopedLoad, waiters: [id: continuation],
                        playback: playback)
                    queue.append(key)
                }
                pump()
            }
        } onCancel: {
            Task { await self.cancel(key: key, waiter: id) }
        }
        try Task.checkCancellation()
        return result
    }

    private func pump() {
        while live, active < max(1, limits.concurrentLoads), !queue.isEmpty {
            let protectedIndex = queue.firstIndex { jobs[$0]?.playback == true }
            let browseLimit = max(1, limits.concurrentLoads - 1)
            guard protectedIndex != nil || active - protectedWorkers.count < browseLimit else {
                return
            }
            let key = queue.remove(at: protectedIndex ?? queue.startIndex)
            guard var job = jobs[key] else { continue }
            let jobID = job.id
            let item = job.item
            let load = job.load
            let playback = job.playback
            if playback { protectedWorkers.insert(jobID) }
            let disk = disk
            let now = now
            active += 1
            #if DEBUG
                let timing = FoundationLoadTiming(.artwork)
            #endif
            job.task = Task.detached(priority: .utility) { [weak self] in
                var outcome: Result<(FoundationCurrentArtwork.Result, Date)?, Error>
                var write: (Data, Date)?
                do {
                    try Task.checkCancellation()
                    #if DEBUG
                        timing.record(.cacheReadStarted)
                    #endif
                    let record = await disk.read(key)
                    #if DEBUG
                        timing.record(.cacheReadFinished)
                    #endif
                    #if DEBUG
                        timing.record(.decodeStarted)
                    #endif
                    let local = record.flatMap {
                        FoundationCurrentArtwork.decode($0.data, maximumPixels: key.pixels)
                    }
                    #if DEBUG
                        timing.record(.decodeFinished)
                    #endif
                    if let record, let local {
                        outcome = .success((local, record.expiry))
                    } else {
                        #if DEBUG
                            timing.record(.requestStarted)
                        #endif
                        let data = try await FoundationRequestIntent.$artworkJob.withValue(jobID) {
                            try await FoundationRequestIntent.$isPlayback.withValue(playback) {
                                try await load(item, key.pixels)
                            }
                        }
                        #if DEBUG
                            timing.record(.responseReceived)
                            timing.record(.decodeStarted)
                        #endif
                        let result = data.flatMap {
                            FoundationCurrentArtwork.decode($0, maximumPixels: key.pixels)
                        }
                        #if DEBUG
                            timing.record(.decodeFinished)
                        #endif
                        if let result, let data {
                            let expiry = now().addingTimeInterval(
                                item.primaryImageTag?.isEmpty == false ? 30 * 86_400 : 86_400)
                            write = (data, expiry)
                            outcome = .success((result, expiry))
                        } else {
                            outcome = .success(nil)
                        }
                    }
                    try Task.checkCancellation()
                } catch {
                    outcome = .failure(error)
                }
                let didPublish =
                    await self?.publish(
                        key: key, jobID: jobID, outcome: outcome, persists: write != nil) ?? false
                #if DEBUG
                    if didPublish { timing.record(.published) }
                #endif
                if didPublish, let (data, expiry) = write {
                    #if DEBUG
                        await self?.waitBeforePersistence()
                    #endif
                    if !Task.isCancelled {
                        #if DEBUG
                            timing.record(.persistStarted)
                        #endif
                        await disk.write(data, key: key, expiry: expiry)
                        #if DEBUG
                            timing.record(.persistFinished)
                        #endif
                    }
                }
                await self?.completeWorker(jobID)
            }
            jobs[key] = job
            activeTasks[jobID] = job.task
        }
    }

    private func publish(
        key: Key, jobID: UUID, outcome: Result<(FoundationCurrentArtwork.Result, Date)?, Error>,
        persists: Bool
    ) -> Bool {
        guard let job = jobs[key], job.id == jobID else { return false }
        jobs.removeValue(forKey: key)
        if live, case .success(let value) = outcome, let (result, expiry) = value {
            remember(result, key: key, expiry: expiry)
        }
        if live {
            switch outcome {
            case .success(nil): failures[key] = now().addingTimeInterval(60)
            case .failure(let error) where FoundationLibraryError.category(error) != .cancelled:
                failures[key] = now().addingTimeInterval(60)
            default: break
            }
            if failures.count > max(1, limits.pendingKeys),
                let oldest = failures.min(by: { $0.value < $1.value })?.key
            {
                failures.removeValue(forKey: oldest)
            }
        }
        for waiter in job.waiters.values {
            if live {
                waiter.resume(with: outcome.map { $0?.0 })
            } else {
                waiter.resume(throwing: CancellationError())
            }
        }
        let didPublish = live && !Task.isCancelled
        if didPublish, persists, case .success(let value) = outcome, let (image, expiry) = value {
            persisting.insert(jobID)
            pendingImages[key] = (jobID, image, expiry)
        }
        return didPublish
    }

    private func completeWorker(_ id: UUID) {
        protectedWorkers.remove(id)
        if let networkAdmission { Task { await networkAdmission.finishArtwork(id) } }
        active -= 1
        activeTasks.removeValue(forKey: id)
        persisting.remove(id)
        pendingImages = pendingImages.filter { $0.value.id != id }
        pump()
    }

    /// Explicit durability boundary for cache retirement and storage accounting.
    func flushPersistence() async {
        let tasks = persisting.compactMap { activeTasks[$0] }
        for task in tasks { await task.value }
    }

    private func cancel(key: Key, waiter: UUID) {
        guard var job = jobs[key], let continuation = job.waiters.removeValue(forKey: waiter)
        else { return }
        continuation.resume(throwing: CancellationError())
        if job.waiters.isEmpty {
            if let task = job.task {
                task.cancel()
                // Keep the slot until the cancelled native request actually ends.
                jobs.removeValue(forKey: key)
            } else {
                jobs.removeValue(forKey: key)
                queue.removeAll { $0 == key }
            }
        } else {
            jobs[key] = job
        }
    }

    private func remember(_ result: FoundationCurrentArtwork.Result, key: Key, expiry: Date) {
        clock &+= 1
        let entry = Entry(result: result, expiry: expiry, access: clock)
        // A view may use an oversized hero without flushing every reusable thumbnail.
        guard entry.cost <= max(0, limits.memoryBytes) else { return }
        entries[key] = entry
        while entries.values.reduce(0, { $0 + $1.cost }) > max(0, limits.memoryBytes),
            let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key
        {
            entries.removeValue(forKey: oldest)
        }
    }

    func invalidate(removeDisk: Bool) async -> Bool {
        live = false
        for job in previews.values {
            job.task.cancel()
            for waiter in job.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
        previews.removeAll()
        entries.removeAll()
        pendingImages.removeAll()
        failures.removeAll()
        revisions.removeAll()
        queue.removeAll()
        let draining = removeDisk ? [] : persisting.compactMap { activeTasks[$0] }
        let tasks = Array(activeTasks.values)
        for (id, task) in activeTasks where removeDisk || !persisting.contains(id) { task.cancel() }
        for job in jobs.values {
            job.task?.cancel()
            for waiter in job.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
        jobs = jobs.filter { $0.value.task != nil }.mapValues {
            var job = $0
            job.waiters.removeAll()
            return job
        }
        // Retaining disk cache drains only already-published writes, never pending downloads.
        for task in draining { await task.value }
        let cleared = await disk.invalidate(removeFiles: removeDisk)
        for task in tasks { await task.value }
        return cleared
    }

    /// Aggregate scheduling seam for deterministic cancellation tests; contains no identities.
    func consumerCount() -> Int { jobs.values.reduce(0) { $0 + $1.waiters.count } }

    nonisolated static func clearStoredArtwork(retaining scope: String? = nil, root: URL? = nil)
        async -> Bool
    {
        let directory =
            root
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VelacantoArtwork", isDirectory: true)
        return await FoundationArtworkDirectoryOwner.shared.clear(root: directory, retaining: scope)
    }

    /// Separate physical cache files from transient decoded-image memory.
    func storageUsage() async -> (memory: Int64, disk: Int64?) {
        await flushPersistence()
        guard live else { return (0, nil) }
        let bytes = await disk.storageBytes()
        guard live else { return (0, nil) }
        return (Int64(entries.values.reduce(0, { $0 + $1.cost })), bytes)
    }

    func usage() async -> (memory: Int, disk: Int, active: Int, pending: Int) {
        await flushPersistence()
        return (entries.values.reduce(0, { $0 + $1.cost }), await disk.bytes(), active, jobs.count)
    }
}

/// Serial off-main filesystem operations; only the disposable account cache is ever removed.
private actor FoundationArtworkDisk {
    struct Record: Codable, Sendable {
        let data: Data
        let expiry: Date
    }
    private let directory: URL
    private let limit: Int
    private let now: @Sendable () -> Date
    private var live = true
    private let lease: UUID
    private let registration: Task<Void, Never>
    private var lastReadMaintenance: Date?
    private var touches: [URL: Date] = [:]

    init(directory: URL, limit: Int, now: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.limit = limit
        self.now = now
        let lease = UUID()
        self.lease = lease
        registration = Task {
            await FoundationArtworkDirectoryOwner.shared.protect(directory, lease: lease)
        }
    }

    private func prepare() throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
        else { throw FoundationLibraryError.unavailable }
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func url(_ key: FoundationArtworkCache.Key) -> URL {
        directory.appendingPathComponent("\(key.identity)-\(key.pixels).art")
    }

    struct CachedRecord: Sendable {
        let key: FoundationArtworkCache.Key
        let record: Record
        var data: Data { record.data }
    }
    struct RevisionRecord: Codable, Sendable {
        let identity: String
        let tag: String
        let expiry: Date
    }
    private var revisionFile: URL { directory.appendingPathComponent("revisions.plist") }

    private func revisions() -> [String: RevisionRecord] {
        guard
            let values = try? revisionFile.resourceValues(forKeys: [
                .fileSizeKey, .isSymbolicLinkKey,
            ]),
            values.isSymbolicLink != true, let size = values.fileSize, size <= 65_536,
            let bytes = try? Data(contentsOf: revisionFile),
            let records = try? PropertyListDecoder().decode(
                [String: RevisionRecord].self, from: bytes)
        else { return [:] }
        guard records.count <= 128 else { return [:] }
        return records.filter { $0.value.expiry > now() }.filter {
            $0.key.count == 64 && $0.value.identity.count == 64
                && !$0.value.tag.isEmpty && $0.value.tag.utf8.count <= 256
        }
    }

    func revision(base: String) async -> RevisionRecord? {
        await registration.value
        guard live else { return nil }
        return revisions()[base]
    }

    func rememberRevision(base: String, identity: String, tag: String, expiry: Date) async {
        await registration.value
        guard live, limit > 0, (try? prepare()) != nil else { return }
        var records = revisions()
        records[base] = RevisionRecord(identity: identity, tag: tag, expiry: expiry)
        while records.count > 128,
            let oldest = records.min(by: { $0.value.expiry < $1.value.expiry })?.key
        {
            records.removeValue(forKey: oldest)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(records), data.count <= min(limit, 65_536) else {
            return
        }
        try? data.write(to: revisionFile, options: .atomic)
        #if os(iOS)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: revisionFile.path)
        #endif
        trim()
    }

    func read(_ key: FoundationArtworkCache.Key) async -> Record? {
        await read(key, allowsSmaller: false)?.record
    }

    func read(_ key: FoundationArtworkCache.Key, allowsSmaller: Bool) async -> CachedRecord? {
        await registration.value
        guard live, (try? prepare()) != nil else { return nil }
        let candidates = FoundationArtworkCache.renditionCandidates(
            key, allowsSmaller: allowsSmaller)
        for candidate in candidates {
            let file = url(candidate)
            guard
                let values = try? file.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ]),
                values.isRegularFile == true, values.isSymbolicLink != true,
                let size = values.fileSize, size <= FoundationCurrentArtwork.maximumBytes + 4096,
                let data = try? Data(contentsOf: file),
                let record = try? PropertyListDecoder().decode(Record.self, from: data),
                record.expiry > now(), record.data.count <= FoundationCurrentArtwork.maximumBytes
            else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if touches[file].map({ now().timeIntervalSince($0) >= 30 }) ?? true {
                try? FileManager.default.setAttributes(
                    [.modificationDate: now()], ofItemAtPath: file.path)
                if touches.count >= 256 { touches.removeAll(keepingCapacity: true) }
                touches[file] = now()
            }
            maintainAfterRead()
            return CachedRecord(key: candidate, record: record)
        }
        maintainAfterRead()
        return nil
    }

    private func maintainAfterRead() {
        guard lastReadMaintenance.map({ now().timeIntervalSince($0) >= 30 }) ?? true else { return }
        lastReadMaintenance = now()
        trim()
    }

    func write(_ data: Data, key: FoundationArtworkCache.Key, expiry: Date) async {
        await registration.value
        guard live, !Task.isCancelled, limit > 0, (try? prepare()) != nil else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let encoded = try? encoder.encode(Record(data: data, expiry: expiry)),
            encoded.count <= limit
        else { return }
        let file = url(key)
        do {
            try encoded.write(to: file, options: .atomic)
            #if os(iOS)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: file.path)
            #endif
            trim()
        } catch { try? FileManager.default.removeItem(at: file) }
    }

    private func files() -> [(URL, Int, Date)] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return urls.compactMap { file in
            guard
                file.pathExtension == "art"
                    || file.lastPathComponent == revisionFile.lastPathComponent,
                let values = try? file.resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey,
                ]),
                let size = values.fileSize
            else { return nil }
            return (file, size, values.contentModificationDate ?? .distantPast)
        }
    }

    private func trim() {
        let files = files().sorted { $0.2 < $1.2 }
        var total = files.reduce(0) { $0 + $1.1 }
        for file in files where total > limit {
            if (try? FileManager.default.removeItem(at: file.0)) != nil { total -= file.1 }
        }
    }

    func bytes() -> Int { files().reduce(0) { $0 + $1.1 } }

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
            for url in urls
            where url.pathExtension == "art"
                || url.lastPathComponent == revisionFile.lastPathComponent
            {
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

    func invalidate(removeFiles: Bool) async -> Bool {
        live = false
        await registration.value
        return await FoundationArtworkDirectoryOwner.shared.release(
            directory, lease: lease, removeFiles: removeFiles)
    }
}

/// Serial directory retirement prevents startup cleanup from removing a newly active account.
private actor FoundationArtworkDirectoryOwner {
    static let shared = FoundationArtworkDirectoryOwner()
    private var leases: [String: Set<UUID>] = [:]

    func protect(_ directory: URL, lease: UUID) {
        leases[directory.resolvingSymlinksInPath().standardizedFileURL.path, default: []].insert(
            lease)
    }

    func release(_ directory: URL, lease: UUID, removeFiles: Bool) -> Bool {
        leases[directory.resolvingSymlinksInPath().standardizedFileURL.path]?.remove(lease)
        if leases[directory.resolvingSymlinksInPath().standardizedFileURL.path]?.isEmpty == true {
            leases.removeValue(forKey: directory.resolvingSymlinksInPath().standardizedFileURL.path)
        }
        guard removeFiles,
            leases[directory.resolvingSymlinksInPath().standardizedFileURL.path] == nil,
            FileManager.default.fileExists(atPath: directory.path)
        else { return true }
        do {
            try FileManager.default.removeItem(at: directory)
            return true
        } catch { return false }
    }

    func clear(root: URL, retaining scope: String?) -> Bool {
        guard FileManager.default.fileExists(atPath: root.path) else { return true }
        do {
            let entries = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var cleared = true
            for entry in entries {
                let name = entry.lastPathComponent
                guard name != scope,
                    leases[entry.resolvingSymlinksInPath().standardizedFileURL.path] == nil,
                    name.count == 64,
                    name.allSatisfy({ "0123456789abcdef".contains($0) })
                else { continue }
                do {
                    let values = try entry.resourceValues(forKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey,
                    ])
                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                        continue
                    }
                    try FileManager.default.removeItem(at: entry)
                } catch { cleared = false }
            }
            return cleared
        } catch { return false }
    }
}
