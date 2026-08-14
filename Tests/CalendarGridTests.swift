import XCTest
@testable import mull

/// The calendar's arithmetic, which had no tests at all while it was buried in a
/// SwiftUI view. Every case here is a thing that was got wrong once, or that would
/// only ever be noticed by looking very carefully at the screen.
final class CalendarGridTests: XCTestCase {

    // MARK: - The month grid both the month view and the picker draw

    /// Six rows, always. A grid that is five rows in February and six in March changes
    /// height as you page — in the toolbar's Jump-to popover that moves the day you
    /// were about to click out from under the pointer.
    func testAMonthGridIsAlwaysSixWeeks() {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1
        for month in 1...12 {
            let first = cal.date(from: DateComponents(year: 2026, month: month, day: 1))!
            XCTAssertEqual(CalendarGrid.monthGridDays(of: first, calendar: cal).count, 42,
                           "month \(month) drew a grid of a different height")
        }
        // February 2027 begins on a Monday and has 28 days: the one month that fits in
        // four rows, and the case a "just enough rows" grid gets wrong.
        let feb = cal.date(from: DateComponents(year: 2027, month: 2, day: 1))!
        XCTAssertEqual(CalendarGrid.monthGridDays(of: feb, calendar: cal).count, 42)
    }

    func testTheGridStartsOnTheSystemsFirstWeekday() {
        var sunday = Calendar(identifier: .gregorian)
        sunday.firstWeekday = 1
        var monday = Calendar(identifier: .gregorian)
        monday.firstWeekday = 2

        // 1 August 2026 is a Saturday.
        let august = sunday.date(from: DateComponents(year: 2026, month: 8, day: 1))!

        XCTAssertEqual(sunday.component(.weekday, from: CalendarGrid.monthGridDays(of: august, calendar: sunday)[0]),
                       1, "a Sunday-first calendar must open the grid on a Sunday")
        XCTAssertEqual(monday.component(.weekday, from: CalendarGrid.monthGridDays(of: august, calendar: monday)[0]),
                       2, "a Monday-first calendar must open the grid on a Monday")
    }

    func testAnyInstantInTheMonthGivesTheSameGrid() {
        // The picker holds a whole date and the month view holds the first of the month.
        // Both must land on the same 42 days, or the two grids disagree about a month.
        let cal = Calendar(identifier: .gregorian)
        let first = cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let middle = cal.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 14, minute: 30))!

        XCTAssertEqual(CalendarGrid.monthGridDays(of: first, calendar: cal),
                       CalendarGrid.monthGridDays(of: middle, calendar: cal))
    }

    func testTheGridCoversEveryDayOfTheMonth() {
        let cal = Calendar(identifier: .gregorian)
        let first = cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let days = CalendarGrid.monthGridDays(of: first, calendar: cal)
        let inMonth = days.filter { cal.isDate($0, equalTo: first, toGranularity: .month) }

        XCTAssertEqual(inMonth.count, 31, "August has 31 days and all of them must be reachable")
        XCTAssertEqual(cal.component(.day, from: inMonth.first!), 1)
        XCTAssertEqual(cal.component(.day, from: inMonth.last!), 31)
    }

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

    // MARK: - The all-day band

    /// Monday 2026-08-10 through Sunday, the week every case below is drawn on.
    private var week: [Date] { (0..<7).map { date(2026, 8, 10 + $0) } }

    /// EventKit's shape for a day-shaped event: midnight on the first day to
    /// midnight after the last, so the end is a day that is not covered.
    private func allDay(_ id: String, _ from: Int, through last: Int) -> CalendarGrid.DayInterval {
        CalendarGrid.DayInterval(id: id, start: date(2026, 8, from), end: date(2026, 8, last + 1))
    }

    private func bars(_ intervals: [CalendarGrid.DayInterval],
                      days: [Date]? = nil) -> [String: CalendarGrid.Bar] {
        let laid = CalendarGrid.allDayBars(intervals, days: days ?? week, calendar: calendar)
        return Dictionary(uniqueKeysWithValues: laid.map { ($0.id, $0) })
    }

    /// The case the band got wrong: a four-day trip was filed under each of its four
    /// days and drawn four times, once per column.
    func testMultiDayEventIsOneBarSpanningItsDays() {
        let laid = CalendarGrid.allDayBars([allDay("trip", 11, through: 14)],
                                           days: week, calendar: calendar)

        XCTAssertEqual(laid.count, 1, "one commitment is one bar, however many days it covers")
        XCTAssertEqual(laid[0].column, 1)
        XCTAssertEqual(laid[0].span, 4)
    }

    func testOneDayEventOccupiesOneColumn() {
        let bar = bars([allDay("birthday", 12, through: 12)])["birthday"]

        XCTAssertEqual(bar?.column, 2)
        XCTAssertEqual(bar?.span, 1)
        XCTAssertEqual(bar?.continuesBefore, false)
        XCTAssertEqual(bar?.continuesAfter, false)
    }

    /// An all-day event whose end is stored inclusively — 23:59:59 on the last day
    /// rather than the midnight after it — must not gain a trailing column.
    func testInclusiveEndDoesNotInventATrailingDay() {
        let inclusive = CalendarGrid.DayInterval(id: "pto",
                                                 start: date(2026, 8, 11),
                                                 end: date(2026, 8, 12, 23, 59))
        XCTAssertEqual(bars([inclusive])["pto"]?.span, 2)
    }

    /// The lane jog: a bar used to move up a row the moment the event above it
    /// ended, because each column stacked its own chips with no memory of its
    /// neighbours. `run` is pushed to the second lane by an earlier bar, and has to
    /// stay there on Wednesday, Thursday and Friday — where the first lane is empty
    /// and the old band would have pulled it up.
    func testABarHoldsOneLaneForTheWholeOfItsRun() {
        let laid = bars([allDay("mon-tue", 10, through: 11),
                         allDay("run", 11, through: 14)])

        XCTAssertEqual(laid["mon-tue"]?.lane, 0)
        XCTAssertEqual(laid["run"]?.lane, 1)
        XCTAssertEqual(laid["run"]?.column, 1)
        XCTAssertEqual(laid["run"]?.span, 4, "one bar, one lane, four columns")
    }

    /// Where two begin on the same day, the longer one goes on top — Apple's order,
    /// and the one that keeps a week of PTO above the afternoon inside it.
    func testLongerRunTakesTheUpperLane() {
        let laid = bars([allDay("short", 10, through: 10),
                         allDay("long", 10, through: 13)])

        XCTAssertEqual(laid["long"]?.lane, 0)
        XCTAssertEqual(laid["short"]?.lane, 1)
    }

    func testBarsThatDoNotOverlapShareALane() {
        let laid = bars([allDay("early", 10, through: 11),
                         allDay("late", 13, through: 14)])

        XCTAssertEqual(laid["early"]?.lane, 0)
        XCTAssertEqual(laid["late"]?.lane, 0, "a lane is free again once its bar has ended")
    }

    /// Touching, not overlapping: one ends on Tuesday, the next begins on Wednesday.
    func testABarMayReuseALaneTheDayAfterItsNeighbourEnds() {
        let laid = bars([allDay("first", 10, through: 11),
                         allDay("second", 12, through: 13)])

        XCTAssertEqual(laid["first"]?.lane, 0)
        XCTAssertEqual(laid["second"]?.lane, 0)
    }

    func testRunsLeavingTheRangeAreClippedAndSayThatTheyWere() {
        let laid = bars([CalendarGrid.DayInterval(id: "leave",
                                                  start: date(2026, 8, 6),
                                                  end: date(2026, 8, 20))])["leave"]

        XCTAssertEqual(laid?.column, 0)
        XCTAssertEqual(laid?.span, 7)
        XCTAssertTrue(laid?.continuesBefore == true, "it did not begin on Monday")
        XCTAssertTrue(laid?.continuesAfter == true, "and it does not end on Sunday")
    }

    func testAnEventEndingInsideTheRangeDoesNotClaimToContinue() {
        let laid = bars([CalendarGrid.DayInterval(id: "arriving",
                                                  start: date(2026, 8, 8),
                                                  end: date(2026, 8, 12))])["arriving"]

        XCTAssertTrue(laid?.continuesBefore == true)
        XCTAssertFalse(laid?.continuesAfter == true)
        XCTAssertEqual(laid?.span, 2, "Monday and Tuesday of the week on screen")
    }

    /// Day view is the same band one column wide, and a trip passing through it has
    /// to read as passing through rather than as a one-day booking.
    func testDayViewShowsAPassingRunAsContinuingBothWays() {
        let laid = CalendarGrid.allDayBars([allDay("trip", 10, through: 14)],
                                           days: [date(2026, 8, 12)], calendar: calendar)

        XCTAssertEqual(laid.count, 1)
        XCTAssertEqual(laid[0].span, 1)
        XCTAssertTrue(laid[0].continuesBefore)
        XCTAssertTrue(laid[0].continuesAfter)
    }

    func testEventsOutsideTheRangeAreNotDrawn() {
        XCTAssertTrue(CalendarGrid.allDayBars([allDay("last-month", 1, through: 3)],
                                              days: week, calendar: calendar).isEmpty)
    }

    func testNoDaysMeansNoBars() {
        XCTAssertTrue(CalendarGrid.allDayBars([allDay("trip", 11, through: 14)],
                                              days: [], calendar: calendar).isEmpty)
    }

    /// The band is rebuilt on every load; two identical layouts must not swap lanes
    /// between them, or a bar moves under the cursor for no reason.
    func testLayoutIsStableForEventsThatCannotBeToldApartByDate() {
        let same = [allDay("b", 10, through: 11), allDay("a", 10, through: 11)]

        XCTAssertEqual(bars(same)["a"]?.lane, 0)
        XCTAssertEqual(bars(same.reversed())["a"]?.lane, 0)
    }

    // MARK: - Dragging a span

    private func dragged(_ start: Date, by hours: Double, columns: Int = 0) -> Date {
        CalendarGrid.draggedStart(from: start, shift: hours * 3600,
                                  dayDelta: columns, calendar: calendar)
    }

    func testDraggingDownTheAxisMovesTheStartAndSnaps() {
        let moved = dragged(date(2026, 8, 10, 9, 0), by: 2.1)
        XCTAssertEqual(moved, date(2026, 8, 10, 11, 0))
    }

    /// The wrap: a nudge upward at the top of the day used to roll the event onto
    /// yesterday, and the card leapt to the bottom of the column on the way.
    func testDraggingUpPastMidnightIsHeldAtMidnight() {
        let moved = dragged(date(2026, 8, 10, 0, 15), by: -2)

        XCTAssertEqual(moved, date(2026, 8, 10, 0, 0))
    }

    func testDraggingDownPastMidnightIsHeldAtTheLastQuarterOfTheDay() {
        let moved = dragged(date(2026, 8, 10, 23, 0), by: 5)

        XCTAssertEqual(moved, date(2026, 8, 10, 23, 45),
                       "and never 00:00, which is a different day wearing the same clock")
    }

    func testDraggingSidewaysMovesWholeDaysAndKeepsTheTime() {
        let moved = dragged(date(2026, 8, 10, 9, 30), by: 0, columns: 2)
        XCTAssertEqual(moved, date(2026, 8, 12, 9, 30))
    }

    func testSidewaysAndDownwardsCompose() {
        let moved = dragged(date(2026, 8, 10, 9, 0), by: 1.5, columns: -1)
        XCTAssertEqual(moved, date(2026, 8, 9, 10, 30))
    }

    /// A span that began yesterday and is drawn clamped at the top of today's column
    /// still belongs to yesterday: its clamp is yesterday's, shifted by the columns
    /// the pointer asked for.
    func testAContinuingSpanIsClampedToItsOwnDay() {
        let moved = dragged(date(2026, 8, 9, 23, 30), by: 4)
        XCTAssertEqual(moved, date(2026, 8, 9, 23, 45))
    }

    /// A day that is 25 hours long really has a 24:xx to be dragged into.
    func testTheClampFollowsALongDaysRealLength() {
        var american = Calendar(identifier: .gregorian)
        american.timeZone = TimeZone(identifier: "America/New_York")!
        let fallBack = american.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 22))!
        let moved = CalendarGrid.draggedStart(from: fallBack, shift: 6 * 3600,
                                              dayDelta: 0, calendar: american)

        XCTAssertEqual(moved.timeIntervalSince(american.startOfDay(for: fallBack)),
                       24.75 * 3600, accuracy: 1,
                       "the last quarter hour of a 25-hour day")
    }

    // MARK: - Which column a drag asked for

    func testASmallSidewaysWobbleIsNotADayChange() {
        XCTAssertEqual(CalendarGrid.draggedColumns(12, columnWidth: 100, from: 2, columns: 7), 0)
    }

    func testHalfAColumnRoundsToTheNextOne() {
        XCTAssertEqual(CalendarGrid.draggedColumns(60, columnWidth: 100, from: 2, columns: 7), 1)
    }

    func testADragOffTheEdgeOfTheWeekStopsAtTheEdge() {
        XCTAssertEqual(CalendarGrid.draggedColumns(900, columnWidth: 100, from: 5, columns: 7), 1)
        XCTAssertEqual(CalendarGrid.draggedColumns(-900, columnWidth: 100, from: 1, columns: 7), -1)
    }

    /// Day view is one column, and there is nowhere sideways to go.
    func testASingleColumnRangeNeverChangesDay() {
        XCTAssertEqual(CalendarGrid.draggedColumns(500, columnWidth: 100, from: 0, columns: 1), 0)
    }
}
