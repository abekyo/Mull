import XCTest
@testable import mull

/// Locks the privacy filter: these must never pass through to an LLM prompt.
final class SensitiveTextTests: XCTestCase {

    func testFlagsSecrets() {
        XCTAssertTrue(SensitiveText.isSensitive("sk-ant-api_key-abc123"))
        XCTAssertTrue(SensitiveText.isSensitive("contact me at jane@example.com"))
        XCTAssertTrue(SensitiveText.isSensitive("Authorization: Bearer eyJabc.def"))
        XCTAssertTrue(SensitiveText.isSensitive("card 4242 4242 4242 4242"))
        XCTAssertTrue(SensitiveText.isSensitive("https://example.com/secret?token=xyz"))
        XCTAssertTrue(SensitiveText.isSensitive("-----BEGIN PRIVATE KEY-----"))
        XCTAssertTrue(SensitiveText.isSensitive("password: hunter2"))
    }

    func testAllowsOrdinaryText() {
        XCTAssertFalse(SensitiveText.isSensitive("Refactored the ChartViewModel bindings"))
        XCTAssertFalse(SensitiveText.isSensitive("買い物リストを作った"))
        XCTAssertFalse(SensitiveText.isSensitive("Met with the design team about onboarding"))
    }
}
