import SwiftUI

/// The inspector for one scheduled event.
///
/// The first version of this was a 280pt column holding two `.compact` date
/// pickers, which is the worst of both worlds on a Mac: each control carries a
/// whole date *and* a time in one squeezed field, neither half can be reached with
/// the arrow keys, and there is no way to say "make it an hour" without doing
/// arithmetic on the end time yourself.
///
/// So the form is built around what is actually being changed:
///
///   - the **date** is one field with a calendar button beside it, because most
///     events begin and end on the same day and the second date only appears when
///     they don't;
///   - the **times** are stepper fields — arrow keys, ⇅ buttons, typing, all of it;
///   - the **duration** is a menu of the lengths meetings actually are, so the end
///     time is usually something you pick rather than compute;
///   - moving the start carries the end along with it, keeping the length.
///
/// Nothing is written until Save. Delete asks twice. Both go through
/// `CalendarWriter`, so ⌘Z undoes either.
struct EventEditor: View {
    let event: CalendarEvent
    /// Which occurrence this form is editing — not merely which series. See
    /// `CalendarService.EventHandle`.
    let handle: CalendarService.EventHandle
    let calendars: [CalendarService.WritableCalendar]
    let writer: CalendarWriter
    let undoManager: UndoManager?
    let onFinished: () -> Void

    @State private var fields: CalendarService.EventFields
    @State private var confirmingDelete = false
    @State private var showingStartCalendar = false
    @State private var showingEndCalendar = false
    /// What was on screen when the editor opened — the "before" half of the undo,
    /// and what tells Save whether there is anything to do.
    ///
    /// `@State`, not a `let`: this struct is rebuilt whenever the grid behind it
    /// re-renders (the minute tick, an EventKit change notification), and a plain
    /// property would be recomputed from the store on every one of those while the
    /// user's `fields` stayed put. An event moved in Calendar.app under an open,
    /// untouched editor then read as an unsaved edit — Save lit up, and Return
    /// wrote the old time back over the new one.
    @State private var original: CalendarService.EventFields
    /// The clock times the event had before "All-day" was switched on.
    ///
    /// The toggle used to be a one-way door: on, then off again, left a 14:30
    /// meeting as a 24-hour block beginning at midnight, with nothing short of ⌘Z
    /// after a save to get the afternoon back.
    @State private var timedSpan: DateInterval?

    /// The lengths meetings actually are. "Custom" is not in the list because the
    /// end field is right there; this is the shortcut, not the only way.
    private static let durations: [(String, TimeInterval)] = [
        ("15 min", 900), ("30 min", 1800), ("45 min", 2700),
        ("1 hr", 3600), ("1 hr 30", 5400), ("2 hr", 7200), ("3 hr", 10800),
    ]

    private static let labelWidth: CGFloat = 64
    private static let dateFieldWidth: CGFloat = 116
    private static let timeFieldWidth: CGFloat = 96

    init(event: CalendarEvent,
         handle: CalendarService.EventHandle,
         calendars: [CalendarService.WritableCalendar],
         writer: CalendarWriter,
         undoManager: UndoManager?,
         onFinished: @escaping () -> Void) {
        self.event = event
        self.handle = handle
        self.calendars = calendars
        self.writer = writer
        self.undoManager = undoManager
        self.onFinished = onFinished

        // Read from EventKit where possible rather than from the card mull drew:
        // the card can be a minute old, and undo has to restore what was really there.
        let current = writer.currentFields(handle)
            ?? CalendarService.EventFields(title: event.title, start: event.start,
                                           end: event.end, location: event.location,
                                           isAllDay: event.isAllDay,
                                           calendarID: event.calendarIdentifier)
        // Both are `State(initialValue:)`, which SwiftUI honours on first
        // presentation and ignores on every rebuild after it — which is exactly
        // the lifetime "what was on screen when the editor opened" describes.
        _fields = State(initialValue: current)
        _original = State(initialValue: current)
    }

    private var hasChanges: Bool { fields != original }

    private var spansTwoDays: Bool {
        !Calendar.current.isDate(fields.start, inSameDayAs: fields.end)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            titleRow
            if event.isRecurring { recurrenceRow }
            Divider()
            allDayRow
            startRow
            endRow
            if !fields.isAllDay { durationRow }
            if calendars.count > 1 { calendarRow }
            locationRow
            Divider()
            buttonRow
        }
        .padding(DS.lg)
        .frame(width: 340)
        .onExitCommand { onFinished() }
    }

    // MARK: - Rows

    private var titleRow: some View {
        HStack(spacing: DS.sm) {
            RoundedRectangle(cornerRadius: DS.radiusXs)
                .fill(event.color)
                .frame(width: 4, height: 22)
            TextField("New Event", text: $fields.title)
                .textFieldStyle(.plain)
                .font(DS.subtitleMedium)
                .onSubmit(save)
        }
    }

    /// What every write in this form is going to mean.
    ///
    /// mull saves and deletes with EventKit's `.thisEvent` throughout — a decision
    /// made where the undo chain lives, because an occurrence removed from a series
    /// cannot be put back into it. The form used to be silent about that, so moving
    /// Wednesday's stand-up read as moving the stand-up, and every other calendar the
    /// reader has ever used would have asked which they meant.
    private var recurrenceRow: some View {
        HStack(spacing: DS.xs) {
            Image(systemName: DS.Glyph.repeats)
            Text(CalendarWeekView.CalItem.recurrenceNote)
        }
        .font(DS.miniFont)
        .foregroundStyle(DS.inkFaint)
        .accessibilityElement(children: .combine)
    }

    private var allDayRow: some View {
        row("All-day") {
            Toggle("", isOn: $fields.isAllDay)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .onChange(of: fields.isAllDay) { _, isAllDay in
                    let cal = Calendar.current
                    guard isAllDay else {
                        // Back to a clock. Where there were times before the toggle
                        // was switched on, they are what comes back — put on
                        // whatever day the form says *now*, so a date changed while
                        // it was all-day isn't thrown away. An event that arrived
                        // all-day has no times to return to and gets a working hour.
                        let previous = timedSpan.map { cal.dateComponents([.hour, .minute], from: $0.start) }
                        let length = timedSpan.map { max($0.duration, 60) } ?? 3600
                        let base = cal.date(bySettingHour: previous?.hour ?? 9,
                                            minute: previous?.minute ?? 0,
                                            second: 0, of: fields.start) ?? fields.start
                        fields.start = base
                        fields.end = base.addingTimeInterval(length)
                        return
                    }
                    // A day-shaped commitment starts at midnight and runs whole days;
                    // leaving 14:30 in the fields would write an "all-day" event that
                    // EventKit files on two days.
                    timedSpan = DateInterval(start: fields.start, end: max(fields.end, fields.start))
                    fields.start = cal.startOfDay(for: fields.start)
                    fields.end = cal.date(byAdding: .day, value: 1,
                                          to: cal.startOfDay(for: fields.end)) ?? fields.end
                }
            Spacer(minLength: 0)
        }
    }

    private var startRow: some View {
        row("Starts") {
            dateField(startBinding, showingCalendar: $showingStartCalendar)
            if !fields.isAllDay { timeField(startBinding) }
            Spacer(minLength: 0)
        }
    }

    private var endRow: some View {
        row("Ends") {
            // The second date only earns its place when the event actually crosses
            // midnight; the rest of the time it is a field saying the same thing twice.
            if spansTwoDays || fields.isAllDay {
                dateField(endBinding, showingCalendar: $showingEndCalendar)
            } else {
                Text(Self.dayLabel(fields.end))
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .frame(width: Self.dateFieldWidth, alignment: .leading)
            }
            if !fields.isAllDay { timeField(endBinding, notBefore: fields.start) }
            Spacer(minLength: 0)
        }
    }

    /// The start, bound so that moving it carries the end along and keeps the
    /// length. Every calendar does this, and nobody notices until one doesn't.
    ///
    /// A binding rather than an `.onChange`, because the observer used to hang off
    /// the *time* field — which is not in the hierarchy at all when the event is
    /// all-day. An all-day event's start date could therefore be pushed past its
    /// own end with nothing carrying it and nothing complaining, leaving a form
    /// that showed one thing and saved another.
    private var startBinding: Binding<Date> {
        Binding(
            get: { fields.start },
            set: { moved in
                let floor: TimeInterval = fields.isAllDay ? 86_400 : 60
                let length = max(fields.end.timeIntervalSince(fields.start), floor)
                fields.start = moved
                fields.end = moved.addingTimeInterval(length)
            }
        )
    }

    /// The end, floored at the start. The timed field has `in:` to lean on; the
    /// all-day date field has nothing, so the floor lives here where both reach it.
    private var endBinding: Binding<Date> {
        Binding(
            get: { fields.end },
            set: { fields.end = max($0, minimumEnd) }
        )
    }

    private var minimumEnd: Date {
        guard fields.isAllDay else { return fields.start.addingTimeInterval(60) }
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: fields.start))
            ?? fields.start.addingTimeInterval(86_400)
    }

    private var durationRow: some View {
        row("Length") {
            Menu {
                ForEach(Self.durations, id: \.0) { name, seconds in
                    Button(name) { fields.end = fields.start.addingTimeInterval(seconds) }
                }
            } label: {
                Text(CalendarWeekView.durationLabel(fields.end.timeIntervalSince(fields.start)))
                    .font(DS.captionFont)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Set the end time by how long it runs")
            Spacer(minLength: 0)
        }
    }

    private var calendarRow: some View {
        row("Calendar") {
            Menu {
                ForEach(calendars) { calendar in
                    Button {
                        fields.calendarID = calendar.id
                    } label: {
                        Label {
                            Text(calendar.title)
                        } icon: {
                            Circle().fill(Color(cgColor: calendar.color))
                        }
                    }
                }
            } label: {
                HStack(spacing: DS.xs) {
                    Circle()
                        .fill(Color(cgColor: selectedCalendar?.color ?? event.calendarColor))
                        .frame(width: 7, height: 7)
                    Text(selectedCalendar?.title ?? "Calendar")
                        .font(DS.captionFont)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Move this event to another calendar")
            Spacer(minLength: 0)
        }
    }

    private var locationRow: some View {
        row("Where") {
            TextField("Optional", text: Binding(
                get: { fields.location ?? "" },
                set: { fields.location = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(DS.captionFont)
            .onSubmit(save)
        }
    }

    private var buttonRow: some View {
        HStack {
            // The confirming label names what is about to go. "Delete?" on a repeating
            // event left the reader to guess whether the series was about to go with
            // it, which is the one question a confirmation exists to answer.
            Button(deleteLabel, role: .destructive, action: deleteTapped)
                .controlSize(.small)
                .help(confirmingDelete ? String(localized: "Click again to delete it (⌘Z undoes this)")
                                       : deleteHelp)

            Spacer()

            Button("Cancel") { onFinished() }
                .controlSize(.small)

            Button("Save", action: save)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(DS.moon)
                .disabled(!hasChanges)
                .keyboardShortcut(.return, modifiers: [])
        }
    }

    // MARK: - Field builders

    /// A label and whatever goes beside it, on one baseline. A fixed label column is
    /// what makes five rows read as a form rather than five unrelated controls.
    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
            Text(label)
                .font(DS.captionFont)
                .foregroundStyle(DS.inkFaint)
                .frame(width: Self.labelWidth, alignment: .leading)
            content()
        }
    }

    /// A typable date, plus the little calendar everyone reaches for when they don't
    /// know what day the 14th is.
    private func dateField(_ value: Binding<Date>,
                           showingCalendar: Binding<Bool>) -> some View {
        HStack(spacing: 2) {
            DatePicker("", selection: value, displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
                .frame(width: Self.dateFieldWidth)

            Button { showingCalendar.wrappedValue = true } label: {
                Image(systemName: DS.Glyph.calendar)
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                    // 22 rather than the standard 30: it sits against a
                    // `.datePickerStyle(.field)`, and a taller control here would set
                    // the row's height and leave the field floating inside it.
                    .iconHitTarget(22)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityLabel("Pick a date")
            .popover(isPresented: showingCalendar, arrowEdge: .bottom) {
                DatePicker("", selection: value, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(DS.md)
            }
        }
    }

    /// A stepper field, so the time answers the arrow keys — which is the whole
    /// difference between nudging a meeting and retyping it.
    @ViewBuilder
    private func timeField(_ value: Binding<Date>, notBefore floor: Date? = nil) -> some View {
        if let floor {
            DatePicker("", selection: value, in: floor.addingTimeInterval(60)...,
                       displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField)
                .labelsHidden()
                .frame(width: Self.timeFieldWidth)
        } else {
            DatePicker("", selection: value, displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField)
                .labelsHidden()
                .frame(width: Self.timeFieldWidth)
        }
    }

    private var deleteLabel: String {
        if event.isRecurring {
            return confirmingDelete ? String(localized: "Delete this one?") : String(localized: "Delete occurrence")
        }
        return confirmingDelete ? "Delete?" : "Delete"
    }

    private var deleteHelp: String {
        event.isRecurring
            ? String(localized: "Remove this occurrence from the series (⌘Z undoes this)")
            : String(localized: "Delete from your calendar")
    }

    private var selectedCalendar: CalendarService.WritableCalendar? {
        calendars.first { $0.id == fields.calendarID } ?? calendars.first(where: \.isDefault)
    }

    private static func dayLabel(_ date: Date) -> String {
        CalendarWeekView.templateFormatter("EEEdMMM").string(from: date)
    }

    // MARK: - Actions

    private func save() {
        guard hasChanges else { onFinished(); return }
        writer.update(ref: writer.ref(for: handle),
                      from: original, to: fields, undo: undoManager)
        onFinished()
    }

    /// Two clicks rather than a modal. Deleting is the one thing in this form that
    /// removes something rather than changing it — and ⌘Z brings it back, which is
    /// why one confirmation is enough.
    private func deleteTapped() {
        guard confirmingDelete else { confirmingDelete = true; return }
        writer.delete(ref: writer.ref(for: handle), fields: original, undo: undoManager)
        onFinished()
    }
}
