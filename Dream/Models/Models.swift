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

/// A Dream-generated daily summary.
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
    var filePath: String         // Relative path within ~/Dream/memory/
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

// MARK: - Dream Lock

/// Tracks Dream execution state for the 3-gate trigger system.
struct DreamLock: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var lastDreamAt: Date?
    var holderPID: Int32?
    var sessionsSinceLast: Int

    static let databaseTableName = "dream_lock"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Analytics Event

/// Anonymous usage metric — never contains content.
struct AnalyticsEvent: Codable {
    var appVersion: String
    var os: String
    var hardware: String
    var event: String
    var value: String?
    var plan: String
    var timestamp: Date
}

// MARK: - Enums

enum LLMProvider: String, CaseIterable, Identifiable {
    case local = "local"
    case claude = "claude"
    case openai = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: "Local (Ollama)"
        case .claude: "Claude API"
        case .openai: "OpenAI API"
        }
    }
}

enum AIExportDestination: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case chatgpt = "ChatGPT"
    case clipboard = "Clipboard"

    var id: String { rawValue }

    var url: URL? {
        switch self {
        case .claude: URL(string: "https://claude.ai")
        case .chatgpt: URL(string: "https://chatgpt.com")
        case .clipboard: nil
        }
    }

    var icon: String {
        switch self {
        case .claude: "brain.head.profile"
        case .chatgpt: "bubble.left.and.bubble.right"
        case .clipboard: "doc.on.clipboard"
        }
    }
}

/// 3-layer context system for token-conscious AI export.
///
///   me.md   (~200 tokens) — Always safe. "Who are you?"
///   now.md  (~500 tokens) — Current context. "What are you doing?"
///   full.md (~1500 tokens) — Everything. "Onboard me completely."
enum ExportContextLayer: String, CaseIterable, Identifiable {
    case profile = "Profile"
    case standard = "Standard"
    case full = "Full"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .profile: "Identity + preferences"
        case .standard: "Identity + today's work + patterns"
        case .full:     "Everything including raw input"
        }
    }

    var tokenEstimate: String {
        switch self {
        case .profile:  "~200 tokens"
        case .standard: "~700 tokens"
        case .full:     "~1,500+ tokens"
        }
    }

    var icon: String {
        switch self {
        case .profile:  "person.fill"
        case .standard: "briefcase.fill"
        case .full:     "brain.head.profile.fill"
        }
    }

    var files: [String] {
        switch self {
        case .profile:  ["me.md"]
        case .standard: ["me.md", "now.md"]
        case .full:     ["full.md"]
        }
    }
}
