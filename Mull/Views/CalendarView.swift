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
// `CalendarWeekView`'s members are internal, not private, because this view is
// four files: CalendarView.swift plus CalendarView+Grid / +Chrome / +Items /
// +Data. Swift's `private` is file-scoped, so splitting a 2,395-line type into
// readable pieces and keeping `private` are mutually exclusive — and 2,395 lines
// holding data loading, EventKit writes, undo registration, drag geometry, three
// calendar modes and every popover in one scope was the worse of the two. The
// type is still only constructed from FullWindowView; nothing else touches it.
struct CalendarWeekView: View {
    @EnvironmentObject var appState: AppState
    /// The window's undo stack. Every calendar write registers its inverse here, so
    /// ⌘Z reaches them through the responder chain like any other edit.
    @Environment(\.undoManager) var undoManager
    /// When set by the parent (a search hit click), the view jumps to that day in Day mode.
    var jumpDate: Binding<Date?> = .constant(nil)

    @State var weekOffset: Int = 0
    @State var weekBlocks: [Date: [TimeBlock]] = [:]
    @State var weekEvents: [Date: [CalendarEvent]] = [:]
    /// Day-shaped commitments — a flight, PTO, a birthday. They have no place on
    /// the hour axis, so they live in their own band above it (as Apple's do).
    @State var weekAllDay: [Date: [CalendarEvent]] = [:]
    /// The card whose detail or editor is open.
    @State var selectedItem: CalItem?
    /// Set while the "write to Calendar" sheet is up. Holds the plan the sheet is
    /// describing, so what gets written is what the reader agreed to rather than a
    /// freshly computed answer that may have moved on.
    @State var exportProposal: ExportProposal?
    /// Whether the sheet's "keep doing this" box is ticked.
    ///
    /// Lives here rather than in the sheet because the sheet is a function, and it is
    /// reset every time one opens: agreeing to write today is not agreeing to write
    /// every day, and a box that remembered yesterday's tick would turn the second
    /// press into a decision the reader did not make.
    @State var exportKeepUpdated = false
    /// The card the keyboard is on. Separate from `selectedItem` so ↑ / ↓ can walk
    /// the day without a popover springing open at every step.
    @State var keyboardSelection: String?
    @State var hoveredItem: String?
    /// Whether EventKit is actually answering. An empty grid means two entirely
    /// different things depending on this, and the empty state has to say which.
    ///
    /// Seeded from the live status rather than defaulting to `.granted`: the
    /// optimistic default meant any frame drawn before the first refresh told an
    /// unauthorized user "nothing recorded this week" instead of offering them
    /// the permission.
    @State var calendarAccess: CalendarService.Access = CalendarService.currentAccessState

    enum CalMode: String, CaseIterable {
        case day = "Day", week = "Week", month = "Month", year = "Year"

        /// The segment's title, looked up rather than printed.
        ///
        /// The picker used to draw `Text(rawValue)`, and `Text` localises a *literal*,
        /// never a `String` it is handed. So the one control that names the four ranges
        /// stayed in English on a machine where the row beside it had already turned —
        /// 今日, 終日, localised weekday names — and the four translations sat in the
        /// catalogue reachable only by the off-screen ⌘1–⌘4 buttons.
        var label: String {
            switch self {
            case .day:   return String(localized: "Day")
            case .week:  return String(localized: "Week")
            case .month: return String(localized: "Month")
            case .year:  return String(localized: "Year")
            }
        }
    }
    @State var mode: CalMode = .week
    @State var dayOffset: Int = 0
    @State var monthOffset: Int = 0
    @State var monthData: [Date: (duration: TimeInterval, label: String)] = [:]
    /// A month cell lists what was *committed to* as well as what was done, so the
    /// month load fetches EventKit for the whole grid — a month of empty squares
    /// with a dot in the corner was a chart of activity, not a calendar.
    @State var monthEvents: [Date: [CalendarEvent]] = [:]
    @State var yearOffset: Int = 0
    @State var yearCounts: [Date: Int] = [:]
    /// Busiest day of the loaded year — hoisted out of `activeFraction`, which is
    /// called once per cell (365+ times) and used to re-scan every value each time.
    @State var yearMax: Int = 1

    // Loading lives off the main thread: a week is 7 block analyses + 1 EventKit
    // round-trip, a month is up to 42, and a year is a full-range SQL aggregate.
    // `loadToken` invalidates a load whose result arrived after the user moved on.
    @State var isLoading = false
    @State var loadToken = 0
    /// The range whose data is currently on screen — `nil` while a load is in flight.
    /// This is what keeps the header and the body from ever disagreeing.
    @State var loadedKey: String?
    /// The debounced events-only refresh. A calendar change should not re-derive a
    /// week of activity blocks from the database, and a busy sync should not do it
    /// forty times.
    @State var eventRefresh: Task<Void, Never>?
    /// The in-flight re-derive of today's blocks, so a slow minute cannot stack up
    /// behind the next one.
    @State var blockRefresh: Task<Void, Never>?

    /// The clock behind the "now" line. Read from state, not `Date()` during body —
    /// body only re-runs on state changes, so the line used to freeze mid-morning.
    @State var now = Date()
    let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// The day everything in here is measured from. Every offset below is relative
    /// to "today", so this is the origin of the whole view — and a window left open
    /// overnight used to keep yesterday's origin: the header still said Today, and
    /// the blocks under it were the previous day's. Holding the origin in state lets
    /// a rollover invalidate `loadKey`, so the day mull is showing is always a day
    /// it has actually read.
    @State var today = Calendar.current.startOfDay(for: Date())

    /// How tall an hour is drawn. Apple's calendar stretches under ⌘+ / ⌘− and a
    /// pinch, and the setting survives the window closing — so this is stored, not
    /// a constant. The whole grid is always 24 × this.
    @AppStorage("calendarHourHeight") var hourHeightSetting: Double = 52
    /// Not read here — `TimeBlockEngine` reads it. Held so the grid can notice the
    /// setting change: it decides where the blocks under the reader's eyes begin and
    /// end, and a grid that kept the old segmentation until the next navigation would
    /// look exactly like a control that does nothing.
    @AppStorage(Preferences.resumeGapKey) var resumeGapSetting = Int(BlockSegmenter.defaultResumeGap)
    /// Where a pinch started from, so the gesture scales the hour it began on rather
    /// than compounding on every delta.
    @State var pinchBase: Double?
    /// How far down the grid is scrolled, in points. Tracked so a zoom can put the
    /// same *time* back under the eye instead of the same pixel.
    @State var scrollOffset: CGFloat = 0
    @State var zoomAnchorHour: Int?
    /// Whether the next load should jump the grid to the present.
    ///
    /// It used to do that on every load, which meant paging from week to week yanked
    /// you back to this morning each time. Apple keeps your position when you page;
    /// only opening the view, switching range, or asking for Today should move it.
    @State var wantsAnchorScroll = true

    /// The jump-to-date popover. Reaching a day three months back used to be a
    /// dozen chevron clicks; the grid keeps the focus so the arrow keys work.
    @State var showingDatePicker = false
    @State var pickerDate = Date()
    @FocusState var gridFocused: Bool

    // MARK: Writing

    /// Composed once and held, because `UndoManager` does *not* retain the target it
    /// registers against — a writer rebuilt per body pass would take the whole undo
    /// stack down with it.
    @State var writer: CalendarWriter?

    /// Whether the reader has asked the system to move things less.
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// An animation, or none at all where the reader has asked for less movement.
    ///
    /// Everything the calendar animates goes through here. Motion added to a grid this
    /// dense is exactly what Reduce Motion exists to switch off, and a helper that
    /// returns `nil` means honouring it costs one call rather than a branch at each
    /// site — `withAnimation` and `.animation(_:value:)` both take an optional and read
    /// `nil` as "just change".
    func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// An event being composed on the grid and not yet in EventKit.
    struct EventDraft {
        var day: Date
        var start: Date
        var end: Date
        var title: String = ""
        var isAllDay: Bool = false
        var calendarID: String?
    }
    @State var draft: EventDraft?
    @FocusState var draftFocused: Bool
    /// An hour the grid has been asked to bring into view, on purpose rather than as a
    /// side effect of a load.
    ///
    /// The token is what makes asking twice for the same hour scroll twice — walking
    /// ↓ through three meetings inside one hour has to keep working.
    struct ScrollRequest: Equatable {
        var hour: Int
        var token: Int
    }
    @State var scrollRequest: ScrollRequest?
    @State var scrollRequestCount = 0

    /// Ask the grid to put `moment` where it can be seen, an hour down from the top so
    /// it doesn't sit against the edge.
    func bringIntoView(_ moment: Date) {
        scrollRequestCount += 1
        scrollRequest = ScrollRequest(hour: max(Calendar.current.component(.hour, from: moment) - 1, 0),
                                      token: scrollRequestCount)
    }
    /// Which half of the draft card a drag took hold of, and the times the card had
    /// when that drag began — held rather than read back each frame, so dragging away
    /// and back again doesn't compound its own snapping.
    @State var draftGrip: ActiveDrag.Kind?
    @State var draftGripOrigin: DateInterval?

    /// Whether the card being typed into is still on a day the grid is drawing.
    ///
    /// Only Day and Week have somewhere to draw one; Month and Year have no hour axis
    /// and no all-day band.
    var draftIsVisible: Bool {
        guard let draft, mode == .day || mode == .week else { return false }
        return displayedDays.contains { Calendar.current.isDate($0, inSameDayAs: draft.day) }
    }

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
    @State var dragging: ActiveDrag?

    /// Whatever went wrong with a write, in the user's words. An alert, because a
    /// failed save must not be something you can miss.
    @State var writeError: String?

    /// The day the month grid has selected. Clicking a cell used to jump straight to
    /// Day view, so there was no way to point at a day in the month without leaving
    /// the month — the one thing a month view is for.
    @State var monthSelection: Date?

    /// The two settings that decide whether the mirror runs at all.
    ///
    /// Read here, and only to draw the status pill: `@AppStorage` is what makes the
    /// toolbar notice the moment the export sheet turns the mirror on, without which
    /// the pill would not appear until the next minute tick. The counts behind it come
    /// from `CalendarMirrorStatus`, which is not observable and does not need to be —
    /// see `mirrorState`.
    @AppStorage(Preferences.mirrorEnabledKey) var mirrorIsOn = false
    @AppStorage(Preferences.mirrorCalendarKey) var mirrorCalendarID = ""

    /// Calendars the reader has switched off, by identifier.
    ///
    /// Stored as one string because `@AppStorage` cannot hold a `Set`. It filters the
    /// *view's* reads only: `dayEvents` takes the exclusion as an argument and
    /// defaults to none, so hiding a holiday feed here says nothing to `MullMCP`
    /// about what the agent may see.
    @AppStorage("calendarHiddenIDs") var hiddenCalendarIDs: String = ""

    var hiddenCalendars: Set<String> {
        Set(hiddenCalendarIDs.split(separator: "\n").map(String.init))
    }

    func setCalendar(_ id: String, hidden: Bool) {
        var ids = hiddenCalendars
        if hidden { ids.insert(id) } else { ids.remove(id) }
        hiddenCalendarIDs = ids.sorted().joined(separator: "\n")
        refreshEvents()
    }

    var hourHeight: CGFloat { CGFloat(hourHeightSetting) }
    /// Wide enough for "12 AM" and for "12時" — the old 48 was sized for a bare digit.
    let timeColumnWidth: CGFloat = 58
    /// One bar in the all-day band. Scaled, because the title inside it is: a fixed
    /// 18 clips the text at the larger system sizes, and a bar that has to be a fixed
    /// height is the price of lanes that line up across seven columns.
    @ScaledMetric(relativeTo: .caption2) var allDayBarHeight: CGFloat = 18

    static let minHourHeight: Double = 26
    static let maxHourHeight: Double = 180
    /// Below this the half-hour rule crowds the hour rule instead of dividing it.
    static let halfHourRuleThreshold: CGFloat = 34
    /// Legibility floor for a drawn span, and the room kept below a padded one.
    static let minSpanHeight: CGFloat = 18
    static let spanGap: CGFloat = 1
    /// The strip at a card's lower edge that stretches it rather than moving it.
    static let resizeGrip: CGFloat = 8
    static let gridSpace = "calendar.grid"
    /// How many lanes of all-day the band shows before it starts scrolling instead of
    /// pushing the hour grid down the window. A fortnight of overlapping trips is
    /// rare; a band that eats half the screen when it happens is not acceptable.
    static let maxAllDayLanes = 3

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            modeContent
                // A load empties the grid before it refills it, so paging read as a
                // flash of blank week followed by a pop. Dimming while the answer is
                // being fetched makes those two moments one crossfade, and says with
                // the picture what the pill says in words.
                .opacity(isLoading ? 0.55 : 1)
                .overlay(alignment: .top) {
                    if isLoading { loadingPill }
                }
                // The pill has carried `.transition(.opacity)` all along and has never
                // once used it: a transition needs the state change driving it to be
                // animated, and `isLoading` was set from `beginLoad` / `finishLoad`
                // with nothing around it. So the pill appeared and vanished instantly,
                // which is the one thing a "still working" indicator must not do.
                .animation(motion(.easeOut(duration: 0.18)), value: isLoading)
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
            // The observed half was derived once, when the range was opened, and
            // then never again — so a window left on today showed the work you were
            // doing when you opened it and nothing since. The red now-line kept
            // moving down an hour that stayed empty.
            refreshToday()
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
            // The open popover is anchored to a card in the range being left. Closing
            // on screen writes its own binding back; a card removed out from under it
            // does not, and a `selectedItem` left behind stands ⌘Z, ⌫ and Return down
            // over an editor nobody can see — the same trap the draft used to set.
            selectedItem = nil
            // A pending jump is about to change the key; let it own the load.
            guard jumpDate.wrappedValue == nil else { return }
            loadCurrent()
        }
        .onChange(of: mode) { _, _ in
            // A new range is a new view of the day; that one *should* open at now.
            wantsAnchorScroll = true
            keyboardSelection = nil
        }
        // A draft is a card on a day, and only the days on screen draw one. Paging to
        // next week, jumping to a date or switching to Month therefore left it alive
        // with nothing drawing it: the title being typed was dropped without a word the
        // next time a draft was opened, and — because ⌘Z, ⌫ and Return all stand down
        // while a title is being typed — the keyboard stayed stood down over a card
        // that was no longer anywhere. Leaving its day discards it, which is what
        // Escape would have done. Nothing was written, so there is nothing to undo.
        .onChange(of: draftIsVisible) { _, visible in
            if !visible { draft = nil }
        }
        // Only the observed half is re-derived, and only because its segmentation
        // just changed underneath it.
        .onChange(of: resumeGapSetting) { _, _ in loadCurrent() }
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
        .sheet(item: $exportProposal) { exportSheet($0) }
    }

    var writeErrorBinding: Binding<Bool> {
        Binding(get: { writeError != nil }, set: { if !$0 { writeError = nil } })
    }

    /// Build the writer once and wire its two outputs to this view's state.
    func prepareWriter() {
        guard writer == nil else { return }
        let made = CalendarWriter(service: appState.calendar)
        made.onError = { message in writeError = message }
        made.onChange = { refreshEvents() }
        writer = made
    }

    /// The shortcuts Calendar.app answers to, laid out off-screen because they
    /// belong to the view rather than to any one control on it.
    var keyEquivalents: some View {
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

    func zoom(by factor: Double) {
        zoomAnchorHour = Int(scrollOffset / hourHeight)
        withAnimation(motion(.easeOut(duration: 0.15))) {
            hourHeightSetting = clampHour(hourHeightSetting * factor)
        }
    }

    func clampHour(_ value: Double) -> Double {
        min(max(value, Self.minHourHeight), Self.maxHourHeight)
    }

    /// Move the origin when the calendar day turns under an open window. Cheap and
    /// idempotent, so both callers can fire it freely.
    func rollOver(to instant: Date) {
        let start = Calendar.current.startOfDay(for: instant)
        guard start != today else { return }
        today = start
    }

    /// Identity of what is on screen. Everything that should cause a reload — and
    /// nothing that shouldn't — belongs in here. The origin day is part of that
    /// identity: "day|0" means a different day either side of midnight.
    var loadKey: String {
        let origin = Int(today.timeIntervalSinceReferenceDate)
        switch mode {
        case .day:   return "day|\(origin)|\(dayOffset)"
        case .week:  return "week|\(origin)|\(weekOffset)"
        case .month: return "month|\(origin)|\(monthOffset)"
        case .year:  return "year|\(origin)|\(yearOffset)"
        }
    }

    func loadCurrent() {
        switch mode {
        case .day:   loadDay()
        case .week:  loadWeek()
        case .month: loadMonth()
        case .year:  loadYear()
        }
    }

    @ViewBuilder
    var modeContent: some View {
        switch mode {
        case .day:   dayContent
        case .week:  weekContent
        case .month: monthContent
        case .year:  yearContent
        }
    }

    /// A quiet note that the grid is still filling — the analysis runs off the main
    /// thread, so the view is live (scrollable) while this is up.
    var loadingPill: some View {
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
    func applyJump() {
        guard let target = jumpDate.wrappedValue else { return }
        dayOffset = dayIndex(of: target)
        mode = .day
        wantsAnchorScroll = true
        jumpDate.wrappedValue = nil
        // No load here: changing the offset and mode changes `loadKey`, and the
        // single onChange above owns loading.
    }

}

/// How far the hour grid is scrolled. Read so a zoom can keep the same time in view.
/// Internal, not file-private: the grid lives in CalendarView+Grid.swift.
struct GridScrollKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Pointer feedback

/// A pointing hand over anything that actually does something. macOS 14 has no
/// `.pointerStyle`, so the cursor is pushed and popped by hand; the `inside` flag
/// keeps the stack balanced, including when the control is disabled or removed
/// while the pointer is still over it.
struct PointingHandCursor: ViewModifier {
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

        let isSelected = monthSelection.map { cal.isDate($0, inSameDayAs: date) } ?? false

        return VStack(alignment: .leading, spacing: 1) {
            // The number is the way into the day, as it is in Calendar.app. The cell
            // itself used to be: a single click anywhere in it left the month, so
            // there was no way to point at a day and stay where you were.
            Button { jumpToDay(date) } label: {
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
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(isSelected ? DS.moon.opacity(0.16) : .clear))
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Open \(dayLabel.string(from: date)) in Day view")

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
        .background(isToday ? DS.moon.opacity(0.05)
                            : (isSelected ? DS.moon.opacity(0.04) : Color.clear))
        .overlay(alignment: .leading) {
            Rectangle().fill(DS.hairline).frame(width: 0.5)
        }
        .overlay {
            if isSelected {
                Rectangle().strokeBorder(DS.moon.opacity(0.5), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        // One literal. `Text`/`help` take `LocalizedStringKey` from a literal and the
        // pass-through initialiser from a `String` expression, so the `+` that used to
        // join these two halves quietly took this line out of the catalog (WRITING.md §5.4).
        .help("Click to select \(dayLabel.string(from: date)) · double-click to add an event · click the date to open it in Day view")
        .onTapGesture(count: 2) { newEvent(on: date) }
        .onTapGesture { monthSelection = key }
        .accessibilityAction(named: "New event") { newEvent(on: date) }
        .accessibilityAction(named: "Open in Day view") { jumpToDay(date) }
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

    /// The 42 days this grid draws. Shared with `MonthPicker` — see
    /// `CalendarGrid.monthGridDays`.
    var monthGridDays: [Date] { CalendarGrid.monthGridDays(of: displayedMonth) }

    /// Up to 42 day analyses plus one EventKit fetch — the heaviest load in the
    /// calendar. Detached for the same reason as the week.
    func loadMonth() {
        let days = monthGridDays
        guard let first = days.first, let last = days.last else { return }
        let rangeEnd = Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last
        let database = appState.database
        let calendarService = appState.calendar
        let rangeKey = loadKey
        let hidden = hiddenCalendars
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

            let fetched = calendarService.dayEvents(from: first, to: rangeEnd, excluding: hidden)
            // A month cell has no hour axis, so a 14:00 meeting and a day of PTO are
            // both simply "on that day" — the two buckets merge here, day-shaped first.
            let chips = CalendarService.merged(timed: fetched.timed, allDay: fetched.allDay)

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
            VStack(alignment: .leading, spacing: DS.md) {
                // Every other range in this window shades by what was *scheduled*.
                // This one shades by what was recorded, which is a different question
                // wearing the same shape: a day full of meetings you spent away from
                // the Mac is pale here, and a quiet Sunday of writing is dark. The
                // tooltip said "captures"; nothing said it before you hovered.
                Text("Shaded by what mull recorded, not by what was scheduled.")
                    .font(DS.miniFont)
                    .foregroundStyle(DS.inkFaint)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: DS.xl)],
                          alignment: .leading, spacing: DS.xl) {
                    ForEach(yearMonths, id: \.self) { miniMonth($0) }
                }
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
                .help(counted(count,
                              one: "\(CalendarWeekView.shortDate(day)) · 1 capture recorded",
                              other: "\(CalendarWeekView.shortDate(day)) · \(count) captures recorded"))
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
