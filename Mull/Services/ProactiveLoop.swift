import Foundation

/// The proactive loop (DIRECTION §9.2) — the self-driving core that makes
/// mull ACT, not just answer. A passive selection layer does nothing until an
/// agent calls it; this is the part that fires on its own.
///
/// When you switch into a project (a state change), it runs one end-to-end pass:
///   1. ANCHOR  — read the present (CurrentState: the active entity).
///   2. SELECT  — pull the relevant slice for it (the selection layer), plus any
///                decision you already recorded about it.
///   3. JUDGE   — an LLM brief when a provider is configured; a rule-based
///                factual headline otherwise, so the loop always closes.
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

    private let database: MCPDatabase
    private let llm: LLMClient

    private var lastEntity: String?
    /// An entity seen on exactly one check so far. A switch only counts once the
    /// same entity shows up on two consecutive checks (~20s apart) — glancing at
    /// another window for a few seconds is not a project switch, and briefing on
    /// it made the loop fire constantly during normal window-hopping.
    private var pendingEntity: String?
    private var lastCheckAt: Date = .distantPast
    private var lastFiredAt: Date = .distantPast
    /// True while a brief is being written. `judge()` calls an LLM, which routinely
    /// outlives the 180s cooldown; two overlapping briefs both reach
    /// `Curator.curate("proactive.md")`, a read-merge-write, and one is lost.
    private var briefing = false

    /// Throttle the DB-touching check; the active entity rarely changes faster.
    private let checkInterval: TimeInterval = 20
    /// Floor between two briefs. Was 180s, which meant a banner every three
    /// minutes for anyone rotating between projects — the single loudest thing
    /// in the app. A brief is a resumption aid, not a ticker; fifteen minutes
    /// between any two is still prompt for a real context switch.
    private let cooldown: TimeInterval = 900

    static let briefsFile = "proactive.md"

    init(database: MCPDatabase, llm: LLMClient = LLMClient()) {
        self.database = database
        self.llm = llm
        Self.resetLegacyBriefsOnce()
    }

    /// Cheap to call often (from AppState's refresh tick). Throttled internally;
    /// only acts when the active entity changed and there's material to surface.
    func tick() {
        // Off by default (Settings › General). The resumption predicate is still
        // "the active entity changed", which briefs on ordinary window-hopping
        // between two live projects — "Back on Mull — last worked on earlier
        // today" is a banner about the present, not a resumption. Until the
        // predicate keys on genuine absence (last activity on the entity hours
        // ago, cooldowns that survive relaunch), the whole pass is opt-in —
        // including the proactive.md write-back and the LLM judge call, which
        // would otherwise keep spending quietly on briefs nobody sees.
        guard UserDefaults.standard.bool(forKey: "proactiveBriefs") else { return }

        let now = Date()
        guard now.timeIntervalSince(lastCheckAt) >= checkInterval else { return }
        guard !briefing else { return }
        lastCheckAt = now

        let db = database
        let previousEntity = lastEntity
        let pending = pendingEntity
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

            // Dwell: the first check that sees a new entity only nominates it.
            // It has to still be the active entity on the next check to count.
            guard entity == pending else {
                await MainActor.run { [weak self] in self?.pendingEntity = entity }
                return
            }

            // Inside the cooldown, absorb the switch silently instead of leaving
            // it armed: before this, a switch during cooldown fired the moment the
            // cooldown expired — a banner about something minutes stale.
            guard canFire else {
                await MainActor.run { [weak self] in self?.lastEntity = entity }
                return
            }

            // 2. Select the relevant slice for this project. Keystroke buffers and
            //    app switches never make a readable "Recent" line — a romaji IME
            //    fragment ("kannzi", "zixyouuo") is typing, not a thread — so they
            //    are excluded here the same way CurrentState.recentActions excludes
            //    them. Over-fetch (24) because the digest dedups aggressively below.
            let since: TimeInterval = 14 * 86_400
            let events = db.fetchCandidates(
                query: entity, since: now.addingTimeInterval(-since), useFTS: false, limit: 200)
                .filter { $0.eventType != .keystroke && $0.eventType != .appSwitch }
            let items = Selection.rank(events: events, query: "", entity: entity,
                                       type: nil, now: now, since: since, limit: 24)

            // Format for a human before deciding to fire: after deduping repeated
            // window titles and dropping lines that only echo the entity's own
            // name, a project can turn out to have nothing worth saying.
            let lines = Self.digestLines(entity: entity, items: items)
            let fallback = Self.ruleHeadline(entity: entity, items: items, now: now)

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
                guard !lines.isEmpty else { self.lastEntity = entity; return }  // nothing to say yet
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
                Task { await self.brief(entity: entity, lines: lines,
                                        fallback: fallback, priorDecision: prior) }
            }
        }
    }

    // MARK: - Judge → write-back → hand off

    /// Caller sets `briefing`; this clears it on every exit path.
    private func brief(entity: String, lines: [String], fallback: String, priorDecision: String?) async {
        defer { briefing = false }

        let recent = lines.joined(separator: "\n")
        // The recorded decision joins the same digest the judge reads: "you already
        // settled this" is often the single most useful thing to know on resumption,
        // and it should shape the headline rather than trail it.
        let digest = priorDecision.map { "\(recent)\n- \(Self.label("decision"))\($0)" } ?? recent
        let headline = await judge(entity: entity, digest: digest, fallback: fallback)

        // 4. Write-back: one editable block per project, updated in place. The
        //    Curator protects any edits the human makes to it.
        //
        //    `managedPrefixes: ["brief:"]` makes this pass the owner of every
        //    brief block, so blocks whose entity no longer passes today's judgment
        //    (an app name, a filename — fossils of older extraction) are pruned
        //    instead of accumulating forever. Blocks that still qualify are
        //    re-submitted unchanged so the prune keeps them; human-edited blocks
        //    are protected by the Curator either way.
        let newBlock = ContextBlock(
            id: "brief:\(ContextBlockFile.slug(entity))",
            source: .agent,
            // `headline` may come from an LLM, so it is flattened to a paragraph:
            // a reply that happened to start a list or a heading would otherwise
            // splice its own structure into the middle of this block.
            content: "## \(entity)\n\n\(MarkdownDoc.inline(headline, limit: 400))\n\n\(Self.recentHeading)\n\n\(digest)",
            agentHash: nil)
        let existing = ContextBlockFile.parse(MullDirectory.read(Self.briefsFile) ?? "").blocks
        let kept = existing.filter {
            $0.source == .agent && $0.id.hasPrefix("brief:")
                && $0.id != newBlock.id && Self.stillBriefable($0)
        }
        _ = Curator.curate(
            relativePath: Self.briefsFile,
            header: Self.fileHeader,
            pinnedContent: nil, agentBlocks: kept + [newBlock], managedPrefixes: ["brief:"])

        // 5. Hand off — through the app's one notifier, so this shares a rate limit
        //    with ProactiveEngine instead of running a second, blind one.
        Notifier.shared.send(id: "proactive-brief",
                             title: Self.notificationTitle(entity), body: headline)
    }

    /// 3. Judgment. LLM when a provider is configured — and only the already
    /// SensitiveText-filtered selection reaches it. Rule-based factual fallback
    /// otherwise (`ruleHeadline`), never a canned phrase.
    private func judge(entity: String, digest: String, fallback: String) async -> String {
        guard llm.provider != "off" else { return fallback }
        let prompt = """
        I just switched back to working on "\(entity)". My most recent related activity:
        \(digest)

        In ONE or TWO sentences, tell me the single most useful thing to resume right now —
        the open thread, the last decision, or the next concrete action. Be specific. No preamble.
        Answer in the language the activity itself is written in.
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

    // MARK: - Digest formatting (pure, testable)

    /// Human-readable "Recent" lines from ranked selection results.
    ///
    /// What the raw dump used to show — and why each rule exists:
    ///   - the same window title six times   → dedup on normalized text
    ///   - "元のプロファイル — Mozilla Firefox" under the 元のプロファイル brief
    ///     → a line whose every segment is the entity itself or app chrome says
    ///       nothing; drop it, and strip those segments from lines that survive
    ///   - "- activity: <text>"              → internal type vocabulary; only
    ///     note / error / decision carry a (localized) label, the rest is the
    ///     when + where + what the label was standing in for
    nonisolated static func digestLines(
        entity: String, items: [Selection.Result], limit: Int = 6,
        japanese: Bool = isJapanese
    ) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items {
            guard let text = displayText(entity: entity, item: item) else { continue }
            let key = normalized(text)
            guard seen.insert(key).inserted else { continue }

            let when = TimeFormat.personDay(item.timestamp)
            let app = item.app.map { " (\($0))" } ?? ""
            // `text` is the user's clipboard or a window title — arbitrary, and
            // routinely multi-line. Interpolated raw it ended the list at its first
            // newline and ran the remainder together as prose: a copied OneTab dump
            // of eight tab titles did exactly that, four near-identical times in a
            // row, and is the single worst-reading passage in the shipped vault.
            out.append("- \(when)\(app) \(label(item.type, japanese: japanese))\(MarkdownDoc.inline(text, limit: 140))")
            if out.count >= limit { break }
        }
        return out
    }

    /// The factual headline when no LLM is configured. Not a summary — just what
    /// the records support: when the project was last touched and where.
    nonisolated static func ruleHeadline(
        entity: String, items: [Selection.Result], now: Date = Date(),
        japanese: Bool = isJapanese
    ) -> String {
        guard let latest = items.map(\.timestamp).max() else {
            return japanese ? "「\(entity)」に戻りました。" : "Back on \(entity)."
        }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: latest), to: calendar.startOfDay(for: now)
        ).day ?? 0

        let appCounts = Dictionary(grouping: items.compactMap(\.app), by: { $0 })
        let mainApp = appCounts.max { $0.value.count < $1.value.count }?.key

        if japanese {
            let when = days <= 0 ? "今日" : days == 1 ? "昨日" : "\(days)日前"
            var s = "「\(entity)」の続き。最後の作業は\(when)"
            if let mainApp { s += "、主に \(mainApp)" }
            return s + "。"
        } else {
            let when = days <= 0 ? "earlier today" : days == 1 ? "yesterday" : "\(days) days ago"
            var s = "Back on \(entity) — last worked on \(when)"
            if let mainApp { s += ", mostly in \(mainApp)" }
            return s + "."
        }
    }

    /// Strip segments that only repeat the brief's own frame — the entity name,
    /// the app's name, browser/editor chrome — and return what remains, or nil
    /// when nothing does (the line carried no information beyond "you were there").
    nonisolated private static func displayText(entity: String, item: Selection.Result) -> String? {
        let noise = Set([entity.lowercased(), item.app?.lowercased() ?? ""])
        let segments = ProjectNames.segments(of: item.text).filter { segment in
            let lower = segment.lowercased()
            return !segment.isEmpty && !noise.contains(lower) && !ProjectNames.appNames.contains(lower)
        }
        guard !segments.isEmpty else { return nil }
        return segments.joined(separator: " — ")
    }

    /// Dedup key: case- and whitespace-insensitive prefix, so the 5-second window
    /// poller's near-identical titles collapse into one line.
    nonisolated private static func normalized(_ text: String) -> String {
        String(text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
    }

    nonisolated private static func label(_ type: String, japanese: Bool = isJapanese) -> String {
        switch type {
        case "note": return japanese ? "メモ: " : "note: "
        case "error": return japanese ? "エラー: " : "error: "
        case "decision": return japanese ? "決定: " : "decision: "
        default: return ""
        }
    }

    // MARK: - File lifecycle

    /// Does this previously-written brief block still name something mull would
    /// brief on today? The entity is the block's `## heading`; re-judging it on
    /// every write is what lets a tightened `ProjectNames` retroactively clean
    /// the file instead of preserving old mistakes forever.
    nonisolated static func stillBriefable(_ block: ContextBlock) -> Bool {
        guard let heading = block.content.components(separatedBy: "\n").first,
              heading.hasPrefix("## ") else { return false }
        let name = String(heading.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return Entity.from(name) == name
    }

    /// One-time cleanup of the accumulated legacy file. Before `managedPrefixes`
    /// ownership, every entity ever briefed on stayed in proactive.md forever —
    /// including ones today's extraction would reject, and blocks written before
    /// the SensitiveText filter existed. `retract` withdraws mull's own blocks
    /// only; anything the user edited is promoted to `.human` and kept.
    /// V2 re-runs it for the markdown restructure: blocks written before
    /// `digestLines` flattened foreign text still contain raw multi-line clipboard
    /// dumps, which no amount of re-rendering fixes — the newlines are in the
    /// stored content. Blocks the user edited are `.human` and are kept, mess and
    /// all; that promise outranks tidiness, and mull will not quietly delete
    /// someone's writing to make a file look better.
    nonisolated private static func resetLegacyBriefsOnce() {
        let key = "ProactiveLoop.briefsResetV2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // Only remember it as done if it actually was: an unwritable vault here
        // would otherwise burn the one-time flag and leave the legacy blocks in
        // place forever.
        guard Curator.retract(relativePath: briefsFile, idPrefixes: ["brief:"]).written else { return }
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: - Localized fixed text

    /// The briefs file is read by its owner, not by an AI — so unlike me.md/now.md
    /// it follows the reader's language.
    nonisolated static var isJapanese: Bool { UserLanguage.isJapanese }

    nonisolated static var fileHeader: String {
        MarkdownDoc.header(
            title: isJapanese ? "再開のてがかり" : "Proactive briefs",
            meta: [],
            note: isJapanese
                ? "編集しても、次の更新で消えません。"
                : "Your edits survive the next update.")
    }

    /// `###`, because it sits inside a brief's `## <entity>` block. It was
    /// `直近の記録:` / `Recent:` — a label line markdown renders as prose, so the
    /// only visible structure in the file was the entity heading above it.
    nonisolated private static var recentHeading: String {
        isJapanese ? "### 直近の記録" : "### Recent"
    }

    nonisolated private static func notificationTitle(_ entity: String) -> String {
        isJapanese ? "「\(entity)」を再開" : "Resume \(entity)"
    }

}
