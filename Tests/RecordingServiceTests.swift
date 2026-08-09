import XCTest
@testable import mull

/// The capture layer's first tests.
///
/// It had none, and not by neglect: `RecordingService` called `NSWorkspace`,
/// `AXUIElementCopyAttributeValue`, `NSPasteboard` and `IsSecureEventInputEnabled`
/// inline, so it could not be constructed in a test and could not be made to
/// observe anything. Which meant that every privacy gate mull advertises —
/// excluded apps, secure input, private browsing, no-recording-our-own-output —
/// shipped unverified, in the one layer the whole product rests on (CLAUDE.md
/// §2.1, §8.2).
///
/// `CaptureEnvironment` is the seam. These drive the real policy code against a
/// stub machine.
@MainActor
final class RecordingServiceTests: XCTestCase {

    // MARK: - Doubles

    /// A machine that does whatever the test says.
    private final class StubEnvironment: CaptureEnvironment {
        var frontmostAppName: String? = "Code"
        var frontmostBundleID: String? = "com.microsoft.VSCode"
        var activeWindowTitle: String? = "Selection.swift — Mull"
        var clipboardChangeCount: Int = 0
        var clipboardText: String?
        var clipboardIsMarkedDoNotStore: Bool = false
        var isSecureInputEnabled: Bool = false
        var now: Date = Date(timeIntervalSince1970: 1_700_000_000)

        /// Copy something, the way a person would: the change counter moves.
        func copy(_ text: String) {
            clipboardText = text
            clipboardChangeCount += 1
            clipboardIsMarkedDoNotStore = false
        }

        /// Copy the way a password manager does: same as above, plus the
        /// `org.nspasteboard.ConcealedType` marker on the item.
        func copyConcealed(_ text: String) {
            copy(text)
            clipboardIsMarkedDoNotStore = true
        }
    }

    /// The database, reduced to what capture is allowed to do to it.
    private final class SpyWriter: EventWriting, @unchecked Sendable {
        private(set) var written: [RecordingEvent] = []
        func insertEvent(_ event: RecordingEvent) { written.append(event) }
        var texts: [String] { written.compactMap(\.textContent) }
    }

    private var env: StubEnvironment!
    private var db: SpyWriter!
    private var recorder: RecordingService!

    override func setUp() {
        super.setUp()
        env = StubEnvironment()
        db = SpyWriter()
        recorder = RecordingService(database: db, environment: env)
    }

    // MARK: - The gate that failed in production once already

    /// A password copied out of 1Password must not reach the database. The
    /// clipboard poller was the one channel that did not check the exclusion list,
    /// and a secret landed in the vault because of it.
    func testClipboardFromAnExcludedAppIsNeverRecorded() {
        env.frontmostBundleID = "com.1password.1password"
        env.frontmostAppName = "1Password"
        env.copy("correct horse battery staple")

        recorder.pollClipboard()

        XCTAssertTrue(db.written.isEmpty, "a secret reached the database: \(db.texts)")
    }

    /// Not even held in memory: the gate returns before the pasteboard is read, so
    /// the next legitimate copy must still be seen as new.
    func testAnExcludedCopyDoesNotPoisonTheNextRealOne() {
        env.frontmostBundleID = "com.1password.1password"
        env.copy("a secret")
        recorder.pollClipboard()

        env.frontmostBundleID = "com.microsoft.VSCode"
        env.copy("a real note about pagination")
        recorder.pollClipboard()

        XCTAssertEqual(db.texts, ["a real note about pagination"])
    }

    /// The race the exclusion list above cannot win.
    ///
    /// Exclusion asks which app is frontmost *when the poll ticks*, and it ticks
    /// twice a second. Copy in 1Password, ⌘Tab to the browser, paste — the normal
    /// way anyone uses a password manager — and the frontmost app by the time mull
    /// looks is the browser, so the excluded-app check passes and the password is
    /// recorded. The marker travels with the copy instead of with the frontmost
    /// process, which is the only thing that survives the switch.
    func testAConcealedCopyIsNotRecordedEvenAfterSwitchingAwayFromTheSourceApp() {
        env.frontmostBundleID = "com.1password.1password"
        env.copyConcealed("correct horse battery staple")
        // The user switches before the 0.5s poll comes round.
        env.frontmostBundleID = "com.google.Chrome"
        env.frontmostAppName = "Google Chrome"

        recorder.pollClipboard()

        XCTAssertTrue(db.written.isEmpty, "a secret reached the database: \(db.texts)")
    }

    /// Honoured for any app that sets it, not just the ones on the exclusion list —
    /// that is the point of a convention. A terminal, an SSH agent or a one-off
    /// script that marks a copy concealed is taken at its word.
    func testAConcealedCopyFromAnUnlistedAppIsAlsoDropped() {
        env.frontmostBundleID = "com.apple.Terminal"
        env.copyConcealed("ghp_A1b2C3d4E5f6G7h8I9j0K1L2")

        recorder.pollClipboard()

        XCTAssertTrue(db.written.isEmpty, "a secret reached the database: \(db.texts)")
    }

    /// And it does not poison what comes next: the drop happens before the
    /// pasteboard string is read, so the following ordinary copy still looks new.
    func testAConcealedCopyDoesNotPoisonTheNextRealOne() {
        env.copyConcealed("a secret")
        recorder.pollClipboard()

        env.copy("a real note about pagination")
        recorder.pollClipboard()

        XCTAssertEqual(db.texts, ["a real note about pagination"])
    }

    /// System-wide secure input means a password field somewhere has the keyboard.
    func testNothingIsRecordedWhileSecureInputIsEnabled() {
        env.isSecureInputEnabled = true
        env.copy("whatever is on the pasteboard right now")

        recorder.pollClipboard()

        XCTAssertTrue(db.written.isEmpty)
    }

    /// Private/incognito windows are dropped entirely, not merely unindexed.
    func testClipboardIsNotRecordedFromAPrivateBrowsingWindow() {
        env.activeWindowTitle = "Something (Private Browsing) — Firefox"
        recorder.pollWindowTitle()          // let the recorder learn the title
        env.copy("a link from a private window")

        recorder.pollClipboard()

        XCTAssertTrue(db.texts.contains("a link from a private window") == false,
                      "recorded from a private window: \(db.texts)")
    }

    /// Recording our own output is a feedback loop — a copied me.md block would
    /// come back as "focus topics".
    func testMullsOwnGeneratedOutputIsNotRecorded() {
        env.copy("<!-- mull:block id=\"note\" src=\"agent\" hash=\"abc123\" -->\ngenerated line")

        recorder.pollClipboard()

        XCTAssertTrue(db.written.isEmpty, "mull recorded its own output: \(db.texts)")
    }

    /// Paused means paused. The tap is disabled at the OS level too, but the
    /// pollers must not record either.
    func testNothingIsRecordedWhilePaused() {
        recorder.pauseIndefinitely()
        env.copy("typed while paused")

        recorder.pollClipboard()

        XCTAssertTrue(db.written.isEmpty)
    }

    func testResumeStartsRecordingAgain() {
        recorder.pauseIndefinitely()
        env.copy("during the pause")
        recorder.pollClipboard()

        recorder.resume()
        env.copy("after the pause")
        recorder.pollClipboard()

        XCTAssertEqual(db.texts, ["after the pause"])
    }

    // MARK: - Capture fidelity

    /// The clipboard is capped, not dropped: you cannot re-copy the past
    /// (MAP-ARCHITECTURE 法則①), so the cap has to be generous and it has to
    /// truncate rather than reject.
    func testALongCopyIsTruncatedRatherThanDiscarded() {
        // Varied text, not a repeated character: a long run of one glyph is
        // keyboard mashing and `TestInput` is supposed to reject it — which it
        // does, and which is why the first draft of this test was wrong.
        let long = (0..<5_000).map { "行\($0) 選択層のしきい値を見直す。\n" }.joined()
        XCTAssertGreaterThan(long.count, 40_000)
        env.copy(long)

        recorder.pollClipboard()

        XCTAssertEqual(db.written.count, 1)
        XCTAssertEqual(db.texts.first?.count, 40_000)
    }

    /// Copying the same thing twice is one event, but the change counter moving
    /// without the text changing must not produce a phantom.
    func testTheSameTextCopiedTwiceIsRecordedOnce() {
        env.copy("the same note")
        recorder.pollClipboard()
        env.copy("the same note")
        recorder.pollClipboard()

        XCTAssertEqual(db.written.count, 1)
    }

    /// No copy happened — the counter did not move — so nothing is recorded even
    /// though there is text on the pasteboard.
    func testAnUnchangedPasteboardProducesNothing() {
        env.clipboardText = "something copied before mull started"
        recorder.pollClipboard()

        XCTAssertTrue(db.written.isEmpty)
    }

    /// Capture-time enrichment (#4): the row carries its own entity/type/salience
    /// so the selection layer does not recompute per query.
    func testRecordedEventsCarryTheirCaptureTimeIndex() throws {
        env.activeWindowTitle = "Selection.swift — Mull"
        recorder.pollWindowTitle()
        env.copy("decided to keep the anchor as a prior, not a filter")

        recorder.pollClipboard()

        let event = try XCTUnwrap(db.written.first)
        XCTAssertEqual(event.entity, "Mull")
        XCTAssertNotNil(event.contentType)
        XCTAssertNotNil(event.salience)
    }

    // MARK: - Window titles

    func testAWindowTitleChangeIsRecorded() {
        env.activeWindowTitle = "Selection.swift — Mull"
        recorder.pollWindowTitle()

        XCTAssertEqual(db.texts, ["Selection.swift — Mull"])
    }

    func testAnUnchangedWindowTitleIsNotRecordedTwice() {
        env.activeWindowTitle = "Selection.swift — Mull"
        recorder.pollWindowTitle()
        recorder.pollWindowTitle()

        XCTAssertEqual(db.written.count, 1)
    }

    /// VS Code rewrites its window title on every keystroke in the command
    /// palette. Recording that produces a hundred near-identical rows — which is
    /// exactly the `duplicate-flood` failure the real-log eval found.
    func testIncrementalTypingInAWindowTitleIsNotRecorded() {
        env.activeWindowTitle = "search"
        recorder.pollWindowTitle()
        env.activeWindowTitle = "search fo"
        recorder.pollWindowTitle()
        env.activeWindowTitle = "search for th"
        recorder.pollWindowTitle()

        XCTAssertEqual(db.written.count, 1, "typing was recorded as three titles: \(db.texts)")
    }

    /// A private window's title is remembered so it is not reprocessed, but never
    /// written down.
    func testPrivateBrowsingTitlesAreNotRecorded() {
        env.activeWindowTitle = "Reddit (Private Browsing) — Firefox"
        recorder.pollWindowTitle()

        XCTAssertTrue(db.written.isEmpty)
    }

    func testWindowTitlesFromExcludedAppsAreNotRecorded() {
        env.frontmostBundleID = "com.apple.keychainaccess"
        env.activeWindowTitle = "Keychain Access"

        recorder.pollWindowTitle()

        XCTAssertTrue(db.written.isEmpty)
    }

    /// Exclusion also matches on app name, because a bundle can be renamed and
    /// Xcode debug builds report a different identifier.
    func testExclusionMatchesOnAppNameToo() {
        env.frontmostBundleID = "com.example.unknown"
        env.frontmostAppName = "Mull"
        env.copy("mull's own window contents")

        recorder.pollClipboard()

        XCTAssertTrue(db.written.isEmpty)
    }

    // MARK: - App switching
    //
    // The gap the four tests above could not see. Every channel they cover asks
    // the exclusion list about the *frontmost* app, which is right for a poller
    // and wrong for the app-switch handler: it runs after the switch, and the row
    // it writes describes the app just left. So Settings said the exclusion list
    // covered window titles, and leaving 1Password wrote
    // "1Password: <title> (2m10s)" every time.

    /// Drive the real sequence: the handler records the session for the app being
    /// left, and only then moves the current-app pointer.
    private func leaveApp(toBundleID bundleID: String, named name: String) {
        env.frontmostBundleID = bundleID
        env.frontmostAppName = name
        recorder.recordAppSession()
        recorder.updateCurrentApp()
    }

    func testLeavingAnExcludedAppDoesNotRecordItsTitleOrDuration() {
        env.frontmostBundleID = "com.1password.1password"
        env.frontmostAppName = "1Password"
        env.activeWindowTitle = "1Password — Personal"
        recorder.updateCurrentApp()

        env.now = env.now.addingTimeInterval(130)
        leaveApp(toBundleID: "com.microsoft.VSCode", named: "Code")

        XCTAssertTrue(db.written.isEmpty,
                      "an excluded app's session reached the database: \(db.texts)")
    }

    /// The other end of the same switch: arriving at an excluded app must not
    /// record its window title either.
    func testSwitchingIntoAnExcludedAppDoesNotRecordItsTitle() {
        env.activeWindowTitle = "Selection.swift — Mull"
        recorder.updateCurrentApp()

        env.frontmostBundleID = "com.apple.keychainaccess"
        env.frontmostAppName = "Keychain Access"
        env.activeWindowTitle = "Keychain Access"
        recorder.updateCurrentApp()
        recorder.pollWindowTitle()

        XCTAssertTrue(db.written.isEmpty,
                      "an excluded app's title reached the database: \(db.texts)")
    }

    /// The control. Without this, the two tests above pass just as well against a
    /// gate that has swallowed app sessions entirely.
    func testLeavingAnOrdinaryAppStillRecordsTheSession() {
        env.activeWindowTitle = "Selection.swift — Mull"
        recorder.updateCurrentApp()

        env.now = env.now.addingTimeInterval(130)
        leaveApp(toBundleID: "com.apple.Safari", named: "Safari")

        XCTAssertEqual(db.texts, ["Code: Selection.swift — Mull (2m10s)"])
    }
}
