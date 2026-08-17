import XCTest
@testable import mull

/// The human-facing vault files speak the user's language; the AI contract files
/// (me.md / now.md / full.md / MEMORY.md) stay English. These tests pin the
/// pieces of that split that fail silently: a template line that leaks into
/// me.md, a locale switch that stacks a second onboarding section, a folder or
/// section someone adds without a translation.
final class VaultLocalizationTests: XCTestCase {

    // MARK: - UserLanguage

    /// The default is the machine's own language setting — not a guess made by
    /// substring-matching the free-prose setup answer.
    ///
    /// That guess is what these tests used to pin ("stated Japanese wins whatever
    /// the OS locale is"). It had no symptom when it missed: phrasing the matcher
    /// did not recognise — "にほんご", "JP", "日本" — silently fell through to the
    /// locale, and the picker existed to undo it. The answer is still prose and
    /// still goes to the AI verbatim; it just decides nothing here.
    func testSystemChoiceFollowsTheMacsLanguageSetting() {
        XCTAssertTrue(UserLanguage.resolve(preference: .system, systemIsJapanese: true))
        XCTAssertFalse(UserLanguage.resolve(preference: .system, systemIsJapanese: false))
    }

    /// The stated answer no longer reaches this decision from any direction.
    func testTheStatedAnswerCannotChangeTheLanguage() {
        let key = UserLanguage.onboardingAnswersKey
        let saved = UserDefaults.standard.dictionary(forKey: key)
        let savedPreference = UserDefaults.standard.string(forKey: UserLanguage.preferenceKey)
        defer {
            UserDefaults.standard.set(saved, forKey: key)
            UserDefaults.standard.set(savedPreference, forKey: UserLanguage.preferenceKey)
        }
        UserDefaults.standard.removeObject(forKey: UserLanguage.preferenceKey)

        for stated in ["Japanese (日本語)", "English", "日本語で", "にほんご", "JP"] {
            UserDefaults.standard.set(["language": stated], forKey: key)
            XCTAssertEqual(UserLanguage.isJapanese, UserLanguage.systemIsJapanese,
                           "\"\(stated)\" must not move the language — macOS decides")
        }
    }

    /// An explicit choice wins over the machine, in both directions. This is the
    /// case the picker exists for: macOS in English, work in Japanese.
    func testExplicitChoiceOverridesTheSystem() {
        XCTAssertTrue(UserLanguage.resolve(preference: .japanese, systemIsJapanese: false))
        XCTAssertFalse(UserLanguage.resolve(preference: .english, systemIsJapanese: true))
        XCTAssertTrue(UserLanguage.resolve(preference: .japanese, systemIsJapanese: true))
        XCTAssertFalse(UserLanguage.resolve(preference: .english, systemIsJapanese: false))
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

    // MARK: - The app's own windows

    /// Everything below writes `AppleLanguages` in the app's own domain, which is
    /// the live setting — the test host *is* mull. Put back exactly what was there,
    /// including "there was nothing".
    private func restoringChrome(_ body: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.object(forKey: UserLanguage.chromeKey)
        let savedPreference = UserDefaults.standard.string(forKey: UserLanguage.preferenceKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: UserLanguage.chromeKey) }
            else { UserDefaults.standard.removeObject(forKey: UserLanguage.chromeKey) }
            if let savedPreference {
                UserDefaults.standard.set(savedPreference, forKey: UserLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: UserLanguage.preferenceKey)
            }
        }
        try body()
    }

    /// "What is macOS set to" must not be answered by mull's own override.
    ///
    /// It was: `systemIsJapanese` read `Locale.preferredLanguages`, and inside the
    /// app that list is led by the app-domain `AppleLanguages` mull itself writes.
    /// So one trip through the picker made `.system` mean "Japanese" on an English
    /// Mac, permanently — the picker's own change detection then compared Japanese
    /// against Japanese, decided nothing had happened, and returned before it could
    /// remove the override. `MullMCP` has no override to read, so the app and the
    /// 13 tools also disagreed about what `.system` meant.
    func testSystemLanguageIgnoresMullsOwnOverride() {
        restoringChrome {
            let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
            let macOSIsJapanese = ((global?[UserLanguage.chromeKey] as? [String])?.first ?? "en")
                .hasPrefix("ja")

            for override in [["ja"], ["en"]] {
                UserDefaults.standard.set(override, forKey: UserLanguage.chromeKey)
                XCTAssertEqual(UserLanguage.systemIsJapanese, macOSIsJapanese,
                               "an override of \(override) rewrote what the system says")
            }
        }
    }

    /// A stored answer reaches the bundle at launch, not only when the picker moves.
    ///
    /// The write used to live in Settings' `onChange`, so a preference stored before
    /// the windows followed it at all left the chrome in the other language for
    /// good: nothing said why, and the only way out was to move the picker off the
    /// answer it was already showing and back onto it.
    func testLaunchPointsTheBundleAtTheStoredChoice() {
        restoringChrome {
            UserDefaults.standard.removeObject(forKey: UserLanguage.chromeKey)
            UserDefaults.standard.set(UserLanguage.Preference.japanese.rawValue,
                                      forKey: UserLanguage.preferenceKey)
            UserLanguage.applyChromeAtLaunch()
            XCTAssertEqual(UserLanguage.chromeOverride, "ja")

            UserDefaults.standard.set(UserLanguage.Preference.english.rawValue,
                                      forKey: UserLanguage.preferenceKey)
            UserLanguage.applyChromeAtLaunch()
            XCTAssertEqual(UserLanguage.chromeOverride, "en")
        }
    }

    /// `.system` clears the override when it is chosen, and a later launch leaves
    /// that alone. Clearing on every launch would delete the per-app entry in
    /// System Settings › General › Language & Region each time mull opened.
    func testSystemClearsTheOverrideOnceRatherThanEveryLaunch() {
        restoringChrome {
            UserLanguage.applyChrome(.japanese)
            XCTAssertEqual(UserLanguage.chromeOverride, "ja")

            UserLanguage.applyChrome(.system)
            XCTAssertNil(UserLanguage.chromeOverride, "choosing macOS hands the windows back")

            // Somebody sets mull's language in System Settings instead. mull's own
            // answer is still `.system`, and a launch must not undo their choice.
            UserDefaults.standard.set(["ja"], forKey: UserLanguage.chromeKey)
            UserDefaults.standard.set(UserLanguage.Preference.system.rawValue,
                                      forKey: UserLanguage.preferenceKey)
            UserLanguage.applyChromeAtLaunch()
            XCTAssertEqual(UserLanguage.chromeOverride, "ja")
        }
    }

    /// The banner in Settings › General is derived from this, and it has to be true
    /// of a launch that came up out of step — not only of a change made this session.
    func testRelaunchNoticeFollowsTheBundleRatherThanThePicker() {
        restoringChrome {
            UserDefaults.standard.set([UserLanguage.runningChrome], forKey: UserLanguage.chromeKey)
            XCTAssertFalse(UserLanguage.chromeNeedsRelaunch,
                           "the windows are already in the language that is set")

            let other = UserLanguage.runningChrome.hasPrefix("ja") ? "en" : "ja"
            UserDefaults.standard.set([other], forKey: UserLanguage.chromeKey)
            XCTAssertTrue(UserLanguage.chromeNeedsRelaunch)

            // A region-tagged value from System Settings resolves to the same
            // `.lproj`, so it is not a mismatch.
            UserDefaults.standard.set(["\(UserLanguage.runningChrome)-GB"],
                                      forKey: UserLanguage.chromeKey)
            XCTAssertFalse(UserLanguage.chromeNeedsRelaunch)
        }
    }

    // MARK: - The shipped strings

    /// Every English string in the bundle has a Japanese one.
    ///
    /// Read from the built `.lproj` rather than from `Localizable.xcstrings`,
    /// because a catalog entry that never compiles into the app is the same
    /// English screen as one that was never written. What is exempt is what reads
    /// the same in both languages: format-only keys, key-equivalent glyphs, and
    /// words of four characters or less (`mull`, `AI`, `OK`).
    func testEveryEnglishStringHasAJapaneseOne() throws {
        let english = try stringsTable("en")
        let japanese = try stringsTable("ja")
        XCTAssertGreaterThan(english.count, 100, "the en table did not load")

        let untranslatable = try NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:@|lld|%)")
        let missing = english.keys.filter { key in
            if japanese[key] != nil { return false }
            if key.count <= 4 { return false }
            if key.contains(where: { "⌘⇧⌥⌃".contains($0) }) { return false }
            let range = NSRange(key.startIndex..., in: key)
            let bare = untranslatable.stringByReplacingMatches(in: key, range: range, withTemplate: "")
            return bare.contains(where: { $0.isLetter })
        }
        XCTAssertEqual(missing.sorted(), [],
                       "these ship in English in a Japanese window")
    }

    /// No key may carry a positional specifier — `%1$@` rather than `%@`.
    ///
    /// Swift builds the lookup key from the literal, and it writes `%@` / `%lld` in
    /// order whatever the argument count: `"\(a) · \(b) recorded"` asks for
    /// `%@ · %@ recorded` and nothing else. Ten entries had been written with the
    /// positional form, so ten Japanese strings sat in the catalog that the app could
    /// never ask for — the screen stayed English and the catalog looked complete,
    /// which is the worst pair of symptoms to have together.
    ///
    /// The *value* may still be positional. A translation that needs the arguments in
    /// another order says so there, and `%2$lld件中 %1$lld件` works.
    func testNoKeyUsesAPositionalSpecifier() throws {
        let positional = try NSRegularExpression(pattern: "%\\d+\\$")
        let offenders = try stringsTable("en").keys.filter { key in
            positional.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
        }
        XCTAssertEqual(offenders.sorted(), [],
                       "Swift never asks for these keys, so their translations are unreachable")
    }

    private func stringsTable(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                            subdirectory: "\(language).lproj"),
            "\(language).lproj/Localizable.strings is not in the bundle")
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil)
        return try XCTUnwrap(plist as? [String: String])
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
        let japanese = body + "\n\n# ── mull プロフィール（セットアップでの回答 · 設定で編集） ──\n- Role: founder\n# ── mull プロフィール ここまで ──\n"
        // The Japanese start marker before it was reworded to match Settings.
        let japaneseLegacy = body + "\n\n# ── mull プロフィール（オンボーディングの回答 · Settings で編集） ──\n- Role: founder\n# ── mull プロフィール ここまで ──\n"

        for text in [english, japanese, japaneseLegacy] {
            let stripped = OnboardingProfile.removeSection(from: text)
            XCTAssertFalse(stripped.contains("Role: founder"))
            XCTAssertTrue(stripped.contains("- my own pinned fact"), "only the managed section goes")
        }
    }

    /// Saving the profile twice must leave the same file, not a taller one.
    ///
    /// `writeSection` puts a blank line in front of the start marker on every save;
    /// removal took the marker lines and left that blank behind, so each save added
    /// one. Onboarding's Save & Continue and Settings › General both write through
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
