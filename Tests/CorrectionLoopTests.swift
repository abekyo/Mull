import XCTest
@testable import mull

/// Locks the correction loop — the one signal no competitor can have
/// (HARNESS.md 第II部 §6). Until 2026-08-09 mull detected human edits and threw
/// the evidence away; these tests exist so it cannot go back to that silently.
final class CorrectionLoopTests: XCTestCase {

    private func card(kept: String, wouldWrite: String?) -> CorrectionCard {
        CorrectionCard(path: "me.md", blockID: "fact:tools", date: Date(),
                       kept: kept, wouldWrite: wouldWrite, context: nil)
    }

    // MARK: - CorrectionCard

    func testCardSeparatesDroppedSurvivedAndAdded() {
        let c = card(kept: "- kept line\n- human line",
                     wouldWrite: "- kept line\n- deleted line")
        XCTAssertEqual(c.dropped, ["- deleted line"])
        XCTAssertEqual(c.survived, ["- kept line"])
        XCTAssertEqual(c.added, ["- human line"])
    }

    func testCardWithNoCandidateRecordsOnlyWhatItKnows() {
        // The 60s pass may not emit this id on the pass that notices the edit.
        // Claiming a "before" mull does not have would be a fabricated provenance
        // (Invariant Contract 契約1).
        let c = card(kept: "- something the human wrote", wouldWrite: nil)
        XCTAssertTrue(c.dropped.isEmpty)
        XCTAssertTrue(c.survived.isEmpty)
        XCTAssertEqual(c.added, ["- something the human wrote"])
        XCTAssertEqual(c.drift, 1)
    }

    func testRenderedCardLeavesInterpretationBlank() {
        // Sections 4/5/8 are the intellectual work. A machine-written guess there
        // is a plausible lie, not a label — the card must ship them empty.
        let rendered = card(kept: "a", wouldWrite: "a\nb").render()
        XCTAssertTrue(rendered.contains("### 4. Hidden axis"))
        XCTAssertTrue(rendered.contains("自動生成しない"))
        XCTAssertTrue(rendered.contains("### 1. Context snapshot"))
        XCTAssertTrue(rendered.contains("### 3. Signals observed"))
        // Section 3 IS filled — observation is automatable.
        XCTAssertTrue(rendered.contains("~~b~~"), "the dropped line is recorded")
    }

    func testCardIDIsStablePerBlock() {
        let a = card(kept: "x", wouldWrite: nil).id
        let b = card(kept: "totally different", wouldWrite: nil).id
        XCTAssertEqual(a, b, "same file + block → same card, even after re-editing")
    }

    // MARK: - CorrectionIndex

    func testDroppedIsNegativeAndSurvivedIsPositive() {
        let index = CorrectionIndex.fold([card(kept: "- keep me", wouldWrite: "- keep me\n- drop me")])
        XCTAssertLessThan(index.delta(for: "- drop me"), 0)
        XCTAssertGreaterThan(index.delta(for: "- keep me"), 0)
        XCTAssertEqual(index.delta(for: "- never seen"), 0)
    }

    func testDeletionOutweighsSurvival() {
        // Leaving something alone is weaker evidence than deleting it: a human who
        // edits one bullet has not thereby endorsed the other five.
        let index = CorrectionIndex.fold([card(kept: "- a", wouldWrite: "- a\n- b")])
        XCTAssertGreaterThan(abs(index.delta(for: "- b")), abs(index.delta(for: "- a")))
    }

    func testVerdictsAreClamped() {
        let repeated = Array(repeating: card(kept: "- a", wouldWrite: "- a\n- b"), count: 10)
        let index = CorrectionIndex.fold(repeated)
        XCTAssertGreaterThanOrEqual(index.delta(for: "- b"), -1)
        XCTAssertLessThanOrEqual(index.delta(for: "- a"), 1)
    }

    func testSignatureIgnoresWhitespaceAndCase() {
        XCTAssertEqual(CorrectionIndex.signature("Fix The Parser"),
                       CorrectionIndex.signature("fix   the parser"))
    }

    func testLedgerRoundTrips() {
        let index = CorrectionIndex.fold([card(kept: "- a", wouldWrite: "- a\n- b")])
        let reloaded = CorrectionIndex.parseLedger(index.renderLedger())
        XCTAssertEqual(reloaded.count, index.count)
        XCTAssertEqual(reloaded.delta(for: "- b"), index.delta(for: "- b"), accuracy: 0.001)
    }

    func testHandEditedLedgerCannotCrashTheSelectionLayer() {
        // The file is advertised as editable, so garbage in it must degrade to
        // "no signal", never to a failure (Invariant Contract 契約2).
        let junk = """
        # Correction ledger
        | dropped | not-a-number | `abc` | x |
        | dropped |
        random prose with no pipes at all
        | kept | +0.50 | `deadbeef` | fine |
        """
        let index = CorrectionIndex.parseLedger(junk)
        XCTAssertEqual(index.count, 1, "only the well-formed row survives")
    }

    // MARK: - Curator.detectCorrections

    private func file(_ blocks: [ContextBlock]) -> String {
        ContextBlockFile.serialize(header: "", blocks: blocks)
    }

    func testDetectsAnEditedAgentBlock() {
        let original = ContextBlock(id: "fact:tools", source: .agent,
                                    content: "- Primary tools: Code, Xcode",
                                    agentHash: ContextBlock.hash("- Primary tools: Code, Xcode"))
        var edited = original
        edited.content = "- Primary tools: Xcode"   // the human deleted one

        let cards = Curator.detectCorrections(existing: file([edited]),
                                              agentBlocks: [original], path: "me.md")
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.blockID, "fact:tools")
        XCTAssertEqual(cards.first?.kept, "- Primary tools: Xcode")
    }

    func testUntouchedAgentBlockIsNotACorrection() {
        let b = ContextBlock(id: "fact:tools", source: .agent, content: "- unchanged",
                             agentHash: ContextBlock.hash("- unchanged"))
        XCTAssertTrue(Curator.detectCorrections(existing: file([b]),
                                                agentBlocks: [b], path: "me.md").isEmpty)
    }

    func testHumanAndPinnedBlocksAreNotCorrections() {
        // They were never mull's to be corrected. A `.human` block is the *result*
        // of a past correction, not a new one — counting it again would let one
        // edit accumulate weight forever.
        let human = ContextBlock(id: "note", source: .human, content: "mine", agentHash: nil)
        let pinned = ContextBlock(id: "pinned-facts", source: .pinned, content: "mine", agentHash: nil)
        XCTAssertTrue(Curator.detectCorrections(existing: file([human, pinned]),
                                                agentBlocks: [], path: "me.md").isEmpty)
    }
}
