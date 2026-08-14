import XCTest
@testable import mull

/// Tests for the CurrentState anchor's pure entity extraction.
final class CurrentStateTests: XCTestCase {

    func testProjectLastEditorTitle() {
        // VS Code / Xcode style: "file — Project"
        XCTAssertEqual(CurrentState.entity(from: "ContentView.swift — PantryApp"), "PantryApp")
    }

    func testProjectFirstEditorTitle() {
        XCTAssertEqual(CurrentState.entity(from: "PantryApp — ContentView.swift"), "PantryApp")
    }

    func testDropsKnownApp() {
        // "Project — file — App" → App dropped, project kept.
        XCTAssertEqual(CurrentState.entity(from: "PantryApp — main.swift — Xcode"), "PantryApp")
    }

    func testSingleSegmentEntity() {
        XCTAssertEqual(CurrentState.entity(from: "PantryApp"), "PantryApp")
    }

    func testRejectsChatLikeTitle() {
        // A sentence/question is not a project.
        XCTAssertNil(CurrentState.entity(from: "このバグを直してくれますか？"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(CurrentState.entity(from: nil))
        XCTAssertNil(CurrentState.entity(from: ""))
    }

    // MARK: - What the eight slots are allowed to say
    //
    // `whats_active_now` is the first call an agent makes, and this list is its
    // whole first impression. A line in it is read as something the user did.

    private final class Events: EventReading, @unchecked Sendable {
        var events: [RecordingEvent] = []
        /// Ascending, like the real query — newest-first fixtures make `CurrentState`
        /// read the oldest event as "now".
        func fetchEvents(from start: Date, to end: Date) -> [RecordingEvent] {
            events.filter { $0.timestamp >= start && $0.timestamp <= end }
                .sorted { $0.timestamp < $1.timestamp }
        }
        func fetchCandidates(query: String, since: Date, useFTS: Bool, limit: Int) -> [RecordingEvent] { [] }
        func searchEvents(query: String, limit: Int) -> [RecordingEvent] { [] }
        func countEvents(from start: Date, to end: Date) -> Int {
            fetchEvents(from: start, to: end).count
        }
        func dailyEventCounts(from start: Date, to end: Date) -> [Date: Int] { [:] }
    }

    private func anchor(_ events: [RecordingEvent]) -> CurrentState {
        let reading = Events()
        reading.events = events
        return CurrentState.current(database: reading)
    }

    private func event(_ secondsAgo: Double, _ type: RecordingEvent.EventType,
                       _ app: String, _ text: String) -> RecordingEvent {
        RecordingEvent(
            timestamp: Date().addingTimeInterval(-secondsAgo),
            eventType: type, appName: app,
            windowTitle: type == .screenText ? text : nil,
            textContent: text)
    }

    /// The regression. A heading copied out of a document read exactly like a task
    /// worked on in the same editor, because both arrived here as `[Code] <text>`.
    func testACopiedFragmentIsNotReportedAsWork() {
        let state = anchor([
            event(60, .screenText, "Code", "ログ機能のバグチェック — Pet"),
            event(30, .clipboard, "Code", "A. カルテが濃くなる（本命）"),
        ])

        XCTAssertTrue(state.recentActions.contains("[Code] ログ機能のバグチェック — Pet"))
        XCTAssertFalse(state.recentActions.contains("[Code] A. カルテが濃くなる（本命）"),
                       "a copy is not an activity")
        XCTAssertTrue(state.recentActions.contains { $0.contains("A. カルテが濃くなる（本命）") },
                      "it is still reported — as what it was")
    }

    /// A copy long enough to be cut mid-sentence is a piece of a document. The first
    /// 80 characters of a paragraph name nothing, and `search` still has all of it.
    func testAPastedParagraphIsNotAnAnchor() {
        let paragraph = String(repeating: "その子の一冊が実物で届く。", count: 8)
        let state = anchor([
            event(60, .screenText, "Code", "チャーン率低減施策の検討 — Pet"),
            event(30, .clipboard, "Code", paragraph),
        ])

        XCTAssertEqual(state.recentActions, ["[Code] チャーン率低減施策の検討 — Pet"])
    }

    /// `[Claude] Claude` spends one of eight slots repeating the `App:` line above it.
    func testATitleThatOnlyRepeatsTheAppIsDropped() {
        let state = anchor([
            event(60, .screenText, "Code", "OpenAIのコンピュータ履歴について調査 — Mull"),
            event(30, .screenText, "Claude", "Claude"),
        ])

        XCTAssertEqual(state.recentActions, ["[Code] OpenAIのコンピュータ履歴について調査 — Mull"])
    }
}
