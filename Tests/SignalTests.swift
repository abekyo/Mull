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
