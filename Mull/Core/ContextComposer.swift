import Foundation

/// Composes the "Copy context" / "inject into field" context block.
///
/// This is a context-composition *engine*, not app state, which is why it lives
/// outside AppState: it reads the database, extracts facts, classifies recent
/// clipboard/screen text by mode, and ranks active projects. None of that has
/// anything to do with the app's @Published surface — AppState only needs the
/// finished string to put on the pasteboard.
///
/// PLACEMENT NOTE — why Services and not Core:
/// this type is UI-free (Foundation only) and would otherwise belong in Mull/Core
/// alongside CurrentState / TimeBlockEngine / Selection, so that MCPServer's
/// `get_user_context` could become its natural second caller. It cannot go there
/// yet for one reason: it depends on `FactExtractor`, which lives in
/// Mull/Services and is therefore not compiled into the MullMCP target. Moving
/// FactExtractor into Core is the prerequisite; once that happens this file can
/// move down with no source changes.
///
/// It is also, knowingly, the fourth independent answer to "what is the user
/// working on" (alongside TimeBlockEngine.projectSnapshots, CurrentState.current
/// and Selection). Extracting it whole is the step that makes that duplication
/// visible and mergeable later — it is deliberately not being reconciled here.
struct ContextComposer {

    let database: EventReading

    /// The line that makes a pasted block self-explanatory wherever it lands.
    /// Exposed because onboarding composes a starter block from a live read of the
    /// Mac before any history exists, and that block has to arrive framed the same
    /// way this one does.
    static let preamble = "Here is my current context from mull (a tool that records what I work on). "
        + "Use it to help me without making me re-explain myself.\n"

    /// Build the "Copy context" text — a SELECTED, current, self-contained snapshot,
    /// not a raw full.md dump. It composes the same use-time signals the MCP tools
    /// serve (identity + what you're doing now + where you left off), so a paste
    /// into ChatGPT/Claude is immediately useful with no tools to call. Passively
    /// consumed media (YouTube titles you watched, background audio) is excluded by
    /// construction: these engines key on projects/apps/files, not raw window
    /// titles, so the noise that pollutes full.md never reaches the clipboard.
    func compose() async -> String {
        await Task.detached { [database] in
            var sections: [String] = []

            // 1. Who I am — the user's own stated facts first, then rule-based ones
            //    (role, stack, work patterns).
            //    NOT me.md: its header is MCP-oriented boilerplate ("call the tools"),
            //    which is useless once pasted somewhere no tools exist.
            //
            //    The pinned layer used to be missing here entirely, which meant the
            //    seven answers onboarding asks for — role, working language, how the
            //    AI should reply — were written to me.pinned.md and then left out of
            //    the one payload the user actually hands an AI. It also left a fresh
            //    install with nothing to copy at all: inference needs days of events,
            //    while a stated fact is true the moment it is typed.
            var identityParts: [String] = []
            let pinned = Curator.pinnedFacts().trimmingCharacters(in: .whitespacesAndNewlines)
            if !pinned.isEmpty { identityParts.append(pinned) }

            let identity = FactExtractor(analytics: AnalyticsEngine(database: database),
                                         database: database)
                .generateFactSummary(days: 14)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !identity.isEmpty { identityParts.append(identity) }

            if !identityParts.isEmpty {
                sections.append("# Who I am\n\n" + identityParts.joined(separator: "\n\n"))
            }

            // 2. Right now — organized by MODE, not filtered by deletion
            //    (MAP-ARCHITECTURE.md: keep everything, mean it with mode). The lens
            //    for a small-context model surfaces what you're DOING
            //    (produce/decide/think/communicate) and keeps consumption but
            //    compacts it as research/consume — nothing is silently dropped.
            let state = CurrentState.current(database: database)
            var nowLines: [String] = []
            if let entity = state.activeEntity { nowLines.append("Active: \(entity)") }
            else if let title = state.activeTitle { nowLines.append("Active: \(title)") }
            if let app = state.activeApp { nowLines.append("App: \(app)") }

            var doing: [String] = []        // produce / decide / think / communicate
            var researching: [String] = []  // consume / research — kept, compacted
            var seen = Set<String>()
            for e in database.fetchEvents(from: Date().addingTimeInterval(-1800), to: Date()).reversed() {
                guard e.eventType == .clipboard || e.eventType == .screenText,
                      let raw = e.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                      raw.count >= 3 else { continue }
                let key = String(raw.prefix(40)).lowercased()
                if seen.contains(key) { continue }
                seen.insert(key)
                let snippet = String(raw.prefix(90))
                switch e.resolvedMode {
                case .produce, .decide, .think, .communicate:
                    if doing.count < 6 { doing.append("- [\(e.resolvedMode.rawValue)] \(snippet)") }
                case .consume, .research:
                    if researching.count < 4 { researching.append(String(snippet.prefix(50))) }
                }
                if doing.count >= 6 && researching.count >= 4 { break }
            }
            if !doing.isEmpty {
                nowLines.append("Recently (doing):")
                nowLines.append(contentsOf: doing)
            }
            if !researching.isEmpty {
                nowLines.append("Also (research/consume): " + researching.joined(separator: " · "))
            }
            if !nowLines.isEmpty { sections.append("# Right now\n\n\(nowLines.joined(separator: "\n"))") }

            // 3. Where I left off — ranked active projects with resume points.
            //    Drop window-title / file-path junk masquerading as a project
            //    (full paths, "NNN notes" counters, truncated titles): better an
            //    empty section than "projects" the AI would wrongly trust.
            func isJunkProject(_ name: String) -> Bool {
                if name.contains("/") { return true }
                if name.contains("…") || name.hasSuffix("...") { return true }
                if name.range(of: #"\d+\s*notes"#, options: .regularExpression) != nil { return true }
                return false
            }
            let snaps = TimeBlockEngine(database: database).projectSnapshots(days: 14)
            let active = snaps.filter { $0.daysSinceActive < 3 && !isJunkProject($0.name) }.prefix(5)
            if !active.isEmpty {
                var lines = ["# Active work — where I left off"]
                for p in active {
                    var line = "- **\(p.name)** — \(p.totalDurationFormatted), \(p.primaryApp), last \(p.lastActiveFormatted)"
                    if let file = p.lastFile { line += "\n  - resume at: \(file)" }
                    lines.append(line)
                }
                sections.append(lines.joined(separator: "\n"))
            }

            guard !sections.isEmpty else { return "" }

            // A short preamble so the pasted block is self-explanatory to any AI.
            var text = Self.preamble + "\n" + sections.joined(separator: "\n\n")
            text = ContextBlockFile.stripMarkers(text)

            let maxChars = Preferences.outputMaxChars
            return (maxChars > 0 && text.count > maxChars) ? String(text.prefix(maxChars)) : text
        }.value
    }
}
