import SwiftUI
import Combine
import ApplicationServices
@preconcurrency import UserNotifications

/// Central observable state for the entire app.
@MainActor
final class AppState: ObservableObject {

    // MARK: - mull Engine State

    @Published var isSummarizing = false
    @Published var mullProgress: String?
    @Published var lastSummaryDate: Date?

    // MARK: - Recording State

    @Published var isRecording = false
    @Published var isPaused = false
    /// When a timed pause will auto-resume (nil = not paused, or paused indefinitely).
    @Published var pauseEndsAt: Date?
    /// True when recording is started but keystroke capture has been lost (permissions revoked).
    /// Clipboard and window title monitoring may still work.
    @Published var isRecordingDegraded = false
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
    /// Where onboarding got to, so an interrupted setup resumes instead of restarting.
    ///
    /// Onboarding is only "complete" when the user reaches the end of it. Quitting
    /// mid-flow, or closing the window, used to mean either being marked done having
    /// granted nothing, or starting again from the welcome screen — so this is the
    /// raw value of `OnboardingView.OnboardingStep` the user last reached.
    @AppStorage("onboardingStep") var onboardingStep = 0
    let permissions = PermissionService()
    @Published var todayEventCount: Int = 0
    @Published var todayStorageBytes: Int64 = 0

    // LLM provider — synced with @AppStorage
    // Defaults to .off — no off-device processing until the user opts in.
    @Published var llmProvider: LLMProvider = .off {
        didSet {
            UserDefaults.standard.set(llmProvider.rawValue, forKey: "llmProvider")
        }
    }

    // MARK: - Main window sidebar
    //
    // Whether the main window shows its sidebar. This is held here, rather than as
    // `@State` inside `FullWindowView`, because the button that flips it does not
    // live in the SwiftUI tree: it is an `NSTitlebarAccessoryViewController` on the
    // window (see `AppDelegate.installSidebarToggle`).
    //
    // It moved out there to stop it moving on screen. `NavigationSplitView` supplies
    // a toggle of its own, and AppKit lays that one out against the *split divider*
    // — so collapsing the sidebar took the divider to x=0 and the button jumped
    // roughly 190pt left, to sit beside the traffic lights, then jumped back on the
    // next click. The control you press to hide the sidebar was the control that
    // moved out from under the pointer when you pressed it. A title-bar accessory is
    // laid out against the traffic lights instead, which do not move, so the button
    // is in the same place in both states.
    //
    // This is the same rule `FullWindowView.searchField` states for the search box:
    // a control you have to catch is worse than one that is simply always there.
    @Published var sidebarVisible = true

    // MARK: - In-app notices
    //
    // Several actions (copy context, import, export, conflict resolution) used to
    // speak only through a system notification — invisible under Do Not Disturb,
    // and silent altogether when nothing happened. A notice is the in-app answer:
    // it says what mull just did, or why it did nothing, in the window the user is
    // already looking at.

    struct ActionNotice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var detail: String? = nil
        /// A file the notice is about — the user can go look at it.
        var revealURL: URL? = nil
        /// Something didn't happen. Stays until dismissed.
        var isProblem: Bool = false
    }

    @Published var actionNotice: ActionNotice?
    private var noticeDismissTask: Task<Void, Never>?

    /// Show an in-app notice. Plain confirmations fade on their own; anything the
    /// user may need to act on (a problem, or a file to go find) waits to be dismissed.
    func postNotice(_ text: String, detail: String? = nil, revealURL: URL? = nil, isProblem: Bool = false) {
        let notice = ActionNotice(text: text, detail: detail, revealURL: revealURL, isProblem: isProblem)
        actionNotice = notice
        noticeDismissTask?.cancel()
        guard !isProblem, revealURL == nil else { return }
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard let self, self.actionNotice?.id == notice.id else { return }
            self.actionNotice = nil
        }
    }

    func dismissNotice() {
        noticeDismissTask?.cancel()
        actionNotice = nil
    }

    // MARK: - Summaries

    @Published var todaySummary: DailySummary?
    @Published var recentSummaries: [DailySummary] = []
    @Published var hasUnreadSummary = false
    /// Bumped when the evening auto-draft lands, so an already-open Home reloads it.
    @Published var eveningDraftReady: Date?

    // MARK: - Services

    let database: DatabaseService
    let recorder: RecordingService
    let mullEngine: MullEngine
    let analytics: AnalyticsEngine
    let calendar: CalendarService
    /// Copies settled activity blocks into a calendar the user picked. Inert unless
    /// enabled in Settings — see `CalendarMirror` for what it will and will not write.
    let calendarMirror: CalendarMirrorRunner
    let email: EmailService
    let proactive: ProactiveEngine
    let proactiveLoop: ProactiveLoop
    let ingestion: IngestionService

    /// The chat transcript, owned here rather than by ChatPanelView.
    ///
    /// It used to be a @StateObject on the view, which FullWindowView tears down and
    /// rebuilds on every sidebar selection change — so clicking Home to check a fact
    /// and coming back destroyed the whole conversation, with no warning and nothing
    /// to recover it from. Living on AppState, it survives navigation for as long as
    /// the app is running.
    let chat = ChatViewModel()

    private var refreshTimer: Timer?
    private var eveningDraftTimer: Timer?
    private var lastRefreshDate: Date = Date()
    /// Owned, not observed: releasing this removes the global event monitor (see
    /// GlobalShortcuts.deinit), so AppState's own deinit no longer has to.
    private var shortcuts: GlobalShortcuts?

    deinit {
        refreshTimer?.invalidate()
        eveningDraftTimer?.invalidate()
        ingestion.stop()
        mullEngine.cancelSchedule()
    }

    // MARK: - Evening draft (先回り)

    /// Daily timer (same pattern as MullEngine.scheduleSummary): at 17:30, draft today's
    /// report in the user's voice and cache it, so Home shows it without a button press.
    private func scheduleEveningDraft(at hour: Int = 17, minute: Int = 30) {
        eveningDraftTimer?.invalidate()
        var match = DateComponents()
        match.hour = hour
        match.minute = minute
        guard let fireDate = Calendar.current.nextDate(after: Date(), matching: match,
                                                       matchingPolicy: .nextTime) else { return }
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.generateEveningDraftIfDue()
                await MainActor.run { self.scheduleEveningDraft(at: hour, minute: minute) }
            }
        }
        eveningDraftTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Draft once per day, and only when there's something to draft against: LLM on,
    /// no approved report yet, no cached draft yet. Failures stay silent here — this is
    /// background anticipation; the Home card has its own explicit error path.
    private func generateEveningDraftIfDue() async {
        guard (UserDefaults.standard.string(forKey: "llmProvider") ?? "off") != "off" else { return }
        let writer = ReportWriter(database: database)
        guard writer.saved(for: Date()) == nil, writer.cachedDraft(for: Date()) == nil else { return }
        guard let draft = try? await writer.draft(for: Date()) else { return }
        writer.cacheDraft(draft, for: Date())
        await MainActor.run { self.eveningDraftReady = Date() }
    }

    // MARK: - Init

    init() {
        // Validate ~/mull directory before anything else. Cheap (mkdir + one write
        // probe) and everything that touches the vault gates on its status, so this
        // one stays inline; the heavier startup work is deferred (see below).
        MullDirectory.setup()

        self.database = DatabaseService()
        self.recorder = RecordingService(database: database)
        self.mullEngine = MullEngine(database: database)
        self.analytics = AnalyticsEngine(database: database)
        self.calendar = CalendarService()
        self.email = EmailService(database: database)
        self.proactive = ProactiveEngine(database: database, calendar: calendar, analytics: analytics)
        // Off until the user turns it on and names a calendar; `reschedule()` starts
        // no timer in that state, so an install that never enables it costs nothing.
        self.calendarMirror = CalendarMirrorRunner(database: database, calendar: calendar)
        // The self-driving proactive loop: anchor → select → judge
        // → write-back → notify, fired on project switches.
        self.proactiveLoop = ProactiveLoop(database: database)
        // Phase B ingestion — pulls from configured MCP sources. No-op until the
        // user registers a source (no surprise network access).
        self.ingestion = IngestionService.fromConfiguredSources()

        // Sync LLM provider from UserDefaults
        if let saved = UserDefaults.standard.string(forKey: "llmProvider"),
           let provider = LLMProvider(rawValue: saved) {
            self.llmProvider = provider
        }

        // Schedule nightly consolidation + wire up completion callbacks
        mullEngine.onSummaryComplete = { [weak self] summary in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.todaySummary = summary
                self.hasUnreadSummary = true
                self.lastSummaryDate = Date()
                self.loadRecentSummaries()
                if self.summaryBannersEnabled {
                    self.sendNotification(
                        title: "Tonight's summary is ready ☽",
                        body: summary.preview
                    )
                }
                // The summary exists either way, so this is not a failure — but a
                // user who switched a provider on and got the rule-based version
                // should not have to compare prose styles to find that out.
                let configured = UserDefaults.standard.string(forKey: "llmProvider") ?? "off"
                if summary.llmProvider == "rule-based", configured != "off" {
                    self.postNotice(
                        "Tonight's summary was written without the model",
                        detail: "mull couldn't reach \(configured), so it fell back to its own rule-based summary. Settings › AI can test the connection.",
                        isProblem: true)
                }
            }
        }
        mullEngine.onSummaryFailed = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Both channels: the notification may be refused by macOS, and
                // this is the one message that explains a missing summary.
                if self.summaryBannersEnabled {
                    self.sendNotification(
                        title: "Summary failed",
                        body: error.localizedDescription
                    )
                }
                self.postNotice("Tonight's summary didn't run",
                                detail: error.localizedDescription, isProblem: true)
            }
        }

        // A permission going away is the one failure mull cannot let pass quietly:
        // capture simply stops, the files keep being written (just emptier), and
        // nothing on screen changes. Someone can lose a week of their record before
        // they notice the day looks thin.
        permissions.onRevoked = { [weak self] permission in
            Task { @MainActor [weak self] in
                self?.handlePermissionRevoked(permission)
            }
        }

        // Set default output limit if not configured
        if UserDefaults.standard.object(forKey: "outputMaxChars") == nil {
            UserDefaults.standard.set(50000, forKey: "outputMaxChars")
        }

        // Global keyboard shortcuts. Weak self throughout: the monitor outlives
        // nothing here, but the handlers must not be what keeps AppState alive.
        shortcuts = GlobalShortcuts(
            onOpenWindow: { [weak self] in self?.openMainWindow() },
            onCopyContext: { [weak self] in self?.copyContextToClipboard() },
            onInjectContext: { [weak self] in self?.injectContextIntoFocusedField() }
        )

        // Refresh stats every 3 seconds + handle date crossing
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStats()
            }
        }

        // Everything else waits until after the first frame — see startDeferredWork.
        Task { @MainActor [weak self] in self?.startDeferredWork() }
    }

    /// Startup work that the first frame does not depend on.
    ///
    /// All of this used to run synchronously inside `init()`, before SwiftUI could
    /// draw anything: scaffolding ~10 index.md files, two summary queries, a pair of
    /// DELETEs plus a VACUUM, and a full stats refresh. On a large database that is a
    /// multi-second hang at launch with no window on screen. The window comes up
    /// first now; these fill in behind it, and each piece already tolerates arriving
    /// a moment late (the views observe @Published state).
    private func startDeferredWork() {
        // A database running from a temporary file loses everything on restart,
        // and the only place that said so was the Home tab — which a menu-bar
        // user may never open. Say it once, in the channel that persists until
        // dismissed.
        if let reason = database.fallbackReason {
            postNotice(database.isFallback ? "Today is being kept somewhere temporary"
                                           : "mull had trouble opening its store",
                       detail: reason, isProblem: true)
        }

        // Mail capture that stops working months after it was switched on used to
        // be visible only to someone who happened to open Settings › Data.
        EmailService.onProblemAppeared = { problem in
            Task { @MainActor [weak self] in
                self?.postNotice("Email capture stopped", detail: problem.message, isProblem: true)
            }
        }

        // Scaffold the v3 folder ontology (idempotent, non-destructive) and apply
        // retention — both are file/DB work with no first-frame dependency.
        let db = database
        Task.detached {
            VaultLayout.migrate()
            // Memory files named before `MemoryFiles.fileName(for:)` existed carry a
            // POSIX colon, which Finder renders as a slash — mull and Finder calling
            // one file two names. Idempotent, so it costs a query on every launch and
            // does nothing once the vault is clean.
            MemoryFiles.repairLegacyNames(database: self.database)
            Self.pruneToRetention(database: db)
            let today = db.fetchSummary(for: Date())
            let recent = db.fetchRecentSummaries(limit: 30)
            await MainActor.run { [weak self] in
                self?.todaySummary = today
                self?.recentSummaries = recent
            }
        }

        // Pull from configured sources every 30 min (no-op if none configured).
        ingestion.onFailure = { [weak self] connector, error in
            self?.postNotice("“\(connector)” stopped pulling", detail: error, isProblem: true)
        }
        ingestion.schedule(every: 1800)

        // Auto-start recording if onboarding is already done.
        // Don't gate on AXIsProcessTrusted — it lies on debug builds.
        // Recording will start and capture what it can.
        // Onboarding itself is handled by AppDelegate.applicationDidFinishLaunching.
        //
        // Also starts for onboarding that was interrupted after the permissions
        // step: capture legitimately began there, and a user who quit at the cold
        // read and came back should not silently have a gap in their record until
        // they get round to clicking Done.
        if hasCompletedOnboarding || onboardingStep > OnboardingView.OnboardingStep.permissions.rawValue {
            startRecording()
        }

        let hour = UserDefaults.standard.object(forKey: "summaryTime") as? Int ?? 23
        let minute = UserDefaults.standard.object(forKey: "summaryTimeMinute") as? Int ?? 0
        mullEngine.scheduleSummary(at: hour, minute: minute)

        // No catch-up pass at launch, deliberately. Everything the mirror would have
        // written while mull was closed is still settled and still in range, so the
        // first scheduled tick covers it — and a write into somebody's calendar in the
        // first second of launch is not a thing to do before the window is even up.
        calendarMirror.reschedule()

        // 先回り: by the time the user opens mull in the evening, today's report draft
        // is already waiting (the understudy works ahead). Daily at 17:30, plus a
        // catch-up at launch for the day mull wasn't running at 17:30.
        scheduleEveningDraft()
        if Calendar.current.component(.hour, from: Date()) >= 17 {
            Task { await self.generateEveningDraftIfDue() }
        }

        refreshStats()
    }

    private var lastMeFileUpdate: Date = .distantPast

    /// True while a context generation is in flight.
    ///
    /// `refreshStats()` runs every 3 seconds but the 60s gate only closes AFTER the
    /// detached task finishes writing `lastMeFileUpdate`. A generation takes longer
    /// than 3s (the folder fill alone did a 14-day TimeBlockEngine scan plus a 7-day
    /// fetch), so the gate stayed open and each tick spawned another overlapping run
    /// — several of them racing inside Curator's non-atomic read-merge-write, which
    /// is exactly how curated blocks get lost. Same check-and-set pattern as
    /// IngestionService.beginRun.
    private var contextGenerationInFlight = false

    /// `todayEventCount` as of the last generation this started.
    ///
    /// The 60s pass rewrites five files atomically — me.md, now.md, full.md
    /// (19KB on its own), mull.md and the day's snapshot — and it did so whether
    /// or not anything had been recorded since the last one, because the header
    /// timestamp guarantees the bytes differ. Overnight that is 1,440 rewrites of
    /// each file, five new inodes a minute for Spotlight to re-index, for a record
    /// that has not changed.
    ///
    /// Gating on events rather than on whether the user is at the keyboard is
    /// deliberate. An agent can be working, and reading the vault, while its user
    /// is away; what it does moves window titles, and window titles are events. So
    /// the question is not whether anyone is present, it is whether there is
    /// anything new to write.
    private var lastGeneratedEventCount: Int?

    /// Whether the 60s pass has anything to do. Pure and static so the rule can be
    /// tested without standing up an AppState.
    static func shouldRegenerateContext(eventCount: Int, lastGenerated: Int?,
                                        sinceLastUpdate: TimeInterval) -> Bool {
        eventCount > 0 && sinceLastUpdate > 60 && eventCount != lastGenerated
    }

    /// Run one context generation if none is already running. Shared by the 60s tick
    /// and the explicit `regenerateContextNow()` so the two can never overlap either.
    private func generateContextIfIdle() {
        guard !contextGenerationInFlight else { return }
        contextGenerationInFlight = true
        // Snapshot at the decision, not at completion: an event that lands while a
        // generation is running may or may not be in it, so it must still be able
        // to trigger the next one.
        lastGeneratedEventCount = todayEventCount

        let db = database
        let analyticsRef = analytics
        let calendarRef = calendar
        // Read the inbox HERE, on the main actor, and hand the detached task a
        // value. Passing `EmailService` across meant a detached task calling into
        // a type whose 5-minute poll timer mutates it on main — the same class of
        // race as the statics noted below, found by strict concurrency checking
        // rather than by anything failing.
        let inbox = LiveContextGenerator.InboxSnapshot.read(from: email)

        Task.detached {
            // Services are passed in, not stashed in LiveContextGenerator statics —
            // those assignments were a retain/release race across detached tasks.
            // `lastMeFileUpdate` is the freshness clock the UI shows and the 60s
            // gate reads. Advancing it after a failed generation claimed the
            // files had just been refreshed when nothing had been written —
            // exactly the state (an unwritable ~/mull) where that matters most.
            var generated = true
            do {
                try LiveContextGenerator.generate(analytics: analyticsRef, database: db,
                                                  calendar: calendarRef, inbox: inbox)
            } catch {
                generated = false
            }
            if MullDirectory.status != .ready { generated = false }
            let didGenerate = generated
            await MainActor.run { [weak self] in
                guard let self else { return }
                if didGenerate { self.lastMeFileUpdate = Date() }
                self.contextGenerationInFlight = false
            }
        }
    }

    private func refreshStats() {
        let today = Calendar.current.startOfDay(for: Date())
        let lastDay = Calendar.current.startOfDay(for: lastRefreshDate)
        if today != lastDay {
            loadTodaySummary()
            loadRecentSummaries()
        }
        lastRefreshDate = Date()

        // Proactive notifications — lightweight in-memory checks only
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let frontWindow = recorder.currentWindowTitlePublic
        let browserURL = recorder.lastBrowserURLPublic
        proactive.tick(todayEventCount: todayEventCount, currentApp: frontApp, currentWindow: frontWindow, browserURL: browserURL)
        // Self-driving loop: fires a brief when you switch projects (throttled).
        proactiveLoop.tick()

        // DB reads on a background thread; file generation has its own in-flight
        // guard so a slow pass can't stack up behind the 3s tick.
        let db = database
        Task.detached {
            let count = db.eventCountToday()
            let bytes = db.storageBytesToday()

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.todayEventCount = count
                self.todayStorageBytes = bytes
            }
        }

        if Self.shouldRegenerateContext(eventCount: todayEventCount,
                                        lastGenerated: lastGeneratedEventCount,
                                        sinceLastUpdate: Date().timeIntervalSince(lastMeFileUpdate)) {
            generateContextIfIdle()
        }
    }

    // MARK: - Actions

    /// Force an immediate me/now/full regeneration. Used right after the onboarding
    /// profile is saved so me.md reflects the new pinned facts at once instead of
    /// waiting for the next 60s tick. Shares the 60s tick's in-flight guard — a
    /// Settings/Onboarding tap landing mid-generation must not start a second one.
    func regenerateContextNow() {
        generateContextIfIdle()
    }

    func startRecording() {
        recorder.onHealthStatusChanged = { [weak self] isHealthy in
            Task { @MainActor [weak self] in
                self?.isRecordingDegraded = !isHealthy
            }
        }
        recorder.start()
        email.start()
        isRecording = true
        isRecordingDegraded = false

        // Window-title capture (the entity anchor for the selection layer + the
        // proactive loop) needs Accessibility. If it isn't granted, actively show
        // the system dialog instead of silently capturing half-dead — otherwise
        // titles come back nil and the loop has no material. Harmless when already
        // trusted (the dialog only appears when not).
        //
        // Once only. Recording starts on every launch, so this fired the system
        // Accessibility dialog at every launch for anyone who had deliberately
        // declined — an app that keeps asking after being told no is not asking,
        // it is nagging. Settings › Data and the menu bar banner both still offer
        // the grant whenever the user wants it.
        if !permissions.accessibilityGranted,
           !UserDefaults.standard.bool(forKey: "askedAccessibilityOnStart") {
            UserDefaults.standard.set(true, forKey: "askedAccessibilityOnStart")
            permissions.promptAccessibility()
        }
    }

    func stopRecording() {
        recorder.stop()
        isRecording = false
    }

    /// Pause/resume capture for real — the menu-bar toggle. When paused, the CGEvent
    /// tap is disabled at the OS level (keystrokes aren't delivered) and clipboard/
    /// window pollers early-return. Nothing is stored while paused.
    func togglePause() {
        if isPaused { resumeCapture() } else { pauseCapture() }
    }

    /// Pause until the user resumes.
    func pauseCapture() {
        recorder.pauseIndefinitely()
        isPaused = true
        pauseEndsAt = nil
    }

    /// Pause for a fixed window, then auto-resume.
    func pauseCapture(for duration: TimeInterval) {
        recorder.pause(for: duration)
        isPaused = true
        let ends = Date().addingTimeInterval(duration)
        pauseEndsAt = ends
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            await MainActor.run {
                guard let self, self.pauseEndsAt == ends else { return }  // not superseded
                self.isPaused = false
                self.pauseEndsAt = nil
            }
        }
    }

    func resumeCapture() {
        recorder.resume()
        isPaused = false
        pauseEndsAt = nil
    }

    // MARK: - Forget (privacy — "that never happened")

    /// The cloud provider currently switched on, in the name a person would
    /// recognise, or `nil` when nothing leaves this Mac ("off", "local", "localopenai").
    ///
    /// One definition, used by both the Data tab's privacy notice and the forget
    /// dialog. Two spellings of "is this provider a cloud?" is how one surface
    /// ends up promising local-only while the other is uploading.
    static func cloudProviderName(for provider: String) -> String? {
        switch provider {
        case "claude": "Anthropic"
        case "openai": "OpenAI"
        case "gemini": "Google"
        default: nil
        }
    }

    var cloudProviderName: String? {
        Self.cloudProviderName(for: UserDefaults.standard.string(forKey: "llmProvider") ?? "off")
    }

    /// Survey what forgetting the last `minutes` would take. Read-only — this is
    /// what the confirmation dialog is built from.
    func forgetPlan(lastMinutes minutes: Int) -> ForgetService.Plan {
        let end = Date()
        let start = end.addingTimeInterval(-Double(minutes) * 60)
        return forgetPlan(for: DateInterval(start: start, end: end))
    }

    func forgetPlan(for interval: DateInterval) -> ForgetService.Plan {
        ForgetService.plan(interval: interval, database: database,
                           cloudProvider: cloudProviderName)
    }

    /// Perform a planned forget. Returns the plan with `retainedBlocks` filled in,
    /// so the caller can report what mull declined to delete — and with
    /// `failureMessage` set when the forget did not fully happen, so the caller
    /// can say so where the user is looking.
    ///
    /// The context files are regenerated immediately afterwards rather than left
    /// to the 60s tick: `forget` retracts mull's blocks, and this rebuilds what is
    /// still true from the post-delete database. Doing it in that order also
    /// settles a race — a generation pass already in flight when the rows went may
    /// land with pre-delete content, and this pass overwrites it. Regeneration
    /// runs on failure too: whatever state the database is in now is the state
    /// the context files should describe.
    @discardableResult
    func forget(_ plan: ForgetService.Plan) -> ForgetService.Plan {
        var result: ForgetService.Plan
        do {
            result = try ForgetService.forget(plan, database: database)
        } catch {
            result = plan
            result.failedLayer = (error as? ForgetService.LayerError)?.layer ?? "its records"
        }
        regenerateContextNow()
        loadTodaySummary()
        loadRecentSummaries()
        Task.detached { [database] in
            let count = database.eventCountToday()
            let bytes = database.storageBytesToday()
            await MainActor.run { [weak self] in
                self?.todayEventCount = count
                self?.todayStorageBytes = bytes
            }
        }
        // Success stays silent by design — the event count dropping is the
        // confirmation. Failure is the one outcome this feature must never keep
        // to itself: a forget that quietly didn't happen is exactly the "success
        // it did not achieve" the service's header warns about. The notice bar
        // is the app-wide record; callers with their own surface (the menu bar
        // panel, Settings) additionally show the same message where the user is.
        if let problem = result.failureMessage {
            postNotice("Forget didn't finish", detail: problem, isProblem: true)
        }
        return result
    }

    // MARK: - App exclusion (privacy — "don't record in these apps")

    var excludedAppList: [(id: String, name: String)] { recorder.excludedAppList }
    var addableRunningApps: [(id: String, name: String)] { recorder.addableRunningApps }
    func excludeApp(_ bundleID: String) { recorder.addExcludedApp(bundleID); objectWillChange.send() }
    func includeApp(_ bundleID: String) { recorder.removeExcludedApp(bundleID); objectWillChange.send() }

    /// Run mull immediately (manual trigger).
    func triggerSummaryNow() {
        guard !isSummarizing else { return }

        Task {
            isSummarizing = true
            mullProgress = "Summarizing..."

            do {
                let summary = try await mullEngine.runSummary()
                todaySummary = summary
                hasUnreadSummary = true
                lastSummaryDate = Date()
                loadRecentSummaries()
                mullProgress = nil

                // No banner: this is the manual run, so the person is in the window
                // watching the progress line they started. The nightly run keeps its
                // banner — that one finishes while they are elsewhere.
            } catch {
                mullProgress = "mull failed: \(error.localizedDescription)"
                // `mullProgress` clears itself after five seconds, so someone who
                // started this and walked away would find no trace of the failure.
                // The notice stays until dismissed, without a banner.
                postNotice("Summary didn't run", detail: error.localizedDescription, isProblem: true)
                try? await Task.sleep(for: .seconds(5))
                mullProgress = nil
            }

            isSummarizing = false
        }
    }

    private func sendNotification(title: String, body: String) {
        Notifier.shared.send(id: UUID().uuidString, title: title, body: body)
    }

    /// Settings › General › Notifications. Absent key means on. Governs only the
    /// banner: the summary itself, the in-app notices and the menu bar's unread
    /// mark are unaffected.
    private var summaryBannersEnabled: Bool {
        UserDefaults.standard.object(forKey: "summaryNotifications") as? Bool ?? true
    }

    // MARK: - Permission loss

    /// Say that capture has stopped, and give the user the way back.
    ///
    /// Three channels because no single one is reliable at the moment it matters:
    /// the in-app notice is sticky (it's a problem, so it waits to be dismissed
    /// rather than fading) but only exists inside the window; the system
    /// notification reaches the user who is in System Settings or another app; and
    /// the sheet is the one-click re-grant, shown only on mull's own window so it
    /// never steals focus from whatever they are actually doing.
    ///
    /// Silent during onboarding: the permissions step is already this conversation,
    /// and interrupting it with an alert about the switch the user is mid-way
    /// through flipping would be noise.
    private func handlePermissionRevoked(_ permission: PermissionService.Permission) {
        guard hasCompletedOnboarding else { return }

        let detail = "mull has stopped recording \(permission.whatStops). "
            + "Turn \(permission.displayName) back on for mull in System Settings → "
            + "Privacy & Security to pick it back up."
        postNotice("\(permission.displayName) was turned off", detail: detail, isProblem: true)
        sendNotification(title: "mull stopped recording", body: detail)
        AppDelegate.shared?.presentPermissionRecovery(permission)
    }

    /// Open the pane for a permission — used by the recovery sheet.
    func openSettingsFor(_ permission: PermissionService.Permission) {
        switch permission {
        case .accessibility: permissions.openAccessibilitySettings()
        case .inputMonitoring: permissions.openInputMonitoringSettings()
        }
    }

    func markSummaryRead() {
        hasUnreadSummary = false
    }

    /// Inject context directly into the focused text field. ⌘+Shift+W from anywhere.
    /// Clipboard-safe: saves current clipboard, pastes context, restores original clipboard.
    func injectContextIntoFocusedField() {
        Task {
            let contextText = await ContextComposer(database: database).compose()
            guard !contextText.isEmpty else {
                postNotice(Self.nothingToLendTitle, detail: Self.nothingToLendDetail, isProblem: true)
                return
            }
            // Already on the main actor (AppState is @MainActor) — no await needed.
            // The synthetic ⌘V needs Accessibility; without it nothing is pasted
            // and saying otherwise would be mull reporting work it didn't do. The
            // context is put on the clipboard instead, so the user can finish the
            // job themselves rather than being left with nothing.
            guard TextInjector.inject(contextText) else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(contextText, forType: .string)
                postNotice(
                    "Couldn't paste it for you",
                    detail: "Pasting into another app needs Accessibility, which mull doesn't have. Your context is on the clipboard — press ⌘V. Settings › Data can turn the permission on.",
                    isProblem: true)
                return
            }
            // Nothing to announce on success: the text is now sitting in the field
            // the person is looking at. Only the failure above is worth saying out
            // loud, because that one leaves the field empty.
        }
    }

    /// Instant copy — no UI, no sheet. ⌘+Shift+C from anywhere.
    func copyContextToClipboard() {
        Task {
            let finalText = await ContextComposer(database: database).compose()
            // Nothing composed means mull genuinely has nothing to lend yet — say so
            // rather than leaving the clipboard silently untouched. The clipboard is
            // deliberately not cleared: whatever the user had there is still theirs.
            guard !finalText.isEmpty else {
                postNotice(Self.nothingToLendTitle, detail: Self.nothingToLendDetail, isProblem: true)
                return
            }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(finalText, forType: .string)

            let wordCount = finalText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
            // In-app notice only. This used to also fire a system banner, on the
            // reasoning that ⌘⇧C is a global shortcut so the window is usually not
            // on screen to show the notice — but the person pressed the shortcut,
            // and a banner with a sound announcing the result of a key you just hit
            // is the thing macOS reserves for what happens without you. The auto-copy
            // in ProactiveEngine still announces itself, because nobody asked for it
            // and it puts the clipboard back 30 seconds later.
            postNotice("Context copied", detail: "\(wordCount) words about your day — paste into any AI.")
        }
    }

    private static let nothingToLendTitle = "Nothing to lend yet"
    private static let nothingToLendDetail =
        "mull hasn't recorded enough today to describe what you're working on. "
        + "Leave it running a little longer, or check that recording is on in Live."

    /// Open the main mull window from anywhere via ⌘+Shift+D
    ///
    /// Asks the object that owns the window rather than hunting `NSApp.windows` for
    /// one titled "mull". No window has ever had that title — the main window is
    /// created with `title = ""` and `titleVisibility = .hidden`, because its title
    /// bar is meant to be empty — so the lookup matched nothing and this did nothing
    /// at all, every time, whenever the window had been closed. Which is precisely
    /// when someone reaches for it.
    func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.shared?.showMainWindow()
    }

    // MARK: - Data Loading

    func loadTodaySummary() {
        todaySummary = database.fetchSummary(for: Date())
    }

    func loadRecentSummaries() {
        recentSummaries = database.fetchRecentSummaries(limit: 30)
    }

    // MARK: - Formatted Helpers

    var todayStorageFormatted: String {
        ByteCountFormatter.string(fromByteCount: todayStorageBytes, countStyle: .file)
    }

    /// How many records mull stored today, said as what it is.
    ///
    /// `todayEventCount` is a row count — buffered keystroke lines, clipboard
    /// entries, window and app changes. Rendered large and called "events" it reads
    /// like a score for the day's work, which it is not: a long think with no typing
    /// scores near zero. "Captures" names the mechanism instead of implying a
    /// verdict, and the singular case reads correctly ("1 capture", not "1 events").
    var todayCaptureLabel: String {
        let n = todayEventCount
        if n == 1 { return "1 capture" }
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return "\(formatted) captures"
    }

    // MARK: - Data Retention

    /// Default retention for a fresh install: 90 days of raw events.
    ///
    /// The default used to be "unlimited", which meant the code below early-returned
    /// and a default install grew forever — the doc comment claimed a 7-day auto-prune
    /// that did not exist. 90 days is long enough to cover the review/retrospective
    /// use cases in DIRECTION.md §3 (a quarter of history) while bounding the file.
    /// Summaries and memory files are unaffected by this — they're the durable layer.
    /// The user can still choose "unlimited" explicitly in Settings → Data.
    static let defaultDataRetentionDays = "90"

    /// Apply the data retention policy on launch.
    ///
    /// Honours the user's Settings → Data choice; on a fresh install that choice is
    /// `defaultDataRetentionDays` rather than unlimited, so the DB is bounded without
    /// the user having to discover the setting. Choosing "unlimited" disables pruning
    /// entirely — there is no hidden forced deletion.
    func applyDataRetention() {
        let db = database
        Task.detached { Self.pruneToRetention(database: db) }
    }

    /// The actual pruning. `nonisolated` and database-parameterised so the launch
    /// path can run it off the main thread — two DELETEs plus a VACUUM is not
    /// something to do while the first frame is waiting.
    nonisolated static func pruneToRetention(database: DatabaseService) {
        let retentionSetting = UserDefaults.standard.string(forKey: "dataRetention")
            ?? defaultDataRetentionDays
        guard retentionSetting != "unlimited", let days = Int(retentionSetting) else { return }

        try? database.deleteEventsOlderThan(days: days)
        try? database.deleteSummariesOlderThan(days: days)
        database.vacuum()
    }
}
