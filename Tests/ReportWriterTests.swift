import XCTest
@testable import mull

/// Locks the fidelity loop — the one claim mull's positioning rests on.
///
/// CLAUDE.md sells the understudy on a loop: it drafts in your voice, you edit, your
/// edits become tomorrow's voice samples, and it converges on sounding like you. An
/// audit found the loop did not exist as described. Two defects, both covered here:
///
/// A. "Keep this" wrote the model's *unedited* draft into `reports/`, which
///    `voiceSamples()` reads as the purest sample of how the USER writes. Approve
///    three days running and every voice slot held the model imitating itself.
/// B. Nothing anywhere computed an edit distance, so "fidelity" was a word in
///    comments rather than a measurement.
///
/// Safety: `MullDirectory.root` redirects to a throwaway temp vault under XCTest and
/// `DatabaseService.temporary()` is a throwaway DB, so the user's real reports and
/// recorded history are never opened or touched.
final class ReportWriterTests: XCTestCase {

    private var db: DatabaseService!
    private var writer: ReportWriter!

    /// A fixed historical day, so nothing here depends on the wall clock.
    private let day = DateComponents(calendar: .current, year: 2026, month: 3, day: 10, hour: 12).date!

    override func setUp() {
        super.setUp()
        // The suite runs inside the real app as its test host. A failed
        // expectation that runs on into `series[0]` or a force-unwrap does not
        // fail one test — it SIGTRAPs the whole host and takes every remaining
        // suite down with it (seen live: unattended runs where read-after-write
        // returned nil crashed the app twice per session). Stop at the first
        // broken expectation instead.
        continueAfterFailure = false
        MullDirectory.setup()
        // The test vault is shared by every test in the process. Reports and their
        // hidden sidecars are wiped between cases so one test's approval cannot be
        // read as another's voice sample.
        for folder in ["reports", "notes"] {
            try? FileManager.default.removeItem(at: MullDirectory.url(for: folder))
        }
        db = try! DatabaseService.temporary()
        writer = ReportWriter(database: db, defaults: freshDefaults())
    }

    override func tearDown() {
        for folder in ["reports", "notes"] {
            try? FileManager.default.removeItem(at: MullDirectory.url(for: folder))
        }
        writer = nil
        db = nil
        super.tearDown()
    }

    /// An isolated defaults domain — the language decision is deliberately sticky, so
    /// a test that inherited `.standard` would inherit the developer's own last report.
    private func freshDefaults() -> UserDefaults {
        let name = "mull.tests.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    /// A generous budget: the default 3500 chars is a prompt budget, and these tests
    /// assert on presence, not on which sample won a squeeze.
    private func samples() -> String { writer.voiceSamples(maxChars: 200_000).text }

    // MARK: - Defect A: the approve button must not poison the voice corpus

    func testApprovingADraftUneditedDoesNotMakeItAVoiceSample() {
        let machineProse = "MACHINEMARKER I orchestrated a comprehensive refactor of the parsing subsystem today."
        writer.cacheDraft(.init(text: machineProse, sources: []), for: day)

        XCTAssertTrue(writer.save(machineProse, for: day))

        let record = writer.provenance(for: day)
        XCTAssertEqual(record?.hadDraft, true)
        XCTAssertEqual(record?.edited, false, "Text kept verbatim is the model's, not the user's")
        XCTAssertFalse(samples().contains("MACHINEMARKER"),
                       "The model's own unedited prose fed back in as a sample of the user's voice")
    }

    func testApprovingAnEditedDraftDoesMakeItAVoiceSample() {
        writer.cacheDraft(.init(text: "I orchestrated a comprehensive refactor today.", sources: []), for: day)

        XCTAssertTrue(writer.save("HUMANMARKER fixed the parser. still slow.", for: day))

        XCTAssertEqual(writer.provenance(for: day)?.edited, true)
        XCTAssertTrue(samples().contains("HUMANMARKER"),
                      "The user's rewrite is the whole point of the loop and must reach the prompt")
    }

    func testReflowingWhitespaceIsNotAnEdit() {
        let draft = "I fixed the parser today. It is still slow."
        writer.cacheDraft(.init(text: draft, sources: []), for: day)

        // A hard-wrap is not a change of voice. Counting it as one would readmit
        // untouched machine prose to the corpus through the back door.
        XCTAssertTrue(writer.save("I fixed the parser today.\n\nIt is still slow.", for: day))

        XCTAssertEqual(writer.provenance(for: day)?.edited, false)
        XCTAssertEqual(writer.provenance(for: day)?.drift, 0)
    }

    func testAReportWrittenWithNoDraftIsAlwaysTheUsersOwn() {
        XCTAssertTrue(writer.save("OWNMARKER wrote this myself, no model involved.", for: day))

        let record = writer.provenance(for: day)
        XCTAssertEqual(record?.hadDraft, false)
        XCTAssertNil(record?.drift, "There is no draft to measure divergence from")
        XCTAssertTrue(samples().contains("OWNMARKER"))
    }

    /// Editing an approved report in the Files editor never passes through `save()`.
    /// Without the digest check the report would stay branded machine prose forever and
    /// the user's real writing would be locked out of their own voice loop.
    func testHandEditingAnApprovedReportOnDiskReadmitsItAsAVoiceSample() {
        let machineProse = "MACHINEMARKER a comprehensive refactor of the parsing subsystem."
        writer.cacheDraft(.init(text: machineProse, sources: []), for: day)
        XCTAssertTrue(writer.save(machineProse, for: day))
        XCTAssertFalse(samples().contains("MACHINEMARKER"))

        MullDirectory.write("LATERMARKER fixed the parser. still slow.", to: ReportWriter.path(for: day))

        XCTAssertTrue(samples().contains("LATERMARKER"))
    }

    /// The filter runs before the limit, not after. A user who kept three drafts
    /// verbatim still has a month of edited reports behind them, and taking the newest
    /// three and *then* discarding the machine ones would leave them with no voice.
    func testMachineApprovalsDoNotCrowdOutOlderHumanReports() {
        let cal = Calendar.current
        let older = cal.date(byAdding: .day, value: -5, to: day)!
        XCTAssertTrue(writer.save("HUMANMARKER shipped the lexer. tired.", for: older))

        for offset in 0..<3 {
            let d = cal.date(byAdding: .day, value: -offset, to: day)!
            let prose = "MACHINEMARKER\(offset) I orchestrated a comprehensive refactor."
            writer.cacheDraft(.init(text: prose, sources: []), for: d)
            XCTAssertTrue(writer.save(prose, for: d))
        }

        let text = samples()
        XCTAssertTrue(text.contains("HUMANMARKER"))
        XCTAssertFalse(text.contains("MACHINEMARKER"))
    }

    /// A discarded report is no longer on disk, so the trend must stop quoting it.
    func testDiscardingAKeptReportRemovesItsMeasurement() {
        writer.cacheDraft(.init(text: "a draft", sources: []), for: day)
        XCTAssertTrue(writer.save("my own words entirely", for: day))
        XCTAssertNotNil(writer.provenance(for: day))

        writer.discardSaved(for: day)

        XCTAssertNil(writer.provenance(for: day))
        XCTAssertTrue(writer.fidelitySeries().isEmpty)
    }

    // MARK: - Defect B: fidelity is a number now

    func testIdenticalTextHasZeroDistance() {
        XCTAssertEqual(EditDistance.normalized("I fixed the parser today.",
                                               "I fixed the parser today."), 0, accuracy: 0.0001)
    }

    func testFullyRewrittenTextIsNearlyOne() {
        // Disjoint alphabets: nothing can be preserved, so every character must move.
        XCTAssertEqual(EditDistance.normalized("aaaaaaaaaaaa", "bbbbbbbbbbbb"), 1, accuracy: 0.0001)
        XCTAssertGreaterThan(EditDistance.normalized("I fixed the parser today and it works",
                                                     "今日はレクサーを書き直した。まだ遅い。"), 0.9)
    }

    func testPartialEditLandsBetween() {
        let d = EditDistance.normalized("I fixed the parser today. It is still slow.",
                                        "I fixed the parser today. It is still fast.")
        XCTAssertGreaterThan(d, 0)
        XCTAssertLessThan(d, 0.2, "One word changed out of nine is a small edit, not a rewrite")
    }

    func testDistanceIsBoundedOnPathologicalInput() {
        // 400k characters would be 1.6e11 cell updates unbounded. The prefix bound
        // makes this a few milliseconds; if this test ever hangs, the bound is gone.
        let a = String(repeating: "a", count: 400_000)
        let b = String(repeating: "b", count: 400_000)
        XCTAssertEqual(EditDistance.normalized(a, b), 1, accuracy: 0.0001)
    }

    func testDriftIsPersistedAndTheSeriesIsChronological() {
        let cal = Calendar.current
        for (offset, kept) in [(2, "totally different words here entirely"),
                               (1, "I fixed the parser today. It is still slowish."),
                               (0, "I fixed the parser today. It is still slow.")] {
            let d = cal.date(byAdding: .day, value: -offset, to: day)!
            writer.cacheDraft(.init(text: "I fixed the parser today. It is still slow.", sources: []), for: d)
            XCTAssertTrue(writer.save(kept, for: d))
        }

        let series = writer.fidelitySeries()
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series.map(\.day), series.map(\.day).sorted(), "Oldest first")
        // The understudy converging: each day the user changed less than the day before.
        XCTAssertGreaterThan(series[0].drift, series[1].drift)
        XCTAssertGreaterThan(series[1].drift, series[2].drift)
        XCTAssertEqual(series[2].drift, 0, accuracy: 0.0001)
    }

    func testHandWrittenDaysAreAbsentFromTheSeries() {
        // No draft existed, so there is nothing to have diverged from. Scoring it 1.0
        // would read as the understudy getting worse on a day it never wrote.
        XCTAssertTrue(writer.save("wrote this myself", for: day))
        XCTAssertTrue(writer.fidelitySeries().isEmpty)
    }

    func testFidelityNoteIsSilentUntilSomethingIsMeasured() throws {
        XCTAssertNil(writer.fidelityNote(for: day))

        writer.cacheDraft(.init(text: "I fixed the parser today.", sources: []), for: day)
        XCTAssertTrue(writer.save("I fixed the parser today.", for: day))

        let note = try XCTUnwrap(writer.fidelityNote(for: day))
        XCTAssertTrue(note.contains("0%"), "Kept verbatim means nothing was changed")
    }

    // MARK: - Which language the report is written in

    // What used to be here: seven tests over a CJK-ratio sampler with a persisted
    // previous answer and a 15–35% deadband — first-look threshold, borderline
    // stability, a clear move, stickiness across calls, empty samples, emoji
    // scalar counting. Every one of them was pinning the *stability* of a guess
    // ("how much Japanese is in this person's writing?"). The guess is gone: the
    // reader states their language in Settings › General and `UserLanguage`
    // answers. A stated setting has no threshold to sit on and no previous value
    // to drift from, so there is nothing left for a deadband to hold — which is
    // why the tests below are about *obeying* rather than about *not wobbling*.

    private func withVaultLanguage(_ p: UserLanguage.Preference, _ body: () -> Void) {
        let saved = UserDefaults.standard.string(forKey: UserLanguage.preferenceKey)
        defer { UserDefaults.standard.set(saved, forKey: UserLanguage.preferenceKey) }
        UserDefaults.standard.set(p.rawValue, forKey: UserLanguage.preferenceKey)
        body()
    }

    private func text(cjkRatio: Double, length: Int = 400) -> String {
        let cjk = Int(Double(length) * cjkRatio)
        return String(repeating: "あ", count: cjk) + String(repeating: "a", count: length - cjk)
    }

    func testTheSettingDecidesTheLanguage() {
        withVaultLanguage(.japanese) {
            XCTAssertEqual(writer.dominantLanguage(of: ""), "Japanese")
        }
        withVaultLanguage(.english) {
            XCTAssertEqual(writer.dominantLanguage(of: ""), "English")
        }
    }

    /// The whole point of the change: writing that reads the other way must not
    /// move the report. Someone whose notes are full of English identifiers still
    /// gets a Japanese report if that is what they asked for.
    func testTheSamplesCannotOverrideTheSetting() {
        withVaultLanguage(.japanese) {
            XCTAssertEqual(writer.dominantLanguage(of: text(cjkRatio: 0.0)), "Japanese",
                           "All-ASCII samples must not unseat a stated Japanese")
        }
        withVaultLanguage(.english) {
            XCTAssertEqual(writer.dominantLanguage(of: text(cjkRatio: 1.0)), "English",
                           "All-CJK samples must not unseat a stated English")
        }
    }

    /// No wobble is possible, because nothing is being measured. This is the
    /// property the deadband existed to approximate.
    func testTheAnswerIsStableAcrossBorderlineSamples() {
        withVaultLanguage(.japanese) {
            for ratio in [0.24, 0.26, 0.23, 0.27, 0.25, 0.22, 0.28] {
                XCTAssertEqual(writer.dominantLanguage(of: text(cjkRatio: ratio)), "Japanese")
            }
        }
    }

    /// `.system` follows macOS, exactly as `UserLanguage` resolves it everywhere else.
    func testSystemFollowsTheMachine() {
        withVaultLanguage(.system) {
            XCTAssertEqual(writer.dominantLanguage(of: text(cjkRatio: 0.9)),
                           UserLanguage.systemIsJapanese ? "Japanese" : "English")
        }
    }
}
