import Foundation

/// One answer to "which language does the human read?" for every file mull
/// writes *for the user* (me.pinned.md's scaffold, proactive briefs, folder
/// indexes, inbox digests) and for notifications.
///
/// The system locale is the wrong first witness: plenty of people run macOS in
/// English and work in Japanese — this vault's own history is typed through a
/// Japanese IME on an en-US system. So the user's *stated* working language
/// (the onboarding "What language should AI reply in?" answer) wins when
/// present, and the locale is only the fallback.
///
/// Deliberately NOT applied to the AI-facing contract files — me.md, now.md,
/// full.md, MEMORY.md stay in stable English because their audience is whatever
/// model the user pastes them into, and a fixed format survives locale changes.
/// The split is the same one TimeFormat draws between `person` and `machine`.
enum UserLanguage {

    /// Mirror of `OnboardingProfile.answersKey` — kept literal here so Core
    /// stays free of Services imports; a test asserts the two agree.
    static let onboardingAnswersKey = "onboardingProfileAnswers"

    static var isJapanese: Bool {
        let answers = UserDefaults.standard
            .dictionary(forKey: onboardingAnswersKey) as? [String: String]
        if let stated = answers?["language"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !stated.isEmpty {
            return stated.contains("日本語") || stated.contains("japanese")
                || stated == "ja" || stated.hasPrefix("ja-") || stated.hasPrefix("ja_")
        }
        return Locale.preferredLanguages.first?.hasPrefix("ja") == true
    }
}
