import Foundation

/// Barnum effect — turn generic data patterns into personal-feeling insights.
///
/// "Peak hours: 11:00, 14:00"
///   → "You tend to hit your stride late morning. Your second wind comes after lunch."
///
/// Same data. Feels like it was written just for you.
/// All rule-based. No LLM.
struct InsightPhrases {

    // MARK: - Activity Pattern

    static func activityInsight(hourly: [HourlyStat]) -> String? {
        let peak = hourly.sorted { $0.eventCount > $1.eventCount }.first
        guard let p = peak, p.eventCount > 0 else { return nil }

        switch p.hour {
        case 5...8:
            return "You're an early riser — your most productive hours are before most people open their laptops."
        case 9...11:
            return "Late morning is your power zone. You tend to do your deepest work before lunch."
        case 12...13:
            return "You work through lunch — your focus peaks when others are taking breaks."
        case 14...16:
            return "Your afternoon sessions are your strongest. You build momentum as the day goes on."
        case 17...19:
            return "You're an end-of-day finisher. Your best output comes in the final stretch."
        case 20...23:
            return "You're a night owl. Your deepest focus happens when the world gets quiet."
        case 0...4:
            return "Late nights are your element. You do your most focused work in the small hours."
        default:
            return nil
        }
    }

    // MARK: - Weekday Pattern

    static func weekdayInsight(weekday: [WeekdayStat]) -> String? {
        // Weekday encoding: 1=Sun, 2=Mon, 3=Tue, 4=Wed, 5=Thu, 6=Fri, 7=Sat.
        // Need enough days with data before claiming a weekly rhythm — on a new
        // install most weekdays legitimately have zero events (no data yet), and
        // a zero must not be read as "a day off."
        let daysWithData = weekday.filter { $0.eventCount > 0 }.count
        guard daysWithData >= 4,
              let busiest = weekday.max(by: { $0.eventCount < $1.eventCount }),
              let quietest = weekday.min(by: { $0.eventCount < $1.eventCount }),
              busiest.eventCount > 0 else { return nil }

        if busiest.weekday == 1 || busiest.weekday == 7 { // Sun or Sat
            return "Interestingly, you're most active on \(busiest.name) — weekends are your productive time."
        }

        // A genuine zero-event day (any weekday) once there's enough data to tell.
        if quietest.eventCount == 0 {
            return "You take \(quietest.name) completely off. Clear boundaries between work and rest."
        }

        if busiest.weekday == 2 { // Monday
            return "You hit the ground running on Mondays. You start the week with the most energy."
        }

        if busiest.weekday == 6 { // Friday
            return "Fridays are your power day. You push hardest before the weekend."
        }

        return "Your \(busiest.name)s tend to be the most intense. \(quietest.name)s are your quieter days."
    }

    // MARK: - Language Mix

    static func languageInsight(mix: LanguageMix) -> String? {
        if mix.japanesePercent > 40 && mix.englishPercent > 40 {
            return "You operate in two languages naturally — switching between Japanese and English throughout the day."
        }

        if mix.codePercent > 20 {
            return "A significant portion of your work is in code. You think in programming logic."
        }

        if mix.japanesePercent > 70 {
            return "Your work is primarily in Japanese. You think and communicate in your native language."
        }

        if mix.englishPercent > 70 && mix.japanesePercent > 5 {
            return "You work mainly in English, but Japanese appears in your communication."
        }

        return nil
    }

    // MARK: - App Usage

    static func appUsageInsight(apps: [AppUsageStat]) -> String? {
        guard let top = apps.first else { return nil }

        if top.percentage > 70 {
            return "You're deeply committed to \(top.appName) — it's your primary workspace, and you rarely leave it."
        }

        if apps.count >= 3 {
            let topThree = apps.prefix(3).map(\.appName).joined(separator: ", ")
            if apps[0].percentage < 40 {
                return "You spread your time across tools — \(topThree). You're a multi-tool operator."
            }
        }

        if apps.contains(where: { ["Slack", "Discord", "Teams", "Zoom"].contains($0.appName) }) {
            return "Your day includes both deep work and communication. You balance building with collaborating."
        }

        return "\(top.appName) is your home base — where you spend the most time."
    }

    // MARK: - Focus Style

    static func focusInsight(mainActivities: Int, totalDuration: TimeInterval) -> String? {
        let hours = totalDuration / 3600

        if mainActivities == 1 && hours > 2 {
            return "You have the ability to maintain deep focus. Single-tasking for \(Int(hours))+ hours is rare."
        }

        if mainActivities >= 4 {
            return "You're a context-switcher — comfortable moving between multiple projects in one day."
        }

        if mainActivities == 2 {
            return "You tend to structure your day around two main themes. Balanced, not scattered."
        }

        if hours > 6 {
            return "A long day of active work. You put in the hours when it matters."
        }

        return nil
    }

    // MARK: - Keywords

    static func keywordInsight(keywords: [KeywordStat]) -> String? {
        guard keywords.count >= 3 else { return nil }

        let topThree = keywords.prefix(3).map(\.word)

        // Check for patterns
        let devWords = Set(["swift", "func", "struct", "class", "view", "controller", "storyboard", "api", "error", "debug"])
        let devMatches = topThree.filter { devWords.contains($0.lowercased()) }
        if devMatches.count >= 2 {
            return "Your vocabulary this week is deeply technical. You're in builder mode."
        }

        let planWords = Set(["plan", "design", "todo", "review", "meeting", "discuss", "decide"])
        let planMatches = topThree.filter { planWords.contains($0.lowercased()) }
        if planMatches.count >= 2 {
            return "Your recent focus has been on planning and coordination, not just execution."
        }

        return "The themes in your work this week: \(topThree.joined(separator: ", "))."
    }
}
