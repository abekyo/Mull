import SwiftUI

/// Menu bar panel — control panel only.
///
/// No information display. No search. No summaries.
/// Just: status + 3 actions.
///
///   1. Recording status (running / paused / events count)
///   2. Copy context (one click)
///   3. Open mull (⇧⌘D)
///   4. Pause / Resume
struct MenuBarPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var showCopied = false
    /// The capture draft outlives the panel. The panel is dismissed by anything —
    /// Escape, a click outside, another app taking focus — and half a thought is
    /// still the user's, not ours to throw away. It comes back on the next open.
    @AppStorage("menuBarCaptureDraft") private var captureText = ""
    @State private var captureSaved = false
    @FocusState private var captureFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Escape closes the panel and leaves the draft alone. Bound explicitly
            // because the field editor's own cancelOperation *clears the field*, which
            // read as "Escape deleted what I typed". A key equivalent is resolved
            // before the field editor sees the key, so this wins.
            Button("") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)

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

            // Quick capture — frictionless drop into the vault (Crane MD 摩擦ゼロ捕捉)
            captureRow
                .padding(.horizontal, DS.lg)
                .padding(.vertical, DS.sm)

            Divider()

            // Actions
            VStack(spacing: DS.hair) {
                panelButton(
                    icon: showCopied ? "checkmark" : "doc.on.clipboard",
                    // "Copy to AI" frames the record as feed handed to a machine.
                    // You are lending your own context; the label says so.
                    label: showCopied ? "Copied" : "Copy context",
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
                    icon: "macwindow",
                    label: "Open mull",
                    hint: "⇧⌘D",
                    accent: false
                ) {
                    appState.openMainWindow()
                    NSApp.keyWindow?.close()
                }

                pauseControl
            }
            .padding(.horizontal, DS.sm)
            .padding(.vertical, DS.sm)

            if appState.isSummarizing {
                Divider()

                HStack(spacing: DS.sm) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(appState.mullProgress ?? "Summarizing…")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkDim)
                }
                .padding(.horizontal, DS.lg)
                .padding(.vertical, DS.sm)
            }
        }
        .frame(width: DS.panelWidth)
    }

    // MARK: - Quick Capture

    /// One focused field. Type a thought, press Return, it's in `09_inbox/captures.md`.
    /// No file picker, no destination prompt, no save button — capture stays cheap so
    /// it actually gets used. mull routes it later.
    private var captureRow: some View {
        HStack(spacing: DS.sm) {
            Image(systemName: captureSaved ? "checkmark.circle.fill" : "square.and.pencil")
                .font(DS.bodyFont)
                .foregroundStyle(captureSaved ? DS.recording : DS.moon)
                // The glyph flipping to a checkmark is the only confirmation that a
                // capture landed — the field clears either way.
                .accessibilityLabel(captureSaved ? "Saved to your inbox" : "Quick capture")

            TextField("Capture a thought…", text: $captureText)
                .textFieldStyle(.plain)
                .font(DS.bodyFont)
                .focused($captureFocused)
                .onSubmit(commitCapture)

            if !captureText.isEmpty {
                Text("↵")
                    .font(DS.microFont)
                    .foregroundStyle(DS.inkFaint)
            }
        }
        // The focus grab is no longer unconditional. When a permission is missing the
        // banner above is what the panel is for, and dropping the caret into a capture
        // field would send the first keystroke of a reaction into the vault. Otherwise
        // the field takes focus so an unfinished draft can simply be carried on.
        .onAppear { captureFocused = permissionsSettled }
    }

    private var permissionsSettled: Bool {
        appState.permissions.inputMonitoringGranted && appState.permissions.accessibilityGranted
    }

    /// Close the panel without touching the draft.
    private func dismiss() {
        NSApp.keyWindow?.close()
    }

    private func commitCapture() {
        guard QuickCapture.append(captureText) else { return }
        captureText = ""
        withAnimation(.spring(duration: 0.2)) { captureSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.spring(duration: 0.2)) { captureSaved = false }
        }
        captureFocused = true
    }

    // MARK: - Status Row

    private var statusRow: some View {
        HStack(spacing: DS.sm) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.5), radius: appState.isRecording && !appState.isPaused ? 4 : 0)

            VStack(alignment: .leading, spacing: DS.hair) {
                // A degraded state is not a caption, it is a thing to fix — so the line
                // that names it is the control that opens the pane that fixes it.
                if appState.isRecordingDegraded && !appState.isPaused {
                    Button { appState.permissions.openInputMonitoringSettings() } label: {
                        HStack(spacing: DS.xs) {
                            Text("Limited — open Input Monitoring")
                                .font(DS.bodyMedium)
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(DS.moon)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("mull's keyboard tap is not delivering events — open the system pane")
                } else {
                    Text(statusLabel)
                        .font(DS.bodyMedium)
                }
                Text("\(appState.todayCaptureLabel) today")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .monospacedDigit()
                    .help("Stored records — keystroke buffers, clipboard entries, window and app changes. Not a measure of what you did.")
            }

            Spacer()

            Text(appState.todayStorageFormatted)
                .font(DS.microFont)
                .foregroundStyle(DS.inkGhost)
        }
        // Paused and degraded draw the same amber dot, so the colour never
        // distinguished all four states even for someone who can see it. The
        // spoken value is `statusLabel`, which does.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording status")
        .accessibilityValue(statusLabel)
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

    // MARK: - Pause control (real — stops capture; timed or until-resume)
    //
    // The control names the state's *exit*, never an action the state cannot take.
    // Offering "Pause Recording" while nothing is recording was the panel describing
    // a world it wasn't in.

    @ViewBuilder
    private var pauseControl: some View {
        if appState.isPaused {
            panelButton(
                icon: "play.fill",
                label: "Resume Recording",
                hint: resumeHint,
                accent: false
            ) {
                appState.resumeCapture()
            }
        } else if !appState.isRecording {
            // Stopped: the only move is to start again.
            panelButton(
                icon: "record.circle",
                label: "Start Recording",
                hint: nil,
                accent: false
            ) {
                appState.startRecording()
            }
        } else {
            Menu {
                Button("Pause for 15 minutes") { appState.pauseCapture(for: 15 * 60) }
                Button("Pause for 1 hour") { appState.pauseCapture(for: 60 * 60) }
                Button("Pause until I resume") { appState.pauseCapture() }
            } label: {
                pauseLabel(icon: "pause.fill", label: "Pause Recording")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(DS.ink)
        }
    }

    /// "resumes 14:30" when a timed pause is active.
    private var resumeHint: String? {
        guard let ends = appState.pauseEndsAt else { return nil }
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("jmm")
        return "until \(f.string(from: ends))"
    }

    private func pauseLabel(icon: String, label: String) -> some View {
        HStack(spacing: DS.sm) {
            Image(systemName: icon)
                .font(DS.smallFont)
                .frame(width: 16)
            Text(label)
                .font(DS.bodyFont)
            Spacer()
        }
        .padding(.horizontal, DS.md)
        .padding(.vertical, DS.sm)
        .contentShape(Rectangle())
    }

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
                        .foregroundStyle(DS.inkGhost)
                }
            }
            .padding(.horizontal, DS.md)
            .padding(.vertical, DS.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusSm)
                    .fill(accent ? DS.moon.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent ? DS.moon : DS.ink)
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
                    .foregroundStyle(DS.inkFaint)
            }

            Spacer()

            Button("Grant") { action() }
                .font(DS.captionFont)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
