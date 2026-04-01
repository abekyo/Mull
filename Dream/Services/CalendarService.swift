import Foundation
import EventKit

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
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay } // Skip all-day events (less actionable)
            .sorted { $0.startDate < $1.startDate }

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
