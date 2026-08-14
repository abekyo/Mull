import XCTest
@testable import mull

/// Keystroke capture is off until the user turns it on, and nothing in mull may ask
/// for Input Monitoring before then.
///
/// This is a lint wearing a test's clothes, like `EvalReachabilityTests` and
/// `ShippedVocabularyTests`, and for the same reason: the promise lives in code paths
/// no unit test can reach. Creating a CGEvent tap needs a real session, a real TCC
/// decision and a real prompt, so the one thing that would actually break — a tap
/// installed on launch — cannot be asserted against by running it. What *can* be
/// asserted is that the guards are still written down.
///
/// Every check here corresponds to a way the promise has a plausible route back:
///
/// | Regression | What it would do to a user |
/// |---|---|
/// | A `true` default creeps into either declaration | Input Monitoring prompt on first launch |
/// | `start()` stops consulting the preference | Tap installed regardless of the switch |
/// | The health-check guard is dropped | Prompt every ten seconds, forever |
/// | Onboarding asks again | The heaviest grant back in the install decision |
///
/// The measurement behind the decision is on `Preferences.keystrokeCaptureEnabled`;
/// the reasoning is CLAUDE.md §8.3.
final class KeystrokeOptInTests: XCTestCase {

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/
            .deletingLastPathComponent()    // repo root
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - Off is the default, in both places that state it

    func testTheSettingIsFalseWhenNobodyHasTouchedIt() {
        // `store.bool(forKey:)` answers false for an unset key, which is the entire
        // mechanism — there is no default to register and none may be added. Asserted
        // against an isolated suite rather than `Preferences.store`, which under a
        // test host is the developer's own live settings.
        let suite = "mull.keystroke.tests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }

        XCTAssertFalse(store.bool(forKey: Preferences.keystrokeCaptureKey),
                       "an untouched install must not be reading the keyboard")
        store.set(true, forKey: Preferences.keystrokeCaptureKey)
        XCTAssertTrue(store.bool(forKey: Preferences.keystrokeCaptureKey),
                      "and it must still be reachable once asked for")
    }

    func testTheToggleAndThePreferenceAgreeOnTheDefault() throws {
        // Two defaults for one key is how a switch comes up showing the opposite of
        // what the recorder is doing. It has happened here before: `dataRetention`
        // displayed "Unlimited" while the pruner deleted everything past 90 days.
        let settings = try source("Mull/Views/Settings/SettingsView.swift")
        XCTAssertTrue(
            settings.contains("@AppStorage(Preferences.keystrokeCaptureKey) private var keystrokeCapture = false"),
            "the Settings toggle must default to false, and must bind the same key Preferences reads"
        )

        let preferences = try source("Mull/Core/Preferences.swift")
        XCTAssertTrue(
            preferences.contains("static var keystrokeCaptureEnabled: Bool { store.bool(forKey: keystrokeCaptureKey) }"),
            "reading through anything that can supply a default is how off-by-default stops being true"
        )
    }

    // MARK: - Nothing installs the tap on its own

    func testStartOnlyInstallsTheTapWhenAskedTo() throws {
        let recording = try source("Mull/Services/RecordingService.swift")
        XCTAssertTrue(
            recording.contains("Preferences.keystrokeCaptureEnabled ? startKeystrokeCapture() : true"),
            "start() must consult the preference; an unconditional call is the prompt on first launch"
        )
    }

    func testTheHealthCheckDoesNotResurrectATapNobodyAskedFor() throws {
        // The tick's recreate branch calls `startKeystrokeCapture()` when `eventTap` is
        // nil — which is exactly the state a user who left this off is in. Unguarded,
        // that is a permission prompt every ten seconds for the life of the process.
        let recording = try source("Mull/Services/RecordingService.swift")
        XCTAssertTrue(
            recording.contains("guard Preferences.keystrokeCaptureEnabled else { return }"),
            "the health check must stand down when there is no tap to keep alive"
        )
    }

    // MARK: - The install decision

    func testOnboardingDoesNotAskForInputMonitoring() throws {
        // The point of the change is that the heaviest grant macOS has is not part of
        // deciding whether to install mull. A row here puts it back.
        let onboarding = try source("Mull/Views/OnboardingView.swift")
        XCTAssertFalse(onboarding.contains("requestInputMonitoring()"),
                       "onboarding must not raise the Input Monitoring prompt")
        XCTAssertFalse(onboarding.contains("openInputMonitoringSettings()"),
                       "nor send the user to the pane for it")
    }

    func testSurfacesAskWhetherTheGrantIsWantedRatherThanOnlyWhetherItIsHeld() throws {
        // `inputMonitoringGranted` alone is false on every fresh install, so a surface
        // that warns on it warns everybody about a channel mull is not using — and a
        // banner that is wrong the first time is one nobody reads the second.
        for relative in ["Mull/Views/MenuBarPanel.swift"] {
            let file = try source(relative)
            XCTAssertFalse(file.contains("!appState.permissions.inputMonitoringGranted"),
                           "\(relative) must ask `inputMonitoringMissing`, which also asks whether mull wants it")
        }
    }
}
