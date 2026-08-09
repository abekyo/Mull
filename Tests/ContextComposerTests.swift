import XCTest
@testable import mull

/// Locks the three filters on the block the user actually pastes into an AI.
///
/// Until 2026-08-09 this path had no tests and no eval, while the number the
/// README quotes (F1 0.919) measures `Selection.rank`, which `ContextComposer`
/// never calls. A real paste from that build carried four YouTube titles about
/// tattoos, a sentence about which currencies the user gets paid in listed as a
/// project, and two entries worth one and two minutes. Roughly three of its
/// twenty-five lines were usable.
final class ContextComposerTests: XCTestCase {

    /// Minimal `EventReading`: the composer and everything it calls
    /// (`FactExtractor`, `AnalyticsEngine`, `TimeBlockEngine`, `CurrentState`)
    /// read through this one protocol, so a list of events is the whole fixture.
    private final class FakeEvents: EventReading, @unchecked Sendable {
        let events: [RecordingEvent]
        init(_ events: [RecordingEvent]) { self.events = events }

        /// Ascending, like the real query. Returning them newest-first made
        /// `CurrentState` read the OLDEST event as "now", which is a fixture bug
        /// that looks exactly like a product bug.
        func fetchEvents(from start: Date, to end: Date) -> [RecordingEvent] {
            events.filter { $0.timestamp >= start && $0.timestamp <= end }
                .sorted { $0.timestamp < $1.timestamp }
        }
        func fetchCandidates(query: String, since: Date, useFTS: Bool, limit: Int) -> [RecordingEvent] {
            Array(events.filter { $0.timestamp >= since }.prefix(limit))
        }
        func searchEvents(query: String, limit: Int) -> [RecordingEvent] { [] }
        func countEvents(from start: Date, to end: Date) -> Int {
            fetchEvents(from: start, to: end).count
        }
        func dailyEventCounts(from start: Date, to end: Date) -> [Date: Int] { [:] }
    }

    private func event(_ minutesAgo: Double,
                       _ type: RecordingEvent.EventType,
                       _ text: String,
                       app: String = "Code",
                       title: String? = nil) -> RecordingEvent {
        RecordingEvent(id: nil,
                       timestamp: Date().addingTimeInterval(-minutesAgo * 60),
                       eventType: type,
                       appName: app,
                       windowTitle: title ?? text,
                       textContent: text)
    }

    private func compose(_ events: [RecordingEvent]) async -> String {
        await ContextComposer(database: FakeEvents(events)).compose()
    }

    // MARK: - Consumption is only included when it is about the work

    func testConsumptionFromAnotherTabIsNotPasted() async {
        // The anchor is Mull; a video playing in a browser is not.
        let text = await compose([
            event(1, .screenText, "ContentView.swift — Mull", title: "ContentView.swift — Mull"),
            event(2, .clipboard, "let composer = ContextComposer(database: db)"),
            event(3, .screenText, "刺青タトゥー入れてる奴は全員バカです - YouTube",
                  app: "Google Chrome", title: "刺青タトゥー入れてる奴は全員バカです - YouTube")
        ])
        XCTAssertFalse(text.contains("タトゥー"),
                       "consumption outside the active entity must not reach the clipboard")
    }

    func testConsumptionAboutTheActiveProjectIsKept() async {
        // The filter is about relevance, not about suppressing the consume mode.
        // Reading the docs for the thing you are building is context.
        let text = await compose([
            event(1, .screenText, "ContentView.swift — Mull", title: "ContentView.swift — Mull"),
            event(2, .screenText, "MCP specification — Mull",
                  app: "Google Chrome", title: "MCP specification — Mull")
        ])
        XCTAssertTrue(text.contains("Mull"))
    }

    func testWithNoAnchorNothingConsumedIsIncluded() async {
        // No active entity means there is nothing to test relevance against, and a
        // guess would be a claim about the user's work made out of someone else's
        // words (CLAUDE.md §7.1).
        let text = await compose([
            event(3, .screenText, "刺青タトゥー入れてる奴は全員バカです - YouTube",
                  app: "Google Chrome", title: "刺青タトゥー入れてる奴は全員バカです - YouTube")
        ])
        XCTAssertFalse(text.contains("タトゥー"))
    }

    // MARK: - What the user produced is still included

    func testWhatYouWroteIsStillPasted() async {
        let text = await compose([
            event(1, .screenText, "ContentView.swift — Mull", title: "ContentView.swift — Mull"),
            event(2, .clipboard, "TODO: wire the ledger into Selection")
        ])
        XCTAssertTrue(text.contains("wire the ledger"),
                      "the filters must not cost the user their own material")
    }

    func testAnEmptyRecordProducesNothingRatherThanAShell() async {
        let text = await compose([])
        XCTAssertTrue(text.isEmpty)
    }

    // MARK: - The measurement

    /// A labeled window, scored the way `eval/` scores `Selection.rank`.
    ///
    /// The composed block cannot join `eval/run.sh`: that harness is GRDB-free and
    /// filesystem-free on purpose, and this path reaches `FactExtractor`,
    /// `Preferences` and the vault. So the measurement lives here instead, which is
    /// the only place its dependencies resolve. `SELECTION-LAYER.md` §6 says which
    /// harness covers which path.
    ///
    /// The fixture is the shape of the real 2026-08-09 paste: work on one project,
    /// with unrelated video titles and a second project touched for a moment.
    func testComposedBlockCarriesTheWorkAndNotTheNoise() async {
        let relevant = ["ContextComposer", "wire the ledger", "RuleBook"]
        let irrelevant = ["タトゥー", "しげち"]

        let text = await compose([
            event(1, .screenText, "ContextComposer.swift — Mull", title: "ContextComposer.swift — Mull"),
            event(2, .clipboard, "TODO: wire the ledger into Selection"),
            event(3, .clipboard, "RuleBook collects the rules"),
            event(4, .screenText, "刺青タトゥー入れてる奴は全員バカです - YouTube",
                  app: "Google Chrome", title: "刺青タトゥー入れてる奴は全員バカです - YouTube"),
            event(5, .screenText, "しげち - YouTube", app: "Google Chrome", title: "しげち - YouTube"),
        ])

        let kept = relevant.filter { text.contains($0) }.count
        let leaked = irrelevant.filter { text.contains($0) }
        XCTAssertEqual(kept, relevant.count, "the user's own material must survive the filters")
        XCTAssertTrue(leaked.isEmpty, "leaked into the paste: \(leaked)")
    }

    /// A sentence is not a project. It may still be reported as something the user
    /// was doing, which it was; what it must never become is a `Working on:` line
    /// or an entry in "Active work", because those are claims about what the user
    /// builds. The clause rule lives in `ProjectNames` so this section and
    /// `Working on:` cannot disagree (PITFALLS.md §7), and `ProjectNamesTests`
    /// pins the rule itself.
    func testASentenceIsNeverPresentedAsAProject() async {
        let text = await compose([
            event(1, .screenText, "ContentView.swift — Mull", title: "ContentView.swift — Mull"),
            event(2, .screenText, "プロダクトの事業価値と社会的インパクトを検討",
                  title: "プロダクトの事業価値と社会的インパクトを検討")
        ])
        XCTAssertFalse(text.contains("Working on: プロダクトの事業価値"))
        XCTAssertFalse(text.contains("**プロダクトの事業価値"))
    }
}
