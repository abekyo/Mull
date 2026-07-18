import Foundation
import AppKit
@preconcurrency import UserNotifications

/// The one notification path for the whole app.
///
/// There used to be three independent `UNMutableNotificationContent` builders
/// (AppState, ProactiveEngine, ProactiveLoop), each with its own throttle and no
/// knowledge of the others. ProactiveEngine and ProactiveLoop both fire on a project
/// switch from the SAME 3-second tick, so one app switch could produce two banners
/// saying nearly the same thing. Routing everything through here gives them a shared
/// rate limit and a shared record of which project has already been announced.
@MainActor
final class Notifier {

    static let shared = Notifier()
    private init() {}

    /// Floor between any two notifications, whatever their source. Long enough that
    /// two systems reacting to one app switch collapse into a single banner, short
    /// enough that genuinely separate events (a meeting reminder an hour later)
    /// still get through.
    private let globalFloor: TimeInterval = 30

    private var lastSentAt: Date = .distantPast
    private var announcedProjects: [String: Date] = [:]

    /// Deliver a notification unless another one just went out. Returns whether it
    /// was actually enqueued, so callers can avoid marking state as "notified" for
    /// something the user never saw.
    @discardableResult
    func send(id: String, title: String, body: String, userInfo: [String: Any] = [:]) -> Bool {
        guard Date().timeIntervalSince(lastSentAt) >= globalFloor else { return false }
        lastSentAt = Date()

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if !userInfo.isEmpty { content.userInfo = userInfo }

            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
        return true
    }

    /// Claim the right to announce a return to `project`. The first of the two
    /// proactive systems to ask wins; the other stays quiet for the cooldown, so a
    /// single switch yields one brief instead of two contradicting ones.
    func claimProjectAnnouncement(_ project: String, cooldown: TimeInterval = 900) -> Bool {
        let key = project.lowercased()
        if let last = announcedProjects[key], Date().timeIntervalSince(last) < cooldown {
            return false
        }
        announcedProjects[key] = Date()
        return true
    }
}

/// mull comes to you. Not the other way around.
///
/// Four interventions, each triggered by existing data:
///
///   1. AI auto-copy — user opens claude.ai or chatgpt.com → context copied to clipboard
///   2. Project resumption — stale project reopened → notification with "Open" action
///   3. Morning briefing — first activity of the day → notification with top action
///   4. Pre-meeting — 15 minutes before a calendar event → notification
///
/// No polling. No new observers. Runs inside AppState's existing 3-second refresh loop.
@MainActor
final class ProactiveEngine: NSObject {

    private let database: DatabaseService
    private let calendar: CalendarService
    private let analytics: AnalyticsEngine

    // State tracking to avoid duplicate triggers
    private var hasSentMorningBriefing = false
    private var lastMorningBriefingDate: Date = .distantPast
    private var notifiedMeetings: Set<String> = []
    private var notifiedProjects: Set<String> = []
    private var notifiedKnowledge: Set<String> = []  // knowledge topics already surfaced today
    private var lastActiveApp: String = ""
    private var lastActiveWindow: String = ""
    private var projectCache: [ProjectSnapshot] = []
    private var projectCacheDate: Date = .distantPast
    private var projectCacheRefreshing = false

    // Upcoming calendar events, cached. `upcomingEvents` is a full EventKit
    // predicate query; running it straight off the 3-second tick meant one every
    // 3 seconds on the main thread. The pre-meeting window is 13–15 minutes out,
    // so a 60-second refresh cannot miss it.
    private var upcomingCache: [(title: String, start: Date)] = []
    private var upcomingCacheDate: Date = .distantPast
    private var upcomingRefreshing = false

    // AI auto-copy state
    private var lastCopiedForAIURL: String = ""
    private var lastAICopyDate: Date = .distantPast

    // Notification action data
    private var pendingActions: [String: NotificationAction] = [:]

    /// The AI sites that trigger auto-copy.
    private static let aiSites = ["claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com"]

    init(database: DatabaseService, calendar: CalendarService, analytics: AnalyticsEngine) {
        self.database = database
        self.calendar = calendar
        self.analytics = analytics
        super.init()
        setupNotificationDelegate()
    }

    /// Called every 3 seconds from AppState.refreshStats().
    func tick(todayEventCount: Int, currentApp: String?, currentWindow: String?, browserURL: String?) {
        let today = Calendar.current.startOfDay(for: Date())

        // Reset daily state at midnight
        if today != Calendar.current.startOfDay(for: lastMorningBriefingDate) {
            hasSentMorningBriefing = false
            notifiedMeetings.removeAll()
            notifiedProjects.removeAll()
            notifiedKnowledge.removeAll()
            lastCopiedForAIURL = ""
            lastAICopyDate = .distantPast
            lastMorningBriefingDate = today
        }

        // 1. AI auto-copy — highest priority, zero friction
        if let url = browserURL {
            checkAISiteAndCopy(url: url)
        }

        // 2. Morning briefing
        if !hasSentMorningBriefing && todayEventCount > 5 {
            hasSentMorningBriefing = true
            sendMorningBriefing()
        }

        // 3. Project resumption + knowledge surfacing
        let app = currentApp ?? ""
        let window = currentWindow ?? ""
        if app != lastActiveApp || window != lastActiveWindow {
            lastActiveApp = app
            lastActiveWindow = window
            checkProjectResumption(app: app, window: window)
            surfaceRelevantKnowledge(window: window)
        }

        // 4. Pre-meeting
        checkUpcomingMeetings()
    }

    // MARK: - 1. AI Auto-Copy

    private func checkAISiteAndCopy(url: String) {
        let urlLower = url.lowercased()

        // Check if this URL is an AI site
        guard Self.aiSites.contains(where: { urlLower.contains($0) }) else { return }

        // Don't re-copy for the same URL
        guard url != lastCopiedForAIURL else { return }

        // Don't copy more than once per 5 minutes (avoid spamming on tab switches)
        guard Date().timeIntervalSince(lastAICopyDate) > 300 else { return }

        lastCopiedForAIURL = url
        lastAICopyDate = Date()

        // Read files off main thread, then copy on main thread
        Task.detached { [weak self] in
            let text: String
            if let fullContent = MullDirectory.read("full.md"), fullContent.count > 50 {
                text = fullContent
            } else {
                let parts = ["me.md", "now.md"].compactMap { MullDirectory.read($0) }
                    .filter { !$0.isEmpty }
                text = parts.isEmpty ? "" : parts.joined(separator: "\n\n")
            }

            guard !text.isEmpty else { return }

            // me/now/full are curated files — strip the Curator provenance markers
            // before this lands on the clipboard. They're internal metadata and
            // would be pure noise pasted into an AI chat.
            let clean = ContextBlockFile.stripMarkers(text)
            let maxChars = UserDefaults.standard.integer(forKey: "outputMaxChars")
            let finalText = (maxChars > 0 && clean.count > maxChars) ? String(clean.prefix(maxChars)) : clean

            // Re-capture weakly here rather than reading the outer closure's `self`
            // binding from a second concurrent closure (a Swift 6 error).
            await MainActor.run { [weak self] in
                let pasteboard = NSPasteboard.general
                let savedItems = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
                    guard let type = item.types.first,
                          let data = item.data(forType: type) else { return nil }
                    return (type.rawValue, data)
                } ?? []

                pasteboard.clearContents()
                pasteboard.setString(finalText, forType: .string)

                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    if !savedItems.isEmpty {
                        pasteboard.clearContents()
                        for (typeStr, data) in savedItems {
                            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(typeStr))
                        }
                    }
                }

                self?.sendNotification(
                    id: "ai-context-ready",
                    title: "Context ready",
                    body: "Paste with \u{2318}V — clipboard restores in 30s.",
                    action: nil
                )
            }
        }
    }

    // MARK: - 2. Morning Briefing

    private func sendMorningBriefing() {
        let db = database
        let cal = calendar
        Task.detached { [weak self] in
            // Heavy DB work off main thread
            let engine = TimeBlockEngine(database: db)
            let cache = engine.projectSnapshots(days: 14)
            // Only push observations, never interpretations/judgments (PRODUCT.md "Epistemics").
            let patterns = BehaviorPatternEngine(database: db).detectPatterns()
                .filter { $0.autoSurfaceable }
            let upcoming = cal.upcomingEvents(limit: 1)

            await MainActor.run { [weak self] in
                self?.projectCache = cache
                self?.projectCacheDate = Date()

                var title = "Good morning"
                var lines: [String] = []
                var action: NotificationAction?

                if let topPattern = patterns.first {
                    title = topPattern.title
                    lines.append(topPattern.insight)
                    lines.append(topPattern.action)

                    if let project = topPattern.project {
                        let matchingProject = cache.first { $0.name == project }
                        if let proj = matchingProject {
                            action = .openApp(proj.primaryApp)
                        }
                    }
                } else {
                    let stalled = cache.filter { $0.daysSinceActive >= 3 }
                    if let top = stalled.first {
                        title = "\(top.name) is waiting"
                        lines.append("\(top.name): \(top.daysSinceActive) days stalled")
                        action = .openApp(top.primaryApp)
                    }
                }

                if let next = upcoming.first {
                    let hours = next.minutesUntil / 60
                    let mins = next.minutesUntil % 60
                    let timeStr = hours > 0 ? "\(hours)h\(mins > 0 ? " \(mins)m" : "")" : "\(mins)m"
                    lines.append("Next: \(next.title) in \(timeStr)")
                } else if lines.isEmpty {
                    lines.append("No meetings. Full focus today.")
                }

                self?.sendNotification(
                    id: "morning-briefing",
                    title: title,
                    body: lines.joined(separator: "\n"),
                    action: action
                )
            }
        }
    }

    // MARK: - 3. Project Resumption

    private func checkProjectResumption(app: String, window: String) {
        guard !window.isEmpty else { return }
        refreshProjectCacheIfNeeded()

        let windowLower = window.lowercased()
        let appLower = app.lowercased()

        // Find matching stalled project (lightweight, uses cache)
        var matchedProject: ProjectSnapshot?
        for project in projectCache {
            guard project.daysSinceActive >= 3 else { continue }
            guard !notifiedProjects.contains(project.name) else { continue }

            let nameMatch = windowLower.contains(project.name.lowercased())
            let fileMatch = project.lastFile.map { windowLower.contains($0.lowercased()) } ?? false
            let appMatch = appLower == project.primaryApp.lowercased()

            if nameMatch || (appMatch && fileMatch) {
                matchedProject = project
                break
            }
        }

        guard let project = matchedProject else { return }
        // ProactiveLoop fires on the same project switch from the same 3s tick.
        // Whichever system claims the project first speaks; the other stays quiet.
        guard Notifier.shared.claimProjectAnnouncement(project.name) else { return }
        notifiedProjects.insert(project.name)

        // Heavy pattern detection off main thread
        let db = database
        let projectName = project.name
        let projectApp = project.primaryApp
        let daysSince = project.daysSinceActive
        let lastFile = project.lastFile
        let lastClip = project.lastClipboard

        Task.detached { [weak self] in
            // Only surface observations proactively, never judgments (PRODUCT.md "Epistemics").
            let patterns = BehaviorPatternEngine(database: db).detectPatterns()
                .filter { $0.autoSurfaceable }
            let projectPattern = patterns.first { $0.project == projectName }

            // `let`, not a mutated `var` — a captured var read from the nested
            // concurrent closure is a Swift 6 error.
            let body: String
            if let pattern = projectPattern {
                body = pattern.insight + "\n" + pattern.action
            } else {
                var lines = "\(daysSince) days since last session"
                if let file = lastFile { lines += "\nLast file: \(file)" }
                if let clip = lastClip { lines += "\nLast copied: \(clip)" }
                body = lines
            }

            await MainActor.run { [weak self] in
                self?.sendNotification(
                    id: "project-resume-\(projectName)",
                    title: "Welcome back to \(projectName)",
                    body: body,
                    action: .openApp(projectApp)
                )
            }
        }
    }

    // MARK: - 3.5. Knowledge Surfacing

    /// When the user opens a file/project, surface related knowledge they've accumulated.
    /// "You solved a similar problem before" — delivered before they even ask.
    private func surfaceRelevantKnowledge(window: String) {
        guard !window.isEmpty else { return }

        // A DB query on EVERY window-title change — that's a keystroke-rate trigger
        // in an editor. Off the main thread, like the other proactive lookups.
        let db = database
        Task.detached { [weak self] in
            let relevant = db.findRelevantKnowledge(context: window, limit: 1)
            guard let entry = relevant.first else { return }

            // Only surface if knowledge is from a different day (not what they just did)
            let daysSince = Calendar.current.dateComponents([.day], from: entry.sourceDate, to: Date()).day ?? 0
            guard daysSince >= 1 else { return }

            var body = entry.decision
            if let reasoning = entry.reasoning, !reasoning.isEmpty {
                body += "\nWhy: \(reasoning)"
            }

            await MainActor.run {
                guard let self else { return }
                // Don't re-notify same topic (checked on the main actor, where the
                // set lives — the fetch above is concurrent).
                guard !self.notifiedKnowledge.contains(entry.topic) else { return }
                self.notifiedKnowledge.insert(entry.topic)

                self.sendNotification(
                    id: "knowledge-\(entry.id ?? 0)-\(entry.topic.prefix(20))",
                    title: "You know this: \(entry.topic)",
                    body: body,
                    action: nil
                )
            }
        }
    }

    // MARK: - 4. Pre-Meeting

    private func checkUpcomingMeetings() {
        refreshUpcomingCacheIfNeeded()

        let now = Date()
        for event in upcomingCache {
            // Recomputed from `start`, not read from the cache — the cached value
            // would be up to a minute stale and could skip the 13–15 min window.
            let minutesUntil = Int(event.start.timeIntervalSince(now) / 60)
            guard minutesUntil <= 15 && minutesUntil >= 13 else { continue }

            let key = "\(event.title)-\(event.start.timeIntervalSince1970)"
            guard !notifiedMeetings.contains(key) else { continue }
            notifiedMeetings.insert(key)

            guard let twoHoursAgo = Calendar.current.date(byAdding: .hour, value: -2, to: now) else { continue }

            // The 2-hour fetch + grouping is a DB read; keep it off the main thread
            // (same precedent as the BehaviorPatternEngine hops above).
            let db = database
            let title = event.title
            Task.detached { [weak self] in
                let recentEvents = db.fetchEvents(from: twoHoursAgo, to: Date())
                let appCounts = Dictionary(grouping: recentEvents.filter { $0.eventType == .appSwitch }) { $0.appName ?? "Unknown" }
                let topApp = appCounts.max(by: { $0.value.count < $1.value.count })?.key

                // `let`, not a mutated `var` — see checkProjectResumption.
                let body = topApp.map { "\(title) in \(minutesUntil) minutes\nCurrent session: \($0)" }
                    ?? "\(title) in \(minutesUntil) minutes"

                await MainActor.run { [weak self] in
                    self?.sendNotification(id: "meeting-\(key)", title: "Meeting soon",
                                           body: body, action: nil)
                }
            }
        }
    }

    /// Refresh the EventKit query at most once a minute, off the main thread.
    private func refreshUpcomingCacheIfNeeded() {
        guard !upcomingRefreshing, Date().timeIntervalSince(upcomingCacheDate) > 60 else { return }
        upcomingRefreshing = true
        upcomingCacheDate = Date()

        let cal = calendar
        Task.detached { [weak self] in
            let events = cal.upcomingEvents(limit: 3).map { (title: $0.title, start: $0.start) }
            await MainActor.run {
                self?.upcomingCache = events
                self?.upcomingRefreshing = false
            }
        }
    }

    // MARK: - Project Cache

    /// `projectSnapshots(days: 14)` is a 14-day scan. Hourly is fine, but it must
    /// not run ON the main thread — it was being invoked straight from the 3s tick's
    /// window-title branch.
    private func refreshProjectCacheIfNeeded() {
        guard !projectCacheRefreshing, Date().timeIntervalSince(projectCacheDate) > 3600 else { return }
        projectCacheRefreshing = true
        projectCacheDate = Date()

        let db = database
        Task.detached { [weak self] in
            let snapshots = TimeBlockEngine(database: db).projectSnapshots(days: 14)
            await MainActor.run {
                self?.projectCache = snapshots
                self?.projectCacheRefreshing = false
            }
        }
    }

    // MARK: - Notification Actions

    enum NotificationAction {
        case openApp(String)       // Open an app by name (e.g. "Xcode")
        case openDashboard         // Open mull dashboard
    }

    // MARK: - Notification Delivery

    /// All delivery goes through the shared Notifier, so this engine and
    /// ProactiveLoop share one rate limit instead of two independent ones.
    private func sendNotification(id: String, title: String, body: String, action: NotificationAction?) {
        // Register the action BEFORE delivery — the tap handler looks it up by id.
        if let action { pendingActions[id] = action }

        let delivered = Notifier.shared.send(
            id: id, title: title, body: body,
            userInfo: action != nil ? ["actionID": id] : [:])

        // Rate-limited away: drop the action so `pendingActions` doesn't accumulate
        // entries for banners the user never got.
        if !delivered { pendingActions.removeValue(forKey: id) }
    }

    // MARK: - Notification Delegate Setup

    private func setupNotificationDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Execute the action associated with a notification.
    private func executeAction(for id: String) {
        guard let action = pendingActions.removeValue(forKey: id) else { return }

        switch action {
        case .openApp(let appName):
            // Launch the app by name
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID(for: appName)) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            } else {
                // Fallback when the bundle-id guess misses. `launchApplication(_:)`
                // is deprecated and has no by-name replacement, so resolve the
                // bundle path ourselves and use the modern URL-based API.
                let candidates = ["/Applications", "/System/Applications",
                                  NSHomeDirectory() + "/Applications"]
                    .map { URL(fileURLWithPath: $0).appendingPathComponent("\(appName).app") }
                if let bundle = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    NSWorkspace.shared.openApplication(at: bundle, configuration: .init())
                }
            }

        case .openDashboard:
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.title == "mull" }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Map common app names to bundle IDs.
    private func bundleID(for appName: String) -> String {
        switch appName {
        case "Xcode": return "com.apple.dt.Xcode"
        case "Code", "Visual Studio Code": return "com.microsoft.VSCode"
        case "Cursor": return "com.todesktop.230313mzl4w4u92"
        case "Safari": return "com.apple.Safari"
        case "Chrome", "Google Chrome": return "com.google.Chrome"
        case "Firefox": return "org.mozilla.firefox"
        case "Arc": return "company.thebrowser.Browser"
        case "Terminal": return "com.apple.Terminal"
        case "Simulator": return "com.apple.iphonesimulator"
        case "Figma": return "com.figma.Desktop"
        default: return "com.apple.\(appName.lowercased())"
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension ProactiveEngine: UNUserNotificationCenterDelegate {

    /// Handle notification tap — execute the associated action.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["actionID"] as? String

        Task { @MainActor in
            if let id {
                self.executeAction(for: id)
            }
            completionHandler()
        }
    }

    /// Show notifications even when app is in foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
