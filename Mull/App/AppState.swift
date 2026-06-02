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
    private var lastRefreshDate: Date = Date()
    private var globalShortcutMonitor: Any?

    deinit {
        refreshTimer?.invalidate()
        ingestion.stop()
        mullEngine.cancelSchedule()
        if let monitor = globalShortcutMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Init

    init() {
        // Validate ~/mull directory before anything else
        MullDirectory.setup()
        // Scaffold the v3 folder ontology (idempotent, non-destructive).
        FolderOntology.scaffold()

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

        loadTodaySummary()
        loadRecentSummaries()

        // Pull from configured sources every 30 min (no-op if none configured).
        ingestion.schedule(every: 1800)

        // Auto-start recording if onboarding is already done
        // Don't gate on AXIsProcessTrusted — it lies on debug builds.
        // Recording will start and capture what it can.
        // Always start recording if onboarding is done
        if hasCompletedOnboarding {
            startRecording()
        }
        // Onboarding is handled by AppDelegate.applicationDidFinishLaunching

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

        let hour = UserDefaults.standard.object(forKey: "summaryTime") as? Int ?? 23
        let minute = UserDefaults.standard.object(forKey: "summaryTimeMinute") as? Int ?? 0
        mullEngine.scheduleSummary(at: hour, minute: minute)

        // Set default output limit if not configured
        if UserDefaults.standard.object(forKey: "outputMaxChars") == nil {
            UserDefaults.standard.set(50000, forKey: "outputMaxChars")
        }

        // Apply data retention on launch
        applyDataRetention()

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
        refreshStats()
    }

    private var lastMeFileUpdate: Date = .distantPast

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

        // DB reads + file generation on background thread
        let db = database
        let analyticsRef = analytics
        let calendarRef = calendar
        let emailRef = email
        let shouldGenerateFiles = todayEventCount > 0 && Date().timeIntervalSince(lastMeFileUpdate) > 60

        Task.detached {
            let count = db.eventCountToday()
            let bytes = db.storageBytesToday()

            if shouldGenerateFiles {
                LiveContextGenerator.calendarService = calendarRef
                LiveContextGenerator.emailService = emailRef
                try? LiveContextGenerator.generate(analytics: analyticsRef, database: db)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.todayEventCount = count
                self.todayStorageBytes = bytes
                if shouldGenerateFiles {
                    self.lastMeFileUpdate = Date()
                }
            }
        }
    }

    // MARK: - Actions

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

    func pauseRecording(duration: TimeInterval) {
        recorder.pause(for: duration)
        isPaused = true

        Task {
            try? await Task.sleep(for: .seconds(duration))
            isPaused = false
        }
    }

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
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
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
            await performInject(contextText)
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

    /// Build context text from mull files. Reads from disk on a background thread.
    private func buildContextText() async -> String {
        await Task.detached {
            var text: String
            if let fullContent = MullDirectory.read("full.md"), fullContent.count > 50 {
                text = fullContent
            } else {
                let parts = ["me.md", "now.md"].compactMap { MullDirectory.read($0) }
                    .filter { !$0.isEmpty }
                text = parts.isEmpty ? "" : parts.joined(separator: "\n\n")
            }
            // Never export Curator provenance markers to an AI/clipboard.
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

    /// Apply data retention policy on launch + periodically.
    /// Also auto-prunes raw events older than 7 days regardless of mull,
    /// so DB doesn't grow forever if user never triggers mull.
    func applyDataRetention() {
        let retentionSetting = UserDefaults.standard.string(forKey: "dataRetention") ?? "unlimited"

        // Only apply user's configured retention — no hidden forced deletion
        if retentionSetting != "unlimited", let days = Int(retentionSetting) {
            try? database.deleteEventsOlderThan(days: days)
            try? database.deleteSummariesOlderThan(days: days)
            database.vacuum()
        }
    }
}
