import Foundation

/// The "deliberate" tier: a periodic LLM pass that organizes each active
/// project into its own briefing file at `~/mull/projects/<slug>.md`.
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
    /// The id every per-project briefing block carries. Shared rather than private
    /// because `sweepFossilProjectFiles` withdraws these blocks when the project
    /// turns out not to be one, and a second copy of the literal is a second thing
    /// to update.
    static let blockID = "deliberation"

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
        // Before writing anything: withdraw what should not have been written. This
        // does not need the LLM and must not wait for one — the files it retracts are
        // exactly the ones an LLM that is now switched off left behind.
        sweepFossilProjectFiles()

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

    /// Withdraw per-project briefings whose subject is not a project.
    ///
    /// `projects/*.md` is written here, and writing needs an LLM
    /// provider. When one is switched off — or when the extraction rule that
    /// nominated a name is later fixed — the files it already wrote stay. The
    /// shipped vault kept `claude.md` ("Claude" is an app), `project.md` (「元の
    /// プロファイル」 is Firefox's default profile, in the title of every Firefox
    /// window) and `review-vs-code-markdown.md` (a sentence) as first-class
    /// projects for two months. `ProjectNames` rejects all three today; nothing
    /// re-examined the files it had already been wrong about.
    ///
    /// Both of `ProjectNames`' gates are applied, because they catch different
    /// things: shape (`isPlausible`) rejects the app name and the sentence, and
    /// evidence (`chrome`) is the only thing that can recognise a browser
    /// profile's name in an arbitrary locale.
    ///
    /// Only mull's own block is withdrawn, via `Curator.retract`. A briefing the
    /// user has edited is theirs, and its file is kept even when mull would no
    /// longer have written it.
    ///
    /// This lived in `FolderFiller` until 2026-08-09, next to the code that
    /// summarised these files into `03_projects/index.md`. That index is gone
    /// (DIRECTION §6.1) and this is not: withdrawing a briefing mull should not have
    /// written has nothing to do with folder scaffolding, and belongs beside the
    /// engine that wrote it. It runs on the same nightly pass as the writing does.
    func sweepFossilProjectFiles() {
        let since = Date().addingTimeInterval(-14 * 86_400)
        let chrome = ProjectNames.chrome(in: database.fetchEvents(from: since, to: Date())
            .compactMap { event in
                guard event.eventType == .screenText,
                      let app = event.appName, let title = event.textContent else { return nil }
                return (app: app, title: title)
            })

        for path in MullDirectory.markdownFiles(in: VaultLayout.projects) {
            guard let raw = MullDirectory.read(path) else { continue }
            let (header, _) = ContextBlockFile.parse(raw)
            guard let titleLine = header.components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("# ") }) else { continue }
            let name = String(titleLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            guard !ProjectNames.isPlausible(name) || chrome.contains(name) else { continue }

            let retraction = Curator.retract(relativePath: path, idPrefixes: [Self.blockID])
            guard retraction.written, retraction.retained.isEmpty else { continue }

            // Nothing of mull's is left, and nothing of the user's was there: the
            // file is now a bare `# Claude` and a heading is not a briefing.
            // Called in a closure, not passed as `map(ContextBlockFile.parse)`:
            // a function *reference* drops the tuple's element labels, and the
            // result reads as `(String, [ContextBlock])` with no `.header`.
            let remaining = MullDirectory.read(path).map { ContextBlockFile.parse($0) }
                ?? (header: "", blocks: [])
            if remaining.blocks.isEmpty, remaining.header == titleLine {
                MullDirectory.delete(path)
            }
        }
    }

    /// Upsert the agent block into `~/mull/projects/<slug>.md` through the Curator
    /// — the one sanctioned writer for curated files. User prose at the top of the
    /// file is preserved as the header, and if the user edits the deliberation
    /// block directly, the Curator's hash check promotes it to `.human` and stops
    /// overwriting it. Returns the relative path on success.
    private func writeProjectFile(name: String, body: String) -> String? {
        let path = "\(VaultLayout.projects)/\(slug(name)).md"
        let existing = MullDirectory.read(path) ?? ""
        let (existingHeader, _) = ContextBlockFile.parse(existing)
        let header = existingHeader.isEmpty ? "# \(name)" : existingHeader
        let block = ContextBlock(id: Self.blockID, source: .agent, content: body, agentHash: nil)
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
