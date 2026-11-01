import Combine
import CryptoKit
import Foundation

struct FoundationMusicLibraryChoice: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String

    var isValid: Bool {
        FoundationJellyfinLibrary.validID(id) && !name.isEmpty && name.utf8.count <= 512
    }
}

/// This owner changes catalog scope only; playback and downloads keep the account adapter.
@MainActor
final class FoundationMusicLibrarySelection: ObservableObject {
    @Published private(set) var selectedID: String?
    @Published private(set) var selectedName: String?
    @Published private(set) var unavailable = false
    @Published private(set) var selectionReadFailed: Bool
    private let load: @Sendable () async throws -> [FoundationMusicLibraryChoice]
    private let save: (FoundationMusicLibraryChoice?) throws -> Void
    private let apply: (String?, Bool) -> Void
    private let allowsNetwork: () -> Bool
    private var epoch = 0
    private var active = true

    init(
        selected: FoundationMusicLibraryChoice? = nil,
        selectionReadFailed: Bool = false,
        load: @escaping @Sendable () async throws -> [FoundationMusicLibraryChoice],
        save: @escaping (FoundationMusicLibraryChoice?) throws -> Void,
        allowsNetwork: @escaping () -> Bool = { true },
        apply: @escaping (String?, Bool) -> Void
    ) {
        self.selectionReadFailed = selectionReadFailed
        selectedID = selected?.id
        selectedName = selected?.name
        self.load = load
        self.save = save
        self.apply = apply
        self.allowsNetwork = allowsNetwork
    }

    func loadChoices() async throws -> [FoundationMusicLibraryChoice] {
        let owner = epoch
        guard active else { throw CancellationError() }
        guard allowsNetwork() else { throw FoundationLibraryError.unavailable }
        let choices = try await load()
        try Task.checkCancellation()
        guard active, epoch == owner else { throw CancellationError() }
        guard choices.count <= 128, choices.allSatisfy(\.isValid),
            Set(choices.map(\.id)).count == choices.count
        else { throw FoundationLibraryError.invalidResponse }
        return choices
    }

    func select(_ choice: FoundationMusicLibraryChoice?) async throws {
        guard active, allowsNetwork() else { throw FoundationLibraryError.unavailable }
        epoch += 1
        let owner = epoch
        if let choice {
            let choices = try await loadChoices()
            guard choices.contains(choice) else { throw FoundationLibraryError.unavailable }
        }
        try Task.checkCancellation()
        guard active, epoch == owner else { throw CancellationError() }
        guard allowsNetwork() else { throw FoundationLibraryError.unavailable }
        try save(choice)
        selectedID = choice?.id
        selectedName = choice?.name
        unavailable = false
        selectionReadFailed = false
        apply(selectedID, true)
    }

    /// Offline never lists libraries. Reconnect validates a retained choice without changing it.
    func validateSavedChoice() async {
        guard selectedID != nil, active, allowsNetwork() else { return }
        let owner = epoch
        do {
            let choices = try await loadChoices()
            guard active, epoch == owner, !Task.isCancelled else { return }
            unavailable = !choices.contains { $0.id == selectedID }
            apply(selectedID, !unavailable)
        } catch is CancellationError {
            return
        } catch {
            guard active, epoch == owner, !Task.isCancelled else { return }
            unavailable = true
            apply(selectedID, false)
        }
    }

    func invalidate() {
        active = false
        epoch += 1
    }
}

struct FoundationMusicLibraryStore {
    enum StorageError: Error { case invalidRecord, unsafePath }
    let scope: String
    var root: URL = Self.defaultRoot
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Velacanto/MusicLibrarySelections", isDirectory: true)
    }
    private var directory: URL { root.appendingPathComponent(scope, isDirectory: true) }
    private var file: URL { directory.appendingPathComponent("selection-v1.json") }

    static func digest(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func validatePath() throws {
        guard scope.count == 64, scope.allSatisfy({ $0.isHexDigit }) else {
            throw StorageError.unsafePath
        }
        try Self.rejectSymbolicLinks(file)
    }

    private static func rejectSymbolicLinks(_ url: URL) throws {
        // Foundation canonicalizes /private/var and /private/tmp back to their system
        // aliases even after resolvingSymlinksInPath(). Expand only these known aliases;
        // retain and reject symbolic links anywhere in the application-owned path.
        var candidate = url.path
        if candidate == "/var" || candidate.hasPrefix("/var/")
            || candidate == "/tmp" || candidate.hasPrefix("/tmp/")
        {
            candidate = "/private" + candidate
        }
        while candidate != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: candidate),
                attributes[.type] as? FileAttributeType == .typeSymbolicLink
            {
                throw StorageError.unsafePath
            }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
    }

    func load() throws -> FoundationMusicLibraryChoice? {
        try validatePath()
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber, size.intValue <= 4096
        else { throw StorageError.invalidRecord }
        let choice = try JSONDecoder().decode(
            FoundationMusicLibraryChoice.self, from: Data(contentsOf: file))
        guard choice.isValid else { throw StorageError.invalidRecord }
        return choice
    }

    func save(_ choice: FoundationMusicLibraryChoice?) throws {
        try validatePath()
        guard let choice else {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            return
        }
        guard choice.isValid else { throw StorageError.invalidRecord }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.protect(root)
        try Self.protect(directory)
        let data = try JSONEncoder().encode(choice)
        let staged = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: staged) }
        #if os(iOS)
            try data.write(
                to: staged, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: staged, options: .atomic)
        #endif
        try Self.protect(staged)
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: file)
        }
    }

    private static func protect(_ url: URL) throws {
        var protected = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        try FileManager.default.setAttributes(
            [.posixPermissions: url.hasDirectoryPath ? 0o700 : 0o600], ofItemAtPath: url.path)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
        #endif
    }

    static func clear(retaining scope: String? = nil, root: URL = defaultRoot) -> Bool {
        do {
            try rejectSymbolicLinks(root)
            guard FileManager.default.fileExists(atPath: root.path) else { return true }
            let children = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
            for child in children where child.lastPathComponent != scope {
                guard child.lastPathComponent.count == 64,
                    child.lastPathComponent.allSatisfy({ $0.isHexDigit }),
                    try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                else { throw StorageError.unsafePath }
                try rejectSymbolicLinks(child)
                try FileManager.default.removeItem(at: child)
            }
            return true
        } catch { return false }
    }
}
