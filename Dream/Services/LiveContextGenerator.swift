import Foundation

/// Generates me.md / now.md / full.md from raw event data + analytics.
/// NO LLM required. Pure rule-based. Runs every 60 seconds.
///
/// This ensures that "AIがあなたを知っている状態" works from day one,
/// before the nightly Dream has ever run.
enum LiveContextGenerator {

    private static let dreamDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Dream")
    }()

    static func generate(analytics: AnalyticsEngine, database: DatabaseService) throws {
        try FileManager.default.createDirectory(at: dreamDir, withIntermediateDirectories: true)

        let memories = database.fetchAllMemories()
        let summaries = database.fetchRecentSummaries(limit: 7)
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)

        try generateMe(memories: memories, analytics: analytics, timestamp: timestamp)
        try generateNow(memories: memories, summaries: summaries, analytics: analytics, database: database, timestamp: timestamp)
        try generateFull(database: database, analytics: analytics, timestamp: timestamp)
        try installToClaudeConfig()
    }

    // MARK: - me.md (~200 tokens) — Who you are

    private static func generateMe(memories: [MemoryEntry], analytics: AnalyticsEngine, timestamp: String) throws {
        var lines: [String] = []
        lines.append("About the user (auto-updated: \(timestamp)):")
        lines.append("")

        // From Dream memories (if they exist)
        let userMemories = memories.filter { $0.memoryType == .user }
        if !userMemories.isEmpty {
            for mem in userMemories {
                lines.append("- \(mem.description)")
            }
        }

        // From analytics (always available, even before first Dream)
        let lang = analytics.languageMix(days: 30)
        if lang.japanesePercent > 20 && lang.englishPercent > 20 {
            lines.append("- Bilingual user (Japanese \(pct(lang.japanesePercent))%, English \(pct(lang.englishPercent))%)")
        } else if lang.japanesePercent > 50 {
            lines.append("- Primary language: Japanese")
        } else if lang.englishPercent > 50 {
            lines.append("- Primary language: English")
        }

        if lang.codePercent > 15 {
            lines.append("- Writes code (\(pct(lang.codePercent))% of input is code)")
        }

        // Top apps → infer role
        let apps = analytics.appUsage(days: 7)
        let topAppNames = apps.prefix(3).map(\.appName)
        if topAppNames.contains("Xcode") || topAppNames.contains("Code") {
            lines.append("- Software developer (primary tools: \(topAppNames.joined(separator: ", ")))")
        }

        // Preferences from feedback memories
        let feedback = memories.filter { $0.memoryType == .feedback }
        for mem in feedback.prefix(3) {
            lines.append("- \(mem.description)")
        }

        if lines.count <= 2 {
            lines.append("- (Dream is still learning about this user. More data will improve this profile.)")
        }

        try lines.joined(separator: "\n")
            .write(to: dreamDir.appendingPathComponent("me.md"), atomically: true, encoding: .utf8)
    }

    // MARK: - now.md (~500 tokens) — What you're working on

    private static func generateNow(
        memories: [MemoryEntry],
        summaries: [DailySummary],
        analytics: AnalyticsEngine,
        database: DatabaseService,
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

        // Today's activity from live events
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let todayEvents = database.fetchEvents(from: startOfDay, to: Date())

        if !todayEvents.isEmpty {
            // Window titles → what files/pages are open
            var titleSeen = Set<String>()
            var titleLines: [String] = []
            for event in todayEvents where event.eventType == .screenText {
                guard let text = event.textContent, !text.isEmpty else { continue }
                let key = String(text.prefix(50).lowercased())
                guard !titleSeen.contains(key) else { continue }
                titleSeen.insert(key)
                titleLines.append("- \(text) (\(event.appName ?? ""))")
            }
            // Compress typing sequences
            let compressed = compress(titleLines)
            if !compressed.isEmpty {
                lines.append("Today's files/pages:")
                lines.append(contentsOf: Array(compressed.prefix(10)))
                lines.append("")
            }

            // App usage today
            let appGroups = Dictionary(grouping: todayEvents) { $0.appName ?? "Unknown" }
                .sorted { $0.value.count > $1.value.count }
            if !appGroups.isEmpty {
                lines.append("App usage today:")
                for (app, events) in appGroups.prefix(5) {
                    lines.append("- \(app): \(events.count) events")
                }
                lines.append("")
            }
        }

        // Recent summaries (if Dream has run before)
        if !summaries.isEmpty {
            lines.append("Recent days:")
            for s in summaries.prefix(5) {
                lines.append("- \(s.dateShort): \(s.preview)")
            }
            lines.append("")
        }

        // Behavioral patterns
        let patterns = analytics.generatePatternSummary(days: 7)
        if !patterns.isEmpty {
            lines.append(patterns)
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

        try lines.joined(separator: "\n")
            .write(to: dreamDir.appendingPathComponent("now.md"), atomically: true, encoding: .utf8)
    }

    // MARK: - full.md — Everything

    private static func generateFull(database: DatabaseService, analytics: AnalyticsEngine, timestamp: String) throws {
        var parts: [String] = []

        // Combine me.md + now.md
        let mePath = dreamDir.appendingPathComponent("me.md")
        let nowPath = dreamDir.appendingPathComponent("now.md")

        if let me = try? String(contentsOf: mePath, encoding: .utf8) {
            parts.append(me)
        }
        if let now = try? String(contentsOf: nowPath, encoding: .utf8) {
            parts.append(now)
        }

        // Add raw recent input for maximum context
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let todayEvents = database.fetchEvents(from: startOfDay, to: Date())

        let keystrokeEvents = todayEvents.filter { $0.eventType == .keystroke }
        if !keystrokeEvents.isEmpty {
            parts.append("")
            parts.append("Raw keyboard input today (\(keystrokeEvents.count) entries):")
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            for event in keystrokeEvents.suffix(50) {
                guard let text = event.textContent, !text.isEmpty else { continue }
                let time = formatter.string(from: event.timestamp)
                let clean = String(text.prefix(300)).replacingOccurrences(of: "\n", with: "\\n")
                parts.append("- \(time) [\(event.appName ?? "")] \(clean)")
            }
        }

        let clipEvents = todayEvents.filter { $0.eventType == .clipboard }
        if !clipEvents.isEmpty {
            parts.append("")
            parts.append("Clipboard today (\(clipEvents.count) entries):")
            for event in clipEvents {
                guard let text = event.textContent, !text.isEmpty else { continue }
                let clean = String(text.prefix(500)).replacingOccurrences(of: "\n", with: "\\n")
                parts.append("- \(clean)")
            }
        }

        try parts.joined(separator: "\n")
            .write(to: dreamDir.appendingPathComponent("full.md"), atomically: true, encoding: .utf8)
    }

    // MARK: - Auto-install into Claude Code config

    /// Install Dream into Claude Code and Cursor:
    ///   1. Symlink ~/Dream/ into ~/.claude/dream/
    ///   2. Add Dream instruction to ~/.claude/CLAUDE.md
    ///   3. Register DreamMCP server in Claude Code config
    ///   4. Register DreamMCP server in Cursor config (.cursor/mcp.json)
    private static func installToClaudeConfig() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        // 1. Symlink ~/.claude/dream/ → ~/Dream/
        let claudeDir = home.appendingPathComponent(".claude")
        try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let dreamLink = claudeDir.appendingPathComponent("dream")
        if !fm.fileExists(atPath: dreamLink.path) {
            try? fm.createSymbolicLink(at: dreamLink, withDestinationURL: dreamDir)
        }

        // 2. CLAUDE.md instruction
        let claudeMdPath = claudeDir.appendingPathComponent("CLAUDE.md")
        let dreamInstruction = """

        # Dream — User Context
        Read ~/.claude/dream/me.md and ~/.claude/dream/now.md for context about who this user is and what they are working on.
        The Dream MCP server is also available — use get_user_context tool for live data.

        """

        if fm.fileExists(atPath: claudeMdPath.path) {
            let existing = (try? String(contentsOf: claudeMdPath, encoding: .utf8)) ?? ""
            if !existing.contains("dream/me.md") {
                try (existing + "\n" + dreamInstruction).write(to: claudeMdPath, atomically: true, encoding: .utf8)
            }
        } else {
            try dreamInstruction.write(to: claudeMdPath, atomically: true, encoding: .utf8)
        }

        // 3. Register MCP server in Claude Code
        // Find the DreamMCP binary (built alongside Dream.app)
        let mcpBinary = findMCPBinary()

        if let binaryPath = mcpBinary {
            // Register in ~/.claude.json (user scope — works across all projects)
            let claudeJsonPath = home.appendingPathComponent(".claude.json")
            registerMCPServer(at: claudeJsonPath, binaryPath: binaryPath)

            // Also register for Cursor (project-level .mcp.json)
            // Users can copy this to their project roots
            let cursorMcpPath = dreamDir.appendingPathComponent("mcp.json")
            let cursorConfig: [String: Any] = [
                "mcpServers": [
                    "dream": [
                        "command": binaryPath,
                        "args": [] as [String]
                    ]
                ]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: cursorConfig, options: .prettyPrinted) {
                try? data.write(to: cursorMcpPath)
            }
        }
    }

    /// Find the DreamMCP binary. Check common locations.
    private static func findMCPBinary() -> String? {
        let fm = FileManager.default
        let candidates = [
            // Installed app
            "/Applications/Dream.app/Contents/MacOS/DreamMCP",
            // Xcode DerivedData (development)
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/DerivedData")
                .path,
            // Next to Dream app
            Bundle.main.bundlePath + "/../DreamMCP",
            // In ~/Dream/
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Dream/DreamMCP").path,
        ]

        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Search DerivedData for built DreamMCP
        let derivedData = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        if let contents = try? fm.contentsOfDirectory(atPath: derivedData.path) {
            for dir in contents where dir.hasPrefix("Dream-") {
                let buildPath = derivedData
                    .appendingPathComponent(dir)
                    .appendingPathComponent("Build/Products/Debug/DreamMCP")
                if fm.isExecutableFile(atPath: buildPath.path) {
                    return buildPath.path
                }
            }
        }

        return nil
    }

    /// Register DreamMCP in a claude.json config file.
    private static func registerMCPServer(at configPath: URL, binaryPath: String) {
        var config: [String: Any] = [:]

        // Read existing config
        if let data = try? Data(contentsOf: configPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = existing
        }

        // Add/update mcpServers.dream
        var mcpServers = config["mcpServers"] as? [String: Any] ?? [:]
        mcpServers["dream"] = [
            "command": binaryPath,
            "args": [] as [String]
        ]
        config["mcpServers"] = mcpServers

        // Write back
        if let data = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) {
            try? data.write(to: configPath)
        }
    }

    // MARK: - Helpers

    private static func pct(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    /// Remove incremental typing sequences, keep only final version.
    private static func compress(_ items: [String]) -> [String] {
        guard !items.isEmpty else { return [] }
        var result: [String] = []
        for i in 0..<items.count {
            if i + 1 < items.count {
                let current = items[i]
                let next = items[i + 1]
                if next.hasPrefix(current) || current.hasPrefix(next) { continue }
            }
            result.append(items[i])
        }
        return result
    }
}
