import CryptoKit
import Darwin
import Foundation
import Security

/// One isolated Keychain entry. Loading does not validate or contact a server.
enum FoundationCredentials {
    /// A narrow seam keeps credential-policy tests away from real saved sign-ins.
    struct Operations {
        var update: ([String: Any], [String: Any]) -> OSStatus
        var add: ([String: Any]) -> OSStatus
        var copy: ([String: Any]) -> (OSStatus, CFTypeRef?)
        var delete: ([String: Any]) -> OSStatus

        static var system: Operations {
            Operations(
                update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
                add: { SecItemAdd($0 as CFDictionary, nil) },
                copy: {
                    var result: CFTypeRef?
                    let status = SecItemCopyMatching($0 as CFDictionary, &result)
                    return (status, result)
                },
                delete: { SecItemDelete($0 as CFDictionary) })
        }
    }

    private static let service = "Velacanto.NativeFoundation.Session"
    private static let account = "current-session"

    private static var query: [String: Any] {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        #if os(macOS)
            // Never consult the legacy login keychain, even when this store is empty.
            var query = base
            query[kSecUseDataProtectionKeychain as String] = true
            return query
        #else
            return base
        #endif
    }

    static func save(
        _ session: FoundationSession, operations: Operations = .system, accessGroup: String? = nil,
        generation: Data? = nil
    ) throws {
        _ = try FoundationJellyfinLibrary.validatedServerURL(session.serverURL)
        let data = try JSONEncoder().encode(session)
        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let generation { attributes[kSecAttrGeneric as String] = generation }
        var selected = query
        if let accessGroup { selected[kSecAttrAccessGroup as String] = accessGroup }
        let status = operations.update(selected, attributes)
        if status == errSecItemNotFound {
            let insertion = selected.merging(attributes) { _, new in new }
            guard operations.add(insertion) == errSecSuccess else {
                throw FoundationLibraryError.credentials
            }
        } else if status != errSecSuccess {
            throw FoundationLibraryError.credentials
        }
    }

    static func load(
        operations: Operations = .system, accessGroup: String? = nil
    ) throws -> FoundationSession? {
        var request = query
        if let accessGroup { request[kSecAttrAccessGroup as String] = accessGroup }
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = operations.copy(request)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw FoundationLibraryError.credentials
        }
        do {
            let session = try JSONDecoder().decode(FoundationSession.self, from: data)
            _ = try FoundationJellyfinLibrary.validatedServerURL(session.serverURL)
            guard !session.accessToken.isEmpty, FoundationJellyfinLibrary.validID(session.userID),
                UUID(uuidString: session.deviceID) != nil
            else { throw FoundationLibraryError.credentials }
            return session
        } catch { throw FoundationLibraryError.credentials }
    }

    static func clear(operations: Operations = .system, accessGroup: String? = nil) throws {
        var selected = query
        if let accessGroup { selected[kSecAttrAccessGroup as String] = accessGroup }
        let status = operations.delete(selected)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FoundationLibraryError.credentials
        }
    }
}

/// A single local-only sign-out intent. It contains no credential or server address.
/// The marker is not authority to delete native data by itself.
enum FoundationSignOutIntentStore {
    struct Intent: Codable, Equatable, Sendable {
        let version: Int
        let operation: UUID
        let scope: String
        let accessGroup: String
        let credentialGeneration: Data?
        let cleanupComplete: Bool?

        init(
            version: Int, operation: UUID, scope: String, accessGroup: String,
            credentialGeneration: Data? = nil, cleanupComplete: Bool? = nil
        ) {
            self.version = version
            self.operation = operation
            self.scope = scope
            self.accessGroup = accessGroup
            self.credentialGeneration = credentialGeneration
            self.cleanupComplete = cleanupComplete
        }

        var isValid: Bool {
            guard version == 1, scope.utf8.count == 64, !accessGroup.isEmpty,
                scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { return false }
            guard let credentialGeneration else { return true }
            guard let string = String(data: credentialGeneration, encoding: .utf8),
                let uuid = UUID(uuidString: string)
            else { return false }
            return uuid.uuidString == string
        }
    }

    enum StorageError: Error { case unavailable, ambiguous, invalid, existing, stale }
    private static let service = "Velacanto.NativeFoundation.Session"
    private static let intentAccount = "pending-sign-out"
    private static let credentialAccount = "current-session"
    private static let maximumData = 1024

    private static func query(account: String) -> [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        #if os(macOS)
            result[kSecUseDataProtectionKeychain as String] = true
        #endif
        return result
    }

    private static func attributes(
        account: String, operations: FoundationCredentials.Operations
    ) throws -> [[String: Any]] {
        var request = query(account: account)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, value) = operations.copy(request)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let values = value as? [[String: Any]] else {
            throw StorageError.unavailable
        }
        guard values.count <= 1 else { throw StorageError.ambiguous }
        return values
    }

    static func load(operations: FoundationCredentials.Operations = .system) throws -> Intent? {
        let matches = try attributes(account: intentAccount, operations: operations)
        guard let attributes = matches.first else { return nil }
        guard let group = attributes[kSecAttrAccessGroup as String] as? String, !group.isEmpty,
            let generic = attributes[kSecAttrGeneric as String] as? Data,
            let operationString = String(data: generic, encoding: .utf8),
            let operation = UUID(uuidString: operationString),
            operation.uuidString == operationString
        else { throw StorageError.invalid }
        var request = query(account: intentAccount)
        request[kSecAttrAccessGroup as String] = group
        request[kSecAttrGeneric as String] = generic
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, value) = operations.copy(request)
        guard status == errSecSuccess, let data = value as? Data, data.count <= maximumData,
            let intent = try? JSONDecoder().decode(Intent.self, from: data), intent.isValid,
            intent.operation == operation, intent.accessGroup == group
        else { throw StorageError.invalid }
        return intent
    }

    struct CredentialIdentity {
        let accessGroup: String
        let generation: Data?
    }

    static func credentialIdentity(
        operations: FoundationCredentials.Operations = .system
    ) throws -> CredentialIdentity? {
        let credentials = try attributes(account: credentialAccount, operations: operations)
        guard let attributes = credentials.first else { return nil }
        guard let group = attributes[kSecAttrAccessGroup as String] as? String, !group.isEmpty
        else {
            throw StorageError.unavailable
        }
        let generation = attributes[kSecAttrGeneric as String] as? Data
        if let generation {
            guard let string = String(data: generation, encoding: .utf8),
                let uuid = UUID(uuidString: string), uuid.uuidString == string
            else { throw StorageError.invalid }
        } else if attributes[kSecAttrGeneric as String] != nil {
            throw StorageError.invalid
        }
        return CredentialIdentity(accessGroup: group, generation: generation)
    }

    /// Assign only metadata to the selected existing credential while its account
    /// transaction lock is held. Never rewrite its secret or another access group.
    static func assignCredentialGeneration(
        accessGroup: String, generation: Data = Data(UUID().uuidString.utf8),
        operations: FoundationCredentials.Operations = .system
    ) throws -> Data {
        guard let text = String(data: generation, encoding: .utf8),
            let uuid = UUID(uuidString: text), uuid.uuidString == text
        else { throw StorageError.invalid }
        guard let identity = try credentialIdentity(operations: operations),
            identity.accessGroup == accessGroup, identity.generation == nil
        else { throw StorageError.stale }
        var selected = query(account: credentialAccount)
        selected[kSecAttrAccessGroup as String] = accessGroup
        guard operations.update(selected, [kSecAttrGeneric as String: generation]) == errSecSuccess
        else { throw StorageError.unavailable }
        guard let verified = try credentialIdentity(operations: operations),
            verified.accessGroup == accessGroup, verified.generation == generation
        else { throw StorageError.ambiguous }
        return generation
    }

    static func credentialAccessGroup(
        operations: FoundationCredentials.Operations = .system
    ) throws -> String? {
        try credentialIdentity(operations: operations)?.accessGroup
    }

    static func create(
        scope: String, operation: UUID = UUID(),
        operations: FoundationCredentials.Operations = .system
    ) throws -> Intent {
        guard try load(operations: operations) == nil else { throw StorageError.existing }
        guard let identity = try credentialIdentity(operations: operations) else {
            throw StorageError.unavailable
        }
        let group = identity.accessGroup
        let intent = Intent(
            version: 1, operation: operation, scope: scope, accessGroup: group,
            credentialGeneration: identity.generation)
        guard intent.isValid else { throw StorageError.invalid }
        let data = try JSONEncoder().encode(intent)
        guard data.count <= maximumData else { throw StorageError.invalid }
        var addition = query(account: intentAccount)
        addition[kSecAttrAccessGroup as String] = group
        addition[kSecAttrGeneric as String] = Data(intent.operation.uuidString.utf8)
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard operations.add(addition) == errSecSuccess else { throw StorageError.unavailable }
        guard try load(operations: operations) == intent else { throw StorageError.ambiguous }
        return intent
    }

    static func markCleanupComplete(
        _ expected: Intent, operations: FoundationCredentials.Operations = .system
    ) throws -> Intent {
        guard expected.isValid, try load(operations: operations) == expected else {
            throw StorageError.stale
        }
        if expected.cleanupComplete == true { return expected }
        let completed = Intent(
            version: expected.version, operation: expected.operation, scope: expected.scope,
            accessGroup: expected.accessGroup, credentialGeneration: expected.credentialGeneration,
            cleanupComplete: true)
        let data = try JSONEncoder().encode(completed)
        guard data.count <= maximumData else { throw StorageError.invalid }
        var selected = query(account: intentAccount)
        selected[kSecAttrAccessGroup as String] = expected.accessGroup
        selected[kSecAttrGeneric as String] = Data(expected.operation.uuidString.utf8)
        guard operations.update(selected, [kSecValueData as String: data]) == errSecSuccess else {
            throw StorageError.unavailable
        }
        guard try load(operations: operations) == completed else { throw StorageError.ambiguous }
        return completed
    }

    static func remove(
        _ expected: Intent, operations: FoundationCredentials.Operations = .system
    ) throws {
        guard expected.isValid, try load(operations: operations) == expected else {
            throw StorageError.stale
        }
        var deletion = query(account: intentAccount)
        deletion[kSecAttrAccessGroup as String] = expected.accessGroup
        deletion[kSecAttrGeneric as String] = Data(expected.operation.uuidString.utf8)
        guard operations.delete(deletion) == errSecSuccess else { throw StorageError.stale }
        guard try load(operations: operations) == nil else { throw StorageError.ambiguous }
    }
}

/// Compares complete path components, never a string prefix or a resolved symlink.
nonisolated enum FoundationTrustedAccountPath {
    static func components(_ root: URL, below anchor: URL) -> [String]? {
        guard root.isFileURL, anchor.isFileURL else { return nil }
        let path = root.standardizedFileURL.pathComponents
        let base = anchor.standardizedFileURL.pathComponents
        guard path.count >= base.count, path.starts(with: base) else { return nil }
        let tail = Array(path.dropFirst(base.count))
        guard tail.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") })
        else { return nil }
        return tail
    }
}

/// The system-provided Application Support URL is the production sandbox anchor.
/// Only app-owned components below that anchor are traversed with no-follow checks.
private enum FoundationAccountLockDirectory {
    static func open(root: URL?) -> Int32 {
        let anchor: String
        let components: [String]
        if let root {
            let temporary = FileManager.default.temporaryDirectory
            if let relative = FoundationTrustedAccountPath.components(root, below: temporary) {
                anchor = temporary.path
                components = relative
            } else {
                var path = root.standardizedFileURL.path
                if path == "/var" || path.hasPrefix("/var/") || path == "/tmp"
                    || path.hasPrefix("/tmp/")
                {
                    path = "/private" + path
                }
                guard path.hasPrefix("/") else { return -1 }
                anchor = "/"
                components = path.split(separator: "/").map(String.init)
            }
        } else {
            guard
                let support = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                ).first
            else { return -1 }
            do {
                try FileManager.default.createDirectory(
                    at: support, withIntermediateDirectories: true)
            } catch { return -1 }
            anchor = support.path
            components = ["Velacanto", "AccountOwnership"]
        }
        var directory = Darwin.open(anchor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return -1 }
        for name in components {
            var next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT {
                if mkdirat(directory, name, 0o700) != 0 && errno != EEXIST {
                    close(directory)
                    return -1
                }
                next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                close(directory)
                return -1
            }
            close(directory)
            directory = next
        }
        var rootInfo = stat()
        guard fstat(directory, &rootInfo) == 0, rootInfo.st_uid == geteuid(),
            (rootInfo.st_mode & mode_t(0o077)) == 0
        else {
            close(directory)
            return -1
        }
        return directory
    }
}

/// The active process owns account resources until its model and callbacks retire.
/// This lock is separate from the short credential-transaction lock and must be
/// acquired first. It coordinates only cooperating processes in this container.
final class FoundationAccountLifetimeLease: @unchecked Sendable {
    enum LeaseError: Error { case busy, unavailable }
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    static func acquire(
        root: URL? = nil
    ) throws -> FoundationAccountLifetimeLease {
        let directory = FoundationAccountLockDirectory.open(root: root)
        guard directory >= 0 else { throw LeaseError.unavailable }
        defer { close(directory) }
        let name = "account-lifetime.lock"
        let fd = openat(
            directory, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw LeaseError.unavailable }
        var adopted = false
        defer { if !adopted { close(fd) } }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
            (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            opened.st_uid == geteuid(), opened.st_nlink == 1,
            (opened.st_mode & mode_t(0o777)) == mode_t(0o600)
        else { throw LeaseError.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK ? LeaseError.busy : LeaseError.unavailable
        }
        var current = stat()
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_dev == opened.st_dev, current.st_ino == opened.st_ino,
            (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            current.st_uid == geteuid(), current.st_nlink == 1
        else { throw LeaseError.unavailable }
        adopted = true
        return FoundationAccountLifetimeLease(descriptor: fd)
    }
}

/// Short-lived coordination for cooperating account owners in the same app container.
/// The lock file is never removed; durable sign-out authority stays in Keychain.
enum FoundationAccountTransactionLock {
    enum LockError: Error { case unavailable, busy }

    static func withLock<T>(root: URL? = nil, _ body: () throws -> T) throws -> T {
        let directory = FoundationAccountLockDirectory.open(root: root)
        guard directory >= 0 else { throw LockError.unavailable }
        defer { close(directory) }
        let name = "account-ownership.lock"
        let file = openat(
            directory, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard file >= 0 else { throw LockError.unavailable }
        defer { close(file) }
        var opened = stat()
        guard fstat(file, &opened) == 0,
            (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            opened.st_uid == geteuid(), opened.st_nlink == 1,
            (opened.st_mode & mode_t(0o777)) == mode_t(0o600)
        else { throw LockError.unavailable }
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK ? LockError.busy : LockError.unavailable
        }
        defer { _ = flock(file, LOCK_UN) }
        var current = stat()
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_dev == opened.st_dev, current.st_ino == opened.st_ino,
            (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            current.st_uid == geteuid(), current.st_nlink == 1
        else { throw LockError.unavailable }
        return try body()
    }
}

/// Synchronous operations inside this transaction are run off-main by the caller.
/// Only cooperating app owners in this container participate in the lock.
enum FoundationAccountCredentialTransaction {
    enum TransactionError: Error { case pending, changed, unavailable }
    struct Snapshot: Sendable {
        let intent: FoundationSignOutIntentStore.Intent?
        let session: FoundationSession?
        let accessGroup: String?
        let credentialGeneration: Data?
    }

    private static func scope(_ session: FoundationSession) -> String {
        let identity = "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func same(_ lhs: FoundationSession, _ rhs: FoundationSession) -> Bool {
        lhs.serverURL == rhs.serverURL && lhs.userID == rhs.userID
            && lhs.deviceID == rhs.deviceID && lhs.accessToken == rhs.accessToken
    }

    static func inspect(
        root: URL? = nil,
        operations: FoundationCredentials.Operations = .system
    ) throws -> Snapshot {
        try FoundationAccountTransactionLock.withLock(root: root) {
            let intent = try FoundationSignOutIntentStore.load(operations: operations)
            let identity = try FoundationSignOutIntentStore.credentialIdentity(
                operations: operations)
            let group = identity?.accessGroup
            if let intent, let group, intent.accessGroup != group { throw TransactionError.changed }
            let session = try group.flatMap {
                try FoundationCredentials.load(operations: operations, accessGroup: $0)
            }
            if group != nil && session == nil { throw TransactionError.unavailable }
            if let intent, let session, scope(session) != intent.scope {
                throw TransactionError.changed
            }
            return Snapshot(
                intent: intent, session: session, accessGroup: group,
                credentialGeneration: identity?.generation)
        }
    }

    struct Preparation: Sendable {
        let operation = UUID()
        let candidateGeneration = Data(UUID().uuidString.utf8)
    }

    static func prepareSignOut(
        _ expected: FoundationSession, expecting snapshot: Snapshot,
        preparation: Preparation = Preparation(), root: URL? = nil,
        operations: FoundationCredentials.Operations = .system
    ) throws -> FoundationSignOutIntentStore.Intent {
        try FoundationAccountTransactionLock.withLock(root: root) {
            let expectedScope = scope(expected)
            let existing = try FoundationSignOutIntentStore.load(operations: operations)
            let identity = try FoundationSignOutIntentStore.credentialIdentity(
                operations: operations)
            let group = identity?.accessGroup
            guard existing == snapshot.intent, group == snapshot.accessGroup,
                identity?.generation == snapshot.credentialGeneration
            else { throw TransactionError.changed }
            if let existing, existing.scope != expectedScope { throw TransactionError.changed }
            if let existing, let group, existing.accessGroup != group {
                throw TransactionError.changed
            }
            if let existing, existing.credentialGeneration != snapshot.credentialGeneration {
                throw TransactionError.changed
            }
            let current = try group.flatMap {
                try FoundationCredentials.load(operations: operations, accessGroup: $0)
            }
            if group != nil && current == nil { throw TransactionError.unavailable }
            switch (snapshot.session, current) {
            case (nil, nil): break
            case (let old?, let now?) where same(old, now): break
            default: throw TransactionError.changed
            }
            if let current, !same(current, expected) { throw TransactionError.changed }
            guard current != nil else { throw TransactionError.unavailable }
            var expectedGeneration = identity?.generation
            if existing == nil, let group, expectedGeneration == nil {
                expectedGeneration = try FoundationSignOutIntentStore.assignCredentialGeneration(
                    accessGroup: group, generation: preparation.candidateGeneration,
                    operations: operations)
                guard
                    let confirmed = try FoundationCredentials.load(
                        operations: operations, accessGroup: group), same(confirmed, expected)
                else { throw TransactionError.changed }
            }
            let intent =
                try existing
                ?? FoundationSignOutIntentStore.create(
                    scope: expectedScope, operation: preparation.operation, operations: operations)
            guard intent.credentialGeneration == expectedGeneration,
                let confirmed = try FoundationCredentials.load(
                    operations: operations, accessGroup: intent.accessGroup),
                same(confirmed, expected)
            else { throw TransactionError.changed }
            return intent
        }
    }

    /// Called only after the owner has verified local cleanup for this exact account.
    static func recordCompletedSignOut(
        _ expected: FoundationSession, intent: FoundationSignOutIntentStore.Intent,
        expecting snapshot: Snapshot,
        root: URL? = nil,
        operations: FoundationCredentials.Operations = .system
    ) throws -> FoundationSignOutIntentStore.Intent {
        try FoundationAccountTransactionLock.withLock(root: root) {
            guard intent.scope == scope(expected),
                snapshot.intent == nil || snapshot.intent == intent,
                let original = snapshot.session, same(original, expected),
                try FoundationSignOutIntentStore.load(operations: operations) == intent,
                let identity = try FoundationSignOutIntentStore.credentialIdentity(
                    operations: operations),
                identity.accessGroup == intent.accessGroup,
                identity.accessGroup == snapshot.accessGroup,
                identity.generation == snapshot.credentialGeneration,
                identity.generation == intent.credentialGeneration,
                let saved = try FoundationCredentials.load(
                    operations: operations, accessGroup: intent.accessGroup),
                same(saved, expected)
            else { throw TransactionError.changed }
            let completed = try FoundationSignOutIntentStore.markCleanupComplete(
                intent, operations: operations)
            try FoundationCredentials.clear(operations: operations, accessGroup: intent.accessGroup)
            guard
                try FoundationCredentials.load(
                    operations: operations, accessGroup: intent.accessGroup) == nil
            else { throw TransactionError.unavailable }
            return completed
        }
    }

    static func finishSignOut(
        _ expected: FoundationSession, intent: FoundationSignOutIntentStore.Intent,
        expecting snapshot: Snapshot,
        root: URL? = nil,
        operations: FoundationCredentials.Operations = .system
    ) throws {
        let completed = try recordCompletedSignOut(
            expected, intent: intent, expecting: snapshot, root: root, operations: operations)
        try finishCompletedSignOut(completed, root: root, operations: operations)
    }

    /// Recovery trusts only a recorded cleanup-complete phase, never credential absence alone.
    static func finishCompletedSignOut(
        _ expected: FoundationSignOutIntentStore.Intent,
        root: URL? = nil,
        operations: FoundationCredentials.Operations = .system
    ) throws {
        try FoundationAccountTransactionLock.withLock(root: root) {
            guard expected.cleanupComplete == true,
                try FoundationSignOutIntentStore.load(operations: operations) == expected
            else { throw TransactionError.pending }
            let identity = try FoundationSignOutIntentStore.credentialIdentity(
                operations: operations)
            if let identity {
                guard identity.accessGroup == expected.accessGroup,
                    let expectedGeneration = expected.credentialGeneration,
                    identity.generation == expectedGeneration,
                    let session = try FoundationCredentials.load(
                        operations: operations, accessGroup: identity.accessGroup),
                    scope(session) == expected.scope
                else { throw TransactionError.changed }
                try FoundationCredentials.clear(
                    operations: operations, accessGroup: expected.accessGroup)
                guard
                    try FoundationCredentials.load(
                        operations: operations, accessGroup: expected.accessGroup) == nil
                else { throw TransactionError.unavailable }
            }
            try FoundationSignOutIntentStore.remove(expected, operations: operations)
        }
    }

    static func commitSignIn(
        _ session: FoundationSession, expecting expected: Snapshot,
        root: URL? = nil,
        operations: FoundationCredentials.Operations = .system
    ) throws {
        try FoundationAccountTransactionLock.withLock(root: root) {
            guard expected.intent == nil,
                try FoundationSignOutIntentStore.load(operations: operations) == nil
            else { throw TransactionError.pending }
            let identity = try FoundationSignOutIntentStore.credentialIdentity(
                operations: operations)
            let group = identity?.accessGroup
            guard group == expected.accessGroup,
                identity?.generation == expected.credentialGeneration
            else { throw TransactionError.changed }
            let current = try group.flatMap {
                try FoundationCredentials.load(operations: operations, accessGroup: $0)
            }
            if group != nil && current == nil { throw TransactionError.unavailable }
            switch (expected.session, current) {
            case (nil, nil): break
            case (let old?, let now?) where same(old, now): break
            default: throw TransactionError.changed
            }
            try FoundationCredentials.save(
                session, operations: operations, accessGroup: group,
                generation: Data(UUID().uuidString.utf8))
        }
    }
}
