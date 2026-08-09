import SwiftUI
import AppKit
import EventKit

/// The calendar, built to the shape of Calendar.app.
///
/// Everything that was planned and everything that happened shares **one lane on one
/// time axis**, laid out the way Apple lays out overlapping events: a cluster of
/// overlapping spans is cut into equal columns across the day's full width. The two
/// kinds are told apart by how they are *drawn*, never by where they sit:
///
///   - **Scheduled** (EventKit) — a commitment made in advance. Outlined.
///   - **Observed** (TimeBlockEngine) — evidence of what actually happened. Filled.
///
/// The scheduled half is editable: double-click or drag an empty slot to make one,
/// drag an existing one to move or stretch it, click it to open its editor. Every
/// write goes to EventKit and is read back from it — mull keeps no copy — and every
/// write registers an undo, because writing to somebody's real calendar without one
/// is fine a hundred times and then isn't.
///
/// The geometry lives in `CalendarGrid`, where a test can reach it. What is left in
/// here is the drawing and the gestures.
struct CalendarWeekView: View {
    @EnvironmentObject var appState: AppState
    /// The window's undo stack. Every calendar write registers its inverse here, so
    /// ⌘Z reaches them through the responder chain like any other edit.
    @Environment(\.undoManager) private var undoManager
    /// When set by the parent (a search hit click), the view jumps to that day in Day mode.
    var jumpDate: Binding<Date?> = .constant(nil)

    @State private var weekOffset: Int = 0
    @State private var weekBlocks: [Date: [TimeBlock]] = [:]
    @State private var weekEvents: [Date: [CalendarEvent]] = [:]
    /// Day-shaped commitments — a flight, PTO, a birthday. They have no place on
    /// the hour axis, so they live in their own band above it (as Apple's do).
    @State private var weekAllDay: [Date: [CalendarEvent]] = [:]
    /// The card whose detail or editor is open.
    @State private var selectedItem: CalItem?
    /// The card the keyboard is on. Separate from `selectedItem` so ↑ / ↓ can walk
    /// the day without a popover springing open at every step.
    @State private var keyboardSelection: String?
    @State private var hoveredItem: String?
    /// Whether EventKit is actually answering. An empty grid means two entirely
    /// different things depending on this, and the empty state has to say which.
    ///
    /// Seeded from the live status rather than defaulting to `.granted`: the
    /// optimistic default meant any frame drawn before the first refresh told an
    /// unauthorized user "nothing recorded this week" instead of offering them
    /// the permission.
    @State private var calendarAccess: CalendarService.Access = CalendarService.currentAccessState

    enum CalMode: String, CaseIterable { case day = "Day", week = "Week", month = "Month", year = "Year" }
    @State private var mode: CalMode = .week
    @State private var dayOffset: Int = 0
    @State private var monthOffset: Int = 0
    @State private var monthData: [Date: (duration: TimeInterval, label: String)] = [:]
    /// A month cell lists what was *committed to* as well as what was done, so the
    /// month load fetches EventKit for the whole grid — a month of empty squares
    /// with a dot in the corner was a chart of activity, not a calendar.
    @State private var monthEvents: [Date: [CalendarEvent]] = [:]
    @State private var yearOffset: Int = 0
    @State private var yearCounts: [Date: Int] = [:]
    /// Busiest day of the loaded year — hoisted out of `activeFraction`, which is
    /// called once per cell (365+ times) and used to re-scan every value each time.
    @State private var yearMax: Int = 1

    // Loading lives off the main thread: a week is 7 block analyses + 1 EventKit
    // round-trip, a month is up to 42, and a year is a full-range SQL aggregate.
    // `loadToken` invalidates a load whose result arrived after the user moved on.
    @State private var isLoading = false
    @State private var loadToken = 0
    /// The range whose data is currently on screen — `nil` while a load is in flight.
    /// This is what keeps the header and the body from ever disagreeing.
    @State private var loadedKey: String?
    /// The debounced events-only refresh. A calendar change should not re-derive a
    /// week of activity blocks from the database, and a busy sync should not do it
    /// forty times.
    @State private var eventRefresh: Task<Void, Never>?

    /// The clock behind the "now" line. Read from state, not `Date()` during body —
    /// body only re-runs on state changes, so the line used to freeze mid-morning.
    @State private var now = Date()
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// The day everything in here is measured from. Every offset below is relative
    /// to "today", so this is the origin of the whole view — and a window left open
    /// overnight used to keep yesterday's origin: the header still said Today, and
    /// the blocks under it were the previous day's. Holding the origin in state lets
    /// a rollover invalidate `loadKey`, so the day mull is showing is always a day
    /// it has actually read.
    @State private var today = Calendar.current.startOfDay(for: Date())

    /// How tall an hour is drawn. Apple's calendar stretches under ⌘+ / ⌘− and a
    /// pinch, and the setting survives the window closing — so this is stored, not
    /// a constant. The whole grid is always 24 × this.
    @AppStorage("calendarHourHeight") private var hourHeightSetting: Double = 52
    /// Where a pinch started from, so the gesture scales the hour it began on rather
    /// than compounding on every delta.
    @State private var pinchBase: Double?
    /// How far down the grid is scrolled, in points. Tracked so a zoom can put the
    /// same *time* back under the eye instead of the same pixel.
    @State private var scrollOffset: CGFloat = 0
    @State private var zoomAnchorHour: Int?
    /// Whether the next load should jump the grid to the present.
    ///
    /// It used to do that on every load, which meant paging from week to week yanked
    /// you back to this morning each time. Apple keeps your position when you page;
    /// only opening the view, switching range, or asking for Today should move it.
    @State private var wantsAnchorScroll = true

    /// The jump-to-date popover. Reaching a day three months back used to be a
    /// dozen chevron clicks; the grid keeps the focus so the arrow keys work.
    @State private var showingDatePicker = false
    @State private var pickerDate = Date()
    @FocusState private var gridFocused: Bool

    // MARK: Writing

    /// Composed once and held, because `UndoManager` does *not* retain the target it
    /// registers against — a writer rebuilt per body pass would take the whole undo
    /// stack down with it.
    @State private var writer: CalendarWriter?

    /// An event being composed on the grid and not yet in EventKit.
    struct EventDraft {
        var day: Date
        var start: Date
        var end: Date
        var title: String = ""
        var isAllDay: Bool = false
        var calendarID: String?
    }
    @State private var draft: EventDraft?
    @FocusState private var draftFocused: Bool

    /// An event being dragged on the grid.
    struct ActiveDrag {
        enum Kind { case move, resize }
        let itemID: String
        let handle: CalendarService.EventHandle
        let original: CalendarService.EventFields
        var start: Date
        var end: Date
        let kind: Kind
        /// Whether the pointer actually went anywhere. A drag that never moved is a
        /// click, and must open the editor rather than rewrite the event with the
        /// times it already had.
        var moved = false
    }
    @State private var dragging: ActiveDrag?

    /// Whatever went wrong with a write, in the user's words. An alert, because a
    /// failed save must not be something you can miss.
    @State private var writeError: String?

    private var hourHeight: CGFloat { CGFloat(hourHeightSetting) }
    /// Wide enough for "12 AM" and for "12時" — the old 48 was sized for a bare digit.
    private let timeColumnWidth: CGFloat = 58

    private static let minHourHeight: Double = 26
    private static let maxHourHeight: Double = 180
    /// Below this the half-hour rule crowds the hour rule instead of dividing it.
    private static let halfHourRuleThreshold: CGFloat = 34
    /// Legibility floor for a drawn span, and the room kept below a padded one.
    private static let minSpanHeight: CGFloat = 18
    private static let spanGap: CGFloat = 1
    /// The strip at a card's lower edge that stretches it rather than moving it.
    private static let resizeGrip: CGFloat = 8
    private static let gridSpace = "calendar.grid"

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            modeContent
                .overlay(alignment: .top) {
                    if isLoading { loadingPill }
                }
        }
        // Keyboard navigation. The whole view takes focus so ← / → step by whatever
        // unit is on screen and ↑ / ↓ walk the events on it, without the reader
        // having to find a control first.
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onAppear {
            prepareWriter()
            gridFocused = true
        }
        .onMoveCommand { direction in
            switch direction {
            case .left:  step(-1)
            case .right: step(1)
            case .up:    moveKeyboardSelection(-1)
            case .down:  moveKeyboardSelection(1)
            @unknown default: break
            }
        }
        // ⌫ on the highlighted event. Guarded on nothing being typed, so backspace
        // inside a title stays backspace.
        .onDeleteCommand {
            guard draft == nil, selectedItem == nil else { return }
            deleteKeyboardSelection()
        }
        .onKeyPress(.return) {
            guard draft == nil, selectedItem == nil,
                  let item = keyboardItem() else { return .ignored }
            selectedItem = item
            return .handled
        }
        .background { keyEquivalents }
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
        .onChange(of: mode) { _, _ in
            // A new range is a new view of the day; that one *should* open at now.
            wantsAnchorScroll = true
            keyboardSelection = nil
        }
        // Somebody changed the calendar — mull itself saving one, or Calendar.app on
        // another Space, or a shared invite landing. Only the events are re-read: a
        // calendar change says nothing about what you were doing, and re-deriving a
        // week of activity blocks for it was seven database analyses per sync tick.
        .onReceive(NotificationCenter.default
            .publisher(for: .EKEventStoreChanged)
            .receive(on: RunLoop.main)) { _ in
            refreshEvents()
        }
        .onAppear { applyJump() }
        .onChange(of: jumpDate.wrappedValue) { _, _ in applyJump() }
        .alert("Couldn't save that", isPresented: writeErrorBinding, presenting: writeError) { _ in
            Button("OK", role: .cancel) { writeError = nil }
        } message: { message in
            Text(message)
        }
    }

    private var writeErrorBinding: Binding<Bool> {
        Binding(get: { writeError != nil }, set: { if !$0 { writeError = nil } })
    }

    /// Build the writer once and wire its two outputs to this view's state.
    private func prepareWriter() {
        guard writer == nil else { return }
        let made = CalendarWriter(service: appState.calendar)
        made.onError = { message in writeError = message }
        made.onChange = { refreshEvents() }
        writer = made
    }

    /// The shortcuts Calendar.app answers to, laid out off-screen because they
    /// belong to the view rather than to any one control on it.
    private var keyEquivalents: some View {
        ZStack {
            Button("Today") { goToToday() }.keyboardShortcut("t", modifiers: .command)
            Button("Day") { mode = .day }.keyboardShortcut("1", modifiers: .command)
            Button("Week") { mode = .week }.keyboardShortcut("2", modifiers: .command)
            Button("Month") { mode = .month }.keyboardShortcut("3", modifiers: .command)
            Button("Year") { mode = .year }.keyboardShortcut("4", modifiers: .command)
            Button("New Event") { newEvent() }.keyboardShortcut("n", modifiers: .command)
            // ⌘+ is ⌘⇧= on most layouts and plain ⌘= on some; both are bound so the
            // shortcut works wherever the reader's fingers expect it.
            Button("Zoom in") { zoom(by: 1.25) }.keyboardShortcut("+", modifiers: .command)
            Button("Zoom in") { zoom(by: 1.25) }.keyboardShortcut("=", modifiers: .command)
            Button("Zoom out") { zoom(by: 0.8) }.keyboardShortcut("-", modifiers: .command)

            // Undo belongs to the responder chain, but only while nothing here is
            // taking text: inside a title field ⌘Z has to mean "undo my typing".
            if draft == nil, selectedItem == nil {
                Button("Undo") { undoManager?.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { undoManager?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func zoom(by factor: Double) {
        zoomAnchorHour = Int(scrollOffset / hourHeight)
        withAnimation(.easeOut(duration: 0.15)) {
            hourHeightSetting = clampHour(hourHeightSetting * factor)
        }
    }

    private func clampHour(_ value: Double) -> Double {
        min(max(value, Self.minHourHeight), Self.maxHourHeight)
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

    /// A quiet note that the grid is still filling — the analysis runs off the main
    /// thread, so the view is live (scrollable) while this is up.
    private var loadingPill: some View {
        HStack(spacing: DS.sm) {
            ProgressView().controlSize(.small)
            Text("Reading your records…")
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
        wantsAnchorScroll = true
        jumpDate.wrappedValue = nil
        // No load here: changing the offset and mode changes `loadKey`, and the
        // single onChange above owns loading.
    }

    // MARK: - Toolbar
    //
    // One row, as Calendar.app has: what you are looking at on the left, the controls
    // that move it on the right. This was two stacked bars — a segmented picker above
    // a centred title with its own chevrons — which is a shape no Apple calendar has,
    // and it cost a fifth of the window's height before a single hour was drawn.

    private var toolbar: some View {
        HStack(spacing: DS.md) {
            Text(rangeTitle)
                .font(DS.displayFont)
                .foregroundStyle(DS.ink)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: DS.md)

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

    /// The visible half of ⌘N. A keyboard shortcut nobody is told about is not a way
    /// to add an event, and this is where a Mac user looks first.
    ///
    /// With more than one writable calendar it becomes a menu, because "which
    /// calendar did that go into" is a question you would otherwise only think to ask
    /// once the event was already in the wrong one. Clicking it still just makes an
    /// event in the default; the list is there when you want it.
    @ViewBuilder
    private var newEventControl: some View {
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
    private var newEventHelp: String {
        guard let calendar = appState.calendar.defaultCalendarTitle else {
            return "No calendar on this Mac accepts new events"
        }
        return "New event in \(calendar) (⌘N) · or double-click the grid"
    }

    /// What the toolbar is titled with, in whatever unit is on screen.
    private var rangeTitle: String {
        switch mode {
        case .day:   return Self.fullDayLabel(selectedDay)
        case .week:  return weekRangeLabel
        case .month: return monthLabel
        case .year:  return yearLabel
        }
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

    private func navArrow(_ symbol: String, hint: String,
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

    private var weekContent: some View {
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

    private var selectedDay: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: today) ?? today
    }

    /// One timeline, as Calendar.app's day view is. It used to be two parallel columns
    /// headed SCHEDULED and ACTIVITY, which put the same 09:30 in two places and left
    /// each half at a third of the width it had.
    private var dayContent: some View {
        VStack(spacing: 0) {
            dayHeaderRow([selectedDay])
            allDayBand
            Divider()
            timeGrid(days: [selectedDay])
                .overlay(alignment: .top) { emptyState }
        }
    }

    // MARK: - The hour grid
    //
    // All 24 hours, always. The grid used to draw only the band the day's activity
    // occupied, which meant its height and its scroll position changed every time a
    // load landed — the single largest reason it did not feel like a calendar. The
    // hours you were not here are cheap; the grid simply opens at the present.

    private func timeGrid(days: [Date]) -> some View {
        let labels = TimeFormat.hourLabels()
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    timeLabels(labels)
                    ForEach(days, id: \.self) { dayColumn(date: $0) }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: GridScrollKey.self,
                            value: -geo.frame(in: .named(Self.gridSpace)).minY
                        )
                    }
                )
                // Attached to the *content*, not the ScrollView: the hour ids don't
                // exist until the rows are realised, which is why an onAppear scroll
                // on the ScrollView missed and left the day pinned at 00:00.
                .onAppear { scrollToAnchor(proxy, force: true) }
                .onChange(of: loadedKey) { _, _ in scrollToAnchor(proxy) }
                .onChange(of: hourHeightSetting) { _, _ in restoreZoomAnchor(proxy) }
            }
            .coordinateSpace(name: Self.gridSpace)
            .onPreferenceChange(GridScrollKey.self) { offset in scrollOffset = offset }
            .gesture(pinchToZoom)
        }
    }

    /// Pinch stretches the hour, as it does in Calendar.app. Anchored to the height
    /// the gesture began at so the scale doesn't compound with every delta.
    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? hourHeightSetting
                if pinchBase == nil {
                    pinchBase = base
                    zoomAnchorHour = Int(scrollOffset / hourHeight)
                }
                hourHeightSetting = clampHour(base * value.magnification)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func timeLabels(_ labels: [String]) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(labels[hour])
                    .font(DS.microFont)
                    .foregroundStyle(DS.inkFaint)
                    // Padded before the frame, so the gutter's total width stays
                    // exactly `timeColumnWidth` and lines up with the header above it.
                    .padding(.trailing, DS.sm)
                    .frame(width: timeColumnWidth, height: hourHeight, alignment: .topTrailing)
                    .offset(y: -5)   // sit astride the hour rule, not below it
                    .id(hour)        // scroll target
            }
        }
    }

    /// Hour rules, and a fainter one at the half hour once there is room for it —
    /// the divide Calendar.app draws and this grid did not.
    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Color.clear
                    .frame(height: hourHeight)
                    .overlay(alignment: .top) {
                        Rectangle().fill(DS.hairline).frame(height: 0.5)
                    }
                    .overlay(alignment: .center) {
                        if hourHeight >= Self.halfHourRuleThreshold {
                            Rectangle().fill(DS.hairline.opacity(0.5)).frame(height: 0.5)
                        }
                    }
            }
        }
    }

    private func dayColumn(date: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        let items = items(on: date)
        let spans = CalendarGrid.layout(items.map { CalendarGrid.Interval(start: $0.start, end: $0.end) },
                                        day: date,
                                        hourHeight: hourHeight,
                                        minHeight: Self.minSpanHeight,
                                        gap: Self.spanGap)

        return ZStack(alignment: .topLeading) {
            if isToday { Rectangle().fill(DS.moon.opacity(0.03)) }

            hourLines

            // The empty grid, and the only thing on the column that answers a
            // double-click or a drag. It sits *under* the cards, so a click that
            // lands on an event opens the event; one that lands on nothing lands here.
            emptySlotLayer(on: date)

            GeometryReader { proxy in
                let lane = max(proxy.size.width - 4, 12)
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let span = dragAdjusted(spans[index], for: item)
                    let slice = CalendarGrid.slice(span, laneX: 2, laneWidth: lane)
                    itemView(item, width: slice.width, span: span)
                        .offset(x: slice.x, y: span.y)
                }
            }

            draftCard(on: date)

            if isToday { nowIndicator }
        }
        .frame(maxWidth: .infinity)
        // 24 rows on the 363 days that have 24 hours, and one row taller on the day
        // the clocks go back — that day really is 25 hours long, and a column fixed
        // at 24 put its last hour under `.clipped()`, where an 11 PM event simply
        // was not drawn. The spring-forward day keeps its 24 rows and ends with one
        // empty, so the columns beside it stay in step with the gutter.
        .frame(height: max(24 * hourHeight,
                           CalendarGrid.dayHeight(date, hourHeight: hourHeight)))
        // The vertical rule between columns. Its absence was half of why a week read
        // as seven overlapping lists rather than a grid.
        .overlay(alignment: .leading) {
            Rectangle().fill(DS.hairline).frame(width: 0.5)
        }
        .clipped()
        // VoiceOver cannot double-click an empty slot, so the gesture is offered as
        // an action on the column instead. Without this, ⌘N was the only way in.
        .accessibilityAction(named: "New event on \(Self.shortDate(date))") {
            newEvent(on: date)
        }
    }

    /// Everything drawn on one day's axis, in one list — which is what lets a meeting
    /// and the work either side of it share the width instead of each being penned
    /// into a fixed fraction of the column.
    private func items(on date: Date) -> [CalItem] {
        let key = Calendar.current.startOfDay(for: date)
        let scheduled = (weekEvents[key] ?? []).map(CalItem.init(event:))
        let observed = (weekBlocks[key] ?? []).map(CalItem.init(block:))
        return (scheduled + observed).sorted { $0.start < $1.start }
    }

    // MARK: - Making an event on the grid

    /// The transparent sheet that turns empty space into a gesture.
    ///
    /// Two ways in, both of them the ones a Mac user already has in their hands:
    /// double-click for a default hour, or drag to say how long. A *single* click
    /// deliberately does nothing — in a grid this dense it would create an event
    /// every time somebody clicked to dismiss a popover.
    private func emptySlotLayer(on date: Date) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { point in
                beginDraft(on: date, from: point.y, to: nil)
            }
            // Below the double-click's slop, so making an event by double-clicking
            // never turns into a one-minute drag.
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        beginDraft(on: date, from: value.startLocation.y, to: value.location.y)
                    }
                    .onEnded { value in
                        beginDraft(on: date, from: value.startLocation.y, to: value.location.y)
                        draftFocused = true
                    }
            )
    }

    /// Open (or extend) a draft between two points on the column.
    private func beginDraft(on date: Date, from startY: CGFloat, to endY: CGFloat?) {
        guard appState.calendar.canCreateEvents else {
            writeError = CalendarService.WriteError.noWritableCalendar.errorDescription
            return
        }
        let anchor = CalendarGrid.snapped(time(on: date, atY: startY))
        let other = endY.map { CalendarGrid.snapped(time(on: date, atY: $0)) }
        var start = anchor
        var end = other ?? anchor.addingTimeInterval(3600)
        if end <= start { swap(&start, &end) }
        // A drag inside one quarter-hour still has to mean *something*.
        if end.timeIntervalSince(start) < 900 { end = start.addingTimeInterval(900) }

        // Extending a drag must not restart the title being typed.
        if var existing = draft, !existing.isAllDay,
           Calendar.current.isDate(existing.day, inSameDayAs: date) {
            existing.start = start
            existing.end = end
            draft = existing
        } else {
            draft = EventDraft(day: date, start: start, end: end)
            draftFocused = true
        }
    }

    /// ⌘N and the ＋ button: an hour starting at the next quarter, on the day already
    /// on screen.
    private func newEvent(in calendarID: String? = nil) {
        let cal = Calendar.current
        switch mode {
        case .day:
            newEvent(on: selectedDay, in: calendarID)
        case .week:
            let day = displayedDays.first { cal.isDateInToday($0) } ?? displayedDays.first ?? today
            newEvent(on: day, in: calendarID)
        case .month, .year:
            // There is no hour axis to put it on here, so go where there is one.
            let inThisMonth = cal.isDate(displayedMonth, equalTo: today, toGranularity: .month)
            newEvent(on: inThisMonth ? today : displayedMonth, in: calendarID)
        }
    }

    private func newEvent(on day: Date, in calendarID: String? = nil) {
        guard appState.calendar.canCreateEvents else {
            writeError = CalendarService.WriteError.noWritableCalendar.errorDescription
            return
        }
        let cal = Calendar.current
        // On today that means "from about now"; on any other day, the start of an
        // ordinary working morning, because "now" has no meaning over there.
        let base = cal.isDateInToday(day)
            ? CalendarGrid.snapped(now, rounding: .up)
            : cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        if mode == .month || mode == .year {
            dayOffset = dayIndex(of: day)
            mode = .day
        }
        draft = EventDraft(day: day, start: base, end: base.addingTimeInterval(3600),
                           calendarID: calendarID)
        draftFocused = true
    }

    /// The card being composed. It carries its own text field and its own two
    /// instructions, because a card that appears under the cursor with a caret in it
    /// has to say what Return and Escape will do.
    @ViewBuilder
    private func draftCard(on date: Date) -> some View {
        if let draft, !draft.isAllDay, Calendar.current.isDate(draft.day, inSameDayAs: date) {
            let y = CalendarGrid.yOffset(for: draft.start, hourHeight: hourHeight)
            let length = draft.end.timeIntervalSince(draft.start)
            // Never shorter than the field needs, whatever the drag said.
            let height = max(hourHeight * length / 3600, 44)

            VStack(alignment: .leading, spacing: 1) {
                TextField("New Event", text: draftTitle)
                    .textFieldStyle(.plain)
                    .font(DS.miniMedium)
                    .foregroundStyle(DS.ink)
                    .focused($draftFocused)
                    .onSubmit { commitDraft() }

                Text("\(TimeFormat.person(draft.start)) – \(TimeFormat.person(draft.end))")
                    .font(DS.miniFont)
                    .foregroundStyle(DS.inkFaint)

                if height >= 58 {
                    Text("Return to save · Esc to discard")
                        .font(DS.miniFont)
                        .foregroundStyle(DS.inkFaint)
                }
            }
            .padding(.horizontal, DS.xs)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: DS.radiusChip).fill(DS.moon.opacity(0.14)))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusChip)
                    .strokeBorder(DS.moon.opacity(0.7), lineWidth: 1)
            )
            .padding(.horizontal, 2)
            .offset(y: y)
            .accessibilityLabel("New event")
            // Escape anywhere in the draft throws it away — nothing has been written
            // yet, so there is nothing to undo.
            .onExitCommand { self.draft = nil }
        }
    }

    private var draftTitle: Binding<String> {
        Binding(get: { draft?.title ?? "" }, set: { draft?.title = $0 })
    }

    /// Write the draft. The grid does not paint the new event itself — it saves, and
    /// the store's change notification brings it back as a real event, so what you
    /// end up looking at is EventKit's copy and not mull's guess at it.
    private func commitDraft() {
        guard let draft, let writer else { return }
        let fields = CalendarService.EventFields(
            title: draft.title, start: draft.start, end: draft.end,
            location: nil, isAllDay: draft.isAllDay, calendarID: draft.calendarID
        )
        writer.create(fields, undo: undoManager)
        self.draft = nil
        gridFocused = true
    }

    /// The moment a point down the column stands for.
    private func time(on day: Date, atY y: CGFloat) -> Date {
        CalendarGrid.time(on: day, atY: y, hourHeight: hourHeight)
    }

    // MARK: - Moving and stretching an event
    //
    // Creating an event without being able to nudge it afterwards leaves the whole
    // feature at "type it right the first time, or open the editor" — and the grid
    // is where you can *see* that the meeting wants to be half an hour later.

    /// The span a card is drawn at, which is its laid-out one unless it is the card
    /// currently being dragged.
    private func dragAdjusted(_ span: CalendarGrid.Span, for item: CalItem) -> CalendarGrid.Span {
        guard let dragging, dragging.itemID == item.id, dragging.moved else { return span }
        var adjusted = span
        let height = max(hourHeight * dragging.end.timeIntervalSince(dragging.start) / 3600,
                         Self.minSpanHeight)
        adjusted.y = CalendarGrid.yOffset(for: dragging.start, hourHeight: hourHeight)
        adjusted.height = height
        adjusted.trueHeight = height
        return adjusted
    }

    /// Body drags move; the lower edge stretches. Only scheduled events on writable
    /// calendars respond — an observed block is a record of what happened, and moving
    /// it would be editing the past.
    private func dragGesture(for item: CalItem, span: CalendarGrid.Span) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                guard let handle = item.editableHandle else { return }
                if dragging?.itemID != item.id {
                    let onGrip = value.startLocation.y >= span.height - Self.resizeGrip
                    let fields = writer?.currentFields(handle)
                        ?? CalendarService.EventFields(title: item.title, start: item.start,
                                                       end: item.end, location: nil)
                    dragging = ActiveDrag(itemID: item.id, handle: handle,
                                          original: fields, start: item.start, end: item.end,
                                          kind: onGrip ? .resize : .move)
                }
                guard var active = dragging else { return }
                let shift = TimeInterval(Double(value.translation.height / hourHeight) * 3600)
                switch active.kind {
                case .move:
                    let moved = CalendarGrid.snapped(item.start.addingTimeInterval(shift),
                                                     rounding: .nearest)
                    active.start = moved
                    active.end = moved.addingTimeInterval(item.end.timeIntervalSince(item.start))
                case .resize:
                    let ended = CalendarGrid.snapped(item.end.addingTimeInterval(shift),
                                                     rounding: .nearest)
                    active.start = item.start
                    active.end = max(ended, item.start.addingTimeInterval(900))
                }
                active.moved = true
                dragging = active
            }
            .onEnded { _ in
                guard let active = dragging else { return }
                dragging = nil
                // A drag that never moved is a click; let the tap gesture have it.
                guard active.moved, let writer else { return }
                guard active.start != active.original.start
                        || active.end != active.original.end else { return }
                var fields = active.original
                fields.start = active.start
                fields.end = active.end
                writer.update(ref: writer.ref(for: active.handle),
                              from: active.original, to: fields, undo: undoManager)
            }
    }

    // MARK: - Empty state
    //
    // Week is the mode the app opens in, so this is the first screen a new reader
    // sees — and it was seven blank columns and a 24-hour grid, which reads as a
    // broken app rather than an empty record.

    private var rangeIsEmpty: Bool {
        let cal = Calendar.current
        return displayedDays.allSatisfy { date in
            let key = cal.startOfDay(for: date)
            return (weekBlocks[key] ?? []).isEmpty
                && (weekEvents[key] ?? []).isEmpty
                && (weekAllDay[key] ?? []).isEmpty
        }
    }

    /// Nothing here has happened yet, so nothing *could* have been recorded.
    private var rangeIsFuture: Bool {
        displayedDays.allSatisfy { Calendar.current.startOfDay(for: $0) > today }
    }

    @ViewBuilder
    private var emptyState: some View {
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
    private func grantCalendarAccess() {
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

    // MARK: - Day headers (sticky, above the scroll)

    private func dayHeaderRow(_ days: [Date]) -> some View {
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

    @ViewBuilder
    private var allDayBand: some View {
        let cal = Calendar.current
        let days = displayedDays
        let rows = days.map { weekAllDay[cal.startOfDay(for: $0)] ?? [] }
        let composing = draft?.isAllDay == true

        if rows.contains(where: { !$0.isEmpty }) || composing {
            HStack(alignment: .top, spacing: 0) {
                Text("all-day")
                    .font(DS.miniFont)
                    .foregroundStyle(DS.inkFaint)
                    .padding(.trailing, DS.sm)
                    .frame(width: timeColumnWidth, alignment: .trailing)

                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    VStack(alignment: .leading, spacing: DS.hair) {
                        ForEach(rows[index]) { allDayChip($0) }
                        allDayDraftChip(on: day)
                    }
                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .topLeading)
                    .padding(.horizontal, 1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginAllDayDraft(on: day) }
                    .accessibilityAction(named: "New all-day event") { beginAllDayDraft(on: day) }
                }
            }
            .padding(.vertical, DS.xs)
        }
    }

    /// Outlined like a scheduled event, because that is what it is — a commitment
    /// made in advance — only without a time to put it against.
    private func allDayChip(_ event: CalendarEvent) -> some View {
        let item = CalItem(event: event)
        return Text(event.title)
            .font(DS.miniMedium)
            .foregroundStyle(DS.ink)
            .lineLimit(1)
            .padding(.horizontal, DS.xs)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusChip).fill(event.color.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusChip)
                    .strokeBorder(event.color.opacity(0.45), lineWidth: 0.75)
            )
            .help(event.title)
            .contentShape(Rectangle())
            .pointingHandCursor()
            .onTapGesture { selectedItem = item }
            .popover(isPresented: popoverBinding(for: item), arrowEdge: .bottom) {
                itemDetail(item)
            }
    }

    @ViewBuilder
    private func allDayDraftChip(on day: Date) -> some View {
        if let draft, draft.isAllDay, Calendar.current.isDate(draft.day, inSameDayAs: day) {
            TextField("New Event", text: draftTitle)
                .textFieldStyle(.plain)
                .font(DS.miniMedium)
                .foregroundStyle(DS.ink)
                .focused($draftFocused)
                .onSubmit { commitDraft() }
                .padding(.horizontal, DS.xs)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: DS.radiusChip).fill(DS.moon.opacity(0.14)))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusChip)
                        .strokeBorder(DS.moon.opacity(0.7), lineWidth: 1)
                )
                .onExitCommand { self.draft = nil }
        }
    }

    private func beginAllDayDraft(on day: Date) {
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
    private var displayedDays: [Date] {
        mode == .day ? [selectedDay] : weekDays
    }

    /// Where a freshly laid-out grid should sit: an hour before now when the range
    /// contains today, otherwise the start of an ordinary working day rather than
    /// midnight.
    private var scrollAnchorHour: Int {
        guard displayedDays.contains(where: { Calendar.current.isDateInToday($0) }) else { return 8 }
        return max(Calendar.current.component(.hour, from: now) - 1, 0)
    }

    /// Scroll once the rows exist. Calling `scrollTo` straight out of `onAppear` races
    /// the first layout pass and silently no-ops — which is how the day used to open
    /// pinned at midnight. Hopping to the next runloop lands after layout; the second
    /// hop covers the case where the data settles a beat later.
    private func scrollToAnchor(_ proxy: ScrollViewProxy, force: Bool = false) {
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
    private func restoreZoomAnchor(_ proxy: ScrollViewProxy) {
        guard let hour = zoomAnchorHour else { return }
        zoomAnchorHour = nil
        DispatchQueue.main.async { proxy.scrollTo(hour, anchor: .top) }
    }

    // MARK: - One thing on the grid

    /// A span drawn on the hour axis, whichever half of mull it came from.
    ///
    /// Scheduled and observed share a lane, so they have to share a type: the layout
    /// cannot give a meeting and the work around it equal footing while they live in
    /// two separate arrays being drawn into two fixed fractions of the column.
    struct CalItem: Identifiable, Equatable {
        let id: String
        let start: Date
        let end: Date
        let title: String
        let color: Color
        /// A commitment made in advance (outlined), rather than evidence of what
        /// happened (filled).
        let isScheduled: Bool
        let event: CalendarEvent?
        let block: TimeBlock?

        static func == (lhs: CalItem, rhs: CalItem) -> Bool { lhs.id == rhs.id }

        init(event: CalendarEvent) {
            // EventKit's identifier where there is one: `event.id` is a fresh UUID
            // minted on every fetch, so an open popover lost its anchor the moment
            // a store change reloaded the range underneath it.
            //
            // The identifier alone is not enough for a repeating event: every
            // occurrence carries the same one, so a week of stand-ups was one card
            // as far as selection, hover, ↑/↓ and dragging were concerned — clicking
            // Wednesday's opened five popovers and dragging it moved all five.
            // Only the repeating case needs the occurrence appended; keeping it out
            // of a lone event's id is what lets an open popover survive that event
            // being dragged somewhere else.
            if let identifier = event.eventIdentifier {
                if event.isRecurring, let occurrence = event.occurrenceDate {
                    self.id = "event-\(identifier)@\(occurrence.timeIntervalSinceReferenceDate)"
                } else {
                    self.id = "event-\(identifier)"
                }
            } else {
                self.id = "event-\(event.id.uuidString)"
            }
            self.start = event.start
            self.end = event.end
            self.title = event.title
            self.color = event.color
            self.isScheduled = true
            self.event = event
            self.block = nil
        }

        init(block: TimeBlock) {
            self.id = "block-\(block.id)"
            self.start = block.start
            self.end = block.end
            self.title = block.app
            self.color = block.color
            self.isScheduled = false
            self.event = nil
            self.block = block
        }

        /// The EventKit handle, but only when this is something mull may change.
        /// Names one occurrence, not a whole series — see `CalendarEvent.handle`.
        var editableHandle: CalendarService.EventHandle? {
            guard let event, event.isEditable else { return nil }
            return event.handle
        }

        /// The lines under the title, longest-lived first. The card takes as many as
        /// its height allows and drops the rest.
        var detailLines: [String] {
            if let event {
                var lines: [String] = []
                if let location = event.location, !location.isEmpty { lines.append(location) }
                lines.append(event.timeFormatted)
                return lines
            }
            guard let block else { return [] }
            var lines: [String] = []
            if !block.label.isEmpty, block.label != block.app { lines.append(block.label) }
            if !block.secondaryApps.isEmpty {
                lines.append("+ " + block.secondaryApps.prefix(2).joined(separator: ", "))
            }
            lines.append(block.durationFormatted)
            return lines
        }

        var tooltip: String {
            if let event {
                let place = (event.location?.isEmpty == false) ? " · \(event.location!)" : ""
                let hint = event.isEditable ? " · drag to move, drag the lower edge to stretch" : ""
                return "\(title) · \(event.timeFormatted)\(place)\(hint)"
            }
            guard let block else { return title }
            let label = (block.label.isEmpty || block.label == block.app) ? "" : " · \(block.label)"
            return "\(block.startFormatted) – \(block.endFormatted) · \(block.durationFormatted)\(label)"
        }
    }

    /// Drawn at whichever edge the span runs past — the reader is told the span was
    /// cut by midnight, not that it began or ended there.
    private func continuationMark(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(tint.opacity(0.75))
            .padding(.horizontal, DS.hair)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The wash behind a span. The true extent takes the full tint; whatever the card
    /// was padded by fades to a ghost, so a four-minute block never passes for half an hour.
    private func spanWash(_ tint: Color, span: CalendarGrid.Span, strength: Double) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: DS.radiusChip)
                .fill(tint.opacity(span.isPadded ? strength * 0.3 : strength))
            if span.isPadded {
                RoundedRectangle(cornerRadius: DS.radiusChip)
                    .fill(tint.opacity(strength))
                    .frame(height: max(span.trueHeight, 2))
            }
        }
    }

    /// The coloured rule down a span's left edge, drawn at its *true* duration —
    /// never at the padded card height.
    private func spanRule(_ tint: Color, span: CalendarGrid.Span) -> some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: DS.radiusXs)
                .fill(tint)
                .frame(width: 3, height: max(min(span.trueHeight, span.height), 2))
            Spacer(minLength: 0)
        }
    }

    // MARK: - The card

    /// One card, drawn two ways. Scheduled is outlined — a frame, drawn before the
    /// fact; observed is filled and unframed. Both open on click.
    ///
    /// Not a `Button` any more: a Button's action fires on mouse-up whether or not
    /// the pointer travelled, so dragging an event to a new time also opened its
    /// editor on release. A tap gesture and a drag gesture compose the way those two
    /// meanings actually differ.
    private func itemView(_ item: CalItem, width: CGFloat, span: CalendarGrid.Span) -> some View {
        let height = span.height
        let isHovered = hoveredItem == item.id
        let isKeyed = keyboardSelection == item.id
        // Two detail lines need ~30pt and ~44pt of card. Below that the tooltip and
        // the popover carry them.
        let visibleDetails = height >= 44 ? 2 : (height >= 30 ? 1 : 0)

        return HStack(spacing: 0) {
            spanRule(item.color, span: span)

            VStack(alignment: .leading, spacing: DS.hair) {
                Text(item.title)
                    .font(DS.miniMedium)
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)

                ForEach(Array(item.detailLines.prefix(visibleDetails).enumerated()), id: \.offset) { _, line in
                    Text(line)
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
        .background(spanWash(item.color, span: span,
                             strength: washStrength(item, hovered: isHovered)))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusChip)
                .strokeBorder(borderTint(item, hovered: isHovered, keyed: isKeyed),
                              lineWidth: isKeyed ? 1.5 : 0.75)
        )
        .overlay(alignment: .top) {
            if span.continuesBefore { continuationMark("chevron.up", tint: item.color) }
        }
        .overlay(alignment: .bottom) {
            if span.continuesAfter { continuationMark("chevron.down", tint: item.color) }
        }
        // The strip that stretches instead of moving, shown on hover so the grip can
        // be found without reading a tooltip first.
        .overlay(alignment: .bottom) {
            if item.editableHandle != nil, isHovered, height >= 24, !span.continuesAfter {
                Capsule()
                    .fill(item.color.opacity(0.8))
                    .frame(width: 16, height: 2)
                    .padding(.bottom, 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            keyboardSelection = item.id
            selectedItem = item
        }
        .gesture(dragGesture(for: item, span: span))
        .help(item.tooltip + Self.continuationNote(span))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.tooltip)
        .onHover { hovering in
            if hovering {
                hoveredItem = item.id
                NSCursor.pointingHand.push()
            } else {
                if hoveredItem == item.id { hoveredItem = nil }
                NSCursor.pop()
            }
        }
        .onDisappear {
            if hoveredItem == item.id {
                hoveredItem = nil
                NSCursor.pop()
            }
        }
        // Anchored to the card, not to the window. This used to hang off the root
        // VStack, so every block's detail popped from the same spot at the top.
        .popover(isPresented: popoverBinding(for: item), arrowEdge: .trailing) {
            itemDetail(item)
        }
    }

    private func washStrength(_ item: CalItem, hovered: Bool) -> Double {
        if item.isScheduled { return hovered ? 0.16 : 0.10 }
        return hovered ? 0.20 : 0.12
    }

    private func borderTint(_ item: CalItem, hovered: Bool, keyed: Bool) -> Color {
        if keyed { return DS.moon }
        if item.isScheduled { return item.color.opacity(hovered ? 0.7 : 0.45) }
        return hovered ? DS.moon.opacity(0.55) : .clear
    }

    /// The tooltip half of the continuation marker — a chevron alone doesn't say
    /// which day the rest of the span is on.
    private static func continuationNote(_ span: CalendarGrid.Span) -> String {
        switch (span.continuesBefore, span.continuesAfter) {
        case (true, true):   return " · runs through this whole day"
        case (true, false):  return " · continues from the previous day"
        case (false, true):  return " · continues into the next day"
        case (false, false): return ""
        }
    }

    private func popoverBinding(for item: CalItem) -> Binding<Bool> {
        Binding(
            get: { selectedItem?.id == item.id },
            set: { shown in
                if shown { selectedItem = item }
                else if selectedItem?.id == item.id { selectedItem = nil }
            }
        )
    }

    // MARK: - Keyboard selection

    /// Every card on the displayed range, in the order ↑ / ↓ walk them.
    private var selectableItems: [CalItem] {
        displayedDays.flatMap { items(on: $0) }.sorted { $0.start < $1.start }
    }

    private func keyboardItem() -> CalItem? {
        guard let id = keyboardSelection else { return nil }
        return selectableItems.first { $0.id == id }
    }

    private func moveKeyboardSelection(_ delta: Int) {
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
    private func deleteKeyboardSelection() {
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

    private var nowIndicator: some View {
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

    // MARK: - Detail popovers

    @ViewBuilder
    private func itemDetail(_ item: CalItem) -> some View {
        if let event = item.event {
            // Editable where the calendar allows it. A subscribed feed — holidays,
            // someone else's shared calendar — falls back to the read-only card
            // rather than offering a Save button that would always fail.
            if let handle = item.editableHandle, let writer {
                EventEditor(
                    event: event,
                    handle: handle,
                    calendars: appState.calendar.writableCalendars,
                    writer: writer,
                    undoManager: undoManager,
                    onFinished: { selectedItem = nil }
                )
            } else {
                eventDetail(event)
            }
        } else if let block = item.block {
            blockDetail(block)
        }
    }

    /// The read-only card, for an event on a calendar mull is not allowed to change.
    private func eventDetail(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                RoundedRectangle(cornerRadius: DS.radiusXs)
                    .fill(event.color)
                    .frame(width: 4, height: 24)
                VStack(alignment: .leading, spacing: DS.hair) {
                    Text(event.title)
                        .font(DS.bodyMedium)
                    Text("Scheduled")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                }
            }

            Divider()

            HStack(spacing: DS.md) {
                Label(event.timeFormatted, systemImage: "clock")
                    .font(DS.captionFont)
                Label(CalendarWeekView.durationLabel(event.duration), systemImage: "hourglass")
                    .font(DS.captionFont)
            }
            .foregroundStyle(DS.inkDim)

            if let location = event.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                    .lineLimit(2)
            }

            Text("This calendar is subscribed, so mull can only read it.")
                .font(DS.miniFont)
                .foregroundStyle(DS.inkFaint)
        }
        .padding(DS.lg)
        .frame(width: 280)
    }

    static func durationLabel(_ duration: TimeInterval) -> String {
        let minutes = max(Int(duration / 60), 0)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h"
    }

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

    /// A week is 7 full day analyses plus one EventKit fetch. Doing that on the main
    /// thread froze the window on every arrow-key week change; it runs detached and
    /// publishes once.
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

            // One EventKit round trip for the whole week, not seven.
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

    /// The span of days whose events are on screen.
    private var eventRange: (Date, Date)? {
        let cal = Calendar.current
        switch mode {
        case .day:
            let start = cal.startOfDay(for: selectedDay)
            return (start, cal.date(byAdding: .day, value: 1, to: start) ?? start)
        case .week:
            let start = weekRange.0
            return (start, cal.date(byAdding: .day, value: 7, to: start) ?? start)
        case .month:
            guard let first = monthGridDays.first, let last = monthGridDays.last else { return nil }
            return (first, cal.date(byAdding: .day, value: 1, to: last) ?? last)
        case .year:
            return nil
        }
    }

    /// Re-read only the calendar half of the range, after a short pause.
    ///
    /// The pause is what makes an account sync — which posts a store change per batch
    /// — cost one fetch instead of forty. Nothing is cleared first and the loading
    /// pill stays down, so saving an event no longer blinks the week out and back.
    private func refreshEvents() {
        guard let range = eventRange else { return }
        eventRefresh?.cancel()
        let calendarService = appState.calendar
        let rangeKey = loadKey
        let currentMode = mode

        eventRefresh = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let fetched = calendarService.dayEvents(from: range.0, to: range.1)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard rangeKey == loadKey else { return }
                switch currentMode {
                case .day, .week:
                    weekEvents = fetched.timed
                    weekAllDay = fetched.allDay
                case .month:
                    var chips = fetched.timed
                    for (day, events) in fetched.allDay {
                        chips[day, default: []].append(contentsOf: events)
                    }
                    monthEvents = chips
                case .year:
                    break
                }
            }
        }
    }

    /// Claim a load slot. A newer load supersedes an older one, so a slow week that
    /// lands after the user already paged elsewhere is dropped instead of flickering in.
    private func beginLoad() -> Int {
        loadToken += 1
        isLoading = true
        loadedKey = nil
        return loadToken
    }

    /// True when `token` is still the newest load (and the spinner should come down).
    private func finishLoad(_ token: Int, key: String) -> Bool {
        guard loadToken == token else { return false }
        isLoading = false
        loadedKey = key
        return true
    }

    // MARK: - Navigation
    //
    // Three ways to the same place: the header chevrons, the arrow keys, and the
    // date picker. None of them is clamped at today: the observed half of the grid
    // has nothing to say about tomorrow, but the scheduled half does, and refusing
    // to page forward hid every meeting the user had already agreed to.

    /// The date the view is currently showing, whatever unit it is showing it in.
    private var anchorDate: Date {
        switch mode {
        case .day:   return selectedDay
        case .week:  return weekRange.0
        case .month: return displayedMonth
        case .year:  return displayedYear
        }
    }

    /// Move by one of whatever unit is on screen.
    private func step(_ delta: Int) {
        keyboardSelection = nil
        switch mode {
        case .day:   dayOffset += delta
        case .week:  weekOffset += delta
        case .month: monthOffset += delta
        case .year:  yearOffset += delta
        }
    }

    /// ⌘T. All four offsets reset, so switching mode afterwards also lands on now.
    private func goToToday() {
        dayOffset = 0
        weekOffset = 0
        monthOffset = 0
        yearOffset = 0
        wantsAnchorScroll = true
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

    func dayIndex(of date: Date) -> Int { CalendarGrid.dayIndex(of: date, from: today) }
    func weekIndex(of date: Date) -> Int { CalendarGrid.weekIndex(of: date, from: today) }
    func monthIndex(of date: Date) -> Int { CalendarGrid.monthIndex(of: date, from: today) }
    func yearIndex(of date: Date) -> Int { CalendarGrid.yearIndex(of: date, from: today) }

    // MARK: - Helpers

    func startOfWeek(_ date: Date) -> Date { CalendarGrid.startOfWeek(date) }

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
        return CalendarGrid.orderedWeekdaySymbols(cal[keyPath: symbols], firstWeekday: cal.firstWeekday)
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

    static func shortDate(_ date: Date) -> String {
        CalendarWeekView.templateFormatter("MMMd").string(from: date)
    }
}

/// How far the hour grid is scrolled. Read so a zoom can keep the same time in view.
private struct GridScrollKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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

extension View {
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        modifier(PointingHandCursor(enabled: enabled))
    }
}

// MARK: - Month View
//
// A flat ruled grid whose cells list what is *in* the day, which is what a month
// view is. It used to be 42 rounded cards, each with a border and a fill, showing a
// dot and a duration — a chart of how busy you were, in the shape of a calendar.

extension CalendarWeekView {

    var monthContent: some View {
        VStack(spacing: 0) {
            monthWeekdayRow
            Divider()
            monthGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // One formatter for the whole grid. Built inside `monthCell` it was 42 of
        // them per layout pass, each re-deriving the locale's date template.
        let dayLabel = CalendarWeekView.templateFormatter("MMMd")
        // 6 week-rows dividing the available height equally, so the grid grows and
        // shrinks with the window. Rules rather than gaps: cells touch, as Apple's do.
        return VStack(spacing: 0) {
            ForEach(weeks.indices, id: \.self) { index in
                HStack(spacing: 0) {
                    ForEach(weeks[index], id: \.self) { monthCell($0, dayLabel: dayLabel) }
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .top) {
                    Rectangle().fill(DS.hairline).frame(height: 0.5)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func monthCell(_ date: Date, dayLabel: DateFormatter) -> some View {
        let cal = Calendar.current
        let key = cal.startOfDay(for: date)
        let inMonth = cal.component(.month, from: date) == cal.component(.month, from: displayedMonth)
        let isToday = cal.isDateInToday(date)
        let events = monthEvents[key] ?? []
        let observed = monthData[key]
        let hasObserved = (observed?.duration ?? 0) > 60
        // Three chips plus the observed line is about what a cell holds at the height
        // six rows leaves it; the rest are counted rather than crammed.
        let shown = events.prefix(hasObserved ? 2 : 3)
        let hidden = events.count - shown.count

        return VStack(alignment: .leading, spacing: 1) {
            if isToday {
                Text(dayNum(date))
                    .font(DS.smallMedium)
                    .foregroundStyle(DS.canvas)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(DS.moon))
            } else {
                Text(dayNum(date))
                    .font(DS.smallFont)
                    .foregroundStyle(inMonth ? DS.ink : DS.inkGhost)
                    .frame(height: 20)
            }

            // Commitments first, then the evidence — outlined and filled keep the
            // same meanings they have on the hour grid.
            ForEach(shown) { event in
                monthChip(event.title, color: event.color, filled: false)
            }
            if hasObserved, let observed {
                monthChip(observed.label.isEmpty ? "Activity" : observed.label,
                          color: DS.moon, filled: true)
            }
            if hidden > 0 {
                Text("+\(hidden) more")
                    .font(DS.miniFont)
                    .foregroundStyle(DS.inkFaint)
                    .padding(.leading, 3)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.xs)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isToday ? DS.moon.opacity(0.05) : Color.clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(DS.hairline).frame(width: 0.5)
        }
        .contentShape(Rectangle())
        .pointingHandCursor()
        .help("Open \(dayLabel.string(from: date)) in Day view · double-click to add an event")
        .onTapGesture(count: 2) { newEvent(on: date) }
        .onTapGesture { jumpToDay(date) }
        .accessibilityAction(named: "New event") { newEvent(on: date) }
    }

    private func monthChip(_ title: String, color: Color, filled: Bool) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title)
                .font(DS.miniFont)
                .foregroundStyle(DS.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusXs)
                .fill(color.opacity(filled ? 0.14 : 0))
        )
    }

    // MARK: Month data

    var displayedMonth: Date {
        let cal = Calendar.current
        let base = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        return cal.date(byAdding: .month, value: monthOffset, to: base) ?? base
    }

    var monthLabel: String {
        CalendarWeekView.templateFormatter("MMMMy").string(from: displayedMonth)
    }

    /// 42 days (6 weeks) covering the month, starting on the first weekday of the
    /// week the 1st falls in — whichever day the system says that is.
    var monthGridDays: [Date] {
        let cal = Calendar.current
        let firstOfMonth = displayedMonth
        let weekday = cal.component(.weekday, from: firstOfMonth)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        guard let start = cal.date(byAdding: .day, value: -lead, to: firstOfMonth) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    /// Up to 42 day analyses plus one EventKit fetch — the heaviest load in the
    /// calendar. Detached for the same reason as the week.
    func loadMonth() {
        let days = monthGridDays
        guard let first = days.first, let last = days.last else { return }
        let rangeEnd = Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last
        let database = appState.database
        let calendarService = appState.calendar
        let rangeKey = loadKey
        let token = beginLoad()
        // Last month's chips must not sit under this month's title.
        monthData = [:]
        monthEvents = [:]
        calendarAccess = calendarService.accessState

        Task.detached(priority: .userInitiated) {
            let engine = TimeBlockEngine(database: database)
            let cal = Calendar.current
            var result: [Date: (duration: TimeInterval, label: String)] = [:]
            for date in days {
                // Don't compute the future — nothing was observed there. The
                // scheduled half below covers it.
                if cal.startOfDay(for: date) > cal.startOfDay(for: Date()) { continue }
                let blocks = engine.generateBlocks(for: date)
                guard !blocks.isEmpty else { continue }
                let total = blocks.reduce(0.0) { $0 + $1.duration }
                let main = blocks.max(by: { $0.duration < $1.duration })
                let label = (main?.label.isEmpty == false ? main?.label : main?.app) ?? ""
                result[cal.startOfDay(for: date)] = (total, label)
            }

            let fetched = calendarService.dayEvents(from: first, to: rangeEnd)
            // A month cell has no hour axis, so a 14:00 meeting and a day of PTO are
            // both simply "on that day" — the two buckets merge here.
            var chips = fetched.timed
            for (day, events) in fetched.allDay {
                chips[day, default: []].append(contentsOf: events)
            }

            await MainActor.run {
                guard finishLoad(token, key: rangeKey) else { return }
                monthData = result
                monthEvents = chips
            }
        }
    }

    /// The digit alone, for the same reason as the week header's — a localised "d"
    /// becomes 19日 and will not sit in the cell's corner.
    private func dayNum(_ date: Date) -> String {
        String(Calendar.current.component(.day, from: date))
    }
}

// MARK: - Year View

extension CalendarWeekView {

    var yearContent: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: DS.xl)],
                      alignment: .leading, spacing: DS.xl) {
                ForEach(yearMonths, id: \.self) { miniMonth($0) }
            }
            .padding(DS.lg)
        }
    }

    /// One mini-month: title, weekday initials from the system's first weekday, then
    /// the day grid. The familiar year-at-a-glance (Apple Calendar風), shaded by how
    /// busy the day was — which is the one thing Apple's year view also does.
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
                    Text(s).font(DS.miniFont).foregroundStyle(DS.inkFaint)
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
            let count = yearCounts[cal.startOfDay(for: day)] ?? 0
            let active = count > 0
            Text("\(cal.component(.day, from: day))")
                .font(DS.miniFont)
                .foregroundStyle(isToday ? DS.canvas : DS.ink)
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
                .help("\(CalendarWeekView.shortDate(day)) · \(pluralized(count, "capture")) recorded")
                .pointingHandCursor()
                .onTapGesture { jumpToDay(day) }
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

    var yearLabel: String {
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
            // A wholly future year: nothing observed to read, but still claim the slot
            // so an older in-flight load can't land afterwards and repaint under this title.
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

    func jumpToDay(_ date: Date) {
        dayOffset = dayIndex(of: date)
        mode = .day
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
