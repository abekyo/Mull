import XCTest
@testable import mull

/// The human-facing vault files speak the user's language; the AI contract files
/// (me.md / now.md / full.md / MEMORY.md) stay English. These tests pin the
/// pieces of that split that fail silently: a template line that leaks into
/// me.md, a locale switch that stacks a second onboarding section, a folder or
/// section someone adds without a translation.
final class VaultLocalizationTests: XCTestCase {

    // MARK: - UserLanguage

    func testStatedWorkingLanguageBeatsSystemLocale() {
        let key = UserLanguage.onboardingAnswersKey
        let saved = UserDefaults.standard.dictionary(forKey: key)
        let savedPreference = UserDefaults.standard.string(forKey: UserLanguage.preferenceKey)
        defer {
            UserDefaults.standard.set(saved, forKey: key)
            UserDefaults.standard.set(savedPreference, forKey: UserLanguage.preferenceKey)
        }
        // This is the no-explicit-choice path; a leftover preference would decide
        // the answer before the stated one was consulted.
        UserDefaults.standard.removeObject(forKey: UserLanguage.preferenceKey)

        UserDefaults.standard.set(["language": "Japanese (日本語)"], forKey: key)
        XCTAssertTrue(UserLanguage.isJapanese, "stated Japanese wins whatever the OS locale is")

        UserDefaults.standard.set(["language": "English"], forKey: key)
        XCTAssertFalse(UserLanguage.isJapanese, "stated English wins too — no locale fallback once stated")

        UserDefaults.standard.set(["language": "日本語で"], forKey: key)
        XCTAssertTrue(UserLanguage.isJapanese)
    }

    /// The reason the picker was added: an explicit choice has to win over prose
    /// that a substring match reads the other way, in both directions.
    func testExplicitChoiceOverridesTheStatedAnswer() {
        XCTAssertTrue(UserLanguage.resolve(preference: .japanese, stated: "English only please"))
        XCTAssertFalse(UserLanguage.resolve(preference: .english, stated: "Japanese (日本語)"))
        XCTAssertTrue(UserLanguage.resolve(preference: .japanese, stated: nil))
        XCTAssertFalse(UserLanguage.resolve(preference: .english, stated: nil))
    }

    /// …and that `.system` is not a third behaviour but the old one, unchanged —
    /// so upgrading does not move anybody's vault to another language.
    func testSystemChoiceKeepsThePreviousPrecedence() {
        XCTAssertTrue(UserLanguage.resolve(preference: .system, stated: "Japanese (日本語)"))
        XCTAssertTrue(UserLanguage.resolve(preference: .system, stated: "ja-JP"))
        XCTAssertFalse(UserLanguage.resolve(preference: .system, stated: "English"))

        // The silent failure the picker exists for: prose a reader would call
        // Japanese that the match does not see, so it falls through to the locale.
        let localeIsJapanese = Locale.preferredLanguages.first?.hasPrefix("ja") == true
        for missed in ["にほんご", "JP", "日本"] {
            XCTAssertEqual(UserLanguage.resolve(preference: .system, stated: missed), localeIsJapanese,
                           "\"\(missed)\" is unmatched prose — only the explicit choice can fix it")
            XCTAssertTrue(UserLanguage.resolve(preference: .japanese, stated: missed))
        }
    }

    func testStoredPreferenceIsWhatIsJapaneseReads() {
        let saved = UserDefaults.standard.string(forKey: UserLanguage.preferenceKey)
        defer { UserDefaults.standard.set(saved, forKey: UserLanguage.preferenceKey) }

        UserDefaults.standard.set(UserLanguage.Preference.japanese.rawValue,
                                  forKey: UserLanguage.preferenceKey)
        XCTAssertEqual(UserLanguage.preference, .japanese)
        XCTAssertTrue(UserLanguage.isJapanese)

        UserDefaults.standard.set(UserLanguage.Preference.english.rawValue,
                                  forKey: UserLanguage.preferenceKey)
        XCTAssertFalse(UserLanguage.isJapanese)

        // Garbage in the defaults must not decide the language.
        UserDefaults.standard.set("klingon", forKey: UserLanguage.preferenceKey)
        XCTAssertEqual(UserLanguage.preference, .system)
    }

    func testAnswersKeyMirrorsOnboardingProfile() {
        // UserLanguage keeps its own literal so Core stays Services-free; this is
        // the assertion that stops the two constants drifting apart.
        XCTAssertEqual(UserLanguage.onboardingAnswersKey, OnboardingProfile.answersKey)
    }

    // MARK: - me.pinned.md scaffold

    func testPinnedTemplateContributesNothingToMeMd() {
        // Every template line is a heading or a quote; if one loses its marker,
        // the scaffold text becomes an "authoritative fact" at the top of me.md.
        for japanese in [true, false] {
            let (text, withheld) = Curator.filterPinned(Curator.pinnedTemplate(japanese: japanese))
            XCTAssertTrue(text.isEmpty, "template must be inert (japanese: \(japanese))")
            XCTAssertTrue(withheld.isEmpty)
        }
    }

    /// me.pinned.md is a `.md`, and markdown has no `#` comment. The old scaffold
    /// used one anyway, so every explanation line rendered as an H1 and the bare
    /// `#` spacers rendered as a hash mark on an otherwise empty line — in mull's
    /// own preview as much as in Obsidian or GitHub.
    func testPinnedTemplateRendersAsMarkdown() {
        for japanese in [true, false] {
            let lines = Curator.pinnedTemplate(japanese: japanese)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            XCTAssertEqual(lines.filter { $0.hasPrefix("#") }.count, 1,
                           "exactly one heading — the title (japanese: \(japanese))")
            for line in lines where line.hasPrefix("#") {
                XCTAssertTrue(line.hasPrefix("# ") && line.count > 2,
                              "'\(line)' renders as an empty heading / stray hash")
            }
            for line in lines where !line.hasPrefix("#") {
                XCTAssertTrue(line.hasPrefix(">"),
                              "'\(line)' is neither title nor quote, so it lands in me.md")
            }
        }
    }

    func testPristineScaffoldDetection() {
        XCTAssertTrue(Curator.isPristineScaffold(Curator.pinnedTemplate(japanese: true)))
        XCTAssertTrue(Curator.isPristineScaffold(Curator.pinnedTemplate(japanese: false)))
        XCTAssertTrue(Curator.isPristineScaffold(""))
        XCTAssertTrue(Curator.isPristineScaffold("\n  \n# comment\n"))
        // The pre-markdown scaffold, verbatim: still nothing but mull's own words,
        // so a user upgrading gets the readable version instead of keeping the hashes.
        XCTAssertTrue(Curator.isPristineScaffold(
            "# Facts AI should always get right about you. mull NEVER overwrites this file.\n#\n# You can delete these comment lines.\n"))

        XCTAssertFalse(Curator.isPristineScaffold("# comment\n- 仕事は日本語。"),
                       "one user-written line makes the file theirs — never rewrite it")
        XCTAssertFalse(Curator.isPristineScaffold(
            "# ── mull profile (from onboarding · edit in Settings) ──\n- Role: founder\n# ── end mull profile ──"),
            "projected onboarding facts are user content too")
    }

    /// Old files must keep parsing to the same facts: the `#` scaffold and the
    /// `# ── … ──` onboarding markers are headings, so they are skipped either way.
    func testLegacyHashScaffoldStillFiltered() {
        let legacy = """
            # Facts AI should always get right about you. mull NEVER overwrites this file.
            #
            # Every line that does NOT start with '#' is placed at the top of me.md.

            # ── mull profile (from onboarding · edit in Settings) ──
            - Role: Solo founder
            # ── end mull profile ──
            """
        XCTAssertEqual(Curator.filterPinned(legacy).text, "- Role: Solo founder")
    }

    // MARK: - Onboarding section markers

    func testRemoveSectionStripsEveryMarkerVariantEverShipped() {
        // A vault written under English macOS, later opened under Japanese (or
        // vice versa): removal must match the OLD markers, or every save stacks
        // a fresh section under the current language on top of the stale one.
        let body = "# my own comment\n- my own pinned fact"
        let english = body + "\n\n# ── mull profile (from onboarding · edit in Settings) ──\n- Role: founder\n# ── end mull profile ──\n"
        let japanese = body + "\n\n# ── mull プロフィール（オンボーディングの回答 · Settings で編集） ──\n- Role: founder\n# ── mull プロフィール ここまで ──\n"

        for text in [english, japanese] {
            let stripped = OnboardingProfile.removeSection(from: text)
            XCTAssertFalse(stripped.contains("Role: founder"))
            XCTAssertTrue(stripped.contains("- my own pinned fact"), "only the managed section goes")
        }
    }

    /// Saving the profile twice must leave the same file, not a taller one.
    ///
    /// `writeSection` puts a blank line in front of the start marker on every save;
    /// removal took the marker lines and left that blank behind, so each save added
    /// one. Onboarding's Save & Continue and Settings › Profile both write through
    /// here, which made merely revisiting the form grow the gap in a file mull has
    /// promised never to damage. Written against the removal half because that is
    /// where the collapse lives — the projection itself touches the real vault.
    func testRepeatedSavesDoNotGrowTheGapBeforeTheSection() {
        let start = "# ── mull profile (from onboarding · edit in Settings) ──"
        let end = "# ── end mull profile ──"

        // The exact shape `writeSection` produces, given already-stripped text.
        func project(into existing: String) -> String {
            var text = OnboardingProfile.removeSection(from: existing)
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            return text + "\n\(start)\n- Role: founder\n\(end)\n"
        }

        var file = "# my own comment\n\n- my own pinned fact\n"
        let first = project(into: file)
        file = first
        for save in 2...5 {
            file = project(into: file)
            XCTAssertEqual(file, first, "save #\(save) changed a file that should have settled")
        }

        // And a file that already accumulated blanks under the old code heals
        // rather than shrinking by one line per visit.
        let accumulated = "- my own pinned fact\n\n\n\n\n\n\(start)\n- Role: founder\n\(end)\n"
        XCTAssertFalse(project(into: accumulated).contains("\n\n\n"),
                       "an existing run of blank lines should collapse, not persist")
    }

    // The folder-ontology translation tests lived here: every numbered folder had a
    // Japanese title, purpose, per-section heading, fill guidance and empty hint, and
    // these pinned the maps against the schema so a new folder could not ship
    // half-translated. All of it went with the folders on 2026-08-09 (DIRECTION §6.1).
    // What is left in the vault that follows the reader's language is the pinned-facts
    // scaffold and its markers, which the tests above this line already cover.
}
