import SwiftUI
import AppKit

/// Apple Calendar week-view style — auto-filled from recorded activity.
/// No manual input. Your day fills itself.
///
/// Two kinds of thing are drawn on the same time axis, and they are deliberately
/// *not* drawn alike:
///
///   - **Scheduled** (EventKit) — a commitment made in advance. Framed: an outlined
///     card. A record of intent, and not interactive.
///   - **Observed** (TimeBlockEngine) — evidence of what actually happened. Filled,
///     unframed, and it opens on click.
///
/// Geometry is honest: a span's coloured rule is always drawn at its true duration.
/// A very short span's *card* may be padded up to stay legible, but only as far as
/// the next span allows, and the padded part is drawn as a ghost — the reader is
/// never told four minutes was half an hour.
///
/// Design matches Apple Calendar as closely as possible:
///   - Flex-width day columns
///   - Today's date in a filled tobacco circle (DS.moon)
///   - Thin grid lines (0.5pt)
///   - Left color bar on blocks (not full background)
///   - Today's column has subtle background tint
///   - Auto-scrolls to the current hour once the grid has laid out
struct CalendarWeekView: View {
    @EnvironmentObject var appState: AppState
    /// When set by the parent (a search hit click), the view jumps to that day in Day mode.
    var jumpDate: Binding<Date?> = .constant(nil)
    @State private var weekOffset: Int = 0
    @State private var weekBlocks: [Date: [TimeBlock]] = [:]
    @State private var weekEvents: [Date: [CalendarEvent]] = [:]
    /// Day-shaped commitments — a flight, PTO, a birthday. They have no place on
    /// the hour axis, so they live in their own band above it (as Apple's do).
    @State private var weekAllDay: [Date: [CalendarEvent]] = [:]
    @State private var popoverBlock: TimeBlock?
    @State private var hoveredBlock: UUID?
    /// Whether EventKit is actually answering. An empty grid means two entirely
    /// different things depending on this, and the empty state has to say which.
    @State private var calendarAccess: CalendarService.Access = .granted

    enum CalMode: String, CaseIterable { case day = "Day", week = "Week", month = "Month", year = "Year" }
    @State private var mode: CalMode = .week
    @State private var dayOffset: Int = 0
    @State private var monthOffset: Int = 0
    @State private var monthData: [Date: (duration: TimeInterval, label: String)] = [:]
    @State private var yearOffset: Int = 0
    @State private var yearCounts: [Date: Int] = [:]
    /// Busiest day of the loaded year — hoisted out of `activeFraction`, which is
    /// called once per cell (365+ times) and used to re-scan every value each time.
    @State private var yearMax: Int = 1

    // Loading lives off the main thread: a week is 7 block analyses + 7 EventKit
    // round-trips, a month is up to 42, and a year is a full-range SQL aggregate.
    // `loadToken` invalidates a load whose result arrived after the user moved on.
    @State private var isLoading = false
    @State private var loadToken = 0
    /// The range whose data is currently on screen — `nil` while a load is in flight.
    /// This is what keeps the header and the body from ever disagreeing.
    @State private var loadedKey: String?

    /// The clock behind the "now" line. Read from state, not `Date()` during body —
    /// body only re-runs on state changes, so the line used to freeze mid-morning.
    @State private var now = Date()
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// The day everything in here is measured from. Every offset below is relative
    /// to "today", so this is the origin of the whole view — and a window left open
    /// overnight used to keep yesterday's origin: the header still said Today, and
    /// the blocks under it were the previous day's, because nothing had asked for a
    /// reload. Holding the origin in state lets a rollover invalidate `loadKey`, so
    /// the day mull is showing is always a day it has actually read.
    @State private var today = Calendar.current.startOfDay(for: Date())

    /// Opt out of the trimmed hour band and draw all 24 hours.
    @State private var showsFullDay = false

    /// The jump-to-date popover. Reaching a day three months back used to be a
    /// dozen chevron clicks; the grid keeps the focus so the arrow keys work.
    @State private var showingDatePicker = false
    @State private var pickerDate = Date()
    @FocusState private var gridFocused: Bool

    private let hourHeight: CGFloat = 50
    private let timeColumnWidth: CGFloat = 48

    /// The band shown when there is nothing to derive one from — an ordinary working
    /// day, so an empty grid still reads as a day rather than a sliver.
    private let defaultHourRange = 8..<20
    /// Never trim below this many hours; a two-hour grid reads as a bug.
    private let minVisibleHours = 6

    /// Legibility floor for a drawn span. Nothing is drawn shorter than this, and
    /// anything padded up to it is marked (see `SpanGeometry.isPadded`).
    private static let minSpanHeight: CGFloat = 18
    /// Breathing room kept between a padded span and the next one.
    private static let spanGap: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()
            modeContent
                .overlay(alignment: .top) {
                    if isLoading { loadingPill }
                }
        }
        // Keyboard navigation. The whole view takes focus so ← / → step by whatever
        // unit is on screen — a day, a week, a month, a year — without the reader
        // having to find the chevrons first. ⌘T comes home from anywhere.
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onAppear { gridFocused = true }
        .onMoveCommand { direction in
            switch direction {
            case .left:  step(-1)
            case .right: step(1)
            default:     break
            }
        }
        .background {
            Button("Today") { goToToday() }
                .keyboardShortcut("t", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onReceive(clock) { instant in
            now = instant
            // The notification below is the proper signal, but it is not guaranteed
            // to reach an app that slept through midnight. The minute tick is the
            // belt to its braces, and both converge on the same state.
            rollOver(to: instant)
        }
        .onReceive(NotificationCenter.default
            .publisher(for: .NSCalendarDayChanged)
            .receive(on: RunLoop.main)) { _ in
            // Posted off the main thread, hence the hop.
            rollOver(to: Date())
        }
        // One load per (mode, range). This replaces the four per-offset onChanges,
        // the mode onChange, and each subview's onAppear — which between them fired
        // two loads (14 EventKit round trips in Week) for a single mode switch.
        .onChange(of: loadKey, initial: true) { _, _ in
            // A pending jump is about to change the key; let it own the load.
            guard jumpDate.wrappedValue == nil else { return }
            loadCurrent()
        }
        .onAppear { applyJump() }
        .onChange(of: jumpDate.wrappedValue) { _, _ in applyJump() }
    }

    /// Move the origin when the calendar day turns under an open window. Cheap and
    /// idempotent, so both callers can fire it freely.
    private func rollOver(to instant: Date) {
        let start = Calendar.current.startOfDay(for: instant)
        guard start != today else { return }
        today = start
    }

    /// Identity of what is on screen. Everything that should cause a reload — and
    /// nothing that shouldn't — belongs in here. The origin day is part of that
    /// identity: "day|0" means a different day either side of midnight.
    private var loadKey: String {
        let origin = Int(today.timeIntervalSinceReferenceDate)
        switch mode {
        case .day:   return "day|\(origin)|\(dayOffset)"
        case .week:  return "week|\(origin)|\(weekOffset)"
        case .month: return "month|\(origin)|\(monthOffset)"
        case .year:  return "year|\(origin)|\(yearOffset)"
        }
    }

    private func loadCurrent() {
        switch mode {
        case .day:   loadDay()
        case .week:  loadWeek()
        case .month: loadMonth()
        case .year:  loadYear()
        }
    }

    @ViewBuilder
    private var modeContent: some View {
        switch mode {
        case .day:   dayContent
        case .week:  weekContent
        case .month: monthContent
        case .year:  yearContent
        }
    }

    /// A quiet note that the grid is still filling — the analysis now runs off the
    /// main thread, so the view is live (scrollable) while this is up.
    private var loadingPill: some View {
        HStack(spacing: DS.sm) {
            ProgressView().controlSize(.small)
            Text("Reading your activity…")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkDim)
        }
        .padding(.horizontal, DS.md)
        .padding(.vertical, DS.xs)
        .background(Capsule().fill(DS.surface))
        .overlay(Capsule().strokeBorder(DS.hairline, lineWidth: 0.75))
        .padding(.top, DS.sm)
        .transition(.opacity)
    }

    /// Honour a parent's request to open a specific day (from a search hit).
    private func applyJump() {
        guard let target = jumpDate.wrappedValue else { return }
        dayOffset = dayIndex(of: target)
        mode = .day
        jumpDate.wrappedValue = nil
        // No load here: changing the offset and mode changes `loadKey`, and the single
        // onChange above owns loading. Calling it here too is what used to make a jump
        // cost two loads.
    }

    /// Day | Week | Month | Year segmented switch.
    private var modeBar: some View {
        HStack {
            Picker("", selection: $mode) {
                ForEach(CalMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Calendar range")
            .frame(width: 280)
            Spacer()
        }
        .padding(.horizontal, DS.xl)
        .padding(.vertical, DS.sm)
    }

    private var weekContent: some View {
        VStack(spacing: 0) {
            weekHeader
            Divider()
            dayHeaders
            allDayBand
            Divider()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    calendarGrid
                        // Attached to the *content*, not the ScrollView: the hour ids
                        // don't exist until the rows are realised, which is why the
                        // old onAppear scroll missed and left the day pinned at 00:00.
                        .onAppear { scrollToAnchor(proxy) }
                        .onChange(of: loadedKey) { _, _ in scrollToAnchor(proxy) }
                        .onChange(of: showsFullDay) { _, _ in scrollToAnchor(proxy) }
                }
            }
            // Seven blank columns and a bare hour grid is what a new reader used to
            // open on, with nothing to say why.
            .overlay(alignment: .top) { weekEmptyState }
        }
    }

    // MARK: - Week empty state
    //
    // Week is the mode the app opens in, so this is the first screen a new reader
    // sees — and until now it was seven blank columns and a 24-hour grid, which
    // reads as a broken app rather than an empty record. It has to separate the
    // two reasons a week can be blank, because CalendarService answers both of
    // them with the same empty array.

    /// Nothing observed *and* nothing scheduled anywhere in the displayed week.
    private var weekIsEmpty: Bool {
        let cal = Calendar.current
        return weekDays.allSatisfy { date in
            let key = cal.startOfDay(for: date)
            return (weekBlocks[key] ?? []).isEmpty
                && (weekEvents[key] ?? []).isEmpty
                && (weekAllDay[key] ?? []).isEmpty
        }
    }

    @ViewBuilder
    private var weekEmptyState: some View {
        // Same rule as the day columns: say nothing about a week not yet read.
        if weekIsEmpty, !isLoading, loadedKey != nil {
            VStack(spacing: DS.sm) {
                if calendarAccess == .granted {
                    Text("Nothing recorded this week")
                        .font(DS.titleFont)
                        .foregroundStyle(DS.ink)
                    Text("mull fills this in as you work — no input needed.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkDim)
                } else {
                    Text("No calendar access, so no schedule here")
                        .font(DS.titleFont)
                        .foregroundStyle(DS.ink)
                    // Both halves of the grid are empty here, and only one of them
                    // has a cause worth acting on — so say which is which.
                    Text("Nothing observed this week either — mull fills that in as you work.")
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
            .background(
                RoundedRectangle(cornerRadius: DS.radiusMd).fill(DS.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusMd).strokeBorder(DS.hairline, lineWidth: 0.75)
            )
            .padding(.top, DS.xxl)
        }
    }

    /// The system only prompts once. After that the decision lives in System
    /// Settings, so that is where the button has to lead.
    private func grantCalendarAccess() {
        guard calendarAccess == .notDetermined else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        appState.calendar.requestAccess { granted in
            calendarAccess = granted ? .granted : .denied
            if granted { loadCurrent() }
        }
    }

    // MARK: - Day

    private var selectedDay: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: today) ?? today
    }

    private var dayContent: some View {
        VStack(spacing: 0) {
            dayHeader
            Divider()
            allDayBand
            dayTwoColumnHeaders   // SCHEDULED | ACTIVITY
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    dayTimeline
                        .onAppear { scrollToAnchor(proxy) }
                        .onChange(of: loadedKey) { _, _ in scrollToAnchor(proxy) }
                        .onChange(of: showsFullDay) { _, _ in scrollToAnchor(proxy) }
                }
            }
        }
    }

    /// Column headers: real calendar (left) vs what mull observed you doing (right).
    private var dayTwoColumnHeaders: some View {
        HStack(spacing: 0) {
            hourRangeToggle
            columnHeader("SCHEDULED", icon: "calendar")
            columnHeader("ACTIVITY", icon: "waveform")
        }
        .padding(.vertical, DS.xs)
    }

    private func columnHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: DS.xs) {
            Image(systemName: icon).font(.system(size: 9))
            Text(title).font(DS.miniFont).tracking(1.2)
        }
        .foregroundStyle(DS.inkFaint)
        .frame(maxWidth: .infinity)
    }

    /// Hour gutter + two parallel timelines on the same time axis:
    /// left = real EventKit events, right = mull's captured activity blocks.
    private var dayTimeline: some View {
        // `hourRange` scans every block and event in the displayed range, so it is
        // resolved once here and threaded down rather than re-derived per span.
        let range = hourRange
        let dayKey = Calendar.current.startOfDay(for: selectedDay)
        let blocks = weekBlocks[dayKey] ?? []
        let events = weekEvents[dayKey] ?? []
        let eventGeo = layoutSpans(events.map { (start: $0.start, end: $0.end) },
                                   origin: range.lowerBound, day: selectedDay)
        let blockGeo = layoutSpans(blocks.map { (start: $0.start, end: $0.end) },
                                   origin: range.lowerBound, day: selectedDay)
        let isToday = Calendar.current.isDateInToday(selectedDay)
        return HStack(alignment: .top, spacing: 0) {
            timeLabels(range)
            timelineColumn(range: range, isToday: isToday,
                           isEmpty: events.isEmpty, emptyText: "No events") {
                GeometryReader { geo in
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        let slice = spanSlice(eventGeo[index], laneX: 3,
                                              laneWidth: max(geo.size.width - 6, 12))
                        calendarEventView(event: event, width: slice.width,
                                          geometry: eventGeo[index])
                            .offset(x: slice.x, y: eventGeo[index].y)
                    }
                }
            }
            Divider()
            timelineColumn(range: range, isToday: isToday,
                           isEmpty: blocks.isEmpty, emptyText: "No activity recorded") {
                GeometryReader { geo in
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        let slice = spanSlice(blockGeo[index], laneX: 3,
                                              laneWidth: max(geo.size.width - 6, 12))
                        blockView(block: block, width: slice.width,
                                  geometry: blockGeo[index])
                            .offset(x: slice.x, y: blockGeo[index].y)
                    }
                }
            }
        }
    }

    /// One timeline column: hour grid lines + positioned content + now-line + empty hint.
    private func timelineColumn<Content: View>(
        range: Range<Int>, isToday: Bool, isEmpty: Bool, emptyText: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let totalHeight = CGFloat(range.count) * hourHeight
        return ZStack(alignment: .topLeading) {
            if isToday { Rectangle().fill(DS.moon.opacity(0.03)) }
            VStack(spacing: 0) {
                ForEach(range, id: \.self) { _ in
                    Color.clear.frame(height: hourHeight)
                        .overlay(alignment: .top) {
                            Rectangle().fill(DS.hairline).frame(height: 0.5)
                        }
                }
            }
            content()
            if isToday { nowIndicator(range) }
            // Only claim emptiness once we actually know. While a load is in flight the
            // grid says nothing rather than "No activity recorded" about a day it hasn't read.
            if isEmpty, !isLoading, loadedKey != nil {
                Text(emptyText)
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, totalHeight * 0.38)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: totalHeight)
        .clipped()
    }

    private var dayHeader: some View {
        calendarHeader(
            title: Self.fullDayLabel(selectedDay),
            todayLabel: "Today",
            isAtToday: dayOffset == 0,
            canGoForward: dayOffset < 0,
            back: { dayOffset -= 1 },
            forward: { dayOffset += 1 },
            today: { dayOffset = 0 }
        )
    }

    private func loadDay() {
        let day = selectedDay
        let key = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: key) ?? key
        let database = appState.database
        let calendarService = appState.calendar
        let rangeKey = loadKey
        let token = beginLoad()
        // The header already reads the new day — yesterday's blocks must not sit under it.
        weekBlocks = [:]
        weekEvents = [:]
        weekAllDay = [:]
        calendarAccess = calendarService.accessState

        Task.detached(priority: .userInitiated) {
            let engine = TimeBlockEngine(database: database)
            let blocks = engine.generateBlocks(for: day)
            let events = calendarService.dayEvents(from: key, to: dayEnd)
            await MainActor.run {
                guard finishLoad(token, key: rangeKey) else { return }
                weekBlocks[key] = blocks
                weekEvents = events.timed
                weekAllDay = events.allDay
            }
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

    // MARK: - Shared header
    //
    // One header for all four modes. It exists because the four hand-rolled copies
    // each carried the same two defects: a "Today" button that shoved the centred
    // title sideways the moment it appeared, and a disabled forward arrow painted in
    // the *enabled* colour — an explicit .foregroundStyle beats SwiftUI's disabled
    // dimming, so a dead control looked live.

    private func calendarHeader(
        title: String,
        todayLabel: String,
        isAtToday: Bool,
        canGoForward: Bool,
        back: @escaping () -> Void,
        forward: @escaping () -> Void,
        today: @escaping () -> Void
    ) -> some View {
        HStack(spacing: DS.sm) {
            navArrow("chevron.left", enabled: true, hint: "Go back", action: back)

            Spacer(minLength: DS.md)

            // Laid out whether or not it is offered, so nothing beside it ever shifts.
            Button(todayLabel, action: today)
                .font(DS.captionFont)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .opacity(isAtToday ? 0 : 1)
                .disabled(isAtToday)
                .accessibilityHidden(isAtToday)

            navArrow("chevron.right", enabled: canGoForward,
                     hint: canGoForward ? "Go forward" : "Nothing recorded past today",
                     action: forward)

            jumpButton
        }
        // The title is an overlay rather than a member of the row, so it is centred on
        // the header itself and cannot be pushed around by its neighbours.
        .overlay {
            Text(title)
                .font(DS.titleFont)
                .foregroundStyle(DS.ink)
                .lineLimit(1)
                .padding(.horizontal, 150)
        }
        .padding(.horizontal, DS.xl)
        .padding(.vertical, DS.sm)
    }

    /// Go straight to a date rather than walking to it. Last April was twelve
    /// clicks of the back chevron before this existed.
    private var jumpButton: some View {
        Button { pickerDate = anchorDate; showingDatePicker = true } label: {
            Image(systemName: "calendar")
                .font(DS.bodyFont)
                .foregroundStyle(DS.inkDim)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to a date (← → to step, ⌘T for today)")
        .accessibilityLabel("Jump to a date")
        .accessibilityHint("Opens a date picker. Left and right arrows step by one period.")
        .pointingHandCursor()
        .popover(isPresented: $showingDatePicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DS.sm) {
                Text("Jump to")
                    .font(DS.captionMedium)
                    .foregroundStyle(DS.inkDim)
                // Bounded at today for the same reason the forward chevron is:
                // there is nothing recorded past this moment to go and look at.
                DatePicker("", selection: $pickerDate, in: ...Date(),
                           displayedComponents: .date)
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

    private func navArrow(_ symbol: String, enabled: Bool, hint: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(DS.bodyFont)
                // Explicit, because .buttonStyle(.plain) plus a foregroundStyle means
                // SwiftUI's own disabled dimming never reaches the glyph.
                .foregroundStyle(enabled ? DS.inkDim : DS.inkFaint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(hint)
        // `hint` already reads as a spoken label ("Go back", "Nothing recorded
        // past today"), so it serves for both — unlike the tooltips that carry a
        // key equivalent, which must not be spoken verbatim.
        .accessibilityLabel(hint)
        .pointingHandCursor(enabled)
    }

    // MARK: - Week Header

    private var weekHeader: some View {
        calendarHeader(
            title: weekRangeLabel,
            todayLabel: "This week",
            isAtToday: weekOffset == 0,
            canGoForward: weekOffset < 0,
            back: { weekOffset -= 1 },
            forward: { weekOffset += 1 },
            today: { weekOffset = 0 }
        )
    }

    /// The actual span of the displayed week, not merely its month — the old label
    /// said "September 2025" for all five of September's weeks. Parts the two ends
    /// share are said once: "15 – 21 September 2025", "29 September – 5 October 2025",
    /// "30 December 2024 – 5 January 2025".
    ///
    /// The three patterns are templates, not literal formats: `d MMMM yyyy` is fixed
    /// British order and read wrongly on a Japanese machine, whereas the template is
    /// rearranged by the locale into 2025年9月21日.
    private var weekRangeLabel: String {
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

    // MARK: - Day Headers (sticky, doesn't scroll)

    private var dayHeaders: some View {
        HStack(spacing: 0) {
            hourRangeToggle

            ForEach(weekDays, id: \.self) { date in
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
            }
        }
        .padding(.vertical, DS.xs)
    }

    // MARK: - All-day band
    //
    // A flight, a week of PTO, a birthday. These were dropped at the source and so
    // appeared nowhere in mull at all — and nothing said they had been dropped.
    // They can't be put on an hour axis honestly (a birthday did not take 24 hours),
    // so they sit in their own band under the day headers, the way Apple's do, and
    // stay out of the timed grid's layout entirely.

    @ViewBuilder
    private var allDayBand: some View {
        let cal = Calendar.current
        let days = displayedDays
        let rows = days.map { weekAllDay[cal.startOfDay(for: $0)] ?? [] }

        if rows.contains(where: { !$0.isEmpty }) {
            HStack(alignment: .top, spacing: 0) {
                Text("ALL-DAY")
                    .font(DS.miniFont)
                    .tracking(0.8)
                    .foregroundStyle(DS.inkFaint)
                    .frame(width: timeColumnWidth, alignment: .trailing)

                ForEach(Array(days.enumerated()), id: \.offset) { index, _ in
                    VStack(alignment: .leading, spacing: DS.hair) {
                        ForEach(rows[index]) { allDayChip($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 1)
                }
            }
            .padding(.vertical, DS.xs)
        }
    }

    /// Outlined like a scheduled event, because that is what it is — a commitment
    /// made in advance — only without a time to put it against.
    private func allDayChip(_ event: CalendarEvent) -> some View {
        Text(event.title)
            .font(DS.miniMedium)
            .foregroundStyle(DS.ink)
            .lineLimit(1)
            .padding(.horizontal, DS.xs)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusChip)
                    .fill(event.color.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusChip)
                    .strokeBorder(event.color.opacity(0.45), lineWidth: 0.75)
            )
            .help("\(event.title) · all day")
    }

    // MARK: - Hour band
    //
    // The grid used to draw all 24 hours, always, so opening a day meant scrolling
    // past eight empty night hours to reach anything. It now draws the band the day
    // actually occupies — with an hour of margin either side — and offers the rest.

    /// Hours the grid draws, as a half-open range.
    private var hourRange: Range<Int> {
        if showsFullDay { return 0..<24 }
        let cal = Calendar.current
        var lo = 24
        var hi = 0

        for date in displayedDays {
            let key = cal.startOfDay(for: date)
            for block in weekBlocks[key] ?? [] {
                let band = hourBand(from: block.start, to: block.end, in: date)
                lo = min(lo, band.0); hi = max(hi, band.1)
            }
            for event in weekEvents[key] ?? [] {
                let band = hourBand(from: event.start, to: event.end, in: date)
                lo = min(lo, band.0); hi = max(hi, band.1)
            }
            if cal.isDateInToday(date) {
                let h = cal.component(.hour, from: now)
                lo = min(lo, h); hi = max(hi, h + 1)
            }
        }

        guard lo < hi else { return defaultHourRange }
        lo = max(0, lo - 1)
        hi = min(24, hi + 1)
        if hi - lo < minVisibleHours {
            hi = min(24, lo + minVisibleHours)
            lo = max(0, hi - minVisibleHours)
        }
        return lo..<hi
    }

    /// The hour band a span occupies *within the day it is drawn on*.
    ///
    /// Both ends are clamped to that day, which is what the grid does with them:
    /// an event that began at 22:00 yesterday and is being drawn on today's column
    /// occupies hour 0 here, not hour 22 — reporting 22 dragged the whole week's
    /// band down to cover a night nothing had happened in.
    private func hourBand(from start: Date, to end: Date, in day: Date) -> (Int, Int) {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let from = max(start, dayStart)
        let to = min(max(end, from), dayEnd)

        let lo = cal.component(.hour, from: from)
        guard to < dayEnd else { return (lo, 24) }
        let h = cal.component(.hour, from: to)
        let m = cal.component(.minute, from: to)
        return (lo, min(24, max(h + (m > 0 ? 1 : 0), lo + 1)))
    }

    /// The days the current hour band is derived from.
    private var displayedDays: [Date] {
        mode == .day ? [selectedDay] : weekDays
    }

    /// Sits in the hour gutter. Only offered when something is in fact hidden.
    @ViewBuilder
    private var hourRangeToggle: some View {
        if showsFullDay || hourRange.lowerBound > 0 || hourRange.upperBound < 24 {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showsFullDay.toggle() }
            } label: {
                Image(systemName: showsFullDay ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.inkFaint)
                    .frame(width: timeColumnWidth, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(showsFullDay ? "Trim to the hours you were here"
                               : "Show the whole 24-hour day")
            .accessibilityLabel(showsFullDay ? "Trim to the hours you were here"
                                             : "Show the whole 24-hour day")
        } else {
            Spacer().frame(width: timeColumnWidth)
        }
    }

    /// Where a freshly laid-out grid should sit: an hour before now when the range
    /// contains today, otherwise the top of the band.
    private var scrollAnchorHour: Int {
        let range = hourRange
        guard displayedDays.contains(where: { Calendar.current.isDateInToday($0) }) else {
            return range.lowerBound
        }
        let target = Calendar.current.component(.hour, from: now) - 1
        return min(max(target, range.lowerBound), max(range.upperBound - 1, range.lowerBound))
    }

    /// Scroll once the rows exist. Calling `scrollTo` straight out of `onAppear` races
    /// the first layout pass and silently no-ops — which is how the day used to open
    /// pinned at midnight. Hopping to the next runloop lands after layout; the second
    /// hop covers the case where the data (and so the band) settles a beat later.
    private func scrollToAnchor(_ proxy: ScrollViewProxy) {
        let target = scrollAnchorHour
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .top)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                proxy.scrollTo(target, anchor: .top)
            }
        }
    }

    // MARK: - Calendar Grid

    private var calendarGrid: some View {
        let range = hourRange   // resolved once for the whole grid, not per span
        return HStack(alignment: .top, spacing: 0) {
            timeLabels(range)
            ForEach(weekDays, id: \.self) { date in
                dayColumn(date: date, range: range)
            }
        }
    }

    private func timeLabels(_ range: Range<Int>) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(range, id: \.self) { hour in
                Text(hour == 0 ? "" : String(format: "%d", hour))
                    .font(DS.microFont)
                    .foregroundStyle(DS.inkFaint)
                    .frame(width: timeColumnWidth, height: hourHeight, alignment: .topTrailing)
                    .padding(.trailing, DS.sm)
                    .offset(y: -6) // Align with grid line
                    .id(hour) // For scroll target
            }
        }
    }

    private func dayColumn(date: Date, range: Range<Int>) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(date)
        let dayKey = calendar.startOfDay(for: date)
        let blocks = weekBlocks[dayKey] ?? []
        let events = weekEvents[dayKey] ?? []
        let eventGeo = layoutSpans(events.map { (start: $0.start, end: $0.end) },
                                   origin: range.lowerBound, day: date)
        let blockGeo = layoutSpans(blocks.map { (start: $0.start, end: $0.end) },
                                   origin: range.lowerBound, day: date)

        return ZStack(alignment: .topLeading) {
            // Background: today gets a subtle tint
            if isToday {
                Rectangle()
                    .fill(DS.moon.opacity(0.03))
            }

            // Grid lines — thin, Apple-style
            VStack(spacing: 0) {
                ForEach(range, id: \.self) { _ in
                    Color.clear
                        .frame(height: hourHeight)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(DS.hairline)
                                .frame(height: 0.5)
                        }
                }
            }

            // Two sub-columns: scheduled (left) + observed (right)
            GeometryReader { geo in
                let hasEvents = !events.isEmpty
                let eventWidth = hasEvents ? geo.size.width * 0.38 : 0
                let blockWidth = hasEvents ? geo.size.width * 0.60 : geo.size.width

                if hasEvents {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        let slice = spanSlice(eventGeo[index], laneX: 1, laneWidth: eventWidth)
                        calendarEventView(event: event, width: slice.width, geometry: eventGeo[index])
                            .offset(x: slice.x, y: eventGeo[index].y)
                    }
                }

                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    let slice = spanSlice(blockGeo[index],
                                          laneX: hasEvents ? eventWidth + 2 : 0,
                                          laneWidth: blockWidth)
                    blockView(block: block, width: slice.width, geometry: blockGeo[index])
                        .offset(x: slice.x, y: blockGeo[index].y)
                }
            }

            // Now indicator
            if isToday {
                nowIndicator(range)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(range.count) * hourHeight)
        .clipped()
    }

    // MARK: - Span geometry

    /// Where a span sits, how tall it is drawn, and how tall its minutes alone say it
    /// should be. When the two differ, the card has been padded up to stay legible —
    /// and the view has to say so rather than misreport a duration.
    ///
    /// `column` / `columns` place it side by side with anything it overlaps, and
    /// `continuesBefore` / `continuesAfter` say that it runs past the edge of the
    /// day being drawn rather than beginning or ending there.
    private struct SpanGeometry {
        let y: CGFloat
        let height: CGFloat
        let trueHeight: CGFloat
        var column: Int = 0
        var columns: Int = 1
        var continuesBefore: Bool = false
        var continuesAfter: Bool = false
        var isPadded: Bool { height > trueHeight + 0.5 }
    }

    /// Lay spans out on the time axis of one particular day.
    ///
    /// Three things happen here, and the middle one is the reason the others are
    /// not enough on their own:
    ///
    /// 1. Each span is clamped to `day`. A span running 23:40 → 00:50 used to be
    ///    drawn from its own hour to a height past the bottom of the grid, where it
    ///    was silently clipped; now it stops at midnight and says it continues.
    /// 2. Overlapping spans are grouped into clusters and given a column each, as
    ///    Apple Calendar does. They used to be stacked at the same x in a ZStack,
    ///    so the earlier of two overlapping meetings was both invisible *and*
    ///    unclickable — the later one covered it entirely.
    /// 3. A short span is padded up to the legibility floor, but only as far as the
    ///    next span in its own column allows, so padding can never make two
    ///    consecutive spans appear to overlap.
    private func layoutSpans(_ intervals: [(start: Date, end: Date)],
                             origin: Int, day: Date) -> [SpanGeometry] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // 1 — clamp to the rendered day.
        var geo: [SpanGeometry] = intervals.map { interval in
            let start = max(interval.start, dayStart)
            let end = min(max(interval.end, start), dayEnd)
            let y = yOffsetForDate(start, origin: origin)
            let trueHeight = max(hourHeight * end.timeIntervalSince(start) / 3600, 1)
            return SpanGeometry(y: y, height: trueHeight, trueHeight: trueHeight,
                                continuesBefore: interval.start < dayStart,
                                continuesAfter: interval.end > dayEnd)
        }

        // 2 — cluster by true extent, then hand out columns within each cluster.
        for cluster in overlapClusters(geo) {
            var columnEnds: [CGFloat] = []
            for i in cluster {
                let free = columnEnds.firstIndex { $0 <= geo[i].y + 0.5 }
                let column = free ?? columnEnds.count
                if free == nil { columnEnds.append(0) }
                columnEnds[column] = geo[i].y + geo[i].trueHeight
                geo[i].column = column
            }
            // Every member of a cluster is cut to the same width, so a column of
            // meetings doesn't change width halfway down the hour.
            for i in cluster { geo[i].columns = max(columnEnds.count, 1) }
        }

        // 3 — pad short spans, but only into space no one else in the column holds.
        for i in geo.indices {
            let nextY = geo.indices
                .filter { $0 != i && geo[$0].column == geo[i].column && geo[$0].y > geo[i].y + 0.5 }
                .map { geo[$0].y }
                .min() ?? .greatestFiniteMagnitude
            let room = max(nextY - geo[i].y - Self.spanGap, 2)
            geo[i] = SpanGeometry(y: geo[i].y,
                                  height: max(geo[i].trueHeight, min(Self.minSpanHeight, room)),
                                  trueHeight: geo[i].trueHeight,
                                  column: geo[i].column,
                                  columns: geo[i].columns,
                                  continuesBefore: geo[i].continuesBefore,
                                  continuesAfter: geo[i].continuesAfter)
        }
        return geo
    }

    /// Indices grouped so that every span sharing a group overlaps at least one
    /// other member of it — the unit that has to share the available width.
    private func overlapClusters(_ geo: [SpanGeometry]) -> [[Int]] {
        let order = geo.indices.sorted { geo[$0].y < geo[$1].y }
        var clusters: [[Int]] = []
        var current: [Int] = []
        var clusterEnd: CGFloat = -.greatestFiniteMagnitude

        for i in order {
            if current.isEmpty || geo[i].y < clusterEnd - 0.5 {
                current.append(i)
                clusterEnd = max(clusterEnd, geo[i].y + geo[i].trueHeight)
            } else {
                clusters.append(current)
                current = [i]
                clusterEnd = geo[i].y + geo[i].trueHeight
            }
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    /// The horizontal slice of a lane a span gets, given the column it landed in.
    private func spanSlice(_ geometry: SpanGeometry,
                           laneX: CGFloat, laneWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let width = laneWidth / CGFloat(max(geometry.columns, 1))
        return (laneX + width * CGFloat(geometry.column), width)
    }

    /// Drawn at whichever edge the span runs past — the reader is told the span was
    /// cut by midnight, not that it began or ended there.
    @ViewBuilder
    private func continuationMark(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(tint.opacity(0.75))
            .padding(.horizontal, DS.hair)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The wash behind a span. The true extent takes the full tint; whatever the card
    /// was padded by fades to a ghost, so a four-minute block never passes for half an hour.
    private func spanWash(_ tint: Color, geometry: SpanGeometry, strength: Double) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: DS.radiusChip)
                .fill(tint.opacity(geometry.isPadded ? strength * 0.3 : strength))
            if geometry.isPadded {
                RoundedRectangle(cornerRadius: DS.radiusChip)
                    .fill(tint.opacity(strength))
                    .frame(height: max(geometry.trueHeight, 2))
            }
        }
    }

    /// The coloured rule down a span's left edge, drawn at its *true* duration —
    /// never at the padded card height.
    private func spanRule(_ tint: Color, geometry: SpanGeometry) -> some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: DS.radiusXs)
                .fill(tint)
                .frame(width: 3, height: max(min(geometry.trueHeight, geometry.height), 2))
            Spacer(minLength: 0)
        }
    }

    // MARK: - Scheduled event (a commitment — outlined, not interactive)

    private func calendarEventView(event: CalendarEvent, width: CGFloat,
                                   geometry: SpanGeometry) -> some View {
        let height = geometry.height
        return HStack(spacing: 0) {
            spanRule(event.color, geometry: geometry)

            VStack(alignment: .leading, spacing: DS.hair) {
                Text(event.title)
                    .font(DS.miniMedium)
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)

                if height >= 30 {
                    Text(event.timeFormatted)
                        .font(DS.miniFont)
                        .foregroundStyle(DS.inkDim)
                        .lineLimit(1)
                }
            }
            .padding(.leading, DS.xs)
            .padding(.vertical, DS.radiusXs)

            Spacer(minLength: 0)
        }
        .frame(width: max(width - 2, 12), height: height, alignment: .topLeading)
        .background(spanWash(event.color, geometry: geometry, strength: 0.10))
        // Outlined: a commitment made in advance is a frame, drawn before the fact.
        // The observed block beside it is filled and unframed — two kinds, two looks,
        // and only one of them responds to the pointer.
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusChip)
                .strokeBorder(event.color.opacity(0.45), lineWidth: 0.75)
        )
        .overlay(alignment: .top) {
            if geometry.continuesBefore { continuationMark("chevron.up", tint: event.color) }
        }
        .overlay(alignment: .bottom) {
            if geometry.continuesAfter { continuationMark("chevron.down", tint: event.color) }
        }
        // A short event has no room for its times inline; it still has to be readable.
        .help("\(event.title) · \(event.timeFormatted)\(Self.continuationNote(geometry))")
    }

    /// The tooltip half of the continuation marker — a chevron alone doesn't say
    /// which day the rest of the span is on.
    private static func continuationNote(_ geometry: SpanGeometry) -> String {
        switch (geometry.continuesBefore, geometry.continuesAfter) {
        case (true, true):   return " · runs through this whole day"
        case (true, false):  return " · continues from the previous day"
        case (false, true):  return " · continues into the next day"
        case (false, false): return ""
        }
    }

    // MARK: - Observed activity block (evidence — filled, and it opens)

    private func blockView(block: TimeBlock, width: CGFloat,
                           geometry: SpanGeometry) -> some View {
        let height = geometry.height
        let isHovered = hoveredBlock == block.id

        return Button { popoverBlock = block } label: {
            HStack(spacing: 0) {
                spanRule(block.color, geometry: geometry)

                VStack(alignment: .leading, spacing: DS.hair) {
                    Text(block.app)
                        .font(DS.miniMedium)
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)

                    if height >= 46, !block.label.isEmpty, block.label != block.app {
                        Text(block.label)
                            .font(DS.miniFont)
                            .foregroundStyle(DS.inkDim)
                            .lineLimit(1)
                    }

                    // Multitasking blocks own up to the apps they wove through.
                    if height >= 62, !block.secondaryApps.isEmpty {
                        Text("+ " + block.secondaryApps.prefix(2).joined(separator: ", "))
                            .font(DS.miniFont)
                            .foregroundStyle(DS.inkFaint)
                            .lineLimit(1)
                    }

                    // Was gated at >60pt, which meant anything under ~72 minutes showed
                    // no time at all. A second line fits from 32pt; below that the
                    // tooltip and the popover carry it.
                    if height >= 32 {
                        Text(block.durationFormatted)
                            .font(DS.miniFont)
                            .foregroundStyle(DS.inkFaint)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, DS.xs)
                .padding(.vertical, DS.radiusXs)

                Spacer(minLength: 0)
            }
            .frame(width: max(width - 2, 12), height: height, alignment: .topLeading)
            .background(spanWash(block.color, geometry: geometry, strength: isHovered ? 0.20 : 0.12))
            // No resting border — filled and unframed, the opposite of a scheduled
            // event. The tobacco edge appears on hover, and this is the only thing on
            // the grid that can be clicked.
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusChip)
                    .strokeBorder(isHovered ? DS.moon.opacity(0.55) : Color.clear, lineWidth: 0.75)
            )
            .overlay(alignment: .top) {
                if geometry.continuesBefore { continuationMark("chevron.up", tint: block.color) }
            }
            .overlay(alignment: .bottom) {
                if geometry.continuesAfter { continuationMark("chevron.down", tint: block.color) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(block.startFormatted) – \(block.endFormatted) · \(block.durationFormatted)"
              + (block.label.isEmpty || block.label == block.app ? "" : " · \(block.label)")
              + Self.continuationNote(geometry))
        .onHover { hovering in
            if hovering {
                hoveredBlock = block.id
                NSCursor.pointingHand.push()
            } else {
                if hoveredBlock == block.id { hoveredBlock = nil }
                NSCursor.pop()
            }
        }
        .onDisappear {
            if hoveredBlock == block.id {
                hoveredBlock = nil
                NSCursor.pop()
            }
        }
        // Anchored to the block, not to the window. This used to hang off the root
        // VStack, so every block's detail popped from the same spot at the top.
        .popover(isPresented: popoverBinding(for: block), arrowEdge: .trailing) {
            blockDetail(block)
        }
    }

    private func popoverBinding(for block: TimeBlock) -> Binding<Bool> {
        Binding(
            get: { popoverBlock?.id == block.id },
            set: { shown in
                if shown { popoverBlock = block }
                else if popoverBlock?.id == block.id { popoverBlock = nil }
            }
        )
    }

    // MARK: - Now Indicator (tobacco line + dot, Apple-style placement)

    @ViewBuilder
    private func nowIndicator(_ range: Range<Int>) -> some View {
        // `now` is ticked by the view's clock; reading Date() here would pin the line
        // to whenever the grid last happened to re-render.
        let hour = Calendar.current.component(.hour, from: now)
        // Trimming can put the present outside the drawn band (a past day, or the
        // full-day view scrolled to a night hour) — then there is no line to draw.
        if range.contains(hour) {
            let minute = Calendar.current.component(.minute, from: now)
            let y = CGFloat(hour - range.lowerBound) * hourHeight + CGFloat(minute) / 60.0 * hourHeight

            GeometryReader { geo in
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
        }
    }

    // MARK: - Block Detail Popover

    private func blockDetail(_ block: TimeBlock) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                RoundedRectangle(cornerRadius: DS.radiusXs)
                    .fill(block.color)
                    .frame(width: 4, height: 24)
                VStack(alignment: .leading, spacing: DS.hair) {
                    Text(block.app)
                        .font(DS.bodyMedium)
                    if !block.label.isEmpty && block.label != block.app {
                        Text(block.label)
                            .font(DS.captionFont)
                            .foregroundStyle(DS.inkDim)
                    }
                }
            }

            Divider()

            HStack(spacing: DS.md) {
                Label(block.startFormatted + " – " + block.endFormatted, systemImage: "clock")
                    .font(DS.captionFont)
                Label(block.durationFormatted, systemImage: "hourglass")
                    .font(DS.captionFont)
                // A bare number beside a "#" glyph left the reader to guess what had
                // been counted. It is captures, and it says so.
                Label(pluralized(block.eventCount, "capture"), systemImage: "number")
                    .font(DS.captionFont)
            }
            .foregroundStyle(DS.inkDim)

            // Which other apps this session wove through, with their dots.
            if !block.secondaryApps.isEmpty {
                HStack(spacing: DS.xs) {
                    Image(systemName: "square.on.square")
                        .font(DS.miniFont)
                        .foregroundStyle(DS.inkFaint)
                    ForEach(block.secondaryApps.prefix(4), id: \.self) { name in
                        HStack(spacing: DS.hair) {
                            Circle().fill(DS.appColor(name)).frame(width: 5, height: 5)
                            Text(name).font(DS.captionFont).foregroundStyle(DS.inkDim)
                        }
                    }
                }
            }

            if let title = block.topWindowTitle {
                HStack(spacing: DS.xs) {
                    Image(systemName: "doc.text")
                        .font(DS.miniFont)
                        .foregroundStyle(DS.inkFaint)
                    Text(title)
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkDim)
                        .lineLimit(2)
                }
            }

            if let clip = block.topClipboard {
                HStack(spacing: DS.xs) {
                    Image(systemName: "text.quote")
                        .font(DS.miniFont)
                        .foregroundStyle(DS.inkFaint)
                    Text("\"\(String(clip.prefix(100)))\"")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                        .italic()
                        .lineLimit(2)
                }
            }
        }
        .padding(DS.lg)
        .frame(width: 280)
    }

    // MARK: - Data Loading

    /// A week is 7 full day analyses plus 7 blocking EventKit fetches. Doing that on
    /// the main thread froze the window on every arrow-key week change; it now runs
    /// detached and publishes once. The analysis itself is unchanged.
    ///
    /// The calendar side is one round trip for the whole week — `dayEvents(from:to:)`
    /// takes the range and hands back both the timed events and the all-day ones.
    private func loadWeek() {
        let (weekStart, _) = weekRange
        let database = appState.database
        let calendarService = appState.calendar
        let rangeKey = loadKey
        let token = beginLoad()
        // Never let last week's grid sit under this week's header.
        weekBlocks = [:]
        weekEvents = [:]
        weekAllDay = [:]
        calendarAccess = calendarService.accessState

        Task.detached(priority: .userInitiated) {
            let engine = TimeBlockEngine(database: database)
            var blockResult: [Date: [TimeBlock]] = [:]

            for offset in 0..<7 {
                guard let date = Calendar.current.date(byAdding: .day, value: offset, to: weekStart) else { continue }
                let dayKey = Calendar.current.startOfDay(for: date)
                blockResult[dayKey] = engine.generateBlocks(for: date)
            }

            // One EventKit round trip for the whole week, not seven. Days with
            // nothing scheduled come back absent, which the grid already reads
            // as empty.
            let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
            let eventResult = calendarService.dayEvents(from: weekStart, to: weekEnd)

            await MainActor.run {
                guard finishLoad(token, key: rangeKey) else { return }
                weekBlocks = blockResult
                weekEvents = eventResult.timed
                weekAllDay = eventResult.allDay
            }
        }
    }

    /// Claim a load slot. A newer load supersedes an older one, so a slow week that
    /// lands after the user already paged elsewhere is dropped instead of flickering in.
    /// Clearing `loadedKey` also marks the on-screen data as belonging to nothing, which
    /// is what stops the empty states asserting anything mid-load.
    private func beginLoad() -> Int {
        loadToken += 1
        isLoading = true
        loadedKey = nil
        return loadToken
    }

    /// True when `token` is still the newest load (and the spinner should come down).
    /// Records which range the on-screen data belongs to.
    private func finishLoad(_ token: Int, key: String) -> Bool {
        guard loadToken == token else { return false }
        isLoading = false
        loadedKey = key
        return true
    }

    // MARK: - Navigation
    //
    // Three ways to the same place: the header chevrons, the arrow keys, and the
    // date picker. They all go through these, so none of them can drift from the
    // others — and none of them can walk into a future there is no record of.

    /// The date the view is currently showing, whatever unit it is showing it in.
    private var anchorDate: Date {
        switch mode {
        case .day:   return selectedDay
        case .week:  return weekRange.0
        case .month: return displayedMonth
        case .year:  return displayedYear
        }
    }

    /// Move by one of whatever unit is on screen, clamped at the present exactly
    /// as the forward chevron is.
    private func step(_ delta: Int) {
        switch mode {
        case .day:   dayOffset = min(dayOffset + delta, 0)
        case .week:  weekOffset = min(weekOffset + delta, 0)
        case .month: monthOffset = min(monthOffset + delta, 0)
        case .year:  yearOffset = min(yearOffset + delta, 0)
        }
    }

    /// ⌘T. All four offsets reset, so switching mode afterwards also lands on now.
    private func goToToday() {
        dayOffset = 0
        weekOffset = 0
        monthOffset = 0
        yearOffset = 0
    }

    /// Open a specific date in the unit currently on screen.
    private func jump(to date: Date) {
        switch mode {
        case .day:   dayOffset = dayIndex(of: date)
        case .week:  weekOffset = weekIndex(of: date)
        case .month: monthOffset = monthIndex(of: date)
        case .year:  yearOffset = yearIndex(of: date)
        }
    }

    func dayIndex(of date: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: today,
                                  to: cal.startOfDay(for: date)).day ?? 0
    }

    /// Weeks between the week holding `date` and the week holding today.
    ///
    /// The old form divided a raw day-delta by seven and truncated, which is not
    /// the same question: the day before the week turns is −1 day → offset 0 →
    /// *this* week, which begins today and does not contain the day that was
    /// clicked. Diffing the two week-starts cannot be off by a week.
    func weekIndex(of date: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.weekOfYear], from: startOfWeek(today),
                                  to: startOfWeek(date)).weekOfYear ?? 0
    }

    func monthIndex(of date: Date) -> Int {
        let cal = Calendar.current
        let base = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        let target = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
        return cal.dateComponents([.month], from: base, to: target).month ?? 0
    }

    func yearIndex(of date: Date) -> Int {
        let cal = Calendar.current
        return cal.component(.year, from: date) - cal.component(.year, from: today)
    }

    // MARK: - Helpers

    /// The first day of the week `date` falls in — the anchor the whole week view is
    /// built on, in one place so `weekRange` and `weekIndex` cannot disagree.
    ///
    /// Which day that is belongs to the reader, not to us: a machine set to 日曜始まり
    /// gets Sunday, one set to Monday gets Monday. The old arithmetic pinned it to
    /// Monday, which put the Week and Month views out of step with the Year view on
    /// the same screen.
    func startOfWeek(_ date: Date) -> Date {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let offset = (calendar.component(.weekday, from: day) - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: day) ?? day
    }

    private var weekRange: (Date, Date) {
        let calendar = Calendar.current
        let thisWeek = startOfWeek(today)
        guard let start = calendar.date(byAdding: .day, value: weekOffset * 7, to: thisWeek),
              let end = calendar.date(byAdding: .day, value: 6, to: start) else {
            return (thisWeek, thisWeek)
        }
        return (start, end)
    }

    private var weekDays: [Date] {
        let (start, _) = weekRange
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }

    /// Weekday names ordered from the system's first weekday. All three grids read
    /// their column headings from here, so one screen cannot label its columns two
    /// different ways depending on which range the reader happens to be in.
    func orderedWeekdaySymbols(_ symbols: KeyPath<Calendar, [String]>) -> [String] {
        let cal = Calendar.current
        let names = cal[keyPath: symbols]   // index 0 is always Sunday
        return (0..<7).map { names[(cal.firstWeekday - 1 + $0) % 7] }
    }

    private func yOffsetForDate(_ date: Date, origin: Int) -> CGFloat {
        let hour = Calendar.current.component(.hour, from: date)
        let minute = Calendar.current.component(.minute, from: date)
        return CGFloat(hour - origin) * hourHeight + CGFloat(minute) / 60.0 * hourHeight
    }

    private func dayName(_ date: Date) -> String {
        let weekday = Calendar.current.component(.weekday, from: date)
        return Calendar.current.shortStandaloneWeekdaySymbols[weekday - 1]
    }

    /// The bare number, not a formatted date. A "d" pattern is localised to 19日 in
    /// Japanese, which is right in a sentence and wrong inside a 24pt circle — the
    /// column header wants the digit alone, as Apple Calendar shows it.
    private func dayNumber(_ date: Date) -> String {
        String(Calendar.current.component(.day, from: date))
    }
}

// MARK: - Pointer feedback

/// A pointing hand over anything that actually does something. macOS 14 has no
/// `.pointerStyle`, so the cursor is pushed and popped by hand; the `inside` flag
/// keeps the stack balanced, including when the control is disabled or removed
/// while the pointer is still over it.
private struct PointingHandCursor: ViewModifier {
    let enabled: Bool
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, enabled, !inside {
                    inside = true
                    NSCursor.pointingHand.push()
                } else if !hovering, inside {
                    inside = false
                    NSCursor.pop()
                }
            }
            .onChange(of: enabled) { _, isEnabled in
                if !isEnabled, inside { inside = false; NSCursor.pop() }
            }
            .onDisappear {
                if inside { inside = false; NSCursor.pop() }
            }
    }
}

private extension View {
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        modifier(PointingHandCursor(enabled: enabled))
    }
}

// MARK: - Month View

extension CalendarWeekView {

    var monthContent: some View {
        VStack(spacing: 0) {
            monthHeader
            Divider()
            monthWeekdayRow
            monthGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var monthHeader: some View {
        calendarHeader(
            title: monthLabel,
            todayLabel: "This month",
            isAtToday: monthOffset == 0,
            canGoForward: monthOffset < 0,
            back: { monthOffset -= 1 },
            forward: { monthOffset += 1 },
            today: { monthOffset = 0 }
        )
    }

    private var monthWeekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(orderedWeekdaySymbols(\.shortStandaloneWeekdaySymbols).enumerated()),
                    id: \.offset) { _, name in
                Text(name).font(DS.miniFont).foregroundStyle(DS.inkDim)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, DS.xs)
    }

    private var monthGrid: some View {
        let days = monthGridDays
        let weeks = stride(from: 0, to: days.count, by: 7).map {
            Array(days[$0..<min($0 + 7, days.count)])
        }
        // 6 week-rows that divide the available height equally, so the grid grows
        // and shrinks with the window instead of sitting at a fixed height.
        return VStack(spacing: DS.hair) {
            ForEach(weeks.indices, id: \.self) { wi in
                HStack(spacing: DS.hair) {
                    ForEach(weeks[wi], id: \.self) { date in
                        monthCell(date)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DS.md)
        .padding(.vertical, DS.sm)
    }

    private func monthCell(_ date: Date) -> some View {
        let cal = Calendar.current
        let key = cal.startOfDay(for: date)
        let inMonth = cal.component(.month, from: date) == cal.component(.month, from: displayedMonth)
        let isToday = cal.isDateInToday(date)
        let info = monthData[key]
        let hasActivity = (info?.duration ?? 0) > 60

        return VStack(alignment: .leading, spacing: DS.hair) {
            HStack {
                if isToday {
                    Text(dayNum(date)).font(DS.smallMedium).foregroundStyle(DS.canvas)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(DS.moon))
                } else {
                    Text(dayNum(date)).font(DS.smallFont)
                        .foregroundStyle(inMonth ? DS.ink : DS.inkFaint)
                }
                Spacer()
                if hasActivity { Circle().fill(DS.moon).frame(width: 5, height: 5) }
            }
            if hasActivity, let info {
                Text(info.label).font(DS.miniFont).foregroundStyle(DS.inkDim).lineLimit(1)
                Text(formatDur(info.duration)).font(DS.tinyFont).foregroundStyle(DS.inkFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.radiusInset).fill(isToday ? DS.moon.opacity(0.06) : DS.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusInset).strokeBorder(DS.hairline, lineWidth: 0.5))
        .opacity(inMonth ? 1 : 0.45)
        .contentShape(Rectangle())
        .pointingHandCursor()
        .onTapGesture { jumpToWeek(of: date) }
    }

    // MARK: Month data

    var displayedMonth: Date {
        let cal = Calendar.current
        let base = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        return cal.date(byAdding: .month, value: monthOffset, to: base) ?? base
    }

    private var monthLabel: String {
        CalendarWeekView.templateFormatter("MMMMy").string(from: displayedMonth)
    }

    /// 42 days (6 weeks) covering the month, starting on the first weekday of the
    /// week the 1st falls in — whichever day the system says that is.
    private var monthGridDays: [Date] {
        let cal = Calendar.current
        let firstOfMonth = displayedMonth
        let weekday = cal.component(.weekday, from: firstOfMonth)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        guard let start = cal.date(byAdding: .day, value: -lead, to: firstOfMonth) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    /// Up to 42 day analyses — the heaviest load in the calendar. Detached for the
    /// same reason as the week; the per-day derivation below is untouched.
    func loadMonth() {
        let database = appState.database
        let days = monthGridDays
        let rangeKey = loadKey
        let token = beginLoad()
        monthData = [:]   // last month's dots must not sit under this month's title

        Task.detached(priority: .userInitiated) {
            let engine = TimeBlockEngine(database: database)
            let cal = Calendar.current
            var result: [Date: (duration: TimeInterval, label: String)] = [:]
            for date in days {
                // Don't compute the future.
                if cal.startOfDay(for: date) > cal.startOfDay(for: Date()) { continue }
                let blocks = engine.generateBlocks(for: date)
                guard !blocks.isEmpty else { continue }
                let total = blocks.reduce(0.0) { $0 + $1.duration }
                let main = blocks.max(by: { $0.duration < $1.duration })
                let label = (main?.label.isEmpty == false ? main?.label : main?.app) ?? ""
                result[cal.startOfDay(for: date)] = (total, label)
            }
            await MainActor.run {
                guard finishLoad(token, key: rangeKey) else { return }
                monthData = result
            }
        }
    }

    /// Open the week that actually contains the clicked day — see `weekIndex`,
    /// which replaced the day-delta ÷ 7 that could open the wrong week entirely.
    private func jumpToWeek(of date: Date) {
        weekOffset = weekIndex(of: date)
        mode = .week
    }

    /// The digit alone, for the same reason as the week header's — a localised "d"
    /// becomes 19日 and will not sit in the cell's corner.
    private func dayNum(_ date: Date) -> String {
        String(Calendar.current.component(.day, from: date))
    }

    private func formatDur(_ d: TimeInterval) -> String {
        let m = Int(d / 60)
        if m < 60 { return "\(m)m" }
        let h = m / 60, rem = m % 60
        return rem > 0 ? "\(h)h\(rem)m" : "\(h)h"
    }
}

// MARK: - Year View (activity heatmap)

extension CalendarWeekView {

    var yearContent: some View {
        VStack(spacing: 0) {
            yearHeader
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: DS.xl)],
                          alignment: .leading, spacing: DS.xl) {
                    ForEach(yearMonths, id: \.self) { miniMonth($0) }
                }
                .padding(DS.lg)
            }
        }
    }

    private var yearHeader: some View {
        calendarHeader(
            title: yearLabel,
            todayLabel: "This year",
            isAtToday: yearOffset == 0,
            canGoForward: yearOffset < 0,
            back: { yearOffset -= 1 },
            forward: { yearOffset += 1 },
            today: { yearOffset = 0 }
        )
    }

    /// One mini-month: title, weekday initials from the system's first weekday, then
    /// the day grid. The familiar year-at-a-glance (Apple Calendar風), not a
    /// contribution heatmap.
    private func miniMonth(_ monthStart: Date) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: DS.hair), count: 7)
        return VStack(alignment: .leading, spacing: DS.xs) {
            Button { jumpToMonth(monthStart) } label: {
                Text(monthTitle(monthStart))
                    .font(DS.bodyMedium)
                    .foregroundStyle(DS.moon)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Open \(monthTitle(monthStart)) in Month view")
            LazyVGrid(columns: cols, spacing: DS.hair) {
                ForEach(Array(weekdayHeaders.enumerated()), id: \.offset) { _, s in
                    Text(s).font(DS.tinyFont).foregroundStyle(DS.inkFaint)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: cols, spacing: DS.hair) {
                ForEach(Array(monthDays(monthStart).enumerated()), id: \.offset) { _, day in
                    miniDayCell(day)
                }
            }
        }
    }

    @ViewBuilder
    private func miniDayCell(_ day: Date?) -> some View {
        if let day {
            let cal = Calendar.current
            let isToday = cal.isDateInToday(day)
            let isFuture = cal.startOfDay(for: day) > today
            let count = yearCounts[cal.startOfDay(for: day)] ?? 0
            let active = count > 0 && !isFuture
            Text("\(cal.component(.day, from: day))")
                .font(DS.tinyFont)
                .foregroundStyle(isToday ? DS.canvas : (isFuture ? DS.inkFaint : DS.ink))
                .frame(maxWidth: .infinity, minHeight: 19)
                .background(
                    Circle()
                        .fill(isToday ? DS.moon
                              : (active ? DS.moon.opacity(0.12 + 0.45 * activeFraction(count)) : Color.clear))
                        .frame(width: 19, height: 19)
                )
                .contentShape(Rectangle())
                // The shading alone says "busier"; the tooltip is where the reader
                // finds out busier at what, so it stays explicit about the unit.
                .help(isFuture ? "" : "\(Self.shortDate(day)) · \(pluralized(count, "capture")) recorded")
                // Only past days go anywhere; the pointer says so before the click does.
                .pointingHandCursor(!isFuture)
                .onTapGesture { if !isFuture { jumpToDay(day) } }
        } else {
            Color.clear.frame(height: 19)
        }
    }

    /// Activity intensity 0–1 of a day's count relative to the busiest day this year.
    private func activeFraction(_ count: Int) -> Double {
        min(1.0, Double(count) / Double(max(yearMax, 1)))
    }

    var displayedYear: Date {
        let cal = Calendar.current
        let base = cal.date(from: cal.dateComponents([.year], from: today)) ?? today
        return cal.date(byAdding: .year, value: yearOffset, to: base) ?? base
    }

    private var yearLabel: String {
        CalendarWeekView.templateFormatter("y").string(from: displayedYear)
    }

    /// First-of-month for each of the 12 months in the displayed year.
    private var yearMonths: [Date] {
        let cal = Calendar.current
        let year = cal.component(.year, from: displayedYear)
        return (1...12).compactMap { cal.date(from: DateComponents(year: year, month: $0, day: 1)) }
    }

    /// Day cells for a month: leading blanks from the system's first weekday, each day,
    /// then trailing blanks to a fixed 6 rows (42 cells) so every month is the same height
    /// and adjacent months line up — as Apple's year view does.
    private func monthDays(_ monthStart: Date) -> [Date?] {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: monthStart)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        let count = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for d in 0..<count { cells.append(cal.date(byAdding: .day, value: d, to: monthStart)) }
        while cells.count < 42 { cells.append(nil) }   // 6 weeks, fixed height
        return cells
    }

    /// Localized weekday initials, ordered from the system's first weekday (日曜/月曜 設定を尊重).
    private var weekdayHeaders: [String] {
        orderedWeekdaySymbols(\.veryShortStandaloneWeekdaySymbols)
    }

    private func monthTitle(_ monthStart: Date) -> String {
        let cal = Calendar.current
        let idx = cal.component(.month, from: monthStart) - 1
        let symbols = cal.standaloneMonthSymbols
        return (idx >= 0 && idx < symbols.count) ? symbols[idx] : ""
    }

    /// The heat grid needs one number per day, not the rows behind it. This used to
    /// fetch every event of the year (≈1.5M rows, text and all) on the main thread
    /// purely to bucket them by day — SQLite does the GROUP BY now, off-thread.
    func loadYear() {
        let cal = Calendar.current
        let start = displayedYear
        let end = min(cal.date(byAdding: .year, value: 1, to: start) ?? start, Date())
        let rangeKey = loadKey
        guard end > start else {
            // A wholly future year: nothing to read, but still claim the slot so an
            // older in-flight load can't land afterwards and repaint under this title.
            let token = beginLoad()
            yearCounts = [:]
            yearMax = 1
            _ = finishLoad(token, key: rangeKey)
            return
        }
        let database = appState.database
        let token = beginLoad()
        yearCounts = [:]   // last year's heat must not sit under this year's title

        Task.detached(priority: .userInitiated) {
            let counts = database.dailyEventCounts(from: start, to: end)
            let busiest = max(counts.values.max() ?? 1, 1)
            await MainActor.run {
                guard finishLoad(token, key: rangeKey) else { return }
                yearCounts = counts
                yearMax = busiest
            }
        }
    }

    /// Drill down from the year view into a specific month (Apple's year→month gesture).
    private func jumpToMonth(_ monthStart: Date) {
        monthOffset = monthIndex(of: monthStart)
        mode = .month
    }

    private func jumpToDay(_ date: Date) {
        dayOffset = dayIndex(of: date)
        mode = .day
    }

    private static func shortDate(_ date: Date) -> String {
        CalendarWeekView.templateFormatter("MMMd").string(from: date)
    }
}

// Make TimeBlock work with popover. TimeBlock is declared in this module, so the
// conformance is not retroactive (and marking it so is an error under Swift 6).
extension TimeBlock: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: TimeBlock, rhs: TimeBlock) -> Bool {
        lhs.id == rhs.id
    }
}
