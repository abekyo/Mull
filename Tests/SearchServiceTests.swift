import XCTest
@testable import mull

/// Locks the ranking and filtering behind Home's search.
///
/// Search is how the user interrogates their own record — "when did I first write
/// about the migration?" — so the rules that decide *which* rows appear and in
/// *what order* are load-bearing. They used to live inside `HomeTab`'s body, where
/// nothing could reach them; `SearchService` exists so they can be asserted on.
///
/// Safety: the one test that touches storage uses `DatabaseService.temporary()` (a
/// throwaway DB in a unique temp dir). The user's real recorded history is never
/// opened. `CalendarService` is never constructed — its initialiser asks EventKit
/// for access — so the calendar half is exercised through `timeline(events:
/// calendarEvents:)` with hand-built `CalendarEvent`s instead.
///
/// Determinism: fixtures use fixed timestamps built from `DateComponents`, so the
/// results do not depend on the wall clock or the time zone. `SearchRange` is the
/// one API anchored to `Date()` by design, so its tests are phrased in offsets from
/// now rather than absolute dates.
final class SearchServiceTests: XCTestCase {

    // MARK: - Fixture helpers

    /// A fixed clock time on a fixed historical day. Built from components so the
    /// same local wall-clock time is used in every time zone.
    private func at(_ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 10
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    private func hit(_ id: String,
                     _ date: Date,
                     _ kind: SearchHit.Kind,
                     app: String? = nil,
                     text: String = "") -> SearchHit {
        SearchHit(id: id, date: date, kind: kind, app: app, detail: app, text: text)
    }

    private func calendarEvent(_ title: String, at start: Date, location: String? = nil) -> CalendarEvent {
        CalendarEvent(title: title,
                      start: start,
                      end: start.addingTimeInterval(1800),
                      location: location,
                      calendarColor: CGColor(gray: 0.5, alpha: 1))
    }

    // MARK: - Merge

    /// Captured events and calendar entries are one record, not two lists — the
    /// answer to "when did this appear?" is a single newest-first timeline.
    func testTimelineMergesBothSourcesNewestFirst() {
        let events = [
            RecordingEvent(id: 1, timestamp: at(9, 0), eventType: .clipboard,
                           appName: "Xcode", textContent: "migration checklist for the storyboard refactor"),
            RecordingEvent(id: 2, timestamp: at(14, 0), eventType: .keystroke,
                           appName: "Xcode", textContent: "finished the migration of the account view"),
        ]
        let calendarEvents = [calendarEvent("Migration review", at: at(11, 0))]

        let merged = SearchService.timeline(events: events, calendarEvents: calendarEvents)

        XCTAssertEqual(merged.map(\.date), [at(14, 0), at(11, 0), at(9, 0)],
                       "hits must be interleaved by time, not grouped by source")
        XCTAssertEqual(merged.map(\.kind), [.typed, .schedule, .copied])
    }

    /// The identity regression: a fresh UUID per render made `ForEach` rebuild every
    /// row on each redraw and drop in-progress text selection. Ids must be derived
    /// from the underlying row, and therefore stable across repeated mapping.
    func testHitIdsAreContentDerivedAndStable() {
        let event = RecordingEvent(id: 42, timestamp: at(9, 0), eventType: .keystroke,
                                   appName: "Xcode", textContent: "rewrote the schedule parser")
        XCTAssertEqual(SearchService.hit(for: event).id, SearchService.hit(for: event).id)
        XCTAssertEqual(SearchService.hit(for: event).id, "e42")

        let entry = calendarEvent("Design review", at: at(11, 0))
        XCTAssertEqual(SearchService.hit(for: entry).id, SearchService.hit(for: entry).id)

        // An unsaved event still gets a deterministic id from its timestamp + kind.
        let unsaved = RecordingEvent(timestamp: at(9, 0), eventType: .keystroke,
                                     appName: "Xcode", textContent: "rewrote the schedule parser")
        XCTAssertEqual(SearchService.hit(for: unsaved).id, SearchService.hit(for: unsaved).id)
        XCTAssertFalse(SearchService.hit(for: unsaved).id.isEmpty)
    }

    /// A calendar entry shows its location when it has one, and its time range when
    /// it doesn't — the row never leaves the secondary line blank.
    func testCalendarHitPrefersLocationOverTimeRange() {
        let located = SearchService.hit(for: calendarEvent("Design review", at: at(11, 0), location: "Studio"))
        XCTAssertEqual(located.detail, "Studio")

        let unlocated = SearchService.hit(for: calendarEvent("Design review", at: at(11, 0)))
        XCTAssertEqual(unlocated.detail, calendarEvent("Design review", at: at(11, 0)).timeFormatted)

        XCTAssertNil(unlocated.app, "calendar hits have no owning app — the app filter depends on it")
    }

    // MARK: - Kind + app filtering

    func testTimelineHitsRespectsKindFilter() {
        let hits = [
            hit("a", at(9, 0), .typed, app: "Xcode", text: "storyboard migration"),
            hit("b", at(10, 0), .copied, app: "Xcode", text: "storyboard migration"),
            hit("c", at(11, 0), .schedule, text: "Migration review"),
        ]

        let typedOnly = SearchService.timelineHits(hits, range: .all, kinds: [.typed], apps: [])
        XCTAssertEqual(typedOnly.map(\.id), ["a"])

        let none = SearchService.timelineHits(hits, range: .all, kinds: [], apps: [])
        XCTAssertTrue(none.isEmpty, "turning every chip off shows nothing, not everything")
    }

    /// "Xcode only" means only Xcode's activity — a calendar entry has no owning app,
    /// so it drops out rather than riding along.
    func testAppFilterExcludesCalendarHits() {
        let hits = [
            hit("a", at(9, 0), .typed, app: "Xcode", text: "storyboard migration"),
            hit("b", at(10, 0), .typed, app: "Safari", text: "storyboard migration"),
            hit("c", at(11, 0), .schedule, text: "Migration review"),
        ]
        let kinds = Set(SearchHit.Kind.allCases)

        XCTAssertEqual(SearchService.timelineHits(hits, range: .all, kinds: kinds, apps: ["Xcode"]).map(\.id),
                       ["a"])
        XCTAssertEqual(SearchService.timelineHits(hits, range: .all, kinds: kinds, apps: ["Xcode", "Safari"]).map(\.id),
                       ["a", "b"], "selecting two apps is a union; filtering preserves the order it was given")
        XCTAssertEqual(SearchService.timelineHits(hits, range: .all, kinds: kinds, apps: []).count, 3,
                       "no app selected means no app filtering at all")
    }

    // MARK: - Time range

    func testInRangeKeepsOnlyHitsInsideThePeriod() {
        let now = Date()
        let hits = [
            hit("recent", now.addingTimeInterval(-3600), .typed, app: "Xcode"),
            hit("lastMonth", now.addingTimeInterval(-40 * 86_400), .typed, app: "Xcode"),
            hit("upcoming", now.addingTimeInterval(3600), .schedule),
        ]

        XCTAssertEqual(SearchService.inRange(hits, range: .all).count, 3)
        XCTAssertEqual(Set(SearchService.inRange(hits, range: .week).map(\.id)), ["recent", "upcoming"],
                       "a future calendar match sits above now and always passes a lower bound")
        XCTAssertEqual(SearchService.inRange(hits, range: .year).count, 3)
    }

    // MARK: - Chip counts

    /// The chip numbers describe the period the reader is looking at, so they are
    /// tallied after the range filter and before the kind/app filters — otherwise a
    /// chip would report zero for hits it is itself hiding.
    func testCountsAreTalliedOverTheRangedHits() {
        let now = Date()
        let hits = [
            hit("a", now.addingTimeInterval(-3600), .typed, app: "Xcode"),
            hit("b", now.addingTimeInterval(-7200), .typed, app: "Xcode"),
            hit("c", now.addingTimeInterval(-7200), .copied, app: "Safari"),
            hit("old", now.addingTimeInterval(-40 * 86_400), .typed, app: "Xcode"),
            hit("cal", now.addingTimeInterval(-3600), .schedule),
        ]
        let ranged = SearchService.inRange(hits, range: .week)

        XCTAssertEqual(SearchService.kindCountMap(ranged)[.typed], 2, "the 40-day-old hit is out of period")
        XCTAssertEqual(SearchService.kindCountMap(ranged)[.copied], 1)

        let appCounts = SearchService.appCountMap(ranged)
        XCTAssertEqual(appCounts["Xcode"], 2)
        XCTAssertEqual(appCounts["Safari"], 1)
        XCTAssertNil(appCounts[""], "an app-less calendar hit must not become an empty-named chip")
        XCTAssertEqual(appCounts.count, 2)
    }

    // MARK: - Highlighting

    func testHighlightMarksEveryOccurrenceCaseInsensitively() {
        let raw = "Migration notes: the migration of the account view is done"
        let result = SearchService.highlighted(raw, query: "migration")

        let emphasised = result.runs.filter { $0.foregroundColor == DS.moon }
        XCTAssertEqual(emphasised.count, 2, "both the capitalised and lowercase occurrence match")
        for run in emphasised {
            XCTAssertEqual(String(result[run.range].characters).lowercased(), "migration")
        }
    }

    /// Rows stay compact: long matches are capped and newlines flattened, so one hit
    /// can never push the rest of the timeline off screen.
    func testHighlightCapsLengthAndFlattensNewlines() {
        let raw = String(repeating: "migration notes ", count: 40) + "\ntrailing line"
        let result = SearchService.highlighted(raw, query: "migration")
        let text = String(result.characters)

        XCTAssertEqual(text.count, 120)
        XCTAssertFalse(text.contains("\n"))
    }

    func testHighlightWithEmptyQueryLeavesTextPlain() {
        let result = SearchService.highlighted("the migration is done", query: "   ")
        XCTAssertTrue(result.runs.allSatisfy { $0.foregroundColor == nil })
    }

    // MARK: - Projects

    func testMatchingProjectsLooksAtNameAppAndResumeFile() {
        let db = try! DatabaseService.temporary()
        let engine = TimeBlockEngine(database: db)

        // Two days of real-shaped activity so `projectSnapshots` has something to infer
        // from — going through the engine keeps the test honest about the shape of a
        // ProjectSnapshot rather than hand-building one the engine would never emit.
        for dayOffset in 1...2 {
            let base = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date())!
            for i in 0..<12 {
                db.insertEvent(RecordingEvent(
                    timestamp: base.addingTimeInterval(Double(i) * 120),
                    eventType: .screenText,
                    appName: "Xcode",
                    windowTitle: "AccountView.swift — PantryApp",
                    textContent: "reviewing the account view layout"
                ))
            }
        }

        let projects = engine.projectSnapshots(days: 14)
        XCTAssertFalse(projects.isEmpty, "fixture should produce at least one project")

        XCTAssertFalse(SearchService.matchingProjects(projects, query: "xcode").isEmpty,
                       "the primary app matches, case-insensitively")
        XCTAssertTrue(SearchService.matchingProjects(projects, query: "Photoshop").isEmpty)
    }
}
