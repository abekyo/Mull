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
    ///
    /// ## The shape of the block (2026-08-09)
    ///
    /// It used to be three `#` headings, in the order mull stores things:
    /// identity, then now, then project snapshots. Read as a reader rather than as
    /// a data model, that shape has one large defect and several small ones. The
    /// large one: **the same fact appeared in all three sections.** A real block
    /// said "Mull" nine times, as `取り組み中: Mull`, `作業中: Mull`, six
    /// `— Mull` suffixes, and a bolded snapshot. Three headings tell a reader that
    /// three different things are coming, so they read all three looking for the
    /// difference and pay for a distinction that is not there.
    ///
    /// The small ones: `[produce]` leaked mull's own mode vocabulary into a block
    /// meant for someone else; the `#` headings collided with whatever document
    /// the block was pasted into; and the most load-bearing number (hours today)
    /// was last.
    ///
    /// So: one sentence for the anchor, one list for the work, and one trailing
    /// line for everything else. The project name is stated once and stripped from
    /// the lines beneath it, because a suffix repeated six times is not
    /// information.
    func compose() async -> String {
        await Task.detached { [database] in
            let facts = FactExtractor(analytics: AnalyticsEngine(database: database),
                                      database: database).extractFacts(days: 14)
            func factTexts(_ category: FactCategory) -> [String] {
                facts.filter { $0.category == category }.map(\.text)
            }

            let state = CurrentState.current(database: database)
            let snaps = TimeBlockEngine(database: database).projectSnapshots(days: 14)

            var doing: [String] = []        // produce / decide / think / communicate
            var researching: [String] = []  // consume / research, kept when anchored
            var seen = Set<String>()
            var doingText: [String] = []    // the raw snippets behind `doing`

            /// Are these two snippets the same utterance, caught mid-flush?
            ///
            /// Dictation and a typing buffer both emit the sentence several times
            /// as it grows, and the exact-prefix key below cannot see it: a real
            /// paste carried "うーん、今のところ4年フィリピンにいて" beside
            /// "今のところ4年フィリピンにいてそろそろ国変えてもいいかなって思ってる",
            /// which differ at character one and say the same thing.
            ///
            /// The test is a shared contiguous run, sized against the SHORTER
            /// string rather than fixed. Two different notes can share a stock
            /// phrase (`database: database`); what they do not share is most of one
            /// of them. Requiring 60% coverage is what keeps this from folding two
            /// genuinely different lines that happen to start alike.
            func sameUtterance(_ a: String, _ b: String) -> Bool {
                let (short, long) = a.count <= b.count ? (a, b) : (b, a)
                let need = max(12, Int(Double(short.count) * 0.6))
                guard short.count >= need else { return false }
                let chars = Array(short)
                for start in 0...(chars.count - need) {
                    if long.contains(String(chars[start..<(start + need)])) { return true }
                }
                return false
            }
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
                    // Keep the longest version, not the newest one. A growing
                    // dictation buffer usually emits the complete sentence last,
                    // so newest-wins is right most of the time and silently wrong
                    // the rest — an edit that shortens a line, a flush that lands
                    // out of order. Length is what "complete" actually means here,
                    // and it does not depend on the order events arrive in.
                    if let i = doingText.firstIndex(where: { sameUtterance($0, snippet) }) {
                        if snippet.count > doingText[i].count {
                            doing[i] = snippet
                            doingText[i] = snippet
                        }
                        continue
                    }
                    if doing.count < 6 {
                        doing.append(snippet)
                        doingText.append(snippet)
                    }
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
            // Drop window-title / file-path junk masquerading as a project (full
            // paths, "NNN notes" counters, truncated titles): better to say nothing
            // than to name a "project" the AI would wrongly trust.
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

            let active = snaps
                .filter { $0.daysSinceActive < 3 && $0.totalDuration >= minimumWorth && !isJunkProject($0.name) }
                .prefix(5)

            // MARK: - Assemble

            /// Drop a trailing `— Mull` when the whole list is about Mull. The
            /// suffix is the window title's, and repeating it under a heading that
            /// already names the project is six copies of one fact.
            func withoutProjectSuffix(_ line: String, _ project: String?) -> String {
                guard let project, !project.isEmpty else { return line }
                for sep in ProjectNames.separators where line.hasSuffix(sep + project) {
                    return String(line.dropLast(sep.count + project.count))
                        .trimmingCharacters(in: .whitespaces)
                }
                return line
            }

            let anchor = state.activeEntity
            let anchorSnapshot = anchor.flatMap { name in active.first { $0.name == name } }
            var sections: [String] = []

            // The user's own answers, first and verbatim. They were typed rather
            // than inferred, which makes them true on a fresh install where
            // everything below needs days of events before it says anything.
            let pinned = Curator.pinnedFacts().trimmingCharacters(in: .whitespacesAndNewlines)
            if !pinned.isEmpty { sections.append(pinned) }

            // One sentence: where you are, in what, for how long.
            var opening: [String] = []
            switch (anchor, state.activeApp) {
            case let (entity?, app?):
                opening.append(VaultText.t("Working on \(entity) in \(app).",
                                           "いま \(entity) を \(app) で作業中。"))
            case let (entity?, nil):
                opening.append(VaultText.t("Working on \(entity).", "いま \(entity) を作業中。"))
            case let (nil, app?):
                opening.append(VaultText.t("In \(app).", "いま \(app) を使用中。"))
            case (nil, nil):
                break
            }
            if let snapshot = anchorSnapshot {
                opening.append(VaultText.t("\(snapshot.totalDurationFormatted) today.",
                                           "今日ここまで \(snapshot.totalDurationFormatted)。"))
            }
            if !opening.isEmpty { sections.append(opening.joined(separator: " ")) }

            // Language and tools, as observations rather than as instructions. The
            // useful form would be "reply in Japanese", and that is a claim about
            // what the user wants rather than a record of what they did (§7.1).
            let about = (factTexts(.identity) + factTexts(.skills)).joined(separator: VaultText.t(". ", "。"))
            if !about.isEmpty { sections.append(about + VaultText.t(".", "。")) }

            if !doing.isEmpty {
                let header = VaultText.t("Today, most recent first:", "今日やったこと（新しい順）:")
                let lines = doing.map { "- " + withoutProjectSuffix($0, anchor) }
                sections.append(([header] + lines).joined(separator: "\n"))
            }

            if !researching.isEmpty {
                let label = anchor.map { VaultText.t("Read about \($0): ", "\($0) について見ていたもの: ") }
                    ?? VaultText.t("Also read: ", "ほかに見ていたもの: ")
                sections.append(label + researching.joined(separator: VaultText.t(" · ", "、")))
            }

            // Everything that is not the anchor, named once. `Working on:` facts and
            // the snapshots are two answers to the same question, so they are merged
            // here rather than printed as two lists (PITFALLS.md §7).
            var others: [String] = []
            for text in factTexts(.projects) {
                let name = text
                    .replacingOccurrences(of: VaultText.t("Working on: ", "取り組み中: "), with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, name != anchor, !others.contains(name) { others.append(name) }
            }
            for p in active where p.name != anchor && !others.contains(p.name) {
                others.append(p.name)
            }
            if !others.isEmpty {
                sections.append(VaultText.t("Also open: ", "ほかに開いていたもの: ")
                                + others.joined(separator: VaultText.t(", ", "、")))
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
