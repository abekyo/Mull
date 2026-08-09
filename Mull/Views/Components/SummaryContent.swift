import SwiftUI

/// Renders the body of a daily summary.
///
/// The summary arrives as markdown, because the understudy writes markdown (see
/// ReportWriter). It is rendered through `MarkdownView` — the same display layer
/// me.md/now.md/daily notes use — rather than dropped into a `Text`, which showed
/// `**bold**` and `## heading` with their syntax characters still attached.
struct SummaryContent: View {
    let summary: DailySummary

    /// Every section's text, in order — also the sample the language choice reads.
    private let joinedBody: String

    /// The heading language, decided once per body rather than per redraw, and with
    /// a deadband so a summary sitting near the threshold doesn't flip its headings
    /// between 午前 and Morning while the user is reading it (see `SectionLabels`).
    @State private var labels: SectionLabels
    /// Which day `labels` was decided for. The deadband is only meaningful within
    /// one summary; see the `onChange` below.
    @State private var labelledDay: Date

    init(summary: DailySummary) {
        self.summary = summary
        let body = Self.bodyText(of: summary)
        self.joinedBody = body
        // Decided in the initialiser, not in `body`: starting from a placeholder and
        // correcting it in .onAppear would show one frame of the wrong language.
        _labels = State(initialValue: SectionLabels.matching(body, previous: nil))
        _labelledDay = State(initialValue: summary.date)
    }

    private var sections: [(title: String, content: String)] {
        [(labels.morning, summary.morningSection),
         (labels.afternoon, summary.afternoonSection),
         (labels.evening, summary.eveningSection),
         (labels.learned, summary.learnings),
         (labels.inProgress, summary.inProgress)]
            .compactMap { title, content in
                guard let content,
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return (title, content)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            if sections.isEmpty {
                // A summary with nothing in it used to render as a zero-height card:
                // a heading floating over empty space, which reads as a broken app.
                // Say what happened instead — mull doesn't invent a day it didn't see.
                emptyState
            } else {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    SummarySection(title: section.title, content: section.content)
                }
            }
        }
        // The text can change under a live view (a re-run, a rewritten report).
        // Re-decide then, carrying the previous choice so the deadband applies.
        .onChange(of: joinedBody) { _, new in
            // A *different* day is a fresh look, not a rewrite. `@State` outlives
            // this struct wherever the parent reuses the view's identity for the
            // next summary, so carrying `labels` across unconditionally let one
            // day's language decide the next one's: step from an English day to a
            // Japanese one near the threshold and the higher hysteresis bar kept
            // English headings over Japanese prose — the exact mismatch the deadband
            // exists to prevent, caused by the deadband.
            let rewrite = labelledDay == summary.date
            labels = SectionLabels.matching(new, previous: rewrite ? labels : nil)
            labelledDay = summary.date
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            Text(labels.nothingRecorded)
                .font(DS.bodyFont)
                .foregroundStyle(DS.inkDim)
            Text(labels.nothingRecordedDetail)
                .font(DS.captionFont)
                .foregroundStyle(DS.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func bodyText(of summary: DailySummary) -> String {
        [summary.morningSection, summary.afternoonSection, summary.eveningSection,
         summary.learnings, summary.inProgress]
            .compactMap { $0 }
            .joined(separator: "\n")
    }
}

/// Section headings in the two languages mull's summaries are written in.
///
/// The summary is written in the language the user actually writes in (see
/// ReportWriter.dominantLanguage, which MullEngine's prompt uses). English headings
/// bolted onto Japanese prose read as a translation layer over someone else's
/// report, so the labels follow the text they label.
struct SectionLabels: Equatable {
    let isJapanese: Bool
    let morning, afternoon, evening, learned, inProgress: String
    let nothingRecorded, nothingRecordedDetail: String

    static let english = SectionLabels(
        isJapanese: false,
        morning: "Morning", afternoon: "Afternoon", evening: "Evening",
        learned: "Learned", inProgress: "In progress",
        nothingRecorded: "Nothing was written up for this day.",
        nothingRecordedDetail: "There wasn't enough recorded activity to write from. The day's events are still in Live and Calendar.")

    static let japanese = SectionLabels(
        isJapanese: true,
        morning: "午前", afternoon: "午後", evening: "夜",
        learned: "わかったこと", inProgress: "途中",
        nothingRecorded: "この日の記録はまとめられていません。",
        nothingRecordedDetail: "書くための材料が足りませんでした。その日のイベントは Live と Calendar に残っています。")

    /// The same crude, honest test ReportWriter uses: mostly CJK means Japanese.
    ///
    /// Two things it does that the earlier version didn't:
    ///
    /// 1. It compares like with like. The old test counted CJK *unicode scalars* and
    ///    divided by a *Character* count, so any emoji or combining sequence in the
    ///    body quietly moved the threshold.
    /// 2. It applies a deadband around the switch point. A body hovering near 25% CJK
    ///    — bilingual notes, Japanese prose carrying English identifiers, sit exactly
    ///    there — flipped its headings on every recomputation. Once a language has
    ///    been chosen it takes a clear move to unseat it.
    static func matching(_ text: String, previous: SectionLabels?) -> SectionLabels {
        let scalars = text.unicodeScalars
        let total = scalars.count
        guard total > 0 else { return previous ?? .english }

        let cjk = scalars.filter {
            (0x3040...0x30FF).contains($0.value)        // kana
                || (0x4E00...0x9FFF).contains($0.value) // CJK ideographs
        }.count
        let ratio = Double(cjk) / Double(total)

        switch previous?.isJapanese {
        case .some(true):  return ratio >= 0.15 ? .japanese : .english   // stay Japanese unless clearly not
        case .some(false): return ratio >= 0.35 ? .japanese : .english   // stay English unless clearly not
        case .none:        return ratio >= 0.25 ? .japanese : .english   // first look: the plain threshold
        }
    }
}

/// A labeled section of the summary. Renders whatever shape the text arrived in:
/// paragraphs as paragraphs, and lists only where the user's own writing (which the
/// summary imitates) actually used them. An earlier version put a dot in front of
/// every line, so a paragraph came back as a list of fragments and the report looked
/// like a status ticket no matter how it had been written.
///
/// The markdown itself is rendered by `MarkdownView`, the app's display layer. This
/// type's only job is to normalise line breaks first — joining the soft-wrapped lines
/// of one paragraph back together, while leaving list items, headings and quotes
/// standing on their own lines.
struct SummarySection: View {
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            // The ring-fragment as fleuron. The optional SF Symbol this replaced
            // was never passed by any caller — dead API pretending to be a design.
            HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                StippleMark(dot: 2.5)
                Text(title)
                    .sectionLabel()
            }

            MarkdownView(Self.normalized(content), titleFirstLine: false)
                .textSelection(.enabled)
        }
    }

    /// Rejoin soft-wrapped prose; keep every structural line standing on its own.
    ///
    /// The line-merging rule is why this exists: a numbered item ("1. Fixed the
    /// lexer") used to be treated as ordinary prose and glued onto the line above,
    /// producing "Shipped the parser 1. Fixed the lexer 2. Added tests". Anything
    /// that opens a block — any list marker, a heading, a quote, a table row, a
    /// fence — now breaks the paragraph instead of disappearing into it.
    static func normalized(_ content: String) -> String {
        var out: [String] = []
        var pending: [String] = []

        func flush() {
            let text = pending.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(text) }
            pending = []
        }

        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                flush()
                if let last = out.last, !last.isEmpty { out.append("") }  // one paragraph break, not five
            } else if isStructural(line) {
                flush()
                out.append(line)
            } else {
                pending.append(line)
            }
        }
        flush()

        while let last = out.last, last.isEmpty { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// True for any line that opens a markdown block rather than continuing a
    /// sentence: unordered bullets (including the full-width and typographic marks
    /// that appear in Japanese writing), ordered items (`1.` / `1)` / `１）`),
    /// headings, quotes, fences, tables and rules.
    private static func isStructural(_ line: String) -> Bool {
        guard let first = line.first else { return false }

        if "#>|".contains(first) { return true }
        if line.hasPrefix("```") || line.hasPrefix("---") || line.hasPrefix("___") { return true }

        // Unordered: a marker followed by a space.
        if "-*+•‣・".contains(first) {
            let rest = line.dropFirst()
            return rest.isEmpty || rest.first == " " || rest.first == "\u{3000}"
        }

        // Ordered: up to three digits (ASCII or full-width) then a . or ) then a space.
        var digits = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber, digits < 4 {
            digits += 1
            idx = line.index(after: idx)
        }
        guard digits > 0, digits <= 3, idx < line.endIndex else { return false }
        guard ".)．）、".contains(line[idx]) else { return false }
        let after = line.index(after: idx)
        // "12.5% faster" stays prose; "1. Fixed the lexer" is a list item.
        return after == line.endIndex || line[after] == " " || line[after] == "\u{3000}"
    }
}
