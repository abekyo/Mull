import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Recording service — captures EVERYTHING. No filtering.
///
/// Strategy: Record all signals, let AI sort it out.
///
///   1. All keystrokes (CGEvent tap) — romaji, CJK, code, typos, everything
///   2. Clipboard changes — every copy/paste
///   3. Window titles — every file/page/tab change
///   4. App switches + session duration
///
/// No romaji filter. No "is this meaningful?" check. No heuristics.
/// AI is better at understanding messy data than we are at cleaning it.
///
/// **Main-actor isolated.** Every field below — the keystroke buffer, the current
/// app pointer, the clipboard change counter, the browser URL cache — is touched
/// by five timers, an NSWorkspace notification, and a CGEvent tap callback. That
/// they all happen to land on the main run loop was true, documented in three
/// places, and enforced by nothing; one `DispatchQueue.global` in a future caller
/// would have corrupted the buffer silently. `@MainActor` makes the compiler
/// check what the comments were asserting.
///
/// The one deliberate exception is the AppleScript call in the browser-URL path,
/// which runs on `browserQueue` and hands its result back to the main actor.
@MainActor
final class RecordingService {

    private let database: EventWriting
    /// The machine, behind a protocol so the capture rules can be tested without
    /// one. See CaptureEnvironment — every privacy gate below used to be
    /// unverifiable because these calls were inline.
    private let environment: CaptureEnvironment
    private(set) var isRunning = false
    private var isPaused = false

    /// Called on health check when recording capability changes.
    /// `true` = fully operational, `false` = keystroke capture lost (permissions revoked or tap dead).
    var onHealthStatusChanged: ((Bool) -> Void)?

    // Observers & timers
    private var appSwitchObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var clipboardTimer: Timer?
    private var windowTitleTimer: Timer?
    private var windowBodyTimer: Timer?
    private var browserURLTimer: Timer?
    private var lastWindowBody = ""
    private var healthCheckTimer: Timer?

    // Keystroke capture
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keystrokeBuffer: String = ""
    private var keystrokeFlushTimer: Timer?

    // State
    private var currentAppName: String?
    /// Bundle ID of `currentAppName`, so the exclusion list can be consulted about
    /// the app mull is leaving rather than the one it just arrived at.
    private var currentAppBundleID: String?
    private var currentWindowTitle: String?
    private var currentAppStartTime: Date = Date()
    private var lastClipboardCount: Int = 0
    private var lastClipboardText: String = ""

    // MARK: - Away backoff
    //
    // Two of the pollers below are expensive in a way that does not show up in
    // mull's own CPU time, because most of the work happens in somebody else's
    // process: the window-body walk is up to 1,500 AX nodes × 3 cross-process
    // calls into whatever app is in front, and the browser URL fetch is a
    // synchronous Apple Event that wakes the browser's main thread. Both ran at a
    // fixed 30s whether or not anyone was at the machine, which is 2,880 walks a
    // day into an app nobody is looking at.
    //
    // With no input at all, neither one can learn anything: an untouched window's
    // body is the body already recorded (the `lastWindowBody` dedupe would drop
    // it) and an untouched browser is on the URL already cached. So while the user
    // is away, sample rarely rather than not at all — rarely, because "the machine
    // did something while I was gone" is exactly the kind of thing the record is
    // for, and the territory cannot be re-read later (MAP-ARCHITECTURE).
    //
    // The 5s window-title poll is deliberately NOT backed off. It is two AX calls,
    // and titles are the entity anchor the whole selection layer ranks on — an
    // agent working in the editor while its user is away from the keyboard is a
    // thing that happens here, and mull should be able to say what it did.

    /// No human input for this long and the pollers treat the user as away.
    static let awayAfter: TimeInterval = 120

    /// How often the expensive pollers still sample while the user is away.
    static let awaySampleInterval: TimeInterval = 300

    /// Nobody has touched the machine for `awayAfter`.
    var isUserAway: Bool { environment.secondsSinceUserInput >= Self.awayAfter }

    /// Whether an expensive poller should run this tick. Always yes while the user
    /// is present; while they are away, yes once per `awaySampleInterval`.
    ///
    /// The caller records `now` into its own `last` only when it actually goes on
    /// to do the work, so a tick dropped by a privacy gate does not consume the
    /// slot. Coming back is instant: one keypress makes this true again on the
    /// next tick rather than after the interval.
    private func dueWhileAway(since last: Date) -> Bool {
        !isUserAway || environment.now.timeIntervalSince(last) >= Self.awaySampleInterval
    }

    private var lastWindowBodyPollAt: Date = .distantPast
    private var lastBrowserURLPollAt: Date = .distantPast

    /// Public read-only access for ProactiveEngine.
    var currentWindowTitlePublic: String? { currentWindowTitle }
    var lastBrowserURLPublic: String? { lastBrowserURL.isEmpty ? nil : lastBrowserURL }

    // Excluded apps
    private static let defaultExcluded: Set<String> = [
        "com.mull.app",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.apple.keychainaccess",
        "com.apple.systempreferences",
        "com.apple.SystemPreferences",
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.notificationcenterui",
    ]

    private var excludedBundleIDs: Set<String>
    private static let excludedAppsKey = "excludedBundleIDs"

    init(database: EventWriting, environment: CaptureEnvironment = SystemCaptureEnvironment()) {
        self.database = database
        self.environment = environment
        if let saved = UserDefaults.standard.stringArray(forKey: Self.excludedAppsKey) {
            self.excludedBundleIDs = Set(saved)
        } else {
            self.excludedBundleIDs = Self.defaultExcluded
        }
    }

    private func persistExcludedApps() {
        UserDefaults.standard.set(Array(excludedBundleIDs), forKey: Self.excludedAppsKey)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        // Don't check AXIsProcessTrusted() here — it returns false on Xcode debug builds
        // even when permission is granted. CGEvent.tapCreate will fail if truly not permitted.
        isRunning = true
        print("[mull] Recording started")

        startAppSwitchMonitor()
        print("[mull] App switch monitor started")

        startClipboardMonitor()
        print("[mull] Clipboard monitor started")

        startWindowTitleMonitor()
        print("[mull] Window title monitor started")

        startWindowBodyMonitor()
        print("[mull] Window body monitor started")

        startBrowserURLMonitor()

        // A tap that cannot be created means keystroke capture is dead from the
        // first second. The health check would notice, but only on its 10s tick,
        // and it used to seed itself as healthy regardless — so the UI said
        // "Recording" over nothing for the first ten seconds of every launch.
        let tapAlive = startKeystrokeCapture()

        startWakeMonitor()
        startHealthCheck(initialHealth: tapAlive)
        updateCurrentApp()
        print("[mull] All monitors running")
    }

    func stop() {
        isRunning = false

        // Keystrokes
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        keystrokeFlushTimer?.invalidate()
        keystrokeFlushTimer = nil
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        flushKeystrokeBuffer()

        // Other monitors
        if let obs = appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        appSwitchObserver = nil
        if let obs = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        wakeObserver = nil
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        windowTitleTimer?.invalidate()
        windowTitleTimer = nil
        windowBodyTimer?.invalidate()
        windowBodyTimer = nil
        browserURLTimer?.invalidate()
        browserURLTimer = nil

        recordAppSession()
    }

    /// Generation token so a stale timed-pause auto-resume can't override a later
    /// manual pause/resume.
    private var pauseToken = 0

    /// Pause until explicitly resumed. Honest pause: we also DISABLE the CGEvent tap
    /// at the OS level, so keystrokes are not even delivered to mull while paused —
    /// not merely dropped in-process. Clipboard/window pollers early-return on isPaused.
    func pauseIndefinitely() {
        pauseToken += 1
        setPaused(true)
    }

    /// Pause for a fixed window, then auto-resume (unless superseded meanwhile).
    func pause(for duration: TimeInterval) {
        pauseToken += 1
        let token = pauseToken
        setPaused(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.pauseToken == token else { return }   // not superseded
            self.setPaused(false)
        }
    }

    /// Resume capture immediately (cancels any pending timed auto-resume).
    func resume() {
        pauseToken += 1
        setPaused(false)
    }

    private func setPaused(_ paused: Bool) {
        isPaused = paused
        // Disabling the tap stops keystrokes from reaching us at all; re-enabling
        // resumes without rebuilding the whole capture stack.
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: !paused) }
    }

    // MARK: - 1. Keystroke Capture (CGEvent tap — EVERYTHING)

    /// Capture every keystroke. No filtering.
    /// Romaji, half-width katakana, confirmed CJK, code, typos — all recorded.
    /// AI will figure out what matters.
    /// Returns `true` if the event tap was created successfully.
    @discardableResult
    private func startKeystrokeCapture() -> Bool {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let service = Unmanaged<RecordingService>.fromOpaque(refcon).takeUnretainedValue()
                // A C callback cannot be actor-isolated. This one is nonetheless
                // always on the main run loop: the run-loop source below is added
                // to `CFRunLoopGetCurrent()` from `start()`, which is main-actor
                // isolated. `assumeIsolated` states that as a precondition the
                // runtime checks, instead of an assumption in a comment — if the
                // tap were ever installed from another thread this traps here
                // rather than quietly interleaving with the flush timer.
                MainActor.assumeIsolated { service.handleKeyEvent(event) }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[mull] CGEvent tap creation FAILED")
            print("[mull] → Grant 'Input Monitoring' in System Settings → Privacy & Security → Input Monitoring")
            print("[mull] → Clipboard and window title recording will still work without this")
            return false
        }
        print("[mull] CGEvent tap created — keystroke capture active")

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Flush buffer every 3 seconds — reduces IME romaji fragmentation
        keystrokeFlushTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.flushKeystrokeBuffer()
        }
        return true
    }

    /// Maximum buffer size in characters. If IME or a stuck timer causes the buffer
    /// to exceed this, it is force-flushed to prevent unbounded memory growth.
    private static let maxBufferLength = 10_000

    private func handleKeyEvent(_ event: CGEvent) {
        guard !isPaused, !isExcludedApp() else { return }

        // Skip if system-wide secure input is active (password dialogs)
        if environment.isSecureInputEnabled { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Skip keyboard shortcuts (⌘C, ⌃A, …). They still emit characters
        // ("c", "a"), which would otherwise be appended to the recorded text and
        // pollute keyword/language analytics. Shift and Option are genuine text
        // input (capitals, IME, alt-graph) and are intentionally NOT skipped.
        let isShortcut = event.flags.contains(.maskCommand) || event.flags.contains(.maskControl)

        // Get the characters from this key event
        if !isShortcut, let chars = event.keyboardCharacters, !chars.isEmpty {
            keystrokeBuffer.append(chars)
        }

        // Flush on Return/Enter/Tab (natural break points) or when buffer is too large
        if keyCode == 36 || keyCode == 76 || keyCode == 48
            || keystrokeBuffer.count >= Self.maxBufferLength {
            flushKeystrokeBuffer()
        }
    }

    private func flushKeystrokeBuffer() {
        let text = keystrokeBuffer
        keystrokeBuffer = ""

        guard !text.isEmpty else { return }

        // Record EVERYTHING. No filtering. AI will sort it out.
        recordEvent(type: .keystroke, text: text)
    }

    // MARK: - 2. App Switch + Session Duration

    private func startAppSwitchMonitor() {
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isPaused else { return }
            // Flush any pending keystrokes BEFORE the current-app pointer moves,
            // so text typed in the app being left is attributed to that app —
            // not stamped with the app just switched to. (recordEvent reads the
            // live currentAppName/currentWindowTitle, which updateCurrentApp is
            // about to overwrite.)
            self.flushKeystrokeBuffer()
            self.recordAppSession()
            let prevApp = self.currentAppName
            self.updateCurrentApp()
            // Same gap as `recordAppSession`, at the other end of the switch: this
            // row is the window title of the app just arrived at, and switching
            // *into* an excluded app wrote it.
            guard !self.isExcludedApp() else { return }
            if self.currentAppName != prevApp, let title = self.currentWindowTitle ?? self.currentAppName {
                self.recordEvent(type: .appSwitch, text: title)
            }
        }
    }

    /// Internal, like the two pollers, so the app-switch pair can be driven in
    /// tests: the notification handler calls `recordAppSession()` *before* this,
    /// and that ordering is the whole reason the exclusion gate below is subtle.
    func updateCurrentApp() {
        guard let name = environment.frontmostAppName else { return }
        currentAppName = name
        // Kept alongside the name because the exclusion list is keyed by bundle ID
        // and `recordAppSession` has to ask about the app being *left*, which is no
        // longer the frontmost one by the time it runs.
        currentAppBundleID = environment.frontmostBundleID
        currentWindowTitle = getActiveWindowTitle()
        currentAppStartTime = environment.now
    }

    func recordAppSession() {
        guard let app = currentAppName else { return }
        // The exclusion list said it covers window titles, and this line wrote one:
        // leaving an excluded app recorded "1Password: <title> (2m10s)" because the
        // gate on every other channel asks about the *frontmost* app, and by now the
        // frontmost app is the one being switched to. Ask about the app this row is
        // actually about.
        guard !isExcluded(bundleID: currentAppBundleID, name: app) else { return }
        let duration = environment.now.timeIntervalSince(currentAppStartTime)
        guard duration >= 5 else { return }

        let minutes = Int(duration / 60)
        let seconds = Int(duration) % 60
        let timeStr = minutes > 0 ? "\(minutes)m\(seconds)s" : "\(seconds)s"
        recordEvent(
            type: .appSwitch,
            text: "\(app): \(currentWindowTitle ?? "unknown") (\(timeStr))"
        )
    }

    // MARK: - 3. Window Title Monitor

    private func startWindowTitleMonitor() {
        windowTitleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.pollWindowTitle()
        }
    }

    /// One window-title tick. Split out of the timer for the same reason as
    /// `pollClipboard`: the private-browsing gate and the typing-in-progress
    /// heuristic are policy, and policy that cannot be called cannot be tested.
    func pollWindowTitle() {
        guard !isPaused else { return }
        guard !isExcludedApp() else { return }

        let newTitle = getActiveWindowTitle()
        guard let title = newTitle, !title.isEmpty else { return }

        // Never record private / incognito browser windows. Remember the
        // title so we don't reprocess it, but drop it from the record entirely.
        if PrivateBrowsing.isPrivate(title) {
            currentWindowTitle = title
            return
        }

        // Skip if title hasn't changed meaningfully
        guard title != currentWindowTitle else { return }

        // Skip titles that are clearly typing-in-progress
        // (VS Code updates window title as you type in its command palette / chat)
        // Real window titles are stable for > 1 second. Typing titles change every keystroke.
        // We use a simple heuristic: if the new title is a prefix/suffix of the old one
        // and only differs by a few characters, it's likely typing, not a real title change.
        if let old = currentWindowTitle {
            let oldClean = old.trimmingCharacters(in: .whitespacesAndNewlines)
            let newClean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            // If one is a substring of the other and difference is small, skip
            if newClean.hasPrefix(oldClean) || oldClean.hasPrefix(newClean) {
                let diff = abs(newClean.count - oldClean.count)
                if diff < 10 && diff > 0 {
                    // Likely incremental typing in command palette — update internal state but don't record
                    currentWindowTitle = title
                    return
                }
            }
        }

        // Append the browser URL if one arrived since the last title event.
        // Read from cache — never fetched inline here; see the browser URL
        // monitor below for why this timer must not touch AppleScript.
        let enriched: String
        if let url = takePendingBrowserURL() {
            enriched = "\(title) | \(url)"
        } else {
            enriched = title
        }

        currentWindowTitle = title
        recordEvent(type: .screenText, text: enriched)
    }

    // MARK: - 3b. Window Body Monitor (capture fidelity #1)
    //
    // Reads the BODY text of the focused window every 30s — the work itself, not
    // the title. Territory-first (MAP-ARCHITECTURE.md): a body we don't capture
    // now can never be re-captured. Recorded only on change, on a separate
    // channel (.windowBody) so title heuristics stay clean. Same privacy gates
    // as every monitor: app exclusions, private browsing, secure input — plus
    // WindowTextCapture itself never reads password fields.

    private func startWindowBodyMonitor() {
        windowBodyTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.pollWindowBody()
        }
    }

    /// One window-body tick. Internal for the same reason as the other two
    /// pollers: the gates below are policy, and policy that cannot be called
    /// cannot be tested.
    func pollWindowBody() {
        guard !isPaused else { return }
        guard !isExcludedApp() else { return }
        if environment.isSecureInputEnabled { return }
        if let title = currentWindowTitle, PrivateBrowsing.isPrivate(title) { return }

        // Last gate before the expensive part, and only the expensive part: the
        // privacy gates above have already answered, and their answers cost
        // nothing. Nothing below this line runs 30-secondly with nobody there.
        guard dueWhileAway(since: lastWindowBodyPollAt) else { return }
        lastWindowBodyPollAt = environment.now

        // Below ~80 chars a title-only window adds nothing over .screenText.
        guard let body = environment.focusedWindowBody, body.count >= 80 else { return }
        guard body != lastWindowBody else { return }
        lastWindowBody = body
        recordEvent(type: .windowBody, text: body)
    }

    // MARK: - 3c. Browser URL Monitor
    //
    // The URL used to be read inline from the 5-second window-title timer, on the
    // main run loop, with a synchronous NSAppleScript Apple Event into
    // Safari/Chrome/Arc. A synchronous Apple Event blocks until the TARGET app
    // answers, and a browser that is busy, showing a modal, still launching, or
    // sitting behind a TCC prompt does not answer for seconds — mull's entire UI
    // froze along with it, up to twelve times a minute.
    //
    // So: fetch on its own 30s cadence (a URL does not need 5-second resolution —
    // the same interval the window-body monitor already uses), run the Apple Event
    // off the main thread, and let the fast timer read an answer that is always
    // already sitting in a variable.
    //
    // Thread-safety: only the NSAppleScript call itself leaves the main thread.
    // Every piece of shared state below (`lastBrowserURL`, `pendingBrowserURL`,
    // `browserFetchInFlight`) is read and written on the main thread only, like the
    // rest of this class.

    /// Serial and off-main. Serial so two ticks can never have Apple Events in
    /// flight at once: NSAppleScript is not thread-safe, and one stuck browser
    /// should stall this queue, not pile up on it.
    private static let browserQueue = DispatchQueue(label: "com.mull.browser-url", qos: .utility)

    /// Most recent URL seen, for dedupe and for `lastBrowserURLPublic`.
    private var lastBrowserURL: String = ""

    /// A newly-changed URL waiting to be attached to the next title event.
    /// Consumed once, mirroring the old behaviour where `getBrowserURL()` returned
    /// nil for a URL it had already reported.
    private var pendingBrowserURL: String?

    private var browserFetchInFlight = false

    private func startBrowserURLMonitor() {
        browserURLTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.fetchBrowserURL()
        }
        // Warm the cache now rather than leaving the first half-minute of browsing
        // unattributed.
        fetchBrowserURL()
        print("[mull] Browser URL monitor started")
    }

    private func takePendingBrowserURL() -> String? {
        defer { pendingBrowserURL = nil }
        return pendingBrowserURL
    }

    /// Decide on the main thread, run the Apple Event off it, publish back on it.
    private func fetchBrowserURL() {
        guard isRunning, !isPaused, !isExcludedApp() else { return }

        // A private/incognito window's URL must never be read at all, let alone
        // cached. The title timer used to make this check before ever calling in;
        // now that the fetch has its own clock, the check has to live here too or
        // incognito browsing leaks out through `lastBrowserURLPublic`.
        if let title = currentWindowTitle, PrivateBrowsing.isPrivate(title) {
            lastBrowserURL = ""
            pendingBrowserURL = nil
            return
        }

        guard !browserFetchInFlight, let ask = browserURLScript() else { return }

        // After the in-flight check, so a tick that had nothing to do anyway does
        // not spend the away slot. A browser nobody is touching stays on the URL
        // already in `lastBrowserURL`; waking it every 30s to be told that costs
        // the browser more than it costs mull.
        guard dueWhileAway(since: lastBrowserURLPollAt) else { return }
        lastBrowserURLPollAt = environment.now

        browserFetchInFlight = true

        Self.browserQueue.async {
            let url = Self.runBrowserURLScript(ask.script, browser: ask.browser)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.browserFetchInFlight = false
                guard let url, url != self.lastBrowserURL else { return }
                self.lastBrowserURL = url
                self.pendingBrowserURL = url
            }
        }
    }

    /// AppleScript source for the frontmost browser, or nil if the front app isn't
    /// one we can ask. Touches NSWorkspace, so it stays on the main thread.
    /// Works with Safari, Chrome, Arc, Brave, Edge (Firefox exposes no URL).
    private func browserURLScript() -> (script: String, browser: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }

        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return ("tell application \"Safari\" to get URL of current tab of front window", "Safari")

        case "com.google.Chrome", "com.google.Chrome.canary",
             "com.brave.Browser", "com.microsoft.edgemac",
             "company.thebrowser.Browser": // Arc
            let appName = app.localizedName ?? "Google Chrome"
            return ("tell application \"\(appName)\" to get URL of active tab of front window", appName)

        default:
            // Firefox included: it doesn't support AppleScript for URL.
            return nil
        }
    }

    /// Why mull can't read the address bar, in the user's terms.
    ///
    /// This used to be nothing at all: the error dictionary was discarded, so a
    /// denied Automation permission and "the front window has no URL" produced
    /// the same silence. And the ask arrives unannounced — the first fetch runs
    /// moments after onboarding's permission screen, so a reflexive "Don't Allow"
    /// is permanent, invisible, and takes every browser URL with it.
    enum BrowserAccessProblem: Equatable, Sendable {
        /// The macOS Automation permission was denied (AppleScript -1743/-1744).
        case automationDenied(browser: String)
        /// Anything else AppleScript reported, verbatim.
        case scriptFailed(browser: String, detail: String)

        var message: String {
            switch self {
            case .automationDenied(let browser):
                "macOS is blocking mull from reading \(browser)'s address bar. Allow it in System Settings › Privacy & Security › Automation › mull › \(browser)."
            case .scriptFailed(let browser, let detail):
                "\(browser) returned an error when mull asked for the current page: \(detail)"
            }
        }

        var isPermission: Bool {
            if case .automationDenied = self { return true }
            return false
        }
    }

    /// The last thing that went wrong asking a browser for its URL, or nil if the
    /// last attempt worked. Lock-guarded: written from `browserQueue`, read from
    /// the main thread by Settings.
    private static let browserProblemLock = NSLock()
    private static var storedBrowserProblem: BrowserAccessProblem?

    static var lastBrowserProblem: BrowserAccessProblem? {
        get { browserProblemLock.lock(); defer { browserProblemLock.unlock() }; return storedBrowserProblem }
        set { browserProblemLock.lock(); storedBrowserProblem = newValue; browserProblemLock.unlock() }
    }

    /// The blocking part. Static and argument-only so it cannot reach instance
    /// state from the background queue.
    private static func runBrowserURLScript(_ source: String, browser: String) -> String? {
        guard let scriptObj = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = scriptObj.executeAndReturnError(&error)

        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743: the user said no. -1744: not yet authorized for this target.
            if code == -1743 || code == -1744 {
                lastBrowserProblem = .automationDenied(browser: browser)
            } else if code == -1728 || code == -600 {
                // "No front window" / app not running — an ordinary state, not a
                // problem to report. A browser with no window open hits this.
                lastBrowserProblem = nil
            } else {
                let detail = (error[NSAppleScript.errorMessage] as? String) ?? "error \(code)"
                lastBrowserProblem = .scriptFailed(browser: browser, detail: detail)
            }
            return nil
        }

        lastBrowserProblem = nil
        guard let url = result.stringValue, !url.isEmpty else { return nil }
        return url
    }

    private func getActiveWindowTitle() -> String? { environment.activeWindowTitle }

    // MARK: - 4. Clipboard Monitor

    private func startClipboardMonitor() {
        clipboardTimer?.invalidate()
        lastClipboardCount = environment.clipboardChangeCount
        lastClipboardText = environment.clipboardText ?? ""

        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.pollClipboard()
        }
    }

    /// One clipboard tick.
    ///
    /// Split out of the timer closure so it can be called directly. The privacy
    /// gates below are the ones mull advertises — excluded apps, secure input,
    /// private browsing — and until there was a seam here, not one of them had a
    /// test. `RecordingServiceTests` now drives this method against a stub
    /// environment, which is the only way to assert that a password copied out of
    /// 1Password never reaches the database.
    func pollClipboard() {
        guard !isPaused else { return }

        let currentCount = environment.clipboardChangeCount
        guard currentCount != lastClipboardCount else { return }
        // Advance the counter before the privacy gates: even when we drop this
        // copy, the *next* one (from a permitted app) must still look changed.
        lastClipboardCount = currentCount

        // The same privacy gates every other capture channel applies — keystrokes,
        // window titles and window body all check these, and the clipboard was the
        // one poller that didn't, so a password copied out of 1Password (an
        // explicitly excluded app) still landed in the vault. We return before
        // reading the pasteboard at all, so the secret isn't even held in
        // `lastClipboardText`. Checked here rather than at the top of the tick:
        // this runs twice a second, and the common case is "nothing was copied".
        if isExcludedApp() { return }
        if environment.isSecureInputEnabled { return }
        if let title = currentWindowTitle, PrivateBrowsing.isPrivate(title) { return }

        // The gate the exclusion list above cannot be: exclusion asks which app is
        // frontmost *when this tick runs*, and it runs twice a second. The ordinary
        // way anyone uses a password manager — copy in 1Password, ⌘Tab, paste —
        // routinely puts a different app in front before mull looks, and the
        // password is then recorded from an app that is on the excluded list. That
        // race is why `defaultExcluded` alone was never enough.
        //
        // A do-not-store marker rides on the pasteboard item instead of on the
        // frontmost process, so it survives the app switch. Checked before the
        // string is read, so a concealed secret is never held in memory here.
        if environment.clipboardIsMarkedDoNotStore { return }

        guard let text = environment.clipboardText,
              !text.isEmpty,
              text != lastClipboardText else { return }
        lastClipboardText = text

        // Skip mull's own output (recording our own output is a feedback loop).
        // Includes Curator provenance markers — copying a me.md block would
        // otherwise feed "hash", "src", "agent" back in as "focus topics".
        if MarkdownDoc.isGeneratedByMull(text) { return }

        // Log the shape, never the content: Console.app is world-readable to any
        // process that can talk to the unified log, so echoing clipboard text
        // there leaks exactly what the local-only vault promise protects.
        print("[mull] Clipboard captured: \(text.count) chars")
        // Capture fidelity (MAP-ARCHITECTURE.md): the cap is irreversible loss
        // at the territory layer — you can't re-copy the past. Keep generously;
        // pasted docs/code routinely exceed 5k chars. SQLite handles this fine.
        recordEvent(type: .clipboard, text: String(text.prefix(40000)))
    }

    // MARK: - 5. Sleep/Wake

    private func startWakeMonitor() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `!isPaused` matters: setPaused(true) deliberately disables the tap at the
            // OS level, and a wake would otherwise silently switch keystroke capture
            // back on behind the user's explicit pause.
            guard let self, self.isRunning, !self.isPaused else { return }
            self.updateCurrentApp()
            // Re-enable event tap (may be disabled after sleep)
            if let tap = self.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    // MARK: - 6. Health Check (Re-enable event tap if macOS killed it)

    /// macOS silently disables CGEvent taps on:
    ///   - Sleep/wake (handled by wake monitor, but not always reliable)
    ///   - Screen lock / fast user switching
    ///   - System deciding the tap is "unresponsive"
    ///   - Accessibility permission changes
    ///
    /// This timer checks every 10 seconds and re-enables if needed.
    /// Notifies AppState via `onHealthStatusChanged` so UI stays in sync.
    private var lastHealthStatus: Bool = true

    private func startHealthCheck(initialHealth: Bool = true) {
        lastHealthStatus = initialHealth
        if !initialHealth { onHealthStatusChanged?(false) }
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            // While paused the tap is disabled *on purpose* (setPaused). Without the
            // isPaused check this timer read that as "macOS killed the tap" and
            // re-enabled it within 10s, quietly undoing the user's pause. A paused
            // tap has nothing to recover, so skip the tick entirely — recreating a
            // destroyed tap below would re-enable it too.
            guard let self, self.isRunning, !self.isPaused else { return }

            var isHealthy = true

            if let tap = self.eventTap {
                if !CGEvent.tapIsEnabled(tap: tap) {
                    print("[mull] Event tap was disabled by macOS — re-enabling")
                    CGEvent.tapEnable(tap: tap, enable: true)

                    // Verify re-enable actually worked
                    if !CGEvent.tapIsEnabled(tap: tap) {
                        print("[mull] Re-enable failed — permissions likely revoked")
                        self.eventTap = nil
                        if let source = self.runLoopSource {
                            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                        }
                        self.runLoopSource = nil
                        isHealthy = false
                    }
                }
            } else {
                // Event tap was destroyed entirely — try to recreate
                print("[mull] Event tap was destroyed — attempting recreate")
                isHealthy = self.startKeystrokeCapture()
            }

            // Notify UI only when status changes
            if isHealthy != self.lastHealthStatus {
                self.lastHealthStatus = isHealthy
                self.onHealthStatusChanged?(isHealthy)
            }
        }
    }

    // MARK: - Helpers

    private func isExcludedApp() -> Bool {
        isExcluded(bundleID: environment.frontmostBundleID, name: environment.frontmostAppName)
    }

    /// The exclusion question, asked about a named app rather than about whichever
    /// app happens to be frontmost right now. Every live-capture channel wants the
    /// frontmost form above; `recordAppSession` is the one caller describing an app
    /// mull has already left.
    private func isExcluded(bundleID: String?, name: String?) -> Bool {
        guard name != nil || bundleID != nil else { return false }

        // Check bundle ID
        if let bundleID, excludedBundleIDs.contains(bundleID) {
            return true
        }

        // Also check by app name (catches renamed bundles, Xcode debug builds).
        //
        // Compared lowercased: localizedName is "Mull" (project.yml sets
        // PRODUCT_NAME: Mull), so a case-sensitive lookup for "mull" never
        // matched and this fallback covered nothing. The list also held "mull"
        // twice — a Set deduped it silently, hiding that the intended "old name
        // + new name" pair was really just one entry.
        let excludedNames: Set<String> = [
            "mull", "whatly",   // our own app, before and after the rename
            "usernotificationcenter", "notificationcenter",
            "securityagent", "loginwindow",
            "universalaccessauthwarn",
        ]
        if let name, excludedNames.contains(name.lowercased()) {
            return true
        }

        return false
    }

    private static let trivialChars = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet.punctuationCharacters)
        .union(CharacterSet(charactersIn: "/-_.~`"))

    private func recordEvent(type: RecordingEvent.EventType, text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        // Skip trivial content: only punctuation, whitespace, or single characters
        if type == .keystroke {
            let stripped = cleaned.unicodeScalars.filter { !Self.trivialChars.contains($0) }
            guard stripped.count > 0 else { return }
        }

        // Skip synthetic test/QA input (pangrams, keyboard mashing, abnormal
        // spacing) — the same idea as app exclusion, matched on content rather
        // than source app. Keeps "the quick brown fox" / "test   double   spaces"
        // out of keyword, phrase, and language analytics.
        if type == .keystroke || type == .clipboard, TestInput.isLikelyTestInput(cleaned) {
            return
        }

        // Type and size only — this path carries keystrokes, clipboard and window
        // body text, none of which belongs in the unified log.
        print("[mull] Recording event: \(type.rawValue) — \(cleaned.count) chars")

        // Capture-time enrichment (#4): classify once, store on the row, so the
        // selection layer doesn't recompute kind/salience/entity per query.
        let signal = Signal.classify(text: cleaned, eventType: type, windowTitle: currentWindowTitle)
        let mode = Mode.classify(text: cleaned, eventType: type, appName: currentAppName,
                                 windowTitle: currentWindowTitle, contentType: signal.type)
        let event = RecordingEvent(
            timestamp: Date(),
            eventType: type,
            appName: currentAppName,
            windowTitle: currentWindowTitle,
            textContent: cleaned,
            entity: Entity.from(currentWindowTitle ?? cleaned),
            contentType: signal.type,
            salience: signal.salience,
            mode: mode.rawValue
        )
        database.insertEvent(event)
    }

    // MARK: - Configuration

    func addExcludedApp(_ bundleID: String) {
        excludedBundleIDs.insert(bundleID)
        persistExcludedApps()
    }

    func removeExcludedApp(_ bundleID: String) {
        guard bundleID != "com.mull.app" else { return }
        excludedBundleIDs.remove(bundleID)
        persistExcludedApps()
    }

    var excludedApps: Set<String> {
        excludedBundleIDs
    }

    /// Excluded apps as (bundleID, displayName), sorted by name — for the settings list.
    var excludedAppList: [(id: String, name: String)] {
        excludedBundleIDs
            .map { (id: $0, name: Self.appName(for: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Currently running, user-facing apps not already excluded — for the "Add" picker.
    var addableRunningApps: [(id: String, name: String)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (id: String, name: String)? in
                guard let id = app.bundleIdentifier,
                      !excludedBundleIDs.contains(id),
                      seen.insert(id).inserted else { return nil }
                return (id: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Best-effort friendly name for a bundle id (running app → installed app → id).
    static func appName(for bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

// MARK: - CGEvent Extension

private extension CGEvent {
    var keyboardCharacters: String? {
        var length = 0
        keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else { return nil }
        var chars = [UniChar](repeating: 0, count: length)
        keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length)
    }
}
