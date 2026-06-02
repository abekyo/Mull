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
}
