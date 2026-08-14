import XCTest
@testable import mull

/// The gates that decide whether the day gets written.
///
/// These exist because the written record stopped for three days on the author's
/// own machine and nothing in the product could say why (CLAUDE.md §0 場面 E). Two
/// separate faults, both invisible from outside, because a gate returning false is
/// what a gate is for:
///
/// - the day-gap gate measured 24 hours from when the last run *finished*, and the
///   only caller fires at a fixed time of day — so the interval was always just
///   under 24 hours and every other day was refused;
/// - a day mull was not running at the scheduled hour had no second chance at all.
///
/// Every test here is written against a clock passed in, not `Date()`, because both
/// faults are about which side of a boundary a moment falls on.
final class ConsolidationSchedulerTests: XCTestCase {

    private var db: DatabaseService!
    private var scheduler: ConsolidationScheduler!

    override func setUp() {
        super.setUp()
        db = try! DatabaseService.temporary()
        scheduler = ConsolidationScheduler(database: db)
    }

    // MARK: - Helpers

    /// A local wall-clock moment, so "23:00 on the 11th" means that in the same
    /// calendar the gate uses.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = day
        c.hour = hour; c.minute = minute; c.second = second
        return Calendar.current.date(from: c)!
    }

    /// Enough events to clear gate 2, spread across the window ending at `now`.
    private func giveItSomethingToSummarize(endingAt now: Date) {
        for i in 0..<(ConsolidationScheduler.minEventsRequired + 10) {
            db.insertEvent(RecordingEvent(
                timestamp: now.addingTimeInterval(-Double(i) * 60),
                eventType: .screenText,
                appName: "Code",
                windowTitle: "something \(i)"
            ))
        }
    }

    /// A summary already on the record for the day `runTime` would have covered.
    private func recordSummary(forRunAt runTime: Date, took seconds: Double) {
        db.insertSummary(DailySummary(
            date: ConsolidationScheduler.summaryDate(forRunAt: runTime),
            content: "# a day\n\nSomething happened.",
            eventCount: 900,
            processingSeconds: seconds,
            llmProvider: "rule-based",
            createdAt: runTime.addingTimeInterval(seconds)
        ))
    }

    // MARK: - The every-other-day fault

    /// The regression. A run at 23:00 that took 67.8 seconds finished at 23:01:07,
    /// and the next day's fire at 23:00:00 was 23h58m53s later — under 24, so the
    /// old gate refused it. That is exactly what happened on 2026-08-10 here.
    func testTheDayAfterASuccessfulRunIsNotRefused() {
        recordSummary(forRunAt: at(9, 23, 0), took: 67.8)
        giveItSomethingToSummarize(endingAt: at(10, 23, 0))

        XCTAssertTrue(scheduler.shouldRun(triggeredBy: .schedule, now: at(10, 23, 0)),
                      "a run one day after the last one covers a different day and must be allowed")
    }

    /// The same fault at its narrowest: a run that took a fraction of a second still
    /// finished after the scheduled instant, so under the old rule EVERY day was
    /// refused, forever, once one run had succeeded.
    func testASubSecondRunDoesNotBlockTomorrow() {
        recordSummary(forRunAt: at(14, 23, 0), took: 0.65)
        giveItSomethingToSummarize(endingAt: at(15, 23, 0))

        XCTAssertTrue(scheduler.shouldRun(triggeredBy: .schedule, now: at(15, 23, 0)))
    }

    /// What the gate was actually protecting, which still holds: one day, one
    /// summary. A second fire on the same evening finds the day written.
    func testTheSameDayIsNotWrittenTwice() {
        recordSummary(forRunAt: at(11, 23, 0), took: 62.8)
        giveItSomethingToSummarize(endingAt: at(11, 23, 30))

        XCTAssertFalse(scheduler.shouldRun(triggeredBy: .schedule, now: at(11, 23, 30)))
    }

    /// An empty record has nothing to refuse against.
    func testAFreshInstallIsAllowedToRun() {
        giveItSomethingToSummarize(endingAt: at(11, 23, 0))
        XCTAssertTrue(scheduler.shouldRun(triggeredBy: .schedule, now: at(11, 23, 0)))
    }

    // MARK: - The missed-day fault

    /// 2026-08-12: the last thing written that day was 13:43, so nothing was running
    /// at 23:00. Opening mull the next morning should find the day and write it.
    func testALaunchWritesAFinishedDayNobodyWasThereFor() {
        recordSummary(forRunAt: at(11, 23, 0), took: 62.8)
        giveItSomethingToSummarize(endingAt: at(13, 9, 0))

        XCTAssertTrue(scheduler.shouldRun(triggeredBy: .launch, now: at(13, 9, 0)),
                      "09:00 gathers back to 09:00 yesterday — midpoint 21:00 on the 12th, a day that is over and unwritten")
    }

    /// A launch may not take today's slot. `insertSummary` replaces by date, so a
    /// half-day summary written at lunchtime would hold the day against the 23:00
    /// run that was going to describe all of it.
    func testALaunchWillNotWriteADayStillInProgress() {
        recordSummary(forRunAt: at(12, 23, 0), took: 60)
        giveItSomethingToSummarize(endingAt: at(13, 20, 0))

        // 20:00 gathers back to 20:00 yesterday; the midpoint is 08:00 today.
        XCTAssertFalse(scheduler.shouldRun(triggeredBy: .launch, now: at(13, 20, 0)))
        // The scheduled run at 23:00 is the one entitled to write it.
        XCTAssertTrue(scheduler.shouldRun(triggeredBy: .schedule, now: at(13, 23, 0)))
    }

    /// Launching four times in an evening must not produce four summaries.
    func testRepeatedLaunchesAreIdempotent() {
        recordSummary(forRunAt: at(12, 9, 0), took: 1)   // yesterday, already filled
        giveItSomethingToSummarize(endingAt: at(12, 10, 0))

        XCTAssertFalse(scheduler.shouldRun(triggeredBy: .launch, now: at(12, 10, 0)))
        XCTAssertFalse(scheduler.shouldRun(triggeredBy: .launch, now: at(12, 11, 0)))
    }

    // MARK: - Gate 2 still holds

    func testAQuietDayIsNotSummarized() {
        db.insertEvent(RecordingEvent(timestamp: at(11, 22, 0), eventType: .screenText,
                                      appName: "Code", windowTitle: "one thing"))
        XCTAssertFalse(scheduler.shouldRun(triggeredBy: .schedule, now: at(11, 23, 0)),
                       "one event is not a day")
    }

    // MARK: - The prediction matches the record

    /// `summaryDate(forRunAt:)` runs before anything is gathered; the row is stamped
    /// from the window that actually was. If these two ever disagree, the gate
    /// checks one day and the pipeline writes another, and the fault looks exactly
    /// like the one this file exists to stop.
    func testThePredictedDayMatchesTheDayTheRunStamps() {
        for hour in 0..<24 {
            let now = at(11, hour, 30)
            let windowStart = Calendar.current.date(
                byAdding: .hour, value: -ConsolidationScheduler.gatherWindowHours, to: now)!
            let gathered = GatheredData(
                events: [], morning: [], afternoon: [], evening: [], appGroups: [:],
                windowStart: windowStart, windowEnd: now)

            XCTAssertEqual(ConsolidationScheduler.summaryDate(forRunAt: now), gathered.summaryDate,
                           "prediction and record disagree for a run at \(hour):30")
        }
    }
}
