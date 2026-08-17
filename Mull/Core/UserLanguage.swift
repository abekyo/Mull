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
        /// Only the first one is translated. "English" and "日本語" are endonyms:
        /// a language is named in itself in a language picker, so that a reader who
        /// cannot read the current UI can still find their own row.
        var label: String {
            switch self {
            case .system:   return String(localized: "Same as macOS")
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
    ///
    /// Read from the global domain rather than from `Locale.preferredLanguages`.
    /// Inside the app that list is *already led by mull's own `AppleLanguages`
    /// override* (`chromeOverride`), so once the picker has been used it answers
    /// "what did mull last choose" while calling itself the system. Two things
    /// broke on that. "Same as macOS" could not switch back: the picker decides
    /// whether anything happened by comparing the new resolution against the old
    /// one, and with a `ja` override in front both answers were Japanese, so it
    /// returned before it could remove the override. And `MullMCP` has no override
    /// to read, so the app and the 13 tools disagreed about what `.system` meant —
    /// the exact split `Preferences` exists to close.
    ///
    /// The fallback is what a process that cannot read the global domain would have
    /// answered anyway.
    static var systemIsJapanese: Bool {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let languages = global?[chromeKey] as? [String]
        return (languages?.first ?? Locale.preferredLanguages.first)?.hasPrefix("ja") == true
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

    // MARK: - The app's own windows
    //
    // The vault and the windows are resolved by different machinery and there is no
    // honest way to make them switch together. The vault is written by mull, so
    // `VaultText` reads the preference at every write and the next pass picks it up
    // within the minute. The windows are a real macOS localization: `Text("…")`
    // resolves against the bundle's `.lproj`, which CoreFoundation binds **once, at
    // process start**, from `AppleLanguages`. So everything below sets up the next
    // launch and can do nothing at all for this one.
    //
    // Only the app calls these. `MullMCP` has no windows.

    /// Where macOS keeps a bundle's language: the key System Settings › General ›
    /// Language & Region writes when someone picks a language for one app. mull
    /// writes it too, because a choice made in Settings has to reach the windows
    /// and not only the vault.
    static let chromeKey = "AppleLanguages"

    /// mull's own override, read from the app's domain **alone**.
    ///
    /// `UserDefaults.standard.stringArray(forKey:)` answers this key from the global
    /// domain when no override is set, which is a different question wearing the
    /// same name — and it is the read that made `systemIsJapanese` wrong.
    static var chromeOverride: String? {
        let own = UserDefaults.standard.persistentDomain(forName: Preferences.domain)
        return (own?[chromeKey] as? [String])?.first
    }

    /// The language the windows on screen are drawn in. A fact about this launch,
    /// not about the preference.
    static var runningChrome: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// What the *next* launch will draw in: the override if there is one — mull's,
    /// or the per-app entry somebody set in System Settings — and macOS otherwise.
    static var nextLaunchChrome: String { chromeOverride ?? (systemIsJapanese ? "ja" : "en") }

    /// True while the windows are in a different language from the one now chosen,
    /// which is exactly the stretch between choosing and quitting.
    ///
    /// Compared two letters at a time: an override written by System Settings can
    /// carry a region (`ja-JP`, `en-GB`) that the bundle resolves to a bare `.lproj`.
    static var chromeNeedsRelaunch: Bool {
        runningChrome.prefix(2) != nextLaunchChrome.prefix(2)
    }

    /// Make the stored answer true of the bundle. Called at every launch.
    ///
    /// The write used to happen only inside the picker's `onChange`, which meant a
    /// preference stored before the windows followed it at all — the vault language
    /// is older than that — left the chrome in English for good: nothing on screen
    /// said why, and the only way out was to move the picker off the answer it was
    /// already showing and back onto it.
    ///
    /// `.system` is left alone here rather than cleared. Clearing is what *choosing*
    /// it means, and that is done once, at the moment it is chosen; a launch that
    /// cleared as well would delete the per-app entry in System Settings › General ›
    /// Language & Region every time mull opened.
    static func applyChromeAtLaunch() {
        switch preference {
        case .system:   break
        case .english:  setChrome("en")
        case .japanese: setChrome("ja")
        }
    }

    /// The same, for an answer the user has just chosen.
    ///
    /// `.system` removes the override instead of pinning `en`/`ja`: it is the one
    /// answer that means mull does not decide this, and writing a value there would
    /// make the per-app picker in System Settings a control that silently does
    /// nothing.
    static func applyChrome(_ preference: Preference) {
        switch preference {
        case .system:   Preferences.store.removeObject(forKey: chromeKey)
        case .english:  setChrome("en")
        case .japanese: setChrome("ja")
        }
    }

    private static func setChrome(_ language: String) {
        guard chromeOverride != language else { return }
        Preferences.store.set([language], forKey: chromeKey)
    }
}
