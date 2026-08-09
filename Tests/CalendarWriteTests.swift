import XCTest
@testable import mull

/// What mull normalises before anything reaches EventKit.
///
/// Create and update used to enforce these rules separately and slightly
/// differently — one filled an empty title, both nudged a zero-length event, only
/// one trimmed the location — which is the shape of bug that shows up as "the
/// location I typed vanished when I edited it later". One `normalized()` now stands
/// between every write and the store, and this is what it promises.
final class CalendarEventFieldsTests: XCTestCase {

    private func fields(title: String = "Standup",
                        start: Date = Date(timeIntervalSinceReferenceDate: 0),
                        minutes: Double = 30,
                        location: String? = nil,
                        isAllDay: Bool = false) -> CalendarService.EventFields {
        CalendarService.EventFields(title: title,
                                    start: start,
                                    end: start.addingTimeInterval(minutes * 60),
                                    location: location,
                                    isAllDay: isAllDay)
    }

    func testTitleIsTrimmed() {
        XCTAssertEqual(fields(title: "  Standup \n").normalized().title, "Standup")
    }

    /// Making the slot first and naming it later is how people actually use a
    /// calendar, so an empty title is filled in rather than refused.
    func testEmptyTitleBecomesNewEvent() {
        XCTAssertEqual(fields(title: "").normalized().title, "New Event")
        XCTAssertEqual(fields(title: "   ").normalized().title, "New Event")
    }

    func testBlankLocationBecomesNil() {
        XCTAssertNil(fields(location: "   ").normalized().location)
        XCTAssertNil(fields(location: "").normalized().location)
    }

    func testLocationIsTrimmedButKept() {
        XCTAssertEqual(fields(location: "  Room 2 ").normalized().location, "Room 2")
    }

    func testZeroLengthEventIsGivenAMinute() {
        let squashed = fields(minutes: 0).normalized()
        XCTAssertEqual(squashed.end.timeIntervalSince(squashed.start), 60)
    }

    /// A drag that ended above where it started, or an end field typed earlier than
    /// the start — either way the event must not be written inside out.
    func testBackwardsEventIsStraightened() {
        let straightened = fields(minutes: -90).normalized()
        XCTAssertGreaterThan(straightened.end, straightened.start)
    }

    /// An all-day event's shortest possible length is a day, not a minute.
    func testZeroLengthAllDayEventIsGivenADay() {
        let squashed = fields(minutes: 0, isAllDay: true).normalized()
        XCTAssertEqual(squashed.end.timeIntervalSince(squashed.start), 86_400)
    }

    func testAWellFormedEventIsLeftAlone() {
        let good = fields(title: "Design review", location: "Room 2")
        XCTAssertEqual(good.normalized(), good)
    }

    func testNormalizationIsIdempotent() {
        let once = fields(title: "  ", minutes: 0, location: " ").normalized()
        XCTAssertEqual(once.normalized(), once)
    }
}

/// The lengths the editor's duration menu produces, and the labels it shows for
/// them. `durationLabel` is what the menu button reads, so a 90-minute meeting
/// saying "90m" instead of "1h 30m" is a real (if small) defect.
final class DurationLabelTests: XCTestCase {

    func testUnderAnHourIsMinutes() {
        XCTAssertEqual(CalendarWeekView.durationLabel(15 * 60), "15m")
        XCTAssertEqual(CalendarWeekView.durationLabel(59 * 60), "59m")
    }

    func testWholeHoursDropTheMinutes() {
        XCTAssertEqual(CalendarWeekView.durationLabel(3600), "1h")
        XCTAssertEqual(CalendarWeekView.durationLabel(2 * 3600), "2h")
    }

    func testMixedLengthsCarryBoth() {
        XCTAssertEqual(CalendarWeekView.durationLabel(90 * 60), "1h 30m")
        XCTAssertEqual(CalendarWeekView.durationLabel(3600 + 5 * 60), "1h 5m")
    }

    func testNegativeDurationDoesNotProduceANegativeLabel() {
        XCTAssertEqual(CalendarWeekView.durationLabel(-600), "0m")
    }
}

/// Times shown to a person follow their Mac; times written for a machine do not.
final class TimeFormatTests: XCTestCase {

    func testMachineTimeIsAlwaysTwentyFourHour() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let afternoon = cal.date(from: DateComponents(year: 2026, month: 8, day: 10,
                                                     hour: 14, minute: 5))!
        XCTAssertEqual(TimeFormat.machine(afternoon), "14:05")
    }

    func testThereIsOneHourLabelPerHourOfTheDay() {
        let labels = TimeFormat.hourLabels()
        XCTAssertEqual(labels.count, 24)
        XCTAssertFalse(labels.contains(where: \.isEmpty),
                       "midnight used to be blank, which read as a broken gutter")
        XCTAssertEqual(Set(labels).count, 24, "two hours cannot carry the same label")
    }
}
