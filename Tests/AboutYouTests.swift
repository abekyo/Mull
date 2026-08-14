import XCTest
@testable import mull

/// What the About you page shows.
///
/// me.md is a curated file: every fact in it sits under a
/// `<!-- mull:block id=… src=agent hash=… ts=… -->` line, which is internal
/// metadata. Handed to a renderer they are drawn as text, and the page reading
/// "what mull knows about you" becomes a wall of hashes. This is the one surface
/// where that had no other symptom — the file on disk is fine, the MCP tools are
/// fine, only the page is wrong — so it is pinned here.
final class AboutYouTests: XCTestCase {

    private let file = """
    ---
    generator: "mull"
    updated: "2026-08-15T01:20+08:00"
    ---

    # Who I am

    > Rewrite a block and mull stops touching it.

    <!-- mull:block id=mem:ai-assistant-preference src=agent hash=2eb45ff7 ts=1786705114 -->
    - Prefers Claude for AI assistance; used frequently (updated 11 Aug 2026)

    <!-- mull:block id=pref:通知が鳴りすぎてうざい src=agent hash=29316191 ts=1786705114 -->
    - 通知が多すぎて操作の邪魔になると感じた（2026-08-09）
    """

    func testTheMarkersDoNotReachThePage() {
        let shown = AboutYouView.displayText(file)
        XCTAssertFalse(shown.contains(ContextBlockFile.markerPrefix), shown)
        XCTAssertFalse(shown.contains("hash="))
        XCTAssertFalse(shown.contains("src=agent"))
    }

    func testTheFactsThemselvesSurvive() {
        let shown = AboutYouView.displayText(file)
        XCTAssertTrue(shown.contains("- Prefers Claude for AI assistance; used frequently (updated 11 Aug 2026)"))
        XCTAssertTrue(shown.contains("- 通知が多すぎて操作の邪魔になると感じた（2026-08-09）"))
        XCTAssertTrue(shown.contains("# Who I am"), "the heading is content, not metadata")
    }

    /// A stripped marker leaves a blank line behind, and that blank line is the only
    /// thing keeping one block's last bullet off the next block's heading — see
    /// `ContextBlockFile.serialize`.
    func testBlocksStayApart() {
        let shown = AboutYouView.displayText(file)
        XCTAssertFalse(shown.contains("(updated 11 Aug 2026)\n- 通知"),
                       "two facts ran together: \(shown)")
    }
}
