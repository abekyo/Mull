import Foundation
import EventKit
import SwiftUI

/// A calendar event for display in the week view.
struct CalendarEvent: Identifiable {
    let id = UUID()
    let title: String
    let start: Date
    let end: Date
    let location: String?
    let color: Color

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

    private func requestAccess() {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in
                self.hasAccess = granted
            }
        } else {
            store.requestAccess(to: .event) { granted, _ in
                self.hasAccess = granted
            }
        }
    }

    /// Get today's calendar events as a plain text summary for AI.
    func todaySchedule() -> String? {
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
    func events(for date: Date) -> [CalendarEvent] {
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
                color: Color(cgColor: event.calendar.cgColor)
            ))
        }

        return results
    }

    /// Get upcoming events (next 3) for quick context.
    func upcomingEvents(limit: Int = 3) -> [(title: String, start: Date, minutesUntil: Int)] {
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
