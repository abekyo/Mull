import XCTest
@testable import mull

/// The calendar's arithmetic, which had no tests at all while it was buried in a
/// SwiftUI view. Every case here is a thing that was got wrong once, or that would
/// only ever be noticed by looking very carefully at the screen.
final class CalendarGridTests: XCTestCase {

    private let hour: CGFloat = 60          // one hour = 60pt, so 1pt = 1 minute
    private let minSpan: CGFloat = 18
    private let gap: CGFloat = 1

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        cal.firstWeekday = 2   // Monday, so a Sunday-first default can't pass by accident
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ h: Int = 0, _ m: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: h, minute: m))!
    }

    private func layout(_ intervals: [(Date, Date)], on day: Date) -> [CalendarGrid.Span] {
        CalendarGrid.layout(intervals.map { CalendarGrid.Interval(start: $0.0, end: $0.1) },
                            day: day, hourHeight: hour, minHeight: minSpan, gap: gap,
                            calendar: calendar)
    }

    // MARK: - Placing a span

    func testSpanSitsAtItsOwnTimeAndDuration() {
        let day = date(2026, 8, 10)
        let spans = layout([(date(2026, 8, 10, 9, 30), date(2026, 8, 10, 11, 0))], on: day)

        XCTAssertEqual(spans[0].y, 9.5 * hour, accuracy: 0.01)
        XCTAssertEqual(spans[0].trueHeight, 1.5 * hour, accuracy: 0.01)
        XCTAssertFalse(spans[0].isPadded)
    }

    func testShortSpanIsPaddedButKeepsItsTrueHeight() {
        let day = date(2026, 8, 10)
        // Four minutes: 4pt tall by its own minutes, which is unreadable.
        let spans = layout([(date(2026, 8, 10, 9, 0), date(2026, 8, 10, 9, 4))], on: day)

        XCTAssertEqual(spans[0].height, minSpan, accuracy: 0.01)
        XCTAssertEqual(spans[0].trueHeight, 4, accuracy: 0.01)
        XCTAssertTrue(spans[0].isPadded, "the view draws the padded part as a ghost, "
                      + "which it can only do if the geometry admits it was padded")
    }

    /// Padding must never make two consecutive spans appear to overlap — the case
    /// that turns "two five-minute things back to back" into a lie.
    func testPaddingStopsShortOfTheNextSpan() {
        let day = date(2026, 8, 10)
        let spans = layout([
            (date(2026, 8, 10, 9, 0), date(2026, 8, 10, 9, 4)),
            (date(2026, 8, 10, 9, 10), date(2026, 8, 10, 9, 14)),
        ], on: day)

        XCTAssertLessThanOrEqual(spans[0].y + spans[0].height, spans[1].y,
                                 "a padded span grew over the one after it")
    }

    // MARK: - Midnight

    func testSpanRunningPastMidnightIsClampedAndMarked() {
        let day = date(2026, 8, 10)
        let spans = layout([(date(2026, 8, 10, 23, 40), date(2026, 8, 11, 0, 50))], on: day)

        XCTAssertEqual(spans[0].y, 23 * hour + 40, accuracy: 0.01)
        XCTAssertEqual(spans[0].y + spans[0].trueHeight, 24 * hour, accuracy: 0.01,
                       "the span must stop at the bottom of the day it is drawn on")
        XCTAssertTrue(spans[0].continuesAfter)
        XCTAssertFalse(spans[0].continuesBefore)
    }

    func testSpanArrivingFromYesterdayStartsAtMidnight() {
        let day = date(2026, 8, 11)
        let spans = layout([(date(2026, 8, 10, 23, 40), date(2026, 8, 11, 0, 50))], on: day)

        XCTAssertEqual(spans[0].y, 0, accuracy: 0.01)
        XCTAssertEqual(spans[0].trueHeight, 50, accuracy: 0.01)
        XCTAssertTrue(spans[0].continuesBefore)
        XCTAssertFalse(spans[0].continuesAfter)
    }

    func testSpanCoveringTheWholeDayIsMarkedAtBothEnds() {
        let day = date(2026, 8, 11)
        let spans = layout([(date(2026, 8, 10, 9, 0), date(2026, 8, 12, 9, 0))], on: day)

        XCTAssertTrue(spans[0].continuesBefore)
        XCTAssertTrue(spans[0].continuesAfter)
        XCTAssertEqual(spans[0].trueHeight, 24 * hour, accuracy: 0.01)
    }

    // MARK: - Overlapping

    func testOverlappingSpansTakeSeparateColumns() {
        let day = date(2026, 8, 10)
        let spans = layout([
            (date(2026, 8, 10, 9, 0), date(2026, 8, 10, 10, 0)),
            (date(2026, 8, 10, 9, 30), date(2026, 8, 10, 10, 30)),
        ], on: day)

        XCTAssertEqual(Set(spans.map(\.column)), [0, 1],
                       "two overlapping meetings must not be stacked at the same x")
        XCTAssertEqual(spans.map(\.columns), [2, 2],
                       "both are cut to the same width, so the column doesn't change "
                       + "width halfway down the hour")
    }

    func testSpansThatMerelyTouchDoNotShareTheWidth() {
        let day = date(2026, 8, 10)
        let spans = layout([
            (date(2026, 8, 10, 9, 0), date(2026, 8, 10, 10, 0)),
            (date(2026, 8, 10, 10, 0), date(2026, 8, 10, 11, 0)),
        ], on: day)

        XCTAssertEqual(spans.map(\.columns), [1, 1])
    }

    func testSeparateOverlapClustersDoNotAffectEachOther() {
        let day = date(2026, 8, 10)
        let spans = layout([
            (date(2026, 8, 10, 9, 0), date(2026, 8, 10, 10, 0)),
            (date(2026, 8, 10, 9, 30), date(2026, 8, 10, 10, 30)),
            (date(2026, 8, 10, 15, 0), date(2026, 8, 10, 16, 0)),   // alone in the afternoon
        ], on: day)

        XCTAssertEqual(spans[2].columns, 1, "an unrelated afternoon event was narrowed "
                       + "by a clash in the morning")
        XCTAssertEqual(spans[2].column, 0)
    }

    func testGeometryIsReturnedInInputOrder() {
        let day = date(2026, 8, 10)
        // Deliberately out of chronological order: the view indexes the result
        // against its own array, so clustering must not reorder anything.
        let spans = layout([
            (date(2026, 8, 10, 15, 0), date(2026, 8, 10, 16, 0)),
            (date(2026, 8, 10, 9, 0), date(2026, 8, 10, 10, 0)),
        ], on: day)

        XCTAssertEqual(spans[0].y, 15 * hour, accuracy: 0.01)
        XCTAssertEqual(spans[1].y, 9 * hour, accuracy: 0.01)
    }

    // MARK: - Slices

    func testColumnsDivideTheLaneEvenly() {
        var span = CalendarGrid.Span(y: 0, height: 10, trueHeight: 10)
        span.columns = 2
        span.column = 1
        let slice = CalendarGrid.slice(span, laneX: 2, laneWidth: 100)

        XCTAssertEqual(slice.width, 50, accuracy: 0.01)
        XCTAssertEqual(slice.x, 52, accuracy: 0.01)
    }

    // MARK: - The time axis

    func testPointDownTheColumnBecomesATime() {
        let day = date(2026, 8, 10)
        let moment = CalendarGrid.time(on: day, atY: 9.5 * hour, hourHeight: hour,
                                       calendar: calendar)
        XCTAssertEqual(moment, date(2026, 8, 10, 9, 30))
    }

    func testTimeAtPointIsClampedToTheDay() {
        let day = date(2026, 8, 10)
        XCTAssertEqual(CalendarGrid.time(on: day, atY: -500, hourHeight: hour, calendar: calendar),
                       date(2026, 8, 10, 0, 0))
        XCTAssertEqual(CalendarGrid.time(on: day, atY: 9_999, hourHeight: hour, calendar: calendar),
                       date(2026, 8, 11, 0, 0))
    }

    func testYOffsetAndTimeAreInverses() {
        let day = date(2026, 8, 10)
        let moment = date(2026, 8, 10, 14, 45)
        let y = CalendarGrid.yOffset(for: moment, hourHeight: hour, calendar: calendar)
        XCTAssertEqual(CalendarGrid.time(on: day, atY: y, hourHeight: hour, calendar: calendar),
                       moment)
    }

    // MARK: - The two days a year that are not 24 hours long
    //
    // `yOffset` used to read hour-and-minute off the wall clock while
    // `time(on:atY:)` measured elapsed seconds from midnight and `layout` sized
    // every card from `timeIntervalSince`. Those agree on 363 days and disagree by a
    // whole hour on the other two, which is why nothing here can be written in
    // Asia/Tokyo — it has no clock change, so every one of these passes by default.

    private var newYork: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.firstWeekday = 2
        return cal
    }

    /// 2026-03-08 loses an hour at 02:00; 2026-11-01 repeats one at 01:00.
    private func nyDate(_ year: Int, _ month: Int, _ day: Int,
                        _ h: Int = 0, _ m: Int = 0) -> Date {
        newYork.date(from: DateComponents(year: year, month: month, day: day,
                                          hour: h, minute: m))!
    }

    func testColumnIsAsTallAsTheDayReallyIs() {
        let cal = newYork
        XCTAssertEqual(CalendarGrid.dayHeight(nyDate(2026, 3, 8), hourHeight: hour, calendar: cal),
                       23 * hour, accuracy: 0.01, "the day the clocks go forward")
        XCTAssertEqual(CalendarGrid.dayHeight(nyDate(2026, 11, 1), hourHeight: hour, calendar: cal),
                       25 * hour, accuracy: 0.01, "the day they go back")
        XCTAssertEqual(CalendarGrid.dayHeight(nyDate(2026, 6, 15), hourHeight: hour, calendar: cal),
                       24 * hour, accuracy: 0.01, "an ordinary day")
    }

    /// Double-clicking a row and the card that appears there must mean the same
    /// moment. They did not: the click resolved through elapsed seconds and the card
    /// was placed by wall-clock components, so on a clock-change day the draft landed
    /// a full row away from the pointer.
    func testAPointAndTheTimeItStandsForRoundTripOnClockChangeDays() {
        let cal = newYork
        for (day, rows) in [(nyDate(2026, 3, 8), 23.0), (nyDate(2026, 11, 1), 25.0)] {
            for row in stride(from: 0.0, to: rows, by: 0.25) {
                let y = CGFloat(row) * hour
                let moment = CalendarGrid.time(on: day, atY: y, hourHeight: hour, calendar: cal)
                XCTAssertEqual(CalendarGrid.yOffset(for: moment, hourHeight: hour, calendar: cal),
                               y, accuracy: 0.01, "row \(row) of \(day)")
            }
        }
    }

    /// On the day the clocks go back, 01:00–04:00 is four real hours and the 04:00
    /// after it starts exactly where it ends. Component arithmetic drew the first
    /// across rows 1–4 and put the second at row 4, so `layout` read them as
    /// simultaneous and split the day into two columns.
    func testTheRepeatedHourDoesNotInventAnOverlap() {
        let cal = newYork
        let day = nyDate(2026, 11, 1)
        let spans = CalendarGrid.layout(
            [CalendarGrid.Interval(start: nyDate(2026, 11, 1, 1), end: nyDate(2026, 11, 1, 4)),
             CalendarGrid.Interval(start: nyDate(2026, 11, 1, 4), end: nyDate(2026, 11, 1, 5))],
            day: day, hourHeight: hour, minHeight: minSpan, gap: gap, calendar: cal)

        XCTAssertEqual(spans[0].trueHeight, 4 * hour, accuracy: 0.01,
                       "01:00 → 04:00 across the repeated hour is four hours, not three")
        XCTAssertEqual(spans[1].y, spans[0].y + spans[0].trueHeight, accuracy: 0.01,
                       "the next event begins exactly where the last one ends")
        XCTAssertEqual(spans[0].columns, 1)
        XCTAssertEqual(spans[1].columns, 1)
    }

    func testSnappingGoesToTheQuarterHour() {
        XCTAssertEqual(CalendarGrid.snapped(date(2026, 8, 10, 9, 58)),
                       date(2026, 8, 10, 9, 45))
        XCTAssertEqual(CalendarGrid.snapped(date(2026, 8, 10, 9, 58), rounding: .up),
                       date(2026, 8, 10, 10, 0))
        XCTAssertEqual(CalendarGrid.snapped(date(2026, 8, 10, 9, 52), rounding: .nearest),
                       date(2026, 8, 10, 9, 45))
        XCTAssertEqual(CalendarGrid.snapped(date(2026, 8, 10, 9, 53), rounding: .nearest),
                       date(2026, 8, 10, 10, 0))
    }

    func testSnappingLeavesAnAlreadyRoundTimeAlone() {
        let round = date(2026, 8, 10, 9, 30)
        XCTAssertEqual(CalendarGrid.snapped(round), round)
        XCTAssertEqual(CalendarGrid.snapped(round, rounding: .up), round)
    }

    // MARK: - Which week

    func testStartOfWeekFollowsTheSystemFirstWeekday() {
        // 2026-08-10 is a Monday.
        XCTAssertEqual(CalendarGrid.startOfWeek(date(2026, 8, 13), calendar: calendar),
                       date(2026, 8, 10))

        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        XCTAssertEqual(CalendarGrid.startOfWeek(date(2026, 8, 13), calendar: sundayFirst),
                       date(2026, 8, 9))
    }

    /// The bug a day-delta ÷ 7 cannot avoid: the day before the week turns is −1 day,
    /// which truncates to offset 0 — *this* week, which does not contain it.
    func testWeekIndexIsExactAcrossTheWeekBoundary() {
        let monday = date(2026, 8, 10)          // start of this week
        let sunday = date(2026, 8, 9)           // the day before it

        XCTAssertEqual(CalendarGrid.weekIndex(of: sunday, from: monday, calendar: calendar), -1)
        XCTAssertEqual(CalendarGrid.weekIndex(of: date(2026, 8, 16), from: monday, calendar: calendar), 0)
        XCTAssertEqual(CalendarGrid.weekIndex(of: date(2026, 8, 17), from: monday, calendar: calendar), 1)
    }

    func testDayMonthAndYearIndexes() {
        let origin = date(2026, 8, 10, 15, 0)   // mid-afternoon: must not affect a day count
        XCTAssertEqual(CalendarGrid.dayIndex(of: date(2026, 8, 12, 1, 0), from: origin, calendar: calendar), 2)
        XCTAssertEqual(CalendarGrid.dayIndex(of: date(2026, 8, 9, 23, 0), from: origin, calendar: calendar), -1)
        XCTAssertEqual(CalendarGrid.monthIndex(of: date(2026, 11, 1), from: origin, calendar: calendar), 3)
        XCTAssertEqual(CalendarGrid.monthIndex(of: date(2025, 12, 31), from: origin, calendar: calendar), -8)
        XCTAssertEqual(CalendarGrid.yearIndex(of: date(2028, 1, 1), from: origin, calendar: calendar), 2)
    }

    func testWeekdaySymbolsRotateToTheFirstWeekday() {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        XCTAssertEqual(CalendarGrid.orderedWeekdaySymbols(names, firstWeekday: 1), names)
        XCTAssertEqual(CalendarGrid.orderedWeekdaySymbols(names, firstWeekday: 2),
                       ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
    }

    func testWeekdaySymbolsPassThroughWhenTheInputIsNotAWeek() {
        XCTAssertEqual(CalendarGrid.orderedWeekdaySymbols(["a", "b"], firstWeekday: 2), ["a", "b"])
    }

    // MARK: - Nothing to lay out

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(layout([], on: date(2026, 8, 10)).isEmpty)
    }

    func testZeroLengthSpanStillGetsADrawableHeight() {
        let day = date(2026, 8, 10)
        let instant = date(2026, 8, 10, 9, 0)
        let spans = layout([(instant, instant)], on: day)

        XCTAssertGreaterThan(spans[0].height, 0)
        XCTAssertGreaterThan(spans[0].trueHeight, 0)
    }
}
