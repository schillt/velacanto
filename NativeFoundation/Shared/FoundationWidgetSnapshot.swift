import Darwin
import Foundation

enum FoundationWidgetDisplayMode: String, Codable, CaseIterable, Hashable, Sendable {
    case currentSong, recentCollection
}

/// Presentation metadata only. The extension receives no credential, media URL or queue database.
struct FoundationWidgetSnapshot: Codable, Equatable, Sendable {
    static let kind = "VelaCantoPlaybackWidget"
    static let maximumBytes = 16_384
    static let maximumArtworkBytes = 262_144
    enum Presentation: String, Codable, Sendable { case empty, track, collection }
    enum Action: String, Codable, Sendable { case play, pause, collection }

    struct Collection: Codable, Equatable, Sendable {
        let id: String
        let kind: String
        let title: String
        let subtitle: String
        let imageTag: String?

        func matches(id: String?, kind: String?) -> Bool { self.id == id && self.kind == kind }
        func sameIdentity(as other: Self?) -> Bool { matches(id: other?.id, kind: other?.kind) }
        func sameArtwork(as other: Self?) -> Bool {
            sameIdentity(as: other) && imageTag == other?.imageTag
        }
        var isValid: Bool {
            ["album", "playlist"].contains(kind) && Self.valid(id, maximum: 256)
                && Self.valid(title, maximum: 256) && subtitle.utf8.count <= 512
                && !subtitle.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                && (imageTag.map { Self.valid($0, maximum: 256) } ?? true)
        }
        private static func valid(_ value: String, maximum: Int) -> Bool {
            !value.isEmpty && value.utf8.count <= maximum
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }

    let version: Int
    let presentation: Presentation
    let scope: String?
    let occurrence: UUID?
    let collection: Collection?
    let title: String
    let detail: String
    let isPlaying: Bool
    var artworkName: String?
    var recentCollection: Collection?
    var recentArtworkName: String?

    init(
        version: Int, presentation: Presentation, scope: String?, occurrence: UUID?,
        collection: Collection?, title: String, detail: String, isPlaying: Bool,
        artworkName: String? = nil, recentCollection: Collection? = nil,
        recentArtworkName: String? = nil
    ) {
        self.version = version
        self.presentation = presentation
        self.scope = scope
        self.occurrence = occurrence
        self.collection = collection
        self.title = title
        self.detail = detail
        self.isPlaying = isPlaying
        self.artworkName = artworkName
        self.recentCollection = recentCollection
        self.recentArtworkName = recentArtworkName
    }

    private enum CodingKeys: String, CodingKey {
        case version, presentation, scope, occurrence, collection, title, detail, isPlaying
        case artworkName, recentCollection, recentArtworkName
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        presentation = try values.decode(Presentation.self, forKey: .presentation)
        scope = try values.decodeIfPresent(String.self, forKey: .scope)
        occurrence = try values.decodeIfPresent(UUID.self, forKey: .occurrence)
        collection = try values.decodeIfPresent(Collection.self, forKey: .collection)
        title = try values.decode(String.self, forKey: .title)
        detail = try values.decode(String.self, forKey: .detail)
        isPlaying = try values.decode(Bool.self, forKey: .isPlaying)
        artworkName = try values.decodeIfPresent(String.self, forKey: .artworkName)
        let recent = try? values.decodeIfPresent(Collection.self, forKey: .recentCollection)
        let image = try? values.decodeIfPresent(String.self, forKey: .recentArtworkName)
        let validImage =
            !values.contains(.recentArtworkName)
            || (try? values.decodeNil(forKey: .recentArtworkName)) == true
            || image.map(Self.validArtworkName) == true
        if let recent, recent.isValid, validImage, presentation != .empty, scope != nil {
            recentCollection = recent
            recentArtworkName = image
        } else {
            // New optional cache fields must not destroy a valid v1 current-song record.
            recentCollection = nil
            recentArtworkName = nil
        }
    }

    static let empty = Self(
        version: 1, presentation: .empty, scope: nil, occurrence: nil, collection: nil,
        title: "VelaCanto", detail: "Open VelaCanto to choose music", isPlaying: false)

    static func validArtworkName(_ value: String) -> Bool {
        value.hasSuffix(".jpg") && UUID(uuidString: String(value.dropLast(4))) != nil
    }
    var isValid: Bool {
        guard version == 1, title.utf8.count <= 512, detail.utf8.count <= 512,
            !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            !detail.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            collection?.isValid ?? true, recentCollection?.isValid ?? true,
            artworkName.map(Self.validArtworkName) ?? true,
            recentArtworkName.map(Self.validArtworkName) ?? true,
            recentArtworkName == nil || recentCollection != nil
        else { return false }
        if presentation == .empty {
            return scope == nil && occurrence == nil && collection == nil && !isPlaying
                && artworkName == nil && recentCollection == nil && recentArtworkName == nil
        }
        guard let scope, scope.count == 64,
            scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return false }
        return presentation == .track ? occurrence != nil : occurrence == nil && collection != nil
    }

    /// Old v1 records can supply only a proven current/idle collection, never guessed membership.
    var effectiveRecent: Collection? { recentCollection ?? collection }
    var referencedArtwork: Set<String> { Set([artworkName, recentArtworkName].compactMap { $0 }) }
    var action: Action? {
        switch presentation {
        case .empty: nil
        case .track: isPlaying ? .pause : .play
        case .collection: .collection
        }
    }

    func display(_ mode: FoundationWidgetDisplayMode) -> FoundationWidgetDisplay {
        if mode == .currentSong {
            guard presentation == .track else { return .empty }
            return .init(
                title: title, detail: detail, artworkName: artworkName,
                action: action, occurrence: occurrence, collection: nil)
        }
        guard let recent = effectiveRecent else { return .empty }
        let matching = presentation == .track && collection?.sameIdentity(as: recent) == true
        let image =
            recentCollection != nil
            ? recentArtworkName
            : presentation == .collection ? artworkName : nil
        return .init(
            title: recent.title, detail: recent.subtitle, artworkName: image,
            action: matching ? action : .collection,
            occurrence: matching ? occurrence : nil, collection: recent)
    }
}

struct FoundationWidgetDisplay: Equatable, Sendable {
    let title: String
    let detail: String
    let artworkName: String?
    let action: FoundationWidgetSnapshot.Action?
    let occurrence: UUID?
    let collection: FoundationWidgetSnapshot.Collection?
    static let empty = Self(
        title: "VelaCanto", detail: "Open VelaCanto to choose music",
        artworkName: nil, action: nil, occurrence: nil, collection: nil)
}

struct FoundationWidgetCommand: Sendable {
    let scope: String
    let occurrence: UUID?
    let collectionID: String?
    let action: FoundationWidgetSnapshot.Action
    var mode: FoundationWidgetDisplayMode = .currentSong
    var collectionKind: String? = nil

    func matches(_ snapshot: FoundationWidgetSnapshot) -> Bool {
        guard snapshot.isValid, snapshot.scope == scope else { return false }
        if action == .collection {
            return mode == .recentCollection && occurrence == nil
                && snapshot.effectiveRecent?.matches(id: collectionID, kind: collectionKind) == true
        }
        guard snapshot.presentation == .track, let occurrence,
            occurrence == snapshot.occurrence
        else { return false }
        if mode == .currentSong { return collectionID == nil && collectionKind == nil }
        return snapshot.effectiveRecent?.matches(id: collectionID, kind: collectionKind) == true
            && snapshot.collection?.matches(id: collectionID, kind: collectionKind) == true
    }
}

/// Fixed bounded records in the app group. Callers supply disposable roots in tests.
struct FoundationWidgetStore: Sendable {
    enum Location: Sendable {
        case disabled, unavailable
        case directory(URL)
    }
    enum Failure: Error { case unavailable, invalidRecord, unsafePath }
    let location: Location
    #if FOUNDATION_ISOLATED_TEST_HOST
        enum PublicationFailure: Equatable, Sendable { case afterFirstArtwork, beforeMetadata }
        var testFailure: PublicationFailure? = nil
    #endif

    static var systemLocation: Location {
        #if DEBUG
            if NSClassFromString("XCTestCase") != nil
                || ProcessInfo.processInfo.arguments.contains("-foundationTesting")
            {
                return .disabled
            }
        #endif
        guard
            let identifier = Bundle.main.object(
                forInfoDictionaryKey: "VelacantoWidgetAppGroupIdentifier") as? String,
            !identifier.isEmpty
        else { return .disabled }
        guard
            let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: identifier)
        else { return .unavailable }
        return .directory(root.appendingPathComponent("PlaybackWidget", isDirectory: true))
    }

    func load() throws -> FoundationWidgetSnapshot {
        guard let root = try directory(create: false) else { return .empty }
        let file = root.appendingPathComponent("snapshot.json")
        guard try attributesIfPresent(file) != nil else { return .empty }
        let data = try read(file, maximum: FoundationWidgetSnapshot.maximumBytes)
        let snapshot = try JSONDecoder().decode(FoundationWidgetSnapshot.self, from: data)
        guard snapshot.isValid else { throw Failure.invalidRecord }
        return snapshot
    }

    func artwork(
        for snapshot: FoundationWidgetSnapshot,
        mode: FoundationWidgetDisplayMode = .currentSong
    ) -> Data? {
        guard snapshot.isValid, let name = snapshot.display(mode).artworkName,
            let root = try? directory(create: false)
        else { return nil }
        return try? read(
            root.appendingPathComponent(name),
            maximum: FoundationWidgetSnapshot.maximumArtworkBytes)
    }

    func save(
        _ snapshot: FoundationWidgetSnapshot, artwork: Data?, recentArtwork: Data? = nil,
        preservingCurrentArtwork: Bool = true
    )
        throws
    {
        guard snapshot.isValid, artwork == nil || snapshot.presentation != .empty,
            recentArtwork == nil || snapshot.recentCollection != nil
        else {
            throw Failure.invalidRecord
        }
        guard let root = try directory(create: true) else { return }
        let previous = try load()
        let inventory = try ownedFiles(in: root)
        try removeOrphans(inventory.files, retaining: previous.referencedArtwork)
        guard inventory.complete else { throw Failure.invalidRecord }
        // Two committed slots + two new images + one metadata/staging file fit the
        // existing eight-entry transaction admission. No old/new history is retained.
        let incoming = [artwork, recentArtwork].compactMap { $0 }.count
        guard 1 + previous.referencedArtwork.count + incoming + 1 <= 8 else {
            throw Failure.invalidRecord
        }
        for image in [artwork, recentArtwork].compactMap({ $0 }) {
            guard image.count <= FoundationWidgetSnapshot.maximumArtworkBytes else {
                throw Failure.invalidRecord
            }
        }
        var snapshot = snapshot
        var created: [URL] = []
        func imageName(_ data: Data) throws -> String {
            let file = root.appendingPathComponent(UUID().uuidString + ".jpg")
            created.append(file)
            try write(data, to: file)
            #if FOUNDATION_ISOLATED_TEST_HOST
                if testFailure == .afterFirstArtwork, created.count == 1 {
                    throw Failure.unavailable
                }
            #endif
            return file.lastPathComponent
        }
        do {
            if let artwork {
                snapshot.artworkName = try imageName(artwork)
            } else if preservingCurrentArtwork, previous.scope == snapshot.scope,
                previous.presentation == snapshot.presentation,
                previous.occurrence == snapshot.occurrence,
                snapshot.presentation == .track
                    || (previous.collection?.sameArtwork(as: snapshot.collection)
                        ?? (snapshot.collection == nil)),
                let name = previous.artworkName,
                (try? read(
                    root.appendingPathComponent(name),
                    maximum: FoundationWidgetSnapshot.maximumArtworkBytes)) != nil
            {
                snapshot.artworkName = name
            } else {
                snapshot.artworkName = nil
            }
            if let recentArtwork, snapshot.recentCollection != nil {
                snapshot.recentArtworkName = try imageName(recentArtwork)
            } else if previous.scope == snapshot.scope,
                snapshot.recentCollection?.sameArtwork(as: previous.effectiveRecent) == true,
                let name = previous.display(.recentCollection).artworkName,
                (try? read(
                    root.appendingPathComponent(name),
                    maximum: FoundationWidgetSnapshot.maximumArtworkBytes)) != nil
            {
                snapshot.recentArtworkName = name
            } else {
                snapshot.recentArtworkName = nil
            }
            let data = try JSONEncoder().encode(snapshot)
            guard snapshot.isValid, data.count <= FoundationWidgetSnapshot.maximumBytes else {
                throw Failure.invalidRecord
            }
            #if FOUNDATION_ISOLATED_TEST_HOST
                if testFailure == .beforeMetadata { throw Failure.unavailable }
            #endif
            // Nothing fallible follows metadata commit. New referenced images are never rolled back.
            try write(data, to: root.appendingPathComponent("snapshot.json"))
        } catch {
            for file in created { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    func clear(scope: String) -> Bool {
        do {
            guard let root = try directory(create: false) else { return true }
            let snapshot = try load()
            guard snapshot.scope == nil || snapshot.scope == scope else { return false }
            let inventory = try ownedFiles(in: root)
            try removeOrphans(inventory.files, retaining: snapshot.referencedArtwork)
            guard inventory.complete else { return false }
            try FileManager.default.removeItem(at: root)
            return !FileManager.default.fileExists(atPath: root.path)
        } catch { return false }
    }

    private func removeOrphans(_ files: [URL], retaining artworkNames: Set<String>) throws {
        for file in files
        where file.lastPathComponent != "snapshot.json"
            && !artworkNames.contains(file.lastPathComponent)
        {
            try FileManager.default.removeItem(at: file)
        }
    }

    private struct OwnedInventory {
        let files: [URL]
        let complete: Bool
    }

    private func ownedFiles(in root: URL) throws -> OwnedInventory {
        let errors = EnumerationErrors()
        guard
            let entries = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, _ in
                    errors.record()
                    return false
                })
        else { throw Failure.unsafePath }
        var files: [URL] = []
        var complete = false
        while files.count < 8 {
            guard let entry = entries.nextObject() else {
                complete = true
                break
            }
            guard let file = entry as? URL else { throw Failure.unsafePath }
            let name = file.lastPathComponent
            guard
                name == "snapshot.json"
                    || (name.hasSuffix(".jpg") && UUID(uuidString: String(name.dropLast(4))) != nil)
                    || (name.hasPrefix(".widget-stage-")
                        && UUID(uuidString: String(name.dropFirst(14))) != nil)
            else { throw Failure.unsafePath }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw Failure.unsafePath
            }
            files.append(file)
        }
        if !complete { complete = entries.nextObject() == nil }
        guard !errors.failed else { throw Failure.unsafePath }
        return OwnedInventory(files: files, complete: complete)
    }

    private final class EnumerationErrors: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func record() {
            lock.lock()
            value = true
            lock.unlock()
        }
        var failed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func directory(create: Bool) throws -> URL? {
        switch location {
        case .disabled: return nil
        case .unavailable: throw Failure.unavailable
        case .directory(let root):
            if try attributesIfPresent(root) == nil {
                guard create else { return nil }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw Failure.unsafePath
            }
            return root
        }
    }

    private func attributesIfPresent(_ file: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: file.path) } catch {
            let value = error as NSError
            guard value.domain == NSCocoaErrorDomain,
                [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(value.code)
            else { throw error }
            return nil
        }
    }

    private func read(_ file: URL, maximum: Int) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw Failure.unsafePath
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw Failure.invalidRecord }
        return data
    }

    private func write(_ data: Data, to file: URL) throws {
        if let attributes = try attributesIfPresent(file) {
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw Failure.unsafePath
            }
        }
        var stage = file.deletingLastPathComponent().appendingPathComponent(
            ".widget-stage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        #if os(iOS)
            try data.write(
                to: stage, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: stage, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: stage.path)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try stage.setResourceValues(values)
        guard rename(stage.path, file.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
