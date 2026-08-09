import XCTest
@testable import mull

/// Tests for MCPServer — the entire AI-facing contract.
///
/// Every downstream AI (Claude Code, Cursor, Claude Desktop) sees mull only
/// through this JSON-RPC surface, and it fails silently: a malformed response
/// looks to the agent like mull "had nothing", not like a bug. So this suite
/// pins the protocol shape itself (id presence, isError, tool inventory) as
/// hard as it pins the tool payloads.
///
/// SAFETY: these tests never touch the user's real vault. `MCPServer.mullDir` is
/// `MullDirectory.root`, which redirects to a throwaway per-PID directory under
/// XCTest (see `MullDirectory.isRunningTests`), so writes here land in a temp
/// vault and are discarded with it. Read paths (`read_file`, `list_files`,
/// resources) see that same empty temp vault, which is why they are asserted on
/// response *shape* rather than on content — there is no real content to expect.
final class MCPServerTests: XCTestCase {

    private var db: DatabaseService!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        // A throwaway database — never DatabaseService(), which would open the
        // user's real recorded history.
        db = try! DatabaseService.temporary()
        server = MCPServer(database: db)
    }

    // MARK: - Helpers

    /// Dispatch a `tools/call` and return the tool's text plus its error flag.
    @discardableResult
    private func callTool(_ name: String,
                          _ arguments: [String: Any] = [:],
                          id: Any? = 1) -> (text: String, isError: Bool) {
        let response = server.handleForTesting([
            "jsonrpc": "2.0", "id": id as Any, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ].compactMapValues { $0 })
        guard let result = response?["result"] as? [String: Any] else {
            return ("<no result: \(response ?? [:])>", true)
        }
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, result["isError"] as? Bool ?? false)
    }

    /// Realistic fixture text. Deliberately avoids pangrams / keyboard mash /
    /// adjacent single-letter words — `TestInput.isLikelyTestInput` discards
    /// those, and every assertion below would then run against empty results.
    private func seedEvent(_ text: String,
                           type: RecordingEvent.EventType = .clipboard,
                           app: String = "Xcode",
                           title: String? = nil,
                           at date: Date = Date()) {
        db.insertEvent(RecordingEvent(
            timestamp: date, eventType: type, appName: app,
            windowTitle: title, textContent: text
        ))
    }

    // MARK: - JSON-RPC Envelope

    func testRespondAlwaysIncludesIDEvenWhenRequestIDWasNil() {
        // JSON-RPC 2.0 requires `id` to be PRESENT on every response, null when
        // it couldn't be determined. Omitting the key produces a message strict
        // clients drop — the call then looks to the agent like it hung.
        let response = server.handleForTesting(["jsonrpc": "2.0", "method": "initialize"])
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.keys.contains("id"), "`id` key must be present, not omitted")
        XCTAssertTrue(response!["id"] is NSNull, "absent request id must serialize as null")

        // And it must survive serialization as a literal null, not vanish.
        let json = String(data: try! JSONSerialization.data(withJSONObject: response!), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"id\":null"), "got: \(json)")
    }

    func testRespondErrorAlwaysIncludesIDEvenWhenRequestIDWasNil() {
        // Same rule on the error branch. An unknown *tool* is used because the
        // unknown-*method* branch intentionally stays silent for notifications.
        let response = server.handleForTesting([
            "jsonrpc": "2.0", "method": "tools/call",
            "params": ["name": "no_such_tool", "arguments": [:]]
        ])
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.keys.contains("id"))
        XCTAssertTrue(response!["id"] is NSNull)
        XCTAssertEqual((response!["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testRequestIDIsEchoedUnchanged() {
        let intID = server.handleForTesting(["jsonrpc": "2.0", "id": 42, "method": "initialize"])
        XCTAssertEqual(intID?["id"] as? Int, 42)

        // MCP allows string ids too; they must not be coerced to a number.
        let stringID = server.handleForTesting(["jsonrpc": "2.0", "id": "req-7", "method": "initialize"])
        XCTAssertEqual(stringID?["id"] as? String, "req-7")
    }

    func testNotificationProducesNoResponse() {
        // `notifications/initialized` has no id and no reply. Emitting anything
        // here would desynchronize the client's request/response pairing.
        XCTAssertNil(server.handleForTesting(["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    func testUnknownMethodReturnsMethodNotFound() {
        let response = server.handleForTesting([
            "jsonrpc": "2.0", "id": 3, "method": "tools/execute"
        ])
        let error = response?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
        XCTAssertEqual((error?["message"] as? String)?.hasPrefix("Method not found"), true)
        XCTAssertNil(response?["result"], "an error response must not also carry a result")
    }

    // MARK: - isError flag

    func testToolResultMarksErrorWhenTextStartsWithError() {
        // The tool functions signal failure by returning a string starting with
        // "Error:". Hardcoding isError:false handed those to the client as
        // successful output — the agent would read "Error: only .md files are
        // allowed" as the note's contents and carry on.
        let (text, isError) = callTool("write_note", ["path": "", "content": ""])
        XCTAssertTrue(text.hasPrefix("Error:"), "got: \(text)")
        XCTAssertTrue(isError)
    }

    func testToolResultIsNotErrorForOrdinaryOutput() {
        // The empty-database answer is a legitimate "nothing yet", not a failure.
        let (text, isError) = callTool("whats_active_now")
        XCTAssertFalse(text.hasPrefix("Error:"))
        XCTAssertFalse(isError)
    }

    // MARK: - initialize

    func testInitializeReturnsHandshakeAndInstructions() {
        let result = server.handleForTesting([
            "jsonrpc": "2.0", "id": 1, "method": "initialize"
        ])?["result"] as? [String: Any]
        XCTAssertNotNil(result)

        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-03-26")

        let capabilities = result?["capabilities"] as? [String: Any]
        XCTAssertNotNil(capabilities?["tools"])
        XCTAssertNotNil(capabilities?["resources"])

        let serverInfo = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "mull")
        XCTAssertNotNil(serverInfo?["version"] as? String)

        // The instructions string is the server-side front door: it is what
        // orients an agent before its first call, so its key directives are
        // part of the contract, not prose.
        let instructions = result?["instructions"] as? String ?? ""
        XCTAssertEqual(instructions, MCPServer.serverInstructions)
        XCTAssertTrue(instructions.contains("mull://me"))
        XCTAssertTrue(instructions.contains("whats_active_now"))
        XCTAssertTrue(instructions.contains("mull://start"))
    }

    // MARK: - tools/list

    func testToolsListExposesTheFullInventory() {
        let result = server.handleForTesting([
            "jsonrpc": "2.0", "id": 1, "method": "tools/list"
        ])?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]] ?? []

        // Exact set, not just a count: a renamed or dropped tool silently breaks
        // every agent that learned to call it.
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, [
            "get_user_context", "whats_active_now", "search", "get_projects",
            "get_knowledge", "get_relevant", "search_history", "write_note",
            "list_files", "read_file", "curate", "calendar"
        ])
        XCTAssertEqual(tools.count, 12, "no duplicate entries")
    }

    func testEveryToolDefinitionIsWellFormed() {
        let result = server.handleForTesting([
            "jsonrpc": "2.0", "id": 1, "method": "tools/list"
        ])?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]] ?? []
        XCTAssertFalse(tools.isEmpty)

        for tool in tools {
            let name = tool["name"] as? String ?? "<unnamed>"
            // The description is the only thing an agent uses to decide whether
            // to call a tool at all — an empty one makes the tool dead weight.
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty, "\(name) has no description")

            let schema = tool["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", "\(name) schema must be an object")
            XCTAssertNotNil(schema?["properties"], "\(name) schema has no properties map")

            // Anything listed in `required` has to actually exist in properties,
            // or the client rejects every call it builds from the schema.
            let properties = schema?["properties"] as? [String: Any] ?? [:]
            for required in (schema?["required"] as? [String] ?? []) {
                XCTAssertNotNil(properties[required], "\(name): required '\(required)' is not declared")
            }
        }
    }

    func testEveryAdvertisedToolIsDispatchable() {
        // A tool listed but not handled falls through to "Unknown tool" — a
        // -32602 the agent can only discover by trying. Read-only tools only:
        // write_note/curate are called with arguments that refuse before writing.
        let safeArguments: [String: [String: Any]] = [
            "get_user_context": ["detail_level": "brief"],
            "whats_active_now": [:],
            "search": ["query": "storyboard"],
            "get_projects": ["days": 1],
            "get_knowledge": ["query": "migration"],
            "get_relevant": ["context": "PantryApp"],
            "search_history": ["query": "storyboard", "days": 1],
            "list_files": [:],
            "read_file": ["path": "definitely-not-a-real-file-9f3a.md"],
            // Refusal paths only — both return before any filesystem write.
            "write_note": ["path": "", "content": ""],
            "curate": ["path": "", "block_id": "", "content": ""],
        ]
        for (name, arguments) in safeArguments {
            let response = server.handleForTesting([
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": name, "arguments": arguments]
            ])
            XCTAssertNil(response?["error"], "\(name) was advertised but not dispatched")
            XCTAssertNotNil(response?["result"], "\(name) returned no result")
        }
    }

    // MARK: - resources

    func testResourcesListExposesTheFourContextFiles() {
        let result = server.handleForTesting([
            "jsonrpc": "2.0", "id": 1, "method": "resources/list"
        ])?["result"] as? [String: Any]
        let resources = result?["resources"] as? [[String: Any]] ?? []

        XCTAssertEqual(Set(resources.compactMap { $0["uri"] as? String }),
                       ["mull://start", "mull://me", "mull://now", "mull://full"])
        for resource in resources {
            XCTAssertEqual(resource["mimeType"] as? String, "text/markdown")
            XCTAssertFalse((resource["name"] as? String ?? "").isEmpty)
        }
    }

    func testUnknownResourceURIIsRejected() {
        let response = server.handleForTesting([
            "jsonrpc": "2.0", "id": 1, "method": "resources/read",
            "params": ["uri": "mull://secrets"]
        ])
        XCTAssertEqual((response?["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testResourceReadReturnsMarkdownEnvelope() {
        // Read-only against the real vault: asserted on envelope shape only,
        // never on the user's actual content (which varies per machine and is
        // theirs, not a fixture).
        let result = server.handleForTesting([
            "jsonrpc": "2.0", "id": 1, "method": "resources/read",
            "params": ["uri": "mull://me"]
        ])?["result"] as? [String: Any]
        let contents = result?["contents"] as? [[String: Any]] ?? []
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents.first?["uri"] as? String, "mull://me")
        XCTAssertEqual(contents.first?["mimeType"] as? String, "text/markdown")
        // Always a string — a missing file yields the placeholder, never nil.
        XCTAssertNotNil(contents.first?["text"] as? String)
    }

    // MARK: - write_note refusals (no write happens on any of these paths)

    func testWriteNoteRefusesNonMarkdownPaths() {
        // resolveVaultPath rejects on suffix before touching the filesystem.
        for path in ["notes/todo.txt", "scripts/run.sh", "notes/report"] {
            let (text, isError) = callTool("write_note", ["path": path, "content": "release notes draft"])
            XCTAssertTrue(text.contains("only .md files are allowed"), "\(path) → \(text)")
            XCTAssertTrue(isError)
        }
    }

    func testWriteNoteRefusesCuratorOwnedAndUserOwnedFiles() {
        // me.pinned.md is the user's own file; me/now/full/MEMORY/mull.md are
        // assembled from provenance blocks by the Curator. A raw overwrite here
        // destroys hand edits and pinned facts — exactly what this server's own
        // `initialize` instructions promise never happens.
        for name in ["me.md", "me.pinned.md", "now.md", "full.md", "MEMORY.md", "mull.md"] {
            let (text, isError) = callTool("write_note", ["path": name, "content": "# overwritten"])
            XCTAssertTrue(isError, "\(name) was not refused: \(text)")
            XCTAssertTrue(text.contains("is curated"), "\(name) → \(text)")
            // The refusal has to route the agent somewhere, or it just gives up.
            XCTAssertTrue(text.contains("`curate`"), "\(name) refusal does not point at curate: \(text)")
        }
    }

    func testWriteNoteRefusesFolderIndexAtAnyDepth() {
        // FolderOntology seeds index.md and FolderFiller curates its sections,
        // so they are Curator-managed wherever they live — matched by name, not
        // by a fixed path list.
        for path in ["index.md", "notes/index.md", "03_projects/mull/deep/index.md"] {
            let (text, isError) = callTool("write_note", ["path": path, "content": "# overwritten"])
            XCTAssertTrue(isError, "\(path) was not refused: \(text)")
            XCTAssertTrue(text.contains("is curated"), "\(path) → \(text)")
        }
    }

    func testWriteNoteRefusesVaultEscape() {
        // Containment is checked on the *resolved* path, so a traversal is
        // refused whether or not it contains a literal "..".
        for path in ["../escaped-note.md", "notes/../../escaped-note.md", "../../tmp/escaped-note.md"] {
            let (text, isError) = callTool("write_note", ["path": path, "content": "payload"])
            XCTAssertTrue(text.contains("escapes the mull vault"), "\(path) → \(text)")
            XCTAssertTrue(isError)
        }
        // And nothing was created outside the vault by the attempt.
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("escaped-note.md").path))
    }

    func testWriteNoteRequiresPathAndContent() {
        XCTAssertTrue(callTool("write_note", ["path": "notes/a.md", "content": ""]).isError)
        XCTAssertTrue(callTool("write_note", ["path": "", "content": "text"]).isError)
    }

    func testCurateRefusesBeforeAnyWriteWhenArgumentsAreIncomplete() {
        // Guard clause returns ahead of Curator.curate, so no vault write occurs.
        let (text, isError) = callTool("curate", ["path": "notes/a.md", "block_id": "", "content": "x"])
        XCTAssertEqual(text, "Error: path, block_id, and content are required.")
        XCTAssertTrue(isError)
    }

    func testCurateRefusesVaultEscapeBeforeAnyWrite() {
        let (text, isError) = callTool("curate", [
            "path": "../escaped-block.md", "block_id": "summary", "content": "payload"
        ])
        XCTAssertTrue(text.contains("escapes the mull vault"), text)
        XCTAssertTrue(isError)
    }

    // MARK: - search_history

    func testSearchHistoryHonoursTheDaysWindow() {
        // `days` was accepted, advertised, and echoed in the reply sentence — but
        // never applied, so an agent asking for "the last day" got results from
        // months ago labelled as today's.
        seedEvent("Fixed the storyboard segue crash in RegisterAccountViewController")
        seedEvent("Archived the storyboard migration plan from the spring rewrite",
                  at: Date().addingTimeInterval(-30 * 86_400))

        let narrow = callTool("search_history", ["query": "storyboard", "days": 1]).text
        XCTAssertTrue(narrow.contains("RegisterAccountViewController"), narrow)
        XCTAssertFalse(narrow.contains("spring rewrite"), "a 30-day-old event leaked into a 1-day window")

        let wide = callTool("search_history", ["query": "storyboard", "days": 90]).text
        XCTAssertTrue(wide.contains("RegisterAccountViewController"), wide)
        XCTAssertTrue(wide.contains("spring rewrite"), "widening the window should recover the old event")
    }

    func testSearchHistoryNeverLeaksSensitiveText() {
        // This path hands raw keystroke/clipboard text straight to a third-party
        // AI. The ranked `search` path filters secrets inside Selection.rank;
        // this one bypassed it entirely.
        seedEvent("Fixed the storyboard segue crash in RegisterAccountViewController")
        seedEvent("storyboard deploy notes — api_key: sk-live-8f21c0b4d7e9a3f5b6c1")

        let (text, isError) = callTool("search_history", ["query": "storyboard", "days": 7])
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("RegisterAccountViewController"), "the benign match should survive: \(text)")
        XCTAssertFalse(text.contains("sk-live-8f21c0b4d7e9a3f5b6c1"), "secret leaked to the agent: \(text)")
        XCTAssertFalse(text.contains("api_key"), "secret leaked to the agent: \(text)")
    }

    func testSearchHistoryOnEmptyDatabaseSaysSoInsteadOfFailing() {
        let (text, isError) = callTool("search_history", ["query": "storyboard", "days": 7])
        XCTAssertEqual(text, "No events found matching 'storyboard' in the last 7 days.")
        XCTAssertFalse(isError, "\"nothing recorded yet\" is an answer, not a failure")
    }

    // MARK: - search (ranked selection)

    func testSearchReturnsRankedMatchForSeededActivity() {
        seedEvent("Fixed the NavigationStack push regression in the settings flow")
        seedEvent("Reviewed the invoice reconciliation spreadsheet for June")

        let (text, isError) = callTool("search", ["query": "NavigationStack", "days": 7])
        XCTAssertFalse(isError)
        XCTAssertTrue(text.hasPrefix("Relevant to 'NavigationStack'"), text)
        XCTAssertTrue(text.contains("NavigationStack"), text)
        // Ranked, not dumped: the unrelated event must not ride along.
        XCTAssertFalse(text.contains("invoice reconciliation"), text)
    }

    func testSearchNeverSurfacesSensitiveText() {
        seedEvent("NavigationStack rollout checklist, bearer sk-live-3c9d1f0a7b2e4658")

        let text = callTool("search", ["query": "NavigationStack", "days": 7]).text
        XCTAssertFalse(text.contains("sk-live-3c9d1f0a7b2e4658"), text)
    }

    func testSearchOnEmptyDatabaseSaysSoInsteadOfFailing() {
        let (text, isError) = callTool("search", ["query": "NavigationStack"])
        XCTAssertTrue(text.hasPrefix("No relevant activity for 'NavigationStack'"), text)
        XCTAssertFalse(isError)
    }

    // MARK: - whats_active_now

    func testWhatsActiveNowReportsTheAnchorFromRecentEvents() {
        // The anchor is built from window-title (screenText) events, which the
        // recorder writes every few seconds.
        seedEvent("PantryApp — RegisterAccountViewController.swift",
                  type: .screenText, app: "Xcode",
                  title: "PantryApp — RegisterAccountViewController.swift")

        let (text, isError) = callTool("whats_active_now")
        XCTAssertFalse(isError)
        // A markdown list, so the anchor can be embedded under any heading the
        // reader supplies — `now.md` puts it under `## Right now`, the tool hands
        // it back on its own. The bare `Active:` / `App:` label lines it replaced
        // were prose to every renderer and carried no level to nest at.
        XCTAssertTrue(text.contains("- **App:** Xcode"), text)
        XCTAssertTrue(text.contains("- **Active:**"), text)
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            XCTAssertTrue(line.trimmingCharacters(in: .whitespaces).hasPrefix("- "),
                          "not a list item: \(line)")
        }
    }

    func testWhatsActiveNowOnEmptyDatabaseSaysSoInsteadOfFailing() {
        let (text, isError) = callTool("whats_active_now")
        XCTAssertEqual(text, "(no recent activity)")
        XCTAssertFalse(isError)
    }

    // MARK: - get_projects

    func testGetProjectsOnEmptyDatabaseSaysSoInsteadOfFailing() {
        let (text, isError) = callTool("get_projects", ["days": 14])
        XCTAssertEqual(text, "No projects detected in the last 14 days.")
        XCTAssertFalse(isError)
        // The window in the sentence must match the window that was asked for.
        XCTAssertEqual(callTool("get_projects", ["days": 3]).text,
                       "No projects detected in the last 3 days.")
    }

    func testGetProjectsDefaultsToFourteenDaysWhenUnspecified() {
        XCTAssertEqual(callTool("get_projects").text, "No projects detected in the last 14 days.")
    }

    // MARK: - get_knowledge

    func testGetKnowledgeRendersSeededEntries() {
        db.insertKnowledge(KnowledgeEntry(
            topic: "Binding strategy",
            decision: "Closure-based callbacks over Combine",
            reasoning: "The project has no Combine dependency and the team is on macOS 12",
            rejected: "Combine, RxSwift",
            project: "PantryApp",
            relatedProjects: "mull",
            tags: "architecture,mvvm",
            sourceDate: Date(), createdAt: Date()
        ))

        let (text, isError) = callTool("get_knowledge", ["query": ""])
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("Knowledge entries (1)"), text)
        XCTAssertTrue(text.contains("## Binding strategy [PantryApp]"), text)
        XCTAssertTrue(text.contains("Decision: Closure-based callbacks over Combine"), text)
        // The optional fields are what make an entry actionable rather than a
        // bare verdict — they must be rendered when present.
        XCTAssertTrue(text.contains("Why: "), text)
        XCTAssertTrue(text.contains("Rejected: Combine, RxSwift"), text)
        XCTAssertTrue(text.contains("Tags: architecture,mvvm"), text)
    }

    func testGetKnowledgeDistinguishesEmptyStoreFromNoMatch() {
        // Two different "nothing" answers: one tells the agent the pipeline has
        // not run yet, the other that this topic genuinely is not recorded.
        XCTAssertTrue(callTool("get_knowledge", ["query": ""]).text
            .hasPrefix("No knowledge entries yet"))

        db.insertKnowledge(KnowledgeEntry(
            topic: "Binding strategy", decision: "Closure-based callbacks",
            project: "PantryApp", sourceDate: Date(), createdAt: Date()
        ))
        XCTAssertEqual(callTool("get_knowledge", ["query": "kubernetes"]).text,
                       "No knowledge found for 'kubernetes'.")
    }

    // MARK: - get_relevant

    func testGetRelevantOnEmptyDatabaseSaysSoInsteadOfFailing() {
        let (text, isError) = callTool("get_relevant", ["context": "PantryApp"])
        XCTAssertTrue(text.contains("No relevant context found for 'PantryApp'."), text)
        XCTAssertFalse(isError)
    }

    func testGetRelevantNeverSurfacesSensitiveText() {
        seedEvent("PantryApp staging credentials — password: hunter-brawl-2026")

        let text = callTool("get_relevant", ["context": "PantryApp"]).text
        XCTAssertFalse(text.contains("hunter-brawl-2026"), text)
    }

    // MARK: - calendar

    func testCalendarRendersPlannedVsActualPerDay() {
        // Calendar access may or may not be granted to the test host, so only
        // the day scaffolding is asserted — both branches print a "Scheduled:"
        // line, and an empty DB always prints the no-activity line.
        let (text, isError) = callTool("calendar", ["days": 2])
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("Scheduled"), text)
        XCTAssertTrue(text.contains("Activity: (none recorded)"), text)
        // One "# <weekday>, <month> <day>" header per requested day.
        let headers = text.split(separator: "\n").filter { $0.hasPrefix("# ") }
        XCTAssertEqual(headers.count, 2)
    }

    func testCalendarClampsTheRequestedWindow() {
        // days is clamped to 1...14; an absurd request must not fan out.
        let headers = callTool("calendar", ["days": 400]).text
            .split(separator: "\n").filter { $0.hasPrefix("# ") }
        XCTAssertEqual(headers.count, 14)

        let zero = callTool("calendar", ["days": 0]).text
            .split(separator: "\n").filter { $0.hasPrefix("# ") }
        XCTAssertEqual(zero.count, 1)
    }

    // MARK: - get_user_context / read_file (read-only against the real vault)

    func testGetUserContextAlwaysReturnsUsableTextAtEveryLevel() {
        // Content is the user's own and varies per machine, so this asserts the
        // contract only: never empty, never an error, at every detail level.
        for level in ["brief", "normal", "full", "nonsense-level"] {
            let (text, isError) = callTool("get_user_context", ["detail_level": level])
            XCTAssertFalse(isError, "\(level) → \(text)")
            XCTAssertFalse(text.isEmpty, "\(level) returned empty text")
        }
    }

    func testReadFileRejectsNonMarkdownAndEscapesBeforeTouchingDisk() {
        XCTAssertTrue(callTool("read_file", ["path": "../.ssh/id_rsa"]).text
            .contains("only .md files are allowed"))
        XCTAssertTrue(callTool("read_file", ["path": "../../etc/hosts.md"]).text
            .contains("escapes the mull vault"))
    }

    func testReadFileReportsAMissingFileAsAnErrorNotEmptyContent() {
        // An agent that reads "" concludes the note is blank; it needs to know
        // the file simply is not there.
        let (text, isError) = callTool("read_file", ["path": "notes/no-such-note-4b71e2.md"])
        XCTAssertTrue(text.hasPrefix("Error: could not read"), text)
        XCTAssertTrue(isError)
    }

    func testListFilesReturnsAHeaderAndDoesNotFail() {
        let (text, isError) = callTool("list_files")
        XCTAssertFalse(isError)
        XCTAssertTrue(text.hasPrefix("Files in ~/mull/:"), text)
    }
}
