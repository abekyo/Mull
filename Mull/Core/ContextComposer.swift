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

    /// Build the "Copy context" text: a selected, current, self-contained snapshot
    /// rather than a raw full.md dump. It composes the same use-time signals the MCP
    /// tools serve (identity, what you're doing now, where you left off), so a paste
    /// into ChatGPT or Claude is useful with no tools to call.
    ///
    /// This comment used to claim that passively consumed media "is excluded by
    /// construction". **It was not.** The `.consume` / `.research` branch below kept
    /// window titles verbatim, and a real paste carried four YouTube titles about
    /// tattoos into a block about building this app. Nothing about the construction
    /// excluded them; the sentence was aspiration written as fact.
    ///
    /// What excludes them now is the anchor: consumption is included only when it
    /// belongs to the entity the user is actually working in, because "what I read
    /// about this project" is context and "what played in another tab" is not.
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
            // The raw window title used to be the fallback here, which meant that
            // whatever page happened to be frontmost was pasted verbatim under
            // "Active:". `activeEntity` is nil exactly when the title names no
            // project — a browser tab, a video — so the fallback fired precisely in
            // the cases where the title was somebody else's words. The app name
            // alone is the honest answer: mull knows which app, and does not know
            // what it was for.
            if let entity = state.activeEntity { nowLines.append("Active: \(entity)") }
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
                    // Only what was consumed *about the thing being worked on*.
                    //
                    // Without this, every paste carried whatever had been playing in
                    // another tab. The failure is not that the titles are
                    // embarrassing (though they were); it is that consumption is the
                    // one mode where the user is not the author, so an unanchored
                    // entry is a claim about their work made out of someone else's
                    // words. With no anchor there is nothing to test that against,
                    // so nothing is included.
                    guard let anchor = state.activeEntity,
                          let entity = e.entity ?? Entity.from(e.windowTitle ?? raw),
                          entity.caseInsensitiveCompare(anchor) == .orderedSame else { continue }
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
                // The shared shape gate, so a name this section rejects and one
                // `Working on:` accepts cannot disagree (PITFALLS.md §7).
                return !ProjectNames.isPlausible(name)
            }

            // A project you touched for a minute is not where you left off.
            //
            // Without a floor, a stray window title that happened to survive the
            // shape gate arrives beside five hours of real work carrying the same
            // "**bold** — duration" formatting, and an agent has no way to tell that
            // one of them is a rounding error. `1m` and `2m` entries were doing
            // exactly that in a real paste.
            let minimumWorth: TimeInterval = 300

            let snaps = TimeBlockEngine(database: database).projectSnapshots(days: 14)
            let active = snaps
                .filter { $0.daysSinceActive < 3 && $0.totalDuration >= minimumWorth && !isJunkProject($0.name) }
                .prefix(5)
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
