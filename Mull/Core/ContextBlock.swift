import Foundation

/// Provenance of a context block.
/// - agent:  written by mull (rule-based or LLM). May be updated/overwritten by mull.
/// - human:  the user edited this block directly. mull must NEVER overwrite it.
/// - pinned: authored by the user in me.pinned.md. Authoritative; refreshed only
///           from that file, never from agent output.
enum BlockSource: String {
    case agent
    case human
    case pinned
}

/// One unit of curated context. Files are a sequence of these, so mull can update,
/// append, or protect individual blocks instead of rewriting the whole file.
/// This is the foundation for the ACE "Curator" pattern (see PRODUCT.md): append /
/// diff-curate, tag each block with provenance, never clobber human-touched content.
struct ContextBlock {
    var id: String
    var source: BlockSource
    var content: String
    /// Hash of `content` as the agent last wrote it. If the on-disk content no longer
    /// matches this, a human edited the block → it gets promoted to `.human`.
    var agentHash: String?

    /// Deterministic content hash (FNV-1a, stable across runs — unlike Swift's Hasher).
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

/// Serializes/parses blocks to marker-delimited Markdown. Markers are HTML comments,
/// so the file stays human-readable and editable, and provenance survives round-trips:
///
///     <!-- mull:block id=fact:skills:tech-stack src=agent hash=1a2b3c -->
///     - Tech stack: Swift, Vercel
///     <!-- mull:block id=priority src=human -->
///     - FX is the current priority; the app business is frozen.
enum ContextBlockFile {
    static let markerPrefix = "<!-- mull:block"

    /// Parse marker-delimited markdown into a leading header (text before the first
    /// marker) and the ordered blocks.
    static func parse(_ text: String) -> (header: String, blocks: [ContextBlock]) {
        let lines = text.components(separatedBy: "\n")
        var headerLines: [String] = []
        var blocks: [ContextBlock] = []
        var sawBlock = false

        var curID: String?
        var curSource: BlockSource = .agent
        var curHash: String?
        var buffer: [String] = []

        func flush() {
            guard let id = curID else { return }
            let content = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            blocks.append(ContextBlock(id: id, source: curSource, content: content, agentHash: curHash))
            buffer = []
        }

        for line in lines {
            if line.hasPrefix(markerPrefix) {
                sawBlock = true
                flush()
                let attrs = parseMarker(line)
                curID = attrs["id"] ?? "unknown"
                curSource = BlockSource(rawValue: attrs["src"] ?? "agent") ?? .agent
                curHash = attrs["hash"]
            } else if !sawBlock {
                headerLines.append(line)
            } else {
                buffer.append(line)
            }
        }
        flush()

        let header = headerLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (header, blocks)
    }

    /// Parse `key=value` attributes from a marker line. Values may not contain spaces.
    private static func parseMarker(_ line: String) -> [String: String] {
        let inner = line
            .replacingOccurrences(of: markerPrefix, with: "")
            .replacingOccurrences(of: "-->", with: "")
        var dict: [String: String] = [:]
        for token in inner.split(separator: " ") {
            let kv = token.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
        }
        return dict
    }

    /// Remove provenance marker lines, leaving only readable content. Use when a
    /// curated file (me.md / MEMORY.md) is embedded into a derived or exported
    /// artifact (full.md, daily snapshot, AI clipboard) — the markers are internal
    /// metadata and must not leak into what the user or an AI reads.
    static func stripMarkers(_ text: String) -> String {
        text
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(markerPrefix) }
            .joined(separator: "\n")
    }

    static func serialize(header: String, blocks: [ContextBlock]) -> String {
        var out: [String] = []
        if !header.isEmpty {
            out.append(header)
            out.append("")
        }
        for b in blocks {
            // Drop vacuous agent blocks, but KEEP an emptied human/pinned block as
            // a tombstone marker. If the user clears a block's body, that empty
            // marker records the deletion so the next curate won't treat the fact
            // as new and re-append it (which silently undid the user's deletion).
            if b.content.isEmpty && b.source == .agent { continue }
            var marker = "\(markerPrefix) id=\(b.id) src=\(b.source.rawValue)"
            if b.source == .agent, let h = b.agentHash { marker += " hash=\(h)" }
            marker += " -->"
            out.append(marker)
            if !b.content.isEmpty { out.append(b.content) }
        }
        return out.joined(separator: "\n")
    }

    /// Slugify into a marker-safe id fragment (no spaces; letters/digits kept, incl. CJK).
    static func slug(_ s: String, max: Int = 48) -> String {
        let mapped = s.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        var out = String(mapped)
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // Punctuation-only input slugifies to "" — distinct such inputs would all
        // collapse to the same empty fragment and collide (one block silently
        // overwriting another). Fall back to a stable per-input hash instead.
        if out.isEmpty { return "x" + String(ContextBlock.hash(s).prefix(8)) }
        return String(out.prefix(max))
    }
}
