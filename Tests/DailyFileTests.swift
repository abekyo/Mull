import XCTest
@testable import mull

/// What lands in `daily/`.
///
/// The folder held the wrong thing for long enough to matter: `writeDailyFile` was
/// a no-op, and `LiveContextGenerator` was copying `full.md` in there every 60
/// seconds. So the one place in the vault a person would look for what they did on
/// a Tuesday held an agent's context dump saying "Assembled from me.md and now.md",
/// while the day's actual record lived only in SQLite (DIRECTION §6.2).
final class DailyFileTests: XCTestCase {

    private var db: DatabaseService!
    private var engine: MullEngine!

    override func setUpWithError() throws {
        db = try DatabaseService.temporary()
        _ = MullDirectory.setup()   // throwaway vault under XCTest — see MullDirectory.root
        engine = MullEngine(database: db)
        for path in MullDirectory.markdownFilesRecursively(in: VaultLayout.daily) {
            MullDirectory.delete(path)
        }
    }

    // MARK: - Fixtures

    private func day(_ d: Int) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 8; c.day = d
        return Calendar.current.date(from: c)!
    }

    @discardableResult
    private func summary(_ d: Int, _ text: String, by provider: String = "rule-based") -> DailySummary {
        let s = DailySummary(
            date: day(d), content: text, eventCount: 900,
            processingSeconds: 1, llmProvider: provider, createdAt: day(d))
        db.insertSummary(s)
        return s
    }

    // MARK: - The record reaches the disk

    func testABackfilledDayIsWrittenWhereItsDaySays() {
        summary(9, "# Aug 9, 2026\n\n## Morning\nRead the mail.")
        engine.backfillDailyFiles()

        let text = MullDirectory.read("daily/2026/08/2026-08-09.md")
        XCTAssertNotNil(text, "the day's record belongs at daily/YYYY/MM/YYYY-MM-DD.md")
        XCTAssertTrue(text?.contains("## Morning") == true, "it is the record, not a summary of it")
        XCTAssertTrue(text?.contains("Read the mail.") == true)
    }

    /// Front matter says which day and who wrote it. `written_by` comes off the row,
    /// so a day the model could not answer for is marked as the fallback's work
    /// rather than as the configured provider's.
    func testTheFileSaysWhichDayAndWhoWroteIt() {
        summary(10, "# Aug 10, 2026\n\nSomething.", by: "rule-based")
        engine.backfillDailyFiles()

        let text = MullDirectory.read("daily/2026/08/2026-08-10.md") ?? ""
        XCTAssertTrue(text.contains(#"day: "2026-08-10""#), text)
        XCTAssertTrue(text.contains(#"written_by: "rule-based""#), text)
        XCTAssertTrue(text.contains(MarkdownDoc.generatorStamp))
    }

    /// The summary opens with the day as its own H1. Two would be one too many.
    func testTheRecordKeepsItsOwnHeading() {
        summary(11, "# Aug 11, 2026\n\nSomething.")
        engine.backfillDailyFiles()

        let body = MarkdownDoc.stripFrontMatter(MullDirectory.read("daily/2026/08/2026-08-11.md") ?? "")
        XCTAssertEqual(body.components(separatedBy: "\n# ").count - 1 + (body.hasPrefix("# ") ? 1 : 0), 1,
                       "exactly one H1: \(body)")
    }

    func testBackfillIsIdempotent() {
        summary(12, "# Aug 12, 2026\n\nSomething.")
        engine.backfillDailyFiles()
        let once = MullDirectory.read("daily/2026/08/2026-08-12.md")
        engine.backfillDailyFiles()
        XCTAssertEqual(MullDirectory.read("daily/2026/08/2026-08-12.md"), once)
        XCTAssertEqual(MullDirectory.markdownFilesRecursively(in: VaultLayout.daily).count, 1)
    }

    // MARK: - Clearing out what the folder used to hold

    /// A `full.md` copy for a day with no summary behind it is the old scheme's
    /// leftover. After the backfill, every mull-written file in here corresponds to
    /// a row, which is what makes "no row" a sound test rather than a guess at the
    /// text.
    func testTheOldSnapshotsAreCleared() {
        MullDirectory.write(
            MarkdownDoc.header(title: "Full context", meta: [("updated", "2026-08-13T23:59+08:00")],
                               note: "Assembled from me.md and now.md. Edit those, not this."),
            to: "daily/2026/08/2026-08-13.md")

        engine.backfillDailyFiles()

        XCTAssertFalse(MullDirectory.exists("daily/2026/08/2026-08-13.md"),
                       "a context dump filed as a day's record is not a record of that day")
    }

    /// A snapshot for a day that DOES have a summary is replaced, not deleted.
    func testASnapshotIsReplacedByTheRealRecord() {
        MullDirectory.write(
            MarkdownDoc.header(title: "Full context", meta: [("updated", "x")],
                               note: "Assembled from me.md and now.md."),
            to: "daily/2026/08/2026-08-14.md")
        summary(14, "# Aug 14, 2026\n\n## Evening\nShipped it.")

        engine.backfillDailyFiles()

        let text = MullDirectory.read("daily/2026/08/2026-08-14.md") ?? ""
        XCTAssertTrue(text.contains("Shipped it."))
        XCTAssertFalse(text.contains("Assembled from"))
    }

    /// The sweep only removes mull's own writing. Somebody who kept a hand-written
    /// note in here keeps it — `daily/` is mull's folder, but 契約2 is about who
    /// wrote a file, not which folder it is in.
    func testAHandWrittenFileSurvivesTheSweep() {
        MullDirectory.write("# Friday\n\nI wrote this myself.", to: "daily/2026/08/2026-08-07.md")

        engine.backfillDailyFiles()

        XCTAssertEqual(MullDirectory.read("daily/2026/08/2026-08-07.md"),
                       "# Friday\n\nI wrote this myself.")
    }

    // MARK: - One formula for the path

    /// The writer, the forget path and the sweep have to agree, or a forget reports
    /// success while the file it meant to delete is still there.
    func testForgetLooksWhereTheRunWrites() {
        XCTAssertEqual(ForgetService.snapshotPath(for: day(9)), VaultLayout.dailyPath(for: day(9)))
        XCTAssertEqual(VaultLayout.dailyPath(for: day(9)), "daily/2026/08/2026-08-09.md")
    }
}
