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

    private var refreshTimer: Timer?
    private var eveningDraftTimer: Timer?
    private var lastRefreshDate: Date = Date()
    private var globalShortcutMonitor: Any?

    deinit {
        refreshTimer?.invalidate()
        eveningDraftTimer?.invalidate()
        ingestion.stop()
        mullEngine.cancelSchedule()
        if let monitor = globalShortcutMonitor {
            NSEvent.removeMonitor(monitor)
        }
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

        // Set default output limit if not configured
        if UserDefaults.standard.object(forKey: "outputMaxChars") == nil {
            UserDefaults.standard.set(50000, forKey: "outputMaxChars")
        }

        // Global keyboard shortcuts
        globalShortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // ⌘+Shift+D — open main window
            if mods == [.command, .shift] && event.keyCode == 2 {
                Task { @MainActor in
                    self?.openMainWindow()
                }
            }

            // ⌘+Shift+C — instant copy context to clipboard (no UI, no sheet)
            if mods == [.command, .shift] && event.keyCode == 8 {
                Task { @MainActor in
                    self?.copyContextToClipboard()
                }
            }

            // ⌘+Shift+W — inject context into current text field (clipboard-safe)
            if mods == [.command, .shift] && event.keyCode == 13 {
                Task { @MainActor in
                    self?.injectContextIntoFocusedField()
                }
            }
        }

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
        if hasCompletedOnboarding {
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

    func markSummaryRead() {
        hasUnreadSummary = false
    }

    /// Inject context directly into the focused text field. ⌘+Shift+W from anywhere.
    /// Clipboard-safe: saves current clipboard, pastes context, restores original clipboard.
    func injectContextIntoFocusedField() {
        Task {
            let contextText = await buildContextText()
            guard !contextText.isEmpty else { return }
            // Already on the main actor (AppState is @MainActor) — no await needed.
            performInject(contextText)
        }
    }

    private func performInject(_ contextText: String) {

        // 1. Save current clipboard
        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
            guard let type = item.types.first,
                  let data = item.data(forType: type) else { return nil }
            return (type.rawValue, data)
        } ?? []

        // 2. Put context on clipboard
        pasteboard.clearContents()
        pasteboard.setString(contextText, forType: .string)

        // 3. Simulate ⌘V to paste into focused field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .combinedSessionState)
            // Key down: ⌘V
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
                keyDown.flags = .maskCommand
                keyDown.post(tap: .cghidEventTap)
            }
            // Key up: ⌘V
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
                keyUp.flags = .maskCommand
                keyUp.post(tap: .cghidEventTap)
            }

            // 4. Restore original clipboard after paste completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !savedItems.isEmpty {
                    pasteboard.clearContents()
                    for (typeStr, data) in savedItems {
                        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(typeStr))
                    }
                }
            }
        }

        sendNotification(
            title: "Context injected",
            body: "Your AI context has been pasted. Clipboard restored."
        )
    }

    /// Build the "Copy to AI" text — a SELECTED, current, self-contained snapshot,
    /// not a raw full.md dump. It composes the same use-time signals the MCP tools
    /// serve (identity + what you're doing now + where you left off), so a paste
    /// into ChatGPT/Claude is immediately useful with no tools to call. Passively
    /// consumed media (YouTube titles you watched, background audio) is excluded by
    /// construction: these engines key on projects/apps/files, not raw window
    /// titles, so the noise that pollutes full.md never reaches the clipboard.
    private func buildContextText() async -> String {
        await Task.detached { [database] in
            var sections: [String] = []

            // 1. Who I am — rule-based identity facts (role, stack, work patterns).
            //    NOT me.md: its header is MCP-oriented boilerplate ("call the tools"),
            //    which is useless once pasted somewhere no tools exist.
            let identity = FactExtractor(analytics: AnalyticsEngine(database: database),
                                         database: database)
                .generateFactSummary(days: 14)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !identity.isEmpty { sections.append("# Who I am\n\n\(identity)") }

            // 2. Right now — organized by MODE, not filtered by deletion
            //    (MAP-ARCHITECTURE.md: keep everything, mean it with mode). The lens
            //    for a small-context model surfaces what you're DOING
            //    (produce/decide/think/communicate) and keeps consumption but
            //    compacts it as research/consume — nothing is silently dropped.
            let state = CurrentState.current(database: database)
            var nowLines: [String] = []
            if let entity = state.activeEntity { nowLines.append("Active: \(entity)") }
            else if let title = state.activeTitle { nowLines.append("Active: \(title)") }
            if let app = state.activeApp { nowLines.append("App: \(app)") }

            var doing: [String] = []        // produce / decide / think / communicate
            var researching: [String] = []  // consume / research — kept, compacted
            var seen = Set<String>()
            for e in database.fetchEvents(from: Date().addingTimeInterval(-1800), to: Date()).reversed() {
                guard e.eventType == .clipboard || e.eventType == .screenText,
                      let raw = e.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                      raw.count >= 3 else { continue }
                let key = String(raw.prefix(40)).lowercased()
                if seen.contains(key) { continue }
                seen.insert(key)
                let snippet = String(raw.prefix(90))
                switch e.resolvedMode {
                case .produce, .decide, .think, .communicate:
                    if doing.count < 6 { doing.append("- [\(e.resolvedMode.rawValue)] \(snippet)") }
                case .consume, .research:
                    if researching.count < 4 { researching.append(String(snippet.prefix(50))) }
                }
                if doing.count >= 6 && researching.count >= 4 { break }
            }
            if !doing.isEmpty {
                nowLines.append("Recently (doing):")
                nowLines.append(contentsOf: doing)
            }
            if !researching.isEmpty {
                nowLines.append("Also (research/consume): " + researching.joined(separator: " · "))
            }
            if !nowLines.isEmpty { sections.append("# Right now\n\n\(nowLines.joined(separator: "\n"))") }

            // 3. Where I left off — ranked active projects with resume points.
            //    Drop window-title / file-path junk masquerading as a project
            //    (full paths, "NNN notes" counters, truncated titles): better an
            //    empty section than "projects" the AI would wrongly trust.
            func isJunkProject(_ name: String) -> Bool {
                if name.contains("/") { return true }
                if name.contains("…") || name.hasSuffix("...") { return true }
                if name.range(of: #"\d+\s*notes"#, options: .regularExpression) != nil { return true }
                return false
            }
            let snaps = TimeBlockEngine(database: database).projectSnapshots(days: 14)
            let active = snaps.filter { $0.daysSinceActive < 3 && !isJunkProject($0.name) }.prefix(5)
            if !active.isEmpty {
                var lines = ["# Active work — where I left off"]
                for p in active {
                    var line = "- **\(p.name)** — \(p.totalDurationFormatted), \(p.primaryApp), last \(p.lastActiveFormatted)"
                    if let file = p.lastFile { line += "\n  - resume at: \(file)" }
                    lines.append(line)
                }
                sections.append(lines.joined(separator: "\n"))
            }

            guard !sections.isEmpty else { return "" }

            // A short preamble so the pasted block is self-explanatory to any AI.
            let preamble = "Here is my current context from mull (a tool that records what I work on). "
                + "Use it to help me without making me re-explain myself.\n"
            var text = preamble + "\n" + sections.joined(separator: "\n\n")
            text = ContextBlockFile.stripMarkers(text)

            let maxChars = UserDefaults.standard.integer(forKey: "outputMaxChars")
            return (maxChars > 0 && text.count > maxChars) ? String(text.prefix(maxChars)) : text
        }.value
    }

    /// Instant copy — no UI, no sheet. ⌘+Shift+C from anywhere.
    func copyContextToClipboard() {
        Task {
            let finalText = await buildContextText()
            guard !finalText.isEmpty else { return }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(finalText, forType: .string)

            let wordCount = finalText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
            sendNotification(
                title: "Context copied",
                body: "Paste into any AI — \(wordCount) words about your day."
            )
        }
    }

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

    // MARK: - Data Retention

    /// Default retention for a fresh install: 90 days of raw events.
    ///
    /// The default used to be "unlimited", which meant the code below early-returned
    /// and a default install grew forever — the doc comment claimed a 7-day auto-prune
    /// that did not exist. 90 days is long enough to cover the review/retrospective
    /// use cases in PRODUCT.md §2 (a quarter of history) while bounding the file.
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
