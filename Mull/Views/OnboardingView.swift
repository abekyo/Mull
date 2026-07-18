import SwiftUI
import ApplicationServices

/// Onboarding — the first 2 minutes that define whether the user keeps the app.
///
/// Flow:
///   1. Welcome (10s) — set expectation
///   2. Permissions (30s) — get it done
///   3. What mull can see (30s) — each observation with the source it came from
///   4. Try it (30s) — read the context payload, then copy it if you want it
///
/// The tone throughout is the custode's: this screen sequence asks for the two most
/// invasive permissions macOS has, so every claim on it has to be one mull can keep.
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var step: OnboardingStep
    @State private var permissionCheckTimer: Timer?
    @State private var showHowTo = false
    // Whether mull has already shown the system's own request for each permission.
    // Drives the second tap, which is the only one that opens System Settings.
    @State private var askedAccessibility = false
    @State private var askedInputMonitoring = false
    @State private var showCopiedConfirmation = false
    // Loaded when the profile step appears, not in the initialiser: a default
    // expression runs on every re-init of the struct, and this one reads a file.
    @State private var profileAnswers: [String: String] = [:]

    init(isPresented: Binding<Bool>, startStep: OnboardingStep = .welcome) {
        _isPresented = isPresented
        _step = State(initialValue: startStep)
    }

    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case permissions = 1
        case coldRead = 2    // "What mull can see right now" — sourced, and bounded
        case profile = 3     // "Now lock in the essentials" — guided me.pinned.md
        case tryIt = 4       // The payload, read before it is copied
        case connect = 5     // Hand it to the AI tools already on this Mac
    }

    @State private var coldReading: ColdReading?
    @State private var revealedFactCount = 0
    @State private var factRevealTimer: Timer?
    @State private var coldReadTask: Task<Void, Never>?

    // The exact text "Copy my context" would put on the clipboard, shown before it
    // goes anywhere (根拠を見せる — DESIGN-NORTHSTAR §3.5).
    @State private var contextPreview: String?
    @State private var isLoadingPreview = false
    /// True when nothing has been recorded yet, so the pane is holding only the
    /// live read and the stated profile. The screen says so rather than letting
    /// "written from what mull has seen so far" imply a history that isn't there.
    @State private var previewIsStarterOnly = false

    // Step 6 — the AI clients found on this Mac, and the one awaiting consent.
    @State private var aiTools: [AIToolSetup.AITool] = []
    @State private var pendingConnect: PendingConnect?
    @State private var connectError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Where you are — stated, not scored. Filled dots read as a completion
            // meter (progress mechanics are a named DON'T); a quiet line of type
            // orients without keeping score.
            Text("\(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(DS.microFont)
                .foregroundStyle(DS.inkFaint)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, DS.lg)
                .padding(.horizontal, DS.lg)

            // Content
            switch step {
            case .welcome:
                welcomeStep
            case .permissions:
                permissionsStep
            case .coldRead:
                coldReadStep
            case .profile:
                profileStep
            case .tryIt:
                tryItStep
            case .connect:
                connectStep
            }
        }
        // A floor, not a fixed size. The window is built around this view's fitting
        // size (see AppDelegate.showOnboarding), so the ideal values are what it opens
        // at; the minimums are what stops a resize from cropping the primary button off
        // the bottom, and the absent maximums are what lets a larger system text size
        // — or a user who simply wants a bigger window — have the room.
        .frame(minWidth: 500, idealWidth: 500, maxWidth: .infinity,
               minHeight: 560, idealHeight: 560, maxHeight: .infinity)
        // Paper, not glass: .ultraThinMaterial is the cold-tech surface the design
        // north star bans on anything a person reads (DESIGN-NORTHSTAR / CLAUDE.md §4).
        .background(DS.canvas)
        .interactiveDismissDisabled()
        // The poller belongs to the permissions step alone. It used to keep running
        // after "Skip", so granting a permission ten minutes later yanked the user
        // back to .coldRead — mid-typing, from wherever they had got to.
        .onChange(of: step) { _, newStep in
            if newStep != .permissions { stopPermissionPolling() }
            // Remember where they got to. Onboarding can end without being finished
            // — the window closed, the app quit — and the next start should be the
            // step they owe, not the pitch they have already read.
            appState.onboardingStep = newStep.rawValue
        }
        .onAppear { appState.onboardingStep = step.rawValue }
        .onDisappear {
            stopPermissionPolling()
            factRevealTimer?.invalidate()
            factRevealTimer = nil
            coldReadTask?.cancel()
            coldReadTask = nil
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: DS.xl) {
            Spacer()

            // The mark, drawn rather than lit: a hairline circle and the moon in
            // tobacco. A gradient blob with a glow behind it is the AI-startup
            // icon treatment, and it is not what this app is.
            ZStack {
                Circle()
                    .strokeBorder(DS.moon.opacity(0.3), lineWidth: 1)
                    .frame(width: 72, height: 72)
                Image(systemName: "moon.stars")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(DS.moon)
            }

            VStack(spacing: DS.sm) {
                Text("mull")
                    .font(DS.heroFont)

                Text("Know what you did.\nStop explaining yourself to AI.")
                    .font(DS.titleRegular)
                    .foregroundStyle(DS.inkDim)
                    .multilineTextAlignment(.center)
            }

            // Said plainly, before anything is asked for.
            //
            // This used to read "Records quietly while you work" — for an app whose
            // core function is a keystroke and clipboard recorder, that is softening,
            // not describing. The one sentence the user most needs is the one naming
            // what gets captured, and it belongs on the screen *before* the permission
            // dialog, not in a grey sub-caption underneath the button that triggers it.
            VStack(alignment: .leading, spacing: DS.md) {
                valueProp(icon: "keyboard", text: "Records what you type, copy, and have open")
                valueProp(icon: "doc.text", text: "Keeps the day in plain markdown files you own")
                valueProp(icon: "arrow.up.doc", text: "Hands that context to an AI when you ask")
            }
            .padding(.horizontal, 48)

            Text("It never records password fields, and never any app you exclude.")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button {
                appState.permissions.checkAll()
                if appState.permissions.inputMonitoringGranted && appState.permissions.accessibilityGranted {
                    withAnimation { step = .coldRead }
                    startRecordingAndProof()
                } else {
                    withAnimation { step = .permissions }
                }
            } label: {
                Text("Get Started")
                    .font(DS.subtitleMedium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
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
                .foregroundStyle(DS.moon)

            Text("Two permissions needed")
                .font(DS.headlineFont)

            // "Nothing it records leaves your Mac" was the sentence used to buy the
            // two scariest permissions macOS has — and it stops being true the moment
            // the user turns on a cloud provider in Settings → AI. A promise made at
            // the point of maximum trust must survive the rest of the product.
            Text("mull needs these to see what you're working on. What it records stays on this Mac unless you later turn on a cloud AI — and it will tell you when you do.")
                .font(DS.bodyFont)
                .foregroundStyle(DS.inkDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.lg)

            // Ask the system first; offer Settings only to the user the system
            // couldn't help. Both rows used to lead with (or straight to) the
            // Settings pane, which is the slowest path and, for Input Monitoring,
            // often a pane mull was not even listed in.
            VStack(alignment: .leading, spacing: DS.md) {
                permissionRow(
                    name: "Accessibility",
                    detail: "Read window titles",
                    granted: appState.permissions.accessibilityGranted,
                    // The prompt and System Settings used to be fired back to back,
                    // so the modal grant dialog and a whole Settings window raced for
                    // the foreground and the user answered whichever one they could
                    // see — usually dismissing the dialog that would have done it in
                    // one click. One thing at a time.
                    asked: askedAccessibility,
                    action: {
                        if askedAccessibility {
                            appState.permissions.openAccessibilitySettings()
                        } else {
                            askedAccessibility = true
                            appState.permissions.promptAccessibility()
                        }
                    }
                )
                permissionRow(
                    name: "Input Monitoring",
                    detail: "Record keyboard input",
                    granted: appState.permissions.inputMonitoringGranted,
                    asked: askedInputMonitoring,
                    action: {
                        if askedInputMonitoring {
                            appState.permissions.openInputMonitoringSettings()
                        } else {
                            askedInputMonitoring = true
                            // Creating a real tap is what makes macOS register mull
                            // in the Input Monitoring list and show its prompt; the
                            // passive check the app polls with does neither. Without
                            // this the row dropped the user into a pane where mull
                            // might not appear at all.
                            appState.permissions.requestInputMonitoring()
                        }
                    }
                )
            }
            .padding(.horizontal, 40)

            if appState.permissions.accessibilityGranted && appState.permissions.inputMonitoringGranted {
                HStack(spacing: DS.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DS.recording)
                    Text("mull is recording")
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
                        .foregroundStyle(DS.moon)
                }
                .buttonStyle(.plain)

                if showHowTo {
                    howToGuide
                        .transition(.opacity)
                }
            }

            Spacer()

            // Skipping is allowed, and it is described.
            //
            // "Skip — clipboard still works" read as a reassurance; what it actually
            // buys is a recorder that keeps taking everything you copy — passwords
            // pasted from a manager, addresses, message drafts — and nothing else,
            // which is the least useful and least expected half of the product. And
            // it used to mark onboarding *complete*, so mull never asked again: a
            // keystroke recorder that records no keystrokes, permanently.
            VStack(spacing: DS.xs) {
                Button("Skip for now") {
                    stopPermissionPolling()
                    withAnimation { step = .coldRead }
                    startRecordingAndProof()
                }
                .font(DS.captionFont)
                .buttonStyle(.plain)
                .foregroundStyle(DS.inkDim)

                Text("mull will still record everything you copy, and nothing else. Finish this later from the mull menu.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .padding(.bottom, DS.sm)
        }
        .onAppear { startPermissionPolling() }
    }

    // MARK: - Step 3: What mull can see right now

    /// This screen arrives seconds after the user granted a keystroke recorder access
    /// to their machine — the single most anxious moment in the product. It used to
    /// open with "Here's what I already know" and close with "Imagine what mull knows
    /// after a full day", which is the patter of a fortune teller. From something that
    /// genuinely can watch everything you type, the same line is a threat.
    ///
    /// So it says the smaller, true thing: here is what is visible right now, this is
    /// where each item came from, none of it was recorded, and you decide where it
    /// goes. Reassurance, not a demonstration of reach (DESIGN-NORTHSTAR §0/§1).
    private var coldReadStep: some View {
        VStack(spacing: DS.lg) {
            Spacer()

            VStack(spacing: DS.xs) {
                Text("What mull can see right now")
                    .font(DS.headlineFont)
                // Not "nothing has been recorded yet" — recording starts when this
                // step is entered, and the screen must not open with a claim that is
                // already false. What is true is where these lines came from.
                Text("Read just now from what's open on this Mac — not from anything mull has stored.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            VStack(alignment: .leading, spacing: DS.md) {
                if coldReading == nil {
                    coldReadLoadingState
                } else if hasColdRead, let reading = coldReading {
                    ForEach(Array(reading.facts.prefix(revealedFactCount).enumerated()), id: \.offset) { _, fact in
                        HStack(alignment: .top, spacing: DS.md) {
                            // A typographic bullet, not a glyph. These are plain
                            // observations; marking them with "magic" iconography
                            // would claim they were conjured rather than read.
                            Circle()
                                .fill(DS.moon.opacity(0.45))
                                .frame(width: 4, height: 4)
                                .padding(.top, 7)
                            Text(fact)
                                .font(DS.bodyFont)
                                .foregroundStyle(DS.ink)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if coldReading?.timedOut == true {
                        Text("One of those checks didn't answer in time, so this list is short.")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.inkFaint)
                    }
                } else {
                    // A cold read can legitimately come back empty (fresh Mac, nothing
                    // open, no calendar access). An empty 200pt box under a headline
                    // promising knowledge read as a bug — say the truth instead.
                    coldReadEmptyState
                }
            }
            .padding(.horizontal, 40)
            .frame(minHeight: 200, alignment: .top)

            if hasColdRead, revealedFactCount >= (coldReading?.facts.count ?? 0) {
                Text("That's the whole of it, and it stays on this Mac. Nothing is sent anywhere until you send it, and you can pause or delete any of it whenever you like.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .transition(.opacity)
            }

            Spacer()

            // Never gated. The old screen disabled Continue for 2.4 seconds while the
            // reveal played out — an unexplained dead button on a screen the user may
            // well want to leave immediately. The staged fade is decoration; leaving
            // is always available, and doing so stops the reveal.
            Button {
                factRevealTimer?.invalidate()
                factRevealTimer = nil
                withAnimation { step = .profile }
            } label: {
                Text("Continue")
                    .font(DS.subtitleMedium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            .padding(.bottom, DS.xl)
        }
        .onAppear { startColdRead() }
    }

    /// The read runs off the main thread, so this is a real wait — say so rather than
    /// showing an empty frame.
    private var coldReadLoadingState: some View {
        HStack(spacing: DS.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Looking at what's open…")
                .font(DS.bodyFont)
                .foregroundStyle(DS.inkDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DS.xl)
    }

    // MARK: - Step 4: Profile (guided me.pinned.md — stated facts mull can't infer)

    private var profileStep: some View {
        VStack(spacing: DS.md) {
            VStack(spacing: DS.xs) {
                Text("Tell mull the essentials")
                    .font(DS.headlineFont)
                Text("Every field is optional. Skip what you like; you can correct any of it later in About Me — your edits.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, DS.lg)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.lg) {
                    ForEach(OnboardingProfile.questions) { q in
                        VStack(alignment: .leading, spacing: DS.xs) {
                            Text(q.prompt)
                                .font(DS.bodyMedium)
                            Text(q.hint)
                                .font(DS.captionFont)
                                .foregroundStyle(DS.inkFaint)
                            TextField(q.placeholder, text: Binding(
                                get: { profileAnswers[q.id] ?? "" },
                                set: { profileAnswers[q.id] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, DS.sm)
            }

            HStack {
                Button("Skip") {
                    withAnimation { step = .tryIt }
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.inkFaint)
                .font(DS.captionFont)

                Spacer()

                Button {
                    OnboardingProfile.save(profileAnswers)
                    appState.regenerateContextNow()
                    withAnimation { step = .tryIt }
                } label: {
                    Text("Save & Continue")
                        .font(DS.subtitleMedium)
                        .padding(.horizontal, DS.lg)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, DS.lg)
        }
        // Read the saved answers here — the file read happens once, when the step is
        // actually shown, rather than on every re-init of the view struct.
        .onAppear {
            if profileAnswers.isEmpty { profileAnswers = OnboardingProfile.answers }
        }
    }

    /// True when the cold read actually produced something to show.
    private var hasColdRead: Bool { !(coldReading?.isEmpty ?? true) }

    /// Shown when mull can't see anything yet — honest, and points at the fix.
    private var coldReadEmptyState: some View {
        VStack(spacing: DS.sm) {
            Image(systemName: "moon.stars")
                .font(.system(size: 28, weight: .thin))
                .foregroundStyle(DS.moon.opacity(0.4))
            Text("Nothing to read yet")
                .font(DS.bodyMedium)
            Text("mull looks at what's open, your calendar and your Mac's own settings. With those unavailable there's nothing to guess from — it starts learning the moment you keep working.")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DS.lg)
    }

    /// Kick off the read. It is deliberately not called inline: the read makes two
    /// blocking Accessibility calls and an EventKit query, and on the main thread a
    /// single unresponsive frontmost app froze the whole onboarding window. It now
    /// runs off-main under a time budget (see ColdReadService.read), so the worst case
    /// is a short list instead of a beachball.
    private func startColdRead() {
        // Re-entering the step (back navigation, a second .onAppear) must not leave
        // the previous reveal timer running alongside the new one.
        factRevealTimer?.invalidate()
        factRevealTimer = nil
        coldReadTask?.cancel()
        coldReading = nil
        revealedFactCount = 0

        coldReadTask = Task { @MainActor in
            let reading = await ColdReadService.read()
            guard !Task.isCancelled else { return }
            coldReading = reading
            startFactReveal(count: reading.facts.count)
        }
    }

    /// Fade the observations in one after another. A quick stagger — it is a page
    /// settling, not a reveal being drawn out for effect, and nothing waits on it.
    private func startFactReveal(count: Int) {
        guard count > 0 else { return }
        var index = 0
        factRevealTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { timer in
            guard index < count else {
                timer.invalidate()
                return
            }
            withAnimation(.spring(duration: 0.3)) {
                index += 1
                revealedFactCount = index
            }
        }
        // Show the first line immediately rather than after one tick of dead air.
        withAnimation(.spring(duration: 0.3)) { revealedFactCount = 1 }
        index = 1
    }

    // MARK: - Step 4: Try It

    /// The first time mull's record leaves the app, the user reads it first.
    ///
    /// The old screen told the user to copy their activity and paste it into ChatGPT
    /// without ever showing them what was in it — asking for trust in the one place
    /// the app can simply show its work instead. The payload is composed and rendered
    /// here, and the button copies exactly the text on screen.
    private var tryItStep: some View {
        VStack(spacing: DS.lg) {
            VStack(spacing: DS.sm) {
                Text("This is what you'd hand an AI")
                    .font(DS.displayFont)

                // The old opener — "Written from what mull has seen so far" — is
                // false twice over on a first run: mull has seen nothing, and the
                // identity half was *told* to it on the previous screen rather than
                // observed. It also sat above an empty box, so the flow's one
                // untrue sentence was the same one that made it look broken. What
                // replaces it is the part the screen can always keep.
                Text(previewIsStarterOnly
                     ? "Nothing has been recorded yet, so this is what mull can say today: what is open in front of you. It grows on its own from here."
                     : "Read it, then copy it if you're happy with it — it goes to your clipboard and nowhere else.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.top, DS.lg)

            contextPreviewPane
                .padding(.horizontal, 32)

            Button {
                copyPreviewedContext()
            } label: {
                HStack(spacing: DS.sm) {
                    Image(systemName: "doc.on.clipboard")
                    Text("Copy this")
                }
                .font(DS.titleMedium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            .disabled((contextPreview ?? "").isEmpty)

            if showCopiedConfirmation {
                // A confirmation, not a celebration: state the fact and move on.
                HStack(spacing: DS.sm) {
                    Image(systemName: "checkmark")
                        .font(DS.captionFont)
                    Text("Copied — paste it (⌘V) at the start of any AI conversation.")
                        .font(DS.captionFont)
                }
                .foregroundStyle(DS.inkDim)
                .transition(.opacity)
            }

            // Only advertise the accelerator to users for whom it can actually fire.
            // The global monitor behind ⌘⇧C needs Accessibility (see GlobalShortcuts);
            // told to someone who skipped that permission, it is an instruction that
            // silently does nothing forever.
            if appState.permissions.accessibilityGranted {
                VStack(spacing: DS.xs) {
                    Text("You can do this anytime with")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                    Text("⌘ + Shift + C")
                        .font(DS.codeFont)
                        .foregroundStyle(DS.moon)
                }
            } else {
                Text("You can do this anytime from mull's menu bar icon.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
            }

            Spacer(minLength: DS.sm)

            Button {
                withAnimation { step = .connect }
            } label: {
                Text("Continue")
                    .font(DS.subtitleMedium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            .padding(.bottom, DS.xl)
        }
        .onAppear { loadContextPreview() }
    }

    // MARK: - Step 6: Connect

    /// The step that decides whether mull is the product it claims to be.
    ///
    /// Everything before this leaves the user with a folder of markdown and a
    /// keyboard shortcut — a good diary. The pitch is not a diary: it is an AI that
    /// already knows you, and that only happens once a client is pointed at mull's
    /// MCP server. That step existed, worked, and was buried in Settings → AI, a
    /// screen onboarding never mentioned and most people never open. So the flow
    /// ended one click short of its own premise, and shipped its weakest form to
    /// everybody who took the default path.
    ///
    /// It stays a real decision, not a formality: mull is about to edit a file it
    /// did not author (~/.claude.json holds every other MCP server the user has
    /// registered), so it goes through the same consent sheet Settings uses — the
    /// exact fragment, the exact path, the backup — and skipping is one click.
    private var connectStep: some View {
        VStack(spacing: DS.lg) {
            VStack(spacing: DS.xs) {
                Text("Let your AI read this")
                    .font(DS.headlineFont)
                Text("So you never have to paste it. mull can add itself to the AI tools already on this Mac — you'll see the exact change before anything is written.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .padding(.top, DS.lg)

            VStack(alignment: .leading, spacing: DS.md) {
                if installedTools.isEmpty {
                    noToolsState
                } else {
                    ForEach(installedTools) { tool in
                        connectRow(tool)
                    }
                }
            }
            .padding(.horizontal, 40)
            .frame(minHeight: 150, alignment: .top)

            if let error = connectError {
                Text(error)
                    .font(DS.captionFont)
                    .foregroundStyle(DS.paused)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("You can connect, or disconnect, any of these later in Settings → AI.")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer(minLength: DS.sm)

            Button {
                finishOnboarding()
            } label: {
                Text("Done")
                    .font(DS.subtitleMedium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            .padding(.bottom, DS.xl)
        }
        .onAppear { aiTools = AIToolSetup.detectTools() }
        .sheet(item: $pendingConnect) { pending in
            MCPConnectSheet(tool: pending.tool, fragment: pending.fragment) {
                confirmConnect(pending.tool)
            }
        }
    }

    /// Only what is actually on the machine. A row reading "Cursor — not installed"
    /// is an advert for another company's product on a setup screen.
    private var installedTools: [AIToolSetup.AITool] { aiTools.filter(\.detected) }

    private func connectRow(_ tool: AIToolSetup.AITool) -> some View {
        HStack(spacing: DS.md) {
            Image(systemName: tool.configured ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(tool.configured ? AnyShapeStyle(DS.recording) : AnyShapeStyle(DS.inkFaint))

            VStack(alignment: .leading, spacing: DS.hair) {
                Text(tool.name).font(DS.bodyMedium)
                Text(tool.configured
                     ? "Connected — restart \(tool.name) to load mull."
                     : "Not connected yet")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
            }

            Spacer()

            if !tool.configured {
                Button("Connect") { beginConnect(tool) }
                    .font(DS.captionFont)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var noToolsState: some View {
        VStack(spacing: DS.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .thin))
                .foregroundStyle(DS.moon.opacity(0.4))
            Text("No AI tools found on this Mac")
                .font(DS.bodyMedium)
            Text("mull looks for Claude Code, Claude Desktop and Cursor. Install any of them and connect it from Settings → AI — until then, the copy button on the last screen does the same job by hand.")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DS.md)
    }

    /// Build the preview and open the consent sheet. If the MullMCP binary can't be
    /// resolved there is nothing honest to show, so it fails here rather than
    /// writing a config that points at nothing.
    private func beginConnect(_ tool: AIToolSetup.AITool) {
        connectError = nil
        switch AIToolSetup.configFragment() {
        case .success(let fragment):
            pendingConnect = PendingConnect(tool: tool, fragment: fragment)
        case .failure(let error):
            connectError = error.localizedDescription
        }
    }

    private func confirmConnect(_ tool: AIToolSetup.AITool) {
        pendingConnect = nil
        if case .failure(let error) = AIToolSetup.setup(tool: tool) {
            connectError = error.localizedDescription
        }
        // Re-detect rather than assume: the badge should reflect the file on disk,
        // not what the button believed it did.
        aiTools = AIToolSetup.detectTools()
    }

    /// The payload itself, on paper. Scrollable and selectable — it is a document to
    /// be read, not a status chip.
    private var contextPreviewPane: some View {
        ScrollView {
            Group {
                if let preview = contextPreview, !preview.isEmpty {
                    MarkdownView(preview, titleFirstLine: false)
                        .textSelection(.enabled)
                } else if isLoadingPreview {
                    HStack(spacing: DS.sm) {
                        ProgressView().controlSize(.small)
                        Text("Putting it together…")
                            .font(DS.bodyFont)
                            .foregroundStyle(DS.inkDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Now reachable only when there is genuinely nothing at all: no
                    // profile answered, no history, and a cold read that came back
                    // empty too. Honest — pretending otherwise would be the first
                    // thing mull made up.
                    Text("There's nothing to hand over yet — mull has only just started. Come back after a stretch of work and this will have your day in it.")
                        .font(DS.bodyFont)
                        .foregroundStyle(DS.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.md)
        }
        .frame(height: 210)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSm))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusSm)
                .strokeBorder(DS.hairline, lineWidth: 1)
        )
    }

    private func loadContextPreview() {
        guard contextPreview == nil, !isLoadingPreview else { return }
        isLoadingPreview = true
        Task { @MainActor in
            let recorded = await ContextComposer(database: appState.database).compose()
            previewIsStarterOnly = recorded.isEmpty
            contextPreview = Self.previewText(recorded: recorded, reading: coldReading)
            isLoadingPreview = false
        }
    }

    /// What the pane shows, and exactly what the button copies.
    ///
    /// The recorded context is the real thing and always leads. The live read is
    /// appended rather than substituted because on the run that matters — the first
    /// one — the recorded half is empty and the live half is all there is; and on a
    /// resumed setup, where both exist, "what is open in front of you now" is not
    /// something half an hour of recorded history already said.
    ///
    /// `isStarterOnly` (below) reads off the same rule, so the caption under the
    /// pane can never claim more than the pane holds.
    static func previewText(recorded: String, reading: ColdReading?) -> String {
        let live = reading?.contextBlock() ?? ""
        if recorded.isEmpty {
            return live.isEmpty ? "" : ContextComposer.preamble + "\n" + live
        }
        return live.isEmpty ? recorded : recorded + "\n\n" + live
    }

    /// Copies the text the user just read — not a freshly recomposed one, which could
    /// differ from what was on screen.
    private func copyPreviewedContext() {
        guard let preview = contextPreview, !preview.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preview, forType: .string)
        withAnimation(.spring(duration: 0.3)) { showCopiedConfirmation = true }
    }

    // MARK: - Helpers

    private func valueProp(icon: String, text: String) -> some View {
        HStack(spacing: DS.md) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(DS.moon)
                .frame(width: 24)
            Text(text)
                .font(DS.bodyFont)
                .foregroundStyle(DS.inkDim)
        }
    }

    /// `asked` = mull has already put the system's own request in front of the user.
    /// Until then the button is the ask itself; afterwards it becomes the way out for
    /// the case where the dialog never appeared or was dismissed.
    private func permissionRow(name: String, detail: String, granted: Bool,
                               asked: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: DS.md) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(granted ? AnyShapeStyle(DS.recording) : AnyShapeStyle(DS.inkFaint))

            VStack(alignment: .leading, spacing: DS.hair) {
                Text(name).font(DS.bodyMedium)
                Text(detail).font(DS.captionFont).foregroundStyle(DS.inkFaint)
            }

            Spacer()

            if !granted {
                Button(asked ? "Still stuck? Open Settings" : "Allow") { action() }
                    .font(DS.captionFont)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    /// Current macOS, not Mojave. There has been no padlock to click since Ventura
    /// moved these panes into System Settings → Privacy & Security, where each app is
    /// a switch; describing a lock-and-plus flow sent users hunting for controls that
    /// aren't on screen.
    private var howToGuide: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("1. Click \"Open Settings\" above — it opens System Settings → Privacy & Security")
            Text("2. Find mull in the list and turn its switch on")
            Text("3. If mull isn't listed, click \"+\", then choose mull in Applications")
            Text("macOS may ask you to quit and reopen mull for it to take effect.")
                .foregroundStyle(DS.inkFaint)
            #if DEBUG
            // Developer-only: a build launched by Xcode is granted under Xcode's
            // identity. Never shipped — it is meaningless to anyone who installed
            // mull normally, and reads as a leaked internal note.
            Text("Debug build: when running from Xcode, add Xcode instead.")
                .foregroundStyle(DS.inkFaint)
            #endif
        }
        .font(DS.captionFont)
        .foregroundStyle(DS.inkDim)
        .padding(DS.md)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSm))
        .padding(.horizontal, 40)
    }

    // MARK: - Actions

    private func startPermissionPolling() {
        stopPermissionPolling()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in
                // The user may have moved on (Skip, or a granted-then-advanced race)
                // between ticks: never auto-advance from anywhere but this step.
                guard step == .permissions else { stopPermissionPolling(); return }
                appState.permissions.checkAll()
                if appState.permissions.accessibilityGranted && appState.permissions.inputMonitoringGranted {
                    stopPermissionPolling()
                    // Auto-advance after 1 second
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        withAnimation(.spring(duration: 0.3)) { step = .coldRead }
                        startRecordingAndProof()
                    }
                }
            }
        }
    }

    private func stopPermissionPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    /// Start capturing so the next screen has something true to show.
    ///
    /// It deliberately does NOT mark onboarding complete. That flag used to be set
    /// here, which meant "Skip" — the one path where the user has granted nothing —
    /// was also the path that told mull setup was over and it need never ask again.
    /// Completion belongs to the end of the flow, and to nowhere else.
    private func startRecordingAndProof() {
        appState.startRecording()
    }

    private func finishOnboarding() {
        factRevealTimer?.invalidate()
        factRevealTimer = nil
        stopPermissionPolling()
        appState.hasCompletedOnboarding = true
        appState.onboardingStep = 0
        isPresented = false
        (NSApp.delegate as? AppDelegate)?.closeOnboarding()
    }
}
