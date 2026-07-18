import Foundation

/// Masks secrets in text that is about to be *shown* or *learned from*.
///
/// mull records the clipboard; people copy API keys. The recording layer keeps the raw
/// event (the vault is local and the user's own), but no surface should ever *display*
/// a credential (Home project cards, calendar popovers) and the understudy must never
/// *learn* from one (voice samples). One place for the patterns, so every surface
/// agrees on what a secret looks like.
enum Redactor {

    /// Common credential shapes: OpenAI/Anthropic/GitHub/Slack/AWS prefixes, bearer
    /// tokens, and long unbroken base64/hex runs that look like keys.
    private static let patterns: [NSRegularExpression] = [
        #"sk-[A-Za-z0-9_-]{16,}"#,           // OpenAI / Anthropic style
        #"ghp_[A-Za-z0-9]{20,}"#,            // GitHub PAT
        #"gho_[A-Za-z0-9]{20,}"#,
        #"xox[baprs]-[A-Za-z0-9-]{10,}"#,    // Slack
        #"AKIA[0-9A-Z]{16}"#,                // AWS access key id
        #"Bearer\s+[A-Za-z0-9._~+/=-]{20,}"#,
        #"eyJ[A-Za-z0-9._-]{40,}"#,          // JWT
        #"\b[A-Fa-f0-9]{40,}\b"#,            // long hex (tokens, sha-like secrets)
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Replace each secret with its first 6 characters + "…(hidden)".
    static func mask(_ text: String) -> String {
        var result = text
        for regex in patterns {
            while let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
                  let range = Range(match.range, in: result) {
                let secret = result[range]
                result.replaceSubrange(range, with: "\(secret.prefix(6))…(hidden)")
            }
        }
        return result
    }

    /// True when the text contains anything credential-shaped — used to drop a
    /// candidate voice sample entirely rather than feed a half-masked one to the LLM.
    static func containsSecret(_ text: String) -> Bool {
        patterns.contains { regex in
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }
}
