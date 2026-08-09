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
// The page reads top to bottom in three layers, by who wrote each line:
//   what you told mull   — the setup answers, edited here (they used to live
//                          behind a section in General *also* called "Profile",
//                          so the word pointed at two different places)
//   what mull observed   — read-only; it changes as you work, not by hand
//   what mull wrote      — the nightly notes, correctable line by line
// Every section says which layer it is in, in the title row, so "can I change
// this?" is answered where the eye already is.
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

    // Correction state for "Notes mull keeps".
    @State private var editingID: Int64?
    @State private var draftName = ""
    @State private var draftDescription = ""
    @State private var draftContent = ""
    @State private var pendingDeletion: MemoryEntry?
    /// A forget that didn't happen. The row stays on screen; this says why.
    @State private var forgetProblem: String?

    // The setup answers, edited on this tab because this is the tab named
    // "Profile" — see the header comment.
    @State private var showAnswersEditor = false
    @State private var showResetConfirm = false
    @State private var answersResetDone = false
    /// Clears the "cleared" confirmation. A success message that never leaves
    /// stops being a confirmation and becomes a permanent label.
    @State private var resetNoticeTask: Task<Void, Never>?

    private enum LoadPhase { case idle, loading, loaded }

    /// The answer to "can I change this line?", carried in every section's
    /// title row. Read-only stays faint; the two markers that name an action
    /// you can take here (or in your own file) carry the accent.
    private enum Access {
        case yours        // your words — edit them whenever you like
        case observed     // measurements; they follow what you do, not a pencil
        case correctable  // mull's words about you, correctable line by line

        var label: String {
            switch self {
            case .yours:       "yours to edit"
            case .observed:    "observed · read-only"
            case .correctable: "mull's words · correctable"
            }
        }

        var tint: Color { self == .observed ? DS.inkFaint : DS.moon }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.xxl) {
                header

                // Layer one — your own words — needs no database read, so it is
                // never behind the loading state.
                answersSection

                if phase == .idle || (phase == .loading && loadedAt == nil) {
                    loadingBlock
                } else {
                    // Beside the answers, not below the portrait: these are also
                    // your words, and pinned junk on a fresh install is exactly
                    // the case where the portrait is empty and the user most
                    // needs to be told why.
                    withheldPinnedSection
                    if isPortraitEmpty {
                        emptyBlock
                    } else {
                        todaySection
                        summarySection
                        factsSection
                        rhythmSection
                        attentionSection
                        languageSection
                        wordsSection
                    }
                    notesSection
                }
            }
            .frame(maxWidth: DS.readMeasure, alignment: .leading)
            .padding(.horizontal, DS.xl)
            .padding(.top, DS.xl)
            .padding(.bottom, DS.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refreshIfStale() }
        .sheet(isPresented: $showAnswersEditor) {
            ProfileAnswersEditor { answers in
                OnboardingProfile.save(answers)
                appState.regenerateContextNow()
                // The withheld-lines section reads me.pinned.md, which this
                // just rewrote; re-read rather than showing the old file.
                Task { await refresh() }
            }
        }
        .onDisappear { resetNoticeTask?.cancel() }
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
        .alert(
            "Couldn't forget that",
            isPresented: Binding(get: { forgetProblem != nil },
                                 set: { if !$0 { forgetProblem = nil } })
        ) {
            Button("OK", role: .cancel) { forgetProblem = nil }
        } message: {
            Text(forgetProblem ?? "")
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

            // The three kinds of line used to be spelled out here as well as on every
            // section's title row. The markers do that job in place; this says only
            // the thing none of them says.
            Text("Every section says whose lines it holds. mull holds all of it for you — it owns none of it.")
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

    // MARK: - What you told mull

    /// The setup answers — moved here from a section in General that was also
    /// called "Profile", so that the tab named for you is where you are edited.
    /// Editing opens a sheet, not the setup wizard: no step counter, and closing
    /// it lands back on this tab.
    private var answersSection: some View {
        section("What you told mull", period: nil, access: .yours) {
            Text("Your answers from setup sit at the top of me.md via me.pinned.md, and capture never overwrites them — clear one and mull goes back to inferring it from what you do.")
                .font(DS.bodyFont)
                .foregroundStyle(DS.inkDim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DS.md) {
                Button("Edit answers…") { showAnswersEditor = true }
                    .buttonStyle(.plain)
                    .font(DS.captionMedium)
                    .foregroundStyle(DS.moon)

                Button("Reset answers") { showResetConfirm = true }
                    .buttonStyle(.plain)
                    .font(DS.captionMedium)
                    .foregroundStyle(OnboardingProfile.hasAnswers ? DS.error : DS.inkFaint)
                    .disabled(!OnboardingProfile.hasAnswers)

                Spacer(minLength: DS.sm)

                if answersResetDone {
                    Label("Cleared from me.pinned.md", systemImage: "checkmark.circle.fill")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.recording)
                        .transition(.opacity)
                }
            }
            .padding(.top, DS.xs)
            .animation(.easeInOut(duration: 0.2), value: answersResetDone)
            .confirmationDialog(
                "Clear your profile answers?",
                isPresented: $showResetConfirm
            ) {
                Button("Clear answers", role: .destructive) { resetAnswers() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything you told mull at setup — your role, working language, what you're building, how you want AI to answer — is removed from me.pinned.md. Anything you wrote in that file by hand is kept. mull will go back to inferring these from what you do.")
            }
        }
    }

    private func resetAnswers() {
        OnboardingProfile.reset()
        appState.regenerateContextNow()
        answersResetDone = true
        resetNoticeTask?.cancel()
        resetNoticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            answersResetDone = false
        }
        // The withheld-lines section reads the file this just rewrote.
        Task { await refresh() }
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
            StippleRings.roundel()
                .frame(width: 56, height: 56)
                .opacity(0.5)
                .padding(.bottom, DS.xs)
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
            // Named precisely: `isRecordingDegraded` is set by the CGEvent tap's
            // own health check, which is Input Monitoring. Blaming Accessibility
            // here sent people to a pane where the switch was already on.
            return "Keystroke capture has stopped — Input Monitoring was most likely turned off for mull in System Settings › Privacy & Security. Clipboard and window titles are still being kept, but the words and the rhythm below are read from keystrokes."
        }
        return "Recording is on, but the \(Self.windowLabel) hold too little to say anything honest. A few hours of ordinary work is usually enough."
    }

    // MARK: - Today

    @ViewBuilder
    private var todaySection: some View {
        let scheduleLines = todaySchedule.map(Self.parseSchedule) ?? []

        if dayShape != nil || !scheduleLines.isEmpty {
            section("Today", period: "today", access: .observed) {
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
            section("Today's summary", period: "today", access: .observed) {
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
            // "Not published from me.pinned.md" led with a filename; the reader's
            // question is "why isn't my line showing up?", so the title now
            // answers in terms of the file they actually hand to an AI.
            section("Left out of me.md", period: nil, access: .yours) {
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
    private var factsSection: some View {
        if !facts.isEmpty {
            // Titled for what the extractor actually emits — observed facts —
            // not "What mull reads in you", which promised an interpretation
            // this screen deliberately does not make (FactExtractor is
            // observation-only; the inferences were deleted in 2026-07).
            section("Facts", period: Self.windowLabel, access: .observed) {
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
        section("Rhythm", period: Self.windowLabel, access: .observed) {
            let lines = [
                InsightPhrases.activityInsight(hourly: hourly),
                // Passed explicitly, though it currently equals the parameter's
                // default: the phrase decides which weekdays have actually elapsed
                // from this number, so a window widened here and not there would
                // have it silently describing days that never happened.
                InsightPhrases.weekdayInsight(weekday: weekday, windowDays: Self.windowDays)
            ].compactMap { $0 }

            if lines.isEmpty {
                quiet("Not enough was recorded to describe a rhythm. It takes several days with activity before a shape is real rather than an accident of when mull happened to be running.")
            } else {
                prose(lines)
            }
        }
    }

    // MARK: - Attention

    private var attentionSection: some View {
        section("Where your attention went", period: Self.windowLabel, access: .observed) {
            if appUsage.isEmpty {
                quiet("No application switches were recorded, so there is nothing to apportion.")
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
                                .help(app.appName)
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
        section("Language", period: Self.windowLabel, access: .observed) {
            let total = langMix.japanesePercent + langMix.englishPercent + langMix.codePercent
            if total <= 0 {
                quiet("Nothing was copied, and the language mix is read from what you copy.")
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
        section("Words", period: Self.windowLabel, access: .observed) {
            if keywords.isEmpty {
                quiet("No recurring words yet. This is read from keystrokes and copies, and there aren't enough of them to call anything frequent.")
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

    // MARK: - Notes mull keeps

    private var notesSection: some View {
        // "Held for you" named the sentiment and not the thing; a reader scanning
        // for "where are the AI-written notes?" had no word to catch on.
        section("Notes mull keeps", period: nil, access: .correctable) {
            Text("Written during the nightly summary. They are about you and therefore yours.")
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

        if !HeldMemoryStore.save(updated, database: appState.database) {
            forgetProblem = "“\(updated.name)” was corrected in mull's memory, but its file "
                + "in ~/mull/memory could not be written — that copy still has the old wording."
        }
        memories[index] = updated
        editingID = nil
    }

    private func forget(_ memory: MemoryEntry) {
        pendingDeletion = nil
        guard HeldMemoryStore.forget(memory, database: appState.database) else {
            // The memory stays in the list because it is, in fact, still there.
            forgetProblem = "“\(memory.name)” could not be removed — its file in ~/mull/memory is still in place."
            return
        }
        memories.removeAll { $0.id == memory.id }
        if editingID == memory.id { editingID = nil }
    }

    // MARK: - Composition

    /// An editorial section: a letterspaced label carrying its own period, a
    /// hairline rule, then prose. No card, no grid, no frame.
    ///
    /// `access` is required, not defaulted: every section must answer "can I
    /// change this?" in its title row, because mixing editable and read-only
    /// prose with no marking is what made this screen hard to trust.
    private func section<Content: View>(
        _ title: String,
        period: String?,
        access: Access,
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
                Spacer(minLength: DS.sm)
                Text(access.label)
                    .font(DS.captionFont)
                    .foregroundStyle(access.tint)
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

        guard !Task.isCancelled else {
            // Leaving the tab cancels the `.task` driving this, but a TabView keeps
            // the tab's `@State` — so bailing without putting the phase back left it
            // on `.loading` forever. `refreshIfStale` then refused to run (it bails
            // on `.loading`) and "Read again" was disabled with it, and the tab
            // showed the loading block until the Settings window was closed and
            // opened again.
            phase = .idle
            return
        }
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

// MARK: - Profile Answers Editor
//
// The same questions the setup wizard asks, edited in place. It is explicitly
// *not* the wizard: no step counter (there are no steps), no "Save & Continue"
// leading somewhere else, and closing it returns to the Profile tab — because
// that is where the user was. Answers are the user's stated priors; nothing is
// required. (Lives here because this tab is its only presenter; it used to sit
// in SettingsView beside a General-tab section that duplicated this surface.)

struct ProfileAnswersEditor: View {
    /// Called with the edited answers when the user commits.
    let onSave: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var answers: [String: String] = [:]
    @State private var original: [String: String] = [:]
    @State private var showDiscardConfirm = false

    private var isDirty: Bool {
        OnboardingProfile.questions.contains { q in
            (answers[q.id] ?? "") != (original[q.id] ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            VStack(alignment: .leading, spacing: DS.xs) {
                Text("Your profile answers")
                    .font(DS.titleFont)
                    .foregroundStyle(DS.ink)
                Text("Change anything; clear a field to drop that fact. Every one is optional, and capture keeps refining the rest.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DS.lg) {
                    ForEach(OnboardingProfile.questions) { q in
                        VStack(alignment: .leading, spacing: DS.xs) {
                            Text(q.prompt).font(DS.bodyMedium).foregroundStyle(DS.ink)
                            Text(q.hint).font(DS.captionFont).foregroundStyle(DS.inkFaint)
                            TextField(q.placeholder, text: Binding(
                                get: { answers[q.id] ?? "" },
                                set: { answers[q.id] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(.vertical, DS.xs)
                .padding(.trailing, DS.sm)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    if isDirty { showDiscardConfirm = true } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)

                Button("Save answers") {
                    onSave(answers)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.xl)
        .frame(width: 460, height: 520)
        .background(DS.canvas)
        .onAppear {
            answers = OnboardingProfile.answers
            original = answers
        }
        .confirmationDialog("Discard your changes?", isPresented: $showDiscardConfirm) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("The edits you just made to your answers won't be saved.")
        }
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

    /// Returns whether the file half landed too. `forget` in this same type is
    /// careful to report a half-done deletion; this used to discard the write error
    /// with `try?`, so an unwritable vault left the row corrected in the database and
    /// on screen while `~/mull/memory/` kept mull's old wording — under a caption
    /// promising the correction had reached both.
    @discardableResult
    static func save(_ entry: MemoryEntry, database: DatabaseService) -> Bool {
        database.updateMemory(entry)
        do {
            try body(for: entry).write(
                to: MullDirectory.url(for: entry.filePath),
                atomically: true,
                encoding: .utf8
            )
            return true
        } catch {
            return false
        }
    }

    /// File first, row second, and the row only if the file went: a row without
    /// a file is an orphan the UI can't show, but a file without a row is
    /// forgotten text still sitting in the vault — the worse failure for a
    /// forget control. Returns whether both halves happened, so the caller can
    /// keep showing the memory instead of pretending it's gone.
    static func forget(_ entry: MemoryEntry, database: DatabaseService) -> Bool {
        // Keyed by filePath, not by name: two notes can share a name, and
        // deleting by name would wipe both rows while removing only one file.
        guard MullDirectory.delete(entry.filePath) else { return false }
        return database.deleteMemory(entry)
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
