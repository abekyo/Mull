import Foundation
import Security

/// Wrapper around macOS Keychain Services for secure API key storage.
/// Never stores keys in UserDefaults/plist.
enum KeychainService {

    private static let serviceName = "com.mull.app"

    /// Store a value, reporting whether it actually landed in the keychain.
    ///
    /// This used to return Void and merely print on failure, so the settings UI told the
    /// user "saved" for a key that was never stored — and the next API call failed with an
    /// unexplained 401. Callers that show success/failure should check the result.
    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete existing entry first
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[mull] Keychain save failed for \(key): \(status)")
            return false
        }
        return true
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Load a credential for *use*. API keys arrive via copy-paste and routinely carry an
    /// invisible trailing newline/space, which silently corrupts an Authorization header
    /// (the classic "my key is correct but I get 401"). Always trim at the point of use so
    /// even keys saved before trimming existed self-heal.
    static func loadKey(_ key: String) -> String? {
        guard let raw = load(key: key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
