import XCTest
import GRDB
@testable import mull

/// The boundary between the app (which owns the database) and MullMCP (which
/// reads it).
///
/// Both processes used to open the same SQLite file read-write and both ran the
/// migrator. SQLite's response to a second writer on a shared WAL is to hand a
/// reader a page it cannot reconcile and report SQLITE_CORRUPT — which the app's
/// recovery path acted on by renaming the user's history away. Thirty times, on
/// the machine this was found on.
///
/// These tests pin the two halves of the fix: SQLite refuses the write, and the
/// type handed to the MCP surface has no write on it to refuse.
final class DatabaseBoundaryTests: XCTestCase {

    private var dir: URL!
    private var path: String { dir.appendingPathComponent("mull.sqlite").path }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boundary-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Create the database the way the app does, then let go of it.
    @discardableResult
    private func seedAsApp(_ body: (DatabaseService) -> Void = { _ in }) throws -> String {
        let app = try DatabaseService(path: path)
        body(app)
        try app.dbPool.close()
        return path
    }

    // MARK: - The engine enforces it

    func testReadOnlyHandleCanRead() throws {
        try seedAsApp { db in
            db.insertEvent(RecordingEvent(timestamp: Date(), eventType: .clipboard,
                                          appName: "Code", windowTitle: "Notes — Mull",
                                          textContent: "written by the app"))
        }

        let reader = try DatabaseService.openReadOnly(at: path)
        XCTAssertTrue(reader.isReadOnly)
        XCTAssertEqual(reader.searchEvents(query: "written").count, 1)
    }

    /// The point of the whole exercise: a write through the reader must fail at
    /// the SQLite level, not merely be discouraged by a comment.
    func testReadOnlyHandleCannotWrite() throws {
        try seedAsApp()
        let reader = try DatabaseService.openReadOnly(at: path)

        XCTAssertThrowsError(try reader.dbPool.write { db in
            try db.execute(sql: "INSERT INTO recording_events (timestamp, eventType) VALUES (?, ?)",
                           arguments: [Date(), "clipboard"])
        }) { error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_READONLY,
                           "expected SQLite itself to refuse, got \(error)")
        }
    }

    /// A reader must never create the file. Silently opening an empty database is
    /// how "mull knows nothing about today" becomes indistinguishable from a
    /// broken install.
    func testReadOnlyRefusesToCreateAMissingDatabase() throws {
        XCTAssertThrowsError(try DatabaseService.openReadOnly(at: path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Launch the mull app"),
                          "the error has to tell the user what to do: \(error.localizedDescription)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// Schema ownership belongs to the app. A reader that met a database with no
    /// schema used to run the migrator against it from a second process; now it
    /// declines and says why.
    func testReadOnlyRefusesADatabaseWithNoSchema() throws {
        let bare = try DatabasePool(path: path)
        try bare.close()

        XCTAssertThrowsError(try DatabaseService.openReadOnly(at: path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("recording_events"), error.localizedDescription)
        }
    }

    /// The reader does not migrate. If it did, two processes could run ALTER
    /// TABLE at once — the other half of what produced the quarantines.
    func testReadOnlyDoesNotMigrate() throws {
        try seedAsApp()
        // Roll the schema version back so a migrator, if one ran, would have
        // something to do and would fail loudly on a read-only connection.
        let app = try DatabasePool(path: path)
        try app.write { db in try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v8_drop_unused_signal_indexes'") }
        try app.close()

        XCTAssertNoThrow(try DatabaseService.openReadOnly(at: path),
                         "the reader must open regardless of pending migrations, and leave them alone")

        let remaining = try DatabasePool(path: path).read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v8_drop_unused_signal_indexes'")
        }
        XCTAssertEqual(remaining, 0, "the reader re-applied a migration it does not own")
    }

    // MARK: - The type enforces it

    /// `MCPServer` takes `MCPDatabase`, which is composed only of read protocols.
    /// If someone adds a write method to that surface, this stops compiling —
    /// which is the intent. The assertion is that the server still works when it
    /// is handed nothing but reads.
    func testMCPServerRunsOnAReadOnlyHandle() throws {
        try seedAsApp { db in
            db.insertEvent(RecordingEvent(timestamp: Date(), eventType: .clipboard,
                                          appName: "Code", windowTitle: "Notes — Mull",
                                          textContent: "pagination rewrite decided"))
        }

        let reader = try DatabaseService.openReadOnly(at: path)
        let surface: MCPDatabase = reader
        _ = MCPServer(database: surface)

        XCTAssertEqual(surface.searchEvents(query: "pagination").count, 1)
    }

    /// The regression this nearly shipped with: SQLite refuses an O_RDONLY open of
    /// a WAL database when the `-shm` is missing, which is exactly the state after
    /// the app shuts down cleanly. "The agent asks while the app is closed" is
    /// ordinary, so the reader has to survive it — via `query_only`, which SQLite
    /// enforces just as hard.
    func testReadOnlyStillOpensWhenTheWalSidecarsAreGone() throws {
        try seedAsApp { db in
            db.insertEvent(RecordingEvent(timestamp: Date(), eventType: .clipboard,
                                          appName: "Code", windowTitle: "Notes — Mull",
                                          textContent: "recorded before the app quit"))
        }
        for ext in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + ext)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-shm"))

        let reader = try DatabaseService.openReadOnly(at: path)
        XCTAssertEqual(reader.searchEvents(query: "recorded").count, 1)

        // Still refuses to write, by the other mechanism.
        XCTAssertThrowsError(try reader.dbPool.write { db in
            try db.execute(sql: "DELETE FROM recording_events")
        })
    }

    /// The capture path gets append-only access. `RecordingService` holding a
    /// handle that can `deleteAllData()` was the shape of the old problem.
    func testCaptureSurfaceIsAppendOnly() throws {
        let app = try DatabaseService(path: path)
        let capture: EventWriting = app
        capture.insertEvent(RecordingEvent(timestamp: Date(), eventType: .keystroke,
                                           appName: "Code", windowTitle: nil,
                                           textContent: "typed something"))
        XCTAssertEqual(app.searchEvents(query: "typed").count, 1)
    }
}
