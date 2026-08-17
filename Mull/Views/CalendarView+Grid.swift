import SwiftUI
import EventKit
import AppKit

// The hour grid: the columns, the drag that makes an event, and the drag that
// moves or resizes one.
//
// Lifted out of CalendarView.swift, which was 2,395 lines in a single `View`
// type — data loading, EventKit writes, undo registration, drag geometry, three
// calendar modes and every popover in one scope. Nothing here changed in the
// move; these are the same members in an extension on the same type.

extension CalendarWeekView {

    // MARK: - The hour grid
    //
    // All 24 hours, always. The grid used to draw only the band the day's activity
    // occupied, which meant its height and its scroll position changed every time a
    // load landed — the single largest reason it did not feel like a calendar. The
    // hours you were not here are cheap; the grid simply opens at the present.

    func timeGrid(days: [Date]) -> some View {
        let labels = TimeFormat.hourLabels()
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    timeLabels(labels)
                    ForEach(days, id: \.self) { dayColumn(date: $0) }
                }
                // The card being dragged is drawn here rather than in its column,
                // because a column clips its contents and a drag to Wednesday has to
                // be visible in Wednesday. Inside the scrolled content, so it keeps
                // its hour when the grid moves under it.
                .overlay(alignment: .topLeading) { dragPreview(days: days) }
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
                // What carries the grid to a draft ⌘N opened at an hour of its own, and
                // to a card ↑ / ↓ walked to below the fold.
                .onChange(of: scrollRequest) { _, request in
                    guard let request else { return }
                    DispatchQueue.main.async {
                        withAnimation(motion(.easeOut(duration: 0.18))) {
                            proxy.scrollTo(request.hour, anchor: .top)
                        }
                    }
                }
            }
            .coordinateSpace(name: Self.gridSpace)
            .onPreferenceChange(GridScrollKey.self) { offset in scrollOffset = offset }
            .gesture(pinchToZoom)
        }
    }

    /// Pinch stretches the hour, as it does in Calendar.app. Anchored to the height
    /// the gesture began at so the scale doesn't compound with every delta.
    var pinchToZoom: some Gesture {
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

    func timeLabels(_ labels: [String]) -> some View {
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
    var hourLines: some View {
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

    func dayColumn(date: Date) -> some View {
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
                    let span = spans[index]
                    let slice = CalendarGrid.slice(span, laneX: 2, laneWidth: lane)
                    itemView(item, width: slice.width, span: span,
                             on: date, columnWidth: proxy.size.width)
                        // Hidden, not removed: the gesture that is driving the drag
                        // belongs to this view, and a view taken out of the hierarchy
                        // mid-drag takes the drag with it. The preview above stands
                        // in for it wherever the pointer has got to.
                        .opacity(isBeingDragged(item) ? 0 : 1)
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
        .accessibilityAction(named: String(localized: "New event on \(Self.shortDate(date))")) {
            newEvent(on: date)
        }
    }

    /// Everything drawn on one day's axis, in one list — which is what lets a meeting
    /// and the work either side of it share the width instead of each being penned
    /// into a fixed fraction of the column.
    func items(on date: Date) -> [CalItem] {
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
    func emptySlotLayer(on date: Date) -> some View {
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
    func beginDraft(on date: Date, from startY: CGFloat, to endY: CGFloat?) {
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
    func newEvent(in calendarID: String? = nil) {
        let cal = Calendar.current
        switch mode {
        case .day:
            newEvent(on: selectedDay, in: calendarID)
        case .week:
            let day = displayedDays.first { cal.isDateInToday($0) } ?? displayedDays.first ?? today
            newEvent(on: day, in: calendarID)
        case .month, .year:
            // There is no hour axis to put it on here, so go where there is one — on
            // the day the month grid has selected, if that day is one it is showing.
            let selected = monthSelection.flatMap { day in
                mode == .month && cal.isDate(day, equalTo: displayedMonth, toGranularity: .month)
                    ? day : nil
            }
            let inThisMonth = cal.isDate(displayedMonth, equalTo: today, toGranularity: .month)
            newEvent(on: selected ?? (inThisMonth ? today : displayedMonth), in: calendarID)
        }
    }

    func newEvent(on day: Date, in calendarID: String? = nil) {
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
        // Unlike a draft made by pointing at the grid, this one is at an hour nobody
        // just looked at. Bring the grid to it.
        bringIntoView(base)
    }

    /// The card being composed. It carries its own text field and its own two
    /// instructions, because a card that appears under the cursor with a caret in it
    /// has to say what Return and Escape will do.
    @ViewBuilder
    func draftCard(on date: Date) -> some View {
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
                    // Asked for again here, and this is the request that lands.
                    // `beginDraft` sets `draftFocused` in the same turn as it sets
                    // `draft` — which is a turn in which this field does not exist yet,
                    // and a `@FocusState` aimed at a field that is not in the hierarchy
                    // is dropped rather than remembered. The card appeared with no caret
                    // in it often enough to look like weather: you double-clicked, typed,
                    // and the title went to whatever had the keyboard before.
                    .onAppear { draftFocused = true }
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
            .gesture(draftGesture(height: height))
            .offset(y: y)
            .accessibilityLabel("New event")
            // Escape anywhere in the draft throws it away — nothing has been written
            // yet, so there is nothing to undo.
            .onExitCommand { self.draft = nil }
        }
    }

    var draftTitle: Binding<String> {
        Binding(get: { draft?.title ?? "" }, set: { draft?.title = $0 })
    }

    /// The draft answers the same two drags a real card does — the body moves it, the
    /// lower edge stretches it.
    ///
    /// Without them the times a draft opened with were the times it had to be saved
    /// with. The card sits *over* the empty grid the create-drag comes from, so there
    /// was no second drag to be had: a meeting that wanted to be half an hour later,
    /// or half an hour longer, meant Escape and typing the title again.
    ///
    /// Down the column only. Sideways would mean redrawing the card in another column,
    /// and the field being typed into would go with it — a caret that changes windows
    /// mid-word is worse than a drag that cannot cross a day.
    func draftGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                guard var next = draft else { return }
                if draftGrip == nil {
                    draftGrip = value.startLocation.y >= height - Self.resizeGrip ? .resize : .move
                    draftGripOrigin = DateInterval(start: next.start,
                                                   end: max(next.end, next.start))
                }
                guard let grip = draftGrip, let origin = draftGripOrigin else { return }
                let shift = TimeInterval(Double(value.translation.height / hourHeight) * 3600)
                switch grip {
                case .move:
                    let moved = CalendarGrid.draggedStart(from: origin.start, shift: shift, dayDelta: 0)
                    next.start = moved
                    next.end = moved.addingTimeInterval(origin.duration)
                case .resize:
                    // Same floor the create-drag uses: a quarter of an hour still has
                    // to mean something.
                    let ended = CalendarGrid.snapped(origin.end.addingTimeInterval(shift),
                                                     rounding: .nearest)
                    next.end = max(ended, next.start.addingTimeInterval(900))
                }
                draft = next
            }
            .onEnded { _ in
                draftGrip = nil
                draftGripOrigin = nil
                // The drag took the caret out of the field. Put it back, or Return no
                // longer saves the thing that was just moved into place.
                draftFocused = true
            }
    }

    /// Write the draft. The grid does not paint the new event itself — it saves, and
    /// the store's change notification brings it back as a real event, so what you
    /// end up looking at is EventKit's copy and not mull's guess at it.
    func commitDraft() {
        guard let draft, let writer else { return }
        let fields = CalendarService.EventFields(
            title: CalendarGrid.draftTitle(draft.title, placeholder: String(localized: "New Event")),
            start: draft.start, end: draft.end,
            location: nil, isAllDay: draft.isAllDay, calendarID: draft.calendarID
        )
        writer.create(fields, undo: undoManager)
        self.draft = nil
        gridFocused = true
    }

    /// The moment a point down the column stands for.
    func time(on day: Date, atY y: CGFloat) -> Date {
        CalendarGrid.time(on: day, atY: y, hourHeight: hourHeight)
    }

    // MARK: - Moving and stretching an event
    //
    // Creating an event without being able to nudge it afterwards leaves the whole
    // feature at "type it right the first time, or open the editor" — and the grid
    // is where you can *see* that the meeting wants to be half an hour later.

    func isBeingDragged(_ item: CalItem) -> Bool {
        dragging?.itemID == item.id && dragging?.moved == true
    }

    /// The card as it will be if it is dropped here — at the hour the pointer is on,
    /// in the column the pointer is over, reading the time it is *about to have*.
    ///
    /// The card used to be moved by adjusting its laid-out span in place, which left
    /// two things wrong at once: it could not leave its own column, and the time
    /// printed on it stayed the time the event still had in EventKit. Dragging a
    /// 10:00 meeting down to the afternoon showed a card sitting at 15:00 with
    /// "10:00 – 11:00" written inside it.
    @ViewBuilder
    func dragPreview(days: [Date]) -> some View {
        if let dragging, dragging.moved,
           let column = days.firstIndex(where: {
               Calendar.current.isDate($0, inSameDayAs: dragging.start)
           }) {
            GeometryReader { geo in
                let columnWidth = max((geo.size.width - timeColumnWidth) / CGFloat(days.count), 1)
                let height = max(hourHeight * dragging.end.timeIntervalSince(dragging.start) / 3600,
                                 Self.minSpanHeight)

                VStack(alignment: .leading, spacing: DS.hair) {
                    Text(dragging.original.title)
                        .font(DS.miniMedium)
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)
                    if height >= 30 {
                        Text("\(TimeFormat.person(dragging.start)) – \(TimeFormat.person(dragging.end))")
                            .font(DS.miniFont)
                            .foregroundStyle(DS.inkDim)
                    }
                }
                .padding(.horizontal, DS.xs)
                .padding(.vertical, DS.radiusXs)
                .frame(width: max(columnWidth - 4, 12), height: height, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: DS.radiusChip).fill(DS.moon.opacity(0.16)))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusChip)
                        .strokeBorder(DS.moon.opacity(0.8), lineWidth: 1)
                )
                .offset(x: timeColumnWidth + columnWidth * CGFloat(column) + 2,
                        y: CalendarGrid.yOffset(for: dragging.start, hourHeight: hourHeight))
            }
            .allowsHitTesting(false)
        }
    }

    /// Body drags move; the lower edge stretches. Only scheduled events on writable
    /// calendars respond — an observed block is a record of what happened, and moving
    /// it would be editing the past.
    ///
    /// A move goes sideways as well as down: whole columns across, as Calendar.app
    /// does, and clamped inside the day it lands on so the axis cannot quietly change
    /// the date on its own (`CalendarGrid.draggedStart`).
    func dragGesture(for item: CalItem, span: CalendarGrid.Span,
                     on date: Date, columnWidth: CGFloat) -> some Gesture {
        let days = displayedDays
        let column = days.firstIndex { Calendar.current.isDate($0, inSameDayAs: date) } ?? 0

        return DragGesture(minimumDistance: 4, coordinateSpace: .local)
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
                    let dayDelta = CalendarGrid.draggedColumns(value.translation.width,
                                                               columnWidth: columnWidth,
                                                               from: column, columns: days.count)
                    let moved = CalendarGrid.draggedStart(from: item.start,
                                                          shift: shift, dayDelta: dayDelta)
                    active.start = moved
                    active.end = moved.addingTimeInterval(item.end.timeIntervalSince(item.start))
                case .resize:
                    // Stretching keeps the start where it is, so the day cannot move
                    // and only the length is in question. Past midnight is allowed —
                    // events do run late, and the grid marks the ones that do.
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
}
