import Foundation
import AppKit
@preconcurrency import UserNotifications

/// The one notification path for the whole app.
///
/// There used to be three independent `UNMutableNotificationContent` builders
/// (AppState, ProactiveEngine, ProactiveLoop), each with its own throttle and no
/// knowledge of the others — and ProactiveEngine and ProactiveLoop both fired on a
/// project switch from the SAME 3-second tick, so one app switch could produce two
/// banners saying nearly the same thing. ProactiveLoop is now the only project-switch
/// path, but the sources that remain (meetings, clipboard hand-off) still
/// fire independently, so routing everything through here keeps one rate limit for
/// the app instead of one per subsystem.
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

    /// Whether macOS is currently refusing to show mull's notifications, as last
    /// observed. `nil` until the first answer comes back.
    ///
    /// This exists because `send` used to return `true` the instant it had asked
    /// for authorization — before the answer arrived — so every caller believed
    /// a banner had gone out. For someone who had said no to notifications, a
    /// meeting reminder was marked "already reminded" and never retried, and the
    /// "Summary failed" alert was posted into nothing.
    private(set) var deliveryBlocked: Bool?

    /// Deliver a notification unless another one just went out. Returns whether it
    /// was actually enqueued, so callers can avoid marking state as "notified" for
    /// something the user never saw.
    ///
    /// Authorization resolves asynchronously, so "enqueued" cannot always be known
    /// by the time this returns: when the answer is already in and it was no, the
    /// refusal is immediate; when it isn't, `onUndelivered` fires afterwards so the
    /// caller can undo whatever it marked. Callers that keep "already notified"
    /// state must handle both.
    @discardableResult
    func send(id: String, title: String, body: String,
              userInfo: [String: Any] = [:],
              onUndelivered: (() -> Void)? = nil) -> Bool {
        // A known refusal is not worth a rate-limit slot: burning the floor on a
        // banner nobody can receive would suppress the next one that might.
        if deliveryBlocked == true {
            onUndelivered?()
            return false
        }
        guard Date().timeIntervalSince(lastSentAt) >= globalFloor else { return false }
        let previousSendAt = lastSentAt
        lastSentAt = Date()

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            let fail: () -> Void = {
                Task { @MainActor in
                    self.deliveryBlocked = true
                    // Give the slot back — nothing was shown in it.
                    self.lastSentAt = previousSendAt
                    onUndelivered?()
                }
            }
            guard granted else { return fail() }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if !userInfo.isEmpty { content.userInfo = userInfo }

            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                if error != nil { return fail() }
                Task { @MainActor in self.deliveryBlocked = false }
            }
        }
        return true
    }

    /// Re-read the system's answer without prompting, so a Settings row can say
    /// whether notifications are actually getting through.
    func refreshDeliveryState(then report: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let blocked = settings.authorizationStatus == .denied
            Task { @MainActor in
                self.deliveryBlocked = blocked
                report?(blocked)
            }
        }
    }

    /// Claim the right to announce a return to `project`. A project announced inside
    /// the cooldown is not announced again, so hopping away and back — or a second
    /// caller appearing later — cannot re-brief the same project. An hour: the brief
    /// exists for a genuine resumption, and within an hour you still remember what
    /// you were doing.
    func claimProjectAnnouncement(_ project: String, cooldown: TimeInterval = 3600) -> Bool {
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
/// Two interventions, each triggered by existing data:
///
///   1. AI auto-copy — user opens claude.ai or chatgpt.com → context copied to clipboard
///   2. Pre-meeting — 15 minutes before a calendar event → notification
///
/// The morning briefing was removed (2026-08): its content was either a
/// productivity lecture ("Block 2 hours right now"), a stalled-project nag built
/// inline — bypassing the `autoSurfaceable` epistemic filter it was supposed to
/// pass through — or an empty banner ("No meetings. Full focus today."). All
/// three hurry the reader on their own behalf, which mull does not do. If a morning orientation
/// earns a place, it belongs in Home when the user opens it, not in a banner.
///
/// Project resumption used to be a fourth intervention here, keyed off a raw
/// window-title diff against a 14-day `projectSnapshots` cache. ProactiveLoop now
/// owns that case entirely — it anchors on `CurrentState.activeEntity` and ranks
/// with the selection layer (SELECTION-LAYER.md) instead of substring
/// matching, and both fired from this same 3-second tick. What is left here is the
/// set of interventions ProactiveLoop does not cover: clipboard hand-off, the
/// once-a-day briefing, and calendar proximity.
///
/// No polling. No new observers. Runs inside AppState's existing 3-second refresh loop.
@MainActor
final class ProactiveEngine: NSObject {

    private let database: EventReading
    private let calendar: CalendarService
    private let analytics: AnalyticsEngine

    // State tracking to avoid duplicate triggers
    private var lastDailyResetDate: Date = .distantPast
    private var notifiedMeetings: Set<String> = []

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

    init(database: EventReading, calendar: CalendarService, analytics: AnalyticsEngine) {
        self.database = database
        self.calendar = calendar
        self.analytics = analytics
        super.init()
        setupNotificationDelegate()
    }

    /// Called every 3 seconds from AppState.refreshStats().
    ///
    /// `todayEventCount`, `currentApp` and `currentWindow` are no longer read: the
    /// count only gated the removed morning briefing, and the window pair fed the
    /// project-resumption diff, now owned by ProactiveLoop. They stay in the
    /// signature so AppState's call site is untouched, and because the eventual
    /// window-anchored interventions belong here rather than in the loop.
    func tick(todayEventCount: Int, currentApp: String?, currentWindow: String?, browserURL: String?) {
        let today = Calendar.current.startOfDay(for: Date())

        // Reset daily state at midnight
        if today != Calendar.current.startOfDay(for: lastDailyResetDate) {
            notifiedMeetings.removeAll()
            lastCopiedForAIURL = ""
            lastAICopyDate = .distantPast
            lastDailyResetDate = today
        }

        // 1. AI auto-copy — highest priority, zero friction
        if let url = browserURL {
            checkAISiteAndCopy(url: url)
        }

        // 2. Pre-meeting
        checkUpcomingMeetings()
    }

    // MARK: - 1. AI Auto-Copy

    private func checkAISiteAndCopy(url: String) {
        // Settings › General › Notifications. Absent key means on; the toggle
        // kills the whole feature, not just the banner — copying without the
        // banner would replace the clipboard with nothing anywhere saying so.
        guard UserDefaults.standard.object(forKey: "aiAutoCopy") as? Bool ?? true else { return }

        let urlLower = url.lowercased()

        // Check if this URL is an AI site
        guard Self.aiSites.contains(where: { urlLower.contains($0) }) else { return }

        // Don't re-copy for the same URL
        guard url != lastCopiedForAIURL else { return }

        // Once per half hour at most. Every new conversation on claude.ai/chatgpt is
        // a new URL, so at the old 5-minute floor a heavy AI user got a banner (and a
        // clobbered clipboard) up to 12 times an hour. One hand-off per sitting is
        // the feature; the rest was noise.
        guard Date().timeIntervalSince(lastAICopyDate) > 1800 else { return }

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

    // MARK: - 2. Pre-Meeting

    private func checkUpcomingMeetings() {
        // Settings › General › Notifications. Absent key means on. Checked
        // before the cache refresh so a disabled reminder also stops the
        // once-a-minute EventKit query it exists to feed.
        guard UserDefaults.standard.object(forKey: "meetingReminders") as? Bool ?? true else { return }

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

            // The 2-hour fetch + grouping is a DB read; keep it off the main thread.
            let db = database
            let title = event.title
            Task.detached { [weak self] in
                let recentEvents = db.fetchEvents(from: twoHoursAgo, to: Date())
                let appCounts = Dictionary(grouping: recentEvents.filter { $0.eventType == .appSwitch }) { $0.appName ?? "Unknown" }
                let topApp = appCounts.max(by: { $0.value.count < $1.value.count })?.key

                // `let`, not a mutated `var` — a captured var read from the nested
                // concurrent closure is a Swift 6 error.
                let body = topApp.map { "\(title) in \(minutesUntil) minutes\nCurrent session: \($0)" }
                    ?? "\(title) in \(minutesUntil) minutes"

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Un-mark on either failure path — rate-limited away now, or
                    // refused by macOS a moment later — so the next tick inside
                    // the 13–15 min window retries instead of losing the reminder.
                    let delivered = self.sendNotification(
                        id: "meeting-\(key)", title: "Meeting soon", body: body, action: nil,
                        onUndelivered: { [weak self] in self?.notifiedMeetings.remove(key) })
                    if !delivered { self.notifiedMeetings.remove(key) }
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

    // MARK: - Notification Actions

    enum NotificationAction {
        case openApp(String)       // Open an app by name (e.g. "Xcode")
        case openDashboard         // Open mull dashboard
    }

    // MARK: - Notification Delivery

    /// All delivery goes through the shared Notifier, so this engine and
    /// ProactiveLoop share one rate limit instead of two independent ones.
    /// Returns whether the banner was actually enqueued (see `Notifier.send`).
    @discardableResult
    private func sendNotification(id: String, title: String, body: String,
                                  action: NotificationAction?,
                                  onUndelivered: (() -> Void)? = nil) -> Bool {
        // Register the action BEFORE delivery — the tap handler looks it up by id.
        if let action { pendingActions[id] = action }

        let delivered = Notifier.shared.send(
            id: id, title: title, body: body,
            userInfo: action != nil ? ["actionID": id] : [:],
            // Authorization can refuse after this call has already returned true,
            // so the same cleanup has to be reachable from both paths.
            onUndelivered: { [weak self] in
                self?.pendingActions.removeValue(forKey: id)
                onUndelivered?()
            })

        // Rate-limited away: drop the action so `pendingActions` doesn't accumulate
        // entries for banners the user never got.
        if !delivered { pendingActions.removeValue(forKey: id) }
        return delivered
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
