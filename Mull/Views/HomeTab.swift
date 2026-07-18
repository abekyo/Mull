import SwiftUI
import EventKit
import AppKit

/// Home — the "face" of mull.
///
/// Not an instrument panel. The study you come back to: what is being held
/// for you today, laid out so you can pick the thread back up.
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

    // Search results are STATE, not derived in body: the three queries behind them
    // (event FTS, a 15-month EventKit scan, summary FTS) are blocking, and AppState
    // republishes every 3s — running them per body evaluation re-queried constantly.
    @State private var searchHits: [SearchHit] = []
    @State private var summaryHits: [DailySummary] = []
    @State private var searchRunning = false
    /// The query the hits on screen were actually computed from. Results and the
    /// text they are highlighted against have to move together, or a re-run shows
    /// yesterday's answers underlined with today's question.
    @State private var resultsQuery = ""
    /// The range those results were fetched with — paired with resultsQuery so the
    /// view can tell "these hits match what is on screen" from "these are stale".
    @State private var resultsRange: SearchRange = .all

    // Calendar reads are blocking EventKit round-trips; same reason they live here
    // rather than being called from body.
    //
    // These are the structured events straight from EventKit — not the markdown
    // summary CalendarService also produces. That string exists for AI context
    // files; re-parsing it back into rows here mangled any title containing a
    // hyphen ("Sprint - retro" → "Sprintretro").
    @State private var todayEvents: [CalendarEvent] = []
    @State private var nextEvent: (title: String, start: Date, minutesUntil: Int)?
    @State private var calendarAuthorized = true

    // Disclosure / expansion state — nothing here is truncated silently, so the
    // view has to remember what the reader chose to open.
    @State private var showAllProjects = false
    @State private var showAllPatterns = false
    @State private var revealedDiagnostics: Set<String> = []
    @State private var directoryIssue: String? = MullDirectory.issueDescription

    /// When the analysis on screen was computed. Home used to refresh only on
    /// navigation and never said how old it was.
    @State private var lastRefreshed: Date?
    @State private var isRefreshing = false

    // Search filters — which kinds of hit to show, and how far back to look.
    @State private var enabledKinds: Set<SearchHit.Kind> = Set(SearchHit.Kind.allCases)
    @State private var timeRange: SearchRange = .all
    @State private var selectedApps: Set<String> = []   // empty = all apps

    var body: some View {
        ScrollView {
            if debouncedQuery.isEmpty {
                homeContent
                    .padding(.horizontal, DS.xl)
                    .padding(.vertical, DS.lg)
            } else {
                SearchResultsView(
                    query: debouncedQuery,
                    projects: projects,
                    // Stale hits are dropped the moment the question changes.
                    // Showing them highlighted against the new query would be the
                    // app asserting an answer it has not computed yet.
                    hits: resultsAreCurrent ? searchHits : [],
                    summaries: resultsAreCurrent ? summaryHits : [],
                    isRunning: searchRunning || !resultsAreCurrent,
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
        // 14-day analysis is fine; replacing the loaded page with a skeleton
        // every single time is not — so the skeleton is first-load only.
        .onAppear { refreshIfStale() }
        // Coming back to the app is the honest moment to re-read: you were away,
        // the record moved on. Quietly, underneath what is already drawn.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshIfStale()
        }
        .task { await loadCalendar() }
        // Search runs here, keyed on the debounced query, instead of inside body.
        // Keyed on the range too: it is part of the query now, so changing it has to
        // re-run the search rather than just re-filter what a previous run returned.
        .task(id: SearchRunKey(query: debouncedQuery, range: timeRange)) {
            await runSearch(debouncedQuery)
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


    // MARK: - Home Content

    @ViewBuilder
    private var homeContent: some View {
        VStack(spacing: DS.lg) {
            if let reason = appState.database.fallbackReason {
                recordNotice(
                    title: "Some of the record may be missing",
                    message: "mull is still keeping today, but it could not open its own store the usual way. Nothing already saved has been discarded. Restarting mull will try again from the beginning.",
                    diagnostic: reason,
                    retry: nil
                )
            }

            if let dirIssue = directoryIssue {
                recordNotice(
                    title: "The files for your AI are not being written",
                    message: "mull cannot write to the ~/mull folder, so me.md, now.md and full.md have stopped being refreshed. Recording itself is unaffected.",
                    diagnostic: dirIssue,
                    retry: {
                        _ = MullDirectory.setup()
                        directoryIssue = MullDirectory.issueDescription
                    }
                )
            }

            if isLoading {
                loadingSkeleton
            } else if hasRecord {
                nocturneHero

                ReportCardView()

                if !behaviorPatterns.isEmpty {
                    behaviorSection
                }

                if !projects.isEmpty {
                    projectsSection
                }

                // Shown whenever there is a record at all, including a week whose
                // seven days are empty. Gating this on "some day has time on it"
                // meant a reader whose activity all predates Monday watched the
                // section disappear — which reads as "mull lost the feature", not
                // as "the week is quiet". A week of empty bars still says which
                // week it is, and still says nothing happened in it.
                WeekSection(days: weekDays, comparison: weekComp, onSelectDay: onOpenDay)

                if !todayEvents.isEmpty {
                    scheduleSection
                }

                asOfLine
            } else {
                // One silence, said once. Home used to stack the hero's "A quiet
                // day so far", the report card's own blank note and a third
                // empty-state paragraph on top of each other — three voices
                // telling a new user the same thing three different ways.
                emptyState
            }
        }
    }

    /// Whether mull is actually holding anything worth laying out. Calendar
    /// events alone don't count: they are Calendar.app's record, not mull's.
    private var hasRecord: Bool {
        !projects.isEmpty
            || !behaviorPatterns.isEmpty
            || weekDays.contains { $0.totalDuration > 0 }
    }

    // MARK: - As Of

    /// When this page was read, and how to read it again. Deliberately the
    /// quietest thing on the page: a footnote, not a control panel.
    private var asOfLine: some View {
        HStack(spacing: DS.md) {
            Spacer()

            Text(lastRefreshed.map { "As of \(Self.clockFormatter.string(from: $0))" } ?? "Not yet read")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkFaint)

            Button {
                refresh()
            } label: {
                Label("Read again", systemImage: "arrow.clockwise")
                    .font(DS.captionFont)
                    .padding(.vertical, DS.xs)
                    .padding(.horizontal, DS.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isRefreshing ? DS.inkFaint : DS.moon)
            .disabled(isRefreshing)
            .help("Re-read the last 14 days")
        }
        .padding(.top, DS.xs)
    }

    /// `j` asks the locale for its hour cycle, so a Mac set to 12-hour time gets
    /// 12-hour time here instead of the 24-hour clock `"HH:mm"` imposed on everyone.
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    // MARK: - Nocturne Hero

    /// The hero surface: a quiet moonlit reflection — date, what you mostly did,
    /// recent work as strata bars, and where to resume.
    private var nocturneHero: some View {
        let top = Array(projects.prefix(3))
        let maxDur = max(top.map(\.totalDuration).max() ?? 1, 1)

        return VStack(alignment: .leading, spacing: DS.lg) {
            // Date
            Text(Self.heroDate)
                .font(DS.smallMedium)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(DS.inkFaint)

            // Headline
            VStack(alignment: .leading, spacing: DS.xs) {
                Text("Today")
                    // Larger than DS.heroFont (28/bold) and lighter in weight, so the
                    // page opens like a printed title rather than a headline number.
                    .font(DS.pageTitleFont)
                    .foregroundStyle(DS.ink)
                Text(heroSubtitle)
                    .font(DS.readFont)
                    .foregroundStyle(DS.inkDim)
            }

            // Focus line — next meeting / uninterrupted time (folded in from the
            // old Today's Briefing card). Extracted into its own builder to keep
            // this VStack within the type-checker's inference budget.
            focusLineView

            strataBlock(top, maxDur: maxDur)

            // Resume
            if let resume = top.first {
                HStack(spacing: DS.sm) {
                    Text("RESUME")
                        .font(DS.miniBold)
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

    /// The strata bars, under a label that says what window they cover.
    ///
    /// The headline directly above them reads "Today", and without a label these
    /// fourteen-day totals are read as today's hours. One line of type is the
    /// whole difference between a record and a misleading one.
    @ViewBuilder
    private func strataBlock(_ top: [ProjectSnapshot], maxDur: Double) -> some View {
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: DS.sm) {
                Text("LAST 14 DAYS")
                    .font(DS.miniBold)
                    .tracking(1.2)
                    .foregroundStyle(DS.inkFaint)

                ForEach(top) { project in
                    strataRow(project, fraction: project.totalDuration / maxDur)
                }
            }
            .padding(.top, DS.xs)
        }
    }

    private func strataRow(_ project: ProjectSnapshot, fraction: Double) -> some View {
        HStack(spacing: DS.md) {
            // The column is fixed so the bars beside it start on one line — that
            // alignment is what makes the strata readable as a comparison. The cost
            // is that a name past ~15 characters is cut, permanently and with no
            // way to ask what it was, so the full name is available on hover.
            Text(project.name)
                .font(DS.bodyFont)
                .foregroundStyle(DS.ink)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)
                .help(project.name)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.hairline)
                        .frame(height: 4)
                    // Flat tobacco, not a gradient: the bar's length is the only
                    // thing carrying meaning here.
                    Capsule().fill(DS.moon)
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

    // MARK: - The today-claim
    //
    // The hero says "Today". Whatever follows it therefore has to come from
    // today, or not claim to. It used to read "Mostly X" where X was the top
    // project of a *fourteen-day* aggregate — so on a morning with no activity
    // at all mull would still confidently announce what you had mostly been
    // doing today. That is exactly the kind of assertion the product is not
    // allowed to make.

    /// Today's own row from the week snapshots — the only source that is
    /// actually about today.
    private var todaySnapshot: DaySnapshot? {
        weekDays.first { $0.isToday }
    }

    /// Below this there is not enough of a day to characterise. Twenty minutes
    /// of scattered blocks is noise; calling it "mostly" something is a guess
    /// wearing a fact's clothes.
    private static let todayClaimThreshold: TimeInterval = 20 * 60

    private var heroSubtitle: String {
        let todayDuration = todaySnapshot?.totalDuration ?? 0

        if todayDuration >= Self.todayClaimThreshold, let main = todaySnapshot?.mainProject {
            return "Mostly \(main)."
        }

        if todayDuration > 0 {
            // Something today, but too little to name. Say the true small thing.
            return "Only just begun — not enough today to call it anything yet."
        }

        // Nothing today at all. The fortnight is still knowable; it is simply a
        // different claim, and it gets said as one.
        if let recent = projects.first?.name {
            return "Nothing recorded today yet. Recently, mostly \(recent)."
        }

        return "Nothing recorded today yet."
    }

    /// The date the page opens with, written the way the reader's Mac writes dates.
    ///
    /// `"EEEE, d MMMM"` is not a format, it is one locale's *order* — it printed
    /// "Sunday, 19 July" on a Japanese system that would write 7月19日(日). Asking
    /// for the template instead lets the locale choose both the order and the
    /// wording, and costs nothing anywhere else.
    private static var heroDate: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f.string(from: Date())
    }

    /// The focus-line row, or nothing. Kept as its own ViewBuilder so the hero's
    /// VStack stays simple enough to type-check.
    @ViewBuilder private var focusLineView: some View {
        if let focus = focusLine {
            HStack(spacing: DS.sm) {
                Image(systemName: focus.icon)
                    .font(DS.captionFont)
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
            return ("calendar.badge.exclamationmark", "No calendar access, so no schedule here")
        }
        if !todayEvents.isEmpty {
            return ("checkmark.circle", "Today's last meeting has ended")
        }
        return ("calendar", "Nothing on the calendar today")
    }

    // MARK: - Behavior Patterns Section

    private static let patternPreviewCount = 3

    private var behaviorSection: some View {
        let shown = showAllPatterns
            ? behaviorPatterns
            : Array(behaviorPatterns.prefix(Self.patternPreviewCount))
        let hidden = behaviorPatterns.count - shown.count

        return VStack(alignment: .leading, spacing: DS.md) {
            HStack {
                Text("PATTERNS")
                    .sectionLabel()
                Spacer()
                if behaviorPatterns.count > Self.patternPreviewCount {
                    Text(Self.countLabel(showing: shown.count, of: behaviorPatterns.count, noun: "pattern"))
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                }
            }

            ForEach(shown) { pattern in
                behaviorCard(pattern)
            }

            disclosureRow(hidden: hidden, expanded: $showAllPatterns)
        }
    }

    // MARK: - Honest counts
    //
    // A heading that says "9 projects" over a list of six is the app telling a
    // small lie about its own record. Either the number matches what is on the
    // page, or it says plainly that it is showing a part of the whole — and
    // there is always a way to see the rest.

    private static func countLabel(showing: Int, of total: Int, noun: String) -> String {
        let unit = pluralNoun(total, noun)
        return showing == total ? "\(total) \(unit)" : "\(showing) of \(total) \(unit)"
    }

    /// "Show N more" / "Show fewer", or nothing when everything is already out.
    @ViewBuilder
    private func disclosureRow(hidden: Int, expanded: Binding<Bool>) -> some View {
        if hidden > 0 {
            moreButton("Show \(hidden) more") { expanded.wrappedValue = true }
        } else if expanded.wrappedValue {
            moreButton("Show fewer") { expanded.wrappedValue = false }
        }
    }

    private func moreButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { action() }
        } label: {
            Text(title)
                .font(DS.captionMedium)
                .foregroundStyle(DS.moon)
                .padding(.vertical, DS.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func behaviorCard(_ pattern: BehaviorPattern) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            // Header with severity indicator
            HStack(spacing: DS.sm) {
                RoundedRectangle(cornerRadius: DS.radiusXs)
                    .fill(DS.moon)
                    .frame(width: 4, height: 28)

                VStack(alignment: .leading, spacing: DS.hair) {
                    Text(pattern.title)
                        .font(DS.bodyMedium)
                    // One quiet tone for every pattern. Grading these by severity in
                    // red/amber turned a held record into a report card on the person.
                    Text(patternTypeLabel(pattern.type))
                        .font(DS.miniMedium)
                        .foregroundStyle(DS.moon)
                        .padding(.horizontal, DS.xs)
                        .padding(.vertical, 1)
                        .background(DS.moon.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: DS.radiusChip))
                }

                Spacer()
            }

            // Insight — what the data shows
            Text(pattern.insight)
                .font(DS.bodyFont)
                .foregroundStyle(DS.inkDim)
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
                .foregroundStyle(DS.inkGhost)
                .padding(.leading, DS.lg)
        }
        .mullHeroCard()
    }

    /// What was measured, not a verdict on the person. Severity still orders the
    /// list; it no longer colours it, and no label calls the reader avoidant.
    private func patternTypeLabel(_ type: BehaviorPattern.PatternType) -> String {
        switch type {
        case .abandonment: "untouched since"
        case .peakWaste: "peak hours"
        case .focusDecline: "fewer long blocks"
        case .avoidance: "short sessions only"
        case .correlation: "recurring together"
        }
    }



    // MARK: - Projects Section

    private static let projectPreviewCount = 6

    private var projectsSection: some View {
        let shown = showAllProjects
            ? projects
            : Array(projects.prefix(Self.projectPreviewCount))
        let hidden = projects.count - shown.count

        return VStack(alignment: .leading, spacing: DS.md) {
            HStack {
                Text("PROJECTS")
                    .sectionLabel()
                Spacer()
                // Reads "6 projects" when six is all there is, and
                // "6 of 9 projects" when it isn't.
                Text(Self.countLabel(showing: shown.count, of: projects.count, noun: "project"))
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkGhost)
            }

            ForEach(shown) { project in
                projectCard(project, expanded: false)
            }

            disclosureRow(hidden: hidden, expanded: $showAllProjects)
        }
    }

    private func projectCard(_ project: ProjectSnapshot, expanded: Bool) -> some View {
        let isStale = project.daysSinceActive >= 3
        let sessions = project.sessions

        return VStack(alignment: .leading, spacing: DS.sm) {
            // Header
            HStack(alignment: .top) {
                HStack(spacing: DS.sm) {
                    RoundedRectangle(cornerRadius: DS.radiusXs)
                        .fill(project.color)
                        .frame(width: 4, height: 36)

                    VStack(alignment: .leading, spacing: DS.hair) {
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
                                    .clipShape(RoundedRectangle(cornerRadius: DS.radiusChip))
                            }
                        }

                        HStack(spacing: DS.xs) {
                            Text(project.primaryApp)
                                .font(DS.captionFont)
                                .foregroundStyle(DS.inkFaint)
                            Text("·")
                                .foregroundStyle(DS.inkGhost)
                            Text(project.totalDurationFormatted)
                                .font(DS.captionMedium)
                                .foregroundStyle(DS.moon)
                            Text("·")
                                .foregroundStyle(DS.inkGhost)
                            Text(project.lastActiveFormatted)
                                .font(DS.captionFont)
                                .foregroundStyle(isStale ? DS.paused : DS.inkDim)
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
                            .foregroundStyle(isStale ? DS.paused : DS.inkFaint)
                    }

                    if let file = project.lastFile {
                        HStack(spacing: DS.xs) {
                            Image(systemName: "doc.text")
                                .font(DS.miniFont)
                                .foregroundStyle(DS.inkFaint)
                            Text(file)
                                .font(DS.captionFont)
                                .foregroundStyle(DS.inkDim)
                                .lineLimit(1)
                        }
                    }

                    if let clip = project.lastClipboard {
                        HStack(spacing: DS.xs) {
                            Image(systemName: "text.quote")
                                .font(DS.miniFont)
                                .foregroundStyle(DS.inkFaint)
                            Text("\"\(clip)\"")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.inkFaint)
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
        // `sessions` is newest-first, so a prefix keeps the most recent ones and
        // the ones dropped are always the earliest. The list below renders them
        // reversed (oldest at the top), which is why the "+N earlier" note sits
        // above it rather than below.
        let displaySessions = expanded ? Array(sessions.prefix(10)) : Array(sessions.prefix(4))
        let hiddenSessions = sessions.count - displaySessions.count
        let avgDuration = sessions.reduce(0.0) { $0 + $1.duration } / Double(max(sessions.count, 1))

        return VStack(alignment: .leading, spacing: DS.xs) {
            Divider()

            HStack {
                Text("PROGRESS")
                    .font(DS.miniBold)
                    .tracking(0.5)
                    .foregroundStyle(DS.inkGhost)

                Spacer()

                if sessions.count > 1 {
                    let avgMins = Int(avgDuration / 60)
                    Text("avg \(avgMins)m/session")
                        .font(DS.miniFont)
                        .foregroundStyle(DS.inkGhost)
                }
            }

            // The cut is stated rather than silently made. The full run is on the
            // project's own page (the expanded card), so this is a signpost, not
            // a dead end.
            if hiddenSessions > 0 {
                Text(hiddenSessions == 1
                     ? "1 earlier session not shown"
                     : "\(hiddenSessions) earlier sessions not shown")
                    .font(DS.miniFont)
                    .foregroundStyle(DS.inkFaint)
                    .padding(.leading, 20)
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
                        .foregroundStyle(isLast ? DS.inkDim : DS.inkFaint)
                        .frame(width: 65, alignment: .leading)

                    Text(session.durationFormatted)
                        .font(DS.microFont)
                        .foregroundStyle(isLast ? DS.moon : DS.inkDim)
                        .frame(width: 40, alignment: .trailing)

                    if !session.mainLabel.isEmpty && session.mainLabel != project.name {
                        Text(session.mainLabel)
                            .font(DS.captionFont)
                            .foregroundStyle(DS.inkFaint)
                            .lineLimit(1)
                            .help(session.mainLabel)
                    }

                    // "← here" was a glyph the reader had to decode: an arrow into a
                    // deictic with no referent. It marks the last session on a project
                    // nothing has touched for days, so it says that.
                    if isLast && project.daysSinceActive >= 3 {
                        Text("you left off here")
                            .font(DS.miniMedium)
                            .foregroundStyle(DS.paused)
                    }
                }
            }
        }
        .padding(.leading, DS.lg)
    }

    // MARK: - Schedule Section

    /// Today's calendar, read from the calendar.
    ///
    /// This used to scrape `CalendarService.todaySchedule()` — a markdown string
    /// built for AI context files — back into rows: `dropFirst()` to lose a
    /// header line that was only there by convention, then
    /// `replacingOccurrences(of: "- ")` across the *whole* line, which quietly
    /// deleted the hyphen out of any event whose title contained one, so
    /// "Sprint - retro" was shown to the user as "Sprintretro". A structured
    /// source was available the entire time.
    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack {
                Text("SCHEDULE")
                    .sectionLabel()
                Spacer()
                Text(Self.countLabel(showing: todayEvents.count, of: todayEvents.count, noun: "event"))
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkGhost)
            }

            ForEach(todayEvents) { event in
                scheduleRow(event)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mullCard()
    }

    private func scheduleRow(_ event: CalendarEvent) -> some View {
        let now = Date()
        let isNow = event.start <= now && event.end >= now
        let minutesUntil = Int(event.start.timeIntervalSince(now) / 60)
        let isSoon = !isNow && event.start > now && minutesUntil < 30

        return HStack(spacing: DS.sm) {
            Circle()
                .fill(isNow ? DS.recording : (isSoon ? DS.paused : DS.inkFaint.opacity(0.5)))
                .frame(width: 6, height: 6)

            Text(event.timeFormatted)
                .font(DS.microFont)
                .foregroundStyle(isNow ? DS.ink : DS.inkFaint)

            Text(event.title)
                .font(isNow ? DS.bodyMedium : DS.bodyFont)
                .foregroundStyle(isNow ? DS.ink : DS.inkDim)
                .lineLimit(1)

            if let location = event.location, !location.isEmpty {
                Text(location)
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isNow {
                Text("now")
                    .font(DS.miniMedium)
                    .foregroundStyle(DS.recording)
            } else if isSoon {
                Text("in \(max(minutesUntil, 0))m")
                    .font(DS.miniMedium)
                    .foregroundStyle(DS.paused)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One entry, read as one sentence — otherwise the leading dot announces as
        // an unnamed image and the time, title and "now" arrive as four separate
        // stops. The state is said in words as the value, so it does not depend on
        // telling olive from amber at six points.
        .accessibilityElement(children: .combine)
        .accessibilityValue(isNow ? "Happening now" : (isSoon ? "Starting soon" : "Later"))
    }


    // MARK: - Empty State

    /// The one empty state. Two situations, one voice, said once.
    ///
    /// Recording being off is a different fact from a day not having happened
    /// yet, and only one of them is something the reader can act on — so only
    /// one of them carries an action.
    private var emptyState: some View {
        let recordingOff = !appState.isRecording

        return VStack(spacing: DS.lg) {
            Image(systemName: "moon.stars")
                .font(DS.heroFont)
                .foregroundStyle(DS.moon.opacity(0.3))

            VStack(spacing: DS.sm) {
                Text(recordingOff ? "Nothing is being kept" : "Still a quiet page")
                    .font(DS.titleFont)
                    .foregroundStyle(DS.ink)

                Text(recordingOff
                     ? "Recording is off, so there is nothing here for mull to hold. Turning it back on, and the permissions it needs, both live in Settings."
                     : "A day's work makes the first page. Until there is one there is little to show — and everything kept stays on this Mac.")
                    .font(DS.bodyFont)
                    .foregroundStyle(DS.inkDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                if recordingOff {
                    Button("Open Settings") {
                        AppDelegate.shared?.showSettings(tab: .data)
                    }
                    .buttonStyle(HomeActionButtonStyle())
                    .padding(.top, DS.sm)
                } else {
                    whatIsBeingWaitedFor
                        .padding(.top, DS.md)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.xxl + DS.lg)
    }

    /// What the silence is waiting on, said in numbers.
    ///
    /// "A day's work makes the first page" is true and gives the reader nothing to
    /// check it against. Behind this page are two real thresholds — a written
    /// summary needs a day's gap and \(ConsolidationScheduler.minEventsRequired)
    /// recorded moments — and neither was stated anywhere in the app. Someone whose
    /// day generates forty moments waits forever, correctly, and has no way to tell
    /// that apart from mull being broken. Naming the gate is the difference between
    /// a wait and a fault.
    ///
    /// Stated, not scored. A bar filling toward 50 would turn a recorder into a
    /// game with a target, and give the user a reason to feed it — which is the one
    /// thing that would make the record stop being a record of their actual work.
    private var whatIsBeingWaitedFor: some View {
        VStack(spacing: DS.xs) {
            Text(appState.todayEventCount == 1
                 ? "1 moment kept today."
                 : "\(appState.todayEventCount) moments kept today.")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkDim)

            Text("This page fills in as the day takes a shape worth naming. The written summary comes overnight, once there is a day between them and about \(ConsolidationScheduler.minEventsRequired) moments to read.")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkFaint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        // Two lines that only make sense together — read as one.
        .accessibilityElement(children: .combine)
    }

    /// Run the search off the main thread and publish it into state. Three blocking
    /// sources — event FTS, a 15-month EventKit scan, and summary FTS — merged into
    /// one newest-first timeline, each hit carrying its own timestamp.
    private func runSearch(_ query: String) async {
        guard !query.isEmpty else {
            searchHits = []
            summaryHits = []
            resultsQuery = query
            searchRunning = false
            return
        }
        searchRunning = true
        let database = appState.database
        let calendarService = appState.calendar
        let range = timeRange

        // The range goes INTO the query, not on top of its results. The old call
        // fetched the newest 80 rows globally and let the view filter those — so
        // narrowing to "Today" showed whichever slice of the global newest-80 happened
        // to be today, and the chip counts, computed over the same capped set,
        // confirmed the lie. SQLite enforces the cutoff now, so narrowing genuinely
        // re-queries (hence the `id:` on the .task below includes timeRange).
        let results = await Task.detached(priority: .userInitiated) {
            SearchService.search(query: query, database: database,
                                 calendar: calendarService, range: range)
        }.value
        let (hits, summaries) = (results.hits, results.summaries)

        // A newer keystroke already cancelled this .task — don't publish stale hits.
        guard !Task.isCancelled else { return }
        searchHits = hits
        summaryHits = summaries
        // Published together with the hits, never apart: this is the pairing the
        // view checks before it dares highlight anything.
        resultsQuery = query
        resultsRange = range
        searchRunning = false
    }

    /// What a search run is keyed on. The range is part of the query itself now
    /// (SQLite applies the cutoff), so a range change is a new run, not a re-filter.
    private struct SearchRunKey: Equatable {
        let query: String
        let range: SearchRange
    }

    /// Whether the hits in state were computed from the search now on screen —
    /// both the text and the range, since either one changes what was fetched.
    private var resultsAreCurrent: Bool {
        resultsQuery == debouncedQuery && resultsRange == timeRange
    }

    /// Today's calendar + next meeting. EventKit calls block; keeping them out of
    /// body means they run once per appearance instead of once per redraw.
    private func loadCalendar() async {
        let calendarService = appState.calendar
        // macOS 14 is the deployment target, so full access is the only grant that
        // lets CalendarService read anything.
        let authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess

        let loaded = await Task.detached(priority: .userInitiated) {
            (events: calendarService.events(for: Date()),
             next: calendarService.upcomingEvents(limit: 1).first)
        }.value

        guard !Task.isCancelled else { return }
        calendarAuthorized = authorized
        todayEvents = loaded.events
        nextEvent = loaded.next
    }

    // MARK: - Data Loading

    /// How long a reading of the record stays good enough to reuse. Returning to
    /// Home twice in a minute shouldn't re-run a fortnight of analysis.
    private static let refreshInterval: TimeInterval = 60

    private func refreshIfStale() {
        guard !isRefreshing else { return }
        if let lastRefreshed, Date().timeIntervalSince(lastRefreshed) < Self.refreshInterval {
            return
        }
        refresh()
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        // Only the very first load shows the skeleton. Later refreshes happen
        // silently underneath the content that's already on screen — an explicit
        // "Read again" should not blank the page it is re-reading.
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
                // started, or capture is broken). `hasRecord` reads it straight off
                // these three results, so there is no second flag to fall out of
                // step with them.
                self.directoryIssue = MullDirectory.issueDescription
                self.hasLoadedOnce = true
                self.isLoading = false
                self.lastRefreshed = Date()
                self.isRefreshing = false
            }
        }

        // The calendar is part of what the page is "as of", so it moves with it.
        Task { await loadCalendar() }
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
                    ForEach(0..<7, id: \.self) { day in
                        VStack(spacing: DS.xs) {
                            skeletonBar(width: nil, height: 12)
                            skeletonBar(width: nil, height: Self.skeletonDayHeights[day])
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

    // The skeleton's ragged edge used to come from `CGFloat.random` evaluated
    // inside `body`, which meant every re-render re-rolled it and the placeholder
    // twitched while you waited. The unevenness is the point — a page of
    // identical bars doesn't read as text — so it is kept, but fixed: chosen once,
    // indexed by position, and therefore perfectly still.
    private static let skeletonLineWidths: [CGFloat] = [186, 142, 208, 164, 128, 196, 150, 174]
    private static let skeletonDayHeights: [CGFloat] = [34, 22, 46, 28, 41, 18, 31]

    private func skeletonCard(lines: Int, heroStyle: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            ForEach(0..<lines, id: \.self) { i in
                skeletonBar(
                    width: i == 0 ? nil : Self.skeletonLineWidths[i % Self.skeletonLineWidths.count],
                    height: i == 0 ? 14 : 10
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(heroStyle ? AnyViewModifier(mullHeroCardModifier()) : AnyViewModifier(mullCardModifier()))
    }

    private var skeletonLabel: some View {
        RoundedRectangle(cornerRadius: DS.radiusChip)
            .fill(DS.ink.opacity(0.06))
            .frame(width: 80, height: 10)
    }

    private func skeletonBar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: DS.radiusChip)
            .fill(DS.ink.opacity(0.06))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    // MARK: - When something is wrong with the record itself
    //
    // This used to be a card headed "Database Issue" containing nothing but a raw
    // internal diagnostic and no way forward — developer-ese shouted at someone
    // who has no idea what a migration is. What a person needs to know is what it
    // means for their record, whether anything was lost, and what to do. The
    // diagnostic still matters, for a bug report; it just belongs folded away.

    private func recordNotice(
        title: String,
        message: String,
        diagnostic: String,
        retry: (() -> Void)?
    ) -> some View {
        let revealed = revealedDiagnostics.contains(diagnostic)

        return VStack(alignment: .leading, spacing: DS.sm) {
            HStack(alignment: .top, spacing: DS.sm) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(DS.paused)

                VStack(alignment: .leading, spacing: DS.xs) {
                    Text(title)
                        .font(DS.bodyMedium)
                        .foregroundStyle(DS.ink)
                    Text(message)
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: DS.sm) {
                if let retry {
                    Button("Try again", action: retry)
                        .buttonStyle(HomeActionButtonStyle())
                }

                Button("Reveal ~/mull in Finder") {
                    _ = NSWorkspace.shared.selectFile(
                        nil,
                        inFileViewerRootedAtPath: NSString(string: "~/mull").expandingTildeInPath
                    )
                }
                .buttonStyle(HomeActionButtonStyle())

                Spacer(minLength: 0)

                Button(revealed ? "Hide details" : "Details") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if revealed {
                            revealedDiagnostics.remove(diagnostic)
                        } else {
                            revealedDiagnostics.insert(diagnostic)
                        }
                    }
                }
                .buttonStyle(.plain)
                .font(DS.captionFont)
                .foregroundStyle(DS.inkFaint)
            }

            if revealed {
                // Selectable, because the only use for this text is pasting it
                // into a bug report.
                Text(diagnostic)
                    .font(DS.microFont)
                    .foregroundStyle(DS.inkDim)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DS.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DS.radiusInset)
                            .fill(DS.ink.opacity(0.04))
                    )
            }
        }
        .padding(DS.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusSm)
                .fill(DS.paused.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusSm)
                .strokeBorder(DS.paused.opacity(0.28), lineWidth: 0.75)
        )
    }

}

// MARK: - Action button

/// A real button, in the app's own materials.
///
/// Where an empty state or a warning offers the reader their only way forward,
/// that affordance has to look like something you can press. `.buttonStyle(.plain)`
/// on a caption-sized label is a link pretending to be a button, with a hit area
/// to match. This is the restrained version: a hairline-edged tobacco chip on the
/// ivory page, with enough height (~30pt) to actually aim at.
struct HomeActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.smallMedium)
            .foregroundStyle(DS.moon)
            .padding(.horizontal, DS.lg)
            .padding(.vertical, DS.sm + 1)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusSm)
                    .fill(DS.moon.opacity(configuration.isPressed ? 0.16 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSm)
                    .strokeBorder(DS.moon.opacity(0.32), lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.radiusSm))
    }
}
