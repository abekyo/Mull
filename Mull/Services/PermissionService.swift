import Foundation
import AppKit
import ApplicationServices

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
    @Published var eventTapWorking = false

    /// Human-readable status for UI display.
    @Published var statusMessage = "Checking..."

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
        checkAccessibility()
        checkInputMonitoring()
        updateStatusMessage()
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

    /// Empirical probe: is the Accessibility API actually usable right now?
    private func accessibilityAPIEnabled() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value)
        // Denied → .apiDisabled / .notImplemented. Granted → .success / .noValue /
        // .attributeUnsupported (a real read that just had nothing to return).
        return err != .apiDisabled && err != .notImplemented
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
    private func checkInputMonitoring() {
        let testTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passRetained(event) },
            userInfo: nil
        )

        if let tap = testTap {
            inputMonitoringGranted = true
            // Clean up test tap immediately
            CGEvent.tapEnable(tap: tap, enable: false)
        } else {
            inputMonitoringGranted = false
        }
    }

    // MARK: - Status Message

    private func updateStatusMessage() {
        if inputMonitoringGranted {
            statusMessage = "All permissions granted"
            eventTapWorking = true
        } else if accessibilityGranted {
            statusMessage = "Input Monitoring permission needed for keystroke recording"
            eventTapWorking = false
        } else {
            statusMessage = "Accessibility and Input Monitoring permissions needed"
            eventTapWorking = false
        }
    }

    /// Whether we have enough permissions to record anything useful.
    /// Clipboard always works. Window titles need Accessibility. Keystrokes need Input Monitoring.
    var canRecordKeystrokes: Bool { inputMonitoringGranted }
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
