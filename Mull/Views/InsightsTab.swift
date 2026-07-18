import SwiftUI

// MARK: - Insights Tab (the "wow" tab)

struct InsightsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var keywords: [KeywordStat] = []
    @State private var appUsage: [AppUsageStat] = []
    @State private var hourly: [HourlyStat] = []
    @State private var weekday: [WeekdayStat] = []
    @State private var langMix = LanguageMix(japanesePercent: 0, englishPercent: 0, codePercent: 0)
    @State private var facts: [Fact] = []
    // Everything below used to be computed inside `body`: a TimeBlockEngine day
    // analysis, a memories fetch, and a blocking EventKit call — all re-running on
    // every redraw. They're loaded once, off the main thread, into state.
    @State private var focusInsight: String?
    @State private var memories: [MemoryEntry] = []
    @State private var todaySchedule: String?

    var body: some View {
        ScrollView {
            VStack(spacing: DS.lg) {
                // Hero: identity card
                heroCard
                    .padding(.horizontal, DS.xl)
                    .padding(.top, DS.lg)

                // Schedule (if available)
                if let schedule = todaySchedule {
                    scheduleCard(schedule)
                        .padding(.horizontal, DS.xl)
                }

                // mull summary (if available)
                if let summary = appState.todaySummary {
                    summaryCard(summary)
                        .padding(.horizontal, DS.xl)
                }

                // Analytics grid — uniform card size
                let cardHeight: CGFloat = 160

                HStack(alignment: .top, spacing: DS.md) {
                    activityHeatmap.frame(maxWidth: .infinity, minHeight: cardHeight)
                    weekdayChart.frame(maxWidth: .infinity, minHeight: cardHeight)
                }
                .padding(.horizontal, DS.xl)

                HStack(alignment: .top, spacing: DS.md) {
                    languageCard.frame(maxWidth: .infinity, minHeight: cardHeight)
                    appUsageCard.frame(maxWidth: .infinity, minHeight: cardHeight)
                }
                .padding(.horizontal, DS.xl)

                // Keywords — full width
                keywordsCard
                    .padding(.horizontal, DS.xl)

                // What mull knows — full width
                memoryCard
                    .padding(.horizontal, DS.xl)
                    .padding(.bottom, DS.xl)
            }
        }
        .task { await refresh() }
    }

    /// Six analytics passes, a day analysis, a memories fetch and an EventKit read —
    /// each one scans days of events. Running them synchronously from .onAppear froze
    /// the window on every visit to this tab; they run detached and publish once.
    private func refresh() async {
        let analytics = appState.analytics
        let database = appState.database
        let calendarService = appState.calendar

        let loaded = await Task.detached(priority: .userInitiated) { () -> (
            keywords: [KeywordStat], appUsage: [AppUsageStat], hourly: [HourlyStat],
            weekday: [WeekdayStat], langMix: LanguageMix, facts: [Fact],
            focus: String?, memories: [MemoryEntry], schedule: String?
        ) in
            let dayAnalysis = TimeBlockEngine(database: database).analyzDay(for: Date())
            return (
                analytics.topKeywords(days: 7, limit: 20),
                analytics.appUsage(days: 7),
                analytics.hourlyPattern(days: 7),
                analytics.weekdayPattern(days: 30),
                analytics.languageMix(days: 7),
                FactExtractor(analytics: analytics, database: database).extractFacts(days: 7),
                InsightPhrases.focusInsight(mainActivities: dayAnalysis.mainActivities.count,
                                            totalDuration: dayAnalysis.totalDuration),
                database.fetchAllMemories(),
                calendarService.todaySchedule()
            )
        }.value

        guard !Task.isCancelled else { return }
        keywords = loaded.keywords
        appUsage = loaded.appUsage
        hourly = loaded.hourly
        weekday = loaded.weekday
        langMix = loaded.langMix
        facts = loaded.facts
        focusInsight = loaded.focus
        memories = loaded.memories
        todaySchedule = loaded.schedule
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        VStack(spacing: DS.md) {
            // Big identity statement
            HStack(spacing: DS.md) {
                ZStack {
                    Circle()
                        .fill(DS.accentGradient)
                        .frame(width: 48, height: 48)
                    Image(systemName: "person.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: DS.xs) {
                    Text("Your Profile")
                        .font(DS.titleFont)

                    if facts.isEmpty {
                        // Day 1: seed from cold read instead of showing nothing
                        Text("Watch the patterns emerge — first insights build within hours.")
                            .font(DS.captionFont)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(appState.todayEventCount)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.moon)
                    Text("events today")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                }
            }

            // Facts as tags
            if !facts.isEmpty {
                FlowLayout(spacing: DS.xs) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                        factTag(fact)
                    }
                }
            }

            // Barnum-style focus insight (computed in refresh(), not here)
            if let focus = focusInsight {
                Text(focus)
                    .font(DS.captionFont)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .mullHeroCard()
    }

    private func factTag(_ fact: Fact) -> some View {
        HStack(spacing: DS.xs) {
            Image(systemName: factIcon(fact.category))
                .font(.system(size: 8))
                .foregroundStyle(factColor(fact.category))
            Text(fact.text)
                .font(.system(size: 11))
        }
        .padding(.horizontal, DS.sm)
        .padding(.vertical, DS.xs)
        .background(factColor(fact.category).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSm))
    }

    private func factIcon(_ category: FactCategory) -> String {
        switch category {
        case .identity: "person.fill"
        case .skills: "wrench.fill"
        case .projects: "folder.fill"
        case .patterns: "clock.fill"
        }
    }

    private func factColor(_ category: FactCategory) -> Color {
        switch category {
        case .identity: DS.moon
        case .skills: DS.recording
        case .projects: DS.paused
        case .patterns: DS.eventApp
        }
    }

    // MARK: - Schedule Card

    private func scheduleCard(_ schedule: String) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(DS.moon)
                Text("Today's Schedule")
                    .font(DS.titleFont)
            }

            let lines = schedule.components(separatedBy: "\n").dropFirst() // Skip "Today's schedule:" header
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let isNow = line.contains("← NOW")
                let isSoon = line.contains("← in")

                HStack(spacing: DS.sm) {
                    Circle()
                        .fill(isNow ? DS.recording : (isSoon ? DS.paused : Color.secondary.opacity(0.3)))
                        .frame(width: 6, height: 6)

                    Text(line.replacingOccurrences(of: "- ", with: ""))
                        .font(isNow ? DS.bodyMedium : DS.bodyFont)
                        .foregroundStyle(isNow ? .primary : .secondary)
                }
            }
        }
        .mullCard()
    }

    // MARK: - Summary Card

    private func summaryCard(_ summary: DailySummary) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack {
                Image(systemName: "moon.stars.fill")
                    .foregroundStyle(DS.moon)
                Text("Today's Summary")
                    .font(DS.titleFont)
                Spacer()
                Text(String(format: "%.0fs", summary.processingSeconds))
                    .font(DS.microFont)
                    .foregroundStyle(.tertiary)
            }

            SummaryContent(summary: summary)
        }
        .mullCard()
    }

    // MARK: - Activity Heatmap (hourly)

    private var activityHeatmap: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("ACTIVITY")
                .sectionLabel()

            // 24-hour bar chart — bars share the column width so it never overflows the
            // narrow Settings pane.
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(hourly) { h in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor(intensity: h.intensity))
                            .frame(height: max(3, h.intensity * 50))
                            .frame(maxWidth: .infinity)

                        if h.hour % 6 == 0 {
                            Text("\(h.hour)")
                                .font(.system(size: 8))
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
            }
            .frame(height: 65)

            if let insight = InsightPhrases.activityInsight(hourly: hourly) {
                Text(insight)
                    .font(DS.captionFont)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .mullCard()
    }

    private func barColor(intensity: Double) -> Color {
        if intensity > 0.7 { return DS.moon }
        if intensity > 0.3 { return DS.moon.opacity(0.6) }
        return DS.moon.opacity(0.15)
    }

    // MARK: - Weekday Chart

    private var weekdayChart: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("WEEK")
                .sectionLabel()

            HStack(alignment: .bottom, spacing: DS.sm) {
                ForEach(weekday) { day in
                    VStack(spacing: DS.xs) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor(intensity: day.intensity))
                            .frame(height: max(4, day.intensity * 40))
                            .frame(maxWidth: .infinity)

                        Text(day.name)
                            .font(.system(size: 9))
                            .foregroundStyle(day.intensity > 0.7 ? .primary : .tertiary)
                    }
                }
            }
            .frame(height: 60)

            if let insight = InsightPhrases.weekdayInsight(weekday: weekday) {
                Text(insight)
                    .font(DS.captionFont)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .mullCard()
    }

    // MARK: - Language Mix

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("LANGUAGE")
                .sectionLabel()

            // Segmented bar
            GeometryReader { geo in
                HStack(spacing: 0) {
                    if langMix.japanesePercent > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DS.langJapanese.opacity(0.65))
                            .frame(width: geo.size.width * langMix.japanesePercent / 100)
                    }
                    if langMix.englishPercent > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DS.langEnglish.opacity(0.55))
                            .frame(width: geo.size.width * langMix.englishPercent / 100)
                    }
                    if langMix.codePercent > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DS.langCode.opacity(0.55))
                            .frame(width: geo.size.width * langMix.codePercent / 100)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 14)

            HStack(spacing: DS.md) {
                langLabel(color: DS.langJapanese, name: "日本語", pct: langMix.japanesePercent)
                langLabel(color: DS.langEnglish, name: "English", pct: langMix.englishPercent)
                langLabel(color: DS.langCode, name: "Code", pct: langMix.codePercent)
            }

            if let insight = InsightPhrases.languageInsight(mix: langMix) {
                Text(insight)
                    .font(DS.captionFont)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .mullCard()
    }

    private func langLabel(color: Color, name: String, pct: Double) -> some View {
        HStack(spacing: DS.xs) {
            Circle().fill(color.opacity(0.65)).frame(width: 6, height: 6)
            Text("\(name) \(String(format: "%.0f", pct))%")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - App Usage

    private var appUsageCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("APPS")
                .sectionLabel()

            ForEach(Array(appUsage.prefix(5))) { app in
                HStack(spacing: DS.sm) {
                    Text(app.appName)
                        .font(.system(size: 11))
                        .frame(width: 60, alignment: .leading)
                        .lineLimit(1)

                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(DS.moon.opacity(0.5))
                            .frame(width: geo.size.width * app.percentage / 100)
                    }
                    .frame(height: 8)

                    Text(String(format: "%.0f%%", app.percentage))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, alignment: .trailing)
                }
                .frame(height: 18)
            }

            if let insight = InsightPhrases.appUsageInsight(apps: appUsage) {
                Text(insight)
                    .font(DS.captionFont)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .mullCard()
    }

    // MARK: - Keywords

    private var keywordsCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("TOP KEYWORDS")
                .sectionLabel()

            if keywords.isEmpty {
                Text("Keywords appear after a few hours of recording")
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: DS.xs) {
                    ForEach(keywords.prefix(15)) { kw in
                        let maxCount = keywords.first?.count ?? 1
                        let intensity = Double(kw.count) / Double(max(maxCount, 1))

                        HStack(spacing: 3) {
                            Text(kw.word)
                                .font(.system(size: 11))
                            Text("\(kw.count)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, DS.sm)
                        .padding(.vertical, 3)
                        .background(DS.moon.opacity(intensity * 0.15 + 0.03))
                        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSm))
                    }
                }

                if let insight = InsightPhrases.keywordInsight(keywords: keywords) {
                    Text(insight)
                        .font(DS.captionFont)
                        .foregroundStyle(.secondary)
                        .italic()
                        .padding(.top, DS.xs)
                }
            }
        }
        .mullCard()
    }

    // MARK: - Memory Card

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack {
                Image(systemName: "brain")
                    .foregroundStyle(DS.moon)
                Text("What mull Knows")
                    .font(DS.titleFont)
            }

            if memories.isEmpty {
                VStack(spacing: DS.sm) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(.quaternary)
                    Text("mull will learn about you over time")
                        .font(DS.bodyFont)
                        .foregroundStyle(.tertiary)
                    Text("Memories are extracted after each nightly summary")
                        .font(DS.captionFont)
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.lg)
            } else {
                ForEach(memories) { memory in
                    HStack(alignment: .top, spacing: DS.sm) {
                        Text(memory.memoryType.rawValue)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, DS.sm)
                            .padding(.vertical, 2)
                            .background(DS.moon.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 3))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(memory.name)
                                .font(DS.bodyMedium)
                            Text(memory.description)
                                .font(DS.captionFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .mullCard()
    }
}
