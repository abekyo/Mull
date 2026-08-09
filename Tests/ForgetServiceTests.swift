import XCTest
@testable import mull

/// Tests for the forget path — time-scoped erasure that reaches past the raw
/// events into everything mull derived from them.
///
/// The failure these guard against is specific and quiet: a forget that deletes
/// `recording_events` and reports success while the summary, the memory and the
/// frozen daily snapshot built from those events all survive. The user believes
/// the window is gone. It isn't. So most of what follows asserts on the DERIVED
/// layers, not on the event count.
final class ForgetServiceTests: XCTestCase {

    private var db: DatabaseService!

    override func setUpWithError() throws {
        db = try DatabaseService.temporary()
        _ = MullDirectory.setup()   // throwaway vault under XCTest — see MullDirectory.root
    }

    // MARK: - Fixtures

    private func at(_ minutesAgo: Double) -> Date {
        Date().addingTimeInterval(-minutesAgo * 60)
    }

    /// The last 30 minutes.
    private var window: DateInterval {
        DateInterval(start: at(30), end: Date())
    }

    @discardableResult
    private func event(_ minutesAgo: Double, _ text: String) -> RecordingEvent {
        let e = RecordingEvent(timestamp: at(minutesAgo), eventType: .clipboard, textContent: text)
        db.insertEvent(e)
        return e
    }

    private func memory(_ name: String, created: Date, updated: Date? = nil) {
        db.insertMemory(MemoryEntry(
            name: name, description: "d-\(name)", memoryType: .user,
            content: "c-\(name)", filePath: "memory/\(name).md",
            createdAt: created, updatedAt: updated ?? created))
    }

    // MARK: - Plan is read-only

    func testPlanCountsOnlyTheWindow() {
        event(10, "inside")
        event(20, "inside too")
        event(90, "outside")

        let plan = ForgetService.plan(interval: window, database: db)
        XCTAssertEqual(plan.events, 2)
        XCTAssertFalse(plan.isEmpty)
    }

    func testPlanTouchesNothing() {
        event(10, "inside")
        _ = ForgetService.plan(interval: window, database: db)
        XCTAssertEqual(db.countEvents(from: at(60), to: Date()), 1,
                       "plan() must be read-only — the dialog is built from it before the user has agreed")
    }

    func testEmptyWindowIsReportedAsEmpty() {
        event(90, "outside")
        XCTAssertTrue(ForgetService.plan(interval: window, database: db).isEmpty)
    }

    // MARK: - Events

    func testForgetRemovesOnlyTheWindow() throws {
        event(10, "inside")
        event(90, "outside")

        let plan = ForgetService.plan(interval: window, database: db)
        _ = try ForgetService.forget(plan, database: db)

        XCTAssertEqual(db.countEvents(from: at(30), to: Date()), 0)
        XCTAssertEqual(db.countEvents(from: at(200), to: at(30)), 1,
                       "an event before the window is not the user's to lose")
    }

    /// The whole point of the feature: deleting the source must not leave the
    /// conclusion. A search that still returns the forgotten text is the bug.
    func testForgottenTextIsNoLongerSearchable() throws {
        event(10, "zzunique-token-in-window")
        XCTAssertFalse(db.searchEvents(query: "zzunique-token-in-window").isEmpty,
                       "precondition: the text is findable before forgetting")

        _ = try ForgetService.forget(ForgetService.plan(interval: window, database: db), database: db)

        XCTAssertTrue(db.searchEvents(query: "zzunique-token-in-window").isEmpty,
                      "forgotten text must be gone from the FTS index, not just from the base table")
    }

    // MARK: - Memories (the derived layer that does not self-heal)

    func testMemoryFormedInsideTheWindowGoes() throws {
        memory("formed-inside", created: at(10))
        memory("formed-before", created: at(600))

        let plan = ForgetService.plan(interval: window, database: db)
        XCTAssertEqual(plan.memories.map(\.name), ["formed-inside"])

        _ = try ForgetService.forget(plan, database: db)
        XCTAssertEqual(db.fetchAllMemories().map(\.name), ["formed-before"])
    }

    /// A memory that predates the window but was revised inside it is a blend
    /// mull cannot unmix. Deleting a month of understanding to erase fifteen
    /// minutes of it would be the wrong trade — but so would staying silent.
    func testRevisedMemoryIsKept() throws {
        memory("long-standing", created: at(6000), updated: at(10))

        let plan = ForgetService.plan(interval: window, database: db)
        XCTAssertTrue(plan.memories.isEmpty, "not formed in the window — must not be deleted")
        XCTAssertEqual(plan.revisedMemories, ["long-standing"])

        _ = try ForgetService.forget(plan, database: db)
        XCTAssertEqual(db.fetchAllMemories().count, 1)
    }

    func testMemoryFileAndIndexEntryGoWithTheRow() throws {
        memory("secret-thing", created: at(10))
        MullDirectory.write("body", to: "memory/secret-thing.md")
        MullDirectory.write("""
        # MEMORY.md

        - [secret-thing](memory/secret-thing.md) — d-secret-thing
        - [keeper](memory/keeper.md) — unrelated
        """, to: "MEMORY.md")

        _ = try ForgetService.forget(ForgetService.plan(interval: window, database: db), database: db)

        XCTAssertFalse(MullDirectory.exists("memory/secret-thing.md"),
                       "the row is gone; the file holding the same text must go too")
        let index = MullDirectory.read("MEMORY.md") ?? ""
        XCTAssertFalse(index.contains("secret-thing"),
                       "MEMORY.md must not keep describing a memory that no longer exists")
        XCTAssertTrue(index.contains("keeper"), "unrelated index entries are left byte-identical")
    }

    // MARK: - Summaries and knowledge

    func testSummaryCoveringTheWindowGoes() throws {
        db.insertSummary(DailySummary(
            date: Calendar.current.startOfDay(for: Date()), content: "today's summary",
            eventCount: 5, processingSeconds: 1, llmProvider: "off", createdAt: Date()))

        let plan = ForgetService.plan(interval: window, database: db)
        XCTAssertEqual(plan.summaries.count, 1)

        _ = try ForgetService.forget(plan, database: db)
        XCTAssertNil(db.fetchSummary(for: Date()))
    }

    func testKnowledgeSourcedInTheWindowGoes() throws {
        db.insertKnowledge(KnowledgeEntry(
            topic: "t", decision: "d", project: "p",
            sourceDate: at(10), createdAt: at(10)))
        db.insertKnowledge(KnowledgeEntry(
            topic: "old", decision: "d", project: "p",
            sourceDate: at(600), createdAt: at(600)))

        let plan = ForgetService.plan(interval: window, database: db)
        XCTAssertEqual(plan.knowledge, 1)

        _ = try ForgetService.forget(plan, database: db)
        XCTAssertEqual(db.fetchAllKnowledge().map(\.topic), ["old"])
    }

    // MARK: - Curated files

    /// A forget at 15:00 must not leave the nightly block describing the window
    /// until the next consolidation runs. This is the case `curate`'s own pruning
    /// cannot reach, and the reason `Curator.retract` exists.
    func testNightlyBlockIsRetractedNotLeftForTomorrow() throws {
        let content = "Yesterday you worked on the thing you want forgotten."
        MullDirectory.write(ContextBlockFile.serialize(header: "H", blocks: [
            ContextBlock(id: "nightly:now", source: .agent, content: content,
                         agentHash: ContextBlock.hash(content))
        ]), to: "now.md")

        event(10, "inside")
        _ = try ForgetService.forget(ForgetService.plan(interval: window, database: db), database: db)

        XCTAssertFalse(MullDirectory.read("now.md")?.contains("want forgotten") ?? false)
    }

    func testEditedBlockIsKept() throws {
        // mull wrote this block, then the user rewrote it — the hash no longer
        // matches, which is how `merge` recognises human text.
        MullDirectory.write(ContextBlockFile.serialize(header: "H", blocks: [
            ContextBlock(id: "nightly:now", source: .agent, content: "my own words",
                         agentHash: ContextBlock.hash("what mull originally wrote"))
        ]), to: "now.md")

        event(10, "inside")
        let result = try ForgetService.forget(
            ForgetService.plan(interval: window, database: db), database: db)

        XCTAssertTrue(MullDirectory.read("now.md")?.contains("my own words") ?? false,
                      "mull deletes its own writing, never the user's")
        XCTAssertTrue(result.retainedBlocks.contains { $0.contains("now.md") },
                      "and it records that it declined, even though no dialog shows it")
    }

    // MARK: - What the user is told
    //
    // This control is pressed rarely and in a hurry. These assert that the
    // message stays one readable sentence — the earlier itemised version was
    // accurate and unreadable, which for a privacy control is the same as broken.

    func testMessageIsOneSentenceWithTheScale() {
        event(10, "inside")
        event(20, "inside too")
        memory("formed-inside", created: at(10))
        db.insertSummary(DailySummary(
            date: Calendar.current.startOfDay(for: Date()), content: "s",
            eventCount: 1, processingSeconds: 1, llmProvider: "off", createdAt: Date()))

        let plan = ForgetService.plan(interval: window, database: db)
        let sentence = plan.sentence(label: "the last 30 minutes")

        XCTAssertTrue(sentence.contains("2 recorded events"), "the user gets the scale…")
        XCTAssertTrue(sentence.contains("the last 30 minutes"), "…and the window, in their words")
        XCTAssertFalse(sentence.contains("•"), "no bullet list")
        XCTAssertFalse(sentence.contains("knowledge"),
                       "internal categories are mull's business, not the user's")
        XCTAssertFalse(sentence.contains("formed-inside"),
                       "naming each memory was detail nobody reads at this moment")
        XCTAssertTrue(sentence.contains("Your own notes and reports are kept"))
        XCTAssertNil(plan.warning, "nothing to interrupt for when everything is local")
    }

    func testEmptyWindowSaysSoPlainly() {
        event(90, "outside")
        let plan = ForgetService.plan(interval: window, database: db)
        XCTAssertEqual(plan.sentence(label: "the last 30 minutes"),
                       "There's nothing recorded in the last 30 minutes.")
    }

    /// The one thing a forget genuinely cannot do — and it has to be said before
    /// the user decides, not reported afterwards.
    func testCloudProviderIsTheOnlyWarning() throws {
        event(10, "inside")
        let plan = ForgetService.plan(interval: window, database: db, cloudProvider: "Anthropic")
        let warning = try XCTUnwrap(plan.warning)
        XCTAssertTrue(warning.contains("Anthropic"))
        XCTAssertTrue(warning.contains("can't take back"),
                      "mull must not imply it can recall what already left the Mac")
    }

    // MARK: - Day arithmetic

    func testDaysInIntervalCoversEveryTouchedDay() {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -2, to: Date())!
        let days = ForgetService.days(in: DateInterval(start: start, end: Date()))
        XCTAssertEqual(days.count, 3, "a two-day-old start touches three calendar days")
        XCTAssertTrue(days.allSatisfy { $0 == cal.startOfDay(for: $0) })
    }

    /// Today's snapshot is rewritten from full.md on the next tick, so deleting
    /// it would be busywork. A past day's is frozen — nothing regenerates it, so
    /// it still holds the window and has to go.
    func testOnlyFrozenSnapshotsAreTaken() throws {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        MullDirectory.write("x", to: ForgetService.snapshotPath(for: yesterday))
        MullDirectory.write("x", to: ForgetService.snapshotPath(for: Date()))

        let plan = ForgetService.plan(
            interval: DateInterval(start: yesterday, end: Date()), database: db)
        XCTAssertEqual(plan.frozenSnapshots, [ForgetService.snapshotPath(for: yesterday)])

        _ = try ForgetService.forget(plan, database: db)
        XCTAssertFalse(MullDirectory.exists(ForgetService.snapshotPath(for: yesterday)))
        XCTAssertTrue(MullDirectory.exists(ForgetService.snapshotPath(for: Date())),
                      "today's regenerates itself — taking it here would be pointless churn")
    }

    // MARK: - Failure is reported, not swallowed
    //
    // The header comment stakes the feature on "a privacy control that reports
    // success it did not achieve is worse than no control at all". These pin
    // the reporting half: what `failureMessage` says, and when it says nothing.

    func testCleanForgetHasNoFailureMessage() throws {
        event(10, "inside")
        let result = try ForgetService.forget(
            ForgetService.plan(interval: window, database: db), database: db)
        XCTAssertNil(result.failureMessage,
                     "a forget that did everything it promised has nothing to confess")
    }

    func testStoppedLayerIsNamedAndRetryIsSuggested() throws {
        var plan = ForgetService.Plan(interval: window)
        plan.failedLayer = "daily summaries"
        let message = try XCTUnwrap(plan.failureMessage)
        XCTAssertTrue(message.contains("daily summaries"),
                      "the user must learn where the forget stopped, not just that it did")
        XCTAssertTrue(message.contains("Try Forget again"))
    }

    func testFileAndScrubFailuresAreToldTogether() throws {
        var plan = ForgetService.Plan(interval: window)
        plan.failedFiles = ["daily/2026/08/2026-08-07.md"]
        plan.scrubFailed = true
        let message = try XCTUnwrap(plan.failureMessage)
        XCTAssertTrue(message.contains("2026-08-07.md"),
                      "the file still holding the window is named, not counted")
        XCTAssertTrue(message.contains("scrubbed"))
    }

    /// The layer error carries its name so AppState can put it in the plan it
    /// hands back — the UI's sentence is built from that field.
    func testLayerErrorNamesTheLayer() {
        let failure = ForgetService.LayerError(
            layer: "recorded events",
            underlying: NSError(domain: "test", code: 1))
        XCTAssertEqual(failure.layer, "recorded events")
    }
}
