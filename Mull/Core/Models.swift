import Foundation
import GRDB

// MARK: - Recording Events

/// A single captured event from the recording layer.
struct RecordingEvent: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var timestamp: Date
    var eventType: EventType
    var appName: String?
    var windowTitle: String?
    var textContent: String?
    // Capture-time enrichment (#4): computed once and stored so the selection
    // layer filters/ranks by them without recomputing. Nil for rows recorded
    // before the migration (the reader falls back to recomputing).
    var entity: String?
    var contentType: String?
    var salience: Double?
    // MODE axis (MAP-ARCHITECTURE.md): how this moment is engaged with
    // (produce/consume/decide/think/research/communicate). See `Mode`.
    var mode: String?

    enum EventType: String, Codable, DatabaseValueConvertible {
        case screenText
        case keystroke
        case clipboard
        case appSwitch
        case audio
        // Capture-fidelity #1 (MAP-ARCHITECTURE.md): the BODY text of the focused
        // window — the work itself, not just its title. Separate channel so
        // title-based heuristics (CurrentState, project inference) stay clean.
        case windowBody
    }

    static let databaseTableName = "recording_events"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Daily Summaries

/// A Auto-generated daily summary.
struct DailySummary: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var date: Date
    var content: String          // Full markdown summary
    var morningSection: String?
    var afternoonSection: String?
    var eveningSection: String?
    var learnings: String?
    var inProgress: String?
    var eventCount: Int          // Number of events that fed this summary
    var processingSeconds: Double
    var llmProvider: String
    var createdAt: Date

    static let databaseTableName = "daily_summaries"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// One-line preview for collapsed card display.
    ///
    /// The list marker is stripped. A summary's first content line is usually
    /// already a bullet, and every caller puts the preview inside something —
    /// a card, or `- **2026-06-10** — …` in now.md, which is where it rendered as
    /// `— - Opened and edited…`. A preview is a fragment; whoever displays it owns
    /// its presentation.
    var preview: String {
        let lines = content.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.hasPrefix("#") }
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else {
            return String(localized: "No activity recorded")
        }
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where first.hasPrefix(marker) {
            return String(first.dropFirst(marker.count))
        }
        return first
    }

    var dateFormatted: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: date)
    }

    var dateShort: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

extension Collection where Element == DailySummary {

    /// Split summaries into the ones recent enough to head a "recent days"
    /// section and, when there are none, the newest one that exists anyway.
    ///
    /// A section called "Recent days" listing 2026-06-10 on 2026-08-09 is not a
    /// small cosmetic problem: it is the file's own answer to "when did anything
    /// last happen", and both the user and every AI reading now.md take it at face
    /// value. The date was accurate — `daily_summaries` genuinely held one row from
    /// June, because the nightly consolidation needs an LLM provider and had not
    /// run since. What was wrong was the framing. Two months of silence is
    /// information, and it belongs in the file as itself rather than disguised as
    /// the most recent thing the user did.
    func splitByRecency(days: Int = 7, now: Date = Date())
        -> (recent: [DailySummary], newestStale: DailySummary?) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let recent = filter { $0.date >= cutoff }
        guard recent.isEmpty else { return (recent, nil) }
        return ([], self.max(by: { $0.date < $1.date }))
    }
}

// MARK: - Memory Files

/// A persistent memory entry (user, feedback, project, reference).
struct MemoryEntry: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var name: String
    var description: String
    var memoryType: MemoryType
    var content: String
    var filePath: String         // Relative path within ~/mull/memory/
    var createdAt: Date
    var updatedAt: Date

    enum MemoryType: String, Codable, DatabaseValueConvertible {
        case user
        case feedback
        case project
        case reference
    }

    static let databaseTableName = "memory_entries"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - What may be asserted as identity
    //
    // me.md is headed "Who I am" and is described as the timeless layer, safe to
    // include in every prompt. On 2026-08-15 it held four lines, and three of them
    // were one day's observation promoted to a standing trait, with the day removed:
    //
    //   "Regularly uses LINE for messaging."
    //     ← "LINE was used extensively TODAY (high activity on 10 June 2026)"
    //   "Often does heavy video editing and coding in afternoons."
    //     ← "TODAY (10 June 2026) shows a pattern: concentrated video editing…"
    //
    // Both rows were written on 10 June and never touched again — 66 days of not
    // happening, still being handed to every agent as who this person is. The
    // evidence was in the row the whole time: `content` says "today", `description`
    // says "regularly", and me.md renders `description`.
    //
    // The rule below needs no language analysis and no model. `createdAt ==
    // updatedAt` means the nightly pass wrote this once and never confirmed it (the
    // "update" action bumps `updatedAt` — see `MullEngine.applyMemoryAction`). A
    // behaviour seen on one day and not since is an observation, and CLAUDE.md §7.1
    // is exactly about not printing one of those as a claim.

    /// Seen once, and never seen again since.
    var isSingleObservation: Bool {
        Calendar.current.isDate(createdAt, inSameDayAs: updatedAt)
    }

    /// How long a once-seen behaviour may stand as identity before it has to be
    /// confirmed. A month of not recurring is the answer to "is this who they are".
    static let unconfirmedLifetime: TimeInterval = 30 * 24 * 60 * 60

    /// May this line be printed under "Who I am"?
    ///
    /// Re-observed memories always may — that is what re-observation is. A
    /// single-day one may for a month, because the day it was seen is recent enough
    /// that "this is what they do" is still a fair reading of it.
    func isIdentity(asOf now: Date = Date()) -> Bool {
        guard isSingleObservation else { return true }
        return now.timeIntervalSince(updatedAt) < Self.unconfirmedLifetime
    }

    /// The line as it goes into me.md: the claim, and the day it was last seen.
    ///
    /// The date is appended only when the description does not already carry a year.
    /// The nightly model writes one about half the time ("(updated 11 Aug 2026)",
    /// "（2026-08-09）"), and two dates on one line is worse than none.
    func identityLine(dateFormatter: DateFormatter) -> String {
        guard description.range(of: #"20\d\d"#, options: .regularExpression) == nil else {
            return "- \(description)"
        }
        return "- \(description) (\(dateFormatter.string(from: updatedAt)))"
    }
}

// MARK: - Knowledge Entries

/// A piece of extracted knowledge — not what you did, but what you learned.
///
/// Activity: "Worked on ChartVM for 3 hours"
/// Knowledge: "Chose closure-based bindings over Combine because project has no Combine dependency"
struct KnowledgeEntry: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var topic: String              // e.g. "MVVM binding strategy"
    var decision: String           // What was decided/learned
    var reasoning: String?         // Why this decision was made
    var rejected: String?          // Alternatives considered and rejected
    var project: String            // Which project this applies to
    var relatedProjects: String?   // Other projects this could apply to
    var tags: String?              // Comma-separated tags for search
    var sourceDate: Date           // When this knowledge was acquired
    var createdAt: Date

    static let databaseTableName = "knowledge_entries"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Predictions

/// A behavior prediction mull made about the user, later graded against the log.
///
/// This is how mull gets ground truth in a domain that has none (DIRECTION.md 付録A
/// "Epistemics"): we don't predict *preference* ("you should do X" — unverifiable),
/// we predict *behavior* ("you'll resume X within 2 days" — tomorrow's log
/// confirms or denies it). Grading these turns proactivity into a measurable,
/// self-correcting signal instead of a guess.
struct Prediction: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var createdAt: Date
    var project: String            // subject of the prediction
    var kind: String               // e.g. "resume"
    var statement: String          // human-readable prediction
    var dueAt: Date                // it should have come true by this time
    var outcome: String            // "pending" | "hit" | "miss"
    var gradedAt: Date?

    static let databaseTableName = "predictions"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - mull Lock

/// Tracks mull execution state for the 3-gate trigger system.
struct mullLock: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var lastSummaryAt: Date?
    var holderPID: Int32?
    /// When the current holder acquired the lock. Staleness is measured from
    /// THIS, not `lastSummaryAt` (last *success*), so a live, long-running pass
    /// isn't wrongly reclaimed into a second concurrent run.
    var acquiredAt: Date?
    var sessionsSinceLast: Int

    static let databaseTableName = "mull_lock"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Enums

enum LLMProvider: String, CaseIterable, Identifiable {
    /// Default for fresh installs: no cloud processing until the user opts in.
    /// Keeps "all data stays on your Mac" true out of the box (rule-based only).
    case off = "off"
    case gemini = "gemini"
    case local = "local"
    case localOpenAI = "localopenai"
    case claude = "claude"
    case openai = "openai"

    var id: String { rawValue }

    /// Whether this provider sends data off-device.
    var isCloud: Bool {
        switch self {
        case .off, .local, .localOpenAI: false
        case .gemini, .claude, .openai: true
        }
    }

    var displayName: String {
        switch self {
        case .off: String(localized: "Off — local rule-based only")
        case .gemini: "Gemini Flash"
        case .local: "Local (Ollama)"
        case .localOpenAI: String(localized: "Local (OpenAI-compatible)")
        case .claude: "Claude API"
        case .openai: "OpenAI API"
        }
    }
}

