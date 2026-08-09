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
/// This is the foundation for the ACE "Curator" pattern (see DIRECTION.md 付録A): append /
/// diff-curate, tag each block with provenance, never clobber human-touched content.
struct ContextBlock {
    var id: String
    var source: BlockSource
    var content: String
    /// Hash of `content` as the agent last wrote it. If the on-disk content no longer
    /// matches this, a human edited the block → it gets promoted to `.human`.
    var agentHash: String?
    /// When mull last wrote this block. Nil for human/pinned blocks (mull did not
    /// write them, so it has no claim about their age) and for agent blocks
    /// written before the stamp existed.
    ///
    /// It exists because a file can hold blocks on very different clocks: the 60s
    /// pass rewrites its own every minute, while the `nightly:` blocks are only
    /// touched when the nightly consolidation runs — and that pass needs an LLM
    /// provider, so with the LLM off it may never run again. Without an age, a
    /// block that stopped being maintained is indistinguishable from a current
    /// one, and the shipped vault showed the consequence: now.md and full.md were
    /// still presenting a two-month-old consolidation, in a markdown style three
    /// releases out of date, under the heading "From last night's consolidation".
    var writtenAt: Date?

    /// Deterministic content hash (FNV-1a, stable across runs — unlike Swift's Hasher).
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Content as it will exist after a serialize→parse round trip.
    ///
    /// `parse` trims each block's outer whitespace; `serialize` used to write
    /// whatever the caller handed it. So a block whose content ended in a space or
    /// a newline — routine for text assembled from a clipboard entry — came back
    /// different from what was hashed, `merge` read that difference as a human
    /// edit, and promoted mull's own block to `.human`. Since mull never rewrites
    /// a human block, it froze permanently: the OneTab dump in the shipped
    /// proactive.md was mull's own output, held in place by its own protection.
    ///
    /// Normalising before hashing makes the round trip a fixed point, so the only
    /// thing that can trip the human-edit check is an actual human edit.
    static func normalized(_ content: String) -> String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
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
        var curWrittenAt: Date?
        var buffer: [String] = []

        func flush() {
            guard let id = curID else { return }
            let content = ContextBlock.normalized(buffer.joined(separator: "\n"))
            blocks.append(ContextBlock(id: id, source: curSource, content: content,
                                       agentHash: curHash, writtenAt: curWrittenAt))
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
                curWrittenAt = attrs["ts"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
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

    /// Blocks are separated by a BLANK line, not just a newline.
    ///
    /// With the markers present the file reads fine either way — a marker line is
    /// its own separator. But every surface that shows this text to a human or an
    /// AI runs `stripMarkers` first (the daily snapshot, full.md's embed, the
    /// Files tab, the AI clipboard, the MCP context tools), and that deletes the
    /// only thing keeping the blocks apart. The last bullet of one block then sat
    /// directly against the next block's `##` heading, which is how the shipped
    /// `daily/2026-08-09.md` ran "Key references" straight into "From last night's
    /// consolidation". The blank line is what survives the strip.
    ///
    /// `parse` trims each block's outer whitespace, so the extra newline does not
    /// come back as content on the round trip.
    static func serialize(header: String, blocks: [ContextBlock]) -> String {
        var chunks: [String] = []
        if !header.isEmpty { chunks.append(header) }
        for b in blocks {
            // Drop vacuous agent blocks, but KEEP an emptied human/pinned block as
            // a tombstone marker. If the user clears a block's body, that empty
            // marker records the deletion so the next curate won't treat the fact
            // as new and re-append it (which silently undid the user's deletion).
            if b.content.isEmpty && b.source == .agent { continue }
            var marker = "\(markerPrefix) id=\(b.id) src=\(b.source.rawValue)"
            if b.source == .agent, let h = b.agentHash { marker += " hash=\(h)" }
            if b.source == .agent, let ts = b.writtenAt {
                marker += " ts=\(Int(ts.timeIntervalSince1970))"
            }
            marker += " -->"
            chunks.append(b.content.isEmpty ? marker : marker + "\n" + b.content)
        }
        return chunks.joined(separator: "\n\n")
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
