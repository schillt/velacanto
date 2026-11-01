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

    static func save(_ session: FoundationSession, operations: Operations = .system) throws {
        _ = try FoundationJellyfinLibrary.validatedServerURL(session.serverURL)
        let data = try JSONEncoder().encode(session)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = operations.update(query, attributes)
        if status == errSecItemNotFound {
            let insertion = query.merging(attributes) { _, new in new }
            guard operations.add(insertion) == errSecSuccess else {
                throw FoundationLibraryError.credentials
            }
        } else if status != errSecSuccess {
            throw FoundationLibraryError.credentials
        }
    }

    static func load(operations: Operations = .system) throws -> FoundationSession? {
        var request = query
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

    static func clear(operations: Operations = .system) throws {
        let status = operations.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FoundationLibraryError.credentials
        }
    }
}
