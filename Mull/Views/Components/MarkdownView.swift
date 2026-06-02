import SwiftUI

/// The display layer — Crane MD's "表示層" (設計思想 §エディタモデル) translated to mull.
///
/// Renders plain Markdown for *reading* (me.md, now.md, proactive.md, daily/…) with
/// the calm typography of a reading surface, NOT the dense dashboard. It is display
/// only: it parses a copy and never writes — so the file on disk stays byte-for-byte
/// what produced it (原則6). Editing still happens in a plain TextEditor; this is the
/// polished face mull shows when you're reading what it knows about you.
///
/// Line-based on purpose: a full CommonMark engine would be Crane-MD-level effort the
/// editor doesn't warrant. We cover the constructs that actually appear in mull's
/// files — title (1行目), `#`/`##`/`###`, `- [ ]`/`- [x]`, bullets, `>` quote — plus
/// inline `**bold**` / `*italic*` / `` `code` `` via AttributedString.
struct MarkdownView: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let lines = text.components(separatedBy: "\n")
            // The first non-empty line reads as the note's title (Crane: 1行目=タイトル),
            // unless it's already an explicit heading.
            let titleIdx = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                row(line, isTitleLine: idx == titleIdx && !line.hasPrefix("#"))
            }
        }
    }

    @ViewBuilder
    private func row(_ line: String, isTitleLine: Bool) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            Color.clear.frame(height: DS.readLineSpacing + 4)        // paragraph breathing
        } else if isTitleLine {
            inline(trimmed)
                .font(DS.readTitleFont)
                .foregroundStyle(DS.ink)
                .padding(.bottom, DS.sm)
        } else if let h = heading(trimmed) {
            inline(h.text)
                .font(h.level == 1 ? DS.readTitleFont : (h.level == 2 ? DS.readH2Font : DS.readH3Font))
                .foregroundStyle(DS.ink)
                .padding(.top, h.level == 1 ? DS.lg : DS.md)
                .padding(.bottom, DS.xs)
        } else if let task = checkbox(trimmed) {
            HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                Image(systemName: task.done ? "checkmark.square.fill" : "square")
                    .font(DS.readFont)
                    .foregroundStyle(task.done ? DS.moon : DS.inkFaint)
                inline(task.text)
                    .font(DS.readFont)
                    .foregroundStyle(task.done ? DS.inkDim : DS.ink)
                    .strikethrough(task.done, color: DS.inkFaint)
            }
            .padding(.vertical, 1)
        } else if let bullet = bullet(trimmed) {
            HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                Text("•").font(DS.readFont).foregroundStyle(DS.moonDim)
                inline(bullet).font(DS.readFont).foregroundStyle(DS.ink)
            }
            .padding(.vertical, 1)
        } else if trimmed.hasPrefix(">") {
            inline(String(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
                .font(DS.readFont)
                .foregroundStyle(DS.inkDim)
                .italic()
                .padding(.leading, DS.md)
                .overlay(alignment: .leading) {
                    Rectangle().fill(DS.hairline).frame(width: 2)
                }
                .padding(.vertical, 1)
        } else {
            inline(line)
                .font(DS.readFont)
                .foregroundStyle(DS.ink)
                .lineSpacing(DS.readLineSpacing)
        }
    }

    /// Inline emphasis via Markdown, falling back to plain text if it doesn't parse.
    private func inline(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(s)
    }

    // MARK: - Line classifiers

    private func heading(_ s: String) -> (level: Int, text: String)? {
        guard s.hasPrefix("#") else { return nil }
        var level = 0
        var idx = s.startIndex
        while idx < s.endIndex, s[idx] == "#", level < 6 {
            level += 1; idx = s.index(after: idx)
        }
        guard idx < s.endIndex, s[idx] == " " else { return nil }
        return (level, String(s[idx...]).trimmingCharacters(in: .whitespaces))
    }

    private func checkbox(_ s: String) -> (done: Bool, text: String)? {
        for marker in ["- ", "* "] where s.hasPrefix(marker) {
            let rest = String(s.dropFirst(marker.count))
            if rest.hasPrefix("[ ] ") { return (false, String(rest.dropFirst(4))) }
            if rest.lowercased().hasPrefix("[x] ") { return (true, String(rest.dropFirst(4))) }
        }
        return nil
    }

    private func bullet(_ s: String) -> String? {
        for marker in ["- ", "* "] where s.hasPrefix(marker) {
            return String(s.dropFirst(marker.count))
        }
        return nil
    }
}
