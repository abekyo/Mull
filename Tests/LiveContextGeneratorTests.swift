import XCTest
@testable import mull

/// Tests for LiveContextGenerator — data filtering and output quality.
final class LiveContextGeneratorTests: XCTestCase {

    // MARK: - isMullOutput (tool output filtering)

    func testFiltersClaudeCodeToolOutput() {
        let toolOutputs = [
            "WebSearch tool output (rex3pc) — notes-site",
            "Grep output (3k3opz) — Blow",
            "Bash tool output (olwimo) — PantryApp",
            "Read tool output (abc123) — project",
            "Glob tool output (xyz) — something",
        ]
        for text in toolOutputs {
            XCTAssertTrue(
                LiveContextGenerator.isMullOutput(text),
                "Should filter: \(text)"
            )
        }
    }

    func testFiltersmullOwnOutput() {
        let ownOutputs = [
            "About the user (auto-updated: 02/04/2026)",
            "mull is recording your activity",
            "mull is still learning",
            "Raw activity data for 2026-04-02",
        ]
        for text in ownOutputs {
            XCTAssertTrue(
                LiveContextGenerator.isMullOutput(text),
                "Should filter: \(text)"
            )
        }
    }

    func testDoesNotFilterNormalText() {
        let normalTexts = [
            "ViewController.swift — PantryApp",
            "Blow — BreathingSessionView.swift",
            "MVVM導入を行なってください",
            "func startRecording()",
        ]
        for text in normalTexts {
            XCTAssertFalse(
                LiveContextGenerator.isMullOutput(text),
                "Should NOT filter: \(text)"
            )
        }
    }

    // MARK: - isSensitive (URL and credential filtering)

    func testFiltersURLs() {
        let urls = [
            "https://www.farfetch.com/jp/wishlist",
            "http://localhost:3000/api/test",
            "https://maths-in-industry.org/27tokuten/",
        ]
        for text in urls {
            XCTAssertTrue(
                LiveContextGenerator.isSensitive(text),
                "Should filter URL: \(text)"
            )
        }
    }

    func testFiltersEmails() {
        XCTAssertTrue(LiveContextGenerator.isSensitive("contact me at user@example.com"))
    }

    func testFiltersZoomLinks() {
        XCTAssertTrue(LiveContextGenerator.isSensitive("Join: https://zoom.us/j/12345"))
        XCTAssertTrue(LiveContextGenerator.isSensitive("Meeting ID: 860 3536 8787\nPasscode: 143941"))
    }

    func testFiltersAPIKeys() {
        XCTAssertTrue(LiveContextGenerator.isSensitive("api_key=sk-abc123"))
        XCTAssertTrue(LiveContextGenerator.isSensitive("Bearer eyJhbGciOiJIUzI1NiJ9"))
        XCTAssertTrue(LiveContextGenerator.isSensitive("-----BEGIN RSA PRIVATE KEY-----"))
    }

    func testFiltersCreditCards() {
        XCTAssertTrue(LiveContextGenerator.isSensitive("Card: 4242 4242 4242 4242"))
    }

    func testDoesNotFilterNormalClipboard() {
        let normalTexts = [
            "MVVM導入を行なってください",
            "これなしでは生きられない感覚",
            "struct ContentView: View { }",
            "PantryApp — phase 2",
        ]
        for text in normalTexts {
            XCTAssertFalse(
                LiveContextGenerator.isSensitive(text),
                "Should NOT filter: \(text)"
            )
        }
    }
}

