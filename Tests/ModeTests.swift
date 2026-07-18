import XCTest
@testable import mull

/// Locks the MODE axis (MAP-ARCHITECTURE.md). Mode is computed at capture and
/// stored on the row, so a regression mislabels everything recorded afterwards.
/// The precedence order is load-bearing: comms → consuming → decide → think →
/// maker app → contentType fallback.
final class ModeTests: XCTestCase {

    private func mode(_ text: String,
                      _ eventType: RecordingEvent.EventType = .keystroke,
                      app: String? = nil,
                      title: String? = nil,
                      contentType: String? = nil) -> Mode {
        Mode.classify(text: text, eventType: eventType, appName: app,
                      windowTitle: title, contentType: contentType)
    }

    // MARK: - Precedence

    func testCommsAppWinsOverEverything() {
        XCTAssertEqual(mode("func reload() {", app: "Slack"), .communicate)
        XCTAssertEqual(mode("決めた、これにする", app: "Discord"), .communicate)
    }

    func testMailMatchesExactlyAndDoesNotSwallowOtherApps() {
        XCTAssertEqual(mode("hello", app: "Mail"), .communicate)
        // Documented trap: a substring rule must never turn Mailbox-like or
        // Xcode-like names into comms.
        XCTAssertNotEqual(mode("hello", app: "Xcode"), .communicate)
    }

    func testBrowserIsConsumeUnlessItLooksLikeResearch() {
        XCTAssertEqual(mode("", app: "Safari", title: "Cat videos"), .consume)
        XCTAssertEqual(mode("", app: "Safari", title: "How to use Combine"), .research)
        XCTAssertEqual(mode("", app: "Arc", title: "Stack Overflow — nil crash"), .research)
    }

    func testJapaneseResearchNeedles() {
        XCTAssertEqual(mode("", app: "Chrome", title: "SwiftUIとは"), .research)
        XCTAssertEqual(mode("", app: "Chrome", title: "GRDB 使い方の解説"), .research)
        XCTAssertEqual(mode("", app: "Chrome", title: "ニュース"), .consume)
    }

    func testMediaAppsConsume() {
        XCTAssertEqual(mode("", app: "Music"), .consume)
        XCTAssertEqual(mode("", app: "Podcasts"), .consume)
        XCTAssertEqual(mode("", title: "audio playing"), .consume)
    }

    // MARK: - decide / think

    func testDecisionsFromClipboardAndKeystrokes() {
        XCTAssertEqual(mode("we'll use GRDB instead of Core Data", .clipboard), .decide)
        XCTAssertEqual(mode("decided: ship on Friday", .keystroke), .decide)
        XCTAssertEqual(mode("SQLiteにする", .keystroke), .decide)
        XCTAssertEqual(mode("その案は却下", .clipboard), .decide)
    }

    func testDecisionHeuristicOnlyAppliesToTypedOrCopiedText() {
        // A window title that happens to contain a decision phrase is not a decision.
        XCTAssertNotEqual(mode("decided: ship on Friday", .windowBody), .decide)
    }

    func testLongProseIsThinking() {
        let musing = "この設計はもう少し単純にできるかもしれない、"
            + "とくに選択層のところは分けたほうがいいと思う。"
        XCTAssertEqual(mode(musing), .think)
    }

    func testShortTextIsNotThinking() {
        // The 40-char floor keeps titles and snippets out of `think`.
        //
        // Asserting `!= .think` on a bare string would prove nothing: the final
        // fallback also returns .think. Use a maker app instead — `looksLikeThinking`
        // is checked BEFORE `isMakerApp`, so short text falls through to .produce
        // while long prose in the same app is still caught as .think.
        XCTAssertEqual(mode("短いメモ。", app: "Xcode"), .produce)

        let long = "この設計はもう少し単純にできるかもしれない、"
            + "とくに選択層のところは分けたほうがいいと思う。"
        XCTAssertGreaterThanOrEqual(long.count, 40)
        XCTAssertEqual(mode(long, app: "Xcode"), .think)
    }

    // MARK: - Maker apps and contentType fallback

    func testMakerAppsProduce() {
        XCTAssertEqual(mode("x", app: "Xcode"), .produce)
        XCTAssertEqual(mode("x", app: "Ghostty"), .produce)
        XCTAssertEqual(mode("x", app: "Obsidian"), .produce)
    }

    func testContentTypeFallback() {
        XCTAssertEqual(mode("x", app: "SomeUnknownApp", contentType: "code"), .produce)
        XCTAssertEqual(mode("x", app: "SomeUnknownApp", contentType: "note"), .produce)
        XCTAssertEqual(mode("x", app: "SomeUnknownApp", contentType: "web"), .consume)
        // A body snapshot outside a maker app or browser (Preview, Acrobat) is reading.
        XCTAssertEqual(mode("x", app: "Preview", contentType: "document"), .consume)
        XCTAssertEqual(mode("x", app: "SomeUnknownApp", contentType: nil), .think)
    }

    // MARK: - resolvedMode

    func testResolvedModePrefersTheStoredValue() {
        var event = RecordingEvent(timestamp: Date(), eventType: .keystroke,
                                   appName: "Xcode", windowTitle: nil,
                                   textContent: "func f() {}")
        event.mode = Mode.consume.rawValue
        XCTAssertEqual(event.resolvedMode, .consume, "a stored mode must not be recomputed")
    }

    func testResolvedModeRecomputesForPreMigrationRows() {
        let event = RecordingEvent(timestamp: Date(), eventType: .keystroke,
                                   appName: "Xcode", windowTitle: nil,
                                   textContent: "func f() {}")
        XCTAssertNil(event.mode)
        XCTAssertEqual(event.resolvedMode, .produce)
    }

    func testResolvedModeIgnoresAnUnparseableStoredValue() {
        var event = RecordingEvent(timestamp: Date(), eventType: .keystroke,
                                   appName: "Slack", windowTitle: nil,
                                   textContent: "hi")
        event.mode = "not-a-mode"
        XCTAssertEqual(event.resolvedMode, .communicate)
    }
}
