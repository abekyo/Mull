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
}
