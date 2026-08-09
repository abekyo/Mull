import XCTest
@testable import mull

/// Locks the query-building helpers behind every search path.
///
/// These were the site of two silent failures: FTS5 syntax errors swallowed by a
/// `catch` and reported to the user as "no results", and Japanese queries that
/// could never match because unicode61 tokenizes a CJK run as a single token.
/// Both failed by returning an empty array, which is indistinguishable from a
/// genuine miss — exactly the shape of bug a test has to catch.
final class SearchQueryTests: XCTestCase {

    // MARK: - CJK detection

    func testDetectsJapaneseScripts() {
        XCTAssertTrue(TextScript.containsCJK("会議"))          // kanji
        XCTAssertTrue(TextScript.containsCJK("ひらがな"))       // hiragana
        XCTAssertTrue(TextScript.containsCJK("カタカナ"))       // katakana
        XCTAssertTrue(TextScript.containsCJK("今日のmeeting"))  // mixed
    }

    func testDoesNotFlagLatinOrPunctuation() {
        XCTAssertFalse(TextScript.containsCJK("meeting notes"))
        XCTAssertFalse(TextScript.containsCJK("re-render main()"))
        XCTAssertFalse(TextScript.containsCJK(""))
        XCTAssertFalse(TextScript.containsCJK("123 — ok"))
    }

    // MARK: - FTS expression building

    func testBuildsPrefixTerms() {
        XCTAssertEqual(DatabaseService.ftsMatchExpression("swift"), "\"swift\"*")
        XCTAssertEqual(DatabaseService.ftsMatchExpression("swift chart"),
                       "\"swift\"* \"chart\"*")
    }

    func testPunctuationCannotBreakSyntax() {
        // Every one of these threw an FTS5 syntax error before quoting/reduction,
        // which the catch turned into "no results".
        for query in ["re-render", "main()", "foo\"bar", "a:b", "x AND y", "(paren"] {
            let expr = DatabaseService.ftsMatchExpression(query)
            XCTAssertNotNil(expr, "\(query) produced no expression")
            // Terms are alphanumeric-only and quoted; nothing else survives.
            XCTAssertFalse(expr!.contains("("), "\(query) leaked a paren")
            XCTAssertFalse(expr!.contains(":"), "\(query) leaked a colon")
        }
    }

    func testBareBooleanKeywordsAreQuotedNotInterpreted() {
        // Unquoted, "AND"/"OR"/"NEAR" are FTS5 operators. Quoted, they are terms.
        XCTAssertEqual(DatabaseService.ftsMatchExpression("and"), "\"and\"*")
        XCTAssertEqual(DatabaseService.ftsMatchExpression("near"), "\"near\"*")
    }

    func testReturnsNilWhenNothingSearchable() {
        XCTAssertNil(DatabaseService.ftsMatchExpression(""))
        XCTAssertNil(DatabaseService.ftsMatchExpression("   "))
        XCTAssertNil(DatabaseService.ftsMatchExpression("-- ()"))
    }

    // MARK: - LIKE escaping

    func testLikePatternEscapesWildcards() {
        // Unescaped, a literal % or _ in the user's query would silently widen
        // the match instead of narrowing it.
        XCTAssertEqual(DatabaseService.likePattern("50%"), "%50\\%%")
        XCTAssertEqual(DatabaseService.likePattern("a_b"), "%a\\_b%")
        XCTAssertEqual(DatabaseService.likePattern("c:\\tmp"), "%c:\\\\tmp%")
    }

    func testLikePatternWrapsPlainText() {
        XCTAssertEqual(DatabaseService.likePattern("会議"), "%会議%")
    }
}
