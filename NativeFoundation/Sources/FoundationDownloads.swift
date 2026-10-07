import Combine
import Foundation
import ImageIO
import Network

nonisolated enum FoundationDownloadState: String, Sendable {
    case queued, expanding, waitingForWiFi, downloading, ready, cancelled, failed
}

nonisolated enum FoundationDownloadAvailability: Equatable, Sendable {
    case unavailable
    case partial(ready: Int, total: Int)
    case ready
}

struct FoundationDownloadOwner: Identifiable {
    let id: String
    var item: FoundationItem
    var tracks: [FoundationItem]
    var state: FoundationDownloadState
    var progress: Double = 0
    var availability: FoundationDownloadAvailability = .unavailable
    var status: String {
        switch state {
        case .queued: "Waiting"
        case .expanding: "Reading tracks"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .downloading: "Downloading"
        case .ready:
            switch availability {
            case .ready: "On Device"
            case .partial: "Partially On Device"
            case .unavailable: "No tracks On Device"
            }
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
    typealias FileVerifier =
        @Sendable ([String: FoundationDownloadManifest.File], URL) async throws
        -> [String: FoundationDownloadManifest.File]

    @Published private(set) var owners: [FoundationDownloadOwner] = []
    @Published private(set) var allowsCellular = false
    @Published private(set) var isLoading = false
    @Published private(set) var storageBytes: Int64 = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var artworkRevision: UInt = 0
    private let library: any FoundationLibrary
    private let directory: URL
    private let transfer: Transfer
    private let verifyReacquisitionFiles: FileVerifier
    private var manifest = FoundationDownloadManifest()
    private var collectionModels: [String: FoundationBrowseModel] = [:]
    private var paused: Set<String> = []
    private var expanded: Set<String> = []
    private var reacquiring: Set<String> = []
    private var leases: [String: Int] = [:]
    private var pendingDeletion: Set<String> = []
    private var readyFileIDs: Set<String> = []
    private(set) var artworkTask: Task<Void, Never>?
    private var attemptedArtwork: Set<String> = []
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
    private var leaseWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var storageUsable = true

    init(
        scope: String, library: any FoundationLibrary, root: URL? = nil,
        transfer: Transfer? = nil, monitorConnectivity: Bool = true,
        verifyReacquisitionFiles: FileVerifier? = nil
    ) {
        self.library = library
        self.verifyReacquisitionFiles =
            verifyReacquisitionFiles ?? { files, directory in
                try await FoundationDownloadStorage.verifiedFiles(files, directory: directory)
            }
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
                if saved.reacquiresExcludedTracks == true { reacquiring.insert(saved.id) }
                owners.append(
                    FoundationDownloadOwner(
                        id: saved.id, item: saved.item.item, tracks: saved.tracks.map(\.item),
                        state: saved.paused ? .cancelled : .queued))
            }
            if manifest.files.isEmpty && (manifest.artwork?.isEmpty ?? true) {
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
        artworkTask?.cancel()
        worker?.cancel()
        syncTask?.cancel()
        inventoryTask?.cancel()
        monitor?.cancel()
    }

    private func beginInventory() {
        isLoading = true
        let files = manifest.files
        let artwork = manifest.artwork ?? [:]
        let directory = directory
        let epoch = generation
        inventoryTask = Task { [weak self] in
            do {
                let verified = try await FoundationDownloadStorage.verifiedFiles(
                    files, directory: directory)
                let verifiedArtwork = try await FoundationDownloadStorage.verifiedFiles(
                    artwork.mapValues(\.file), directory: directory)
                guard let self, self.isLive, self.generation == epoch else { return }
                self.manifest.artwork = artwork.filter { verifiedArtwork[$0.key] != nil }
                self.manifest.files = verified
                self.isLoading = false
                try self.finishInventory()
                self.inventoryTask = nil
                self.scheduleArtwork()
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
        readyFileIDs = Set(manifest.files.keys)
        let retained = Set(manifest.files.values.map(\.name))
            .union((manifest.artwork ?? [:]).values.map { $0.file.name }).union(["manifest.json"])
        for url in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) where !retained.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
        try save()
        refreshStates()
        collectUnusedFiles()
        refreshBytes()
        artworkRevision &+= 1
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
            artworkTask?.cancel()
            syncTask?.cancel()
        }
        refreshStates()
        if allowed {
            scheduleArtwork()
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
        artworkTask?.cancel()
        syncTask?.cancel()
        refreshStates()
        if allowed {
            scheduleArtwork()
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
        let wasReacquiring = reacquiring.remove(ownerID) != nil
        do { try save() } catch {
            owners.insert(old, at: index)
            if wasPaused { paused.insert(ownerID) }
            if wasExpanded { expanded.insert(ownerID) }
            if wasReacquiring { reacquiring.insert(ownerID) }
            reportStorageFailure()
            return
        }
        if activeOwner == ownerID { worker?.cancel() }
        collectUnusedFiles()
        refreshBytes()
        schedule()
    }

    private func isExcluded(_ id: String) -> Bool {
        manifest.excludedTrackIDs?.contains(id) == true
    }

    private var retainedTrackIDs: Set<String> {
        Set(owners.flatMap(\.tracks).map(\.id).filter { !isExcluded($0) })
    }

    /// Physical files are shared; the Songs projection never repeats playlist occurrences.
    var downloadedSongs: [FoundationItem] {
        var seen: Set<String> = []
        return owners.flatMap(\.tracks).filter { isReady($0) && seen.insert($0.id).inserted }
    }

    var downloadedPlaylists: [FoundationItem] {
        guard isLive, storageUsable else { return [] }
        // Saved snapshots remain browsable after their final local track is removed.
        return owners.filter { $0.item.kind == .playlist && expanded.contains($0.id) }.map(\.item)
    }

    var downloadedAlbums: [FoundationItem] {
        guard isLive, storageUsable else { return [] }
        var items = owners.filter {
            $0.item.kind == .album && expanded.contains($0.id)
        }.map(\.item)
        var seen = Set(items.map(\.id))
        for song in downloadedSongs {
            if let album = song.album, seen.insert(album.id).inserted {
                items.append(
                    FoundationItem(
                        id: album.id, title: album.title, subtitle: song.subtitle,
                        kind: .album, duration: nil, primaryImageTag: album.primaryImageTag))
            }
        }
        return items
    }

    private func collectionKey(_ item: FoundationItem) -> String {
        FoundationStoredDownloadItem(item).kind + ":" + item.id
    }

    /// One account-owned model serves every entry point for the same collection identity.
    func collectionModel(for item: FoundationItem) -> FoundationBrowseModel {
        guard isLive else { return FoundationBrowseModel() }
        let key = collectionKey(item)
        if let model = collectionModels[key] { return model }
        let model = FoundationBrowseModel()
        collectionModels[key] = model
        let tracks = snapshotTracks(for: item)
        let hasSnapshot = owners.contains {
            $0.item.kind == item.kind && $0.id == ownerID(item) && expanded.contains($0.id)
        }
        if hasSnapshot || !tracks.isEmpty { model.installSnapshot(tracks, complete: hasSnapshot) }
        return model
    }

    /// Known membership includes excluded and unavailable occurrences, in saved/server order.
    func knownCollectionTracks(for item: FoundationItem) -> [FoundationItem] {
        guard isLive else { return [] }
        if let model = collectionModels[collectionKey(item)], model.loaded || !model.items.isEmpty {
            return model.items
        }
        return snapshotTracks(for: item)
    }

    func hasCompleteCollectionSnapshot(for item: FoundationItem) -> Bool {
        guard isLive else { return false }
        if item.kind == .track { return true }
        if let model = collectionModels[collectionKey(item)], model.loaded || !model.items.isEmpty {
            // An established canonical page supersedes the older complete download snapshot.
            return model.loaded && model.nextStartIndex == nil
        }
        return owners.contains {
            $0.item.kind == item.kind && $0.id == ownerID(item) && expanded.contains($0.id)
        }
    }

    private func installCollectionSnapshot(
        _ item: FoundationItem, tracks: [FoundationItem], refreshed: Bool = false
    ) {
        guard let model = collectionModels[collectionKey(item)], !model.isLoading,
            refreshed || !model.loaded || model.isRetainedSnapshot
        else { return }
        model.installSnapshot(tracks)
    }

    /// Intent remains removable when all audio is excluded or a transfer has not completed.
    func hasDownloadedData(for item: FoundationItem) -> Bool {
        guard isLive, storageUsable, [.track, .album, .playlist].contains(item.kind) else {
            return false
        }
        if owners.contains(where: { $0.id == ownerID(item) }) { return true }
        let tracks = knownCollectionTracks(for: item)
        let retained = tracks.filter { track in
            manifest.files[track.id] != nil || retainedTrackIDs.contains(track.id)
        }
        if !retained.isEmpty { return true }
        if item.kind == .album || item.kind == .playlist {
            return manifest.artwork?[artworkKey(item)] != nil
        }
        return false
    }

    func removalAffectsPlaylist(for item: FoundationItem) -> Bool {
        guard isLive else { return false }
        let ids: Set<String>
        if item.kind == .track {
            ids = [item.id]
        } else if (item.kind == .album || item.kind == .playlist)
            && !owners.contains(where: { $0.id == ownerID(item) })
        {
            ids = Set(knownCollectionTracks(for: item).map(\.id))
        } else {
            return false
        }
        return owners.contains { owner in
            owner.item.kind == .playlist && owner.tracks.contains(where: { ids.contains($0.id) })
        }
    }

    /// Explicit collection removal releases its owner; unowned groups remove their known shared songs.
    func removeDownloads(for item: FoundationItem) {
        guard isLive, storageUsable, [.track, .album, .playlist].contains(item.kind) else { return }
        if item.kind == .track {
            removeTrack(item)
        } else if owners.contains(where: { $0.id == ownerID(item) }) {
            remove(ownerID: ownerID(item))
        } else if item.kind == .album || item.kind == .playlist {
            let ids = Set(knownCollectionTracks(for: item).map(\.id)).intersection(retainedTrackIDs)
            removeSelected(ownerIDs: [], trackIDs: ids)
        }
    }

    private func snapshotTracks(for item: FoundationItem) -> [FoundationItem] {
        if item.kind == .track { return [item] }
        guard item.kind == .album || item.kind == .playlist else { return [] }
        if let owner = owners.first(where: { $0.id == ownerID(item) }),
            item.kind != .album || expanded.contains(owner.id) || !owner.tracks.isEmpty
        {
            return owner.tracks
        }
        if item.kind == .album {
            var seen: Set<String> = []
            return owners.flatMap(\.tracks).filter {
                $0.album?.id == item.id && seen.insert($0.id).inserted
            }
        }
        return []
    }

    func browseTracks(for item: FoundationItem) -> [FoundationItem] {
        knownCollectionTracks(for: item).filter { isReady($0) }
    }

    func availability(for item: FoundationItem) -> FoundationDownloadAvailability {
        if item.kind == .track { return isReady(item) ? .ready : .unavailable }
        let tracks = knownCollectionTracks(for: item)
        let ready = tracks.filter { isReady($0) }.count
        guard ready > 0 else { return .unavailable }
        // Partial derived groups do not prove complete membership; a full server snapshot does.
        if hasCompleteCollectionSnapshot(for: item) && ready == tracks.count { return .ready }
        return .partial(ready: ready, total: tracks.count)
    }

    func itemBytes(_ item: FoundationItem) -> Int64 {
        let tracks = browseTracks(for: item)
        let ids = Set(tracks.map(\.id))
        let artworkKeys = Set(([item] + tracks).map { artworkKey($0) })
        return ids.reduce(0) { $0 + (manifest.files[$1]?.bytes ?? 0) }
            + artworkKeys.reduce(0) { $0 + (manifest.artwork?[$1]?.file.bytes ?? 0) }
    }

    /// Bytes actually deletable now, excluding shared references and active playback leases.
    func reclaimableBytes(ownerIDs: Set<String>, trackIDs: Set<String>) -> Int64 {
        let selected = Set(owners.filter { ownerIDs.contains($0.id) }.flatMap(\.tracks).map(\.id))
            .union(trackIDs)
        let remaining = Set(
            owners.filter { !ownerIDs.contains($0.id) }
                .flatMap(\.tracks).map(\.id).filter { !isExcluded($0) && !trackIDs.contains($0) })
        let selectedItems =
            owners.filter { ownerIDs.contains($0.id) }.flatMap { [$0.item] + $0.tracks }
            + owners.flatMap(\.tracks).filter { trackIDs.contains($0.id) }
        let remainingItems = owners.filter {
            !ownerIDs.contains($0.id) && !($0.item.kind == .track && trackIDs.contains($0.item.id))
        }.flatMap { owner in
            [owner.item] + owner.tracks.filter { !isExcluded($0.id) && !trackIDs.contains($0.id) }
        }
        let removedArt = Set(selectedItems.map { artworkKey($0) })
            .subtracting(Set(remainingItems.map { artworkKey($0) }))
        return selected.subtracting(remaining).reduce(0) {
            $0 + ((leases[$1] ?? 0) == 0 ? (manifest.files[$1]?.bytes ?? 0) : 0)
        } + removedArt.reduce(0) { $0 + (manifest.artwork?[$1]?.file.bytes ?? 0) }
    }

    func removeTrack(_ item: FoundationItem) {
        guard item.kind == .track else { return }
        removeSelected(ownerIDs: [], trackIDs: [item.id])
    }

    /// Local exclusions preserve collection snapshots/order and survive successful reconciliation.
    func removeSelected(ownerIDs: Set<String>, trackIDs: Set<String>) {
        guard isLive, storageUsable else { return }
        let previousOwners = owners
        let previousPaused = paused
        let previousExpanded = expanded
        let previousReacquiring = reacquiring
        let previousManifest = manifest
        owners.removeAll {
            ownerIDs.contains($0.id) || ($0.item.kind == .track && trackIDs.contains($0.item.id))
        }
        paused.formIntersection(Set(owners.map(\.id)))
        expanded.formIntersection(Set(owners.map(\.id)))
        reacquiring.formIntersection(Set(owners.map(\.id)))
        // A newer global song removal supersedes earlier pending collection reacquisition.
        if !trackIDs.isEmpty { reacquiring = [] }
        manifest.excludedTrackIDs = (manifest.excludedTrackIDs ?? []).union(trackIDs)
        do { try save() } catch {
            owners = previousOwners
            paused = previousPaused
            expanded = previousExpanded
            reacquiring = previousReacquiring
            manifest = previousManifest
            reportStorageFailure()
            return
        }
        worker?.cancel()
        collectUnusedFiles()
        refreshStates()
        schedule()
    }

    func downloadAgain(_ item: FoundationItem) {
        guard isLive, storageUsable, [.track, .album, .playlist].contains(item.kind) else { return }
        let previousManifest = manifest
        let previousOwners = owners
        let previousPaused = paused
        let previousExpanded = expanded
        let previousReacquiring = reacquiring
        let ids = Set(knownCollectionTracks(for: item).map(\.id))
        let id = ownerID(item)
        if item.kind == .track {
            manifest.excludedTrackIDs = (manifest.excludedTrackIDs ?? []).subtracting(ids)
        } else {
            reacquiring.insert(id)
            expanded.remove(id)
        }
        if let index = owners.firstIndex(where: { $0.id == id }) {
            paused.remove(id)
            owners[index].state = .queued
        } else {
            owners.append(FoundationDownloadOwner(id: id, item: item, tracks: [], state: .queued))
        }
        do { try save() } catch {
            manifest = previousManifest
            owners = previousOwners
            paused = previousPaused
            expanded = previousExpanded
            reacquiring = previousReacquiring
            reportStorageFailure()
            return
        }
        if activeOwner == id { worker?.cancel() }
        // A leased, previously excluded file can be retained again without replacing it.
        attemptedArtwork = attemptedArtwork.filter { attempt in
            !knownCollectionTracks(for: item).contains(where: {
                attempt.hasPrefix(artworkKey($0) + ":")
            })
        }
        readyFileIDs.formUnion(
            ids.filter { id in
                guard !isExcluded(id) else { return false }
                return knownCollectionTracks(for: item).first(where: { $0.id == id }).map {
                    fileIsPresent($0)
                }
                    == true
            })
        errorMessage = nil
        refreshStates()
        scheduleArtwork()
        schedule()
    }

    func isReady(_ item: FoundationItem) -> Bool {
        isLive && storageUsable && !isLoading && !isExcluded(item.id)
            && readyFileIDs.contains(item.id)
    }

    /// Inventory validates hashes; playback rechecks the filesystem before granting a new lease.
    private func fileIsPresent(_ item: FoundationItem) -> Bool {
        guard let file = manifest.files[item.id],
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
                    let reacquires = reacquiring.contains(owner.id)
                    let leasedFiles = manifest.files.filter { id, _ in
                        reacquires && tracks.contains(where: { $0.id == id })
                            && (leases[id] ?? 0) > 0
                    }
                    let verified = try await verifyReacquisitionFiles(leasedFiles, directory)
                    try check(epoch: epoch, ownerID: owner.id)
                    // Lease release may collect an excluded file while verification suspends.
                    // Only the same currently retained, present record can become ready.
                    let reusable = verified.filter { id, file in
                        guard let current = manifest.files[id],
                            current.name == file.name, current.bytes == file.bytes,
                            current.digest == file.digest,
                            let track = tracks.first(where: { $0.id == id })
                        else { return false }
                        return fileIsPresent(track)
                    }
                    guard
                        leasedFiles.keys.allSatisfy({
                            (leases[$0] ?? 0) == 0 || reusable[$0] != nil
                        })
                    else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    guard let index = owners.firstIndex(where: { $0.id == owner.id }) else {
                        return
                    }
                    let before = owners[index].tracks
                    let previousManifest = manifest
                    let previousExpanded = expanded
                    let previousReacquiring = reacquiring
                    owners[index].tracks = tracks
                    expanded.insert(owner.id)
                    if reacquires {
                        manifest.excludedTrackIDs = (manifest.excludedTrackIDs ?? []).subtracting(
                            Set(tracks.map(\.id)))
                        reacquiring.remove(owner.id)
                    }
                    do { try save() } catch {
                        owners[index].tracks = before
                        manifest = previousManifest
                        expanded = previousExpanded
                        reacquiring = previousReacquiring
                        throw error
                    }
                    readyFileIDs.formUnion(reusable.keys.filter { !isExcluded($0) })
                    installCollectionSnapshot(owner.item, tracks: tracks)
                    scheduleArtwork()
                }
                guard let current = owners.first(where: { $0.id == owner.id }) else { continue }
                setState(owner.id, .downloading)
                var visited: Set<String> = []
                for track in current.tracks where visited.insert(track.id).inserted {
                    try check(epoch: epoch, ownerID: owner.id)
                    if isExcluded(track.id) || isReady(track) { continue }
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
                            readyFileIDs.insert(track.id)
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
                scheduleArtwork()
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
        if state == .ready {
            owners[index].progress = 1
            owners[index].availability = availability(for: owners[index].item)
        }
    }

    private func refreshStates() {
        for index in owners.indices {
            let id = owners[index].id
            owners[index].availability = availability(for: owners[index].item)
            if paused.contains(id) { continue }
            if expanded.contains(id),
                owners[index].tracks.allSatisfy({ isExcluded($0.id) || isReady($0) })
            {
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
                paused: paused.contains($0.id), expanded: expanded.contains($0.id),
                reacquiresExcludedTracks: reacquiring.contains($0.id) ? true : nil)
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
        let referenced = retainedTrackIDs
        readyFileIDs.formIntersection(referenced)
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
        collectUnusedArtwork()
        do { try save() } catch { reportStorageFailure() }
        refreshBytes()
    }

    var audioBytes: Int64 { manifest.files.values.reduce(0) { $0 + $1.bytes } }
    var artworkBytes: Int64 { (manifest.artwork ?? [:]).values.reduce(0) { $0 + $1.file.bytes } }
    var otherBytes: Int64 { max(0, storageBytes - audioBytes - artworkBytes) }

    private func artworkKey(_ item: FoundationItem) -> String {
        let image = FoundationStoredDownloadItem(item.catalogArtworkItem)
        return image.kind + ":" + image.id
    }

    private var retainedArtworkItems: [FoundationItem] {
        var seen: Set<String> = []
        let items = owners.filter { expanded.contains($0.id) }.flatMap { owner in
            let collection =
                owner.item.kind == .track && isExcluded(owner.item.id) ? [] : [owner.item]
            return collection + owner.tracks.filter { !isExcluded($0.id) }
        }
        return items.map(\.catalogArtworkItem).filter {
            $0.kind != .track && seen.insert(artworkKey($0)).inserted
        }
    }

    /// Scoped, opaque identity for view task keys; unrelated artwork changes do not restart reads.
    func retainedArtworkIdentity(for item: FoundationItem) -> String? {
        guard isLive, storageUsable, !isLoading,
            retainedArtworkItems.contains(where: { artworkKey($0) == artworkKey(item) }),
            let record = manifest.artwork?[artworkKey(item)]
        else { return nil }
        return record.file.name
    }

    /// Local-only read. A failed tag refresh can keep the last validated rendition for this identity.
    func retainedArtwork(for item: FoundationItem) async -> Data? {
        guard isLive, storageUsable, !isLoading,
            retainedArtworkItems.contains(where: { artworkKey($0) == artworkKey(item) }),
            let record = manifest.artwork?[artworkKey(item)],
            let url = FoundationDownloadStorage.fileURL(record.file, directory: directory)
        else { return nil }
        let epoch = generation
        let file = record.file
        let maximumBytes = FoundationCurrentArtwork.maximumBytes
        let task = Task.detached(priority: .utility) {
            guard file.bytes > 0, file.bytes <= Int64(maximumBytes),
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == file.bytes
            else { return nil as Data? }
            return try? Data(contentsOf: url)
        }
        let data = await task.value
        guard isLive, generation == epoch, !Task.isCancelled,
            retainedArtworkItems.contains(where: { artworkKey($0) == artworkKey(item) })
        else { return nil }
        return data
    }

    private func scheduleArtwork() {
        guard isLive, storageUsable, !isLoading, allowed, artworkTask == nil else { return }
        let items = retainedArtworkItems.filter { item in
            let attempt = artworkKey(item) + ":" + (item.primaryImageTag ?? "")
            guard !attemptedArtwork.contains(attempt) else { return false }
            guard let existing = manifest.artwork?[artworkKey(item)] else { return true }
            return existing.item.artworkTag != item.primaryImageTag
        }
        guard !items.isEmpty else { return }
        let epoch = generation
        let cellular = allowsCellular
        artworkTask = Task { [weak self] in
            guard let self else { return }
            for item in items {
                guard self.isLive, self.allowed, self.generation == epoch, !Task.isCancelled else {
                    break
                }
                let key = self.artworkKey(item)
                let attempt = key + ":" + (item.primaryImageTag ?? "")
                do {
                    guard
                        let data = try await self.library.downloadArtwork(
                            for: item, size: 640, allowsCellular: cellular),
                        let rendition = try await Self.normalizeArtwork(data)
                    else {
                        self.attemptedArtwork.insert(attempt)
                        continue
                    }
                    try Task.checkCancellation()
                    guard self.isLive, self.allowed, self.generation == epoch,
                        self.retainedArtworkItems.contains(where: { self.artworkKey($0) == key })
                    else { continue }
                    try await self.storeArtwork(rendition, item: item, epoch: epoch)
                    self.attemptedArtwork.insert(attempt)
                } catch {
                    if Task.isCancelled || !self.isLive || self.generation != epoch { break }
                    self.attemptedArtwork.insert(attempt)
                    // Audio readiness and previous optional artwork survive failures.
                }
            }
            self.artworkTask = nil
            self.scheduleArtwork()
        }
    }

    nonisolated private static func normalizeArtwork(_ data: Data) async throws -> Data? {
        let task = Task.detached(priority: .utility) { () throws -> Data? in
            try Task.checkCancellation()
            let decoded = FoundationCurrentArtwork.decode(data)
            try Task.checkCancellation()
            guard let decoded,
                let output = CFDataCreateMutable(nil, 0),
                let encoder = CGImageDestinationCreateWithData(
                    output, "public.jpeg" as CFString, 1, nil)
            else { return nil }
            try Task.checkCancellation()
            CGImageDestinationAddImage(
                encoder, decoded.image,
                [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            let finalized = CGImageDestinationFinalize(encoder)
            try Task.checkCancellation()
            guard finalized else { return nil }
            let rendition = output as Data
            guard rendition.count <= FoundationCurrentArtwork.maximumBytes else { return nil }
            let valid = FoundationCurrentArtwork.decode(rendition) != nil
            try Task.checkCancellation()
            return valid ? rendition : nil
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func storeArtwork(_ data: Data, item: FoundationItem, epoch: UInt) async throws {
        let key = artworkKey(item)
        let stage = directory.appendingPathComponent("stage-" + UUID().uuidString + ".jpg")
        defer {
            if FileManager.default.fileExists(atPath: stage.path) {
                do { try FileManager.default.removeItem(at: stage) } catch {
                    reportStorageFailure()
                }
            }
        }
        try data.write(to: stage, options: .atomic)
        try FoundationDownloadStorage.protect(stage)
        let digest = try await FoundationDownloadStorage.digestOffMain(stage)
        try Task.checkCancellation()
        guard isLive, allowed, generation == epoch,
            retainedArtworkItems.contains(where: { artworkKey($0) == key })
        else { throw CancellationError() }
        let file = FoundationDownloadManifest.File(
            name: UUID().uuidString + ".jpg", bytes: Int64(data.count), digest: digest)
        let destination = directory.appendingPathComponent(file.name)
        try FileManager.default.moveItem(at: stage, to: destination)
        let previous = manifest.artwork?[key]
        do {
            try FoundationDownloadStorage.protect(destination)
            if manifest.artwork == nil { manifest.artwork = [:] }
            manifest.artwork?[key] = .init(item: FoundationStoredDownloadItem(item), file: file)
            do { try save() } catch {
                manifest.artwork?[key] = previous
                throw error
            }
        } catch {
            do { try FileManager.default.removeItem(at: destination) } catch {
                reportStorageFailure()
            }
            throw error
        }
        if let previous,
            let oldURL = FoundationDownloadStorage.fileURL(previous.file, directory: directory)
        {
            do { try FileManager.default.removeItem(at: oldURL) } catch { reportStorageFailure() }
        }
        artworkRevision &+= 1
        refreshBytes()
    }

    private func collectUnusedArtwork() {
        let retained = Set(retainedArtworkItems.map { artworkKey($0) })
        attemptedArtwork = attemptedArtwork.filter { attempt in
            retained.contains(where: { attempt.hasPrefix($0 + ":") })
        }
        for key in Array((manifest.artwork ?? [:]).keys) where !retained.contains(key) {
            guard let record = manifest.artwork?[key],
                let url = FoundationDownloadStorage.fileURL(record.file, directory: directory)
            else { continue }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                manifest.artwork?.removeValue(forKey: key)
                artworkRevision &+= 1
            } catch { reportStorageFailure() }
        }
    }

    func playbackResource(for item: FoundationItem, allowsRemoteFallback: Bool = true) async throws
        -> FoundationPlaybackResource
    {
        guard isLive else { throw CancellationError() }
        if isReady(item), !fileIsPresent(item) {
            readyFileIDs.remove(item.id)
            refreshStates()
        }
        if isReady(item), let file = manifest.files[item.id],
            let url = FoundationDownloadStorage.fileURL(file, directory: directory)
        {
            leases[item.id, default: 0] += 1
            return FoundationPlaybackResource(url: url) { [self] in
                await releaseLease(item.id)
            }
        }
        guard allowsRemoteFallback else { throw FoundationLibraryError.unavailable }
        let epoch = generation
        let url = try await library.playbackURL(for: item)
        guard isLive, epoch == generation else { throw CancellationError() }
        return FoundationPlaybackResource(url: url, release: {})
    }

    private func releaseLease(_ id: String) {
        leases[id] = max(0, (leases[id] ?? 0) - 1)
        if leases.values.allSatisfy({ $0 == 0 }), !leaseWaiters.isEmpty {
            let waiters = leaseWaiters.values
            leaseWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: true) }
            return
        }
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
                    installCollectionSnapshot(item, tracks: entries.map(\.item), refreshed: true)
                    if activeOwner == owner.id { worker?.cancel() }
                    collectUnusedFiles()
                    scheduleArtwork()
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
        for model in collectionModels.values { model.clearRetainedData() }
        collectionModels.removeAll()
        artworkTask?.cancel()
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
        artworkTask?.cancel()
        worker?.cancel()
        syncTask?.cancel()
        await artworkTask?.value
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
            let previousReacquiring = reacquiring
            let previousManifest = manifest
            owners = []
            paused = []
            expanded = []
            reacquiring = []
            manifest.excludedTrackIDs = nil
            do { try save() } catch {
                owners = previousOwners
                paused = previousPaused
                expanded = previousExpanded
                reacquiring = previousReacquiring
                manifest = previousManifest
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
            attemptedArtwork = []
            artworkRevision &+= 1
            readyFileIDs = []
            owners = []
            paused = []
            expanded = []
            reacquiring = []
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

    /// Account teardown has already stopped playback; wait for its asynchronous lease releases.
    private func waitForPlaybackLeases() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if leases.values.allSatisfy({ $0 == 0 }) {
                    continuation.resume(returning: true)
                } else {
                    leaseWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.leaseWaiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    func clearAccount(waitForPlayback: Bool = false) async -> Bool {
        invalidate()
        await artworkTask?.value
        await worker?.value
        await syncTask?.value
        await inventoryTask?.value
        inventoryTask = nil
        isLoading = false
        if waitForPlayback {
            pendingClear = false
            let released = await waitForPlaybackLeases()
            if !released, leases.values.contains(where: { $0 > 0 }) {
                pendingClear = true
                return false
            }
        }
        guard leases.values.allSatisfy({ $0 == 0 }) else {
            pendingClear = true
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            owners = []
            reacquiring = []
            readyFileIDs = []
            manifest = FoundationDownloadManifest()
            artworkRevision &+= 1
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
