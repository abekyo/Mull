import Foundation

/// One item pulled from an external source (an email, a calendar event, a file…).
/// Deliberately small and source-agnostic: the pull is mechanical (no AI), so the
/// connector only normalizes into this shape. Synthesis (Phase C) is what later
/// turns these into organized category documents.
struct IngestedItem: Codable, Equatable {
    /// Stable id from the source, used for dedup (e.g. message id, event id).
    let id: String
    let timestamp: Date
    /// Connector id this came from (matches VaultLayout.rawConnectors).
    let source: String
    let title: String
    /// Short, privacy-safe summary. Connectors must not put secrets here.
    let summary: String
    var metadata: [String: String]

    init(id: String, timestamp: Date, source: String, title: String,
         summary: String, metadata: [String: String] = [:]) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.title = title
        self.summary = summary
        self.metadata = metadata
    }
}

/// A pull-based source mull ingests from. The pull is mechanical and must not
/// require an LLM (per Direction v3: "just pulling MCP data doesn't need AI").
protocol IngestionConnector {
    /// Stable id; should match one of `VaultLayout.rawConnectors`.
    var id: String { get }
    /// Pull the latest items. Throwing is fine — IngestionService isolates failures.
    func pull() async throws -> [IngestedItem]
}
