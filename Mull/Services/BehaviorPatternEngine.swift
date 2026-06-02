import Foundation

/// Detects behavioral patterns that humans can't see about themselves.
///
/// Not analytics (what happened). Not knowledge (what was learned).
/// Patterns = "you always do X when Y happens" — self-awareness from data.
///
/// All rule-based. No LLM needed. The patterns are in the data, not in language.
struct BehaviorPatternEngine {

    let database: DatabaseService

    /// Run all pattern detectors and return actionable insights.
    func detectPatterns() -> [BehaviorPattern] {
        var patterns: [BehaviorPattern] = []

        patterns.append(contentsOf: detectProjectAbandonment())
        patterns.append(contentsOf: detectPeakHourWaste())
        patterns.append(contentsOf: detectFocusDecline())
        patterns.append(contentsOf: detectAvoidancePattern())
        patterns.append(contentsOf: detectContextSwitchCorrelation())

        // Sort by severity
        return patterns.sorted { $0.severity > $1.severity }
    }

    // MARK: - 1. Project Abandonment Pattern

    /// "Every time you pause a project for 3+ days, you never come back."
    /// Looks at all projects from the last 60 days and checks which ones died after a gap.
    private func detectProjectAbandonment() -> [BehaviorPattern] {
        let engine = TimeBlockEngine(database: database)
        let projects = engine.projectSnapshots(days: 60)

        // Find projects that had activity, then stopped
        var abandonedCount = 0
        var resumedCount = 0

        for project in projects {
            let sessions = project.sessions.sorted { $0.date < $1.date }
            guard sessions.count >= 2 else { continue }

            for i in 0..<(sessions.count - 1) {
                let gap = Calendar.current.dateComponents([.day], from: sessions[i].date, to: sessions[i + 1].date).day ?? 0
                if gap >= 3 {
                    if i + 2 < sessions.count {
                        // There's activity after the gap — project was resumed
                        resumedCount += 1
                    } else if i + 1 == sessions.count - 1 {
                        // Gap led to the final session — check if it went stale after
                        guard let lastDate = sessions.last?.date else { continue }
                        let daysSinceLast = Calendar.current.dateComponents([.day], from: lastDate, to: Date()).day ?? 0
                        if daysSinceLast >= 5 {
                            abandonedCount += 1
                        }
                    }
                }
            }
        }

        // Find currently stalled projects
        let stalledProjects = projects.filter { $0.daysSinceActive >= 3 && $0.daysSinceActive < 30 }
        let totalGaps = abandonedCount + resumedCount

        guard totalGaps >= 2, !stalledProjects.isEmpty else { return [] }

        let abandonRate = totalGaps > 0 ? Double(abandonedCount) / Double(totalGaps) * 100 : 0

        if abandonRate >= 50 {
            return stalledProjects.prefix(2).map { project in
                BehaviorPattern(
                    type: .abandonment,
                    title: "\(project.name) — \(project.daysSinceActive) days quiet",
                    // Observation, not verdict: state the record, ask rather than judge.
                    insight: "No activity on \(project.name) for \(project.daysSinceActive) days. Across the last 60 days, paused projects resumed \(100 - Int(abandonRate))% of the time.",
                    action: "Still want to continue \(project.name)?",
                    evidence: "\(abandonedCount) stayed paused vs \(resumedCount) resumed after a 3+ day gap (last 60 days)",
                    severity: project.daysSinceActive >= 5 ? 1.0 : 0.8,
                    project: project.name,
                    // Inference about the future of the project, not a logged fact.
                    epistemicClass: .interpretation
                )
            }
        }

        return []
    }

    // MARK: - 2. Peak Hour Waste

    /// "Your most productive hours are 7-9am, but you spend them on email/browsing."
    private func detectPeakHourWaste() -> [BehaviorPattern] {
        let hourly = AnalyticsEngine(database: database).hourlyPattern(days: 30)

        // Find top 3 peak hours
        let peakHours = hourly.sorted { $0.eventCount > $1.eventCount }.prefix(3).map(\.hour)
        guard !peakHours.isEmpty else { return [] }

        // Check what apps are used during peak hours today
        let today = Calendar.current.startOfDay(for: Date())
        let events = database.fetchEvents(from: today, to: Date())

        var peakAppCounts: [String: Int] = [:]
        for event in events where event.eventType == .appSwitch {
            let hour = Calendar.current.component(.hour, from: event.timestamp)
            guard peakHours.contains(hour) else { continue }
            guard let app = event.appName else { continue }
            guard !AnalyticsEngine.noiseApps.contains(app) else { continue }
            peakAppCounts[app, default: 0] += 1
        }

        // Identify "shallow" apps used during peak hours
        let shallowApps = Set(["Mail", "Slack", "Discord", "Messages", "Safari", "Firefox",
                                "Chrome", "Google Chrome", "Arc", "Brave Browser",
                                "Notion", "Notes", "Reminders"])

        let shallowCount = peakAppCounts.filter { shallowApps.contains($0.key) }.values.reduce(0, +)
        let totalCount = max(peakAppCounts.values.reduce(0, +), 1)
        let shallowPercent = Double(shallowCount) / Double(totalCount) * 100

        guard shallowPercent > 30 else { return [] }

        let peakStr = peakHours.map { "\($0):00" }.joined(separator: ", ")
        let topShallow = peakAppCounts.filter { shallowApps.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(2)
            .map(\.key)
            .joined(separator: " and ")

        return [BehaviorPattern(
            type: .peakWaste,
            title: "Peak hours spent on shallow work",
            insight: "Your most productive hours are \(peakStr) (based on 30 days of data). Today, \(Int(shallowPercent))% of that time went to \(topShallow).",
            action: "Move \(topShallow) to after \(peakHours.last.map { "\($0 + 1):00" } ?? "noon"). Protect your peak hours for deep work.",
            evidence: "30-day pattern: peak hours at \(peakStr). Today: \(Int(shallowPercent))% shallow apps",
            severity: shallowPercent > 50 ? 0.9 : 0.6,
            project: nil
        )]
    }

    // MARK: - 3. Focus Decline

    /// "Your deep work blocks dropped from 5 last week to 1 this week."
    private func detectFocusDecline() -> [BehaviorPattern] {
        let engine = TimeBlockEngine(database: database)
        let comp = engine.weekComparison()

        // Deep work decline
        if comp.lastWeekDeepBlocks >= 3 && comp.thisWeekDeepBlocks <= 1 {
            let drop = comp.lastWeekDeepBlocks - comp.thisWeekDeepBlocks
            return [BehaviorPattern(
                type: .focusDecline,
                title: "Deep work is disappearing",
                insight: "Last week you had \(comp.lastWeekDeepBlocks) deep work blocks (2h+ uninterrupted). This week: \(comp.thisWeekDeepBlocks). That's a \(drop)-block drop.",
                action: "Block 2 hours on your calendar right now. No meetings, no Slack. One project.",
                evidence: "Last week: \(comp.lastWeekDeepBlocks) blocks >= 2h. This week: \(comp.thisWeekDeepBlocks)",
                severity: 0.85,
                project: nil
            )]
        }

        // Context switch increase
        if comp.lastWeekContextSwitches > 0 {
            let increase = Double(comp.thisWeekContextSwitches - comp.lastWeekContextSwitches) / Double(comp.lastWeekContextSwitches) * 100
            if increase > 50 {
                return [BehaviorPattern(
                    type: .focusDecline,
                    title: "Attention is fragmenting",
                    insight: "Context switches up \(Int(increase))% vs last week (\(comp.thisWeekContextSwitches) vs \(comp.lastWeekContextSwitches)). You're touching more things but finishing less.",
                    action: "Pick one project. Work on it until lunch. Everything else waits.",
                    evidence: "App switches: \(comp.thisWeekContextSwitches) this week vs \(comp.lastWeekContextSwitches) last week",
                    severity: 0.7,
                    project: nil
                )]
            }
        }

        return []
    }

    // MARK: - 4. Avoidance Pattern

    /// "You opened PantryApp 3 times this week but closed it within 5 minutes each time."
    private func detectAvoidancePattern() -> [BehaviorPattern] {
        let engine = TimeBlockEngine(database: database)
        let projects = engine.projectSnapshots(days: 14)

        var patterns: [BehaviorPattern] = []

        for project in projects {
            let recentSessions = project.sessions.filter {
                let days = Calendar.current.dateComponents([.day], from: $0.date, to: Date()).day ?? 0
                return days <= 7
            }

            // Check for many short sessions (< 10 minutes)
            let shortSessions = recentSessions.filter { $0.duration < 600 }
            let longSessions = recentSessions.filter { $0.duration >= 600 }

            if shortSessions.count >= 3 && longSessions.isEmpty {
                patterns.append(BehaviorPattern(
                    type: .avoidance,
                    title: "\(project.name): short sessions only",
                    // Observation of the log; "avoiding / circling" was a judgment — dropped.
                    insight: "You opened \(project.name) \(shortSessions.count) times in the last 7 days, each under 10 minutes, with no longer session.",
                    action: "Want to set aside 30 minutes for \(project.name)?",
                    evidence: "\(shortSessions.count) sessions under 10min, 0 sessions over 10min in the last 7 days",
                    severity: 0.75,
                    project: project.name,
                    // The fact is logged; calling it "avoidance" is the inference.
                    epistemicClass: .interpretation
                ))
            }
        }

        return patterns
    }

    // MARK: - 5. Context Switch Correlation

    /// "On days when you context-switch less, you ship 2x more."
    private func detectContextSwitchCorrelation() -> [BehaviorPattern] {
        let calendar = Calendar.current
        let engine = TimeBlockEngine(database: database)

        struct DayMetrics {
            let switches: Int
            let deepBlocks: Int
            let totalDuration: TimeInterval
        }

        var days: [DayMetrics] = []

        for offset in 0..<14 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let start = calendar.startOfDay(for: date)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }

            let events = database.fetchEvents(from: start, to: min(end, Date()))
            let switches = events.filter { $0.eventType == .appSwitch }.count
            guard switches > 0 else { continue }

            let blocks = engine.generateBlocks(for: date)
            let deepBlocks = blocks.filter { $0.duration >= 7200 }.count
            let totalDuration = blocks.reduce(0.0) { $0 + $1.duration }

            days.append(DayMetrics(switches: switches, deepBlocks: deepBlocks, totalDuration: totalDuration))
        }

        guard days.count >= 5 else { return [] }

        // Split days into low-switch and high-switch
        let sortedBySwitches = days.sorted { $0.switches < $1.switches }
        let half = sortedBySwitches.count / 2
        let lowSwitchDays = Array(sortedBySwitches.prefix(half))
        let highSwitchDays = Array(sortedBySwitches.suffix(half))

        let lowAvgDuration = lowSwitchDays.reduce(0.0) { $0 + $1.totalDuration } / Double(max(lowSwitchDays.count, 1))
        let highAvgDuration = highSwitchDays.reduce(0.0) { $0 + $1.totalDuration } / Double(max(highSwitchDays.count, 1))

        guard lowAvgDuration > 0 && highAvgDuration > 0 else { return [] }

        let ratio = lowAvgDuration / highAvgDuration

        if ratio >= 1.3 {
            let avgLowSwitches = lowSwitchDays.reduce(0) { $0 + $1.switches } / max(lowSwitchDays.count, 1)
            let avgHighSwitches = highSwitchDays.reduce(0) { $0 + $1.switches } / max(highSwitchDays.count, 1)
            let multiplier = String(format: "%.1f", ratio)

            return [BehaviorPattern(
                type: .correlation,
                title: "Less switching = more output",
                insight: "On days with fewer than \(avgLowSwitches) app switches, you produce \(multiplier)x more deep work than days with \(avgHighSwitches)+ switches.",
                action: "Today, try to stay under \(avgLowSwitches) switches. Close apps you don't need.",
                evidence: "14-day analysis: low-switch days avg \(Int(lowAvgDuration / 3600))h deep work, high-switch days avg \(Int(highAvgDuration / 3600))h",
                severity: 0.65,
                project: nil
            )]
        }

        return []
    }
}

// MARK: - Data Types

struct BehaviorPattern: Identifiable {
    let id = UUID()
    let type: PatternType
    let title: String       // Short label
    let insight: String     // What the data shows (the "mirror")
    let action: String      // What to do about it (the "lever")
    let evidence: String    // The raw data behind this insight
    let severity: Double    // 0.0 to 1.0 — how urgently this needs attention
    let project: String?    // Related project, if any
    var epistemicClass: EpistemicClass = .observation

    enum PatternType {
        case abandonment       // Project about to be abandoned
        case peakWaste         // Best hours spent on shallow work
        case focusDecline      // Deep work blocks dropping
        case avoidance         // Opening but not engaging
        case correlation       // Behavioral correlation discovered
    }

    /// How grounded the pattern is — drives whether mull may *push* it.
    ///
    /// PRODUCT.md "Epistemics": observations are facts in the log and are safe
    /// to surface directly. Interpretations are judgments with no ground truth
    /// (§3.6: users don't want to be judged) — they may appear in-app for the
    /// user to consider, but mull must NOT auto-notify them.
    enum EpistemicClass {
        case observation     // a verifiable fact about what happened
        case interpretation  // a judgment/inference about what it means
    }

    /// Only observations may be pushed as proactive notifications. Reversible by
    /// construction (a notification the user can ignore), and never a judgment.
    var autoSurfaceable: Bool { epistemicClass == .observation }
}
