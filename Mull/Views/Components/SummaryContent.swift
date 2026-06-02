import SwiftUI

/// Renders the body of a daily summary.
struct SummaryContent: View {
    let summary: DailySummary

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            if let morning = summary.morningSection, !morning.isEmpty {
                SummarySection(title: "Morning", content: morning)
            }
            if let afternoon = summary.afternoonSection, !afternoon.isEmpty {
                SummarySection(title: "Afternoon", content: afternoon)
            }
            if let evening = summary.eveningSection, !evening.isEmpty {
                SummarySection(title: "Evening", content: evening)
            }
            if let learnings = summary.learnings, !learnings.isEmpty {
                SummarySection(title: "Learned", content: learnings, icon: "lightbulb.fill")
            }
            if let inProgress = summary.inProgress, !inProgress.isEmpty {
                SummarySection(title: "In progress", content: inProgress, icon: "arrow.right.circle.fill")
            }
        }
    }
}

/// A labeled section with bullet points.
struct SummarySection: View {
    let title: String
    let content: String
    var icon: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(spacing: DS.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                }
                Text(title)
                    .sectionLabel()
            }

            ForEach(bulletLines, id: \.self) { line in
                HStack(alignment: .top, spacing: DS.sm) {
                    Circle()
                        .fill(.tertiary)
                        .frame(width: 4, height: 4)
                        .padding(.top, 6)
                    Text(line)
                        .font(DS.bodyFont)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var bulletLines: [String] {
        content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { line in
                if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
                if line.hasPrefix("* ") { return String(line.dropFirst(2)) }
                return line
            }
            .filter { !$0.isEmpty }
    }
}
