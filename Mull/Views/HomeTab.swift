import SwiftUI

/// The Home dashboard — the "face" of mull.
///
/// Not a report. A decision engine.
/// Every element exists to change the user's next action.
///
/// Sections flow future → present → past:
///   1. Briefing — actionable outlook, not facts
///   2. Projects — narrative flow with stall detection
///   3. This Week — week-over-week comparison + deep work
///   4. Schedule — today's calendar
///   5. Activity — recent proof of life
struct HomeTab: View {
    @EnvironmentObject var appState: AppState
    @Binding var searchQuery: String
    @State private var debouncedQuery = ""
    @State private var projects: [ProjectSnapshot] = []
    @State private var weekDays: [DaySnapshot] = []
    @State private var weekComp: WeekComparison?
    @State private var behaviorPatterns: [BehaviorPattern] = []
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            if debouncedQuery.isEmpty {
                dashboardContent
                    .padding(.horizontal, DS.xl)
                    .padding(.vertical, DS.lg)
            } else {
                searchResultsContent
                    .padding(.horizontal, DS.xl)
                    .padding(.vertical, DS.lg)
            }
        }
        .onAppear { refresh() }
        .onChange(of: searchQuery) { _, newValue in
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                debouncedQuery = newValue
            }
        }
    }


    // MARK: - Dashboard Content

    @ViewBuilder
    private var dashboardContent: some View {
        VStack(spacing: DS.lg) {
            if let reason = appState.database.fallbackReason {
                databaseWarning(reason)
            }

            if let dirIssue = MullDirectory.issueDescription {
                databaseWarning(dirIssue)
            }

            if isLoading {
                loadingSkeleton
            } else {
                nocturneHero

                if !behaviorPatterns.isEmpty {
                    behaviorSection
                }

                if !projects.isEmpty {
                    projectsSection
                }

                if weekDays.contains(where: { $0.totalDuration > 0 }) {
                    weekSection
                }

                if let schedule = appState.calendar.todaySchedule() {
                    scheduleSection(schedule)
                }

                if projects.isEmpty && behaviorPatterns.isEmpty {
                    emptyState
                }
            }
        }
    }

    // MARK: - Nocturne Hero

    /// The hero surface: a quiet moonlit reflection — date, what you mostly did,
    /// recent work as strata bars, and where to resume.
    private var nocturneHero: some View {
        let top = Array(projects.prefix(3))
        let maxDur = max(top.map(\.totalDuration).max() ?? 1, 1)
        let mainName = top.first?.name

        return VStack(alignment: .leading, spacing: DS.lg) {
            // Date + moon
            HStack {
                Text(Self.heroDate)
                    .font(.system(size: 12, weight: .medium))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(DS.inkFaint)
                Spacer()
                Image(systemName: "moon.stars")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.moon.opacity(0.8))
            }

            // Headline
            VStack(alignment: .leading, spacing: DS.xs) {
                Text("Today")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(DS.ink)
                Text(mainName.map { "Mostly \($0)." } ?? "A quiet day so far.")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.inkDim)
            }

            // Focus line — next meeting / uninterrupted time (folded in from the
            // old Today's Briefing card). Extracted into its own builder to keep
            // this VStack within the type-checker's inference budget.
            focusLineView

            // Strata bars
            if !top.isEmpty {
                VStack(spacing: DS.sm) {
                    ForEach(top) { project in
                        strataRow(project, fraction: project.totalDuration / maxDur)
                    }
                }
                .padding(.top, DS.xs)
            }

            // Resume
            if let resume = top.first {
                HStack(spacing: DS.sm) {
                    Text("RESUME")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(DS.moon)
                    Text(resume.lastFile ?? resume.name)
                        .font(DS.bodyFont)
                        .foregroundStyle(DS.inkDim)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.top, DS.xs)
            }
        }
        .padding(DS.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusLg)
                .fill(DS.surface)
                .moonGlow(0.14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusLg)
                .strokeBorder(DS.moon.opacity(0.16), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusLg))
    }

    private func strataRow(_ project: ProjectSnapshot, fraction: Double) -> some View {
        HStack(spacing: DS.md) {
            Text(project.name)
                .font(DS.bodyFont)
                .foregroundStyle(DS.ink)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.hairline)
                        .frame(height: 4)
                    Capsule().fill(DS.accentGradient)
                        .frame(width: max(6, geo.size.width * fraction), height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 8)
            Text(project.totalDurationFormatted)
                .font(DS.microFont)
                .foregroundStyle(DS.inkFaint)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private static var heroDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: Date())
    }

    /// The focus-line row, or nothing. Kept as its own ViewBuilder so the hero's
    /// VStack stays simple enough to type-check.
    @ViewBuilder private var focusLineView: some View {
        if let focus = focusLine {
            HStack(spacing: DS.sm) {
                Image(systemName: focus.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.moon.opacity(0.8))
                    .frame(width: 14)
                Text(focus.text)
                    .font(DS.smallFont)
                    .foregroundStyle(DS.inkDim)
                Spacer()
            }
        }
    }

    /// Next meeting countdown, or uninterrupted-focus note. The one piece of the
    /// old Today's Briefing not already covered by the hero's resume point.
    private var focusLine: (icon: String, text: String)? {
        if let next = appState.calendar.upcomingEvents(limit: 1).first, next.minutesUntil > 0 {
            let h = next.minutesUntil / 60, m = next.minutesUntil % 60
            let t = h > 0 ? "\(h)h\(m > 0 ? " \(m)m" : "")" : "\(m)m"
            return ("clock", "\(t) until \(next.title)")
        }
        return ("bolt", "No meetings today — uninterrupted focus")
    }

    // MARK: - Behavior Patterns Section

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Text("PATTERNS")
                .sectionLabel()

            ForEach(behaviorPatterns.prefix(3)) { pattern in
                behaviorCard(pattern)
            }
        }
    }

    private func behaviorCard(_ pattern: BehaviorPattern) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            // Header with severity indicator
            HStack(spacing: DS.sm) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(severityColor(pattern.severity))
                    .frame(width: 4, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pattern.title)
                        .font(DS.bodyMedium)
                    Text(patternTypeLabel(pattern.type))
                        .font(DS.miniMedium)
                        .foregroundStyle(severityColor(pattern.severity))
                        .padding(.horizontal, DS.xs)
                        .padding(.vertical, 1)
                        .background(severityColor(pattern.severity).opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                Spacer()
            }

            // Insight — what the data shows
            Text(pattern.insight)
                .font(DS.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, DS.lg)

            // Action — what to do about it
            HStack(spacing: DS.sm) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(DS.captionFont)
                    .foregroundStyle(Color.accentColor)
                Text(pattern.action)
                    .font(DS.bodyMedium)
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, DS.lg)

            // Evidence — collapsed, for credibility
            Text(pattern.evidence)
                .font(DS.miniFont)
                .foregroundStyle(.quaternary)
                .padding(.leading, DS.lg)
        }
        .mullHeroCard()
    }

    private func severityColor(_ severity: Double) -> Color {
        if severity >= 0.8 { return DS.error }
        if severity >= 0.6 { return DS.paused }
        return Color.accentColor
    }

    private func patternTypeLabel(_ type: BehaviorPattern.PatternType) -> String {
        switch type {
        case .abandonment: "abandonment risk"
        case .peakWaste: "peak hour waste"
        case .focusDecline: "focus declining"
        case .avoidance: "avoidance detected"
        case .correlation: "pattern found"
        }
    }



    // MARK: - Projects Section

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            HStack {
                Text("PROJECTS")
                    .sectionLabel()
                Spacer()
                Text("\(projects.count) detected")
                    .font(DS.captionFont)
                    .foregroundStyle(.quaternary)
            }

            ForEach(projects.prefix(6)) { project in
                projectCard(project, expanded: false)
            }
        }
    }

    private func projectCard(_ project: ProjectSnapshot, expanded: Bool) -> some View {
        let isStale = project.daysSinceActive >= 3
        let sessions = project.sessions

        return VStack(alignment: .leading, spacing: DS.sm) {
            // Header
            HStack(alignment: .top) {
                HStack(spacing: DS.sm) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(project.color)
                        .frame(width: 4, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DS.xs) {
                            Text(project.name)
                                .font(DS.bodyMedium)
                                .lineLimit(1)

                            if isStale {
                                Text("stalled")
                                    .font(DS.miniMedium)
                                    .foregroundStyle(DS.paused)
                                    .padding(.horizontal, DS.xs)
                                    .padding(.vertical, 1)
                                    .background(DS.paused.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }

                        HStack(spacing: DS.xs) {
                            Text(project.primaryApp)
                                .font(DS.captionFont)
                                .foregroundStyle(.tertiary)
                            Text("·")
                                .foregroundStyle(.quaternary)
                            Text(project.totalDurationFormatted)
                                .font(DS.captionMedium)
                                .foregroundStyle(Color.accentColor)
                            Text("·")
                                .foregroundStyle(.quaternary)
                            Text(project.lastActiveFormatted)
                                .font(DS.captionFont)
                                .foregroundStyle(isStale ? DS.paused : Color.secondary)
                        }
                    }
                }

                Spacer()
            }

            // Resume point — the key context for returning to this project
            if project.lastFile != nil || project.lastClipboard != nil {
                VStack(alignment: .leading, spacing: DS.xs) {
                    if isStale || expanded {
                        Text("RESUME POINT")
                            .font(DS.miniBold)
                            .tracking(0.5)
                            .foregroundStyle(isStale ? DS.paused : Color.secondary.opacity(0.5))
                    }

                    if let file = project.lastFile {
                        HStack(spacing: DS.xs) {
                            Image(systemName: "doc.text")
                                .font(DS.miniFont)
                                .foregroundStyle(.tertiary)
                            Text(file)
                                .font(DS.captionFont)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if let clip = project.lastClipboard {
                        HStack(spacing: DS.xs) {
                            Image(systemName: "text.quote")
                                .font(DS.miniFont)
                                .foregroundStyle(.tertiary)
                            Text("\"\(clip)\"")
                                .font(DS.captionFont)
                                .foregroundStyle(.tertiary)
                                .italic()
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.leading, DS.lg)
            }

            // Session timeline — the narrative arc
            if !sessions.isEmpty && (expanded || sessions.count <= 5) {
                sessionTimeline(sessions: sessions, project: project, expanded: expanded)
            }
        }
        .mullCard()
    }

    private func sessionTimeline(sessions: [ProjectSession], project: ProjectSnapshot, expanded: Bool) -> some View {
        let displaySessions = expanded ? Array(sessions.prefix(10)) : Array(sessions.prefix(4))
        let avgDuration = sessions.reduce(0.0) { $0 + $1.duration } / Double(max(sessions.count, 1))

        return VStack(alignment: .leading, spacing: DS.xs) {
            Divider()

            HStack {
                Text("PROGRESS")
                    .font(DS.miniBold)
                    .tracking(0.5)
                    .foregroundStyle(.quaternary)

                Spacer()

                if sessions.count > 1 {
                    let avgMins = Int(avgDuration / 60)
                    Text("avg \(avgMins)m/session")
                        .font(DS.miniFont)
                        .foregroundStyle(.quaternary)
                }
            }

            ForEach(Array(displaySessions.reversed().enumerated()), id: \.offset) { index, session in
                let isLast = index == displaySessions.count - 1

                HStack(spacing: DS.sm) {
                    // Timeline dot + line
                    VStack(spacing: 0) {
                        if index > 0 {
                            Rectangle()
                                .fill(project.color.opacity(0.2))
                                .frame(width: 1, height: 6)
                        }
                        Circle()
                            .fill(isLast ? project.color : project.color.opacity(0.4))
                            .frame(width: isLast ? 7 : 5, height: isLast ? 7 : 5)
                        if !isLast {
                            Rectangle()
                                .fill(project.color.opacity(0.2))
                                .frame(width: 1, height: 6)
                        }
                    }
                    .frame(width: 12)

                    Text(session.dateFormatted)
                        .font(DS.microFont)
                        .foregroundStyle(isLast ? .secondary : .tertiary)
                        .frame(width: 65, alignment: .leading)

                    Text(session.durationFormatted)
                        .font(DS.microFont)
                        .foregroundStyle(isLast ? Color.accentColor : .secondary)
                        .frame(width: 40, alignment: .trailing)

                    if !session.mainLabel.isEmpty && session.mainLabel != project.name {
                        Text(session.mainLabel)
                            .font(DS.captionFont)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    if isLast && project.daysSinceActive >= 3 {
                        Text("← here")
                            .font(DS.miniMedium)
                            .foregroundStyle(DS.paused)
                    }
                }
            }
        }
        .padding(.leading, DS.lg)
    }

    // MARK: - Week Section

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Text("THIS WEEK")
                .sectionLabel()

            // Day bars
            HStack(spacing: DS.sm) {
                ForEach(weekDays) { day in
                    weekDayColumn(day)
                }
            }

            // Week-over-week comparison
            if let comp = weekComp {
                Divider()

                weekComparisonView(comp)
            }
        }
        .mullCard()
    }

    private func weekDayColumn(_ day: DaySnapshot) -> some View {
        let maxDuration = weekDays.map(\.totalDuration).max() ?? 1
        let barHeight = day.totalDuration > 0 ? max(6, day.totalDuration / maxDuration * 60) : 3

        return VStack(spacing: DS.xs) {
            Text(day.mainProject ?? "")
                .font(DS.tinyFont)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(height: 10)

            Text(day.durationFormatted)
                .font(DS.miniMedium)
                .foregroundStyle(day.isToday ? Color.accentColor : .secondary)
                .frame(height: 12)

            RoundedRectangle(cornerRadius: 3)
                .fill(day.isToday ? Color.accentColor : Color.accentColor.opacity(day.totalDuration > 0 ? 0.4 : 0.08))
                .frame(height: barHeight)

            Text(day.dayName)
                .font(day.isToday ? Font.system(size: 10, weight: .bold) : DS.microFont)
                .foregroundStyle(day.isToday ? .primary : .tertiary)

            Text(day.dayNumber)
                .font(DS.miniFont)
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity)
    }

    private func weekComparisonView(_ comp: WeekComparison) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            // Duration comparison
            HStack(spacing: DS.md) {
                compStat(
                    label: "This week",
                    value: comp.thisWeekHours,
                    delta: comp.lastWeekDuration > 0 ? comp.deltaFormatted : nil,
                    deltaUp: comp.durationDelta >= 0
                )

                compStat(
                    label: "Last week (same point)",
                    value: comp.lastWeekHours,
                    delta: nil,
                    deltaUp: true
                )
            }

            // Deep work + context switches
            HStack(spacing: DS.md) {
                let deepDelta = comp.thisWeekDeepBlocks - comp.lastWeekDeepBlocks
                compStat(
                    label: "Deep work (2h+)",
                    value: "\(comp.thisWeekDeepBlocks) blocks",
                    delta: deepDelta != 0 ? (deepDelta > 0 ? "+\(deepDelta)" : "\(deepDelta)") : nil,
                    deltaUp: deepDelta >= 0
                )

                let switchDelta = comp.thisWeekContextSwitches - comp.lastWeekContextSwitches
                let switchPct = comp.lastWeekContextSwitches > 0
                    ? Int(Double(switchDelta) / Double(comp.lastWeekContextSwitches) * 100)
                    : 0
                compStat(
                    label: "Context switches",
                    value: "\(comp.thisWeekContextSwitches)",
                    delta: switchPct != 0 ? (switchPct > 0 ? "+\(switchPct)%" : "\(switchPct)%") : nil,
                    deltaUp: switchDelta <= 0 // fewer switches is better
                )
            }
        }
    }

    private func compStat(label: String, value: String, delta: String?, deltaUp: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DS.miniFont)
                .foregroundStyle(.quaternary)

            HStack(spacing: DS.xs) {
                Text(value)
                    .font(DS.bodyMedium)
                    .foregroundStyle(.primary)

                if let delta {
                    Text(delta)
                        .font(DS.microFont)
                        .foregroundStyle(deltaUp ? DS.recording : DS.paused)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Schedule Section

    private func scheduleSection(_ schedule: String) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("SCHEDULE")
                .sectionLabel()

            let lines = schedule.components(separatedBy: "\n").dropFirst()
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


    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DS.lg) {
            Image(systemName: "moon.stars")
                .font(DS.heroFont)
                .foregroundStyle(Color.accentColor.opacity(0.3))

            VStack(spacing: DS.xs) {
                Text("Your dashboard is building")
                    .font(DS.titleFont)
                Text("mull is recording your activity. Projects and insights will appear here as patterns emerge.")
                    .font(DS.bodyFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Search Results

    @ViewBuilder
    private var searchResultsContent: some View {
        let query = debouncedQuery.lowercased()

        let matchingProjects = projects.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.primaryApp.localizedCaseInsensitiveContains(query) ||
            ($0.lastFile?.localizedCaseInsensitiveContains(query) ?? false)
        }

        VStack(spacing: DS.lg) {
            if !matchingProjects.isEmpty {
                VStack(alignment: .leading, spacing: DS.md) {
                    Text("PROJECTS")
                        .sectionLabel()

                    ForEach(matchingProjects) { project in
                        projectCard(project, expanded: true)
                    }
                }
            }

            let eventResults = appState.database.searchEvents(query: debouncedQuery, limit: 50)
            if !eventResults.isEmpty {
                eventSearchResults(eventResults)
            }

            let summaryResults = appState.database.searchSummaries(query: debouncedQuery)
            if !summaryResults.isEmpty {
                summarySearchResults(summaryResults)
            }

            if matchingProjects.isEmpty && eventResults.isEmpty && summaryResults.isEmpty {
                VStack(spacing: DS.md) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.heroFont)
                        .foregroundStyle(.quaternary)
                    Text("No results for \"\(debouncedQuery)\"")
                        .font(DS.bodyFont)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            }
        }
    }

    private func eventSearchResults(_ events: [RecordingEvent]) -> some View {
        let grouped = Dictionary(grouping: events) { event in
            Calendar.current.startOfDay(for: event.timestamp)
        }
        let sortedDates = grouped.keys.sorted().reversed()

        return VStack(alignment: .leading, spacing: DS.md) {
            Text("EVENTS")
                .sectionLabel()

            ForEach(Array(sortedDates), id: \.self) { date in
                VStack(alignment: .leading, spacing: DS.xs) {
                    let f = DateFormatter()
                    let _ = f.dateFormat = "M/d (EEEE)"
                    Text(f.string(from: date))
                        .font(DS.captionMedium)
                        .foregroundStyle(.secondary)

                    ForEach(Array((grouped[date] ?? []).prefix(5).enumerated()), id: \.offset) { _, event in
                        HStack(spacing: DS.sm) {
                            Text(formatTime(event.timestamp))
                                .font(DS.microFont)
                                .foregroundStyle(.quaternary)
                                .frame(width: 48, alignment: .trailing)

                            Circle()
                                .fill(eventColor(event.eventType))
                                .frame(width: 4, height: 4)

                            VStack(alignment: .leading, spacing: 0) {
                                if let app = event.appName {
                                    Text(app)
                                        .font(DS.miniMedium)
                                        .foregroundStyle(.tertiary)
                                }
                                Text(event.textContent.map { String($0.prefix(80)).replacingOccurrences(of: "\n", with: " ") } ?? "")
                                    .font(DS.captionFont)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }

                            Spacer()
                        }
                    }
                }
                .mullCard()
            }
        }
    }

    private func summarySearchResults(_ summaries: [DailySummary]) -> some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Text("SUMMARIES")
                .sectionLabel()

            ForEach(summaries.prefix(5)) { summary in
                VStack(alignment: .leading, spacing: DS.sm) {
                    Text(summary.dateFormatted)
                        .font(DS.bodyMedium)
                    Text(summary.preview)
                        .font(DS.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .mullCard()
            }
        }
    }

    // MARK: - Data Loading

    private func refresh() {
        isLoading = true

        Task.detached { [database = appState.database] in
            let engine = TimeBlockEngine(database: database)
            let loadedProjects = engine.projectSnapshots(days: 14)
            let loadedWeek = engine.weekSnapshots()
            let loadedComp = engine.weekComparison()
            let loadedPatterns = BehaviorPatternEngine(database: database).detectPatterns()

            await MainActor.run {
                self.projects = loadedProjects
                self.weekDays = loadedWeek
                self.weekComp = loadedComp
                self.behaviorPatterns = loadedPatterns
                self.isLoading = false
            }
        }
    }


    // MARK: - Loading Skeleton

    private var loadingSkeleton: some View {
        VStack(spacing: DS.lg) {
            // Briefing skeleton
            skeletonCard(lines: 3, heroStyle: true)

            // Projects skeleton
            VStack(alignment: .leading, spacing: DS.md) {
                skeletonLabel
                skeletonCard(lines: 2)
                skeletonCard(lines: 2)
            }

            // Week skeleton
            VStack(alignment: .leading, spacing: DS.md) {
                skeletonLabel
                HStack(spacing: DS.sm) {
                    ForEach(0..<7, id: \.self) { _ in
                        VStack(spacing: DS.xs) {
                            skeletonBar(width: nil, height: 12)
                            skeletonBar(width: nil, height: CGFloat.random(in: 15...50))
                            skeletonBar(width: nil, height: 10)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .mullCard()
            }
        }
        .redacted(reason: .placeholder)
        .shimmer()
    }

    private func skeletonCard(lines: Int, heroStyle: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            ForEach(0..<lines, id: \.self) { i in
                skeletonBar(
                    width: i == 0 ? nil : CGFloat.random(in: 120...220),
                    height: i == 0 ? 14 : 10
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(heroStyle ? AnyViewModifier(mullHeroCardModifier()) : AnyViewModifier(mullCardModifier()))
    }

    private var skeletonLabel: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.primary.opacity(0.06))
            .frame(width: 80, height: 10)
    }

    private func skeletonBar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.primary.opacity(0.06))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    // MARK: - Database Warning

    private func databaseWarning(_ reason: String) -> some View {
        HStack(spacing: DS.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.paused)
            VStack(alignment: .leading, spacing: 2) {
                Text("Database Issue")
                    .font(DS.bodyMedium)
                Text(reason)
                    .font(DS.captionFont)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(DS.md)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusSm)
                .fill(DS.paused.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusSm)
                .strokeBorder(DS.paused.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private func eventColor(_ type: RecordingEvent.EventType) -> Color {
        switch type {
        case .keystroke: DS.eventKeystroke
        case .clipboard: DS.eventClipboard
        case .screenText: DS.eventWindow
        case .appSwitch: DS.eventApp
        case .audio: DS.eventAudio
        }
    }
}
