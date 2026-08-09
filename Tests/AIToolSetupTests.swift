import XCTest
@testable import mull

/// One-click connect edits a file mull did not author. `~/.claude.json` holds every
/// other MCP server the user registered and Claude Code's per-project state; a
/// mistake in it is not mull's data to lose. The UI states four promises about that
/// write — other servers are kept, an unreadable file is never overwritten, a
/// timestamped backup lands first, Disconnect removes only mull — and until this
/// file existed all four were promises with nothing behind them: 42 test files, and
/// none of them touched `AIToolSetup`.
///
/// Everything here runs against a scratch directory. `setup` and `detectTools` take
/// the binary and the home directory as parameters for exactly that reason.
final class AIToolSetupTests: XCTestCase {

    private var dir: URL!
    private var config: URL!
    private var binary: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aitoolsetup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        config = dir.appendingPathComponent(".claude.json")
        binary = try makeExecutable(named: "MullMCP")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeExecutable(named name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func tool(_ path: URL? = nil) -> AIToolSetup.AITool {
        AIToolSetup.AITool(id: "claude-code", name: "Claude Code", detected: true,
                           registration: .absent, configPath: (path ?? config).path)
    }

    private func writeConfig(_ json: String) throws {
        try Data(json.utf8).write(to: config)
    }

    private func readConfig() throws -> [String: Any] {
        let data = try Data(contentsOf: config)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var backups: [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return all.filter { $0.hasPrefix(".claude.json.mull-backup-") }.sorted()
    }

    // MARK: - The merge

    func testConnectKeepsEveryOtherServerAndEveryOtherKey() throws {
        try writeConfig("""
        {"mcpServers":{"github":{"command":"/usr/bin/gh-mcp","args":["serve"]}},
         "numStartups":41,"projects":{"/Users/x/code":{"history":["a"]}}}
        """)

        let result = AIToolSetup.setup(tool: tool(), binary: binary)
        XCTAssertNoThrow(try result.get())

        let after = try readConfig()
        let servers = try XCTUnwrap(after["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["mull"] as? [String: Any])?["command"] as? String, binary)
        XCTAssertEqual((servers["github"] as? [String: Any])?["command"] as? String, "/usr/bin/gh-mcp")
        XCTAssertEqual(after["numStartups"] as? Int, 41,
                       "unrelated top-level keys are Claude Code's, not mull's to drop")
        XCTAssertNotNil(after["projects"])
    }

    func testConnectCreatesAConfigThatDoesNotExistYet() throws {
        XCTAssertNoThrow(try AIToolSetup.setup(tool: tool(), binary: binary).get())
        let servers = try XCTUnwrap(try readConfig()["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["mull"])
        XCTAssertTrue(backups.isEmpty, "there was nothing to back up")
    }

    /// The failure this guards against replaced a user's entire config with nothing
    /// but mull's entry, because `try?` turned "cannot understand this file" into
    /// "there is no file".
    func testAnUnreadableConfigIsRefusedAndLeftByteForByte() throws {
        let original = "{ this is not json"
        try writeConfig(original)

        let result = AIToolSetup.setup(tool: tool(), binary: binary)
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
        XCTAssertTrue(backups.isEmpty, "a refused write leaves no trace at all")
    }

    func testAConfigWrittenAgainstADeadPathDoesNotReadAsConnected() throws {
        try writeConfig(#"{"mcpServers":{}}"#)
        let missing = dir.appendingPathComponent("not-built").path

        let result = AIToolSetup.setup(tool: tool(), binary: missing)
        // A path that is not executable is still what the caller asked for; the
        // refusal that matters is the one when nothing can be resolved at all.
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(AIToolSetup.registration(in: config, binary: binary),
                       .missingBinary(command: missing),
                       "a config written against a dead path must not read as connected")
    }

    /// `~/.claude.json` is tens of kilobytes the user is invited to inspect. Hash
    /// order made every write reshuffle all of it, hiding the one line mull changed.
    func testTheWrittenFileIsInSortedKeyOrder() throws {
        try writeConfig(#"{"zeta":1,"alpha":2,"mcpServers":{}}"#)
        XCTAssertNoThrow(try AIToolSetup.setup(tool: tool(), binary: binary).get())

        let text = try String(contentsOf: config, encoding: .utf8)
        let alpha = try XCTUnwrap(text.range(of: "\"alpha\""))
        let servers = try XCTUnwrap(text.range(of: "\"mcpServers\""))
        let zeta = try XCTUnwrap(text.range(of: "\"zeta\""))
        XCTAssertTrue(alpha.lowerBound < servers.lowerBound)
        XCTAssertTrue(servers.lowerBound < zeta.lowerBound)
    }

    /// The whole file is re-serialised on every write, so an escape mull introduces
    /// lands on paths that are none of its business — every project directory in
    /// `~/.claude.json`.
    func testNoPathInTheFileIsRewrittenWithEscapes() throws {
        try writeConfig(#"{"mcpServers":{},"projects":{"/Users/x/code":{"history":[]}}}"#)
        XCTAssertNoThrow(try AIToolSetup.setup(tool: tool(), binary: binary).get())

        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertFalse(text.contains(#"\/"#), "mull escaped the user's own paths: \(text)")
        XCTAssertTrue(text.contains("/Users/x/code"))
    }

    // MARK: - Backups

    func testTheOldFileIsCopiedBeforeTheNewOneLands() throws {
        let original = #"{"mcpServers":{"github":{"command":"/usr/bin/gh-mcp"}}}"#
        try writeConfig(original)

        XCTAssertNoThrow(try AIToolSetup.setup(tool: tool(), binary: binary).get())

        XCTAssertEqual(backups.count, 1)
        let copy = dir.appendingPathComponent(backups[0])
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), original,
                       "the backup is the file as it was, not as mull left it")
    }

    /// Two edits inside one second produced one name, `copyItem` refused to
    /// overwrite it, and the config write was abandoned with "couldn't write a
    /// backup". A double-click on Connect was enough to trigger it.
    func testTwoEditsInTheSameSecondBothSucceed() throws {
        try writeConfig(#"{"mcpServers":{}}"#)

        XCTAssertNoThrow(try AIToolSetup.setup(tool: tool(), binary: binary).get())
        XCTAssertNoThrow(try AIToolSetup.setup(tool: tool(), binary: binary).get())

        XCTAssertEqual(backups.count, 2, "each edit keeps its own copy")
        XCTAssertEqual(Set(backups).count, 2)
    }

    /// Nothing ever deleted one of these, and their names begin with a dot-file's
    /// name, so the pile was invisible in Finder as well as unbounded.
    func testOnlyTheMostRecentBackupsSurvive() throws {
        try writeConfig(#"{"mcpServers":{}}"#)
        for _ in 0..<(AIToolSetup.backupsKept + 4) {
            XCTAssertNoThrow(try AIToolSetup.setup(tool: tool(), binary: binary).get())
        }
        XCTAssertEqual(backups.count, AIToolSetup.backupsKept)
    }

    /// Pruning deletes by name order, so the names have to sort by time — including
    /// within one second, where an earlier freed name must not be handed to the
    /// newest copy.
    func testTheNewestBackupIsTheOneThatSurvives() throws {
        try writeConfig(#"{"mcpServers":{},"generation":0}"#)
        for generation in 1...(AIToolSetup.backupsKept + 3) {
            XCTAssertNoThrow(try AIToolSetup.setup(tool: tool(), binary: binary).get())
            // Leave a mark, so the newest backup is identifiable by content.
            try writeConfig(#"{"mcpServers":{},"generation":\#(generation)}"#)
        }

        let newest = dir.appendingPathComponent(try XCTUnwrap(backups.last))
        let text = try String(contentsOf: newest, encoding: .utf8)
        XCTAssertTrue(text.contains("\"generation\":\(AIToolSetup.backupsKept + 2)")
                        || text.contains("\"generation\" : \(AIToolSetup.backupsKept + 2)"),
                      "the last name in sort order must hold the most recent copy, got: \(text)")
    }

    /// A Mac set to the Japanese calendar wrote `yyyy` as `8` while the format string
    /// said nothing about eras — and the names stopped sorting, which is the only
    /// thing they are for.
    func testBackupNamesAreStampedInSortableDigits() throws {
        try writeConfig(#"{"mcpServers":{}}"#)
        XCTAssertNoThrow(try AIToolSetup.setup(tool: tool(), binary: binary).get())

        let name = try XCTUnwrap(backups.first)
        let stamp = name.replacingOccurrences(of: ".claude.json.mull-backup-", with: "")
        XCTAssertNotNil(stamp.range(of: #"^\d{8}-\d{6}(-\d{2})?$"#, options: .regularExpression),
                        "unexpected stamp: \(stamp)")
    }

    // MARK: - Disconnect

    func testDisconnectRemovesMullAndNothingElse() throws {
        try writeConfig("""
        {"mcpServers":{"mull":{"command":"/somewhere/MullMCP","args":[]},
                       "github":{"command":"/usr/bin/gh-mcp"}},"numStartups":3}
        """)

        XCTAssertNoThrow(try AIToolSetup.disconnect(tool: tool()).get())

        let after = try readConfig()
        let servers = try XCTUnwrap(after["mcpServers"] as? [String: Any])
        XCTAssertNil(servers["mull"])
        XCTAssertNotNil(servers["github"])
        XCTAssertEqual(after["numStartups"] as? Int, 3)
        XCTAssertEqual(backups.count, 1, "removal is an edit too, and gets its backup")
    }

    /// An empty `mcpServers` is what these clients ship with. Deleting the key
    /// outright would be a bigger edit than the user asked for.
    func testDisconnectLeavesTheKeyBehindEmpty() throws {
        try writeConfig(#"{"mcpServers":{"mull":{"command":"/somewhere/MullMCP"}}}"#)
        XCTAssertNoThrow(try AIToolSetup.disconnect(tool: tool()).get())

        let servers = try XCTUnwrap(try readConfig()["mcpServers"] as? [String: Any])
        XCTAssertTrue(servers.isEmpty)
    }

    func testDisconnectSaysSoWhenThereIsNothingToRemove() throws {
        try writeConfig(#"{"mcpServers":{"github":{"command":"/usr/bin/gh-mcp"}}}"#)
        XCTAssertThrowsError(try AIToolSetup.disconnect(tool: tool()).get())
        XCTAssertTrue(backups.isEmpty, "nothing was changed, so nothing was copied")
    }

    // MARK: - What the config actually says

    /// The finding this whole enum exists for: a key called `mull` was read as a
    /// working connection, so moving the app left the row saying "Connected" over a
    /// client that could no longer start the server — and the server test agreed,
    /// because it resolves the binary itself instead of reading what is registered.
    func testAStaleCommandDoesNotReadAsConnected() throws {
        let gone = dir.appendingPathComponent("moved-away/MullMCP").path
        try writeConfig(#"{"mcpServers":{"mull":{"command":"\#(gone)","args":[]}}}"#)

        XCTAssertEqual(AIToolSetup.registration(in: config, binary: binary),
                       .missingBinary(command: gone))
    }

    func testAnotherCopyOfTheBinaryIsItsOwnState() throws {
        let other = try makeExecutable(named: "MullMCP-old")
        try writeConfig(#"{"mcpServers":{"mull":{"command":"\#(other)","args":[]}}}"#)

        XCTAssertEqual(AIToolSetup.registration(in: config, binary: binary),
                       .otherBinary(command: other),
                       "it runs, but it is not the copy this app would write")
    }

    func testTheBinaryThisAppWritesReadsAsCurrent() throws {
        try writeConfig(#"{"mcpServers":{"mull":{"command":"\#(binary!)","args":[]}}}"#)
        XCTAssertEqual(AIToolSetup.registration(in: config, binary: binary), .current)
    }

    func testRegistrationStatesForTheRest() throws {
        XCTAssertEqual(AIToolSetup.registration(in: config, binary: binary), .absent,
                       "no file at all")

        try writeConfig(#"{"mcpServers":{"github":{"command":"/usr/bin/gh-mcp"}}}"#)
        XCTAssertEqual(AIToolSetup.registration(in: config, binary: binary), .absent)

        try writeConfig("{ not json")
        XCTAssertEqual(AIToolSetup.registration(in: config, binary: binary), .unreadable,
                       "unknown is not the same as absent — nothing may be written")

        try writeConfig(#"{"mcpServers":{"mull":{"args":[]}}}"#)
        XCTAssertEqual(AIToolSetup.registration(in: config, binary: binary),
                       .missingBinary(command: ""),
                       "a hand-written entry with no command cannot count as connected")
    }

    func testOnlyCurrentCountsAsWorkingAndTheRestExplainThemselves() {
        XCTAssertNil(AIToolSetup.Registration.current.problem)
        XCTAssertNil(AIToolSetup.Registration.absent.problem)
        let broken: [AIToolSetup.Registration] = [.missingBinary(command: "/gone/MullMCP"),
                                                  .otherBinary(command: "/other/MullMCP"),
                                                  .unreadable]
        for state in broken {
            XCTAssertNotNil(state.problem, "\(state) has to say what is wrong with it")
        }
        XCTAssertTrue(AIToolSetup.Registration.missingBinary(command: "/gone").isRegistered)
        XCTAssertFalse(AIToolSetup.Registration.unreadable.isRegistered,
                       "an unreadable file tells us nothing, including whether mull is in it")
    }

    // MARK: - Detection

    func testDetectionReadsTheConfigRatherThanGuessing() throws {
        // A home with a Claude Code config that registers mull at a live path.
        try writeConfig(#"{"mcpServers":{"mull":{"command":"\#(binary!)","args":[]}}}"#)

        let tools = AIToolSetup.detectTools(home: dir, binary: binary)
        let claudeCode = try XCTUnwrap(tools.first { $0.id == "claude-code" })
        XCTAssertTrue(claudeCode.detected)
        XCTAssertEqual(claudeCode.registration, .current)

        let cursor = try XCTUnwrap(tools.first { $0.id == "cursor" })
        XCTAssertEqual(cursor.registration, .absent, "no config, no registration")
    }

    func testTheManualCommandNamesTheSameBinaryTheButtonsWrite() throws {
        let command = try XCTUnwrap(AIToolSetup.cliCommand(binary: binary))
        XCTAssertTrue(command.contains(binary))
        XCTAssertTrue(command.hasPrefix("claude mcp add"),
                      "this is the command README tells people to run: \(command)")
    }

    /// The preview is shown as the exact change about to be made, so it has to read
    /// as a path. `JSONSerialization` writes `/` as `\/`, which made the sheet show
    /// `"\/Applications\/Mull.app\/…"` — and put the same escapes through every
    /// path in the config file it rewrote.
    func testThePreviewShowsWhatTheWriteWillDo() throws {
        let fragment = try AIToolSetup.configFragment(binary: binary).get()
        XCTAssertTrue(fragment.contains(binary), "escaped or altered: \(fragment)")
        XCTAssertFalse(fragment.contains(#"\/"#))
        XCTAssertTrue(fragment.contains("mcpServers"))

        XCTAssertNoThrow(try AIToolSetup.setup(tool: tool(), binary: binary).get())
        let written = try XCTUnwrap((try readConfig()["mcpServers"] as? [String: Any])?["mull"] as? [String: Any])
        XCTAssertEqual(written["command"] as? String, binary,
                       "consent to a preview that differs from the deed is not consent")
    }
}
