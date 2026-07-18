import Foundation

/// The proactive loop (DIRECTION §7 / §9.2) — the self-driving core that makes
/// mull ACT, not just answer. A passive selection layer does nothing until an
/// agent calls it; this is the part that fires on its own.
///
/// When you switch into a project (a state change), it runs one end-to-end pass:
///   1. ANCHOR  — read the present (CurrentState: the active entity).
///   2. SELECT  — pull the relevant slice for it (the selection layer), plus any
///                decision you already recorded about it.
///   3. JUDGE   — an LLM brief when a provider is configured; a structured
///                digest otherwise, so the loop always closes.
///   4. WRITE   — persist it as an editable, provenance-protected Curator block
///                (your edits are kept, and become relevance labels later).
///   5. HAND OFF— deliver it as a notification.
///
/// Everything else (capture, structuring, retrieval) is scaffolding for this.
/// State is main-actor isolated: `tick()` is driven from AppState's main-thread
/// refresh loop, while `brief()` runs on the global executor — without isolation the
/// two would read and write `lastEntity`/`lastCheckAt`/`lastFiredAt` concurrently.
@MainActor
final class ProactiveLoop {

    private let database: DatabaseService
    private let llm: LLMClient

    private var lastEntity: String?
    private var lastCheckAt: Date = .distantPast
    private var lastFiredAt: Date = .distantPast
    /// True while a brief is being written. `judge()` calls an LLM, which routinely
    /// outlives the 180s cooldown; two overlapping briefs both reach
    /// `Curator.curate("proactive.md")`, a read-merge-write, and one is lost.
    private var briefing = false

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
        guard !briefing else { return }
        lastCheckAt = now

        let db = database
        let previousEntity = lastEntity
        let canFire = now.timeIntervalSince(lastFiredAt) >= cooldown

        // Steps 1 and 2 are DB work — `CurrentState.current`, a 200-row candidate
        // fetch and a full ranking pass — and they used to run on the main thread
        // every 20 seconds straight off AppState's tick. Do them off-main and come
        // back to decide, since the decision touches main-actor state.
        Task.detached {
            // 1. Anchor on the present. Needs window-title capture (Accessibility);
            //    until that's granted, activeEntity is nil and the loop stays dormant.
            guard let entity = CurrentState.current(database: db).activeEntity else { return }
            guard entity != previousEntity else { return }   // only on a switch
            guard canFire else { return }                    // not too soon

            // 2. Select the relevant slice for this project.
            let since: TimeInterval = 14 * 86_400
            let events = db.fetchCandidates(
                query: entity, since: now.addingTimeInterval(-since), useFTS: false, limit: 200)
            let items = Selection.rank(events: events, query: "", entity: entity,
                                       type: nil, now: now, since: since, limit: 6)

            // Knowledge entries live in their own table, so the ranking pass above —
            // which reads recording_events — can never surface one. This was
            // ProactiveEngine's "You know this" notification; it is folded in here
            // instead of firing as a second banner, and it anchors on the entity
            // rather than on the raw window title it used to match against.
            let prior = db.findRelevantKnowledge(context: entity, limit: 1).first
                .flatMap { entry -> String? in
                    // Something you decided today isn't news — it's what you just did.
                    let days = Calendar.current
                        .dateComponents([.day], from: entry.sourceDate, to: now).day ?? 0
                    guard days >= 1 else { return nil }
                    var line = "\(entry.topic): \(entry.decision)"
                    if let why = entry.reasoning, !why.isEmpty { line += " — why: \(why)" }
                    return line
                }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !items.isEmpty else { self.lastEntity = entity; return }  // nothing to say yet
                guard !self.briefing else { return }

                // Per-project cooldown on top of this loop's own `cooldown`, so
                // hopping away and back doesn't re-announce the same project.
                guard Notifier.shared.claimProjectAnnouncement(entity) else {
                    self.lastEntity = entity
                    return
                }

                self.lastEntity = entity
                self.lastFiredAt = Date()
                self.briefing = true
                Task { await self.brief(entity: entity, items: items, priorDecision: prior) }
            }
        }
    }

    // MARK: - Judge → write-back → hand off

    /// Caller sets `briefing`; this clears it on every exit path.
    private func brief(entity: String, items: [Selection.Result], priorDecision: String?) async {
        defer { briefing = false }

        let recent = items.map { "- \($0.type): \($0.text)" }.joined(separator: "\n")
        // The recorded decision joins the same digest the judge reads: "you already
        // settled this" is often the single most useful thing to know on resumption,
        // and it should shape the headline rather than trail it.
        let digest = priorDecision.map { "\(recent)\n- decision: \($0)" } ?? recent
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

        // 5. Hand off — through the app's one notifier, so this shares a rate limit
        //    with ProactiveEngine instead of running a second, blind one.
        Notifier.shared.send(id: "proactive-brief",
                             title: "Resume \(entity)", body: headline)
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

}
