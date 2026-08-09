import XCTest
@testable import mull

/// Locks the last link of the correction loop (CLAUDE.md §0 場面 B).
///
/// Between 2026-08-09 and this file, mull detected corrections, wrote a card for
/// each, folded the verdicts into a ledger — and **nothing read any of it**. The
/// loop was three quarters built and produced nothing a user could point at. These
/// tests exist so the missing quarter cannot go missing again silently.
final class RuleBookTests: XCTestCase {

    private var vault: URL { MullDirectory.root }

    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(
            at: vault.appendingPathComponent(CorrectionIndex.directory))
        try? FileManager.default.removeItem(
            at: vault.appendingPathComponent(RuleBook.path))
    }

    private func freshCard(_ id: String) -> String {
        CorrectionCard(path: "me.md", blockID: "fact:tools", date: Date(),
                       kept: "- Xcode", wouldWrite: "- Xcode\n- Cursor", context: nil).render()
            .replacingOccurrences(of: "ID: CRX", with: "ID: \(id)")
    }

    private func filledCard(_ id: String, rule: String) -> String {
        ContextBlockFile.serialize(
            header: freshCard(id),
            blocks: [ContextBlock(id: RuleBook.blockID, source: .agent, content: rule,
                                  agentHash: ContextBlock.hash(rule))])
    }

    private func write(_ id: String, _ text: String) {
        _ = MullDirectory.write(text, to: "\(CorrectionIndex.directory)/\(id).md")
    }

    // MARK: - Reading a card

    func testFreshCardHasNoRule() {
        // The normal state of a new card. Sections 4–8 ship as prompts, so a card
        // with no `rule` block is *waiting*, not broken.
        XCTAssertNil(RuleBook.rule(inCard: freshCard("CRX-A")))
    }

    func testFilledCardYieldsItsRule() {
        let card = filledCard("CRX-A", rule: "- Use when: 選択肢を並べたくなった時\n- Check question: 推奨は1つか？")
        XCTAssertEqual(RuleBook.rule(inCard: card)?.contains("推奨は1つか"), true)
    }

    func testEmptyRuleBlockCountsAsUnfilled() {
        // An agent that called `curate` with whitespace has not written a rule, and
        // treating it as one would retire the card without anyone having thought.
        let card = filledCard("CRX-A", rule: "   \n  ")
        XCTAssertNil(RuleBook.rule(inCard: card))
    }

    func testUnfilledListsOnlyCardsWithoutRulesOldestFirst() {
        let cards = [("CRX-C", freshCard("CRX-C")),
                     ("CRX-A", filledCard("CRX-A", rule: "- Use when: x")),
                     ("CRX-B", freshCard("CRX-B"))]
        XCTAssertEqual(RuleBook.unfilled(cards: cards), ["CRX-B", "CRX-C"])
    }

    // MARK: - Composing

    func testComposeEmitsOneBlockPerFilledCard() {
        let blocks = RuleBook.compose(cards: [
            ("CRX-A", filledCard("CRX-A", rule: "- Use when: a")),
            ("CRX-B", freshCard("CRX-B")),
            ("CRX-C", filledCard("CRX-C", rule: "- Use when: c"))
        ])
        XCTAssertEqual(blocks.map(\.id), ["CRX-A", "CRX-C"])
        XCTAssertTrue(blocks[0].content.contains("- Use when: a"))
    }

    func testComposeIsStable() {
        // Same cards in a different order must produce the same file, or every
        // rebuild would read as a change and generate spurious corrections.
        let cards = [("CRX-B", filledCard("CRX-B", rule: "- b")),
                     ("CRX-A", filledCard("CRX-A", rule: "- a"))]
        XCTAssertEqual(RuleBook.compose(cards: cards).map(\.id),
                       RuleBook.compose(cards: cards.reversed()).map(\.id))
    }

    func testHeaderSurfacesThePendingCount() {
        XCTAssertTrue(RuleBook.header(count: 2, pending: 3).contains("3"))
    }

    // MARK: - The loop, end to end

    func testRebuildPutsARuleWhereAnAgentWillReadIt() {
        write("CRX-A", filledCard("CRX-A", rule: "- Use when: 選択肢を並べたくなった時"))
        write("CRX-B", freshCard("CRX-B"))

        XCTAssertTrue(RuleBook.rebuild())

        let rules = MullDirectory.read(RuleBook.path) ?? ""
        XCTAssertTrue(rules.contains("選択肢を並べたくなった時"), "the rule reaches rules.md")
        XCTAssertTrue(rules.contains("CRX-A"), "and says which correction it came from")
        XCTAssertFalse(rules.contains("CRX-B"), "an unfilled card contributes nothing")
    }

    func testRebuildWritesNothingWhenThereIsNothingToSay() {
        // No corrections yet is the cold-start state of every install. Laying down
        // an empty scaffold there would put a file in the user's vault that says
        // only that mull has nothing — and they would have to wonder why.
        XCTAssertFalse(RuleBook.rebuild())
        XCTAssertNil(MullDirectory.read(RuleBook.path))
    }

    func testLedgerIsNotMistakenForACard() {
        _ = MullDirectory.write("| kept | +0.5 | `x` | y |", to: CorrectionIndex.ledgerPath)
        XCTAssertTrue(RuleBook.loadCards().isEmpty)
    }

    func testARuleTheUserRewritesIsNeverOverwritten() {
        // The whole promise of the file. A rule is the user's; mull assembles the
        // index of them (Invariant Contract 契約2).
        write("CRX-A", filledCard("CRX-A", rule: "- Use when: mull が書いた版"))
        RuleBook.rebuild()

        let mine = (MullDirectory.read(RuleBook.path) ?? "")
            .replacingOccurrences(of: "mull が書いた版", with: "私が書き直した版")
        _ = MullDirectory.write(mine, to: RuleBook.path)

        RuleBook.rebuild()
        let after = MullDirectory.read(RuleBook.path) ?? ""
        XCTAssertTrue(after.contains("私が書き直した版"))
        XCTAssertFalse(after.contains("mull が書いた版"))
    }

    // MARK: - Ownership

    func testRulesFileIsSharedNotMullOwned() {
        // `.shared` is the exact combination this file needs: the person may type
        // into it, an agent may only `curate`. `.mull` would lock the user out of
        // their own rules; `.user` would let write_note flatten the provenance.
        XCTAssertEqual(VaultOwnership.of(path: RuleBook.path), .shared)
        XCTAssertTrue(VaultOwnership.refusesWholesaleWrite(path: RuleBook.path))
        XCTAssertFalse(VaultOwnership.isMullWritten(path: RuleBook.path))
    }

    func testANoteTheUserNamesRulesElsewhereIsStillTheirs() {
        XCTAssertEqual(VaultOwnership.of(path: "notes/rules.md"), .user)
    }
}
