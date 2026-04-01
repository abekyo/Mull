import SwiftUI
import ApplicationServices

/// Onboarding — the first 2 minutes that define whether the user keeps the app.
///
/// Flow:
///   1. Welcome (10s) — set expectation
///   2. Permissions (30s) — get it done
///   3. Live proof (30s) — watch events appear in real-time
///   4. Try it (30s) — ⌘+Shift+C → paste → "wow"
///
/// The "wow" must happen within 2 minutes of install.
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var step: OnboardingStep = .welcome
    @State private var permissionCheckTimer: Timer?
    @State private var showHowTo = false
    @State private var liveEventCount = 0
    @State private var liveTimer: Timer?
    @State private var showCopiedConfirmation = false

    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case permissions = 1
        case liveProof = 2
        case tryIt = 3
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: DS.sm) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, DS.lg)

            // Content
            switch step {
            case .welcome:
                welcomeStep
            case .permissions:
                permissionsStep
            case .liveProof:
                liveProofStep
            case .tryIt:
                tryItStep
            }
        }
        .frame(width: 500, height: 560)
        .background(.ultraThinMaterial)
        .interactiveDismissDisabled()
        .onDisappear {
            permissionCheckTimer?.invalidate()
            liveTimer?.invalidate()
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: DS.xl) {
            Spacer()

            ZStack {
                Circle()
                    .fill(DS.accentGradient)
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.accentColor.opacity(0.2), radius: 16, y: 4)
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
            }

            VStack(spacing: DS.sm) {
                Text("Whatly")
                    .font(.system(size: 28, weight: .bold))

                Text("Know what you did.\nStop explaining yourself to AI.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: DS.md) {
                valueProp(icon: "eye.slash", text: "Runs silently while you work")
                valueProp(icon: "doc.text", text: "Structures your day automatically")
                valueProp(icon: "brain.head.profile", text: "AI knows your context — you explain nothing")
            }
            .padding(.horizontal, 48)

            Spacer()

            Button {
                appState.permissions.checkAll()
                if appState.permissions.inputMonitoringGranted && appState.permissions.accessibilityGranted {
                    withAnimation { step = .liveProof }
                    startRecordingAndProof()
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
            .padding(.bottom, DS.xl)
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: DS.lg) {
            Spacer()

            Image(systemName: "hand.raised.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            Text("Two permissions needed")
                .font(.system(size: 18, weight: .semibold))

            Text("Whatly needs these to record your activity.\nAll data stays on your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: DS.md) {
                permissionRow(
                    name: "Accessibility",
                    detail: "Read window titles",
                    granted: appState.permissions.accessibilityGranted,
                    action: { appState.permissions.openAccessibilitySettings() }
                )
                permissionRow(
                    name: "Input Monitoring",
                    detail: "Record keyboard input",
                    granted: appState.permissions.inputMonitoringGranted,
                    action: { appState.permissions.openInputMonitoringSettings() }
                )
            }
            .padding(.horizontal, 40)

            if appState.permissions.accessibilityGranted && appState.permissions.inputMonitoringGranted {
                HStack(spacing: DS.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DS.recording)
                    Text("All set!")
                        .font(DS.bodyMedium)
                        .foregroundStyle(DS.recording)
                }
            } else {
                // How-to toggle
                Button {
                    withAnimation { showHowTo.toggle() }
                } label: {
                    Text(showHowTo ? "Hide instructions" : "How do I do this?")
                        .font(DS.captionFont)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                if showHowTo {
                    howToGuide
                        .transition(.opacity)
                }
            }

            Spacer()

            Button("Skip — clipboard still works") {
                withAnimation { step = .liveProof }
                startRecordingAndProof()
            }
            .font(DS.captionFont)
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .padding(.bottom, DS.sm)
        }
        .onAppear { startPermissionPolling() }
    }

    // MARK: - Step 3: Live Proof (the magic moment)

    private var liveProofStep: some View {
        VStack(spacing: DS.xl) {
            Spacer()

            // Live counter — numbers going up
            VStack(spacing: DS.sm) {
                Text("\(liveEventCount)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text("moments captured")
                    .font(DS.bodyFont)
                    .foregroundStyle(.secondary)
            }

            // Pulse
            ZStack {
                Circle()
                    .fill(DS.recording.opacity(0.1))
                    .frame(width: 40, height: 40)
                Circle()
                    .fill(DS.recording.opacity(0.2))
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(DS.recording)
                    .frame(width: 10, height: 10)
            }

            Text("Whatly is recording your activity right now.\nKeep working normally — switch apps, type, copy text.")
                .font(DS.bodyFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button {
                withAnimation { step = .tryIt }
            } label: {
                Text("Next: Try it out")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .padding(.horizontal, 40)
            .padding(.bottom, DS.xl)
            .disabled(liveEventCount < 3)
            .opacity(liveEventCount >= 3 ? 1 : 0.5)
        }
    }

    // MARK: - Step 4: Try It

    private var tryItStep: some View {
        VStack(spacing: DS.xl) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: DS.sm) {
                Text("Try it now")
                    .font(.system(size: 20, weight: .semibold))

                Text("Press the button below to copy your context,\nthen paste it into Claude, ChatGPT, or any AI.")
                    .font(DS.bodyFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // The big copy button
            Button {
                appState.copyContextToClipboard()
                withAnimation(.spring(duration: 0.3)) {
                    showCopiedConfirmation = true
                }
            } label: {
                HStack(spacing: DS.sm) {
                    Image(systemName: "doc.on.clipboard.fill")
                    Text("Copy My Context")
                }
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .padding(.horizontal, 40)

            if showCopiedConfirmation {
                VStack(spacing: DS.sm) {
                    HStack(spacing: DS.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(DS.recording)
                        Text("Copied!")
                            .font(DS.bodyMedium)
                            .foregroundStyle(DS.recording)
                    }

                    Text("Now paste it (⌘V) at the start of any AI conversation.")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                }
                .transition(.opacity)
            }

            // Shortcut hint
            VStack(spacing: DS.xs) {
                Text("You can do this anytime with")
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
                Text("⌘ + Shift + C")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()

            Button {
                finishOnboarding()
            } label: {
                Text("Done")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .padding(.horizontal, 40)
            .padding(.bottom, DS.xl)
        }
    }

    // MARK: - Helpers

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

    private func permissionRow(name: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: DS.md) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(granted ? AnyShapeStyle(DS.recording) : AnyShapeStyle(.tertiary))

            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(DS.bodyMedium)
                Text(detail).font(DS.captionFont).foregroundStyle(.tertiary)
            }

            Spacer()

            if !granted {
                Button("Open Settings") { action() }
                    .font(DS.captionFont)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var howToGuide: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("1. Click \"Open Settings\" above")
            Text("2. Click the lock icon 🔒 and authenticate")
            Text("3. Click \"+\" and add Whatly")
            Text("From Xcode: add Xcode instead")
                .foregroundStyle(.tertiary)
        }
        .font(DS.captionFont)
        .foregroundStyle(.secondary)
        .padding(DS.md)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSm))
        .padding(.horizontal, 40)
    }

    // MARK: - Actions

    private func startPermissionPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in
                appState.permissions.checkAll()
                if appState.permissions.accessibilityGranted && appState.permissions.inputMonitoringGranted {
                    permissionCheckTimer?.invalidate()
                    // Auto-advance after 1 second
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        withAnimation(.spring(duration: 0.3)) { step = .liveProof }
                        startRecordingAndProof()
                    }
                }
            }
        }
    }

    private func startRecordingAndProof() {
        appState.hasCompletedOnboarding = true
        appState.startRecording()

        // Poll event count to show live numbers
        liveEventCount = appState.todayEventCount
        liveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                let newCount = appState.database.eventCountToday()
                if newCount != liveEventCount {
                    withAnimation(.spring(duration: 0.2)) {
                        liveEventCount = newCount
                    }
                }
            }
        }
    }

    private func finishOnboarding() {
        liveTimer?.invalidate()
        permissionCheckTimer?.invalidate()
        isPresented = false
        (NSApp.delegate as? AppDelegate)?.closeOnboarding()
    }
}
