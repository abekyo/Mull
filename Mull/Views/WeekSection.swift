import SwiftUI

/// "This week" — seven day bars plus the week-over-week comparison.
///
/// The comparison is against last week *at the same point*, not last week's total:
/// a Tuesday morning is never going to look good next to a finished week, and a
/// panel that always reads "down 70%" teaches the reader to ignore it.
///
/// Stateless by construction — it renders exactly the snapshots handed to it, so
/// the 14-day analysis stays owned by `HomeTab`.
struct WeekSection: View {
    let days: [DaySnapshot]
    let comparison: WeekComparison?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Text("THIS WEEK")
                .sectionLabel()

            // Day bars
            HStack(alignment: .bottom, spacing: DS.sm) {
                ForEach(days) { day in
                    dayColumn(day)
                }
            }

            // Week-over-week comparison
            if let comp = comparison {
                Divider()

                comparisonView(comp)
            }
        }
        .mullCard()
    }

    private func dayColumn(_ day: DaySnapshot) -> some View {
        let maxBar: CGFloat = 60
        let maxDuration = days.map(\.totalDuration).max() ?? 1
        let barHeight = day.totalDuration > 0 ? max(6, day.totalDuration / maxDuration * maxBar) : 3

        return VStack(spacing: DS.xs) {
            Text(day.mainProject ?? "")
                .font(DS.tinyFont)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(height: 10)

            Text(day.durationFormatted)
                .font(DS.miniMedium)
                .foregroundStyle(day.isToday ? DS.moon : .secondary)
                .frame(height: 12)

            // Fixed-height track with the bar pinned to the bottom, so every bar grows
            // upward from a shared zero baseline (not centred, which made them spill both ways).
            ZStack(alignment: .bottom) {
                Color.clear.frame(height: maxBar)
                RoundedRectangle(cornerRadius: 3)
                    .fill(day.isToday ? DS.moon : DS.moon.opacity(day.totalDuration > 0 ? 0.4 : 0.08))
                    .frame(height: barHeight)
            }

            Text(day.dayName)
                .font(day.isToday ? Font.system(size: 10, weight: .bold) : DS.microFont)
                .foregroundStyle(day.isToday ? .primary : .tertiary)

            Text(day.dayNumber)
                .font(DS.miniFont)
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity)
    }

    private func comparisonView(_ comp: WeekComparison) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            // Duration comparison
            HStack(spacing: DS.md) {
                stat(
                    label: "This week",
                    value: comp.thisWeekHours,
                    delta: comp.lastWeekDuration > 0 ? comp.deltaFormatted : nil,
                    deltaUp: comp.durationDelta >= 0
                )

                stat(
                    label: "Last week (same point)",
                    value: comp.lastWeekHours,
                    delta: nil,
                    deltaUp: true
                )
            }

            // Deep work + context switches
            HStack(spacing: DS.md) {
                let deepDelta = comp.thisWeekDeepBlocks - comp.lastWeekDeepBlocks
                stat(
                    label: "Deep work (2h+)",
                    value: "\(comp.thisWeekDeepBlocks) blocks",
                    delta: deepDelta != 0 ? (deepDelta > 0 ? "+\(deepDelta)" : "\(deepDelta)") : nil,
                    deltaUp: deepDelta >= 0
                )

                let switchDelta = comp.thisWeekContextSwitches - comp.lastWeekContextSwitches
                let switchPct = comp.lastWeekContextSwitches > 0
                    ? Int(Double(switchDelta) / Double(comp.lastWeekContextSwitches) * 100)
                    : 0
                stat(
                    label: "Context switches",
                    value: "\(comp.thisWeekContextSwitches)",
                    delta: switchPct != 0 ? (switchPct > 0 ? "+\(switchPct)%" : "\(switchPct)%") : nil,
                    deltaUp: switchDelta <= 0 // fewer switches is better
                )
            }
        }
    }

    private func stat(label: String, value: String, delta: String?, deltaUp: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DS.miniFont)
                .foregroundStyle(.quaternary)

            HStack(spacing: DS.xs) {
                Text(value)
                    .font(DS.bodyMedium)
                    .foregroundStyle(.primary)

                if let delta {
                    Text(delta)
                        .font(DS.microFont)
                        .foregroundStyle(deltaUp ? DS.recording : DS.paused)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
