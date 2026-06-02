import Foundation

/// Detects private / incognito browser windows from their title, so mull never
/// records (or surfaces) what the user explicitly chose to keep private.
///
/// Title-based detection only — it's the signal Accessibility gives us — but the
/// markers below are unambiguous private-mode strings across the major browsers.
/// Dependency-free so both the recorder and the context generators can share it.
enum PrivateBrowsing {

    /// Unambiguous private/incognito markers (matched case-insensitively).
    private static let markers = [
        "プライベートブラウジング",   // Firefox (Japanese)
        "private browsing",          // Firefox / Safari (English)
        "incognito",                 // Chrome (English)
        "シークレット モード",         // Chrome (Japanese, "secret mode")
        "シークレットモード",          // Chrome (Japanese, no space)
        "inprivate",                 // Edge
    ]

    static func isPrivate(_ title: String) -> Bool {
        let lower = title.lowercased()
        return markers.contains { lower.contains($0.lowercased()) }
    }
}
