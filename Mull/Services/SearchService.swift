import SwiftUI

// MARK: - Search hit

/// One match in the unified search timeline — a captured event or a calendar entry,
/// reduced to what the result row needs: when it happened, what kind it is, and the text.
struct SearchHit: Identifiable, Hashable {
    /// Derived from the underlying row (event id, or calendar start + title) — NOT a
    /// fresh UUID. A minted-per-render identity made ForEach tear down and rebuild
    /// every result row on each redraw, dropping any text selection in progress.
    let id: String
    let date: Date
    let kind: Kind
    let app: String?        // owning app (events); nil for calendar — used by the app filter
    let detail: String?     // app name, or a calendar event's location / time range
    let text: String        // matched content, or the event title

    enum Kind: CaseIterable, Hashable {
        case typed, copied, window, document, app, audio, schedule

        init(_ type: RecordingEvent.EventType) {
            switch type {
            case .keystroke: self = .typed
            case .clipboard: self = .copied
            case .screenText: self = .window
            case .windowBody: self = .document
            case .appSwitch: self = .app
            case .audio: self = .audio
            }
        }

        var label: String {
            switch self {
            case .typed: "Typed"
            case .copied: "Copied"
            case .window: "Window"
            case .document: "Document"
            case .app: "App"
            case .audio: "Audio"
            case .schedule: "Schedule"
            }
        }

        var icon: String {
            switch self {
            case .typed: "keyboard"
            case .copied: "doc.on.clipboard"
            case .window: "macwindow"
            case .document: "doc.text"
            case .app: "app.dashed"
            case .audio: "waveform"
            case .schedule: "calendar"
            }
        }

        var color: Color {
            switch self {
            case .typed: DS.eventKeystroke
            case .copied: DS.eventClipboard
            case .window: DS.eventWindow
            case .document: DS.taupe
            case .app: DS.eventApp
            case .audio: DS.eventAudio
            case .schedule: DS.moon
            }
        }
    }
}

// MARK: - Search range

/// How far back the timeline reaches. Future-dated calendar matches always pass (they sit
/// above "now"), so this is effectively a lower bound on the past.
enum SearchRange: String, CaseIterable, Hashable {
    case all, today, week, month, year

    var label: String {
        switch self {
        case .all: "All"
        case .today: "Today"
        case .week: "7d"
        case .month: "30d"
        case .year: "1y"
        }
    }

    var cutoff: Date {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .all: return .distantPast
        case .today: return cal.startOfDay(for: now)
        case .week: return cal.date(byAdding: .day, value: -7, to: now) ?? .distantPast
        case .month: return cal.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        case .year: return cal.date(byAdding: .year, value: -1, to: now) ?? .distantPast
        }
    }
}

// MARK: - Search service

/// The gathering, ranking and filtering behind Home's unified search.
///
/// This is deliberately *not* a View. The rules it encodes — how three unrelated
/// sources merge into one chronological record, which hits a filter lets through,
/// how a match is emphasised — are the substance of the search feature, and they
/// were previously trapped inside `HomeTab`'s body where nothing could exercise
/// them. Every method here is pure: same inputs, same output, no observation of
/// the wall clock beyond `SearchRange.cutoff`, which is anchored to "now" by design.
///
/// Threading: `gather` blocks (event FTS, a 15-month EventKit scan, summary FTS), so
/// callers run it off the main thread. It does no publishing of its own — the caller
/// owns where the result lands.
enum SearchService {

    /// Merge every source into one newest-first timeline plus the matching daily
    /// summaries. Typed text, copied text, window/app activity AND calendar schedule
    /// live in the same list, so the answer to "when did this word appear?" is the
    /// timeline itself rather than three lists the reader has to interleave by eye.
    ///
    /// Blocking — call from a detached task.
    static func gather(query: String,
                       database: DatabaseService,
                       calendar: CalendarService) -> (hits: [SearchHit], summaries: [DailySummary]) {
        let merged = timeline(events: database.searchEvents(query: query, limit: 80),
                              calendarEvents: calendar.searchEvents(query: query))
        return (merged, database.searchSummaries(query: query))
    }

    /// The merge itself, split out from `gather` so it can be exercised without an
    /// EventKit store: both sources in, one newest-first list out.
    static func timeline(events: [RecordingEvent], calendarEvents: [CalendarEvent]) -> [SearchHit] {
        (events.map(hit(for:)) + calendarEvents.map(hit(for:))).sorted { $0.date > $1.date }
    }

    /// A captured event as a search row. The id is derived from the row (its database
    /// id, or timestamp+kind for an unsaved one) and is deliberately NOT a fresh UUID:
    /// a minted-per-render identity made `ForEach` tear down and rebuild every result
    /// row on each redraw, dropping any text selection in progress.
    static func hit(for e: RecordingEvent) -> SearchHit {
        let kind = SearchHit.Kind(e.eventType)
        return SearchHit(id: e.id.map { "e\($0)" } ?? "e\(e.timestamp.timeIntervalSince1970)-\(kind)",
                         date: e.timestamp, kind: kind,
                         app: e.appName, detail: e.appName, text: e.textContent ?? "")
    }

    /// A calendar entry as a search row. No owning app — which is what makes it drop
    /// out once the reader narrows to a specific app (see `appPass`).
    static func hit(for c: CalendarEvent) -> SearchHit {
        SearchHit(id: "c\(c.start.timeIntervalSince1970)-\(c.title)",
                  date: c.start, kind: .schedule, app: nil,
                  detail: (c.location?.isEmpty == false ? c.location : c.timeFormatted),
                  text: c.title)
    }

    /// Projects whose name, primary app or resume file mentions the query.
    static func matchingProjects(_ projects: [ProjectSnapshot], query: String) -> [ProjectSnapshot] {
        projects.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.primaryApp.localizedCaseInsensitiveContains(query) ||
            ($0.lastFile?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Hits inside the chosen period. Applied *before* the chip counts are tallied, so
    /// the numbers on the chips describe the period the user is actually looking at.
    static func inRange(_ hits: [SearchHit], range: SearchRange) -> [SearchHit] {
        let cutoff = range.cutoff
        return hits.filter { $0.date >= cutoff }
    }

    /// The rows the timeline finally shows: in-period hits that survive both the
    /// kind chips and the app chips.
    static func timelineHits(_ hits: [SearchHit],
                             range: SearchRange,
                             kinds: Set<SearchHit.Kind>,
                             apps: Set<String>) -> [SearchHit] {
        inRange(hits, range: range).filter { kinds.contains($0.kind) && appPass($0, selectedApps: apps) }
    }

    /// A hit passes the app filter when no app is selected, or it belongs to a selected app.
    /// Calendar hits (no app) are excluded once a specific app is chosen — "Xcode only" means
    /// only Xcode's activity.
    static func appPass(_ hit: SearchHit, selectedApps: Set<String>) -> Bool {
        guard !selectedApps.isEmpty else { return true }
        guard let app = hit.app else { return false }
        return selectedApps.contains(app)
    }

    /// Tally hits per kind — drives the kind chips' counts.
    static func kindCountMap(_ hits: [SearchHit]) -> [SearchHit.Kind: Int] {
        Dictionary(grouping: hits, by: \.kind).mapValues(\.count)
    }

    /// Tally hits per owning app (events only) — drives the app filter chips' counts.
    static func appCountMap(_ hits: [SearchHit]) -> [String: Int] {
        var m: [String: Int] = [:]
        for h in hits { if let a = h.app, !a.isEmpty { m[a, default: 0] += 1 } }
        return m
    }

    /// Render the matched text with the query terms emphasised (moonlight, semibold), so the
    /// eye lands on *why* this row matched. Case-insensitive; capped to keep rows compact.
    static func highlighted(_ raw: String, query: String) -> AttributedString {
        let text = String(raw.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        var result = AttributedString(text)
        let terms = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        for term in terms {
            var from = text.startIndex
            while let r = text.range(of: term, options: .caseInsensitive, range: from..<text.endIndex) {
                if let lo = AttributedString.Index(r.lowerBound, within: result),
                   let hi = AttributedString.Index(r.upperBound, within: result) {
                    result[lo..<hi].foregroundColor = DS.moon
                    result[lo..<hi].font = .system(size: 11, weight: .semibold)
                }
                from = r.upperBound
            }
        }
        return result
    }

    /// Today / Yesterday / "M/d (EEEE)" — the day header for a timeline group.
    static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "M/d (EEEE)"
        return f.string(from: day)
    }

    static func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
