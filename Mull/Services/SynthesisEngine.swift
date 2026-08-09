import Foundation

/// The synthesis tier (Direction v3, Phase C): turn ingested `_raw` data into
/// organized category documents by filling each folder's `index.md` section
/// blocks. It generalizes DeliberationEngine (which synthesizes one project from
/// local capture) to "synthesize a whole category from all routed sources."
///
/// Like deliberation it is best-effort and cloud-tier: with the LLM off it
/// simply no-ops, and every write goes through the Curator so user edits and the
/// folder header survive. Folders owned by other writers are left alone:
///   00_identity / 01_now → LiveContextGenerator (me.md / now.md)
///   03_projects          → DeliberationEngine
///   09_inbox             → IngestionService (staging)
final class SynthesisEngine {

    private let llm: LLMClient

    /// Folder numbers another engine already owns — never synthesized here.
    private let excluded: Set<String> = ["00", "01", "03", "09"]

    init(llm: LLMClient = LLMClient()) {
        self.llm = llm
    }

    /// Synthesize every eligible folder that has routed raw input.
    /// Returns the paths actually written.
    @discardableResult
    func synthesizeAll(maxItemsPerFolder: Int = 40) async -> [String] {
        var written: [String] = []
        for folder in FolderOntology.folders where !excluded.contains(folder.number) {
            let items = gatherItems(for: folder, limit: maxItemsPerFolder)
            guard !items.isEmpty else { continue }
            if await synthesize(folder: folder, items: items) {
                written.append(folder.indexPath)
            }
        }
        return written
    }

    // MARK: - Input

    /// Raw items routed to this folder (excludes local "capture").
    private func gatherItems(for folder: FolderOntology.Folder, limit: Int) -> [IngestedItem] {
        let connectors = FolderOntology.rawConnectors.filter {
            $0 != "capture" && FolderOntology.primaryDestination(forConnector: $0)?.number == folder.number
        }
        let items = connectors
            .flatMap { RawStore.load(connector: $0) }
            .sorted { $0.timestamp > $1.timestamp }
        return Array(items.prefix(limit))
    }

    // MARK: - Synthesis

    private func synthesize(folder: FolderOntology.Folder, items: [IngestedItem]) async -> Bool {
        do {
            let json = try await llm.complete(
                system: systemPrompt,
                prompt: prompt(for: folder, items: items),
                options: .init(maxTokens: 1500)
            )
            let sections = SynthesisEngine.parseSections(json)
            guard !sections.isEmpty else { return false }
            writeFolder(folder, sections: sections)
            return true
        } catch {
            print("[mull] synthesis failed for \(folder.path): \(error.localizedDescription)")
            return false
        }
    }

    private let systemPrompt = """
    You organize a person's raw activity items into one category document.

    Output STRICT JSON: an object mapping section slug → markdown content for that \
    section. Use ONLY the section slugs given in the prompt. No text outside the \
    JSON object, no code fences.

    Rules:
    - Stay grounded in the provided items. Do not invent facts or judge the person.
    - Be concise. Omit a section (leave it out of the JSON) if the items say \
    nothing about it — don't pad.
    """

    private func prompt(for folder: FolderOntology.Folder, items: [IngestedItem]) -> String {
        var lines: [String] = []
        lines.append("Category: \(folder.title) — \(folder.purpose)")
        lines.append("")
        lines.append("Sections (use these exact slugs as JSON keys):")
        for section in folder.sections {
            lines.append("- \(ContextBlockFile.slug(section)) → \(section)")
        }
        lines.append("")
        lines.append("Items (most recent first):")
        for item in items {
            let when = item.timestamp == .distantPast ? "" : " [\(item.timestamp)]"
            let summary = item.summary.isEmpty ? "" : " — \(item.summary.prefix(160))"
            lines.append("- \(item.title)\(when)\(summary)")
        }
        lines.append("")
        lines.append("Return the JSON now.")
        return lines.joined(separator: "\n")
    }

    /// Parse the model's JSON object of section-slug → content. Tolerant of code
    /// fences and surrounding prose. (Unit-tested.)
    static func parseSections(_ text: String) -> [String: String] {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip ```json … ``` fences if present.
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
                 .replacingOccurrences(of: "```", with: "")
                 .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Take the outermost {...} so leading/trailing prose is ignored.
        guard let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}"), open < close else {
            return [:]
        }
        let jsonSlice = String(s[open...close])
        guard let data = jsonSlice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var out: [String: String] = [:]
        for (k, v) in obj {
            if let str = v as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out[k] = str
            }
        }
        return out
    }

    // MARK: - Write (provenance-safe)

    private func writeFolder(_ folder: FolderOntology.Folder, sections: [String: String]) {
        // slug → display title, so we can rebuild "## Title" headings.
        var titleBySlug: [String: String] = [:]
        for section in folder.sections { titleBySlug[ContextBlockFile.slug(section)] = section }

        let blocks: [ContextBlock] = sections.compactMap { slug, content in
            // Only fill slugs that belong to this folder's template.
            guard let title = titleBySlug[slug] else { return nil }
            return ContextBlock(id: "section:\(slug)", source: .agent,
                                content: "## \(FolderOntology.sectionHeading(title))\n\n\(content)", agentHash: nil)
        }
        guard !blocks.isEmpty else { return }

        // Preserve the existing header (and any user prose at the top).
        let existing = MullDirectory.read(folder.indexPath) ?? ""
        let (header, _) = ContextBlockFile.parse(existing)
        let hdr = header.isEmpty ? "# \(folder.number) \(folder.displayTitle)" : header

        _ = Curator.curate(relativePath: folder.indexPath, header: hdr,
                           pinnedContent: nil, agentBlocks: blocks)
    }
}
