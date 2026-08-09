import SwiftUI

// MARK: - Settings › General › "Your answers"
//
// The seven setup answers, and the lines mull is declining to publish from the
// file they are written into. Both are about me.pinned.md, so they sit together.
//
// This used to be the top of a fourth Settings tab called "Profile", underneath
// which sat seven read-only sections of statistics — facts, rhythm, attention,
// language, words, today, today's summary. Those answered no question the user
// could act on, and five of the seven quoted the same measurements the Home tab
// and me.md already carry, at a different window length: Language was 7-day here
// and 14-day in me.md, attention 7-day here and 14-day on Home. The tab's own
// header comment called that the dishonest version. So the statistics went, and
// what was left is two controls about your own file and one about mull's notes
// (Settings › Data). A tab is not the right container for three controls.

struct AnswersSection: View {
    @EnvironmentObject var appState: AppState

    @State private var showEditor = false
    @State private var showResetConfirm = false
    @State private var resetDone = false
    /// Clears the "cleared" confirmation. A success message that never leaves
    /// stops being a confirmation and becomes a permanent label.
    @State private var resetNoticeTask: Task<Void, Never>?

    /// Lines in me.pinned.md mull is declining to publish (see Curator.readPinned).
    @State private var withheldPinned: [String] = []

    var body: some View {
        Group {
            Section("Your answers") {
                Text("Your answers from setup sit at the top of me.md via me.pinned.md, and capture never overwrites them — clear one and mull goes back to inferring it from what you do.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Edit answers…") { showEditor = true }
                        .font(DS.captionFont)
                        .controlSize(.small)

                    Button("Reset answers") { showResetConfirm = true }
                        .font(DS.captionFont)
                        .controlSize(.small)
                        .disabled(!OnboardingProfile.hasAnswers)

                    Spacer()

                    if resetDone {
                        Label("Cleared from me.pinned.md", systemImage: DS.Glyph.success)
                            .font(DS.captionFont)
                            .foregroundStyle(DS.recording)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: resetDone)
            }
            // Every modifier below belongs to this one Section, not to the Group:
            // a Group applies its modifiers to each child in turn, which would
            // register the sheet and the dialog twice over.
            .task { await readWithheld() }
            .onDisappear { resetNoticeTask?.cancel() }
            .sheet(isPresented: $showEditor) {
                ProfileAnswersEditor { answers in
                    OnboardingProfile.save(answers)
                    appState.regenerateContextNow()
                    // The withheld-lines section reads me.pinned.md, which this
                    // just rewrote; re-read rather than showing the old file.
                    Task { await readWithheld() }
                }
            }
            .confirmationDialog("Clear your profile answers?", isPresented: $showResetConfirm) {
                Button("Clear answers", role: .destructive) { resetAnswers() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything you told mull at setup — your role, working language, what you're building, how you want AI to answer — is removed from me.pinned.md. Anything you wrote in that file by hand is kept. mull will go back to inferring these from what you do.")
            }

            withheldSection
        }
    }

    /// What mull is declining to publish from the user's own pinned file.
    ///
    /// `Curator.readPinned` filters me.pinned.md at read time and never edits it.
    /// Filtering silently would be the worse failure of the two: the user would
    /// have written a line, seen it vanish from me.md, and had no way to know
    /// why. So the withheld lines are shown back, verbatim, with the reason.
    @ViewBuilder
    private var withheldSection: some View {
        if !withheldPinned.isEmpty {
            // "Not published from me.pinned.md" led with a filename; the reader's
            // question is "why isn't my line showing up?", so the title now
            // answers in terms of the file they actually hand to an AI.
            Section("Left out of me.md") {
                Text(withheldPinned.count == 1
                     ? "One line carries no information, so it is being left out of me.md. Your file is unchanged — edit it to replace this."
                     : "\(withheldPinned.count) lines carry no information, so they are being left out of me.md. Your file is unchanged — edit it to replace them.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(withheldPinned.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(DS.microFont)
                        .foregroundStyle(DS.inkFaint)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func resetAnswers() {
        OnboardingProfile.reset()
        appState.regenerateContextNow()
        resetDone = true
        resetNoticeTask?.cancel()
        resetNoticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            resetDone = false
        }
        // The withheld-lines section reads the file this just rewrote.
        Task { await readWithheld() }
    }

    /// Off the main thread: this is a file read, and Settings opens on it.
    private func readWithheld() async {
        let lines = await Task.detached(priority: .userInitiated) {
            Curator.readPinned().withheld
        }.value
        guard !Task.isCancelled else { return }
        withheldPinned = lines
    }
}

// MARK: - Profile Answers Editor
//
// The same questions the setup wizard asks, edited in place. It is explicitly
// *not* the wizard: no step counter (there are no steps), no "Save & Continue"
// leading somewhere else, and closing it returns to Settings — because that is
// where the user was. Answers are the user's stated priors; nothing is required.

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
