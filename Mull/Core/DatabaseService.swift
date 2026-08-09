import Foundation
import GRDB
import os.log

/// Shared by every DatabaseService file. Internal rather than file-private
/// because the storage layer is now four files and they all log as "Database".
let databaseLogger = Logger(subsystem: "com.mull.app", category: "Database")

/// SQLite database layer using GRDB with WAL mode and FTS5 full-text search.
/// Uses DatabasePool for concurrent read/write (recording writes don't block mull reads).
/// All data stays local at ~/Library/Application Support/mull/mull.sqlite.
final class DatabaseService: Sendable {

    let dbPool: DatabasePool

    /// Where the live file actually is. Not `primaryDatabasePath()`: the recovery
    /// paths can land the pool on the pre-migration backup or on the temp
    /// fallback, and anything reasoning about files *beside* the database — the
    /// quarantined copies, above all — has to look beside the real one.
    var databaseFilePath: String { dbPool.path }

    /// True when the primary database was unrecoverable and a fallback is in use.
    /// UI should show a warning when this is true.
    let isFallback: Bool

    /// Human-readable reason for fallback, if any.
    let fallbackReason: String?

    /// True when this handle cannot write. Only `openReadOnly` produces one.
    /// Write methods check it and refuse rather than throwing from inside GRDB,
    /// so a mistake reads as "MullMCP tried to write" and not "SQLITE_READONLY".
    let isReadOnly: Bool

    // MARK: - Init

    /// Where the live database lives. Shared by the read-write owner (the app)
    /// and the read-only reader (MullMCP), so the two cannot drift onto different
    /// files — which would look exactly like "mull knows nothing about today".
    static func applicationSupportDirectory() -> URL {
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return dir.appendingPathComponent("mull", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mull", isDirectory: true)
    }

    /// Under XCTest the test host is the app, so `AppState.init()` constructs a
    /// DatabaseService on every run — against the user's real recorded history.
    /// Sandboxing happened to make that read-only, but the suite was one
    /// entitlement change away from mutating real data. Redirect instead.
    static func primaryDatabasePath() -> String {
        if MullDirectory.isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("mull-test-\(ProcessInfo.processInfo.processIdentifier).sqlite")
                .path
        }
        return applicationSupportDirectory().appendingPathComponent("mull.sqlite").path
    }

    init() {
        let appSupport = Self.applicationSupportDirectory()

        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        } catch {
            databaseLogger.error("Failed to create app support directory: \(error.localizedDescription)")
        }
        // Owner-only, for the same reason the files are (FilePrivacy): the database
        // itself is 0600, but the quarantined copies beside it are named after the
        // day they were quarantined, and a 0755 directory hands another account on
        // the machine that list for free.
        FilePrivacy.protectDirectory(at: appSupport)

        let dbPath = Self.primaryDatabasePath()

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

        let config = Self.poolConfiguration()

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
                    throw DatabaseError(resultCode: .SQLITE_CORRUPT,
                                        message: "Integrity check failed: \(result ?? "unknown")")
                }
            }
        } catch {
            databaseLogger.error("Primary database failed: \(error.localizedDescription)")
            pool = nil

            // Quarantine ONLY on true corruption. Any other failure (lock
            // contention, sandbox denial, out of disk) is transient: renaming
            // the primary DB away would destroy the user's history over a
            // recoverable error — which is exactly what happened on
            // 2026-07-18, when concurrent test runs quarantined the real DB
            // eight times in 36 minutes and every "corrupt" file later passed
            // integrity_check. Leave the files untouched and use the
            // temporary fallback below instead.
            let resultCode = (error as? DatabaseError)?.resultCode
            let claimsCorruption = resultCode == .SQLITE_CORRUPT || resultCode == .SQLITE_NOTADB
            // SQLITE_CORRUPT is not proof of corruption. A second process attached
            // to the same WAL — the app plus a test host, the app plus MullMCP —
            // can make a reader see a page it cannot reconcile, and SQLite reports
            // that with the same code as a genuinely damaged file. Both quarantines
            // this database has suffered (2026-07-18, 2026-08-08) were that: eight
            // files in 36 minutes the first time, 8,013 events the second, and
            // every quarantined file passed `integrity_check` afterwards.
            //
            // So the claim is checked before it is acted on: drop the connection,
            // let the other process settle, and open again from scratch. A file
            // that is actually corrupt fails the same way twice. One that was
            // merely being shared comes back.
            var isCorruption = false
            if claimsCorruption {
                if let recovered = Self.reopenAfterCorruptionClaim(at: dbPath, config: config) {
                    pool = recovered
                    databaseLogger.warning("Corruption reported but not reproduced on a fresh connection — primary database kept")
                } else {
                    isCorruption = true
                }
            } else {
                databaseLogger.error("Failure is not corruption — primary database left untouched; using temporary fallback")
            }

            if isCorruption {
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
                            databaseLogger.warning("Renamed corrupted file: \(src) → \(dst)")
                        } catch {
                            databaseLogger.error("Failed to rename corrupted DB: \(error.localizedDescription)")
                            try? fm.removeItem(atPath: src)
                        }
                    }
                }

                do {
                    pool = try DatabasePool(path: dbPath, configuration: config)
                    reason = "Database was corrupted and has been reset. Previous data saved to \(corruptPath)"
                    databaseLogger.warning("\(reason!)")
                } catch {
                    databaseLogger.error("Fresh database creation also failed: \(error.localizedDescription)")
                }
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
                    databaseLogger.fault("\(reason!)")
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
            databaseLogger.fault("Database migration failed: \(error.localizedDescription)")
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
                    databaseLogger.error("Could not move aside \(dbPath + ext): \(error.localizedDescription)")
                }
            }

            do {
                let freshPool = try DatabasePool(path: dbPath, configuration: config)
                try Self.buildMigrator().migrate(freshPool)
                activePool = freshPool
                reason = movedAside
                    ? "The database schema could not be upgraded, so mull started a new one. Your previous data is saved at \(backupPath)."
                    : "The database schema could not be upgraded and has been reset."
                databaseLogger.warning("\(reason!)")
            } catch {
                databaseLogger.fault("Could not recover from migration failure: \(error.localizedDescription)")
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

        // The file that just got created holds every keystroke the user has typed,
        // in plaintext, and SQLite created it under the process umask (0644 on a
        // stock account). Lock it down now that the pool — and therefore the WAL
        // and SHM sidecars — exist. Uses the live pool's path rather than dbPath:
        // the recovery paths above may have landed on the temp fallback or on the
        // pre-migration backup, and those hold the same data.
        FilePrivacy.protectDatabase(atPath: activePool.path)

        // Put back whatever a previous launch moved aside. The two recovery paths
        // above rename the live database and start an empty one; without this,
        // that rename is where the user's history ends. See QuarantineRecovery —
        // it is idempotent, it never deletes, and it skips any file that fails its
        // own integrity check, so running it on every launch is safe and cheap
        // (a drained file is renamed and never looked at again).
        //
        // Skipped on the temporary fallback: restoring the user's history into a
        // database that is about to be thrown away would move it from a file that
        // survives into one that does not.
        var recoveryNote: String?
        if !usedFallback {
            let outcomes = QuarantineRecovery.reattachAll(into: activePool, primaryPath: dbPath)
            recoveryNote = QuarantineRecovery.summary(of: outcomes)
        }

        dbPool = activePool
        isFallback = usedFallback
        isReadOnly = false
        // The recovery note matters more than the fallback note when both exist —
        // "your data came back" is the thing a person needs to read first.
        let notes = [recoveryNote, reason].compactMap { $0 }
        fallbackReason = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    // MARK: - Cross-process migration lock

    /// Retry an open that reported corruption, and return the pool if the file
    /// comes back healthy. Nil means the claim held up and the file really is
    /// damaged — only then may the caller quarantine it.
    ///
    /// Three attempts with a widening pause, because what is being waited out is
    /// another process finishing a WAL checkpoint, and that is measured in
    /// milliseconds. The pauses total under a second, and only on a path that
    /// otherwise ends in the user losing their history.
    ///
    /// `integrity_check` is re-run each time rather than trusting a successful
    /// open: the first attempt failed *inside* that check, and a file that opens
    /// but does not verify is exactly the case this exists to catch.
    private static func reopenAfterCorruptionClaim(at path: String,
                                                   config: Configuration) -> DatabasePool? {
        for attempt in 1...3 {
            Thread.sleep(forTimeInterval: 0.15 * Double(attempt))
            do {
                let pool = try DatabasePool(path: path, configuration: config)
                try pool.read { db in
                    let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
                    if result != "ok" {
                        throw DatabaseError(resultCode: .SQLITE_CORRUPT,
                                            message: "Integrity check failed: \(result ?? "unknown")")
                    }
                }
                return pool
            } catch {
                databaseLogger.error("Corruption re-check \(attempt)/3 failed: \(error.localizedDescription)")
            }
        }
        return nil
    }

    /// Take an exclusive advisory lock on `<dbPath>.migrate.lock`, blocking until
    /// it is available. Returns -1 if the lock could not be taken, in which case
    /// the caller proceeds unlocked — a possible race is still better than
    /// refusing to start.
    private static func acquireMigrationLock(dbPath: String) -> Int32 {
        let fd = open(dbPath + ".migrate.lock", O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            databaseLogger.warning("Could not open the migration lock; migrating unlocked.")
            return -1
        }
        if flock(fd, LOCK_EX) != 0 {
            databaseLogger.warning("Could not take the migration lock; migrating unlocked.")
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

    /// Connection setup shared by the live pool and the test-path pool.
    private static func poolConfiguration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            // Runs on every connection the pool opens — including its read-only
            // reader connections. journal_mode and auto_vacuum live in the
            // database file itself, and auto_vacuum touches the header even
            // when it already says INCREMENTAL, so on a reader the pragma dies
            // with SQLITE_READONLY. That one line took down every read in the
            // app while writes kept succeeding — including the startup
            // integrity check, which sent the app to the temporary fallback
            // database. Persistent settings belong to the writer; readers pick
            // them up from the file.
            if !db.configuration.readonly {
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            }
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return config
    }

    /// Open a database at an explicit path, with the same schema and pragmas as
    /// the real one but none of the recovery/fallback machinery.
    ///
    /// This exists so tests never touch the user's actual recorded history.
    /// They used to construct `DatabaseService()` — the live database — and call
    /// `deleteAllData()` in `setUp`, which destroys everything mull has recorded
    /// on any machine where that file is writable.
    init(path: String) throws {
        let pool = try DatabasePool(path: path, configuration: Self.poolConfiguration())
        try Self.buildMigrator().migrate(pool)

        dbPool = pool
        isFallback = false
        isReadOnly = false
        fallbackReason = nil
    }

    /// Open the live database **read-only**, with no migration and no recovery.
    ///
    /// The app and the MullMCP binary both attach to the same SQLite file. Until
    /// now both did so with full read/write and both ran the migrator, and the
    /// comment in MullMCP's main saying "read-only access" was enforced by
    /// nothing — the binary held a type that can `deleteAllData()`. That shared
    /// write access is what produced the quarantines: a second writer attached to
    /// the WAL makes a reader see a page it cannot reconcile, SQLite reports
    /// SQLITE_CORRUPT, and the recovery path renames the user's history away.
    /// `reopenAfterCorruptionClaim` and the migration flock treat the symptom;
    /// this draws the boundary.
    ///
    /// Read-only also means:
    /// - **no migrator.** Two processes racing `ALTER TABLE` was the other half
    ///   of the same problem. Schema ownership belongs to the app, exclusively.
    /// - **no quarantine, no recovery.** A reader must never rename the writer's
    ///   database out from under it.
    /// - **no file creation.** Opening a database that is not there fails here
    ///   rather than silently creating an empty one and answering every question
    ///   with "no activity" — which is indistinguishable from a broken install.
    static func openReadOnly(at path: String? = nil) throws -> DatabaseService {
        let target = path ?? primaryDatabasePath()

        guard FileManager.default.fileExists(atPath: target) else {
            throw ReadOnlyOpenError.noDatabase(target)
        }

        // Two ways to be read-only, and both are needed.
        //
        // `config.readonly` opens the file O_RDONLY, which is the strongest form
        // and the one to prefer. But a WAL database needs its `-shm` to
        // coordinate readers, and an O_RDONLY connection cannot create one — so
        // the moment the app shuts down cleanly and SQLite removes the sidecars,
        // this fails with SQLITE_CANTOPEN. "The agent asks mull something while
        // the app is closed" is a completely ordinary situation, and answering it
        // with "unable to open database file" would be a worse bug than the one
        // this whole boundary exists to fix.
        //
        // So: try O_RDONLY first (the normal case — the app is running and the
        // sidecars are there), and fall back to a connection that may create the
        // -shm but has `query_only` set. SQLite enforces `query_only` itself:
        // every INSERT, UPDATE, DELETE and DDL returns SQLITE_READONLY. What it
        // still permits is exactly the WAL bookkeeping a reader legitimately
        // needs. `immutable=1` would also open, and is wrong — it promises the
        // file cannot change while the app may well be writing to it.
        var strict = poolConfiguration()
        strict.readonly = true

        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: target, configuration: strict)
        } catch {
            do {
                pool = try openQueryOnly(at: target)
            } catch {
                throw ReadOnlyOpenError.cannotOpen(target, error.localizedDescription)
            }
        }

        // The schema is the app's to own, but a reader still has to know whether
        // it is looking at one it understands. Checking a table it needs is
        // cheaper and more honest than checking a version number.
        let hasSchema = (try? pool.read { db in try db.tableExists("recording_events") }) ?? false
        guard hasSchema else { throw ReadOnlyOpenError.schemaNotReady(target) }

        return DatabaseService(readOnlyPool: pool)
    }

    /// The fallback read-only mode, for a WAL database whose `-shm` is gone.
    ///
    /// `query_only` is enforced by SQLite exactly as hard as O_RDONLY — INSERT,
    /// UPDATE, DELETE and DDL all return SQLITE_READONLY — but the connection is
    /// not opened O_RDONLY, so SQLite may create the `-shm` a WAL reader needs.
    ///
    /// The one wrinkle is that GRDB probes write access during `DatabasePool.init`
    /// (`CREATE TABLE grdb_issue_102; DROP TABLE`) whenever the `-wal` is missing
    /// or empty — which is precisely this case. So `query_only` is armed *after*
    /// init: the latch keeps it off for the connection opened during the probe,
    /// then it is switched on for that connection explicitly and for every reader
    /// connection the pool opens afterwards.
    private static func openQueryOnly(at path: String) throws -> DatabasePool {
        final class Latch: @unchecked Sendable { var armed = false }
        let latch = Latch()

        var config = poolConfiguration()
        config.prepareDatabase { db in
            // Runs after poolConfiguration's own pragmas — `journal_mode` and
            // `auto_vacuum` write to the header and query_only would reject them.
            if latch.armed { try db.execute(sql: "PRAGMA query_only = 1") }
        }

        let pool = try DatabasePool(path: path, configuration: config)
        latch.armed = true
        // The writer connection already exists and missed the closure above.
        try pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA query_only = 1") }
        return pool
    }

    private init(readOnlyPool: DatabasePool) {
        dbPool = readOnlyPool
        isReadOnly = true
        isFallback = false
        fallbackReason = nil
    }

    enum ReadOnlyOpenError: LocalizedError {
        case noDatabase(String)
        case cannotOpen(String, String)
        case schemaNotReady(String)

        var errorDescription: String? {
            switch self {
            case .noDatabase(let path):
                return "No mull database at \(path). Launch the mull app once so it can record and create one."
            case .cannotOpen(let path, let detail):
                return "Could not open \(path) read-only: \(detail)"
            case .schemaNotReady(let path):
                return "The database at \(path) has no recording_events table yet. Launch the mull app once to set up the schema."
            }
        }
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

}
