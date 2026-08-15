import XCTest
@testable import mull

/// What "Who I am" is allowed to say.
///
/// On 2026-08-15 me.md held four lines and three of them were one day's observation
/// promoted to a standing trait, with the day taken off. The evidence was inside the
/// same database row the whole time: `content` said "today", `description` said
/// "regularly", and me.md renders `description`.
///
/// The fixtures below are those rows, verbatim from the author's machine. They are
/// what the rule was written against, so they are what holds it.
final class IdentityLineTests: XCTestCase {

    /// Local wall-clock days, not epochs. The rule and the printed date both run
    /// through `Calendar.current`, so a fixture pinned to a UTC instant lands on the
    /// wrong side of midnight for any reader east of Greenwich — which is where this
    /// was written, and how this line came to be a comment.
    private func day(_ month: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = month; c.day = d; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    private var now: Date { day(8, 15) }
    private var june10: Date { day(6, 10) }
    private var aug11: Date { day(8, 11) }
    private var aug09: Date { day(8, 9) }

    private func memory(_ name: String, _ description: String, _ content: String,
                        created: Date, updated: Date,
                        type: MemoryEntry.MemoryType = .user) -> MemoryEntry {
        MemoryEntry(name: name, description: description, memoryType: type,
                    content: content, filePath: "memory/\(name).md",
                    createdAt: created, updatedAt: updated)
    }

    // MARK: - The rows that were wrong

    /// "LINE was used extensively **today**" became "Regularly uses LINE for
    /// messaging.", and then sat there for 66 days without recurring.
    func testAnUnconfirmedDayStopsBeingIdentity() {
        let line = memory("Messaging preference",
                          "Regularly uses LINE for messaging.",
                          "LINE was used extensively today (high activity on 10 June 2026).",
                          created: june10, updated: june10)

        XCTAssertTrue(line.isSingleObservation)
        XCTAssertFalse(line.isIdentity(asOf: now),
                       "one day in June is not who somebody is in August")
    }

    /// "**Today** (10 June 2026) shows a pattern" became "Often does heavy video
    /// editing and coding in afternoons."
    func testAPatternSeenOnceIsNotAPattern() {
        let line = memory("Work rhythm: afternoons for editing",
                          "Often does heavy video editing and coding in afternoons.",
                          "Today (10 June 2026) shows a pattern: concentrated video editing…",
                          created: june10, updated: june10)

        XCTAssertFalse(line.isIdentity(asOf: now))
    }

    // MARK: - The rows that were right

    /// Written in June, seen again in August. Re-observation is the whole difference
    /// between an observation and a trait, so this one stands.
    func testAReObservedMemoryStands() {
        let line = memory("AI assistant preference",
                          "Prefers Claude for AI assistance; used frequently (updated 11 Aug 2026)",
                          "Used Claude repeatedly today for coding help and drafting notes.",
                          created: june10, updated: aug11)

        XCTAssertFalse(line.isSingleObservation)
        XCTAssertTrue(line.isIdentity(asOf: now))
    }

    /// A single-day observation from this week is fair to print. The rule is about
    /// age, not about suspicion — six days ago is still a reasonable reading of what
    /// somebody does.
    func testARecentSingleObservationStands() {
        let line = memory("通知が鳴りすぎてうざい",
                          "通知が多すぎて操作の邪魔になると感じた（2026-08-09）",
                          "日中に通知が頻繁に発生して作業の邪魔になった。",
                          created: aug09, updated: aug09)

        XCTAssertTrue(line.isSingleObservation)
        XCTAssertTrue(line.isIdentity(asOf: now))
    }

    // MARK: - Every line says when it was seen

    func testTheLineCarriesTheDayItWasLastSeen() {
        let line = memory("Messaging preference", "Regularly uses LINE for messaging.",
                          "…", created: june10, updated: june10)

        XCTAssertEqual(line.identityLine(dateFormatter: Curator.observationDayFormatter),
                       "- Regularly uses LINE for messaging. (2026-06-10)")
    }

    /// The nightly model writes a date itself about half the time. Two dates on one
    /// line is worse than none.
    func testADateAlreadyInTheTextIsNotDoubled() {
        let english = memory("AI assistant preference",
                             "Prefers Claude for AI assistance; used frequently (updated 11 Aug 2026)",
                             "…", created: june10, updated: aug11)
        let japanese = memory("通知", "通知が多すぎて操作の邪魔になると感じた（2026-08-09）",
                              "…", created: aug09, updated: aug09)

        let day = Curator.observationDayFormatter
        XCTAssertEqual(english.identityLine(dateFormatter: day),
                       "- Prefers Claude for AI assistance; used frequently (updated 11 Aug 2026)")
        XCTAssertEqual(japanese.identityLine(dateFormatter: day),
                       "- 通知が多すぎて操作の邪魔になると感じた（2026-08-09）")
    }

    // MARK: - The whole file, as it stood

    /// All four lines together: the two that were evidence survive, the two that
    /// were generalisations do not.
    func testTheFileAsItStoodOnTheDayThisWasWritten() {
        let all = [
            memory("AI assistant preference", "Prefers Claude for AI assistance; used frequently (updated 11 Aug 2026)", "…", created: june10, updated: aug11),
            memory("Messaging preference", "Regularly uses LINE for messaging.", "…", created: june10, updated: june10),
            memory("Work rhythm", "Often does heavy video editing and coding in afternoons.", "…", created: june10, updated: june10),
            memory("通知", "通知が多すぎて操作の邪魔になると感じた（2026-08-09）", "…", created: aug09, updated: aug09),
        ]

        let kept = all.filter { $0.isIdentity(asOf: now) }.map(\.name)
        XCTAssertEqual(kept, ["AI assistant preference", "通知"])
    }

    // MARK: - Who is allowed to be in the identity layer at all
    //
    // `isIdentity` answers "is this still true of them". These answer the question
    // underneath it: is this the kind of thing "Who I am" is for.

    /// A `feedback` memory is how somebody works, which is a rule — and CLAUDE.md
    /// §0.1 says rules do not come out of observation. The nightly pass derives
    /// these by watching one day, so a feedback line under "Who I am" is a rule mull
    /// wrote about the user and then served to every agent as their own.
    ///
    /// The fixture is the row that was doing it: an afternoon's irritation with
    /// notifications, printed as a standing fact about a person.
    func testFeedbackIsNotIdentity() {
        let feedback = memory("通知が鳴りすぎてうざい",
                              "通知が多すぎて操作の邪魔になると感じた（2026-08-09）",
                              "日中に通知が頻繁に発生して作業の邪魔になった。",
                              created: aug09, updated: aug09, type: .feedback)

        XCTAssertTrue(feedback.isIdentity(asOf: now), "still recent — the age rule keeps it")
        XCTAssertTrue(Curator.identityBlocks(from: [feedback], now: now).isEmpty,
                      "…and the type rule still keeps it out of me.md")
    }

    /// project/reference memories have their own homes in now.md and full.md.
    func testOnlyUserMemoriesReachTheFile() {
        let mixed = [
            memory("AI assistant preference", "Prefers Claude; used frequently (11 Aug 2026)", "…",
                   created: june10, updated: aug11),
            memory("Formiq data-mirror plan", "Plan to mirror Formiq data using a Worker", "…",
                   created: aug11, updated: aug11, type: .project),
            memory("Obsidian food log", "Uses an Obsidian vault for meal logging", "…",
                   created: aug11, updated: aug11, type: .reference),
            memory("通知", "通知が多すぎて…", "…", created: aug09, updated: aug09, type: .feedback),
        ]

        XCTAssertEqual(Curator.identityBlocks(from: mixed, now: now).map(\.id),
                       ["mem:ai-assistant-preference"])
    }

    /// One rule, not two copies of one. Both passes that write me.md call this, and
    /// they prune each other's stale `mem:` blocks — so a rule held privately by
    /// either one shows up as a block that appears and vanishes every minute. The
    /// two copies had already drifted (feedback capped at 5 in the nightly pass and
    /// 3 in the 60s one; the "Working on:" gate in one and not the other).
    func testAnImplausibleProjectIsSkipped() {
        let junk = memory("Working on", "Working on: ", "…", created: aug11, updated: aug11)
        XCTAssertTrue(Curator.identityBlocks(from: [junk], now: now).isEmpty)
    }

    /// The whole point of the layer: what survives says when it was last seen.
    func testTheBlockCarriesTheRenderedLine() {
        let line = memory("Messaging preference", "Regularly uses LINE for messaging.", "…",
                          created: june10, updated: june10)

        // Ten days after it was written it is still standing, and dated.
        let blocks = Curator.identityBlocks(from: [line], now: day(6, 20))
        XCTAssertEqual(blocks.map(\.content), ["- Regularly uses LINE for messaging. (2026-06-10)"])
        XCTAssertEqual(blocks.map(\.source), [.agent])
    }
}
