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

    /// Called when a source that was working starts failing. Set by AppState.
    ///
    /// The scheduled pull used to throw its `[Outcome]` away, so a source that
    /// broke (an expired token, a command that no longer exists) went on failing
    /// every 30 minutes in silence — visible only to someone who opened Settings
    /// and pressed "Pull now" by hand.
    @MainActor var onFailure: ((_ connector: String, _ error: String) -> Void)?

    /// Connectors whose most recent pull failed, so the same breakage is
    /// announced once rather than on every tick.
    @MainActor private var failingConnectors: Set<String> = []

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

    /// Announce newly-broken sources, and forget the ones that recovered.
    @MainActor
    private func report(_ outcomes: [Outcome]) {
        for outcome in outcomes {
            guard let error = outcome.error else {
                failingConnectors.remove(outcome.connector)
                continue
            }
            guard failingConnectors.insert(outcome.connector).inserted else { continue }
            onFailure?(outcome.connector, error)
        }
    }

    /// Periodically pull in the background. No-op if no connectors configured.
    func schedule(every interval: TimeInterval) {
        guard hasConnectors else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                await self.report(self.runOnce())
            }
        }
        // Kick off an immediate first pull.
        Task { await report(runOnce()) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // A per-connector digest used to be written to `09_inbox/<connector>.md` here,
    // so a pull was visible somewhere. It went with the numbered folders on
    // 2026-08-09 (DIRECTION §6.1): the pulled items are in `_raw/<connector>/`
    // either way, and the one thing the digest added — "did the pull work?" — is
    // answered properly by the per-connector outcomes in Settings, which say why
    // when it did not.
}
