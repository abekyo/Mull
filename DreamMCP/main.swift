/// DreamMCP — standalone MCP server binary.
///
/// Launched by Claude Code / Cursor as a subprocess.
/// Reads JSON-RPC from stdin, writes responses to stdout.
///
/// Registration:
///   claude mcp add --transport stdio --scope user dream -- /path/to/DreamMCP
///
/// Or in ~/.claude.json:
///   { "mcpServers": { "dream": { "command": "/path/to/DreamMCP" } } }

import Foundation

// Initialize database (read-only access to Dream's existing DB)
let database = DatabaseService()
let server = MCPServer(database: database)

// Log to stderr (stdout is reserved for JSON-RPC)
FileHandle.standardError.write("[DreamMCP] Server started\n".data(using: .utf8)!)

// Block forever, handling JSON-RPC messages
server.run()
