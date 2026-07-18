import XCTest
@testable import mull

/// Tests for the shared project-name gate.
///
/// This type exists because four different places in the app each kept their own
/// hand-written blocklist of "things that are not projects", they disagreed with
/// each other, and none of them caught the failure that actually shipped: the
/// vault contained a project file for `元のプロファイル` — Firefox's default
/// profile name, which appears in the title of every Firefox window. mull gave it
/// a dedicated page and paid an LLM to write a brief about it.
///
/// So the tests here are mostly about the *evidence* rule rather than the shape
/// rule, and specifically about the two directions it has to get right: chrome
/// must be rejected, and a project the user has lived in all week must not be
/// mistaken for chrome.
final class ProjectNamesTests: XCTestCase {

    // MARK: - The shipped bug

    func testBrowserProfileNameIsNotAProject() {
        // Exactly the vault's data: a constant middle segment across many pages.
        let observations = (1...8).map { i in
            (app: "Firefox", title: "Some page \(i) — 元のプロファイル — Mozilla Firefox")
        }

        XCTAssertTrue(ProjectNames.chrome(in: observations).contains("元のプロファイル"))
        XCTAssertTrue(ProjectNames.rank(observations, minMentions: 3).isEmpty,
                      "A browser profile name must never rank as a project")
    }

    func testDominantProjectInAnEditorIsNotMistakenForChrome() {
        // The inverse, and the reason `chrome` only inspects content-driven apps.
        // A segment in 100% of an editor's titles is the project the user has
        // been living in — the single worst thing to blocklist.
        let observations = (1...8).map { i in
            (app: "Xcode", title: "PantryApp — File\(i).swift — Xcode")
        }

        XCTAssertFalse(ProjectNames.chrome(in: observations).contains("PantryApp"))
        XCTAssertEqual(ProjectNames.rank(observations, minMentions: 3).first?.name, "PantryApp")
    }

    func testChromeNeedsEnoughDistinctTitlesToJudge() {
        // Below five distinct titles, "appears in all of them" is not evidence.
        let observations = (1...3).map { i in
            (app: "Safari", title: "Page \(i) — Work Profile")
        }
        XCTAssertTrue(ProjectNames.chrome(in: observations).isEmpty)
    }

    func testWebPagesAndFoldersNeverBecomeProjects() {
        // A Finder window called "Downloads" headed a project section in the
        // shipped full.md. A folder name is not a project, and neither is a page.
        let observations = [
            (app: "Finder", title: "Downloads"), (app: "Finder", title: "Downloads"),
            (app: "Finder", title: "Downloads"), (app: "Finder", title: "Downloads"),
            (app: "Safari", title: "Hacker News"), (app: "Safari", title: "Hacker News"),
            (app: "Safari", title: "Hacker News"), (app: "Safari", title: "Hacker News"),
        ]
        XCTAssertTrue(ProjectNames.rank(observations, minMentions: 3).isEmpty)
    }

    // MARK: - Japanese

    func testJapaneseProjectNamesSurvive() {
        // The rule this replaces was `if title.contains("を") { skip }` — a patch
        // for one user's Claude Code session titles that discarded every window
        // title containing the object particle, i.e. most real Japanese document
        // names. These are nouns and must come through.
        for name in ["確定申告アプリ", "見積書テンプレート", "元のプロファイル", "経費精算を自動化"] {
            XCTAssertTrue(ProjectNames.isPlausible(name), "\(name) should be plausible")
        }
    }

    func testJapaneseSentencesAreRejected() {
        // Chat clients put the user's prompt in the window title. These are
        // mostly hiragana — the grammar that binds a sentence, not a name.
        for prompt in ["修正してください", "うまくいかない", "これを直してほしい"] {
            XCTAssertFalse(ProjectNames.isPlausible(prompt), "\(prompt) should be rejected")
        }
    }

    // MARK: - Shape

    func testRejectsNonProjectShapes() {
        XCTAssertFalse(ProjectNames.isPlausible("Why is the build failing?"))
        XCTAssertFalse(ProjectNames.isPlausible("ViewController.swift"))
        XCTAssertFalse(ProjectNames.isPlausible("someone@example.com"))
        XCTAssertFalse(ProjectNames.isPlausible("https://example.com/page"))
        XCTAssertFalse(ProjectNames.isPlausible("Untitled"))
        XCTAssertFalse(ProjectNames.isPlausible("Welcome to Xcode"))
        XCTAssertFalse(ProjectNames.isPlausible("Xcode"))
        XCTAssertFalse(ProjectNames.isPlausible("12:04"))
        XCTAssertFalse(ProjectNames.isPlausible("a fairly long sentence about nothing"))
    }

    func testAcceptsOrdinaryProjectNames() {
        for name in ["PantryApp", "formiq-web", "Mull", "notes-site", "Q3 Report"] {
            XCTAssertTrue(ProjectNames.isPlausible(name), "\(name) should be plausible")
        }
    }

    func testLowercaseProjectNamesAreAccepted() {
        // The old extractor required `first.isUppercase || first.isNumber`, so
        // every kebab-case repo directory — the normal shape of a project on
        // disk — was invisible to it.
        XCTAssertEqual(ProjectNames.rank((1...6).map { i in
            (app: "Code", title: "index\(i).ts — formiq-web")
        }, minMentions: 3).first?.name, "formiq-web")
    }

    // MARK: - Threshold

    func testProjectNeedsRepeatedSightings() {
        let once = [(app: "Xcode", title: "SideQuest — main.swift — Xcode")]
        XCTAssertTrue(ProjectNames.rank(once, minMentions: 5).isEmpty)
    }
}
