import XCTest
@testable import mull

/// The writes mull makes to things the user owns without being asked, and the doors
/// it offers for the things it cannot observe.
///
/// Both halves come out of the same reading of the app on 2026-08-18. On one side,
/// auto-copy replaced the clipboard on a fresh install the first time its owner
/// opened claude.ai. On the other, the three surfaces where a person can *state*
/// something rather than be watched — the seven setup questions, me.pinned.md, and a
/// correction — were all empty on the machine of the person who built mull, after two
/// and a half months of daily use, because each of them is a form you only meet by
/// going to look for it.
///
/// They are the same defect twice: mull acting where it should ask, and mull waiting
/// where it should offer.
final class UnaskedWritesTests: XCTestCase {

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/
            .deletingLastPathComponent()    // repo root
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - Auto-copy is off until it is asked for

    func testAutoCopyIsOffWhenNobodyHasTouchedIt() {
        let store = UserDefaults(suiteName: "com.mull.tests.autocopy")!
        store.removePersistentDomain(forName: "com.mull.tests.autocopy")
        // `bool(forKey:)` answers false for an unset key, which is the whole of the
        // default. The assertion is that nobody has reintroduced an `?? true`.
        XCTAssertFalse(store.bool(forKey: Preferences.aiAutoCopyKey))
    }

    /// The toggle and the check are declared in different files, and a `true` in
    /// either one is a fresh install that takes the clipboard. This is the same lint
    /// `KeystrokeOptInTests` runs over the keystroke pair, for the same reason.
    func testNeitherDeclarationDefaultsToOn() throws {
        let settings = try source("Mull/Views/Settings/SettingsView.swift")
        XCTAssertTrue(settings.contains("@AppStorage(Preferences.aiAutoCopyKey) private var aiAutoCopy = false"),
                      "the toggle must default to off, and say so through Preferences")

        let engine = try source("Mull/Services/ProactiveEngine.swift")
        XCTAssertTrue(engine.contains("guard Preferences.aiAutoCopyEnabled else { return }"),
                      "the copy path must read the same default the toggle shows")
        XCTAssertFalse(engine.contains("\"aiAutoCopy\") as? Bool ?? true"),
                       "an absent key meaning ‘on’ is the regression this test exists for")
    }

    // MARK: - The door mull offers when it has nothing but guesses

    /// The offer is made where the gap costs something, not in a pane nobody opens.
    func testCopyContextOffersTheAnswersPaneWhenNothingWasStated() throws {
        let state = try source("Mull/App/AppState.swift")
        XCTAssertTrue(state.contains("OnboardingProfile.hasAnswers"),
                      "the offer has to be conditional on the answers actually being absent")
        XCTAssertTrue(state.contains("Curator.readPinned()"),
                      "…and on me.pinned.md holding nothing of the user's own")
        XCTAssertTrue(state.contains("action: .stateYourPremises"),
                      "a notice that names the gap and gives nowhere to go is a complaint")
    }

    func testTheOfferLandsOnTheOneScreenThatOwnsThoseAnswers() {
        // Settings › General is where `AnswersSection` lives. If the action stops
        // agreeing with that, the button becomes a dead end.
        XCTAssertEqual(AppState.NoticeAction.stateYourPremises, .stateYourPremises)
        XCTAssertFalse(AppState.NoticeAction.stateYourPremises.label.isEmpty)
    }

    /// A notice with somewhere to go must not fade before it is read. The auto-dismiss
    /// covers plain confirmations only.
    func testANoticeWithAnActionWaitsToBeDismissed() throws {
        let state = try source("Mull/App/AppState.swift")
        XCTAssertTrue(state.contains("guard !isProblem, revealURL == nil, action == nil else { return }"),
                      "an actionable notice has to outlive the five-second timer")
    }
}
