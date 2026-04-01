import SwiftUI
import Combine
import ApplicationServices
@preconcurrency import UserNotifications

/// Central observable state for the entire app.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Dream Engine State

    @Published var isDreaming = false
    @Published var dreamProgress: String?
    @Published var lastDreamDate: Date?

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
    @Published var hasUnreadDream = false

    // MARK: - Services

    let database: DatabaseService
    let recorder: RecordingService
    let dreamEngine: DreamEngine
    let analytics: AnalyticsEngine
    let calendar: CalendarService
    let email: EmailService

    private var refreshTimer: Timer?
    private var lastRefreshDate: Date = Date()
    private var globalShortcutMonitor: Any?

    deinit {
        refreshTimer?.invalidate()
        dreamEngine.cancelSchedule()
        if let monitor = globalShortcutMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Init

    init() {
        self.database = DatabaseService()
        self.recorder = RecordingService(database: database)
        self.dreamEngine = DreamEngine(database: database)
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
        dreamEngine.onDreamComplete = { [weak self] summary in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.todaySummary = summary
                self.hasUnreadDream = true
                self.lastDreamDate = Date()
                self.loadRecentSummaries()
                self.sendNotification(
                    title: "Tonight's Dream is ready ☽",
                    body: summary.preview
                )
            }
        }
        dreamEngine.onDreamFailed = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.sendNotification(
                    title: "Dream failed",
                    body: error.localizedDescription
                )
            }
        }

        let hour = UserDefaults.standard.object(forKey: "dreamTime") as? Int ?? 23
        let minute = UserDefaults.standard.object(forKey: "dreamTimeMinute") as? Int ?? 0
        dreamEngine.scheduleDream(at: hour, minute: minute)

        // Set default output limit if not configured
        if UserDefaults.standard.object(forKey: "outputMaxChars") == nil {
            UserDefaults.standard.set(50000, forKey: "outputMaxChars")
        }

        // Apply data retention on launch
        applyDataRetention()

        // Global keyboard shortcut: ⌘+Shift+D opens the main window
        globalShortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // ⌘+Shift+D
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 2 {
                Task { @MainActor in
                    self?.openMainWindow()
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
    func triggerDreamNow() {
        guard !isDreaming else { return }

        Task {
            isDreaming = true
            dreamProgress = "Dreaming..."

            do {
                let summary = try await dreamEngine.runDream()
                todaySummary = summary
                hasUnreadDream = true
                lastDreamDate = Date()
                loadRecentSummaries()
                dreamProgress = nil

                // macOS notification — pull user back
                sendNotification(
                    title: "Dream is ready",
                    body: summary.preview
                )
            } catch {
                dreamProgress = "Dream failed: \(error.localizedDescription)"
                sendNotification(
                    title: "Dream failed",
                    body: error.localizedDescription
                )
                try? await Task.sleep(for: .seconds(5))
                dreamProgress = nil
            }

            isDreaming = false
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

    func markDreamRead() {
        hasUnreadDream = false
    }

    /// Open the main Dream window from anywhere via ⌘+Shift+D
    func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Open the main window by its ID
        if let window = NSApp.windows.first(where: { $0.title == "Dream" }) {
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
