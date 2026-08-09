import XCTest
@testable import mull

/// Locks the three promises the calendar mirror makes, all of which are about
/// somebody's real calendar and none of which can be checked by looking at a screen:
/// it writes only work that has finished, it reconciles rather than appends, and a
/// deletion by the user is final.
///
/// Everything here is pure — no EventKit, no database, no clock. `CalendarMirror`
/// exists as a separate type for exactly this reason.
final class CalendarMirrorTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let resumeGap = TimeBlockEngine.defaultResumeGap

    /// A block ending `minutesAgo` before `now`, spanning `spanMinutes`.
    private func block(minutesAgo: Double, spanMinutes: Double = 30, label: String = "Mull — parser") -> TimeBlock {
        let end = now.addingTimeInterval(-minutesAgo * 60)
        var b = TimeBlock(from: EventSegment(timestamp: end.addingTimeInterval(-spanMinutes * 60),
                                             app: "Code", windowTitle: label,
                                             eventType: .screenText, text: ""))
        b.end = end
        b.label = label
        return b
    }

    private func handle(_ id: String) -> CalendarService.EventHandle {
        CalendarService.EventHandle(identifier: id, occurrenceDate: nil)
    }

    private func existing(for b: TimeBlock, id: String = "ek-1", title: String? = nil,
                          end: Date? = nil) -> CalendarMirror.Existing {
        CalendarMirror.Existing(key: CalendarMirror.key(forBlockStartingAt: b.start),
                                handle: handle(id),
                                title: title ?? b.label,
                                start: b.start,
                                end: end ?? b.end)
    }

    private func plan(_ blocks: [TimeBlock],
                      existing: [CalendarMirror.Existing] = [],
                      written: Set<String> = [],
                      tombstoned: Set<String> = []) -> CalendarMirror.Plan {
        CalendarMirror.plan(blocks: blocks, existing: existing, written: written,
                            tombstoned: tombstoned, now: now, resumeGap: resumeGap)
    }

    // MARK: - Only settled work

    func testWorkStillInProgressIsNotWritten() {
        // The whole reason the mirror may run on a timer. This block's last event was
        // two minutes ago, so it is still growing; writing it would tell the calendar
        // the session ended at a moment it did not.
        XCTAssertTrue(plan([block(minutesAgo: 2)]).isEmpty)
    }

    func testABlockPastTheResumeWindowIsWritten() {
        let b = block(minutesAgo: 11)
        let result = plan([b])

        XCTAssertEqual(result.create.count, 1)
        XCTAssertEqual(result.create[0].title, "Mull — parser")
        XCTAssertEqual(result.create[0].start, b.start)
        XCTAssertEqual(result.create[0].end, b.end)
    }

    func testTheSettledBoundaryIsTheLargerOfTheTwoMergeWindows() {
        // A block can still grow through the engine's 180s window *or* through
        // `resumeGap`. Settled means past both, so the boundary is the larger.
        XCTAssertFalse(CalendarMirror.isSettled(end: now.addingTimeInterval(-599), now: now, resumeGap: 600))
        XCTAssertTrue(CalendarMirror.isSettled(end: now.addingTimeInterval(-601), now: now, resumeGap: 600))

        // Rejoining turned off does not drop the floor to zero: the inner window is
        // still open, so a block one minute old is still not final.
        XCTAssertFalse(CalendarMirror.isSettled(end: now.addingTimeInterval(-60), now: now, resumeGap: 0))
        XCTAssertTrue(CalendarMirror.isSettled(end: now.addingTimeInterval(-181), now: now, resumeGap: 0))
    }

    // MARK: - Reconcile, don't append

    func testAnUnchangedDayCostsNoWrites() {
        let b = block(minutesAgo: 30)
        XCTAssertTrue(plan([b], existing: [existing(for: b)], written: [existing(for: b).key]).isEmpty)
    }

    func testARelabelledOrRegrownBlockIsFollowed() {
        // Blocks are derived: the same events yielded fourteen blocks and then eight
        // after one rule change. A mirrored event has to follow its block rather than
        // sit there stale.
        let b = block(minutesAgo: 30)
        let stale = existing(for: b, title: "Mull — old caption", end: b.end.addingTimeInterval(-600))

        let result = plan([b], existing: [stale], written: [stale.key])

        XCTAssertTrue(result.create.isEmpty)
        XCTAssertEqual(result.update.count, 1)
        XCTAssertEqual(result.update[0].handle, handle("ek-1"))
        XCTAssertEqual(result.update[0].entry.title, "Mull — parser")
        XCTAssertEqual(result.update[0].entry.end, b.end)
    }

    func testAnEventWhoseBlockNoLongerExistsIsRemoved() {
        // Re-segmentation merged two blocks into one; the orphan mull wrote for the
        // half that no longer exists is mull's to clean up.
        let kept = block(minutesAgo: 30)
        let vanished = block(minutesAgo: 90, label: "Mull — gone")

        let result = plan([kept],
                          existing: [existing(for: kept), existing(for: vanished, id: "ek-2")],
                          written: [existing(for: kept).key, existing(for: vanished).key])

        XCTAssertEqual(result.delete.map(\.handle), [handle("ek-2")])
        XCTAssertTrue(result.create.isEmpty)
    }

    // MARK: - The user's deletions are final

    func testDeletingAMirroredEventTombstonesItRatherThanRewriting() {
        // The failure this prevents is the mirror taking somebody's calendar away from
        // them: delete an event, and an hour later it is back.
        let b = block(minutesAgo: 30)
        let key = CalendarMirror.key(forBlockStartingAt: b.start)

        let result = plan([b], existing: [], written: [key])

        XCTAssertTrue(result.create.isEmpty, "a deleted event must not be recreated")
        XCTAssertEqual(result.tombstone, [key])
    }

    func testATombstonedBlockStaysGoneOnEveryLaterRun() {
        let b = block(minutesAgo: 30)
        let key = CalendarMirror.key(forBlockStartingAt: b.start)

        XCTAssertTrue(plan([b], existing: [], written: [], tombstoned: [key]).isEmpty)
    }

    func testAnEventMullNeverWroteIsCreatedRatherThanTombstoned() {
        // The distinction the `written` ledger exists for: absent because it was
        // deleted, versus absent because this is the first run.
        let b = block(minutesAgo: 30)

        let result = plan([b], existing: [], written: [])

        XCTAssertEqual(result.create.count, 1)
        XCTAssertTrue(result.tombstone.isEmpty)
    }

    // MARK: - The marker

    func testOnlyMullsOwnMarkerIsRecognised() {
        let key = CalendarMirror.key(forBlockStartingAt: now)
        XCTAssertEqual(CalendarMirror.key(fromMarker: CalendarMirror.marker(key)), key)

        // Anything else on a calendar belongs to the user, whichever calendar it is in.
        XCTAssertNil(CalendarMirror.key(fromMarker: nil))
        XCTAssertNil(CalendarMirror.key(fromMarker: URL(string: "https://example.com/block/123")))
        XCTAssertNil(CalendarMirror.key(fromMarker: URL(string: "x-mull://note/123")))
    }

    func testTheKeyIsStableAcrossRederivation() {
        // A block's start is its first event, which no later event can change — so the
        // same block re-derived tomorrow addresses the same calendar row.
        let b = block(minutesAgo: 30)
        var again = b
        again.end = b.end.addingTimeInterval(900)

        XCTAssertEqual(CalendarMirror.key(forBlockStartingAt: b.start),
                       CalendarMirror.key(forBlockStartingAt: again.start))
    }
}
