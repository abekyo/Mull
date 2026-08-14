import SwiftUI

/// A month grid drawn in mull's own palette, for the places that ask "which day?".
///
/// It replaces `DatePicker(...).datePickerStyle(.graphical)`, which is a fine control
/// in an app that looks like the rest of macOS and wrong in this one. The stock picker
/// paints itself with the system accent (blue, on a page whose tokens say in as many
/// words *never use raw .blue*), sets its own type, and draws its own chrome — so
/// opening it dropped a panel of somebody else's design system into the middle of the
/// calendar. The complaint it answers was not that it was ugly. It was that it visibly
/// came from somewhere else.
///
/// Nothing here is invented: today is a filled tobacco circle with canvas-coloured
/// digits, days outside the month are `inkGhost`, the weekday initials are `miniFont`
/// over `inkFaint`. That is exactly how `CalendarWeekView` already draws its month
/// cells, its year grid and its day headers, because the point is that this is the same
/// calendar rather than a control that happens to sit near one.
///
/// Unbounded in both directions. The observed half of mull has nothing to say about
/// tomorrow, but the scheduled half does, and a picker that stopped at today hid every
/// meeting the reader had already agreed to.
struct MonthPicker: View {

    /// The day currently chosen. Read to draw the ring; never written to on its own —
    /// picking a day calls `onPick`, and the owner decides what that means.
    let selection: Date
    /// A day was chosen. Fires only on a real click: the old popover seeded a
    /// `DatePicker` binding on appear, which counted as a change, so it closed itself
    /// on the same pass that opened it and needed a guard to survive. A callback that
    /// only a click can reach has no such state to get wrong.
    let onPick: (Date) -> Void

    /// The month on screen, which is not the same as the day selected — you can look at
    /// March without choosing anything in it.
    @State private var visibleMonth: Date
    @State private var hovered: Date?

    private let calendar = Calendar.current

    init(selection: Date, onPick: @escaping (Date) -> Void) {
        self.selection = selection
        self.onPick = onPick
        _visibleMonth = State(initialValue: Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: selection)) ?? selection)
    }

    /// One cell.
    ///
    /// Fixed rather than `@ScaledMetric`, to match the day circles the rest of the
    /// calendar already draws at a fixed 20 and 24 (`monthCell`, `dayHeaderRow`). The
    /// type inside it *is* scaled, so at the largest accessibility sizes the digits grow
    /// and the circle does not. That is the same limit the month grid has and it is
    /// better fixed there first, for both, than worked around here for one of them.
    private static let cell: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            header
            weekdayRow
            grid
            Divider()
            todayRow
        }
        .padding(DS.md)
        .frame(width: Self.cell * 7 + DS.md * 2)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.xs) {
            Text(Self.monthTitle.string(from: visibleMonth))
                .font(DS.subtitleSemibold)
                .foregroundStyle(DS.ink)
                .lineLimit(1)

            Spacer(minLength: DS.sm)

            chevron("chevron.left", hint: String(localized: "Previous month"), by: -1)
            chevron("chevron.right", hint: String(localized: "Next month"), by: 1)
        }
    }

    private func chevron(_ symbol: String, hint: String, by months: Int) -> some View {
        Button {
            guard let moved = calendar.date(byAdding: .month, value: months, to: visibleMonth) else { return }
            // Animated because the digits underneath change wholesale, and a grid that
            // swaps instantly reads as a flicker rather than a step.
            withAnimation(.easeOut(duration: 0.12)) { visibleMonth = moved }
        } label: {
            Image(systemName: symbol)
                .font(DS.captionMedium)
                .foregroundStyle(DS.inkDim)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(hint)
        .accessibilityLabel(hint)
    }

    // MARK: - Grid

    /// Weekday initials from the system's first weekday — 日曜始まり / 月曜始まり both
    /// honoured, through the same helper the week and month grids read.
    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(CalendarGrid.orderedWeekdaySymbols(
                calendar.veryShortStandaloneWeekdaySymbols,
                firstWeekday: calendar.firstWeekday).enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(DS.miniFont)
                    .foregroundStyle(DS.inkFaint)
                    .frame(width: Self.cell)
            }
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        dayCell(days[row * 7 + column])
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: selection)
        let inMonth = calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month)
        let isHovered = hovered.map { calendar.isDate($0, inSameDayAs: day) } ?? false

        return Text(String(calendar.component(.day, from: day)))
            .font(isToday || isSelected ? DS.smallMedium : DS.smallFont)
            // Today is the one filled thing on the grid, so it is the one that takes
            // the page colour back out of the ink.
            .foregroundStyle(isToday ? DS.canvas : (inMonth ? DS.ink : DS.inkGhost))
            .frame(width: Self.cell, height: Self.cell - 2)
            .background {
                if isToday {
                    Circle().fill(DS.moon)
                } else if isSelected {
                    Circle().fill(DS.moon.opacity(0.16))
                } else if isHovered {
                    Circle().fill(DS.surfaceHi)
                }
            }
            // A selected day that is also today keeps the fill and gains the ring, so
            // "the day you are on" and "the day mull is showing" stay separable — they
            // are the same day often enough that collapsing them would hide the second.
            .overlay {
                if isSelected {
                    Circle().strokeBorder(DS.moon, lineWidth: isToday ? 1.5 : 1)
                        .frame(width: Self.cell - 2, height: Self.cell - 2)
                }
            }
            .contentShape(Circle())
            // Clear only if this cell is the one currently marked: the pointer enters
            // the next cell before it leaves this one, so an unconditional clear on exit
            // erases the highlight that just moved.
            .onHover { inside in
                if inside { hovered = day } else if isHovered { hovered = nil }
            }
            .onTapGesture { onPick(day) }
            .pointingHandCursor()
            .help(Self.dayHelp.string(from: day))
            .accessibilityLabel(Self.dayHelp.string(from: day))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The same 42 days the month view draws, from the same place — see
    /// `CalendarGrid.monthGridDays`, which is also where the six-rows-always rule and
    /// the first-weekday arithmetic are explained and tested.
    private var days: [Date] { CalendarGrid.monthGridDays(of: visibleMonth, calendar: calendar) }

    // MARK: - Today

    private var todayRow: some View {
        HStack {
            Button("Today") { onPick(Date()) }
                .font(DS.captionFont)
                .buttonStyle(.plain)
                .foregroundStyle(DS.moon)
                .pointingHandCursor()
                .help("Jump to today (⌘T)")
            Spacer()
            Text(Self.fullDate.string(from: selection))
                .font(DS.miniFont)
                .foregroundStyle(DS.inkFaint)
                .lineLimit(1)
        }
    }

    // MARK: - Formatters
    //
    // Built once. Inside `dayCell` they were 42 of them per layout pass, each
    // re-deriving the locale's template — the mistake `monthGrid` already documents.

    private static let monthTitle = CalendarWeekView.templateFormatter("MMMMy")
    private static let dayHelp = CalendarWeekView.templateFormatter("EEEEdMMMMy")
    private static let fullDate = CalendarWeekView.templateFormatter("EEEdMMM")
}
