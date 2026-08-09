import Foundation

/// Maintains the durable context files (me.md / now.md / full.md) every 60s.
///
/// These hold only the OWNED layer — pinned facts (the human) and memories
/// (mull's nightly LLM consolidation), kept current via the Curator. They no
/// longer bake in rule-based pre-digestion (FactExtractor facts, analytics,
/// narratives, project inference): that was the lossy "事前消化" DIRECTION §4/§9.1
/// cuts. Live/current context is assembled at USE-TIME by the agent through the
/// `whats_active_now` and `search` MCP tools (anchored on the captured, lightly
/// structured event stream — entity/type/salience), not pre-summarized here.
enum LiveContextGenerator {

    private static var mullDir: URL { MullDirectory.root }

    /// Calendar/email are PASSED IN, not stored in mutable statics. They used to be
    /// `static var` optionals assigned from every detached generation task — writing
    /// a class reference into shared mutable state from concurrent tasks is a
    /// retain/release data race, and a torn read could hand the generator a
    /// half-released object.
    /// `inbox` is a VALUE, not the service.
    ///
    /// This runs inside `Task.detached` (AppState) so a slow vault write does not
    /// block the UI. It used to take `EmailService` and call it from there — and
    /// `EmailService` owns a 5-minute poll timer that mutates its state on the
    /// main actor, so this was a genuine data race across a detached task. The
    /// same class of bug as the retain/release race noted below, and it was found
    /// by turning on strict concurrency checking rather than by anything failing:
    /// races of this shape do not reproduce, they corrupt.
    ///
    /// The fix is to read the inbox on the main actor before detaching and pass
    /// the answer down. Nothing off-main touches the service now.
    /// What the inbox looked like at the moment the caller asked, captured on the
    /// main actor. Plain values, so it crosses to a detached task safely.
    struct InboxSnapshot: Sendable {
        var summary: String?
        var problem: String?
        static let none = InboxSnapshot()

        /// Read on the main actor, at the call site, before detaching.
        @MainActor
        static func read(from email: EmailService?) -> InboxSnapshot {
            InboxSnapshot(summary: email?.recentEmailSummary(hours: 24),
                          problem: EmailService.lastProblem?.message)
        }
    }

    static func generate(analytics: AnalyticsEngine, database: DatabaseService,
                         calendar: CalendarService?, inbox: InboxSnapshot) throws {
        guard MullDirectory.status == .ready else { return }

        let memories = database.fetchAllMemories()
        let summaries = database.fetchRecentSummaries(limit: 7)
        let timestamp = Curator.timestamp()

        expireStaleNightlyBlocks()

        try generateMe(memories: memories, analytics: analytics, database: database, timestamp: timestamp)
        try generateNow(memories: memories, summaries: summaries, analytics: analytics, database: database, calendar: calendar, inbox: inbox, timestamp: timestamp)
        try generateFull(database: database, analytics: analytics, timestamp: timestamp)
        generateFrontDoor(timestamp: timestamp)
        try snapshotDaily()
        // NOTE: Claude Code integration is manual. User runs:
        //   claude mcp add --transport stdio --scope user mull -- /path/to/MullMCP
        // We don't auto-write to ~/.claude.json or ~/.claude/CLAUDE.md — that's invasive.
    }

    // MARK: - Staleness sweep
    //
    // The 60s pass is the only thing in mull guaranteed to keep running, so it is
    // where the expiry of OTHER passes' output has to live. `nightly:` blocks come
    // from the LLM consolidation; with no provider configured that pass never runs
    // again, and its last output stays in now.md and full.md under the heading
    // "From last night's consolidation" indefinitely — in the shipped vault, for
    // two months. Nothing else could catch it: `curate` only prunes for the pass
    // that is currently running, and that is precisely the pass that stopped.

    /// How long a nightly block may keep claiming to be last night's.
    static let nightlyMaxAge: TimeInterval = 7 * 86_400

    private static func expireStaleNightlyBlocks() {
        for file in ["now.md", "full.md"] {
            Curator.expire(relativePath: file, idPrefixes: ["nightly:"], maxAge: nightlyMaxAge)
        }
    }

    // MARK: - mull.md — the front door (read me first)
    //
    // The single cover page for the whole vault: what this record is, the order
    // to read it in, a map of the folders, and how to work with it. The MCP
    // server points every agent here first (initialize `instructions` +
    // `mull://start`), so the record actually functions as material HANDED to an
    // AI — not a pile of files with no entry point. Rule-based: no LLM, always
    // current. Plain-written (no user blocks) — it's a generated index.

    private static func generateFrontDoor(timestamp: String) {
        var l: [String] = []
        l.append(MarkdownDoc.header(
            title: "mull — start here",
            meta: [("updated", timestamp),
                   ("scope", "the mull record of one person — local, automatically kept"),
                   ("ownership", "kept on the user's Mac; lent to you, not owned by you")]))
        l.append("")
        l.append("This is the mull record of one person: an automatically-kept, local context")
        l.append("vault. Read it to understand who they are and what they are doing, so you can")
        l.append("help without them explaining themselves from scratch.")
        l.append("")
        l.append("## Read in this order")
        l.append("1. **me.md** — who they are: identity, skills, preferences (~200 tokens, always safe).")
        l.append("2. **now.md** — what they're working on right now (~500 tokens).")
        l.append("3. For anything live or specific, call the tools instead of guessing:")
        l.append("   - `whats_active_now` — current app / project / recent actions. Call this FIRST.")
        l.append("   - `search` — relevance-ranked retrieval across projects, ranked toward the current one.")
        l.append("   - `get_projects` — where they left off on each project.")
        l.append("4. **full.md** — me.md + now.md + recent activity in one file. Only when starting a big task.")
        l.append("")
        l.append("## The vault")
        l.append("- `me.md`, `now.md`, `full.md` — the 3-layer context above.")
        l.append("- `daily/` — daily snapshots of the full context.")
        l.append("- `\(VaultLayout.projects)/` — one briefing per project they are working on.")
        l.append("- `\(VaultLayout.corrections)/` — where they corrected mull, and what it should have said.")
        l.append("- `notes/` — the user's own notes, in whatever folders they made.")
        l.append("")
        l.append("## Working with this record")
        l.append("- It is **theirs**. Don't assert what they think; if you infer judgment, mark it as a guess and let them correct it.")
        l.append("- You may write back with the `curate` / `write_note` tools — your own block only. The user's writing is never overwritten.")
        l.append("")
        _ = MullDirectory.write(l.joined(separator: "\n"), to: "mull.md")
    }

    // The rule-based vault fill used to run here, every five minutes, writing
    // section blocks into the numbered folders' index.md files. Retired with those
    // folders on 2026-08-09 (DIRECTION §6.1). What it put in `00_identity` was the
    // FactExtractor pre-digestion that `generateMe` had already, deliberately,
    // stopped writing into me.md — so the same rule-based facts mull removed from
    // one file were being baked into another. They are still available, assembled
    // at use-time, through `ContextComposer` and the Profile tab.

    // MARK: - Daily Snapshot
    //
    // Saves the current full.md as daily/YYYY/MM/YYYY-MM-DD.md.
    // Each 60-second cycle overwrites today's file, so the daily file
    // always reflects the latest state. Past days are frozen in place.

    private static func snapshotDaily() throws {
        guard let raw = MullDirectory.read("full.md"), !raw.isEmpty else { return }
        // full.md is a curated file now (two writers, disjoint block prefixes), so
        // strip the provenance markers before freezing the day's copy — the daily
        // snapshot is a readable artifact, not something the Curator round-trips.
        let content = ContextBlockFile.stripMarkers(raw)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM"
        let subpath = formatter.string(from: Date())

        let fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyy-MM-dd"
        let fileName = fileFormatter.string(from: Date()) + ".md"

        MullDirectory.write(content, to: "daily/\(subpath)/\(fileName)")
    }

    // MARK: - me.md (~200 tokens) — Who you are
    //
    // me.md is NOT rewritten wholesale. It is curated block-by-block (see Curator /
    // ContextBlock): the user's pinned facts (me.pinned.md) and any block the user
    // edited directly are never overwritten; mull only updates its own agent blocks
    // and appends new ones. This is the fix for the original failure mode where
    // rule-based guesses clobbered the user's corrections every 60s ("mull layer
    // went stale"). Both this 60s pass and the nightly MullEngine write through
    // Curator, so neither clobbers the other — or the human.

    private static func generateMe(memories: [MemoryEntry], analytics: AnalyticsEngine, database: DatabaseService, timestamp: String) throws {
        var agentBlocks: [ContextBlock] = []

        // From mull memories (if they exist from past LLM runs)
        for mem in memories where mem.memoryType == .user {
            // Skip stale/invalid project references. Same shape gate as everywhere
            // else — this was a fourth, shorter, differently-worded blocklist.
            if mem.description.hasPrefix("Working on:") {
                let project = mem.description.replacingOccurrences(of: "Working on: ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !ProjectNames.isPlausible(project) { continue }
            }
            agentBlocks.append(ContextBlock(
                id: Curator.memoryBlockID(name: mem.name, description: mem.description),
                source: .agent, content: "- \(mem.description)", agentHash: nil))
        }

        // NOTE: rule-based FactExtractor facts (language %, role, busiest day,
        // inferred projects…) used to be baked in here. Removed (DIRECTION §4/§9.1):
        // me.md holds only the durable, human/AI-owned layer — pinned facts (you)
        // and memories (mull's nightly LLM consolidation). Live, current context
        // is assembled at USE-TIME by the agent via the `whats_active_now` and
        // `search` MCP tools, not pre-digested by rule-based engines here.

        // Preferences from feedback memories
        for mem in memories.filter({ $0.memoryType == .feedback }).prefix(3) {
            agentBlocks.append(ContextBlock(
                id: Curator.feedbackBlockID(name: mem.name, description: mem.description),
                source: .agent, content: "- \(mem.description)", agentHash: nil))
        }

        // me.md was the one contract file with no title at all: it opened with three
        // lines of prose addressed to an AI, so the human it is about met a paragraph
        // of housekeeping before a single fact. Same header as the nightly pass now,
        // via Curator — both passes write this file, and a header they disagree on is
        // a header each rewrites over the other's every minute.
        //
        // Keep `fact:` in the managed prefixes so any rule-based facts written by
        // earlier versions get pruned out of me.md (we no longer emit them).
        Curator.curate(relativePath: "me.md", header: Curator.meHeader(timestamp: timestamp),
                       pinnedContent: Curator.pinnedFacts(), agentBlocks: agentBlocks,
                       managedPrefixes: ["fact:", "mem:", "pref:"])
    }

    // MARK: - now.md (~500 tokens) — What you're working on
    //
    // Curated, not rewritten wholesale. This 60s pass owns the `now:` prefix; the
    // nightly MullEngine pass owns `nightly:`. Both used to `String.write` the whole
    // file, which meant the nightly LLM output was destroyed by the very next tick —
    // me.md had been fixed this way, now.md and full.md had not.

    private static func generateNow(
        memories: [MemoryEntry],
        summaries: [DailySummary],
        analytics: AnalyticsEngine,
        database: DatabaseService,
        calendar: CalendarService?,
        inbox: InboxSnapshot,
        timestamp: String
    ) throws {
        var sections: [String?] = []

        // What the user is doing right now.
        //
        // This section was, for a while, the literal string "Current activity: the
        // AI should call the `whats_active_now` / `search` MCP tools." That is
        // correct for Claude Code with MCP wired up, and worthless for every other
        // reader now.md has — ChatGPT, an editor without MCP, a pasted block, the
        // user's own eyes. mull's headline promise is that an AI reads this and
        // knows; shipping an IOU in its place meant the product's central artifact
        // was ~450 tokens, three of which were the same test keystroke.
        //
        // DIRECTION §4/§9.1 is still honoured: what it kills is *lossy rule-based
        // summary* hardened into the file. `CurrentState` is not a summary — it is
        // the live anchor itself (active entity, app, and the last few salient
        // signals), already filtered for secrets and test input, assembled from
        // rows and regenerated every 60s. Writing it down loses nothing that
        // calling the tool would return; it only removes the requirement to have a
        // tool.
        // Each of these was a `Label:` line with its items under it — prose, as far
        // as markdown is concerned, in the same file whose nightly half used real
        // `##`. They are `##` sections now, and a section with nothing in it is not
        // written at all (MarkdownDoc rule 5), so the trailing-blank bookkeeping
        // this function used to do between every block is gone with it.
        let state = CurrentState.current(database: database)
        let activity = state.summary()
        sections.append(MarkdownDoc.section("Right now", activity == "(no recent activity)" ? nil :
            activity + "\n\n_Fresher and deeper than this: call `whats_active_now` / `search`._"))

        // Active projects from memories
        sections.append(MarkdownDoc.section("Projects", items:
            memories.filter { $0.memoryType == .project }
                .map { "- **\(MarkdownDoc.inline($0.name, limit: 60))** — \(MarkdownDoc.inline($0.description))" }))

        // Email metadata — already read, on the main actor, by the caller.
        if let emailSummary = inbox.summary {
            sections.append(MarkdownDoc.section("Inbox", emailSummary))
        } else if let problem = inbox.problem {
            sections.append(MarkdownDoc.section("Inbox", "Unavailable — \(problem)"))
        }

        // Calendar events
        //
        // A blocked calendar and a genuinely clear day both produce nothing here,
        // and omitting the block let every AI reading this file conclude the day
        // was free. Naming the blind spot is the same rule ColdReadService follows.
        if let schedule = calendar?.todaySchedule() {
            sections.append(MarkdownDoc.section("Today's schedule", schedule))
        } else if let calendar, calendar.accessState != .granted {
            sections.append(MarkdownDoc.section("Today's schedule",
                "Unavailable — mull has not been granted calendar access, so today's events are unknown (not absent)."))
        }

        // NOTE: "Today's files/pages" (rule-based digest of window titles) was
        // removed too — that live activity is exactly what `whats_active_now` /
        // `search` return on demand, anchored on the current entity. Pre-baking it
        // here is the duplicate, stale "事前消化" DIRECTION §4 calls to cut.

        // Recent summaries (if mull has run before). A summary older than a week is
        // reported as the gap it is, not as a "recent day" — see `splitByRecency`.
        let (recentDays, staleDay) = summaries.splitByRecency()
        sections.append(MarkdownDoc.section("Recent days", items:
            recentDays.isEmpty
                ? (staleDay.map { ["- No day has been consolidated since **\($0.dateShort)**. "
                                   + "Nightly consolidation needs an LLM provider; the days since are "
                                   + "in the event record but have not been summarised."] } ?? [])
                : recentDays.prefix(5).map { "- **\($0.dateShort)** — \(MarkdownDoc.inline($0.preview))" }))

        // NOTE: the day "narrative" ("A focused day…"), the keyword/topic cloud,
        // and behavior-pattern insights were removed from now.md. They are vague
        // or analytics-grade — they don't change an AI's next answer, and the
        // topic cloud surfaced email boilerplate ("ご確認のほど") as "focus topics".
        // Those belong in the Insights UI, not the AI context.

        // References
        sections.append(MarkdownDoc.section("Key references", items:
            memories.filter { $0.memoryType == .reference }.prefix(5)
                .map { "- **\(MarkdownDoc.inline($0.name, limit: 60))** — \(MarkdownDoc.inline($0.description))" }))

        Curator.curate(relativePath: "now.md", header: Curator.nowHeader(timestamp: timestamp),
                       pinnedContent: nil,
                       agentBlocks: [ContextBlock(
                           id: "now:live", source: .agent,
                           content: MarkdownDoc.join(sections),
                           agentHash: nil)],
                       managedPrefixes: ["now:"])
    }

    // MARK: - full.md — Synthesized context
    //
    // pagpag philosophy: transform, don't discard.
    // Keep the user's own words (the magic). Remove only truly toxic data.
    // Group by project/context so AI can understand the narrative.
    //
    // Curated under `full:`, disjoint from the nightly pass's `nightly:` — same
    // two-writer fix as now.md above.

    private static func generateFull(database: DatabaseService, analytics: AnalyticsEngine, timestamp: String) throws {
        var sections: [String?] = []

        // me.md + now.md, embedded properly.
        //
        // These used to be appended whole — front matter, `# ` title, orientation
        // note and all — which is why the shipped full.md contained two H1s and
        // three timestamps, the second of them announcing "# now.md — what I'm
        // working on" from the middle of a different document. `body(of:)` drops
        // each file's own chrome and `demoteHeadings` pushes its `##`s to `###`,
        // so they sit under full.md's headings instead of competing with them.
        //
        // Provenance markers still go: full.md is read as prose, not round-tripped.
        func embed(_ path: String) -> String? {
            guard let raw = MullDirectory.read(path) else { return nil }
            let body = MarkdownDoc.body(of: ContextBlockFile.stripMarkers(raw))
            return body.isEmpty ? nil : MarkdownDoc.demoteHeadings(body, by: 1)
        }
        sections.append(MarkdownDoc.section("Who I am", embed("me.md")))
        sections.append(MarkdownDoc.section("What I'm working on", embed("now.md")))

        // Clipboard grouped by project/context — the "pagpag dish"
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let todayEvents = database.fetchEvents(from: startOfDay, to: Date())
            .filter { event in
                guard let app = event.appName else { return true }
                return !AnalyticsEngine.isNoiseApp(app)
            }

        let clipEvents = todayEvents.filter { $0.eventType == .clipboard }
        let titleEvents = todayEvents.filter { $0.eventType == .screenText }
        let grouped = groupClipboardByContext(clips: clipEvents, titles: titleEvents)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append(MarkdownDoc.section("What you were dealing with today",
                                            grouped.isEmpty ? nil : grouped))

        Curator.curate(relativePath: "full.md", header: Curator.fullHeader(timestamp: timestamp),
                       pinnedContent: nil,
                       agentBlocks: [ContextBlock(
                           id: "full:live", source: .agent,
                           content: MarkdownDoc.join(sections),
                           agentHash: nil)],
                       managedPrefixes: ["full:"])
    }

    /// Group clipboard entries by project/context.
    /// Keeps the user's exact words (the magic). Only removes truly toxic data.
    private static func groupClipboardByContext(clips: [RecordingEvent], titles: [RecordingEvent]) -> String {
        struct ClipEntry {
            let text: String
            let timestamp: Date
            let nearestProject: String
        }

        // Which segments are projects is `ProjectNames`' job, shared with
        // FactExtractor / TimeBlockEngine / Entity. The list that used to live
        // here was one of four that disagreed with each other, and it is how a
        // Finder window called "Downloads" ended up heading a project section in
        // full.md — no blocklist can enumerate every folder someone opens.
        let chrome = ProjectNames.chrome(in: titles.compactMap { event in
            guard let title = event.textContent, let app = event.appName else { return nil }
            return (app: app, title: title)
        })

        // Aliases — merge different names for the same project
        let projectAliases: [String: String] = [
            "Dream": "Mull", // legacy window-title from before the rename
        ]

        func normalizeProject(_ name: String) -> String {
            projectAliases[name] ?? name
        }

        // Build a timeline of project names from window titles
        // Prefer the part BEFORE the separator (file/task name comes first, app/project last)
        // Use the app's Xcode/Code project name pattern: "file — Project"
        let projectTimeline: [(Date, String)] = titles.compactMap { event in
            guard let text = event.textContent, !isMullOutput(text) else { return nil }
            guard let app = event.appName,
                  !ProjectNames.contentDrivenApps.contains(app.lowercased()) else { return nil }
            let parts = ProjectNames.segments(of: text)
                .filter { !chrome.contains($0) && ProjectNames.isPlausible($0) }
            // Last part is typically the project name in editors.
            guard let project = parts.last else { return nil }
            return (event.timestamp, normalizeProject(project))
        }

        // Associate each clipboard entry with the nearest project
        var entries: [ClipEntry] = []
        var seen = Set<String>()

        for event in clips {
            guard let text = event.textContent, !text.isEmpty else { continue }
            if isSensitive(text) { continue }
            if isMullOutput(text) { continue }

            // Dedup on the whole item. Keying on the first 60 characters let two
            // clipboard entries that shared an opening line through as separate
            // bullets — visible in the shipped full.md as the same checklist
            // printed twice.
            let key = text.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            // Find nearest project by timestamp (within 5 min window)
            let nearestProject = projectTimeline
                .filter { abs($0.0.timeIntervalSince(event.timestamp)) < 300 }
                .min(by: { abs($0.0.timeIntervalSince(event.timestamp)) < abs($1.0.timeIntervalSince(event.timestamp)) })
                .map(\.1) ?? "General"

            // Condense: multi-line text → first meaningful line
            let condensed: String
            if text.count > 200 {
                let firstLine = text.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty && $0.count > 3 } ?? String(text.prefix(150))
                condensed = String(firstLine.prefix(150)) + "..."
            } else {
                condensed = text.replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            entries.append(ClipEntry(text: condensed, timestamp: event.timestamp, nearestProject: nearestProject))
        }

        // Group by project, skip groups with only 1 entry (noise)
        let grouped = Dictionary(grouping: entries) { $0.nearestProject }
            .filter { $0.value.count >= 2 }
            .sorted { $0.value.count > $1.value.count }

        // `Project:` followed by two-space-indented bullets was neither a heading
        // nor a list — the label rendered as prose and the items hung off it as a
        // lazy continuation. `###` sits correctly under full.md's `##`, and each
        // quoted clip goes through `inline` so a multi-line paste cannot end the
        // list it is part of.
        return MarkdownDoc.join(grouped.prefix(5).map { project, items in
            MarkdownDoc.section(project, level: 3, items:
                items.prefix(5).map { "- \"\(MarkdownDoc.inline($0.text, limit: 160))\"" })
        })
    }

    // MARK: - Auto-install into Claude Code config

    // Claude Code / Cursor integration is manual (not auto-installed):
    //
    // Option 1 — MCP Server (recommended):
    //   claude mcp add --transport stdio --scope user mull -- /path/to/MullMCP
    //
    // Option 2 — File reference in CLAUDE.md:
    //   Read ~/mull/me.md and ~/mull/now.md for context about who I am.
    //
    // Option 3 — Copy & paste from menu bar panel

    // MARK: - Helpers

    /// Check if text is noise that shouldn't appear in AI context.
    static func isMullOutput(_ text: String) -> Bool {
        // mull's own output — one shared predicate (MarkdownDoc), not a fifth
        // private copy of the same phrase list.
        if MarkdownDoc.isGeneratedByMull(text) { return true }
        // Claude Code / AI tool internal output
        if text.contains("tool output (") || text.contains("Grep output (") ||
           text.contains("Bash tool output (") || text.contains("WebSearch tool output (") ||
           text.contains("Read tool output (") || text.contains("Glob tool output (") {
            return true
        }
        // Xcode compiler errors / stack traces
        if text.hasPrefix("/Users/") && text.contains(".swift:") { return true }
        if text.hasPrefix("#") && text.contains("0x") { return true }
        if text.hasPrefix("Thread ") && text.contains("Queue") { return true }
        if text.hasPrefix("Validation failed") { return true }
        // Screenshot filenames
        if text.hasPrefix("Screenshot ") && text.contains(" at ") { return true }
        return false
    }

    /// Check if text contains sensitive data that should not be shared with AI.
    /// Canonical rules now live in `SensitiveText` so every target shares them.
    static func isSensitive(_ text: String) -> Bool { SensitiveText.isSensitive(text) }

    private static func pct(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    /// Remove incremental typing sequences, keep only final version.
    ///
    /// Handles both:
    ///   - Prefix chains: "abc" → "abcd" → "abcde" → keep "abcde"
    ///   - Similarity: "文字を売っても何も何も" vs "文字を売っても何も" → keep longer
    ///
    /// Uses a wide window and substring check (not just prefix).
    private static func compress(_ items: [String]) -> [String] {
        guard !items.isEmpty else { return [] }
        var result: [String] = []

        outer: for i in 0..<items.count {
            let current = items[i]
            guard current.count > 3 else { continue } // Skip very short items

            // Check all future items: if any is a longer/better version, skip current
            for j in (i + 1)..<items.count {
                let future = items[j]

                // Future starts with current → current is typing-in-progress
                if future.hasPrefix(current) && future.count > current.count {
                    continue outer
                }

                // Significant overlap — if >50% of current matches the start of future, skip current
                let shared = commonPrefixLength(current, future)
                if shared > 5 && Double(shared) / Double(current.count) > 0.5 {
                    continue outer
                }
            }
            result.append(current)
        }
        return result
    }

    /// Count how many characters two strings share from the start.
    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        for (ca, cb) in zip(a, b) {
            if ca == cb { count += 1 } else { break }
        }
        return count
    }
}
