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
/// Home's reading of the record, held above the view that draws it.
///
/// HomeTab is built inside `FullWindowView`'s `switch selection`, so navigating away
/// destroys the view and every `@State` on it. That quietly made two pieces of this
/// file's own logic dead letters — "the skeleton is first-load only", and the
/// 60-second staleness guard — because every return to Home was a first load. Going
/// to Calendar and coming back five seconds later flashed the skeleton and re-ran a
/// fortnight of project analysis and pattern detection to reach the answer that had
/// been on screen a moment earlier, and the reader's search filters went with it.
///
/// Anything here survives leaving Home. Anything still `@State` on the view below is
/// deliberately per-visit.
@MainActor
final class HomeAnalysis: ObservableObject {
    @Published var projects: [ProjectSnapshot] = []
    @Published var weekDays: [DaySnapshot] = []
    @Published var weekComp: WeekComparison?
    @Published var behaviorPatterns: [BehaviorPattern] = []
    @Published var directoryIssue: String? = MullDirectory.issueDescription
    /// When the analysis on screen was computed, and whether one has ever landed.
    @Published var lastRefreshed: Date?
    @Published var isLoading = true
    @Published var hasLoadedOnce = false
    @Published var isRefreshing = false
    /// Today's calendar. Here rather than on the view so the hero's countdown and the
    /// schedule card are not blank for an EventKit round trip every time Home is
    /// returned to.
    @Published var todayEvents: [CalendarEvent] = []
    @Published var calendarAuthorized = true

    // Search filters — which kinds of hit to show, over what period, from which apps.
    @Published var enabledKinds: Set<SearchHit.Kind> = Set(SearchHit.Kind.allCases)
    @Published var timeRange: SearchRange = .all
    @Published var selectedApps: Set<String> = []   // empty = all apps
}

struct HomeTab: View {
    @EnvironmentObject var appState: AppState
    /// Owned by the parent, so it outlives a trip to Calendar. See `HomeAnalysis`.
    @ObservedObject var analysis: HomeAnalysis
    @Binding var searchQuery: String
    /// Open a date in the Calendar Day view — wired by the parent so a search hit can jump
    /// to the day it happened.
    var onOpenDay: (Date) -> Void = { _ in }
    @State private var debouncedQuery = ""
    // Pass-throughs to `analysis`, so the ~40 places that read and write these read
    // exactly as they did when they were `@State`. What changed is where the values
    // live: on an object the parent holds, not on a view the parent throws away.
    private var projects: [ProjectSnapshot] {
        get { analysis.projects }
        nonmutating set { analysis.projects = newValue }
    }
    private var weekDays: [DaySnapshot] {
        get { analysis.weekDays }
        nonmutating set { analysis.weekDays = newValue }
    }
    private var weekComp: WeekComparison? {
        get { analysis.weekComp }
        nonmutating set { analysis.weekComp = newValue }
    }
    private var behaviorPatterns: [BehaviorPattern] {
        get { analysis.behaviorPatterns }
        nonmutating set { analysis.behaviorPatterns = newValue }
    }
    private var isLoading: Bool {
        get { analysis.isLoading }
        nonmutating set { analysis.isLoading = newValue }
    }
    private var hasLoadedOnce: Bool {
        get { analysis.hasLoadedOnce }
        nonmutating set { analysis.hasLoadedOnce = newValue }
    }

    @State private var searchDebounceTask: Task<Void, Never>?

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
    private var todayEvents: [CalendarEvent] {
        get { analysis.todayEvents }
        nonmutating set { analysis.todayEvents = newValue }
    }
    /// The next thing on the calendar, worked out against the clock every time this
    /// page draws rather than fetched as a frozen "minutes until".
    ///
    /// It used to be its own EventKit read, stored with the countdown already
    /// computed and refreshed only on appear, on app activation, or by hand — so on a
    /// window left open the hero sat at "12m until Standup" while Standup began and
    /// ended, and `scheduleRow` a few points below it (which does read the clock on
    /// every pass) said "now" at the same moment. Today's events are already here;
    /// asking them is both live and one EventKit call cheaper.
    private var nextEvent: CalendarEvent? {
        let now = Date()
        return todayEvents.filter { $0.start > now }.min { $0.start < $1.start }
    }
    private var calendarAuthorized: Bool {
        get { analysis.calendarAuthorized }
        nonmutating set { analysis.calendarAuthorized = newValue }
    }

    // Disclosure / expansion state — nothing here is truncated silently, so the
    // view has to remember what the reader chose to open.
    @State private var showAllProjects = false
    @State private var showAllPatterns = false
    @State private var revealedDiagnostics: Set<String> = []

    private var directoryIssue: String? {
        get { analysis.directoryIssue }
        nonmutating set { analysis.directoryIssue = newValue }
    }
    /// When the analysis on screen was computed. Home used to refresh only on
    /// navigation and never said how old it was.
    private var lastRefreshed: Date? {
        get { analysis.lastRefreshed }
        nonmutating set { analysis.lastRefreshed = newValue }
    }
    private var isRefreshing: Bool {
        get { analysis.isRefreshing }
        nonmutating set { analysis.isRefreshing = newValue }
    }
    private var enabledKinds: Set<SearchHit.Kind> { analysis.enabledKinds }
    private var timeRange: SearchRange { analysis.timeRange }
    private var selectedApps: Set<String> { analysis.selectedApps }

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
                    enabledKinds: $analysis.enabledKinds,
                    timeRange: $analysis.timeRange,
                    selectedApps: $analysis.selectedApps,
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
        .onAppear {
            refreshIfStale()
            // A query can already be in the field by the time Home is mounted:
            // typing while Calendar, Live, Chat or a note was open navigates *here*,
            // and that assignment happens before this view exists. `.onChange(of:
            // searchQuery)` below therefore never saw it, `debouncedQuery` stayed
            // empty, and the first character of a search started anywhere else
            // produced no results at all until a second one was typed.
            if debouncedQuery != searchQuery { debouncedQuery = searchQuery }
        }
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
                    title: String(localized: "Some of the record may be missing"),
                    message: appState.database.isFallback
                        // The temporary-location case is not "some may be missing",
                        // it is "everything from this session goes on restart", and
                        // that is worth its own sentence.
                        ? "mull could not open its own store, so today is being kept in a temporary file that will not survive a restart. Nothing already saved has been discarded. Restarting mull will try the real store again."
                        : "mull is still keeping today, but it could not open its own store the usual way. Nothing already saved has been discarded. Restarting mull will try again from the beginning.",
                    diagnostic: reason,
                    // The database lives in Application Support, not ~/mull — the
                    // shared button used to send people to the wrong folder.
                    revealPath: "~/Library/Application Support/mull",
                    retry: nil
                )
            }

            if let dirIssue = directoryIssue {
                recordNotice(
                    title: String(localized: "The files for your AI are not being written"),
                    message: String(localized: "mull cannot write to the ~/mull folder, so me.md, now.md and full.md have stopped being refreshed. Recording itself is unaffected."),
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

            Text(lastRefreshed.map { String(localized: "As of \(Self.clockFormatter.string(from: $0))") } ?? "Not yet read")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkFaint)

            Button {
                refresh()
            } label: {
                Label("Read again", systemImage: DS.Glyph.refresh)
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
                        // File names carry their meaning at both ends — the folder
                        // at the start, the extension at the end — so a long one
                        // loses its middle, and the whole of it is on hover.
                        .truncationMode(.middle)
                        .help(resume.lastFile ?? resume.name)
                    Spacer()
                }
                .padding(.top, DS.xs)
            }
        }
        .padding(DS.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: DS.radiusLg)
                    .fill(DS.surface)
                    .moonGlow(0.14)
                // The icon's stipple rings, held at watermark strength — the same
                // figure as the Dock icon, growing out of the card's top-right
                // corner. Kept faint enough that the type never has to fight it.
                StippleRings(center: CGPoint(x: 0.86, y: 0.12))
                    .opacity(0.08)
            }
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

                // A Grid, so the bars beside the names start on one shared line —
                // that alignment is what makes the strata readable as a comparison.
                //
                // The name column takes the width its longest name asks for, and the
                // bar takes the rest. It used to be capped at 220pt, which is a
                // number with nothing behind it: on a normal window the bars had
                // some 700pt of empty track beside them while every Japanese project
                // name was being cut at about fifteen characters. Measured: the three
                // names on this Mac wanted 249–264pt against a cap of 220.
                //
                // The cap existed to stop a pathological title (a raw window title
                // that became a project name) from squeezing the bars into
                // meaninglessness. A floor under the *bar* says that directly and
                // costs nothing when the names are ordinary: past it the name is what
                // gives way, and the whole of it is on hover.
                Grid(alignment: .leading, horizontalSpacing: DS.md, verticalSpacing: DS.sm) {
                    ForEach(top) { project in
                        GridRow {
                            Text(project.name)
                                .font(DS.bodyFont)
                                .foregroundStyle(DS.ink)
                                .lineLimit(1)
                                .help(project.name)
                            strataBar(fraction: project.totalDuration / maxDur)
                                .frame(minWidth: 160)
                            Text(project.totalDurationFormatted)
                                .font(DS.microFont)
                                .foregroundStyle(DS.inkFaint)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
            .padding(.top, DS.xs)
        }
    }

    private func strataBar(fraction: Double) -> some View {
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
            return String(localized: "Mostly \(main).")
        }

        if todayDuration > 0 {
            // Something today, but too little to name. Say the true small thing.
            return String(localized: "Only just begun — not enough recorded today to summarize.")
        }

        // Nothing today at all. The fortnight is still knowable; it is simply a
        // different claim, and it gets said as one.
        if let recent = projects.first?.name {
            return String(localized: "Nothing recorded today yet. Recently, mostly \(recent).")
        }

        return String(localized: "Nothing recorded today yet.")
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
            HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                // One mark for every state. The per-state glyph (clock, calendar,
                // checkmark) made four voices out of one quiet sentence — the
                // words already say which case this is.
                StippleMark(dot: 2.5)
                    .frame(width: 14)
                Text(focus)
                    .font(DS.smallFont)
                    .foregroundStyle(DS.inkDim)
                Spacer()
            }
        }
    }

    /// Next meeting countdown, or uninterrupted-focus note. The one piece of the
    /// old Today's Briefing not already covered by the hero's resume point.
    private var focusLine: String? {
        if let next = nextEvent {
            // Rounded up and floored at one minute. Whole-minute truncation put a
            // meeting starting in 40 seconds at `minutesUntil == 0`, which failed the
            // "is there anything upcoming" test and made the page announce that the
            // day's last meeting had ended — 40 seconds before the next one began.
            let minutes = max(Int((next.start.timeIntervalSince(Date()) / 60).rounded(.up)), 1)
            let h = minutes / 60, m = minutes % 60
            let t = h > 0 ? "\(h)h\(m > 0 ? " \(m)m" : "")" : "\(m)m"
            return "\(t) until \(next.title)"
        }
        // "Nothing upcoming" has three very different meanings, and claiming
        // "uninterrupted focus" for all of them was a lie in two of them.
        if !calendarAuthorized {
            return "No calendar access, so no schedule here"
        }
        if !todayEvents.isEmpty {
            return String(localized: "Today's last meeting has ended")
        }
        return String(localized: "Nothing on the calendar today")
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
                    Text(Self.countLabel(showing: shown.count, of: behaviorPatterns.count))
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

    /// The events variant. It used to take the noun as a `String` and pluralise it by
    /// suffixing an s, which is a sentence assembled from parts and so a sentence no
    /// translation can reach (WRITING.md §5.3). One caller, one noun, four whole keys.
    private static func eventCountLabel(showing: Int, of total: Int) -> String {
        if showing == total {
            return counted(total, one: "1 event", other: "\(total) events")
        }
        return counted(total, one: "\(showing) of 1 event",
                       other: "\(showing) of \(total) events")
    }

    /// The same count for a header that has already named the noun. "PATTERNS · 3 of 7"
    /// says everything "PATTERNS · 3 of 7 patterns" does, without saying it twice.
    private static func countLabel(showing: Int, of total: Int) -> String {
        // `String(localized:)` on the second one, not bare interpolation: "of" is a
        // word, and a bare `"\(a) of \(b)"` is a Swift string that no catalog ever
        // sees. The first is two digits and has nothing to translate.
        showing == total ? "\(total)" : String(localized: "\(showing) of \(total)")
    }

    /// "Show N more" / "Show fewer", or nothing when everything is already out.
    @ViewBuilder
    private func disclosureRow(hidden: Int, expanded: Binding<Bool>) -> some View {
        if hidden > 0 {
            moreButton(String(localized: "Show \(hidden) more")) { expanded.wrappedValue = true }
        } else if expanded.wrappedValue {
            moreButton(String(localized: "Show fewer")) { expanded.wrappedValue = false }
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
            HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                StippleMark(dot: 2.5)
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
        case .abandonment: String(localized: "untouched since")
        case .peakWaste: String(localized: "peak hours")
        case .focusDecline: String(localized: "fewer long blocks")
        case .avoidance: String(localized: "short sessions only")
        case .correlation: String(localized: "recurring together")
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
                Text(Self.countLabel(showing: shown.count, of: projects.count))
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
                                .help(project.name)

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
                        Text("RESUME")
                            .font(DS.miniBold)
                            .tracking(0.5)
                            .foregroundStyle(isStale ? DS.paused : DS.inkFaint)
                    }

                    if let file = project.lastFile {
                        HStack(spacing: DS.xs) {
                            Image(systemName: DS.Glyph.file)
                                .font(DS.miniFont)
                                .foregroundStyle(DS.inkFaint)
                            Text(file)
                                .font(DS.captionFont)
                                .foregroundStyle(DS.inkDim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(file)
                        }
                    }

                    if let clip = project.lastClipboard {
                        HStack(spacing: DS.xs) {
                            Image(systemName: DS.Glyph.quote)
                                .font(DS.miniFont)
                                .foregroundStyle(DS.inkFaint)
                            Text("\"\(clip)\"")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.inkFaint)
                                .italic()
                                .lineLimit(2)
                                .help(clip)
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

                    // Both of these are one word each, and neither may be cut: a date
                    // and a duration are the whole of what the row measures.
                    //
                    // A hard 65pt could not hold the date. It fits "8/9 (Sun)"
                    // (56pt) and not "12/31 (Thu)" (68pt), so from October the
                    // column began cutting itself — and `microFont` scales with
                    // Dynamic Type, which put both columns over at the larger text
                    // sizes whatever the month. `fixedSize` + `minWidth` makes the
                    // number a floor rather than a ceiling: nothing is ever chopped,
                    // and the column widens instead. (Same fix, same reason, as the
                    // Live tab's clock column.)
                    //
                    // 76, not 68: the floor has to clear the *widest* reading the
                    // format can produce, or rows with a short date and rows with a
                    // long one sit at two different widths and the columns to their
                    // right go ragged. Measured across locales, `M/d (EEE)` tops out
                    // at "12/31 (jeu.)" — 74pt.
                    Text(session.dateFormatted)
                        .font(DS.microFont)
                        .foregroundStyle(isLast ? DS.inkDim : DS.inkFaint)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 76, alignment: .leading)

                    // 48 clears the longest duration a session can carry ("12h 45m",
                    // 43pt) for the same reason: every row lands on the floor, so
                    // they all line up.
                    Text(session.durationFormatted)
                        .font(DS.microFont)
                        .foregroundStyle(isLast ? DS.moon : DS.inkDim)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 48, alignment: .trailing)

                    if !session.mainLabel.isEmpty && session.mainLabel != project.name {
                        Text(session.mainLabel)
                            .font(DS.captionFont)
                            .foregroundStyle(DS.inkFaint)
                            .lineLimit(1)
                            .help(session.mainLabel)
                    }

                    // No third dormancy marker here. A stalled card already carries the
                    // `stalled` badge, the days-since figure and the RESUME block; the
                    // last row is the moon-coloured one, which is marker enough.
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
                Text(Self.eventCountLabel(showing: todayEvents.count, of: todayEvents.count))
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
                // When the row runs out of room, the location gives way before the
                // title does — the event's name is the row.
                .layoutPriority(1)
                .help(event.title)

            if let location = event.location, !location.isEmpty {
                Text(location)
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .lineLimit(1)
                    .help(location)
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
            // The first rings of the icon's figure, sparse and half-formed — a
            // record that has only begun to accrete. The same motif as the Dock
            // icon, so the empty page and the app wear one face.
            StippleRings.roundel()
                .frame(width: 88, height: 88)
                .opacity(0.55)

            VStack(spacing: DS.sm) {
                Text(recordingOff ? "Nothing is being kept" : "Nothing recorded yet")
                    .font(DS.titleFont)
                    .foregroundStyle(DS.ink)

                Text(recordingOff
                     ? "Recording is off. Turning it back on, and the permissions it needs, both live in Settings."
                     : "This page is written after a full day of work. That day hasn't happened yet.")
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
                 ? "1 record kept today."
                 : "\(appState.todayEventCount) records kept today.")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkDim)

            Text("The written summary is generated overnight, once a full day has passed and about \(ConsolidationScheduler.minEventsRequired) records have been kept.")
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

        let events = await Task.detached(priority: .userInitiated) {
            calendarService.events(for: Date())
        }.value

        guard !Task.isCancelled else { return }
        calendarAuthorized = authorized
        todayEvents = events
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
        /// Which folder the "Reveal" button opens. Defaults to the vault; the
        /// database notice points at Application Support instead, because a
        /// button that opens the wrong folder is worse than no button.
        revealPath: String = "~/mull",
        retry: (() -> Void)?
    ) -> some View {
        let revealed = revealedDiagnostics.contains(diagnostic)

        return VStack(alignment: .leading, spacing: DS.sm) {
            HStack(alignment: .top, spacing: DS.sm) {
                Image(systemName: DS.Glyph.problem)
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

                Button("Reveal \(revealPath) in Finder") {
                    _ = NSWorkspace.shared.selectFile(
                        nil,
                        inFileViewerRootedAtPath: NSString(string: revealPath).expandingTildeInPath
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
