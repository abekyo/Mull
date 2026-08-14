import SwiftUI

/// About you — what mull works out about you, and the file where you correct it.
///
/// This page is what survived the Files tab (DIRECTION §6.2). The vault browser and
/// its editor went because Finder, Obsidian and VS Code already open a folder of
/// markdown better than mull ever would. This one page did not, because it is not a
/// file browser: it is the only place `me.pinned.md` can be reached *while looking
/// at what it corrects*, and correcting mull's reading of you is the whole reason
/// that file exists (CLAUDE.md §7.4).
///
/// Two texts, one subject, in the order they are read:
///
/// - `me.md`, rendered read-only, because mull rewrites it every 60 seconds and
///   anything typed into it would be gone by the next pass;
/// - `me.pinned.md`, editable, saved as you type, and placed *above* mull's own
///   guesses when the two are assembled.
struct AboutYouView: View {
    @EnvironmentObject var appState: AppState

    /// mull's reading, as it is on disk.
    @State private var me = ""
    /// Yours. Its own buffer: me.md is read-only and rewritten constantly, and these
    /// two must never be confused for one another.
    @State private var pinned = ""
    @State private var pinnedSaved = ""
    @State private var pinnedSaveError: String?
    @State private var pinnedAutosaveTimer: Timer?
    @FocusState private var pinnedFocused: Bool

    /// me.md is regenerated on a 60-second cycle. Re-reading on that cadence keeps
    /// the page true without the machinery the editor needed: there is no buffer to
    /// protect here, because nothing on this half of the page is typed into.
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.lg) {
                    custodeNote
                    MarkdownView(me)
                        .textSelection(.enabled)
                    pinnedEditor
                }
                .frame(maxWidth: DS.readMeasure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, DS.readMargin)
                .padding(.top, DS.lg)
                .padding(.bottom, 160)
            }
        }
        .background(DS.canvas)
        .onAppear {
            load()
            startRefresh()
        }
        .onDisappear {
            stopRefresh()
            // Leaving the page is a save point. The 0.8s autosave timer may not have
            // fired yet, and a view that goes away takes its timer with it.
            savePinned()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.md) {
            HStack(spacing: DS.md) {
                Circle().fill(DS.slate).frame(width: 8, height: 8)
                Text("About you").font(DS.titleFont)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text("Your profile, written by mull, and your own corrections to it"))

            Label("Written by mull · read-only", systemImage: DS.Glyph.locked)
                .font(DS.captionMedium)
                .foregroundStyle(DS.inkDim)

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(me, forType: .string)
            } label: {
                Image(systemName: DS.Glyph.copy)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Copy content")
            .accessibilityHint("Copies the whole of me.md to the clipboard")
            .help("Copy content")
        }
        .padding(.horizontal, DS.xl)
        .padding(.vertical, DS.sm)
    }

    private var custodeNote: some View {
        Text("What mull inferred about you, rewritten on every update. That is why this part can't be edited: the next update would overwrite what you typed. What you write at the bottom of this page is kept as fact and shown above this.")
            .font(DS.captionFont)
            .foregroundStyle(DS.inkDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Your own corrections
    //
    // A plain `TextEditor`, not the markdown editor notes used to get: this file is a
    // short list of statements, and an NSScrollView inside a ScrollView has to
    // negotiate its own height. A fixed box inside the page is the honest shape.
    //
    // It writes the file raw, which is lossless here — me.pinned.md carries no
    // provenance markers (that is the whole reason it is a separate file from me.md).
    // Onboarding's delimited section is ordinary text in this buffer and survives a
    // round trip, exactly as it does when the file is opened in Obsidian.

    private var pinnedEditor: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("What you've told mull yourself")
                    .font(DS.bodyMedium)
                    .foregroundStyle(DS.ink)
                Spacer()
                if let pinnedSaveError {
                    Text("Not saved")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.error)
                        .help("mull couldn't write \(Curator.pinnedFileName): \(pinnedSaveError)\n\nYour text is still here. Keep typing, or copy it out.")
                } else if pinned != pinnedSaved {
                    Text("Edited")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.paused)
                }
            }

            Text("These lines are placed above everything mull works out on its own. Use them for what it gets wrong, or could not know. Saved as you type, to \(Curator.pinnedFileName).")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkDim)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $pinned)
                .font(DS.bodyFont)
                .foregroundStyle(DS.ink)
                .scrollContentBackground(.hidden)
                .focused($pinnedFocused)
                .frame(height: 260)
                .padding(DS.sm)
                .background(RoundedRectangle(cornerRadius: DS.radiusSm).fill(DS.surface))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusSm)
                    .strokeBorder(pinnedFocused ? DS.moon.opacity(0.45) : DS.hairline, lineWidth: 0.75))
                .onChange(of: pinned) { _, _ in schedulePinnedSave() }
                .accessibilityLabel("Facts you have told mull yourself")
                .accessibilityHint("Written to \(Curator.pinnedFileName). Placed above mull's own guesses.")
        }
        .padding(.top, DS.md)
    }

    // MARK: - Disk

    private func load() {
        me = readMe()
        _ = Curator.pinnedFacts()   // lays the scaffold down if this is the first time
        let raw = MullDirectory.read(Curator.pinnedFileName) ?? ""
        pinned = raw
        pinnedSaved = raw
        pinnedSaveError = nil
    }

    /// Re-read mull's half. The reader's half is never reloaded from under them: an
    /// unsaved edit is the one thing on this page that exists nowhere else.
    private func startRefresh() {
        stopRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            let fresh = readMe()
            if fresh != me { me = fresh }
        }
    }

    /// me.md as it is meant to be read.
    ///
    /// The provenance markers come out first. They are internal metadata — one
    /// `<!-- mull:block id=… src=agent hash=… ts=… -->` above every fact in the file
    /// — and a renderer has no reason to know that, so left in they are drawn as
    /// text and the page is a wall of them. Every surface that shows a curated file
    /// to a person or a model strips them (`full.md`'s embed, the AI clipboard, the
    /// MCP context tools); this is one of those surfaces and briefly forgot to be.
    private func readMe() -> String {
        Self.displayText(MullDirectory.read("me.md") ?? "")
    }

    /// The file as read, separated from the reading of it so a test can hold this
    /// page to it without standing up a view.
    static func displayText(_ raw: String) -> String {
        ContextBlockFile.stripMarkers(raw)
    }

    private func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func schedulePinnedSave() {
        pinnedAutosaveTimer?.invalidate()
        guard pinned != pinnedSaved else { return }
        pinnedAutosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
            savePinned()
        }
    }

    /// A failed write must never look like a successful one: the buffer stays
    /// different from `pinnedSaved`, so the header keeps saying so.
    private func savePinned() {
        pinnedAutosaveTimer?.invalidate()
        pinnedAutosaveTimer = nil
        guard pinned != pinnedSaved else { return }
        if MullDirectory.write(pinned, to: Curator.pinnedFileName) {
            pinnedSaved = pinned
            pinnedSaveError = nil
        } else {
            pinnedSaveError = String(localized: "mull could not write to ~/mull.")
        }
    }
}
