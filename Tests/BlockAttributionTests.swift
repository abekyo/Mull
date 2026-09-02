import XCTest
@testable import mull

/// Locks what a stretch about nothing is said to be *for* — and, as carefully, what
/// it is not said to be.
///
/// `BlockAttributor` reads a browser block by what stood around it. The readings
/// that count minutes toward a document are the ones a day summary and a morning
/// plan will act on, so each is pinned here both ways: the case that produces it and
/// the nearest case that must not. Segmenter-level, no database — the segments are
/// built by hand at fixed times, so a result cannot depend on the wall clock.
final class BlockAttributionTests: XCTestCase {

    // MARK: - Fixtures

    /// A fixed clock time on a fixed day, from components, so every zone agrees.
    private func at(_ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 10
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    private func seg(_ hour: Int, _ minute: Int, _ app: String, _ title: String,
                     type: RecordingEvent.EventType = .screenText, text: String = "") -> EventSegment {
        EventSegment(timestamp: at(hour, minute), app: app, windowTitle: title, eventType: type, text: text)
    }

    /// A stretch of one app on one title, one event a minute — dense enough to be a
    /// single block, long enough to survive the 30-second floor.
    private func stretch(_ app: String, _ title: String, from: (Int, Int), to: (Int, Int)) -> [EventSegment] {
        var out: [EventSegment] = []
        var t = at(from.0, from.1)
        let end = at(to.0, to.1)
        while t <= end {
            out.append(EventSegment(timestamp: t, app: app, windowTitle: title, eventType: .screenText, text: ""))
            t = t.addingTimeInterval(60)
        }
        return out
    }

    private func blocks(_ segments: [EventSegment]) -> [TimeBlock] {
        BlockSegmenter.blocks(from: segments, resumeGap: BlockSegmenter.defaultResumeGap)
    }

    private let doc = "Roadmap Draft"
    private let page = "Some video - YouTube"

    // MARK: - Readings that are claims

    func testBrowserBetweenTwoStretchesOfTheSameDocumentIsForThatDocument() {
        let day = stretch("Notion", doc, from: (10, 0), to: (10, 20))
            + stretch("Google Chrome", page, from: (10, 24), to: (10, 40))
            + stretch("Notion", doc, from: (10, 44), to: (11, 0))
        let result = blocks(day)

        XCTAssertEqual(result.count, 3, "four-minute gaps split, and nothing here rejoins")
        let browser = result[1]
        XCTAssertEqual(browser.app, "Google Chrome")
        XCTAssertEqual(browser.servedBy?.artifact, doc)
        XCTAssertEqual(browser.servedBy?.basis, .sandwiched)
        XCTAssertTrue(browser.servedBy!.basis.isClaim)
        XCTAssertNil(result[0].servedBy, "a block about something is not read")
        XCTAssertNil(result[2].servedBy)
    }

    func testARunOfBrowserStretchesIsReadAsOneExcursion() {
        // Two browsers, not one: two Chrome stretches four minutes apart are one
        // session to `coalesceResumed` (same app, nothing to tell them apart) and
        // would rejoin into a single block before attribution ever saw a run.
        let day = stretch("Notion", doc, from: (10, 0), to: (10, 20))
            + stretch("Google Chrome", page, from: (10, 24), to: (10, 30))
            + stretch("Firefox", "Another page — Mozilla Firefox", from: (10, 34), to: (10, 40))
            + stretch("Notion", doc, from: (10, 44), to: (11, 0))
        let result = blocks(day)

        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[1].servedBy?.basis, .sandwiched)
        XCTAssertEqual(result[2].servedBy?.basis, .sandwiched,
                       "the inner stretch has a browser on one side, and is still inside the excursion")
        XCTAssertEqual(result[2].servedBy?.artifact, doc)
    }

    func testDocumentOpenInsideABrowserStretchIsReadFromWithin() {
        // One block: the switches are under three minutes apart. Chrome holds the
        // face by engaged time; Notion is open in the same stretch.
        let day = [
            seg(10, 0, "Google Chrome", page), seg(10, 2, "Google Chrome", page),
            seg(10, 4, "Notion", doc),
            seg(10, 6, "Google Chrome", page), seg(10, 8, "Google Chrome", page),
            seg(10, 10, "Google Chrome", page), seg(10, 12, "Google Chrome", page),
        ]
        let result = blocks(day)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].app, "Google Chrome")
        XCTAssertEqual(result[0].servedBy?.artifact, doc)
        XCTAssertEqual(result[0].servedBy?.basis, .withinBlock)
    }

    func testCopyingInTheBrowserThenGoingToTheDocumentIsAClaim() {
        // Nothing before the browser: without the copy this would be a one-sided cue.
        let day = stretch("Google Chrome", page, from: (10, 0), to: (10, 10))
            + [seg(10, 11, "Google Chrome", page, type: .clipboard, text: "a paragraph worth keeping")]
            + stretch("Notion", doc, from: (10, 15), to: (10, 30))
        let result = blocks(day)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].servedBy?.artifact, doc)
        XCTAssertEqual(result[0].servedBy?.basis, .clipboardFlow)
    }

    // MARK: - Readings that are only cues

    func testBrowserAfterOneDocumentAndBeforeAnotherIsOnlyACue() {
        let day = stretch("Notion", doc, from: (10, 0), to: (10, 20))
            + stretch("Google Chrome", page, from: (10, 24), to: (10, 40))
            + stretch("Notion", "Budget Sheet", from: (10, 44), to: (11, 0))
        let result = blocks(day)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[1].servedBy?.basis, .before)
        XCTAssertEqual(result[1].servedBy?.artifact, doc)
        XCTAssertFalse(result[1].servedBy!.basis.isClaim,
                       "two different documents on either side cannot say which one the page served")
    }

    func testBrowserWithADocumentOnlyAfterItIsOnlyACue() {
        let day = stretch("Google Chrome", page, from: (10, 0), to: (10, 16))
            + stretch("Notion", doc, from: (10, 20), to: (10, 40))
        let result = blocks(day)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].servedBy?.basis, .after)
        XCTAssertFalse(result[0].servedBy!.basis.isClaim)
    }

    // MARK: - What breaks the reading

    func testABreakLongerThanTheResumeWindowBreaksTheReading() {
        // Twenty-minute gaps on both sides: past the ten-minute window, the document
        // is not "next to" the page any more.
        let day = stretch("Notion", doc, from: (10, 0), to: (10, 20))
            + stretch("Google Chrome", page, from: (10, 40), to: (10, 56))
            + stretch("Notion", doc, from: (11, 16), to: (11, 30))
        let result = blocks(day)

        XCTAssertEqual(result.count, 3)
        XCTAssertNil(result[1].servedBy)
    }

    func testAPageTitleIsNeverAnArtifact() {
        // Two browser stretches around a third: nothing here is about anything.
        let day = stretch("Google Chrome", "Docs - Google", from: (10, 0), to: (10, 10))
            + stretch("Firefox", page, from: (10, 14), to: (10, 24))
            + stretch("Google Chrome", "Docs - Google", from: (10, 28), to: (10, 40))
        let result = blocks(day)

        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.allSatisfy { $0.servedBy == nil })
    }

    // MARK: - What counts as an artifact, and its key

    func testArtifactOfATitleAgreesWithTheTaskKeyOfABlockOnIt() {
        // The reading's key and the segmenter's key must be the same string, or a
        // consumer grouping by key puts the page and the document in different
        // buckets — which is the whole thing this exists to prevent.
        let cases: [(app: String, title: String)] = [
            ("Notion", doc),
            ("Code", "Parser.swift — MyProject"),
            // `.mov`, not `.mp4`: the segmenter's filename rule takes letter-only
            // extensions, so a digit in the extension is not a file to it.
            ("QuickTime Player", "Episode36.mov"),
        ]
        for c in cases {
            let one = blocks(stretch(c.app, c.title, from: (10, 0), to: (10, 5)))
            XCTAssertEqual(one.count, 1, c.title)
            let read = BlockAttributor.artifact(inTitle: c.title, app: c.app, chrome: [])
            XCTAssertNotNil(read, c.title)
            XCTAssertEqual(read?.key, BlockSegmenter.normalizeTaskKey(one[0], chrome: []), c.title)
        }
    }

    func testAnEditorTitleNamesItsProjectAndAPageNamesNothing() {
        XCTAssertEqual(BlockAttributor.artifact(inTitle: "Parser.swift — MyProject", app: "Code", chrome: [])?.name,
                       "MyProject")
        XCTAssertNil(BlockAttributor.artifact(inTitle: "MyProject - Google Search", app: "Google Chrome", chrome: []))
    }

    func testAPlaceholderTitleNamesNothing() {
        XCTAssertNil(BlockAttributor.artifact(inTitle: "Untitled", app: "Notion", chrome: []))
    }

    func testTheRecordersOwnFallbackTextNamesNothing() {
        // What a row's title becomes when the recorder had none: the app's name on
        // arrival, "App: unknown (dur)" on departure. Both reached real readings.
        XCTAssertNil(BlockAttributor.artifact(inTitle: "Parallels Desktop", app: "Parallels Desktop", chrome: []))
        XCTAssertNil(BlockAttributor.artifact(inTitle: "parallels desktop", app: "Parallels Desktop", chrome: []))
        XCTAssertNil(BlockAttributor.artifact(inTitle: "Code: unknown (26s)", app: "Code", chrome: []))
        XCTAssertNil(BlockAttributor.artifact(inTitle: "ChatGPT: unknown (18s)", app: "ChatGPT", chrome: []))
    }

    func testABlockCaptionedByItsAppNameIsNotAnAnchor() {
        // Old rows: Parallels with no title on either side of a bare Code stretch.
        // Nothing here names a document, so nothing is read.
        let day = stretch("Parallels Desktop", "Parallels Desktop", from: (10, 0), to: (10, 10))
            + stretch("Code", "Code", from: (10, 14), to: (10, 30))
            + stretch("Parallels Desktop", "Parallels Desktop", from: (10, 34), to: (10, 44))
        let result = blocks(day)

        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.allSatisfy { $0.servedBy == nil })
    }

    func testAJapaneseDocumentTitleIsAnArtifact() {
        // The shape this exists for: a script in Notion, named with a full-width
        // colon and no separator the parser knows. It has to pass every gate.
        let title = "台本：MT5おすすめインジ20選"
        let read = BlockAttributor.artifact(inTitle: title, app: "Notion", chrome: [])
        XCTAssertEqual(read?.name, title)
        let one = blocks(stretch("Notion", title, from: (10, 0), to: (10, 5)))
        XCTAssertEqual(read?.key, BlockSegmenter.normalizeTaskKey(one[0], chrome: []))
    }
}
