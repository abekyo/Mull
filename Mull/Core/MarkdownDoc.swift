import Foundation

/// The vault's markdown house style, in one place.
///
/// mull writes its files from six independent generators, and until this existed
/// each improvised its own chrome. The shipped vault showed what that costs:
///
///   - `full.md` carried two `#` H1s and three timestamps, because it embedded
///     me.md and now.md *including their headers*.
///   - `now.md` announced its sections as `Projects:` in the half written by the
///     60s pass and as `## Projects` in the half written by the nightly pass —
///     two heading conventions in one file, one of which markdown renders as
///     ordinary prose.
///   - the nightly `## From last night's consolidation` was followed immediately
///     by a sibling `## Projects`, so everything that read as nested under the
///     consolidation was in fact beside it.
///   - a multi-line clipboard entry interpolated into a `- ` bullet ended the
///     list and ran its remaining lines together as one paragraph.
///
/// None of those are content problems. They are all the same structural
/// omission: nothing owned the shape of the document. This does.
///
/// The rules, which every generated file follows:
///
///  1. **Metadata goes in front matter, never in the body.** Timestamp, refresh
///     cadence, token budget. A reader meets real content on the first line of
///     prose instead of three italic lines of housekeeping.
///  2. **One `#` per file**, then `##`, then `###`. A bare `Label:` line never
///     stands in for a heading — markdown renders it as prose, so it is invisible
///     as structure to every reader that matters.
///  3. **Embedding a document demotes it.** Strip its front matter and title,
///     push its headings down, so the host file keeps a single spine.
///  4. **Text mull did not author is never interpolated raw.** Clipboard,
///     window titles and LLM replies are flattened to one line before entering a
///     list, or quoted as a block. Their newlines are not mull's structure.
///  5. **An empty section is not written.** Absence is information, and it costs
///     no lines to convey.
enum MarkdownDoc {

    // MARK: - Front matter

    static let fence = "---"

    /// The stamp every generated file carries in its front matter, and the one
    /// reliable way to recognise mull's own writing when it comes back around.
    ///
    /// It has to exist because mull captures the clipboard and window text of a
    /// Mac on which mull's own files are open. Six detectors — RecordingService's
    /// ingest filter, AnalyticsEngine twice, LiveContextGenerator's
    /// `isMullOutput` — recognised those files by the phrase "auto-updated" in
    /// their header. That is an English sentence fragment doing load-bearing
    /// structural work: rewording the header (as this change does) silently turns
    /// the feedback loop back on, and nothing fails visibly when it happens.
    /// A declared key cannot be reworded by accident.
    static let generatorStamp = #"generator: "mull""#

    /// Is this captured text mull's own writing coming back around?
    ///
    /// One predicate, in Core so the MCP target and the analytics engines share
    /// it, because the alternative is what was here before: five copies of an
    /// `||` chain over English phrases, each a slightly different subset of the
    /// others, none of them updated when a header was reworded.
    ///
    /// The legacy phrases stay. Events recorded before the stamp existed are
    /// still in the database and still describe files whose headers said
    /// "auto-updated", and an old vault on disk keeps its old headers until the
    /// next write.
    static func isGeneratedByMull(_ text: String) -> Bool {
        if text.contains(generatorStamp) { return true }
        if text.contains(ContextBlockFile.markerPrefix) { return true }
        return legacyMarkers.contains { text.contains($0) }
    }

    /// Header phrasings mull shipped before `generatorStamp` existed.
    private static let legacyMarkers = [
        "auto-updated", "mull:block", "mull:auto",
        "mull is recording", "mull is still learning",
        "About the user (auto", "What the user is currently",
        "Raw activity data for", "Context about the user", "No activity recorded",
    ]

    /// A YAML front-matter block. Values are always quoted: the most common one
    /// here is an ISO timestamp, whose `:` would otherwise make the line an
    /// invalid mapping and turn the whole block back into visible junk.
    static func frontMatter(_ pairs: [(String, String)]) -> String {
        guard !pairs.isEmpty else { return "" }
        var out = [fence]
        for (key, value) in pairs {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            out.append("\(key): \"\(escaped)\"")
        }
        out.append(fence)
        return out.joined(separator: "\n")
    }

    /// The standard opening of a generated file: front matter, then the single H1.
    /// `note` is the one line of orientation a file is allowed in its body — use it
    /// for what the reader must know to edit safely, not for what mull wants to say.
    static func header(title: String, meta: [(String, String)], note: String? = nil) -> String {
        var parts: [String] = []
        let matter = frontMatter([("generator", "mull")] + meta)
        if !matter.isEmpty { parts.append(matter) }
        parts.append("# \(title)")
        if let note, !note.isEmpty { parts.append("> \(note)") }
        return parts.joined(separator: "\n\n")
    }

    /// Everything after a leading front-matter block, or the text unchanged when
    /// there is none. Only a block at the very top counts — a `---` further down
    /// is a horizontal rule and belongs to the content.
    static func stripFrontMatter(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == fence,
              let close = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == fence
              })
        else { return text }
        return lines[(close + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A document's content with all of its chrome removed — front matter, `#`
    /// title, and the orientation `note` that sits directly under the title.
    /// What you embed when the host file supplies its own heading for it.
    ///
    /// The note goes because it is addressed to someone editing THAT file.
    /// Carried into full.md it became "Edit any of this — your edits are kept"
    /// sitting under a heading in a file whose own note says the opposite ("edit
    /// the other two, not this one"). Only a blockquote in the title position is
    /// dropped; one further down is content the user or an agent wrote.
    static func body(of text: String) -> String {
        var lines = stripFrontMatter(text).components(separatedBy: "\n")

        func dropLeadingBlanks() {
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeFirst()
            }
        }

        dropLeadingBlanks()
        guard lines.first?.hasPrefix("# ") == true else {
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        lines.removeFirst()
        dropLeadingBlanks()
        while lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix(">") == true {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `# ` line a generated document opens with, if it has one.
    static func title(of text: String) -> String? {
        stripFrontMatter(text)
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .flatMap { $0.hasPrefix("# ") ? $0 : nil }
    }

    /// A whole document as a reader should receive it: its title, then its content.
    ///
    /// `body(of:)` is for embedding, where the host file supplies the heading. This
    /// is for handing files over intact — `get_user_context` concatenates several —
    /// where the title is the only thing telling the reader which document a passage
    /// belongs to.
    ///
    /// What goes either way is the front matter and the orientation note. Both are
    /// about the file rather than about its subject, and both were reaching agents:
    /// me.md arrived as `generator: "mull"`, `# Who I am`, and then "Rewrite a block
    /// and mull stops touching it." — an instruction for somebody editing the raw
    /// file, sitting in the position where the first fact about the user should be.
    /// full.md's embed had been stripping exactly this since it was written; the MCP
    /// path had not, so the same text was clean by one road and not by the other.
    static func forReading(_ text: String) -> String {
        let content = body(of: text)
        guard let title = title(of: text) else { return content }
        return content.isEmpty ? title : title + "\n\n" + content
    }

    /// Push every heading down `levels`, so a document can sit under a host
    /// heading without its `##`s colliding with the host's own.
    ///
    /// Fenced code is skipped: a shell comment or a Python `#!` inside a block is
    /// not a heading, and deepening it would corrupt the code the user copied.
    /// Markdown stops at `######`, so anything that would overflow is clamped —
    /// a clamped heading is wrong by one level; an `#######` is not a heading at all.
    static func demoteHeadings(_ text: String, by levels: Int) -> String {
        guard levels > 0 else { return text }
        var inFence = false
        return text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return line
            }
            guard !inFence, trimmed.hasPrefix("#") else { return line }
            let hashes = trimmed.prefix { $0 == "#" }.count
            guard hashes >= 1, hashes <= 6,
                  trimmed.dropFirst(hashes).hasPrefix(" ") else { return line }
            return String(repeating: "#", count: min(6, hashes + levels))
                + trimmed.dropFirst(hashes)
        }.joined(separator: "\n")
    }

    // MARK: - Foreign text

    /// Collapse text mull did not author into one line fit for a list item.
    ///
    /// The line that motivated this: a copied OneTab dump — eight newline-separated
    /// browser tab titles — went into proactive.md as `- document: OneTab` followed
    /// by seven unindented lines. Markdown ended the list at the first of them and
    /// ran the rest together, four near-identical times in a row. The newlines in
    /// someone's clipboard are not mull's document structure.
    static func inline(_ text: String, limit: Int = 120) -> String {
        let flat = text
            .split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return flat.count > limit ? String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : flat
    }

    /// Foreign text kept multi-line, as a blockquote — every line prefixed, so the
    /// block survives intact however long it is and cannot be mistaken for mull's
    /// own words. Blank interior lines get a bare `>` so the quote does not split.
    static func quote(_ text: String, maxLines: Int = 8) -> String {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let shown = lines.prefix(maxLines).map { $0.isEmpty ? ">" : "> \($0)" }
        let more = lines.count > maxLines ? ["> …"] : []
        return (shown + more).joined(separator: "\n")
    }

    // MARK: - Links

    /// Where a markdown link in a vault document points.
    enum LinkTarget: Equatable {
        /// Has a scheme the system knows what to do with (`https:`, `mailto:`, `file:`).
        case external(URL)
        /// A path inside `~/mull`, vault-relative. mull opens these itself.
        case vaultFile(String)
        /// An anchor, a dead path, or something pointing outside the vault.
        case unresolved
    }

    /// Resolve a link's destination.
    ///
    /// Both surfaces that render markdown fed every link to `NSWorkspace` /
    /// `openURL`, which can only act on a URL with a scheme. mull's own links have
    /// none: `MEMORY.md` is a list of `[VS Codeでの作業習慣](memory/vs_codeでの作業
    /// 習慣.md)` — vault-relative paths — so every click on the one file whose
    /// entire purpose is to be an index did nothing at all, silently.
    ///
    /// A relative path resolves against the folder of the document it appears in,
    /// which is what makes `memory/x.md` in `MEMORY.md` and `../me.md` in
    /// `projects/x.md` both mean what a reader assumes. A `.md` extension is
    /// inferred when the bare path does not exist, so Obsidian-style links work.
    ///
    /// A path that climbs out of the vault is `unresolved`, never opened. These
    /// documents are written by mull, by the user, and by any agent holding the
    /// `write_note` / `curate` tools — a link is untrusted input, and a click is
    /// not consent to open an arbitrary file on the disk.
    static func linkTarget(_ raw: String, from sourceRelativePath: String? = nil,
                           exists: (String) -> Bool = MullDirectory.exists) -> LinkTarget {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return .unresolved }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            // `file:` is external in the sense that mull hands it off, but only when
            // it stays in the vault — same reason as the traversal check below.
            if scheme == "file" {
                let path = url.standardizedFileURL.path
                let root = MullDirectory.root.standardizedFileURL.path
                guard path == root || path.hasPrefix(root + "/") else { return .unresolved }
                return .external(url)
            }
            return .external(url)
        }

        // Percent-encoding survives the markdown parser (a Japanese filename comes
        // back as %E3%81%…), and a path with a literal `%` in it is not a thing
        // these documents contain.
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        let base = sourceRelativePath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        guard !decoded.hasPrefix("/") else { return .unresolved }
        let joined = base.isEmpty ? decoded : (base as NSString).appendingPathComponent(decoded)

        // Collapsed by hand rather than with `standardizingPath`, which only
        // resolves `..` in an ABSOLUTE path — on a relative one it cannot know
        // whether a component is a symlink, so it leaves the `..` in place and the
        // guard below then rejects a link that was perfectly valid.
        var stack: [String] = []
        for component in joined.components(separatedBy: "/") {
            switch component {
            case "", ".": continue
            case "..":
                if stack.isEmpty { return .unresolved }   // climbing out of the vault
                stack.removeLast()
            default: stack.append(component)
            }
        }
        guard !stack.isEmpty else { return .unresolved }
        let normalized = stack.joined(separator: "/")

        if exists(normalized) { return .vaultFile(normalized) }
        let withExtension = normalized + ".md"
        if exists(withExtension) { return .vaultFile(withExtension) }
        return .unresolved
    }

    // MARK: - Sections

    /// A `##`-level section, or nil when there is nothing to put in it. Callers
    /// `compactMap` over these, which is what makes rule 5 the default rather
    /// than something each generator has to remember.
    static func section(_ title: String, level: Int = 2, _ body: String?) -> String? {
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return String(repeating: "#", count: max(1, min(6, level))) + " \(title)\n\n"
            + body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same, from a list of items: no items, no section.
    static func section(_ title: String, level: Int = 2, items: [String]) -> String? {
        section(title, level: level, items.isEmpty ? nil : items.joined(separator: "\n"))
    }

    /// Join built sections into a document body with one blank line between them.
    static func join(_ sections: [String?]) -> String {
        sections.compactMap { $0 }.joined(separator: "\n\n")
    }
}
