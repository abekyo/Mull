import XCTest
@testable import mull

/// Tests for Curator.merge — provenance, pruning of stale agent blocks, and
/// subsumption dedup (the me.md "About me" cleanup).
final class CuratorTests: XCTestCase {

    /// Build a serialized file from agent blocks, stamping each with the hash
    /// Curator would have written (so they read back as agent-authored, not
    /// human-edited).
    private func serialized(_ pairs: [(id: String, content: String)]) -> String {
        let blocks = pairs.map {
            ContextBlock(id: $0.id, source: .agent, content: $0.content,
                         agentHash: ContextBlock.hash($0.content))
        }
        return ContextBlockFile.serialize(header: "H", blocks: blocks)
    }

    private func agent(_ id: String, _ content: String) -> ContextBlock {
        ContextBlock(id: id, source: .agent, content: content, agentHash: nil)
    }

    // MARK: - Retraction (the forget path)

    func testRetractWithdrawsAgentBlocksUnderPrefix() {
        let existing = serialized([
            ("nightly:now", "- Yesterday you worked on the forgotten thing"),
            ("now:live", "- Currently in Xcode"),
        ])
        let (text, retained) = Curator.withdraw(existing: existing, idPrefixes: ["nightly:"])

        XCTAssertFalse(text.contains("forgotten thing"))
        XCTAssertTrue(text.contains("Currently in Xcode"), "blocks outside the prefixes are untouched")
        XCTAssertTrue(retained.isEmpty)
        XCTAssertTrue(text.hasPrefix("H"), "the header survives retraction")
    }

    /// The case that separates retraction from deletion. mull may withdraw its
    /// own sentences; the user's are not its to take, even when the user asked
    /// for the window they sit in to be forgotten.
    func testRetractKeepsAndReportsBlocksTheUserEdited() {
        let edited = ContextBlockFile.serialize(header: "H", blocks: [
            // src=agent, but the content no longer matches the hash mull wrote →
            // the user rewrote it by hand.
            ContextBlock(id: "nightly:now", source: .agent, content: "my own words",
                         agentHash: ContextBlock.hash("what mull wrote")),
        ])
        let (text, retained) = Curator.withdraw(existing: edited, idPrefixes: ["nightly:"])

        XCTAssertTrue(text.contains("my own words"))
        XCTAssertEqual(retained, ["nightly:now"])
    }

    func testRetractKeepsPinnedAndHumanBlocks() {
        let existing = ContextBlockFile.serialize(header: "H", blocks: [
            ContextBlock(id: "mem:pinned-ish", source: .pinned, content: "- pinned", agentHash: nil),
            ContextBlock(id: "mem:by-hand", source: .human, content: "- handwritten", agentHash: nil),
            ContextBlock(id: "mem:mulls-own", source: .agent, content: "- auto",
                         agentHash: ContextBlock.hash("- auto")),
        ])
        let (text, retained) = Curator.withdraw(existing: existing, idPrefixes: ["mem:"])

        XCTAssertTrue(text.contains("pinned"))
        XCTAssertTrue(text.contains("handwritten"))
        XCTAssertFalse(text.contains("- auto"))
        XCTAssertEqual(Set(retained), ["mem:pinned-ish", "mem:by-hand"])
    }

    func testRetractOnUnrelatedPrefixChangesNothing() {
        let existing = serialized([("now:live", "- Currently in Xcode")])
        let (text, retained) = Curator.withdraw(existing: existing, idPrefixes: ["nightly:"])
        XCTAssertEqual(text, existing)
        XCTAssertTrue(retained.isEmpty)
    }

    // MARK: - Pruning

    func testStaleManagedBlockIsPruned() {
        // me.md already has a "Bilingual" fact from a previous run.
        let existing = serialized([
            ("fact:identity:bilingual", "- Bilingual: Japanese (78%) and English (21%)"),
            ("fact:identity:primary-language", "- Primary language: Japanese"),
        ])
        // This run only emits "Primary language" — "Bilingual" is no longer produced.
        let merged = Curator.merge(
            existing: existing, header: "H", pinnedContent: nil,
            agentBlocks: [agent("fact:identity:primary-language", "- Primary language: Japanese")],
            managedPrefixes: ["fact:"])

        XCTAssertFalse(merged.contains("Bilingual"), "stale fact: block should be pruned")
        XCTAssertTrue(merged.contains("Primary language: Japanese"))
    }

    func testUnmanagedPrefixIsNotPruned() {
        let existing = serialized([("mem:old", "- some memory")])
        // Manage only fact:, so the mem: block must survive even though it's not re-emitted.
        let merged = Curator.merge(
            existing: existing, header: "H", pinnedContent: nil,
            agentBlocks: [], managedPrefixes: ["fact:"])

        XCTAssertTrue(merged.contains("some memory"), "blocks outside managed prefixes are never pruned")
    }

    func testNoPruningWhenNoManagedPrefixes() {
        let existing = serialized([("fact:identity:bilingual", "- Bilingual: x and y")])
        let merged = Curator.merge(
            existing: existing, header: "H", pinnedContent: nil,
            agentBlocks: [], managedPrefixes: [])

        XCTAssertTrue(merged.contains("Bilingual"), "default behaviour preserves all agent blocks")
    }

    // MARK: - Subsumption dedup

    func testBareBlockSubsumedByRicherIsDropped() {
        let merged = Curator.merge(
            existing: "", header: "H", pinnedContent: nil,
            agentBlocks: [
                agent("mem:user-role", "- Software developer"),
                agent("fact:identity:software-developer", "- Software developer (primary tools: Code, Xcode)"),
            ],
            managedPrefixes: ["fact:", "mem:"])

        XCTAssertTrue(merged.contains("Software developer (primary tools: Code, Xcode)"))
        // The bare duplicate line must be gone (only the richer one remains).
        let bareCount = merged.components(separatedBy: "- Software developer\n").count - 1
        XCTAssertEqual(bareCount, 0, "bare 'Software developer' should be dropped as subsumed")
    }

    func testDistinctBlocksAreNotMerged() {
        let merged = Curator.merge(
            existing: "", header: "H", pinnedContent: nil,
            agentBlocks: [
                agent("fact:projects:a", "- Working on: Alpha"),
                agent("fact:projects:b", "- Working on: Beta"),
            ],
            managedPrefixes: ["fact:"])

        XCTAssertTrue(merged.contains("Alpha"))
        XCTAssertTrue(merged.contains("Beta"), "non-prefix facts must both survive")
    }

    // MARK: - Pinned facts

    // me.pinned.md is declared authoritative and placed above everything else in
    // me.md, so it is the first thing any AI reads about the user — and nothing
    // validated it. The shipped vault contained `ああ / あああ / あああ`, keyboard
    // mash typed once to check the file worked, and mull handed it to every
    // assistant as the user's identity for over a month.

    func testKeyboardMashIsNotPublishedAsIdentity() {
        let result = Curator.filterPinned("ああ\nあああ\n- Founder; FX trading is the priority.")

        XCTAssertEqual(result.text, "- Founder; FX trading is the priority.")
        XCTAssertEqual(result.withheld, ["ああ", "あああ"])
    }

    func testWithheldLinesAreReturnedNotDropped() {
        // Filtering silently would be the worse failure: the user writes a line,
        // watches it vanish from me.md, and has no way to learn why. Every line
        // mull declines must come back so a surface can show it.
        let result = Curator.filterPinned("aaaaa\n- Primary working language: Japanese.")

        XCTAssertFalse(result.withheld.isEmpty, "a withheld line must be reported")
        XCTAssertTrue(result.text.contains("Japanese"))
    }

    func testListMarkersDoNotSmuggleMashThrough() {
        // "- ああ" and "ああ" are the same non-fact; the marker must be stripped
        // before judging, not treated as content.
        XCTAssertEqual(Curator.filterPinned("- ああ").text, "")
    }

    func testCommentsAndRealFactsSurvive() {
        let raw = """
        # this is the template comment
        - Founder running several businesses.
        - Primary working language: Japanese.
        """
        let result = Curator.filterPinned(raw)

        XCTAssertTrue(result.withheld.isEmpty, "no real fact may be withheld: \(result.withheld)")
        XCTAssertTrue(result.text.contains("Founder running several businesses."))
        XCTAssertFalse(result.text.contains("template comment"))
    }

    // MARK: - Round-trip stability

    /// The bug that froze mull's own writing in place. A block whose content ended
    /// in whitespace came back from `parse` trimmed, so it no longer matched the
    /// hash `merge` had written, `merge` read that as a human edit, and promoted
    /// the block to `.human` — after which mull would never touch it again. The
    /// OneTab dump in the shipped proactive.md was mull's own output, held there
    /// by mull's own protection.
    func testTrailingWhitespaceDoesNotLookLikeAHumanEdit() {
        let first = Curator.merge(existing: "", header: "H", pinnedContent: nil,
                                  agentBlocks: [agent("brief:x", "- a line\n")])
        let second = Curator.merge(existing: first, header: "H", pinnedContent: nil,
                                   agentBlocks: [agent("brief:x", "- a different line")])

        XCTAssertTrue(second.contains("- a different line"),
                      "mull must still own the block it wrote: \(second)")
        XCTAssertFalse(second.contains("src=human"),
                       "a round trip is not an edit: \(second)")
    }

    func testGenuineHumanEditIsStillProtected() {
        let written = Curator.merge(existing: "", header: "H", pinnedContent: nil,
                                    agentBlocks: [agent("brief:x", "- mull's line")])
        let edited = written.replacingOccurrences(of: "- mull's line", with: "- the user's line")
        let after = Curator.merge(existing: edited, header: "H", pinnedContent: nil,
                                  agentBlocks: [agent("brief:x", "- mull's second try")])

        XCTAssertTrue(after.contains("- the user's line"))
        XCTAssertFalse(after.contains("second try"), "an edited block is the user's")
    }

    /// Every surface that shows a curated file to a human or an AI strips the
    /// markers first. Without a blank line between blocks that strip glued the
    /// last bullet of one block to the next block's heading.
    func testBlocksSurviveMarkerStrippingAsSeparateSections() {
        let file = Curator.merge(existing: "", header: "H", pinnedContent: nil,
                                 agentBlocks: [agent("a", "- last bullet"),
                                               agent("b", "## Next section")])
        let stripped = ContextBlockFile.stripMarkers(file)

        XCTAssertTrue(stripped.contains("- last bullet\n\n## Next section"),
                      "blocks ran together once the markers went: \(stripped)")
    }

    // MARK: - Expiry (the staleness path)

    private func stamped(_ id: String, _ content: String, _ writtenAt: Date?) -> ContextBlock {
        ContextBlock(id: id, source: .agent, content: content,
                     agentHash: ContextBlock.hash(content), writtenAt: writtenAt)
    }

    func testStaleNightlyBlockIsSwept() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let file = ContextBlockFile.serialize(header: "H", blocks: [
            stamped("nightly:now", "## From last night's consolidation", now.addingTimeInterval(-30 * 86_400)),
            stamped("now:live", "## Right now", now),
        ])
        let swept = Curator.sweep(existing: file, idPrefixes: ["nightly:"], maxAge: 7 * 86_400, now: now)

        XCTAssertFalse(swept.contains("last night's consolidation"),
                       "a month-old block may not keep claiming to be last night's")
        XCTAssertTrue(swept.contains("## Right now"))
    }

    func testFreshNightlyBlockSurvives() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let file = ContextBlockFile.serialize(header: "H", blocks: [
            stamped("nightly:now", "## From last night's consolidation", now.addingTimeInterval(-3_600)),
        ])
        let swept = Curator.sweep(existing: file, idPrefixes: ["nightly:"], maxAge: 7 * 86_400, now: now)

        XCTAssertTrue(swept.contains("last night's consolidation"))
    }

    /// An unstamped block was written before the stamp existed, so its age cannot
    /// be established — and "from last night" is a claim about age.
    func testUnstampedNightlyBlockIsSwept() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let file = ContextBlockFile.serialize(header: "H", blocks: [
            stamped("nightly:full", "## From last night's consolidation", nil),
        ])
        let swept = Curator.sweep(existing: file, idPrefixes: ["nightly:"], maxAge: 7 * 86_400, now: now)

        XCTAssertFalse(swept.contains("last night's consolidation"))
    }

    /// mull expires its own writing. A block the user edited (or pinned) carries no
    /// stamp by design, and sweeping on that absence would delete their work.
    func testSweepNeverTouchesHumanOrPinnedBlocks() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let file = ContextBlockFile.serialize(header: "H", blocks: [
            ContextBlock(id: "nightly:now", source: .human, content: "- my own note", agentHash: nil),
            ContextBlock(id: "pinned-facts", source: .pinned, content: "- I work in Japanese", agentHash: nil),
        ])
        let swept = Curator.sweep(existing: file, idPrefixes: ["nightly:", "pinned"], maxAge: 0, now: now)

        XCTAssertTrue(swept.contains("- my own note"))
        XCTAssertTrue(swept.contains("- I work in Japanese"))
    }

    // MARK: - Header timestamp

    func testTimestampIsISO8601WithOffset() {
        // "11/06/2026, 12:26 AM" (the old locale .short format) is ambiguous to an
        // AI reader — June 11 or November 6. The header timestamp must be ISO 8601
        // with an explicit UTC offset, and must not vary with the user's locale.
        let stamp = Curator.timestamp(Date(timeIntervalSince1970: 1_780_000_000))
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#
        XCTAssertNotNil(stamp.range(of: pattern, options: .regularExpression),
                        "not ISO 8601: \(stamp)")
    }

    // MARK: - What me.md says when it has nothing to say
    //
    // The identity layer can now legitimately empty out (`identityBlocks`), and an
    // empty one is the correct answer when nothing has been confirmed. But "Rewrite
    // a block and mull stops touching it" under an empty heading is advice about
    // nothing, and the one thing that would fill the file — the answers pane, which
    // is opt-in and was never opened on the machine this was written on — went
    // unmentioned. So the empty state says where a fact can be stated instead.

    func testTheEmptyIdentityHeaderPointsAtTheAnswersPane() {
        let empty = Curator.meHeader(timestamp: "t", isEmpty: true)
        // Named as this reader's own Settings window names it, not as the source
        // writes it: "Your answers" sends a Japanese reader hunting for a control
        // that says セットアップでの回答.
        XCTAssertTrue(empty.contains(VaultText.t("Your answers", "セットアップでの回答")), empty)
        XCTAssertFalse(empty.contains("Rewrite a block"),
                       "there are no blocks to rewrite")
    }

    func testTheFilledIdentityHeaderKeepsTheEditingPromise() {
        let filled = Curator.meHeader(timestamp: "t")
        XCTAssertTrue(filled.contains(VaultText.t("Rewrite a block and mull stops touching it.",
                                                  "ブロックを書き換えれば、mull はそこに触れません。")),
                      filled)
        XCTAssertFalse(filled.contains("Your answers"))
    }
}
