import Foundation

/// MCP (Model Context Protocol) server for Dream.
///
/// Runs as a subprocess, communicates via stdio JSON-RPC.
/// Allows Claude Code, Cursor, and any MCP client to query Dream data
/// without the user copying/pasting anything.
///
/// The "なんで知ってるの？" moment:
///   AI asks Dream "what is the user working on?" → Dream answers from live data
///   User never did anything. AI just... knows.
///
/// Resources exposed:
///   dream://me       — who the user is (~200 tokens)
///   dream://now      — what they're working on (~500 tokens)
///   dream://full     — everything (~2000 tokens)
///   dream://today    — raw today's events
///
/// Tools exposed:
///   get_user_context — get me.md + now.md (for mid-conversation queries)
///   search_history   — search past events by keyword
///   get_patterns     — get behavioral analytics
final class MCPServer {

    private let database: DatabaseService
    private let analytics: AnalyticsEngine
    private let dreamDir: URL

    init(database: DatabaseService) {
        self.database = database
        self.analytics = AnalyticsEngine(database: database)
        self.dreamDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Dream")
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
                "serverInfo": ["name": "dream", "version": "1.0.0"]
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
                "description": "Get context about who this user is and what they are currently working on. Call this at the start of a conversation or when you need to understand the user's background, projects, and recent activity. Returns structured profile + current activity data.",
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
                "name": "search_history",
                "description": "Search the user's activity history by keyword. Returns matching events from recorded keystrokes, clipboard, and window titles. Use this when the user references something they did recently and you need specifics.",
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
                "description": "Get the user's behavioral patterns: most used keywords, peak productivity hours, app usage, language mix. Useful for understanding how the user works and adapting your responses accordingly.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "days": [
                            "type": "integer",
                            "description": "Analysis period in days (default 7)"
                        ]
                    ]
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

        case "search_history":
            let query = args["query"] as? String ?? ""
            let days = args["days"] as? Int ?? 7
            let content = searchHistory(query: query, days: days)
            respondToolResult(id: id, text: content)

        case "get_patterns":
            let days = args["days"] as? Int ?? 7
            let content = analytics.generatePatternSummary(days: days)
            respondToolResult(id: id, text: content)

        default:
            respondError(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
    }

    // MARK: - Resources

    private func resourceDefinitions() -> [[String: Any]] {
        [
            [
                "uri": "dream://me",
                "name": "User Profile (me.md)",
                "description": "Who this user is — identity, skills, preferences. ~200 tokens.",
                "mimeType": "text/markdown"
            ],
            [
                "uri": "dream://now",
                "name": "Current Context (now.md)",
                "description": "What the user is currently working on — projects, today's files, app usage. ~500 tokens.",
                "mimeType": "text/markdown"
            ],
            [
                "uri": "dream://full",
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
        case "dream://me": fileName = "me.md"
        case "dream://now": fileName = "now.md"
        case "dream://full": fileName = "full.md"
        default:
            respondError(id: id, code: -32602, message: "Unknown resource: \(uri)")
            return
        }

        let filePath = dreamDir.appendingPathComponent(fileName)
        let content = (try? String(contentsOf: filePath, encoding: .utf8)) ?? "(No data yet. Dream is still recording.)"

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
            let path = dreamDir.appendingPathComponent(file)
            if let content = try? String(contentsOf: path, encoding: .utf8), !content.isEmpty {
                parts.append(content)
            }
        }

        if parts.isEmpty {
            return "(Dream is still recording. No user context available yet. Ask the user directly for now.)"
        }

        return parts.joined(separator: "\n\n")
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
