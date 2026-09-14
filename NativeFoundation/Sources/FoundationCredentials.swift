import Foundation
import Security

/// One isolated Keychain entry. Loading does not validate or contact a server.
enum FoundationCredentials {
    private static let service = "Velacanto.NativeFoundation.Session"
    private static let account = "current-session"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func save(_ session: FoundationSession) throws {
        _ = try FoundationJellyfinLibrary.validatedServerURL(session.serverURL)
        let data = try JSONEncoder().encode(session)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insertion = query.merging(attributes) { _, new in new }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
                throw FoundationLibraryError.credentials
            }
        } else if status != errSecSuccess {
            throw FoundationLibraryError.credentials
        }
    }

    static func load() throws -> FoundationSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
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

    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FoundationLibraryError.credentials
        }
    }
}
