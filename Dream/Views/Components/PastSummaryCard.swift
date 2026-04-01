import SwiftUI

/// A past day's summary card — collapsed by default, expandable on click.
struct PastSummaryCard: View {
    let summary: DailySummary
    var expanded: Bool = false
    var highlightQuery: String? = nil

    @State private var isExpanded: Bool
    @State private var isHovered = false

    init(summary: DailySummary, expanded: Bool = false, highlightQuery: String? = nil) {
        self.summary = summary
        self.expanded = expanded
        self.highlightQuery = highlightQuery
        self._isExpanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Button {
                withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(summary.dateFormatted.uppercased())
                        .sectionLabel()
                        .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                SummaryContent(summary: summary)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                if let query = highlightQuery, !query.isEmpty {
                    HighlightedText(text: summary.preview, highlight: query)
                        .font(DS.bodyFont)
                        .lineLimit(1)
                } else {
                    Text(summary.preview)
                        .font(DS.bodyFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .dreamCard(isHovered: isHovered)
        .onHover { hovering in
            withAnimation(.spring(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

/// Renders text with highlighted search matches.
struct HighlightedText: View {
    let text: String
    let highlight: String

    var body: some View {
        attributedText
    }

    private var attributedText: Text {
        guard !highlight.isEmpty else {
            return Text(text).foregroundStyle(.secondary)
        }

        var result = Text("")
        var remaining = text[text.startIndex...]
        let query = highlight.lowercased()

        while let range = remaining.lowercased().range(of: query) {
            let before = remaining[remaining.startIndex..<range.lowerBound]
            let match = remaining[range]

            result = result + Text(before).foregroundStyle(.secondary)
            result = result + Text(match).foregroundStyle(Color.accentColor).bold()

            remaining = remaining[range.upperBound...]
        }

        result = result + Text(remaining).foregroundStyle(.secondary)
        return result
    }
}
