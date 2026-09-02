import XCTest
@testable import mull

/// Which language a line mull *already wrote* is in.
///
/// The vault localization made every heading follow the reader. It could not touch
/// what sits under those headings, because an entry is rewritten only when the
/// nightly pass has a reason to update it, and "the reader changed their mind about
/// language" is not a reason it can see. So on 2026-08-18 the author's now.md had
/// Japanese headings over English bullets written in June, and no action anywhere in
/// the app would ever have fixed it.
///
/// `UserLanguage.matchesReader` is what lets the consolidation prompt name those
/// entries so the model restates them. Its whole job is to be right about mixed text:
/// Japanese prose about software is full of Latin identifiers, and English prose about
/// this user's work is full of Japanese project names.
final class StoredLanguageTests: XCTestCase {

    // MARK: - Japanese, including the awkward kinds

    func testJapaneseProseIsJapanese() {
        XCTAssertTrue(UserLanguage.looksJapanese("通知が多すぎて操作の邪魔になると感じた"))
        XCTAssertTrue(UserLanguage.looksJapanese("オンボーディングの権限説明が不親切で改善が必要"))
    }

    /// The case the ratio exists for: a sentence that is mostly Latin identifiers and
    /// is nonetheless Japanese.
    func testJapaneseAroundLatinIdentifiersIsStillJapanese() {
        XCTAssertTrue(UserLanguage.looksJapanese(
            "クリーンcloneでビルドが通らない原因は project.yml の configFiles"))
        XCTAssertTrue(UserLanguage.looksJapanese("Formiq Web のトップページのスマホ表示を直した"))
    }

    func testKatakanaAlone() {
        XCTAssertTrue(UserLanguage.looksJapanese("スクリーンショットのバグ"))
    }

    // MARK: - English, including the kind with Japanese in it

    func testEnglishProseIsNotJapanese() {
        XCTAssertFalse(UserLanguage.looksJapanese(
            "Stress-testing Formiq/UTAGE new signup and email linking (17 Aug 2026)."))
        XCTAssertFalse(UserLanguage.looksJapanese("Gold verification cannot be tested."))
    }

    /// An English line that quotes a Japanese title is English. This is the one that
    /// decides whether the threshold is a ratio or a contains-check — a contains-check
    /// would send this to the model to be "restated in English" forever.
    func testEnglishQuotingAJapaneseTitleIsEnglish() {
        XCTAssertFalse(UserLanguage.looksJapanese(
            "Editing a YouTube project in Premiere Pro, on the video called エクスパンション, "
            + "which has been in progress since the start of the month and is not finished."))
    }

    // MARK: - What may be handed to the model as ‘wrong language’

    func testALineInTheReadersLanguageIsLeftAlone() {
        XCTAssertTrue(UserLanguage.matchesReader("通知が多すぎて邪魔だと感じた", japanese: true))
        XCTAssertTrue(UserLanguage.matchesReader("Prefers terse answers, no preamble.", japanese: false))
    }

    func testALineInTheOtherLanguageIsNamed() {
        XCTAssertFalse(UserLanguage.matchesReader("Gold verification cannot be tested.", japanese: true))
        XCTAssertFalse(UserLanguage.matchesReader("通知が多すぎて邪魔だと感じた", japanese: false))
    }

    /// A bare date, a project name, a version string. Nothing here has a language, and
    /// asking the model to "restate it in Japanese" would corrupt it.
    func testLanguageNeutralTextIsNeverNamed() {
        for text in ["", "Mull", "v1.2.0", "2026-08-17", "Formiq"] {
            XCTAssertTrue(UserLanguage.matchesReader(text, japanese: true), "named ‘\(text)’")
            XCTAssertTrue(UserLanguage.matchesReader(text, japanese: false), "named ‘\(text)’")
        }
    }

    // MARK: - The prompt actually carries the instruction

    func testTheConsolidationPromptAsksForTheRestatement() throws {
        let engine = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Mull/Services/MullEngine.swift"),
            encoding: .utf8)

        XCTAssertTrue(engine.contains("UserLanguage.matchesReader"),
                      "the prompt has to know which entries are in the wrong language")
        XCTAssertTrue(engine.contains("Entries written in the wrong language"))
        XCTAssertTrue(engine.contains("keeping `name` exactly as written here"),
                      "name is how mull matches an update; a renamed entry is a new one")
    }
}
