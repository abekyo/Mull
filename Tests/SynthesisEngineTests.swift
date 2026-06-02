import XCTest
@testable import mull

/// Tests for the synthesis parser (the LLM call itself is integration-only).
final class SynthesisEngineTests: XCTestCase {

    func testParsesPlainJSONObject() {
        let json = #"{"summary":"Did things","skills":"Swift"}"#
        let out = SynthesisEngine.parseSections(json)
        XCTAssertEqual(out["summary"], "Did things")
        XCTAssertEqual(out["skills"], "Swift")
    }

    func testStripsCodeFences() {
        let fenced = """
        ```json
        {"decisions": "Chose GRDB"}
        ```
        """
        XCTAssertEqual(SynthesisEngine.parseSections(fenced)["decisions"], "Chose GRDB")
    }

    func testIgnoresSurroundingProse() {
        let messy = "Here is the JSON you asked for:\n{\"references\": \"link\"}\nHope that helps!"
        XCTAssertEqual(SynthesisEngine.parseSections(messy)["references"], "link")
    }

    func testDropsEmptyValuesAndNonStrings() {
        let json = #"{"a":"keep","b":"","c":123}"#
        let out = SynthesisEngine.parseSections(json)
        XCTAssertEqual(out, ["a": "keep"])
    }

    func testInvalidReturnsEmpty() {
        XCTAssertTrue(SynthesisEngine.parseSections("not json at all").isEmpty)
        XCTAssertTrue(SynthesisEngine.parseSections("").isEmpty)
    }
}
