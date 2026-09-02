import XCTest
@testable import mull

/// A row that records what happened must not answer "are you available then?"
///
/// An `EKEvent` nobody sets is busy, so every event the mirror wrote before it learned
/// to say `.free` tells whoever reads that calendar — Google, a booking link, a
/// colleague proposing a meeting — that its owner was occupied from the first row of
/// the day to the last. Writing new rows free fixed the next event and not one of the
/// ones already out there: `apply` skips a key it has written, and `updateEvent` takes
/// `EventFields`, which carries a title and two dates and no availability at all.
///
/// So the repair is part of the plan, and these tests hold the two halves of it — that
/// a row which is wrong is named, and that a row which is not is left alone, because a
/// pointless save is a modification date, a sync, and a notification on every device
/// the person owns.
final class MirrorAvailabilityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let resumeGap = BlockSegmenter.defaultResumeGap

    private func block(minutesAgo: Double, spanMinutes: Double = 30,
                       label: String = "Mull — parser") -> TimeBlock {
        let end = now.addingTimeInterval(-minutesAgo * 60)
        var b = TimeBlock(from: EventSegment(timestamp: end.addingTimeInterval(-spanMinutes * 60),
                                             app: "Code", windowTitle: label,
                                             eventType: .screenText, text: ""))
        b.end = end
        b.label = label
        return b
    }

    private func existing(for b: TimeBlock, id: String = "ek-1", busy: Bool,
                          title: String? = nil) -> CalendarMirror.Existing {
        CalendarMirror.Existing(key: CalendarMirror.key(forBlockStartingAt: b.start),
                                handle: CalendarService.EventHandle(identifier: id, occurrenceDate: nil),
                                title: title ?? b.label,
                                start: b.start,
                                end: b.end,
                                isBusy: busy)
    }

    private func plan(_ blocks: [TimeBlock],
                      existing: [CalendarMirror.Existing] = [],
                      written: Set<String> = [],
                      trigger: CalendarMirror.Trigger = .reconcile) -> CalendarMirror.Plan {
        CalendarMirror.plan(blocks: blocks, existing: existing, written: written,
                            tombstoned: [], now: now, resumeGap: resumeGap, trigger: trigger)
    }

    // MARK: - What gets repaired

    func testAnOlderRowThatStillSaysBusyIsRepaired() {
        let b = block(minutesAgo: 11)
        let result = plan([b], existing: [existing(for: b, busy: true)])

        XCTAssertEqual(result.repair.count, 1)
        XCTAssertEqual(result.repair.first?.identifier, "ek-1")
        XCTAssertTrue(result.update.isEmpty,
                      "nothing about the event changed — the flag is not a content change")
        XCTAssertTrue(result.create.isEmpty, "the row is already there")
    }

    /// The plan is what a run decides to do, and a run whose only work is a repair must
    /// still happen. `isEmpty` is the gate both callers check first.
    func testARunWithNothingButRepairsIsNotEmpty() {
        let b = block(minutesAgo: 11)
        XCTAssertFalse(plan([b], existing: [existing(for: b, busy: true)]).isEmpty)
        XCTAssertTrue(plan([b], existing: [existing(for: b, busy: false)]).isEmpty,
                      "a day that is already right costs no writes at all")
    }

    func testARowThatAlreadySaysFreeIsLeftAlone() {
        let b = block(minutesAgo: 11)
        XCTAssertTrue(plan([b], existing: [existing(for: b, busy: false)]).repair.isEmpty)
    }

    /// A row on its way out is not worth a save. It is about to stop existing, and the
    /// save would sync twice for a state nobody will read.
    func testARowAboutToBeDeletedIsNotRepaired() {
        let stale = block(minutesAgo: 400)
        var row = existing(for: stale, busy: true)
        // A key no block would produce any more: the segmentation moved under it.
        row = CalendarMirror.Existing(key: "999", handle: row.handle, title: row.title,
                                      start: row.start, end: row.end, isBusy: true)

        let result = plan([block(minutesAgo: 11)], existing: [row])

        XCTAssertEqual(result.delete.count, 1)
        XCTAssertTrue(result.repair.isEmpty)
    }

    /// A row whose title changed needs both, and they are separate lists on purpose:
    /// the update goes through `updateEvent`, which cannot carry availability, so a
    /// repair folded into it would be a repair that never happened.
    func testAChangedRowIsBothUpdatedAndRepaired() {
        let b = block(minutesAgo: 11)
        let result = plan([b], existing: [existing(for: b, busy: true, title: "an older name")])

        XCTAssertEqual(result.update.count, 1)
        XCTAssertEqual(result.repair.count, 1)
    }

    // MARK: - Both triggers repair

    /// The failure this whole area has already had once: a wire attached to `apply()`
    /// alone, on a Mac where the timer had never once met its start condition and the
    /// button had written every event there was. A repair that only the timer performs
    /// is a repair that does not happen.
    func testThePressRepairsToo() {
        let b = block(minutesAgo: 11)
        let pressed = plan([b], existing: [existing(for: b, busy: true)],
                           written: [CalendarMirror.key(forBlockStartingAt: b.start)],
                           trigger: .press)
        XCTAssertEqual(pressed.repair.count, 1)
    }

    func testBothWritePathsActOnTheRepairList() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for path in ["Mull/Services/CalendarMirrorRunner.swift",
                     "Mull/Views/CalendarView+Export.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("plan.repair"),
                          "\(path) plans a repair and never performs it")
            XCTAssertTrue(source.contains("markFree("),
                          "\(path) must go through the one call that touches availability alone")
        }
    }

    /// `updateEvent` stays unable to carry availability. If it ever learns to, the
    /// repair list should go — and until then, folding the two would silently drop it.
    func testTheOrdinaryUpdatePathStillCarriesNoAvailability() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Mull/Core/CalendarService.swift"),
            encoding: .utf8)
        let fields = try XCTUnwrap(source.range(of: "struct EventFields"))
        let body = String(source[fields.lowerBound...].prefix(600))
        XCTAssertFalse(body.contains("availability"),
                       "EventFields carries availability now — the repair list has a rival")
    }
}
