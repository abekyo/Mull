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
    private let resumeGap = BlockSegmenter.defaultResumeGap

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

    // MARK: - What is fit to write in somebody's day

    func testProseIsNotWrittenAsATitle() {
        // `generateLabel` falls through to a cleaned window title when it can parse
        // nothing out of it, so a question somebody asked an assistant arrives here
        // wearing exactly the shape of a project name. On the grid that is a card you
        // can ignore; on a calendar it is a line in your day, on your phone.
        XCTAssertFalse(CalendarMirror.isPresentable("how do I cancel a Task in Swift"))
        XCTAssertFalse(CalendarMirror.isPresentable("修正してください"))
        XCTAssertFalse(CalendarMirror.isPresentable("プロダクトの事業価値と社会的インパクトを検討"))
        XCTAssertFalse(CalendarMirror.isPresentable("https://example.com/a/page"))
        XCTAssertFalse(CalendarMirror.isPresentable("Untitled"))
        XCTAssertFalse(CalendarMirror.isPresentable(""))
        XCTAssertFalse(CalendarMirror.isPresentable(String(repeating: "a", count: 200)))
    }

    func testANameOrAFileNameIsWritten() {
        XCTAssertTrue(CalendarMirror.isPresentable("Mull — parser"))
        // A filename is rejected as a *project* name and is exactly right as a
        // calendar title. Two different questions; only one is asked here.
        XCTAssertTrue(CalendarMirror.isPresentable("CalendarView.swift"))
        XCTAssertTrue(CalendarMirror.isPresentable("Mull — CalendarView.swift"))
    }

    func testAGlanceIsLeftOutAndSaidSo() {
        // The engine's floor is 30 seconds, which is right for a grid you can zoom into
        // and wrong for a calendar that syncs to a phone. Counted rather than silently
        // dropped: a day of nothing but glances must not read as an empty day.
        let result = plan([block(minutesAgo: 30, spanMinutes: 3)])

        XCTAssertTrue(result.create.isEmpty)
        XCTAssertEqual(result.quality.tooShort, 1)
        XCTAssertEqual(result.quality.considered, 0)
        XCTAssertNil(result.quality.namedFraction, "nothing to name is not the same as naming nothing")
    }

    func testAnUnreadableTitleFallsBackToTheAppAndIsCounted() {
        let result = plan([block(minutesAgo: 30, label: "how do I cancel a Task in Swift")])

        XCTAssertEqual(result.create.count, 1)
        XCTAssertEqual(result.create[0].title, "Code", "an hour of Code is true; the sentence is not a title")
        XCTAssertEqual(result.quality.fellBack, 1)
        XCTAssertEqual(result.quality.named, 0)
        XCTAssertEqual(result.quality.namedFraction, 0)
    }

    func testCopiedTextIsNeverWrittenAsATitle() {
        // The shape gate cannot help here, and that is the whole point: all three of
        // these pass `isPresentable` on their own merits. Short copied fragments clear
        // it exactly when they are worst — a client, a subject, a figure — because the
        // long ones die on the 40-character limit and what is left reads like a name.
        // So the refusal cannot be made by looking at the string. It has to know where
        // the string came from, which is what `labelFromClipboard` carries.
        for copied in ["田中商事 見積書", "退職の相談", "Acme Corp Q3 renewal"] {
            XCTAssertTrue(CalendarMirror.isPresentable(copied),
                          "\(copied) reads as a name; the source is the only thing that separates it")

            var b = block(minutesAgo: 30, label: copied)
            b.labelFromClipboard = true
            let result = plan([b])

            XCTAssertEqual(result.create.count, 1)
            XCTAssertEqual(result.create[0].title, "Code",
                           "what the user copied does not leave this Mac wearing a calendar title")
            XCTAssertEqual(result.quality.fellBack, 1)
            XCTAssertEqual(result.quality.named, 0)
        }
    }

    func testTheSameLabelFromAWindowTitleIsStillWritten() {
        // The refusal above is about provenance, not vocabulary. Nothing is on a list.
        let result = plan([block(minutesAgo: 30, label: "Acme Corp Q3 renewal")])

        XCTAssertEqual(result.create[0].title, "Acme Corp Q3 renewal")
        XCTAssertEqual(result.quality.named, 1)
    }

    func testTheQualityReadingCountsBothHalves() {
        let result = plan([block(minutesAgo: 30, label: "Mull — parser"),
                           block(minutesAgo: 90, label: "うまくいかないので直したい"),
                           block(minutesAgo: 150, spanMinutes: 2)])

        XCTAssertEqual(result.quality.named, 1)
        XCTAssertEqual(result.quality.fellBack, 1)
        XCTAssertEqual(result.quality.tooShort, 1)
        XCTAssertEqual(result.quality.namedFraction, 0.5)
    }

    // MARK: - The correction the mirror used to throw away

    func testDeletingAMirroredEventProducesACorrectionCard() {
        // §7.3 calls "mull proposed it, the human removed it" the highest-quality
        // relevance label there is. Until now the calendar produced one every time
        // somebody cleared a row and spent it entirely on not repeating itself.
        let b = block(minutesAgo: 30)
        let key = CalendarMirror.key(forBlockStartingAt: b.start)

        let cards = CalendarMirror.correctionCards(for: plan([b], existing: [], written: [key]),
                                                   now: now)

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].blockID, key)
        XCTAssertEqual(cards[0].dropped, ["Mull — parser"], "the title is what was rejected")
        XCTAssertTrue(cards[0].survived.isEmpty)
        XCTAssertTrue(cards[0].added.isEmpty, "a deletion adds nothing")
    }

    func testTheRejectedTitleGetsANegativeVerdictInTheLedger() {
        // The point of routing this through `CorrectionIndex` rather than a private
        // list: a window title not worth an hour of somebody's day is not worth a slot
        // in a context window either, and now one fact settles both.
        let b = block(minutesAgo: 30)
        let key = CalendarMirror.key(forBlockStartingAt: b.start)
        let cards = CalendarMirror.correctionCards(for: plan([b], existing: [], written: [key]),
                                                   now: now)

        XCTAssertLessThan(CorrectionIndex.fold(cards).delta(for: "Mull — parser"), 0)
    }

    func testAnOrdinaryWriteProducesNoCards() {
        // Only a deletion is a correction. Writing an event is mull proposing, and a
        // proposal nobody has answered is not a verdict.
        XCTAssertTrue(CalendarMirror.correctionCards(for: plan([block(minutesAgo: 30)]),
                                                     now: now).isEmpty)
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
