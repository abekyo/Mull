import XCTest
import GRDB
@testable import mull

/// Tests for DatabaseService — the most critical data path.
/// Uses an in-memory database to avoid touching the real DB.
final class DatabaseServiceTests: XCTestCase {

    private var db: DatabaseService!

    override func setUp() {
        super.setUp()
        // A throwaway database — never the user's real recorded history.
        // Each test therefore starts from a genuinely clean slate.
        db = try! DatabaseService.temporary()
    }

    // MARK: - Migration

    func testMigrationCompletesWithoutError() {
        // DatabaseService.init() runs migrate() — if we get here, it succeeded.
        XCTAssertNotNil(db.dbPool)
    }

    func testSchemaVersionIsLatest() {
        // Derived, not hardcoded: this assertion went stale silently through v4,
        // v5 and v6, so it was testing nothing until it started failing.
        XCTAssertEqual(db.schemaVersion, DatabaseService.latestMigrationIdentifier)
    }

    // MARK: - Recording Events CRUD

    func testInsertAndFetchEvent() {
        let event = RecordingEvent(
            timestamp: Date(),
            eventType: .keystroke,
            appName: "Xcode",
            windowTitle: "Test.swift",
            textContent: "hello world"
        )
        db.insertEvent(event)

        let fetched = db.fetchEvents(from: Date().addingTimeInterval(-60), to: Date())
        XCTAssertFalse(fetched.isEmpty)
        XCTAssertEqual(fetched.last?.textContent, "hello world")
        XCTAssertEqual(fetched.last?.appName, "Xcode")
    }

    func testEventCountToday() {
        let before = db.eventCountToday()

        let event = RecordingEvent(
            timestamp: Date(),
            eventType: .clipboard,
            appName: "Safari",
            textContent: "copied text"
        )
        db.insertEvent(event)

        XCTAssertEqual(db.eventCountToday(), before + 1)
    }

    func testFetchEventsDateRange() {
        let yesterday = Date().addingTimeInterval(-86400)
        let old = RecordingEvent(timestamp: yesterday, eventType: .keystroke, textContent: "old")
        let recent = RecordingEvent(timestamp: Date(), eventType: .keystroke, textContent: "new")

        db.insertEvent(old)
        db.insertEvent(recent)

        // Only fetch last hour
        let results = db.fetchEvents(
            from: Date().addingTimeInterval(-3600),
            to: Date()
        )
        XCTAssertTrue(results.allSatisfy { $0.textContent != "old" || $0.timestamp > yesterday.addingTimeInterval(3600) })
        XCTAssertTrue(results.contains { $0.textContent == "new" })
    }

    // MARK: - Summaries CRUD

    func testInsertAndFetchSummary() {
        let summary = DailySummary(
            date: Date(),
            content: "# Test Summary\nYou worked on tests.",
            morningSection: "Testing",
            afternoonSection: nil,
            eveningSection: nil,
            learnings: "Unit tests matter",
            inProgress: "DatabaseService",
            eventCount: 42,
            processingSeconds: 1.5,
            llmProvider: "local",
            createdAt: Date()
        )
        db.insertSummary(summary)

        let fetched = db.fetchSummary(for: Date())
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.eventCount, 42)
        XCTAssertEqual(fetched?.learnings, "Unit tests matter")
    }

    func testInsertSummaryUpserts() {
        let date = Date()
        let first = DailySummary(
            date: date, content: "First", eventCount: 10,
            processingSeconds: 1, llmProvider: "local", createdAt: date
        )
        let second = DailySummary(
            date: date, content: "Second", eventCount: 20,
            processingSeconds: 2, llmProvider: "claude", createdAt: date
        )

        db.insertSummary(first)
        db.insertSummary(second)

        let fetched = db.fetchSummary(for: date)
        XCTAssertEqual(fetched?.content, "Second", "Second insert should replace the first")
        XCTAssertEqual(fetched?.eventCount, 20)
    }

    func testFetchRecentSummaries() {
        for i in 0..<5 {
            let date = Calendar.current.date(byAdding: .day, value: -i, to: Date())!
            let s = DailySummary(
                date: date, content: "Day \(i)", eventCount: i * 10,
                processingSeconds: 0.5, llmProvider: "local", createdAt: Date()
            )
            db.insertSummary(s)
        }

        let recent = db.fetchRecentSummaries(limit: 3)
        XCTAssertEqual(recent.count, 3)
        // Most recent first
        XCTAssertEqual(recent.first?.content, "Day 0")
    }

    // MARK: - Knowledge CRUD

    func testInsertAndFetchKnowledge() {
        let entry = KnowledgeEntry(
            topic: "Binding strategy",
            decision: "Closure-based over Combine",
            reasoning: "No Combine dependency in project",
            rejected: "Combine, RxSwift",
            project: "PantryApp",
            relatedProjects: "mull",
            tags: "architecture,mvvm",
            sourceDate: Date(),
            createdAt: Date()
        )
        db.insertKnowledge(entry)

        let all = db.fetchAllKnowledge()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.topic, "Binding strategy")
        XCTAssertEqual(all.first?.project, "PantryApp")
    }

    func testFetchKnowledgeByProject() {
        let e1 = KnowledgeEntry(
            topic: "A", decision: "X", project: "PantryApp",
            sourceDate: Date(), createdAt: Date()
        )
        let e2 = KnowledgeEntry(
            topic: "B", decision: "Y", project: "Blow",
            sourceDate: Date(), createdAt: Date()
        )
        db.insertKnowledge(e1)
        db.insertKnowledge(e2)

        let results = db.fetchKnowledge(forProject: "PantryApp")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.topic, "A")
    }

    // MARK: - Memory CRUD

    func testInsertAndFetchMemory() {
        let mem = MemoryEntry(
            name: "user_role",
            description: "Software developer",
            memoryType: .user,
            content: "Senior iOS developer",
            filePath: "memory/user_role.md",
            createdAt: Date(),
            updatedAt: Date()
        )
        db.insertMemory(mem)

        let all = db.fetchAllMemories()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "user_role")
        XCTAssertEqual(all.first?.memoryType, .user)
    }

    // MARK: - FTS Search

    func testSearchEvents() {
        let e1 = RecordingEvent(timestamp: Date(), eventType: .clipboard, textContent: "SwiftUI navigation")
        let e2 = RecordingEvent(timestamp: Date(), eventType: .clipboard, textContent: "UIKit storyboard")
        db.insertEvent(e1)
        db.insertEvent(e2)

        let results = db.searchEvents(query: "SwiftUI")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.textContent, "SwiftUI navigation")
    }

    func testSearchEventsEmptyQuery() {
        let results = db.searchEvents(query: "")
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchSummaries() {
        let s = DailySummary(
            date: Date(), content: "Deep work on MVVM refactor",
            eventCount: 100, processingSeconds: 2, llmProvider: "local", createdAt: Date()
        )
        db.insertSummary(s)

        let results = db.searchSummaries(query: "MVVM")
        XCTAssertEqual(results.count, 1)
    }

    // MARK: - FTS Rebuild

    func testRebuildFTSIndexes() {
        let event = RecordingEvent(timestamp: Date(), eventType: .keystroke, textContent: "rebuild test")
        db.insertEvent(event)

        // Should not crash
        db.rebuildFTSIndexes()

        // Search should still work after rebuild
        let results = db.searchEvents(query: "rebuild")
        XCTAssertEqual(results.count, 1)
    }

    // MARK: - Data Deletion

    func testDeleteEventsOlderThan() throws {
        let old = RecordingEvent(
            timestamp: Date().addingTimeInterval(-86400 * 10),
            eventType: .keystroke, textContent: "ancient"
        )
        let recent = RecordingEvent(
            timestamp: Date(),
            eventType: .keystroke, textContent: "fresh"
        )
        db.insertEvent(old)
        db.insertEvent(recent)

        try db.deleteEventsOlderThan(days: 5)

        let all = db.fetchEvents(
            from: Date().addingTimeInterval(-86400 * 30),
            to: Date()
        )
        XCTAssertTrue(all.allSatisfy { $0.textContent != "ancient" })
        XCTAssertTrue(all.contains { $0.textContent == "fresh" })
    }

    // MARK: - mull Lock

    func testMullLockInitialized() {
        let lock = db.fetchmullLock()
        XCTAssertNotNil(lock)
        XCTAssertEqual(lock?.sessionsSinceLast, 0)
    }

    func testIncrementSessionCount() {
        db.incrementSessionCount()
        db.incrementSessionCount()

        let lock = db.fetchmullLock()
        XCTAssertEqual(lock?.sessionsSinceLast, 2)
    }

    // MARK: - Fallback State

    func testNotInFallbackByDefault() {
        XCTAssertFalse(db.isFallback)
        // fallbackReason can be non-nil if DB was reset, but isFallback should be false
        // for a normal init
    }
}


extension DatabaseServiceTests {
    func testInsertKeepsBrowserContentWithoutProjectMetadata() throws {
        let event = RecordingEvent(timestamp: Date(), eventType: .windowBody, appName: "Firefox",
                                   windowTitle: "Concurrency reference — 元のプロファイル",
                                   textContent: "Swift cancellation reference", entity: "元のプロファイル")
        db.insertEvent(event)
        let saved = try db.dbPool.read { try RecordingEvent.fetchOne($0) }
        XCTAssertNil(try XCTUnwrap(saved).entity)
        XCTAssertEqual(saved?.textContent, event.textContent)
        XCTAssertEqual(saved?.windowTitle, event.windowTitle)
    }

    func testLegacyBrowserEntityMigrationPreservesRecordsAndEditorProjects() throws {
        let path = db.databaseFilePath
        let now = Date()
        // Bypass today's insert guard to represent rows written by the old app.
        try db.dbPool.write { conn in
            for (app, entity) in [("Firefox", "元のプロファイル"), ("GOOGLE CHROME", "Migration guide"), ("Xcode", "Halyard")] {
                let event = RecordingEvent(timestamp: now, eventType: .windowBody, appName: app,
                                           windowTitle: "Original window title", textContent: "Swift cancellation reference", entity: entity)
                try event.insert(conn)
            }
            try conn.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v9_clear_content_app_entities'")
        }
        try db.dbPool.close()
        db = try DatabaseService(path: path)
        let rows = try db.dbPool.read { try RecordingEvent.fetchAll($0, sql: "SELECT * FROM recording_events ORDER BY id") }
        XCTAssertEqual(rows.count, 3)
        XCTAssertNil(rows[0].entity)
        XCTAssertNil(rows[1].entity)
        XCTAssertEqual(rows[2].entity, "Halyard")
        XCTAssertTrue(rows.allSatisfy { $0.windowTitle == "Original window title" && $0.textContent == "Swift cancellation reference" })
        let hits = try db.dbPool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM recording_events_fts WHERE recording_events_fts MATCH 'cancellation'") }
        XCTAssertEqual(hits, 3, "metadata repair must not remove searchable history")
        XCTAssertEqual(db.schemaVersion, DatabaseService.latestMigrationIdentifier)
    }
}


extension DatabaseServiceTests {
    func testKnowledgeFallbackDoesNotNameBrowserProfileAsProject() {
        let browser = RecordingEvent(timestamp: Date(), eventType: .screenText, appName: "Firefox",
                                     textContent: "Concurrency reference — 元のプロファイル")
        let clip = RecordingEvent(timestamp: Date(), eventType: .clipboard, appName: "Firefox",
                                  textContent: "We chose structured concurrency because cancellation must propagate.")
        let extractor = KnowledgeExtractor(database: db)
        XCTAssertEqual(extractor.extractRuleBased(events: [browser, clip]).map(\.project), ["Unknown"])
        let editor = RecordingEvent(timestamp: Date(), eventType: .screenText, appName: "Code",
                                    textContent: "Task.swift — Halyard")
        XCTAssertEqual(extractor.extractRuleBased(events: [browser, editor, clip]).map(\.project), ["Halyard"])
    }
}
