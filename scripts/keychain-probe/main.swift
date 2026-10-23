import Foundation
import Security

#if PROBE_REVISION_TWO
    let revision = "rebuilt"
#else
    let revision = "initial"
#endif

// Standalone disposable validation executable. Never link this into the app.
struct Configuration: Decodable {
    let testID: UUID
    let nonce: String
}

func finish(_ operation: String, _ outcome: String, success: Bool) -> Never {
    let result = ["operation": operation, "outcome": outcome, "build": revision]
    if let output = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data([10]))
    }
    exit(success ? 0 : 1)
}

func outcome(_ status: OSStatus) -> String {
    switch status {
    case errSecSuccess: return "success"
    case errSecItemNotFound: return "item_not_found"
    case errSecDuplicateItem: return "duplicate_item"
    case errSecMissingEntitlement: return "missing_entitlement"
    case errSecInteractionNotAllowed: return "interaction_not_allowed"
    case errSecAuthFailed: return "authorization_failed"
    default: return "security_failure"
    }
}

let arguments = CommandLine.arguments
let operations = ["add", "read", "update", "read-updated", "absent", "delete"]
guard arguments.count == 3, operations.contains(arguments[1]),
    let configuration = try? JSONDecoder().decode(
        Configuration.self, from: Data(arguments[2].utf8)),
    let nonce = Data(base64Encoded: configuration.nonce), nonce.count == 32
else { finish("configuration", "invalid_configuration", success: false) }

let operation = arguments[1]
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "VelaCanto.Keychain.Validation." + configuration.testID.uuidString,
    kSecAttrAccount as String: "disposable-probe",
    kSecAttrSynchronizable as String: false,
    kSecUseDataProtectionKeychain as String: true,
]
var updated = Data("updated-disposable-probe:".utf8)
updated.append(nonce)
let status: OSStatus
switch operation {
case "add":
    var insertion = query
    insertion[kSecValueData as String] = nonce
    insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    status = SecItemAdd(insertion as CFDictionary, nil)
case "update":
    status = SecItemUpdate(
        query as CFDictionary, [kSecValueData as String: updated] as CFDictionary)
case "delete":
    status = SecItemDelete(query as CFDictionary)
    finish(
        operation, outcome(status), success: status == errSecSuccess || status == errSecItemNotFound
    )
default:
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    status = SecItemCopyMatching(request as CFDictionary, &result)
    if operation == "absent" {
        finish(operation, outcome(status), success: status == errSecItemNotFound)
    }
    if status == errSecSuccess {
        let expected = operation == "read-updated" ? updated : nonce
        finish(
            operation, (result as? Data) == expected ? "success" : "data_mismatch",
            success: (result as? Data) == expected)
    }
}
finish(operation, outcome(status), success: status == errSecSuccess)
