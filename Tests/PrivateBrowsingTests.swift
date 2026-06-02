import XCTest
@testable import mull

/// Locks the private-browsing filter: these titles must never be recorded.
final class PrivateBrowsingTests: XCTestCase {

    func testDetectsPrivateWindows() {
        XCTAssertTrue(PrivateBrowsing.isPrivate("Some Page — Mozilla Firefox — プライベートブラウジング"))
        XCTAssertTrue(PrivateBrowsing.isPrivate("Reddit — Private Browsing"))
        XCTAssertTrue(PrivateBrowsing.isPrivate("YouTube - Google Chrome (Incognito)"))
        XCTAssertTrue(PrivateBrowsing.isPrivate("ニュース - Google Chrome（シークレット モード）"))
        XCTAssertTrue(PrivateBrowsing.isPrivate("Bing - InPrivate - Microsoft Edge"))
    }

    func testAllowsNormalTitles() {
        XCTAssertFalse(PrivateBrowsing.isPrivate("GitHub - Mozilla Firefox"))
        XCTAssertFalse(PrivateBrowsing.isPrivate("ViewController.swift — Mull"))
        XCTAssertFalse(PrivateBrowsing.isPrivate("プライベートメモ.md"))  // not a browser private-mode marker
    }
}
