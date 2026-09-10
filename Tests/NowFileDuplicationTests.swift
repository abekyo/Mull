import XCTest
@testable import mull

/// now.md says everything once.
///
/// On 2026-08-18 it said everything twice. Two passes wrote the file — the 60-second
/// rule-based one in `LiveContextGenerator` under `now:`, and the nightly
/// consolidation under `nightly:` — and both rendered the *same two tables* through
/// the *same formatter*. So ten projects, four days and three references appeared
/// once under プロジェクト / ここ数日 / 主な参照先 and again under Projects / This
/// week / References, in the file `get_user_context` and `mull://now` hand over
/// whole. Half of 5,332 bytes, on every agent call.
///
/// The fix is the division `generateLayerC` already states for full.md, applied to
/// now.md: ownership, not topic. These tests hold both halves of it — that the
/// nightly pass contributes nothing here, and that a block left by an older build is
/// swept out rather than waiting for a nightly run that needs an LLM provider to
/// happen at all.
final class NowFileDuplicationTests: XCTestCase {

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - The nightly pass writes no block into now.md

    func testTheNightlyPassContributesNoBlockToNow() throws {
        let engine = try source("Mull/Services/MullEngine.swift")
        // The three headings it used to render. Any of them reappearing beside a
        // now.md curate is the duplication coming back.
        let layerB = try XCTUnwrap(engine.range(of: "private func generateLayerB"))
        let after = String(engine[layerB.lowerBound...].prefix(1200))
        XCTAssertTrue(after.contains("agentBlocks: []"),
                      "generateLayerB must contribute nothing — its call survives only to prune")
        XCTAssertFalse(after.contains("MarkdownDoc.section(\"Projects\""),
                       "Projects belongs to the 60s pass, which localizes it and is always current")
        XCTAssertFalse(after.contains("MarkdownDoc.section(\"This week\""))
        XCTAssertFalse(after.contains("MarkdownDoc.section(\"References\""))
    }

    /// The one thing the nightly block showed more of was a seventh day.
    func testTheLivePassStillShowsSevenDays() throws {
        let live = try source("Mull/Services/LiveContextGenerator.swift")
        XCTAssertTrue(live.contains("recentDays.prefix(7)"),
                      "dropping the nightly block must not cost two days of summaries")
    }

    // MARK: - A block written by an older build is swept out

    /// `Curator.sweep` is the pure half of the expiry, so the rule is checkable
    /// without touching a vault.
    func testAFreshNightlyBlockIsStillRemovedFromNow() {
        let existing = """
        # いま取り組んでいること

        <!-- mull:block id=now:live src=agent hash=aaa ts=\(Int(Date().timeIntervalSince1970)) -->
        ## プロジェクト

        - **Mull** — a macOS app

        <!-- mull:block id=nightly:now src=agent hash=bbb ts=\(Int(Date().timeIntervalSince1970)) -->
        ## From last night's consolidation

        ### Projects

        - **Mull** — a macOS app
        """

        let swept = Curator.sweep(existing: existing, idPrefixes: ["nightly:"],
                                  maxAge: 0, now: Date())

        XCTAssertFalse(swept.contains("nightly:now"),
                       "no age makes a second copy of the same list worth keeping")
        XCTAssertFalse(swept.contains("From last night's consolidation"))
        XCTAssertTrue(swept.contains("now:live"), "the pass that owns the file keeps its block")
        XCTAssertTrue(swept.contains("プロジェクト"))
    }

    /// full.md's nightly block holds what only the nightly pass can produce, so it
    /// keeps the seven-day grace the staleness sweep was built with.
    func testFullKeepsItsNightlyBlockForAWeek() {
        let written = Int(Date().addingTimeInterval(-86_400).timeIntervalSince1970)
        let existing = """
        # Everything

        <!-- mull:block id=nightly:full src=agent hash=ccc ts=\(written) -->
        ## From last night's consolidation
        """

        let swept = Curator.sweep(existing: existing, idPrefixes: ["nightly:"],
                                  maxAge: LiveContextGenerator.nightlyMaxAge, now: Date())
        XCTAssertTrue(swept.contains("nightly:full"))
    }

    // MARK: - The headings under it follow the reader

    /// The last five raw English headings in the vault. The 2026-08-18 localization
    /// reached the 60s generator and not this pass, so full.md printed 私について over
    /// "Daily details (last 7 days)".
    func testTheNightlyFullHeadingsGoThroughVaultText() throws {
        let engine = try source("Mull/Services/MullEngine.swift")
        for heading in ["Daily details (last 7 days)", "Working style & feedback",
                        "Observed activity patterns", "Knowledge base",
                        "From last night's consolidation"] {
            XCTAssertFalse(engine.contains("MarkdownDoc.section(\"\(heading)\""),
                           "‘\(heading)’ is prose, and prose follows the reader")
            XCTAssertTrue(engine.contains("VaultText.t(\"\(heading)\""),
                          "‘\(heading)’ needs a Japanese form")
        }
    }
}
