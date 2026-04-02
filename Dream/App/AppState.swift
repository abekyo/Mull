import SwiftUI
import Combine
import ApplicationServices
@preconcurrency import UserNotifications

/// Central observable state for the entire app.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Dream Engine State

    @Published var isSummarizing = false
    @Published var whatlyProgress: String?
    @Published var lastSummaryDate: Date?

    // MARK: - Recording State

    @Published var isRecording = false
    @Published var isPaused = false
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
    let permissions = PermissionService()
    @Published var todayEventCount: Int = 0
    @Published var todayStorageBytes: Int64 = 0

    // MARK: - Privacy

    @Published var analyticsOptIn = false

    // LLM provider — synced with @AppStorage
    @Published var llmProvider: LLMProvider = .local {
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
    let whatlyEngine: WhatlyEngine
    let analytics: AnalyticsEngine
    let calendar: CalendarService
    let email: EmailService

    private var refreshTimer: Timer?
    private var lastRefreshDate: Date = Date()
    private var globalShortcutMonitor: Any?

    deinit {
        refreshTimer?.invalidate()
        whatlyEngine.cancelSchedule()
        if let monitor = globalShortcutMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Init

    init() {
        self.database = DatabaseService()
        self.recorder = RecordingService(database: database)
        self.whatlyEngine = WhatlyEngine(database: database)
        self.analytics = AnalyticsEngine(database: database)
        self.calendar = CalendarService()
        self.email = EmailService(database: database)

        // Sync LLM provider from UserDefaults
        if let saved = UserDefaults.standard.string(forKey: "llmProvider"),
           let provider = LLMProvider(rawValue: saved) {
            self.llmProvider = provider
        }

        loadTodaySummary()
        loadRecentSummaries()

        // Auto-start recording if onboarding is already done
        // Don't gate on AXIsProcessTrusted — it lies on debug builds.
        // Recording will start and capture what it can.
        // Always start recording if onboarding is done
        if hasCompletedOnboarding {
            startRecording()
        }
        // Onboarding is handled by AppDelegate.applicationDidFinishLaunching

        // Schedule nightly dream + wire up completion callbacks
        whatlyEngine.onSummaryComplete = { [weak self] summary in
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
        whatlyEngine.onSummaryFailed = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.sendNotification(
                    title: "Summary failed",
                    body: error.localizedDescription
                )
            }
        }

        let hour = UserDefaults.standard.object(forKey: "summaryTime") as? Int ?? 23
        let minute = UserDefaults.standard.object(forKey: "summaryTimeMinute") as? Int ?? 0
        whatlyEngine.scheduleSummary(at: hour, minute: minute)

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

        todayEventCount = database.eventCountToday()
        todayStorageBytes = database.storageBytesToday()

        // Auto-generate me.md/now.md every 60 seconds if we have data
        // No LLM needed — pure rule-based from AnalyticsEngine
        if todayEventCount > 0 && Date().timeIntervalSince(lastMeFileUpdate) > 60 {
            lastMeFileUpdate = Date()
            LiveContextGenerator.calendarService = calendar
            LiveContextGenerator.emailService = email
            Task.detached { [analytics, database] in
                try? LiveContextGenerator.generate(analytics: analytics, database: database)
            }
        }
    }

    // MARK: - Actions

    func startRecording() {
        recorder.start()
        email.start()
        isRecording = true
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

    /// Run Dream immediately (manual trigger).
    func triggerSummaryNow() {
        guard !isSummarizing else { return }

        Task {
            isSummarizing = true
            whatlyProgress = "Summarizing..."

            do {
                let summary = try await whatlyEngine.runSummary()
                todaySummary = summary
                hasUnreadSummary = true
                lastSummaryDate = Date()
                loadRecentSummaries()
                whatlyProgress = nil

                // macOS notification — pull user back
                sendNotification(
                    title: "Summary is ready",
                    body: summary.preview
                )
            } catch {
                whatlyProgress = "Dream failed: \(error.localizedDescription)"
                sendNotification(
                    title: "Summary failed",
                    body: error.localizedDescription
                )
                try? await Task.sleep(for: .seconds(5))
                whatlyProgress = nil
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

    /// Instant copy — no UI, no sheet. ⌘+Shift+C from anywhere.
    func copyContextToClipboard() {
        let whatlyDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Whatly")

        // Read full.md (richest) → fallback to me.md + now.md
        let text: String
        let fullFile = whatlyDir.appendingPathComponent("full.md")
        if let content = try? String(contentsOf: fullFile, encoding: .utf8), content.count > 50 {
            text = content
        } else {
            var parts: [String] = []
            for file in ["me.md", "now.md"] {
                if let content = try? String(contentsOf: whatlyDir.appendingPathComponent(file), encoding: .utf8),
                   !content.isEmpty {
                    parts.append(content)
                }
            }
            text = parts.isEmpty ? "Whatly is still recording. No context yet." : parts.joined(separator: "\n\n")
        }

        // Apply max chars
        let maxChars = UserDefaults.standard.integer(forKey: "outputMaxChars")
        let finalText = (maxChars > 0 && text.count > maxChars) ? String(text.prefix(maxChars)) : text

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(finalText, forType: .string)

        // Notify — make it feel like a moment, not a file transfer
        let wordCount = finalText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        sendNotification(
            title: "Your context is ready",
            body: "Paste into any AI — it will understand \(wordCount) words about your day."
        )
    }

    /// Open the main Dream window from anywhere via ⌘+Shift+D
    func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Open the main window by its ID
        if let window = NSApp.windows.first(where: { $0.title == "Whatly" }) {
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
    /// Also auto-prunes raw events older than 7 days regardless of Dream,
    /// so DB doesn't grow forever if user never triggers Dream.
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
