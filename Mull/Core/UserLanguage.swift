import Foundation

/// One answer to "which language does the human read?" for every file mull
/// writes *for the user* (me.pinned.md's scaffold, proactive briefs, folder
/// indexes, inbox digests) and for notifications.
///
/// Three sources, in order: the explicit choice in Settings › Profile, then the
/// user's *stated* working language (the onboarding "What language should AI
/// reply in?" answer), then the system locale. The locale is the wrong first
/// witness: plenty of people run macOS in English and work in Japanese — this
/// vault's own history is typed through a Japanese IME on an en-US system.
///
/// Deliberately NOT applied to the AI-facing contract files — me.md, now.md,
/// full.md, MEMORY.md stay in stable English because their audience is whatever
/// model the user pastes them into, and a fixed format survives locale changes.
/// The split is the same one TimeFormat draws between `person` and `machine`.
enum UserLanguage {

    /// Mirror of `OnboardingProfile.answersKey` — kept literal here so Core
    /// stays free of Services imports; a test asserts the two agree.
    static let onboardingAnswersKey = "onboardingProfileAnswers"

    /// The explicit choice. Absent (`.system`) reproduces the original two-step
    /// behaviour exactly, so nobody's vault changes language on upgrade.
    static let preferenceKey = "vaultLanguage"

    /// Why an explicit control exists on top of the stated answer: that answer is
    /// free prose — "Terse, mostly 日本語", "にほんご", "JP" — and deciding a binary
    /// from prose means substring matching, which fails *silently*. Someone whose
    /// phrasing missed the match read a vault in the wrong language with no way
    /// to say otherwise. The prose still does its job (it is what the AI reads);
    /// this decides only what mull itself writes.
    enum Preference: String, CaseIterable, Identifiable {
        case system, english, japanese

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system:   return "Follow my answer, then the system"
            case .english:  return "English"
            case .japanese: return "日本語"
            }
        }
    }

    static var preference: Preference {
        Preference(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system
    }

    /// The free-text onboarding answer, if the user gave one.
    static var statedLanguage: String? {
        (UserDefaults.standard.dictionary(forKey: onboardingAnswersKey) as? [String: String])?["language"]
    }

    static var isJapanese: Bool { isJapanese(preference: preference) }

    /// Resolution for a preference the caller is holding rather than the stored
    /// one — the Settings picker learns its previous value only after
    /// `@AppStorage` has already written the new one, and it needs both to know
    /// whether the language actually flipped.
    static func isJapanese(preference: Preference) -> Bool {
        resolve(preference: preference, stated: statedLanguage)
    }

    /// Pure, so the precedence is testable without UserDefaults or the vault.
    static func resolve(preference: Preference, stated: String?) -> Bool {
        switch preference {
        case .japanese: return true
        case .english:  return false
        case .system:   break
        }
        if let stated = stated?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !stated.isEmpty {
            return stated.contains("日本語") || stated.contains("japanese")
                || stated == "ja" || stated.hasPrefix("ja-") || stated.hasPrefix("ja_")
        }
        return Locale.preferredLanguages.first?.hasPrefix("ja") == true
    }
}
