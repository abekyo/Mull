import Foundation

/// What a component is allowed to do to the database, stated in its own type.
///
/// Before this file there was exactly one protocol in the whole codebase, and
/// every consumer took `DatabaseService` whole. Twenty-one types held a handle
/// that can `deleteAllData()`, including `RecordingService`, whose entire need is
/// `insertEvent`. Two things followed from that:
///
/// - **Nothing could be substituted.** The capture layer had no seam, so none of
///   it was tested — and the capture layer is the one asymmetry the product is
///   built on.
/// - **The MCP surface had no boundary.** `MullMCP`'s main says "read-only access
///   to mull's existing DB" and was enforced by nothing; the binary held a type
///   that could drop every table. Two writers on one SQLite file is what produced
///   the 30 quarantine files.
///
/// The split is by what the caller does, not by table, because that is the axis
/// the harm ran along. The measured surface says the same thing: of twenty-one
/// consumers, eleven use `fetchEvents` and nothing else.
///
/// `DatabaseService` implements all of these. It stays one connection owner — the
/// pool, the migrations and the recovery paths are genuinely one concern — but
/// nobody has to accept all of it to read yesterday's events.

// MARK: - The territory (MAP-ARCHITECTURE: `_raw`)

/// Reading recorded events. The most-wanted slice by a wide margin.
protocol EventReading: AnyObject, Sendable {
    func fetchEvents(from start: Date, to end: Date) -> [RecordingEvent]
    func fetchCandidates(query: String, since: Date, useFTS: Bool, limit: Int) -> [RecordingEvent]
    func searchEvents(query: String, limit: Int) -> [RecordingEvent]
    func countEvents(from start: Date, to end: Date) -> Int
    func dailyEventCounts(from start: Date, to end: Date) -> [Date: Int]
}

extension EventReading {
    /// Protocols cannot carry default parameter values, and the concrete method
    /// has had `limit: Int = 100` since it was written. Restore it here so
    /// narrowing a call site's type does not change how it reads.
    func searchEvents(query: String) -> [RecordingEvent] {
        searchEvents(query: query, limit: 100)
    }
}

/// Appending recorded events. Deliberately append-only: capture never edits or
/// deletes, and the two callers that record (`RecordingService`, `EmailService`)
/// should not be able to.
protocol EventWriting: AnyObject, Sendable {
    func insertEvent(_ event: RecordingEvent)
}

// MARK: - The map (what was derived from the territory)

/// Reading the derived layers — summaries, extracted decisions, memories.
/// Everything here is regenerable from events, which is why reading it is a
/// separate permission from reading them.
protocol DerivedReading: AnyObject, Sendable {
    func fetchRecentSummaries(limit: Int) -> [DailySummary]
    func fetchSummary(for date: Date) -> DailySummary?
    func searchSummaries(query: String) -> [DailySummary]
    func fetchAllKnowledge() -> [KnowledgeEntry]
    func fetchKnowledge(forProject project: String) -> [KnowledgeEntry]
    func searchKnowledge(query: String, limit: Int) -> [KnowledgeEntry]
    func findRelevantKnowledge(context: String, limit: Int) -> [KnowledgeEntry]
    func fetchAllMemories() -> [MemoryEntry]
}

extension DerivedReading {
    func searchKnowledge(query: String) -> [KnowledgeEntry] { searchKnowledge(query: query, limit: 20) }
    func findRelevantKnowledge(context: String) -> [KnowledgeEntry] { findRelevantKnowledge(context: context, limit: 3) }
}

/// The calibration loop's own store. Split out because `PredictionEngine` is the
/// only thing that touches it, and it touches nothing else.
protocol PredictionStoring: AnyObject, Sendable {
    func insertPrediction(_ prediction: Prediction)
    func fetchDuePredictions(asOf date: Date) -> [Prediction]
    func hasPendingPrediction(project: String, kind: String) -> Bool
    func updatePrediction(_ prediction: Prediction)
    func fetchGradedPredictions(since: Date) -> [Prediction]
}

// MARK: - Composed surfaces

/// Everything the MCP surface may touch: reads, and only reads.
///
/// This is the boundary that `MullMCP` was documented to have and did not. An
/// agent asking mull what happened cannot, through this type, write a row —
/// which matters because the writer is a different process, and SQLite's answer
/// to two writers on one WAL was the quarantines.
typealias MCPDatabase = EventReading & DerivedReading

/// Reading events and appending to them: the capture path, and nothing more.
typealias CaptureDatabase = EventReading & EventWriting

// MARK: - DatabaseService is the one implementation

extension DatabaseService: EventReading, EventWriting, DerivedReading, PredictionStoring {}
