import SwiftUI
import AppKit

/// The *writing* surface — Bear-style live markdown decoration.
///
/// Where `MarkdownView` is the read-only display layer, this is what mull shows when
/// you actually edit a note. It wraps an `NSTextView` and re-styles the buffer on every
/// edit: headings grow, `**bold**` goes bold, `` `code` `` turns mono on a tint, quotes
/// dim, list markers catch moonlight — yet the *markers stay visible* and the bytes on
/// disk never change. This is the crucial difference from Notion-style WYSIWYG (a mull
/// non-feature): we decorate plain markdown, we do not hide its syntax. `textView.string`
/// is always the literal file text, so round-trip safety (原則6) and MCP/git portability
/// are untouched — only the on-screen appearance is enriched.
///
/// Decoration is attribute-only and re-applied over the whole document on each change
/// (mull's files are small — hundreds of lines — so a full pass per keystroke is cheap;
/// a soft cap skips the heavy regex on pathologically large buffers).
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // Build the TextKit 1 stack by hand so we can install our own layout manager —
        // the thing that draws code panels, quote bars and rules behind the glyphs.
        // (scrollableTextView()'s default stack gives us no hook for that.)
        let storage = NSTextStorage()
        let layoutManager = MarkdownLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        // Plain-markdown discipline: attributes are ours to set, but the *characters*
        // must stay exactly what the user typed. Kill every macOS auto-substitution that
        // would silently rewrite markdown punctuation (" → “, -- → —, ... → …).
        textView.isRichText = true               // we need per-run attributes…
        textView.importsGraphics = false         // …but never images / RTF paste fidelity
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false

        // ⌘F inside a note. The whole pitch is that these md files are the product,
        // and until now finding a word in an open one was simply not possible — the
        // keystroke did nothing at all, which in an app whose sidebar offers a
        // cross-file search reads as "the app is broken" rather than "that feature
        // isn't here". The find bar is AppKit's own, so ⌘F / ⌘G / ⌘E all work and
        // it matches every other macOS text view the user knows.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Nocturne surface: transparent so DS.canvas shows through; moonlight caret.
        textView.drawsBackground = false
        textView.insertionPointColor = MD.moon
        textView.selectedTextAttributes = [.backgroundColor: MD.moon.withAlphaComponent(0.25)]
        textView.textContainerInset = NSSize(width: 0, height: DS.sm)
        textView.textContainer?.lineFragmentPadding = 0
        textView.font = MD.body
        textView.typingAttributes = MD.baseAttributes

        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        context.coordinator.textView = textView

        textView.string = text   // triggers the storage delegate → first highlight pass
        layoutManager.activeParagraph = (text as NSString).paragraphRange(for: NSRange(location: 0, length: 0))

        // Opening a note means you want to type: hand the editor keyboard focus, so the
        // first keystrokes don't fall into the sidebar as type-ahead selection jumps.
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // NEVER overwrite while the user is editing. The binding lags the view by a
        // runloop turn (and during IME composition the marked text isn't in the binding
        // at all), while ancestor re-renders arrive constantly (AppState refreshes every
        // 3s) — comparing strings here and "fixing" the difference was wiping freshly
        // typed characters and destroying in-flight Japanese conversions. Programmatic
        // content changes (file switch) recreate this view via .id(file), so the only
        // sync needed here is for external changes while the editor is NOT being used.
        //
        // Consequence: while the editor HAS focus, an external write (MCP write_note,
        // Obsidian) is deliberately not reflected here — the buffer goes stale rather
        // than risk eating a keystroke. The save path is what protects that file: it
        // compares the on-disk modification date against the one captured at load and
        // refuses to overwrite a file that moved underneath it (FullWindowView.saveFile).
        let isEditing = textView.window?.firstResponder === textView
        if !isEditing, !textView.hasMarkedText(), textView.string != text {
            textView.string = text
            if let lm = textView.layoutManager as? MarkdownLayoutManager {
                lm.activeParagraph = (text as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownTextEditor
        /// Needed to ask `hasMarkedText()` from the storage delegate (which has no view).
        weak var textView: NSTextView?

        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        /// Reveal-on-cursor: when the caret crosses into a new paragraph, reveal that
        /// paragraph's raw markers and re-conceal the one we left. We only flip glyphs for
        /// the two affected lines, so moving the caret is cheap and doesn't reflow the doc.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView,
                  let lm = tv.layoutManager as? MarkdownLayoutManager,
                  let storage = tv.textStorage else { return }
            // Selection shifts constantly during IME composition; leave glyphs alone until
            // the text is committed so we don't flicker the candidate window's underline.
            if tv.hasMarkedText() { return }
            let para = (storage.string as NSString).paragraphRange(for: tv.selectedRange())
            guard !NSEqualRanges(para, lm.activeParagraph) else { return }
            let previous = lm.activeParagraph
            lm.activeParagraph = para
            for range in [previous, para] where range.location != NSNotFound && NSMaxRange(range) <= storage.length {
                lm.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
                lm.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            }
            tv.needsDisplay = true
        }

        /// The syntax-highlight hook. Fires after each edit; we only re-style when the
        /// *characters* changed (attribute-only edits are our own work — ignore them to
        /// avoid re-entrancy). Changing attributes here is supported by NSTextStorage.
        func textStorage(_ textStorage: NSTextStorage,
                         didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange,
                         changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            // Never restyle mid-IME-composition: touching attributes (or concealing glyphs)
            // under marked text disrupts the conversion candidates / underline. The commit
            // is itself an edit, so highlighting resumes the moment composition finalises.
            if textView?.hasMarkedText() == true { return }
            MarkdownHighlighter.highlight(textStorage, editedRange: editedRange)
        }
    }
}

// MARK: - Custom attributes
//
// The highlighter tags ranges with these so the layout manager knows what block
// background to paint. They carry no visual attributes themselves — they're purely a
// channel from the (text-only) highlighter to the (geometry-aware) layout manager.
private extension NSAttributedString.Key {
    static let mdCodeBlock = NSAttributedString.Key("mull.mdCodeBlock")
    static let mdInlineCode = NSAttributedString.Key("mull.mdInlineCode")
    static let mdBlockquote = NSAttributedString.Key("mull.mdBlockquote")
    static let mdRule = NSAttributedString.Key("mull.mdRule")
    /// Syntax punctuation (`#`, `**`, `` ` ``, `[`…`](url)`) that should collapse to
    /// zero width unless the caret is on its line — Bear's reveal-on-cursor concealment.
    static let mdConceal = NSAttributedString.Key("mull.mdConceal")
}

// MARK: - Layout manager (block backgrounds)
//
// TextKit can't paint a padded, rounded panel behind a code block, a bar beside a quote
// or a rule for a `---` — `.backgroundColor` only fills behind glyphs, leaving a jagged
// edge with no breathing room. So we drop to the layout manager and draw those block
// decorations ourselves, behind the text, keyed off the custom attributes above.
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {

    /// The paragraph the caret is in. Concealed markers inside it are *revealed* (Bear
    /// shows you the raw syntax of the line you're editing); everywhere else they collapse.
    var activeParagraph = NSRange(location: NSNotFound, length: 0)

    override init() {
        super.init()
        delegate = self
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    // Glyph generation hook: collapse `.mdConceal` runs to zero-width null glyphs, except
    // on the active paragraph. This is what actually *hides* the `#`/`**`/backticks rather
    // than just dimming them — and it reflows the line so heading text sits at the margin.
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>,
                       font: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        let count = glyphRange.length
        guard let storage = textStorage else {
            layoutManager.setGlyphs(glyphs, properties: properties, characterIndexes: characterIndexes,
                                    font: font, forGlyphRange: glyphRange)
            return count
        }
        var props = Array(UnsafeBufferPointer(start: properties, count: count))
        for i in 0..<count {
            let charIndex = characterIndexes[i]
            guard charIndex < storage.length else { continue }
            if storage.attribute(.mdConceal, at: charIndex, effectiveRange: nil) != nil,
               !NSLocationInRange(charIndex, activeParagraph) {
                props[i] = .null
            }
        }
        // An empty glyph range yields a nil baseAddress — force-unwrapping it crashed
        // on the zero-length ranges the layout manager legitimately asks about.
        props.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            layoutManager.setGlyphs(glyphs, properties: base, characterIndexes: characterIndexes,
                                    font: font, forGlyphRange: glyphRange)
        }
        return count
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first {
            let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            drawCodeBlocks(storage, chars, origin, container)
            drawInlineCode(storage, chars, origin, container)
            drawBlockquotes(storage, chars, origin, container)
            drawRules(storage, chars, origin, container)
        }
        // Selection highlight (drawn by super) sits *above* our panels.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    // Full-measure rounded panel spanning every line of a fenced block.
    private func drawCodeBlocks(_ s: NSTextStorage, _ range: NSRange, _ origin: NSPoint, _ container: NSTextContainer) {
        s.enumerateAttribute(.mdCodeBlock, in: range, options: []) { value, sub, _ in
            guard value != nil else { return }
            let rects = enclosingRects(forCharRange: sub, origin: origin, container: container)
            guard let minY = rects.map(\.minY).min(), let maxY = rects.map(\.maxY).max() else { return }
            let width = container.size.width
            let panel = NSRect(x: origin.x, y: minY - 5, width: width, height: (maxY - minY) + 10)
            let path = NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8)
            MD.codePanelFill.setFill(); path.fill()
            MD.codePanelStroke.setStroke(); path.lineWidth = 0.75; path.stroke()
        }
    }

    // A small rounded chip per line fragment behind inline `code`.
    private func drawInlineCode(_ s: NSTextStorage, _ range: NSRange, _ origin: NSPoint, _ container: NSTextContainer) {
        s.enumerateAttribute(.mdInlineCode, in: range, options: []) { value, sub, _ in
            guard value != nil else { return }
            for r in enclosingRects(forCharRange: sub, origin: origin, container: container) {
                let chip = NSRect(x: r.minX - 3, y: r.minY + 1.5, width: r.width + 6, height: r.height - 3)
                let path = NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4)
                MD.codeChipFill.setFill(); path.fill()
            }
        }
    }

    // A single continuous moonlight bar down the left of a (possibly multi-line) quote.
    private func drawBlockquotes(_ s: NSTextStorage, _ range: NSRange, _ origin: NSPoint, _ container: NSTextContainer) {
        s.enumerateAttribute(.mdBlockquote, in: range, options: []) { value, sub, _ in
            guard value != nil else { return }
            let rects = enclosingRects(forCharRange: sub, origin: origin, container: container)
            guard let minY = rects.map(\.minY).min(), let maxY = rects.map(\.maxY).max() else { return }
            let bar = NSRect(x: origin.x + 2, y: minY + 1, width: 3, height: (maxY - minY) - 2)
            let path = NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5)
            MD.quoteBar.setFill(); path.fill()
        }
    }

    // A real hairline rule across the measure, vertically centred in the `---` line.
    private func drawRules(_ s: NSTextStorage, _ range: NSRange, _ origin: NSPoint, _ container: NSTextContainer) {
        s.enumerateAttribute(.mdRule, in: range, options: []) { value, sub, _ in
            guard value != nil else { return }
            for r in enclosingRects(forCharRange: sub, origin: origin, container: container) {
                let y = (r.minY + r.maxY) / 2
                let path = NSBezierPath()
                path.move(to: NSPoint(x: origin.x, y: y))
                path.line(to: NSPoint(x: origin.x + container.size.width, y: y))
                path.lineWidth = 1
                MD.ruleColor.setStroke(); path.stroke()
            }
        }
    }

    /// One rect per line fragment covered by `charRange`, in view coordinates.
    func enclosingRects(forCharRange charRange: NSRange, origin: NSPoint, container: NSTextContainer) -> [NSRect] {
        let glyphRange = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var rects: [NSRect] = []
        enumerateEnclosingRects(forGlyphRange: glyphRange,
                                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                in: container) { rect, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
    }
}

// MARK: - Palette (AppKit mirror of DS, nocturne)

/// AppKit twins of the `DS` tokens, DERIVED from them (not hardcoded) so a palette
/// change in DesignTokens propagates here — hardcoding the old nocturne values left
/// white ink on the warm ivory canvas (invisible text).
private enum MD {
    static let ink = NSColor(DS.ink)
    static let inkDim = NSColor(DS.inkDim)
    static let inkFaint = NSColor(DS.inkFaint)
    static let moon = NSColor(DS.moon)
    static let moonDim = NSColor(DS.moonDim)
    static let codeInk = NSColor(DS.ink).withAlphaComponent(0.85)
    static let codePanelFill = NSColor(DS.ink).withAlphaComponent(0.05)
    static let codePanelStroke = NSColor(DS.ink).withAlphaComponent(0.10)
    static let codeChipFill = NSColor(DS.ink).withAlphaComponent(0.08)
    static let quoteBar = NSColor(DS.moon).withAlphaComponent(0.55)
    static let ruleColor = NSColor(DS.ink).withAlphaComponent(0.18)

    static let bodySize: CGFloat = 15
    static let body = NSFont.systemFont(ofSize: bodySize)
    static let mono = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    static func heading(_ level: Int) -> NSFont {
        switch level {
        case 1: return NSFont.systemFont(ofSize: 22, weight: .bold)
        case 2: return NSFont.systemFont(ofSize: 17, weight: .semibold)
        case 3: return NSFont.systemFont(ofSize: 15, weight: .semibold)
        default: return NSFont.systemFont(ofSize: 14, weight: .semibold)
        }
    }

    static let titleFont = NSFont.systemFont(ofSize: 22, weight: .bold)

    /// One factory for every block's paragraph metrics. `lineHeight` is a *multiple* of
    /// the font's natural line height, so leading scales with type size (a 22pt heading
    /// and 15pt body that share a multiple stay proportionally spaced — the fix for the
    /// "all lines share one fixed gap" look). `after`/`before` are the gaps below/above
    /// the block; `firstHead`/`head` give lists their hanging indent (marker at `firstHead`,
    /// wrapped lines at `head`); `tail` (negative) is the right inset for code panels.
    static func paragraph(lineHeight: CGFloat = 1.35, before: CGFloat = 0, after: CGFloat = 0,
                          firstHead: CGFloat = 0, head: CGFloat = 0, tail: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = lineHeight
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.firstLineHeadIndent = firstHead
        p.headIndent = head
        p.tailIndent = tail
        return p
    }

    // Vertical rhythm: large type wants a *tighter* multiple (big fonts already carry
    // generous intrinsic leading), body opens up to ~1.4 for readability, code sits
    // snug. Headings also open more air above as they grow.
    static let bodyParagraph = paragraph(lineHeight: 1.4, after: 8)
    static let titleParagraph = paragraph(lineHeight: 1.1, after: 12)
    static func headingParagraph(_ level: Int) -> NSParagraphStyle {
        switch level {
        case 1: return paragraph(lineHeight: 1.1, before: 20, after: 8)
        case 2: return paragraph(lineHeight: 1.15, before: 16, after: 6)
        case 3: return paragraph(lineHeight: 1.2, before: 12, after: 4)
        default: return paragraph(lineHeight: 1.25, before: 10, after: 4)
        }
    }
    static func listParagraph(indent: CGFloat) -> NSParagraphStyle {
        paragraph(lineHeight: 1.4, after: 2, firstHead: indent, head: indent + 18)   // 18 ≈ "- " / "1. " width
    }
    static let blockquoteParagraph = paragraph(lineHeight: 1.4, after: 2, firstHead: 18, head: 18)
    static let ruleParagraph = paragraph(before: 10, after: 10)
    static func codeParagraph(before: CGFloat = 0, after: CGFloat = 0) -> NSParagraphStyle {
        paragraph(lineHeight: 1.3, before: before, after: after, firstHead: 12, head: 12, tail: -12)
    }

    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: body,
        .foregroundColor: ink,
        .paragraphStyle: bodyParagraph,
    ]
}

// MARK: - Highlighter

/// Stateless markdown → attributes mapper. Re-applies the full decoration set over a
/// text storage in one pass: reset to base, mark code regions (so their punctuation is
/// never re-interpreted), style each line as a block, then layer inline emphasis.
private enum MarkdownHighlighter {

    /// Above this many characters we only lay down the base font and bail — the regex
    /// passes aren't worth the per-keystroke cost on a buffer that large (and mull's real
    /// files never approach it).
    private static let heavyPassCap = 200_000

    /// Restyle the document. With no `editedRange` (initial load, file switch) the whole
    /// buffer is processed; with one, the regex/attribute passes are confined to the
    /// touched paragraph(s) — the expensive part is proportional to the edited line.
    ///
    /// Fence detection is NOT: `fencedCodeRanges` still walks every line of the buffer on
    /// each call, because whether the edited paragraph sits inside a ``` block can only be
    /// answered from the fences above it. It's a single line enumeration with a prefix
    /// test — cheap next to the styling passes it scopes — but it is O(buffer), so the
    /// per-keystroke cost is not purely proportional to the line. `heavyPassCap` is what
    /// bounds the rest. `editedRange` is the post-edit range reported by the text storage.
    static func highlight(_ storage: NSTextStorage, editedRange: NSRange? = nil) {
        let ns = storage.string as NSString
        let docRange = NSRange(location: 0, length: ns.length)
        let fenced = fencedCodeRanges(ns)
        let dirty = dirtyRange(ns, editedRange: editedRange, docRange: docRange, fenced: fenced)

        storage.setAttributes(MD.baseAttributes, range: dirty)
        guard ns.length <= heavyPassCap else { return }
        styleRange(storage, ns, dirty, fenced: fenced)
    }

    /// The span to restyle for an edit: the paragraph(s) it touches, widened to swallow any
    /// fenced block it overlaps. A typed/removed fence marker flips everything below it, so
    /// in that one case we extend to end-of-document — still far cheaper than a full pass on
    /// every ordinary keystroke.
    private static func dirtyRange(_ ns: NSString, editedRange: NSRange?, docRange: NSRange, fenced: [NSRange]) -> NSRange {
        guard let edited = editedRange else { return docRange }
        let loc = min(edited.location, ns.length)
        let len = min(edited.length, ns.length - loc)
        var dirty = ns.paragraphRange(for: NSRange(location: loc, length: len))
        for f in fenced where NSIntersectionRange(f, dirty).length > 0 {
            dirty = NSUnionRange(dirty, f)
        }
        let touched = ns.substring(with: dirty)
        if touched.contains("```") || touched.contains("~~~") {
            dirty = NSRange(location: dirty.location, length: ns.length - dirty.location)
        }
        return dirty
    }

    /// Apply the full decoration set within `range` (assumed paragraph-aligned). Inline
    /// constructs never cross a paragraph, so paragraph-aligned scoping keeps them correct.
    private static func styleRange(_ storage: NSTextStorage, _ ns: NSString, _ range: NSRange, fenced: [NSRange]) {
        // 1. Code regions. The panel / chip backgrounds are painted by the layout manager;
        //    here we set mono text and tag the range. Fenced blocks overlapping `range` were
        //    pulled fully inside it by dirtyRange, so they style end-to-end.
        var protected: [NSRange] = []
        for r in fenced where NSIntersectionRange(r, range).length > 0 {
            storage.addAttributes([.font: MD.mono, .foregroundColor: MD.codeInk,
                                   .mdCodeBlock: true], range: r)
            applyCodeParagraphs(storage, ns, r)
            protected.append(r)
        }
        forEachMatch(inlineCode, in: ns, range: range) { m in
            let r = m.range
            if intersects(protected, r) { return }
            storage.addAttributes([.font: MD.mono, .foregroundColor: MD.codeInk,
                                   .mdInlineCode: true], range: r)
            conceal(storage, NSRange(location: r.location, length: 1))
            conceal(storage, NSRange(location: r.location + r.length - 1, length: 1))
            protected.append(r)
        }

        // 2. Block-level: the first non-empty, non-heading line reads as the title
        //    (Crane: 1行目=タイトル); every other line is classified by its prefix.
        let titleRange = firstTitleLineRange(ns)
        ns.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            if fullyInside(protected, lineRange) { return }
            let line = ns.substring(with: lineRange)
            styleLine(storage, line: line, base: lineRange.location, isTitle: NSEqualRanges(lineRange, titleRange))
        }

        // 3. Inline emphasis, layered over everything except code.
        emphasize(storage, ns, range, regex: boldStar, markerLen: 2, protected: protected) { s, r in
            addTrait(s, r, .boldFontMask)
        }
        emphasize(storage, ns, range, regex: boldUnder, markerLen: 2, protected: protected) { s, r in
            addTrait(s, r, .boldFontMask)
        }
        emphasize(storage, ns, range, regex: italicStar, markerLen: 1, protected: protected) { s, r in
            addTrait(s, r, .italicFontMask)
        }
        emphasize(storage, ns, range, regex: italicUnder, markerLen: 1, protected: protected) { s, r in
            addTrait(s, r, .italicFontMask)
        }
        emphasize(storage, ns, range, regex: strike, markerLen: 2, protected: protected) { s, r in
            s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            s.addAttribute(.strikethroughColor, value: MD.inkDim, range: r)
        }
        styleLinks(storage, ns, range, protected: protected)
    }

    // MARK: Block lines

    private static func styleLine(_ s: NSTextStorage, line: String, base: Int, isTitle: Bool) {
        // Heading — `#…###### text`. Whole line takes the heading font (so the markers
        // sit at the same size, just dimmed) and a touch of space above.
        if let m = firstMatch(heading, line) {
            let level = m.range(at: 1).length
            let lineRange = NSRange(location: base, length: (line as NSString).length)
            s.addAttribute(.font, value: MD.heading(level), range: lineRange)
            s.addAttribute(.paragraphStyle, value: MD.headingParagraph(level), range: lineRange)
            conceal(s, shift(unionRange(m, 1, 2), by: base))   // hide the #'s and their space
            return
        }
        if isTitle {
            let lineRange = NSRange(location: base, length: (line as NSString).length)
            s.addAttribute(.font, value: MD.titleFont, range: lineRange)
            s.addAttribute(.paragraphStyle, value: MD.titleParagraph, range: lineRange)
            return
        }
        // Blockquote — `> text`: dim italic body, marker faint, indented for its bar
        // (the bar itself is painted by the layout manager off the .mdBlockquote tag).
        if let m = firstMatch(blockquote, line) {
            let lineRange = NSRange(location: base, length: (line as NSString).length)
            s.addAttribute(.paragraphStyle, value: MD.blockquoteParagraph, range: lineRange)
            s.addAttribute(.mdBlockquote, value: true, range: lineRange)
            conceal(s, shift(m.range(at: 1), by: base))   // hide `> `; the bar stands in for it
            let content = shift(m.range(at: 2), by: base)
            s.addAttribute(.foregroundColor, value: MD.inkDim, range: content)
            addTrait(s, content, .italicFontMask)
            return
        }
        // Task list — `- [ ] / - [x]`: marker faint, box accented, done items struck.
        if let m = firstMatch(task, line) {
            listIndent(s, line, base)
            dim(s, shift(unionRange(m, 1, 3), by: base))     // bullet + spaces
            let box = shift(m.range(at: 2), by: base)
            let content = shift(m.range(at: 4), by: base)
            let done = line.range(of: "[x]", options: .caseInsensitive) != nil
            s.addAttribute(.foregroundColor, value: done ? MD.moon : MD.inkDim, range: box)
            if done {
                s.addAttribute(.foregroundColor, value: MD.inkDim, range: content)
                s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
                s.addAttribute(.strikethroughColor, value: MD.inkFaint, range: content)
            }
            return
        }
        // Bullet — `- / *`: just tint the marker glyph with moonlight.
        if let m = firstMatch(bullet, line) {
            listIndent(s, line, base)
            s.addAttribute(.foregroundColor, value: MD.moonDim, range: shift(m.range(at: 2), by: base))
            return
        }
        // Ordered — `1.`: tint the number.
        if let m = firstMatch(ordered, line) {
            listIndent(s, line, base)
            s.addAttribute(.foregroundColor, value: MD.moonDim, range: shift(m.range(at: 2), by: base))
            return
        }
        // Horizontal rule — `---` / `***` / `___`: hide the dashes and let the layout
        // manager draw a real hairline rule (off the .mdRule tag).
        if firstMatch(hr, line) != nil {
            let lineRange = NSRange(location: base, length: (line as NSString).length)
            s.addAttribute(.mdRule, value: true, range: lineRange)
            s.addAttribute(.foregroundColor, value: NSColor.clear, range: lineRange)
            s.addAttribute(.paragraphStyle, value: MD.ruleParagraph, range: lineRange)
            return
        }
    }

    /// Indent a list line so wrapped text hangs under the content, not the marker.
    private static func listIndent(_ s: NSTextStorage, _ line: String, _ base: Int) {
        var spaces = 0
        for c in line {
            if c == " " { spaces += 1 } else if c == "\t" { spaces += 4 } else { break }
        }
        let indent = CGFloat(spaces) * 7   // ≈ one space width at 15pt
        s.addAttribute(.paragraphStyle, value: MD.listParagraph(indent: indent),
                       range: NSRange(location: base, length: (line as NSString).length))
    }

    /// Code lines get the panel's interior padding everywhere, plus a gap above the first
    /// line and below the last so the panel stands clear of surrounding prose.
    private static func applyCodeParagraphs(_ s: NSTextStorage, _ ns: NSString, _ range: NSRange) {
        s.addAttribute(.paragraphStyle, value: MD.codeParagraph(), range: range)
        let firstLine = ns.lineRange(for: NSRange(location: range.location, length: 0))
        let lastLine = ns.lineRange(for: NSRange(location: max(range.location, NSMaxRange(range) - 1), length: 0))
        if NSEqualRanges(firstLine, lastLine) {
            s.addAttribute(.paragraphStyle, value: MD.codeParagraph(before: 8, after: 8),
                           range: NSIntersectionRange(firstLine, range))
        } else {
            s.addAttribute(.paragraphStyle, value: MD.codeParagraph(before: 8),
                           range: NSIntersectionRange(firstLine, range))
            s.addAttribute(.paragraphStyle, value: MD.codeParagraph(after: 8),
                           range: NSIntersectionRange(lastLine, range))
        }
    }

    // MARK: Inline emphasis

    private static func emphasize(_ s: NSTextStorage, _ ns: NSString, _ range: NSRange,
                                  regex: NSRegularExpression, markerLen: Int,
                                  protected: [NSRange],
                                  apply: (NSTextStorage, NSRange) -> Void) {
        forEachMatch(regex, in: ns, range: range) { m in
            let outer = m.range
            if intersects(protected, outer) { return }
            let inner = NSRange(location: outer.location + markerLen,
                                length: outer.length - 2 * markerLen)
            guard inner.length > 0 else { return }
            apply(s, inner)
            conceal(s, NSRange(location: outer.location, length: markerLen))
            conceal(s, NSRange(location: outer.location + outer.length - markerLen, length: markerLen))
        }
    }

    private static func styleLinks(_ s: NSTextStorage, _ ns: NSString, _ range: NSRange, protected: [NSRange]) {
        forEachMatch(link, in: ns, range: range) { m in
            let outer = m.range
            if intersects(protected, outer) { return }
            let label = m.range(at: 1)
            // Hide `[`, and the trailing `](url)`; keep only the label, styled as a link.
            conceal(s, NSRange(location: outer.location, length: label.location - outer.location))
            conceal(s, NSRange(location: NSMaxRange(label), length: NSMaxRange(outer) - NSMaxRange(label)))
            s.addAttribute(.foregroundColor, value: MD.moon, range: label)
            s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: label)
        }
    }

    // MARK: Attribute helpers

    /// Add a font trait (bold / italic) while preserving the run's existing size — so
    /// emphasis inside a heading stays heading-sized, not shrunk to body.
    private static func addTrait(_ s: NSTextStorage, _ range: NSRange, _ trait: NSFontTraitMask) {
        guard range.location >= 0, NSMaxRange(range) <= s.length else { return }
        s.enumerateAttribute(.font, in: range) { value, sub, _ in
            let f = (value as? NSFont) ?? MD.body
            let nf = NSFontManager.shared.convert(f, toHaveTrait: trait)
            s.addAttribute(.font, value: nf, range: sub)
        }
    }

    private static func dim(_ s: NSTextStorage, _ range: NSRange) {
        guard range.location >= 0, NSMaxRange(range) <= s.length else { return }
        s.addAttribute(.foregroundColor, value: MD.inkFaint, range: range)
    }

    /// Mark syntax punctuation for concealment: it collapses to nothing off the active
    /// line, and shows faint when the caret reveals it. The colour matters only while
    /// revealed; the layout manager hides the glyphs entirely otherwise.
    private static func conceal(_ s: NSTextStorage, _ range: NSRange) {
        guard range.location >= 0, NSMaxRange(range) <= s.length, range.length > 0 else { return }
        s.addAttribute(.mdConceal, value: true, range: range)
        s.addAttribute(.foregroundColor, value: MD.inkFaint, range: range)
    }

    // MARK: Code-region discovery

    /// Ranges spanned by ``` fenced ``` blocks, including the fence lines. Unterminated
    /// fences run to end-of-document (so styling tracks as you open a block).
    private static func fencedCodeRanges(_ ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var fenceStart: Int? = nil
        let full = NSRange(location: 0, length: ns.length)
        ns.enumerateSubstrings(in: full, options: [.byLines]) { sub, lineRange, enclosing, _ in
            let trimmed = (sub ?? "").trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return }
            if let start = fenceStart {
                ranges.append(NSRange(location: start, length: NSMaxRange(enclosing) - start))
                fenceStart = nil
            } else {
                fenceStart = lineRange.location
            }
        }
        if let start = fenceStart {
            ranges.append(NSRange(location: start, length: ns.length - start))
        }
        return ranges
    }

    private static func firstTitleLineRange(_ ns: NSString) -> NSRange {
        var result = NSRange(location: NSNotFound, length: 0)
        let full = NSRange(location: 0, length: ns.length)
        ns.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, lineRange, _, stop in
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            if !line.hasPrefix("#") { result = lineRange }
            stop.pointee = true   // only the first non-empty line is a candidate
        }
        return result
    }

    // MARK: Range utilities

    private static func intersects(_ ranges: [NSRange], _ r: NSRange) -> Bool {
        ranges.contains { NSIntersectionRange($0, r).length > 0 }
    }

    private static func fullyInside(_ ranges: [NSRange], _ r: NSRange) -> Bool {
        ranges.contains { $0.location <= r.location && NSMaxRange(r) <= NSMaxRange($0) }
    }

    private static func shift(_ r: NSRange, by offset: Int) -> NSRange {
        NSRange(location: r.location + offset, length: r.length)
    }

    /// The combined span of two capture groups (assumed adjacent), in match coordinates.
    private static func unionRange(_ m: NSTextCheckingResult, _ a: Int, _ b: Int) -> NSRange {
        NSUnionRange(m.range(at: a), m.range(at: b))
    }

    // MARK: Regex plumbing

    private static func firstMatch(_ regex: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
        let ns = line as NSString
        return regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
    }

    private static func forEachMatch(_ regex: NSRegularExpression, in ns: NSString,
                                     range: NSRange, _ body: (NSTextCheckingResult) -> Void) {
        regex.enumerateMatches(in: ns as String, range: range) { m, _, _ in
            if let m { body(m) }
        }
    }

    private static func re(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure is a programmer error.
        try! NSRegularExpression(pattern: pattern)
    }

    // Block patterns (matched per line).
    private static let heading = re(#"^(#{1,6})([ \t]+)\S?.*$"#)
    private static let blockquote = re(#"^([ \t]*>[ \t]?)(.*)$"#)
    private static let task = re(#"^([ \t]*[-*][ \t]+)(\[[ xX]\])([ \t]+)(.*)$"#)
    private static let bullet = re(#"^([ \t]*)([-*])([ \t]+)(.*)$"#)
    private static let ordered = re(#"^([ \t]*)(\d+\.)([ \t]+)(.*)$"#)
    private static let hr = re(#"^[ \t]*([-*_])[ \t]*(\1[ \t]*){2,}$"#)

    // Inline patterns (matched over the whole buffer; never span a line break).
    private static let boldStar = re(#"\*\*(?:[^*\n]|\*(?!\*))+\*\*"#)
    private static let boldUnder = re(#"__[^_\n]+__"#)
    private static let italicStar = re(#"(?<![\*\w])\*(?!\*)[^*\n]+?\*(?!\*)"#)
    private static let italicUnder = re(#"(?<![_\w])_(?!_)[^_\n]+?_(?!_)"#)
    private static let strike = re(#"~~[^~\n]+~~"#)
    private static let inlineCode = re("`[^`\\n]+`")
    private static let link = re(#"\[([^\]\n]+)\]\([^)\n]+\)"#)
}
