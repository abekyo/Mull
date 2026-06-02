import XCTest
@testable import mull

/// Tests for the CurrentState anchor's pure entity extraction.
final class CurrentStateTests: XCTestCase {

    func testProjectLastEditorTitle() {
        // VS Code / Xcode style: "file — Project"
        XCTAssertEqual(CurrentState.entity(from: "ContentView.swift — PantryApp"), "PantryApp")
    }

    func testProjectFirstEditorTitle() {
        XCTAssertEqual(CurrentState.entity(from: "PantryApp — ContentView.swift"), "PantryApp")
    }

    func testDropsKnownApp() {
        // "Project — file — App" → App dropped, project kept.
        XCTAssertEqual(CurrentState.entity(from: "PantryApp — main.swift — Xcode"), "PantryApp")
    }

    func testSingleSegmentEntity() {
        XCTAssertEqual(CurrentState.entity(from: "PantryApp"), "PantryApp")
    }

    func testRejectsChatLikeTitle() {
        // A sentence/question is not a project.
        XCTAssertNil(CurrentState.entity(from: "このバグを直してくれますか？"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(CurrentState.entity(from: nil))
        XCTAssertNil(CurrentState.entity(from: ""))
    }
}
