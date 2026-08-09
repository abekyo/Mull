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
struct AIToolSetup {

    struct AITool: Identifiable {
        let id: String        // "claude-code" | "claude-desktop" | "cursor"
        let name: String
        let detected: Bool    // is this client installed?
        let configured: Bool  // is mull already in its MCP config?
        let configPath: String
    }

    // MARK: - Detect

    static func detectTools() -> [AITool] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

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
        /// Kept to plain path checks rather than LaunchServices: this file is also
        /// compiled into the headless MullMCP binary, which links no AppKit.
        func appInstalled(named name: String) -> Bool {
            let roots = ["/Applications", "/System/Applications",
                         home.appendingPathComponent("Applications").path,
                         "/opt/homebrew/Caskroom"]
            return roots.contains { dirExists(URL(fileURLWithPath: $0).appendingPathComponent(name)) }
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
                   detected: claudeCodeDetected, configured: mullConfigured(in: claudeCode),
                   configPath: claudeCode.path),
            AITool(id: "claude-desktop", name: "Claude Desktop",
                   detected: desktopDetected, configured: mullConfigured(in: desktopCfg),
                   configPath: desktopCfg.path),
            AITool(id: "cursor", name: "Cursor",
                   detected: cursorDetected, configured: mullConfigured(in: cursorCfg),
                   configPath: cursorCfg.path),
        ]
    }

    // MARK: - Connect

    static func setup(tool: AITool) -> Result<String, Error> {
        switch tool.id {
        case "claude-code", "claude-desktop", "cursor":
            return writeMCPConfig(path: tool.configPath, toolName: tool.name)
        default:
            return .failure(SetupError.unsupportedTool)
        }
    }

    /// Merge `mcpServers.mull = { command, args }` into a client's JSON config,
    /// preserving everything else already in the file. Refuses to write at all if
    /// an existing config can't be read or parsed, and always leaves a timestamped
    /// backup beside it first.
    private static func writeMCPConfig(path: String, toolName: String) -> Result<String, Error> {
        guard let binary = mullMCPPath() else { return .failure(SetupError.binaryNotFound) }
        let url = URL(fileURLWithPath: path)
        do {
            var config = try readConfig(at: url)

            var servers = config["mcpServers"] as? [String: Any] ?? [:]
            servers["mull"] = ["command": binary, "args": [String]()]
            config["mcpServers"] = servers

            try write(config, to: url)
            return .success("\(toolName) connected — restart \(toolName) to load mull.")
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
            return .success("\(tool.name) disconnected — restart \(tool.name) to drop mull.")
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Consent preview

    /// The exact JSON mull would merge in, pretty-printed for the confirmation
    /// sheet — built from the same values the write uses, so the preview cannot
    /// drift from the deed. Consent to a config edit you were never shown is not
    /// consent.
    static func configFragment() -> Result<String, Error> {
        guard let binary = mullMCPPath() else { return .failure(SetupError.binaryNotFound) }
        let fragment: [String: Any] = [
            "mcpServers": ["mull": ["command": binary, "args": [String]()]]
        ]
        guard let data = try? JSONSerialization.data(
                withJSONObject: fragment, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return .failure(SetupError.badResponse())
        }
        return .success(text)
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
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let backup = url.appendingPathExtension("mull-backup-\(stamp.string(from: Date()))")
            do { try fm.copyItem(at: url, to: backup) }
            catch { throw SetupError.backupFailed(backup.lastPathComponent) }
        }

        let out = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        try out.write(to: url, options: .atomic)
    }

    /// Where the backup for a given config lands, named for the sheet that has to
    /// promise it.
    static func backupDescription(for tool: AITool) -> String {
        "\(URL(fileURLWithPath: tool.configPath).lastPathComponent).mull-backup-<timestamp>"
    }

    // MARK: - Test connection (real handshake)

    /// Spawn the bundled MullMCP binary and run the MCP `initialize` handshake.
    /// Succeeds only if the server replies as "mull" — proof the binary exists,
    /// runs, and speaks the protocol.
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

    private static func mullConfigured(in url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = config["mcpServers"] as? [String: Any] else {
            return false
        }
        return servers["mull"] != nil
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
