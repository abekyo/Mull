import Foundation
import UserNotifications

/// The proactive loop (DIRECTION §7 / §9.2) — the self-driving core that makes
/// mull ACT, not just answer. A passive selection layer does nothing until an
/// agent calls it; this is the part that fires on its own.
///
/// When you switch into a project (a state change), it runs one end-to-end pass:
///   1. ANCHOR  — read the present (CurrentState: the active entity).
///   2. SELECT  — pull the relevant slice for it (the selection layer).
///   3. JUDGE   — an LLM brief when a provider is configured; a structured
///                digest otherwise, so the loop always closes.
///   4. WRITE   — persist it as an editable, provenance-protected Curator block
///                (your edits are kept, and become relevance labels later).
///   5. HAND OFF— deliver it as a notification.
///
/// Everything else (capture, structuring, retrieval) is scaffolding for this.
final class ProactiveLoop {

    private let database: DatabaseService
    private let llm: LLMClient

    private var lastEntity: String?
    private var lastCheckAt: Date = .distantPast
    private var lastFiredAt: Date = .distantPast

    /// Throttle the DB-touching check; the active entity rarely changes faster.
    private let checkInterval: TimeInterval = 20
    /// Floor between two briefs, so rapid project hopping isn't spammy.
    private let cooldown: TimeInterval = 180

    init(database: DatabaseService, llm: LLMClient = LLMClient()) {
        self.database = database
        self.llm = llm
    }

    /// Cheap to call often (from AppState's refresh tick). Throttled internally;
    /// only acts when the active entity changed and there's material to surface.
    func tick() {
        let now = Date()
        guard now.timeIntervalSince(lastCheckAt) >= checkInterval else { return }
        lastCheckAt = now

        // 1. Anchor on the present. Needs window-title capture (Accessibility);
        //    until that's granted, activeEntity is nil and the loop stays dormant.
        guard let entity = CurrentState.current(database: database).activeEntity else { return }
        guard entity != lastEntity else { return }                       // only on a switch
        guard now.timeIntervalSince(lastFiredAt) >= cooldown else { return } // not too soon

        // 2. Select the relevant slice for this project.
        let since: TimeInterval = 14 * 86_400
        let events = database.fetchCandidates(
            query: entity, since: now.addingTimeInterval(-since), useFTS: false, limit: 200)
        let items = Selection.rank(events: events, query: "", entity: entity,
                                   type: nil, now: now, since: since, limit: 6)
        guard !items.isEmpty else { lastEntity = entity; return }        // nothing to say yet

        lastEntity = entity
        lastFiredAt = now
        Task { await self.brief(entity: entity, items: items) }
    }

    // MARK: - Judge → write-back → hand off

    private func brief(entity: String, items: [Selection.Result]) async {
        let digest = items.map { "- \($0.type): \($0.text)" }.joined(separator: "\n")
        let headline = await judge(entity: entity, digest: digest)

        // 4. Write-back: one editable block per project, updated in place. The
        //    Curator protects any edits the human makes to it.
        let block = ContextBlock(
            id: "brief:\(ContextBlockFile.slug(entity))",
            source: .agent,
            content: "## \(entity)\n\n\(headline)\n\nRecent:\n\(digest)",
            agentHash: nil)
        _ = Curator.curate(
            relativePath: "proactive.md",
            header: "# Proactive briefs\n\n_What mull surfaced when you returned to each project. Edit freely — your edits are kept._",
            pinnedContent: nil, agentBlocks: [block])

        // 5. Hand off.
        notify(title: "Resume \(entity)", body: headline)
    }

    /// 3. Judgment. LLM when a provider is configured — and only the already
    /// SensitiveText-filtered selection reaches it. Structured fallback otherwise.
    private func judge(entity: String, digest: String) async -> String {
        let fallback = "Back on \(entity). Most recent threads below — pick up where you left off."
        guard llm.provider != "off" else { return fallback }
        let prompt = """
        I just switched back to working on "\(entity)". My most recent related activity:
        \(digest)

        In ONE or TWO sentences, tell me the single most useful thing to resume right now —
        the open thread, the last decision, or the next concrete action. Be specific. No preamble.
        """
        do {
            let out = try await llm.complete(
                system: "You are a terse, specific proactive work assistant. No filler.",
                prompt: prompt, options: .init(maxTokens: 120))
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        } catch {
            return fallback
        }
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "proactive-brief", content: content, trigger: nil)
            center.add(request)
        }
    }
}
