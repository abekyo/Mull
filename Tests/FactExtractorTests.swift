import XCTest
import GRDB
@testable import mull

/// Tests for FactExtractor — the rule-based layer that turns raw recorded events into
/// the lines that end up in `me.md`. This is the "portrait" half of mull's promise: an
/// AI reads these facts and knows who the user is without being told. Two failure modes
/// matter and both are tested here. Under-extraction makes mull silent — the user
/// installs it, works for a week, and me.md still says nothing. Over-extraction is
/// worse: a hallucinated "Working on: Untitled" or a role inferred from three stray app
/// switches gets copied into every AI conversation the user has, and they have to
/// notice and correct it. So these tests assert both that real signal produces facts
/// AND that thin/ambiguous signal produces none.
///
/// Every test runs against `DatabaseService.temporary()` — a throwaway SQLite file in a
/// unique temp directory, never the user's real recorded history.
final class FactExtractorTests: XCTestCase {

    private var db: DatabaseService!
    private var analytics: AnalyticsEngine!
    private var extractor: FactExtractor!

    override func setUp() {
        super.setUp()
        db = try! DatabaseService.temporary()
        analytics = AnalyticsEngine(database: db)
        extractor = FactExtractor(analytics: analytics, database: db)
    }

    // MARK: - Empty database

    func testEmptyDatabaseProducesNoFacts() {
        // A fresh install must claim nothing. Anything asserted here would be a
        // fact invented from zero evidence.
        XCTAssertTrue(extractor.extractFacts(days: 7).isEmpty)
    }

    func testEmptyDatabaseProducesEmptySummary() {
        // generateFactSummary early-returns "" rather than emitting a header with no
        // body — me.md must not gain an empty section on day one.
        XCTAssertEqual(extractor.generateFactSummary(days: 7), "")
    }

    // MARK: - Role inference

    func testInfersSoftwareDeveloperFromDevToolUsage() {
        // The "Software developer" profile requires 2+ matching apps in the top 8,
        // so a single editor is not enough evidence — Xcode AND Terminal are.
        insertAppSwitches(app: "Xcode", count: 5)
        insertAppSwitches(app: "Terminal", count: 4)

        let facts = extractor.extractFacts(days: 1)
        let identity = texts(facts, in: .identity)

        XCTAssertTrue(identity.contains { $0.contains("Software developer") },
                      "Expected a developer role fact, got: \(identity)")
        // The fact names its evidence — that disclosure is a product requirement,
        // not decoration (the user has to be able to see WHY mull decided this).
        XCTAssertTrue(identity.contains { $0.contains("Xcode") && $0.contains("Terminal") })
    }

    func testSingleDevAppIsNotEnoughForDeveloperRole() {
        // minMatch of 2 for the developer profile: one app could be incidental.
        insertAppSwitches(app: "Xcode", count: 8)

        let identity = texts(extractor.extractFacts(days: 1), in: .identity)
        XCTAssertFalse(identity.contains { $0.contains("Software developer") })
    }

    func testInfersDesignerFromSingleDesignApp() {
        // Designer/Writer/Researcher profiles use minMatch 1 — those apps are far
        // more specific than "Terminal", so one is sufficient evidence.
        insertAppSwitches(app: "Figma", count: 6)

        let identity = texts(extractor.extractFacts(days: 1), in: .identity)
        XCTAssertTrue(identity.contains { $0.contains("Designer") },
                      "Expected a designer role fact, got: \(identity)")
    }

    // MARK: - Tool / skill inference

    func testInfersPrimaryToolsExcludingBrowsers() {
        // Browsers are deliberately excluded: which browser someone uses does not
        // change an AI's answer, so it must not occupy a "primary tools" slot.
        insertAppSwitches(app: "Xcode", count: 10)
        insertAppSwitches(app: "Safari", count: 20)
        insertAppSwitches(app: "Terminal", count: 8)

        let skills = texts(extractor.extractFacts(days: 1), in: .skills)
        let primary = skills.first { $0.hasPrefix("Primary tools:") }

        XCTAssertNotNil(primary, "Expected a primary-tools fact, got: \(skills)")
        XCTAssertTrue(primary!.contains("Xcode"))
        XCTAssertTrue(primary!.contains("Terminal"))
        // Safari has the highest raw count but must not appear.
        XCTAssertFalse(primary!.contains("Safari"))
    }

    func testExcludesNoiseAppsFromPrimaryTools() {
        // mull must never report itself as the user's primary tool.
        insertAppSwitches(app: "mull", count: 50)
        insertAppSwitches(app: "Xcode", count: 5)
        insertAppSwitches(app: "Terminal", count: 5)

        let skills = texts(extractor.extractFacts(days: 1), in: .skills)
        XCTAssertFalse(skills.contains { $0.contains("mull") })
    }

    func testDetectsTechStackFromClipboardContent() {
        // Tech-stack detection reads clipboard text, not app names — copying SwiftUI
        // code is stronger evidence of the stack than merely having Xcode open.
        insertClipboard("VStack { Text(\"hello\") } is the SwiftUI layout I settled on")

        let skills = texts(extractor.extractFacts(days: 1), in: .skills)
        XCTAssertTrue(skills.contains { $0.hasPrefix("Works with:") && $0.contains("SwiftUI") },
                      "Expected a SwiftUI stack fact, got: \(skills)")
    }

    // MARK: - Project inference

    func testInfersProjectFromRepeatedWindowTitles() {
        // Window titles arrive as "Project — File — App". The extractor keeps the
        // project segment, drops the filename (trailing extension <= 5 chars) and
        // drops the app name (skipApps). A project needs 5+ mentions to count, so a
        // file opened once in passing never becomes a claimed project.
        insertScreenText("PantryApp — ViewController.swift — Xcode", count: 6)

        let projects = texts(extractor.extractFacts(days: 1), in: .projects)
        XCTAssertTrue(projects.contains { $0 == "Working on: PantryApp" },
                      "Expected a PantryApp project fact, got: \(projects)")
        // The filename and the app name are not projects.
        XCTAssertFalse(projects.contains { $0.contains("ViewController") })
        XCTAssertFalse(projects.contains { $0.contains("Xcode") })
    }

    func testProjectRequiresRepeatedMentions() {
        // Four mentions is below the threshold of five — deliberately just under, so
        // this test fails if anyone lowers the bar without thinking about it.
        insertScreenText("PantryApp — ViewController.swift — Xcode", count: 4)

        let projects = texts(extractor.extractFacts(days: 1), in: .projects)
        XCTAssertFalse(projects.contains { $0.contains("PantryApp") })
    }

    func testIgnoresPlaceholderWindowTitles() {
        // "Untitled" and "Welcome to …" are in the skip list — they are UI chrome
        // that appears constantly and would otherwise dominate the project ranking.
        insertScreenText("Untitled — Document — Pages", count: 10)
        insertScreenText("Welcome to Xcode — Xcode", count: 10)

        let projects = texts(extractor.extractFacts(days: 1), in: .projects)
        XCTAssertFalse(projects.contains { $0.contains("Untitled") })
        XCTAssertFalse(projects.contains { $0.contains("Welcome") })
    }

    func testIgnoresChatPromptsUsedAsWindowTitles() {
        // Claude Code / ChatGPT put the user's prompt in the window title. Those are
        // questions, not projects — the extractor drops anything with ？/?/！ or a
        // Japanese verb ending. Without this, me.md fills up with the user's own
        // half-typed questions presented as "projects".
        insertScreenText("Refactorがうまくいかない — 修正してください", count: 10)
        insertScreenText("Why is the build failing? — Claude", count: 10)

        let projects = texts(extractor.extractFacts(days: 1), in: .projects)
        XCTAssertFalse(projects.contains { $0.contains("Refactor") })
        XCTAssertFalse(projects.contains { $0.contains("build failing") })
    }

    // MARK: - Noise produces nothing

    func testOrdinaryProseProducesNoFacts() {
        // Real, non-synthetic clipboard text about nothing in particular. This must
        // NOT be phrased as classic test filler ("the quick brown fox", "lorem
        // ipsum", "asdf", adjacent single letters) — TestInput.isLikelyTestInput
        // discards those upstream, so such a fixture would pass vacuously by never
        // reaching the extractor at all. These sentences survive that filter and
        // still, correctly, carry no inferable fact.
        insertClipboard("remember to water the plants before the weekend")
        insertClipboard("picked up bread and milk on the way back")
        insertClipboard("the neighbour dropped off a parcel this morning")

        let facts = extractor.extractFacts(days: 1)
        XCTAssertTrue(facts.isEmpty,
                      "Ordinary prose should yield no facts, got: \(facts.map(\.text))")
    }

    func testThinAppUsageProducesNoRoleFact() {
        // Two switches into an app nobody can classify. No role profile matches, and
        // one app is below the 2-app floor for a primary-tools fact.
        insertAppSwitches(app: "Weather", count: 2)

        let facts = extractor.extractFacts(days: 1)
        XCTAssertTrue(facts.isEmpty,
                      "Unclassifiable app usage should yield no facts, got: \(facts.map(\.text))")
    }

    func testShortClipboardSampleProducesNoLanguageFact() {
        // The language verdict requires 200+ prose characters. A couple of copied
        // lines is not enough to declare someone's primary language — and getting
        // that wrong is visible in every AI conversation thereafter.
        insertClipboard("これは短いメモです")

        let identity = texts(extractor.extractFacts(days: 1), in: .identity)
        XCTAssertFalse(identity.contains { $0.contains("Primary language") })
        XCTAssertFalse(identity.contains { $0.contains("Bilingual") })
    }

    // MARK: - Day window

    func testDayWindowExcludesOlderEvents() {
        // Events from 10 days ago, strong enough to produce a role fact if seen.
        insertAppSwitches(app: "Xcode", count: 5, daysAgo: 10)
        insertAppSwitches(app: "Terminal", count: 5, daysAgo: 10)

        // A 1-day window must not see them...
        let recent = texts(extractor.extractFacts(days: 1), in: .identity)
        XCTAssertFalse(recent.contains { $0.contains("Software developer") },
                       "10-day-old events leaked into a 1-day window: \(recent)")

        // ...but a 30-day window must. This is the pair that proves the parameter is
        // actually threaded through to the queries rather than ignored.
        let wide = texts(extractor.extractFacts(days: 30), in: .identity)
        XCTAssertTrue(wide.contains { $0.contains("Software developer") },
                      "30-day window missed 10-day-old events: \(wide)")
    }

    func testDayWindowBoundsProjectInference() {
        // Same check on the project path, which queries the database directly rather
        // than going through AnalyticsEngine — a separate `since` computation that
        // could drift from the analytics one.
        insertScreenText("PantryApp — ViewController.swift — Xcode", count: 6, daysAgo: 10)

        XCTAssertFalse(texts(extractor.extractFacts(days: 1), in: .projects)
                        .contains { $0.contains("PantryApp") })
        XCTAssertTrue(texts(extractor.extractFacts(days: 30), in: .projects)
                        .contains { $0.contains("PantryApp") })
    }

    // MARK: - Summary rendering

    func testFactSummaryRendersOneBulletPerFact() {
        insertAppSwitches(app: "Xcode", count: 5)
        insertAppSwitches(app: "Terminal", count: 4)

        let facts = extractor.extractFacts(days: 1)
        let summary = extractor.generateFactSummary(days: 1)

        XCTAssertFalse(facts.isEmpty, "precondition: fixture should produce facts")
        let lines = summary.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, facts.count)
        // Markdown bullets — this text is spliced straight into me.md.
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("- ") })
        XCTAssertTrue(summary.contains("Software developer"))
    }

    // MARK: - Helpers

    private func texts(_ facts: [Fact], in category: FactCategory) -> [String] {
        facts.filter { $0.category == category }.map(\.text)
    }

    private func insertAppSwitches(app: String, count: Int, daysAgo: Int = 0) {
        for _ in 0..<count {
            insertEvent(type: .appSwitch, app: app, text: nil, daysAgo: daysAgo)
        }
    }

    private func insertClipboard(_ text: String, daysAgo: Int = 0) {
        insertEvent(type: .clipboard, app: "Code", text: text, daysAgo: daysAgo)
    }

    private func insertScreenText(_ text: String, count: Int, daysAgo: Int = 0) {
        for _ in 0..<count {
            insertEvent(type: .screenText, app: "Xcode", text: text, daysAgo: daysAgo)
        }
    }

    private func insertEvent(type: RecordingEvent.EventType, app: String, text: String?, daysAgo: Int) {
        // Nudged 60s into the past so the row is never timestamped after the `to:`
        // bound that the extractor computes a moment later.
        let timestamp = Date().addingTimeInterval(-60 - Double(daysAgo) * 86_400)
        db.insertEvent(RecordingEvent(
            timestamp: timestamp,
            eventType: type,
            appName: app,
            textContent: text
        ))
    }
}
