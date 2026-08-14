import Foundation

/// One answer to "which language does the human read?" for every file mull
/// writes *for the user* (me.pinned.md's scaffold, proactive briefs, folder
/// indexes, inbox digests) and for notifications.
///
/// Two sources, in order: the explicit choice in Settings › General, then the
/// language macOS itself is set to. That is all.
///
/// **It used to read the onboarding answer first, and that was wrong.** The
/// question mull asks at setup — "what language should AI reply in?" — is
/// answered in free prose ("Terse, mostly 日本語", "にほんご", "JP"), so getting a
/// yes/no out of it meant substring matching, and a match that misses has no
/// symptom: the vault is simply in the wrong language and nothing says why. The
/// old code shipped a picker to work around that, which is a setting that exists
/// to undo a guess.
///
/// The macOS language setting is not a guess. The user chose it, it is one value
/// rather than a sentence, and every other app on the machine already obeys it —
/// so it is the default a reader can predict without being told. The argument
/// against it (people run macOS in English and work in Japanese) is real, and it
/// is exactly what the explicit picker is for: a stated choice, made once, that
/// beats the system. What it is not is a reason to infer the answer from prose.
///
/// The onboarding answer still does its own job — it is prose, it stays prose,
/// and it is what the AI reads in me.pinned.md. It just no longer decides
/// anything on the user's behalf.
///
/// **Read through `Preferences.store`, not `UserDefaults.standard`.** The two are
/// not the same store in the two targets: the app's standard domain is
/// `com.mull.app`, and `MullMCP` is a bare executable whose standard domain is
/// keyed on the executable name and holds none of the app's values. Reading
/// `.standard` from Core — which `project.yml` compiles into both targets — meant
/// the picker in Settings › General governed the vault files (written by the app)
/// and nothing at all in the 13 MCP tools (served by the helper), which is the
/// surface CLAUDE.md §5 calls the product. A vault in Japanese and an agent being
/// answered in English, from one setting, with no symptom that says why.
/// `Preferences` exists for exactly this and its doc comment describes this bug;
/// this type simply was not using it.
///
/// Scope, as of the vault localization work: this decides me.md, now.md, full.md
/// and everything else mull writes for a human to read. `VaultText` holds the
/// reasoning — briefly, the reader opens those files in mull's own Files tab, and
/// a model reads Japanese, so pinning them to English bought nothing. What stays
/// English is what is *addressed to* a model (`mull.md`) and what is *parsed* by
/// one (front-matter keys, `MarkdownDoc.generatorStamp`, block provenance
/// markers) — protocol, not prose.
enum UserLanguage {

    /// Mirror of `OnboardingProfile.answersKey` — kept literal here so Core
    /// stays free of Services imports; a test asserts the two agree.
    static let onboardingAnswersKey = "onboardingProfileAnswers"

    /// The explicit choice. Absent (`.system`) means "whatever macOS is set to".
    static let preferenceKey = "vaultLanguage"

    enum Preference: String, CaseIterable, Identifiable {
        case system, english, japanese

        var id: String { rawValue }

        /// Named for what it does, not for how it is implemented. "Follow my
        /// answer, then the system" was the old label, and it described a
        /// precedence the reader had no way to check — they would have had to
        /// remember what they typed at setup and guess whether mull's matcher
        /// saw it the same way.
        var label: String {
            switch self {
            case .system:   return "Same as macOS"
            case .english:  return "English"
            case .japanese: return "日本語"
            }
        }
    }

    static var preference: Preference {
        Preference(rawValue: Preferences.store.string(forKey: preferenceKey) ?? "") ?? .system
    }

    /// The free-text onboarding answer, if the user gave one. Read by the profile
    /// projection, which puts it in front of the AI verbatim. Nothing decides a
    /// language from it — see the note at the top of this file.
    static var statedLanguage: String? {
        (Preferences.store.dictionary(forKey: onboardingAnswersKey) as? [String: String])?["language"]
    }

    /// What macOS itself is set to, as a yes/no.
    static var systemIsJapanese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("ja") == true
    }

    static var isJapanese: Bool { isJapanese(preference: preference) }

    /// Resolution for a preference the caller is holding rather than the stored
    /// one — the Settings picker learns its previous value only after
    /// `@AppStorage` has already written the new one, and it needs both to know
    /// whether the language actually flipped.
    static func isJapanese(preference: Preference) -> Bool {
        resolve(preference: preference, systemIsJapanese: systemIsJapanese)
    }

    /// Pure, so the precedence is testable without UserDefaults or a locale.
    static func resolve(preference: Preference, systemIsJapanese: Bool) -> Bool {
        switch preference {
        case .japanese: return true
        case .english:  return false
        case .system:   return systemIsJapanese
        }
    }
}
