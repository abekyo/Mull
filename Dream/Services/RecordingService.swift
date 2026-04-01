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
    private var isRunning = false
    private var isPaused = false

    // Observers & timers
    private var appSwitchObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var clipboardTimer: Timer?
    private var windowTitleTimer: Timer?
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

    // Excluded apps
    private static let defaultExcluded: Set<String> = [
        "com.dream.app",
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
        print("[Dream] Recording started")

        startAppSwitchMonitor()
        print("[Dream] App switch monitor started")

        startClipboardMonitor()
        print("[Dream] Clipboard monitor started")

        startWindowTitleMonitor()
        print("[Dream] Window title monitor started")

        startKeystrokeCapture()
        // CGEvent tap creation logs its own success/failure

        startWakeMonitor()
        startHealthCheck()
        updateCurrentApp()
        print("[Dream] All monitors running")
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

        recordAppSession()
    }

    func pause(for duration: TimeInterval) {
        isPaused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.isPaused = false
        }
    }

    // MARK: - 1. Keystroke Capture (CGEvent tap — EVERYTHING)

    /// Capture every keystroke. No filtering.
    /// Romaji, half-width katakana, confirmed CJK, code, typos — all recorded.
    /// AI will figure out what matters.
    private func startKeystrokeCapture() {
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
            print("[Dream] ⚠️ CGEvent tap creation FAILED")
            print("[Dream] → Grant 'Input Monitoring' in System Settings → Privacy & Security → Input Monitoring")
            print("[Dream] → Clipboard and window title recording will still work without this")
            return
        }
        print("[Dream] ✓ CGEvent tap created successfully — keystroke capture active")

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Flush buffer every 1 second — minimal lag while still batching
        keystrokeFlushTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.flushKeystrokeBuffer()
        }
    }

    private func handleKeyEvent(_ event: CGEvent) {
        guard !isPaused, !isExcludedApp() else { return }

        // Skip if system-wide secure input is active (password dialogs)
        if IsSecureEventInputEnabled() { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Get the characters from this key event
        if let chars = event.keyboardCharacters, !chars.isEmpty {
            keystrokeBuffer.append(chars)
        }

        // Flush on Return/Enter/Tab (natural break points)
        if keyCode == 36 || keyCode == 76 || keyCode == 48 {
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
        guard result == .success, let window = windowRef else { return nil }
        let windowElement = window as! AXUIElement

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
            self.lastClipboardCount = currentCount

            guard let text = NSPasteboard.general.string(forType: .string),
                  !text.isEmpty,
                  text != self.lastClipboardText else { return }
            self.lastClipboardText = text

            // Skip Dream's own output (recording our own output is a feedback loop)
            if text.contains("Dream is recording") ||
               text.contains("Dream is still learning") ||
               text.contains("auto-updated:") ||
               text.contains("About the user (auto") ||
               text.contains("What the user is currently") ||
               text.contains("Raw activity data for") ||
               text.contains("Context about the user") ||
               text.contains("No activity recorded") {
                return
            }

            print("[Dream] Clipboard captured: \(text.prefix(50))...")
            self.recordEvent(type: .clipboard, text: String(text.prefix(5000)))
        }
    }

    // MARK: - 5. Sleep/Wake

    private func startWakeMonitor() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
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
    /// This timer checks every 30 seconds and re-enables if needed.
    private func startHealthCheck() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }

            if let tap = self.eventTap {
                if !CGEvent.tapIsEnabled(tap: tap) {
                    print("[Dream] Event tap was disabled by macOS — re-enabling")
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            } else {
                // Event tap was destroyed entirely — recreate
                print("[Dream] Event tap was destroyed — recreating")
                self.startKeystrokeCapture()
            }
        }
    }

    // MARK: - Helpers

    private func isExcludedApp() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return excludedBundleIDs.contains(bundleID)
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

        print("[Dream] Recording event: \(type.rawValue) — \(cleaned.prefix(60))")

        let event = RecordingEvent(
            timestamp: Date(),
            eventType: type,
            appName: currentAppName,
            windowTitle: currentWindowTitle,
            textContent: cleaned
        )
        database.insertEvent(event)
    }

    // MARK: - Configuration

    func addExcludedApp(_ bundleID: String) {
        excludedBundleIDs.insert(bundleID)
        persistExcludedApps()
    }

    func removeExcludedApp(_ bundleID: String) {
        guard bundleID != "com.dream.app" else { return }
        excludedBundleIDs.remove(bundleID)
        persistExcludedApps()
    }

    var excludedApps: Set<String> {
        excludedBundleIDs
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
