import SwiftUI
import EventKit
import AppKit

// One thing drawn on the grid, its card, and the popovers that open from it.
//
// Lifted out of CalendarView.swift. Nothing here changed in the move.

extension CalendarWeekView {

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

        /// One occurrence of a series rather than a lone event. Everything mull writes
        /// is `.thisEvent`, so this is the difference between "I moved my stand-up"
        /// and "I moved *this* stand-up" — see `CalItem.recurrenceNote`.
        var isRecurring: Bool { event?.isRecurring == true }

        /// Said on the card's tooltip, in the read-only popover and in the editor,
        /// because the alternative is a repeating event that looks exactly like a
        /// one-off and quietly detaches an occurrence the first time it is touched.
        static let recurrenceNote = String(localized: "Repeats · changes here affect this one occurrence")

        var tooltip: String {
            if let event {
                let place = (event.location?.isEmpty == false) ? " · \(event.location!)" : ""
                // Nothing on an all-day event can be dragged, and its clock times are
                // both midnight — "12:00 AM – 12:00 AM · drag to move" was three
                // wrong things in one line.
                // Opening moved from one click to two, so the tooltip is where that is
                // said. Its own fragment rather than a longer version of the drag hint,
                // which is already translated and true of timed events only.
                let opens = event.isEditable ? String(localized: " · double-click to edit") : ""
                let hint = (event.isEditable && !event.isAllDay)
                    ? String(localized: " · drag to move, drag the lower edge to stretch") : ""
                let repeats = event.isRecurring ? " · \(Self.recurrenceNote.lowercased())" : ""
                let when = event.isAllDay ? "all-day" : event.timeFormatted
                return "\(title) · \(when)\(place)\(repeats)\(opens)\(hint)"
            }
            guard let block else { return title }
            let label = (block.label.isEmpty || block.label == block.app) ? "" : " · \(block.label)"
            let away = block.pauses.isEmpty
                ? ""
                : String(localized: " · away \(CalendarWeekView.durationLabel(block.pausedDuration))")
            return "\(block.startFormatted) – \(block.endFormatted) · \(block.durationFormatted)\(label)\(away)"
        }
    }

    /// The glyph Calendar.app puts on a repeating event. Small, beside the title, and
    /// on every surface that can show a repeating event at all — a series that looks
    /// like a one-off is a series somebody is about to break a piece off.
    var recurrenceMark: some View {
        Image(systemName: DS.Glyph.repeats)
            .font(DS.iconMini.weight(.semibold))
            .foregroundStyle(DS.inkFaint)
            .accessibilityLabel("Repeats")
    }

    /// Drawn at whichever edge the span runs past — the reader is told the span was
    /// cut by midnight, not that it began or ended there.
    func continuationMark(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(DS.iconMini.weight(.semibold))
            .foregroundStyle(tint.opacity(0.75))
            .padding(.horizontal, DS.hair)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The wash behind a span. The true extent takes the full tint; whatever the card
    /// was padded by fades to a ghost, so a four-minute block never passes for half an hour.
    func spanWash(_ tint: Color, span: CalendarGrid.Span, strength: Double) -> some View {
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
    func spanRule(_ tint: Color, span: CalendarGrid.Span) -> some View {
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
    func itemView(_ item: CalItem, width: CGFloat, span: CalendarGrid.Span,
                  on date: Date, columnWidth: CGFloat) -> some View {
        let height = span.height
        let isHovered = hoveredItem == item.id
        let isKeyed = keyboardSelection == item.id
        // Two detail lines need ~30pt and ~44pt of card. Below that the tooltip and
        // the popover carry them.
        let visibleDetails = height >= 44 ? 2 : (height >= 30 ? 1 : 0)

        return HStack(spacing: 0) {
            spanRule(item.color, span: span)

            VStack(alignment: .leading, spacing: DS.hair) {
                HStack(spacing: DS.hair) {
                    Text(item.title)
                        .font(DS.miniMedium)
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)
                    if item.isRecurring { recurrenceMark }
                }

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
        // Hover and selection used to snap between two states with nothing in
        // between, on the surface the pointer spends all its time over.
        .animation(motion(.easeOut(duration: 0.12)), value: isHovered)
        .animation(motion(.easeOut(duration: 0.12)), value: isKeyed)
        .contentShape(Rectangle())
        // One click selects; two open it. That is what every calendar on this Mac
        // does, and it is also the whole of why ⌫ could not reach an event.
        //
        // A single click used to do both, and opening the editor is what stopped the
        // delete: `onDeleteCommand` stands down while `selectedItem` is set — it has
        // to, or ⌫ inside the editor's title field would delete the event instead of a
        // character — and the popover takes key focus besides. So clicking an event,
        // the one gesture anybody would call selecting it, was the one gesture that
        // guaranteed Delete would do nothing. The only path that worked was ↑ / ↓ and
        // then ⌫, which nobody finds.
        //
        // Double before single is the order Apple documents for stacking the two.
        .onTapGesture(count: 2) {
            keyboardSelection = item.id
            selectedItem = item
        }
        .onTapGesture(count: 1) {
            keyboardSelection = item.id
            // ⌫ and Return are handled on the grid, so the key has to land there.
            gridFocused = true
        }
        .gesture(dragGesture(for: item, span: span, on: date, columnWidth: columnWidth))
        .help(item.tooltip + Self.continuationNote(span))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.tooltip)
        // The cursor is `PointingHandCursor`'s business, which counts its own pushes.
        // Rolled by hand here, the pop in the not-hovering branch ran whether or not
        // this card had ever pushed, and a card taken out from under the pointer popped
        // twice — once there and once from `onDisappear`. `NSCursor`'s stack is global,
        // so an unmatched pop takes somebody else's cursor off it. The grid rebuilds its
        // cards every minute and on every calendar sync, so a pointer resting on an
        // event was the whole of what it took to leave the wrong cursor behind.
        .pointingHandCursor()
        .onHover { hovering in
            if hovering { hoveredItem = item.id }
            else if hoveredItem == item.id { hoveredItem = nil }
        }
        .onDisappear {
            if hoveredItem == item.id { hoveredItem = nil }
        }
        // Anchored to the card, not to the window. This used to hang off the root
        // VStack, so every block's detail popped from the same spot at the top.
        .popover(isPresented: popoverBinding(for: item), arrowEdge: .trailing) {
            itemDetail(item)
        }
    }

    func washStrength(_ item: CalItem, hovered: Bool) -> Double {
        if item.isScheduled { return hovered ? 0.16 : 0.10 }
        return hovered ? 0.20 : 0.12
    }

    func borderTint(_ item: CalItem, hovered: Bool, keyed: Bool) -> Color {
        if keyed { return DS.moon }
        if item.isScheduled { return item.color.opacity(hovered ? 0.7 : 0.45) }
        return hovered ? DS.moon.opacity(0.55) : .clear
    }

    /// The tooltip half of the continuation marker — a chevron alone doesn't say
    /// which day the rest of the span is on.
    private static func continuationNote(_ span: CalendarGrid.Span) -> String {
        switch (span.continuesBefore, span.continuesAfter) {
        case (true, true):   return String(localized: " · runs through this whole day")
        case (true, false):  return String(localized: " · continues from the previous day")
        case (false, true):  return String(localized: " · continues into the next day")
        case (false, false): return ""
        }
    }

    func popoverBinding(for item: CalItem) -> Binding<Bool> {
        Binding(
            get: { selectedItem?.id == item.id },
            set: { shown in
                if shown { selectedItem = item }
                else if selectedItem?.id == item.id { selectedItem = nil }
            }
        )
    }

    // MARK: - Detail popovers

    @ViewBuilder
    func itemDetail(_ item: CalItem) -> some View {
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
    func eventDetail(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                RoundedRectangle(cornerRadius: DS.radiusXs)
                    .fill(event.color)
                    .frame(width: 4, height: 24)
                VStack(alignment: .leading, spacing: DS.hair) {
                    Text(event.title)
                        .font(DS.bodyMedium)
                    HStack(spacing: DS.xs) {
                        Text("Scheduled")
                        if event.isRecurring {
                            Label("Repeats", systemImage: DS.Glyph.repeats)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                }
            }

            Divider()

            HStack(spacing: DS.md) {
                Label(event.timeFormatted, systemImage: DS.Glyph.timeOfDay)
                    .font(DS.captionFont)
                Label(CalendarWeekView.durationLabel(event.duration), systemImage: DS.Glyph.duration)
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
        VaultText.duration(minutes: max(Int(duration / 60), 0))
    }

    func blockDetail(_ block: TimeBlock) -> some View {
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
                Label(block.startFormatted + " – " + block.endFormatted, systemImage: DS.Glyph.timeOfDay)
                    .font(DS.captionFont)
                Label(block.durationFormatted, systemImage: DS.Glyph.duration)
                    .font(DS.captionFont)
                // A bare number beside a "#" glyph left the reader to guess what had
                // been counted. It is captures, and it says so.
                Label(counted(block.eventCount, one: "1 capture",
                              other: "\(block.eventCount) captures"), systemImage: "number")
                    .font(DS.captionFont)
            }
            .foregroundStyle(DS.inkDim)

            // A rejoined session spans time nothing was recorded in. The card draws
            // that span, so the span has to say what is inside it — otherwise the
            // merge quietly turns a break into work.
            if !block.pauses.isEmpty {
                let away = CalendarWeekView.durationLabel(block.pausedDuration)
                Label(counted(block.pauses.count,
                              one: "1 break · away \(away)",
                              other: "\(block.pauses.count) breaks · away \(away)"),
                      systemImage: "pause")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
            }

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
                    Image(systemName: DS.Glyph.file)
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
                    Image(systemName: DS.Glyph.quote)
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
}
