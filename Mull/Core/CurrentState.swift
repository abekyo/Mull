import Foundation

/// The "now" anchor for the selection layer (SELECTION-LAYER.md §2).
///
/// For personal, proactive context, *what you're doing right now* is the single
/// strongest relevance signal — so retrieval is conditioned on this rather than
/// on a query string alone. Built purely from recent recorded events (the
/// recorder logs the active window title every ~5s), so it needs no Accessibility
/// access and is unit-testable. Self-contained on purpose: it must outlive the
/// rule-based analytics engines that are being removed.
struct CurrentState {
    var activeApp: String?
    var activeTitle: String?
    var activeEntity: String?
    var recentActions: [String]
    var sessionStart: Date?

    /// Assemble the anchor from the last `window` seconds of events.
    static func current(database: DatabaseService, now: Date = Date(), window: TimeInterval = 1200) -> CurrentState {
        let events = database.fetchEvents(from: now.addingTimeInterval(-window), to: now)
            .filter { event in
                guard let app = event.appName else { return true }
                return !AnalyticsEngine.isNoiseApp(app)
            }
        guard !events.isEmpty else {
            return CurrentState(activeApp: nil, activeTitle: nil, activeEntity: nil,
                                recentActions: [], sessionStart: nil)
        }

        let activeApp = events.last(where: { $0.appName != nil })?.appName
        let activeTitle = events.last { $0.eventType == .screenText }
            .flatMap(meaningfulText)
        let activeEntity = entity(from: activeTitle)

        return CurrentState(
            activeApp: activeApp,
            activeTitle: activeTitle,
            activeEntity: activeEntity,
            recentActions: recentActions(from: events),
            sessionStart: sessionStart(from: events)
        )
    }

    /// One-line text form for an MCP `whats_active_now` response.
    func summary() -> String {
        var lines: [String] = []
        if let entity = activeEntity { lines.append("Active: \(entity)") }
        else if let title = activeTitle { lines.append("Active: \(title)") }
        if let app = activeApp { lines.append("App: \(app)") }
        if !recentActions.isEmpty {
            lines.append("Recently:")
            lines.append(contentsOf: recentActions.map { "- \($0)" })
        }
        return lines.isEmpty ? "(no recent activity)" : lines.joined(separator: "\n")
    }

    // MARK: - Derivation (cheap, rule-based — structure, not summarization)

    /// The most recent meaningful signals (self-authored notes, copied text,
    /// window titles), newest-first, deduped. Keystroke fragments and app
    /// switches are excluded as low-salience.
    private static func recentActions(from events: [RecordingEvent], limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for event in events.reversed() where event.eventType == .clipboard || event.eventType == .screenText {
            guard let text = meaningfulText(event) else { continue }
            let key = String(text.prefix(40)).lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let app = event.appName.map { "[\($0)] " } ?? ""
            out.append(app + String(text.prefix(80)))
            if out.count >= limit { break }
        }
        return out
    }

    /// Start of the contiguous run ending at the latest event (gaps < 5 min →
    /// same session).
    private static func sessionStart(from events: [RecordingEvent]) -> Date? {
        guard let last = events.last else { return nil }
        var start = last.timestamp
        var prev = last.timestamp
        for event in events.reversed() {
            if prev.timeIntervalSince(event.timestamp) > 300 { break }
            start = event.timestamp
            prev = event.timestamp
        }
        return start
    }

    /// Non-noise, non-test, non-sensitive text content of an event, or nil.
    private static func meaningfulText(_ event: RecordingEvent) -> String? {
        guard let text = event.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count >= 2,
              !TestInput.isLikelyTestInput(text),
              !SensitiveText.isSensitive(text) else { return nil } // never surface secrets
        return text
    }

    // The noise list lives in AnalyticsEngine and is matched case-insensitively
    // (`localizedName` is "Mull", "System Settings" — a case-sensitive lookup
    // silently matched nothing). A second private copy here drifted from it and
    // had the same bug, so this now defers to the one definition.

    /// Best-effort project/entity from a window title. Thin wrapper over the
    /// shared `Entity` extractor (kept for call sites and tests).
    static func entity(from title: String?) -> String? { Entity.from(title) }
}
