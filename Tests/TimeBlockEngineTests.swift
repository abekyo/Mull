import XCTest
@testable import mull

/// Locks the "what you mainly did" inference — the product's core claim.
///
/// `TimeBlockEngine` turns a raw event stream into the sentence a human (and every
/// downstream AI surface) reads: Home's project cards, the Calendar geometry,
/// `AppState.buildContextText` and the proactive briefing all derive from these
/// blocks. A silent regression here does not crash anything; it just makes mull
/// quietly wrong about the user's day, which is the one failure the product cannot
/// survive. So these tests assert on *behaviour through the public API* —
/// segmentation, dominant-app settlement, duration accounting — not internals.
///
/// Safety: every test runs against `DatabaseService.temporary()` (a throwaway DB in
/// a unique temp dir). The user's real recorded history is never opened or touched.
///
/// Determinism: fixtures use fixed timestamps built from `DateComponents`, so the
/// results do not depend on the wall clock or the time zone. The few APIs that are
/// anchored to `Date()` by design (`projectSnapshots`, `weekSnapshots`,
/// `weekComparison`) are seeded relative to *whole day offsets* at a fixed hour, so
/// they cannot straddle a midnight boundary.
final class TimeBlockEngineTests: XCTestCase {

    private var db: DatabaseService!
    private var engine: TimeBlockEngine!

    /// A fixed day in the past. `generateBlocks` clamps its window to `min(endOfDay,
    /// Date())`, so the fixture day must be historical or events would be cut off.
    private let fixtureYear = 2026
    private let fixtureMonth = 3
    private let fixtureDay = 10   // Tuesday

    override func setUp() {
        super.setUp()
        db = try! DatabaseService.temporary()
        engine = TimeBlockEngine(database: db)
    }

    override func tearDown() {
        engine = nil
        db = nil
        super.tearDown()
    }

    // MARK: - Fixture helpers

    /// A fixed clock time on the fixture day. Built from components so the same
    /// local wall-clock time is used in every time zone.
    private func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var c = DateComponents()
        c.year = fixtureYear; c.month = fixtureMonth; c.day = fixtureDay
        c.hour = hour; c.minute = minute; c.second = second
        return Calendar.current.date(from: c)!
    }

    private var fixtureDate: Date { at(12, 0) }

    /// `n` whole days before today at a fixed hour. Used only for the APIs that are
    /// anchored to `Date()`. `n >= 1` guarantees the timestamp is in the past
    /// regardless of what time of day the suite runs.
    private func daysAgo(_ n: Int, hour: Int, minute: Int = 0) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -n, to: cal.startOfDay(for: Date()))!
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    /// Seed a dense run of events: `count` events starting at `start`, `spacing`
    /// seconds apart, all in the same app. Returns the timestamp of the last event.
    @discardableResult
    private func seedRun(
        start: Date,
        count: Int,
        spacing: TimeInterval = 60,
        app: String,
        title: String? = nil,
        type: RecordingEvent.EventType = .screenText,
        text: String? = nil
    ) -> Date {
        var last = start
        for i in 0..<count {
            last = start.addingTimeInterval(Double(i) * spacing)
            db.insertEvent(RecordingEvent(
                timestamp: last,
                eventType: type,
                appName: app,
                windowTitle: title,
                textContent: text
            ))
        }
        return last
    }

    /// Seed a run described in minutes of wall-clock span (one event per minute).
    @discardableResult
    private func seedMinutes(
        from start: Date, minutes: Int, app: String, title: String
    ) -> Date {
        seedRun(start: start, count: minutes + 1, spacing: 60, app: app, title: title)
    }

    // MARK: - Segmentation

    func testConsecutiveEventsInSameAppBecomeOneBlock() {
        // 11 events one minute apart — every gap is well under the 180s merge
        // window, so this is a single continuous session, not 11 blocks.
        seedRun(start: at(9, 0), count: 11, spacing: 60, app: "Xcode", title: "PantryApp — ChartViewModel.swift")

        let blocks = engine.generateBlocks(for: fixtureDate)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].eventCount, 11)
        XCTAssertEqual(blocks[0].start, at(9, 0))
        XCTAssertEqual(blocks[0].end, at(9, 10))
        XCTAssertEqual(blocks[0].duration, 600, accuracy: 0.5)
        XCTAssertFalse(blocks[0].isMultiApp)
    }

    func testGapLongerThanThreeMinutesSplitsBlocks() {
        // Two runs separated by 20 minutes of nothing. The engine merges gaps
        // strictly under 180s; 1200s is a genuine break.
        seedRun(start: at(9, 0), count: 3, spacing: 60, app: "Xcode", title: "PantryApp — ChartViewModel.swift")
        seedRun(start: at(9, 22), count: 3, spacing: 60, app: "Xcode", title: "PantryApp — ChartViewModel.swift")

        let blocks = engine.generateBlocks(for: fixtureDate)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].end, at(9, 2))
        XCTAssertEqual(blocks[1].start, at(9, 22))
    }

    func testMergeThresholdIsExactlyOneHundredEightySeconds() {
        // Boundary lock. `gap < 180` merges, so 179s continues the block and 180s
        // starts a new one. This constant is the difference between "one afternoon
        // on the parser" and "nine fragments" on the calendar.
        seedRun(start: at(9, 0), count: 2, spacing: 60, app: "Xcode", title: "Nocturne — IngestPipeline.swift")
        db.insertEvent(RecordingEvent(timestamp: at(9, 1).addingTimeInterval(179),
                                      eventType: .screenText, appName: "Xcode",
                                      windowTitle: "Nocturne — IngestPipeline.swift"))
        XCTAssertEqual(engine.generateBlocks(for: fixtureDate).count, 1, "179s gap must stay in the same block")

        let db2 = try! DatabaseService.temporary()
        let engine2 = TimeBlockEngine(database: db2)
        for t in [at(9, 0), at(9, 1), at(9, 1).addingTimeInterval(180)] {
            db2.insertEvent(RecordingEvent(timestamp: t, eventType: .screenText,
                                           appName: "Xcode", windowTitle: "Nocturne — IngestPipeline.swift"))
        }
        // The second block here is a lone event (0s span) and is dropped by the
        // <30s filter — the observable split is that the first block now ends at 9:01.
        let split = engine2.generateBlocks(for: fixtureDate)
        XCTAssertEqual(split.count, 1)
        XCTAssertEqual(split[0].end, at(9, 1), "180s gap must NOT be absorbed into the block")
    }

    func testAppSwitchWithinThreeMinutesContinuesTheBlockAsMultiApp() {
        // Documented behaviour (TimeBlockEngine.swift:59-66): a *different* app
        // within 3 minutes is multitasking, not a new session. The block keeps
        // running and is flagged multi-app rather than fragmenting the timeline.
        seedMinutes(from: at(9, 0), minutes: 30, app: "Xcode", title: "PantryApp — ChartViewModel.swift")
        seedMinutes(from: at(9, 31), minutes: 9, app: "Safari", title: "Swift Concurrency — Apple Developer")

        let blocks = engine.generateBlocks(for: fixtureDate)

        XCTAssertEqual(blocks.count, 1, "an app switch inside the merge window does not split the block")
        XCTAssertTrue(blocks[0].isMultiApp)
        XCTAssertEqual(blocks[0].start, at(9, 0))
        XCTAssertEqual(blocks[0].end, at(9, 40))
        // Safari dwelled ~9 minutes — well past the 30s floor — so it is reported
        // as a secondary app rather than being hidden.
        XCTAssertEqual(blocks[0].secondaryApps, ["Safari"])
    }

    func testShortBlocksAreDiscarded() {
        // A lone event has a 0s span, and a 20s two-event flicker is below the 30s
        // floor. Neither is an activity worth putting on a calendar.
        seedRun(start: at(9, 0), count: 1, spacing: 60, app: "Xcode", title: "Atlas — RouteStore.swift")
        seedRun(start: at(10, 0), count: 2, spacing: 20, app: "Code", title: "Blow — Dashboard.swift")
        // 40s is above the floor and survives.
        seedRun(start: at(11, 0), count: 2, spacing: 40, app: "Code", title: "Blow — Dashboard.swift")

        let blocks = engine.generateBlocks(for: fixtureDate)

        XCTAssertEqual(blocks.count, 1, "only the 40s block clears the <30s filter")
        XCTAssertEqual(blocks[0].start, at(11, 0))
        XCTAssertEqual(blocks[0].duration, 40, accuracy: 0.5)
    }

    func testNoiseAppsAreExcludedWhenTheNameMatchesCaseExactly() {
        // The noise list is stored lowercase and is meant to be consulted through
        // the case-insensitive `AnalyticsEngine.isNoiseApp`.
        seedMinutes(from: at(9, 0), minutes: 10, app: "system settings", title: "Displays")

        XCTAssertTrue(engine.generateBlocks(for: fixtureDate).isEmpty)
    }

    func testRealWorldNoiseAppNamesAreFiltered() {
        // Regression guard. `appName` comes from NSRunningApplication.localizedName
        // — "System Settings", "Mull" — while the noise list holds lowercase
        // entries. Every lookup used to be a case-sensitive `noiseApps.contains`,
        // so nothing in the list ever matched and mull's own window could be
        // reported as "what you mainly did". All call sites now go through
        // `AnalyticsEngine.isNoiseApp`.
        seedMinutes(from: at(9, 0), minutes: 10, app: "System Settings", title: "Displays")
        seedMinutes(from: at(11, 0), minutes: 10, app: "Mull", title: "Home")

        XCTAssertTrue(engine.generateBlocks(for: fixtureDate).isEmpty,
                      "noise apps must not become time blocks, whatever their casing")
    }

    func testNoiseFilterIsCaseInsensitiveBothWays() {
        // The lowercase spelling was the only one that ever matched; assert both
        // so a future "optimization" back to a raw Set lookup fails here.
        seedMinutes(from: at(9, 0), minutes: 10, app: "system settings", title: "Displays")
        XCTAssertTrue(engine.generateBlocks(for: fixtureDate).isEmpty)
    }

    // MARK: - Dominant app ("what you mainly did")

    func testDominantAppWinsOverTheAppThatOpenedTheBlock() {
        // The single most load-bearing behaviour in the file. A stray Safari lookup
        // opens the session, then 40 minutes of Xcode follow. The block's face must
        // be Xcode — before `finalizeDominantApp` existed the *first* app silently
        // won, which is exactly how a day of coding gets labelled "Safari".
        seedRun(start: at(9, 0), count: 1, spacing: 60, app: "Safari",
                title: "Swift Concurrency — Apple Developer")
        seedMinutes(from: at(9, 1), minutes: 40, app: "Xcode",
                    title: "PantryApp — ChartViewModel.swift")

        let blocks = engine.generateBlocks(for: fixtureDate)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].app, "Xcode", "the dominant app, not the opening app, is the block's face")
        XCTAssertTrue(blocks[0].isMultiApp)
    }

    func testLabelFollowsTheDominantAppsWindowTitle() {
        // The caption must belong to the app that won. A Safari page name must never
        // caption a block whose face is Xcode.
        seedRun(start: at(9, 0), count: 2, spacing: 60, app: "Safari",
                title: "Swift Concurrency — Apple Developer")
        seedMinutes(from: at(9, 2), minutes: 40, app: "Xcode",
                    title: "PantryApp — ChartViewModel.swift — Xcode")

        let blocks = engine.generateBlocks(for: fixtureDate)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].app, "Xcode")
        // "Project — File — Xcode": the app-name part is stripped, and both a
        // project and a file are recognised, so the label is "Project — File".
        XCTAssertEqual(blocks[0].label, "PantryApp — ChartViewModel.swift")
    }

    func testBlockWithoutWindowTitlesFallsBackToTheAppName() {
        // Keystroke events carry no title, so there is nothing to caption with.
        // The label degrades to the app name rather than producing an empty row.
        seedRun(start: at(9, 0), count: 11, spacing: 60, app: "Terminal",
                type: .keystroke, text: "swift build --configuration release")

        let blocks = engine.generateBlocks(for: fixtureDate)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].label, "Terminal")
    }

    func testClipboardCaptionsABlockWhenNoTitleIsAvailable() {
        // Priority order is title > clipboard > app name.
        seedRun(start: at(9, 0), count: 5, spacing: 60, app: "Terminal",
                type: .keystroke, text: "git rebase --onto main")
        db.insertEvent(RecordingEvent(timestamp: at(9, 2), eventType: .clipboard,
                                      appName: "Terminal",
                                      textContent: "Refactored the ChartViewModel bindings"))

        let blocks = engine.generateBlocks(for: fixtureDate)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].label, "Refactored the ChartViewModel bindings")
    }

    // MARK: - Duration accounting

    func testActiveDurationCapsLongGapsWhileDurationStaysWallClock() {
        // `duration` is calendar geometry (raw end − start). `activeDuration` is
        // engaged time: each inter-event gap is capped at `activeGapCap` (90s) so a
        // pause inside a block cannot be counted as deep work.
        // Gaps: 60s, 150s, 60s → engaged 60 + 90 + 60 = 210s; wall clock 270s.
        for t in [at(9, 0), at(9, 1), at(9, 3, 30), at(9, 4, 30)] {
            db.insertEvent(RecordingEvent(timestamp: t, eventType: .screenText,
                                          appName: "Xcode",
                                          windowTitle: "Nocturne — IngestPipeline.swift"))
        }

        let blocks = engine.generateBlocks(for: fixtureDate)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].duration, 270, accuracy: 0.5)
        XCTAssertEqual(blocks[0].activeDuration, 210, accuracy: 0.5,
                       "the 150s gap contributes only the 90s cap")
        XCTAssertEqual(TimeBlockEngine.activeGapCap, 90)
        XCTAssertLessThanOrEqual(blocks[0].activeDuration, blocks[0].duration)
    }

    func testEventCountsAndDurationsAddUpAcrossBlocks() {
        // Accounting sanity: nothing is invented, nothing is lost.
        seedMinutes(from: at(9, 0), minutes: 20, app: "Xcode", title: "PantryApp — ChartViewModel.swift")
        seedMinutes(from: at(11, 0), minutes: 10, app: "Code", title: "Blow — Dashboard.swift")

        let blocks = engine.generateBlocks(for: fixtureDate)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.eventCount }, 21 + 11)
        // Every gap is 60s (under the 90s cap), so engaged time equals wall clock here.
        XCTAssertEqual(blocks[0].activeDuration, 1200, accuracy: 0.5)
        XCTAssertEqual(blocks[1].activeDuration, 600, accuracy: 0.5)
    }

    // MARK: - analyzDay

    /// Five distinct projects with strictly descending engaged time, laid out one
    /// per hour so each becomes its own block. Shared by the analyzDay/asText tests.
    private func seedFiveProjectDay() {
        seedMinutes(from: at(9, 0), minutes: 20, app: "Xcode", title: "PantryApp — ChartViewModel.swift")
        seedMinutes(from: at(10, 0), minutes: 16, app: "Code", title: "Blow — Dashboard.swift")
        seedMinutes(from: at(11, 0), minutes: 12, app: "Xcode", title: "Nocturne — IngestPipeline.swift")
        seedMinutes(from: at(12, 0), minutes: 8, app: "Code", title: "Ledger — ReportBuilder.swift")
        seedMinutes(from: at(13, 0), minutes: 4, app: "Xcode", title: "Atlas — RouteStore.swift")
    }

    func testAnalyzDaySplitsMainFromOtherAndOrdersByDuration() {
        seedFiveProjectDay()

        let day = engine.analyzDay(for: fixtureDate)

        // Top 3 by engaged time are "what you mainly did"; the rest are "also".
        XCTAssertEqual(day.mainActivities.count, 3)
        XCTAssertEqual(day.otherActivities.count, 2)
        XCTAssertEqual(day.mainActivities.map(\.label), [
            "PantryApp — ChartViewModel.swift",
            "Blow — Dashboard.swift",
            "Nocturne — IngestPipeline.swift",
        ])
        XCTAssertEqual(day.otherActivities.map(\.label), [
            "Ledger — ReportBuilder.swift",
            "Atlas — RouteStore.swift",
        ])
        // Strictly descending — the ordering is what makes "mainly" meaningful.
        let durations = (day.mainActivities + day.otherActivities).map(\.totalDuration)
        XCTAssertEqual(durations, durations.sorted(by: >))
        XCTAssertEqual(day.mainActivities[0].totalDuration, 1200, accuracy: 0.5)
        XCTAssertEqual(day.mainActivities[0].app, "Xcode")
        XCTAssertEqual(day.totalDuration, 1200 + 960 + 720 + 480 + 240, accuracy: 1)
    }

    func testAnalyzDayAppBreakdownPercentagesSumToOneHundred() {
        seedFiveProjectDay()

        let day = engine.analyzDay(for: fixtureDate)

        XCTAssertEqual(day.appBreakdown.map(\.app), ["Xcode", "Code"], "sorted by engaged time, descending")
        // Xcode: 1200+720+240 = 2160 of 3600 → 60%. Code: 960+480 = 1440 → 40%.
        XCTAssertEqual(day.appBreakdown[0].percentage, 60, accuracy: 0.5)
        XCTAssertEqual(day.appBreakdown[1].percentage, 40, accuracy: 0.5)
        XCTAssertEqual(day.appBreakdown.reduce(0) { $0 + $1.percentage }, 100, accuracy: 0.5)
        XCTAssertEqual(day.appBreakdown.reduce(0) { $0 + $1.duration }, day.totalDuration, accuracy: 1)
    }

    func testAnalyzDayGroupsTheSameProjectAcrossAppsAndSessions() {
        // "Same project across Xcode + Code + Terminal = same task" — the grouping
        // key is the parsed project name, so a project worked on in two sittings in
        // two editors is one activity, not three.
        seedMinutes(from: at(9, 0), minutes: 10, app: "Xcode", title: "PantryApp — ChartViewModel.swift")
        seedMinutes(from: at(11, 0), minutes: 10, app: "Code", title: "PantryApp — HealthStore.swift")

        let day = engine.analyzDay(for: fixtureDate)

        XCTAssertEqual(day.mainActivities.count, 1)
        XCTAssertEqual(day.mainActivities[0].blocks.count, 2)
        XCTAssertEqual(day.mainActivities[0].eventCount, 22)
        XCTAssertEqual(day.mainActivities[0].totalDuration, 1200, accuracy: 1)
    }

    func testEmptyDayProducesNeutralResultsWithoutCrashing() {
        // No events at all — the shape downstream code must tolerate.
        let blocks = engine.generateBlocks(for: fixtureDate)
        XCTAssertTrue(blocks.isEmpty)

        let day = engine.analyzDay(for: fixtureDate)
        XCTAssertTrue(day.mainActivities.isEmpty)
        XCTAssertTrue(day.otherActivities.isEmpty)
        XCTAssertTrue(day.appBreakdown.isEmpty)
        XCTAssertEqual(day.totalDuration, 0)
    }

    // MARK: - DailyActivity.asText()

    func testAsTextProducesTheExpectedStructure() {
        seedFiveProjectDay()

        let text = engine.analyzDay(for: fixtureDate).asText()

        XCTAssertEqual(text, """
        What you mainly did today:
        - PantryApp — ChartViewModel.swift (20m, Xcode)
        - Blow — Dashboard.swift (16m, Code)
        - Nocturne — IngestPipeline.swift (12m, Xcode)

        Also:
        - Ledger — ReportBuilder.swift (8m, Code)
        - Atlas — RouteStore.swift (4m, Xcode)

        App usage:
        - Xcode: 60%
        - Code: 40%
        """)
    }

    func testAsTextOnAnEmptyDayIsStillWellFormed() {
        // This string is fed to the LLM and to context files; on a blank day it must
        // degrade to headers, not to garbage or a crash.
        let text = engine.analyzDay(for: fixtureDate).asText()
        XCTAssertEqual(text, "What you mainly did today:\n\nApp usage:")
    }

    func testAsTextIsBoundedBecauseAnalyzDayCapsTheOtherBucket() {
        // The audit flagged `asText()` as looping over ALL otherActivities unbounded.
        // It does — the loop has no prefix — but every DailyActivity built by
        // `analyzDay` is pre-capped (main: prefix(3), other: prefix(5), apps:
        // prefix(6) at print time). So through the public API the prompt cannot
        // grow past 3 + 5 + 6 lines no matter how fragmented the day is.
        for hour in 8..<20 {
            seedMinutes(from: at(hour, 0), minutes: 10, app: "Xcode",
                        title: "Project\(hour) — File\(hour).swift")
        }

        let day = engine.analyzDay(for: fixtureDate)
        XCTAssertEqual(day.mainActivities.count, 3)
        XCTAssertEqual(day.otherActivities.count, 5, "the 'other' bucket is capped at 5, not unbounded")

        let lines = day.asText().split(separator: "\n", omittingEmptySubsequences: false)
        let bullets = lines.filter { $0.hasPrefix("- ") }
        XCTAssertLessThanOrEqual(bullets.count, 3 + 5 + 6)
    }

    // MARK: - projectSnapshots

    func testProjectSnapshotsWindowBoundsResults() {
        seedMinutes(from: daysAgo(3, hour: 9), minutes: 10, app: "Xcode", title: "Halyard — RouteStore.swift")
        seedMinutes(from: daysAgo(20, hour: 9), minutes: 10, app: "Code", title: "Driftwood — LegacyView.swift")

        let recent = engine.projectSnapshots(days: 7).map(\.name)
        XCTAssertEqual(recent, ["Halyard"], "a 7-day window must not reach 20 days back")

        let wide = engine.projectSnapshots(days: 30).map(\.name)
        XCTAssertEqual(Set(wide), ["Halyard", "Driftwood"])
        // Sorted most-recently-active first — Home shows the live thread on top.
        XCTAssertEqual(wide.first, "Halyard")
    }

    func testProjectSnapshotCarriesLastActiveDateAndResumePoint() throws {
        let start = daysAgo(3, hour: 9)
        seedMinutes(from: start, minutes: 10, app: "Xcode", title: "Halyard — RouteStore.swift")
        db.insertEvent(RecordingEvent(timestamp: start.addingTimeInterval(300),
                                      eventType: .clipboard, appName: "Xcode",
                                      textContent: "let store = RouteStore(context: modelContext)"))

        let snapshot = try XCTUnwrap(engine.projectSnapshots(days: 7).first)
        // The resume point is exactly what was seeded: the file you were in and the
        // last thing you copied.
        XCTAssertEqual(snapshot.lastFile, "RouteStore.swift")
        XCTAssertEqual(snapshot.lastClipboard, "let store = RouteStore(context: modelContext)")
        XCTAssertEqual(snapshot.primaryApp, "Xcode")
        XCTAssertEqual(snapshot.lastActiveDate.timeIntervalSince(start), 600, accuracy: 1,
                       "last active = the end of the last block, i.e. the final seeded event")
        XCTAssertEqual(snapshot.totalDuration, 600, accuracy: 1)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.sessions.first).duration, 600, accuracy: 1)
    }

    func testProjectSnapshotsRequireAtLeastThreeEvents() {
        // Two events 40s apart form a valid (>=30s) block but only 2 events, which
        // is below the `data.events >= 3` bar — a two-event blip is not a project.
        seedRun(start: daysAgo(2, hour: 9), count: 2, spacing: 40, app: "Xcode",
                title: "Sparrow — Tiny.swift")

        XCTAssertTrue(engine.projectSnapshots(days: 7).isEmpty)
    }

    func testDaysSinceActiveIsElapsed24HourPeriodsNotCalendarDays() {
        // Characterization of a real defect (TimeBlockEngine.swift:729): daysSince
        // is `dateComponents([.day], from: lastDate, to: now)`, an elapsed-time
        // measure, not a calendar-day difference. Work done 5 calendar days ago at
        // 09:00 reports 4 when the suite runs before 09:00 and 5 after — and
        // `lastActiveFormatted` renders that as "4 days ago" vs "5 days ago".
        // The test asserts the tolerated band precisely because the value is not
        // stable; it must not be tightened until the source uses calendar days.
        seedMinutes(from: daysAgo(5, hour: 9), minutes: 10, app: "Xcode", title: "Halyard — RouteStore.swift")

        let snapshot = engine.projectSnapshots(days: 10).first
        XCTAssertNotNil(snapshot)
        let days = snapshot!.daysSinceActive
        XCTAssertTrue(days == 4 || days == 5, "expected 4 or 5, got \(days)")
    }

    // MARK: - weekSnapshots

    func testWeekSnapshotsCoverMondayThroughSunday() {
        let cal = Calendar.current
        let week = engine.weekSnapshots()

        XCTAssertEqual(week.count, 7)
        // Starts on a Monday (weekday 2 in the Gregorian calendar).
        XCTAssertEqual(cal.component(.weekday, from: week[0].date), 2)
        // Consecutive days, no gaps.
        for i in 1..<week.count {
            let delta = cal.dateComponents([.day], from: week[i - 1].date, to: week[i].date).day
            XCTAssertEqual(delta, 1)
        }
        // Exactly one day is today, and today is always inside the current week.
        XCTAssertEqual(week.filter(\.isToday).count, 1)
    }

    func testWeekSnapshotsZeroOutFutureDays() {
        // Days later in the week have not happened yet; they must read as empty
        // rather than being analysed (and must not crash on the empty range).
        let week = engine.weekSnapshots()
        guard let todayIndex = week.firstIndex(where: { $0.isToday }) else {
            return XCTFail("today must appear in the current week")
        }
        for day in week[(todayIndex + 1)...] {
            XCTAssertEqual(day.totalDuration, 0)
            XCTAssertNil(day.mainProject)
            XCTAssertEqual(day.eventCount, 0)
            XCTAssertFalse(day.isToday)
        }
    }

    // MARK: - weekComparison

    /// Monday of the current week, using the same arithmetic as the engine.
    private var thisMonday: Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let daysFromMonday = (cal.component(.weekday, from: today) + 5) % 7
        return cal.date(byAdding: .day, value: -daysFromMonday, to: today)!
    }

    func testWeekComparisonComparesTheRightTwoWindows() {
        let cal = Calendar.current
        let lastMonday = cal.date(byAdding: .day, value: -7, to: thisMonday)!
        let priorMonday = cal.date(byAdding: .day, value: -14, to: thisMonday)!

        // Seed last week (always >= 7 days ago, so always in the past) and the week
        // before it. Nothing at all in the current week.
        seedMinutes(from: cal.date(bySettingHour: 10, minute: 0, second: 0, of: lastMonday)!,
                    minutes: 30, app: "Xcode", title: "PantryApp — ChartViewModel.swift")
        seedMinutes(from: cal.date(bySettingHour: 10, minute: 0, second: 0, of: priorMonday)!,
                    minutes: 30, app: "Xcode", title: "PantryApp — ChartViewModel.swift")

        let comparison = engine.weekComparison()

        XCTAssertEqual(comparison.thisWeekDuration, 0, "nothing was seeded this week")
        XCTAssertEqual(comparison.lastWeekDuration, 1800, accuracy: 2)
        // The week *before* last must not leak into either window — this is the
        // assertion that proves the two windows are the right two.
        XCTAssertEqual(comparison.lastWeekFullDuration, 1800, accuracy: 2)
        XCTAssertEqual(comparison.durationDelta, -1800, accuracy: 2)
        XCTAssertEqual(comparison.durationDeltaPercent, -100, accuracy: 1)
        XCTAssertEqual(comparison.deltaFormatted, "-30m")
    }

    func testWeekComparisonCountsDeepBlocksAndContextSwitches() {
        let cal = Calendar.current
        let lastMonday = cal.date(byAdding: .day, value: -7, to: thisMonday)!
        let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: lastMonday)!

        // 2.5 hours of continuous work (events 150s apart, inside the 180s merge
        // window) → one block of 9000s, past the 7200s "deep work" bar.
        seedRun(start: start, count: 61, spacing: 150, app: "Xcode",
                title: "PantryApp — ChartViewModel.swift")
        // Four app switches on the same day feed the context-switch counter.
        for i in 0..<4 {
            db.insertEvent(RecordingEvent(timestamp: start.addingTimeInterval(Double(i) * 300 + 10),
                                          eventType: .appSwitch, appName: "Slack",
                                          windowTitle: "mull — general"))
        }

        let comparison = engine.weekComparison()

        XCTAssertEqual(comparison.lastWeekDeepBlocks, 1)
        XCTAssertEqual(comparison.thisWeekDeepBlocks, 0)
        XCTAssertEqual(comparison.lastWeekContextSwitches, 4)
        XCTAssertEqual(comparison.thisWeekContextSwitches, 0)
    }
}
