import Foundation

/// Transforms raw data into narrative — like a fortune teller framing facts as stories.
///
/// Same data, different framing:
///   Data:      "Code: 47%, Xcode: 22%, Firefox: 12%"
///   Narrative: "Today was a deep coding day. You spent most of your time
///              building, with minimal context-switching."
///
/// All rule-based. No LLM needed.
struct NarrativeEngine {

    let analysis: DailyActivity
    let analytics: AnalyticsEngine
    let database: DatabaseService

    /// Generate a full narrative for the day.
    func generateNarrative() -> String {
        var parts: [String] = []

        // Opening line — the "fortune teller" hook
        parts.append(openingLine())

        // Main story — what you spent time on, told as a story
        let mainStory = mainActivityStory()
        if !mainStory.isEmpty {
            parts.append("")
            parts.append(mainStory)
        }

        // What you were working with (clipboard insights)
        let clipInsight = clipboardInsight()
        if !clipInsight.isEmpty {
            parts.append("")
            parts.append(clipInsight)
        }

        // Pattern observation — compared to your usual behavior
        let pattern = patternObservation()
        if !pattern.isEmpty {
            parts.append("")
            parts.append(pattern)
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Opening Line

    /// One sentence that captures the day's character.
    private func openingLine() -> String {
        guard !analysis.mainActivities.isEmpty else {
            return "A quiet day — not much activity recorded yet."
        }

        let totalMinutes = Int(analysis.totalDuration / 60)
        let mainApp = analysis.mainActivities.first?.app ?? ""
        let mainLabel = analysis.mainActivities.first?.label ?? ""
        let activityCount = analysis.mainActivities.count + analysis.otherActivities.count

        // Single-focus day
        if analysis.mainActivities.count == 1 {
            let pct = analysis.appBreakdown.first?.percentage ?? 0
            if pct > 70 {
                return "A focused day — you spent most of your time on \(mainLabel)."
            }
            return "Today centered around \(mainLabel) (\(analysis.mainActivities.first?.durationFormatted ?? ""))."
        }

        // Multi-project day
        if analysis.mainActivities.count >= 3 {
            let names = analysis.mainActivities.prefix(3).map(\.label)
            return "A varied day — you moved between \(names.joined(separator: ", "))."
        }

        // Two-focus day
        if analysis.mainActivities.count == 2 {
            let a = analysis.mainActivities[0]
            let b = analysis.mainActivities[1]
            if a.totalDuration > b.totalDuration * 2 {
                return "Mostly \(a.label) today, with some time on \(b.label)."
            }
            return "Split between \(a.label) and \(b.label) today."
        }

        return "You worked for about \(totalMinutes / 60)h \(totalMinutes % 60)m today."
    }

    // MARK: - Main Activity Story

    /// Turn activities into sentences, not bullet points.
    private func mainActivityStory() -> String {
        guard !analysis.mainActivities.isEmpty else { return "" }

        var sentences: [String] = []

        for activity in analysis.mainActivities {
            let duration = activity.durationFormatted
            let label = activity.label
            let app = activity.app

            // Frame the activity based on the app type
            if isCodeEditor(app) {
                if label.contains("swift") || label.contains("Swift") {
                    sentences.append("You coded in \(label) for \(duration).")
                } else {
                    sentences.append("You worked on \(label) for \(duration) in \(app).")
                }
            } else if isBrowser(app) {
                sentences.append("You spent \(duration) browsing — \(label).")
            } else if isCommApp(app) {
                sentences.append("Communication: \(duration) in \(app).")
            } else {
                sentences.append("\(label) — \(duration) in \(app).")
            }
        }

        // Other activities as a brief mention
        if !analysis.otherActivities.isEmpty {
            let others = analysis.otherActivities
                .prefix(3)
                .map { "\($0.label) (\($0.durationFormatted))" }
                .joined(separator: ", ")
            sentences.append("Also: \(others).")
        }

        return sentences.joined(separator: " ")
    }

    // MARK: - Clipboard Insight

    /// What the clipboard reveals about current work.
    private func clipboardInsight() -> String {
        let since = Calendar.current.startOfDay(for: Date())
        let clips = database.fetchEvents(from: since, to: Date())
            .filter { $0.eventType == .clipboard }
            .filter { e in
                guard let app = e.appName, !AnalyticsEngine.noiseApps.contains(app) else { return false }
                guard let text = e.textContent, text.count > 10, text.count < 200 else { return false }
                return true
            }
            .compactMap(\.textContent)

        guard !clips.isEmpty else { return "" }

        // Deduplicate
        var seen = Set<String>()
        var unique: [String] = []
        for clip in clips {
            let key = String(clip.prefix(50).lowercased())
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(String(clip.prefix(80)).replacingOccurrences(of: "\n", with: " "))
        }

        if unique.count == 1 {
            return "You were working with: \"\(unique[0])\""
        }

        if unique.count <= 3 {
            let items = unique.map { "\"\($0)\"" }.joined(separator: ", ")
            return "Key things you worked with: \(items)"
        }

        let sample = unique.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ")
        return "You copied \(unique.count) things today, including: \(sample)"
    }

    // MARK: - Pattern Observation

    /// Compare today to the user's typical patterns.
    private func patternObservation() -> String {
        var observations: [String] = []

        // Compare app usage to weekly average
        let weeklyApps = analytics.appUsage(days: 7)
        let todayApps = analytics.appUsage(days: 1)

        if let todayTop = todayApps.first, let weeklyTop = weeklyApps.first {
            if todayTop.appName == weeklyTop.appName {
                observations.append("\(todayTop.appName) continues to be your most-used tool.")
            } else {
                observations.append("Today \(todayTop.appName) was your top tool — usually it's \(weeklyTop.appName).")
            }
        }

        // Peak hour observation
        let todayHourly = analytics.hourlyPattern(days: 1)
        let peak = todayHourly.max(by: { $0.eventCount < $1.eventCount })
        if let p = peak, p.eventCount > 0 {
            let hour = p.hour
            if hour < 10 {
                observations.append("Your most active hour was \(hour):00 — early start today.")
            } else if hour >= 20 {
                observations.append("Your most active hour was \(hour):00 — a late session.")
            }
        }

        // Activity count comparison
        let todayCount = analysis.mainActivities.count + analysis.otherActivities.count
        if todayCount >= 5 {
            observations.append("High context-switching today — \(todayCount) different tasks.")
        } else if todayCount == 1 {
            observations.append("Deep focus today — single task, no context-switching.")
        }

        return observations.joined(separator: " ")
    }

    // MARK: - Helpers

    private func isCodeEditor(_ app: String) -> Bool {
        ["Xcode", "Code", "Visual Studio Code", "Cursor", "Zed", "IntelliJ IDEA", "Android Studio"].contains(app)
    }

    private func isBrowser(_ app: String) -> Bool {
        ["Safari", "Firefox", "Chrome", "Google Chrome", "Arc", "Brave", "Edge"].contains(app)
    }

    private func isCommApp(_ app: String) -> Bool {
        ["Slack", "Discord", "Teams", "Zoom", "Messages", "Mail"].contains(app)
    }
}
