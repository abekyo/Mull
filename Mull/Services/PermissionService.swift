import Foundation
import AppKit
import ApplicationServices
import IOKit.hidsystem

/// Monitors Accessibility and Input Monitoring permission status.
///
/// - Accessibility: checked via AXIsProcessTrusted() — unreliable on Xcode debug builds
/// - Input Monitoring: checked by attempting CGEvent tap creation — the only reliable method
/// - Clipboard: no permission needed
///
/// Provides observable state for UI and periodic re-checking.
@MainActor
final class PermissionService: ObservableObject {

    @Published var accessibilityGranted = false
    @Published var inputMonitoringGranted = false

    /// Which permission went away. Enough for the caller to name it and to send the
    /// user back to the right pane.
    enum Permission {
        case accessibility
        case inputMonitoring

        /// The name macOS itself uses, so the sentence mull writes matches the
        /// switch the user has to go and find.
        var displayName: String {
            switch self {
            case .accessibility: return String(localized: "Accessibility")
            case .inputMonitoring: return String(localized: "Input Monitoring")
            }
        }

        /// What stops being recorded the moment it's revoked.
        var whatStops: String {
            switch self {
            case .accessibility: return String(localized: "window titles and page names")
            case .inputMonitoring: return String(localized: "what you type")
            }
        }
    }

    /// Fired once on a granted → revoked transition.
    ///
    /// The 5s poll below has always *detected* revocation; nothing ever reacted to
    /// it, so a permission switched off in System Settings — or dropped by macOS
    /// after an app update, which it does silently — took capture down and said
    /// nothing. The user could lose a week before noticing the day was empty.
    /// Fired only on the transition: a permission that has been off since install
    /// (someone who skipped it during onboarding) is not a loss and must not
    /// nag every five seconds.
    var onRevoked: ((Permission) -> Void)?

    private var checkTimer: Timer?

    init() {
        checkAll()
        // Re-check every 5 seconds (user may grant permission while app is running)
        checkTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAll()
            }
        }
    }

    deinit {
        checkTimer?.invalidate()
    }

    func checkAll() {
        // Snapshot before the probes so the transition can be spotted afterwards.
        // The first call happens inside `init`, before any caller has had the
        // chance to set `onRevoked`, so a fresh launch can't announce a phantom loss.
        let hadAccessibility = accessibilityGranted
        let hadInputMonitoring = inputMonitoringGranted

        checkAccessibility()
        checkInputMonitoring()

        if hadAccessibility && !accessibilityGranted { onRevoked?(.accessibility) }
        // Only a loss if mull was using it. With keystroke capture off, revoking Input
        // Monitoring takes nothing away, and "mull has stopped recording" would be
        // false — the other five channels never depended on this grant.
        if hadInputMonitoring && !inputMonitoringGranted,
           Preferences.keystrokeCaptureEnabled { onRevoked?(.inputMonitoring) }
    }

    // MARK: - Accessibility

    /// AXIsProcessTrusted() lies on Xcode debug builds (false even when granted).
    /// So, like the Input-Monitoring check, we ALSO probe empirically: try to read
    /// a real AX attribute. When Accessibility is off the API returns `.apiDisabled`;
    /// any other result means it's actually enabled — the only thing that matters,
    /// since window-title capture is exactly such a read. Trust either signal (OR)
    /// so we never report "granted" while titles silently come back nil.
    private func checkAccessibility() {
        accessibilityGranted = AXIsProcessTrusted() || accessibilityAPIEnabled()
    }

    /// Empirical probe: is CROSS-APP Accessibility actually usable right now?
    /// Must read a DIFFERENT app — reading our own process's AX never requires the
    /// permission, so probing self (often frontmost right after launch) would
    /// false-positive and wrongly suppress the grant prompt. This is exactly what
    /// made window-title capture silently stay dead.
    private func accessibilityAPIEnabled() -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier > 0
            && app.processIdentifier != myPID {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value)
            switch err {
            case .success, .noValue, .attributeUnsupported:
                return true            // the API answered for another app → we have access
            case .apiDisabled, .notImplemented:
                return false           // definitively no access
            default:
                continue               // inconclusive for this app; try the next
            }
        }
        return false                   // couldn't get a definitive yes → assume not granted
    }

    /// Actively trigger the system "grant Accessibility?" dialog (shown once when
    /// not yet trusted). Lower friction than making the user hunt through Settings.
    func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Input Monitoring

    /// The ONLY reliable way to check Input Monitoring permission:
    /// try to create a CGEvent tap. If it succeeds, permission is granted.
    /// Immediately destroy the test tap.
    ///
    /// Deliberately `.listenOnly`: this runs every 5 seconds forever, and a passive
    /// tap is the check that observes without asking for anything. Asking is a
    /// separate, user-initiated act — see `requestInputMonitoring()`.
    private func checkInputMonitoring() {
        let testTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )

        if let tap = testTap {
            inputMonitoringGranted = true
            // Tear the probe down properly. `tapEnable(false)` only stops delivery;
            // the mach port itself lived on, and this function runs every 5 seconds
            // for the lifetime of the app.
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        } else {
            inputMonitoringGranted = false
        }
    }

    /// Ask macOS for Input Monitoring, rather than just pointing at the pane.
    ///
    /// The `.listenOnly` probe above is invisible to TCC: it neither prompts nor
    /// registers mull in Privacy & Security → Input Monitoring. So the onboarding
    /// row used to open a Settings pane in which mull might not be listed at all,
    /// leaving the user to work out that they had to click "+" and go find the app
    /// in /Applications — for the single permission the product cannot work without.
    ///
    /// A tap that can *alter* events (`.defaultTap`) is what makes the system
    /// register the app and show its prompt. This creates exactly one, never enables
    /// it, and invalidates it immediately — no keystroke ever reaches the callback.
    ///
    /// Whether macOS still has an Input Monitoring dialog left to show.
    ///
    /// TCC shows each prompt once and then keeps the answer, so "not granted" and
    /// "asking will do nothing visible" are different states, and the caller wants
    /// opposite things on screen for each: a dialog to answer, or the Settings pane
    /// to go and find the switch in. Only `unknown` — never asked — still prompts.
    ///
    /// `requestInputMonitoring()` below can't answer this. It reports whether the
    /// tap was created, and on a first run the tap fails *while* raising the very
    /// dialog whose absence its failure was being read as proof of.
    ///
    /// Must be read before asking: immediately afterwards the user has not answered
    /// yet, so the state is still `unknown` and says nothing about what happened.
    var inputMonitoringPromptAvailable: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown
    }

    /// Returns true when the tap succeeded, i.e. permission is already granted and
    /// no prompt will appear. When it returns false a prompt may or may not have
    /// appeared — ask `inputMonitoringPromptAvailable` first to tell those apart.
    @discardableResult
    func requestInputMonitoring() -> Bool {
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )

        guard let tap else {
            inputMonitoringGranted = false
            return false
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        inputMonitoringGranted = true
        return true
    }

    /// Whether we have enough permissions to record anything useful.
    /// Clipboard always works. Window titles need Accessibility. Keystrokes need Input Monitoring.
    var canRecordKeystrokes: Bool { inputMonitoringGranted }

    /// A grant mull is short of **and currently wants**.
    ///
    /// Every surface that warns about Input Monitoring asks this rather than
    /// `inputMonitoringGranted`, because keystroke capture is off by default now
    /// (`Preferences.keystrokeCaptureEnabled`). Without the second half, the first
    /// thing a new user would see is a red banner demanding a permission for a channel
    /// mull is not using and did not ask them for — which is how people learn to
    /// ignore the banner that matters.
    var inputMonitoringMissing: Bool {
        Preferences.keystrokeCaptureEnabled && !inputMonitoringGranted
    }
    var canRecordWindowTitles: Bool { accessibilityGranted }
    var canRecordClipboard: Bool { true } // Always available

    /// Open the relevant System Settings pane.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
