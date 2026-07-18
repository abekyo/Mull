import Foundation

/// Turns the day's measurements into sentences.
///
///   Data:      "Code: 47%, Xcode: 22%, Firefox: 12%"
///   Sentences: "Most of the day was in Code, 47% of it. Xcode took 22%."
///
/// Prose, not framing. The job is to make the numbers readable, not to characterize
/// the day or the person who spent it — mull counts events, which is no basis for
/// telling someone they were focused, intense, or taking it easy (§1 Custode: no
/// 所有者面; §3.5: no verdicts dressed as knowledge). Sentence shapes are varied on
/// purpose: a page where every line is "clause — reframe" reads as generated.
///
/// All rule-based. No LLM needed.
struct NarrativeEngine {

    let analysis: DailyActivity
    let analytics: AnalyticsEngine
    let database: DatabaseService

    /// How many activities get a sentence of their own before the rest are summed.
    private static let maxActivitySentences = 3

    /// What the narrative has already spent, so a later section does not spend it
    /// again in different words.
    ///
    /// The sections draw on the same handful of numbers — the day's largest
    /// activity is the opening line's subject, the story's first sentence and the
    /// pattern section's leading app — and each was free to phrase it afresh.
    /// Three true sentences about one fact still read as a machine padding a page.
    /// A section notes what it has said; the sections after it check first.
    private struct StatedFacts {
        private var keys: Set<String> = []

        private static func key(_ kind: String, _ subject: String) -> String {
            "\(kind):\(subject.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
        }

        /// A subject whose duration or share has already been given in figures.
        mutating func noteQuantity(of subject: String) { keys.insert(Self.key("quantity", subject)) }
        func hasQuantity(of subject: String) -> Bool { keys.contains(Self.key("quantity", subject)) }

        /// A subject already named as the thing the day mostly went to.
        mutating func noteLead(_ subject: String) { keys.insert(Self.key("lead", subject)) }
        func hasLead(_ subject: String) -> Bool { keys.contains(Self.key("lead", subject)) }

        /// The day has already been described as one thing or as many.
        mutating func noteActivityCount() { keys.insert("activity-count") }
        var hasActivityCount: Bool { keys.contains("activity-count") }
    }

    /// Generate a full narrative for the day.
    func generateNarrative() -> String {
        var parts: [String] = []
        var stated = StatedFacts()

        // Opening line — what the day mostly consisted of
        parts.append(openingLine(stated: &stated))

        // Main story — what you spent time on, told as a story
        let mainStory = mainActivityStory(stated: &stated)
        if !mainStory.isEmpty {
            parts.append("")
            parts.append(mainStory)
        }

        // Comparisons against the recorded past — stated with their basis
        let comparisons = comparisonsAgainstRecord(stated: &stated)
        if !comparisons.isEmpty {
            parts.append("")
            parts.append(comparisons)
        }

        // What you were working with (clipboard insights)
        let clipInsight = clipboardInsight()
        if !clipInsight.isEmpty {
            parts.append("")
            parts.append(clipInsight)
        }

        // Pattern observation — compared to your usual behavior
        let pattern = patternObservation(stated: &stated)
        if !pattern.isEmpty {
            parts.append("")
            parts.append(pattern)
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Opening Line

    /// One sentence for what the day mostly consisted of.
    private func openingLine(stated: inout StatedFacts) -> String {
        guard !analysis.mainActivities.isEmpty else {
            return "Not much recorded today yet."
        }

        let totalMinutes = Int(analysis.totalDuration / 60)
        let mainLabel = analysis.mainActivities.first?.label ?? ""
        let leadingApp = analysis.appBreakdown.first?.app

        // Single-focus day
        if analysis.mainActivities.count == 1 {
            let pct = analysis.appBreakdown.first?.percentage ?? 0
            stated.noteQuantity(of: mainLabel)
            stated.noteLead(mainLabel)
            if let leadingApp { stated.noteLead(leadingApp) }
            stated.noteActivityCount()
            if pct > 70 {
                return "Almost all of today was \(mainLabel), \(Int(pct))% of the recorded time."
            }
            return "Today was mostly \(mainLabel), \(analysis.mainActivities.first?.durationFormatted ?? "")."
        }

        // Multi-project day
        if analysis.mainActivities.count >= 3 {
            let names = analysis.mainActivities.prefix(3).map(\.label)
            // Named, but not measured — the story below still has their durations
            // to add, so only the lead is spent here.
            stated.noteLead(mainLabel)
            if let leadingApp { stated.noteLead(leadingApp) }
            return "Today moved between \(names.joined(separator: ", "))."
        }

        // Two-focus day
        if analysis.mainActivities.count == 2 {
            let a = analysis.mainActivities[0]
            let b = analysis.mainActivities[1]
            if a.totalDuration > b.totalDuration * 2 {
                stated.noteLead(a.label)
                if let leadingApp { stated.noteLead(leadingApp) }
                stated.noteQuantity(of: b.label)
                return "Today was mostly \(a.label), with \(b.durationFormatted) on \(b.label)."
            }
            return "Today split between \(a.label) and \(b.label)."
        }

        return "\(totalMinutes / 60)h \(totalMinutes % 60)m recorded today."
    }

    // MARK: - Main Activity Story

    /// Turn activities into sentences, not bullet points.
    private func mainActivityStory(stated: inout StatedFacts) -> String {
        guard !analysis.mainActivities.isEmpty else { return "" }

        // On a single-focus day the opening line has already paired the activity
        // with its duration, and saying it again in a second register is the
        // symptom this file's header warns about. Anything already measured
        // aloud is passed over here.
        let unspoken = analysis.mainActivities.filter { !stated.hasQuantity(of: $0.label) }

        var sentences: [String] = []

        for activity in unspoken.prefix(Self.maxActivitySentences) {
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
                sentences.append("You spent \(duration) in \(app) on \(label).")
            } else if isCommApp(app) {
                sentences.append("\(app) took \(duration).")
            } else {
                sentences.append("\(label) took \(duration) in \(app).")
            }

            stated.noteQuantity(of: label)
        }

        // A day that fragmented badly arrives as a long tail, and one sentence of
        // the same shape per item stops being prose and becomes a list with full
        // stops in it. Past the cap the remainder is summed rather than recited.
        let remainder = Array(unspoken.dropFirst(Self.maxActivitySentences)) + analysis.otherActivities
        if remainder.count > 3 {
            let total = remainder.reduce(0.0) { $0 + $1.totalDuration }
            sentences.append("Another \(remainder.count) activities took \(durationPhrase(total)) between them.")
        } else if !remainder.isEmpty {
            let others = remainder
                .map { "\($0.label) (\($0.durationFormatted))" }
                .joined(separator: ", ")
            sentences.append("There was also \(others).")
        }

        return sentences.joined(separator: " ")
    }

    // MARK: - Comparisons against the record

    /// Today set against what was recorded before it. Each line names the comparison
    /// it rests on ("than yesterday", "in the N recorded days before today") so the
    /// specificity reads as arithmetic on the user's own records rather than as a
    /// lucky guess.
    ///
    /// The name of this section used to be "Hot Reading", after the fortune-telling
    /// technique of arriving already knowing something about the mark. That framing
    /// is gone: the goal is a comparison the user can check, not one that lands.
    private func comparisonsAgainstRecord(stated: inout StatedFacts) -> String {
        var observations: [String] = []

        // Compare today's duration to yesterday
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let yesterdayEngine = TimeBlockEngine(database: database)
        let yesterdayAnalysis = yesterdayEngine.analyzDay(for: yesterday)

        if yesterdayAnalysis.totalDuration > 0 && analysis.totalDuration > 0 {
            let diff = analysis.totalDuration - yesterdayAnalysis.totalDuration
            let diffMinutes = Int(abs(diff) / 60)

            if diffMinutes > 30 {
                if diff > 0 {
                    observations.append("That is \(diffMinutes) minutes more than yesterday.")
                } else {
                    observations.append("That is \(diffMinutes) minutes less than yesterday.")
                }
            }
        }

        // Compare today's top app to yesterday's top app
        let yesterdayApps = yesterdayAnalysis.appBreakdown
        let todayApps = analysis.appBreakdown
        if let todayTop = todayApps.first, let yesterdayTop = yesterdayApps.first {
            if todayTop.app != yesterdayTop.app {
                // Which app leads today may already have opened the narrative. The
                // new half of this comparison is yesterday's, so on a repeat only
                // yesterday's half is kept.
                if stated.hasLead(todayTop.app) {
                    observations.append("Yesterday the top app was \(yesterdayTop.app).")
                } else {
                    observations.append("Yesterday's top app was \(yesterdayTop.app); today it is \(todayTop.app).")
                    stated.noteLead(todayTop.app)
                }
            }
        }

        // Things that appear today and not in the past week.
        //
        // This is the last surviving piece of the "hot reading" design — the
        // fortune-teller's trick of producing an impressive specific to make the
        // reader feel known (ONBOARDING.md, now deleted). It said "X hasn't
        // appeared in the past week's records until today" on the strength of a
        // 15-character prefix substring match against raw window titles, with
        // `break // Only mention one new thing` enforcing the showmanship rule of
        // never over-explaining. Rename the title from `Foo — index.ts` to
        // `Foo — main.ts` and it announced a discovery.
        //
        // Kept, because "you have not touched this in a week" is genuinely useful
        // to an assistant. Rewritten so the claim is one the data supports:
        // compared as entities rather than as string prefixes, and silent when
        // the week holds too little to support an absence claim at all — mull
        // being switched off last Tuesday is not evidence that anything is new.
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let weekEvents = database.fetchEvents(from: weekAgo, to: Calendar.current.startOfDay(for: Date()))
            .filter { $0.eventType == .screenText }

        // An absence is only meaningful against a week that was actually recorded.
        let recordedDays = Set(weekEvents.map { Calendar.current.startOfDay(for: $0.timestamp) })
        if recordedDays.count >= 3 {
            let weekEntities = Set(weekEvents.compactMap { Entity.from($0.textContent)?.lowercased() })
            let fresh = analysis.mainActivities.filter { activity in
                guard activity.totalDuration > 300 else { return false }
                guard let entity = Entity.from(activity.label)?.lowercased() else { return false }
                return !weekEntities.contains(entity)
            }
            // Two at most, because a list of five stops being informative — not
            // because one lands better.
            for activity in fresh.prefix(2) {
                observations.append("\(activity.label) does not appear in the \(recordedDays.count) recorded days before today.")
            }
        }

        // Detect if today's schedule is busier than usual
        let todayHour = Calendar.current.component(.hour, from: Date())
        let todayHourly = analytics.hourlyPattern(days: 1)
        let weeklyHourly = analytics.hourlyPattern(days: 7)

        if todayHour >= 6 {
            let todayEventsUpToNow = todayHourly.filter { $0.hour <= todayHour }.reduce(0) { $0 + $1.eventCount }
            let weeklyAvgUpToNow = weeklyHourly.filter { $0.hour <= todayHour }.reduce(0) { $0 + $1.eventCount } / 7

            if weeklyAvgUpToNow > 0 {
                let ratio = Double(todayEventsUpToNow) / Double(weeklyAvgUpToNow)
                // Event counts against event counts. Whether the day was intense or
                // restful is not something a counter can know, so it isn't said.
                if ratio > 1.5 {
                    observations.append("By this hour there are more events logged than on an average day this week.")
                } else if ratio < 0.5 && todayEventsUpToNow > 10 {
                    observations.append("By this hour there are fewer events logged than on an average day this week.")
                }
            }
        }

        // Detect heavy time invested in one activity (engaged time, summed
        // across the day's blocks — not necessarily one unbroken session).
        for activity in analysis.mainActivities {
            // Rounding the same duration up to whole hours does not make it a
            // second observation, so an activity already measured is left alone.
            if activity.totalDuration > 7200, !stated.hasQuantity(of: activity.label) { // 2+ hours of engaged time
                let hours = Int(activity.totalDuration / 3600)
                observations.append("\(activity.label) accounts for over \(hours) hours of today.")
                stated.noteQuantity(of: activity.label)
                break
            }
        }

        // Detect late/early activity
        if let firstEvent = analysis.mainActivities.first?.blocks.first {
            let startHour = Calendar.current.component(.hour, from: firstEvent.start)
            if startHour < 6 {
                observations.append("The first block today started before 6 AM.")
            }
        }

        guard !observations.isEmpty else { return "" }
        return observations.prefix(3).joined(separator: " ")
    }

    // MARK: - Clipboard Insight

    /// What was copied today, quoted. mull knows the text was on the clipboard and
    /// nothing beyond that, so the sentences say only that.
    ///
    /// The quoting is the dangerous part: this string is written into a markdown file
    /// under ~/mull that syncs, gits, and is readable over MCP. The only filter used to
    /// be a length window, so a password-manager paste, a 2FA code, an API key or a
    /// private DM landed verbatim in the user's permanent record. Anything
    /// `SensitiveText` recognises is now dropped outright rather than masked — a
    /// half-masked secret is still a secret, and the sentence reads fine without it.
    private func clipboardInsight() -> String {
        let since = Calendar.current.startOfDay(for: Date())
        let clips = database.fetchEvents(from: since, to: Date())
            .filter { $0.eventType == .clipboard }
            .filter { e in
                guard let app = e.appName, !AnalyticsEngine.isNoiseApp(app) else { return false }
                guard let text = e.textContent, text.count > 10, text.count < 200 else { return false }
                guard !SensitiveText.isSensitive(text) else { return false }
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
            // Belt and braces: the filter above already dropped credential-shaped
            // text, but this string is about to be written to disk permanently.
            let preview = Redactor.mask(String(clip.prefix(80)))
            unique.append(preview.replacingOccurrences(of: "\n", with: " "))
        }

        if unique.count == 1 {
            return "You copied one thing today, \"\(unique[0])\"."
        }

        if unique.count <= 3 {
            let items = unique.map { "\"\($0)\"" }.joined(separator: ", ")
            return "You copied \(items)."
        }

        let sample = unique.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ")
        return "You copied \(unique.count) things today, among them \(sample)."
    }

    // MARK: - Pattern Observation

    /// Compare today to the user's typical patterns.
    private func patternObservation(stated: inout StatedFacts) -> String {
        var observations: [String] = []

        // Compare app usage to weekly average
        let weeklyApps = analytics.appUsage(days: 7)
        let todayApps = analytics.appUsage(days: 1)

        if let todayTop = todayApps.first, let weeklyTop = weeklyApps.first {
            // What led today may be two sections old by now. The week is the part
            // that has not been said, so on a repeat only the week is said.
            if stated.hasLead(todayTop.appName) {
                if todayTop.appName == weeklyTop.appName {
                    observations.append("\(weeklyTop.appName) leads the week too, not only today.")
                } else {
                    observations.append("Over the week the leading app is \(weeklyTop.appName).")
                }
            } else if todayTop.appName == weeklyTop.appName {
                observations.append("\(todayTop.appName) led today, as it did over the week.")
                stated.noteLead(todayTop.appName)
            } else {
                observations.append("\(todayTop.appName) led today; over the week it is \(weeklyTop.appName).")
                stated.noteLead(todayTop.appName)
            }
        }

        // Peak hour observation
        let todayHourly = analytics.hourlyPattern(days: 1)
        let peak = todayHourly.max(by: { $0.eventCount < $1.eventCount })
        if let p = peak, p.eventCount > 0 {
            let hour = p.hour
            if hour < 10 || hour >= 20 {
                observations.append("The busiest hour was \(String(format: "%02d:00", hour)).")
            }
        }

        // Activity count comparison
        let todayCount = analysis.mainActivities.count + analysis.otherActivities.count
        if todayCount >= 5 && !stated.hasActivityCount {
            observations.append("There were \(todayCount) distinct activities today.")
            stated.noteActivityCount()
        } else if todayCount == 1 && !stated.hasActivityCount {
            observations.append("Everything today fell under one activity.")
            stated.noteActivityCount()
        }

        return observations.joined(separator: " ")
    }

    // MARK: - Helpers

    /// Matches `ActivitySummary.durationFormatted` so a summed tail reads in the
    /// same units as the sentences above it.
    private func durationPhrase(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remaining = minutes % 60
        return remaining > 0 ? "\(hours)h \(remaining)m" : "\(hours)h"
    }

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
