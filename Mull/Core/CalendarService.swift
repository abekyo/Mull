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

    var duration: TimeInterval { end.timeIntervalSince(start) }

    var timeFormatted: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: start)) – \(f.string(from: end))"
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
        requestAccess()
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
    var accessState: Access {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined { return .notDetermined }
        if #available(macOS 14.0, *) {
            return status == .fullAccess ? .granted : .denied
        }
        return status == .authorized ? .granted : .denied
    }

    /// Ask for read access on demand — for an "allow calendar" affordance in the
    /// UI, which needs the answer to come back rather than being fired and
    /// forgotten in `init`. Once the answer is `.denied` the system will not
    /// prompt again, so callers should send the user to System Settings instead.
    func requestAccess(completion: @escaping (Bool) -> Void) {
        let finish: (Bool) -> Void = { granted in
            DispatchQueue.main.async {
                self.hasAccess = granted
                completion(granted)
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in finish(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in finish(granted) }
        }
    }

    /// Only prompt when the decision hasn't been made yet. On later launches we
    /// read the existing status instead of calling request again, so a granted
    /// permission is never re-prompted (when the build's code signature is stable).
    private func requestAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            if status == .fullAccess {
                hasAccess = true
            } else {
                // Request full READ access whenever we don't already have it:
                // - .notDetermined → first prompt
                // - .writeOnly ("Add only") → prompt to upgrade to full (the cause
                //   of "calendar won't load events" — write-only can't read)
                // - .denied/.restricted → returns false without prompting (Settings needed)
                store.requestFullAccessToEvents { granted, _ in
                    DispatchQueue.main.async { self.hasAccess = granted }
                }
            }
        } else {
            if status == .authorized {
                hasAccess = true
            } else {
                store.requestAccess(to: .event) { granted, _ in
                    DispatchQueue.main.async { self.hasAccess = granted }
                }
            }
        }
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

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        var lines: [String] = ["Today's schedule:"]
        for event in events {
            let start = formatter.string(from: event.startDate)
            let end = formatter.string(from: event.endDate)
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
                isAllDay: event.isAllDay
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
                isAllDay: ev.isAllDay
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
