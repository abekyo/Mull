import Foundation

/// The Curator — incremental, provenance-aware writer for durable context files
/// (me.md, MEMORY.md). It NEVER rewrites a file wholesale. Instead it:
///   1. preserves blocks the user pinned (me.pinned.md) or edited directly,
///   2. updates the agent's own blocks in place,
///   3. appends genuinely new facts.
///
/// This is the ACE "Curator" pattern (PRODUCT.md §"borrow ACE's Curator"): the only
/// sanctioned way to write a curated file. Both the 60s rule-based pass
/// (LiveContextGenerator) and the nightly LLM pass (MullEngine) go through here, so
/// neither can clobber the other — or the human.
enum Curator {

    // MARK: - Pinned facts (me.pinned.md)

    /// User-owned pinned facts file. mull creates it once, then only ever reads it.
    static let pinnedFileName = "me.pinned.md"

    private static let pinnedTemplate = """
    # Pinned facts — you own this file. mull NEVER overwrites it.
    #
    # Every line below that does NOT start with '#' is treated as authoritative and
    # placed at the top of me.md, above mull's own auto-detected guesses. Use it to
    # lock facts auto-detection gets wrong or can't know. Example:
    #
    # - Founder running several businesses; FX trading is the current priority.
    # - Primary working language: Japanese.
    #
    # Delete these comment lines and add your own. An empty file disables the layer.

    """

    /// Read the user's pinned facts (comment + blank lines stripped). Scaffolds the
    /// file once if missing; never overwrites an existing one. Empty if none.
    static func pinnedFacts() -> String {
        if !MullDirectory.exists(pinnedFileName) {
            MullDirectory.write(pinnedTemplate, to: pinnedFileName)
        }
        guard let raw = MullDirectory.read(pinnedFileName) else { return "" }
        return raw
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Curate (chokepoint)

    /// Merge agent blocks into `relativePath`, preserving pinned/human content, and
    /// write the result. The ONLY sanctioned writer for curated files.
    @discardableResult
    static func curate(relativePath: String, header: String, pinnedContent: String?, agentBlocks: [ContextBlock]) -> Bool {
        let existing = MullDirectory.read(relativePath) ?? ""
        let merged = merge(existing: existing, header: header, pinnedContent: pinnedContent, agentBlocks: agentBlocks)
        return MullDirectory.write(merged, to: relativePath)
    }

    /// Pure merge (no I/O) so it can be unit-tested.
    static func merge(existing: String, header: String, pinnedContent: String?, agentBlocks: [ContextBlock]) -> String {
        let pinnedID = "pinned-facts"
        var (_, existingBlocks) = ContextBlockFile.parse(existing)

        // 1. Detect human edits: an agent block whose content no longer matches the
        //    hash mull last wrote → the human touched it → promote to .human (protected).
        for i in existingBlocks.indices where existingBlocks[i].source == .agent {
            if let stored = existingBlocks[i].agentHash,
               stored != ContextBlock.hash(existingBlocks[i].content) {
                existingBlocks[i].source = .human
                existingBlocks[i].agentHash = nil
            }
        }

        // 2. The pinned block is sourced from me.pinned.md, not from agent output.
        //    Drop the old one and re-seat it from the file (its authority).
        existingBlocks.removeAll { $0.id == pinnedID }

        var result: [ContextBlock] = []
        if let pinned = pinnedContent, !pinned.isEmpty {
            result.append(ContextBlock(id: pinnedID, source: .pinned, content: pinned, agentHash: nil))
        }
        result.append(contentsOf: existingBlocks)

        // 3. Apply agent candidates: update the agent's own blocks in place, append new
        //    ones, never touch human/pinned blocks.
        var indexByID: [String: Int] = [:]
        for (i, b) in result.enumerated() { indexByID[b.id] = i }

        for var cand in agentBlocks {
            cand.source = .agent
            cand.agentHash = ContextBlock.hash(cand.content)
            if let idx = indexByID[cand.id] {
                if result[idx].source == .agent {
                    result[idx].content = cand.content
                    result[idx].agentHash = cand.agentHash
                }
                // human / pinned → leave untouched
            } else {
                result.append(cand)
                indexByID[cand.id] = result.count - 1
            }
        }

        return ContextBlockFile.serialize(header: header, blocks: result)
    }

    // MARK: - Agent block builders (shared id conventions)

    /// Stable id for a memory-derived block. Both the 60s and nightly passes use this,
    /// so they update the same block instead of duplicating it.
    static func memoryBlockID(name: String, description: String) -> String {
        let key = name.isEmpty ? description : name
        return "mem:" + ContextBlockFile.slug(key)
    }

    static func feedbackBlockID(name: String, description: String) -> String {
        let key = name.isEmpty ? description : name
        return "pref:" + ContextBlockFile.slug(key)
    }

    /// Stable id for a FactExtractor fact. Key-only for attributes whose value changes
    /// (tech stack, language ratios → updates replace), full-line for container facts
    /// whose value is the identity ("Working on: X" → each project distinct).
    static func factBlockID(category: String, text: String) -> String {
        var t = text
        if t.hasPrefix("- ") { t = String(t.dropFirst(2)) }

        // First colon at paren-depth 0.
        var depth = 0
        var colon: String.Index?
        var i = t.startIndex
        while i < t.endIndex {
            switch t[i] {
            case "(": depth += 1
            case ")": depth = max(0, depth - 1)
            case ":" where depth == 0: colon = i
            default: break
            }
            if colon != nil { break }
            i = t.index(after: i)
        }

        let keyPart: String
        if let c = colon {
            let key = String(t[..<c]).trimmingCharacters(in: .whitespaces)
            let containerKeys: Set<String> = ["working on", "project", "projects"]
            keyPart = containerKeys.contains(key.lowercased()) ? t : key
        } else {
            // No colon: strip parentheticals so e.g. "Software developer (tools: …)" is stable.
            keyPart = t.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        }
        return "fact:\(category):\(ContextBlockFile.slug(keyPart))"
    }
}
