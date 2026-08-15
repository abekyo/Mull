import XCTest
@testable import mull

/// The instructions that decide what me.md is allowed to say.
///
/// `MemoryEntry.isIdentity` (see `IdentityLineTests`) stops an unconfirmed
/// single-day observation standing as identity. That is the enforcement, and it
/// works whatever words the model chose. This file is about the other half: the
/// nightly prompt used to *ask* for the bad output — "Create new memories for …
/// working patterns" — and a pattern from one day is a generalisation with no
/// evidence behind it. That is where "Often does heavy video editing and coding in
/// afternoons." came from, on the strength of 10 June 2026 and nothing else.
///
/// The pairing matters: mull counts the days, and only the model can recognise that
/// today is the same thing as last Tuesday. Take the Confirm rule out and nothing is
/// ever confirmed, so everything expires and me.md empties.
final class ConsolidationPromptTests: XCTestCase {

    private var db: DatabaseService!
    private var engine: MullEngine!

    override func setUpWithError() throws {
        db = try DatabaseService.temporary()
        engine = MullEngine(database: db)
    }

    private func day(_ month: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = month; c.day = d; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    private var emptyDay: GatheredData {
        GatheredData(events: [], morning: [], afternoon: [], evening: [], appGroups: [:],
                     windowStart: day(8, 14), windowEnd: day(8, 15))
    }

    private func memory(_ name: String, _ description: String,
                        created: Date, updated: Date) -> MemoryEntry {
        MemoryEntry(name: name, description: description, memoryType: .user,
                    content: "…", filePath: "memory/\(name).md",
                    createdAt: created, updatedAt: updated)
    }

    // MARK: - What the prompt asks for

    /// The model is told it is looking at one day, and told what that forbids.
    func testItRefusesToAskForAPatternFromOneDay() {
        let prompt = engine.buildConsolidationPrompt(data: emptyDay, memories: [])

        XCTAssertTrue(prompt.contains("Write what you observed, not what the person is"), prompt)
        XCTAssertTrue(prompt.contains("cannot see the others"))
        for adverb in ["usually", "often", "regularly", "prefers", "tends to"] {
            XCTAssertTrue(prompt.contains("*\(adverb)*"),
                          "the word the model reaches for should be named: \(adverb)")
        }
    }

    /// The rule mull's own counting depends on. Without it every memory stays a
    /// single observation, `isIdentity` expires all of them, and me.md goes empty.
    func testItAsksForARepeatToBeConfirmed() {
        let prompt = engine.buildConsolidationPrompt(data: emptyDay, memories: [])

        XCTAssertTrue(prompt.contains("**Confirm**"), prompt)
        XCTAssertTrue(prompt.contains("even with nothing new to add"))
        XCTAssertTrue(prompt.contains("counting is mull's job"))
    }

    /// The other half of the same failure. The rules above fix *when* a memory may
    /// be written; this one is about whether it was worth writing at all. What
    /// survived the age rule on the day this was added was "Prefers Claude for AI
    /// assistance; used frequently" — true, dated, confirmed, and read by Claude,
    /// which learns nothing from being told the user talks to it.
    func testItRefusesToAskForWhatTheAgentCanSeeForItself() {
        let prompt = engine.buildConsolidationPrompt(data: emptyDay, memories: [])

        XCTAssertTrue(prompt.contains("Only write down what an agent could not find out for itself"),
                      prompt)
        XCTAssertTrue(prompt.contains("what an agent would do differently for"))
        XCTAssertTrue(prompt.contains("If the answer is nothing, do not create it"))
    }

    /// Where each type lands. `user` is the only one that stands as identity, and a
    /// model that does not know which drawer it is filling puts a working preference
    /// in the one labelled "Who I am" — see `IdentityLineTests.testFeedbackIsNotIdentity`.
    func testItSaysWhichTypeReachesTheIdentityLayer() {
        let prompt = engine.buildConsolidationPrompt(data: emptyDay, memories: [])
        XCTAssertTrue(prompt.contains("Only \"user\" stands"), prompt)
        XCTAssertTrue(prompt.contains("under \"Who I am\" in me.md"))
    }

    /// The test above governs what gets written. On its own it leaves everything
    /// already in the table standing forever: a re-observed memory never expires
    /// (`isIdentity` returns true for it by definition), so "Prefers Claude for AI
    /// assistance" would outlive every rule written to prevent it. Phase 4 puts the
    /// existing rows through the same question.
    func testPruneAppliesTheSameTestToWhatIsAlreadyThere() {
        let prompt = engine.buildConsolidationPrompt(data: emptyDay, memories: [])
        XCTAssertTrue(prompt.contains("Would you create it today?"), prompt)
        XCTAssertTrue(prompt.contains("does not keep its place by having been"))
    }

    /// The old wording. It asked for exactly the line that had to be deleted.
    func testItNoLongerAsksForWorkingPatterns() {
        let prompt = engine.buildConsolidationPrompt(data: emptyDay, memories: [])
        XCTAssertFalse(prompt.contains("working patterns"), prompt)
    }

    // MARK: - What the model is shown

    /// A model cannot recognise "again" without being told when "before" was.
    func testExistingMemoriesCarryWhenTheyWereLastSeen() {
        let prompt = engine.buildConsolidationPrompt(data: emptyDay, memories: [
            memory("Messaging preference", "Used LINE heavily on 10 June 2026",
                   created: day(6, 10), updated: day(6, 10)),
            memory("AI assistant preference", "Used Claude for coding help",
                   created: day(6, 10), updated: day(8, 11)),
        ])

        XCTAssertTrue(prompt.contains("(seen once, on 2026-06-10)"), prompt)
        XCTAssertTrue(prompt.contains("(first seen 2026-06-10, last confirmed 2026-08-11)"), prompt)
    }

    /// Descriptions are the line that gets read, and a description saying "recently"
    /// is unreadable a month later.
    func testTheDateRuleReachesTheDescription() {
        let prompt = engine.buildConsolidationPrompt(data: emptyDay, memories: [])
        XCTAssertTrue(prompt.contains("In the description as well as the content"), prompt)
    }
}
