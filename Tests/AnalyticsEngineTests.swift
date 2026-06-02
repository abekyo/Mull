import XCTest
import GRDB
@testable import mull

/// Tests for AnalyticsEngine — pattern detection and noise filtering.
final class AnalyticsEngineTests: XCTestCase {

    private var db: DatabaseService!
    private var analytics: AnalyticsEngine!

    override func setUp() {
        super.setUp()
        db = DatabaseService()
        try? db.deleteAllData()
        analytics = AnalyticsEngine(database: db)
    }

    // MARK: - Keyword Extraction

    func testTopKeywordsFiltersStopWords() {
        insertClipboard("the quick brown fox jumps over the lazy dog")
        insertClipboard("the quick brown fox jumps over the lazy dog")

        let keywords = analytics.topKeywords(days: 1, limit: 10)
        let words = keywords.map(\.word)

        // "the" should be filtered as a stop word
        XCTAssertFalse(words.contains("the"))
        // Content words should remain
        XCTAssertTrue(words.contains("quick"))
        XCTAssertTrue(words.contains("brown"))
    }

    func testTopKeywordsFiltersURLs() {
        insertClipboard("https://example.com/some/page")
        insertClipboard("check http://localhost:3000/api")

        let keywords = analytics.topKeywords(days: 1, limit: 10)
        let words = keywords.map(\.word)

        XCTAssertFalse(words.contains("https"))
        XCTAssertFalse(words.contains("example"))
        XCTAssertFalse(words.contains("localhost"))
    }

    func testTopKeywordsFiltersCommandFragments() {
        insertClipboard("Phase 2残りCalendar IUO解消を着手してください")
        insertClipboard("Phase 2残りCalendar IUO解消を着手してください")

        let keywords = analytics.topKeywords(days: 1, limit: 10)
        let words = keywords.map(\.word)

        // Command fragments ending in ください should be filtered
        XCTAssertFalse(words.contains { $0.hasSuffix("ください") })
    }

    func testTopKeywordsFiltersEmptyAndShortWords() {
        insertClipboard("a b cd efg hijkl")
        insertClipboard("a b cd efg hijkl")

        let keywords = analytics.topKeywords(days: 1, limit: 10)
        let words = keywords.map(\.word)

        XCTAssertFalse(words.contains("a"))
        XCTAssertFalse(words.contains("b"))
        XCTAssertFalse(words.contains("cd"))
        // 3+ chars should pass (if not a stop word)
        XCTAssertTrue(words.contains("efg"))
    }

    // MARK: - Phrase Detection

    func testTopPhrasesRequiresMinimumCount() {
        // Insert phrase only once — should not appear (minimum is 3)
        insertClipboard("unique special phrase")

        let phrases = analytics.topPhrases(days: 1, limit: 5)
        XCTAssertFalse(phrases.contains { $0.word.contains("unique special") })
    }

    func testTopPhrasesFiltersNoisePatterns() {
        for _ in 0..<5 {
            insertClipboard("Phase 2残りCalendar IUO解消を着手してください")
        }

        let phrases = analytics.topPhrases(days: 1, limit: 10)
        let phraseTexts = phrases.map(\.word)

        XCTAssertFalse(phraseTexts.contains { $0.contains("着手して") })
        XCTAssertFalse(phraseTexts.contains { $0.contains("phase ") })
    }

    func testTopPhrasesFiltersEmptyWords() {
        for _ in 0..<5 {
            insertClipboard("test   double   spaces")
        }

        let phrases = analytics.topPhrases(days: 1, limit: 10)
        // No phrase should contain empty word components
        for phrase in phrases {
            let words = phrase.word.components(separatedBy: " ")
            XCTAssertFalse(words.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                           "Phrase '\(phrase.word)' contains empty word")
        }
    }

    // MARK: - Pattern Summary

    func testGeneratePatternSummaryFormat() {
        for _ in 0..<3 {
            insertClipboard("SwiftUI navigation pattern")
            insertKeystroke(app: "Code", text: "func viewDidLoad")
        }

        let summary = analytics.generatePatternSummary(days: 1)

        XCTAssertTrue(summary.contains("Behavioral patterns"))
        // Should use new labels
        XCTAssertFalse(summary.contains("Most used words"))
        XCTAssertFalse(summary.contains("Repeated phrases"))
    }

    // MARK: - App Usage

    func testAppUsageExcludesNoiseApps() {
        insertEvent(type: .appSwitch, app: "Code", text: nil)
        insertEvent(type: .appSwitch, app: "Code", text: nil)
        insertEvent(type: .appSwitch, app: "loginwindow", text: nil)

        let usage = analytics.appUsage(days: 1)
        let apps = usage.map(\.appName)

        XCTAssertTrue(apps.contains("Code"))
        XCTAssertFalse(apps.contains("loginwindow"))
    }

    // MARK: - Weekday Pattern

    func testWeekdayPatternReturns7Days() {
        let pattern = analytics.weekdayPattern(days: 30)
        XCTAssertEqual(pattern.count, 7)
    }

    // MARK: - Helpers

    private func insertClipboard(_ text: String) {
        insertEvent(type: .clipboard, app: "Code", text: text)
    }

    private func insertKeystroke(app: String, text: String) {
        insertEvent(type: .keystroke, app: app, text: text)
    }

    private func insertEvent(type: RecordingEvent.EventType, app: String, text: String?) {
        let event = RecordingEvent(
            timestamp: Date(),
            eventType: type,
            appName: app,
            textContent: text
        )
        db.insertEvent(event)
    }
}
