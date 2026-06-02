import Foundation

/// Single source of truth for "should this text never leave the device / never
/// reach an LLM." Dependency-free (Foundation only) so every target — the app,
/// the MCP tool — can share one definition instead of duplicating the rules.
///
/// Used by full.md formatting (LiveContextGenerator) AND the LLM prompt paths
/// (MullEngine, KnowledgeExtractor) so clipboard/keystroke secrets are filtered
/// everywhere, not just in one place.
enum SensitiveText {

    static func isSensitive(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Email addresses
        let emailPattern = try? NSRegularExpression(pattern: "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}")
        if let regex = emailPattern, regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return true
        }
        // URLs — personal wishlists, business pages, tokens in query strings
        if lower.contains("http://") || lower.contains("https://") { return true }
        // Zoom/meeting links with passcodes
        if lower.contains("zoom.us/j/") { return true }
        if lower.contains("meeting id:") && lower.contains("passcode") { return true }
        if lower.contains("join zoom meeting") { return true }
        // Passwords, tokens, API keys
        if lower.contains("password:") || lower.contains("passcode:") { return true }
        if lower.contains("api_key") || lower.contains("apikey") || lower.contains("secret_key") { return true }
        if lower.contains("bearer ") || lower.contains("token:") { return true }
        // Private keys, certificates
        if text.contains("-----BEGIN") { return true }
        // Credit card patterns (4 groups of 4 digits)
        let ccPattern = try? NSRegularExpression(pattern: "\\b\\d{4}[- ]?\\d{4}[- ]?\\d{4}[- ]?\\d{4}\\b")
        if let regex = ccPattern, regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return true
        }
        return false
    }
}
