import SwiftUI
import EventKit

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
    /// Open a date in the Calendar Day view — wired by the parent so a search hit can jump
    /// to the day it happened.
    var onOpenDay: (Date) -> Void = { _ in }
    @State private var debouncedQuery = ""
    @State private var projects: [ProjectSnapshot] = []
    @State private var weekDays: [DaySnapshot] = []
    @State private var weekComp: WeekComparison?
    @State private var behaviorPatterns: [BehaviorPattern] = []
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var isLoading = true
    @State private var hasLoadedOnce = false
    @State private var loadFailed = false

    // Search results are STATE, not derived in body: the three queries behind them
    // (event FTS, a 15-month EventKit scan, summary FTS) are blocking, and AppState
    // republishes every 3s — running them per body evaluation re-queried constantly.
    @State private var searchHits: [SearchHit] = []
    @State private var summaryHits: [DailySummary] = []
    @State private var searchRunning = false

    // Calendar reads are blocking EventKit round-trips; same reason they live here
    // rather than being called from body.
    @State private var todaySchedule: String?
    @State private var nextEvent: (title: String, start: Date, minutesUntil: Int)?
    @State private var todayEventCount = 0
    @State private var calendarAuthorized = true

    // Search filters — which kinds of hit to show, and how far back to look.
    @State private var enabledKinds: Set<SearchHit.Kind> = Set(SearchHit.Kind.allCases)
    @State private var timeRange: SearchRange = .all
    @State private var selectedApps: Set<String> = []   // empty = all apps

    var body: some View {
        ScrollView {
            if debouncedQuery.isEmpty {
                dashboardContent
                    .padding(.horizontal, DS.xl)
                    .padding(.vertical, DS.lg)
            } else {
                SearchResultsView(
                    query: debouncedQuery,
                    projects: projects,
                    hits: searchHits,
                    summaries: summaryHits,
                    isRunning: searchRunning,
                    enabledKinds: $enabledKinds,
                    timeRange: $timeRange,
                    selectedApps: $selectedApps,
                    onOpenDay: onOpenDay,
                    projectCard: { projectCard($0, expanded: true) }
                )
                .padding(.horizontal, DS.xl)
                .padding(.vertical, DS.lg)
            }
        }
        // Home is revisited constantly (Calendar → Home → Calendar). Re-running the
        // 14-day analysis is fine; replacing the loaded dashboard with a skeleton
        // every single time is not — so the skeleton is first-load only.
        .onAppear { refresh() }
        .task { await loadCalendar() }
        // Search runs here, keyed on the debounced query, instead of inside body.
        .task(id: debouncedQuery) { await runSearch(debouncedQuery) }
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

                ReportCardView()

                if !behaviorPatterns.isEmpty {
                    behaviorSection
                }

                if !projects.isEmpty {
                    projectsSection
                }

                if weekDays.contains(where: { $0.totalDuration > 0 }) {
                    WeekSection(days: weekDays, comparison: weekComp)
                }

                if let schedule = todaySchedule {
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
            // Date
            Text(Self.heroDate)
                .font(.system(size: 12, weight: .medium))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(DS.inkFaint)

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
        if let next = nextEvent, next.minutesUntil > 0 {
            let h = next.minutesUntil / 60, m = next.minutesUntil % 60
            let t = h > 0 ? "\(h)h\(m > 0 ? " \(m)m" : "")" : "\(m)m"
            return ("clock", "\(t) until \(next.title)")
        }
        // "Nothing upcoming" has three very different meanings, and claiming
        // "uninterrupted focus" for all of them was a lie in two of them.
        if !calendarAuthorized {
            return ("calendar.badge.exclamationmark", "Calendar not connected — mull can't see your schedule")
        }
        if todayEventCount > 0 {
            return ("checkmark.circle", "Meetings done for today — the rest is yours")
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
                    .foregroundStyle(DS.moon)
                Text(pattern.action)
                    .font(DS.bodyMedium)
                    .foregroundStyle(DS.moon)
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
        return DS.moon
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
                                .foregroundStyle(DS.moon)
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
                        .foregroundStyle(isLast ? DS.moon : .secondary)
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

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mullCard()
    }


    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DS.lg) {
            Image(systemName: "moon.stars")
                .font(DS.heroFont)
                .foregroundStyle(DS.moon.opacity(0.3))

            VStack(spacing: DS.xs) {
                // Two different silences: "not enough yet" vs "nothing was captured
                // at all", which usually means recording is off or permissions lapsed.
                Text(loadFailed && !appState.isRecording ? "Nothing recorded yet" : "Your dashboard is building")
                    .font(DS.titleFont)
                Text(loadFailed && !appState.isRecording
                     ? "mull isn't recording, so there's nothing to analyse. Check permissions in Settings → Data."
                     : "mull is recording your activity. Projects and insights will appear here as patterns emerge.")
                    .font(DS.bodyFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if loadFailed && !appState.isRecording {
                    Button("Open Settings") { AppDelegate.shared?.showSettings() }
                        .font(DS.captionFont)
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.moon)
                        .padding(.top, DS.sm)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    /// Run the search off the main thread and publish it into state. Three blocking
    /// sources — event FTS, a 15-month EventKit scan, and summary FTS — merged into
    /// one newest-first timeline, each hit carrying its own timestamp.
    private func runSearch(_ query: String) async {
        guard !query.isEmpty else {
            searchHits = []
            summaryHits = []
            searchRunning = false
            return
        }
        searchRunning = true
        let database = appState.database
        let calendarService = appState.calendar

        let (hits, summaries) = await Task.detached(priority: .userInitiated) {
            SearchService.gather(query: query, database: database, calendar: calendarService)
        }.value

        // A newer keystroke already cancelled this .task — don't publish stale hits.
        guard !Task.isCancelled else { return }
        searchHits = hits
        summaryHits = summaries
        searchRunning = false
    }

    /// Today's schedule + next meeting. EventKit calls block; keeping them out of
    /// body means they run once per appearance instead of once per redraw.
    private func loadCalendar() async {
        let calendarService = appState.calendar
        // macOS 14 is the deployment target, so full access is the only grant that
        // lets CalendarService read anything.
        let authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess

        let loaded = await Task.detached(priority: .userInitiated) {
            (schedule: calendarService.todaySchedule(),
             next: calendarService.upcomingEvents(limit: 1).first,
             todayCount: calendarService.events(for: Date()).count)
        }.value

        guard !Task.isCancelled else { return }
        calendarAuthorized = authorized
        todaySchedule = loaded.schedule
        nextEvent = loaded.next
        todayEventCount = loaded.todayCount
    }

    // MARK: - Data Loading

    private func refresh() {
        // Only the very first load shows the skeleton. Later appearances refresh
        // silently underneath the content that's already on screen.
        isLoading = !hasLoadedOnce

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
                // A pass that finds nothing at all is a real state (recording just
                // started, or capture is broken) — the empty view says so instead of
                // promising forever that the dashboard is "building".
                self.loadFailed = loadedProjects.isEmpty && loadedWeek.allSatisfy { $0.totalDuration == 0 }
                self.hasLoadedOnce = true
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

}
