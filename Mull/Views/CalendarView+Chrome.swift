import SwiftUI
import EventKit
import AppKit

// The furniture around the grid: toolbar, day headers, the all-day band, the
// now indicator, the empty state and the keyboard-selection handling.
//
// Lifted out of CalendarView.swift. Nothing here changed in the move.

extension CalendarWeekView {

    // MARK: - Toolbar
    //
    // One row, as Calendar.app has: what you are looking at on the left, the controls
    // that move it on the right. This was two stacked bars — a segmented picker above
    // a centred title with its own chevrons — which is a shape no Apple calendar has,
    // and it cost a fifth of the window's height before a single hour was drawn.

    var toolbar: some View {
        HStack(spacing: DS.md) {
            Text(rangeTitle)
                .font(DS.displayFont)
                .foregroundStyle(DS.ink)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: DS.md)

            calendarVisibilityControl

            newEventControl

            HStack(spacing: DS.xs) {
                navArrow("chevron.left", hint: "Go back", action: { step(-1) })
                // Always live, as Apple's is. It used to vanish when you were already
                // on today, which is a control that moves under the pointer.
                Button("Today") { goToToday() }
                    .font(DS.captionFont)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Today (⌘T)")
                navArrow("chevron.right", hint: "Go forward", action: { step(1) })
            }

            jumpButton

            Picker("", selection: $mode) {
                ForEach(CalMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Calendar range")
        }
        .padding(.horizontal, DS.xl)
        .padding(.vertical, DS.sm)
    }

    /// Which calendars the grid draws.
    ///
    /// Every calendar mounted on the Mac used to be drawn with no way to turn any of
    /// them off — a subscribed holiday feed, a shared team calendar and your own week
    /// all at once, and no equivalent of the checkboxes in Calendar.app's sidebar. A
    /// menu rather than a sidebar because there is no room for one here, and the
    /// question is asked rarely.
    ///
    /// The choice is the view's, not the vault's: `dayEvents` takes it as an argument
    /// and defaults to hiding nothing, so what an agent reads over MCP is unchanged.
    @ViewBuilder
    var calendarVisibilityControl: some View {
        let sources = appState.calendar.eventCalendars
        if sources.count > 1 {
            let hidden = hiddenCalendars
            Menu {
                ForEach(sources) { source in
                    Toggle(isOn: Binding(
                        get: { !hidden.contains(source.id) },
                        set: { setCalendar(source.id, hidden: !$0) }
                    )) {
                        Label {
                            Text(source.title)
                        } icon: {
                            Circle().fill(Color(cgColor: source.color))
                        }
                    }
                }
            } label: {
                Image(systemName: hidden.isEmpty ? "calendar.badge.checkmark" : "calendar.badge.minus")
                    .font(DS.bodyFont)
                    .foregroundStyle(hidden.isEmpty ? DS.inkDim : DS.moon)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // The count is on the tooltip because a grid that is quietly missing a
            // calendar has to be able to say so when asked.
            .help(hidden.isEmpty ? "Which calendars to show"
                                 : "Which calendars to show · \(hidden.count) hidden")
            .accessibilityLabel("Calendars shown")
        }
    }

    /// The visible half of ⌘N. A keyboard shortcut nobody is told about is not a way
    /// to add an event, and this is where a Mac user looks first.
    ///
    /// With more than one writable calendar it becomes a menu, because "which
    /// calendar did that go into" is a question you would otherwise only think to ask
    /// once the event was already in the wrong one. Clicking it still just makes an
    /// event in the default; the list is there when you want it.
    @ViewBuilder
    var newEventControl: some View {
        let calendars = appState.calendar.writableCalendars
        if calendars.count > 1 {
            Menu {
                ForEach(calendars) { calendar in
                    Button {
                        newEvent(in: calendar.id)
                    } label: {
                        Label {
                            Text(calendar.title)
                        } icon: {
                            Circle().fill(Color(cgColor: calendar.color))
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(DS.bodyFont)
                    .foregroundStyle(DS.inkDim)
            } primaryAction: {
                newEvent()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(newEventHelp)
            .accessibilityLabel("New event")
        } else {
            Button { newEvent() } label: {
                Image(systemName: "plus")
                    .font(DS.bodyFont)
                    .foregroundStyle(calendars.isEmpty ? DS.inkFaint : DS.inkDim)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(calendars.isEmpty)
            .pointingHandCursor(!calendars.isEmpty)
            .help(newEventHelp)
            .accessibilityLabel("New event")
        }
    }

    /// The tooltip names the calendar the event will land in — mull writes to the
    /// default you already chose, and saying which one is what stops "where did it
    /// go?" being the next question.
    var newEventHelp: String {
        guard let calendar = appState.calendar.defaultCalendarTitle else {
            return "No calendar on this Mac accepts new events"
        }
        return "New event in \(calendar) (⌘N) · or double-click the grid"
    }

    /// What the toolbar is titled with, in whatever unit is on screen.
    var rangeTitle: String {
        switch mode {
        case .day:   return Self.fullDayLabel(selectedDay)
        case .week:  return weekRangeLabel
        case .month: return monthLabel
        case .year:  return yearLabel
        }
    }

    /// Go straight to a date rather than walking to it. Last April was twelve
    /// clicks of the back chevron before this existed.
    var jumpButton: some View {
        Button { pickerDate = anchorDate; showingDatePicker = true } label: {
            Image(systemName: "calendar")
                .font(DS.bodyFont)
                .foregroundStyle(DS.inkDim)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to a date (← → to step)")
        .accessibilityLabel("Jump to a date")
        .accessibilityHint("Left and right arrows step by one period.")
        .pointingHandCursor()
        .popover(isPresented: $showingDatePicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DS.sm) {
                Text("Jump to")
                    .font(DS.captionMedium)
                    .foregroundStyle(DS.inkDim)
                // Unbounded in both directions. It used to stop at today, on the
                // grounds that nothing is recorded past this moment — but the
                // calendar half of the grid knows perfectly well what is coming.
                DatePicker("", selection: $pickerDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .accessibilityLabel("Jump to date")
                    .onChange(of: pickerDate) { _, date in
                        // The picker opens seeded with the date already on screen,
                        // and that seeding is itself a change — without this guard
                        // it closes the popover on the same pass that opened it.
                        guard !Calendar.current.isDate(date, inSameDayAs: anchorDate) else { return }
                        jump(to: date)
                        showingDatePicker = false
                    }
            }
            .padding(DS.md)
        }
    }

    func navArrow(_ symbol: String, hint: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(DS.bodyFont)
                .foregroundStyle(DS.inkDim)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityLabel(hint)
        .pointingHandCursor()
    }

    // MARK: - Week and Day

    var weekContent: some View {
        VStack(spacing: 0) {
            dayHeaderRow(weekDays)
            allDayBand
            Divider()
            timeGrid(days: weekDays)
                // Seven blank columns and a bare hour grid is what a new reader used
                // to open on, with nothing to say why.
                .overlay(alignment: .top) { emptyState }
        }
    }

    var selectedDay: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: today) ?? today
    }

    /// One timeline, as Calendar.app's day view is. It used to be two parallel columns
    /// headed SCHEDULED and ACTIVITY, which put the same 09:30 in two places and left
    /// each half at a third of the width it had.
    var dayContent: some View {
        VStack(spacing: 0) {
            dayHeaderRow([selectedDay])
            allDayBand
            Divider()
            timeGrid(days: [selectedDay])
                .overlay(alignment: .top) { emptyState }
        }
    }

    // MARK: - Empty state
    //
    // Week is the mode the app opens in, so this is the first screen a new reader
    // sees — and it was seven blank columns and a 24-hour grid, which reads as a
    // broken app rather than an empty record.

    var rangeIsEmpty: Bool {
        let cal = Calendar.current
        return displayedDays.allSatisfy { date in
            let key = cal.startOfDay(for: date)
            return (weekBlocks[key] ?? []).isEmpty
                && (weekEvents[key] ?? []).isEmpty
                && (weekAllDay[key] ?? []).isEmpty
        }
    }

    /// Nothing here has happened yet, so nothing *could* have been recorded.
    var rangeIsFuture: Bool {
        displayedDays.allSatisfy { Calendar.current.startOfDay(for: $0) > today }
    }

    @ViewBuilder
    var emptyState: some View {
        // Same rule as the day columns: say nothing about a range not yet read, and
        // nothing at all while an event is being composed on top of it.
        if rangeIsEmpty, !isLoading, loadedKey != nil, draft == nil {
            VStack(spacing: DS.sm) {
                // The one empty-state figure: the icon's rings, sparse and
                // half-formed. Every quiet page in mull wears the same face.
                StippleRings.roundel()
                    .frame(width: 56, height: 56)
                    .opacity(0.5)
                    .padding(.bottom, DS.xs)
                if rangeIsFuture {
                    Text(mode == .day ? "Nothing scheduled" : "Nothing scheduled yet")
                        .font(DS.titleFont)
                        .foregroundStyle(DS.ink)
                    Text("Double-click anywhere here to put something in.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkDim)
                } else if calendarAccess == .granted {
                    Text(mode == .day ? "Nothing recorded this day" : "Nothing recorded this week")
                        .font(DS.titleFont)
                        .foregroundStyle(DS.ink)
                    Text("mull fills this in as you work.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkDim)
                } else {
                    Text("No calendar access, so no schedule here")
                        .font(DS.titleFont)
                        .foregroundStyle(DS.ink)
                    // Both halves of the grid are empty here, and only one of them
                    // has a cause worth acting on — so say which is which.
                    Text("Nothing observed either — mull fills this in as you work.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkDim)
                    Button(calendarAccess == .notDetermined ? "Allow calendar access"
                                                            : "Open System Settings") {
                        grantCalendarAccess()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, DS.xs)
                }
            }
            .padding(DS.xl)
            .background(RoundedRectangle(cornerRadius: DS.radiusMd).fill(DS.surface))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusMd).strokeBorder(DS.hairline, lineWidth: 0.75)
            )
            .padding(.top, DS.xxl)
            // It is a note, not a wall: the grid underneath still has to answer a
            // double-click, which is the very thing the note is telling you to do.
            .allowsHitTesting(calendarAccess != .granted)
        }
    }

    /// The system only prompts once. After that the decision lives in System
    /// Settings, so that is where the button has to lead.
    func grantCalendarAccess() {
        guard calendarAccess == .notDetermined else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        appState.calendar.requestAccess { granted in
            // Take the state from TCC, not from the outcome of this one call. A
            // request that fails rather than being refused leaves the decision still
            // open, and writing `.denied` in that case swaps a button that would have
            // worked for an instruction to go hunting through System Settings.
            calendarAccess = CalendarService.currentAccessState
            if granted { loadCurrent() }
        }
    }

    /// Full date with its weekday. A fixed pattern here spelled the date in British
    /// order whatever the machine was set to; `.full` lets the locale order it —
    /// "2026年7月19日日曜日" where the reader expects that, and not otherwise.
    private static func fullDayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f.string(from: date)
    }

    /// The actual span of the displayed week, not merely its month — the old label
    /// said "September 2025" for all five of September's weeks. Parts the two ends
    /// share are said once: "15 – 21 September 2025", "29 September – 5 October 2025".
    ///
    /// The three patterns are templates, not literal formats: `d MMMM yyyy` is fixed
    /// British order and read wrongly on a Japanese machine, whereas the template is
    /// rearranged by the locale into 2025年9月21日.
    var weekRangeLabel: String {
        let (start, end) = weekRange
        let cal = Calendar.current
        let day = Self.templateFormatter("d")
        let dayMonth = Self.templateFormatter("dMMMM")
        let full = Self.templateFormatter("dMMMMy")

        let sameYear = cal.component(.year, from: start) == cal.component(.year, from: end)
        let sameMonth = sameYear && cal.component(.month, from: start) == cal.component(.month, from: end)

        if sameMonth { return "\(day.string(from: start)) – \(full.string(from: end))" }
        if sameYear { return "\(dayMonth.string(from: start)) – \(full.string(from: end))" }
        return "\(full.string(from: start)) – \(full.string(from: end))"
    }

    /// A formatter carrying the *fields* a label needs, leaving their order, their
    /// separators and their spelling to the reader's locale.
    static func templateFormatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    // MARK: - Day headers (sticky, above the scroll)

    func dayHeaderRow(_ days: [Date]) -> some View {
        HStack(spacing: 0) {
            // The corner above the gutter carries the month, the way Calendar.app's
            // week view does — so the axis says which month it belongs to.
            Text(Self.templateFormatter("MMM").string(from: days.first ?? today))
                .font(DS.miniFont)
                .foregroundStyle(DS.inkFaint)
                .padding(.trailing, DS.sm)
                .frame(width: timeColumnWidth, alignment: .bottomTrailing)

            ForEach(days, id: \.self) { date in
                let isToday = Calendar.current.isDateInToday(date)

                VStack(spacing: DS.hair) {
                    Text(dayName(date))
                        .font(DS.miniFont)
                        .foregroundStyle(isToday ? DS.moon : DS.inkDim)

                    // Apple-style: today's number in a filled tobacco circle
                    if isToday {
                        Text(dayNumber(date))
                            .font(DS.smallMedium)
                            .foregroundStyle(DS.canvas)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(DS.moon))
                    } else {
                        Text(dayNumber(date))
                            .font(DS.smallFont)
                            .foregroundStyle(DS.ink)
                            .frame(width: 24, height: 24)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .help("Double-click for \(Self.shortDate(date)) in Day view")
                .onTapGesture(count: 2) {
                    dayOffset = dayIndex(of: date)
                    mode = .day
                }
            }
        }
        .padding(.vertical, DS.xs)
    }

    // MARK: - All-day band
    //
    // A flight, a week of PTO, a birthday. These can't be put on an hour axis
    // honestly (a birthday did not take 24 hours), so they sit in their own band
    // under the day headers, the way Apple's do — and, like Apple's, a double-click
    // in the band is how a day-shaped commitment gets made.
    //
    // One bar per commitment, spanning the days it covers, rather than one chip per
    // day: the arithmetic and the reason for it are in `CalendarGrid.allDayBars`.
    // Positioned by hand off a measured width rather than laid out in an `HStack`,
    // because a bar four columns wide is not a thing a stack of columns can hold.

    /// One entry in the band: the commitment, and where the grid put it.
    struct AllDayBar: Identifiable {
        let bar: CalendarGrid.Bar
        let event: CalendarEvent
        var id: String { bar.id }
    }

    /// The band's contents, each commitment once.
    ///
    /// `dayEvents` files a multi-day event under every day it covers — right for the
    /// dictionary, wrong for the eye — and this is the one place that becomes a
    /// single bar again. Keyed by `CalItem.id`, so the same identity the popover and
    /// the keyboard use decides what counts as one thing.
    var allDayBars: [AllDayBar] {
        let cal = Calendar.current
        var events: [String: CalendarEvent] = [:]
        var intervals: [CalendarGrid.DayInterval] = []

        for day in displayedDays {
            for event in weekAllDay[cal.startOfDay(for: day)] ?? [] {
                let id = CalItem(event: event).id
                guard events[id] == nil else { continue }
                events[id] = event
                intervals.append(CalendarGrid.DayInterval(id: id, start: event.start, end: event.end))
            }
        }

        return CalendarGrid.allDayBars(intervals, days: displayedDays, calendar: cal)
            .compactMap { bar in events[bar.id].map { AllDayBar(bar: bar, event: $0) } }
    }

    /// Where a new all-day event is being typed: the column it was double-clicked in,
    /// and the first lane free on that column, so the field never opens on top of a
    /// bar already running through that day.
    func allDayDraftSlot(_ bars: [AllDayBar]) -> (column: Int, lane: Int)? {
        let cal = Calendar.current
        guard let draft, draft.isAllDay,
              let column = displayedDays.firstIndex(where: { cal.isDate($0, inSameDayAs: draft.day) })
        else { return nil }

        let taken = Set(bars.filter { $0.bar.column <= column && column < $0.bar.column + $0.bar.span }
                            .map(\.bar.lane))
        var lane = 0
        while taken.contains(lane) { lane += 1 }
        return (column, lane)
    }

    @ViewBuilder
    var allDayBand: some View {
        let days = displayedDays
        let bars = allDayBars
        let draftSlot = allDayDraftSlot(bars)
        let lanes = max(bars.map { $0.bar.lane + 1 }.max() ?? 0, draftSlot.map { $0.lane + 1 } ?? 0)
        let step = allDayBarHeight + DS.hair

        if lanes > 0 {
            HStack(alignment: .top, spacing: 0) {
                Text("all-day")
                    .font(DS.miniFont)
                    .foregroundStyle(DS.inkFaint)
                    .padding(.trailing, DS.sm)
                    .frame(width: timeColumnWidth, alignment: .trailing)

                GeometryReader { geo in
                    let columnWidth = geo.size.width / CGFloat(max(days.count, 1))

                    // Beyond a few lanes the band scrolls instead of growing, the way
                    // Apple's does. It used to take whatever height it liked, so a
                    // fortnight of overlapping trips pushed the hour grid — the thing
                    // the window is actually for — off the bottom of it.
                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            // Underneath the bars, so a double-click on empty band
                            // makes an event and a click on a bar opens the one it hit.
                            HStack(spacing: 0) {
                                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                                    Rectangle()
                                        .fill(.clear)
                                        .contentShape(Rectangle())
                                        .onTapGesture(count: 2) { beginAllDayDraft(on: day) }
                                        .accessibilityAction(named: "New all-day event") {
                                            beginAllDayDraft(on: day)
                                        }
                                }
                            }

                            ForEach(bars) { entry in
                                allDayChip(entry)
                                    .frame(width: max(columnWidth * CGFloat(entry.bar.span) - 2, 1),
                                           height: allDayBarHeight)
                                    .offset(x: columnWidth * CGFloat(entry.bar.column) + 1,
                                            y: step * CGFloat(entry.bar.lane))
                            }

                            if let draftSlot {
                                allDayDraftChip
                                    .frame(width: max(columnWidth - 2, 1), height: allDayBarHeight)
                                    .offset(x: columnWidth * CGFloat(draftSlot.column) + 1,
                                            y: step * CGFloat(draftSlot.lane))
                            }
                        }
                        .frame(height: step * CGFloat(lanes), alignment: .topLeading)
                    }
                    .scrollDisabled(lanes <= Self.maxAllDayLanes)
                }
                .frame(height: step * CGFloat(min(lanes, Self.maxAllDayLanes)))
            }
            .padding(.vertical, DS.xs)
        }
    }

    /// Outlined like a scheduled event, because that is what it is — a commitment
    /// made in advance — only without a time to put it against.
    ///
    /// Square where the run leaves the range being shown, rounded where it truly
    /// begins or ends: a trip that started last Thursday has to say so, and a fully
    /// rounded pill at Monday's edge says the opposite.
    func allDayChip(_ entry: AllDayBar) -> some View {
        let event = entry.event
        let item = CalItem(event: event)
        let isKeyed = keyboardSelection == item.id
        let radius = DS.radiusChip
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: entry.bar.continuesBefore ? 0 : radius,
            bottomLeadingRadius: entry.bar.continuesBefore ? 0 : radius,
            bottomTrailingRadius: entry.bar.continuesAfter ? 0 : radius,
            topTrailingRadius: entry.bar.continuesAfter ? 0 : radius
        )

        return HStack(spacing: DS.hair) {
            Text(event.title)
                .font(DS.miniMedium)
                .foregroundStyle(DS.ink)
                .lineLimit(1)
            if event.isRecurring { recurrenceMark }
        }
            .padding(.horizontal, DS.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(shape.fill(event.color.opacity(0.10)))
            .overlay(shape.stroke(isKeyed ? DS.moon : event.color.opacity(0.45),
                                  lineWidth: isKeyed ? 1.5 : 0.75))
            .help(item.tooltip)
            .contentShape(Rectangle())
            .pointingHandCursor()
            // Same pair as a card on the grid: the click both highlights it for the
            // keyboard and opens it, so ⌫ afterwards means the thing just clicked.
            .onTapGesture {
                keyboardSelection = item.id
                selectedItem = item
            }
            .popover(isPresented: popoverBinding(for: item), arrowEdge: .bottom) {
                itemDetail(item)
            }
    }

    var allDayDraftChip: some View {
        TextField("New Event", text: draftTitle)
            .textFieldStyle(.plain)
            .font(DS.miniMedium)
            .foregroundStyle(DS.ink)
            .focused($draftFocused)
            .onSubmit { commitDraft() }
            .padding(.horizontal, DS.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.radiusChip).fill(DS.moon.opacity(0.14)))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusChip)
                    .strokeBorder(DS.moon.opacity(0.7), lineWidth: 1)
            )
            .accessibilityLabel("New all-day event")
            .onExitCommand { self.draft = nil }
    }

    func beginAllDayDraft(on day: Date) {
        guard appState.calendar.canCreateEvents else {
            writeError = CalendarService.WriteError.noWritableCalendar.errorDescription
            return
        }
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        draft = EventDraft(day: day, start: start,
                           end: cal.date(byAdding: .day, value: 1, to: start) ?? start,
                           isAllDay: true)
        draftFocused = true
    }

    /// The days the current range covers.
    var displayedDays: [Date] {
        mode == .day ? [selectedDay] : weekDays
    }

    /// Where a freshly laid-out grid should sit: an hour before now when the range
    /// contains today, otherwise the start of an ordinary working day rather than
    /// midnight.
    var scrollAnchorHour: Int {
        guard displayedDays.contains(where: { Calendar.current.isDateInToday($0) }) else { return 8 }
        return max(Calendar.current.component(.hour, from: now) - 1, 0)
    }

    /// Scroll once the rows exist. Calling `scrollTo` straight out of `onAppear` races
    /// the first layout pass and silently no-ops — which is how the day used to open
    /// pinned at midnight. Hopping to the next runloop lands after layout; the second
    /// hop covers the case where the data settles a beat later.
    func scrollToAnchor(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard force || wantsAnchorScroll else { return }
        wantsAnchorScroll = false
        let target = scrollAnchorHour
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .top)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                proxy.scrollTo(target, anchor: .top)
            }
        }
    }

    /// Put the same *time* back under the eye after a zoom. Without this the grid
    /// keeps its offset in points, so stretching the hour slides you backwards
    /// through the morning.
    func restoreZoomAnchor(_ proxy: ScrollViewProxy) {
        guard let hour = zoomAnchorHour else { return }
        zoomAnchorHour = nil
        DispatchQueue.main.async { proxy.scrollTo(hour, anchor: .top) }
    }

    // MARK: - Keyboard selection

    /// Every card on the displayed range, in the order ↑ / ↓ walk them.
    ///
    /// The band is in here too. It used to hold only what `items(on:)` returns —
    /// the hour grid — so an all-day event could be made with the keyboard and then
    /// never reached by it again: ↑ / ↓ walked past it, Return would not open it and
    /// ⌫ would not delete it. Each bar appears once however many days it covers,
    /// because `allDayBars` has already done that work.
    var selectableItems: [CalItem] {
        let timed = displayedDays.flatMap { items(on: $0) }
        let dayShaped = allDayBars.map { CalItem(event: $0.event) }
        // A day-shaped thing begins at midnight, so sorting on start alone puts it
        // above that day's meetings — which is where it is drawn.
        return (dayShaped + timed).sorted { $0.start < $1.start }
    }

    func keyboardItem() -> CalItem? {
        guard let id = keyboardSelection else { return nil }
        return selectableItems.first { $0.id == id }
    }

    func moveKeyboardSelection(_ delta: Int) {
        let items = selectableItems
        guard !items.isEmpty else { return }
        guard let current = keyboardSelection,
              let index = items.firstIndex(where: { $0.id == current }) else {
            keyboardSelection = (delta > 0 ? items.first : items.last)?.id
            return
        }
        keyboardSelection = items[min(max(index + delta, 0), items.count - 1)].id
    }

    /// ⌫ on the highlighted event. It goes through the writer, so ⌘Z brings it back.
    func deleteKeyboardSelection() {
        guard let item = keyboardItem(),
              let handle = item.editableHandle,
              let writer else { return }
        let fields = writer.currentFields(handle)
            ?? CalendarService.EventFields(title: item.title, start: item.start,
                                           end: item.end, location: nil)
        keyboardSelection = nil
        writer.delete(ref: writer.ref(for: handle), fields: fields, undo: undoManager)
    }

    // MARK: - Now indicator (tobacco line + dot, Apple-style placement)

    var nowIndicator: some View {
        // The same arithmetic every card on the grid is placed by, rather than a
        // second reading of the clock that agrees with it on all but two days a year.
        let y = CalendarGrid.yOffset(for: now, hourHeight: hourHeight)

        return GeometryReader { geo in
            HStack(spacing: 0) {
                Circle()
                    .fill(DS.nowLine)
                    .frame(width: 8, height: 8)
                    .offset(x: -4)
                Rectangle()
                    .fill(DS.nowLine)
                    .frame(width: geo.size.width, height: 1)
            }
            .offset(y: y)
        }
        .allowsHitTesting(false)
    }
}
