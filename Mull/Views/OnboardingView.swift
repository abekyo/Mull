import SwiftUI
import ApplicationServices

// Onboarding page gutter — the one horizontal margin every step shares, so the
// text columns line up as the steps advance. It was the literal 40 in eighteen
// places; a nineteenth typed as 32 or 48 would have gone unnoticed.
extension DS {
    fileprivate static let onboardingGutter: CGFloat = 40
}

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
    // Ticks of the permission poller spent waiting after a system prompt has been
    // shown but before the grant lands. That gap is the System Settings round trip
    // — find mull in the list, flip the switch, maybe relaunch — and it is where
    // people get lost, so after a few of these the instructions open themselves.
    @State private var stuckTicks = 0
    // Opened automatically at most once. Closing the guide again is the user's
    // decision, not a state for the poller to keep overriding.
    @State private var autoOpenedHowTo = false
    // Whether mull has already put the system's own request for each permission in
    // front of the user. Drives the second tap, which is the only one that opens
    // System Settings. Persisted, not @State: granting Input Monitoring makes macOS
    // offer to quit and reopen the app, and after that relaunch a reset flag
    // re-labelled the button "Allow" — a tap that did nothing visible, because TCC
    // shows each prompt once and the decision was already on file.
    @AppStorage("onboardingAskedAccessibility") private var askedAccessibility = false
    @AppStorage("onboardingAskedInputMonitoring") private var askedInputMonitoring = false
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
    /// Whether a read is running right now. The payload pane needs it to tell "still
    /// looking" from "looked, and there was nothing" — the second is a statement about
    /// the user's day and must not be made early.
    @State private var coldReadInFlight = false

    // The exact text "Copy my context" would put on the clipboard, shown before it
    // goes anywhere (根拠を見せる — DESIGN-NORTHSTAR §3.5).
    @State private var contextPreview: String?
    @State private var isLoadingPreview = false
    /// True when nothing has been recorded yet, so the pane is holding only the
    /// live read and the stated profile. The screen says so rather than letting
    /// "written from what mull has seen so far" imply a history that isn't there.
    @State private var previewIsStarterOnly = false
    /// The recorded half of the payload, kept so a cold read that arrives after the
    /// database pass can be folded in without repeating it. `nil` means "not composed
    /// yet"; `""` means "composed, and there is nothing recorded" — a distinction the
    /// pane depends on.
    @State private var recordedContext: String?

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
        // The paper is watermarked with the icon's rings in the top-right corner —
        // every onboarding page is a leaf of the same stationery.
        .background(
            ZStack(alignment: .topTrailing) {
                DS.canvas
                StippleRings(center: CGPoint(x: 0.94, y: 0.04))
                    .opacity(0.05)
            }
            .ignoresSafeArea()
        )
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

            // The mark, drawn rather than lit: the moon in tobacco, haloed by the
            // app icon's stipple rings. A gradient blob with a glow behind it is
            // the AI-startup icon treatment, and it is not what this app is.
            ZStack {
                StippleRings(center: CGPoint(x: 0.5, y: 0.5),
                             startR: 0.36, gap: 0.11, maxR: 0.48,
                             dotR: 0.012, dotGap: 0.052, skip: 0.12)
                    .frame(width: 96, height: 96)
                    .opacity(0.45)
                Image(systemName: "moon.stars")
                    .font(DS.iconHero.weight(.light))
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
                valueProp(text: "Records what you type, copy, and have open")
                valueProp(text: "Keeps the day in plain markdown files you own")
                valueProp(text: "Hands that context to an AI when you ask")
            }
            .padding(.horizontal, 48)

            Text("It never records password fields, and never any app you exclude.")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.onboardingGutter)

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
            .padding(.horizontal, DS.onboardingGutter)
            .padding(.bottom, DS.xl)
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: DS.lg) {
            Spacer()

            // A fleuron, not a raised hand: the step is an ask, not a warning.
            StippleMark(dot: 5)

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
            //
            // Input Monitoring leads, and each detail line says what its absence
            // costs. The rows used to sit as equals ("Read window titles" / "Record
            // keyboard input") with nothing to say that one of them is the
            // permission the product cannot work without, or which to start with.
            VStack(alignment: .leading, spacing: DS.md) {
                permissionRow(
                    name: "Input Monitoring",
                    detail: "Record what you type — without this, mull only keeps what you copy",
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
                            //
                            // Whether a dialog is coming has to be read BEFORE the
                            // ask: afterwards the answer is still outstanding and TCC
                            // says nothing useful. A failed tap does NOT mean "already
                            // decided" — on a first run it fails *and* raises the
                            // prompt, so treating failure as "no dialog will appear"
                            // dropped a whole System Settings window on top of the
                            // one-click dialog that would have finished the job. That
                            // is the same race the Accessibility row below was fixed
                            // to avoid, and it was still live here.
                            let promptComing = appState.permissions.inputMonitoringPromptAvailable
                            let alreadyGranted = appState.permissions.requestInputMonitoring()
                            if !alreadyGranted && !promptComing {
                                appState.permissions.openInputMonitoringSettings()
                            }
                        }
                    }
                )
                permissionRow(
                    name: "Accessibility",
                    detail: "Read window titles, so the record says where you were",
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
            }
            .padding(.horizontal, DS.onboardingGutter)

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
                Button("Skip") {
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
                    .padding(.horizontal, DS.onboardingGutter)
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
                    .padding(.horizontal, DS.onboardingGutter)
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
            .padding(.horizontal, DS.onboardingGutter)
            .frame(minHeight: 200, alignment: .top)

            if hasColdRead, revealedFactCount >= (coldReading?.facts.count ?? 0) {
                Text("That's the whole of it, and it stays on this Mac. Nothing is sent anywhere until you send it, and you can pause or delete any of it whenever you like.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.onboardingGutter)
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
            .padding(.horizontal, DS.onboardingGutter)
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
                .padding(.horizontal, DS.onboardingGutter)
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
            .padding(.horizontal, DS.onboardingGutter)
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
            StippleRings.roundel()
                .frame(width: 56, height: 56)
                .opacity(0.5)
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

        // The calendar ask happens here, not at app launch. This is the screen whose
        // copy says mull looks at the calendar, so it is the one moment the system's
        // dialog arrives with its reason already in view. Launching used to fire it
        // cold from CalendarService's initialiser: a third dialog on a flow that had
        // just promised two, and a reflexive "Don't Allow" that only System Settings
        // could undo.
        //
        // It runs ALONGSIDE the read, never in front of it. Awaiting the dialog first
        // put an unbounded modal wait ahead of a read whose entire design is a 2.5s
        // ceiling ("a short reading, never a hang" — ColdReadService), and a dialog
        // that surfaced behind the window, or simply wasn't answered, left this screen
        // on "Looking at what's open…" indefinitely. Worse, Continue is deliberately
        // never gated: a user who moved on while it hung arrived at the payload screen
        // with `coldReading` still nil, and on a first run — where the recorded half is
        // empty by definition — that renders the empty state and a disabled Copy
        // button, which is precisely the failure ColdReading.contextBlock() exists to
        // prevent.
        if appState.calendar.accessState == .notDetermined {
            appState.calendar.requestAccess { granted in
                // An answer that lands after the first pass earns a second one, so a
                // granted calendar still makes it into the reading. A refusal changes
                // nothing that is on screen: the first pass already said mull can't
                // see the calendar, and that is still true.
                if granted { runColdRead() }
            }
        }
        runColdRead()
    }

    /// Perform the read and show it. Safe to run more than once — a calendar grant
    /// that arrives after the first pass earns a repeat — and the reveal resumes from
    /// where it got to rather than replaying the stagger from the top.
    private func runColdRead() {
        coldReadTask?.cancel()
        // Set before the task is created, so a cancelled predecessor can never clear
        // the flag out from under its replacement: the only path that clears it is a
        // read that reached the end without being cancelled, and every mutation here
        // happens on the main actor.
        coldReadInFlight = true
        coldReadTask = Task { @MainActor in
            let reading = await ColdReadService.read()
            guard !Task.isCancelled else { return }
            coldReadInFlight = false
            coldReading = reading
            // The answer can arrive after the user has moved on. The facts are still
            // worth keeping — the payload screen reads `coldReading` — but a reveal
            // timer ticking against a screen nobody is looking at is not.
            if step == .coldRead {
                startFactReveal(count: reading.facts.count, from: revealedFactCount)
            } else {
                revealedFactCount = reading.facts.count
            }
            // Fold it into the payload screen, which may already have been drawn from
            // a half-finished pair. No-ops until that screen has composed its recorded
            // half, and again if the text comes out unchanged.
            rebuildContextPreview()
        }
    }

    /// Fade the observations in one after another. A quick stagger — it is a page
    /// settling, not a reveal being drawn out for effect, and nothing waits on it.
    ///
    /// `from` is how many lines are already on screen. A second pass (the calendar
    /// answered after the first read) continues from there instead of blanking the
    /// list and playing the whole stagger again in front of someone who has already
    /// read it.
    private func startFactReveal(count: Int, from alreadyShown: Int = 0) {
        // A later pass can be shorter than an earlier one. Clamp rather than leave the
        // "that's the whole of it" line keyed to a count the list no longer has.
        var index = min(alreadyShown, count)
        revealedFactCount = index
        guard count > index else { return }

        factRevealTimer?.invalidate()
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
        // Show the next line immediately rather than after one tick of dead air.
        index += 1
        withAnimation(.spring(duration: 0.3)) { revealedFactCount = index }
    }

    // MARK: - Step 5: Try It

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
            .padding(.horizontal, DS.onboardingGutter)
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
            .padding(.horizontal, DS.onboardingGutter)
            .padding(.bottom, DS.xl)
        }
        .onAppear {
            // Onboarding can resume at any step it was abandoned on, and resuming
            // straight into this one means the cold read — which only runs on the
            // screen before — never happened at all. The live half is exactly what
            // carries this screen on a machine with little or no history, so take it
            // now rather than showing the empty state to someone who merely quit at
            // the wrong moment. An already-running read is left to finish.
            if coldReading == nil && !coldReadInFlight { runColdRead() }
            loadContextPreview()
        }
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
                    .padding(.horizontal, DS.onboardingGutter)
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
            .padding(.horizontal, DS.onboardingGutter)
            .frame(minHeight: 150, alignment: .top)

            if let error = connectError {
                Text(error)
                    .font(DS.captionFont)
                    .foregroundStyle(DS.paused)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.onboardingGutter)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("You can connect, or disconnect, any of these later in Settings → AI.")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.onboardingGutter)

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
            .padding(.horizontal, DS.onboardingGutter)
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
                .font(DS.iconBody)
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
            // The empty-state figure everywhere in mull: the icon's rings, sparse
            // and half-formed. "sparkles" was the one glyph the design can least
            // afford — the stock shorthand for AI glitter.
            StippleRings.roundel()
                .frame(width: 56, height: 56)
                .opacity(0.5)
            Text("No AI tools found on this Mac")
                .font(DS.bodyMedium)
            Text("mull looks for Claude Code, Claude Desktop and Cursor. Until one of them is installed, the copy button on the last screen does the same job by hand.")
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
                // Anything already composed keeps the pane, even while a second read
                // is running: content → spinner → the same content again is a flicker
                // that says something is wrong when nothing is.
                if let preview = contextPreview, !preview.isEmpty {
                    MarkdownView(preview, titleFirstLine: false)
                        .textSelection(.enabled)
                } else if isLoadingPreview || coldReadInFlight {
                    HStack(spacing: DS.sm) {
                        ProgressView().controlSize(.small)
                        Text("Putting it together…")
                            .font(DS.bodyFont)
                            .foregroundStyle(DS.inkDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Now reachable only when there is genuinely nothing at all: no
                    // profile answered, no history, and a cold read that has finished
                    // and came back empty. Honest — pretending otherwise would be the
                    // first thing mull made up, and claiming it while the read is
                    // still running would be the same lie told early.
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

    /// Compose the recorded half — the expensive one, a database pass — exactly once,
    /// then derive the pane from it.
    ///
    /// Guarded on `recordedContext` rather than on `contextPreview`, because the
    /// preview is legitimately allowed to be `""` and the old guard could not tell
    /// "not composed yet" from "composed, and there was nothing". That is the same
    /// distinction the pane's own empty state turns on.
    private func loadContextPreview() {
        guard recordedContext == nil, !isLoadingPreview else { return }
        isLoadingPreview = true
        Task { @MainActor in
            recordedContext = await ContextComposer(database: appState.database).compose()
            rebuildContextPreview()
            isLoadingPreview = false
        }
    }

    /// Re-derive the pane from the two halves that feed it: the recorded context and
    /// the live read. String assembly only — the database is not touched — so it is
    /// cheap enough to run again whenever either half changes.
    ///
    /// This exists because the halves do not arrive together. The preview used to be
    /// committed once, at whatever moment the database pass happened to return, and a
    /// cold read that landed a moment later was simply lost: on a first run, where the
    /// recorded half is empty by definition, that left the product's headline screen
    /// showing its empty state with the Copy button disabled. A calendar granted
    /// mid-flow produces a second, richer reading with the same problem.
    private func rebuildContextPreview() {
        guard let recorded = recordedContext else { return }
        let rebuilt = Self.previewText(recorded: recorded, reading: coldReading)
        guard rebuilt != contextPreview else { return }

        previewIsStarterOnly = recorded.isEmpty
        contextPreview = rebuilt
        // The confirmation says the clipboard holds what is on screen. Once the text
        // underneath it has changed that is no longer true, so the note goes rather
        // than sitting beside something it no longer describes.
        if showCopiedConfirmation {
            withAnimation(.spring(duration: 0.3)) { showCopiedConfirmation = false }
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

    private func valueProp(text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.md) {
            // The icon motif's mark as the bullet, not a stock glyph per line —
            // three different symbols were three different voices for one list.
            StippleMark()
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
                .font(DS.iconBody)
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
        .padding(.horizontal, DS.onboardingGutter)
    }

    // MARK: - Actions

    private func startPermissionPolling() {
        stopPermissionPolling()
        stuckTicks = 0
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in
                // The user may have moved on (Skip, or a granted-then-advanced race)
                // between ticks: never auto-advance from anywhere but this step.
                guard step == .permissions else { stopPermissionPolling(); return }
                appState.permissions.checkAll()
                if appState.permissions.accessibilityGranted && appState.permissions.inputMonitoringGranted {
                    stopPermissionPolling()
                    // Let the two ticks register as granted before moving on, then
                    // advance — but only from the step that scheduled this. The tick
                    // above guards on `step` and this delayed half did not, so a user
                    // who tapped Skip and then Continue inside the one-second window
                    // was dragged back to .coldRead from wherever they had reached.
                    // Skip starts recording on its own, so there is nothing to do here
                    // but stand down.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        guard step == .permissions else { return }
                        withAnimation(.spring(duration: 0.3)) { step = .coldRead }
                        startRecordingAndProof()
                    }
                } else if askedAccessibility || askedInputMonitoring {
                    // A prompt has been faced and the grant still hasn't arrived:
                    // the user is somewhere in the Settings round trip. The guide
                    // used to sit collapsed behind "How do I do this?" — the person
                    // who needs it most discovers it only after being lost. ~9s of
                    // waiting is that person.
                    stuckTicks += 1
                    if stuckTicks >= 6 && !autoOpenedHowTo && !showHowTo {
                        autoOpenedHowTo = true
                        withAnimation { showHowTo = true }
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
