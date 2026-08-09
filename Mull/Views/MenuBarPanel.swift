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
    /// Why the last capture didn't land. Shown under the field — the draft is
    /// still in it, so silence would read as "saved".
    @State private var captureProblem: String?
    @FocusState private var captureFocused: Bool
    /// A surveyed-but-unconfirmed forget.
    @State private var pending: PendingForget?
    /// What a confirmed forget failed to do, waiting to be told. The user who
    /// pressed Forget is looking at this panel, not the main window's notice
    /// bar — so the bad news has to arrive here.
    @State private var forgetProblem: String?

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
                // The icon's rings behind the panel's masthead, at a whisper —
                // the one surface seen many times a day carries the same figure
                // as the Dock. Texture, not information: it never changes.
                .background(
                    StippleRings(center: CGPoint(x: 0.92, y: 0.2))
                        .opacity(0.06)
                        .clipped()
                )

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
                    // Panel first, window second. Closing `NSApp.keyWindow` *after*
                    // opening the main window closes the main window — it is the key
                    // one by then. That was harmless only for as long as the opening
                    // half was broken.
                    NSApp.keyWindow?.close()
                    appState.openMainWindow()
                }

                pauseControl
                forgetControl
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

    /// One focused field. Type a thought, press Return, it's in `inbox.md`.
    /// No file picker, no destination prompt, no save button — capture stays cheap so
    /// it actually gets used. mull routes it later.
    private var captureRow: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(spacing: DS.sm) {
                Image(systemName: captureIcon)
                    .font(DS.bodyFont)
                    .foregroundStyle(captureProblem != nil ? DS.error
                                     : (captureSaved ? DS.recording : DS.moon))
                    // The glyph flipping to a checkmark is the only confirmation that a
                    // capture landed — the field clears on success.
                    .accessibilityLabel(captureProblem != nil ? "Not saved"
                                        : (captureSaved ? "Saved to your inbox" : "Quick capture"))

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

            if let captureProblem {
                Text(captureProblem)
                    .font(DS.captionFont)
                    .foregroundStyle(DS.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The focus grab is no longer unconditional. When a permission is missing the
        // banner above is what the panel is for, and dropping the caret into a capture
        // field would send the first keystroke of a reaction into the vault. Otherwise
        // the field takes focus so an unfinished draft can simply be carried on.
        .onAppear { captureFocused = permissionsSettled }
    }

    private var captureIcon: String {
        if captureProblem != nil { return "exclamationmark.triangle" }
        return captureSaved ? "checkmark.circle.fill" : "square.and.pencil"
    }

    private var permissionsSettled: Bool {
        appState.permissions.inputMonitoringGranted && appState.permissions.accessibilityGranted
    }

    /// Close the panel without touching the draft.
    private func dismiss() {
        NSApp.keyWindow?.close()
    }

    private func commitCapture() {
        // An empty field is a no-op, not a failure — Return on nothing should do
        // nothing quietly. A real write that fails is the opposite: the draft is
        // still in the field and the user has no way to know it didn't land.
        guard !captureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard QuickCapture.append(captureText) else {
            captureProblem = MullDirectory.issueDescription
                ?? "mull couldn't write to ~/mull, so this wasn't saved. It's still here."
            return
        }
        captureProblem = nil
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
                                .font(DS.iconMini)
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
        // Word for word what the on-screen button says, so the spoken status and the
        // visible one never disagree about the same state.
        if appState.isRecordingDegraded { return "Limited — open Input Monitoring" }
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
                menuRowLabel(icon: "pause.fill", label: "Pause Recording")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(DS.ink)
        }
    }

    // MARK: - Forget control
    //
    // Pause is for the thing you see coming. This is for the thing you didn't —
    // and it belongs here, two inches from where it happened, rather than four
    // clicks deep in Settings. Nobody can list in advance the moments they will
    // want back; being able to erase one the second it lands is worth more than
    // any panel of checkboxes configured before the fact.

    @ViewBuilder
    private var forgetControl: some View {
        Menu {
            Button("Forget the last 15 minutes") { planForget(minutes: 15, label: "the last 15 minutes") }
            Button("Forget the last hour") { planForget(minutes: 60, label: "the last hour") }
            Button("Forget today so far") { planForgetToday() }
        } label: {
            menuRowLabel(icon: "eraser", label: "Forget…")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(DS.ink)
        // One question, one sentence, two buttons. Forgetting reaches further
        // than the window the user named — into summaries, memories and frozen
        // snapshots — but reaching correctly is mull's job; making the user
        // audit the reach before agreeing is not.
        .confirmationDialog(
            pending.map { "Forget \($0.label)?" } ?? "Forget?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
        ) {
            if let pending, !pending.plan.isEmpty {
                Button("Forget", role: .destructive) { performForget(pending.plan) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(pending?.message ?? "")
        }
        .alert(
            "Forget didn't finish",
            isPresented: Binding(get: { forgetProblem != nil },
                                 set: { if !$0 { forgetProblem = nil } })
        ) {
            Button("OK", role: .cancel) { forgetProblem = nil }
        } message: {
            Text(forgetProblem ?? "")
        }
    }

    /// A surveyed forget waiting for confirmation.
    private struct PendingForget {
        let label: String
        let plan: ForgetService.Plan

        var message: String {
            [plan.sentence(label: label), plan.warning]
                .compactMap { $0 }
                .joined(separator: "\n\n")
        }
    }

    private func planForget(minutes: Int, label: String) {
        pending = PendingForget(label: label, plan: appState.forgetPlan(lastMinutes: minutes))
    }

    private func planForgetToday() {
        let start = Calendar.current.startOfDay(for: Date())
        let interval = DateInterval(start: start, end: Date())
        pending = PendingForget(label: "today so far",
                                plan: appState.forgetPlan(for: interval))
    }

    /// No confirmation of success. The panel's event count drops and the moment
    /// is over — a second dialog to say "done" would be mull asking to be
    /// thanked for it. Failure is the opposite case: silence there would report
    /// a success that did not happen, so it does get a dialog.
    private func performForget(_ plan: ForgetService.Plan) {
        pending = nil
        forgetProblem = appState.forget(plan).failureMessage
    }

    /// "resumes 14:30" when a timed pause is active.
    private var resumeHint: String? {
        guard let ends = appState.pauseEndsAt else { return nil }
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("jmm")
        return "until \(f.string(from: ends))"
    }

    /// The `panelButton` look, for a row that opens a menu instead of acting.
    /// Shared by Pause and Forget so the two sit flush with the buttons above them.
    private func menuRowLabel(icon: String, label: String) -> some View {
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
