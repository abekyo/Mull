import Foundation

/// Rule-based vault fill — the LLM-free floor that keeps the numbered folders
/// from sitting on empty templates. me.md / now.md / full.md were already
/// generated rule-based; this extends the same no-LLM tier to the folder
/// indexes, so the vault is real material the moment mull runs with the LLM off
/// (the default), not a scaffold of "(awaiting synthesis)".
///
/// Coexistence with the cloud tier:
///   - 00/01/03 have no LLM writer for their index sections (SynthesisEngine
///     excludes them; DeliberationEngine writes separate per-project files), so
///     these always fill rule-based.
///   - 06_knowledge IS synthesized by the LLM when one is configured, so the
///     rule-based fill yields to it and only runs when the LLM is off.
///
/// Everything writes through the Curator: a section the user edited by hand is
/// detected and preserved; mull only manages its own `section:` blocks.
enum FolderFiller {

    static func fill(database: DatabaseService, analytics: AnalyticsEngine) {
        guard MullDirectory.status == .ready else { return }
        fillIdentity(database: database, analytics: analytics)   // 00
        fillNow(database: database)                              // 01
        fillProjects(database: database)                         // 03
        if llmOff { fillKnowledge(database: database) }          // 06
    }

    private static var llmOff: Bool {
        (UserDefaults.standard.string(forKey: "llmProvider") ?? "off") == "off"
    }

    // MARK: - 00 identity

    private static func fillIdentity(database: DatabaseService, analytics: AnalyticsEngine) {
        let facts = FactExtractor(analytics: analytics, database: database).extractFacts(days: 14)
        func bullets(_ category: FactCategory) -> String? {
            let items = facts.filter { $0.category == category }
            return items.isEmpty ? nil : items.map { "- \(MarkdownDoc.inline($0.text))" }.joined(separator: "\n")
        }
        write(folder: "00", sections: [
            "Summary": bullets(.identity),
            "Skills": bullets(.skills),
            "Preferences": bullets(.patterns),
            "Values": nil,
        ])
    }

    // MARK: - 01 now

    private static func fillNow(database: DatabaseService) {
        let focus = CurrentState.current(database: database).summary()
        let week = TimeBlockEngine(database: database).weekComparison()
        let weekLine = UserLanguage.isJapanese
            ? "今週の記録 \(week.thisWeekHours)・2時間以上の集中ブロック \(week.thisWeekDeepBlocks) 件。"
            : "\(week.thisWeekHours) tracked this week · \(week.thisWeekDeepBlocks) deep-work block(s) of 2h+."
        write(folder: "01", sections: [
            "Current focus": focus.isEmpty ? nil : focus,
            "This week": weekLine,
            "Upcoming": nil,
        ])
    }

    // MARK: - 03 projects

    private static func fillProjects(database: DatabaseService) {
        sweepFossilProjectFiles(database: database)
        let snaps = TimeBlockEngine(database: database).projectSnapshots(days: 14)
        func render(_ list: [ProjectSnapshot]) -> String? {
            guard !list.isEmpty else { return nil }
            return list.prefix(8).map { p in
                var line = "- **\(p.name)** — \(p.totalDurationFormatted), \(p.primaryApp), \(p.lastActiveFormatted)"
                if let file = p.lastFile {
                    line += UserLanguage.isJapanese ? "\n  - 再開はここから: `\(file)`" : "\n  - resume: `\(file)`"
                }
                return line
            }.joined(separator: "\n")
        }
        write(folder: "03", sections: [
            "Active projects": render(snaps.filter { $0.daysSinceActive < 3 }),
            "Recently touched": render(snaps.filter { $0.daysSinceActive >= 3 }),
        ])
    }

    /// Withdraw per-project briefings whose subject is not a project.
    ///
    /// `03_projects/*.md` is written by `DeliberationEngine`, which needs an LLM
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
    private static func sweepFossilProjectFiles(database: DatabaseService) {
        let since = Date().addingTimeInterval(-14 * 86_400)
        let chrome = ProjectNames.chrome(in: database.fetchEvents(from: since, to: Date())
            .compactMap { event in
                guard event.eventType == .screenText,
                      let app = event.appName, let title = event.textContent else { return nil }
                return (app: app, title: title)
            })

        for path in MullDirectory.markdownFiles(in: "03_projects") {
            guard let raw = MullDirectory.read(path) else { continue }
            let (header, _) = ContextBlockFile.parse(raw)
            guard let titleLine = header.components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("# ") }) else { continue }
            let name = String(titleLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            guard !ProjectNames.isPlausible(name) || chrome.contains(name) else { continue }

            let retraction = Curator.retract(relativePath: path, idPrefixes: [DeliberationEngine.blockID])
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

    // MARK: - 06 knowledge (only when no LLM owns this folder)

    private static func fillKnowledge(database: DatabaseService) {
        let since = Date().addingTimeInterval(-7 * 86_400)
        let events = database.fetchEvents(from: since, to: Date())
        let entries = KnowledgeExtractor(database: database).extractRuleBased(events: events)
        let decisions: String? = entries.isEmpty ? nil : entries.prefix(12).map { e -> String in
            var s = "- **\(MarkdownDoc.inline(e.topic, limit: 80))** [\(e.project)] — \(MarkdownDoc.inline(e.decision, limit: 240))"
            if let r = e.reasoning, !r.isEmpty { s += " · \(MarkdownDoc.inline(r, limit: 200))" }
            return s
        }.joined(separator: "\n")
        write(folder: "06", sections: [
            "Decisions": decisions,
            "References": nil,
            "Learnings": nil,
        ])
    }

    // MARK: - Helpers

    /// Curate one folder's index.md from a section→body map.
    ///
    /// A nil body means the section is not written at all (MarkdownDoc rule 5),
    /// and because this pass manages the `section:` prefix, a section that empties
    /// out is pruned rather than reverting to a placeholder. Each nil used to be
    /// the folder's `emptyHint` instead — which is how `06_knowledge` came to be a
    /// header followed by `## Decisions` / `## References` / `## Learnings`, all
    /// three holding the same sentence telling the user to turn on AI. That
    /// sentence is in the index's front matter now, said once for the folder.
    ///
    /// Human edits survive either way — the Curator promotes an edited block to
    /// `.human` before any of this runs.
    private static func write(folder number: String, sections bodies: [String: String?]) {
        guard let folder = FolderOntology.folder(number) else { return }
        let blocks = folder.sections.compactMap { section -> ContextBlock? in
            guard let body = bodies[section] ?? nil,
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return ContextBlock(
                id: "section:\(ContextBlockFile.slug(section))",
                source: .agent,
                content: "## \(FolderOntology.sectionHeading(section))\n\n\(body)",
                agentHash: nil)
        }
        _ = Curator.curate(relativePath: folder.indexPath,
                           header: FolderOntology.indexHeader(for: folder),
                           pinnedContent: nil, agentBlocks: blocks,
                           managedPrefixes: ["section:"])
    }
}
