import Foundation

/// Orchestrates ingestion (Direction v3, Phase B): runs each connector, lands
/// the pull into the immutable `_raw/` zone, and writes a per-connector digest
/// into `09_inbox/` so freshly ingested data is visible while it awaits
/// synthesis (Phase C). The pull itself is mechanical — no LLM.
final class IngestionService {

    private let connectors: [IngestionConnector]
    private var timer: Timer?
    /// True while a pull pass is in flight. Guards against the scheduled timer
    /// and the immediate kickoff (or two timer ticks) overlapping — which would
    /// race two pulls of the same connector through RawStore.land.
    @MainActor private var inFlight = false

    struct Outcome {
        let connector: String
        let pulled: Int
        let new: Int
        let error: String?
    }

    init(connectors: [IngestionConnector]) {
        self.connectors = connectors
    }

    /// Build from the persisted MCP source registry (enabled sources only).
    static func fromConfiguredSources() -> IngestionService {
        let connectors = MCPSourceStore.load()
            .filter { $0.enabled }
            .map { MCPConnector(config: $0) as IngestionConnector }
        return IngestionService(connectors: connectors)
    }

    var hasConnectors: Bool { !connectors.isEmpty }

    @MainActor private func beginRun() -> Bool {
        if inFlight { return false }
        inFlight = true
        return true
    }

    @MainActor private func endRun() { inFlight = false }

    /// Pull every connector once. Failures are isolated per connector.
    /// No-op if a previous pass is still running (prevents overlapping pulls).
    @discardableResult
    func runOnce() async -> [Outcome] {
        guard await beginRun() else { return [] }
        defer { Task { @MainActor in self.endRun() } }

        var outcomes: [Outcome] = []
        for connector in connectors {
            do {
                let items = try await connector.pull()
                let fresh = RawStore.land(items, connector: connector.id)
                writeInboxDigest(connector: connector.id)
                outcomes.append(Outcome(connector: connector.id, pulled: items.count,
                                        new: fresh.count, error: nil))
            } catch {
                print("[mull] ingestion '\(connector.id)' failed: \(error.localizedDescription)")
                outcomes.append(Outcome(connector: connector.id, pulled: 0, new: 0,
                                        error: error.localizedDescription))
            }
        }
        return outcomes
    }

    /// Periodically pull in the background. No-op if no connectors configured.
    func schedule(every interval: TimeInterval) {
        guard hasConnectors else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.runOnce() }
        }
        // Kick off an immediate first pull.
        Task { await runOnce() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Inbox digest

    /// Write the most recent ingested items for a connector into
    /// `09_inbox/<connector>.md`, Curator-managed so user notes survive.
    private func writeInboxDigest(connector: String) {
        let recent = RawStore.load(connector: connector)
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(15)

        let lines = recent.map { item -> String in
            let when = item.timestamp == .distantPast ? "" :
                " · \(Self.dateFormatter.string(from: item.timestamp))"
            let summary = item.summary.isEmpty ? "" : " — \(item.summary.prefix(120))"
            return "- **\(item.title)**\(when)\(summary)"
        }

        let body = lines.isEmpty ? "_(nothing ingested yet)_"
            : "## Recent from \(connector)\n\n" + lines.joined(separator: "\n")

        let header = "# 09 Inbox — \(connector)\n\n_Freshly ingested, awaiting synthesis._"
        let block = ContextBlock(id: "recent", source: .agent, content: body, agentHash: nil)
        _ = Curator.curate(relativePath: "09_inbox/\(connector).md",
                           header: header, pinnedContent: nil, agentBlocks: [block])
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()
}
