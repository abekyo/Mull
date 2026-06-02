import Foundation
import GRDB
import os.log

private let logger = Logger(subsystem: "com.mull.app", category: "Database")

/// SQLite database layer using GRDB with WAL mode and FTS5 full-text search.
/// Uses DatabasePool for concurrent read/write (recording writes don't block mull reads).
/// All data stays local at ~/Library/Application Support/mull/mull.sqlite.
final class DatabaseService: Sendable {

    let dbPool: DatabasePool

    /// True when the primary database was unrecoverable and a fallback is in use.
    /// UI should show a warning when this is true.
    let isFallback: Bool

    /// Human-readable reason for fallback, if any.
    let fallbackReason: String?

    // MARK: - Init

    init() {
        let appSupport: URL
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            appSupport = dir.appendingPathComponent("mull", isDirectory: true)
        } else {
            appSupport = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".mull", isDirectory: true)
        }

        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create app support directory: \(error.localizedDescription)")
        }

        let dbPath = appSupport.appendingPathComponent("mull.sqlite").path

        // One-time migration from the pre-rename location
        // (~/Library/Application Support/Whatly/whatly.sqlite). Moves the DB and its
        // WAL/SHM sidecars so the user keeps their full recorded history.
        let fmMigrate = FileManager.default
        if !fmMigrate.fileExists(atPath: dbPath),
           let legacyDir = fmMigrate.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
               .appendingPathComponent("Whatly", isDirectory: true) {
            for suffix in ["", "-wal", "-shm"] {
                let old = legacyDir.appendingPathComponent("whatly.sqlite\(suffix)")
                let new = appSupport.appendingPathComponent("mull.sqlite\(suffix)")
                if fmMigrate.fileExists(atPath: old.path) {
                    try? fmMigrate.moveItem(at: old, to: new)
                }
            }
        }

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        }

        // Recovery strategy:
        //   1. Try opening existing DB
        //   2. If corrupted → rename to .corrupt-<timestamp>, create fresh DB at same path
        //   3. If fresh DB also fails → fallback to /tmp (last resort)

        var pool: DatabasePool?
        var usedFallback = false
        var reason: String?

        // Step 1: Try primary path
        do {
            pool = try DatabasePool(path: dbPath, configuration: config)
            // Integrity check — catch corruption early
            try pool!.read { db in
                let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
                if result != "ok" {
                    throw DatabaseError(message: "Integrity check failed: \(result ?? "unknown")")
                }
            }
        } catch {
            logger.error("Primary database failed: \(error.localizedDescription)")
            pool = nil

            // Step 2: Rename corrupted DB and create fresh one
            let fm = FileManager.default
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let corruptPath = dbPath + ".corrupt-\(timestamp)"

            for ext in ["", "-wal", "-shm"] {
                let src = dbPath + ext
                let dst = corruptPath + ext
                if fm.fileExists(atPath: src) {
                    do {
                        try fm.moveItem(atPath: src, toPath: dst)
                        logger.warning("Renamed corrupted file: \(src) → \(dst)")
                    } catch {
                        logger.error("Failed to rename corrupted DB: \(error.localizedDescription)")
                        try? fm.removeItem(atPath: src)
                    }
                }
            }

            do {
                pool = try DatabasePool(path: dbPath, configuration: config)
                reason = "Database was corrupted and has been reset. Previous data saved to \(corruptPath)"
                logger.warning("\(reason!)")
            } catch {
                logger.error("Fresh database creation also failed: \(error.localizedDescription)")
            }
        }

        // Step 3: Last resort — temporary location
        if pool == nil {
            let tmpPath = NSTemporaryDirectory() + "mull-fallback.sqlite"
            do {
                pool = try DatabasePool(path: tmpPath, configuration: config)
                usedFallback = true
                reason = "Database is running from a temporary location. Data will not persist across restarts."
                logger.fault("\(reason!)")
            } catch {
                fatalError("[mull] Cannot create database at all: \(error)")
            }
        }

        dbPool = pool!
        isFallback = usedFallback
        fallbackReason = reason

        do {
            try migrate(dbPath: dbPath, config: config)
        } catch {
            logger.fault("Database migration failed: \(error.localizedDescription)")
            // Migration failure on an existing DB likely means a schema conflict.
            // Back up the current DB and start fresh to avoid a permanently broken state.
            let fm = FileManager.default
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backupPath = dbPath + ".pre-migration-\(timestamp)"
            for ext in ["", "-wal", "-shm"] {
                try? fm.copyItem(atPath: dbPath + ext, toPath: backupPath + ext)
            }
            logger.warning("Pre-migration backup saved to \(backupPath)")

            // Attempt fresh DB at same path
            do {
                for ext in ["", "-wal", "-shm"] {
                    try? fm.removeItem(atPath: dbPath + ext)
                }
                let freshPool = try DatabasePool(path: dbPath, configuration: config)
                // Swap pool — requires reinit, so store in a mutable local first
                // Since dbPool is already assigned above, we re-migrate on the existing pool
                // after wiping tables. This path is rare (migration failure).
                try freshPool.write { db in
                    // Drop all existing tables/triggers/FTS to start clean
                    let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'")
                    for table in tables {
                        try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
                    }
                    let triggers = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='trigger'")
                    for trigger in triggers {
                        try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
                    }
                }
                try freshPool.close()
                // Re-open and migrate
                let reopened = try DatabasePool(path: dbPath, configuration: config)
                try Self.buildMigrator().migrate(reopened)
                try reopened.close()
                // The existing dbPool at the same path will see the new schema
                try Self.buildMigrator().migrate(dbPool)
                if fallbackReason == nil {
                    // Update reason through a workaround since these are let
                }
                logger.warning("Database reset after migration failure. Previous data backed up.")
            } catch {
                logger.fault("Could not recover from migration failure: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Schema Version

    /// Current schema version name (the last applied migration).
    var schemaVersion: String {
        (try? dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT MAX(identifier) FROM grdb_migrations")
        }) ?? "unknown"
    }

    // MARK: - Migration

    /// All migrations in one place. Append new migrations at the end — never modify existing ones.
    ///
    /// Rules for adding migrations:
    ///   1. Always append — never change an existing migration block
    ///   2. Use `ifNotExists: true` / `IF NOT EXISTS` for safety
    ///   3. Use `ALTER TABLE ... ADD COLUMN` with defaults for non-destructive column additions
    ///   4. Name format: "v{N}_{description}" (e.g. "v3_add_event_source_column")
    ///   5. Test locally by deleting the app's DB and re-launching
    private static func buildMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Don't erase DB on schema change in production.
        // In DEBUG, you can uncomment the next line to reset on each schema change:
        // migrator.eraseDatabaseOnSchemaChange = true

        migrator.registerMigration("v1_create_tables") { db in
            try db.create(table: "recording_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("eventType", .text).notNull()
                t.column("appName", .text)
                t.column("windowTitle", .text)
                t.column("textContent", .text)
            }

            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS recording_events_fts
                USING fts5(textContent, appName, windowTitle, content=recording_events, content_rowid=id)
            """)
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

            try db.create(table: "mull_lock") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("lastSummaryAt", .datetime)
                t.column("holderPID", .integer)
                t.column("sessionsSinceLast", .integer).notNull().defaults(to: 0)
            }

            try db.execute(sql: "INSERT INTO mull_lock (sessionsSinceLast) VALUES (0)")
        }

        migrator.registerMigration("v2_knowledge_entries") { db in
            try db.create(table: "knowledge_entries", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("topic", .text).notNull()
                t.column("decision", .text).notNull()
                t.column("reasoning", .text)
                t.column("rejected", .text)
                t.column("project", .text).notNull()
                t.column("relatedProjects", .text)
                t.column("tags", .text)
                t.column("sourceDate", .date).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_entries_fts
                USING fts5(topic, decision, reasoning, rejected, project, tags,
                           content=knowledge_entries, content_rowid=id)
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS knowledge_entries_ai AFTER INSERT ON knowledge_entries BEGIN
                    INSERT INTO knowledge_entries_fts(rowid, topic, decision, reasoning, rejected, project, tags)
                    VALUES (new.id, new.topic, new.decision, new.reasoning, new.rejected, new.project, new.tags);
                END
            """)
        }

        migrator.registerMigration("v3_predictions") { db in
            try db.create(table: "predictions", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull()
                t.column("project", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("statement", .text).notNull()
                t.column("dueAt", .datetime).notNull().indexed()
                t.column("outcome", .text).notNull().defaults(to: "pending")
                t.column("gradedAt", .datetime)
            }
        }

        // ── Future migrations go here ──
        // Example:
        //
        // migrator.registerMigration("v4_add_event_source") { db in
        //     try db.alter(table: "recording_events") { t in
        //         t.add(column: "source", .text).defaults(to: "local")
        //     }
        // }

        return migrator
    }

    private func migrate(dbPath: String, config: Configuration) throws {
        try Self.buildMigrator().migrate(dbPool)
    }

    // MARK: - FTS Rebuild

    /// Rebuild all FTS5 indexes. Call after data import or if search results seem stale.
    func rebuildFTSIndexes() {
        do {
            try dbPool.write { db in
                try db.execute(sql: "INSERT INTO recording_events_fts(recording_events_fts) VALUES('rebuild')")
                try db.execute(sql: "INSERT INTO daily_summaries_fts(daily_summaries_fts) VALUES('rebuild')")
                try db.execute(sql: "INSERT INTO knowledge_entries_fts(knowledge_entries_fts) VALUES('rebuild')")
            }
            logger.info("FTS indexes rebuilt successfully")
        } catch {
            logger.error("FTS rebuild failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Recording Events

    func insertEvent(_ event: RecordingEvent) {
        do {
            try dbPool.write { db in
                var r = event
                try r.insert(db)
            }
        } catch {
            logger.error("Failed to insert event: \(error.localizedDescription)")
        }
    }

    func eventCountToday() -> Int {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        do {
            return try dbPool.read { db in
                try RecordingEvent
                    .filter(Column("timestamp") >= startOfDay)
                    .fetchCount(db)
            }
        } catch {
            logger.warning("Failed to count today's events: \(error.localizedDescription)")
            return 0
        }
    }

    func fetchEvents(from start: Date, to end: Date) -> [RecordingEvent] {
        do {
            return try dbPool.read { db in
                try RecordingEvent
                    .filter(Column("timestamp") >= start && Column("timestamp") <= end)
                    .order(Column("timestamp"))
                    .fetchAll(db)
            }
        } catch {
            logger.warning("Failed to fetch events: \(error.localizedDescription)")
            return []
        }
    }

    func storageBytesToday() -> Int64 {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        do {
            return try dbPool.read { db in
                let row = try Row.fetchOne(db, sql: """
                    SELECT SUM(LENGTH(textContent)) as total
                    FROM recording_events
                    WHERE timestamp >= ?
                """, arguments: [startOfDay])
                return row?["total"] as? Int64 ?? 0
            }
        } catch {
            logger.warning("Failed to read storage bytes: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - Summaries

    /// Upsert: if a summary for this date already exists (e.g. "Summarize Now" twice),
    /// replace it with the newer version instead of silently failing.
    func insertSummary(_ summary: DailySummary) {
        do {
            try dbPool.write { db in
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
        } catch {
            logger.error("Failed to insert summary for \(summary.date): \(error.localizedDescription)")
        }
    }

    func fetchSummary(for date: Date) -> DailySummary? {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        do {
            return try dbPool.read { db in
                try DailySummary
                    .filter(Column("date") >= startOfDay && Column("date") < endOfDay)
                    .fetchOne(db)
            }
        } catch {
            logger.warning("Failed to fetch summary: \(error.localizedDescription)")
            return nil
        }
    }

    func fetchRecentSummaries(limit: Int) -> [DailySummary] {
        do {
            return try dbPool.read { db in
                try DailySummary
                    .order(Column("date").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            logger.warning("Failed to fetch recent summaries: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Search (FTS5)

    func searchSummaries(query: String) -> [DailySummary] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let ftsQuery = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { "\($0)*" }
            .joined(separator: " ")

        do {
            return try dbPool.read { db in
                try DailySummary.fetchAll(db, sql: """
                    SELECT daily_summaries.*
                    FROM daily_summaries
                    JOIN daily_summaries_fts ON daily_summaries.id = daily_summaries_fts.rowid
                    WHERE daily_summaries_fts MATCH ?
                    ORDER BY rank
                    LIMIT 50
                """, arguments: [ftsQuery])
            }
        } catch {
            logger.warning("Failed to search summaries: \(error.localizedDescription)")
            return []
        }
    }

    func searchEvents(query: String, limit: Int = 100) -> [RecordingEvent] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let ftsQuery = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { "\($0)*" }
            .joined(separator: " ")

        do {
            return try dbPool.read { db in
                try RecordingEvent.fetchAll(db, sql: """
                    SELECT recording_events.*
                    FROM recording_events
                    JOIN recording_events_fts ON recording_events.id = recording_events_fts.rowid
                    WHERE recording_events_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                """, arguments: [ftsQuery, limit])
            }
        } catch {
            logger.warning("Failed to search events: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Knowledge

    func insertKnowledge(_ entry: KnowledgeEntry) {
        do {
            try dbPool.write { db in
                var e = entry
                try e.insert(db)
            }
        } catch {
            logger.error("Failed to insert knowledge '\(entry.topic)': \(error.localizedDescription)")
        }
    }

    // MARK: - Predictions

    func insertPrediction(_ prediction: Prediction) {
        do {
            try dbPool.write { db in
                var p = prediction
                try p.insert(db)
            }
        } catch {
            logger.error("Failed to insert prediction for '\(prediction.project)': \(error.localizedDescription)")
        }
    }

    /// Pending predictions whose due time has passed — ready to grade.
    func fetchDuePredictions(asOf date: Date = Date()) -> [Prediction] {
        do {
            return try dbPool.read { db in
                try Prediction
                    .filter(Column("outcome") == "pending" && Column("dueAt") <= date)
                    .fetchAll(db)
            }
        } catch {
            logger.warning("Failed to fetch due predictions: \(error.localizedDescription)")
            return []
        }
    }

    /// Whether a pending prediction already exists for a project+kind (avoids dupes).
    func hasPendingPrediction(project: String, kind: String) -> Bool {
        do {
            return try dbPool.read { db in
                try Prediction
                    .filter(Column("outcome") == "pending"
                            && Column("project") == project
                            && Column("kind") == kind)
                    .fetchCount(db) > 0
            }
        } catch {
            return false
        }
    }

    func updatePrediction(_ prediction: Prediction) {
        do {
            try dbPool.write { db in
                try prediction.update(db)
            }
        } catch {
            logger.error("Failed to update prediction \(prediction.id ?? -1): \(error.localizedDescription)")
        }
    }

    /// Graded predictions created within the window, for hit-rate calculation.
    func fetchGradedPredictions(since: Date) -> [Prediction] {
        do {
            return try dbPool.read { db in
                try Prediction
                    .filter(Column("outcome") != "pending" && Column("createdAt") >= since)
                    .fetchAll(db)
            }
        } catch {
            logger.warning("Failed to fetch graded predictions: \(error.localizedDescription)")
            return []
        }
    }

    func fetchAllKnowledge() -> [KnowledgeEntry] {
        do {
            return try dbPool.read { db in
                try KnowledgeEntry
                    .order(Column("sourceDate").desc)
                    .fetchAll(db)
            }
        } catch {
            logger.warning("Failed to fetch knowledge: \(error.localizedDescription)")
            return []
        }
    }

    func fetchKnowledge(forProject project: String) -> [KnowledgeEntry] {
        let query = project.lowercased()
        do {
            return try dbPool.read { db in
                try KnowledgeEntry
                    .filter(Column("project").lowercased.like("%\(query)%")
                        || Column("relatedProjects").lowercased.like("%\(query)%"))
                    .order(Column("sourceDate").desc)
                    .fetchAll(db)
            }
        } catch {
            logger.warning("Failed to fetch knowledge for project '\(project)': \(error.localizedDescription)")
            return []
        }
    }

    func searchKnowledge(query: String, limit: Int = 20) -> [KnowledgeEntry] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let ftsQuery = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { "\($0)*" }
            .joined(separator: " ")

        do {
            return try dbPool.read { db in
                try KnowledgeEntry.fetchAll(db, sql: """
                    SELECT knowledge_entries.*
                    FROM knowledge_entries
                    JOIN knowledge_entries_fts ON knowledge_entries.id = knowledge_entries_fts.rowid
                    WHERE knowledge_entries_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                """, arguments: [ftsQuery, limit])
            }
        } catch {
            logger.warning("Failed to search knowledge: \(error.localizedDescription)")
            return []
        }
    }

    /// Find knowledge relevant to a given window title / file / topic.
    func findRelevantKnowledge(context: String, limit: Int = 3) -> [KnowledgeEntry] {
        let words = context.components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 3 }
            .prefix(5)
        guard !words.isEmpty else { return [] }
        let query = words.map { "\($0)*" }.joined(separator: " OR ")
        return searchKnowledge(query: query, limit: limit)
    }

    // MARK: - Memory

    func insertMemory(_ entry: MemoryEntry) {
        do {
            try dbPool.write { db in
                var e = entry
                try e.insert(db)
            }
        } catch {
            logger.error("Failed to insert memory '\(entry.name)': \(error.localizedDescription)")
        }
    }

    func fetchAllMemories() -> [MemoryEntry] {
        do {
            return try dbPool.read { db in
                try MemoryEntry
                    .order(Column("updatedAt").desc)
                    .fetchAll(db)
            }
        } catch {
            logger.warning("Failed to fetch memories: \(error.localizedDescription)")
            return []
        }
    }

    func updateMemory(_ entry: MemoryEntry) {
        do {
            try dbPool.write { db in
                try entry.update(db)
            }
        } catch {
            logger.error("Failed to update memory '\(entry.name)': \(error.localizedDescription)")
        }
    }

    // MARK: - mull Lock (3-Gate System)

    func fetchmullLock() -> mullLock? {
        do {
            return try dbPool.read { db in
                try mullLock.fetchOne(db)
            }
        } catch {
            logger.warning("Failed to fetch mull lock: \(error.localizedDescription)")
            return nil
        }
    }

    func updatemullLock(_ lock: mullLock) {
        do {
            try dbPool.write { db in
                try lock.update(db)
            }
        } catch {
            logger.error("Failed to update mull lock: \(error.localizedDescription)")
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
            logger.error("Failed to increment session count: \(error.localizedDescription)")
        }
    }

    // MARK: - Data Management

    func deleteAllData() throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM recording_events")
            try db.execute(sql: "DELETE FROM daily_summaries")
            try db.execute(sql: "DELETE FROM memory_entries")
            try db.execute(sql: "DELETE FROM knowledge_entries")
            try db.execute(sql: "DELETE FROM predictions")
            try db.execute(sql: "UPDATE mull_lock SET lastSummaryAt = NULL, sessionsSinceLast = 0")
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
        do {
            try dbPool.write { db in
                try db.execute(sql: "PRAGMA incremental_vacuum")
            }
        } catch {
            logger.warning("Vacuum failed: \(error.localizedDescription)")
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
