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

        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let rawEvents = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        // Deduplicate: same title + same start time = same event across calendar sources
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
                calendarColor: event.calendar.cgColor
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
                calendarColor: ev.calendar.cgColor
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
