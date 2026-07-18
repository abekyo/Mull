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
        let invite = hint("00")
        let facts = FactExtractor(analytics: analytics, database: database).extractFacts(days: 14)
        func bullets(_ category: FactCategory) -> String {
            let items = facts.filter { $0.category == category }
            return items.isEmpty ? invite : items.map { "- \($0.text)" }.joined(separator: "\n")
        }
        write(folder: "00", sections: [
            "Summary": bullets(.identity),
            "Skills": bullets(.skills),
            "Preferences": bullets(.patterns),
            "Values": invite,
        ])
    }

    // MARK: - 01 now

    private static func fillNow(database: DatabaseService) {
        let invite = hint("01")
        let focus = CurrentState.current(database: database).summary()
        let week = TimeBlockEngine(database: database).weekComparison()
        let weekLine = "\(week.thisWeekHours) tracked this week · \(week.thisWeekDeepBlocks) deep-work block(s) of 2h+."
        write(folder: "01", sections: [
            "Current focus": focus.isEmpty ? invite : focus,
            "This week": weekLine,
            "Upcoming": invite,
        ])
    }

    // MARK: - 03 projects

    private static func fillProjects(database: DatabaseService) {
        let invite = hint("03")
        let snaps = TimeBlockEngine(database: database).projectSnapshots(days: 14)
        func render(_ list: [ProjectSnapshot]) -> String {
            guard !list.isEmpty else { return invite }
            return list.prefix(8).map { p in
                var line = "- **\(p.name)** — \(p.totalDurationFormatted), \(p.primaryApp), \(p.lastActiveFormatted)"
                if let file = p.lastFile { line += "\n  - resume: `\(file)`" }
                return line
            }.joined(separator: "\n")
        }
        write(folder: "03", sections: [
            "Active projects": render(snaps.filter { $0.daysSinceActive < 3 }),
            "Recently touched": render(snaps.filter { $0.daysSinceActive >= 3 }),
        ])
    }

    // MARK: - 06 knowledge (only when no LLM owns this folder)

    private static func fillKnowledge(database: DatabaseService) {
        let invite = hint("06")
        let since = Date().addingTimeInterval(-7 * 86_400)
        let events = database.fetchEvents(from: since, to: Date())
        let entries = KnowledgeExtractor(database: database).extractRuleBased(events: events)
        let decisions = entries.isEmpty ? invite : entries.prefix(12).map { e -> String in
            var s = "- **\(e.topic)** [\(e.project)]: \(e.decision)"
            if let r = e.reasoning, !r.isEmpty { s += " — \(r)" }
            return s
        }.joined(separator: "\n")
        write(folder: "06", sections: [
            "Decisions": decisions,
            "References": invite,
            "Learnings": invite,
        ])
    }

    // MARK: - Helpers

    /// The folder's self-explaining empty hint (what to do when a section has no
    /// content) — shared with the seeded template so empty reads the same way.
    private static func hint(_ number: String) -> String {
        FolderOntology.folder(number)?.emptyHint ?? ""
    }

    /// Curate one folder's index.md from a section→body map. Renders every
    /// section the folder's schema declares (filled or its empty hint) and
    /// manages only the `section:` blocks, so the file's shape and any human
    /// edits survive.
    private static func write(folder number: String, sections bodies: [String: String]) {
        guard let folder = FolderOntology.folder(number) else { return }
        let blocks = folder.sections.map { section in
            ContextBlock(
                id: "section:\(ContextBlockFile.slug(section))",
                source: .agent,
                content: "## \(section)\n\n\(bodies[section] ?? folder.emptyHint)",
                agentHash: nil)
        }
        _ = Curator.curate(relativePath: folder.indexPath,
                           header: FolderOntology.indexHeader(for: folder),
                           pinnedContent: nil, agentBlocks: blocks,
                           managedPrefixes: ["section:"])
    }
}
