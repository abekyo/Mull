import XCTest
@testable import mull

/// The pure rules behind the editor's typing conveniences — what Enter and Tab do
/// to a line, and what counts as a pasteable URL. The AppKit glue in
/// MarkdownTextEditor is deliberately thin; the behaviour worth pinning lives here.
final class MarkdownTypingTests: XCTestCase {

    // MARK: - Enter: continuation

    func testBulletContinues() {
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "- item"),
                       .continueBlock(prefix: "- ", contentStart: 2))
    }

    func testStarBulletKeepsItsMarker() {
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "* item"),
                       .continueBlock(prefix: "* ", contentStart: 2))
    }

    func testIndentedBulletKeepsIndent() {
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "  - item"),
                       .continueBlock(prefix: "  - ", contentStart: 4))
    }

    func testTaskContinuesUnchecked() {
        // The next item is a fresh task, never a pre-checked one.
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "- [x] done thing"),
                       .continueBlock(prefix: "- [ ] ", contentStart: 6))
    }

    func testOrderedIncrements() {
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "3. third"),
                       .continueBlock(prefix: "4. ", contentStart: 3))
    }

    func testOrderedCarriesIntoDoubleDigits() {
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "9. ninth"),
                       .continueBlock(prefix: "10. ", contentStart: 3))
    }

    func testOrderedPreservesGapWidth() {
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "1.  wide"),
                       .continueBlock(prefix: "2.  ", contentStart: 4))
    }

    func testQuoteContinues() {
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "> a thought"),
                       .continueBlock(prefix: "> ", contentStart: 2))
    }

    // MARK: - Enter: termination and plain lines

    func testEmptyBulletTerminates() {
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "- "), .terminate)
    }

    func testEmptyTaskTerminates() {
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "- [ ] "), .terminate)
    }

    func testEmptyOrderedTerminates() {
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "1. "), .terminate)
    }

    func testEmptyQuoteTerminates() {
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "> "), .terminate)
    }

    func testProseIsPlain() {
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "just a sentence"), .plain)
    }

    func testHeadingIsPlain() {
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "# Title"), .plain)
    }

    func testHorizontalRuleIsPlain() {
        // `---` must not read as a bullet — the bullet pattern requires a gap.
        XCTAssertEqual(MarkdownTyping.newlineAction(line: "---"), .plain)
    }

    func testEmptyLineIsPlain() {
        XCTAssertEqual(MarkdownTyping.newlineAction(line: ""), .plain)
    }

    // MARK: - Tab / ⇧Tab

    func testOutdentRemovesOneTab() {
        XCTAssertEqual(MarkdownTyping.outdentLength(line: "\t- x"), 1)
    }

    func testOutdentCapsAtFourSpaces() {
        XCTAssertEqual(MarkdownTyping.outdentLength(line: "      x"), 4)
    }

    func testOutdentRemovesShortSpaceRuns() {
        XCTAssertEqual(MarkdownTyping.outdentLength(line: "  - x"), 2)
    }

    func testOutdentNothingToRemove() {
        XCTAssertEqual(MarkdownTyping.outdentLength(line: "- x"), 0)
    }

    func testListLineDetection() {
        XCTAssertTrue(MarkdownTyping.isListLine("- a"))
        XCTAssertTrue(MarkdownTyping.isListLine("\t* a"))
        XCTAssertTrue(MarkdownTyping.isListLine("2. a"))
        XCTAssertTrue(MarkdownTyping.isListLine("- [x] a"))
        XCTAssertFalse(MarkdownTyping.isListLine("prose"))
        XCTAssertFalse(MarkdownTyping.isListLine("> quote"))
    }

    // MARK: - URL detection (⌘K and paste-over-selection)

    func testHTTPSURLsAreLinkable() {
        XCTAssertTrue(MarkdownTyping.isLinkableURL("https://example.com/a?b=c"))
        XCTAssertTrue(MarkdownTyping.isLinkableURL("http://localhost:3000"))
    }

    func testNonURLsAreNotLinkable() {
        XCTAssertFalse(MarkdownTyping.isLinkableURL("TODO: fix this"))
        XCTAssertFalse(MarkdownTyping.isLinkableURL("example.com"))        // no scheme
        XCTAssertFalse(MarkdownTyping.isLinkableURL("https://"))           // no host
        XCTAssertFalse(MarkdownTyping.isLinkableURL("ftp://example.com"))  // wrong scheme
        XCTAssertFalse(MarkdownTyping.isLinkableURL("https://exa mple.com"))
        XCTAssertFalse(MarkdownTyping.isLinkableURL(""))
    }
}
