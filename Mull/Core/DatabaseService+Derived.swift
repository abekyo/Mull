import Foundation
import GRDB
import os.log

// The derived layers: daily summaries, extracted knowledge, memories.
//
// All of it is regenerable from `recording_events`, which is why reading it is a
// separate permission (`DerivedReading`) from reading the events themselves —
// losing this costs LLM calls, losing the events costs the thing that cannot be
// recovered later.
//
// Split out of DatabaseService.swift. Nothing here changed in the move.

extension DatabaseService {

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
            databaseLogger.error("Failed to insert summary for \(summary.date): \(error.localizedDescription)")
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
            databaseLogger.warning("Failed to fetch summary: \(error.localizedDescription)")
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
            databaseLogger.warning("Failed to fetch recent summaries: \(error.localizedDescription)")
            return []
        }
    }

    /// How many daily summaries exist. A `COUNT(*)`, because the caller that wants
    /// this number was fetching every row — decoding each summary's whole text —
    /// purely to ask for `.count`.
    func summaryCount() -> Int {
        do {
            return try dbPool.read { db in try DailySummary.fetchCount(db) }
        } catch {
            databaseLogger.warning("Failed to count summaries: \(error.localizedDescription)")
            return 0
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
            databaseLogger.error("Failed to insert knowledge '\(entry.topic)': \(error.localizedDescription)")
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
            databaseLogger.warning("Failed to fetch knowledge: \(error.localizedDescription)")
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
            databaseLogger.warning("Failed to fetch knowledge for project '\(project)': \(error.localizedDescription)")
            return []
        }
    }

    func searchKnowledge(query: String, limit: Int = 20) -> [KnowledgeEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            return try dbPool.read { db in
                if TextScript.containsCJK(trimmed) {
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
            databaseLogger.warning("Failed to search knowledge: \(error.localizedDescription)")
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
            databaseLogger.warning("findRelevantKnowledge failed: \(error.localizedDescription)")
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
            databaseLogger.error("Failed to insert memory '\(entry.name)': \(error.localizedDescription)")
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
            databaseLogger.warning("Failed to fetch memories: \(error.localizedDescription)")
            return []
        }
    }

    func updateMemory(_ entry: MemoryEntry) {
        do {
            try dbPool.write { db in
                try entry.update(db)
            }
        } catch {
            databaseLogger.error("Failed to update memory '\(entry.name)': \(error.localizedDescription)")
        }
    }

    /// Delete exactly one memory, keyed by its unique `filePath` — never by
    /// name. Two memories can share a name, and `DELETE WHERE name=?` would
    /// wipe them all while removing only one file, orphaning the rest.
    @discardableResult
    func deleteMemory(_ entry: MemoryEntry) -> Bool {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM memory_entries WHERE filePath = ?",
                               arguments: [entry.filePath])
            }
            return true
        } catch {
            databaseLogger.error("Failed to delete memory '\(entry.name)': \(error.localizedDescription)")
            return false
        }
    }
}
