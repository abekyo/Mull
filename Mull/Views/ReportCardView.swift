import SwiftUI

/// "Today, in your words" — the understudy's draft of today's report.
///
/// This is the first piece of work the understudy does *as you* rather than *about*
/// you, so it carries the dignity constraints with it: the draft never sends itself
/// (§3.6 — you send it), it names what it learned your voice from, and your edit is
/// always one tap away because the edit is what teaches tomorrow's draft.
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

    private var writer: ReportWriter { ReportWriter(database: appState.database) }

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
                    Button { generate() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.inkFaint)
                    .help("Re-draft in my voice")
                }
            }

            if let err = error, !loading {
                HStack(spacing: DS.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(DS.paused)
                    Text(err)
                        .font(DS.captionFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { generate() }
                        .font(DS.captionFont).buttonStyle(.plain).foregroundStyle(DS.moon)
                }
                .padding(DS.sm)
                .background(RoundedRectangle(cornerRadius: DS.radiusSm).fill(DS.paused.opacity(0.08)))
            }

            if isLLMOff {
                llmOffRow
            } else if loading {
                HStack(spacing: DS.sm) {
                    ProgressView().controlSize(.small)
                    Text("Your understudy is drafting…")
                        .font(DS.captionFont).foregroundStyle(.secondary)
                }
                .padding(.vertical, DS.xs)
            } else if editing {
                VStack(alignment: .leading, spacing: DS.sm) {
                    TextEditor(text: $buffer)
                        .font(DS.readFont)
                        .foregroundStyle(DS.ink)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160)
                    HStack {
                        Spacer()
                        Button("Cancel") { editing = false }
                            .buttonStyle(.plain).font(DS.captionFont).foregroundStyle(.secondary)
                        Button("Save") { save() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            } else if let text = draft, !text.isEmpty {
                MarkdownView(text, titleFirstLine: false)
                    .textSelection(.enabled)
                // Dignity: the understudy says what it learned the voice from.
                if !sources.isEmpty {
                    Text("Voice learned from: " + sources.joined(separator: " · "))
                        .font(DS.miniFont)
                        .foregroundStyle(.quaternary)
                }

                HStack(spacing: DS.md) {
                    Button { buffer = text; editing = true } label: {
                        Label("Edit", systemImage: "pencil").font(DS.captionFont)
                    }
                    .buttonStyle(.plain).foregroundStyle(DS.moon)

                    Button { copy(text) } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.clipboard")
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
                    Button { generate() } label: {
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

    private var llmOffRow: some View {
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

    // MARK: - Actions

    /// Pick up whatever already exists for today: an approved report first, then
    /// tonight's cached auto-draft. Never clears — an in-flight or freshly edited
    /// draft outranks anything on disk.
    private func loadExisting() {
        if let approved = writer.saved(for: Date()) {
            draft = approved
            sources = []
        } else if let cached = writer.cachedDraft(for: Date()) {
            draft = cached.text
            sources = cached.sources
        }
    }

    private func generate() {
        loading = true
        editing = false
        error = nil
        draft = nil
        sources = []
        Task {
            // Tokens used to be appended from one unstructured Task each. Unstructured
            // tasks carry no ordering guarantee, so chunks could be applied out of
            // sequence and the draft rendered scrambled. A single stream with one
            // consumer serialises the appends in arrival order.
            let (tokens, continuation) = AsyncStream<String>.makeStream()
            let consumer = Task { @MainActor in
                for await piece in tokens {
                    // The spinner yields to live text on the first token.
                    if loading { loading = false }
                    draft = (draft ?? "") + piece
                }
            }

            do {
                let written = try await writer.draft(for: Date(), onToken: { piece in
                    continuation.yield(piece)
                })
                continuation.finish()
                await consumer.value   // let every queued token land before we settle
                await MainActor.run {
                    draft = written.text
                    sources = written.sources
                    loading = false
                    writer.cacheDraft(written, for: Date())   // survive an app restart
                }
            } catch {
                continuation.finish()
                await consumer.value
                // Never fail silently: the understudy says why it couldn't draft.
                await MainActor.run {
                    self.error = error.localizedDescription
                    loading = false
                    draft = nil
                }
            }
        }
    }

    private func save() {
        writer.save(buffer, for: Date())
        draft = buffer
        editing = false
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
