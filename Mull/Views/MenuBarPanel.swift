import SwiftUI

/// Menu bar panel — control panel only.
///
/// No information display. No search. No summaries.
/// Just: status + 3 actions.
///
///   1. Recording status (running / paused / events count)
///   2. Copy to AI (one click)
///   3. Open Dashboard (⇧⌘D)
///   4. Pause / Resume
struct MenuBarPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var showCopied = false

    var body: some View {
        VStack(spacing: 0) {
            // Permission banner — only on setup
            if !appState.permissions.inputMonitoringGranted || !appState.permissions.accessibilityGranted {
                permissionBanner
                Divider()
            }

            // Status
            statusRow
                .padding(.horizontal, DS.lg)
                .padding(.vertical, DS.md)

            Divider()

            // Actions
            VStack(spacing: 2) {
                panelButton(
                    icon: showCopied ? "checkmark" : "doc.on.clipboard",
                    label: showCopied ? "Copied!" : "Copy to AI",
                    hint: "⇧⌘C",
                    accent: true
                ) {
                    appState.copyContextToClipboard()
                    withAnimation(.spring(duration: 0.2)) { showCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.spring(duration: 0.2)) { showCopied = false }
                    }
                }

                panelButton(
                    icon: "square.grid.2x2",
                    label: "Open Dashboard",
                    hint: "⇧⌘D",
                    accent: false
                ) {
                    appState.openMainWindow()
                    NSApp.keyWindow?.close()
                }

                panelButton(
                    icon: appState.isPaused ? "play.fill" : "pause.fill",
                    label: appState.isPaused ? "Resume Recording" : "Pause Recording",
                    hint: nil,
                    accent: false
                ) {
                    appState.isPaused.toggle()
                }
            }
            .padding(.horizontal, DS.sm)
            .padding(.vertical, DS.sm)

            if appState.isSummarizing {
                Divider()

                HStack(spacing: DS.sm) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(appState.mullProgress ?? "Summarizing...")
                        .font(DS.captionFont)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, DS.lg)
                .padding(.vertical, DS.sm)
            }
        }
        .frame(width: DS.panelWidth)
    }

    // MARK: - Status Row

    private var statusRow: some View {
        HStack(spacing: DS.sm) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.5), radius: appState.isRecording && !appState.isPaused ? 4 : 0)

            VStack(alignment: .leading, spacing: 1) {
                Text(statusLabel)
                    .font(DS.bodyMedium)
                Text("\(appState.todayEventCount) events today")
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Spacer()

            Text(appState.todayStorageFormatted)
                .font(DS.microFont)
                .foregroundStyle(.quaternary)
        }
    }

    private var statusColor: Color {
        if appState.isPaused { return DS.paused }
        if appState.isRecordingDegraded { return DS.paused }
        if appState.isRecording { return DS.recording }
        return DS.error
    }

    private var statusLabel: String {
        if appState.isPaused { return "Paused" }
        if appState.isRecordingDegraded { return "Limited — check Input Monitoring" }
        if appState.isRecording { return "Recording" }
        return "Stopped"
    }

    // MARK: - Panel Button

    private func panelButton(icon: String, label: String, hint: String?, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.sm) {
                Image(systemName: icon)
                    .font(DS.smallFont)
                    .frame(width: 16)
                Text(label)
                    .font(accent ? DS.bodyMedium : DS.bodyFont)
                Spacer()
                if let hint {
                    Text(hint)
                        .font(DS.miniMedium)
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, DS.md)
            .padding(.vertical, DS.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusSm)
                    .fill(accent ? Color.accentColor.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent ? Color.accentColor : .primary)
    }

    // MARK: - Permission Banner

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.paused)
                Text("Permissions needed")
                    .font(DS.bodyMedium)
            }

            if !appState.permissions.accessibilityGranted {
                permissionRow(
                    name: "Accessibility",
                    detail: "Window titles",
                    action: { appState.permissions.openAccessibilitySettings() }
                )
            }
            if !appState.permissions.inputMonitoringGranted {
                permissionRow(
                    name: "Input Monitoring",
                    detail: "Keyboard recording",
                    action: { appState.permissions.openInputMonitoringSettings() }
                )
            }
        }
        .padding(.horizontal, DS.lg)
        .padding(.vertical, DS.md)
    }

    private func permissionRow(name: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: DS.sm) {
            Image(systemName: "xmark.circle.fill")
                .font(DS.smallFont)
                .foregroundStyle(DS.error)

            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(DS.bodyFont)
                Text(detail)
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Grant") { action() }
                .font(DS.captionFont)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
