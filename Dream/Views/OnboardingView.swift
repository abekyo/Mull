import SwiftUI
import ApplicationServices

/// Shown once on first launch as a standalone window (NOT a sheet inside the panel).
/// Solves: "I opened Dream but nothing happened."
///
/// Flow: Welcome → Permission (polls until granted) → Ready → Done
/// Goal: from launch to recording in under 30 seconds.
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var step: OnboardingStep = .welcome
    @State private var permissionCheckTimer: Timer?

    enum OnboardingStep {
        case welcome
        case permissions
        case ready
    }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .welcome:
                welcomeStep
            case .permissions:
                permissionsStep
            case .ready:
                readyStep
            }
        }
        .frame(width: 440, height: 380)
        .background(.ultraThinMaterial)
        .interactiveDismissDisabled()
        .onDisappear {
            permissionCheckTimer?.invalidate()
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "moon.stars.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Dream")
                .font(.system(size: 24, weight: .semibold))

            Text("Remember everything.\nExplain nothing.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Dream lives in your menu bar and silently\nrecords what you work on. Every night, AI\nsummarizes your day.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            // Skip permission if already granted (e.g. reinstall)
            Button {
                appState.permissions.checkAll()
                if appState.permissions.inputMonitoringGranted && appState.permissions.accessibilityGranted {
                    withAnimation { step = .ready }
                } else {
                    withAnimation { step = .permissions }
                }
            } label: {
                Text("Get Started")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Step 2: Permissions (polls until both granted)

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "hand.raised.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            Text("Two Permissions Needed")
                .font(.system(size: 18, weight: .semibold))

            Text("Dream needs these to record your activity.\nAll data stays on your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // Permission checklist
            VStack(alignment: .leading, spacing: 12) {
                permissionCheckRow(
                    name: "Accessibility",
                    detail: "Read window titles",
                    granted: appState.permissions.accessibilityGranted,
                    action: { appState.permissions.openAccessibilitySettings() }
                )
                permissionCheckRow(
                    name: "Input Monitoring",
                    detail: "Record keyboard input",
                    granted: appState.permissions.inputMonitoringGranted,
                    action: { appState.permissions.openInputMonitoringSettings() }
                )
            }
            .padding(.horizontal, 40)

            if appState.permissions.accessibilityGranted && appState.permissions.inputMonitoringGranted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("All permissions granted!")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.green)
                }
                .transition(.opacity)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for permissions...")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(spacing: 8) {
                // Skip button if user doesn't want to grant (clipboard still works)
                if !appState.permissions.accessibilityGranted || !appState.permissions.inputMonitoringGranted {
                    Button {
                        withAnimation { step = .ready }
                    } label: {
                        Text("Skip — clipboard recording still works")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 4) {
                    Image(systemName: "menubar.arrow.up.rectangle")
                        .font(.system(size: 10))
                    Text("Look for the ☽ icon in your menu bar")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .onAppear { startPermissionPolling() }
    }

    private func permissionCheckRow(name: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if !granted {
                Button("Open Settings") { action() }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func startPermissionPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in
                appState.permissions.checkAll()
                if appState.permissions.accessibilityGranted && appState.permissions.inputMonitoringGranted {
                    permissionCheckTimer?.invalidate()
                    withAnimation(.spring(duration: 0.3)) { step = .ready }
                }
            }
        }
    }

    // MARK: - Step 3: Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Dream is ready.")
                .font(.system(size: 18, weight: .semibold))

            VStack(spacing: 8) {
                instructionRow(icon: "moon.fill", text: "Find Dream in your menu bar (☽)")
                instructionRow(icon: "clock", text: "Tonight at 23:00, your first summary appears")
                instructionRow(icon: "brain.head.profile", text: "Press ⌘A anytime to share context with AI")
            }
            .padding(.horizontal, 40)

            Spacer()

            Button {
                appState.hasCompletedOnboarding = true
                appState.startRecording()
                isPresented = false
            } label: {
                Text("Start Recording")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
    }

    private func instructionRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

}
