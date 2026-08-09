import XCTest
@testable import mull

/// Locks the human-facing half of the proactive loop — the part the user actually
/// reads in proactive.md. The shipped vault showed what the raw path produces:
/// the same window title six times, romaji IME fragments as "threads", app names
/// and filenames briefed as projects, and every block ever written accumulating
/// forever. Each test here pins the rule that removes one of those failure modes.
final class ProactiveBriefTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func result(
        _ text: String,
        ago: TimeInterval = 60,
        app: String? = nil,
        type: String = "activity",
        entity: String? = nil
    ) -> Selection.Result {
        Selection.Result(timestamp: now.addingTimeInterval(-ago), app: app,
                         type: type, entity: entity, text: text, eventID: nil)
    }

    // MARK: - digestLines: dedup

    func testRepeatedWindowTitlesCollapseToOneLine() {
        // The 5s window poller records the same title over and over; the old
        // digest printed all six. One line carries all the information.
        let items = (0..<6).map { i in
            result("Storyboard refactor plan", ago: TimeInterval(i) * 100, app: "Notion")
        }

        let lines = ProactiveLoop.digestLines(entity: "PantryApp", items: items, japanese: false)

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("Storyboard refactor plan"))
    }

    func testDedupIsCaseAndWhitespaceInsensitive() {
        let items = [
            result("Storyboard  Refactor Plan"),
            result("storyboard refactor plan"),
        ]

        XCTAssertEqual(ProactiveLoop.digestLines(entity: "PantryApp", items: items, japanese: false).count, 1)
    }

    // MARK: - digestLines: entity echo suppression

    func testLineThatOnlyEchoesTheEntityAndChromeIsDropped() {
        // "元のプロファイル — Mozilla Firefox" under the 元のプロファイル brief:
        // every segment is the entity itself or browser chrome. Zero information.
        let items = [result("元のプロファイル — Mozilla Firefox", app: "Mozilla Firefox")]

        XCTAssertTrue(ProactiveLoop.digestLines(entity: "元のプロファイル", items: items).isEmpty)
    }

    func testEntitySegmentIsStrippedButRealContentSurvives() {
        let items = [result("AI agents as context-aware tools — Dream", app: "Claude")]

        let lines = ProactiveLoop.digestLines(entity: "Dream", items: items, japanese: false)

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("AI agents as context-aware tools"))
        XCTAssertFalse(lines[0].contains("Dream"), "the entity segment is the brief's own frame, not news")
    }

    // MARK: - digestLines: labels

    func testOnlySalientTypesCarryALabel() {
        // "activity" was internal vocabulary leaking into user-facing text; the
        // when/app columns replace it. note/error/decision earn a localized word.
        let items = [
            result("bump the version before release", type: "note"),
            result("checked the dashboard layout", ago: 120, type: "activity"),
        ]

        let en = ProactiveLoop.digestLines(entity: "PantryApp", items: items, japanese: false)
        XCTAssertTrue(en[0].contains("note: "))
        XCTAssertFalse(en[1].contains("activity"))

        let ja = ProactiveLoop.digestLines(entity: "PantryApp", items: items, japanese: true)
        XCTAssertTrue(ja[0].contains("メモ: "))
    }

    func testLimitIsRespectedAfterFiltering() {
        let items = (0..<20).map { i in
            result("distinct working thread number \(i)", ago: TimeInterval(i) * 60)
        }

        XCTAssertEqual(ProactiveLoop.digestLines(entity: "PantryApp", items: items, japanese: false).count, 6)
    }

    // MARK: - ruleHeadline

    func testHeadlineStatesRecencyAndDominantApp() {
        let items = [
            result("layout pass", ago: 2 * 86_400, app: "Xcode"),
            result("second layout pass", ago: 2 * 86_400 + 60, app: "Xcode"),
            result("wrote the release note", ago: 3 * 86_400, app: "Notion"),
        ]

        let en = ProactiveLoop.ruleHeadline(entity: "PantryApp", items: items, now: now, japanese: false)
        XCTAssertTrue(en.contains("2 days ago"), en)
        XCTAssertTrue(en.contains("Xcode"), en)

        let ja = ProactiveLoop.ruleHeadline(entity: "PantryApp", items: items, now: now, japanese: true)
        XCTAssertTrue(ja.contains("2日前"), ja)
        XCTAssertTrue(ja.contains("Xcode"), ja)
    }

    func testHeadlineSaysTodayForSameDayWork() {
        let items = [result("layout pass", ago: 3600, app: "Xcode")]

        XCTAssertTrue(ProactiveLoop.ruleHeadline(entity: "PantryApp", items: items, now: now, japanese: true)
            .contains("今日"))
        XCTAssertTrue(ProactiveLoop.ruleHeadline(entity: "PantryApp", items: items, now: now, japanese: false)
            .contains("earlier today"))
    }

    func testHeadlineWithNoItemsIsStillASentenceNotATemplateDump() {
        XCTAssertEqual(ProactiveLoop.ruleHeadline(entity: "PantryApp", items: [], now: now, japanese: false),
                       "Back on PantryApp.")
    }

    // MARK: - stillBriefable (write-time re-judgment)

    func testBlockNamingARealProjectIsKept() {
        let block = ContextBlock(id: "brief:pantryapp", source: .agent,
                                 content: "## PantryApp\n\nheadline", agentHash: nil)
        XCTAssertTrue(ProactiveLoop.stillBriefable(block))
    }

    func testBlocksNamingAppNamesAndFilenamesArePruned() {
        // Fossils of older extraction: today's ProjectNames rejects these
        // entities, so the write-time re-judgment must sweep their blocks out.
        for name in ["LINE", "Mozilla Firefox", "FX学習動画の準備完了.mp4", "Claude"] {
            let block = ContextBlock(id: "brief:\(ContextBlockFile.slug(name))", source: .agent,
                                     content: "## \(name)\n\nheadline", agentHash: nil)
            XCTAssertFalse(ProactiveLoop.stillBriefable(block), name)
        }
    }

    func testBlockWithoutAHeadingIsPruned() {
        let block = ContextBlock(id: "brief:x", source: .agent, content: "orphan text", agentHash: nil)
        XCTAssertFalse(ProactiveLoop.stillBriefable(block))
    }

    // MARK: - Brief lifecycle through the Curator (pure merge)

    func testStaleBriefBlocksArePrunedAndHumanEditsSurvive() {
        // The legacy file: a garbage agent brief, and a block the user edited.
        let garbage = ContextBlock(id: "brief:downloads", source: .agent,
                                   content: "## Downloads\n\nBack on Downloads.", agentHash: nil)
        let edited = ContextBlock(id: "brief:元のプロファイル", source: .human,
                                  content: "## 元のプロファイル\n\nmy own words", agentHash: nil)
        let existing = ContextBlockFile.serialize(
            header: "# Proactive briefs",
            blocks: [garbage, edited].map { block in
                var b = block
                if b.source == .agent { b.agentHash = ContextBlock.hash(b.content) }
                return b
            })

        // A new brief write submits only the blocks that still qualify (none of
        // the old ones) plus its own, under managedPrefixes ["brief:"].
        let fresh = ContextBlock(id: "brief:pantryapp", source: .agent,
                                 content: "## PantryApp\n\nnew headline", agentHash: nil)
        let merged = Curator.merge(existing: existing, header: "# Proactive briefs",
                                   pinnedContent: nil, agentBlocks: [fresh],
                                   managedPrefixes: ["brief:"])

        XCTAssertFalse(merged.contains("## Downloads"), "unresubmitted agent brief is pruned")
        XCTAssertTrue(merged.contains("my own words"), "human-edited brief is never touched")
        XCTAssertTrue(merged.contains("## PantryApp"))
    }
}

/// The single-title entity path, now app-aware: a content-driven app's window
/// title (browser page, Finder folder) never yields a project, however plausible
/// its shape — the rule ProjectNames.rank always had, applied to the anchor path
/// that ProactiveLoop fires from.
final class EntityAppAwarenessTests: XCTestCase {

    func testFinderAndBrowserTitlesYieldNoEntity() {
        XCTAssertNil(Entity.from("Downloads", app: "Finder"))
        XCTAssertNil(Entity.from("iCloud Drive", app: "Finder"))
        XCTAssertNil(Entity.from("AI agents as context-aware tools", app: "Google Chrome"))
        XCTAssertNil(Entity.from("元のプロファイル", app: "Mozilla Firefox"))
    }

    func testEditorTitlesStillYieldTheProject() {
        XCTAssertEqual(Entity.from("ContentView.swift — PantryApp", app: "Xcode"), "PantryApp")
        XCTAssertEqual(Entity.from("台本：為替手帳", app: "Notion"), "台本：為替手帳")
    }

    func testUnknownOrMissingAppFallsBackToShapeOnly() {
        XCTAssertEqual(Entity.from("PantryApp", app: nil), "PantryApp")
        XCTAssertEqual(Entity.from("PantryApp", app: "SomeNewEditor"), "PantryApp")
    }
}
