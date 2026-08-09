/// MullMCP — standalone MCP server binary.
///
/// Launched by Claude Code / Cursor as a subprocess.
/// Reads JSON-RPC from stdin, writes responses to stdout.
///
/// Registration:
///   claude mcp add --transport stdio --scope user mull -- /path/to/MullMCP
///
/// Or in ~/.claude.json:
///   { "mcpServers": { "mull": { "command": "/path/to/MullMCP" } } }

import Foundation

/// Say what went wrong on stderr, in a form the host can show, and stop.
///
/// This binary has no UI: when it fails at startup, the only thing the person who
/// clicked "Connect" ever saw was Settings' blank "Server did not respond". The
/// app's connection test now reads this line back and shows it, so a vault or a
/// database mull cannot open explains itself instead of looking like a hang.
func die(_ reason: String) -> Never {
    FileHandle.standardError.write(Data("[MullMCP] \(reason)\n".utf8))
    exit(1)
}

// Ready the ~/mull directory so Curator-based write-back (the `curate` tool) works.
//
// A vault that isn't writable is not fatal — every read tool still works, and the
// `curate` tool reports its own failure — but it is worth saying out loud.
let vaultStatus = MullDirectory.setup()
if vaultStatus != .ready {
    FileHandle.standardError.write(
        Data("[MullMCP] \(MullDirectory.issueDescription ?? "~/mull is not ready") Writes will fail; reads are unaffected.\n".utf8))
}

// Initialize database (read-only access to mull's existing DB)
let database = DatabaseService()
if let trouble = database.fallbackReason {
    FileHandle.standardError.write(Data("[MullMCP] \(trouble)\n".utf8))
}
let server = MCPServer(database: database)

// Log to stderr (stdout is reserved for JSON-RPC)
FileHandle.standardError.write("[MullMCP] Server started\n".data(using: .utf8)!)

// Block forever, handling JSON-RPC messages
server.run()
