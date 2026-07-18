import Foundation

/// Plain-language readings of the rule-based statistics.
///
/// "Peak hours: 11:00, 14:00"
///   → "Your busiest hour was 11:00, with 14:00 close behind."
///
/// These lines report a measurement in words. They do not grade the day, praise the
/// user, or name a personality: mull can see that the busiest hour was 06:00, but
/// "you're an early riser" is a claim about a person, made from a clock. §1 Custode
/// forbids the 所有者面 of "we analyzed you"; §1 Cultura forbids the chirpy
/// productivity register that turns a number into a compliment.
///
/// The rule when adding a line here: state the observation and stop. Prefer the
/// concrete measurement ("06:40 is this week's average start") over the label
/// ("early riser"). If a sentence would still make sense about someone else's data,
/// it is a horoscope, not an observation.
///
/// All rule-based. No LLM.
struct InsightPhrases {

    // MARK: - Activity Pattern

    static func activityInsight(hourly: [HourlyStat]) -> String? {
        let peak = hourly.sorted { $0.eventCount > $1.eventCount }.first
        guard let p = peak, p.eventCount > 0 else { return nil }

        let hour = String(format: "%02d:00", p.hour)

        switch p.hour {
        case 5...8:
            return "Your busiest hour was \(hour), before most working days start."
        case 9...11:
            return "Your busiest hour was \(hour), late morning."
        case 12...13:
            return "Your busiest hour was \(hour), over the middle of the day."
        case 14...16:
            return "Your busiest hour was \(hour), in the afternoon."
        case 17...19:
            return "Your busiest hour was \(hour), toward the end of the day."
        case 20...23:
            return "Your busiest hour was \(hour), in the evening."
        case 0...4:
            return "Your busiest hour was \(hour), overnight."
        default:
            return nil
        }
    }

    // MARK: - Weekday Pattern

    /// `windowDays` is the span the buckets were summed over, which the caller
    /// chose when it asked for the pattern. Without it there is no way to tell an
    /// empty weekday from one the window has not reached.
    static func weekdayInsight(weekday: [WeekdayStat], windowDays: Int = 7) -> String? {
        // Weekday encoding: 1=Sun, 2=Mon, 3=Tue, 4=Wed, 5=Thu, 6=Fri, 7=Sat.
        //
        // A bucket sums every occurrence of its weekday inside the window, so a
        // weekday the window has not come round to yet sits at zero for want of
        // having happened — and "Nothing was recorded on Friday", said on a
        // Wednesday, is a claim about the future. Only weekdays that actually
        // elapsed are considered, today excluded because it is still running.
        let elapsed = elapsedWeekdayCounts(windowDays: windowDays)
        let sampled = weekday.filter { (elapsed[$0.weekday] ?? 0) > 0 }

        // Need enough days with data before claiming a weekly rhythm — on a new
        // install most weekdays legitimately have zero events (no data yet), and
        // a zero must not be read as "a day off."
        let daysWithData = sampled.filter { $0.eventCount > 0 }.count
        guard daysWithData >= 4,
              let busiest = sampled.max(by: { $0.eventCount < $1.eventCount }),
              let quietest = sampled.min(by: { $0.eventCount < $1.eventCount }),
              busiest.eventCount > 0,
              busiest.weekday != quietest.weekday else { return nil }

        if busiest.weekday == 1 || busiest.weekday == 7 { // Sun or Sat
            return "\(busiest.name) carried the most activity of any day this week."
        }

        // An elapsed zero is still ambiguous: a day off, or a day mull was not
        // running. It is worth saying only as the single gap in an otherwise
        // complete week — several zeros side by side describe patchy recording,
        // which is a fact about the recorder and not about the week.
        if quietest.eventCount == 0 {
            guard daysWithData == sampled.count - 1 else {
                return "\(busiest.name) carried more than any other day recorded."
            }
            if (elapsed[quietest.weekday] ?? 0) > 1 {
                return "No \(quietest.name) in this window carries a record."
            }
            return "Nothing was recorded on \(quietest.name)."
        }

        return "\(busiest.name) was the busiest day, \(quietest.name) the quietest."
    }

    /// How many times each weekday came and went inside the window. Today is left
    /// out: it is half-lived, and a quiet morning is not an empty day.
    private static func elapsedWeekdayCounts(windowDays: Int, now: Date = Date()) -> [Int: Int] {
        let calendar = Calendar.current
        var counts: [Int: Int] = [:]
        for offset in 1...max(windowDays, 1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            counts[calendar.component(.weekday, from: day), default: 0] += 1
        }
        return counts
    }

    // MARK: - Language Mix

    static func languageInsight(mix: LanguageMix) -> String? {
        if mix.japanesePercent > 40 && mix.englishPercent > 40 {
            return "Your text splits roughly evenly between Japanese and English."
        }

        if mix.codePercent > 20 {
            return "About \(Int(mix.codePercent))% of what you typed was code."
        }

        if mix.japanesePercent > 70 {
            return "\(Int(mix.japanesePercent))% of what you typed was Japanese."
        }

        if mix.englishPercent > 70 && mix.japanesePercent > 5 {
            return "Mostly English (\(Int(mix.englishPercent))%), with some Japanese."
        }

        return nil
    }

    // MARK: - App Usage

    static func appUsageInsight(apps: [AppUsageStat]) -> String? {
        guard let top = apps.first else { return nil }

        if top.percentage > 70 {
            return "\(top.appName) accounted for \(Int(top.percentage))% of your recorded time."
        }

        if apps.count >= 3, top.percentage < 40 {
            let topThree = apps.prefix(3).map(\.appName).joined(separator: ", ")
            // The figure is the leader's own share. Hung on "none of them above",
            // it becomes a ceiling the leader is standing on top of.
            return "Your time was spread across \(topThree), the largest share \(Int(top.percentage))%."
        }

        if let comm = apps.first(where: { ["Slack", "Discord", "Teams", "Zoom"].contains($0.appName) }) {
            return "\(Int(comm.percentage))% of your time was in \(comm.appName)."
        }

        return "\(top.appName) took the most time, at \(Int(top.percentage))%."
    }

    // MARK: - Focus Style

    static func focusInsight(mainActivities: Int, totalDuration: TimeInterval) -> String? {
        let hours = totalDuration / 3600

        if mainActivities == 1 && hours > 2 {
            let minutes = Int(totalDuration.truncatingRemainder(dividingBy: 3600) / 60)
            return "One activity accounted for all \(Int(hours))h \(minutes)m recorded."
        }

        if mainActivities >= 4 {
            return "\(mainActivities) separate activities today."
        }

        if mainActivities == 2 {
            return "Two activities today."
        }

        if hours > 6 {
            return "\(Int(hours)) hours of recorded activity."
        }

        return nil
    }

    // MARK: - Keywords

    static func keywordInsight(keywords: [KeywordStat]) -> String? {
        guard keywords.count >= 3 else { return nil }

        let topThree = keywords.prefix(3).map(\.word)
        return "Most frequent words this week: \(topThree.joined(separator: ", "))."
    }
}
