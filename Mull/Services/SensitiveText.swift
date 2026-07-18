import Foundation

/// Single source of truth for "should this text never leave the device / never
/// reach an LLM." Dependency-free (Foundation only) so every target — the app,
/// the MCP tool — can share one definition instead of duplicating the rules.
///
/// Used by full.md formatting (LiveContextGenerator) AND the LLM prompt paths
/// (MullEngine, KnowledgeExtractor) so clipboard/keystroke secrets are filtered
/// everywhere, not just in one place.
enum SensitiveText {

    /// Compiled once, not per call: Selection.rank asks this question for every
    /// candidate (up to ~200 per tick), and rebuilding two NSRegularExpressions each
    /// time was pure overhead. Same pattern as Redactor.patterns.
    ///
    /// `nil` means the pattern failed to compile, which fails SAFE below (treated as
    /// sensitive) — a one-time, constant-input condition, but the wrong answer here
    /// ships someone's data to an LLM.
    private static let emailPattern = try? NSRegularExpression(
        pattern: "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}")

    /// Credit card patterns (4 groups of 4 digits).
    private static let ccPattern = try? NSRegularExpression(
        pattern: "\\b\\d{4}[- ]?\\d{4}[- ]?\\d{4}[- ]?\\d{4}\\b")

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        // No regex → assume the worst rather than waving the text through.
        guard let regex else { return true }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isSensitive(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Email addresses
        if matches(emailPattern, text) { return true }
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
        // Bare credentials with no label around them — a pasted `sk-…` / PAT / JWT.
        // (Labels above only catch "api_key: …"; the naked key itself slipped through.)
        if Redactor.containsSecret(text) { return true }
        // Credit card patterns
        if matches(ccPattern, text) { return true }
        return false
    }
}
