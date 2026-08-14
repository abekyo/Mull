import SwiftUI
import AppKit

/// How long a day has to be before it looks long.
///
/// The bars were normalised to the week's own tallest day, which meant the height
/// carried nothing: a 9-hour Tuesday and a 40-minute Tuesday both drew the same
/// full-height bar, and the only way to tell them apart was to read the figure
/// printed above. Seven bars whose tallest is always the same height are not a
/// chart of anything — they are a ranking, drawn as if it were a measurement.
///
/// So height is measured against a reference from outside the week: a full working
/// day. Eight hours is a convention rather than a fact about this reader, which is
/// why it is *drawn* — the rule across the columns is what makes the number
/// checkable instead of secretly baked into the geometry.
///
/// The track holds `headroom`× the reference, so a day that runs over still has
/// somewhere to go rather than flattening against the ceiling. Past that the whole
/// strip rescales to the longest day and the rule slides down with it. That is the
/// honest move: clipping a 14-hour day would flatten exactly the day worth noticing,
/// and a rule that stayed put while the bars were squeezed would be lying about
/// where 8h is.
struct WeekBarScale {
    static let referenceSeconds: TimeInterval = 8 * 3600
    static let trackHeight: CGFloat = 104
    /// The ceiling before the strip rescales — 10h.
    static let headroom: Double = 1.25

    /// A recorded day never draws shorter than this, so twenty minutes of work is
    /// still visibly more than none. Below it the bar would read as an empty day.
    static let minimumRecorded: CGFloat = 6
    /// An empty day: a baseline tick, present so the column is not a hole.
    static let emptyStub: CGFloat = 3

    /// Seconds the full track represents.
    let span: TimeInterval

    init(_ durations: [TimeInterval]) {
        span = max(Self.referenceSeconds * Self.headroom, durations.max() ?? 0)
    }

    func height(for duration: TimeInterval) -> CGFloat {
        guard duration > 0 else { return Self.emptyStub }
        return max(Self.minimumRecorded, CGFloat(duration / span) * Self.trackHeight)
    }

    /// Where the 8h rule sits above the baseline.
    var referenceOffset: CGFloat {
        CGFloat(Self.referenceSeconds / span) * Self.trackHeight
    }
}

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

    private var scale: WeekBarScale { WeekBarScale(days.map(\.totalDuration)) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            // The rule inside the bars carries no number of its own — seven repeated
            // "8h" labels would be noise. It is named once, here, at the far end of
            // the header line it already had.
            HStack(spacing: DS.sm) {
                Text("THIS WEEK")
                    .sectionLabel()

                Spacer(minLength: DS.sm)

                if !isEmpty {
                    HStack(spacing: DS.xs) {
                        Rectangle()
                            .fill(DS.inkGhost)
                            .frame(width: 14, height: 1)
                        // `verbatim` on purpose: this names the same unit the seven
                        // figures below it are printed in, and `durationFormatted`
                        // does not translate its "h". A legend that reads 8時間 over
                        // a row of "9h" is explaining the chart in a second dialect.
                        Text(verbatim: "8h")
                            .font(DS.miniFont)
                            // `inkGhost` draws the rule but never the word beside it:
                            // at 1.49:1 the label would be unreadable (DesignTokens).
                            .foregroundStyle(DS.inkFaint)
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Bars are drawn against a full working day of 8 hours")
                }
            }

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
        let scale = self.scale
        let barHeight = scale.height(for: day.totalDuration)
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

            // Monospaced, so the seven figures line up as a row of numbers rather
            // than drifting with the width of each digit — and a point larger than
            // the 9pt it was, because it is the only exact quantity in the column.
            Text(day.durationFormatted.isEmpty ? " " : day.durationFormatted)
                .font(day.isToday ? DS.microBold : DS.microFont)
                .foregroundStyle(day.isToday ? DS.moon : DS.inkDim)

            // Fixed-height track with the bar pinned to the bottom, so every bar grows
            // upward from a shared zero baseline (not centred, which made them spill both ways).
            ZStack(alignment: .bottom) {
                Color.clear.frame(height: WeekBarScale.trackHeight)

                // The 8h rule, behind the bar and the full width of the column, so a
                // long day is seen crossing it. `offset` rather than padding: it is a
                // mark on the track, not something the stack should make room for.
                if !isEmpty {
                    Rectangle()
                        .fill(DS.inkGhost)
                        .frame(height: 1)
                        .offset(y: -scale.referenceOffset)
                }

                // Narrower than the column it sits in. A bar that fills its seventh of
                // a wide card is a squat block whatever its height — the height only
                // reads as a length once the bar is taller than it is wide.
                RoundedRectangle(cornerRadius: DS.radiusChip)
                    .fill(day.isToday ? DS.moon : DS.moon.opacity(day.totalDuration > 0 ? 0.4 : 0.08))
                    .frame(maxWidth: 26)
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
