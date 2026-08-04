import Foundation
import Security

/// Persistence boundary for an authenticated Jellyfin account. Passwords never
/// cross this boundary; only the access token, session metadata, and device ID
/// are stored.

/// The non-secret metadata needed to restore an authenticated connection.
struct JellyfinSession: Codable, Equatable, Sendable {
    let serverURL: URL
    let serverID: String
    let serverName: String
    let userID: String
    let username: String
    let userPrimaryImageTag: String?

    init(
        serverURL: URL,
        serverID: String,
        serverName: String,
        userID: String,
        username: String,
        userPrimaryImageTag: String? = nil
    ) {
        self.serverURL = serverURL
        self.serverID = serverID
        self.serverName = serverName
        self.userID = userID
        self.username = username
        self.userPrimaryImageTag = userPrimaryImageTag
    }
}

/// Stores only the access token. Implementations must never persist passwords.
protocol JellyfinTokenStoring {
    func loadToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

protocol JellyfinSessionPersisting {
    func loadSession() -> JellyfinSession?
    func saveSession(_ session: JellyfinSession)
    func deleteSession()
    func loadDeviceID() -> String?
    func saveDeviceID(_ deviceID: String)
}

protocol JellyfinKeychainTokenPersisting {
    func loadToken(service: String, account: String) throws -> String?
    func saveToken(_ token: String, service: String, account: String) throws
    func deleteToken(service: String, account: String) throws
}

struct SystemJellyfinKeychainTokenStore: JellyfinKeychainTokenPersisting {
    func loadToken(service: String, account: String) throws -> String? {
        var search = query(service: service, account: account)
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
            let token = String(data: data, encoding: .utf8), !token.isEmpty
        else {
            throw JellyfinCredentialStoreError.storageUnavailable
        }
        return token
    }

    func saveToken(
        _ token: String,
        service: String,
        account: String
    ) throws {
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            query(service: service, account: account) as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw JellyfinCredentialStoreError.storageUnavailable
        }

        var add = query(service: service, account: account)
        add[kSecValueData] = data
        #if os(iOS)
            add[kSecAttrAccessible] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw JellyfinCredentialStoreError.storageUnavailable
        }
    }

    func deleteToken(service: String, account: String) throws {
        let status = SecItemDelete(
            query(service: service, account: account) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw JellyfinCredentialStoreError.storageUnavailable
        }
    }

    private func query(
        service: String,
        account: String
    ) -> [CFString: Any] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        return query
    }
}

/// Keychain-backed token storage with one-way migration from earlier local stores.
struct KeychainJellyfinTokenStore: JellyfinTokenStoring {
    private static let defaultAccount = "jellyfin.access-token"
    private static let defaultService =
        "com.chameleonenterprise.velacanto.jellyfin"

    private let fileManager: FileManager
    private let legacyFileURL: URL
    private let service: String
    private let account: String
    private let legacyDefaults: UserDefaults?
    private let keychain: any JellyfinKeychainTokenPersisting
    private let removeLegacyFile: () throws -> Void

    init(
        fileManager: FileManager = .default,
        legacyDirectory: URL? = nil,
        service: String = defaultService,
        account: String = defaultAccount,
        migratingFrom legacyDefaults: UserDefaults? = nil,
        keychain: any JellyfinKeychainTokenPersisting =
            SystemJellyfinKeychainTokenStore(),
        removeLegacyFile: (() throws -> Void)? = nil
    ) {
        let applicationSupport =
            fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
        let resolvedDirectory =
            legacyDirectory
            ?? applicationSupport.appending(
                path: "Velacanto/Session",
                directoryHint: .isDirectory
            )
        self.fileManager = fileManager
        let tokenFileURL = resolvedDirectory.appending(
            path: "jellyfin-access-token-v1",
            directoryHint: .notDirectory
        )
        legacyFileURL = tokenFileURL
        self.service = service
        self.account = account
        self.legacyDefaults = legacyDefaults
        self.keychain = keychain
        self.removeLegacyFile =
            removeLegacyFile
            ?? { try fileManager.removeItem(at: tokenFileURL) }
    }

    func loadToken() throws -> String? {
        // Prefer the Keychain and remove any recovered legacy copy immediately.
        if let token = try keychain.loadToken(
            service: service,
            account: account
        ) {
            try removeLegacyStorage()
            return token
        }

        if let token = try legacyFileToken() {
            try saveToken(token)
            return token
        }

        guard
            let legacyDefaults,
            let token = legacyDefaults.string(forKey: account),
            !token.isEmpty
        else { return nil }

        try saveToken(token)
        return token
    }

    func saveToken(_ token: String) throws {
        guard !token.isEmpty else {
            throw JellyfinCredentialStoreError.invalidToken
        }

        try saveKeychainToken(token)
        try removeLegacyStorage()
    }

    func deleteToken() throws {
        try removeLegacyStorage()
        try keychain.deleteToken(service: service, account: account)
    }

    private func legacyFileToken() throws -> String? {
        guard fileManager.fileExists(atPath: legacyFileURL.path) else {
            return nil
        }
        guard
            let data = try? Data(contentsOf: legacyFileURL),
            let token = String(data: data, encoding: .utf8),
            !token.isEmpty
        else {
            throw JellyfinCredentialStoreError.invalidToken
        }
        return token
    }

    private func saveKeychainToken(_ token: String) throws {
        try keychain.saveToken(token, service: service, account: account)
    }

    private func removeLegacyStorage() throws {
        guard fileManager.fileExists(atPath: legacyFileURL.path) else {
            legacyDefaults?.removeObject(forKey: account)
            return
        }
        do {
            try removeLegacyFile()
        } catch {
            throw JellyfinCredentialStoreError.storageUnavailable
        }
        legacyDefaults?.removeObject(forKey: account)
    }
}

/// Stores non-secret session metadata and the stable device identifier.
struct UserDefaultsJellyfinSessionStore: JellyfinSessionPersisting {
    private let defaults: UserDefaults
    private let sessionKey = "jellyfin.session"
    private let deviceIDKey = "jellyfin.device-id"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSession() -> JellyfinSession? {
        guard let data = defaults.data(forKey: sessionKey) else { return nil }
        return try? JSONDecoder().decode(JellyfinSession.self, from: data)
    }

    func saveSession(_ session: JellyfinSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: sessionKey)
    }

    func deleteSession() {
        defaults.removeObject(forKey: sessionKey)
    }

    func loadDeviceID() -> String? {
        defaults.string(forKey: deviceIDKey)
    }

    func saveDeviceID(_ deviceID: String) {
        defaults.set(deviceID, forKey: deviceIDKey)
    }
}

enum JellyfinCredentialStoreError: LocalizedError, Equatable {
    case invalidToken
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            "Jellyfin returned an invalid access token."
        case .storageUnavailable:
            "The Jellyfin session could not be saved in the system Keychain."
        }
    }
}
