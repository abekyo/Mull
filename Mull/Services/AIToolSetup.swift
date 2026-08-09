import Foundation

/// One-click connect: register mull's MCP server with the AI tools the user
/// already runs, so the "なんで知ってるの？" moment works without anyone editing
/// a config file.
///
/// Writes to each client's REAL MCP location (this is the part the old version
/// got wrong — it wrote `mcpServers` into `~/.claude/settings.json`, which Claude
/// Code does not read for MCP):
///   - Claude Code    → ~/.claude.json                                  (user scope)
///   - Claude Desktop → ~/Library/Application Support/Claude/claude_desktop_config.json
///   - Cursor         → ~/.cursor/mcp.json
///
/// Every write MERGES into existing config (other servers/keys are preserved).
/// `testConnection()` actually spawns the bundled binary and performs the MCP
/// `initialize` handshake — proof it connects, not just that a string is present.
///
/// `cliCommand()` is the same deed by hand, for the clients this file does not
/// know about. There will always be some: the list below is three of a dozen MCP
/// clients, and an app that can only be connected by a button it does not have a
/// row for is not connectable at all.
struct AIToolSetup {

    /// What a client's config actually says about mull.
    ///
    /// This used to be a `Bool` called `configured`, set by "is there a key named
    /// mull". A key is not a working connection. The value mull writes is an
    /// absolute path to `MullMCP`, and that path goes stale the moment the app
    /// moves: a dev build replaced by one in /Applications, a reinstall, a deleted
    /// build directory. The row went on saying "Connected" while the client failed
    /// to launch the server — and `testConnection()` agreed with it, because that
    /// test re-resolves the binary itself instead of reading what is registered.
    /// Two green ticks over a dead integration, with nothing anywhere to hint at
    /// it. So the state now carries the command on record and is judged against
    /// the file system.
    enum Registration: Equatable {
        /// No `mcpServers.mull` — or no config file yet.
        case absent
        /// Registered, and the command on record is an executable: the one this
        /// build resolves, when there is a local copy to compare it against.
        case current
        /// Registered, but the command is not an executable file. This is the
        /// broken case — the client will fail to start mull.
        case missingBinary(command: String)
        /// Registered and runnable, but a different copy of MullMCP than this app
        /// would write: an older bundle still on disk, or a manual install.
        case otherBinary(command: String)
        /// The config exists and is not JSON mull can parse, so what is registered
        /// is unknown. Nothing may be written until the user fixes the file.
        case unreadable

        /// True when mull's entry is in the file, working or not. `.unreadable` is
        /// not included: we do not know.
        var isRegistered: Bool {
            switch self {
            case .current, .missingBinary, .otherBinary: true
            case .absent, .unreadable: false
            }
        }

        /// The command on record, when there is one worth showing the user.
        var command: String? {
            switch self {
            case .missingBinary(let c), .otherBinary(let c): c.isEmpty ? nil : c
            case .absent, .current, .unreadable: nil
            }
        }

        /// One line a row can print about a registration that needs attention.
        /// Nil when there is nothing to say.
        var problem: String? {
            switch self {
            case .absent, .current: nil
            case .missingBinary(let c):
                c.isEmpty
                    ? "Registered without a command. Reconnect to fix it."
                    : "Points at a file that is no longer there."
            case .otherBinary:
                "Points at a different copy of MullMCP than this app."
            case .unreadable:
                "This file is not JSON mull can read, so mull left it alone."
            }
        }
    }

    struct AITool: Identifiable {
        let id: String        // "claude-code" | "claude-desktop" | "cursor"
        let name: String
        let detected: Bool    // is this client installed?
        let registration: Registration
        let configPath: String
    }

    // MARK: - Detect

    /// `home` and `binary` are injectable so this can be tested against a scratch
    /// directory: the whole point of the code below is what it does to a file the
    /// user owns, and that is not something to verify by hand on a real machine.
    static func detectTools(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            binary: String? = nil) -> [AITool] {
        let fm = FileManager.default
        let resolvedBinary = binary ?? mullMCPPath()

        // Every caller below is asking about a directory — a config folder, or an
        // .app bundle, which is one. The `isDir` flag was filled in and then never
        // read, so this was `fileExists` under another name and a stray plain file
        // named `.cursor` or `Cursor.app` counted as the tool being installed.
        func dirExists(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }

        // Claude Code — user-scope MCP lives in ~/.claude.json
        let claudeCode = home.appendingPathComponent(".claude.json")
        let claudeCodeDetected = fm.fileExists(atPath: claudeCode.path)
            || dirExists(home.appendingPathComponent(".claude"))

        /// An app bundle can live somewhere other than /Applications — ~/Applications,
        /// a Homebrew cask prefix, a second volume. Detection used to check the one
        /// fixed path, and a miss removed the Connect button entirely, leaving no way
        /// to set up a tool the user plainly has.
        /// Kept to plain path checks rather than LaunchServices, so detection stays a
        /// cheap read of the file system with no AppKit and no side effects.
        func appInstalled(named name: String) -> Bool {
            let roots = ["/Applications", "/System/Applications",
                         home.appendingPathComponent("Applications").path]
            if roots.contains(where: { dirExists(URL(fileURLWithPath: $0).appendingPathComponent(name)) }) {
                return true
            }
            // Homebrew keeps the bundle at Caskroom/<token>/<version>/<App>.app, two
            // levels down. The old check looked for Caskroom/<App>.app, which exists
            // in no Homebrew installation, so this whole branch had never once
            // matched — a check that read as coverage and provided none.
            for caskroom in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
                let root = URL(fileURLWithPath: caskroom)
                guard let tokens = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                else { continue }
                for token in tokens {
                    guard let versions = try? fm.contentsOfDirectory(at: token, includingPropertiesForKeys: nil)
                    else { continue }
                    if versions.contains(where: { dirExists($0.appendingPathComponent(name)) }) {
                        return true
                    }
                }
            }
            return false
        }

        // Claude Desktop — ~/Library/Application Support/Claude/claude_desktop_config.json
        let desktopCfg = home.appendingPathComponent(
            "Library/Application Support/Claude/claude_desktop_config.json")
        let desktopDetected = dirExists(desktopCfg.deletingLastPathComponent())
            || appInstalled(named: "Claude.app")

        // Cursor — ~/.cursor/mcp.json
        let cursorCfg = home.appendingPathComponent(".cursor/mcp.json")
        let cursorDetected = dirExists(home.appendingPathComponent(".cursor"))
            || appInstalled(named: "Cursor.app")

        return [
            AITool(id: "claude-code", name: "Claude Code",
                   detected: claudeCodeDetected,
                   registration: registration(in: claudeCode, binary: resolvedBinary),
                   configPath: claudeCode.path),
            AITool(id: "claude-desktop", name: "Claude Desktop",
                   detected: desktopDetected,
                   registration: registration(in: desktopCfg, binary: resolvedBinary),
                   configPath: desktopCfg.path),
            AITool(id: "cursor", name: "Cursor",
                   detected: cursorDetected,
                   registration: registration(in: cursorCfg, binary: resolvedBinary),
                   configPath: cursorCfg.path),
        ]
    }

    /// Read one client's config and say what it holds for mull. Judged against the
    /// file system rather than by string comparison alone: what matters to the user
    /// is whether the client can launch what is on record.
    static func registration(in url: URL, binary: String?) -> Registration {
        let config: [String: Any]
        do { config = try readConfig(at: url) }
        catch { return .unreadable }

        guard let servers = config["mcpServers"] as? [String: Any],
              let entry = servers["mull"] else { return .absent }

        // A hand-written entry can be almost anything. Whatever mull cannot read a
        // command out of counts as registered-but-broken, never as connected.
        let command = ((entry as? [String: Any])?["command"] as? String) ?? ""
        guard !command.isEmpty else { return .missingBinary(command: "") }
        guard fm.isExecutableFile(atPath: command) else { return .missingBinary(command: command) }
        guard let binary else { return .current }   // runnable; no local copy to compare with
        return command == binary ? .current : .otherBinary(command: command)
    }

    // MARK: - Connect

    static func setup(tool: AITool, binary: String? = nil) -> Result<String, Error> {
        switch tool.id {
        case "claude-code", "claude-desktop", "cursor":
            return writeMCPConfig(path: tool.configPath, toolName: tool.name, binary: binary)
        default:
            return .failure(SetupError.unsupportedTool)
        }
    }

    /// Merge `mcpServers.mull = { command, args }` into a client's JSON config,
    /// preserving everything else already in the file. Refuses to write at all if
    /// an existing config can't be read or parsed, and always leaves a timestamped
    /// backup beside it first.
    private static func writeMCPConfig(path: String, toolName: String,
                                       binary: String?) -> Result<String, Error> {
        guard let binary = binary ?? mullMCPPath() else { return .failure(SetupError.binaryNotFound) }
        let url = URL(fileURLWithPath: path)
        do {
            var config = try readConfig(at: url)

            var servers = config["mcpServers"] as? [String: Any] ?? [:]
            servers["mull"] = ["command": binary, "args": [String]()]
            config["mcpServers"] = servers

            try write(config, to: url)
            return .success("\(toolName) connected — quit and reopen \(toolName) to load mull.")
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Disconnect

    /// Remove mull's entry from a client's MCP config, leaving every other server
    /// untouched.
    ///
    /// Why this exists: "Connect" was a one-way door. Once written, the row became
    /// a terminal "Connected" badge, so mull could add itself to somebody's AI
    /// tooling but not take itself back out — the user had to hand-edit JSON to
    /// undo a button press. A custode hands things back.
    static func disconnect(tool: AITool) -> Result<String, Error> {
        let url = URL(fileURLWithPath: tool.configPath)
        do {
            var config = try readConfig(at: url)
            guard var servers = config["mcpServers"] as? [String: Any],
                  servers["mull"] != nil else {
                return .failure(SetupError.notConfigured(tool.name))
            }
            servers.removeValue(forKey: "mull")
            // The key stays, now empty: an empty `mcpServers` is what these clients
            // ship with, and deleting the key outright is a bigger edit than the
            // user asked for.
            config["mcpServers"] = servers

            try write(config, to: url)
            return .success("\(tool.name) disconnected — quit and reopen \(tool.name) to drop mull.")
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Consent preview

    /// The exact JSON mull would merge in, pretty-printed for the confirmation
    /// sheet — built from the same values the write uses, so the preview cannot
    /// drift from the deed. Consent to a config edit you were never shown is not
    /// consent.
    static func configFragment(binary: String? = nil) -> Result<String, Error> {
        guard let binary = binary ?? mullMCPPath() else { return .failure(SetupError.binaryNotFound) }
        let fragment: [String: Any] = [
            "mcpServers": ["mull": ["command": binary, "args": [String]()]]
        ]
        guard let data = try? JSONSerialization.data(
                withJSONObject: fragment,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return .failure(SetupError.badResponse())
        }
        return .success(text)
    }

    /// The command that does by hand exactly what Connect does.
    ///
    /// Two people need it. Someone whose client mull has no row for — Windsurf,
    /// Zed, VS Code, Codex, Cline, Continue — for whom the app was otherwise a
    /// dead end, since the only copy of the path lived inside a sheet reachable
    /// through another tool's Connect button. And anyone whose Claude Code is
    /// open right now: that process owns `~/.claude.json` and writes the whole
    /// document back as it runs, so an edit made underneath it can be lost. The
    /// CLI hands the edit to the process that owns the file.
    static func cliCommand(binary: String? = nil) -> String? {
        (binary ?? mullMCPPath()).map {
            "claude mcp add --transport stdio --scope user mull -- \($0)"
        }
    }

    // MARK: - Config file I/O

    /// Read a client's config, or `[:]` if it doesn't exist yet.
    ///
    /// "No config yet" and "config we could not understand" are NOT the same
    /// thing. The old code used `try?` + `as?` for both, so an unreadable or
    /// malformed file silently became `[:]` — and the write then replaced the
    /// client's entire config with nothing but mull's entry. For ~/.claude.json
    /// that is every other MCP server AND Claude Code's per-project state.
    /// Absent is fine; unreadable aborts.
    private static func readConfig(at url: URL) throws -> [String: Any] {
        guard fm.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw SetupError.configUnreadable(url.lastPathComponent) }
        guard !data.isEmpty else { return [:] }
        guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SetupError.configUnreadable(url.lastPathComponent)
        }
        return existing
    }

    /// Back up, then atomically replace. Every path that edits a file mull did not
    /// author goes through here, so "a backup is written" is true of disconnect as
    /// well as connect.
    private static func write(_ config: [String: Any], to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        // Keep a timestamped copy before touching a file we did not author.
        // If the backup can't be made, don't write — an unrecoverable mistake
        // in ~/.claude.json is far worse than a failed button.
        if fm.fileExists(atPath: url.path) {
            let backup = backupURL(for: url)
            do { try fm.copyItem(at: url, to: backup) }
            catch { throw SetupError.backupFailed(backup.lastPathComponent) }
            pruneBackups(for: url)
        }

        // `.sortedKeys` as well as `.prettyPrinted`. Without it JSONSerialization
        // emits the dictionary in hash order, so adding one entry re-shuffled the
        // entire file — and ~/.claude.json is tens of kilobytes of per-project
        // state, in which the one line mull actually changed then became
        // impossible to find. A file the user is invited to inspect has to diff.
        //
        // `.withoutEscapingSlashes` for the same reason, one layer down:
        // JSONSerialization writes `/` as `\/`, so a re-serialised ~/.claude.json
        // came back with every path in it — every project directory of the user's,
        // not only mull's line — escaped. Valid JSON that no human wrote and no
        // diff can read past.
        let out = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: url, options: .atomic)
    }

    /// How many timestamped copies of one config file are kept.
    static let backupsKept = 3

    /// `<config>.mull-backup-<yyyyMMdd-HHmmss>`, with a two-digit suffix when that
    /// name is already taken.
    ///
    /// The formatter is pinned to `en_US_POSIX` for the reason every other fixed
    /// format in mull is (see `Curator`): with the current locale, a Mac set to the
    /// Japanese calendar writes `yyyy` as `8`, and the backups stop sorting by
    /// time — which is the only thing their names are for. The suffix is here
    /// because two edits inside one second produced the same name, `copyItem`
    /// refused to overwrite it, and the write was abandoned with "couldn't write a
    /// backup". A double-click on Connect was enough to do that.
    private static func backupURL(for url: URL) -> URL {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = "mull-backup-\(stamp.string(from: Date()))"
        let bare = url.appendingPathExtension(base)

        // The suffix goes past the highest one already present, rather than filling
        // the first free gap. Pruning can free an earlier name, and reusing it would
        // make the newest copy sort oldest — so the next prune would delete the very
        // copy just taken, and keep three older ones.
        let dir = url.deletingLastPathComponent()
        let prefix = bare.lastPathComponent
        let sameSecond = (try? fm.contentsOfDirectory(atPath: dir.path))?
            .filter { $0 == prefix || $0.hasPrefix(prefix + "-") } ?? []
        guard !sameSecond.isEmpty else { return bare }

        let highest = sameSecond.compactMap { name -> Int? in
            name == prefix ? 1 : Int(name.dropFirst(prefix.count + 1))
        }.max() ?? 1
        let candidate = url.appendingPathExtension("\(base)-\(String(format: "%02d", min(highest + 1, 99)))")
        // 99 edits inside one second is not a real sequence, but `copyItem` refuses
        // to overwrite, and refusing to write the config over a full name space
        // would be a worse answer than dropping one duplicate copy of this second.
        if fm.fileExists(atPath: candidate.path) { try? fm.removeItem(at: candidate) }
        return candidate
    }

    /// Delete all but the newest `backupsKept` backups of this config.
    ///
    /// Every connect and every disconnect copied the file, and nothing ever
    /// removed one. Because the names begin with the config's own dot-name, the
    /// pile was invisible in Finder as well: a growing heap of ~/.claude.json
    /// copies in the home directory that the user was never told about and could
    /// not see. Keeping a few is what makes a backup a safety net; keeping every
    /// one forever is litter, and litter mull left in someone else's house.
    private static func pruneBackups(for url: URL) {
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".mull-backup-"
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        // The POSIX stamp sorts lexically in time order, which is the whole reason
        // it is formatted that way.
        let ours = entries.filter { $0.hasPrefix(prefix) }.sorted()
        for name in ours.dropLast(backupsKept) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Where the backup for a given config lands, named for the sheet that has to
    /// promise it.
    static func backupDescription(for tool: AITool) -> String {
        "\(URL(fileURLWithPath: tool.configPath).lastPathComponent).mull-backup-<timestamp>"
    }

    /// The folder those copies sit in, so the promise can say where to look.
    static func backupFolder(for tool: AITool) -> String {
        URL(fileURLWithPath: tool.configPath).deletingLastPathComponent().path
    }

    // MARK: - Test connection (real handshake)

    /// Spawn the bundled MullMCP binary and run the MCP `initialize` handshake.
    /// Succeeds only if the server replies as "mull" — proof the binary exists,
    /// runs, and speaks the protocol.
    ///
    /// Note what this does NOT prove: that any client is pointed at this binary.
    /// It resolves the path itself. That gap is what `Registration` closes, and
    /// the label on the button says "mull's MCP server" rather than "the
    /// connection" for the same reason.
    static func testConnection() -> Result<String, Error> {
        guard let binary = mullMCPPath() else { return .failure(SetupError.binaryNotFound) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        let stdin = Pipe(), stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        // The server's stderr is where a startup crash says what went wrong. It
        // used to be discarded, so "cannot open its database" reached the user as
        // the blank "Server did not respond".
        let stderr = Pipe()
        proc.standardError = stderr

        do { try proc.run() } catch { return .failure(error) }

        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\n"
        stdin.fileHandleForWriting.write(Data(request.utf8))

        // Read until we have a COMPLETE line, with a timeout so a hung binary can't
        // block. One `availableData` read can return half a JSON object — that used
        // to parse-fail and report "unexpected response" for a healthy server. The
        // buffer lives in a lock-guarded box because the reader thread keeps writing
        // to it while, on timeout, this thread reads it (that was a data race).
        let box = ResponseBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let handle = stdout.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }        // EOF — the server exited
                if box.append(chunk) { break }    // a newline arrived: one full line
            }
            sem.signal()
        }
        let timedOut = sem.wait(timeout: .now() + 5) == .timedOut

        try? stdin.fileHandleForWriting.close()
        proc.terminate()
        proc.waitUntilExit()   // reap the child; terminate() alone leaves a zombie

        // Whatever the server complained about on its way down, minus the routine
        // "Server started" line it prints when healthy.
        let complaint = String(data: stderr.fileHandleForReading.availableData, encoding: .utf8)?
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.contains("Server started") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .last

        if timedOut { return .failure(SetupError.timedOut(detail: complaint)) }
        let received = box.firstLine()

        guard let obj = try? JSONSerialization.jsonObject(with: received) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let info = result["serverInfo"] as? [String: Any],
              (info["name"] as? String) == "mull" else {
            return .failure(SetupError.badResponse(detail: complaint))
        }
        return .success("Connected to mull's MCP server.")
    }

    // MARK: - Helpers

    /// Lock-guarded stdout accumulator shared between `testConnection`'s reader
    /// thread and the thread that gives up on it.
    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        /// Append a chunk; true once the buffer holds a newline-terminated line.
        func append(_ chunk: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            buffer.append(chunk)
            return buffer.contains(UInt8(ascii: "\n"))
        }

        /// The first complete line, or everything read so far if none is terminated.
        func firstLine() -> Data {
            lock.lock(); defer { lock.unlock() }
            guard let end = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return buffer }
            return buffer[buffer.startIndex..<end]
        }
    }

    private static let fm = FileManager.default

    /// Resolve the MullMCP executable. Bundled-app locations first, then the dev
    /// build's sibling product, then common install paths. Returns nil if none
    /// is an actual executable — callers surface "build/install MullMCP" instead
    /// of writing a config that points at nothing.
    static func mullMCPPath() -> String? {
        var candidates: [String] = []
        // Inside a shipped app bundle (Contents/Helpers or Contents/MacOS).
        candidates.append(Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/MullMCP").path)
        if let aux = Bundle.main.path(forAuxiliaryExecutable: "MullMCP") {
            candidates.append(aux)
        }
        // Dev: Mull.app and MullMCP land side-by-side in the build products dir.
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("MullMCP").path)
        // Manual installs.
        candidates.append("/usr/local/bin/MullMCP")
        candidates.append(fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/MullMCP").path)

        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    enum SetupError: LocalizedError {
        case unsupportedTool, binaryNotFound
        /// `detail` is the server's last stderr line, when it left one. Without it
        /// a server that died on startup — an unwritable database, a missing
        /// dependency — reported only that it hadn't answered.
        case timedOut(detail: String? = nil)
        case badResponse(detail: String? = nil)
        case configUnreadable(String)
        case backupFailed(String)
        case notConfigured(String)
        var errorDescription: String? {
            switch self {
            case .unsupportedTool: "Unsupported AI tool"
            case .binaryNotFound:  "MullMCP binary not found — build/install it first"
            case .timedOut(let detail):
                detail.map { "Server did not respond. It said: \($0)" }
                    ?? "Server did not respond"
            case .badResponse(let detail):
                detail.map { "Unexpected response from server. It said: \($0)" }
                    ?? "Unexpected response from server"
            case .notConfigured(let name):
                "mull isn't in \(name)'s MCP config — nothing to remove."
            case .configUnreadable(let name):
                "\(name) exists but couldn't be read as JSON. Nothing was written — "
                    + "fix or move that file, then connect again."
            case .backupFailed(let name):
                "Couldn't write a backup (\(name)) before editing the config. "
                    + "Nothing was written."
            }
        }
    }
}
