import XCTest
import CoreGraphics
@testable import mull

/// What the height of a bar is allowed to mean.
///
/// The complaint this was written against: "nine hours doesn't feel like a long
/// time on the chart". It was not a rendering bug — the bars were normalised to the
/// week's own maximum, so the longest day of any week drew the same full-height bar
/// whether it was nine hours or forty minutes. The tests below are the reference
/// scale that replaced it, and the first one is the complaint itself.
final class WeekBarScaleTests: XCTestCase {

    private let hour: TimeInterval = 3600

    /// The bug, stated as a measurement: two weeks whose longest days differ by an
    /// order of magnitude must not draw the same bar.
    func testALongDayIsNotTheSameHeightAsAShortOne() {
        let longWeek = WeekBarScale([9 * hour, 2 * hour, 0, 0, 0, 0, 0])
        let shortWeek = WeekBarScale([40 * 60, 20 * 60, 0, 0, 0, 0, 0])

        let nineHours = longWeek.height(for: 9 * hour)
        let fortyMinutes = shortWeek.height(for: 40 * 60)

        XCTAssertGreaterThan(nineHours, fortyMinutes * 5,
                             "the week's own maximum must not set the scale")
        XCTAssertGreaterThan(nineHours, 80, "a 9h day should nearly fill the track")
        XCTAssertLessThan(fortyMinutes, 12, "40 minutes should read as a stub")
    }

    /// The same duration draws the same height in any week. This is what "the scale
    /// means something" reduces to, and it is what week-relative scaling could not do.
    func testTheSameDayDrawsTheSameHeightInAnyWeek() {
        let quiet = WeekBarScale([4 * hour, 1 * hour, 0, 0, 0, 0, 0])
        let busy = WeekBarScale([4 * hour, 9 * hour, 7 * hour, 6 * hour, 0, 0, 0])

        XCTAssertEqual(quiet.height(for: 4 * hour), busy.height(for: 4 * hour), accuracy: 0.001)
    }

    /// 8h is the reference, so it lands on the rule — the one place where the drawing
    /// and the printed legend have to agree.
    func testEightHoursLandsOnTheRule() {
        let week = WeekBarScale([8 * hour, 3 * hour, 0, 0, 0, 0, 0])

        XCTAssertEqual(week.height(for: WeekBarScale.referenceSeconds),
                       week.referenceOffset, accuracy: 0.001)
        XCTAssertGreaterThan(week.height(for: 9 * hour), week.referenceOffset,
                             "a day over 8h clears the rule")
        XCTAssertLessThan(week.height(for: 7 * hour), week.referenceOffset)
    }

    /// Below the ceiling the scale is fixed, so the rule does not wander from week to
    /// week. A reader who learns where the line is keeps that knowledge.
    func testTheRuleHoldsStillUntilSomeoneExceedsTheCeiling() {
        let empty = WeekBarScale([0, 0, 0, 0, 0, 0, 0])
        let ordinary = WeekBarScale([6 * hour, 9 * hour, 2 * hour, 0, 0, 0, 0])

        XCTAssertEqual(empty.referenceOffset, ordinary.referenceOffset, accuracy: 0.001)
        XCTAssertEqual(ordinary.referenceOffset, WeekBarScale.trackHeight * 0.8, accuracy: 0.001)
    }

    /// A 14-hour day is exactly the day worth noticing, so it is not clipped: the
    /// strip rescales and the rule slides down to stay truthful about where 8h is.
    func testAnOutsizedDayRescalesTheStripInsteadOfClipping() {
        let week = WeekBarScale([14 * hour, 3 * hour, 0, 0, 0, 0, 0])

        XCTAssertEqual(week.height(for: 14 * hour), WeekBarScale.trackHeight, accuracy: 0.001,
                       "the longest day fills the track and no more")
        XCTAssertLessThan(week.referenceOffset, WeekBarScale.trackHeight * 0.8,
                          "the rule moves down with the scale")
        XCTAssertGreaterThan(week.height(for: 9 * hour), week.referenceOffset,
                             "9h still reads as over a full day")
    }

    /// A recorded day is never mistaken for an empty one, however short it was.
    func testTwentyMinutesIsVisiblyMoreThanNothing() {
        let week = WeekBarScale([20 * 60, 0, 0, 0, 0, 0, 0])

        XCTAssertGreaterThan(week.height(for: 20 * 60), week.height(for: 0))
        XCTAssertEqual(week.height(for: 0), WeekBarScale.emptyStub, accuracy: 0.001)
    }

    /// No days at all is the state Home draws on a fresh Monday morning. It must not
    /// divide by zero on the way to drawing seven stubs.
    func testAnEmptyWeekStillHasAScale() {
        let week = WeekBarScale([])

        XCTAssertEqual(week.span, WeekBarScale.referenceSeconds * WeekBarScale.headroom, accuracy: 0.001)
        XCTAssertTrue(week.referenceOffset.isFinite)
    }
}
