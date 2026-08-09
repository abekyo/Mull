import SwiftUI
import AppKit

/// "This week" — seven day bars plus the week-over-week comparison.
///
/// The comparison is against last week *at the same point*, not last week's total:
/// a Tuesday morning is never going to look good next to a finished week, and a
/// panel that always reads "down 70%" teaches the reader to ignore it.
///
/// Stateless by construction — it renders exactly the snapshots handed to it, so
/// the 14-day analysis stays owned by `HomeTab`. A click on a day is handed back
/// out through `onSelectDay` for the same reason: this view knows which day was
/// pressed and nothing whatever about where days are read.
struct WeekSection: View {
    let days: [DaySnapshot]
    let comparison: WeekComparison?
    /// Supplied by the owner when a day has somewhere to go. Absent by default, and
    /// when it is absent the columns stay inert rather than offering a click that
    /// leads nowhere.
    var onSelectDay: ((Date) -> Void)?

    @State private var hoveredDay: Date?

    /// A week with nothing in it at all. It is drawn, not hidden — a section that
    /// vanishes reads as a broken feature, and a new reader never learns the section
    /// exists. But seven flat stubs and a table of zeroes read as broken too, so an
    /// empty week says so in words and keeps only its shape.
    private var isEmpty: Bool {
        days.allSatisfy { $0.totalDuration <= 0 }
    }

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

            if isEmpty {
                Text("Nothing recorded this week yet.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
            } else if let comp = comparison {
                // Only offered against a week there is something to weigh. Against an
                // empty one every figure is 0 and every delta is −100%, which says
                // nothing true about the reader.
                Divider()

                comparisonView(comp)
            }
        }
        .mullCard()
    }

    private func dayColumn(_ day: DaySnapshot) -> some View {
        let maxBar: CGFloat = 60
        let maxDuration = max(days.map(\.totalDuration).max() ?? 1, 1)
        let barHeight = day.totalDuration > 0 ? max(6, day.totalDuration / maxDuration * maxBar) : 3
        let isHovered = hoveredDay == day.date && onSelectDay != nil

        return VStack(spacing: DS.xs) {
            // A space, not an empty string, on quiet days — it reserves the line so
            // the seven columns stay level. No fixed height: the old `height: 10`
            // was shorter than the font's own line and shaved descenders (and CJK
            // glyphs) off every name. A seventh of the card is narrow, so the name
            // still truncates — the whole of it is on hover.
            Text(day.mainProject ?? " ")
                .font(DS.miniFont)
                .foregroundStyle(DS.inkFaint)
                .lineLimit(1)
                .help(day.mainProject ?? "")

            Text(day.durationFormatted.isEmpty ? " " : day.durationFormatted)
                .font(DS.miniMedium)
                .foregroundStyle(day.isToday ? DS.moon : DS.inkDim)

            // Fixed-height track with the bar pinned to the bottom, so every bar grows
            // upward from a shared zero baseline (not centred, which made them spill both ways).
            ZStack(alignment: .bottom) {
                Color.clear.frame(height: maxBar)
                RoundedRectangle(cornerRadius: DS.radiusChip)
                    .fill(day.isToday ? DS.moon : DS.moon.opacity(day.totalDuration > 0 ? 0.4 : 0.08))
                    .frame(height: barHeight)
            }

            Text(day.dayName)
                .font(day.isToday ? DS.microBold : DS.microFont)
                .foregroundStyle(day.isToday ? DS.ink : DS.inkFaint)

            Text(day.dayNumber)
                .font(DS.miniFont)
                .foregroundStyle(DS.inkGhost)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.xs)
        // The whole column is the target, not just the bar — a quiet day's bar is
        // three points tall, which is no target at all.
        .background(
            RoundedRectangle(cornerRadius: DS.radiusInset)
                .fill(isHovered ? DS.moon.opacity(0.07) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelectDay?(day.date) }
        .onHover { hovering in
            guard onSelectDay != nil else { return }
            if hovering {
                hoveredDay = day.date
                NSCursor.pointingHand.push()
            } else {
                if hoveredDay == day.date { hoveredDay = nil }
                NSCursor.pop()
            }
        }
        .onDisappear {
            if hoveredDay == day.date {
                hoveredDay = nil
                NSCursor.pop()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onSelectDay != nil ? .isButton : [])
        .accessibilityHint(onSelectDay != nil ? "Opens this day in the calendar" : "")
    }

    private func comparisonView(_ comp: WeekComparison) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            // Duration comparison
            HStack(spacing: DS.md) {
                stat(
                    label: String(localized: "So far"),
                    value: comp.thisWeekHours,
                    delta: comp.lastWeekDuration > 0 ? comp.deltaFormatted : nil,
                    deltaUp: comp.durationDelta >= 0
                )

                stat(
                    label: String(localized: "Last week (same point)"),
                    value: comp.lastWeekHours,
                    delta: nil,
                    deltaUp: true
                )
            }

            // Deep work + context switches
            HStack(spacing: DS.md) {
                let deepDelta = comp.thisWeekDeepBlocks - comp.lastWeekDeepBlocks
                stat(
                    label: String(localized: "Deep work (2h+)"),
                    value: pluralized(comp.thisWeekDeepBlocks, "block"),
                    delta: deepDelta != 0 ? (deepDelta > 0 ? "+\(deepDelta)" : "\(deepDelta)") : nil,
                    deltaUp: deepDelta >= 0
                )

                let switchDelta = comp.thisWeekContextSwitches - comp.lastWeekContextSwitches
                let switchPct = comp.lastWeekContextSwitches > 0
                    ? Int(Double(switchDelta) / Double(comp.lastWeekContextSwitches) * 100)
                    : 0
                stat(
                    label: String(localized: "Context switches"),
                    value: "\(comp.thisWeekContextSwitches)",
                    delta: switchPct != 0 ? (switchPct > 0 ? "+\(switchPct)%" : "\(switchPct)%") : nil,
                    deltaUp: switchDelta <= 0 // fewer switches is better
                )
            }
        }
    }

    private func stat(label: String, value: String, delta: String?, deltaUp: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.hair) {
            Text(label)
                .font(DS.miniFont)
                .foregroundStyle(DS.inkGhost)

            HStack(spacing: DS.xs) {
                Text(value)
                    .font(DS.bodyMedium)
                    .foregroundStyle(DS.ink)

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
