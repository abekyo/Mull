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

    /// What one search produced — and the honesty about it.
    ///
    /// `truncated` says the rows are a capped slice rather than the whole answer, so
    /// the view can say "the first N of more" instead of letting N read as "all there
    /// is". It is deliberately a flag and not a total: counting the matches behind the
    /// cap needs a COUNT over the same FTS/LIKE predicate, and `DatabaseService` has no
    /// such method (`countEvents` counts a time window, not a query).
    struct Results {
        let hits: [SearchHit]
        let summaries: [DailySummary]
        /// True when the event side hit its cap — there are more matches than these.
        let truncated: Bool
    }

    /// How many event rows one search materialises.
    ///
    /// Two caps rather than one, because the two fetch paths have very different odds
    /// of being complete. An unbounded search can only ever be a top-ranked slice of
    /// the whole record, so a bigger number buys little. A bounded one pushes its
    /// cutoff into SQL and therefore realistically fetches *everything* in the period —
    /// there the cap is a safety valve against a pathological day, not the shape of
    /// the answer, so it is generous.
    static let unboundedEventCap = 200
    static let boundedEventCap = 800

    /// Merge every source into one newest-first timeline plus the matching daily
    /// summaries. Typed text, copied text, window/app activity AND calendar schedule
    /// live in the same list, so the answer to "when did this word appear?" is the
    /// timeline itself rather than three lists the reader has to interleave by eye.
    ///
    /// `range` is part of the *query*, not a post-filter. It used to be neither: the
    /// fetch took the newest/top-ranked 80 rows across all time and the view then
    /// filtered those 80 down to "Today" — so narrowing never re-queried, and a user
    /// who asked for today's matches got only whichever of the global 80 happened to
    /// fall inside today. The chip counts, tallied over that same capped set,
    /// corroborated the lie. Narrowing now goes down into SQLite.
    ///
    /// Blocking — call from a detached task.
    static func search(query: String,
                       database: DatabaseService,
                       calendar: CalendarService,
                       range: SearchRange = .all) -> Results {
        let (events, truncated) = matchingEvents(query: query, range: range, database: database)
        return Results(hits: timeline(events: events,
                                      calendarEvents: calendar.searchEvents(query: query)),
                       summaries: database.searchSummaries(query: query),
                       truncated: truncated)
    }

    /// Source-compatible shim for callers that have no range to give. Prefer `search`
    /// and pass the range the reader has chosen — otherwise the fetch is unbounded and
    /// the narrowing is back to being a filter over a capped slice.
    static func gather(query: String,
                       database: DatabaseService,
                       calendar: CalendarService) -> (hits: [SearchHit], summaries: [DailySummary]) {
        let r = search(query: query, database: database, calendar: calendar, range: .all)
        return (r.hits, r.summaries)
    }

    /// The event side of a search: matches inside `range`, plus whether the cap bit.
    ///
    /// Two paths, because the two matchers are not interchangeable. `fetchCandidates`
    /// is the only query surface that takes a `since`, so a bounded range goes through
    /// it and the period is enforced by SQLite. It matches via FTS only, which rules
    /// out CJK (indexed as one token per contiguous run — see `containsCJK`), so those
    /// queries stay on `searchEvents` and take the cutoff in memory. That is sound
    /// there: `searchEvents`' LIKE path walks the timestamp index newest-first, so a
    /// raised cap covers a recent period completely.
    ///
    /// Note the app filter is *not* pushed down: no query method accepts an app, so
    /// "Xcode only" is still a filter over what came back. Within a bounded range that
    /// is now honest, because the range itself came back whole.
    private static func matchingEvents(query: String,
                                       range: SearchRange,
                                       database: DatabaseService) -> (events: [RecordingEvent], truncated: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], false) }
        let cutoff = range.cutoff

        // One row over the cap: the cheapest way to learn "there are more" without a
        // second COUNT query. The extra row is dropped before anyone sees it.
        if range != .all, !DatabaseService.containsCJK(trimmed), ftsTokenisable(trimmed) {
            let cap = boundedEventCap
            let fetched = database.fetchCandidates(query: trimmed, since: cutoff,
                                                   useFTS: true, limit: cap + 1)
            return (Array(fetched.prefix(cap)), fetched.count > cap)
        }

        let cap = range == .all ? unboundedEventCap : boundedEventCap
        let fetched = database.searchEvents(query: trimmed, limit: cap + 1)
        return (fetched.prefix(cap).filter { $0.timestamp >= cutoff }, fetched.count > cap)
    }

    /// Whether `fetchCandidates` can genuinely match this query.
    ///
    /// It builds its MATCH from alphanumeric runs of two characters or more, and when
    /// that leaves nothing it silently falls back to an *unfiltered* time window — for
    /// a search that would mean every row in the period rather than the matches. So a
    /// query it cannot tokenise is never handed to it.
    private static func ftsTokenisable(_ query: String) -> Bool {
        query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .contains { $0.count >= 2 }
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

    /// The terms a query marks. One definition, used by both `snippet` (which decides
    /// *where* to cut) and `highlighted` (which decides *what* to mark) — if the two
    /// disagreed, a row could be windowed around a word it then refused to emphasise.
    private static func terms(in query: String) -> [String] {
        query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// The stretch of `raw` worth showing: roughly `radius` characters either side of
    /// the first matched term, elided at whichever end was cut.
    ///
    /// This used to be `raw.prefix(120)`. For any long capture — a windowBody document,
    /// a pasted page — whose match sits at offset 500, that showed the opening of the
    /// text with not one highlighted term in it. The reader saw a result that visibly
    /// did not contain their query and concluded search was broken. Rows still stay
    /// compact; they are now compact *around the match*.
    ///
    /// Newlines are flattened first so the returned offsets describe the string the
    /// row actually renders.
    static func snippet(_ raw: String, query: String, radius: Int = 60) -> String {
        let flat = raw.replacingOccurrences(of: "\n", with: " ")

        // No visible match (empty query, or a term that only matched in appName /
        // windowTitle rather than in this text): fall back to the opening.
        guard let match = terms(in: query)
            .compactMap({ flat.range(of: $0, options: .caseInsensitive) })
            .min(by: { $0.lowerBound < $1.lowerBound }) else {
            let head = flat.prefix(2 * radius)
            return head.count < flat.count ? String(head) + "…" : String(head)
        }

        let lower = flat.index(match.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let upper = flat.index(match.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        return (lower > flat.startIndex ? "…" : "")
            + flat[lower..<upper]
            + (upper < flat.endIndex ? "…" : "")
    }

    /// Render the matched text with the query terms emphasised (moonlight, medium), so the
    /// eye lands on *why* this row matched. Case-insensitive; windowed to keep rows compact.
    static func highlighted(_ raw: String, query: String) -> AttributedString {
        let text = snippet(raw, query: query)
        var result = AttributedString(text)
        for term in terms(in: query) {
            var from = text.startIndex
            while let r = text.range(of: term, options: .caseInsensitive, range: from..<text.endIndex) {
                if let lo = AttributedString.Index(r.lowerBound, within: result),
                   let hi = AttributedString.Index(r.upperBound, within: result) {
                    result[lo..<hi].foregroundColor = DS.moon
                    // `captionFont`'s emphasis tier, not a hand-written 11pt. The row
                    // renders in `DS.captionFont`; a literal size here would sit on a
                    // different baseline the moment that token moved, and the line
                    // would jitter mid-sentence. Same pairing as microFont/microBold.
                    result[lo..<hi].font = DS.captionMedium
                }
                from = r.upperBound
            }
        }
        return result
    }

    /// Today / Yesterday / the date — the day header for a timeline group.
    ///
    /// The date half goes through a template rather than a literal `"M/d (EEEE)"`,
    /// for the same reason `timeLabel` does: that literal fixes the field order to
    /// one locale's convention and prints the weekday in a bracket style no other
    /// locale uses.
    static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MdEEE")
        return f.string(from: day)
    }

    /// The clock time of a row, in the reader's own convention.
    ///
    /// Not `"HH:mm:ss"`: that hardcoding forced 24-hour time on anyone whose Mac is set
    /// to 12-hour, and spent a third of a narrow column on seconds nobody reads off a
    /// search result. The `j` template asks the locale for its hour cycle.
    static func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: date)
    }
}
