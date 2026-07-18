import XCTest
@testable import mull

/// Locks what a cold read is allowed to put on the clipboard.
///
/// `ColdReading.contextBlock()` exists so onboarding's last screen has something
/// true to hand an AI on a fresh install, where the recorded history is empty by
/// definition. That makes it the first thing mull ever says about the user to a
/// third party, and it is assembled from the most sensitive material the app
/// touches — the pasteboard, the window titles, the calendar. The rules below are
/// the ones that keep it defensible:
///
///   - the clipboard never appears, in any form;
///   - a calendar mull was not allowed to read produces silence, never a claim;
///   - the blind-spot sentences written for the onboarding screen ("mull can't
///     read your calendar") stay on that screen and out of the payload.
///
/// None of these tests construct `ColdReadService` — reading the live machine is
/// what the service does, and the value it returns is what needs pinning down.
final class ColdReadContextTests: XCTestCase {

    /// A reading with everything present unless overridden, so each test can state
    /// only the field it is about.
    private func reading(
        facts: [String] = ["Xcode is open right now."],
        runningApps: [String] = ["Xcode", "Safari"],
        frontApp: String = "Xcode",
        frontWindow: String? = "ContextComposer.swift — Mull",
        schedule: [String] = ["15:00 FX review"],
        calendarAccess: ColdReading.CalendarAccess = .granted
    ) -> ColdReading {
        ColdReading(facts: facts,
                    runningApps: runningApps,
                    frontApp: frontApp,
                    frontWindow: frontWindow,
                    schedule: schedule,
                    calendarAccess: calendarAccess)
    }

    // MARK: - What it says

    func testBlockNamesTheOpenAppsFrontWindowAndSchedule() {
        let block = reading().contextBlock()

        XCTAssertTrue(block.contains("Safari, Xcode"), "apps are listed, sorted: \(block)")
        XCTAssertTrue(block.contains("ContextComposer.swift — Mull"), "front window is named: \(block)")
        XCTAssertTrue(block.contains("15:00 FX review"), "schedule is named: \(block)")
    }

    /// The block is handed to an AI with no idea where it came from, so it has to
    /// say that this is a live read and not a recorded day.
    func testBlockSaysNothingHasBeenRecordedYet() {
        XCTAssertTrue(reading().contextBlock().lowercased().contains("not recorded"),
                      "the block states its own provenance")
    }

    // MARK: - What it must never say

    /// The pasteboard is reported to the *user* by shape ("there is code on your
    /// clipboard"). Putting even that in a payload bound for someone else's server
    /// would be mull volunteering the contents of a buffer nobody agreed to send.
    func testClipboardNeverReachesThePayload() {
        let withClipboard = reading(facts: [
            "Xcode is open right now.",
            "There is code on your clipboard.",
            "There is something on your clipboard. mull won't repeat it.",
        ])
        let block = withClipboard.contextBlock()

        XCTAssertFalse(block.lowercased().contains("clipboard"),
                       "no clipboard line, of any shape: \(block)")
    }

    /// A permission mull hasn't been granted is a fact about mull. Pasted into a
    /// chat it becomes the AI's first impression of the user, and it is noise.
    func testBlindSpotSentencesStayOutOfThePayload() {
        let blind = reading(
            facts: ["mull hasn't been given calendar access yet, so it can't see your schedule."],
            schedule: [],
            calendarAccess: .unavailable
        )
        let block = blind.contextBlock()

        XCTAssertFalse(block.contains("hasn't been given"), "blind spots are not payload: \(block)")
        XCTAssertFalse(block.lowercased().contains("calendar"), "no calendar claim at all: \(block)")
    }

    /// An unknown day is not an empty day. Without read access the schedule line is
    /// absent — mull does not get to say the day is clear, and does not get to
    /// print a schedule it may have half-read before its budget expired.
    func testScheduleRequiresGrantedAccess() {
        for access in [ColdReading.CalendarAccess.unavailable, .unknown] {
            let block = reading(calendarAccess: access).contextBlock()
            XCTAssertFalse(block.contains("15:00 FX review"),
                           "schedule withheld when access is \(access): \(block)")
        }
    }

    // MARK: - Bounds and emptiness

    /// The unbounded app list is a dozen menu-bar utilities that say nothing about
    /// the work. It is capped, and the cap is disclosed rather than hidden.
    func testAppListIsCappedAndSaysSo() {
        let many = (1...12).map { "App\($0)" }
        let block = reading(runningApps: many).contextBlock()

        XCTAssertTrue(block.contains("and 4 more"), "the remainder is disclosed: \(block)")
        XCTAssertFalse(block.contains("App9"), "sorted order caps at the first 8: \(block)")
    }

    /// Nothing observable means no block — an empty heading under a promise reads
    /// as a bug, and `previewText` relies on "" to fall through to the honest
    /// empty message.
    func testNothingObservableProducesNoBlock() {
        let nothing = reading(facts: ["mull can't read your calendar — that permission is off."],
                              runningApps: [],
                              frontApp: "",
                              frontWindow: nil,
                              schedule: [],
                              calendarAccess: .unavailable)
        XCTAssertEqual(nothing.contextBlock(), "")
    }

    /// A front window with no owning app name would render as `"…" in ` — the
    /// timed-out read is exactly this shape.
    func testFrontWindowNeedsItsAppToBeNamed() {
        let block = reading(frontApp: "", frontWindow: "Some window").contextBlock()
        XCTAssertFalse(block.contains("Some window"), "half a fact is not a fact: \(block)")
    }

    // MARK: - How onboarding assembles the preview

    /// The recorded context is the real thing and leads; the live read is appended,
    /// never substituted, so a resumed setup keeps both.
    func testPreviewKeepsRecordedContextAndAppendsTheLiveRead() {
        let preview = OnboardingView.previewText(recorded: "# Who I am\n\n- Role: Founder",
                                                 reading: reading())

        XCTAssertTrue(preview.hasPrefix("# Who I am"), "recorded context leads")
        XCTAssertTrue(preview.contains("On this Mac right now"), "live read is appended")
    }

    /// The first-run case: nothing recorded, so the live read is the whole payload
    /// and still has to arrive framed for whoever it is pasted to.
    func testPreviewFramesTheLiveReadWhenNothingIsRecorded() {
        let preview = OnboardingView.previewText(recorded: "", reading: reading())

        XCTAssertTrue(preview.hasPrefix(ContextComposer.preamble), "the block explains itself")
        XCTAssertTrue(preview.contains("On this Mac right now"))
    }

    /// Both halves empty is the one case where the screen's "nothing to hand over
    /// yet" message is the truth — and where the copy button must stay disabled.
    func testPreviewIsEmptyOnlyWhenBothHalvesAre() {
        XCTAssertEqual(OnboardingView.previewText(recorded: "", reading: nil), "")

        let blank = reading(runningApps: [], frontWindow: nil, schedule: [], calendarAccess: .unknown)
        XCTAssertEqual(OnboardingView.previewText(recorded: "", reading: blank), "")
    }
}
