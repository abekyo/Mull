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
        // The self-driving proactive loop (DIRECTION §7): anchor → select → judge
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
                self.sendNotification(
                    title: "Tonight's summary is ready ☽",
                    body: summary.preview
                )
            }
        }
        mullEngine.onSummaryFailed = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.sendNotification(
                    title: "Summary failed",
                    body: error.localizedDescription
                )
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
        // Scaffold the v3 folder ontology (idempotent, non-destructive) and apply
        // retention — both are file/DB work with no first-frame dependency.
        let db = database
        Task.detached {
            FolderOntology.scaffold()
            Self.pruneToRetention(database: db)
            let today = db.fetchSummary(for: Date())
            let recent = db.fetchRecentSummaries(limit: 30)
            await MainActor.run { [weak self] in
                self?.todaySummary = today
                self?.recentSummaries = recent
            }
        }

        // Pull from configured sources every 30 min (no-op if none configured).
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
    /// than 3s (FolderFiller alone does a 14-day TimeBlockEngine scan plus a 7-day
    /// fetch), so the gate stayed open and each tick spawned another overlapping run
    /// — several of them racing inside Curator's non-atomic read-merge-write, which
    /// is exactly how curated blocks get lost. Same check-and-set pattern as
    /// IngestionService.beginRun.
    private var contextGenerationInFlight = false

    /// Run one context generation if none is already running. Shared by the 60s tick
    /// and the explicit `regenerateContextNow()` so the two can never overlap either.
    private func generateContextIfIdle() {
        guard !contextGenerationInFlight else { return }
        contextGenerationInFlight = true

        let db = database
        let analyticsRef = analytics
        let calendarRef = calendar
        let emailRef = email

        Task.detached {
            // Services are passed in, not stashed in LiveContextGenerator statics —
            // those assignments were a retain/release race across detached tasks.
            try? LiveContextGenerator.generate(analytics: analyticsRef, database: db,
                                               calendar: calendarRef, email: emailRef)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastMeFileUpdate = Date()
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

        if todayEventCount > 0 && Date().timeIntervalSince(lastMeFileUpdate) > 60 {
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
        if !permissions.accessibilityGranted {
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

                // macOS notification — pull user back
                sendNotification(
                    title: "Summary is ready",
                    body: summary.preview
                )
            } catch {
                mullProgress = "mull failed: \(error.localizedDescription)"
                sendNotification(
                    title: "Summary failed",
                    body: error.localizedDescription
                )
                try? await Task.sleep(for: .seconds(5))
                mullProgress = nil
            }

            isSummarizing = false
        }
    }

    private func sendNotification(title: String, body: String) {
        Notifier.shared.send(id: UUID().uuidString, title: title, body: body)
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
            TextInjector.inject(contextText)
            sendNotification(
                title: "Context injected",
                body: "Your AI context has been pasted. Clipboard restored."
            )
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
            // In-app first (a system notification is invisible under Do Not Disturb),
            // notification second for when the window isn't on screen.
            postNotice("Context copied", detail: "\(wordCount) words about your day — paste into any AI.")
            sendNotification(
                title: "Context copied",
                body: "Paste into any AI — \(wordCount) words about your day."
            )
        }
    }

    private static let nothingToLendTitle = "Nothing to lend yet"
    private static let nothingToLendDetail =
        "mull hasn't recorded enough today to describe what you're working on. "
        + "Leave it running a little longer, or check that recording is on in Live."

    /// Open the main mull window from anywhere via ⌘+Shift+D
    func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Open the main window by its ID
        if let window = NSApp.windows.first(where: { $0.title == "mull" }) {
            window.makeKeyAndOrderFront(nil)
        }
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
