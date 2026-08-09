import Foundation

/// The reader's language, for text mull writes into the vault.
///
/// Two different switches decide language in this app, and they are not the same
/// one:
///
///   * **The app's chrome** — every window, menu, alert and tooltip — is a real
///     macOS localization. It follows the bundle's `.lproj`, which is to say
///     `AppleLanguages`, and Xcode resolves it from `Localizable.xcstrings`. That
///     is what `Text("…")` and `String(localized:)` reach.
///   * **The files in ~/mull** are not chrome. They are written to disk, read in
///     Obsidian and in a text editor months later, and committed to git. They
///     follow `UserLanguage`, which the reader sets in Settings › General, so a
///     vault does not change language because someone switched macOS to English
///     for an afternoon.
///
/// This is the second one. `ProactiveLoop` has resolved it inline for
/// `proactive.md` since that file existed; this is the same rule with a name, so
/// the other generators can follow it without each inventing a ternary.
///
/// **What this changed.** me.md, now.md and full.md used to be pinned to English
/// on the grounds that their audience is whatever model the user pastes them
/// into. Two things were wrong with that. The reader opens them in mull's own
/// Files tab — that is the default screen — so the argument was answering about
/// the smaller of the two audiences. And a model reads Japanese, so nothing was
/// bought by the pin. What stays English is what is *addressed to* a model
/// (`mull.md`, the front-door instructions) and what is *parsed* by one
/// (`MarkdownDoc.generatorStamp`, the front-matter keys, block provenance
/// markers) — those are protocol, not prose, and rewording them silently breaks
/// a reader that is looking for the exact bytes.
enum VaultText {

    /// Pick by the reader's language. Written with both arguments at the call
    /// site rather than as a lookup key: a vault string has exactly two forms,
    /// they belong next to each other where the sentence is, and a key table
    /// would put a level of indirection between a heading and its translation
    /// for no gain.
    static func t(_ english: String, _ japanese: String) -> String {
        UserLanguage.isJapanese ? japanese : english
    }

    static var isJapanese: Bool { UserLanguage.isJapanese }

    /// A span of time, as a reader of this language writes one: `2h 30m` / `2時間30分`.
    ///
    /// Ten call sites open-coded `"\(h)h \(m)m"` — four of them in one file — so the
    /// shape could not follow a language without being changed in ten places, and
    /// a Japanese screen read "平均 176分/セッション" directly above "5h 52m".
    /// Sub-hour spans stay bare minutes in both languages, which is what every one
    /// of those ten already did.
    static func duration(minutes total: Int) -> String {
        let h = total / 60, m = total % 60
        if h == 0 { return isJapanese ? "\(m)分" : "\(m)m" }
        if m == 0 { return isJapanese ? "\(h)時間" : "\(h)h" }
        return isJapanese ? "\(h)時間\(m)分" : "\(h)h \(m)m"
    }

    /// The same, from a `TimeInterval` of seconds — the form most call sites hold.
    static func duration(seconds: TimeInterval) -> String {
        duration(minutes: Int(seconds) / 60)
    }
}
