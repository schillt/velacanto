import Combine
import Foundation
import Network

nonisolated enum FoundationDownloadState: String, Sendable {
    case queued, expanding, waitingForWiFi, downloading, ready, cancelled, failed
}

struct FoundationDownloadOwner: Identifiable {
    let id: String
    var item: FoundationItem
    var tracks: [FoundationItem]
    var state: FoundationDownloadState
    var progress: Double = 0
    var status: String {
        switch state {
        case .queued: "Waiting"
        case .expanding: "Reading tracks"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .downloading: "Downloading"
        case .ready: "On Device"
        case .cancelled: "Cancelled — downloaded tracks are retained"
        case .failed: "Download incomplete — retry when ready"
        }
    }
}

/// One account owns download intent, native transfers, snapshots and playback leases.
@MainActor
final class FoundationDownloads: ObservableObject {
    typealias Transfer =
        @Sendable (
            FoundationDownloadSource, URL, Bool,
            @escaping @Sendable (Int64, Int64?) -> Void
        ) async throws -> Void

    @Published private(set) var owners: [FoundationDownloadOwner] = []
    @Published private(set) var allowsCellular = false
    @Published private(set) var isLoading = false
    @Published private(set) var storageBytes: Int64 = 0
    @Published private(set) var errorMessage: String?
    private let library: any FoundationLibrary
    private let directory: URL
    private let transfer: Transfer
    private var manifest = FoundationDownloadManifest()
    private var paused: Set<String> = []
    private var expanded: Set<String> = []
    private var leases: [String: Int] = [:]
    private var pendingDeletion: Set<String> = []
    private var worker: Task<Void, Never>?
    private var inventoryTask: Task<Void, Never>?
    private var resetting = false
    private var syncTask: Task<Void, Never>?
    private var syncPending = false
    private var activeOwner: String?
    private var monitor: NWPathMonitor?
    private var connected = false
    private var wifi = false
    private var isLive = true
    private var generation: UInt = 0
    private var pendingClear = false
    private var storageUsable = true

    init(
        scope: String, library: any FoundationLibrary, root: URL? = nil,
        transfer: Transfer? = nil, monitorConnectivity: Bool = true
    ) {
        self.library = library
        directory = FoundationDownloadStorage.directory(scope: scope, root: root)
        self.transfer =
            transfer ?? { source, target, cellular, progress in
                try await FoundationDownloadTransport.transfer(
                    source: source, to: target, allowsCellular: cellular, progress: progress)
            }
        do {
            try FoundationDownloadStorage.prepare(directory)
            manifest = try FoundationDownloadStorage.load(directory: directory)
            allowsCellular = manifest.allowsCellular
            for saved in manifest.owners {
                if saved.paused { paused.insert(saved.id) }
                if saved.expanded { expanded.insert(saved.id) }
                owners.append(
                    FoundationDownloadOwner(
                        id: saved.id, item: saved.item.item, tracks: saved.tracks.map(\.item),
                        state: saved.paused ? .cancelled : .queued))
            }
            if manifest.files.isEmpty {
                try finishInventory()
            } else {
                beginInventory()
            }
        } catch {
            storageUsable = false
            errorMessage =
                "Downloaded storage could not be read safely. Remove downloaded storage before retrying."
        }
        refreshBytes()
        if monitorConnectivity {
            let monitor = NWPathMonitor()
            self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let connected = path.status == .satisfied
                let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                Task { @MainActor [weak self] in
                    self?.receiveConnectivity(connected: connected, wifi: wifi)
                }
            }
            monitor.start(queue: DispatchQueue(label: "Velacanto.DownloadConnectivity"))
        }
    }

    isolated deinit {
        worker?.cancel()
        syncTask?.cancel()
        inventoryTask?.cancel()
        monitor?.cancel()
    }

    private func beginInventory() {
        isLoading = true
        let files = manifest.files
        let directory = directory
        let epoch = generation
        inventoryTask = Task { [weak self] in
            do {
                let verified = try await FoundationDownloadStorage.verifiedFiles(
                    files, directory: directory)
                guard let self, self.isLive, self.generation == epoch else { return }
                self.manifest.files = verified
                self.isLoading = false
                try self.finishInventory()
                self.inventoryTask = nil
                self.schedule()
                if self.syncPending { self.reconcilePlaylists() }
            } catch {
                guard let self, self.isLive, self.generation == epoch else { return }
                self.inventoryTask = nil
                self.isLoading = false
                self.storageUsable = false
                self.errorMessage =
                    "Downloaded storage could not be verified. Remove All Downloads to recover."
            }
        }
    }

    private func finishInventory() throws {
        let retained = Set(manifest.files.values.map(\.name)).union(["manifest.json"])
        for url in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) where !retained.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
        try save()
        refreshStates()
        collectUnusedFiles()
        refreshBytes()
    }

    private var allowed: Bool { connected && (wifi || allowsCellular) }

    /// Injection seam for deterministic policy tests; native transfers also enforce cellular policy.
    func updateConnectivity(isAllowed: Bool) {
        receiveConnectivity(connected: isAllowed, wifi: isAllowed)
    }

    func updateConnectivity(isConnected: Bool, usesWiFi: Bool) {
        receiveConnectivity(connected: isConnected, wifi: usesWiFi)
    }

    private func receiveConnectivity(connected: Bool, wifi: Bool) {
        guard isLive else { return }
        let previous = allowed
        self.connected = connected
        self.wifi = wifi
        if !allowed {
            worker?.cancel()
            syncTask?.cancel()
        }
        refreshStates()
        if allowed {
            schedule()
            if !previous { reconcilePlaylists() }
        }
    }

    func setAllowsCellular(_ value: Bool) {
        guard isLive, storageUsable else { return }
        let old = allowsCellular
        allowsCellular = value
        do { try save() } catch {
            allowsCellular = old
            reportStorageFailure()
            return
        }
        // Restart even when the new policy remains allowed so in-flight requests use it.
        worker?.cancel()
        syncTask?.cancel()
        refreshStates()
        if allowed {
            schedule()
            reconcilePlaylists()
        }
    }

    private func ownerID(_ item: FoundationItem) -> String {
        let kind = item.kind == .playlist ? "playlist" : item.kind == .album ? "album" : "track"
        return kind + ":" + item.id
    }

    func download(_ item: FoundationItem) {
        guard isLive, storageUsable, [.track, .album, .playlist].contains(item.kind) else { return }
        let id = ownerID(item)
        if owners.contains(where: { $0.id == id }) {
            retry(ownerID: id)
            return
        }
        owners.append(FoundationDownloadOwner(id: id, item: item, tracks: [], state: .queued))
        do { try save() } catch {
            owners.removeAll { $0.id == id }
            reportStorageFailure()
            return
        }
        refreshStates()
        schedule()
    }

    func cancel(ownerID: String) {
        guard isLive, storageUsable, let index = owners.firstIndex(where: { $0.id == ownerID })
        else { return }
        paused.insert(ownerID)
        owners[index].state = .cancelled
        if activeOwner == ownerID { worker?.cancel() }
        do { try save() } catch { reportStorageFailure() }
    }

    func retry(ownerID: String) {
        guard isLive, storageUsable, let index = owners.firstIndex(where: { $0.id == ownerID })
        else { return }
        paused.remove(ownerID)
        owners[index].state = .queued
        errorMessage = nil
        do { try save() } catch {
            reportStorageFailure()
            return
        }
        refreshStates()
        schedule()
    }

    func remove(ownerID: String) {
        guard isLive, storageUsable, let index = owners.firstIndex(where: { $0.id == ownerID })
        else { return }
        let old = owners.remove(at: index)
        let wasPaused = paused.remove(ownerID) != nil
        let wasExpanded = expanded.remove(ownerID) != nil
        do { try save() } catch {
            owners.insert(old, at: index)
            if wasPaused { paused.insert(ownerID) }
            if wasExpanded { expanded.insert(ownerID) }
            reportStorageFailure()
            return
        }
        if activeOwner == ownerID { worker?.cancel() }
        collectUnusedFiles()
        refreshBytes()
        schedule()
    }

    func isReady(_ item: FoundationItem) -> Bool {
        guard storageUsable, !isLoading, let file = manifest.files[item.id],
            let url = FoundationDownloadStorage.fileURL(file, directory: directory),
            let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
            && Int64(values.fileSize ?? -1) == file.bytes
    }

    func readyTracks(ownerID: String) -> [FoundationItem] {
        owners.first(where: { $0.id == ownerID })?.tracks.filter { isReady($0) } ?? []
    }

    private func schedule() {
        guard isLive, storageUsable, !isLoading, allowed, worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run()
            self.worker = nil
            self.activeOwner = nil
            self.refreshStates()
            if self.owners.contains(where: { $0.state == .queued }) { self.schedule() }
        }
    }

    private func run() async {
        let epoch = generation
        while isLive, epoch == generation, allowed, !Task.isCancelled,
            let owner = owners.first(where: { $0.state == .queued && !paused.contains($0.id) })
        {
            activeOwner = owner.id
            do {
                if !expanded.contains(owner.id) {
                    setState(owner.id, .expanding)
                    let tracks: [FoundationItem]
                    switch owner.item.kind {
                    case .track: tracks = [owner.item]
                    case .album:
                        tracks = try await FoundationPlaylistMutation.sourceTracks(
                            owner.item, library: library)
                    case .playlist:
                        tracks = try await FoundationPlaylistSnapshot.load(
                            id: owner.item.id, library: library
                        ).map(\.item)
                    default: throw FoundationLibraryError.unavailable
                    }
                    try check(epoch: epoch, ownerID: owner.id)
                    guard let index = owners.firstIndex(where: { $0.id == owner.id }) else {
                        return
                    }
                    let before = owners[index].tracks
                    owners[index].tracks = tracks
                    expanded.insert(owner.id)
                    do { try save() } catch {
                        owners[index].tracks = before
                        expanded.remove(owner.id)
                        throw error
                    }
                }
                guard let current = owners.first(where: { $0.id == owner.id }) else { continue }
                setState(owner.id, .downloading)
                var visited: Set<String> = []
                for track in current.tracks where visited.insert(track.id).inserted {
                    try check(epoch: epoch, ownerID: owner.id)
                    if isReady(track) { continue }
                    let source = try await library.downloadSource(for: track)
                    try check(epoch: epoch, ownerID: owner.id)
                    let ext = source.fileExtension.lowercased()
                    guard !ext.isEmpty, ext.count <= 8,
                        ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
                    else { throw FoundationLibraryError.invalidResponse }
                    let stage = directory.appendingPathComponent(
                        "stage-" + UUID().uuidString + "." + ext)
                    do {
                        try await transfer(source, stage, allowsCellular) {
                            [weak self] bytes, total in
                            Task { @MainActor [weak self] in
                                guard let self, self.generation == epoch,
                                    self.activeOwner == owner.id,
                                    let index = self.owners.firstIndex(where: { $0.id == owner.id })
                                else { return }
                                let complete = self.readyTracks(ownerID: owner.id).count
                                let fraction =
                                    total.map { $0 > 0 ? min(1, Double(bytes) / Double($0)) : 0 }
                                    ?? 0
                                self.owners[index].progress = min(
                                    1,
                                    (Double(complete) + fraction)
                                        / Double(max(1, current.tracks.count)))
                                self.refreshBytes()
                            }
                        }
                        try check(epoch: epoch, ownerID: owner.id)
                        try FoundationDownloadStorage.protect(stage)
                        let bytes = Int64(
                            try stage.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                        guard bytes > 0,
                            source.expectedBytes == nil || source.expectedBytes == bytes
                        else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        let digest = try await FoundationDownloadStorage.digestOffMain(stage)
                        try check(epoch: epoch, ownerID: owner.id)
                        let file = FoundationDownloadManifest.File(
                            name: UUID().uuidString + "." + ext, bytes: bytes, digest: digest)
                        let destination = directory.appendingPathComponent(file.name)
                        try FileManager.default.moveItem(at: stage, to: destination)
                        do {
                            try FoundationDownloadStorage.protect(destination)
                            let previous = manifest.files.updateValue(file, forKey: track.id)
                            do { try save() } catch {
                                manifest.files[track.id] = previous
                                throw error
                            }
                            if let previous,
                                let oldURL = FoundationDownloadStorage.fileURL(
                                    previous, directory: directory)
                            {
                                try FileManager.default.removeItem(at: oldURL)
                            }
                        } catch {
                            if manifest.files[track.id]?.name != file.name {
                                try? FileManager.default.removeItem(at: destination)
                            }
                            throw error
                        }
                    } catch {
                        if FileManager.default.fileExists(atPath: stage.path) {
                            do { try FileManager.default.removeItem(at: stage) } catch {
                                errorMessage =
                                    "A partial download could not be removed. Try removing downloaded storage."
                            }
                        }
                        throw error
                    }
                    refreshBytes()
                }
                setState(owner.id, .ready)
            } catch {
                if !isLive || generation != epoch { return }
                if Task.isCancelled || !allowed || paused.contains(owner.id) {
                    setState(owner.id, paused.contains(owner.id) ? .cancelled : .queued)
                    break
                }
                paused.insert(owner.id)
                setState(owner.id, .failed)
                errorMessage =
                    (error as? FoundationDownloadError)?.errorDescription
                    ?? "The download could not finish. Check connectivity and available storage, then retry."
                do { try save() } catch { reportStorageFailure() }
            }
        }
    }

    private func check(epoch: UInt, ownerID: String) throws {
        try Task.checkCancellation()
        guard isLive, generation == epoch, allowed, !paused.contains(ownerID),
            owners.contains(where: { $0.id == ownerID })
        else { throw CancellationError() }
    }

    private func setState(_ id: String, _ state: FoundationDownloadState) {
        guard let index = owners.firstIndex(where: { $0.id == id }) else { return }
        owners[index].state = state
        if state == .ready { owners[index].progress = 1 }
    }

    private func refreshStates() {
        for index in owners.indices {
            let id = owners[index].id
            if paused.contains(id) { continue }
            if expanded.contains(id), owners[index].tracks.allSatisfy({ isReady($0) }) {
                owners[index].state = .ready
                owners[index].progress = 1
            } else if !allowed {
                owners[index].state = .waitingForWiFi
            } else if id != activeOwner || worker == nil {
                owners[index].state = .queued
            }
        }
    }

    private func save() throws {
        manifest.allowsCellular = allowsCellular
        manifest.owners = owners.map {
            .init(
                id: $0.id, item: FoundationStoredDownloadItem($0.item),
                tracks: $0.tracks.map(FoundationStoredDownloadItem.init),
                paused: paused.contains($0.id), expanded: expanded.contains($0.id))
        }
        try FoundationDownloadStorage.save(manifest, directory: directory)
    }

    private func reportStorageFailure() {
        errorMessage = "Downloaded storage could not be updated. Check available space and retry."
    }

    private func refreshBytes() {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else {
            storageBytes = 0
            return
        }
        storageBytes = urls.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func collectUnusedFiles() {
        guard !isLoading else { return }
        let referenced = Set(owners.flatMap(\.tracks).map(\.id))
        for id in Array(manifest.files.keys) where !referenced.contains(id) {
            if (leases[id] ?? 0) > 0 {
                pendingDeletion.insert(id)
                continue
            }
            guard let file = manifest.files[id],
                let url = FoundationDownloadStorage.fileURL(file, directory: directory)
            else { continue }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                manifest.files.removeValue(forKey: id)
                pendingDeletion.remove(id)
            } catch {
                errorMessage =
                    "Some downloaded files could not be removed. Retry removal or clear downloaded storage."
            }
        }
        do { try save() } catch { reportStorageFailure() }
        refreshBytes()
    }

    func playbackResource(for item: FoundationItem) async throws -> FoundationPlaybackResource {
        guard isLive else { throw CancellationError() }
        if isReady(item), let file = manifest.files[item.id],
            let url = FoundationDownloadStorage.fileURL(file, directory: directory)
        {
            leases[item.id, default: 0] += 1
            return FoundationPlaybackResource(url: url) { [self] in
                await releaseLease(item.id)
            }
        }
        let epoch = generation
        let url = try await library.playbackURL(for: item)
        guard isLive, epoch == generation else { throw CancellationError() }
        return FoundationPlaybackResource(url: url, release: {})
    }

    private func releaseLease(_ id: String) {
        leases[id] = max(0, (leases[id] ?? 0) - 1)
        if pendingClear, leases.values.allSatisfy({ $0 == 0 }) {
            do {
                try FileManager.default.removeItem(at: directory)
                pendingClear = false
            } catch { errorMessage = "Downloaded account data could not be removed." }
        } else if pendingDeletion.contains(id) {
            collectUnusedFiles()
        }
    }

    func reconcilePlaylists() {
        guard isLive, storageUsable else { return }
        syncPending = true
        guard allowed, !isLoading, syncTask == nil else { return }
        syncTask = Task { [weak self] in
            guard let self else { return }
            await self.runReconciliation()
            self.syncTask = nil
            if self.syncPending, self.allowed, self.isLive { self.reconcilePlaylists() }
        }
    }

    private func runReconciliation() async {
        let epoch = generation
        while syncPending, isLive, allowed, !Task.isCancelled {
            syncPending = false
            let snapshots = owners.filter { $0.item.kind == .playlist && expanded.contains($0.id) }
            for owner in snapshots {
                do {
                    let entries = try await FoundationPlaylistSnapshot.load(
                        id: owner.item.id, library: library)
                    let permission = try await library.playlistPermissions(id: owner.item.id)
                    try Task.checkCancellation()
                    guard isLive, epoch == generation,
                        let index = owners.firstIndex(where: { $0.id == owner.id })
                    else { continue }
                    let previous = owners[index]
                    var item = owner.item
                    // FoundationItem title is immutable; retain neutral catalog metadata.
                    item = FoundationItem(
                        id: item.id, title: permission.name, subtitle: item.subtitle,
                        kind: .playlist, duration: item.duration,
                        primaryImageTag: item.primaryImageTag)
                    owners[index].item = item
                    owners[index].tracks = entries.map(\.item)
                    do { try save() } catch {
                        owners[index] = previous
                        throw error
                    }
                    if activeOwner == owner.id { worker?.cancel() }
                    collectUnusedFiles()
                    refreshStates()
                    schedule()
                } catch {
                    if Task.isCancelled || !isLive || epoch != generation { return }
                    errorMessage =
                        "A downloaded playlist could not refresh. Its last saved tracks remain available."
                }
            }
        }
    }

    func invalidate() {
        isLive = false
        generation &+= 1
        worker?.cancel()
        syncTask?.cancel()
        inventoryTask?.cancel()
        monitor?.cancel()
        monitor = nil
    }

    /// Explicit recovery also works when an unreadable manifest cannot supply individual rows.
    func removeAll() async -> Bool {
        guard isLive, !resetting else { return false }
        resetting = true
        defer { resetting = false }
        let previouslyUsable = storageUsable
        storageUsable = false
        generation &+= 1
        syncPending = false
        inventoryTask?.cancel()
        worker?.cancel()
        syncTask?.cancel()
        await worker?.value
        await syncTask?.value
        await inventoryTask?.value
        inventoryTask = nil
        isLoading = false
        guard isLive else { return false }
        errorMessage = nil
        if leases.values.contains(where: { $0 > 0 }), previouslyUsable {
            let previousOwners = owners
            let previousPaused = paused
            let previousExpanded = expanded
            owners = []
            paused = []
            expanded = []
            do { try save() } catch {
                owners = previousOwners
                paused = previousPaused
                expanded = previousExpanded
                storageUsable = previouslyUsable
                reportStorageFailure()
                return false
            }
            storageUsable = true
            collectUnusedFiles()
            return errorMessage == nil
        }
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FoundationDownloadStorage.prepare(directory)
            manifest = FoundationDownloadManifest()
            owners = []
            paused = []
            expanded = []
            pendingDeletion = []
            try save()
            storageUsable = true
            refreshBytes()
            return true
        } catch {
            errorMessage = "Downloaded storage could not be removed. Retry Remove All Downloads."
            refreshBytes()
            return false
        }
    }

    func clearAccount() async -> Bool {
        invalidate()
        await worker?.value
        await syncTask?.value
        await inventoryTask?.value
        inventoryTask = nil
        isLoading = false
        guard leases.values.allSatisfy({ $0 == 0 }) else {
            pendingClear = true
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            owners = []
            manifest = FoundationDownloadManifest()
            storageBytes = 0
            return true
        } catch {
            errorMessage = "Downloaded account data could not be removed. Retry account cleanup."
            return false
        }
    }

    static func clearStoredDownloads(retaining scope: String? = nil) -> Bool {
        let base = FoundationDownloadStorage.base
        guard FileManager.default.fileExists(atPath: base.path) else { return true }
        let retained = scope.map {
            FoundationDownloadStorage.directory(scope: $0, root: nil).lastPathComponent
        }
        do {
            var success = true
            for url in try FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: nil)
            where url.lastPathComponent != retained {
                do { try FileManager.default.removeItem(at: url) } catch { success = false }
            }
            return success
        } catch { return false }
    }
}
