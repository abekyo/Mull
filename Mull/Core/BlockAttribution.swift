import Foundation

/// What a block was *for*, when its own titles do not say.
///
/// A browser block is captioned with a page title, and a page title answers "what
/// was on screen" without answering "why". The why is usually sitting next to it in
/// the record: the document the person had open in the same stretch, the document
/// they went back to, the thing they copied out of the page. None of that is a
/// question to put to the person — it is a reading of what is already there, and it
/// is labelled as a reading, never as a fact they stated.
///
/// The gate is deliberately open. Attribution names whatever document, project or
/// file the record shows, so a piece of work nobody planned still gets a name; a
/// list of expected tasks would only ever recognise the work its author already knew
/// about, which is the blocklist argument `ProjectNames` makes about titles.
///
/// Foundation-only, like `BlockSegmentation`, and listed beside it in
/// `eval/calendar/run.sh` so the reading can be scored against a real day.
struct BlockAttribution: Equatable {
    enum Basis: Equatable {
        /// The artifact was open inside this very block — a browser-faced stretch that
        /// also held the document.
        case withinBlock
        /// Something was copied here, and the next thing worked on was the artifact.
        case clipboardFlow
        /// The same artifact was being worked on immediately before and after.
        case sandwiched
        /// Worked on just before. Context, not a claim: one side alone cannot tell
        /// research from a break.
        case before
        /// Worked on just after. Context, not a claim.
        case after

        /// Whether this basis is strong enough to count the block's time toward the
        /// artifact. One-sided adjacency is shown as a cue and never summed — the
        /// line between an observation and a claim (CLAUDE.md §7.1) runs here.
        var isClaim: Bool {
            switch self {
            case .withinBlock, .clipboardFlow, .sandwiched: return true
            case .before, .after: return false
            }
        }

        /// Fixed English tokens: this goes into text an AI reads and a shell script
        /// parses, so it does not follow the reader's language.
        var token: String {
            switch self {
            case .withinBlock: return "open in the same stretch"
            case .clipboardFlow: return "copied into it"
            case .sandwiched: return "worked on before and after"
            case .before: return "worked on just before"
            case .after: return "worked on just after"
            }
        }
    }

    /// The document, project or file, spelled as its window spelled it.
    let artifact: String
    /// `BlockSegmenter.normalizeTaskKey` of a block about that artifact, so a consumer
    /// grouping by task can fold this block into the same group without re-deriving
    /// the key from a string.
    let key: String
    let basis: Basis
}

enum BlockAttributor {

    /// Settle `servedBy` on every block that is about nothing of its own.
    ///
    /// Three readings, strongest first, and a block keeps the first that lands:
    /// the artifact was open inside the block; something was copied here and the
    /// artifact came next; the artifact stands on both sides. What is left gets a
    /// one-sided cue or nothing. `gap` is how far apart two blocks may be and still be
    /// read together — the resume window, so "the same session" means the same thing
    /// here as it does when a break is rejoined.
    static func attribute(_ blocks: inout [TimeBlock], chrome: Set<String>, gap: TimeInterval) {
        guard !blocks.isEmpty else { return }

        // What each block is about on its own account, or nil.
        let own: [(name: String, key: String)?] = blocks.map { artifact(of: $0, chrome: chrome) }

        // 1. Open in the same stretch.
        for i in blocks.indices where own[i] == nil {
            if let found = artifact(within: blocks[i], chrome: chrome) {
                blocks[i].servedBy = BlockAttribution(artifact: found.name, key: found.key, basis: .withinBlock)
            }
        }

        // An anchor is a block about something — by its own title, or by a reading
        // already settled. Readings chain: the browser stretch that held the document
        // anchors the bare browser stretch after it.
        func anchor(_ i: Int) -> (name: String, key: String)? {
            if let o = own[i] { return o }
            if let a = blocks[i].servedBy, a.basis.isClaim { return (a.artifact, a.key) }
            return nil
        }
        func adjacent(_ earlier: Int, _ later: Int) -> Bool {
            blocks[later].start.timeIntervalSince(blocks[earlier].end) <= gap
        }

        // 2. Copied here, then went to the artifact.
        for i in blocks.indices where anchor(i) == nil && blocks[i].topClipboard != nil {
            let next = i + 1
            guard next < blocks.count, adjacent(i, next), let target = anchor(next) else { continue }
            blocks[i].servedBy = BlockAttribution(artifact: target.name, key: target.key, basis: .clipboardFlow)
        }

        // 3. Runs of blocks about nothing, read by what stands on either side. A run,
        // not a block: three browser stretches between two halves of the same
        // document are one excursion, and reading them one at a time would anchor
        // only the two at the edges.
        var i = 0
        while i < blocks.count {
            guard anchor(i) == nil else { i += 1; continue }
            var j = i
            while j + 1 < blocks.count, anchor(j + 1) == nil { j += 1 }

            let before = (i > 0 && adjacent(i - 1, i)) ? anchor(i - 1) : nil
            let after = (j + 1 < blocks.count && adjacent(j, j + 1)) ? anchor(j + 1) : nil

            let reading: BlockAttribution?
            if let b = before, let a = after, b.key == a.key {
                reading = BlockAttribution(artifact: b.name, key: b.key, basis: .sandwiched)
            } else if let b = before {
                reading = BlockAttribution(artifact: b.name, key: b.key, basis: .before)
            } else if let a = after {
                reading = BlockAttribution(artifact: a.name, key: a.key, basis: .after)
            } else {
                reading = nil
            }
            if let reading {
                for k in i...j { blocks[k].servedBy = reading }
            }
            i = j + 1
        }
    }

    // MARK: - What counts as an artifact

    /// The document, project or file a title names, or nil when it names none.
    ///
    /// A page title in a browser never does — the same rule `BlockSegmenter.projectName`
    /// applies, for the same reason: a web page is something read, not something
    /// worked on. An editor title names its project; a bare filename names the file;
    /// and a title with neither — a Notion page, a Premiere sequence, a document
    /// window — names the artifact directly, under the same shape gate a project
    /// name has to pass.
    ///
    /// The key returned is the one `BlockSegmenter.normalizeTaskKey` would derive for a
    /// block captioned by this title, so grouping by key puts the reading and the
    /// thing it reads in the same bucket. The two must not drift: a test holds them
    /// together.
    static func artifact(inTitle title: String, app: String, chrome: Set<String>) -> (name: String, key: String)? {
        guard !ProjectNames.contentDrivenApps.contains(app.lowercased()) else { return nil }
        // The recorder's own furniture. When it had no title to record, a row's text
        // is the app's name, or the departure line "App: unknown (26s)" — and the
        // segmenter reads that text as the title. Two days of real rows read this
        // way turned "Parallels Desktop" and "Code: unknown (26s)" into the documents
        // an hour of work was for. Neither shape is anything a person named.
        if title.lowercased() == app.lowercased() || title.hasPrefix("\(app): ") { return nil }

        let parsed = BlockSegmenter.parseWindowTitle(title, app: app)
        let candidate: (name: String, key: String)?
        if let project = parsed.project, BlockSegmenter.isValidLabel(project, chrome: chrome) {
            candidate = (project, project.lowercased())
        } else if let file = parsed.file {
            candidate = (file, String(file.lowercased().prefix(40)))
        } else if parsed.project == nil, BlockSegmenter.isValidLabel(parsed.display, chrome: chrome) {
            candidate = (parsed.display, String(parsed.display.lowercased().prefix(40)))
        } else {
            candidate = nil
        }
        // The same gate the calendar mirror puts on a title before it leaves the Mac:
        // a name, not a sentence. A reading that says a stretch was *for* something
        // is a stronger claim than a caption, and it should not pass on a weaker one.
        guard let found = candidate,
              found.name.lowercased() != app.lowercased(),
              CalendarMirror.isPresentable(found.name) else { return nil }
        return found
    }

    /// What a block is about by its own caption, or nil.
    ///
    /// A label lifted from copied text is refused here as it is refused by the
    /// calendar mirror: content the user copied *out of* something is not the thing
    /// they were working on.
    static func artifact(of block: TimeBlock, chrome: Set<String>) -> (name: String, key: String)? {
        guard !block.labelFromClipboard, let title = block.topWindowTitle else { return nil }
        return artifact(inTitle: title, app: block.app, chrome: chrome)
    }

    /// An artifact seen inside a block whose face is something else — the Notion
    /// page that was open through a Chrome-dominated stretch. Most-seen title first;
    /// ties broken on the title so the reading does not change between launches.
    static func artifact(within block: TimeBlock, chrome: Set<String>) -> (name: String, key: String)? {
        let seen = block.observedTitleCounts
            .filter { !ProjectNames.contentDrivenApps.contains($0.app.lowercased()) }
            .sorted { $0.count == $1.count ? $0.title < $1.title : $0.count > $1.count }
        for candidate in seen {
            if let found = artifact(inTitle: candidate.title, app: candidate.app, chrome: chrome) {
                return found
            }
        }
        return nil
    }
}
