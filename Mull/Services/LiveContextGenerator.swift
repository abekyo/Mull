import Foundation

/// Generates me.md / now.md / full.md from raw event data + analytics.
/// NO LLM required. Pure rule-based. Runs every 60 seconds.
///
/// This ensures that "AIがあなたを知っている状態" works from day one,
/// before the nightly mull has ever run.
enum LiveContextGenerator {

    private static var mullDir: URL { MullDirectory.root }

    static var calendarService: CalendarService?
    static var emailService: EmailService?

    static func generate(analytics: AnalyticsEngine, database: DatabaseService) throws {
        guard MullDirectory.status == .ready else { return }

        let memories = database.fetchAllMemories()
        let summaries = database.fetchRecentSummaries(limit: 7)
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)

        try generateMe(memories: memories, analytics: analytics, database: database, timestamp: timestamp)
        try generateNow(memories: memories, summaries: summaries, analytics: analytics, database: database, calendar: calendarService, timestamp: timestamp)
        try generateFull(database: database, analytics: analytics, timestamp: timestamp)
        try snapshotDaily()
        // NOTE: Claude Code integration is manual. User runs:
        //   claude mcp add --transport stdio --scope user mull -- /path/to/MullMCP
        // We don't auto-write to ~/.claude.json or ~/.claude/CLAUDE.md — that's invasive.
    }

    // MARK: - Daily Snapshot
    //
    // Saves the current full.md as daily/YYYY/MM/YYYY-MM-DD.md.
    // Each 60-second cycle overwrites today's file, so the daily file
    // always reflects the latest state. Past days are frozen in place.

    private static func snapshotDaily() throws {
        guard let content = MullDirectory.read("full.md"), !content.isEmpty else { return }

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
        let invalidProjects = ["Welcome", "Analyze project structure", "Getting Started",
                                "Untitled", "Visual Studio Code"]
        for mem in memories where mem.memoryType == .user {
            // Skip stale/invalid project references
            if mem.description.hasPrefix("Working on:") {
                let project = mem.description.replacingOccurrences(of: "Working on: ", with: "")
                if invalidProjects.contains(where: { project.hasPrefix($0) }) { continue }
            }
            agentBlocks.append(ContextBlock(
                id: Curator.memoryBlockID(name: mem.name, description: mem.description),
                source: .agent, content: "- \(mem.description)", agentHash: nil))
        }

        // From FactExtractor (rule-based, available from day one). One block per fact,
        // keyed so updates replace in place instead of duplicating.
        let extractor = FactExtractor(analytics: analytics, database: database)
        for fact in extractor.extractFacts(days: 30) {
            agentBlocks.append(ContextBlock(
                id: Curator.factBlockID(category: fact.category.rawValue, text: fact.text),
                source: .agent, content: "- \(fact.text)", agentHash: nil))
        }

        // Preferences from feedback memories
        for mem in memories.filter({ $0.memoryType == .feedback }).prefix(3) {
            agentBlocks.append(ContextBlock(
                id: Curator.feedbackBlockID(name: mem.name, description: mem.description),
                source: .agent, content: "- \(mem.description)", agentHash: nil))
        }

        let header = "About the user (auto-updated: \(timestamp)).\nPinned/edited blocks are authoritative; agent blocks are rule-based and may be inaccurate — correct them in place or in me.pinned.md."
        Curator.curate(relativePath: "me.md", header: header,
                       pinnedContent: Curator.pinnedFacts(), agentBlocks: agentBlocks)
    }

    // MARK: - now.md (~500 tokens) — What you're working on

    private static func generateNow(
        memories: [MemoryEntry],
        summaries: [DailySummary],
        analytics: AnalyticsEngine,
        database: DatabaseService,
        calendar: CalendarService?,
        timestamp: String
    ) throws {
        var lines: [String] = []
        lines.append("What the user is currently working on (\(timestamp)):")
        lines.append("")

        // Active projects from memories
        let projects = memories.filter { $0.memoryType == .project }
        if !projects.isEmpty {
            lines.append("Projects:")
            for p in projects {
                lines.append("- \(p.name): \(p.description)")
            }
            lines.append("")
        }

        // Email metadata
        if let emailSummary = emailService?.recentEmailSummary(hours: 24) {
            lines.append(emailSummary)
            lines.append("")
        }

        // Calendar events
        if let schedule = calendarService?.todaySchedule() {
            lines.append(schedule)
            lines.append("")
        }

        // Today's activity from live events (excluding noise apps)
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let todayEvents = database.fetchEvents(from: startOfDay, to: Date())
            .filter { event in
                guard let app = event.appName else { return true }
                return !AnalyticsEngine.noiseApps.contains(app)
            }

        if !todayEvents.isEmpty {
            // Window titles → compress typing sequences first, then dedup
            let rawTitles = todayEvents
                .filter { $0.eventType == .screenText }
                .compactMap(\.textContent)
                .filter { !$0.isEmpty && !isMullOutput($0) }

            let compressed = compress(rawTitles)

            var titleSeen = Set<String>()
            var titleLines: [String] = []
            for title in compressed {
                let key = String(title.prefix(60).lowercased())
                guard !titleSeen.contains(key) else { continue }
                titleSeen.insert(key)
                titleLines.append("- \(title)")
            }

            if !titleLines.isEmpty {
                lines.append("Today's files/pages:")
                lines.append(contentsOf: Array(titleLines.prefix(10)))
                lines.append("")
            }

            // App usage today (filter system processes)
            let systemApps = Set(["loginwindow", "universalAccessAuthWarn", "SecurityAgent",
                                   "UserNotificationCenter", "NotificationCenter", "Spotlight",
                                   "System Settings", "SystemPreferences", "Finder"])
            let appGroups = Dictionary(grouping: todayEvents) { $0.appName ?? "Unknown" }
                .filter { !systemApps.contains($0.key) }
                .sorted { $0.value.count > $1.value.count }
            if !appGroups.isEmpty {
                lines.append("App usage today:")
                for (app, events) in appGroups.prefix(5) {
                    lines.append("- \(app): \(events.count) events")
                }
                lines.append("")
            }
        }

        // Recent summaries (if mull has run before)
        if !summaries.isEmpty {
            lines.append("Recent days:")
            for s in summaries.prefix(5) {
                lines.append("- \(s.dateShort): \(s.preview)")
            }
            lines.append("")
        }

        // Narrative of today (framed as a story, not a data dump)
        let timeEngine = TimeBlockEngine(database: database)
        let dayAnalysis = timeEngine.analyzDay(for: Date())
        if !dayAnalysis.mainActivities.isEmpty {
            let narrator = NarrativeEngine(
                analysis: dayAnalysis,
                analytics: analytics,
                database: database
            )
            let narrative = narrator.generateNarrative()
            // The opening line duplicates the "Recent days" preview above,
            // so skip it when summaries exist to avoid repetition.
            if !summaries.isEmpty {
                let withoutOpening = narrative
                    .components(separatedBy: "\n")
                    .dropFirst() // Remove the opening line
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !withoutOpening.isEmpty {
                    lines.append(withoutOpening)
                    lines.append("")
                }
            } else {
                lines.append(narrative)
                lines.append("")
            }
        }

        // Behavioral patterns (analytics)
        let analyticsPatterns = analytics.generatePatternSummary(days: 7)
        if !analyticsPatterns.isEmpty {
            lines.append(analyticsPatterns)
        }

        // Self-awareness patterns (behavior engine)
        let behaviorPatterns = BehaviorPatternEngine(database: database).detectPatterns()
        if !behaviorPatterns.isEmpty {
            lines.append("")
            lines.append("Behavioral patterns (things the user can't see about themselves):")
            for p in behaviorPatterns.prefix(3) {
                lines.append("- \(p.title): \(p.insight)")
            }
        }

        // References
        let refs = memories.filter { $0.memoryType == .reference }
        if !refs.isEmpty {
            lines.append("")
            lines.append("Key references:")
            for r in refs.prefix(5) {
                lines.append("- \(r.name): \(r.description)")
            }
        }

        MullDirectory.write(lines.joined(separator: "\n"), to: "now.md")
    }

    // MARK: - full.md — Synthesized context
    //
    // pagpag philosophy: transform, don't discard.
    // Keep the user's own words (the magic). Remove only truly toxic data.
    // Group by project/context so AI can understand the narrative.

    private static func generateFull(database: DatabaseService, analytics: AnalyticsEngine, timestamp: String) throws {
        var parts: [String] = []

        // me.md + now.md
        if let me = MullDirectory.read("me.md") { parts.append(me) }
        if let now = MullDirectory.read("now.md") { parts.append(now) }

        // Clipboard grouped by project/context — the "pagpag dish"
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let todayEvents = database.fetchEvents(from: startOfDay, to: Date())
            .filter { event in
                guard let app = event.appName else { return true }
                return !AnalyticsEngine.noiseApps.contains(app)
            }

        let clipEvents = todayEvents.filter { $0.eventType == .clipboard }
        let titleEvents = todayEvents.filter { $0.eventType == .screenText }
        let grouped = groupClipboardByContext(clips: clipEvents, titles: titleEvents)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !grouped.isEmpty {
            parts.append("")
            parts.append("What you were dealing with today:")
            parts.append(grouped)
        }

        MullDirectory.write(parts.joined(separator: "\n"), to: "full.md")
    }

    /// Group clipboard entries by project/context.
    /// Keeps the user's exact words (the magic). Only removes truly toxic data.
    private static func groupClipboardByContext(clips: [RecordingEvent], titles: [RecordingEvent]) -> String {
        struct ClipEntry {
            let text: String
            let timestamp: Date
            let nearestProject: String
        }

        // App/generic names that are NOT project names
        let invalidProjects: Set<String> = [
            "Visual Studio Code", "Code", "Xcode", "Cursor", "Zed",
            "Safari", "Firefox", "Google Chrome", "Chrome", "Arc", "Brave",
            "Finder", "Terminal", "iTerm2", "Warp", "Ghostty",
            "Slack", "Discord", "Messages", "Mail", "Zoom", "Teams",
            "System Settings", "System Preferences", "Activity Monitor",
            "Welcome", "Getting Started", "Untitled", "New Tab",
            "Claude", "ChatGPT", "Simulator", "Preview", "Notes",
            "Bear", "Notion", "Obsidian", "loginwindow",
        ]

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
            let separators = [" — ", " - "]
            for sep in separators {
                let parts = text.components(separatedBy: sep)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.count > 2 && $0.count < 40 }
                // Last part is typically the project/app name in editors
                if let project = parts.last, !invalidProjects.contains(project) {
                    return (event.timestamp, normalizeProject(project))
                }
                // Fall back to second-to-last if last was an app name
                if parts.count >= 2, let project = parts.dropLast().last,
                   !invalidProjects.contains(project) {
                    return (event.timestamp, normalizeProject(project))
                }
            }
            return nil
        }

        // Associate each clipboard entry with the nearest project
        var entries: [ClipEntry] = []
        var seen = Set<String>()

        for event in clips {
            guard let text = event.textContent, !text.isEmpty else { continue }
            if isSensitive(text) { continue }
            if isMullOutput(text) { continue }

            // Dedup
            let key = String(text.prefix(60).lowercased())
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

        var lines: [String] = []
        for (project, items) in grouped.prefix(5) {
            lines.append("")
            lines.append("\(project):")
            for item in items.prefix(5) {
                lines.append("  - \"\(item.text)\"")
            }
        }

        return lines.joined(separator: "\n")
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
        // mull's own output
        if text.contains("auto-updated") || text.contains("mull is recording") ||
           text.contains("mull is still learning") || text.contains("Raw activity data for") ||
           text.contains("Context about the user") || text.contains("No activity recorded") {
            return true
        }
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
