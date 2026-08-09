import Foundation
import GRDB
import os.log

// The mull lock, bulk deletion, and time-scoped erasure.
//
// This is the destructive half of the database, kept together and away from
// everything else so that "what can delete the user's history" is one file long
// and easy to audit. `ForgetService` is the only broad consumer; it holds
// `DatabaseService` whole precisely because erasure legitimately spans every
// table, and narrowing it would be dishonest about what it does.
//
// Split out of DatabaseService.swift. Nothing here changed in the move.

extension DatabaseService {

    // MARK: - mull Lock (3-Gate System)

    func fetchmullLock() -> mullLock? {
        do {
            return try dbPool.read { db in
                try mullLock.fetchOne(db)
            }
        } catch {
            databaseLogger.warning("Failed to fetch mull lock: \(error.localizedDescription)")
            return nil
        }
    }

    func updatemullLock(_ lock: mullLock) {
        do {
            try dbPool.write { db in
                try lock.update(db)
            }
        } catch {
            databaseLogger.error("Failed to update mull lock: \(error.localizedDescription)")
        }
    }

    func incrementSessionCount() {
        do {
            try dbPool.write { db in
                try db.execute(sql: """
                    UPDATE mull_lock SET sessionsSinceLast = sessionsSinceLast + 1
                """)
            }
        } catch {
            databaseLogger.error("Failed to increment session count: \(error.localizedDescription)")
        }
    }

    // MARK: - Data Management

    /// Thrown when the tables are empty but a copy of the history is still on disk.
    /// Named separately from a write failure because the two need different words:
    /// here the live database really was cleared.
    struct ArchivesRemainError: LocalizedError {
        let paths: [String]
        var errorDescription: String? {
            let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            return "The database was cleared, but \(paths.count) quarantined "
                + "cop\(paths.count == 1 ? "y" : "ies") of your history could not be deleted "
                + "and \(paths.count == 1 ? "is" : "are") still on disk: \(names)."
        }
    }

    func deleteAllData() throws {
        try deleteAllTables()

        // The quarantined and drained copies beside the live file. Clearing the
        // tables used to be the whole of "delete everything" — and a `.corrupt-*`
        // or `.reattached-*` file is a complete, readable copy of everything mull
        // ever recorded, which nothing else deletes and which the confirmation
        // dialog's "This cannot be undone" quietly excluded. Inside `deleteAllData`
        // rather than at the call site so no future caller can mean "everything"
        // and get less than that.
        let failed = QuarantineRecovery.deleteArchives(besidePrimary: dbPool.path)
        guard failed.isEmpty else { throw ArchivesRemainError(paths: failed) }
    }

    private func deleteAllTables() throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM recording_events")
            try db.execute(sql: "DELETE FROM daily_summaries")
            try db.execute(sql: "DELETE FROM memory_entries")
            try db.execute(sql: "DELETE FROM knowledge_entries")
            try db.execute(sql: "DELETE FROM predictions")
            try db.execute(sql: "UPDATE mull_lock SET lastSummaryAt = NULL, sessionsSinceLast = 0")

            // The delete triggers (v7) evict each row's text as it goes, but an
            // explicit rebuild guarantees the shadow tables are empty even if a
            // trigger was missing when some row was written. "Delete all" has to
            // mean the text is gone from the file, not just from the base tables.
            try db.execute(sql: "INSERT INTO recording_events_fts(recording_events_fts) VALUES('rebuild')")
            try db.execute(sql: "INSERT INTO daily_summaries_fts(daily_summaries_fts) VALUES('rebuild')")
            try db.execute(sql: "INSERT INTO knowledge_entries_fts(knowledge_entries_fts) VALUES('rebuild')")
        }
    }

    /// Delete events recorded at or after `date` — backs Settings' "forget the
    /// last hour/today" actions, which previously ran raw SQL from the View.
    func deleteEvents(since date: Date) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM recording_events WHERE timestamp >= ?", arguments: [date])
        }
    }

    // MARK: - Forget (time-scoped erasure)
    //
    // Raw events are only the INPUT. Within 60 seconds mull derives context files
    // from them, and overnight it derives summaries, memories and knowledge. So a
    // forget that stops at `recording_events` erases the source and leaves every
    // conclusion drawn from it standing. These queries let ForgetService reach the
    // derived layers too — and, first, tell the user what is about to go.

    func deleteEvents(in interval: DateInterval) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM recording_events WHERE timestamp >= ? AND timestamp <= ?",
                           arguments: [interval.start, interval.end])
        }
    }

    /// Memories mull *formed* inside the window — these are conclusions about the
    /// user drawn from the events being erased, so they go with them.
    func fetchMemories(createdIn interval: DateInterval) -> [MemoryEntry] {
        do {
            return try dbPool.read { db in
                try MemoryEntry
                    .filter(Column("createdAt") >= interval.start && Column("createdAt") <= interval.end)
                    .fetchAll(db)
            }
        } catch {
            databaseLogger.warning("Failed to fetch memories created in window: \(error.localizedDescription)")
            return []
        }
    }

    /// Memories that predate the window but were *revised* inside it. Their text
    /// is a blend of the erased window and everything before it, and mull cannot
    /// unmix the two — so it keeps them and reports them rather than deleting a
    /// month of accumulated understanding to erase fifteen minutes of it.
    func fetchMemories(revisedIn interval: DateInterval) -> [MemoryEntry] {
        do {
            return try dbPool.read { db in
                try MemoryEntry
                    .filter(Column("updatedAt") >= interval.start && Column("updatedAt") <= interval.end)
                    .filter(Column("createdAt") < interval.start)
                    .fetchAll(db)
            }
        } catch {
            databaseLogger.warning("Failed to fetch memories revised in window: \(error.localizedDescription)")
            return []
        }
    }

    func deleteMemories(_ entries: [MemoryEntry]) throws {
        guard !entries.isEmpty else { return }
        try dbPool.write { db in
            for entry in entries {
                try db.execute(sql: "DELETE FROM memory_entries WHERE filePath = ?",
                               arguments: [entry.filePath])
            }
        }
    }

    /// Daily summaries whose subject day overlaps the window.
    func fetchSummaries(in interval: DateInterval) -> [DailySummary] {
        do {
            return try dbPool.read { db in
                try DailySummary
                    .filter(Column("date") >= Calendar.current.startOfDay(for: interval.start)
                            && Column("date") <= interval.end)
                    .order(Column("date").asc)
                    .fetchAll(db)
            }
        } catch {
            databaseLogger.warning("Failed to fetch summaries in window: \(error.localizedDescription)")
            return []
        }
    }

    func deleteSummaries(_ summaries: [DailySummary]) throws {
        guard !summaries.isEmpty else { return }
        try dbPool.write { db in
            for summary in summaries where summary.id != nil {
                try db.execute(sql: "DELETE FROM daily_summaries WHERE id = ?", arguments: [summary.id])
            }
        }
    }

    func countKnowledge(sourcedIn interval: DateInterval) -> Int {
        do {
            return try dbPool.read { db in
                try KnowledgeEntry
                    .filter(Column("sourceDate") >= interval.start && Column("sourceDate") <= interval.end)
                    .fetchCount(db)
            }
        } catch {
            databaseLogger.warning("Failed to count knowledge in window: \(error.localizedDescription)")
            return 0
        }
    }

    func deleteKnowledge(sourcedIn interval: DateInterval) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM knowledge_entries WHERE sourceDate >= ? AND sourceDate <= ?",
                           arguments: [interval.start, interval.end])
        }
    }

    func deleteEventsOlderThan(days: Int) throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM recording_events WHERE timestamp < ?", arguments: [cutoff])
        }
    }

    func deleteSummariesOlderThan(days: Int) throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM daily_summaries WHERE date < ?", arguments: [cutoff])
        }
    }

    /// Reclaim disk space after bulk deletes.
    ///
    /// `PRAGMA incremental_vacuum` only reclaims pages when the database was
    /// *created* with auto_vacuum = INCREMENTAL. Databases that predate that
    /// setting — including every `whatly.sqlite` migrated in at init — report
    /// auto_vacuum = NONE and silently ignore it, so the file never shrinks after
    /// a delete. Fall back to a full VACUUM for those.
    ///
    /// Returns whether the pages were actually reclaimed. Callers cleaning up
    /// after a *forget* must report a `false`: until the vacuum runs, the
    /// deleted text is still sitting in unreferenced pages of the file.
    @discardableResult
    func vacuum() -> Bool {
        do {
            let mode = try dbPool.read { db in
                try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0
            }
            if mode == 2 {   // INCREMENTAL
                try dbPool.write { db in
                    try db.execute(sql: "PRAGMA incremental_vacuum")
                }
            } else {
                // Full VACUUM rewrites the file, so it cannot run inside a
                // transaction — writeWithoutTransaction is required here.
                try dbPool.writeWithoutTransaction { db in
                    try db.execute(sql: "VACUUM")
                }
            }
            return true
        } catch {
            databaseLogger.warning("Vacuum failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Actual database file size on disk (more accurate than summing text columns).
    func totalStorageBytes() -> Int64 {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("mull/mull.sqlite") else { return 0 }

        let attrs = try? FileManager.default.attributesOfItem(atPath: appSupport.path)
        let mainSize = attrs?[.size] as? Int64 ?? 0

        // WAL file
        let walPath = appSupport.path + "-wal"
        let walAttrs = try? FileManager.default.attributesOfItem(atPath: walPath)
        let walSize = walAttrs?[.size] as? Int64 ?? 0

        return mainSize + walSize
    }
}
