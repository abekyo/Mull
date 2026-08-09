import SwiftUI

/// Home's search face: one chronological record of everything that mentions the query.
///
/// Purely presentational — every decision about *which* hits belong and *why* a row
/// matched lives in `SearchService`. This view owns the chips, the day grouping and
/// the rows, and nothing else.
///
/// State: the filter selections stay owned by `HomeTab` and arrive as bindings. They
/// deliberately outlive this view — clearing the search box tears the whole results
/// tree down, and a user who had narrowed to "Xcode, last 7 days" expects that
/// narrowing to still be there when they type their next query. Because that
/// persistence can silently shrink a *later* search, an active narrowing is always
/// stated (`activeFilterNotice`) and always undoable in one click, and a chip that
/// falls to zero stays on screen so it can be switched back off.
struct SearchResultsView<ProjectCard: View>: View {
    let query: String
    let projects: [ProjectSnapshot]
    let hits: [SearchHit]
    let summaries: [DailySummary]
    /// Searching runs off-thread, so "nothing yet" must not read as "nothing found"
    /// while the query is still in flight.
    let isRunning: Bool

    @Binding var enabledKinds: Set<SearchHit.Kind>
    @Binding var timeRange: SearchRange
    @Binding var selectedApps: Set<String>

    /// Open a date in the Calendar Day view — a search hit can jump to the day it happened.
    var onOpenDay: (Date) -> Void
    /// The project card is Home's, not search's. Passed in so the two surfaces cannot
    /// drift apart into two subtly different cards.
    @ViewBuilder var projectCard: (ProjectSnapshot) -> ProjectCard

    /// The finished result of the filter → sort → group → highlight pipeline.
    ///
    /// Held in `@State` rather than recomputed in `body`, because `body` re-runs on
    /// every `AppState` republish (every three seconds, whether or not anything about
    /// the search changed). Recomputation is keyed on `Inputs` alone, so the pipeline
    /// runs when the *search* changes and at no other time.
    @State private var digest = Digest()

    var body: some View {
        let matchingProjects = SearchService.matchingProjects(projects, query: query)

        VStack(spacing: DS.lg) {
            if !matchingProjects.isEmpty {
                VStack(alignment: .leading, spacing: DS.md) {
                    Text("PROJECTS")
                        .sectionLabel()

                    ForEach(matchingProjects) { project in
                        projectCard(project)
                    }
                }
            }

            // The filter bar outlives an empty result set: filters are the only way out
            // of "no matches", so hiding them exactly when they bite is the wrong move.
            if !hits.isEmpty || filtersActive {
                filterBar
                if digest.days.isEmpty && !hits.isEmpty {
                    noMatchesWithFilters
                } else if !digest.days.isEmpty {
                    timelineResults
                }
            }

            if !summaries.isEmpty {
                summarySearchResults(summaries)
            }

            if matchingProjects.isEmpty && hits.isEmpty && summaries.isEmpty && isRunning {
                HStack(spacing: DS.sm) {
                    ProgressView().controlSize(.small)
                    Text("Searching your records…")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else if matchingProjects.isEmpty && hits.isEmpty && summaries.isEmpty {
                VStack(spacing: DS.md) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.heroFont)
                        .foregroundStyle(DS.inkGhost)
                    // When filters are what emptied this, the bar above already says so
                    // and carries the way out; repeating it here only spends the reader's
                    // attention on the same sentence twice.
                    Text("No results for \"\(query)\"")
                        .font(DS.bodyFont)
                        .foregroundStyle(DS.inkDim)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            }
        }
        // The one place the pipeline runs. `initial: true` seeds it on first appearance;
        // after that only a genuine change of query / hits / filters can move it.
        .onChange(of: inputs, initial: true) { _, new in
            digest = Self.build(new)
        }
    }

    // MARK: - Pipeline

    /// Everything the rendered result depends on. Equatable so the pipeline can be keyed
    /// on it — `SearchHit` is `Hashable` and the list is bounded (80 rows), so the
    /// comparison costs far less than the work it prevents.
    private struct Inputs: Equatable {
        let query: String
        let hits: [SearchHit]
        let range: SearchRange
        let kinds: Set<SearchHit.Kind>
        let apps: Set<String>
    }

    private var inputs: Inputs {
        Inputs(query: query, hits: hits, range: timeRange,
               kinds: enabledKinds, apps: selectedApps)
    }

    /// One rendered row. The highlight is computed once here, not on every redraw.
    private struct Row: Identifiable {
        let id: String
        let date: Date
        let kind: SearchHit.Kind
        let time: String
        let detail: String?
        let text: AttributedString
        /// The unstyled text, kept for "Copy text" (see `timelineRow`).
        let plain: String
    }

    private struct DayGroup: Identifiable {
        let id: Date
        let label: String
        let rows: [Row]
        /// Matches on this day that the per-day cap kept off screen. Counted so the
        /// timeline can say so: a silent truncation in the one view whose job is
        /// showing what the record contains reads as "the record doesn't have it".
        let hidden: Int
    }

    private struct Digest {
        var counts: [SearchHit.Kind: Int] = [:]
        var appCounts: [String: Int] = [:]
        var days: [DayGroup] = []
        /// How many in-period hits the filters let through, out of how many there were.
        var shown = 0
        var inPeriod = 0
    }

    /// How many matches one day shows before the rest are summarised. A cap keeps the
    /// timeline scannable; not saying there was one is what made it a lie.
    ///
    /// Computed, not stored: this type is generic over ProjectCard, and Swift allows
    /// no stored static properties in a generic type.
    private static var rowsPerDay: Int { 8 }

    private static func build(_ i: Inputs) -> Digest {
        let ranged = SearchService.inRange(i.hits, range: i.range)
        let shown = ranged.filter {
            i.kinds.contains($0.kind) && SearchService.appPass($0, selectedApps: i.apps)
        }

        let grouped = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }
        let days = grouped.keys.sorted(by: >).map { day -> DayGroup in
            let all = (grouped[day] ?? []).sorted { $0.date > $1.date }
            let rows = all
                .prefix(Self.rowsPerDay)
                .map { hit in
                    Row(id: hit.id,
                        date: hit.date,
                        kind: hit.kind,
                        time: SearchService.timeLabel(hit.date),
                        detail: hit.detail,
                        text: hit.text.isEmpty
                            ? AttributedString("—")
                            : SearchService.highlighted(hit.text, query: i.query),
                        plain: hit.text)
                }
            return DayGroup(id: day, label: SearchService.dayLabel(day),
                            rows: Array(rows),
                            hidden: max(all.count - Self.rowsPerDay, 0))
        }

        return Digest(counts: SearchService.kindCountMap(ranged),
                      appCounts: SearchService.appCountMap(ranged),
                      days: days,
                      shown: shown.count,
                      inPeriod: ranged.count)
    }

    // MARK: - Filters

    // Not `static let`: this type is generic over ProjectCard, and Swift does not
    // allow stored static properties in generic types.
    private var allKinds: Set<SearchHit.Kind> { Set(SearchHit.Kind.allCases) }

    /// True when what is on screen is narrower than "everything that matched".
    private var filtersActive: Bool {
        enabledKinds != allKinds || timeRange != .all || !selectedApps.isEmpty
    }

    private func resetFilters() {
        withAnimation(.easeOut(duration: 0.15)) {
            enabledKinds = allKinds
            timeRange = .all
            selectedApps.removeAll()
        }
    }

    private var resetFiltersButton: some View {
        Button(action: resetFilters) {
            Text("Reset filters")
                .font(DS.miniMedium)
                .foregroundStyle(DS.moon)
                .padding(.horizontal, DS.sm)
                .padding(.vertical, DS.xs)
                .background(Capsule().fill(DS.moon.opacity(0.10)))
                .overlay(Capsule().strokeBorder(DS.moon.opacity(0.3), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .help("Show every kind of match, every app, all time")
    }

    /// Filter controls: a time-range segment + per-kind toggle chips with live counts.
    /// Tightening the period or turning off "Typed" is the fastest way to cut noise.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                Picker("", selection: $timeRange) {
                    ForEach(SearchRange.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Time range")
                .frame(maxWidth: 360, alignment: .leading)

                if filtersActive { resetFiltersButton }
            }

            // Every kind stays on screen, including the ones at zero. A chip that
            // vanished at zero could never be switched back off, and its absence read
            // as "there is no such data" when it only meant "you filtered it away".
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.sm) {
                    ForEach(SearchHit.Kind.allCases, id: \.self) { kind in
                        kindChip(kind, count: digest.counts[kind] ?? 0)
                    }
                }
                .padding(.vertical, 1)
            }

            // Top apps in this period — tap to narrow to "Xcode only", etc.
            let apps = digest.appCounts.sorted { $0.value > $1.value }.prefix(8)
            // A selected app with nothing in this period stays visible too, or the
            // narrowing that is hiding everything becomes invisible.
            let strandedApps = selectedApps.subtracting(digest.appCounts.keys).sorted()
            if !apps.isEmpty || !selectedApps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.sm) {
                        if !selectedApps.isEmpty {
                            Button { withAnimation(.easeOut(duration: 0.15)) { selectedApps.removeAll() } } label: {
                                Text("All apps").font(DS.miniMedium).foregroundStyle(DS.moon)
                                    .padding(.horizontal, DS.sm).padding(.vertical, DS.xs)
                                    .background(Capsule().fill(DS.moon.opacity(0.10)))
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(Array(apps), id: \.key) { app, count in
                            appChip(app, count: count)
                        }
                        ForEach(strandedApps, id: \.self) { app in
                            appChip(app, count: 0)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            if filtersActive { activeFilterNotice }
        }
    }

    /// States plainly that this is a narrowed view — the antidote to a filter set three
    /// queries ago quietly producing "there is nothing here".
    private var activeFilterNotice: some View {
        HStack(spacing: DS.xs) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(DS.iconMini)
            Text(narrowingSummary)
                .font(DS.miniFont)
            Spacer(minLength: 0)
        }
        .foregroundStyle(DS.inkFaint)
    }

    private var narrowingSummary: String {
        var clauses: [String] = []
        if timeRange != .all { clauses.append(timeRange.label) }
        if enabledKinds != allKinds {
            let names = SearchHit.Kind.allCases.filter(enabledKinds.contains).map(\.label)
            clauses.append(names.isEmpty ? "no kinds" : names.joined(separator: ", "))
        }
        if !selectedApps.isEmpty { clauses.append(selectedApps.sorted().joined(separator: ", ")) }
        let scope = clauses.isEmpty ? "" : " — \(clauses.joined(separator: " · "))"
        // "matched", not "showing": this counts what the filters let through, and the
        // timeline lists at most `rowsPerDay` of them per day. Calling that a count of
        // what is on screen was simply false whenever a day ran long — and the days
        // that run long say so themselves now.
        return "Filters are narrowing this search: \(digest.shown) of \(digest.inPeriod) matched\(scope)"
    }

    /// The dead end made walkable — the way out sits inside the empty state itself.
    /// The count and the cause are on the notice directly above, so this says neither.
    private var noMatchesWithFilters: some View {
        VStack(spacing: DS.sm) {
            Text("Nothing matches inside these filters.")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkFaint)
            resetFiltersButton
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.lg)
    }

    private func appChip(_ app: String, count: Int) -> some View {
        let on = selectedApps.contains(app)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if on { selectedApps.remove(app) } else { selectedApps.insert(app) }
            }
        } label: {
            HStack(spacing: DS.xs) {
                // A single dot of the icon's stipple, in place of a stock glyph:
                // the chip's colour already says on/off, the label says which app.
                Circle().frame(width: 4, height: 4)
                Text(app).font(DS.miniMedium)
                Text("\(count)").font(DS.miniFont)
                    .foregroundStyle(on ? DS.moon.opacity(0.7) : DS.inkFaint)
            }
            .foregroundStyle(on ? DS.moon : DS.inkDim)
            .opacity(count == 0 && !on ? 0.55 : 1)
            .padding(.horizontal, DS.sm)
            .padding(.vertical, DS.xs)
            .background(Capsule().fill(on ? DS.moon.opacity(0.16) : DS.surface))
            .overlay(Capsule().strokeBorder(on ? DS.moon.opacity(0.3) : DS.hairline, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        // On/off was a tobacco fill and nothing else — no tooltip, no glyph change.
        .help(on ? "Hide \(app)" : "Show only \(app)")
        .accessibilityLabel(app)
        .accessibilityValue(on ? "Filtering to this app" : "Not filtered")
        .accessibilityHint("\(count) results")
    }

    private func kindChip(_ kind: SearchHit.Kind, count: Int) -> some View {
        let on = enabledKinds.contains(kind)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if on { enabledKinds.remove(kind) } else { enabledKinds.insert(kind) }
            }
        } label: {
            HStack(spacing: DS.xs) {
                Circle().frame(width: 4, height: 4)
                Text(kind.label).font(DS.miniMedium)
                Text("\(count)").font(DS.miniFont)
                    .foregroundStyle(on ? kind.color.opacity(0.7) : DS.inkFaint)
            }
            .foregroundStyle(on ? kind.color : DS.inkFaint)
            // A zero chip is dimmed, never removed: it still reports "none of this kind
            // in this period", and it still toggles.
            .opacity(count == 0 && !on ? 0.55 : 1)
            .padding(.horizontal, DS.sm)
            .padding(.vertical, DS.xs)
            .background(Capsule().fill(on ? kind.color.opacity(0.16) : DS.surface))
            .overlay(Capsule().strokeBorder(on ? kind.color.opacity(0.3) : DS.hairline, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .help(on ? "Hide \(kind.label)" : "Show \(kind.label)")
    }

    // MARK: - Timeline

    private var timelineResults: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Text("TIMELINE")
                .sectionLabel()

            ForEach(digest.days) { day in
                VStack(alignment: .leading, spacing: DS.xs) {
                    Text(day.label)
                        .font(DS.captionMedium)
                        .foregroundStyle(DS.inkDim)

                    ForEach(day.rows) { row in
                        timelineRow(row)
                    }

                    if day.hidden > 0 {
                        Button { onOpenDay(day.id) } label: {
                            Text("\(day.hidden) more on this day — open it")
                                .font(DS.miniFont)
                                .foregroundStyle(DS.moon)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, DS.xs)
                        .help("This day has more matches than the timeline lists")
                    }
                }
                .mullCard()
            }
        }
    }

    /// One interaction model, not two: the row is a plain tappable row that opens the
    /// day. Selecting the text with the mouse used to fight the tap — `.textSelection`
    /// inside a `Button` makes a drag both a selection and a click — so copying moved
    /// to the context menu, where it cannot be triggered by accident.
    private func timelineRow(_ row: Row) -> some View {
        Button { onOpenDay(row.date) } label: {
            HStack(alignment: .top, spacing: DS.sm) {
                Text(row.time)
                    .font(DS.microFont)
                    .foregroundStyle(DS.inkGhost)
                    .frame(width: 48, alignment: .trailing)

                kindBadge(row.kind)

                VStack(alignment: .leading, spacing: DS.hair) {
                    if let detail = row.detail, !detail.isEmpty {
                        Text(detail)
                            .font(DS.miniMedium)
                            .foregroundStyle(DS.inkFaint)
                    }
                    Text(row.text)
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkDim)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(DS.iconMini)
                    .foregroundStyle(DS.inkGhost)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(SearchService.dayLabel(Calendar.current.startOfDay(for: row.date))) in Calendar")
        .contextMenu {
            Button("Copy text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.plain, forType: .string)
            }
            .disabled(row.plain.isEmpty)
            Button("Open in Calendar") { onOpenDay(row.date) }
        }
    }

    /// A small coloured pill naming the kind of hit (Typed / Copied / Window / Schedule…).
    private func kindBadge(_ kind: SearchHit.Kind) -> some View {
        HStack(spacing: DS.xs) {
            Circle().frame(width: 4, height: 4)
            Text(kind.label).font(DS.miniMedium)
        }
        .foregroundStyle(kind.color)
        .padding(.horizontal, DS.xs)
        .padding(.vertical, DS.radiusXs)
        .background(Capsule().fill(kind.color.opacity(0.14)))
        .fixedSize()
    }

    // MARK: - Summaries

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
                            .foregroundStyle(DS.inkDim)
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
}
