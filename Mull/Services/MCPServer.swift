import Foundation

/// MCP (Model Context Protocol) server for mull.
///
/// Runs as a subprocess, communicates via stdio JSON-RPC.
/// Allows Claude Code, Cursor, and any MCP client to query mull data
/// without the user copying/pasting anything.
///
/// The "なんで知ってるの？" moment:
///   AI asks mull "what is the user working on?" → mull answers from live data
///   User never did anything. AI just... knows.
///
/// Resources exposed:
///   mull://me       — who the user is (~200 tokens)
///   mull://now      — what they're working on (~500 tokens)
///   mull://full     — everything (~2000 tokens)
///   mull://today    — raw today's events
///
/// Tools exposed:
///   get_user_context — get me.md + now.md (for mid-conversation queries)
///   search_history   — search past events by keyword
///   get_patterns     — get behavioral analytics
final class MCPServer {

    private let database: DatabaseService
    private let analytics: AnalyticsEngine
    private let mullDir: URL

    init(database: DatabaseService) {
        self.database = database
        self.analytics = AnalyticsEngine(database: database)
        self.mullDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("mull")
    }

    /// Run the MCP server loop. Blocks forever (reads stdin until EOF).
    /// Call this in a detached process or background thread.
    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            handle(msg)
        }
    }

    // MARK: - Dispatch

    private func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String ?? ""
        let id = msg["id"] // Int or String or nil

        switch method {
        case "initialize":
            respond(id: id, result: [
                "protocolVersion": "2025-03-26",
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": ["subscribe": false, "listChanged": false]
                ],
                "serverInfo": ["name": "mull", "version": "1.0.0"]
            ])

        case "notifications/initialized":
            break // No response needed

        case "tools/list":
            respond(id: id, result: ["tools": toolDefinitions()])

        case "tools/call":
            handleToolCall(id: id, params: msg["params"] as? [String: Any] ?? [:])

        case "resources/list":
            respond(id: id, result: ["resources": resourceDefinitions()])

        case "resources/read":
            handleResourceRead(id: id, params: msg["params"] as? [String: Any] ?? [:])

        default:
            if id != nil {
                respondError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    // MARK: - Tools

    private func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "get_user_context",
                "description": "Get context about who this user is and what they are currently working on. Call this at the start of a conversation or when you need to understand the user's background, projects, and recent activity.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "detail_level": [
                            "type": "string",
                            "enum": ["brief", "normal", "full"],
                            "description": "brief=identity only (~200 tokens), normal=identity+current work (~700 tokens), full=everything including raw input (~2000 tokens)"
                        ]
                    ]
                ]
            ],
            [
                "name": "whats_active_now",
                "description": "Get what the user is doing RIGHT NOW — active app, current project/entity, and the most recent meaningful actions (notes, copied text, files). Call this FIRST to anchor any further retrieval on the user's present context. Cheap and current.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "search",
                "description": "Find the few most relevant past events for a need — ranked by relevance, NOT a raw dump. Scope with optional facets. If 'entity' is omitted it is anchored to what the user is working on now. Prefer this over dumping history: ask for exactly what this moment needs.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "What you're looking for (keywords or a short phrase)"],
                        "entity": ["type": "string", "description": "Project/entity to scope to. Omit to anchor on the current active project."],
                        "type": ["type": "string", "enum": ["note", "error", "code", "web", "file", "activity"], "description": "Restrict to one kind of event"],
                        "days": ["type": "integer", "description": "How many days back to search (default 7)"]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "get_behavior_patterns",
                "description": "Detect behavioral patterns the user cannot see about themselves. Returns abandonment risks (projects about to be dropped), peak hour waste (best hours spent on shallow work), focus decline (deep work blocks dropping), avoidance patterns (opening but not engaging), and correlations (e.g. 'less switching = more output'). Use this to give the user genuine self-awareness. Each pattern includes an insight, a concrete action, and the data evidence.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "get_projects",
                "description": "Get all detected projects with status, last active date, resume point (last file + last clipboard), session history, and stall detection. Use this when the user asks 'what was I working on?' or 'where did I leave off on X?'",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "days": [
                            "type": "integer",
                            "description": "How many days back to analyze (default 14)"
                        ]
                    ]
                ]
            ],
            [
                "name": "get_knowledge",
                "description": "Search the user's accumulated knowledge — decisions they've made, solutions they've found, alternatives they've rejected. Use this when the user faces a decision similar to one they've made before, or when they ask 'how did I solve this last time?'",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Topic or keyword to search for. Leave empty to get all knowledge."
                        ]
                    ]
                ]
            ],
            [
                "name": "get_week_comparison",
                "description": "Compare this week's productivity to last week at the same point. Returns duration delta, deep work blocks count, and context switch changes. Use this when the user asks 'how am I doing this week?' or when you want to calibrate advice.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "get_relevant",
                "description": "Given a context string (file name, project name, topic), find relevant knowledge and past activity. Use this proactively when the user is working on something — it may surface decisions or solutions from their past that apply to the current task.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "context": [
                            "type": "string",
                            "description": "The current context — a file name, project name, error message, or topic"
                        ]
                    ],
                    "required": ["context"]
                ]
            ],
            [
                "name": "get_briefing",
                "description": "Get today's briefing — behavioral pattern alerts, stalled projects, focus block availability, and week-over-week comparison. This is what the user should see first thing in the morning. Prioritizes actionable insights over raw data.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "search_history",
                "description": "Search the user's activity history by keyword. Returns matching events from recorded keystrokes, clipboard, and window titles.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Search keyword"
                        ],
                        "days": [
                            "type": "integer",
                            "description": "How many days back to search (default 7)"
                        ]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "get_patterns",
                "description": "Get analytics patterns: most used keywords, peak productivity hours, app usage, language mix.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "days": [
                            "type": "integer",
                            "description": "Analysis period in days (default 7)"
                        ]
                    ]
                ]
            ],
            [
                "name": "write_note",
                "description": "Create or update a markdown note in the user's mull folder.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "File path relative to ~/mull/ (e.g. 'notes/meeting-2026-04-01.md')"
                        ],
                        "content": [
                            "type": "string",
                            "description": "Markdown content to write"
                        ]
                    ],
                    "required": ["path", "content"]
                ]
            ],
            [
                "name": "list_files",
                "description": "List all markdown files in the user's mull folder.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ]
        ]
    }

    private func handleToolCall(id: Any?, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        switch name {
        case "get_user_context":
            let level = args["detail_level"] as? String ?? "normal"
            let content = getUserContext(level: level)
            respondToolResult(id: id, text: content)

        case "whats_active_now":
            respondToolResult(id: id, text: CurrentState.current(database: database).summary())

        case "search":
            let query = args["query"] as? String ?? ""
            let entity = args["entity"] as? String
            let type = args["type"] as? String
            let days = args["days"] as? Int ?? 7
            respondToolResult(id: id, text: toolSearch(query: query, entity: entity, type: type, days: days))

        case "search_history":
            let query = args["query"] as? String ?? ""
            let days = args["days"] as? Int ?? 7
            let content = searchHistory(query: query, days: days)
            respondToolResult(id: id, text: content)

        case "get_patterns":
            let days = args["days"] as? Int ?? 7
            let content = analytics.generatePatternSummary(days: days)
            respondToolResult(id: id, text: content)

        case "get_behavior_patterns":
            let content = toolGetBehaviorPatterns()
            respondToolResult(id: id, text: content)

        case "get_projects":
            let days = args["days"] as? Int ?? 14
            let content = toolGetProjects(days: days)
            respondToolResult(id: id, text: content)

        case "get_knowledge":
            let query = args["query"] as? String ?? ""
            let content = toolGetKnowledge(query: query)
            respondToolResult(id: id, text: content)

        case "get_week_comparison":
            let content = toolGetWeekComparison()
            respondToolResult(id: id, text: content)

        case "get_relevant":
            let context = args["context"] as? String ?? ""
            let content = toolGetRelevant(context: context)
            respondToolResult(id: id, text: content)

        case "get_briefing":
            let content = toolGetBriefing()
            respondToolResult(id: id, text: content)

        case "write_note":
            let path = args["path"] as? String ?? ""
            let content = args["content"] as? String ?? ""
            let result = writeNote(path: path, content: content)
            respondToolResult(id: id, text: result)

        case "list_files":
            let result = listFiles()
            respondToolResult(id: id, text: result)

        default:
            respondError(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
    }

    // MARK: - Resources

    private func resourceDefinitions() -> [[String: Any]] {
        [
            [
                "uri": "mull://me",
                "name": "User Profile (me.md)",
                "description": "Who this user is — identity, skills, preferences. ~200 tokens.",
                "mimeType": "text/markdown"
            ],
            [
                "uri": "mull://now",
                "name": "Current Context (now.md)",
                "description": "What the user is currently working on — projects, today's files, app usage. ~500 tokens.",
                "mimeType": "text/markdown"
            ],
            [
                "uri": "mull://full",
                "name": "Full Context (full.md)",
                "description": "Complete user context including raw activity data. ~2000 tokens.",
                "mimeType": "text/markdown"
            ]
        ]
    }

    private func handleResourceRead(id: Any?, params: [String: Any]) {
        let uri = params["uri"] as? String ?? ""

        let fileName: String
        switch uri {
        case "mull://me": fileName = "me.md"
        case "mull://now": fileName = "now.md"
        case "mull://full": fileName = "full.md"
        default:
            respondError(id: id, code: -32602, message: "Unknown resource: \(uri)")
            return
        }

        let filePath = mullDir.appendingPathComponent(fileName)
        let content = (try? String(contentsOf: filePath, encoding: .utf8)) ?? "(No data yet. mull is still recording.)"

        respond(id: id, result: [
            "contents": [[
                "uri": uri,
                "mimeType": "text/markdown",
                "text": content
            ]]
        ])
    }

    // MARK: - Tool Implementations

    private func getUserContext(level: String) -> String {
        var files: [String] = []

        switch level {
        case "brief":
            files = ["me.md"]
        case "full":
            files = ["full.md"]
        default:
            files = ["me.md", "now.md"]
        }

        var parts: [String] = []
        for file in files {
            let path = mullDir.appendingPathComponent(file)
            if let content = try? String(contentsOf: path, encoding: .utf8), !content.isEmpty {
                parts.append(content)
            }
        }

        if parts.isEmpty {
            return "(mull is still recording. No user context available yet. Ask the user directly for now.)"
        }

        return parts.joined(separator: "\n\n")
    }

    /// Selection-layer search (SELECTION-LAYER.md §3-4): relevance-ranked, facet-
    /// scoped, anchored on the current entity when none is given. Replaces the
    /// raw-dump model of `search_history`.
    private func toolSearch(query: String, entity: String?, type: String?, days: Int) -> String {
        let now = Date()
        let since = TimeInterval(max(days, 1) * 86_400)
        let events = database.fetchEvents(from: now.addingTimeInterval(-since), to: now)
        // Anchor on what the user is doing now when the caller didn't scope an entity.
        let anchor = entity ?? CurrentState.current(database: database).activeEntity
        let results = Selection.rank(events: events, query: query, entity: anchor,
                                     type: type, now: now, since: since, limit: 8)
        guard !results.isEmpty else {
            return "No relevant activity for '\(query)'\(anchor.map { " in \($0)" } ?? "")."
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd HH:mm"
        var lines = ["Relevant to '\(query)'\(anchor.map { " (anchored on \($0))" } ?? "") — \(results.count):", ""]
        lines.append(contentsOf: results.map { $0.line(fmt) })
        return lines.joined(separator: "\n")
    }

    private func searchHistory(query: String, days: Int) -> String {
        let results = database.searchEvents(query: query, limit: 20)

        if results.isEmpty {
            return "No events found matching '\(query)' in the last \(days) days."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"

        var lines: [String] = ["Search results for '\(query)' (\(results.count) matches):", ""]
        for event in results {
            let time = formatter.string(from: event.timestamp)
            let app = event.appName ?? ""
            let text = String((event.textContent ?? "").prefix(200))
                .replacingOccurrences(of: "\n", with: " ")
            lines.append("- \(time) [\(app)] \(event.eventType.rawValue): \(text)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Write / List Files

    private func writeNote(path: String, content: String) -> String {
        guard !path.isEmpty, !content.isEmpty else {
            return "Error: path and content are required"
        }

        // Security: prevent path traversal
        let cleaned = path.replacingOccurrences(of: "..", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard cleaned.hasSuffix(".md") else {
            return "Error: only .md files are allowed"
        }

        let filePath = mullDir.appendingPathComponent(cleaned)
        let parentDir = filePath.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try content.write(to: filePath, atomically: true, encoding: .utf8)
            return "Written: ~/mull/\(cleaned) (\(content.count) chars)"
        } catch {
            return "Error writing file: \(error.localizedDescription)"
        }
    }

    private func listFiles() -> String {
        var lines: [String] = ["Files in ~/mull/:"]
        listDir(mullDir, prefix: "", lines: &lines)
        return lines.joined(separator: "\n")
    }

    private func listDir(_ url: URL, prefix: String, lines: inout [String]) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return }

        for item in contents {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let name = item.lastPathComponent

            if isDir {
                lines.append("\(prefix)📁 \(name)/")
                listDir(item, prefix: prefix + "  ", lines: &lines)
            } else if name.hasSuffix(".md") {
                let size = (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                let auto = ["me.md", "now.md", "full.md", "MEMORY.md"].contains(name) ? " (auto)" : ""
                lines.append("\(prefix)📄 \(name) [\(sizeStr)]\(auto)")
            }
        }
    }

    // MARK: - New Tool Implementations

    private func toolGetBehaviorPatterns() -> String {
        let patterns = BehaviorPatternEngine(database: database).detectPatterns()

        if patterns.isEmpty {
            return "No behavioral patterns detected yet. Need at least 5 days of data."
        }

        var lines: [String] = ["Behavioral patterns detected (\(patterns.count)):"]
        lines.append("")

        for pattern in patterns {
            lines.append("## \(pattern.title)")
            lines.append("Type: \(patternTypeStr(pattern.type)) | Severity: \(String(format: "%.0f", pattern.severity * 100))%")
            lines.append("Insight: \(pattern.insight)")
            lines.append("Action: \(pattern.action)")
            lines.append("Evidence: \(pattern.evidence)")
            if let project = pattern.project {
                lines.append("Project: \(project)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func patternTypeStr(_ type: BehaviorPattern.PatternType) -> String {
        switch type {
        case .abandonment: "abandonment_risk"
        case .peakWaste: "peak_hour_waste"
        case .focusDecline: "focus_decline"
        case .avoidance: "avoidance"
        case .correlation: "correlation"
        }
    }

    private func toolGetProjects(days: Int) -> String {
        let engine = TimeBlockEngine(database: database)
        let projects = engine.projectSnapshots(days: days)

        if projects.isEmpty {
            return "No projects detected in the last \(days) days."
        }

        var lines: [String] = ["Projects detected (\(projects.count)):"]
        lines.append("")

        for project in projects {
            lines.append("## \(project.name)")
            lines.append("App: \(project.primaryApp) | Total: \(project.totalDurationFormatted) | Last active: \(project.lastActiveFormatted)")
            if project.daysSinceActive >= 3 {
                lines.append("⚠️ STALLED (\(project.daysSinceActive) days)")
            }
            if let file = project.lastFile {
                lines.append("Last file: \(file)")
            }
            if let clip = project.lastClipboard {
                lines.append("Last copied: \(clip)")
            }
            if !project.sessions.isEmpty {
                lines.append("Sessions:")
                for session in project.sessions.prefix(5) {
                    lines.append("  - \(session.dateFormatted): \(session.durationFormatted) — \(session.mainLabel)")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func toolGetKnowledge(query: String) -> String {
        let entries: [KnowledgeEntry]
        if query.isEmpty {
            entries = database.fetchAllKnowledge()
        } else {
            entries = database.searchKnowledge(query: query)
        }

        if entries.isEmpty {
            return query.isEmpty
                ? "No knowledge entries yet. Knowledge is extracted during nightly processing."
                : "No knowledge found for '\(query)'."
        }

        var lines: [String] = ["Knowledge entries (\(entries.count)):"]
        lines.append("")

        for entry in entries {
            lines.append("## \(entry.topic) [\(entry.project)]")
            lines.append("Decision: \(entry.decision)")
            if let reasoning = entry.reasoning, !reasoning.isEmpty {
                lines.append("Why: \(reasoning)")
            }
            if let rejected = entry.rejected, !rejected.isEmpty {
                lines.append("Rejected: \(rejected)")
            }
            if let related = entry.relatedProjects, !related.isEmpty {
                lines.append("Also applies to: \(related)")
            }
            if let tags = entry.tags, !tags.isEmpty {
                lines.append("Tags: \(tags)")
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            lines.append("Date: \(formatter.string(from: entry.sourceDate))")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func toolGetWeekComparison() -> String {
        let engine = TimeBlockEngine(database: database)
        let comp = engine.weekComparison()
        let week = engine.weekSnapshots()

        var lines: [String] = ["Week comparison:"]
        lines.append("")
        lines.append("This week: \(comp.thisWeekHours)")
        lines.append("Last week (same point): \(comp.lastWeekHours)")
        lines.append("Delta: \(comp.deltaFormatted) (\(String(format: "%.0f", comp.durationDeltaPercent))%)")
        lines.append("")
        lines.append("Deep work blocks (2h+): \(comp.thisWeekDeepBlocks) this week, \(comp.lastWeekDeepBlocks) last week")
        lines.append("Context switches: \(comp.thisWeekContextSwitches) this week, \(comp.lastWeekContextSwitches) last week")
        lines.append("")
        lines.append("Day-by-day:")
        for day in week {
            let marker = day.isToday ? " ← today" : ""
            let project = day.mainProject ?? "-"
            lines.append("  \(day.dayName) \(day.dayNumber): \(day.durationFormatted.isEmpty ? "-" : day.durationFormatted) (\(project))\(marker)")
        }

        return lines.joined(separator: "\n")
    }

    private func toolGetRelevant(context: String) -> String {
        var lines: [String] = ["Relevant context for '\(context)':"]
        lines.append("")

        // 1. Knowledge
        let knowledge = database.findRelevantKnowledge(context: context, limit: 3)
        if !knowledge.isEmpty {
            lines.append("## Past Knowledge")
            for entry in knowledge {
                lines.append("- [\(entry.project)] \(entry.topic): \(entry.decision)")
                if let reasoning = entry.reasoning, !reasoning.isEmpty {
                    lines.append("  Why: \(reasoning)")
                }
            }
            lines.append("")
        }

        // 2. Matching projects
        let engine = TimeBlockEngine(database: database)
        let projects = engine.projectSnapshots(days: 14)
        let matching = projects.filter {
            $0.name.localizedCaseInsensitiveContains(context) ||
            ($0.lastFile?.localizedCaseInsensitiveContains(context) ?? false)
        }
        if !matching.isEmpty {
            lines.append("## Related Projects")
            for project in matching {
                lines.append("- \(project.name): \(project.lastActiveFormatted), \(project.totalDurationFormatted)")
                if let file = project.lastFile { lines.append("  Last file: \(file)") }
                if let clip = project.lastClipboard { lines.append("  Last copied: \(clip)") }
            }
            lines.append("")
        }

        // 3. Recent events
        let events = database.searchEvents(query: context, limit: 5)
        if !events.isEmpty {
            lines.append("## Recent Activity")
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd HH:mm"
            for event in events {
                let time = formatter.string(from: event.timestamp)
                let app = event.appName ?? ""
                let text = String((event.textContent ?? "").prefix(100)).replacingOccurrences(of: "\n", with: " ")
                lines.append("- \(time) [\(app)] \(text)")
            }
        }

        if knowledge.isEmpty && matching.isEmpty && events.isEmpty {
            lines.append("No relevant context found for '\(context)'.")
        }

        return lines.joined(separator: "\n")
    }

    private func toolGetBriefing() -> String {
        var lines: [String] = ["Today's Briefing:"]
        lines.append("")

        // 1. Behavior patterns (most important)
        let patterns = BehaviorPatternEngine(database: database).detectPatterns()
        if !patterns.isEmpty {
            lines.append("## Behavioral Alerts")
            for pattern in patterns.prefix(3) {
                lines.append("⚠️ \(pattern.title)")
                lines.append("   \(pattern.insight)")
                lines.append("   → \(pattern.action)")
                lines.append("")
            }
        }

        // 2. Stalled projects
        let engine = TimeBlockEngine(database: database)
        let projects = engine.projectSnapshots(days: 14)
        let stalled = projects.filter { $0.daysSinceActive >= 3 }
        if !stalled.isEmpty {
            lines.append("## Stalled Projects")
            for project in stalled {
                var line = "- \(project.name) (\(project.daysSinceActive) days)"
                if let file = project.lastFile { line += " — last: \(file)" }
                lines.append(line)
            }
            lines.append("")
        }

        // 3. Week comparison
        let comp = engine.weekComparison()
        if comp.lastWeekDuration > 0 {
            lines.append("## Week Status")
            lines.append("This week: \(comp.thisWeekHours) (last week same point: \(comp.lastWeekHours), delta: \(comp.deltaFormatted))")
            lines.append("Deep work: \(comp.thisWeekDeepBlocks) blocks (last week: \(comp.lastWeekDeepBlocks))")
            lines.append("")
        }

        // 4. Schedule
        let calendar = CalendarService()
        if let schedule = calendar.todaySchedule() {
            lines.append("## Schedule")
            lines.append(schedule)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - JSON-RPC Helpers

    private func respond(id: Any?, result: [String: Any]) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id }
        send(msg)
    }

    private func respondToolResult(id: Any?, text: String) {
        respond(id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": false
        ])
    }

    private func respondError(id: Any?, code: Int, message: String) {
        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { msg["id"] = id }
        send(msg)
    }

    private func send(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let json = String(data: data, encoding: .utf8) else { return }
        print(json) // stdout
        fflush(stdout)
    }
}
