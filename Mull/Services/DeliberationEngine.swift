import Foundation

/// The "deliberate" tier: a periodic LLM pass that organizes each active
/// project into its own briefing file at `~/mull/03_projects/<slug>.md`.
///
/// This is the autonomous-agent layer from Direction v2. The always-on 60s
/// rule-based tier keeps me.md/now.md/full.md fresh for free; this slower,
/// cloud-backed pass mulls over the accumulated record per project and writes a
/// human- and AI-readable summary an assistant can load on demand.
///
/// Two invariants:
///  1. **Edits survive.** Output is written through the `Curator`, so the agent
///     only owns its block — anything the user wrote in the file stays, and a
///     hand-edited block is detected and protected.
///  2. **Observation, not interpretation.** The system prompt forbids judgment
///     ("you're avoiding X"). It reports what happened and where to resume,
///     grounded in the log — the epistemics from DIRECTION.md 付録A.
final class DeliberationEngine {

    private let database: DatabaseService
    private let llm: LLMClient

    /// The agent-owned block id inside each project file.
    private let blockID = "deliberation"

    init(database: DatabaseService, llm: LLMClient = LLMClient()) {
        self.database = database
        self.llm = llm
    }

    struct Result {
        let project: String
        let relativePath: String
    }

    /// Deliberate over each recently-active project and upsert its file.
    /// Failures on one project never abort the others (best-effort, like the
    /// nightly summary's LLM step).
    @discardableResult
    func deliberateActiveProjects(maxProjects: Int = 5, activeWithinDays: Int = 14) async -> [Result] {
        let engine = TimeBlockEngine(database: database)
        let projects = engine.projectSnapshots(days: activeWithinDays)
            .sorted { $0.lastActiveDate > $1.lastActiveDate }
            .prefix(maxProjects)

        var results: [Result] = []
        for project in projects {
            guard let body = await deliberate(on: project) else { continue }
            if let path = writeProjectFile(name: project.name, body: body) {
                results.append(Result(project: project.name, relativePath: path))
            }
        }
        return results
    }

    // MARK: - Per-project deliberation

    /// Returns the regenerated briefing body, or nil if the LLM call failed.
    private func deliberate(on project: ProjectSnapshot) async -> String? {
        do {
            return try await llm.complete(
                system: systemPrompt,
                prompt: prompt(for: project),
                options: .init(maxTokens: 1024)
            )
        } catch {
            print("[mull] Deliberation failed for \(project.name): \(error.localizedDescription)")
            return nil
        }
    }

    private let systemPrompt = """
    You are mull's deliberation pass. You turn one person's activity log for a \
    single project into a short briefing that an AI assistant will read later to \
    pick up context instantly.

    Hard rules:
    - Report observations grounded in the data. Never psychoanalyze or judge. \
    Phrases like "you are avoiding this" or "you should" are forbidden — state \
    what happened, not what it means about the person.
    - Lead with what the project is and the single most useful resume point \
    ("last working on X in file Y").
    - Then: what's in progress, recent files/areas touched, any decisions or \
    errors visible in the data.
    - Be concise. Plain markdown. No preamble, no "Here is", no closing remarks.
    - If the data is thin, say so briefly rather than inventing detail.
    """

    private func prompt(for p: ProjectSnapshot) -> String {
        var lines: [String] = []
        lines.append("Project: \(p.name)")
        lines.append("Primary app: \(p.primaryApp)")
        lines.append("Total tracked time: \(p.totalDurationFormatted)")
        lines.append("Last active: \(p.lastActiveFormatted) (\(p.daysSinceActive) days ago)")
        if let file = p.lastFile { lines.append("Last file/area: \(file)") }
        // Masking alone isn't enough for a prompt that leaves the device: Redactor only
        // rewrites credential shapes, so an email address or card number in the clipboard
        // would still be shipped verbatim. If SensitiveText flags it, drop the line —
        // a briefing is better off without one clipboard than one leak.
        if let clip = p.lastClipboard, !clip.isEmpty, !SensitiveText.isSensitive(clip) {
            lines.append("Last clipboard near this project: \(clip.prefix(200))")
        }

        if !p.sessions.isEmpty {
            lines.append("")
            lines.append("Recent sessions (most recent first):")
            for s in p.sessions.prefix(10) {
                lines.append("- \(s.dateFormatted): \(s.durationFormatted) — \(s.mainLabel) [\(s.app)]")
            }
        }

        lines.append("")
        lines.append("Write the briefing for this project now.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Writing (provenance-safe)

    /// Upsert the agent block into `~/mull/03_projects/<slug>.md` through the Curator
    /// — the one sanctioned writer for curated files. User prose at the top of the
    /// file is preserved as the header, and if the user edits the deliberation
    /// block directly, the Curator's hash check promotes it to `.human` and stops
    /// overwriting it. Returns the relative path on success.
    private func writeProjectFile(name: String, body: String) -> String? {
        let path = "03_projects/\(slug(name)).md"
        let existing = MullDirectory.read(path) ?? ""
        let (existingHeader, _) = ContextBlockFile.parse(existing)
        let header = existingHeader.isEmpty ? "# \(name)" : existingHeader
        let block = ContextBlock(id: blockID, source: .agent, content: body, agentHash: nil)
        return Curator.curate(relativePath: path, header: header,
                              pinnedContent: nil, agentBlocks: [block]) ? path : nil
    }

    /// Filesystem-safe slug for a project name.
    private func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let mapped = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "project" : collapsed
    }
}
