import XCTest
@testable import mull

/// Locks the capture-time classifier. `Signal` runs on every recorded event and
/// its output is stored on the row, so a regression here silently mis-shapes the
/// index for everything captured afterwards — and the stored value is what the
/// selection layer ranks on.
final class SignalTests: XCTestCase {

    // MARK: - kind

    func testErrorsWinOverEverythingElse() {
        // Salience 0.95 — the highest. A stack trace pasted into the clipboard
        // must not be filed as a mere "note".
        XCTAssertEqual(Signal.kind(text: "Fatal error: unexpectedly found nil",
                                   eventType: .clipboard, windowTitle: nil), "error")
        XCTAssertEqual(Signal.kind(text: "Traceback (most recent call last):",
                                   eventType: .keystroke, windowTitle: nil), "error")
        XCTAssertEqual(Signal.kind(text: "Build FAILED",
                                   eventType: .clipboard, windowTitle: nil), "error")
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(Signal.kind(text: "ERROR: disk full",
                                   eventType: .clipboard, windowTitle: nil), "error")
        XCTAssertEqual(Signal.kind(text: "Exception in thread",
                                   eventType: .clipboard, windowTitle: nil), "error")
    }

    func testWebBeatsCodeAndNote() {
        XCTAssertEqual(Signal.kind(text: "see https://example.com/docs",
                                   eventType: .clipboard, windowTitle: nil), "web")
    }

    func testJapaneseImperativeIsASelfAuthoredNote() {
        // The note heuristic is what makes Japanese self-instructions rank above
        // ambient activity (salience 0.85 vs 0.20).
        XCTAssertEqual(Signal.kind(text: "明日までにレポートを書いてください",
                                   eventType: .keystroke, windowTitle: nil), "note")
        XCTAssertEqual(Signal.kind(text: "この関数をリファクタしたい",
                                   eventType: .keystroke, windowTitle: nil), "note")
    }

    func testDecisionsAreTheirOwnKind() {
        // `salience(for:)` scored "decision" at note tier from the start, but
        // `kind` never returned it — the tier was unreachable, and a decision
        // typed at the keyboard scored 0.20 as plain activity.
        XCTAssertEqual(Signal.kind(text: "we'll use GRDB instead of Core Data",
                                   eventType: .clipboard, windowTitle: nil), "decision")
        XCTAssertEqual(Signal.kind(text: "その案は却下",
                                   eventType: .keystroke, windowTitle: nil), "decision")
    }

    func testDecisionVocabularyIsTradeNeutral() {
        // The same branch has to fire outside software, or the top salience tiers
        // belong to one occupation.
        XCTAssertEqual(Signal.kind(text: "ロット数を0.5にする",
                                   eventType: .keystroke, windowTitle: nil), "decision")
        XCTAssertEqual(Signal.kind(text: "この条項は採用しない方針",
                                   eventType: .clipboard, windowTitle: nil), "decision")
        XCTAssertEqual(Signal.kind(text: "配信時間を朝にする",
                                   eventType: .keystroke, windowTitle: nil), "decision")
    }

    func testDecisionIsGatedToAuthoredChannels() {
        // A window title containing 「方針」 is a document being looked at, not a
        // commitment being made.
        XCTAssertNotEqual(Signal.kind(text: "2026年の方針.pages",
                                      eventType: .screenText,
                                      windowTitle: "2026年の方針.pages"), "decision")
    }

    func testErrorStillOutranksDecision() {
        XCTAssertEqual(Signal.kind(text: "decided to fix the fatal error",
                                   eventType: .clipboard, windowTitle: nil), "error")
    }

    func testCodeShapes() {
        XCTAssertEqual(Signal.kind(text: "func reload() {",
                                   eventType: .clipboard, windowTitle: nil), "code")
        XCTAssertEqual(Signal.kind(text: "const f = () => 1",
                                   eventType: .clipboard, windowTitle: nil), "code")
    }

    func testWindowBodyIsAlwaysDocumentRegardlessOfContent() {
        // Regression guard for the documented trap: a README containing "error"
        // or a URL, or a long Japanese body, must still be classified by channel.
        XCTAssertEqual(Signal.kind(text: "error handling — see https://example.com",
                                   eventType: .windowBody, windowTitle: "README.md"), "document")
        XCTAssertEqual(Signal.kind(text: "この章では設定してください",
                                   eventType: .windowBody, windowTitle: "Guide"), "document")
    }

    func testScreenTextWithADottedTitleIsAFile() {
        XCTAssertEqual(Signal.kind(text: "whatever",
                                   eventType: .screenText, windowTitle: "AppState.swift"), "file")
        // No dot in the title → falls through to plain activity.
        XCTAssertEqual(Signal.kind(text: "whatever",
                                   eventType: .screenText, windowTitle: "Untitled"), "activity")
    }

    func testClipboardFallsBackToNote() {
        XCTAssertEqual(Signal.kind(text: "just some copied words",
                                   eventType: .clipboard, windowTitle: nil), "note")
    }

    func testUnremarkableKeystrokesAreActivity() {
        XCTAssertEqual(Signal.kind(text: "hello there",
                                   eventType: .keystroke, windowTitle: nil), "activity")
    }

    // MARK: - salience

    func testSalienceOrdering() {
        // The ranking layer depends on this order; assert the relationships
        // rather than the literals so tuning the numbers doesn't break the test.
        let error = Signal.salience(for: "error")
        let note = Signal.salience(for: "note")
        let code = Signal.salience(for: "code")
        let document = Signal.salience(for: "document")
        let web = Signal.salience(for: "web")
        let activity = Signal.salience(for: "activity")

        XCTAssertGreaterThan(error, note)
        XCTAssertGreaterThan(note, code)
        XCTAssertGreaterThan(code, document)
        XCTAssertGreaterThan(document, web)
        XCTAssertGreaterThan(web, activity)
    }

    func testDecisionRanksWithNote() {
        XCTAssertEqual(Signal.salience(for: "decision"), Signal.salience(for: "note"))
    }

    func testUnknownKindGetsTheFloor() {
        XCTAssertEqual(Signal.salience(for: "something-new"), Signal.salience(for: "activity"))
    }

    // MARK: - classify

    func testClassifyAgreesWithItsParts() {
        let (type, salience) = Signal.classify(text: "Fatal error: nil",
                                               eventType: .clipboard, windowTitle: nil)
        XCTAssertEqual(type, "error")
        XCTAssertEqual(salience, Signal.salience(for: "error"))
    }
}
