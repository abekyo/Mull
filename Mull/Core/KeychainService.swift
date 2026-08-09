import Foundation
import Security

/// Wrapper around macOS Keychain Services for secure API key storage.
/// Never stores keys in UserDefaults/plist.
enum KeychainService {

    private static let serviceName = "com.mull.app"

    /// Why a keychain read came back with nothing.
    ///
    /// "No key" and "the keychain refused to answer" used to be the same `nil`,
    /// and everything downstream chose the wrong one of the two: Settings drew an
    /// empty field over a key that was really there, and the LLM client reported
    /// "No API key configured — set it in Settings" to someone who had set it
    /// years ago. Re-entering it then failed the same way, with the same message.
    enum ReadFailure: Error, Equatable {
        /// No such item — the key genuinely was never saved.
        case notFound
        /// The keychain is locked, or refused this app access to the item.
        case denied(OSStatus)

        var message: String {
            switch self {
            case .notFound:
                "No key saved yet."
            case .denied(let status):
                "macOS wouldn't open the keychain item (\(status)). The key may still be there — unlock your keychain in Keychain Access, or save it again to replace it."
            }
        }
    }

    /// Store a value, reporting whether it actually landed in the keychain.
    ///
    /// This used to return Void and merely print on failure, so the settings UI told the
    /// user "saved" for a key that was never stored — and the next API call failed with an
    /// unexplained 401. Callers that show success/failure should check the result.
    ///
    /// Add first, delete only on the duplicate: the old order deleted the existing
    /// item before adding, so a failing add destroyed a key that had been working
    /// and left nothing to fall back on.
    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        var status = SecItemAdd(attributes as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Update in place rather than delete-then-add, so there is never a
            // window in which the user has no key at all.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key,
            ]
            status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        }

        if status != errSecSuccess {
            print("[mull] Keychain save failed for \(key): \(status)")
            return false
        }
        return true
    }

    static func load(key: String) -> String? {
        try? read(key: key)
    }

    /// The same read, with the reason for an empty answer preserved.
    static func read(key: String) throws(ReadFailure) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { throw .notFound }
        guard status == errSecSuccess, let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else {
            print("[mull] Keychain read failed for \(key): \(status)")
            throw .denied(status)
        }
        return text
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // Deleting something that was never there is the outcome the caller wanted.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            print("[mull] Keychain delete failed for \(key): \(status)")
            return false
        }
        return true
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

    /// `loadKey`, but a refusal is reported instead of read as absence. Callers
    /// that put words on screen about a missing key should use this one.
    static func readKey(_ key: String) throws(ReadFailure) -> String {
        let trimmed = try read(key: key).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw .notFound }
        return trimmed
    }
}
