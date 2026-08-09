import Foundation
import GRDB
import os.log

// Recording events — the territory itself (MAP-ARCHITECTURE 法則①).
//
// Everything else in the database is derived from this table and can be rebuilt;
// these rows cannot. `insertEvent` is the only writer, and it is append-only on
// purpose: capture never edits and never deletes, so the two callers that record
// (RecordingService, EmailService) take `EventWriting` and can do nothing else.
//
// Split out of DatabaseService.swift, which had grown to 1,500 lines across nine
// unrelated concerns. Nothing here changed in the move.

extension DatabaseService {

    // MARK: - FTS Rebuild

    /// Rebuild all FTS5 indexes. Call after data import or if search results seem
    /// stale. Returns whether the rebuild happened — ForgetService reports a
    /// `false` to the user, because a stale index still serves up forgotten text.
    @discardableResult
    func rebuildFTSIndexes() -> Bool {
        do {
            try dbPool.write { db in
                try db.execute(sql: "INSERT INTO recording_events_fts(recording_events_fts) VALUES('rebuild')")
                try db.execute(sql: "INSERT INTO daily_summaries_fts(daily_summaries_fts) VALUES('rebuild')")
                try db.execute(sql: "INSERT INTO knowledge_entries_fts(knowledge_entries_fts) VALUES('rebuild')")
            }
            databaseLogger.info("FTS indexes rebuilt successfully")
            return true
        } catch {
            databaseLogger.error("FTS rebuild failed: \(error.localizedDescription)")
            return false
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
            databaseLogger.error("Failed to insert event: \(error.localizedDescription)")
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
            databaseLogger.warning("Failed to count today's events: \(error.localizedDescription)")
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
            databaseLogger.warning("Failed to fetch events: \(error.localizedDescription)")
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
            databaseLogger.warning("Failed to read storage bytes: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - Search (FTS5)

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
                if TextScript.containsCJK(trimmed) {
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
            databaseLogger.warning("Failed to search summaries: \(error.localizedDescription)")
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
            databaseLogger.warning("fetchCandidates failed: \(error.localizedDescription)")
            return []
        }
    }

    func searchEvents(query: String, limit: Int = 100) -> [RecordingEvent] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            return try dbPool.read { db in
                if TextScript.containsCJK(trimmed) {
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
            databaseLogger.warning("Failed to search events: \(error.localizedDescription)")
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
            databaseLogger.warning("Failed to count events: \(error.localizedDescription)")
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
            databaseLogger.warning("Failed to aggregate daily counts: \(error.localizedDescription)")
            return [:]
        }
    }
}
