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

    // Today's report — the understudy's draft, in your voice.
    @State private var reportDraft: String? = nil
    @State private var reportLoading = false
    @State private var reportEditing = false
    @State private var reportBuffer = ""
    @State private var reportCopied = false
    @State private var reportError: String? = nil
    @State private var reportSources: [String] = []
    private var reportWriter: ReportWriter { ReportWriter(database: appState.database) }
    // @AppStorage, not a bare UserDefaults read: a raw read isn't observable, so
    // switching a provider on in Settings left the "LLM is off" card up until some
    // unrelated state change happened to redraw Home.
    @AppStorage("llmProvider") private var llmProvider = "off"
    private var isLLMOff: Bool { llmProvider == "off" }

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
                searchResultsContent
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
        // The understudy finished tonight's draft while Home was already open — show it
        // (only if the user hasn't generated/edited something themselves meanwhile).
        .onChange(of: appState.eveningDraftReady) { _, _ in
            if reportDraft == nil, !reportLoading, !reportEditing,
               let cached = reportWriter.cachedDraft(for: Date()) {
                withAnimation(.easeOut(duration: 0.25)) {
                    reportDraft = cached.text
                    reportSources = cached.sources
                }
            }
        }
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

                reportCard

                if !behaviorPatterns.isEmpty {
                    behaviorSection
                }

                if !projects.isEmpty {
                    projectsSection
                }

                if weekDays.contains(where: { $0.totalDuration > 0 }) {
                    weekSection
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

    // MARK: - Week Section

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Text("THIS WEEK")
                .sectionLabel()

            // Day bars
            HStack(alignment: .bottom, spacing: DS.sm) {
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
        let maxBar: CGFloat = 60
        let maxDuration = weekDays.map(\.totalDuration).max() ?? 1
        let barHeight = day.totalDuration > 0 ? max(6, day.totalDuration / maxDuration * maxBar) : 3

        return VStack(spacing: DS.xs) {
            Text(day.mainProject ?? "")
                .font(DS.tinyFont)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(height: 10)

            Text(day.durationFormatted)
                .font(DS.miniMedium)
                .foregroundStyle(day.isToday ? DS.moon : .secondary)
                .frame(height: 12)

            // Fixed-height track with the bar pinned to the bottom, so every bar grows
            // upward from a shared zero baseline (not centred, which made them spill both ways).
            ZStack(alignment: .bottom) {
                Color.clear.frame(height: maxBar)
                RoundedRectangle(cornerRadius: 3)
                    .fill(day.isToday ? DS.moon : DS.moon.opacity(day.totalDuration > 0 ? 0.4 : 0.08))
                    .frame(height: barHeight)
            }

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

    // MARK: - Today's report (the understudy's draft)

    @ViewBuilder
    private var reportCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack {
                Text("TODAY, IN YOUR WORDS").sectionLabel()
                Spacer()
                if reportDraft != nil && !reportEditing && !reportLoading {
                    Button { generateReport() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.inkFaint)
                    .help("Re-draft in my voice")
                }
            }

            if let err = reportError, !reportLoading {
                HStack(spacing: DS.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(DS.paused)
                    Text(err)
                        .font(DS.captionFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { generateReport() }
                        .font(DS.captionFont).buttonStyle(.plain).foregroundStyle(DS.moon)
                }
                .padding(DS.sm)
                .background(RoundedRectangle(cornerRadius: DS.radiusSm).fill(DS.paused.opacity(0.08)))
            }

            if isLLMOff {
                reportLLMOff
            } else if reportLoading {
                HStack(spacing: DS.sm) {
                    ProgressView().controlSize(.small)
                    Text("Your understudy is drafting…")
                        .font(DS.captionFont).foregroundStyle(.secondary)
                }
                .padding(.vertical, DS.xs)
            } else if reportEditing {
                VStack(alignment: .leading, spacing: DS.sm) {
                    TextEditor(text: $reportBuffer)
                        .font(DS.readFont)
                        .foregroundStyle(DS.ink)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160)
                    HStack {
                        Spacer()
                        Button("Cancel") { reportEditing = false }
                            .buttonStyle(.plain).font(DS.captionFont).foregroundStyle(.secondary)
                        Button("Save") { saveReport() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            } else if let draft = reportDraft, !draft.isEmpty {
                MarkdownView(draft, titleFirstLine: false)
                    .textSelection(.enabled)
                // Dignity: the understudy says what it learned the voice from.
                if !reportSources.isEmpty {
                    Text("Voice learned from: " + reportSources.joined(separator: " · "))
                        .font(DS.miniFont)
                        .foregroundStyle(.quaternary)
                }

                HStack(spacing: DS.md) {
                    Button { reportBuffer = draft; reportEditing = true } label: {
                        Label("Edit", systemImage: "pencil").font(DS.captionFont)
                    }
                    .buttonStyle(.plain).foregroundStyle(DS.moon)

                    Button { copyReport(draft) } label: {
                        Label(reportCopied ? "Copied" : "Copy", systemImage: reportCopied ? "checkmark" : "doc.on.clipboard")
                            .font(DS.captionFont)
                    }
                    .buttonStyle(.plain).foregroundStyle(DS.moon)

                    Spacer()
                    Text("drafted from today's activity · you send it")
                        .font(DS.miniFont).foregroundStyle(.quaternary)
                }
            } else {
                VStack(alignment: .leading, spacing: DS.sm) {
                    Text("Let your understudy draft today's report in your voice.")
                        .font(DS.bodyFont).foregroundStyle(.secondary)
                    Button { generateReport() } label: {
                        Label("Write today's report", systemImage: "sparkle")
                            .font(DS.bodyMedium)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mullCard()
    }

    private var reportLLMOff: some View {
        HStack(spacing: DS.sm) {
            Image(systemName: "moon.zzz").foregroundStyle(DS.paused)
            Text("Turn on a provider to let your understudy draft this.")
                .font(DS.captionFont).foregroundStyle(.secondary)
            Spacer()
            Button("Open Settings") { AppDelegate.shared?.showSettings() }
                .font(DS.captionFont).buttonStyle(.plain).foregroundStyle(DS.moon)
        }
        .padding(.vertical, DS.xs)
    }

    private func generateReport() {
        reportLoading = true
        reportEditing = false
        reportError = nil
        reportDraft = nil
        reportSources = []
        Task {
            // Tokens used to be appended from one unstructured Task each. Unstructured
            // tasks carry no ordering guarantee, so chunks could be applied out of
            // sequence and the draft rendered scrambled. A single stream with one
            // consumer serialises the appends in arrival order.
            let (tokens, continuation) = AsyncStream<String>.makeStream()
            let consumer = Task { @MainActor in
                for await piece in tokens {
                    // The spinner yields to live text on the first token.
                    if reportLoading { reportLoading = false }
                    reportDraft = (reportDraft ?? "") + piece
                }
            }

            do {
                let draft = try await reportWriter.draft(for: Date(), onToken: { piece in
                    continuation.yield(piece)
                })
                continuation.finish()
                await consumer.value   // let every queued token land before we settle
                await MainActor.run {
                    reportDraft = draft.text
                    reportSources = draft.sources
                    reportLoading = false
                    reportWriter.cacheDraft(draft, for: Date())   // survive an app restart
                }
            } catch {
                continuation.finish()
                await consumer.value
                // Never fail silently: the understudy says why it couldn't draft.
                await MainActor.run {
                    reportError = error.localizedDescription
                    reportLoading = false
                    reportDraft = nil
                }
            }
        }
    }

    private func saveReport() {
        reportWriter.save(reportBuffer, for: Date())
        reportDraft = reportBuffer
        reportEditing = false
    }

    private func copyReport(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { reportCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            await MainActor.run { withAnimation { reportCopied = false } }
        }
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

    // MARK: - Search Results

    @ViewBuilder
    private var searchResultsContent: some View {
        let query = debouncedQuery

        let matchingProjects = projects.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.primaryApp.localizedCaseInsensitiveContains(query) ||
            ($0.lastFile?.localizedCaseInsensitiveContains(query) ?? false)
        }

        // One chronological history: typed text, copied text, window/app activity AND
        // calendar schedule, merged and sorted newest-first — so the answer to "when did
        // this word appear?" is the timeline itself.
        let allHits = searchHits
        let ranged = allHits.filter { $0.date >= timeRange.cutoff }
        let counts = Dictionary(grouping: ranged, by: \.kind).mapValues(\.count)
        let appCounts = appCountMap(ranged)
        let shown = ranged.filter { enabledKinds.contains($0.kind) && appPass($0) }
        let summaryResults = summaryHits

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

            if !allHits.isEmpty {
                filterBar(counts: counts, appCounts: appCounts)
                if shown.isEmpty {
                    Text("No matches with these filters")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.lg)
                } else {
                    timelineResults(shown)
                }
            }

            if !summaryResults.isEmpty {
                summarySearchResults(summaryResults)
            }

            if matchingProjects.isEmpty && allHits.isEmpty && summaryResults.isEmpty && searchRunning {
                // Searching now runs off-thread, so "nothing yet" must not read as
                // "nothing found" while the query is still in flight.
                HStack(spacing: DS.sm) {
                    ProgressView().controlSize(.small)
                    Text("Searching your record…")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else if matchingProjects.isEmpty && allHits.isEmpty && summaryResults.isEmpty {
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

        let (hits, summaries) = await Task.detached(priority: .userInitiated) { () -> ([SearchHit], [DailySummary]) in
            var hits: [SearchHit] = []
            for e in database.searchEvents(query: query, limit: 80) {
                let kind = SearchHit.Kind(e.eventType)
                hits.append(SearchHit(id: e.id.map { "e\($0)" } ?? "e\(e.timestamp.timeIntervalSince1970)-\(kind)",
                                      date: e.timestamp, kind: kind,
                                      app: e.appName, detail: e.appName, text: e.textContent ?? ""))
            }
            for c in calendarService.searchEvents(query: query) {
                hits.append(SearchHit(id: "c\(c.start.timeIntervalSince1970)-\(c.title)",
                                      date: c.start, kind: .schedule, app: nil,
                                      detail: (c.location?.isEmpty == false ? c.location : c.timeFormatted),
                                      text: c.title))
            }
            return (hits.sorted { $0.date > $1.date }, database.searchSummaries(query: query))
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

    /// Filter controls: a time-range segment + per-kind toggle chips with live counts.
    /// Tightening the period or turning off "Typed" is the fastest way to cut noise.
    private func filterBar(counts: [SearchHit.Kind: Int], appCounts: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Picker("", selection: $timeRange) {
                ForEach(SearchRange.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360, alignment: .leading)

            let kinds = SearchHit.Kind.allCases.filter { (counts[$0] ?? 0) > 0 }
            if !kinds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.sm) {
                        ForEach(kinds, id: \.self) { kind in
                            kindChip(kind, count: counts[kind] ?? 0)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            // Top apps in this period — tap to narrow to "Xcode only", etc.
            let apps = appCounts.sorted { $0.value > $1.value }.prefix(8)
            if !apps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.sm) {
                        if !selectedApps.isEmpty {
                            Button { withAnimation(.easeOut(duration: 0.15)) { selectedApps.removeAll() } } label: {
                                Text("All apps").font(DS.miniMedium).foregroundStyle(DS.moon)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Capsule().fill(DS.moon.opacity(0.10)))
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(Array(apps), id: \.key) { app, count in
                            appChip(app, count: count)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func appChip(_ app: String, count: Int) -> some View {
        let on = selectedApps.contains(app)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if on { selectedApps.remove(app) } else { selectedApps.insert(app) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "app.dashed").font(.system(size: 8))
                Text(app).font(DS.miniMedium)
                Text("\(count)").font(DS.miniFont)
                    .foregroundStyle(on ? DS.moon.opacity(0.7) : DS.inkFaint)
            }
            .foregroundStyle(on ? DS.moon : DS.inkDim)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(on ? DS.moon.opacity(0.16) : DS.surface))
            .overlay(Capsule().strokeBorder(on ? DS.moon.opacity(0.3) : DS.hairline, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
    }

    /// Tally hits per owning app (events only) — drives the app filter chips' counts.
    private func appCountMap(_ hits: [SearchHit]) -> [String: Int] {
        var m: [String: Int] = [:]
        for h in hits { if let a = h.app, !a.isEmpty { m[a, default: 0] += 1 } }
        return m
    }

    /// A hit passes the app filter when no app is selected, or it belongs to a selected app.
    /// Calendar hits (no app) are excluded once a specific app is chosen — "Xcode only" means
    /// only Xcode's activity.
    private func appPass(_ hit: SearchHit) -> Bool {
        guard !selectedApps.isEmpty else { return true }
        guard let app = hit.app else { return false }
        return selectedApps.contains(app)
    }

    private func kindChip(_ kind: SearchHit.Kind, count: Int) -> some View {
        let on = enabledKinds.contains(kind)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if on { enabledKinds.remove(kind) } else { enabledKinds.insert(kind) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: kind.icon).font(.system(size: 8))
                Text(kind.label).font(DS.miniMedium)
                Text("\(count)").font(DS.miniFont)
                    .foregroundStyle(on ? kind.color.opacity(0.7) : DS.inkFaint)
            }
            .foregroundStyle(on ? kind.color : DS.inkFaint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(on ? kind.color.opacity(0.16) : DS.surface))
            .overlay(Capsule().strokeBorder(on ? kind.color.opacity(0.3) : DS.hairline, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .help(on ? "Hide \(kind.label)" : "Show \(kind.label)")
    }

    private func timelineResults(_ hits: [SearchHit]) -> some View {
        let grouped = Dictionary(grouping: hits) { Calendar.current.startOfDay(for: $0.date) }
        let days = grouped.keys.sorted(by: >)

        return VStack(alignment: .leading, spacing: DS.md) {
            Text("TIMELINE")
                .sectionLabel()

            ForEach(days, id: \.self) { day in
                VStack(alignment: .leading, spacing: DS.xs) {
                    Text(dayLabel(day))
                        .font(DS.captionMedium)
                        .foregroundStyle(.secondary)

                    ForEach((grouped[day] ?? []).sorted { $0.date > $1.date }.prefix(8)) { hit in
                        timelineRow(hit)
                    }
                }
                .mullCard()
            }
        }
    }

    private func timelineRow(_ hit: SearchHit) -> some View {
        Button { onOpenDay(hit.date) } label: {
            HStack(alignment: .top, spacing: DS.sm) {
                Text(formatTime(hit.date))
                    .font(DS.microFont)
                    .foregroundStyle(.quaternary)
                    .frame(width: 48, alignment: .trailing)

                kindBadge(hit.kind)

                VStack(alignment: .leading, spacing: 1) {
                    if let detail = hit.detail, !detail.isEmpty {
                        Text(detail)
                            .font(DS.miniMedium)
                            .foregroundStyle(.tertiary)
                    }
                    Text(hit.text.isEmpty ? AttributedString("—") : highlighted(hit.text))
                        .font(DS.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(dayLabel(Calendar.current.startOfDay(for: hit.date))) in Calendar")
    }

    /// Render the matched text with the query terms emphasised (moonlight, semibold), so the
    /// eye lands on *why* this row matched. Case-insensitive; capped to keep rows compact.
    private func highlighted(_ raw: String) -> AttributedString {
        let text = String(raw.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        var result = AttributedString(text)
        let terms = debouncedQuery.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        for term in terms {
            var from = text.startIndex
            while let r = text.range(of: term, options: .caseInsensitive, range: from..<text.endIndex) {
                if let lo = AttributedString.Index(r.lowerBound, within: result),
                   let hi = AttributedString.Index(r.upperBound, within: result) {
                    result[lo..<hi].foregroundColor = DS.moon
                    result[lo..<hi].font = .system(size: 11, weight: .semibold)
                }
                from = r.upperBound
            }
        }
        return result
    }

    /// A small coloured pill naming the kind of hit (Typed / Copied / Window / Schedule…).
    private func kindBadge(_ kind: SearchHit.Kind) -> some View {
        HStack(spacing: 3) {
            Image(systemName: kind.icon).font(.system(size: 8))
            Text(kind.label).font(DS.miniMedium)
        }
        .foregroundStyle(kind.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(kind.color.opacity(0.14)))
        .fixedSize()
    }

    /// Today / Yesterday / "M/d (EEEE)" — the day header for a timeline group.
    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "M/d (EEEE)"
        return f.string(from: day)
    }

    private func summarySearchResults(_ summaries: [DailySummary]) -> some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Text("SUMMARIES")
                .sectionLabel()

            ForEach(summaries.prefix(5)) { summary in
                Button { onOpenDay(summary.date) } label: {
                    VStack(alignment: .leading, spacing: DS.sm) {
                        Text(summary.dateFormatted)
                            .font(DS.bodyMedium)
                        Text(summary.preview)
                            .font(DS.captionFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .mullCard()
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Data Loading

    private func refresh() {
        // Only the very first load shows the skeleton. Later appearances refresh
        // silently underneath the content that's already on screen.
        isLoading = !hasLoadedOnce
        // An approved report wins; else tonight's cached auto-draft (先回り — it's
        // already there when you open mull in the evening).
        if let approved = reportWriter.saved(for: Date()) {
            reportDraft = approved
            reportSources = []
        } else if let cached = reportWriter.cachedDraft(for: Date()) {
            reportDraft = cached.text
            reportSources = cached.sources
        }

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

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

}

// MARK: - Search filters

/// How far back the timeline reaches. Future-dated calendar matches always pass (they sit
/// above "now"), so this is effectively a lower bound on the past.
private enum SearchRange: String, CaseIterable, Hashable {
    case all, today, week, month, year

    var label: String {
        switch self {
        case .all: "All"
        case .today: "Today"
        case .week: "7d"
        case .month: "30d"
        case .year: "1y"
        }
    }

    var cutoff: Date {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .all: return .distantPast
        case .today: return cal.startOfDay(for: now)
        case .week: return cal.date(byAdding: .day, value: -7, to: now) ?? .distantPast
        case .month: return cal.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        case .year: return cal.date(byAdding: .year, value: -1, to: now) ?? .distantPast
        }
    }
}

// MARK: - Search hit

/// One match in the unified search timeline — a captured event or a calendar entry,
/// reduced to what the result row needs: when it happened, what kind it is, and the text.
private struct SearchHit: Identifiable {
    /// Derived from the underlying row (event id, or calendar start + title) — NOT a
    /// fresh UUID. A minted-per-render identity made ForEach tear down and rebuild
    /// every result row on each redraw, dropping any text selection in progress.
    let id: String
    let date: Date
    let kind: Kind
    let app: String?        // owning app (events); nil for calendar — used by the app filter
    let detail: String?     // app name, or a calendar event's location / time range
    let text: String        // matched content, or the event title

    enum Kind: CaseIterable, Hashable {
        case typed, copied, window, document, app, audio, schedule

        init(_ type: RecordingEvent.EventType) {
            switch type {
            case .keystroke: self = .typed
            case .clipboard: self = .copied
            case .screenText: self = .window
            case .windowBody: self = .document
            case .appSwitch: self = .app
            case .audio: self = .audio
            }
        }

        var label: String {
            switch self {
            case .typed: "Typed"
            case .copied: "Copied"
            case .window: "Window"
            case .document: "Document"
            case .app: "App"
            case .audio: "Audio"
            case .schedule: "Schedule"
            }
        }

        var icon: String {
            switch self {
            case .typed: "keyboard"
            case .copied: "doc.on.clipboard"
            case .window: "macwindow"
            case .document: "doc.text"
            case .app: "app.dashed"
            case .audio: "waveform"
            case .schedule: "calendar"
            }
        }

        var color: Color {
            switch self {
            case .typed: DS.eventKeystroke
            case .copied: DS.eventClipboard
            case .window: DS.eventWindow
            case .document: DS.taupe
            case .app: DS.eventApp
            case .audio: DS.eventAudio
            case .schedule: DS.moon
            }
        }
    }
}
