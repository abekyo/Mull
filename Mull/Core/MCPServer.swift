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
///   mull://start    — the front door: what this is, read order, vault map (read first)
///   mull://me       — who the user is (~200 tokens)
///   mull://now      — what they're working on (~500 tokens)
///   mull://full     — everything (~2000 tokens)
///   mull://today    — raw today's events
///
/// Tools exposed:
///   whats_active_now — what the user is doing right now (the anchor)
///   search           — relevance-ranked, facet-scoped retrieval
///   get_user_context — get me.md + now.md (for mid-conversation queries)
final class MCPServer {

    private let database: DatabaseService
    private let mullDir: URL

    init(database: DatabaseService) {
        self.database = database
        // Through MullDirectory, not a second hand-built path: it owns the
        // ~/Whatly → ~/mull migration and the writability gate, and a vault that
        // moves must move for every reader at once.
        self.mullDir = MullDirectory.root
    }

    /// Sent in the `initialize` response so the agent is oriented before its
    /// first call — the server-side half of the front door (mull.md is the
    /// file-side half). Keep it short and authoritative.
    static let serverInstructions = """
    mull keeps an automatically-recorded, local context record of one person — \
    who they are and what they are doing — so you can help without them \
    re-explaining themselves. At the start of a conversation, read the `mull://me` \
    resource (who they are) and call `whats_active_now` (what they're doing right \
    now). Use `search` and `get_projects` for specifics instead of guessing. For \
    the full map and the order to read things in, read `mull://start` (mull.md). \
    The record is the user's: never assert what they think — if you infer \
    judgment, mark it as a guess they can correct. You may write back with \
    `curate` / `write_note`, but only your own block; the user's writing is never \
    overwritten.
    """

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
                "serverInfo": ["name": "mull", "version": "1.0.0"],
                "instructions": Self.serverInstructions
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
            ],
            [
                "name": "read_file",
                "description": "Read a markdown file from the user's mull vault (a project briefing, note, me.md, etc). Use list_files to discover paths. Provenance markers are stripped for clean reading.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "File path relative to ~/mull/ (e.g. '03_projects/mull.md', 'me.md')"
                        ]
                    ],
                    "required": ["path"]
                ]
            ],
            [
                "name": "curate",
                "description": "Write your contribution back into a mull file SAFELY. Unlike write_note (raw overwrite), curate updates only your own provenance-tagged block (by id) and NEVER clobbers the user's hand edits. Use this for anything mull/agent-generated.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "File path relative to ~/mull/ (.md)"],
                        "block_id": ["type": "string", "description": "Stable id for your block (e.g. 'summary', 'plan'). Re-using the same id updates it in place instead of duplicating."],
                        "content": ["type": "string", "description": "Markdown content for your block"]
                    ],
                    "required": ["path", "block_id", "content"]
                ]
            ],
            [
                "name": "calendar",
                "description": "Planned vs actual, per day: scheduled calendar events (if calendar access is granted) alongside the activity mull actually observed.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "days": ["type": "integer", "description": "How many days back from today to include (default 1 = today, max 14)"]
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

        case "get_projects":
            let days = args["days"] as? Int ?? 14
            let content = toolGetProjects(days: days)
            respondToolResult(id: id, text: content)

        case "get_knowledge":
            let query = args["query"] as? String ?? ""
            let content = toolGetKnowledge(query: query)
            respondToolResult(id: id, text: content)

        case "get_relevant":
            let context = args["context"] as? String ?? ""
            let content = toolGetRelevant(context: context)
            respondToolResult(id: id, text: content)

        case "write_note":
            let path = args["path"] as? String ?? ""
            let content = args["content"] as? String ?? ""
            let result = writeNote(path: path, content: content)
            respondToolResult(id: id, text: result)

        case "list_files":
            let result = listFiles()
            respondToolResult(id: id, text: result)

        case "read_file":
            let path = args["path"] as? String ?? ""
            respondToolResult(id: id, text: readFile(path: path))

        case "curate":
            let path = args["path"] as? String ?? ""
            let blockID = args["block_id"] as? String ?? ""
            let content = args["content"] as? String ?? ""
            respondToolResult(id: id, text: toolCurate(path: path, blockID: blockID, content: content))

        case "calendar":
            let days = args["days"] as? Int ?? 1
            respondToolResult(id: id, text: toolCalendar(days: days))

        default:
            respondError(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
    }

    // MARK: - Resources

    private func resourceDefinitions() -> [[String: Any]] {
        [
            [
                "uri": "mull://start",
                "name": "Start Here (mull.md)",
                "description": "The front door — what this record is, the order to read it in, and a map of the vault. Read this FIRST.",
                "mimeType": "text/markdown"
            ],
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
        case "mull://start": fileName = "mull.md"
        case "mull://me": fileName = "me.md"
        case "mull://now": fileName = "now.md"
        case "mull://full": fileName = "full.md"
        default:
            respondError(id: id, code: -32602, message: "Unknown resource: \(uri)")
            return
        }

        let filePath = mullDir.appendingPathComponent(fileName)
        // Strip Curator provenance markers — they are bookkeeping for the merge,
        // not context, and now.md/full.md carry them too (not just me.md).
        let content = (try? String(contentsOf: filePath, encoding: .utf8))
            .map(ContextBlockFile.stripMarkers)
            ?? "(No data yet. mull is still recording.)"

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

        // Always lead with mull.md — the front door — so a tool-first agent gets
        // the same orientation (read order + map) as one that read the resource.
        switch level {
        case "brief":
            files = ["mull.md", "me.md"]
        case "full":
            files = ["mull.md", "full.md"]
        default:
            files = ["mull.md", "me.md", "now.md"]
        }

        var parts: [String] = []
        for file in files {
            let path = mullDir.appendingPathComponent(file)
            if let raw = try? String(contentsOf: path, encoding: .utf8), !raw.isEmpty {
                parts.append(ContextBlockFile.stripMarkers(raw))
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
        // FTS narrows ASCII text queries at the index; for a type facet (the query
        // may be the category, e.g. "crash") or a CJK query (the default tokenizer
        // doesn't split it) fall back to a recent window so Selection keeps recall.
        let useFTS = !query.isEmpty && type == nil && query.allSatisfy(\.isASCII)
        let events = database.fetchCandidates(
            query: query, since: now.addingTimeInterval(-since),
            useFTS: useFTS, limit: useFTS ? 80 : 300)
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
        // `days` was accepted, advertised in the schema, and echoed in the reply —
        // but never applied: searchEvents has no time bound. Bound it here instead
        // (over-fetch, drop anything older than the window, then trim) so the
        // sentence the agent reads is actually true.
        let cutoff = Date().addingTimeInterval(-TimeInterval(max(days, 1) * 86_400))
        let results = database.searchEvents(query: query, limit: 200)
            .filter { $0.timestamp >= cutoff }
            // Privacy: this is raw keystroke/clipboard text going straight to a
            // third-party AI. The ranked `search` path filters secrets inside
            // Selection.rank; this path bypassed it entirely. Same rule, one place.
            .filter { !SensitiveText.isSensitive($0.textContent ?? "") }
            .prefix(20)

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

    /// A caller-supplied vault path, canonicalized and proven to stay inside ~/mull.
    private struct VaultPath {
        let url: URL          // absolute, symlinks resolved
        let relative: String  // path relative to the resolved mull directory
    }

    /// Canonicalize a relative vault path, then verify containment.
    ///
    /// The old scrub — `replacingOccurrences(of: "..", with: "")` — happened to
    /// hold, but it is the wrong shape: it mangles legitimate names ("v1..v2.md")
    /// and, more importantly, says nothing about symlinks. A link inside ~/mull
    /// pointing at ~/.ssh resolves straight out of the vault while containing no
    /// ".." at all. So: resolve both sides first, compare after.
    /// Why a path was refused. Carries the message the tool hands back to the AI.
    private struct VaultPathError: Error {
        let reason: String
    }

    private func resolveVaultPath(_ path: String) -> Result<VaultPath, VaultPathError> {
        let relative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard relative.hasSuffix(".md") else { return .failure(VaultPathError(reason: "only .md files are allowed")) }

        let base = mullDir.resolvingSymlinksInPath().standardizedFileURL
        // Walk up to the deepest component that actually exists — the file being
        // written may not, but every directory on the way to it does, and that is
        // where a symlink escape would live.
        var existing = base.appendingPathComponent(relative).standardizedFileURL
        var trailing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) {
            trailing.append(existing.lastPathComponent)
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { break }
            existing = parent
        }
        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for component in trailing.reversed() { resolved.appendPathComponent(component) }
        resolved = resolved.standardizedFileURL

        guard resolved.path.hasPrefix(base.path + "/") else {
            return .failure(VaultPathError(reason: "path escapes the mull vault"))
        }
        return .success(VaultPath(url: resolved,
                                  relative: String(resolved.path.dropFirst(base.path.count + 1))))
    }

    /// Files `write_note` must never raw-overwrite.
    ///
    /// me.pinned.md is the user's own file — its header literally says "you own
    /// this file. mull NEVER overwrites it" — and me/now/full/MEMORY plus mull.md
    /// are assembled from provenance blocks by the Curator. A wholesale write here
    /// destroys hand edits and pinned facts, contradicting the promise this server
    /// makes in its own `initialize` instructions. Agents contribute to these
    /// through `curate`, which merges one tagged block and leaves the rest alone.
    private static let curatorOwnedFiles: Set<String> = [
        "me.md", "me.pinned.md", "now.md", "full.md", "MEMORY.md", "mull.md"
    ]

    /// Reason `write_note` must refuse this path, or nil if it may write it.
    /// Folder `index.md` files are Curator-managed too (FolderOntology seeds them
    /// and FolderFiller curates their sections), so they're matched by name.
    private static func writeRefusal(for relative: String) -> String? {
        let name = (relative as NSString).lastPathComponent
        guard curatorOwnedFiles.contains(name) || name == "index.md" else { return nil }
        return "Error: ~/mull/\(relative) is curated — write_note would overwrite the "
            + "user's own writing. Use the `curate` tool instead: it merges your block "
            + "(by block_id) and never clobbers their edits."
    }

    private func writeNote(path: String, content: String) -> String {
        guard !path.isEmpty, !content.isEmpty else {
            return "Error: path and content are required"
        }

        let resolved: VaultPath
        switch resolveVaultPath(path) {
        case .success(let vp): resolved = vp
        case .failure(let e): return "Error: \(e.reason)."
        }
        if let refusal = Self.writeRefusal(for: resolved.relative) { return refusal }

        do {
            try FileManager.default.createDirectory(at: resolved.url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: resolved.url, atomically: true, encoding: .utf8)
            FilePrivacy.protectFile(at: resolved.url)
            return "Written: ~/mull/\(resolved.relative) (\(content.count) chars)"
        } catch {
            return "Error writing file: \(error.localizedDescription)"
        }
    }

    /// Read any vault .md file. Provenance markers are stripped for clean reading,
    /// and secret-bearing lines are withheld (see `redactSensitiveLines`).
    private func readFile(path: String) -> String {
        let resolved: VaultPath
        switch resolveVaultPath(path) {
        case .success(let vp): resolved = vp
        case .failure(let e): return "Error: \(e.reason)."
        }
        guard let content = try? String(contentsOf: resolved.url, encoding: .utf8) else {
            return "Error: could not read ~/mull/\(resolved.relative). Does it exist? Try list_files."
        }
        return Self.redactSensitiveLines(ContextBlockFile.stripMarkers(content))
    }

    /// What the reader sees in place of a withheld line.
    private static let redactionMarker = "[redacted — withheld by mull's privacy filter]"

    /// Apply the same secret gate to file contents that `search` and `get_relevant`
    /// apply to event rows.
    ///
    /// `list_files` followed by `read_file` was a complete, unfiltered dump of the
    /// vault to whatever MCP client asked. A .md file is not safer than an event
    /// row — the vault is assembled FROM those events, so a clipboard secret that
    /// Selection.rank refused to hand over is sitting verbatim in
    /// daily/2026-07-19.md, one tool call away.
    ///
    /// Filtered line by line rather than whole-file: whole-file means one stray key
    /// blanks a 400-line daily note and the agent silently loses the day. And a
    /// withheld line leaves a visible marker rather than vanishing, because an agent
    /// reading a document with holes in it must be able to tell the holes are there
    /// — otherwise it reasons confidently about text it never saw.
    private static func redactSensitiveLines(_ text: String) -> String {
        var out: [String] = []
        var withheld = 0
        var lastWasMarker = false

        for line in text.components(separatedBy: "\n") {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  SensitiveText.isSensitive(line) else {
                out.append(line)
                lastWasMarker = false
                continue
            }
            withheld += 1
            // Collapse a run of secret lines into one marker: a pasted key block or
            // a PEM body is dozens of lines, and dozens of identical markers is its
            // own kind of noise.
            if !lastWasMarker { out.append(Self.redactionMarker) }
            lastWasMarker = true
        }

        guard withheld > 0 else { return text }
        out.append("")
        out.append("_\(withheld) line\(withheld == 1 ? " was" : "s were") withheld from this file "
            + "by mull's privacy filter (addresses, URLs, credentials). Ask the user directly if you need them._")
        return out.joined(separator: "\n")
    }

    /// Provenance-safe write-back: merge the agent's block into the file via the
    /// Curator so the user's hand edits and pinned content are never clobbered.
    private func toolCurate(path: String, blockID: String, content: String) -> String {
        guard !path.isEmpty, !blockID.isEmpty, !content.isEmpty else {
            return "Error: path, block_id, and content are required."
        }
        let resolved: VaultPath
        switch resolveVaultPath(path) {
        case .success(let vp): resolved = vp
        case .failure(let e): return "Error: \(e.reason)."
        }
        let cleaned = resolved.relative

        let existing = MullDirectory.read(cleaned) ?? ""
        let (header, _) = ContextBlockFile.parse(existing)
        let block = ContextBlock(id: blockID, source: .agent, content: content, agentHash: nil)
        let ok = Curator.curate(relativePath: cleaned, header: header,
                                pinnedContent: nil, agentBlocks: [block])
        return ok
            ? "Curated block '\(blockID)' into ~/mull/\(cleaned). The user's edits were preserved."
            : "Error: write failed (mull directory not ready)."
    }

    /// Planned (calendar events) vs actual (observed activity) per day.
    private func toolCalendar(days: Int) -> String {
        let cal = Calendar.current
        let n = max(1, min(days, 14))
        let calendarSvc = CalendarService()
        let engine = TimeBlockEngine(database: database)
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "EEEE, MMM d"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"

        var out: [String] = []
        for offset in 0..<n {
            guard let date = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            out.append("# \(dayFmt.string(from: date))")

            let events = calendarSvc.events(for: date)
            if events.isEmpty {
                out.append("Scheduled: (none, or calendar access not granted to MullMCP)")
            } else {
                out.append("Scheduled:")
                for e in events {
                    out.append("- \(timeFmt.string(from: e.start))–\(timeFmt.string(from: e.end)) \(e.title)")
                }
            }

            let blocks = engine.generateBlocks(for: date)
            if blocks.isEmpty {
                out.append("Activity: (none recorded)")
            } else {
                out.append("Activity (what you actually did):")
                for b in blocks.prefix(20) {
                    let label = b.label.isEmpty ? b.app : b.label
                    out.append("- \(b.startFormatted)–\(b.endFormatted) \(label) (\(b.durationFormatted))")
                }
            }
            out.append("")
        }
        return out.joined(separator: "\n")
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

        // 3. Recent events (same secret filter as `search` — raw event text is
        // about to be handed to a third-party AI).
        let events = database.searchEvents(query: context, limit: 40)
            .filter { !SensitiveText.isSensitive($0.textContent ?? "") }
            .prefix(5)
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

    // MARK: - JSON-RPC Helpers

    // JSON-RPC 2.0 requires `id` to be PRESENT on every response — null when it
    // couldn't be determined. Omitting the key made those responses malformed;
    // strict clients drop them and the call looks like it hung.
    private func respond(id: Any?, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    /// Tool results carry their own success flag. The tool functions signal failure
    /// by returning a string starting with "Error:" — hardcoding `isError: false`
    /// handed those to the client as successful output, so an agent would read
    /// "Error: only .md files are allowed" as the note's contents and move on.
    private func respondToolResult(id: Any?, text: String) {
        respond(id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": text.hasPrefix("Error:")
        ])
    }

    private func respondError(id: Any?, code: Int, message: String) {
        send([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message]
        ])
    }

    private func send(_ msg: [String: Any]) {
        // Test seam (see `handleForTesting`): when a sink is installed the
        // response is handed to it instead of stdout. Nil in production, so the
        // stdio path below is unchanged.
        if let sink = responseSink {
            sink(msg)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let json = String(data: data, encoding: .utf8) else { return }
        print(json) // stdout
        fflush(stdout)
    }

    // MARK: - Testability

    /// Where `send` delivers responses when set. Internal for testability only.
    private var responseSink: (([String: Any]) -> Void)?

    /// Internal for testability: dispatch one JSON-RPC message and return the
    /// response that `run()` would have written to stdout (nil for notifications
    /// and other no-reply methods). Printing to stdout during a test is both
    /// unobservable and, in the real server, the JSON-RPC stream itself.
    func handleForTesting(_ msg: [String: Any]) -> [String: Any]? {
        var captured: [String: Any]?
        responseSink = { captured = $0 }
        defer { responseSink = nil }
        handle(msg)
        return captured
    }
}
