import Foundation
import GRDB

/// SQLite database layer using GRDB with WAL mode and FTS5 full-text search.
/// Uses DatabasePool for concurrent read/write (recording writes don't block Dream reads).
/// All data stays local at ~/Library/Application Support/Dream/dream.sqlite.
final class DatabaseService: Sendable {

    let dbPool: DatabasePool

    // MARK: - Init

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Dream", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        } catch {
            print("[Dream] Failed to create app support directory: \(error)")
        }

        let dbPath = appSupport.appendingPathComponent("dream.sqlite").path
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        }

        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: dbPath, configuration: config)
        } catch {
            print("[Whatly] DatabasePool init failed, using temporary: \(error)")
            let tmpPath = NSTemporaryDirectory() + "whatly-fallback.sqlite"
            do {
                pool = try DatabasePool(path: tmpPath, configuration: config)
            } catch {
                fatalError("[Whatly] Cannot create database at all: \(error)")
            }
        }
        dbPool = pool
        try? migrate()
    }

    // MARK: - Migration

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_tables") { db in
            // Recording events
            try db.create(table: "recording_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("eventType", .text).notNull()
                t.column("appName", .text)
                t.column("windowTitle", .text)
                t.column("textContent", .text)
            }

            // FTS5 for full-text search on recording events
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS recording_events_fts
                USING fts5(textContent, appName, windowTitle, content=recording_events, content_rowid=id)
            """)

            // Triggers to keep FTS in sync
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS recording_events_ai AFTER INSERT ON recording_events BEGIN
                    INSERT INTO recording_events_fts(rowid, textContent, appName, windowTitle)
                    VALUES (new.id, new.textContent, new.appName, new.windowTitle);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS recording_events_ad AFTER DELETE ON recording_events BEGIN
                    INSERT INTO recording_events_fts(recording_events_fts, rowid, textContent, appName, windowTitle)
                    VALUES ('delete', old.id, old.textContent, old.appName, old.windowTitle);
                END
            """)

            // Daily summaries
            try db.create(table: "daily_summaries") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date", .date).notNull().unique()
                t.column("content", .text).notNull()
                t.column("morningSection", .text)
                t.column("afternoonSection", .text)
                t.column("eveningSection", .text)
                t.column("learnings", .text)
                t.column("inProgress", .text)
                t.column("eventCount", .integer).notNull()
                t.column("processingSeconds", .double).notNull()
                t.column("llmProvider", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            // FTS for daily summaries
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS daily_summaries_fts
                USING fts5(content, learnings, inProgress, content=daily_summaries, content_rowid=id)
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS daily_summaries_ai AFTER INSERT ON daily_summaries BEGIN
                    INSERT INTO daily_summaries_fts(rowid, content, learnings, inProgress)
                    VALUES (new.id, new.content, new.learnings, new.inProgress);
                END
            """)

            // Memory entries
            try db.create(table: "memory_entries") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("description", .text).notNull()
                t.column("memoryType", .text).notNull()
                t.column("content", .text).notNull()
                t.column("filePath", .text).notNull().unique()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // Dream lock
            try db.create(table: "dream_lock") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("lastDreamAt", .datetime)
                t.column("holderPID", .integer)
                t.column("sessionsSinceLast", .integer).notNull().defaults(to: 0)
            }

            // Insert initial lock row
            try db.execute(sql: "INSERT INTO dream_lock (sessionsSinceLast) VALUES (0)")
        }

        try migrator.migrate(dbPool)
    }

    // MARK: - Recording Events

    func insertEvent(_ event: RecordingEvent) {
        try? dbPool.write { db in
            var r = event
            try r.insert(db)
        }
    }

    func eventCountToday() -> Int {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        return (try? dbPool.read { db in
            try RecordingEvent
                .filter(Column("timestamp") >= startOfDay)
                .fetchCount(db)
        }) ?? 0
    }

    func fetchEvents(from start: Date, to end: Date) -> [RecordingEvent] {
        (try? dbPool.read { db in
            try RecordingEvent
                .filter(Column("timestamp") >= start && Column("timestamp") <= end)
                .order(Column("timestamp"))
                .fetchAll(db)
        }) ?? []
    }

    func storageBytesToday() -> Int64 {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        return (try? dbPool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT SUM(LENGTH(textContent)) as total
                FROM recording_events
                WHERE timestamp >= ?
            """, arguments: [startOfDay])
            return row?["total"] as? Int64 ?? 0
        }) ?? 0
    }

    // MARK: - Summaries

    /// Upsert: if a summary for this date already exists (e.g. "Dream Now" twice),
    /// replace it with the newer version instead of silently failing.
    func insertSummary(_ summary: DailySummary) {
        try? dbPool.write { db in
            // Delete existing summary for same date first
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: summary.date)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
            try db.execute(
                sql: "DELETE FROM daily_summaries WHERE date >= ? AND date < ?",
                arguments: [startOfDay, endOfDay]
            )
            var s = summary
            try s.insert(db)
        }
    }

    func fetchSummary(for date: Date) -> DailySummary? {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        return try? dbPool.read { db in
            try DailySummary
                .filter(Column("date") >= startOfDay && Column("date") < endOfDay)
                .fetchOne(db)
        }
    }

    func fetchRecentSummaries(limit: Int) -> [DailySummary] {
        (try? dbPool.read { db in
            try DailySummary
                .order(Column("date").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    // MARK: - Search (FTS5)

    func searchSummaries(query: String) -> [DailySummary] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let ftsQuery = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { "\($0)*" }
            .joined(separator: " ")

        return (try? dbPool.read { db in
            try DailySummary.fetchAll(db, sql: """
                SELECT daily_summaries.*
                FROM daily_summaries
                JOIN daily_summaries_fts ON daily_summaries.id = daily_summaries_fts.rowid
                WHERE daily_summaries_fts MATCH ?
                ORDER BY rank
                LIMIT 50
            """, arguments: [ftsQuery])
        }) ?? []
    }

    func searchEvents(query: String, limit: Int = 100) -> [RecordingEvent] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let ftsQuery = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { "\($0)*" }
            .joined(separator: " ")

        return (try? dbPool.read { db in
            try RecordingEvent.fetchAll(db, sql: """
                SELECT recording_events.*
                FROM recording_events
                JOIN recording_events_fts ON recording_events.id = recording_events_fts.rowid
                WHERE recording_events_fts MATCH ?
                ORDER BY rank
                LIMIT ?
            """, arguments: [ftsQuery, limit])
        }) ?? []
    }

    // MARK: - Memory

    func insertMemory(_ entry: MemoryEntry) {
        try? dbPool.write { db in
            var e = entry
            try e.insert(db)
        }
    }

    func fetchAllMemories() -> [MemoryEntry] {
        (try? dbPool.read { db in
            try MemoryEntry
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }) ?? []
    }

    func updateMemory(_ entry: MemoryEntry) {
        try? dbPool.write { db in
            try entry.update(db)
        }
    }

    // MARK: - Dream Lock (3-Gate System)

    func fetchDreamLock() -> DreamLock? {
        try? dbPool.read { db in
            try DreamLock.fetchOne(db)
        }
    }

    func updateDreamLock(_ lock: DreamLock) {
        try? dbPool.write { db in
            try lock.update(db)
        }
    }

    func incrementSessionCount() {
        try? dbPool.write { db in
            try db.execute(sql: """
                UPDATE dream_lock SET sessionsSinceLast = sessionsSinceLast + 1
            """)
        }
    }

    // MARK: - Data Management

    func deleteAllData() throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM recording_events")
            try db.execute(sql: "DELETE FROM daily_summaries")
            try db.execute(sql: "DELETE FROM memory_entries")
            try db.execute(sql: "UPDATE dream_lock SET lastDreamAt = NULL, sessionsSinceLast = 0")
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
    func vacuum() {
        try? dbPool.write { db in
            try db.execute(sql: "PRAGMA incremental_vacuum")
        }
    }

    /// Actual database file size on disk (more accurate than summing text columns).
    func totalStorageBytes() -> Int64 {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Dream/dream.sqlite")

        let attrs = try? FileManager.default.attributesOfItem(atPath: appSupport.path)
        let mainSize = attrs?[.size] as? Int64 ?? 0

        // WAL file
        let walPath = appSupport.path + "-wal"
        let walAttrs = try? FileManager.default.attributesOfItem(atPath: walPath)
        let walSize = walAttrs?[.size] as? Int64 ?? 0

        return mainSize + walSize
    }
}
