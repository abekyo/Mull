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
final class RecordingService {

    private let database: DatabaseService
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
    private var lastWindowBody = ""
    private var healthCheckTimer: Timer?

    // Keystroke capture
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keystrokeBuffer: String = ""
    private var keystrokeFlushTimer: Timer?

    // State
    private var currentAppName: String?
    private var currentWindowTitle: String?
    private var currentAppStartTime: Date = Date()
    private var lastClipboardCount: Int = 0
    private var lastClipboardText: String = ""

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

    init(database: DatabaseService) {
        self.database = database
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

        startKeystrokeCapture()
        // CGEvent tap creation logs its own success/failure

        startWakeMonitor()
        startHealthCheck()
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
                service.handleKeyEvent(event)
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[mull] ⚠️ CGEvent tap creation FAILED")
            print("[mull] → Grant 'Input Monitoring' in System Settings → Privacy & Security → Input Monitoring")
            print("[mull] → Clipboard and window title recording will still work without this")
            return false
        }
        print("[mull] ✓ CGEvent tap created successfully — keystroke capture active")

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
        if IsSecureEventInputEnabled() { return }

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
            if self.currentAppName != prevApp, let title = self.currentWindowTitle ?? self.currentAppName {
                self.recordEvent(type: .appSwitch, text: title)
            }
        }
    }

    private func updateCurrentApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        currentAppName = app.localizedName
        currentWindowTitle = getActiveWindowTitle()
        currentAppStartTime = Date()
    }

    private func recordAppSession() {
        guard let app = currentAppName else { return }
        let duration = Date().timeIntervalSince(currentAppStartTime)
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
            guard let self, self.isRunning, !self.isPaused else { return }
            guard !self.isExcludedApp() else { return }

            let newTitle = self.getActiveWindowTitle()
            guard let title = newTitle, !title.isEmpty else { return }

            // Never record private / incognito browser windows. Remember the
            // title so we don't reprocess it, but drop it from the record entirely.
            if PrivateBrowsing.isPrivate(title) {
                self.currentWindowTitle = title
                return
            }

            // Skip if title hasn't changed meaningfully
            guard title != self.currentWindowTitle else { return }

            // Skip titles that are clearly typing-in-progress
            // (VS Code updates window title as you type in its command palette / chat)
            // Real window titles are stable for > 1 second. Typing titles change every keystroke.
            // We use a simple heuristic: if the new title is a prefix/suffix of the old one
            // and only differs by a few characters, it's likely typing, not a real title change.
            if let old = self.currentWindowTitle {
                let oldClean = old.trimmingCharacters(in: .whitespacesAndNewlines)
                let newClean = title.trimmingCharacters(in: .whitespacesAndNewlines)
                // If one is a substring of the other and difference is small, skip
                if newClean.hasPrefix(oldClean) || oldClean.hasPrefix(newClean) {
                    let diff = abs(newClean.count - oldClean.count)
                    if diff < 10 && diff > 0 {
                        // Likely incremental typing in command palette — update internal state but don't record
                        self.currentWindowTitle = title
                        return
                    }
                }
            }

            // Append browser URL if this is a browser app
            let enriched: String
            if let url = self.getBrowserURL() {
                enriched = "\(title) | \(url)"
            } else {
                enriched = title
            }

            self.currentWindowTitle = title
            self.recordEvent(type: .screenText, text: enriched)
        }
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
            guard let self, self.isRunning, !self.isPaused else { return }
            guard !self.isExcludedApp() else { return }
            if IsSecureEventInputEnabled() { return }
            if let title = self.currentWindowTitle, PrivateBrowsing.isPrivate(title) { return }

            // Below ~80 chars a title-only window adds nothing over .screenText.
            guard let body = WindowTextCapture.focusedWindowText(), body.count >= 80 else { return }
            guard body != self.lastWindowBody else { return }
            self.lastWindowBody = body
            self.recordEvent(type: .windowBody, text: body)
        }
    }

    /// Get the current URL from the active browser tab via AppleScript.
    /// Works with Safari, Chrome, Firefox, Arc, Brave, Edge.
    private var lastBrowserURL: String = ""

    private func getBrowserURL() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }

        let script: String?

        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            script = "tell application \"Safari\" to get URL of current tab of front window"

        case "com.google.Chrome", "com.google.Chrome.canary",
             "com.brave.Browser", "com.microsoft.edgemac",
             "company.thebrowser.Browser": // Arc
            let appName = app.localizedName ?? "Google Chrome"
            script = "tell application \"\(appName)\" to get URL of active tab of front window"

        case "org.mozilla.firefox":
            // Firefox doesn't support AppleScript for URL — skip
            return nil

        default:
            return nil
        }

        guard let appleScript = script else { return nil }

        var error: NSDictionary?
        guard let scriptObj = NSAppleScript(source: appleScript) else { return nil }
        let result = scriptObj.executeAndReturnError(&error)

        guard error == nil, let url = result.stringValue, !url.isEmpty else { return nil }

        // Skip if same URL as last time
        guard url != lastBrowserURL else { return nil }
        lastBrowserURL = url

        return url
    }

    private func getActiveWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef
        )
        // Some apps answer kAXFocusedWindow with something that isn't an AXUIElement.
        // A force-cast crashes the whole recorder there, so verify the CF type first
        // (same guard as WindowTextCapture.focusedWindowText).
        guard result == .success, let window = windowRef,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let windowElement = unsafeDowncast(window as AnyObject, to: AXUIElement.self)

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef)
        return titleRef as? String
    }

    // MARK: - 4. Clipboard Monitor

    private func startClipboardMonitor() {
        clipboardTimer?.invalidate()
        lastClipboardCount = NSPasteboard.general.changeCount
        lastClipboardText = NSPasteboard.general.string(forType: .string) ?? ""

        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isRunning, !self.isPaused else { return }

            let currentCount = NSPasteboard.general.changeCount
            guard currentCount != self.lastClipboardCount else { return }
            // Advance the counter before the privacy gates: even when we drop this
            // copy, the *next* one (from a permitted app) must still look changed.
            self.lastClipboardCount = currentCount

            // The same privacy gates every other capture channel applies — keystrokes,
            // window titles and window body all check these, and the clipboard was the
            // one poller that didn't, so a password copied out of 1Password (an
            // explicitly excluded app) still landed in the vault. We return before
            // reading the pasteboard at all, so the secret isn't even held in
            // `lastClipboardText`. Checked here rather than at the top of the tick:
            // this runs twice a second, and the common case is "nothing was copied".
            if self.isExcludedApp() { return }
            if IsSecureEventInputEnabled() { return }
            if let title = self.currentWindowTitle, PrivateBrowsing.isPrivate(title) { return }

            guard let text = NSPasteboard.general.string(forType: .string),
                  !text.isEmpty,
                  text != self.lastClipboardText else { return }
            self.lastClipboardText = text

            // Skip mull's own output (recording our own output is a feedback loop).
            // Includes Curator provenance markers — copying a me.md block would
            // otherwise feed "hash", "src", "agent" back in as "focus topics".
            if text.contains("mull:block") ||
               text.contains("mull:auto") ||
               text.contains("mull is recording") ||
               text.contains("mull is still learning") ||
               text.contains("auto-updated:") ||
               text.contains("About the user (auto") ||
               text.contains("What the user is currently") ||
               text.contains("Raw activity data for") ||
               text.contains("Context about the user") ||
               text.contains("No activity recorded") {
                return
            }

            // Log the shape, never the content: Console.app is world-readable to any
            // process that can talk to the unified log, so echoing clipboard text
            // there leaks exactly what the local-only vault promise protects.
            print("[mull] Clipboard captured: \(text.count) chars")
            // Capture fidelity (MAP-ARCHITECTURE.md): the cap is irreversible loss
            // at the territory layer — you can't re-copy the past. Keep generously;
            // pasted docs/code routinely exceed 5k chars. SQLite handles this fine.
            self.recordEvent(type: .clipboard, text: String(text.prefix(40000)))
        }
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

    private func startHealthCheck() {
        lastHealthStatus = true
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
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }

        // Check bundle ID
        if let bundleID = app.bundleIdentifier, excludedBundleIDs.contains(bundleID) {
            return true
        }

        // Also check by app name (catches renamed bundles, Xcode debug builds)
        let excludedNames: Set<String> = [
            "mull", "mull",  // Our own app (old + new name)
            "UserNotificationCenter", "NotificationCenter",
            "SecurityAgent", "loginwindow",
            "universalAccessAuthWarn",
        ]
        if let name = app.localizedName, excludedNames.contains(name) {
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
