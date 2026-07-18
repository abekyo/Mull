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

        // Under XCTest the test host is the app, so AppState.init() constructs a
        // DatabaseService on every run — against the user's real recorded
        // history. Sandboxing happened to make that read-only, but the suite was
        // one entitlement change away from mutating real data. Redirect instead.
        let dbPath: String
        if MullDirectory.isRunningTests {
            dbPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("mull-test-\(ProcessInfo.processInfo.processIdentifier).sqlite")
                .path
        } else {
            dbPath = appSupport.appendingPathComponent("mull.sqlite").path
        }

        // One-time migration from the pre-rename location
        // (~/Library/Application Support/Whatly/whatly.sqlite). Moves the DB and its
        // WAL/SHM sidecars so the user keeps their full recorded history.
        // Skipped under test: the redirected temp path never exists, so this
        // would otherwise fire on every test run and move the user's real legacy
        // database out from under them.
        let fmMigrate = FileManager.default
        if !MullDirectory.isRunningTests,
           !fmMigrate.fileExists(atPath: dbPath),
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

        // Step 3: Last resort — temporary location. Try a stable name first, then a
        // unique one (the stable path may itself be an unwritable leftover).
        if pool == nil {
            for tmpPath in [NSTemporaryDirectory() + "mull-fallback.sqlite",
                            NSTemporaryDirectory() + "mull-fallback-\(UUID().uuidString).sqlite"] {
                if let p = try? DatabasePool(path: tmpPath, configuration: config) {
                    pool = p
                    usedFallback = true
                    reason = "Database is running from a temporary location. Data will not persist across restarts."
                    logger.fault("\(reason!)")
                    break
                }
            }
        }

        guard var activePool = pool else {
            // Nothing is writable — Application Support, the primary path, and the
            // temp directory all failed. There is no honest way to continue.
            fatalError("[mull] Cannot create a database at any location. Disk full or permissions denied.")
        }

        // Serialize migration across processes. The app and the MullMCP binary
        // each open this same file at startup, so without a lock both can run
        // ALTER TABLE at once: one gets SQLITE_BUSY, fails, and drops into the
        // destructive recovery path below while the other is still attached.
        // flock is advisory, but every entrant is ours, and the kernel releases
        // it if a holder dies. The migrator is idempotent, so the process that
        // waits simply finds nothing left to apply.
        let migrationLock = Self.acquireMigrationLock(dbPath: dbPath)
        defer { Self.releaseMigrationLock(migrationLock) }

        // Migrate BEFORE publishing the pool. On failure the pool must be closed
        // before the files are touched: unlinking a database that an open
        // DatabasePool still holds leaves the app writing to a deleted inode
        // (the data looks recorded, then vanishes on next launch).
        do {
            try Self.buildMigrator().migrate(activePool)
        } catch {
            logger.fault("Database migration failed: \(error.localizedDescription)")
            let fm = FileManager.default
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backupPath = dbPath + ".pre-migration-\(timestamp)"

            try? activePool.close()

            // Move aside rather than copy-then-delete: the move IS the backup, and
            // it is atomic where copying a live WAL database is not.
            var movedAside = false
            for ext in ["", "-wal", "-shm"] where fm.fileExists(atPath: dbPath + ext) {
                do {
                    try fm.moveItem(atPath: dbPath + ext, toPath: backupPath + ext)
                    movedAside = true
                } catch {
                    logger.error("Could not move aside \(dbPath + ext): \(error.localizedDescription)")
                }
            }

            do {
                let freshPool = try DatabasePool(path: dbPath, configuration: config)
                try Self.buildMigrator().migrate(freshPool)
                activePool = freshPool
                reason = movedAside
                    ? "The database schema could not be upgraded, so mull started a new one. Your previous data is saved at \(backupPath)."
                    : "The database schema could not be upgraded and has been reset."
                logger.warning("\(reason!)")
            } catch {
                logger.fault("Could not recover from migration failure: \(error.localizedDescription)")
                reason = "The database schema is broken and could not be reset: \(error.localizedDescription)"
                // Re-open the original so the app still runs read-mostly rather than
                // dying; the schema is stale but the user's data is intact.
                if let reopened = try? DatabasePool(path: backupPath, configuration: config) {
                    activePool = reopened
                } else if let reopened = try? DatabasePool(path: dbPath, configuration: config) {
                    activePool = reopened
                } else {
                    fatalError("[mull] Database is unusable after a failed migration: \(error)")
                }
            }
        }

        dbPool = activePool
        isFallback = usedFallback
        fallbackReason = reason
    }

    // MARK: - Cross-process migration lock

    /// Take an exclusive advisory lock on `<dbPath>.migrate.lock`, blocking until
    /// it is available. Returns -1 if the lock could not be taken, in which case
    /// the caller proceeds unlocked — a possible race is still better than
    /// refusing to start.
    private static func acquireMigrationLock(dbPath: String) -> Int32 {
        let fd = open(dbPath + ".migrate.lock", O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            logger.warning("Could not open the migration lock; migrating unlocked.")
            return -1
        }
        if flock(fd, LOCK_EX) != 0 {
            logger.warning("Could not take the migration lock; migrating unlocked.")
            close(fd)
            return -1
        }
        return fd
    }

    private static func releaseMigrationLock(_ fd: Int32) {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// Open a database at an explicit path, with the same schema and pragmas as
    /// the real one but none of the recovery/fallback machinery.
    ///
    /// This exists so tests never touch the user's actual recorded history.
    /// They used to construct `DatabaseService()` — the live database — and call
    /// `deleteAllData()` in `setUp`, which destroys everything mull has recorded
    /// on any machine where that file is writable.
    init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        }
        let pool = try DatabasePool(path: path, configuration: config)
        try Self.buildMigrator().migrate(pool)

        dbPool = pool
        isFallback = false
        fallbackReason = nil
    }

    /// A throwaway database in a unique temp directory, for tests.
    static func temporary() throws -> DatabaseService {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mull-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DatabaseService(path: dir.appendingPathComponent("test.sqlite").path)
    }

    // MARK: - Schema Version

    /// The identifier of the newest migration this build knows how to apply.
    /// `schemaVersion` should equal this after a successful migration.
    static var latestMigrationIdentifier: String {
        buildMigrator().migrations.last ?? "unknown"
    }

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

        migrator.registerMigration("v4_lock_acquired_at") { db in
            try db.alter(table: "mull_lock") { t in
                t.add(column: "acquiredAt", .datetime)
            }
        }

        migrator.registerMigration("v5_event_signal_columns") { db in
            // Capture-time enrichment for the selection layer (#4): entity, a
            // content kind, and a salience score, stored on the row instead of
            // recomputed per query. Indexed so facet filtering can move to SQL.
            try db.alter(table: "recording_events") { t in
                t.add(column: "entity", .text).indexed()
                t.add(column: "contentType", .text).indexed()
                t.add(column: "salience", .double)
            }
        }

        migrator.registerMigration("v6_event_mode_column") { db in
            // The MODE axis (MAP-ARCHITECTURE.md): how a moment is engaged with —
            // produce/consume/decide/think/research/communicate. Stored next to the
            // other capture-time enrichment; recomputed for pre-migration rows.
            try db.alter(table: "recording_events") { t in
                t.add(column: "mode", .text).indexed()
            }
        }

        migrator.registerMigration("v7_fts_delete_triggers") { db in
            // daily_summaries and knowledge_entries shipped with an AFTER INSERT
            // trigger only, so deleting a row left its tokenized text in the FTS
            // shadow table forever — including after "Delete All Data". Add the
            // missing delete/update triggers, then rebuild to purge the orphans
            // already accumulated.
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS daily_summaries_ad AFTER DELETE ON daily_summaries BEGIN
                    INSERT INTO daily_summaries_fts(daily_summaries_fts, rowid, content, learnings, inProgress)
                    VALUES ('delete', old.id, old.content, old.learnings, old.inProgress);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS daily_summaries_au AFTER UPDATE ON daily_summaries BEGIN
                    INSERT INTO daily_summaries_fts(daily_summaries_fts, rowid, content, learnings, inProgress)
                    VALUES ('delete', old.id, old.content, old.learnings, old.inProgress);
                    INSERT INTO daily_summaries_fts(rowid, content, learnings, inProgress)
                    VALUES (new.id, new.content, new.learnings, new.inProgress);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS knowledge_entries_ad AFTER DELETE ON knowledge_entries BEGIN
                    INSERT INTO knowledge_entries_fts(knowledge_entries_fts, rowid, topic, decision, reasoning, rejected, project, tags)
                    VALUES ('delete', old.id, old.topic, old.decision, old.reasoning, old.rejected, old.project, old.tags);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS knowledge_entries_au AFTER UPDATE ON knowledge_entries BEGIN
                    INSERT INTO knowledge_entries_fts(knowledge_entries_fts, rowid, topic, decision, reasoning, rejected, project, tags)
                    VALUES ('delete', old.id, old.topic, old.decision, old.reasoning, old.rejected, old.project, old.tags);
                    INSERT INTO knowledge_entries_fts(rowid, topic, decision, reasoning, rejected, project, tags)
                    VALUES (new.id, new.topic, new.decision, new.reasoning, new.rejected, new.project, new.tags);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS recording_events_au AFTER UPDATE ON recording_events BEGIN
                    INSERT INTO recording_events_fts(recording_events_fts, rowid, textContent, appName, windowTitle)
                    VALUES ('delete', old.id, old.textContent, old.appName, old.windowTitle);
                    INSERT INTO recording_events_fts(rowid, textContent, appName, windowTitle)
                    VALUES (new.id, new.textContent, new.appName, new.windowTitle);
                END
            """)

            // Purge text belonging to rows that were deleted before the triggers existed.
            try db.execute(sql: "INSERT INTO daily_summaries_fts(daily_summaries_fts) VALUES('rebuild')")
            try db.execute(sql: "INSERT INTO knowledge_entries_fts(knowledge_entries_fts) VALUES('rebuild')")
        }

        migrator.registerMigration("v8_drop_unused_signal_indexes") { db in
            // v5/v6 indexed entity/contentType/mode with the stated intent of
            // moving facet filtering into SQL. That never happened: no query in
            // the codebase filters on these columns — `fetchCandidates` narrows
            // by timestamp/FTS and `Selection` facets in Swift, deliberately, so
            // that rows written before the columns existed still match via
            // recompute. Three B-trees on a multi-million-row table were being
            // maintained on every captured event for zero reads.
            //
            // Bring them back together with the query that uses them.
            for name in ["recording_events_on_entity",
                         "recording_events_on_contentType",
                         "recording_events_on_mode"] {
                try db.execute(sql: "DROP INDEX IF EXISTS \(name)")
            }
        }

        // ── Future migrations go here ──
        // Example:
        //
        // migrator.registerMigration("v5_add_event_source") { db in
        //     try db.alter(table: "recording_events") { t in
        //         t.add(column: "source", .text).defaults(to: "local")
        //     }
        // }

        return migrator
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
                let r = event
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
                let s = summary
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

    /// True when the string contains kana or CJK ideographs.
    ///
    /// FTS5's default `unicode61` tokenizer treats every CJK codepoint as a token
    /// character, so a contiguous Japanese run indexes as ONE token: 「今日の会議のメモ」
    /// is a single term. A substring query like 会議 therefore can never
    /// prefix-match it, and FTS silently returns nothing. Those queries take the
    /// LIKE path against the base table instead.
    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            (0x3040...0x30FF).contains(u.value) ||   // hiragana + katakana
            (0x3400...0x4DBF).contains(u.value) ||   // CJK extension A
            (0x4E00...0x9FFF).contains(u.value) ||   // CJK unified ideographs
            (0xF900...0xFAFF).contains(u.value)      // CJK compatibility
        }
    }

    /// Build a safe FTS5 MATCH expression, or nil if the query has no usable terms.
    ///
    /// Terms are reduced to alphanumerics and quoted, so user punctuation — `"`,
    /// `(`, `-`, `:`, or a bare AND/OR/NOT/NEAR — cannot produce a syntax error.
    /// Unquoted, `re-render` or `main()` threw, got swallowed by the catch, and
    /// surfaced to the user as "no results".
    static func ftsMatchExpression(_ query: String) -> String? {
        let terms = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Escape a string for use inside a LIKE pattern with `ESCAPE '\'`.
    static func likePattern(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    func searchSummaries(query: String) -> [DailySummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            return try dbPool.read { db in
                if Self.containsCJK(trimmed) {
                    let p = Self.likePattern(trimmed)
                    return try DailySummary.fetchAll(db, sql: """
                        SELECT * FROM daily_summaries
                        WHERE content LIKE ? ESCAPE '\\'
                           OR learnings LIKE ? ESCAPE '\\'
                           OR inProgress LIKE ? ESCAPE '\\'
                        ORDER BY date DESC
                        LIMIT 50
                    """, arguments: [p, p, p])
                }
                guard let match = Self.ftsMatchExpression(trimmed) else { return [] }
                return try DailySummary.fetchAll(db, sql: """
                    SELECT daily_summaries.*
                    FROM daily_summaries
                    JOIN daily_summaries_fts ON daily_summaries.id = daily_summaries_fts.rowid
                    WHERE daily_summaries_fts MATCH ?
                    ORDER BY rank
                    LIMIT 50
                """, arguments: [match])
            }
        } catch {
            logger.warning("Failed to search summaries: \(error.localizedDescription)")
            return []
        }
    }

    /// Candidate fetch for the selection layer (#4): narrows by time and, when
    /// `useFTS` is set, by full-text match — pushing the heavy reduction into
    /// SQLite instead of loading the whole window into memory. Entity/type
    /// faceting and ranking then run in `Selection` over this smaller set (so
    /// rows recorded before the v5 backfill still match via recompute).
    /// FTS terms are reduced to alphanumerics, so a query can't break FTS syntax.
    func fetchCandidates(query: String, since: Date, useFTS: Bool, limit: Int) -> [RecordingEvent] {
        let terms = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        do {
            return try dbPool.read { db in
                if useFTS && !terms.isEmpty {
                    let match = terms.map { "\($0)*" }.joined(separator: " ")
                    return try RecordingEvent.fetchAll(db, sql: """
                        SELECT recording_events.*
                        FROM recording_events
                        JOIN recording_events_fts ON recording_events.id = recording_events_fts.rowid
                        WHERE recording_events_fts MATCH ? AND recording_events.timestamp >= ?
                        ORDER BY rank
                        LIMIT ?
                    """, arguments: [match, since, limit])
                }
                return try RecordingEvent
                    .filter(Column("timestamp") >= since)
                    .order(Column("timestamp").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            logger.warning("fetchCandidates failed: \(error.localizedDescription)")
            return []
        }
    }

    func searchEvents(query: String, limit: Int = 100) -> [RecordingEvent] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            return try dbPool.read { db in
                if Self.containsCJK(trimmed) {
                    // Walks the timestamp index newest-first and stops at LIMIT.
                    let p = Self.likePattern(trimmed)
                    return try RecordingEvent.fetchAll(db, sql: """
                        SELECT * FROM recording_events
                        WHERE textContent LIKE ? ESCAPE '\\'
                           OR windowTitle LIKE ? ESCAPE '\\'
                           OR appName LIKE ? ESCAPE '\\'
                        ORDER BY timestamp DESC
                        LIMIT ?
                    """, arguments: [p, p, p, limit])
                }
                guard let match = Self.ftsMatchExpression(trimmed) else { return [] }
                return try RecordingEvent.fetchAll(db, sql: """
                    SELECT recording_events.*
                    FROM recording_events
                    JOIN recording_events_fts ON recording_events.id = recording_events_fts.rowid
                    WHERE recording_events_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                """, arguments: [match, limit])
            }
        } catch {
            logger.warning("Failed to search events: \(error.localizedDescription)")
            return []
        }
    }

    /// Count events in a window without materializing them.
    ///
    /// The nightly gate used to call `fetchEvents` (SELECT *, every row decoded
    /// into a struct including textContent) purely to compare `.count` against a
    /// threshold — a full-table scan into memory on every check.
    func countEvents(from start: Date, to end: Date) -> Int {
        do {
            return try dbPool.read { db in
                try RecordingEvent
                    .filter(Column("timestamp") >= start && Column("timestamp") <= end)
                    .fetchCount(db)
            }
        } catch {
            logger.warning("Failed to count events: \(error.localizedDescription)")
            return 0
        }
    }

    /// Per-day event counts over a range, aggregated in SQL.
    ///
    /// Backs the calendar's month/year heat grid, which previously fetched every
    /// row of the range (a full year ≈ 1.5M rows with their text) just to bucket
    /// them by day. Keys are start-of-day in the current calendar.
    func dailyEventCounts(from start: Date, to end: Date) -> [Date: Int] {
        do {
            return try dbPool.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT date(timestamp) AS day, COUNT(*) AS n
                    FROM recording_events
                    WHERE timestamp >= ? AND timestamp <= ?
                    GROUP BY day
                """, arguments: [start, end])

                let parser = DateFormatter()
                parser.dateFormat = "yyyy-MM-dd"
                parser.timeZone = TimeZone(identifier: "UTC")
                parser.locale = Locale(identifier: "en_US_POSIX")

                var out: [Date: Int] = [:]
                for row in rows {
                    guard let day: String = row["day"],
                          let parsed = parser.date(from: day) else { continue }
                    // date() operates on the stored UTC string; re-anchor to the
                    // local day so callers can key by Calendar.startOfDay.
                    out[Calendar.current.startOfDay(for: parsed)] = row["n"] ?? 0
                }
                return out
            }
        } catch {
            logger.warning("Failed to aggregate daily counts: \(error.localizedDescription)")
            return [:]
        }
    }

    // MARK: - Knowledge

    func insertKnowledge(_ entry: KnowledgeEntry) {
        do {
            try dbPool.write { db in
                let e = entry
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
                let p = prediction
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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            return try dbPool.read { db in
                if Self.containsCJK(trimmed) {
                    let p = Self.likePattern(trimmed)
                    return try KnowledgeEntry.fetchAll(db, sql: """
                        SELECT * FROM knowledge_entries
                        WHERE topic LIKE ? ESCAPE '\\'
                           OR decision LIKE ? ESCAPE '\\'
                           OR reasoning LIKE ? ESCAPE '\\'
                           OR project LIKE ? ESCAPE '\\'
                           OR tags LIKE ? ESCAPE '\\'
                        ORDER BY sourceDate DESC
                        LIMIT ?
                    """, arguments: [p, p, p, p, p, limit])
                }
                guard let match = Self.ftsMatchExpression(trimmed) else { return [] }
                return try KnowledgeEntry.fetchAll(db, sql: """
                    SELECT knowledge_entries.*
                    FROM knowledge_entries
                    JOIN knowledge_entries_fts ON knowledge_entries.id = knowledge_entries_fts.rowid
                    WHERE knowledge_entries_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                """, arguments: [match, limit])
            }
        } catch {
            logger.warning("Failed to search knowledge: \(error.localizedDescription)")
            return []
        }
    }

    /// Find knowledge relevant to a given window title / file / topic.
    ///
    /// This used to hand `searchKnowledge` a pre-built expression ("swift* OR
    /// chart*"), which then appended `*` to every whitespace-separated component —
    /// producing `swift** OR* chart**`, an FTS5 syntax error that was caught and
    /// returned as an empty array. The feature never once returned a result.
    /// Terms are now passed as plain words and the OR is built here.
    func findRelevantKnowledge(context: String, limit: Int = 3) -> [KnowledgeEntry] {
        let words = context.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
            .prefix(5)
        guard !words.isEmpty else { return [] }

        let match = words.map { "\"\($0)\"*" }.joined(separator: " OR ")
        do {
            return try dbPool.read { db in
                try KnowledgeEntry.fetchAll(db, sql: """
                    SELECT knowledge_entries.*
                    FROM knowledge_entries
                    JOIN knowledge_entries_fts ON knowledge_entries.id = knowledge_entries_fts.rowid
                    WHERE knowledge_entries_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                """, arguments: [match, limit])
            }
        } catch {
            logger.warning("findRelevantKnowledge failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Memory

    func insertMemory(_ entry: MemoryEntry) {
        do {
            try dbPool.write { db in
                let e = entry
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
    func vacuum() {
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
