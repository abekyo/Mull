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
        .frame(width: 460, height: 520)
        .background(.ultraThinMaterial)
        .interactiveDismissDisabled()
        .onDisappear {
            permissionCheckTimer?.invalidate()
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: DS.xl) {
            Spacer()

            // Hero icon with gradient
            ZStack {
                Circle()
                    .fill(DS.accentGradient)
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 16, y: 4)
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
            }

            VStack(spacing: DS.sm) {
                Text("Whatly")
                    .font(.system(size: 28, weight: .bold))

                Text("Remember everything.\nExplain nothing.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Value props
            VStack(alignment: .leading, spacing: DS.md) {
                valueProp(icon: "eye.slash", text: "Silently records what you work on")
                valueProp(icon: "moon.stars", text: "AI summarizes your day every night")
                valueProp(icon: "brain.head.profile", text: "Any AI instantly knows your context")
            }
            .padding(.horizontal, 48)

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

    @State private var showHowTo = false

    private var permissionsStep: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "hand.raised.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            Text("Two Permissions Needed")
                .font(.system(size: 18, weight: .semibold))

            Text("Whatly needs these to record your activity.\nAll data stays on your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // Permission checklist
            VStack(alignment: .leading, spacing: 10) {
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
            .padding(.horizontal, 36)

            // Status
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

            // How-to guide (expandable)
            Button {
                withAnimation(.spring(duration: 0.2)) { showHowTo.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showHowTo ? "chevron.down" : "questionmark.circle")
                        .font(.system(size: 11))
                    Text(showHowTo ? "Hide instructions" : "How do I grant permissions?")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            if showHowTo {
                howToGuide
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer()

            VStack(spacing: 6) {
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
            .padding(.bottom, 20)
        }
        .onAppear { startPermissionPolling() }
    }

    // MARK: - How-To Guide

    private var howToGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Accessibility
            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility")
                    .font(.system(size: 12, weight: .semibold))

                howToStep("1", "Click \"Open Settings\" above (or go to System Settings → Privacy & Security → Accessibility)")
                howToStep("2", "Click the lock icon 🔒 at bottom-left and authenticate")
                howToStep("3", "Find \"Whatly\" in the list and toggle it ON")
                howToStep("", "If Whatly isn't listed, click \"+\" and add it")
            }

            Divider()

            // Input Monitoring
            VStack(alignment: .leading, spacing: 4) {
                Text("Input Monitoring")
                    .font(.system(size: 12, weight: .semibold))

                howToStep("1", "Go to System Settings → Privacy & Security → Input Monitoring")
                howToStep("2", "Click the lock icon 🔒 and authenticate")
                howToStep("3", "Click \"+\" and add \"Whatly\"")
                howToStep("", "If running from Xcode: add \"Xcode\" instead (Summary runs as Xcode's child process)")
            }

            Divider()

            // After granting
            VStack(alignment: .leading, spacing: 4) {
                Text("After granting both:")
                    .font(.system(size: 12, weight: .semibold))
                howToStep("", "Restart Whatly (⌘Q → reopen, or ⌘R in Xcode)")
                howToStep("", "The checkmarks above will turn green automatically")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 28)
    }

    private func howToStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if !number.isEmpty {
                Text(number)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 12)
            } else {
                Text("→")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
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

            Text("Whatly is ready.")
                .font(.system(size: 18, weight: .semibold))

            VStack(spacing: 8) {
                instructionRow(icon: "moon.fill", text: "Find Whatly in your menu bar (☽)")
                instructionRow(icon: "clock", text: "Tonight at 23:00, your first summary appears")
                instructionRow(icon: "brain.head.profile", text: "Press ⌘A anytime to share context with AI")
            }
            .padding(.horizontal, 40)

            Spacer()

            Button {
                appState.hasCompletedOnboarding = true
                appState.startRecording()
                isPresented = false
                // Close the onboarding window
                (NSApp.delegate as? AppDelegate)?.closeOnboarding()
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

    private func valueProp(icon: String, text: String) -> some View {
        HStack(spacing: DS.md) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            Text(text)
                .font(DS.bodyFont)
                .foregroundStyle(.secondary)
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
