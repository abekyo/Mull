import Foundation
import GRDB
import os.log

private let logger = Logger(subsystem: "com.mull.app", category: "QuarantineRecovery")

/// Puts back what the recovery paths moved aside.
///
/// `DatabaseService.init` has two places where it renames the live database out
/// of the way and starts an empty one: a failed `integrity_check`
/// (`.corrupt-<timestamp>`) and a failed migration (`.pre-migration-<timestamp>`).
/// Both were written as "the data is safe, it is over there" — and then nothing
/// ever went and got it.
///
/// On the machine this was written on that had happened **30 times**, and the
/// live database held 398 events while `mull.sqlite.corrupt-2026-08-08T17-02-18Z`
/// held 8,013 and opened perfectly cleanly. Two months of capture, present on
/// disk, unreachable by the app that recorded it.
///
/// That is not a storage bug, it is the product's first law being broken by its
/// own error path: capture fidelity is the one asset that cannot be recovered
/// later (MAP-ARCHITECTURE 法則①), so an error path that abandons it is worse
/// than one that refuses to start. The quarantine itself is still right — an
/// unreadable file must not block launch. What was missing is the other half.
///
/// Design constraints, in order:
///
/// 1. **Never destroy.** Nothing here deletes. A file that has been drained is
///    renamed to `.reattached-<timestamp>`, so a bad merge is still undoable by
///    hand and the scanner stops picking it up.
/// 2. **Idempotent.** Rows are matched on their content, not their rowid — the
///    quarantined file and the live one both start ids at 1, so ids collide
///    while meaning nothing. Running twice must not double anything.
/// 3. **Schema-tolerant.** A file quarantined before `v5_event_signal_columns`
///    has six columns where the live table has ten. Copy the intersection and
///    let the missing ones default; `Selection` already recomputes `entity` /
///    `contentType` / `salience` / `mode` when they are null, which is exactly
///    the pre-backfill path it was built to handle.
/// 4. **Never partial.** Each file is drained inside one transaction, so a
///    failure halfway through leaves the live database untouched and the
///    quarantine file still named `.corrupt-*` for the next attempt.
enum QuarantineRecovery {

    /// What one quarantine file turned into.
    struct Outcome {
        let path: String
        /// table name → rows actually inserted (rows already present are skipped).
        let restored: [String: Int]
        /// Nil on success. Set when the file was skipped, with the reason.
        let skipped: String?

        var totalRows: Int { restored.values.reduce(0, +) }
    }

    /// Tables worth restoring, with the columns that identify a row.
    ///
    /// `recording_events` is the only irreplaceable one — everything else is
    /// derived from it — but the derived tables cost LLM calls to rebuild, and
    /// `memory_entries` is written by a person. Ordered with events first so a
    /// partial-schema file still gets the part that matters.
    ///
    /// The identity columns are deliberately the whole content of the row, not a
    /// natural key. Two window-title polls a millisecond apart are two events;
    /// two rows with the same timestamp AND the same text are the same event
    /// seen twice, and collapsing them is what makes a second run a no-op.
    private static let tables: [(name: String, identity: [String])] = [
        ("recording_events",  ["timestamp", "eventType", "appName", "windowTitle", "textContent"]),
        ("daily_summaries",   ["date"]),
        ("knowledge_entries", ["topic", "decision", "project", "sourceDate"]),
        ("memory_entries",    ["filePath"]),
        ("predictions",       ["createdAt", "project", "kind", "statement"]),
    ]

    private static let quarantineMarkers = [".corrupt-", ".pre-migration-"]

    /// What a drained file is renamed to. Its rows are all in the live database by
    /// then, so nothing reads it again — but the bytes are still a complete copy of
    /// the history, which is why the erasure paths below have to know the name.
    private static let reattachedMarker = ".reattached-"

    /// Every name that means "a copy of the history, sitting beside the live file".
    private static var archiveMarkers: [String] { quarantineMarkers + [reattachedMarker] }

    // MARK: - Discovery

    /// Quarantine files sitting beside `primaryPath`, oldest first.
    ///
    /// Sidecars (`-wal`, `-shm`) are not returned: SQLite picks them up from the
    /// main file's name when it opens, and returning them would drain each file
    /// three times.
    static func pendingFiles(besidePrimary primaryPath: String) -> [String] {
        files(besidePrimary: primaryPath, matching: quarantineMarkers)
    }

    /// Every copy of the history beside `primaryPath` — pending quarantines AND the
    /// drained ones renamed `.reattached-*`.
    ///
    /// This exists because "Never destroy" (constraint 1 above) is the right rule
    /// for a *recovery* path and the wrong one for an *erasure* path, and for a
    /// while it was the only rule either had. A drained file is a full plaintext
    /// copy of everything mull ever recorded, nothing ever reads it again, and
    /// nothing ever deleted it — so "Delete everything", which tells the user
    /// "Nothing goes to the Trash. This cannot be undone", left as many complete
    /// copies of their history on disk as the app had ever quarantined. On the
    /// machine this was written on that was thirty of them.
    static func archivedFiles(besidePrimary primaryPath: String) -> [String] {
        files(besidePrimary: primaryPath, matching: archiveMarkers)
    }

    private static func files(besidePrimary primaryPath: String, matching markers: [String]) -> [String] {
        let url = URL(fileURLWithPath: primaryPath)
        let dir = url.deletingLastPathComponent()
        let base = url.lastPathComponent

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { name in
                name.hasPrefix(base)
                    && markers.contains { name.contains($0) }
                    && !name.hasSuffix("-wal") && !name.hasSuffix("-shm")
            }
            .sorted()
            .map { dir.appendingPathComponent($0).path }
    }

    // MARK: - Erasure
    //
    // The two ways a user asks for data to be gone, applied to the copies. Neither
    // is a recovery path, so neither obeys "Never destroy" — that constraint
    // protects the user from mull's error handling, not from the user.

    /// Delete every archived copy beside `primaryPath`, sidecars included.
    /// Returns the paths that could not be removed, for the caller to report.
    ///
    /// Only for "delete everything". A window-scoped forget must use
    /// `scrub(interval:)` instead: a pending quarantine holds rows that are not in
    /// the live database, and deleting the file to erase fifteen minutes would take
    /// months of unrelated history with it.
    @discardableResult
    static func deleteArchives(besidePrimary primaryPath: String) -> [String] {
        let fm = FileManager.default
        var failed: [String] = []
        for file in archivedFiles(besidePrimary: primaryPath) {
            for ext in ["", "-wal", "-shm"] where fm.fileExists(atPath: file + ext) {
                do { try fm.removeItem(atPath: file + ext) }
                catch {
                    logger.error("Could not delete archive \(file + ext): \(error.localizedDescription)")
                    failed.append(file + ext)
                }
            }
        }
        return failed
    }

    /// Which column carries the time each table is forgotten by. Mirrors what
    /// `ForgetService` deletes from the live database, so a window erased there is
    /// erased here by the same rule rather than by a second, drifting one.
    private static let timeColumns: [(table: String, column: String)] = [
        ("recording_events",  "timestamp"),
        ("daily_summaries",   "date"),
        ("knowledge_entries", "sourceDate"),
    ]

    /// Remove one window from every archived copy, so a forget reaches the data a
    /// future launch would otherwise re-attach — or, for an already-drained file,
    /// the copy that sits on disk saying the same thing.
    ///
    /// Returns the archives it could not scrub. A corrupt file is the usual reason
    /// and it is not fatal: it fails its integrity check here exactly as it does in
    /// `reattach`, so it will never be merged into the live database either. The
    /// caller still has to say so — a forget that quietly skips a copy is the kind
    /// of silent partial success this whole feature exists to avoid.
    @discardableResult
    static func scrub(interval: DateInterval,
                      memoryFilePaths: [String] = [],
                      besidePrimary primaryPath: String) -> [String] {
        var failed: [String] = []
        for file in archivedFiles(besidePrimary: primaryPath) {
            do { try scrub(interval: interval, memoryFilePaths: memoryFilePaths, file: file) }
            catch {
                logger.error("Could not scrub \(file): \(error.localizedDescription)")
                failed.append(file)
            }
        }
        return failed
    }

    /// Exposed for tests, which build the archive explicitly.
    static func scrub(interval: DateInterval, memoryFilePaths: [String] = [], file: String) throws {
        // Opened on its own, not ATTACHed to the live pool: the live pool is the
        // app's single writer, and the reason these files exist in the first place
        // is two writers on one SQLite file.
        let pool = try DatabasePool(path: file)
        defer { try? pool.close() }

        try pool.write { db in
            let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            guard integrity == "ok" else {
                throw RecoveryError.failedIntegrityCheck(integrity ?? "unknown")
            }

            for (table, column) in timeColumns {
                guard try columns(of: table, in: "main", db: db).contains(column) else { continue }
                // Summaries are stored per day, so a window inside a day still
                // takes the whole day's row — the same coarseness `ForgetService`
                // applies to the live table and names out loud in its plan.
                let start = table == "daily_summaries"
                    ? Calendar.current.startOfDay(for: interval.start) : interval.start
                try db.execute(sql: "DELETE FROM \"\(table)\" WHERE \"\(column)\" >= ? AND \"\(column)\" <= ?",
                               arguments: [start, interval.end])
            }

            if !memoryFilePaths.isEmpty,
               try !columns(of: "memory_entries", in: "main", db: db).isEmpty {
                let holes = databaseQuestionMarks(count: memoryFilePaths.count)
                try db.execute(sql: "DELETE FROM memory_entries WHERE filePath IN (\(holes))",
                               arguments: StatementArguments(memoryFilePaths))
            }

            // The rows are gone; the text is not, until the FTS shadow tables are
            // rebuilt. Archives old enough to predate the v7 delete triggers keep
            // every word of a forgotten window in `*_fts_content` otherwise —
            // "forgotten" has to mean gone from the file (ForgetService §5).
            for table in ["recording_events_fts", "daily_summaries_fts", "knowledge_entries_fts"] {
                guard try !columns(of: table, in: "main", db: db).isEmpty else { continue }
                try db.execute(sql: "INSERT INTO \"\(table)\"(\"\(table)\") VALUES('rebuild')")
            }
        }
        // Hand the freed pages back, so the text is off the disk rather than merely
        // off the freelist.
        try pool.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
    }

    // MARK: - Entry point

    /// Drain every quarantine file beside `primaryPath` into `pool`.
    ///
    /// Returns one outcome per file. Never throws: a database that cannot be
    /// recovered must not stop the app from starting — that was the whole reason
    /// the quarantine path exists.
    @discardableResult
    static func reattachAll(into pool: DatabasePool, primaryPath: String) -> [Outcome] {
        let files = pendingFiles(besidePrimary: primaryPath)
        guard !files.isEmpty else { return [] }

        logger.notice("Found \(files.count) quarantined database(s) beside the live one")
        var outcomes: [Outcome] = []
        for file in files {
            do {
                let restored = try reattach(file: file, into: pool)
                markReattached(file)
                let total = restored.values.reduce(0, +)
                logger.notice("Recovered \(total) row(s) from \(URL(fileURLWithPath: file).lastPathComponent)")
                outcomes.append(Outcome(path: file, restored: restored, skipped: nil))
            } catch {
                // Left named `.corrupt-*` on purpose: the next launch tries again,
                // and a file that is genuinely damaged simply keeps failing here
                // instead of being silently dropped.
                logger.error("Could not recover \(file): \(error.localizedDescription)")
                outcomes.append(Outcome(path: file, restored: [:], skipped: error.localizedDescription))
            }
        }
        return outcomes
    }

    /// A sentence for the user, or nil when there is nothing to say.
    static func summary(of outcomes: [Outcome]) -> String? {
        let rows = outcomes.reduce(0) { $0 + $1.totalRows }
        let failed = outcomes.filter { $0.skipped != nil }.count
        if rows == 0 && failed == 0 { return nil }
        var parts: [String] = []
        if rows > 0 {
            let files = outcomes.filter { $0.totalRows > 0 }.count
            // Whole sentences rather than a stem with English inflections spliced in
            // (WRITING.md §5.3). `counted` lives in the view layer, and this file is
            // compiled into MullMCP as well, so the choice is written out here.
            parts.append(rows == 1
                ? String(localized: "Recovered 1 record from \(files) quarantined database(s).")
                : String(localized: "Recovered \(rows) records from \(files) quarantined database(s)."))
        }
        if failed > 0 {
            parts.append(failed == 1
                ? String(localized: "1 could not be read and was left in place.")
                : String(localized: "\(failed) could not be read and were left in place."))
        }
        return parts.joined(separator: " ")
    }

    // MARK: - One file

    /// Copy every recoverable row out of `file` and into `pool`.
    ///
    /// Exposed for tests, which build both databases explicitly rather than
    /// relying on whatever happens to be in Application Support.
    static func reattach(file: String, into pool: DatabasePool) throws -> [String: Int] {
        // ATTACH cannot run inside a transaction, so the attach/detach has to sit
        // outside one — and the copying has to sit inside one. Hence
        // writeWithoutTransaction plus an explicit inTransaction below.
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS quarantine", arguments: [file])
            defer { try? db.execute(sql: "DETACH DATABASE quarantine") }

            // Do not merge from a file that fails its own integrity check. This is
            // the same check that quarantined it, and most of the time it passes
            // now — the 2026-07-18 and 2026-08-08 quarantines were a second
            // process attached to the WAL, not damage — but when it genuinely
            // fails, pulling rows out of a corrupt b-tree is how one broken file
            // becomes two.
            let integrity = try String.fetchOne(db, sql: "PRAGMA quarantine.integrity_check")
            guard integrity == "ok" else {
                throw RecoveryError.failedIntegrityCheck(integrity ?? "unknown")
            }

            var restored: [String: Int] = [:]
            try db.inTransaction {
                for table in tables {
                    let copied = try copy(table: table.name, identity: table.identity, db: db)
                    if copied > 0 { restored[table.name] = copied }
                }
                return .commit
            }
            return restored
        }
    }

    /// Copy one table's missing rows. Returns how many were inserted.
    private static func copy(table: String, identity: [String], db: Database) throws -> Int {
        let live = try columns(of: table, in: "main", db: db)
        let quarantined = try columns(of: table, in: "quarantine", db: db)
        // A file older than the migration that created this table has nothing to
        // give; a file newer than the running schema has columns we must not
        // mention. Both are handled by intersecting.
        guard !live.isEmpty, !quarantined.isEmpty else { return 0 }

        // `id` is deliberately dropped: both databases number from 1, so copying
        // ids would collide on the primary key and, worse, would silently pin the
        // FTS `content_rowid` to a row that is not there.
        let shared = live.filter { quarantined.contains($0) && $0 != "id" }
        guard !shared.isEmpty else { return 0 }

        // Identity columns the old file does not have cannot participate in the
        // duplicate check. Falling back to the shared set keeps the check
        // conservative (more columns compared = fewer rows treated as duplicates)
        // rather than letting it silently match on nothing and skip everything.
        let keys = identity.filter { shared.contains($0) }
        guard !keys.isEmpty else { return 0 }

        let columnList = shared.map { "\"\($0)\"" }.joined(separator: ", ")
        let selectList = shared.map { "q.\"\($0)\"" }.joined(separator: ", ")
        // IFNULL on both sides: `NULL = NULL` is NULL in SQL, so a row whose
        // appName is null would never match itself and would be re-inserted on
        // every launch — the exact opposite of idempotent.
        let match = keys
            .map { "IFNULL(m.\"\($0)\", '') = IFNULL(q.\"\($0)\", '')" }
            .joined(separator: " AND ")

        let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM main.\"\(table)\"") ?? 0
        try db.execute(sql: """
            INSERT INTO main."\(table)" (\(columnList))
            SELECT \(selectList) FROM quarantine."\(table)" q
            WHERE NOT EXISTS (
                SELECT 1 FROM main."\(table)" m WHERE \(match)
            )
            """)
        let after = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM main.\"\(table)\"") ?? 0
        return after - before
    }

    /// Column names of `schema.table`, or empty when the table is not there.
    ///
    /// The `pragma_table_info` table-valued function takes no schema argument, so
    /// the schema-qualified form has to be the pragma statement, which means the
    /// names are interpolated rather than bound. Both are compile-time constants
    /// from `tables` above and from the two literal schema names — nothing
    /// user-supplied reaches this string.
    private static func columns(of table: String, in schema: String, db: Database) throws -> [String] {
        let rows = try Row.fetchAll(db, sql: "PRAGMA \(schema).table_info(\"\(table)\")")
        return rows.compactMap { $0["name"] as String? }
    }

    // MARK: - Marking

    /// Rename a drained file so the scanner stops seeing it, keeping the bytes.
    private static func markReattached(_ file: String) {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for marker in quarantineMarkers {
            guard let range = file.range(of: marker) else { continue }
            let destination = file.replacingCharacters(in: range, with: ".reattached-\(stamp)-")
            for ext in ["", "-wal", "-shm"] where fm.fileExists(atPath: file + ext) {
                try? fm.moveItem(atPath: file + ext, toPath: destination + ext)
            }
            return
        }
    }

    enum RecoveryError: LocalizedError {
        case failedIntegrityCheck(String)

        var errorDescription: String? {
            switch self {
            case .failedIntegrityCheck(let detail):
                return "the quarantined database did not pass its integrity check (\(detail))"
            }
        }
    }
}
