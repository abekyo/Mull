import SwiftUI

/// "Today, in your words" — the understudy's draft of today's report.
///
/// This is the first piece of work the understudy does *as you* rather than *about*
/// you, so it carries the dignity constraints with it: the draft never fires itself
/// (§3.6 — it waits for you to keep it, and nothing leaves this Mac unless you copy
/// it), it names what it learned your voice from, and your edit is always one tap
/// away because the edit is what teaches tomorrow's draft.
///
/// Two ways out write to reports/: "Keep this" approves the draft as written, and
/// "Edit → Save" replaces it with your own words. Only the second closes the fidelity
/// loop — the first is still the model's prose, is recorded as such, and is kept out
/// of tomorrow's voice samples (ReportWriter.Provenance). Both are measured: how far
/// the kept text moved from the draft is the fidelity number, and it is stated once,
/// quietly, under the report it describes.
///
/// State: the draft, its edit buffer and its error all live here rather than in
/// `HomeTab`, because nothing outside this card reads them. `appState` arrives by
/// environment exactly as it does for the rest of Home.
struct ReportCardView: View {
    @EnvironmentObject var appState: AppState

    @State private var draft: String? = nil
    @State private var loading = false
    @State private var editing = false
    @State private var buffer = ""
    @State private var copied = false
    @State private var error: String? = nil
    @State private var sources: [String] = []

    /// True when what's on screen is the *approved* report on disk — i.e. a voice
    /// sample. Without this the card could not tell the user's kept text apart from
    /// an unapproved machine draft, and the re-draft button would quietly overwrite
    /// the former with the latter.
    @State private var approved = false
    /// Live tokens of a re-draft in flight. Deliberately NOT `draft`: a generation
    /// that fails must leave the text the user was reading exactly where it was
    /// (see generate()).
    @State private var streaming: String? = nil
    /// Asked before a re-draft is allowed to replace an approved report.
    @State private var showRedraftConfirm = false

    /// The fidelity sentence for the kept report, held in state rather than computed
    /// in `body`: it reads a directory of JSON off disk, and SwiftUI re-evaluates a
    /// computed property on every redraw. Refreshed exactly where it can change.
    @State private var fidelityNote: String? = nil

    // MARK: Edit-session state
    //
    // The edit is the moat: it is the one thing in mull that is unambiguously the
    // user's own writing, and it is what tomorrow's draft learns from. So the
    // editing session is the most defended surface in the app — nothing here may
    // lose a word to a mis-click, a crash, or a closed window.

    /// The text the buffer started from. Anything else means unsaved work exists.
    @State private var baseline = ""
    /// Asked before throwing away unsaved words — never discarded on a bare click.
    @State private var showDiscardConfirm = false
    /// Debounces the autosave so a Keychain-style per-keystroke write doesn't lag typing.
    @State private var autosaveTask: Task<Void, Never>?
    /// When the buffer was last written to the recovery file — shown quietly.
    @State private var autosavedAt: Date?
    /// An unsaved edit found on disk at launch, waiting to be resumed or let go.
    @State private var recovered: String?
    /// The day this edit began, fixed for its whole length. Reading the clock afresh
    /// on each autosave meant an edit running past midnight scattered itself across
    /// two recovery files, only one of which anything ever cleaned up.
    @State private var editingDay = Date()

    private var writer: ReportWriter { ReportWriter(database: appState.database) }

    private var isDirty: Bool { buffer != baseline }

    /// Where an *in-progress, unapproved* edit is parked between keystrokes.
    ///
    /// Deliberately alongside the understudy's own draft cache, inside the hidden
    /// `.drafts` folder: `voiceSamples()` skips hidden entries, so a half-finished
    /// sentence can never be mistaken for an approved voice sample and poison the
    /// fidelity loop. It is removed the moment the edit is saved or let go.
    private func editBackupPath(for date: Date) -> String {
        // POSIX, because this is a path and not a sentence. `yyyy-MM-dd` alone is
        // resolved against the *user's* calendar, so a Mac set to the Japanese
        // imperial era writes `0008-07-19` and a draft saved under one calendar
        // setting can never be found again under another.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return "reports/.drafts/\(f.string(from: date))-editing.md"
    }

    // @AppStorage, not a bare UserDefaults read: a raw read isn't observable, so
    // switching a provider on in Settings left the "LLM is off" card up until some
    // unrelated state change happened to redraw Home.
    @AppStorage("llmProvider") private var llmProvider = "off"
    private var isLLMOff: Bool { llmProvider == "off" }

    var body: some View {
        card
            // An approved report wins; else tonight's cached auto-draft (先回り — it's
            // already there when you open mull in the evening).
            .onAppear { loadExisting() }
            // The understudy finished tonight's draft while Home was already open — show it
            // (only if the user hasn't generated/edited something themselves meanwhile).
            .onChange(of: appState.eveningDraftReady) { _, _ in
                if draft == nil, !loading, !editing,
                   let cached = writer.cachedDraft(for: Date()) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        draft = cached.text
                        sources = cached.sources
                        approved = false
                    }
                }
            }
    }

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack {
                Text("TODAY, IN YOUR WORDS").sectionLabel()
                Spacer()
                if draft != nil && !editing && !loading {
                    // Re-drafting an *approved* report throws away the user's own
                    // kept text and puts machine prose in its place. It used to do
                    // that on one click and cache the result, so the next onAppear
                    // brought the approved report back and the regenerated text
                    // vanished — two different texts swapping places with no way to
                    // tell which was yours. It asks first now.
                    Button { requestRedraft() } label: {
                        Image(systemName: "arrow.clockwise").font(DS.captionFont)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.inkFaint)
                    .help(approved ? "Asks first, then replaces your kept report with a new draft"
                                   : "Re-draft in my voice")
                    .accessibilityLabel("Re-draft report")
                }
            }

            if let err = error, !loading {
                HStack(spacing: DS.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(DS.paused)
                    Text(err)
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkDim)
                    Spacer()
                    // The only actionable thing in a failed state must read as a
                    // control, not as a word. Bordered + .small gives it an edge and
                    // a real hit target; the tint comes from the root `.tint(DS.moon)`.
                    // requestRedraft(), not generate(): a retry must respect a kept
                    // report exactly as the re-draft button does.
                    Button("Retry") { requestRedraft() }
                        .font(DS.captionFont)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(DS.sm)
                .background(RoundedRectangle(cornerRadius: DS.radiusSm).fill(DS.paused.opacity(0.08)))
            }

            // An edit that was interrupted (crash, quit, window closed) is offered
            // back before anything else can overwrite it. Words the user typed are
            // never dropped on the floor and never silently reinstated either —
            // they are handed back with the choice left to them.
            if let pending = recovered, !editing {
                recoveryRow(pending)
            }

            // Order matters. An open editor outranks everything: the LLM-off
            // notice used to sit first in this chain, so switching a provider off
            // mid-edit replaced the editor — and the user's unsaved words — with
            // an advert for turning it back on. Likewise a report that already
            // exists stays readable, editable and copyable with the LLM off; it
            // is the user's own text by then, and it does not need a model to be
            // shown back to them.
            if editing {
                editor
            } else if loading {
                VStack(alignment: .leading, spacing: DS.sm) {
                    HStack(spacing: DS.sm) {
                        ProgressView().controlSize(.small)
                        Text("Your understudy is drafting…")
                            .font(DS.captionFont).foregroundStyle(DS.inkDim)
                    }
                    // The new draft streams into its own buffer, so what is on
                    // screen here is provisional — the text being replaced is
                    // still intact behind it until this one finishes (generate()).
                    if let live = streaming, !live.isEmpty {
                        MarkdownView(live, titleFirstLine: false)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, DS.xs)
            } else {
                if isLLMOff { llmOffRow }

                if let text = draft, !text.isEmpty {
                    MarkdownView(text, titleFirstLine: false)
                        .textSelection(.enabled)
                    // Dignity: the understudy says what it learned the voice from.
                    if !sources.isEmpty {
                        Text("Voice learned from: " + sources.joined(separator: " · "))
                            .font(DS.miniFont)
                            .foregroundStyle(DS.inkGhost)
                    }

                    // The fidelity measurement, said once and quietly, only after the
                    // act it measures is complete. Same register as the provenance
                    // line above — no target, no trend arrow, no colour, nothing to
                    // beat (DESIGN-NORTHSTAR §1: no streaks, badges or points on a
                    // surface a human reads about their own life). It states what
                    // happened; whether that number is good is the user's to decide.
                    if approved, let note = fidelityNote {
                        Text(note)
                            .font(DS.miniFont)
                            .foregroundStyle(DS.inkGhost)
                    }

                    HStack(spacing: DS.md) {
                        // The fidelity loop only closes on a write to reports/, and
                        // for a long time the sole path there was Edit → Save. A user
                        // who liked the draft as written — the best case — had no way
                        // to keep it, so nothing was ever saved and tomorrow's draft
                        // learned nothing. Approving unedited is a first-class act.
                        if !approved {
                            Button { approve(text) } label: {
                                Label("Keep this", systemImage: "checkmark")
                                    .font(DS.captionFont)
                            }
                            .buttonStyle(.plain).foregroundStyle(DS.moon)
                            .help("Kept as written, it becomes tomorrow's voice sample")
                        } else {
                            Label("Kept", systemImage: "checkmark.circle")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.inkFaint)
                        }

                        Button { beginEditing(text) } label: {
                            Label("Edit", systemImage: "pencil").font(DS.captionFont)
                        }
                        .buttonStyle(.plain).foregroundStyle(DS.moon)

                        Button { copy(text) } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                                .font(DS.captionFont)
                        }
                        .buttonStyle(.plain).foregroundStyle(DS.moon)

                        Spacer()
                        // This line used to say "you send it", promising a send that
                        // does not exist — the only way out of this card is Copy.
                        // Say what actually happens instead: nothing leaves the Mac,
                        // and where it goes next is the user's own doing.
                        Text("drafted from today's activity · stays on this Mac until you copy it")
                            .font(DS.miniFont).foregroundStyle(DS.inkGhost)
                    }
                } else if !isLLMOff {
                    VStack(alignment: .leading, spacing: DS.sm) {
                        Text("Your understudy can draft it from what you did today.")
                            .font(DS.bodyFont).foregroundStyle(DS.inkDim)
                        Button { generate() } label: {
                            Label("Write today's report", systemImage: "square.and.pencil")
                                .font(DS.bodyMedium)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The rings as stationery watermark: this card is the understudy's letter,
        // and the letterhead is the record it was drafted from. Held at a whisper
        // so the report's own words stay the loudest thing on the paper.
        .background(
            StippleRings(center: CGPoint(x: 0.9, y: 0.1))
                .opacity(0.06)
                .clipped()
        )
        .mullCard()
        .confirmationDialog(
            "Replace your kept report with a new draft?",
            isPresented: $showRedraftConfirm
        ) {
            Button("Write a new draft", role: .destructive) { confirmRedraft() }
            Button("Keep mine", role: .cancel) {}
        } message: {
            Text("Today's report in ~/mull is the version you kept. A new draft would be written by your understudy, not by you, and would take its place. Your kept copy is set aside rather than deleted.")
        }
    }

    // MARK: - The editing surface
    //
    // This is a reading/writing surface, not a form field: DS.readFont and
    // DS.readLineSpacing exist precisely for it, and it gets a warm paper well
    // with a hairline rather than the default sunken box. Room to breathe means
    // the user can actually see the paragraph they are shaping.

    private var editor: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            TextEditor(text: $buffer)
                .font(DS.readFont)
                .lineSpacing(DS.readLineSpacing)
                .foregroundStyle(DS.ink)
                .scrollContentBackground(.hidden)
                .padding(DS.md)
                .frame(minHeight: 340)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusSm).fill(DS.surfaceHi)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusSm)
                        .strokeBorder(DS.hairline, lineWidth: 0.75)
                )
                // Autosave: every pause in typing parks the buffer on disk, so a
                // crash or an accidentally closed window costs at most a second
                // of words rather than the whole edit.
                .onChange(of: buffer) { _, _ in scheduleAutosave() }

            HStack(spacing: DS.md) {
                // Why the edit matters — said once, quietly, where it is true.
                Text(isDirty ? "Your edit becomes tomorrow's voice sample."
                             : "Edit freely — your words teach tomorrow's draft.")
                    .font(DS.miniFont)
                    .foregroundStyle(DS.inkFaint)

                Spacer()

                if let at = autosavedAt {
                    Text("Draft kept \(at.formatted(date: .omitted, time: .shortened))")
                        .font(DS.miniFont)
                        .foregroundStyle(DS.inkFaint)
                        .transition(.opacity)
                }

                Button("Cancel") { requestCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(DS.captionFont)
                    // Esc asks rather than destroys — see requestCancel().
                    .keyboardShortcut(.cancelAction)

                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Save this report (⌘↩)")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: autosavedAt)
        .confirmationDialog(
            "Discard your unsaved edit?",
            isPresented: $showDiscardConfirm
        ) {
            Button("Discard edit", role: .destructive) { discardEdit() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("The words you have written since you opened the editor will be removed. This is the text tomorrow's draft would have learned your voice from, and it cannot be recovered.")
        }
    }

    /// Offers back an edit that was interrupted before it could be saved.
    private func recoveryRow(_ pending: String) -> some View {
        HStack(spacing: DS.sm) {
            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(DS.moon)
            Text("An unsaved edit of today's report was kept for you.")
                .font(DS.captionFont).foregroundStyle(DS.inkDim)
            Spacer()
            Button("Resume editing") {
                buffer = pending
                baseline = draft ?? ""     // it differs from what's on the page — still dirty
                recovered = nil
                editing = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(DS.captionFont)

            Button("Discard") {
                clearBackup()
                recovered = nil
            }
            .buttonStyle(.plain)
            .font(DS.captionFont)
            .foregroundStyle(DS.inkFaint)
        }
        .padding(DS.sm)
        .background(RoundedRectangle(cornerRadius: DS.radiusSm).fill(DS.moon.opacity(0.07)))
    }

    private var llmOffRow: some View {
        HStack(spacing: DS.sm) {
            Image(systemName: "moon.zzz").foregroundStyle(DS.paused)
            Text("Turn on a provider to let your understudy draft this.")
                .font(DS.captionFont).foregroundStyle(DS.inkDim)
            Spacer()
            // Lands on the AI tab: this message is about turning a provider on,
            // and pointing at one page while opening another is a small lie.
            Button("Open Settings") { AppDelegate.shared?.showSettings(tab: .ai) }
                .font(DS.captionFont).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.vertical, DS.xs)
    }

    // MARK: - Actions

    /// Pick up whatever already exists for today: an approved report first, then
    /// tonight's cached auto-draft. Never clears — an in-flight or freshly edited
    /// draft outranks anything on disk.
    private func loadExisting() {
        if let kept = writer.saved(for: Date()) {
            draft = kept
            sources = []
            approved = true
            fidelityNote = writer.fidelityNote(for: Date())
        } else if let cached = writer.cachedDraft(for: Date()) {
            draft = cached.text
            sources = cached.sources
            approved = false
        }

        // An autosaved edit outranks nothing on screen — it is *offered*, not
        // applied. Identical text means the edit did land before the interruption.
        //
        // Whichever day it was parked on, not today's. Every read, write and cleanup
        // used to call `editBackupPath(for: Date())` independently, so an edit
        // autosaved at 23:59 and interrupted at 00:03 was looked for under the *next*
        // day's name and never found again: the words sat on disk in a file nothing
        // would ever open, under a card that promises not to lose one.
        if let path = parkedEdits().first,
           let parked = MullDirectory.read(path)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !parked.isEmpty,
           parked != (draft ?? "") {
            recovered = parked
        } else {
            clearBackup()
        }
    }

    /// Every parked edit on disk, newest first. `yyyy-MM-dd-editing.md` in POSIX
    /// order means sorting the names sorts the days.
    private func parkedEdits() -> [String] {
        MullDirectory.markdownFiles(in: "reports/.drafts")
            .filter { $0.hasSuffix("-editing.md") }
            .sorted(by: >)
    }

    private func beginEditing(_ text: String) {
        buffer = text
        baseline = text
        // Pinned for the length of this edit, so one sitting writes one recovery
        // file however long it runs.
        editingDay = Date()
        autosavedAt = nil
        recovered = nil
        editing = true
    }

    /// Esc / Cancel. Unsaved words are never thrown away on a single click — the
    /// only path out that destroys text runs through an explicit confirmation.
    private func requestCancel() {
        if isDirty {
            showDiscardConfirm = true
        } else {
            endEditing()
        }
    }

    private func discardEdit() {
        buffer = baseline
        endEditing()
    }

    private func endEditing() {
        autosaveTask?.cancel()
        autosaveTask = nil
        clearBackup()
        autosavedAt = nil
        editing = false
    }

    /// Debounced write of the live buffer to the recovery file (see editBackupPath).
    private func scheduleAutosave() {
        guard editing else { return }
        autosaveTask?.cancel()
        let text = buffer
        let day = editingDay
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            MullDirectory.write(text, to: editBackupPath(for: day))
            guard !Task.isCancelled else { return }
            await MainActor.run { autosavedAt = Date() }
        }
    }

    /// Clear every parked edit, not only the one named after today. Only one edit
    /// can be in progress, so anything else on disk is an orphan — and clearing by
    /// today's name alone is what stranded the file an edit across midnight left
    /// behind.
    private func clearBackup() {
        for path in parkedEdits() { MullDirectory.delete(path) }
    }

    /// Confirmed re-draft: step the approved copy off disk first, so a reload cannot
    /// resurrect it over the new text. `loadExisting()` prefers the saved report, and
    /// leaving it in place was what made the two texts swap places between visits.
    /// It is moved, not deleted — see ReportWriter.discardSaved().
    private func confirmRedraft() {
        writer.discardSaved(for: Date())
        approved = false
        generate()
    }

    /// Approve the draft exactly as it stands. The other half of the fidelity loop:
    /// "I'd have written that" is as much a correction signal as a rewrite, and it
    /// is the only one a satisfied user will ever give.
    ///
    /// What it explicitly is NOT is a sample of how the user writes. This button used
    /// to put the model's own unedited prose into `reports/`, where `voiceSamples()`
    /// read it back the next day as the user's voice; three approvals in a row and the
    /// understudy was learning entirely from itself. `ReportWriter.save` now classifies
    /// every write (see ReportWriter.Provenance), so the distinction is enforced where
    /// the file is written rather than by this button remembering to behave.
    private func approve(_ text: String) {
        guard writer.save(text, for: Date()) else {
            error = "Could not write today's report to ~/mull — it is still here on screen."
            return
        }
        approved = true
        fidelityNote = writer.fidelityNote(for: Date())
        // Sources stay: this is still the understudy's prose, kept as-is. Only a
        // rewrite makes it the user's own writing (see save()).
    }

    /// A re-draft over an approved report destroys the user's own kept text, so it
    /// asks. Over an unapproved draft there is nothing of theirs to lose.
    private func requestRedraft() {
        if approved {
            showRedraftConfirm = true
        } else {
            generate()
        }
    }

    private func generate() {
        loading = true
        editing = false
        error = nil
        // Note what is NOT cleared: `draft` and `sources`. Clearing them up front
        // meant a failed generation left the user with an error and a blank card —
        // the text they were reading a second ago simply gone. The new draft is
        // built in `streaming` and only takes the place of the old one on success.
        streaming = ""
        Task {
            // Tokens used to be appended from one unstructured Task each. Unstructured
            // tasks carry no ordering guarantee, so chunks could be applied out of
            // sequence and the draft rendered scrambled. A single stream with one
            // consumer serialises the appends in arrival order.
            let (tokens, continuation) = AsyncStream<String>.makeStream()
            let consumer = Task { @MainActor in
                for await piece in tokens {
                    streaming = (streaming ?? "") + piece
                }
            }

            do {
                let written = try await writer.draft(for: Date(), onToken: { piece in
                    continuation.yield(piece)
                })
                continuation.finish()
                await consumer.value   // let every queued token land before we settle
                await MainActor.run {
                    // The swap happens here and only here.
                    draft = written.text
                    sources = written.sources
                    approved = false   // a fresh draft is the machine's, not yours
                    streaming = nil
                    loading = false
                    writer.cacheDraft(written, for: Date())   // survive an app restart
                }
            } catch {
                continuation.finish()
                await consumer.value
                // Never fail silently: the understudy says why it couldn't draft.
                // The previous draft is untouched and comes straight back — a failed
                // re-draft must never cost the user the text they already had.
                await MainActor.run {
                    // Through the same translator chat uses. This card used to
                    // print the provider's raw text, so a 401 arrived on the Home
                    // screen as a JSON blob and a spent token budget as advice to
                    // raise `maxTokens` — neither of which is the reader's to act on.
                    self.error = LLMFailure.explain(error).text
                    streaming = nil
                    loading = false
                }
            }
        }
    }

    private func save() {
        // Only drop the recovery copy once the real write has succeeded — a failed
        // write with the backup already deleted is exactly how an edit disappears.
        let text = buffer
        guard writer.save(text, for: Date()) else {
            error = "Could not write today's report to ~/mull — your edit is still here."
            return
        }
        draft = text
        baseline = text
        approved = true
        fidelityNote = writer.fidelityNote(for: Date())
        // The report is now the user's own words: it is a voice sample, not the
        // understudy's output, so the provenance line no longer applies. Leaving
        // it up credited the model's sources for prose the user wrote themselves.
        sources = []
        endEditing()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            await MainActor.run { withAnimation { copied = false } }
        }
    }
}
