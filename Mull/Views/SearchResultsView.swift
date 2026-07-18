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
/// narrowing to still be there when they type their next query.
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

    var body: some View {
        let matchingProjects = SearchService.matchingProjects(projects, query: query)
        let ranged = SearchService.inRange(hits, range: timeRange)
        let counts = SearchService.kindCountMap(ranged)
        let appCounts = SearchService.appCountMap(ranged)
        let shown = SearchService.timelineHits(hits, range: timeRange,
                                               kinds: enabledKinds, apps: selectedApps)

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

            if !hits.isEmpty {
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

            if !summaries.isEmpty {
                summarySearchResults(summaries)
            }

            if matchingProjects.isEmpty && hits.isEmpty && summaries.isEmpty && isRunning {
                HStack(spacing: DS.sm) {
                    ProgressView().controlSize(.small)
                    Text("Searching your record…")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else if matchingProjects.isEmpty && hits.isEmpty && summaries.isEmpty {
                VStack(spacing: DS.md) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.heroFont)
                        .foregroundStyle(.quaternary)
                    Text("No results for \"\(query)\"")
                        .font(DS.bodyFont)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            }
        }
    }

    // MARK: - Filters

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

    // MARK: - Timeline

    private func timelineResults(_ hits: [SearchHit]) -> some View {
        let grouped = Dictionary(grouping: hits) { Calendar.current.startOfDay(for: $0.date) }
        let days = grouped.keys.sorted(by: >)

        return VStack(alignment: .leading, spacing: DS.md) {
            Text("TIMELINE")
                .sectionLabel()

            ForEach(days, id: \.self) { day in
                VStack(alignment: .leading, spacing: DS.xs) {
                    Text(SearchService.dayLabel(day))
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
                Text(SearchService.timeLabel(hit.date))
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
                    Text(hit.text.isEmpty ? AttributedString("—") : SearchService.highlighted(hit.text, query: query))
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
        .help("Open \(SearchService.dayLabel(Calendar.current.startOfDay(for: hit.date))) in Calendar")
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
}
