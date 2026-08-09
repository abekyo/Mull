import SwiftUI

/// The display layer — Crane MD's "表示層" (設計思想 §エディタモデル) translated to mull.
///
/// Renders plain Markdown for *reading* (me.md, now.md, proactive.md, daily/…) with
/// the calm typography of a reading surface, NOT the dense dashboard. It is display
/// only: it parses a copy and never writes — so the file on disk stays byte-for-byte
/// what produced it (原則6). Editing happens in `MarkdownTextEditor`; this is the
/// polished face mull shows when you're reading what it knows about you.
///
/// The two renderers must agree. A note that grows a fenced block or a numbered list
/// while you edit it cannot lose that structure the moment you close the editor — the
/// same document has to read the same way on both surfaces, or the file stops feeling
/// like one thing. So the construct list here tracks `MarkdownTextEditor`'s highlighter
/// exactly: title (1行目), `#`…`######`, `- [ ]`/`- [x]`, bullets, `1.` ordered items,
/// `>` quotes, `---` rules, ``` fences, and inline `**bold**` / `*italic*` /
/// `` `code` `` / `~~strike~~` / `[link](url)`.
///
/// Where the two *deliberately* differ is concealment. The editor keeps every marker
/// on screen (Bear-style: decorate the syntax, never hide the bytes) because you are
/// typing into it. Reading is the opposite job — the `#`, the fences and the `](url)`
/// are scaffolding, so here they simply don't appear, exactly as the editor's
/// reveal-on-cursor collapses them on every line the caret isn't sitting in.
struct MarkdownView: View {
    let text: String
    /// Whether the first non-empty line is promoted to a large title. True for note files
    /// (Crane: 1行目=タイトル); false where the text is a paragraph that happens to lead a
    /// document — e.g. a chat reply, whose first line should read as body, not a headline.
    var titleFirstLine: Bool = true
    /// Vault-relative path of the document being rendered, so a relative link
    /// (`memory/x.md`) can be resolved against the folder it was written in.
    var sourcePath: String? = nil
    /// Called with a vault-relative path when the reader clicks a link that points
    /// inside `~/mull`. Surfaces that can navigate (the Files tab) open the file;
    /// where this is nil the file is revealed in Finder instead, because doing
    /// nothing is what this whole change is about.
    var onOpenVaultFile: ((String) -> Void)? = nil

    /// Parsed once per instance rather than per `body` call. The whole point of the
    /// lazy stack below is that a long file doesn't build every line up front; re-walking
    /// the text on each layout pass would hand that saving straight back.
    private let blocks: [MarkdownBlock]

    init(_ text: String, titleFirstLine: Bool = true,
         sourcePath: String? = nil, onOpenVaultFile: ((String) -> Void)? = nil) {
        self.text = text
        self.titleFirstLine = titleFirstLine
        self.sourcePath = sourcePath
        self.onOpenVaultFile = onOpenVaultFile
        self.blocks = MarkdownBlock.parse(text, titleFirstLine: titleFirstLine)
    }

    /// Links were styled here but never wired to anything, so `openURL` got the
    /// default behaviour: hand the URL to the system. mull's own links are
    /// vault-relative paths with no scheme, which the system cannot open, so
    /// clicking one did nothing and said nothing — including in `MEMORY.md`,
    /// which is nothing but links.
    private func open(_ url: URL) -> OpenURLAction.Result {
        // `relativeString` rather than `absoluteString`: a schemeless link stays
        // relative, and absoluteString would resolve it against the app's own
        // working directory.
        switch MarkdownDoc.linkTarget(url.relativeString, from: sourcePath) {
        case .external(let target):
            return .systemAction(target)
        case .vaultFile(let path):
            if let onOpenVaultFile {
                onOpenVaultFile(path)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([MullDirectory.url(for: path)])
            }
            return .handled
        case .unresolved:
            return .discarded
        }
    }

    var body: some View {
        // Lazy because the documents this draws are open-ended: full.md and a month of
        // daily/ notes are thousands of lines, and an eager stack built a `Text` for
        // every one of them before the first paragraph could appear. Off a scroll view
        // (a chat bubble, an onboarding preview) this behaves as a plain VStack, so the
        // short cases are unaffected.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                row(block)
            }
        }
        .environment(\.openURL, OpenURLAction { open($0) })
    }

    // MARK: - Blocks

    @ViewBuilder
    private func row(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .blank:
            Color.clear.frame(height: DS.readLineSpacing + DS.xs)        // paragraph breathing

        case .frontMatter(let pairs):
            // Small, dim, above the title — present for the reader who wants to
            // know how fresh the file is, and out of the way of the one who doesn't.
            // These lines used to be the document's opening paragraph.
            // `generator` never reaches here; it is dropped at the parse site.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    (Text(pair.key.uppercased() + "  ").font(DS.labelFont)
                        + Text(pair.value).font(DS.captionFont))
                        .foregroundStyle(DS.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, DS.sm)

        case .title(let text):
            inline(text)
                .font(DS.readTitleFont)
                .foregroundStyle(DS.ink)
                .padding(.bottom, DS.md)

        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .foregroundStyle(DS.ink)
                .padding(.top, headingLead(level))
                .padding(.bottom, level == 1 ? DS.sm : DS.xs)

        case .rule:
            Rectangle()
                .fill(DS.hairline)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.sm)

        case .code(let lines):
            codePanel(lines)

        case .quote(let lines):
            quote(lines)

        case .task(let done, let text, let indent):
            listRow(indent: indent) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(DS.readFont)
                    .foregroundStyle(done ? DS.moon : DS.inkFaint)
            } content: {
                inline(text)
                    .font(DS.readFont)
                    .foregroundStyle(done ? DS.inkDim : DS.ink)
                    .strikethrough(done, color: DS.inkFaint)
            }

        case .bullet(let text, let indent):
            listRow(indent: indent) {
                Text("•").font(DS.readFont).foregroundStyle(DS.moonDim)
            } content: {
                inline(text).font(DS.readFont).foregroundStyle(DS.ink)
            }

        case .ordered(let marker, let text, let indent):
            listRow(indent: indent) {
                // The literal "3." rather than a re-derived counter: the file is the
                // truth, and a list that starts at 3 in the bytes starts at 3 here.
                Text(marker).font(DS.readFont).foregroundStyle(DS.moonDim)
            } content: {
                inline(text).font(DS.readFont).foregroundStyle(DS.ink)
            }

        case .paragraph(let text):
            inline(text)
                .font(DS.readFont)
                .foregroundStyle(DS.ink)
                .lineSpacing(DS.readLineSpacing)
        }
    }

    /// Marker in its own column so wrapped text hangs under the content rather than
    /// under the bullet — the SwiftUI answer to the editor's `headIndent`.
    private func listRow<Marker: View, Content: View>(
        indent: Int,
        @ViewBuilder marker: () -> Marker,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            marker().frame(minWidth: DS.lg, alignment: .leading)
            content()
        }
        .padding(.leading, CGFloat(indent) * DS.lg)
        .padding(.bottom, DS.hair)
    }

    /// A fenced block, drawn as the editor's layout manager draws it: one rounded panel
    /// spanning every line, inset from the prose, with the fences themselves dropped.
    private func codePanel(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                // A blank line inside a block has no glyphs to give it height, and the
                // panel would swallow it — a space stands in so the code keeps its shape.
                Text(line.isEmpty ? " " : line)
                    .font(DS.codeFont)
                    .foregroundStyle(DS.inkDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, DS.sm)
        .padding(.horizontal, DS.md)
        .background(RoundedRectangle(cornerRadius: DS.radiusSm).fill(DS.ink.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusSm).strokeBorder(DS.hairline, lineWidth: 0.75))
        .padding(.vertical, DS.sm)
    }

    /// Consecutive `>` lines are one quote, so a wrapped citation gets a single
    /// continuous bar down its side instead of one stub per line.
    private func quote(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                inline(line)
                    .font(DS.readFont)
                    .foregroundStyle(DS.inkDim)
                    .italic()
                    .lineSpacing(DS.readLineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, DS.lg)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: DS.radiusXs)
                .fill(DS.moon.opacity(0.55))
                .frame(width: DS.hair)
        }
        .padding(.bottom, DS.hair)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return DS.readTitleFont
        case 2: return DS.readH2Font
        case 3: return DS.readH3Font
        default: return DS.subtitleSemibold
        }
    }

    /// Air above a heading, growing with its rank — the editor's `paragraphSpacingBefore`.
    private func headingLead(_ level: Int) -> CGFloat {
        switch level {
        case 1: return DS.lg
        case 2, 3: return DS.md
        default: return DS.sm
        }
    }

    // MARK: - Inline

    /// Inline emphasis via Markdown, falling back to plain text if it doesn't parse.
    ///
    /// Bold and italic come out of the parse already painted. Code spans, links and
    /// `~~strike~~` do not — they arrive as *intent* with no appearance attached, which
    /// is why they used to render as undecorated prose here while the editor gave all
    /// three a look. Their styling is spelled out below to match it.
    private func inline(_ s: String) -> Text {
        guard var attributed = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return Text(s)
        }

        // Ranges are gathered before anything is written: writing an attribute
        // re-partitions the runs, and mutating mid-enumeration walks a stale view.
        var code: [Range<AttributedString.Index>] = []
        var struck: [Range<AttributedString.Index>] = []
        var links: [Range<AttributedString.Index>] = []
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { code.append(run.range) }
                if intent.contains(.strikethrough) { struck.append(run.range) }
            }
            if run.link != nil { links.append(run.range) }
        }

        for range in code {
            attributed[range].font = DS.codeFont
            attributed[range].foregroundColor = DS.inkDim
        }
        for range in struck {
            attributed[range].strikethroughStyle = Text.LineStyle.single
            attributed[range].foregroundColor = DS.inkDim
        }
        for range in links {
            // Tobacco and underlined, as in the editor. Set explicitly rather than left
            // to SwiftUI's link colour, which follows the tint and would drift the day
            // a view forgets `.mullChrome()`.
            attributed[range].foregroundColor = DS.moon
            attributed[range].underlineStyle = Text.LineStyle.single
        }
        return Text(attributed)
    }
}

// MARK: - Line parsing

/// One rendered unit of a document. Most map to a single line; quotes and fenced code
/// span as many as they need, so the bar beside a quote and the panel behind a block
/// are drawn once rather than once per line.
///
/// The classifiers below are the shared half of the two renderers — the same rules the
/// editor's highlighter applies through regex, expressed over `String` so a view can use
/// them. Kept non-private for that reason: `MarkdownTextEditor` could hand its line
/// ranges through here instead of carrying a second, silently diverging set of patterns.
struct MarkdownBlock: Identifiable {
    let id: Int
    let kind: Kind

    enum Kind {
        case blank
        case frontMatter(pairs: [(key: String, value: String)])
        case title(String)
        case heading(level: Int, text: String)
        case rule
        case code(lines: [String])
        case quote(lines: [String])
        case task(done: Bool, text: String, indent: Int)
        case bullet(text: String, indent: Int)
        case ordered(marker: String, text: String, indent: Int)
        case paragraph(String)
    }

    /// One pass over the document. The classification order mirrors the editor's
    /// `styleLine` — heading, then title, then the block prefixes — so a line that both
    /// renderers see resolves to the same construct in each.
    static func parse(_ text: String, titleFirstLine: Bool) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        /// The title is the *first* non-empty line and nothing else; once any content
        /// line has been seen the offer is withdrawn, whatever that line turned out to be.
        var titleAvailable = titleFirstLine
        var i = 0

        func emit(_ kind: Kind) {
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind))
        }

        // Front matter, if the document opens with it. Consumed before anything
        // else so its `---` is not mistaken for a horizontal rule and its `key:
        // value` lines are not shown as prose — which is what mull's own preview
        // did to every generated file the moment the metadata moved up here.
        // The title offer survives: the H1 is still the first *content* line.
        if let matter = frontMatter(lines) {
            // `generator` is dropped here rather than in the view, so a file whose
            // front matter is *only* the stamp emits no block at all instead of an
            // empty one that still pays for its padding. It exists so
            // `MarkdownDoc.isGeneratedByMull` can tell mull's own writing from the
            // user's when it comes back around through the clipboard, which is a
            // fact about the file and not about the work.
            let shown = matter.pairs.filter { $0.key != "generator" }
            if !shown.isEmpty { emit(.frontMatter(pairs: shown)) }
            i = matter.end
        }

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                emit(.blank)
                i += 1
                continue
            }

            let isTitle = titleAvailable
            titleAvailable = false

            if isFence(trimmed) {
                // An unterminated fence runs to the end of the document, which is what
                // the editor does too — a block you are half-way through writing keeps
                // its panel rather than flickering back into prose.
                var body: [String] = []
                i += 1
                while i < lines.count {
                    if isFence(lines[i].trimmingCharacters(in: .whitespaces)) {
                        i += 1
                        break
                    }
                    body.append(lines[i])
                    i += 1
                }
                emit(.code(lines: body))
                continue
            }

            if let h = heading(trimmed) {
                emit(.heading(level: h.level, text: h.text))
                i += 1
                continue
            }

            if isTitle {
                emit(.title(trimmed))
                i += 1
                continue
            }

            if quoteBody(trimmed) != nil {
                var body: [String] = []
                while i < lines.count,
                      let line = quoteBody(lines[i].trimmingCharacters(in: .whitespaces)) {
                    body.append(line)
                    i += 1
                }
                emit(.quote(lines: body))
                continue
            }

            let indent = indentLevel(raw)

            if let task = checkbox(trimmed) {
                emit(.task(done: task.done, text: task.text, indent: indent))
            } else if let bullet = bullet(trimmed) {
                emit(.bullet(text: bullet, indent: indent))
            } else if let ordered = ordered(trimmed) {
                emit(.ordered(marker: ordered.marker, text: ordered.text, indent: indent))
            } else if isRule(trimmed) {
                emit(.rule)
            } else {
                emit(.paragraph(raw))
            }
            i += 1
        }

        return blocks
    }

    // MARK: Line classifiers

    /// A leading YAML front-matter block: `---`, `key: "value"` lines, `---`.
    /// Only at the very top — a `---` anywhere else is a horizontal rule.
    /// Returns the parsed pairs and the index of the first line after it.
    static func frontMatter(_ lines: [String]) -> (pairs: [(key: String, value: String)], end: Int)? {
        var start = 0
        while start < lines.count, lines[start].trimmingCharacters(in: .whitespaces).isEmpty { start += 1 }
        guard start < lines.count,
              lines[start].trimmingCharacters(in: .whitespaces) == MarkdownDoc.fence,
              let close = (start + 1..<lines.count).first(where: {
                  lines[$0].trimmingCharacters(in: .whitespaces) == MarkdownDoc.fence
              })
        else { return nil }

        let pairs: [(key: String, value: String)] = lines[(start + 1)..<close].compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return (key: parts[0].trimmingCharacters(in: .whitespaces),
                    value: value.replacingOccurrences(of: "\\\"", with: "\""))
        }
        return (pairs, close + 1)
    }

    /// Both fence spellings, and either one closes either one — matching the editor's
    /// fence scan, which is prefix-based for the same reason: a mismatched pair in a
    /// half-written note should end the block rather than swallow the rest of the file.
    static func isFence(_ s: String) -> Bool {
        s.hasPrefix("```") || s.hasPrefix("~~~")
    }

    static func heading(_ s: String) -> (level: Int, text: String)? {
        guard s.hasPrefix("#") else { return nil }
        var level = 0
        var idx = s.startIndex
        while idx < s.endIndex, s[idx] == "#", level < 6 {
            level += 1; idx = s.index(after: idx)
        }
        guard idx < s.endIndex, s[idx] == " " else { return nil }
        return (level, String(s[idx...]).trimmingCharacters(in: .whitespaces))
    }

    static func quoteBody(_ s: String) -> String? {
        guard s.hasPrefix(">") else { return nil }
        return String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    static func checkbox(_ s: String) -> (done: Bool, text: String)? {
        for marker in ["- ", "* "] where s.hasPrefix(marker) {
            let rest = String(s.dropFirst(marker.count))
            if rest.hasPrefix("[ ] ") { return (false, String(rest.dropFirst(4))) }
            if rest.lowercased().hasPrefix("[x] ") { return (true, String(rest.dropFirst(4))) }
        }
        return nil
    }

    static func bullet(_ s: String) -> String? {
        for marker in ["- ", "* "] where s.hasPrefix(marker) {
            return String(s.dropFirst(marker.count))
        }
        return nil
    }

    /// `1. text` — the marker is returned verbatim so the rendered number is the one
    /// in the file.
    static func ordered(_ s: String) -> (marker: String, text: String)? {
        var idx = s.startIndex
        var digits = 0
        while idx < s.endIndex, s[idx].isNumber {
            digits += 1; idx = s.index(after: idx)
        }
        guard digits > 0, idx < s.endIndex, s[idx] == "." else { return nil }
        let afterDot = s.index(after: idx)
        guard afterDot < s.endIndex, s[afterDot] == " " || s[afterDot] == "\t" else { return nil }
        return (String(s[s.startIndex...idx]),
                String(s[afterDot...]).trimmingCharacters(in: .whitespaces))
    }

    /// `---` / `***` / `___`, three or more of one character with optional spaces
    /// between. Checked after the list prefixes, as in the editor, so `- - -` reads as
    /// the list it also is.
    static func isRule(_ s: String) -> Bool {
        let marks = s.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// Nesting depth of a list line, one level per two leading spaces (a tab counts as
    /// four). The editor indents by raw space count; rounding to levels here keeps the
    /// reader on the 4px grid while landing within a point or two of it at every depth
    /// people actually nest to.
    static func indentLevel(_ line: String) -> Int {
        var spaces = 0
        for c in line {
            if c == " " { spaces += 1 } else if c == "\t" { spaces += 4 } else { break }
        }
        return spaces / 2
    }
}
