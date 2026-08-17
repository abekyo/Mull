import XCTest
@testable import mull

/// Locks the one thing the mirror could not say about itself.
///
/// On 2026-08-14 the ledger on the author's own Mac held 37 keys and neither
/// preference the timer needs had ever been written — so the mirror had never run,
/// every one of those writes had come from the toolbar button, and no screen in the
/// app distinguished any of that from a mirror running perfectly every hour. Four
/// states produced one empty calendar. These tests are about keeping them four.
final class CalendarMirrorStatusTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A store of its own, so a test never reads or writes the real app's settings.
    /// `Preferences.store` resolves to the app's own domain under a test host, and a
    /// suite that leaks would put test counts on somebody's Settings pane.
    private var store: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "mull.status.tests.\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        store = nil
        suiteName = nil
        super.tearDown()
    }

    private func plan(tombstone: Set<String> = [],
                      rejected: [String] = [],
                      quality: CalendarMirror.Quality = .init()) -> CalendarMirror.Plan {
        var p = CalendarMirror.Plan()
        p.tombstone = tombstone
        p.rejected = rejected.map {
            CalendarMirror.Entry(key: $0, title: $0, start: now, end: now)
        }
        p.quality = quality
        return p
    }

    // MARK: - Ran and found nothing, versus never ran

    func testARunThatWroteNothingStillCountsAsARun() {
        // The distinction the whole type exists for. Both leave the calendar exactly as
        // it was; only one of them is a fault.
        var status = CalendarMirrorStatus()
        XCTAssertFalse(status.hasRun)

        status.record(plan(), created: 0, updated: 0, deleted: 0,
                      failures: 0, lastError: nil, now: now)

        XCTAssertTrue(status.hasRun)
        XCTAssertEqual(status.lastRun, now)
        XCTAssertNil(status.lastChange, "nothing was written, so nothing changed")
    }

    func testWritingSetsTheChangeStamp() {
        var status = CalendarMirrorStatus()
        status.record(plan(), created: 3, updated: 1, deleted: 0,
                      failures: 0, lastError: nil, now: now)

        XCTAssertEqual(status.lastChange, now)
        XCTAssertEqual(status.created, 3)
        XCTAssertEqual(status.updated, 1)
    }

    func testCountsAccumulateAcrossRuns() {
        var status = CalendarMirrorStatus()
        status.record(plan(), created: 2, updated: 0, deleted: 0,
                      failures: 0, lastError: nil, now: now)
        status.record(plan(tombstone: ["k"]), created: 1, updated: 0, deleted: 1,
                      failures: 0, lastError: nil, now: now.addingTimeInterval(3600))

        XCTAssertEqual(status.created, 3)
        XCTAssertEqual(status.deleted, 1)
        XCTAssertEqual(status.tombstoned, 1)
    }

    func testTheQualityReadingIsTheLatestNotTheAverage() {
        // It describes the range the mirror covers right now. A fraction averaged over
        // three weeks of history answers a question nobody asked.
        var status = CalendarMirrorStatus()
        status.record(plan(quality: .init(named: 10, fellBack: 0, tooShort: 0)),
                      created: 10, updated: 0, deleted: 0, failures: 0, lastError: nil, now: now)
        status.record(plan(quality: .init(named: 1, fellBack: 3, tooShort: 0)),
                      created: 4, updated: 0, deleted: 0, failures: 0, lastError: nil,
                      now: now.addingTimeInterval(3600))

        XCTAssertEqual(status.quality.named, 1)
        XCTAssertEqual(status.quality.fellBack, 3)
    }

    // MARK: - Failure, and getting over it

    func testAFailureIsRecordedWithItsReason() {
        var status = CalendarMirrorStatus()
        status.record(plan(), created: 0, updated: 0, deleted: 0,
                      failures: 2, lastError: "That calendar is subscribed", now: now)

        XCTAssertEqual(status.failures, 2)
        XCTAssertEqual(status.lastError, "That calendar is subscribed")
        XCTAssertEqual(status.lastErrorAt, now)
    }

    func testASuccessfulWriteAfterAFailureClearsTheFault() {
        // A pill that stays red forever is a pill people stop reading.
        var status = CalendarMirrorStatus()
        status.record(plan(), created: 0, updated: 0, deleted: 0,
                      failures: 1, lastError: "nope", now: now)
        XCTAssertEqual(CalendarMirrorState.current(status: status, enabled: true, calendarID: "c"),
                       .failing(status))

        status.record(plan(), created: 1, updated: 0, deleted: 0,
                      failures: 0, lastError: nil, now: now.addingTimeInterval(3600))

        XCTAssertEqual(CalendarMirrorState.current(status: status, enabled: true, calendarID: "c"),
                       .working(status))
        XCTAssertEqual(status.failures, 1, "the history is kept even though the fault cleared")
    }

    // MARK: - The four states

    func testOffIsNotAFault() {
        XCTAssertEqual(CalendarMirrorState.current(status: CalendarMirrorStatus(),
                                                   enabled: false, calendarID: nil), .off)
        XCTAssertFalse(CalendarMirrorState.current(status: CalendarMirrorStatus(),
                                                   enabled: false, calendarID: nil).isFaulty)
    }

    func testWritingByHandWithTheTimerOffIsItsOwnState() {
        // The state the author's Mac was actually in: 56 events written by the toolbar
        // button, `calendarMirrorEnabled` never once written, a status object holding
        // the counts — and every screen asking "is the timer on?", getting no, and
        // drawing nothing. Off and off-but-you-have-been-using-it are not the same
        // thing to say to somebody.
        var status = CalendarMirrorStatus()
        status.record(plan(), created: 6, updated: 0, deleted: 0,
                      failures: 0, lastError: nil, now: now)

        let state = CalendarMirrorState.current(status: status, enabled: false, calendarID: nil)

        XCTAssertEqual(state, .manualOnly(status))
        XCTAssertFalse(state.isFaulty, "writing by hand is a way to use this, not a fault")
    }

    func testARemovalIsCountedWhetherOrNotItWasTombstoned() {
        // A press writes the event again rather than tombstoning it, so `tombstoned`
        // answers zero on a Mac where only the button is used. The retraction criterion
        // in CLAUDE.md §0 asks how often what mull wrote was not wanted, which is this
        // number and not that one.
        var status = CalendarMirrorStatus()
        status.record(plan(tombstone: [], rejected: ["a", "b"]), created: 2, updated: 0,
                      deleted: 0, failures: 0, lastError: nil, now: now)

        XCTAssertEqual(status.removedByUser, 2)
        XCTAssertEqual(status.tombstoned, 0)
    }

    func testOnWithNoCalendarIsAFault() {
        // The exact shape of a timer that fires every hour and returns immediately,
        // which is what two independent switches in a settings pane make easy to build.
        let state = CalendarMirrorState.current(status: CalendarMirrorStatus(),
                                                enabled: true, calendarID: nil)
        XCTAssertEqual(state, .noCalendar)
        XCTAssertTrue(state.isFaulty)
    }

    func testOnAndNotYetRunIsWaitingRatherThanWorking() {
        let state = CalendarMirrorState.current(status: CalendarMirrorStatus(),
                                                enabled: true, calendarID: "c")
        XCTAssertEqual(state, .waiting)
        XCTAssertFalse(state.isFaulty)
    }

    // MARK: - Persistence

    func testStatusSurvivesARelaunch() {
        var status = CalendarMirrorStatus()
        status.record(plan(quality: .init(named: 2, fellBack: 1, tooShort: 4)),
                      created: 2, updated: 0, deleted: 0, failures: 0, lastError: nil, now: now)
        status.save(to: store)

        XCTAssertEqual(CalendarMirrorStatus.load(from: store), status)
    }

    func testAnEmptyStoreLoadsAsNeverRun() {
        XCTAssertFalse(CalendarMirrorStatus.load(from: store).hasRun)
    }

    func testAStatusWrittenByAnOlderBuildKeepsItsCounts() {
        // This is what shipping a new field costs if nobody writes the decoder. The
        // synthesised one throws on the first missing key, `load()` catches it and
        // returns a fresh zero, and every count since the mirror was first used
        // disappears at the moment of an upgrade — silently, which is the exact
        // failure this type was added to end. The JSON below is the shape actually
        // found in `com.mull.app` on 2026-08-18.
        let legacy = """
            {"created":6,"updated":0,"deleted":0,"tombstoned":0,"failures":0,\
            "lastRun":808656467.248357,"lastChange":808656467.248357,\
            "quality":{"named":4,"fellBack":2,"tooShort":3}}
            """
        store.set(Data(legacy.utf8), forKey: CalendarMirrorStatus.storageKey)

        let loaded = CalendarMirrorStatus.load(from: store)

        XCTAssertEqual(loaded.created, 6)
        XCTAssertEqual(loaded.quality.named, 4)
        XCTAssertEqual(loaded.quality.fellBack, 2)
        XCTAssertEqual(loaded.quality.shortened, 0, "a field that did not exist reads as none of it")
        XCTAssertEqual(loaded.removedByUser, 0)
        XCTAssertNil(loaded.lastSweep, "never swept, rather than swept at the epoch")
        XCTAssertTrue(loaded.hasRun)
    }

    func testClearingForgetsEverything() {
        var status = CalendarMirrorStatus()
        status.record(plan(), created: 5, updated: 0, deleted: 0,
                      failures: 0, lastError: nil, now: now)
        status.save(to: store)

        CalendarMirrorStatus.clear(from: store)

        XCTAssertEqual(CalendarMirrorStatus.load(from: store), CalendarMirrorStatus())
    }
}
