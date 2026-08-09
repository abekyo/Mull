import XCTest
import GRDB
@testable import mull

/// The recovery path that puts back what `DatabaseService.init` moved aside.
///
/// These are written against the shapes actually found on disk when this was
/// discovered — 30 quarantine files, one holding 8,013 events beside a live
/// database holding 398, and an older one whose `recording_events` had six
/// columns where the live table has ten.
final class QuarantineRecoveryTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quarantine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var livePath: String { dir.appendingPathComponent("mull.sqlite").path }

    private func makeLive() throws -> DatabaseService {
        try DatabaseService(path: livePath)
    }

    /// A quarantine file with the CURRENT schema, holding `count` events.
    @discardableResult
    private func makeQuarantine(marker: String = ".corrupt-2026-08-08T17-02-18Z",
                                events: Int,
                                startingAt start: Date = Date(timeIntervalSince1970: 1_000_000)) throws -> String {
        let path = livePath + marker
        let db = try DatabaseService(path: path)
        for i in 0..<events {
            db.insertEvent(RecordingEvent(
                timestamp: start.addingTimeInterval(Double(i)),
                eventType: .clipboard,
                appName: "Code",
                windowTitle: "Notes — Mull",
                textContent: "quarantined note \(i)"))
        }
        try db.dbPool.close()
        return path
    }

    // MARK: - The case that was actually on disk

    func testRecoversEventsFromAQuarantinedDatabase() throws {
        try makeQuarantine(events: 8013)
        let live = try makeLive()
        live.insertEvent(RecordingEvent(timestamp: Date(), eventType: .clipboard,
                                        appName: "Code", windowTitle: "Notes — Mull",
                                        textContent: "something recorded after the reset"))

        let outcomes = QuarantineRecovery.reattachAll(into: live.dbPool, primaryPath: livePath)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNil(outcomes[0].skipped)
        XCTAssertEqual(outcomes[0].restored["recording_events"], 8013)

        let total = try live.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM recording_events") }
        XCTAssertEqual(total, 8014, "the 8,013 recovered events plus the one recorded after the reset")
    }

    /// Running twice must be a no-op. Rows are matched on content because both
    /// databases number their ids from 1 — ids collide while meaning nothing.
    func testReattachIsIdempotent() throws {
        let path = try makeQuarantine(events: 50)
        let live = try makeLive()

        _ = try QuarantineRecovery.reattach(file: path, into: live.dbPool)
        let afterFirst = try live.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM recording_events") }
        _ = try QuarantineRecovery.reattach(file: path, into: live.dbPool)
        let afterSecond = try live.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM recording_events") }

        XCTAssertEqual(afterFirst, 50)
        XCTAssertEqual(afterSecond, 50, "a second pass must not duplicate anything")
    }

    /// A row whose appName is NULL must still match itself. `NULL = NULL` is NULL
    /// in SQL, so without IFNULL on both sides these rows re-insert every launch.
    func testRowsWithNullColumnsDoNotDuplicate() throws {
        let path = livePath + ".corrupt-2026-07-18T16-46-09Z"
        let q = try DatabaseService(path: path)
        q.insertEvent(RecordingEvent(timestamp: Date(timeIntervalSince1970: 5_000),
                                     eventType: .keystroke, appName: nil,
                                     windowTitle: nil, textContent: "no app, no title"))
        try q.dbPool.close()

        let live = try makeLive()
        _ = try QuarantineRecovery.reattach(file: path, into: live.dbPool)
        _ = try QuarantineRecovery.reattach(file: path, into: live.dbPool)

        let total = try live.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM recording_events") }
        XCTAssertEqual(total, 1)
    }

    /// Events already present in the live database are left alone; only the
    /// missing ones come across.
    func testOnlyMissingRowsAreCopied() throws {
        let shared = RecordingEvent(timestamp: Date(timeIntervalSince1970: 9_000),
                                    eventType: .clipboard, appName: "Code",
                                    windowTitle: "Notes — Mull", textContent: "both have this")
        let path = livePath + ".corrupt-x"
        let q = try DatabaseService(path: path)
        q.insertEvent(shared)
        q.insertEvent(RecordingEvent(timestamp: Date(timeIntervalSince1970: 9_001),
                                     eventType: .clipboard, appName: "Code",
                                     windowTitle: "Notes — Mull", textContent: "only the quarantine has this"))
        try q.dbPool.close()

        let live = try makeLive()
        live.insertEvent(shared)

        let restored = try QuarantineRecovery.reattach(file: path, into: live.dbPool)
        XCTAssertEqual(restored["recording_events"], 1)
    }

    // MARK: - Schema drift
    //
    // mull.sqlite.pre-migration-2026-06-02 has six columns in recording_events;
    // the live table has ten. The intersection is what can be copied, and the
    // missing signal columns are exactly the null-valued case Selection already
    // recomputes.

    func testCopiesTheColumnIntersectionWhenTheQuarantineIsOlder() throws {
        let path = livePath + ".pre-migration-2026-06-02T07-30-53Z"
        // Build a v1-shaped database by hand: no entity/contentType/salience/mode.
        let old = try DatabasePool(path: path)
        try old.write { db in
            try db.execute(sql: """
                CREATE TABLE recording_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp DATETIME NOT NULL,
                    eventType TEXT NOT NULL,
                    appName TEXT,
                    windowTitle TEXT,
                    textContent TEXT)
                """)
            try db.execute(sql: """
                INSERT INTO recording_events (timestamp, eventType, appName, windowTitle, textContent)
                VALUES ('2026-06-02 07:00:00.000', 'clipboard', 'Code', 'Notes — Dream', 'an old note')
                """)
        }
        try old.close()

        let live = try makeLive()
        let restored = try QuarantineRecovery.reattach(file: path, into: live.dbPool)

        XCTAssertEqual(restored["recording_events"], 1)
        let row = try live.dbPool.read {
            try Row.fetchOne($0, sql: "SELECT textContent, entity, salience FROM recording_events")
        }
        XCTAssertEqual(row?["textContent"] as String?, "an old note")
        XCTAssertNil(row?["entity"] as String?, "columns the old file never had stay null")
        XCTAssertNil(row?["salience"] as Double?)
    }

    // MARK: - Safety

    /// A file that fails its own integrity check is left completely alone. Pulling
    /// rows out of a damaged b-tree is how one broken database becomes two.
    func testSkipsAFileThatFailsIntegrityCheck() throws {
        let path = livePath + ".corrupt-broken"
        try Data("this is not a database at all, not even slightly".utf8).write(to: URL(fileURLWithPath: path))

        let live = try makeLive()
        let outcomes = QuarantineRecovery.reattachAll(into: live.dbPool, primaryPath: livePath)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNotNil(outcomes[0].skipped)
        let total = try live.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM recording_events") }
        XCTAssertEqual(total, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "an unrecoverable file is left in place for the next attempt, never deleted")
    }

    /// Nothing is deleted, ever. A drained file is renamed so the scanner stops
    /// seeing it, and the bytes stay put in case the merge was wrong.
    func testDrainedFilesAreRenamedNotDeleted() throws {
        let path = try makeQuarantine(events: 3)
        let live = try makeLive()

        QuarantineRecovery.reattachAll(into: live.dbPool, primaryPath: livePath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(remaining.contains { $0.contains(".reattached-") },
                      "the file is renamed, not removed: \(remaining)")
        XCTAssertTrue(QuarantineRecovery.pendingFiles(besidePrimary: livePath).isEmpty,
                      "a drained file must not be picked up again")
    }

    /// Sidecars belong to their main file — returning them would drain each
    /// database three times.
    func testSidecarsAreNotTreatedAsSeparateDatabases() throws {
        let path = try makeQuarantine(events: 1)
        for ext in ["-wal", "-shm"] {
            try Data().write(to: URL(fileURLWithPath: path + ext))
        }
        XCTAssertEqual(QuarantineRecovery.pendingFiles(besidePrimary: livePath), [path])
    }

    /// Derived tables cost LLM calls to rebuild and memory entries are written by
    /// a person, so they come across too.
    func testRecoversSummariesAndMemoriesNotJustEvents() throws {
        let path = livePath + ".corrupt-with-derived"
        let q = try DatabaseService(path: path)
        q.insertSummary(DailySummary(date: Date(timeIntervalSince1970: 86_400), content: "a day",
                                     morningSection: nil, afternoonSection: nil, eveningSection: nil,
                                     learnings: nil, inProgress: nil, eventCount: 10,
                                     processingSeconds: 1, llmProvider: "off", createdAt: Date()))
        q.insertMemory(MemoryEntry(name: "handle", description: "the public name",
                                   memoryType: .user, content: "Abekyo",
                                   filePath: "memory/handle.md",
                                   createdAt: Date(), updatedAt: Date()))
        try q.dbPool.close()

        let live = try makeLive()
        let restored = try QuarantineRecovery.reattach(file: path, into: live.dbPool)

        XCTAssertEqual(restored["daily_summaries"], 1)
        XCTAssertEqual(restored["memory_entries"], 1)
    }

    /// Recovered events have to be findable, not merely present — the FTS index is
    /// maintained by triggers, and an INSERT that bypassed them would restore rows
    /// that `search` can never return.
    func testRecoveredEventsAreSearchable() throws {
        let path = livePath + ".corrupt-searchable"
        let q = try DatabaseService(path: path)
        q.insertEvent(RecordingEvent(timestamp: Date(), eventType: .clipboard, appName: "Code",
                                     windowTitle: "Notes — Mull",
                                     textContent: "quarantined thought about pagination"))
        try q.dbPool.close()

        let live = try makeLive()
        _ = try QuarantineRecovery.reattach(file: path, into: live.dbPool)

        XCTAssertFalse(live.searchEvents(query: "pagination").isEmpty,
                       "recovered rows must reach the FTS index, or they are invisible to search")
    }

    // MARK: - Erasure
    //
    // "Never destroy" is the right constraint for the recovery path above and the
    // wrong one for the delete paths: it protects the user from mull's error
    // handling, not from the user. These pin the half that was missing — the half
    // where "Delete everything" said "This cannot be undone" over as many complete
    // plaintext copies of the history as the app had ever quarantined.

    /// A drained file keeps the bytes under a new name. Nothing reads it again and
    /// nothing used to delete it.
    private func makeReattached(events: Int) throws -> String {
        try makeQuarantine(marker: ".reattached-2026-08-08T18-00-00Z-2026-08-08T17-02-18Z", events: events)
    }

    func testArchivedFilesFindsDrainedCopiesAsWellAsPendingOnes() throws {
        try makeQuarantine(events: 2)
        try makeReattached(events: 2)

        XCTAssertEqual(QuarantineRecovery.pendingFiles(besidePrimary: livePath).count, 1,
                       "a drained file must not be re-drained")
        XCTAssertEqual(QuarantineRecovery.archivedFiles(besidePrimary: livePath).count, 2,
                       "but erasure has to see both — they hold the same history")
    }

    func testDeleteArchivesRemovesEveryCopyAndItsSidecars() throws {
        try makeQuarantine(events: 3)
        try makeReattached(events: 3)

        let failed = QuarantineRecovery.deleteArchives(besidePrimary: livePath)

        XCTAssertTrue(failed.isEmpty, "could not delete: \(failed)")
        XCTAssertTrue(QuarantineRecovery.archivedFiles(besidePrimary: livePath).isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".corrupt-") || $0.contains(".reattached-") }
        XCTAssertTrue(leftovers.isEmpty, "sidecars left behind: \(leftovers)")
    }

    /// "Delete everything" has to mean the copies too — that is the whole finding.
    func testDeleteAllDataAlsoRemovesTheQuarantinedCopies() throws {
        try makeQuarantine(events: 5)
        let live = try makeLive()
        live.insertEvent(RecordingEvent(timestamp: Date(), eventType: .clipboard, appName: "Code",
                                        windowTitle: "Notes — Mull", textContent: "a live note"))

        try live.deleteAllData()

        XCTAssertTrue(QuarantineRecovery.archivedFiles(besidePrimary: livePath).isEmpty,
                      "a readable copy of the history survived 'delete everything'")
    }

    // MARK: - Scrubbing a window out of the copies

    /// A forget must reach the copies, or relaunching hands the window back: the
    /// pending file is merged into the live database on the next launch.
    func testScrubRemovesTheWindowFromAPendingQuarantine() throws {
        let day = Date(timeIntervalSince1970: 1_000_000)
        let path = try makeQuarantine(events: 10, startingAt: day)   // day … day+9s
        let window = DateInterval(start: day.addingTimeInterval(2), end: day.addingTimeInterval(5))

        let failed = QuarantineRecovery.scrub(interval: window, besidePrimary: livePath)
        XCTAssertTrue(failed.isEmpty, "could not scrub: \(failed)")

        let remaining = try DatabasePool(path: path).read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM recording_events") ?? 0
        }
        XCTAssertEqual(remaining, 6, "the four events inside the window should be gone")
    }

    /// And the text has to leave the file, not just the base table — an archive old
    /// enough to predate the v7 delete triggers keeps every word in its FTS content
    /// table otherwise.
    func testScrubbedTextIsNotLeftInTheArchivesSearchIndex() throws {
        let day = Date(timeIntervalSince1970: 2_000_000)
        let path = livePath + ".corrupt-fts"
        let q = try DatabaseService(path: path)
        q.insertEvent(RecordingEvent(timestamp: day, eventType: .clipboard, appName: "Code",
                                     windowTitle: "Notes — Mull",
                                     textContent: "the sentence that must be forgotten"))
        try q.dbPool.close()

        QuarantineRecovery.scrub(interval: DateInterval(start: day.addingTimeInterval(-60),
                                                       end: day.addingTimeInterval(60)),
                                 besidePrimary: livePath)

        let hits = try DatabasePool(path: path).read {
            try Int.fetchOne($0, sql: """
                SELECT COUNT(*) FROM recording_events_fts WHERE recording_events_fts MATCH 'forgotten'
                """) ?? 0
        }
        XCTAssertEqual(hits, 0, "the forgotten text is still reachable through the archive's index")
    }

    /// Everything outside the window stays. A forget of fifteen minutes must not
    /// take months of unrelated history with it — which is why this scrubs rather
    /// than deleting the file the way "delete everything" does.
    func testScrubLeavesEverythingOutsideTheWindowAlone() throws {
        let day = Date(timeIntervalSince1970: 3_000_000)
        let path = try makeQuarantine(marker: ".corrupt-keep", events: 6, startingAt: day)
        let window = DateInterval(start: day.addingTimeInterval(100), end: day.addingTimeInterval(200))

        QuarantineRecovery.scrub(interval: window, besidePrimary: livePath)

        let remaining = try DatabasePool(path: path).read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM recording_events") ?? 0
        }
        XCTAssertEqual(remaining, 6, "nothing was in the window, so nothing should have gone")
    }

    /// A file that cannot be opened is reported rather than silently skipped — the
    /// forget path stakes itself on never claiming a success it did not achieve.
    func testAnUnreadableArchiveIsReportedAsAFailure() throws {
        let path = livePath + ".corrupt-garbage"
        try Data("this is not a database".utf8).write(to: URL(fileURLWithPath: path))

        let failed = QuarantineRecovery.scrub(
            interval: DateInterval(start: Date(timeIntervalSince1970: 0), end: Date()),
            besidePrimary: livePath)

        XCTAssertEqual(failed, [path])
    }
}
