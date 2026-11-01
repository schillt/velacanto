import Security
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationDownloadAccountTests: XCTestCase {
    #if os(iOS)
        func testIsolatedKeychainCRUDWithDeviceLocalAccessibility() throws {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Velacanto.SyntheticTest." + UUID().uuidString,
                kSecAttrAccount as String: "synthetic",
                kSecAttrSynchronizable as String: false,
            ]
            defer { SecItemDelete(query as CFDictionary) }
            let value = Data("synthetic-not-a-credential".utf8)
            let insertion = query.merging([
                kSecValueData as String: value,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { _, new in new }
            XCTAssertEqual(SecItemAdd(insertion as CFDictionary, nil), errSecSuccess)
            var read = query
            read[kSecReturnData as String] = true
            read[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &result), errSecSuccess)
            XCTAssertEqual(result as? Data, value)
            let replacement = Data("replacement-fixture".utf8)
            XCTAssertEqual(
                SecItemUpdate(
                    query as CFDictionary, [kSecValueData as String: replacement] as CFDictionary),
                errSecSuccess)
            XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &result), errSecSuccess)
            XCTAssertEqual(result as? Data, replacement)
            XCTAssertEqual(SecItemDelete(query as CFDictionary), errSecSuccess)
            XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &result), errSecItemNotFound)
        }
    #endif

    func testResidualDownloadsPreventNewSignInRequest() async {
        var requests = 0
        do {
            _ = try await FoundationSignInPolicy.authenticate(
                clearPins: { true }, clearPlaybackSessions: { true }, clearDownloads: { false },
                signIn: {
                    requests += 1
                    throw CancellationError()
                })
            XCTFail("Residual account data must prevent a new sign-in")
        } catch {
            XCTAssertTrue(error is FoundationDownloadAccountError)
        }
        XCTAssertEqual(requests, 0)
    }

    func testDownloadCleanupPrecedesAuthentication() async {
        var steps: [String] = []
        do {
            _ = try await FoundationSignInPolicy.authenticate(
                clearPins: {
                    steps.append("pins")
                    return true
                },
                clearPlaybackSessions: {
                    steps.append("session")
                    return true
                },
                clearDownloads: {
                    steps.append("downloads")
                    return true
                },
                signIn: {
                    steps.append("authenticate")
                    throw CancellationError()
                })
        } catch {}
        XCTAssertEqual(steps, ["pins", "session", "downloads", "authenticate"])
    }
}
