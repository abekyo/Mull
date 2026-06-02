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

    enum EventType: String, Codable, DatabaseValueConvertible {
        case screenText
        case keystroke
        case clipboard
        case appSwitch
        case audio
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
    var preview: String {
        let lines = content.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.hasPrefix("#") }
        return lines.first ?? "No activity recorded"
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
/// This is how mull gets ground truth in a domain that has none (PRODUCT.md
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
    case claude = "claude"
    case openai = "openai"

    var id: String { rawValue }

    /// Whether this provider sends data off-device.
    var isCloud: Bool {
        switch self {
        case .off, .local: false
        case .gemini, .claude, .openai: true
        }
    }

    var displayName: String {
        switch self {
        case .off: "Off — local rule-based only"
        case .gemini: "Gemini Flash (Free)"
        case .local: "Local (Ollama)"
        case .claude: "Claude API"
        case .openai: "OpenAI API"
        }
    }
}

