import Foundation

/// Aggregates raw events into time blocks for calendar-style timeline.
/// Pure rule-based — no LLM needed.
///
/// Input: raw RecordingEvents
/// Output: "09:00-10:30 — Xcode: PantryApp (Storyboard refactor)"
///
/// Logic:
///   1. Group consecutive events by dominant app
///   2. Merge short gaps (< 3 min) into the surrounding block
///   3. Label each block from window titles + clipboard context
struct TimeBlockEngine {

    let database: EventReading

    /// How long a break can be before returning to the same work counts as a *new*
    /// piece of work. Seconds; `0` turns rejoining off and restores the pure
    /// elapsed-time segmentation described above.
    ///
    /// Read from `Preferences` at construction so both binaries and every surface
    /// agree; tests pass it explicitly so the suite cannot depend on the developer's
    /// own settings.
    let resumeGap: TimeInterval

    init(database: EventReading, resumeGap: TimeInterval = Preferences.resumeGap) {
        self.database = database
        self.resumeGap = resumeGap
    }

    /// Generate time blocks for a given day.
    func generateBlocks(for date: Date) -> [TimeBlock] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let events = database.fetchEvents(from: startOfDay, to: min(endOfDay, Date()))
            .filter { event in
                guard let app = event.appName else { return true }
                return !AnalyticsEngine.isNoiseApp(app)
            }
        guard !events.isEmpty else { return [] }

        // Step 1: Create raw segments (1 per event with app + time)
        var segments: [EventSegment] = []
        for event in events {
            segments.append(EventSegment(
                timestamp: event.timestamp,
                app: event.appName ?? "Unknown",
                windowTitle: event.windowTitle ?? event.textContent ?? "",
                eventType: event.eventType,
                text: event.textContent ?? ""
            ))
        }

        return BlockSegmenter.blocks(from: segments, resumeGap: resumeGap)
    }
}

// MARK: - Daily Summary (rule-based "what you mainly did")

struct DailyActivity {
    let mainActivities: [ActivitySummary]  // Top 3 by time
    let otherActivities: [ActivitySummary] // Everything else
    let totalDuration: TimeInterval
    let appBreakdown: [(app: String, duration: TimeInterval, percentage: Double)]

    /// Generate plain text for AI or UI.
    func asText() -> String {
        var lines: [String] = []

        lines.append(VaultText.t("What you mainly did today:", "今日おもにしたこと:"))
        for activity in mainActivities where !AnalyticsEngine.isNoiseApp(activity.app) {
            lines.append("- \(activity.label) (\(activity.durationFormatted), \(activity.app))")
        }

        let filteredOther = otherActivities.filter { !AnalyticsEngine.isNoiseApp($0.app) }
        if !filteredOther.isEmpty {
            lines.append("")
            lines.append(VaultText.t("Also:", "ほかに:"))
            for activity in filteredOther {
                lines.append("- \(activity.label) (\(activity.durationFormatted), \(activity.app))")
            }
        }

        lines.append("")
        lines.append(VaultText.t("App usage:", "アプリの使用:"))
        for (app, _, pct) in appBreakdown.prefix(6) {
            lines.append("- \(app): \(String(format: "%.0f", pct))%")
        }

        return lines.joined(separator: "\n")
    }
}

struct ActivitySummary: Identifiable {
    let id = UUID()
    let label: String
    let app: String
    let totalDuration: TimeInterval
    let eventCount: Int
    let blocks: [TimeBlock]

    var durationFormatted: String {
        let minutes = Int(totalDuration / 60)
        if minutes < 1 { return VaultText.t("<1m", "1分未満") }
        return VaultText.duration(minutes: minutes)
    }

}

extension TimeBlockEngine {

    /// Analyze a day's blocks and extract "what you mainly did" + supporting facts.
    func analyzDay(for date: Date) -> DailyActivity {
        let blocks = generateBlocks(for: date)
        guard !blocks.isEmpty else {
            return DailyActivity(mainActivities: [], otherActivities: [], totalDuration: 0, appBreakdown: [])
        }

        // Step 1: Group blocks by project/task (same label = same task)
        let chrome = BlockSegmenter.chromeSegments(in: blocks)
        var taskGroups: [String: [TimeBlock]] = [:]
        for block in blocks {
            let key = BlockSegmenter.normalizeTaskKey(block, chrome: chrome)
            taskGroups[key, default: []].append(block)
        }

        // Step 2: Create ActivitySummary per group, sorted by total duration
        let activities = taskGroups.map { key, blocks -> ActivitySummary in
            let totalDuration = blocks.reduce(0.0) { $0 + $1.activeDuration }
            let totalEvents = blocks.reduce(0) { $0 + $1.eventCount }
            let primaryApp = mostCommonApp(in: blocks)
            let label = BlockSegmenter.bestLabel(for: blocks, key: key, chrome: chrome)

            return ActivitySummary(
                label: label,
                app: primaryApp,
                totalDuration: totalDuration,
                eventCount: totalEvents,
                blocks: blocks
            )
        }
        .sorted { $0.totalDuration > $1.totalDuration }

        // Step 3: Split into main (top 3) vs other
        let main = Array(activities.prefix(3))
        let other = Array(activities.dropFirst(3).prefix(5))

        // Step 4: App breakdown (engaged time, not wall-clock)
        var appDurations: [String: TimeInterval] = [:]
        for block in blocks {
            appDurations[block.app, default: 0] += block.activeDuration
        }
        let totalDuration = blocks.reduce(0.0) { $0 + $1.activeDuration }
        let appBreakdown = appDurations
            .sorted { $0.value > $1.value }
            .map { (app: $0.key, duration: $0.value, percentage: $0.value / max(totalDuration, 1) * 100) }

        return DailyActivity(
            mainActivities: main,
            otherActivities: other,
            totalDuration: totalDuration,
            appBreakdown: appBreakdown
        )
    }

    private func mostCommonApp(in blocks: [TimeBlock]) -> String {
        var counts: [String: TimeInterval] = [:]
        for block in blocks {
            counts[block.app, default: 0] += block.duration
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? "Unknown"
    }
}


// MARK: - Home Dashboard Data

struct ProjectSession: Identifiable {
    let id = UUID()
    let date: Date
    let duration: TimeInterval
    let mainLabel: String
    let app: String

    var durationFormatted: String {
        let minutes = Int(duration / 60)
        if minutes < 1 { return VaultText.t("<1m", "1分未満") }
        return VaultText.duration(minutes: minutes)
    }

    var dateFormatted: String {
        let f = DateFormatter()
        f.dateFormat = "M/d (EEE)"
        return f.string(from: date)
    }
}

struct ProjectSnapshot: Identifiable {
    let id = UUID()
    let name: String
    let lastActiveDate: Date
    let lastFile: String?
    let lastClipboard: String?
    let totalDuration: TimeInterval
    let primaryApp: String
    let eventCount: Int
    let daysSinceActive: Int
    let sessions: [ProjectSession]

    /// Is this worth naming to a reader as a project?
    ///
    /// Asked in one place because it was answered in two and they disagreed. On
    /// 2026-08-09 the pasted block stopped reporting a one-minute stray and a
    /// sentence about payment currencies, and `get_projects` went on serving both
    /// over MCP, which is the surface CLAUDE.md §5 calls the product. The paste is
    /// the fallback for tools that cannot call it.
    ///
    /// Two questions, both structural:
    ///
    /// - **Is the name a name?** `ProjectNames.isPlausible` plus the shapes only a
    ///   window title produces: a path, a truncation, a "NNN notes" counter.
    /// - **Is there enough of it?** A minute is a rounding error arriving in the
    ///   same bold formatting as five hours of real work, and nothing in the line
    ///   tells a reader which is which.
    var isWorthReporting: Bool {
        guard totalDuration >= Self.minimumReportedDuration else { return false }
        if name.contains("/") { return false }
        if name.contains("…") || name.hasSuffix("...") { return false }
        if name.range(of: #"\d+\s*notes"#, options: .regularExpression) != nil { return false }
        return ProjectNames.isPlausible(name)
    }

    /// Five minutes. Below this, mull cannot tell working from passing through.
    static let minimumReportedDuration: TimeInterval = 300

    /// Total over the whole window `projectSnapshots` was asked for — 14 days at
    /// every call site. Named `total` and read as "today" by one of them, which is
    /// why `todayDuration` exists next to it.
    var totalDurationFormatted: String {
        let minutes = Int(totalDuration / 60)
        if minutes < 1 { return VaultText.t("<1m", "1分未満") }
        return VaultText.duration(minutes: minutes)
    }

    /// Just today's share, or nil if this project has not been touched today.
    ///
    /// The pasted block's opening sentence said "\(totalDuration) today", which was
    /// the fourteen-day total wearing today's label — up to two weeks of work
    /// reported as one afternoon. `sessions` already carries the per-day split, so
    /// the honest number was one lookup away.
    var todayDuration: TimeInterval? {
        sessions.first { Calendar.current.isDateInToday($0.date) }?.duration
    }

    var lastActiveFormatted: String {
        if daysSinceActive == 0 { return VaultText.t("Today", "今日") }
        if daysSinceActive == 1 { return VaultText.t("Yesterday", "昨日") }
        return VaultText.t("\(daysSinceActive) days ago", "\(daysSinceActive)日前")
    }

}

struct DaySnapshot: Identifiable {
    let date: Date
    let totalDuration: TimeInterval
    let mainProject: String?
    let eventCount: Int
    let isToday: Bool
    var id: Date { date }

    /// The weekday abbreviation in the reader's own language.
    ///
    /// `"EEE"` is an English-shaped request — it returned "Sun" on a Japanese Mac
    /// that writes 日. The standalone symbols are the form meant to appear as a
    /// column heading rather than inside a sentence, which is exactly the use here.
    var dayName: String {
        let cal = Calendar.current
        let index = cal.component(.weekday, from: date) - 1
        return cal.shortStandaloneWeekdaySymbols[index]
    }

    /// The bare day digit. Deliberately not a date *format*: a localised "d" comes
    /// back as 19日 in Japanese, and this is rendered inside a small fixed circle
    /// that has room for the number and nothing else.
    var dayNumber: String {
        String(Calendar.current.component(.day, from: date))
    }

    var durationFormatted: String {
        let minutes = Int(totalDuration / 60)
        if minutes < 1 { return "" }
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m > 0 ? "\(h)h\(m)m" : "\(h)h"
    }
}

struct BriefingItem: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let subtext: String?
    let emphasis: Bool

    init(icon: String, text: String, subtext: String? = nil, emphasis: Bool = false) {
        self.icon = icon
        self.text = text
        self.subtext = subtext
        self.emphasis = emphasis
    }
}

/// Week-over-week comparison data for the briefing.
struct WeekComparison {
    let thisWeekDuration: TimeInterval
    let lastWeekDuration: TimeInterval   // same point in last week (e.g. Mon-Wed vs last Mon-Wed)
    let lastWeekFullDuration: TimeInterval // full last week
    let thisWeekDeepBlocks: Int          // 2h+ uninterrupted blocks
    let lastWeekDeepBlocks: Int
    let thisWeekContextSwitches: Int     // number of app switches
    let lastWeekContextSwitches: Int

    var durationDelta: TimeInterval { thisWeekDuration - lastWeekDuration }
    var durationDeltaPercent: Double {
        guard lastWeekDuration > 0 else { return 0 }
        return durationDelta / lastWeekDuration * 100
    }

    var thisWeekHours: String { formatDuration(thisWeekDuration) }
    var lastWeekHours: String { formatDuration(lastWeekDuration) }
    var deltaFormatted: String {
        let delta = abs(durationDelta)
        let str = formatDuration(delta)
        return durationDelta >= 0 ? "+\(str)" : "-\(str)"
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        VaultText.duration(seconds: d)
    }
}

extension TimeBlockEngine {

    /// Detect projects from the last N days of time blocks.
    func projectSnapshots(days: Int = 14) -> [ProjectSnapshot] {
        let calendar = Calendar.current
        let now = Date()

        struct ProjectAccum {
            var displayName: String
            var lastDate: Date
            var files: [String] = []
            var clipboards: [String] = []
            var duration: TimeInterval = 0
            var apps: [String: TimeInterval] = [:]
            var events: Int = 0
            var sessions: [ProjectSession] = []
        }

        var accum: [String: ProjectAccum] = [:]

        for dayOffset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let blocks = generateBlocks(for: date)

            var dayProjectDuration: [String: (duration: TimeInterval, label: String, app: String)] = [:]
            let chrome = BlockSegmenter.chromeSegments(in: blocks)

            for block in blocks {
                let key = BlockSegmenter.normalizeTaskKey(block, chrome: chrome)

                var data = accum[key] ?? ProjectAccum(
                    displayName: block.label.isEmpty ? block.app : block.label,
                    lastDate: block.end
                )

                if block.end > data.lastDate {
                    data.lastDate = block.end
                    if !block.label.isEmpty { data.displayName = block.label }
                }

                if let title = block.topWindowTitle {
                    let parsed = BlockSegmenter.parseWindowTitle(title, app: block.app)
                    if let file = parsed.file { data.files.append(file) }
                }
                if let clip = block.topClipboard {
                    data.clipboards.append(clip)
                }

                // Engaged time, not wall clock. These totals are shown as how long
                // was spent on a project — `analyzDay` has always summed
                // `activeDuration` for the same question, and a block can now span a
                // rejoined break, which wall clock would bill to the project.
                data.duration += block.activeDuration
                data.apps[block.app, default: 0] += block.activeDuration
                data.events += block.eventCount

                accum[key] = data

                var dayData = dayProjectDuration[key] ?? (0, "", "")
                dayData.duration += block.activeDuration
                if dayData.label.isEmpty { dayData.label = block.label }
                if dayData.app.isEmpty { dayData.app = block.app }
                dayProjectDuration[key] = dayData
            }

            for (key, dayData) in dayProjectDuration {
                let session = ProjectSession(
                    date: date,
                    duration: dayData.duration,
                    mainLabel: dayData.label,
                    app: dayData.app
                )
                accum[key]?.sessions.append(session)
            }
        }

        return accum.compactMap { key, data in
            guard data.events >= 3 else { return nil }
            let primaryApp = data.apps.max(by: { $0.value < $1.value })?.key ?? "Unknown"
            let daysSince = calendar.dateComponents([.day], from: data.lastDate, to: now).day ?? 0

            let parts = data.displayName.components(separatedBy: " — ")
            let displayName = parts.first ?? data.displayName

            return ProjectSnapshot(
                name: displayName,
                lastActiveDate: data.lastDate,
                lastFile: data.files.last,
                lastClipboard: data.clipboards.last.map { Redactor.mask(String($0.prefix(80))) },
                totalDuration: data.duration,
                primaryApp: primaryApp,
                eventCount: data.events,
                daysSinceActive: daysSince,
                sessions: data.sessions.sorted { $0.date > $1.date }
            )
        }
        .sorted { $0.lastActiveDate > $1.lastActiveDate }
    }

    /// Generate day-by-day snapshots for a week starting from a given Monday.
    private func weekSnapshotsFrom(monday: Date) -> [DaySnapshot] {
        let calendar = Calendar.current
        let now = Date()

        return (0..<7).compactMap { offset -> DaySnapshot? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: monday) else { return nil }
            let isToday = calendar.isDateInToday(date)

            if date > now && !isToday {
                return DaySnapshot(date: date, totalDuration: 0, mainProject: nil, eventCount: 0, isToday: false)
            }

            let analysis = analyzDay(for: date)
            let mainProject = analysis.mainActivities.first.map { act -> String in
                let parts = act.label.components(separatedBy: " — ")
                return parts.first ?? act.label
            }

            return DaySnapshot(
                date: date,
                totalDuration: analysis.totalDuration,
                mainProject: mainProject,
                eventCount: analysis.mainActivities.reduce(0) { $0 + $1.eventCount }
                    + analysis.otherActivities.reduce(0) { $0 + $1.eventCount },
                isToday: isToday
            )
        }
    }

    /// Generate day-by-day snapshots for the current week (Mon-Sun).
    func weekSnapshots() -> [DaySnapshot] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today) else { return [] }
        return weekSnapshotsFrom(monday: monday)
    }

    /// Compare this week (up to today) vs same point in last week.
    func weekComparison() -> WeekComparison {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7

        guard let thisMonday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today),
              let lastMonday = calendar.date(byAdding: .day, value: -7, to: thisMonday) else {
            return WeekComparison(thisWeekDuration: 0, lastWeekDuration: 0, lastWeekFullDuration: 0,
                                  thisWeekDeepBlocks: 0, lastWeekDeepBlocks: 0,
                                  thisWeekContextSwitches: 0, lastWeekContextSwitches: 0)
        }

        let thisWeek = weekSnapshotsFrom(monday: thisMonday)
        let lastWeek = weekSnapshotsFrom(monday: lastMonday)

        // Only compare up to the same day-of-week
        let daysElapsed = daysFromMonday + 1
        let thisWeekSlice = thisWeek.prefix(daysElapsed)
        let lastWeekSlice = lastWeek.prefix(daysElapsed)

        let thisTotal = thisWeekSlice.reduce(0.0) { $0 + $1.totalDuration }
        let lastTotal = lastWeekSlice.reduce(0.0) { $0 + $1.totalDuration }
        let lastFull = lastWeek.reduce(0.0) { $0 + $1.totalDuration }

        // Deep work blocks: blocks >= 2 hours. Measured in engaged time, as
        // `BehaviorPatternEngine.detectContextSwitchCorrelation` measures it — the two
        // counted the same concept two different ways, and wall clock was the wrong
        // one of them even before a block could span a break.
        func countDeepBlocks(from monday: Date, days: Int) -> Int {
            var count = 0
            for offset in 0..<days {
                guard let date = calendar.date(byAdding: .day, value: offset, to: monday) else { continue }
                let blocks = generateBlocks(for: date)
                count += blocks.filter { $0.activeDuration >= 7200 }.count
            }
            return count
        }

        // Context switches: count app switch events
        func countSwitches(from monday: Date, days: Int) -> Int {
            var count = 0
            for offset in 0..<days {
                guard let date = calendar.date(byAdding: .day, value: offset, to: monday) else { continue }
                let start = calendar.startOfDay(for: date)
                guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
                let events = database.fetchEvents(from: start, to: min(end, now))
                count += events.filter { $0.eventType == .appSwitch }.count
            }
            return count
        }

        let thisDeep = countDeepBlocks(from: thisMonday, days: daysElapsed)
        let lastDeep = countDeepBlocks(from: lastMonday, days: daysElapsed)
        let thisSwitches = countSwitches(from: thisMonday, days: daysElapsed)
        let lastSwitches = countSwitches(from: lastMonday, days: daysElapsed)

        return WeekComparison(
            thisWeekDuration: thisTotal,
            lastWeekDuration: lastTotal,
            lastWeekFullDuration: lastFull,
            thisWeekDeepBlocks: thisDeep,
            lastWeekDeepBlocks: lastDeep,
            thisWeekContextSwitches: thisSwitches,
            lastWeekContextSwitches: lastSwitches
        )
    }
}
