import SwiftUI

// MARK: - Insights — the portrait mull holds of you, open to correction
//
// This screen used to be an instrument panel: a 2×2 grid of chart cards, a
// weighted keyword cloud, an unlabelled mix of 7-day and 30-day windows, and a
// count set at heading scale that read as a productivity score.
// DESIGN-NORTHSTAR §1 (Il bello) forbids "計器盤・カードの羅列"; CLAUDE.md §3.6
// forbids the dashboard register outright. What belongs here is a *written
// portrait* — the same measurements, carried by sentences and editorial
// hierarchy instead of by cards and bars.
//
// Three rules this file keeps:
//   1. Every figure names the period it covers, and every figure is drawn from
//      the same window, so no two lines can silently disagree.
//   2. Nothing internal reaches the page — neither the marker strings the
//      services append for the AI context files ("← NOW") nor mull's own
//      debug measurements (LLM processing seconds).
//   3. What mull holds is correctable in place. The right to correct is an
//      action on this screen, not a sentence about one.
//
// One screen, one name. This was `InsightsTab` in code, "Profile" on its tab and
// "Your portrait" in its heading — three names for one place, so a bug report and
// the code that fixes it had no word in common. "Profile" wins because that is
// what the spec calls the tab (CLAUDE.md §5). "Portrait" is left to the Home hero,
// where DESIGN-NORTHSTAR reserves 肖像 for the me.md surface.

struct ProfileTab: View {
    @EnvironmentObject var appState: AppState

    /// The one window every statistic on this screen is drawn from.
    ///
    /// Keywords, apps, hours and language used to be 7-day while the weekday
    /// rhythm was 30-day, with nothing on screen saying so — a month of your life
    /// quoted beside a week of it as though they were the same measurement. One
    /// window, named at every section, is the only honest version.
    private static let windowDays = 7
    private static let windowLabel = "last 7 days"

    @State private var keywords: [KeywordStat] = []
    @State private var appUsage: [AppUsageStat] = []
    @State private var hourly: [HourlyStat] = []
    @State private var weekday: [WeekdayStat] = []
    @State private var langMix = LanguageMix(japanesePercent: 0, englishPercent: 0, codePercent: 0)
    @State private var facts: [Fact] = []
    /// Lines in me.pinned.md mull is declining to publish (see Curator.readPinned).
    @State private var withheldPinned: [String] = []
    // Everything below used to be computed inside `body`: a TimeBlockEngine day
    // analysis, a memories fetch, and a blocking EventKit call — all re-running on
    // every redraw. They're loaded off the main thread, into state.
    @State private var dayShape: String?
    @State private var memories: [MemoryEntry] = []
    @State private var todaySchedule: String?

    // Loading is a state, not an absence. Without it the old cards were
    // indistinguishable from permanently empty ones, and the screen never
    // re-read after its first appearance.
    @State private var phase: LoadPhase = .idle
    @State private var loadedAt: Date?

    // Correction state for "Held for you".
    @State private var editingID: Int64?
    @State private var draftName = ""
    @State private var draftDescription = ""
    @State private var draftContent = ""
    @State private var pendingDeletion: MemoryEntry?

    private enum LoadPhase { case idle, loading, loaded }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.xxl) {
                header

                if phase == .idle || (phase == .loading && loadedAt == nil) {
                    loadingBlock
                } else {
                    if isPortraitEmpty {
                        emptyBlock
                    } else {
                        todaySection
                        summarySection
                        characterSection
                        rhythmSection
                        attentionSection
                        languageSection
                        wordsSection
                    }
                    // Outside the empty/portrait branch on purpose: pinned junk on
                    // a fresh install is exactly the case where the portrait is
                    // empty and the user most needs to be told why.
                    withheldPinnedSection
                    heldForYouSection
                }
            }
            .frame(maxWidth: DS.readMeasure, alignment: .leading)
            .padding(.horizontal, DS.xl)
            .padding(.top, DS.xl)
            .padding(.bottom, DS.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refreshIfStale() }
        .confirmationDialog(
            "Forget this?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { entry in
            Button("Forget “\(entry.name)”", role: .destructive) { forget(entry) }
            Button("Keep", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("The note leaves mull's memory and its file is removed from ~/mull/memory. Your recorded events are untouched.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your profile")
                    .font(DS.heroFont)
                Spacer()
                refreshButton
            }

            Text("Everything below is drawn from the \(Self.windowLabel) of recording, and from nothing else. Where a line is wrong, correct it — mull holds this for you, it does not own it.")
                .font(DS.bodyFont)
                .foregroundStyle(DS.inkDim)
                .fixedSize(horizontal: false, vertical: true)

            // Not a score. This is a raw row count — one row per keystroke line,
            // clipboard copy, window change or app switch. It used to sit at
            // heading scale next to the word "events", where a quiet morning read
            // as "1 events" and a busy one as an achievement. It survives only as
            // a footnote about capture, named for what it actually counts.
            Text(recordCountLine)
                .font(DS.captionFont)
                .foregroundStyle(DS.inkFaint)

            if let loadedAt {
                Text("Read at \(Self.timeFormatter.string(from: loadedAt)).")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
            }
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await refresh() }
        } label: {
            HStack(spacing: DS.xs) {
                Image(systemName: "arrow.clockwise")
                    .font(DS.captionFont)
                Text(phase == .loading ? "Reading…" : "Read again")
                    .font(DS.captionMedium)
            }
            .foregroundStyle(phase == .loading ? DS.inkFaint : DS.moon)
        }
        .buttonStyle(.plain)
        .disabled(phase == .loading)
        .help("Re-read the \(Self.windowLabel)")
    }

    private var recordCountLine: String {
        "\(appState.todayCaptureLabel) kept today — keystroke lines, copies, window and app changes."
    }

    // MARK: - Loading and emptiness

    private var loadingBlock: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading the \(Self.windowLabel)…")
                    .font(DS.bodyFont)
                    .foregroundStyle(DS.inkDim)
            }
            Text("Several passes over the recorded events, and today's calendar. On a full log it takes a moment.")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DS.lg)
    }

    /// True when there is genuinely nothing to say — as distinct from "still
    /// reading", which the old screen could not tell apart from "empty".
    private var isPortraitEmpty: Bool {
        facts.isEmpty && keywords.isEmpty && appUsage.isEmpty
            && hourly.allSatisfy { $0.eventCount == 0 }
            && dayShape == nil
    }

    private var emptyBlock: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("Nothing has taken shape yet")
                .font(DS.readH2Font)
            Text(emptyReason)
                .font(DS.readFont)
                .lineSpacing(DS.readLineSpacing)
                .foregroundStyle(DS.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DS.lg)
    }

    /// An empty screen has to say *why* it is empty. Silence that could equally
    /// mean "no data yet", "recording is off" or "permission was revoked" leaves
    /// the reader to guess about their own record.
    private var emptyReason: String {
        if !appState.isRecording {
            return "Recording is off, so the \(Self.windowLabel) hold nothing to draw from. Start it in Live, and a portrait begins to form after a few hours of ordinary work."
        }
        if appState.isPaused {
            return "Recording is paused. Nothing is being kept, and nothing new will appear here until you resume."
        }
        if appState.isRecordingDegraded {
            return "Keystroke capture has stopped — Accessibility permission was most likely revoked in System Settings › Privacy & Security. Clipboard and window titles are still being kept, but the words and the rhythm below are read from keystrokes."
        }
        return "Recording is on, but the \(Self.windowLabel) hold too little to say anything honest. A few hours of ordinary work is usually enough."
    }

    // MARK: - Today

    @ViewBuilder
    private var todaySection: some View {
        let scheduleLines = todaySchedule.map(Self.parseSchedule) ?? []

        if dayShape != nil || !scheduleLines.isEmpty {
            section("Today", period: "today") {
                if let shape = dayShape {
                    Text(shape)
                        .font(DS.readFont)
                        .lineSpacing(DS.readLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !scheduleLines.isEmpty {
                    VStack(alignment: .leading, spacing: DS.sm) {
                        ForEach(scheduleLines) { line in
                            scheduleRow(line)
                        }
                    }
                    .padding(.top, DS.xs)
                }
            }
        }
    }

    private func scheduleRow(_ line: ScheduleLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
            // The present moment is a typographic rule and a weight, never a
            // coloured dot and never the marker string the service appends.
            Rectangle()
                .fill(line.isNow ? DS.nowLine : Color.clear)
                .frame(width: DS.hair, height: 13)

            Text(line.text)
                .font(line.isNow ? DS.bodyMedium : DS.bodyFont)
                .foregroundStyle(line.isNow ? DS.ink : DS.inkDim)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: DS.sm)

            if let note = line.note {
                Text(note)
                    .font(DS.captionFont)
                    .foregroundStyle(line.isNow ? DS.moon : DS.inkFaint)
            }
        }
    }

    // MARK: - Today's summary

    @ViewBuilder
    private var summarySection: some View {
        if let summary = appState.todaySummary {
            // The model's processing duration ("43s") used to sit in this header.
            // That is a measurement of mull's night, not of your day; it belongs
            // in the log, not on the page.
            section("Today's summary", period: "today") {
                SummaryContent(summary: summary)
            }
        }
    }

    // MARK: - What mull reads in you

    /// What mull is declining to publish from the user's own pinned file.
    ///
    /// `Curator.readPinned` filters me.pinned.md at read time and never edits it.
    /// Filtering silently would be the worse failure of the two: the user would
    /// have written a line, seen it vanish from me.md, and had no way to know
    /// why. So the withheld lines are shown back, verbatim, with the reason.
    @ViewBuilder
    private var withheldPinnedSection: some View {
        if !withheldPinned.isEmpty {
            section("Not published from me.pinned.md", period: nil) {
                VStack(alignment: .leading, spacing: DS.xs) {
                    Text(withheldPinned.count == 1
                         ? "One line carries no information, so it is being left out of me.md. Your file is unchanged — edit it to replace this."
                         : "\(withheldPinned.count) lines carry no information, so they are being left out of me.md. Your file is unchanged — edit it to replace them.")
                        .font(DS.readFont)
                        .lineSpacing(DS.readLineSpacing)
                        .foregroundStyle(DS.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(withheldPinned.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(DS.microFont)
                            .foregroundStyle(DS.inkFaint)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var characterSection: some View {
        if !facts.isEmpty {
            section("What mull reads in you", period: Self.windowLabel) {
                VStack(alignment: .leading, spacing: DS.md) {
                    ForEach(FactCategory.allCases, id: \.self) { category in
                        let lines = facts.filter { $0.category == category }
                        if !lines.isEmpty {
                            VStack(alignment: .leading, spacing: DS.xs) {
                                Text(Self.categoryTitle(category))
                                    .font(DS.captionMedium)
                                    .foregroundStyle(DS.inkFaint)
                                ForEach(Array(lines.enumerated()), id: \.offset) { _, fact in
                                    Text(fact.text)
                                        .font(DS.readFont)
                                        .lineSpacing(DS.readLineSpacing)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func categoryTitle(_ category: FactCategory) -> String {
        switch category {
        case .identity: "Who you appear to be"
        case .skills:   "What you work with"
        case .projects: "What you are working on"
        case .patterns: "How you work"
        }
    }

    // MARK: - Rhythm

    private var rhythmSection: some View {
        section("Rhythm", period: Self.windowLabel) {
            let lines = [
                InsightPhrases.activityInsight(hourly: hourly),
                // Passed explicitly, though it currently equals the parameter's
                // default: the phrase decides which weekdays have actually elapsed
                // from this number, so a window widened here and not there would
                // have it silently describing days that never happened.
                InsightPhrases.weekdayInsight(weekday: weekday, windowDays: Self.windowDays)
            ].compactMap { $0 }

            if lines.isEmpty {
                quiet("Not enough was recorded across the \(Self.windowLabel) to describe a rhythm. It takes several days with activity before a shape is real rather than an accident of when mull happened to be running.")
            } else {
                prose(lines)
            }
        }
    }

    // MARK: - Attention

    private var attentionSection: some View {
        section("Where your attention went", period: Self.windowLabel) {
            if appUsage.isEmpty {
                quiet("No application switches were recorded in the \(Self.windowLabel), so there is nothing to apportion.")
            } else {
                if let line = InsightPhrases.appUsageInsight(apps: appUsage) {
                    prose([line])
                }
                // An index set in type, not a bar chart: same figures, no gauge.
                VStack(alignment: .leading, spacing: DS.xs) {
                    ForEach(Array(appUsage.prefix(5))) { app in
                        HStack(alignment: .firstTextBaseline) {
                            Text(app.appName)
                                .font(DS.bodyFont)
                                .foregroundStyle(DS.inkDim)
                                .lineLimit(1)
                            Spacer(minLength: DS.md)
                            Text("\(Int(app.percentage.rounded()))%")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.inkFaint)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.top, DS.xs)
            }
        }
    }

    // MARK: - Language

    private var languageSection: some View {
        section("Language", period: Self.windowLabel) {
            let total = langMix.japanesePercent + langMix.englishPercent + langMix.codePercent
            if total <= 0 {
                quiet("Nothing was copied in the \(Self.windowLabel), and the language mix is read from what you copy.")
            } else {
                if let line = InsightPhrases.languageInsight(mix: langMix) {
                    prose([line])
                }
                Text(Self.languageBreakdown(langMix))
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .padding(.top, DS.xs)
            }
        }
    }

    private static func languageBreakdown(_ mix: LanguageMix) -> String {
        var parts: [String] = []
        if mix.japanesePercent > 0 { parts.append("Japanese \(Int(mix.japanesePercent.rounded()))%") }
        if mix.englishPercent > 0 { parts.append("English \(Int(mix.englishPercent.rounded()))%") }
        if mix.codePercent > 0 { parts.append("code \(Int(mix.codePercent.rounded()))%") }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - Words

    private var wordsSection: some View {
        section("Words", period: Self.windowLabel) {
            if keywords.isEmpty {
                quiet("No recurring words yet. This is read from keystrokes and copies in the \(Self.windowLabel), and there aren't enough of them to call anything frequent.")
            } else {
                // A running line of type, not a weighted cloud. Frequencies stay
                // out of it: the ordering is the claim, and printing "haptics 41"
                // invites the reader to treat a tally as a score.
                if let line = InsightPhrases.keywordInsight(keywords: keywords) {
                    prose([line])
                }
                let rest = keywords.dropFirst(3).prefix(12).map(\.word)
                if !rest.isEmpty {
                    Text("Also recurring: \(rest.joined(separator: ", ")).")
                        .font(DS.bodyFont)
                        .foregroundStyle(DS.inkDim)
                        .lineSpacing(DS.xs)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, DS.xs)
                }
            }
        }
    }

    // MARK: - Held for you

    private var heldForYouSection: some View {
        section("Held for you", period: nil) {
            Text("Notes mull has written and kept about you. They are yours: change the wording, or have mull forget one entirely.")
                .font(DS.bodyFont)
                .foregroundStyle(DS.inkDim)
                .fixedSize(horizontal: false, vertical: true)

            if memories.isEmpty {
                quiet(appState.llmProvider == .off
                      ? "Nothing kept here yet. These notes are written during the nightly summary, which needs a language model — none is enabled, so mull is keeping the raw record only."
                      : "Nothing kept here yet. Notes are written after the nightly summary.")
            } else {
                VStack(alignment: .leading, spacing: DS.lg) {
                    ForEach(memories) { memory in
                        if editingID != nil && editingID == memory.id {
                            memoryEditor(memory)
                        } else {
                            memoryRow(memory)
                        }
                    }
                }
                .padding(.top, DS.sm)
            }
        }
    }

    private func memoryRow(_ memory: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            Text(memory.name)
                .font(DS.readH3Font)
                .fixedSize(horizontal: false, vertical: true)

            Text(memory.description)
                .font(DS.bodyFont)
                .foregroundStyle(DS.inkDim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DS.md) {
                // Provenance, previously absent altogether: when mull learned
                // this, and when it last changed.
                Text(Self.provenance(memory))
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)

                Spacer(minLength: DS.sm)

                Button("Correct") { beginEditing(memory) }
                    .buttonStyle(.plain)
                    .font(DS.captionMedium)
                    .foregroundStyle(DS.moon)

                Button("Forget") { pendingDeletion = memory }
                    .buttonStyle(.plain)
                    .font(DS.captionMedium)
                    .foregroundStyle(DS.error)
            }
            .padding(.top, DS.hair)
        }
    }

    private func memoryEditor(_ memory: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain)
                .font(DS.readH3Font)

            TextField("Description", text: $draftDescription)
                .textFieldStyle(.plain)
                .font(DS.bodyFont)
                .foregroundStyle(DS.inkDim)

            TextEditor(text: $draftContent)
                .font(DS.bodyFont)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 90)
                .padding(DS.sm)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusInset).fill(DS.surfaceHi)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusInset)
                        .strokeBorder(DS.hairline, lineWidth: 0.75)
                )

            HStack(spacing: DS.md) {
                Text("Your wording replaces mull's, in its memory and in ~/mull/\(memory.filePath).")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: DS.sm)

                Button("Cancel") { editingID = nil }
                    .buttonStyle(.plain)
                    .font(DS.captionMedium)
                    .foregroundStyle(DS.inkDim)

                Button("Save") { commitEditing(memory) }
                    .buttonStyle(.plain)
                    .font(DS.captionMedium)
                    .foregroundStyle(DS.moon)
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DS.md)
        .background(RoundedRectangle(cornerRadius: DS.radiusSm).fill(DS.surface))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusSm)
                .strokeBorder(DS.moon.opacity(0.22), lineWidth: 0.75)
        )
    }

    private static func provenance(_ memory: MemoryEntry) -> String {
        let learned = "Learned \(dayFormatter.string(from: memory.createdAt))"
        // The edit is only worth mentioning when it happened on a different day
        // from the first writing.
        if !Calendar.current.isDate(memory.updatedAt, inSameDayAs: memory.createdAt) {
            return learned + " · last changed \(dayFormatter.string(from: memory.updatedAt))"
        }
        return learned
    }

    // MARK: - Correction

    private func beginEditing(_ memory: MemoryEntry) {
        draftName = memory.name
        draftDescription = memory.description
        draftContent = memory.content
        editingID = memory.id
    }

    private func commitEditing(_ memory: MemoryEntry) {
        guard let index = memories.firstIndex(where: { $0.id == memory.id }) else {
            editingID = nil
            return
        }
        var updated = memories[index]
        updated.name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.description = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.content = draftContent
        updated.updatedAt = Date()

        HeldMemoryStore.save(updated, database: appState.database)
        memories[index] = updated
        editingID = nil
    }

    private func forget(_ memory: MemoryEntry) {
        HeldMemoryStore.forget(memory, database: appState.database)
        memories.removeAll { $0.id == memory.id }
        if editingID == memory.id { editingID = nil }
        pendingDeletion = nil
    }

    // MARK: - Composition

    /// An editorial section: a letterspaced label carrying its own period, a
    /// hairline rule, then prose. No card, no grid, no frame.
    private func section<Content: View>(
        _ title: String,
        period: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                Text(title)
                    .sectionLabel()
                if let period {
                    // Every figure on this screen states the window it covers.
                    Text(period)
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                }
            }

            Rectangle()
                .fill(DS.hairline)
                .frame(height: 0.75)
                .padding(.bottom, DS.xs)

            content()
        }
    }

    private func prose(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(DS.readFont)
                    .lineSpacing(DS.readLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(DS.bodyFont)
            .foregroundStyle(DS.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMMMy")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    // MARK: - Schedule parsing

    private struct ScheduleLine: Identifiable {
        let id = UUID()
        let text: String
        /// A human note ("in 12 min", "now") — never the raw marker.
        let note: String?
        let isNow: Bool
    }

    /// `CalendarService.todaySchedule()` builds a string for the *AI* context
    /// files and appends internal markers (" ← NOW", " ← in 12min") for that
    /// reader. This screen printed those lines verbatim, so the marker leaked
    /// onto the page. Markers are parsed off here and said typographically; an
    /// unrecognised future marker is dropped rather than shown.
    private static func parseSchedule(_ schedule: String) -> [ScheduleLine] {
        schedule.components(separatedBy: "\n").dropFirst().compactMap { raw -> ScheduleLine? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("- ") { line.removeFirst(2) }

            var isNow = false
            var note: String?

            if let marker = line.range(of: "←") {
                let tail = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
                line = String(line[..<marker.lowerBound]).trimmingCharacters(in: .whitespaces)

                if tail.caseInsensitiveCompare("NOW") == .orderedSame {
                    isNow = true
                    note = "now"
                } else if tail.hasPrefix("in ") {
                    note = tail.replacingOccurrences(of: "min", with: " min")
                }
            }

            guard !line.isEmpty else { return nil }
            return ScheduleLine(text: line, note: note, isNow: isNow)
        }
    }

    // MARK: - Reading

    /// Re-reads when the screen has gone stale, rather than exactly once per
    /// process. `.task` fires on every appearance, so coming back to this tab an
    /// hour later no longer shows an hour-old portrait with no way to refresh it.
    private func refreshIfStale() async {
        guard phase != .loading else { return }
        if phase == .loaded, let loadedAt, Date().timeIntervalSince(loadedAt) < 300 { return }
        await refresh()
    }

    /// The analytics passes, a day analysis, a memories fetch and an EventKit read —
    /// each one scans days of events. Running them synchronously from .onAppear froze
    /// the window on every visit to this tab; they run detached and publish once.
    private func refresh() async {
        phase = .loading

        let analytics = appState.analytics
        let database = appState.database
        let calendarService = appState.calendar
        let days = Self.windowDays

        let loaded = await Task.detached(priority: .userInitiated) { () -> (
            keywords: [KeywordStat], appUsage: [AppUsageStat], hourly: [HourlyStat],
            weekday: [WeekdayStat], langMix: LanguageMix, facts: [Fact],
            shape: String?, memories: [MemoryEntry], schedule: String?,
            withheldPinned: [String]
        ) in
            let dayAnalysis = TimeBlockEngine(database: database).analyzDay(for: Date())
            return (
                analytics.topKeywords(days: days, limit: 20),
                analytics.appUsage(days: days),
                analytics.hourlyPattern(days: days),
                // Was `days: 30` while every figure beside it was 7.
                analytics.weekdayPattern(days: days),
                analytics.languageMix(days: days),
                FactExtractor(analytics: analytics, database: database).extractFacts(days: days),
                Self.dayShapeLine(mainActivities: dayAnalysis.mainActivities.count,
                                  totalDuration: dayAnalysis.totalDuration),
                database.fetchAllMemories(),
                calendarService.todaySchedule(),
                Curator.readPinned().withheld
            )
        }.value

        guard !Task.isCancelled else { return }
        keywords = loaded.keywords
        appUsage = loaded.appUsage
        hourly = loaded.hourly
        weekday = loaded.weekday
        langMix = loaded.langMix
        facts = loaded.facts
        dayShape = loaded.shape
        memories = loaded.memories
        todaySchedule = loaded.schedule
        withheldPinned = loaded.withheldPinned
        loadedAt = Date()
        phase = .loaded
    }

    /// States what the day looked like. It does not tell you what kind of person
    /// you are — the old phrasing ("You have the ability to maintain deep focus")
    /// was a cold read, and mull does not get to characterise its owner.
    private static func dayShapeLine(mainActivities: Int, totalDuration: TimeInterval) -> String? {
        guard mainActivities > 0, totalDuration >= 600 else { return nil }
        let hours = Int(totalDuration) / 3600
        let minutes = (Int(totalDuration) % 3600) / 60
        let span = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        let threads = mainActivities == 1 ? "One main thread" : "\(mainActivities) main threads"
        return "\(threads) today, \(span) of activity."
    }
}

// MARK: - Writing back to what mull holds

/// Correction and deletion for the notes shown in "Held for you".
///
/// The database half goes through `DatabaseService`; this type owns the other
/// half — keeping the markdown file in `~/mull/memory/` in step with an edit
/// made from the UI. It mirrors exactly what `MullEngine.applyMemoryUpdate`
/// does for its "update" and "delete" actions, so a correction made by hand and
/// one made by the nightly pass leave identical state on disk and in the
/// database.
private enum HeldMemoryStore {

    static func save(_ entry: MemoryEntry, database: DatabaseService) {
        database.updateMemory(entry)
        try? body(for: entry).write(
            to: MullDirectory.url(for: entry.filePath),
            atomically: true,
            encoding: .utf8
        )
    }

    static func forget(_ entry: MemoryEntry, database: DatabaseService) {
        // Keyed by filePath, not by name: two notes can share a name, and
        // deleting by name would wipe both rows while removing only one file.
        try? FileManager.default.removeItem(at: MullDirectory.url(for: entry.filePath))
        database.deleteMemory(entry)
    }

    /// The same front matter MullEngine writes, so the file never drifts from the row.
    private static func body(for entry: MemoryEntry) -> String {
        """
        ---
        name: \(entry.name)
        description: \(entry.description)
        type: \(entry.memoryType.rawValue)
        ---

        \(entry.content)
        """
    }
}
