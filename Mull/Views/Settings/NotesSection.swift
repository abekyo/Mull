import SwiftUI

// MARK: - Settings › Data › "Notes mull keeps"
//
// The notes the nightly pass writes about you, correctable and deletable one at
// a time. It sits under Data because that is where the rest of what mull holds
// is managed — the counts directly above it, the retention schedule and the bulk
// clears directly below — and because this is the only surface in the app where
// a single note can be corrected or forgotten. Editing the markdown file in
// ~/mull/memory by hand fixes the file and leaves the database row behind; both
// halves only move together through `HeldMemoryStore`.
//
// It used to live at the foot of a Settings tab called "Profile", below seven
// read-only statistics sections. Those are gone (see AnswersSection). This is
// the part of that tab that was load-bearing.

struct NotesSection: View {
    @EnvironmentObject var appState: AppState

    /// Called after a note is forgotten, so the "Memories" count in the Storage
    /// section above stops disagreeing with the list below it.
    var onChanged: () -> Void

    @State private var memories: [MemoryEntry] = []
    @State private var loaded = false

    @State private var editingID: Int64?
    @State private var draftName = ""
    @State private var draftDescription = ""
    @State private var draftContent = ""
    @State private var pendingDeletion: MemoryEntry?
    /// A forget that didn't happen. The row stays on screen; this says why.
    @State private var forgetProblem: String?

    var body: some View {
        Section("Notes mull keeps") {
            Text("Written during the nightly summary. They are about you, and you can correct or delete any of them.")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkFaint)
                .fixedSize(horizontal: false, vertical: true)

            if !loaded {
                HStack(spacing: DS.sm) {
                    ProgressView().controlSize(.small)
                    Text("Reading…")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                }
            } else if memories.isEmpty {
                Text(appState.llmProvider == .off
                     ? String(localized: "Nothing kept here yet. These notes are written during the nightly summary, which needs a language model — none is enabled, so mull is keeping the raw record only.")
                     : String(localized: "Nothing kept here yet. Notes are written after the nightly summary."))
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(memories) { memory in
                    if editingID == memory.id {
                        memoryEditor(memory)
                    } else {
                        memoryRow(memory)
                    }
                }
            }
        }
        .task { await load() }
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

    private func memoryRow(_ memory: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            Text(memory.name)
                .font(DS.bodyMedium)
                .fixedSize(horizontal: false, vertical: true)

            Text(memory.description)
                .font(DS.captionFont)
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
                    .font(DS.captionFont)
                    .controlSize(.small)

                Button("Forget", role: .destructive) { pendingDeletion = memory }
                    .font(DS.captionFont)
                    .controlSize(.small)
            }
            .padding(.top, DS.hair)
        }
        .padding(.vertical, DS.hair)
    }

    private func memoryEditor(_ memory: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)

            TextField("Description", text: $draftDescription)
                .textFieldStyle(.roundedBorder)

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
                    .font(DS.captionFont)
                    .controlSize(.small)

                Button("Save") { commitEditing(memory) }
                    .font(DS.captionFont)
                    .controlSize(.small)
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, DS.xs)
    }

    private static func provenance(_ memory: MemoryEntry) -> String {
        let learned = String(localized: "Learned \(dayFormatter.string(from: memory.createdAt))")
        // The edit is only worth mentioning when it happened on a different day
        // from the first writing.
        if !Calendar.current.isDate(memory.updatedAt, inSameDayAs: memory.createdAt) {
            return learned + " · last changed \(dayFormatter.string(from: memory.updatedAt))"
        }
        return learned
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMMMy")
        return f
    }()

    // MARK: - Correction

    private func load() async {
        let database = appState.database
        let fetched = await Task.detached(priority: .userInitiated) {
            database.fetchAllMemories()
        }.value
        guard !Task.isCancelled else { return }
        memories = fetched
        loaded = true
    }

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
            forgetProblem = String(localized: "“\(memory.name)” could not be removed — its file in ~/mull/memory is still in place.")
            return
        }
        memories.removeAll { $0.id == memory.id }
        if editingID == memory.id { editingID = nil }
        onChanged()
    }
}

// MARK: - Writing back to what mull holds

/// Correction and deletion for the notes shown in "Notes mull keeps".
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
