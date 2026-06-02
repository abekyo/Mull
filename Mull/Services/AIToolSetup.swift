import Foundation

/// Auto-detect and configure AI tools to use mull's MCP server.
///
/// Detects:
///   - Claude Code (~/.claude/)
///   - Cursor (~/Library/Application Support/Cursor/)
///
/// Writes MCP server config so the AI tool connects to mull automatically.
/// User never touches a config file.
struct AIToolSetup {

    struct AITool: Identifiable {
        let id: String       // e.g. "claude-code"
        let name: String     // e.g. "Claude Code"
        let detected: Bool   // Is this tool installed?
        let configured: Bool // Is mull's MCP already configured?
        let configPath: String
    }

    /// Detect all AI tools and their mull configuration status.
    static func detectTools() -> [AITool] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var tools: [AITool] = []

        // Claude Code
        let claudeDir = home.appendingPathComponent(".claude")
        let claudeSettings = claudeDir.appendingPathComponent("settings.json")
        let claudeDetected = FileManager.default.fileExists(atPath: claudeDir.path)
        let claudeConfigured = ismullConfigured(in: claudeSettings)
        tools.append(AITool(
            id: "claude-code",
            name: "Claude Code",
            detected: claudeDetected,
            configured: claudeConfigured,
            configPath: claudeSettings.path
        ))

        // Also check CLAUDE.md for the file-read approach
        let claudeMd = home.appendingPathComponent(".claude/CLAUDE.md")
        let claudeMdDetected = FileManager.default.fileExists(atPath: claudeMd.path)
        let claudeMdConfigured = isMullInClaudeMd(at: claudeMd)
        tools.append(AITool(
            id: "claude-md",
            name: "Claude Code (CLAUDE.md)",
            detected: claudeMdDetected,
            configured: claudeMdConfigured,
            configPath: claudeMd.path
        ))

        // Cursor
        let cursorDir = home.appendingPathComponent("Library/Application Support/Cursor/User")
        let cursorSettings = cursorDir.appendingPathComponent("globalStorage/cursor-mcp/settings.json")
        let cursorDetected = FileManager.default.fileExists(atPath: cursorDir.path)
        let cursorConfigured = ismullConfigured(in: cursorSettings)
        tools.append(AITool(
            id: "cursor",
            name: "Cursor",
            detected: cursorDetected,
            configured: cursorConfigured,
            configPath: cursorSettings.path
        ))

        return tools
    }

    /// Configure mull MCP for a specific tool.
    static func setup(tool: AITool) -> Result<String, Error> {
        switch tool.id {
        case "claude-code":
            return setupClaudeCodeMCP(settingsPath: tool.configPath)
        case "claude-md":
            return setupClaudeMd(path: tool.configPath)
        case "cursor":
            return setupCursorMCP(settingsPath: tool.configPath)
        default:
            return .failure(SetupError.unsupportedTool)
        }
    }

    // MARK: - Claude Code MCP Setup

    private static func setupClaudeCodeMCP(settingsPath: String) -> Result<String, Error> {
        let mcpBinary = mullMCPPath()
        let url = URL(fileURLWithPath: settingsPath)

        do {
            // Read existing settings or create new
            var settings: [String: Any]
            if let data = try? Data(contentsOf: url),
               let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = existing
            } else {
                settings = [:]
            }

            // Add/update mcpServers
            var mcpServers = settings["mcpServers"] as? [String: Any] ?? [:]
            mcpServers["mull"] = [
                "command": mcpBinary,
                "args": [] as [String]
            ]
            settings["mcpServers"] = mcpServers

            // Write back
            let parentDir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)

            return .success("Claude Code MCP configured at \(settingsPath)")
        } catch {
            return .failure(error)
        }
    }

    // MARK: - CLAUDE.md Setup

    private static func setupClaudeMd(path: String) -> Result<String, Error> {
        let instruction = "\n# mull — User Context\nRead ~/mull/me.md and ~/mull/now.md for context about who this user is and what they are working on.\n"
        let url = URL(fileURLWithPath: path)

        do {
            var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

            // Don't add if already present
            if content.contains("mull") || content.contains("mull/me.md") {
                return .success("Already configured in CLAUDE.md")
            }

            content += instruction

            try content.write(to: url, atomically: true, encoding: .utf8)
            return .success("CLAUDE.md updated with mull context instruction")
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Cursor MCP Setup

    private static func setupCursorMCP(settingsPath: String) -> Result<String, Error> {
        let mcpBinary = mullMCPPath()
        let url = URL(fileURLWithPath: settingsPath)

        do {
            var settings: [String: Any]
            if let data = try? Data(contentsOf: url),
               let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = existing
            } else {
                settings = [:]
            }

            var mcpServers = settings["mcpServers"] as? [String: Any] ?? [:]
            mcpServers["mull"] = [
                "command": mcpBinary,
                "args": [] as [String]
            ]
            settings["mcpServers"] = mcpServers

            let parentDir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)

            return .success("Cursor MCP configured at \(settingsPath)")
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Helpers

    private static func mullMCPPath() -> String {
        // Check common locations for MullMCP binary
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("MullMCP").path,
            "/usr/local/bin/MullMCP",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/MullMCP").path,
            Bundle.main.path(forAuxiliaryExecutable: "MullMCP") ?? ""
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: assume it will be at the standard location
        return "/usr/local/bin/MullMCP"
    }

    private static func ismullConfigured(in settingsURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcpServers = settings["mcpServers"] as? [String: Any] else {
            return false
        }
        return mcpServers["mull"] != nil
    }

    private static func isMullInClaudeMd(at url: URL) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
        // Match the actual instruction setupClaudeMd writes ("Read ~/mull/me.md …"),
        // not any stray mention of the word "mull".
        return content.contains("mull/me.md")
    }

    enum SetupError: LocalizedError {
        case unsupportedTool
        var errorDescription: String? { "Unsupported AI tool" }
    }
}
