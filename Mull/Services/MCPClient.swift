import Foundation

/// A minimal MCP *client* over stdio. mull already exposes an MCP *server*
/// (MCPServer.swift); this is the mirror image — it spawns a configured MCP
/// server process and pulls data from it, so mull can ingest from Gmail /
/// Calendar / GitHub / etc. servers (Direction v3, Phase B).
///
/// Transport: newline-delimited JSON-RPC (the MCP stdio convention, same framing
/// mull's own server uses). Every blocking read is bounded by a timeout so a
/// stuck server can never hang ingestion.
final class MCPClient {

    struct ServerConfig: Codable, Equatable {
        var command: String
        var args: [String]
        var env: [String: String]

        init(command: String, args: [String] = [], env: [String: String] = [:]) {
            self.command = command
            self.args = args
            self.env = env
        }
    }

    enum MCPClientError: LocalizedError {
        case spawnFailed(String)
        case timeout(String)
        case transport(String)
        case rpc(String)

        var errorDescription: String? {
            switch self {
            case .spawnFailed(let s): String(localized: "MCP server failed to start: \(s)")
            case .timeout(let s): String(localized: "MCP server timed out: \(s)")
            case .transport(let s): String(localized: "MCP transport error: \(s)")
            case .rpc(let s): String(localized: "MCP error: \(s)")
            }
        }
    }

    private let config: ServerConfig
    private let timeout: TimeInterval
    private var process: Process?
    private var stdin: FileHandle?
    private var outPipe: Pipe?
    private var errPipe: Pipe?
    private var reader: LineReader?
    private var nextID = 0

    init(config: ServerConfig, timeout: TimeInterval = 30) {
        self.config = config
        self.timeout = timeout
    }

    // MARK: - Pure helpers (unit-tested)

    /// Encode a JSON-RPC request as a single newline-terminated line.
    static func encodeRequest(id: Int, method: String, params: [String: Any]) -> Data {
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { msg["params"] = params }
        var data = (try? JSONSerialization.data(withJSONObject: msg)) ?? Data()
        data.append(0x0A) // newline
        return data
    }

    /// Does a JSON-RPC response id (Int, NSNumber, or String) equal the int id we
    /// sent? Tolerant of how different servers echo ids back.
    static func idMatches(_ responseID: Any?, _ sent: Int) -> Bool {
        if let i = responseID as? Int { return i == sent }
        if let n = responseID as? NSNumber { return n.intValue == sent }
        if let s = responseID as? String { return s == String(sent) }
        return false
    }

    /// Extract the concatenated text from an MCP `tools/call` result
    /// (`{ content: [{ type: "text", text: "..." }] }`).
    static func parseToolText(from result: [String: Any]) -> String {
        guard let content = result["content"] as? [[String: Any]] else { return "" }
        return content
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    // MARK: - Lifecycle

    /// Spawn the server and complete the MCP initialize handshake.
    /// Synchronous (blocking I/O) — call it off the main thread.
    func connect() throws {
        let proc = Process()
        let (exe, args) = resolveCommand()
        proc.executableURL = exe
        proc.arguments = args
        if !config.env.isEmpty {
            var env = ProcessInfo.processInfo.environment
            config.env.forEach { env[$0] = $1 }
            proc.environment = env
        }

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe // swallow server logs

        do {
            try proc.run()
        } catch {
            throw MCPClientError.spawnFailed(error.localizedDescription)
        }

        self.process = proc
        self.stdin = inPipe.fileHandleForWriting
        self.outPipe = outPipe
        self.errPipe = errPipe
        self.reader = LineReader(handle: outPipe.fileHandleForReading)

        // initialize → result, then notifications/initialized
        _ = try request(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "mull", "version": "1.0.0"],
        ])
        notify(method: "notifications/initialized", params: [:])
    }

    func listTools() throws -> [String] {
        let result = try request(method: "tools/list", params: [:])
        let tools = result["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { $0["name"] as? String }
    }

    /// Call a tool and return its text content.
    func callTool(_ name: String, arguments: [String: Any]) throws -> String {
        let result = try request(method: "tools/call", params: [
            "name": name,
            "arguments": arguments,
        ])
        return MCPClient.parseToolText(from: result)
    }

    func shutdown() {
        // Order matters: close stdin + terminate so the child exits, which EOFs
        // our read end and unblocks the LineReader's detached read; waitUntilExit
        // reaps the zombie; then we can safely close the (now idle) pipe handles.
        // Without this, every pull leaked file descriptors, a zombie process, and
        // a global-queue thread blocked in availableData.
        try? stdin?.close()
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? outPipe?.fileHandleForReading.close()
        try? errPipe?.fileHandleForReading.close()
        stdin = nil
        reader = nil
        outPipe = nil
        errPipe = nil
        process = nil
    }

    // MARK: - RPC

    private func request(method: String, params: [String: Any]) throws -> [String: Any] {
        guard let stdin, let reader else { throw MCPClientError.transport("not connected") }
        nextID += 1
        let id = nextID
        do {
            try stdin.write(contentsOf: MCPClient.encodeRequest(id: id, method: method, params: params))
        } catch {
            throw MCPClientError.transport("write failed: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let line = reader.readLine(deadline: deadline) else {
                throw MCPClientError.timeout(method)
            }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue } // skip non-JSON / log noise

            // Match our request id; ignore notifications and other ids. JSON-RPC
            // allows string ids, so don't only match Int (a server echoing "1"
            // would otherwise never match → every call hangs to timeout).
            if MCPClient.idMatches(obj["id"], id) {
                if let err = obj["error"] as? [String: Any] {
                    throw MCPClientError.rpc(err["message"] as? String ?? "unknown")
                }
                return obj["result"] as? [String: Any] ?? [:]
            }
        }
        throw MCPClientError.timeout(method)
    }

    private func notify(method: String, params: [String: Any]) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !params.isEmpty { msg["params"] = params }
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        data.append(0x0A)
        try? stdin?.write(contentsOf: data)
    }

    /// Resolve the executable + full argument list. A bare command (no slash) is
    /// run through `/usr/bin/env` so PATH is honored (e.g. `npx`, `uvx`).
    private func resolveCommand() -> (URL, [String]) {
        if config.command.contains("/") {
            return (URL(fileURLWithPath: config.command), config.args)
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), [config.command] + config.args)
    }
}

/// Buffered newline reader over a FileHandle with a deadline, so reads never
/// block indefinitely.
final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) { self.handle = handle }

    /// Returns the next line (without newline), or nil on EOF/deadline.
    /// The blocking read happens off-thread and is bounded by the deadline, so a
    /// silent server cannot hang the caller indefinitely.
    func readLine(deadline: Date) -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }

            final class Box { var data = Data() }
            let box = Box()
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { [handle] in
                box.data = handle.availableData
                sem.signal()
            }
            if sem.wait(timeout: .now() + remaining) == .timedOut { return nil }
            if box.data.isEmpty { return nil } // EOF
            buffer.append(box.data)
        }
    }
}
