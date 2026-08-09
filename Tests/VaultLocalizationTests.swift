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
        defer { UserDefaults.standard.set(saved, forKey: key) }

        UserDefaults.standard.set(["language": "Japanese (日本語)"], forKey: key)
        XCTAssertTrue(UserLanguage.isJapanese, "stated Japanese wins whatever the OS locale is")

        UserDefaults.standard.set(["language": "English"], forKey: key)
        XCTAssertFalse(UserLanguage.isJapanese, "stated English wins too — no locale fallback once stated")

        UserDefaults.standard.set(["language": "日本語で"], forKey: key)
        XCTAssertTrue(UserLanguage.isJapanese)
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

    // MARK: - Folder ontology translations

    func testEveryFolderHasAJapaneseTitleAndPurpose() {
        for folder in FolderOntology.folders {
            XCTAssertNotNil(FolderOntology.jaTitles[folder.number],
                            "folder \(folder.number) \(folder.title) has no Japanese title")
            XCTAssertNotNil(FolderOntology.jaPurposes[folder.number],
                            "folder \(folder.number) \(folder.title) has no Japanese purpose")
        }
    }

    func testEveryDeclaredSectionHasAJapaneseHeading() {
        for folder in FolderOntology.folders {
            for section in folder.sections {
                XCTAssertNotNil(FolderOntology.jaSections[section],
                                "section \"\(section)\" (folder \(folder.number)) has no Japanese heading")
            }
        }
    }

    func testSectionHeadingLocalizesDisplayOnly() {
        XCTAssertEqual(FolderOntology.sectionHeading("Decisions", japanese: true), "決定")
        XCTAssertEqual(FolderOntology.sectionHeading("Decisions", japanese: false), "Decisions")
        // Unknown names fall back rather than vanish.
        XCTAssertEqual(FolderOntology.sectionHeading("Brand new", japanese: true), "Brand new")
    }

    func testGuidanceSpeaksBothLanguagesForEveryFillSource() {
        for folder in FolderOntology.folders {
            let ja = folder.guidance(japanese: true)
            let en = folder.guidance(japanese: false)
            XCTAssertFalse(ja.isEmpty)
            XCTAssertFalse(en.isEmpty)
            XCTAssertNotEqual(ja, en, "folder \(folder.number) guidance is untranslated")

            XCTAssertNotEqual(folder.emptyHint(japanese: true), folder.emptyHint(japanese: false),
                              "folder \(folder.number) empty hint is untranslated")
        }
    }
}
