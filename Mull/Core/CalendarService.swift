import Foundation
import EventKit

/// A calendar event for display in the week view.
struct CalendarEvent: Identifiable {
    let id = UUID()
    let title: String
    let start: Date
    let end: Date
    let location: String?
    /// The calendar's tint, as CoreGraphics rather than SwiftUI — this type
    /// lives in the service layer, which the MCP binary also links. See
    /// `CalendarEvent.color` in the Views layer for the SwiftUI form.
    let calendarColor: CGColor
    /// A day-shaped commitment — a flight, PTO, a birthday. It has no place on an
    /// hour axis, which is why it is carried as a flag rather than dropped.
    var isAllDay: Bool = false
    /// EventKit's own handle on this event. It is what lets an edit or a delete find
    /// the row again — `id` above is a fresh UUID minted on every fetch and
    /// identifies nothing outside this process. `nil` for events mull did not read
    /// from EventKit (a test fixture, a search fixture).
    ///
    /// Not unique on its own: every occurrence of a repeating event carries the
    /// *same* identifier. Use `handle` for anything that has to name one of them.
    var eventIdentifier: String?
    /// Which occurrence of a repeating event this row is — EventKit's
    /// `occurrenceDate`, which stays put even when the occurrence itself is
    /// dragged elsewhere. Equal to `start` for an event that repeats not at all.
    var occurrenceDate: Date?
    /// Whether this row is one occurrence of a series rather than a lone event.
    var isRecurring: Bool = false
    /// Which calendar it currently lives in, so the editor's picker can open on the
    /// right one and moving an event between calendars is possible at all.
    var calendarIdentifier: String?
    /// Whether the calendar holding it accepts changes at all. A subscribed feed —
    /// holidays, a shared read-only team calendar — reads perfectly and refuses
    /// every write, and the editor has to know that before it offers a Save button.
    var isEditable: Bool = false

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// What a write has to be handed to land on *this* row. `nil` when the event
    /// did not come from EventKit and so cannot be written to at all.
    var handle: CalendarService.EventHandle? {
        guard let eventIdentifier else { return nil }
        return CalendarService.EventHandle(
            identifier: eventIdentifier,
            occurrenceDate: isRecurring ? (occurrenceDate ?? start) : nil
        )
    }

    /// Shown to a person, so it follows their clock — see `TimeFormat`.
    var timeFormatted: String {
        "\(TimeFormat.person(start)) – \(TimeFormat.person(end))"
    }
}

/// Reads today's calendar events via EventKit (macOS standard).
/// No account setup needed — uses the user's existing Calendar.app data.
///
/// Feeds into now.md so AI knows:
///   "User has a design review at 14:00" → can prioritize accordingly
final class CalendarService {

    private let store = EKEventStore()
    private var hasAccess = false

    init() {
        // Read the existing decision; never prompt from here. Constructing this
        // service used to fire the system calendar dialog — on the very first
        // launch that meant a permission ask with no explanation on screen,
        // before onboarding had said a word (and macOS asked *three* things when
        // the flow had promised two), and from every process that builds one,
        // including the headless MCP server. A reflexive "Don't Allow" there is
        // permanent short of System Settings. The ask belongs to a screen that
        // can say why — onboarding's cold read, CalendarView's allow button —
        // via requestAccess(completion:).
        recheckAccess()
    }

    /// Why the calendar is empty. A view that only knows "no events came back"
    /// cannot tell a quiet week from a permission that was never granted, and
    /// showing "nothing recorded" to someone who simply never said yes is a lie
    /// with no way out of it.
    enum Access {
        case granted
        /// Never asked, or asked and dismissed — a prompt is still possible.
        case notDetermined
        /// Refused, restricted, or write-only. Only System Settings can undo it.
        case denied
    }

    /// The live authorization state, read fresh (no prompt) on every call.
    var accessState: Access { Self.currentAccessState }

    /// The same reading, without needing a service instance — so a view can seed
    /// its state with the truth instead of an optimistic guess. Reads TCC status
    /// only; it never prompts.
    static var currentAccessState: Access {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined { return .notDetermined }
        if #available(macOS 14.0, *) {
            return status == .fullAccess ? .granted : .denied
        }
        return status == .authorized ? .granted : .denied
    }

    /// The one way mull asks for calendar access. Called from screens that have
    /// the reason on display — onboarding's cold read, CalendarView's allow
    /// button — never from construction. Once the answer is `.denied` the system
    /// will not prompt again, so callers should send the user to System Settings
    /// instead.
    func requestAccess(completion: @escaping (Bool) -> Void) {
        // Read the answer back off TCC rather than trusting the callback's Bool.
        // EventKit reports `false` both for "the user said no" and for "the request
        // itself failed" (the error alongside it, which nothing here can act on), and
        // those are different things to put on screen: only the first means the switch
        // has moved to System Settings and asking again is pointless. Reading the
        // status tells them apart — a failed request leaves it `.notDetermined`, so
        // the caller can keep offering the ask.
        let finish: (Bool) -> Void = { _ in
            DispatchQueue.main.async {
                self.hasAccess = Self.currentAccessState == .granted
                completion(self.hasAccess)
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in finish(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in finish(granted) }
        }
    }

    // MARK: - Writing
    //
    // mull read the calendar and never wrote to it, on the grounds that editing is
    // Calendar.app's job. What overturned that is where you are standing when you
    // find the hole in your day: you are looking at the grid. Being sent to another
    // app to fill the hole you just found is the moment mull stops being the place
    // your day lives — and the gesture every Mac user already tries first
    // (double-click the empty slot) did nothing at all, silently.
    //
    // What keeps it from becoming a second, disagreeing copy of your calendar:
    // mull stores nothing. Every write goes straight to EventKit and is read back
    // from it, into a calendar *the user already chose* as their default — mull
    // never invents one. And nothing is written without a deliberate act.

    /// Why a write could not happen. Each case is a different thing to tell the
    /// user, which is the whole reason this isn't a `Bool`.
    enum WriteError: LocalizedError {
        /// Calendar access was never granted, or was refused.
        case noAccess
        /// Access is fine, but every calendar on this Mac is read-only.
        case noWritableCalendar
        /// The event is no longer in EventKit — deleted in Calendar.app, most likely,
        /// while its card was still on mull's grid.
        case notFound
        /// A subscribed feed: readable, and not ours to change.
        case notEditable
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .noAccess:
                return "mull doesn't have calendar access, so it can't add this."
            case .noWritableCalendar:
                return "There's no calendar on this Mac that accepts new events."
            case .notFound:
                return "That event isn't in your calendar any more."
            case .notEditable:
                return "That calendar is subscribed, so its events can't be changed here."
            case .underlying(let message):
                return message
            }
        }
    }

    /// Everything about an event that mull lets you change, in one value.
    ///
    /// A struct rather than six arguments because undo needs to hold a *before* and
    /// an *after* and swap them: with loose parameters the inverse of an edit has to
    /// be reassembled by hand at every call site, and the one that gets it wrong is
    /// the one that silently loses your location field.
    struct EventFields: Equatable {
        var title: String = ""
        var start: Date
        var end: Date
        var location: String?
        var isAllDay: Bool = false
        /// Which calendar to write into. `nil` means the user's default.
        var calendarID: String?

        /// What actually reaches EventKit.
        ///
        /// An untitled event is a real thing in Calendar.app — you make the slot
        /// first and name it later — so an empty title is filled in rather than
        /// refused, and a zero-length span is given the shortest duration its kind
        /// can have. Both used to be enforced twice, differently, in create and
        /// update.
        func normalized() -> EventFields {
            var out = self
            let title = out.title.trimmingCharacters(in: .whitespacesAndNewlines)
            out.title = title.isEmpty ? "New Event" : title
            let place = out.location?.trimmingCharacters(in: .whitespacesAndNewlines)
            out.location = (place?.isEmpty == false) ? place : nil
            if out.end <= out.start {
                out.end = out.start.addingTimeInterval(out.isAllDay ? 86_400 : 60)
            }
            return out
        }
    }

    /// Which event a write means.
    ///
    /// EventKit gives every occurrence of a repeating event the same
    /// `eventIdentifier`, and `event(withIdentifier:)` answers with the *first*
    /// one. Naming an event by that string alone meant every edit, drag and
    /// delete aimed at Friday's stand-up landed on Monday's instead — silently,
    /// and on somebody's real calendar. The occurrence date is what separates
    /// this Friday from the rest of the series.
    struct EventHandle: Equatable, Hashable {
        let identifier: String
        /// `EKEvent.occurrenceDate` for a repeating event; `nil` for one that
        /// occurs once, where the identifier already means exactly one row.
        let occurrenceDate: Date?
    }

    /// The parts of an event mull does not put on screen but must not destroy.
    ///
    /// Undoing a delete used to rebuild the event out of `EventFields` alone, so
    /// the note you had written on it and the alarm that was going to remind you
    /// were quietly not part of what came back. What EventKit will not let us put
    /// back is recorded here rather than pretended away: attendees are read-only,
    /// and a recurrence rule is deliberately not carried (see `wasRecurring`).
    struct EventExtras {
        var notes: String?
        var url: URL?
        var alarms: [EKAlarm]?
        var availability: EKEventAvailability = .notSupported
        var timeZone: TimeZone?
        /// The event this came from was one occurrence of a series. Removing that
        /// occurrence punches a hole in the series that EventKit offers no way to
        /// fill, so undo puts a standalone event back at that hour instead of
        /// restoring the occurrence — the grid looks right, and the series does
        /// not silently gain a second copy of itself.
        var wasRecurring = false
    }

    /// A calendar a new event could be put in.
    struct WritableCalendar: Identifiable, Equatable {
        let id: String
        let title: String
        let color: CGColor
        /// The one EventKit would pick on its own.
        let isDefault: Bool

        static func == (lhs: WritableCalendar, rhs: WritableCalendar) -> Bool { lhs.id == rhs.id }
    }

    /// Every calendar that accepts new events, default first.
    ///
    /// The UI needs the whole list, not just the default: an event that lands in
    /// "Home" when it belonged in "Work" is worse than one you had to go elsewhere
    /// to make, because you won't notice until someone asks why you missed it.
    var writableCalendars: [WritableCalendar] {
        if !hasAccess { recheckAccess() }
        guard hasAccess else { return [] }
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map {
                WritableCalendar(id: $0.calendarIdentifier, title: $0.title,
                                 color: $0.cgColor, isDefault: $0.calendarIdentifier == defaultID)
            }
            .sorted { ($0.isDefault ? 0 : 1, $0.title) < ($1.isDefault ? 0 : 1, $1.title) }
    }

    /// Whether a new event could be written at all. The difference between "saving
    /// failed" and "saving was never possible" belongs to the UI *before* it offers
    /// the gesture, not to an error afterwards.
    var canCreateEvents: Bool { !writableCalendars.isEmpty }

    /// The calendar a new event would land in, so the UI can say where it went
    /// rather than leaving the user to find out in Calendar.app.
    var defaultCalendarTitle: String? {
        writableCalendars.first(where: \.isDefault)?.title ?? writableCalendars.first?.title
    }

    /// Read an event back as fields — what undo needs to restore what it undid, and
    /// what the editor opens on.
    func fields(for handle: EventHandle) -> EventFields? {
        guard let event = try? resolve(handle) else { return nil }
        return fields(of: event)
    }

    /// The same read, plus everything mull does not show but must be able to put
    /// back. Taken before a delete, handed to the create that undoes it.
    func extras(for handle: EventHandle) -> EventExtras? {
        guard let event = try? resolve(handle) else { return nil }
        return extras(of: event)
    }

    /// Write a new event. Returns a handle on it, so the caller can hold on to
    /// what it just made once the store change notification comes round.
    ///
    /// `extras` is the baggage of an event being restored by an undo; a genuinely
    /// new event has none.
    @discardableResult
    func createEvent(_ fields: EventFields, extras: EventExtras? = nil) throws -> EventHandle {
        if !hasAccess { recheckAccess() }
        guard hasAccess else { throw WriteError.noAccess }
        guard let calendar = calendar(fields.calendarID) else { throw WriteError.noWritableCalendar }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        apply(fields.normalized(), to: event)
        if let extras { apply(extras, to: event) }
        try save(event)
        // Whatever it was restored from, what exists now occurs once: no
        // recurrence rule is ever written here, so the handle needs no date.
        return EventHandle(identifier: event.eventIdentifier, occurrenceDate: nil)
    }

    /// Change an event mull is already showing.
    ///
    /// `.thisEvent` throughout: a repeating event edited from a week grid means
    /// *this* Tuesday, and quietly rewriting every future Tuesday from a card the
    /// user clicked once is not a thing to do on their behalf.
    func updateEvent(_ handle: EventHandle, to fields: EventFields) throws {
        let event = try editable(handle)
        // Moving an event between calendars is a plain field change to EventKit,
        // and refusing to follow it into a read-only one is ours to check.
        if let target = fields.calendarID, target != event.calendar.calendarIdentifier {
            guard let destination = calendar(target) else { throw WriteError.notEditable }
            event.calendar = destination
        }
        apply(fields.normalized(), to: event)
        try save(event)
    }

    func deleteEvent(_ handle: EventHandle) throws {
        let event = try editable(handle)
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw WriteError.underlying(error.localizedDescription)
        }
    }

    private func fields(of event: EKEvent) -> EventFields {
        EventFields(title: event.title ?? "", start: event.startDate, end: event.endDate,
                    location: event.location, isAllDay: event.isAllDay,
                    calendarID: event.calendar.calendarIdentifier)
    }

    private func extras(of event: EKEvent) -> EventExtras {
        EventExtras(
            notes: event.notes,
            url: event.url,
            // Copied rather than referenced: these alarms belong to a row that is
            // about to be removed from the store.
            alarms: event.alarms?.compactMap { $0.copy() as? EKAlarm },
            availability: event.availability,
            timeZone: event.timeZone,
            wasRecurring: event.hasRecurrenceRules
        )
    }

    private func apply(_ fields: EventFields, to event: EKEvent) {
        event.title = fields.title
        event.isAllDay = fields.isAllDay
        event.startDate = fields.start
        event.endDate = fields.end
        event.location = fields.location
    }

    /// Put back what an undo is carrying. No recurrence rule is ever set here:
    /// see `EventExtras.wasRecurring`.
    private func apply(_ extras: EventExtras, to event: EKEvent) {
        event.notes = extras.notes
        event.url = extras.url
        event.alarms = extras.alarms
        if extras.availability != .notSupported,
           event.calendar.supportedEventAvailabilities.contains(Self.mask(for: extras.availability)) {
            event.availability = extras.availability
        }
        if let zone = extras.timeZone { event.timeZone = zone }
    }

    /// EventKit says what a calendar *supports* as an option set and what an event
    /// *is* as an enum, and ships no bridge between the two — so one has to be
    /// written before the support check can be asked its question.
    private static func mask(for availability: EKEventAvailability) -> EKCalendarEventAvailabilityMask {
        switch availability {
        case .busy:        return .busy
        case .free:        return .free
        case .tentative:   return .tentative
        case .unavailable: return .unavailable
        case .notSupported: return []
        @unknown default:  return []
        }
    }

    private func save(_ event: EKEvent) throws {
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw WriteError.underlying(error.localizedDescription)
        }
    }

    /// The writable calendar behind an identifier, or the default when none is asked
    /// for. `nil` when there is nothing writable to fall back to.
    private func calendar(_ identifier: String?) -> EKCalendar? {
        if let identifier,
           let match = store.calendar(withIdentifier: identifier),
           match.allowsContentModifications {
            return match
        }
        let fallback = store.defaultCalendarForNewEvents
        return fallback?.allowsContentModifications == true ? fallback : nil
    }

    /// The one row a handle names.
    ///
    /// For a lone event the identifier is the whole answer. For an occurrence of a
    /// repeating one it is not: `event(withIdentifier:)` hands back the series'
    /// first occurrence whichever one was asked for, so the occurrence is looked
    /// up by date instead. Failing to find it is reported as `.notFound` rather
    /// than quietly falling back on the first occurrence — writing to the wrong
    /// Tuesday is worse than refusing to write.
    private func resolve(_ handle: EventHandle) throws -> EKEvent {
        if !hasAccess { recheckAccess() }
        guard hasAccess else { throw WriteError.noAccess }
        guard let base = store.event(withIdentifier: handle.identifier) else {
            throw WriteError.notFound
        }
        // Named for the date it is, not for the lookup below — a local called
        // `occurrence` shadows the `occurrence(of:on:)` method it is passed to.
        guard let occurrenceDate = handle.occurrenceDate, base.hasRecurrenceRules else { return base }
        guard let match = occurrence(of: handle.identifier, on: occurrenceDate) else {
            throw WriteError.notFound
        }
        return match
    }

    /// The occurrence of a series that sits on a particular date.
    ///
    /// The window is a day and a half either side because an occurrence that has
    /// been detached and moved keeps the `occurrenceDate` it was scheduled for
    /// while its `startDate` walks away from it — matching on the former is what
    /// makes this stable, and the window only has to be wide enough to catch it.
    private func occurrence(of identifier: String, on date: Date) -> EKEvent? {
        let window: TimeInterval = 36 * 3600
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-window),
                                                 end: date.addingTimeInterval(window),
                                                 calendars: nil)
        return store.events(matching: predicate).first {
            $0.eventIdentifier == identifier
                && abs($0.occurrenceDate.timeIntervalSince(date)) < 1
        }
    }

    /// The row a handle names, or the reason it can't be touched.
    private func editable(_ handle: EventHandle) throws -> EKEvent {
        let event = try resolve(handle)
        guard event.calendar.allowsContentModifications else { throw WriteError.notEditable }
        return event
    }

    /// Get today's calendar events as a plain text summary for AI.
    func todaySchedule() -> String? {
        if !hasAccess { recheckAccess() }
        guard hasAccess else { return nil }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let rawEvents = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        // Deduplicate across calendar sources
        var seen = Set<String>()
        let events = rawEvents.filter { event in
            let key = "\(event.title ?? "")|\(event.startDate.timeIntervalSince1970)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }

        guard !events.isEmpty else { return nil }

        var lines: [String] = ["Today's schedule:"]
        for event in events {
            // 24-hour, locale-pinned: this text goes into now.md for an AI to read.
            let start = TimeFormat.machine(event.startDate)
            let end = TimeFormat.machine(event.endDate)
            let title = event.title ?? "Untitled"

            var detail = "- \(start)-\(end) \(title)"

            if let location = event.location, !location.isEmpty {
                detail += " (\(location))"
            }

            // Flag if event is happening now or within 30 minutes
            let now = Date()
            if event.startDate <= now && event.endDate >= now {
                detail += " ← NOW"
            } else if event.startDate > now && event.startDate.timeIntervalSince(now) < 1800 {
                let mins = Int(event.startDate.timeIntervalSince(now) / 60)
                detail += " ← in \(mins)min"
            }

            lines.append(detail)
        }

        return lines.joined(separator: "\n")
    }

    /// Get all events for a specific date (for calendar view).
    /// Deduplicates events that appear in multiple calendar sources (iCloud + Google etc.).
    /// Re-read the live authorization status (no prompt). Lets a permission
    /// granted while the app is running take effect on the next query, so the
    /// user doesn't have to restart.
    private func recheckAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            hasAccess = (status == .fullAccess)
        } else {
            hasAccess = (status == .authorized)
        }
    }

    func events(for date: Date) -> [CalendarEvent] {
        if !hasAccess { recheckAccess() }
        guard hasAccess else { return [] }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }

        // Timed only: every existing caller of this puts events on a clock
        // ("14:00 design review"), and a day-shaped commitment has no clock.
        // `dayEvents(from:to:)` is where the all-day ones can be had.
        return fetch(from: startOfDay, to: endOfDay).filter { !$0.isAllDay }
    }

    /// Every timed event in a date range, bucketed by day.
    ///
    /// A week view calling `events(for:)` seven times is seven EventKit round
    /// trips for what EventKit will answer in one — `predicateForEvents` takes
    /// an arbitrary range. Days with nothing in them are simply absent from the
    /// dictionary; callers should read a missing key as "no events", which is
    /// only sound because the whole range was fetched in this one pass.
    /// See `dayEvents(from:to:)` for the bucketing rule and the all-day half.
    func events(from start: Date, to end: Date) -> [Date: [CalendarEvent]] {
        dayEvents(from: start, to: end).timed
    }

    /// The same range, split into the two things a calendar grid draws differently.
    ///
    /// All-day events used to be filtered out at the source, which meant a flight,
    /// a week of PTO and every birthday were simply absent from mull with nothing
    /// to say they had been dropped. They cannot go on an hour axis, so they come
    /// back in their own bucket, for the band above the grid.
    ///
    /// Either kind is filed under *every* day it covers, not only the one it began
    /// on: a four-day trip belongs on all four days, and a meeting running 23:40 →
    /// 00:50 belongs on both of them (each column clamps and marks its own half).
    func dayEvents(from start: Date, to end: Date)
        -> (timed: [Date: [CalendarEvent]], allDay: [Date: [CalendarEvent]]) {
        if !hasAccess { recheckAccess() }
        guard hasAccess, start < end else { return ([:], [:]) }

        let calendar = Calendar.current
        var timed: [Date: [CalendarEvent]] = [:]
        var allDay: [Date: [CalendarEvent]] = [:]

        for event in fetch(from: start, to: end) {
            var day = calendar.startOfDay(for: max(event.start, start))
            // The last *moment* the event occupies, not its end: an end lands on
            // midnight in two different meanings (EventKit's inclusive all-day
            // 23:59:59, and a timed event that simply finishes at 00:00), and
            // stepping back a second reads both without inventing a trailing day.
            let lastMoment = max(min(event.end, end).addingTimeInterval(-1), event.start)
            let last = calendar.startOfDay(for: lastMoment)
            while day <= last {
                if event.isAllDay {
                    allDay[day, default: []].append(event)
                } else {
                    timed[day, default: []].append(event)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }

        return (timed, allDay)
    }

    /// The one place raw EventKit rows become `CalendarEvent`s.
    ///
    /// Deduplicates on title + start time: the same appointment subscribed from
    /// two sources arrives twice, and showing it twice would misrepresent the
    /// day. Keyed on start rather than identifier because the duplicates are
    /// distinct EventKit objects.
    ///
    /// All-day events are carried through with a flag rather than discarded —
    /// deciding what to do with them is the caller's business, and dropping them
    /// here is what made them invisible everywhere at once.
    private func fetch(from start: Date, to end: Date) -> [CalendarEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let rawEvents = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }

        var seen = Set<String>()
        var results: [CalendarEvent] = []

        for event in rawEvents {
            let title = event.title ?? "Untitled"
            let key = "\(title)|\(event.startDate.timeIntervalSince1970)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            results.append(CalendarEvent(
                title: title,
                start: event.startDate,
                end: event.endDate,
                location: event.location,
                calendarColor: event.calendar.cgColor,
                isAllDay: event.isAllDay,
                eventIdentifier: event.eventIdentifier,
                occurrenceDate: event.occurrenceDate,
                isRecurring: event.hasRecurrenceRules,
                calendarIdentifier: event.calendar.calendarIdentifier,
                isEditable: event.calendar.allowsContentModifications
            ))
        }

        return results
    }

    /// Search calendar events by title/location across a window around now. EventKit has
    /// no text index, so we fetch the range and filter in memory — fine for a personal
    /// calendar, and keeps mull's "calendar is read-only, never stored" principle (we don't
    /// copy events into the DB just to search them).
    func searchEvents(query: String, monthsBack: Int = 12, monthsAhead: Int = 3) -> [CalendarEvent] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if !hasAccess { recheckAccess() }
        guard hasAccess else { return [] }

        let cal = Calendar.current
        let now = Date()
        guard let start = cal.date(byAdding: .month, value: -monthsBack, to: now),
              let end = cal.date(byAdding: .month, value: monthsAhead, to: now) else { return [] }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let matches = store.events(matching: predicate).filter { ev in
            (ev.title?.localizedCaseInsensitiveContains(q) ?? false) ||
            (ev.location?.localizedCaseInsensitiveContains(q) ?? false)
        }
        .sorted { $0.startDate > $1.startDate }

        var seen = Set<String>()
        var results: [CalendarEvent] = []
        for ev in matches {
            let title = ev.title ?? "Untitled"
            let key = "\(title)|\(ev.startDate.timeIntervalSince1970)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(CalendarEvent(
                title: title,
                start: ev.startDate,
                end: ev.endDate,
                location: ev.location,
                calendarColor: ev.calendar.cgColor,
                isAllDay: ev.isAllDay,
                eventIdentifier: ev.eventIdentifier,
                occurrenceDate: ev.occurrenceDate,
                isRecurring: ev.hasRecurrenceRules,
                calendarIdentifier: ev.calendar.calendarIdentifier,
                isEditable: ev.calendar.allowsContentModifications
            ))
        }
        return results
    }

    /// Get upcoming events (next 3) for quick context.
    func upcomingEvents(limit: Int = 3) -> [(title: String, start: Date, minutesUntil: Int)] {
        if !hasAccess { recheckAccess() }
        guard hasAccess else { return [] }

        let now = Date()
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!

        let predicate = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { (
                title: $0.title ?? "Untitled",
                start: $0.startDate,
                minutesUntil: Int($0.startDate.timeIntervalSince(now) / 60)
            )}
    }
}
