import XCTest
@testable import mull

/// Tests for TestInput — the content-based test/QA input filter.
final class TestInputTests: XCTestCase {

    // MARK: - Should be flagged as test input

    func testFlagsPangram() {
        XCTAssertTrue(TestInput.isLikelyTestInput("the quick brown fox jumps over the lazy dog"))
    }

    func testFlagsAbnormalSpacing() {
        XCTAssertTrue(TestInput.isLikelyTestInput("test   double   spaces"))
    }

    func testFlagsConsecutiveSingleLetters() {
        XCTAssertTrue(TestInput.isLikelyTestInput("a b cd efg hijkl"))
    }

    func testFlagsKeyboardMash() {
        XCTAssertTrue(TestInput.isLikelyTestInput("asdfgh"))
        XCTAssertTrue(TestInput.isLikelyTestInput("qwerty"))
    }

    func testFlagsLongCharRun() {
        XCTAssertTrue(TestInput.isLikelyTestInput("aaaaa"))
    }

    // MARK: - Should NOT be flagged (real work)

    func testKeepsRealJapaneseInstruction() {
        XCTAssertFalse(TestInput.isLikelyTestInput("Phase 2残りCalendar IUO解消を着手してください"))
    }

    func testKeepsRealEnglishPhrase() {
        XCTAssertFalse(TestInput.isLikelyTestInput("SwiftUI navigation pattern"))
    }

    func testKeepsRealCode() {
        XCTAssertFalse(TestInput.isLikelyTestInput("func viewDidLoad() { super.viewDidLoad() }"))
    }

    func testKeepsShortSentence() {
        XCTAssertFalse(TestInput.isLikelyTestInput("I am refactoring the calendar view"))
    }
}
