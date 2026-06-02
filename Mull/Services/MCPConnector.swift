import Foundation

/// Configuration for one MCP ingestion source, persisted in UserDefaults.
struct MCPSourceConfig: Codable, Equatable, Identifiable {
    /// Connector id; should be one of `FolderOntology.rawConnectors`.
    var connectorID: String
    var server: MCPClient.ServerConfig
    /// Tool to call on the server to pull items (e.g. "search_messages").
    var tool: String
    /// Static arguments passed to the tool.
    var arguments: [String: String]
    var enabled: Bool

    var id: String { connectorID }

    init(connectorID: String, server: MCPClient.ServerConfig, tool: String,
         arguments: [String: String] = [:], enabled: Bool = true) {
        self.connectorID = connectorID
        self.server = server
        self.tool = tool
        self.arguments = arguments
        self.enabled = enabled
    }
}

/// Persisted registry of MCP ingestion sources. Empty by default — nothing is
/// pulled until the user configures a source (no surprise network access).
enum MCPSourceStore {
    private static let key = "mcpSources"

    static func load() -> [MCPSourceConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([MCPSourceConfig].self, from: data)
        else { return [] }
        return list
    }

    static func save(_ sources: [MCPSourceConfig]) {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// An IngestionConnector backed by an external MCP server.
struct MCPConnector: IngestionConnector {
    let config: MCPSourceConfig
    var id: String { config.connectorID }

    func pull() async throws -> [IngestedItem] {
        let connectorID = id
        let cfg = config
        // Blocking stdio I/O runs off the cooperative pool.
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let client = MCPClient(config: cfg.server)
                // Register cleanup BEFORE connect so a failed connect (spawned
                // process, opened pipes) is still torn down — not leaked.
                defer { client.shutdown() }
                do {
                    try client.connect()
                    let text = try client.callTool(cfg.tool, arguments: cfg.arguments)
                    cont.resume(returning: MCPConnector.mapItems(text, source: connectorID))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Map a tool's text result into items. Convention: if the text is a JSON
    /// array of `{id,title,timestamp,summary}`, use it; otherwise treat the whole
    /// text as one item. (Unit-tested.)
    static func mapItems(_ text: String, source: String) -> [IngestedItem] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let data = trimmed.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return arr.enumerated().compactMap { idx, obj in
                let title = obj["title"] as? String ?? obj["subject"] as? String ?? "(untitled)"
                let summary = obj["summary"] as? String ?? obj["snippet"] as? String ?? ""
                let id = obj["id"] as? String ?? "\(source):\(stableHash(title + summary))-\(idx)"
                let ts = MCPConnector.parseTimestamp(obj["timestamp"] as? String)
                return IngestedItem(id: id, timestamp: ts ?? .distantPast,
                                    source: source, title: title, summary: summary)
            }
        }

        // Fallback: opaque text → a single item keyed by content hash.
        return [IngestedItem(id: "\(source):\(stableHash(trimmed))",
                             timestamp: .distantPast, source: source,
                             title: "\(source) pull", summary: trimmed)]
    }

    /// Parse an ISO-8601 timestamp, tolerating fractional seconds (e.g. Gmail's
    /// `…:00.123Z`). A plain `ISO8601DateFormatter` rejects those, which used to
    /// collapse valid timestamps to `.distantPast` (wrong order, lost time).
    static func parseTimestamp(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = isoFractional.date(from: s) { return d }
        return isoPlain.date(from: s)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// Deterministic FNV-1a hash (stable across runs, unlike Hasher).
    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
