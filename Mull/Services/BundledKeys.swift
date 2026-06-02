import Foundation

/// Bundled API keys for zero-config experience.
///
/// Keys are lightly obfuscated to prevent casual extraction from the binary.
/// This is NOT security — a determined attacker can still extract them.
/// The purpose is to deter casual scraping by bots and scripts.
///
/// If the bundled key hits rate limits, users are prompted to set their own.
/// User keys (stored in Keychain) always take priority over bundled keys.
enum BundledKeys {

    /// Gemini Flash API key (free tier).
    /// Replace the encoded value with your actual key before distribution.
    ///
    /// To encode a key:  echo -n "YOUR_KEY" | base64
    /// To decode:         BundledKeys.decode("base64string")
    static var gemini: String {
        // TODO: Replace with your base64-encoded Gemini API key before release
        // Example: decode("QUl6YVN5...")
        decode("")
    }

    // MARK: - Obfuscation

    /// Decode a base64-encoded key. Minimal obfuscation — keeps keys out of
    /// plain-text searches (grep, strings) but NOT cryptographically secure.
    private static func decode(_ encoded: String) -> String {
        guard !encoded.isEmpty,
              let data = Data(base64Encoded: encoded),
              let key = String(data: data, encoding: .utf8)
        else { return "" }
        return key
    }
}
