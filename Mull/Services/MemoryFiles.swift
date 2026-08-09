import Foundation

/// What a memory is called on disk, and the one-time repair for the ones that were
/// named before this existed.
///
/// `MullEngine` used to build the name inline as
/// `name.lowercased().replacingOccurrences(of: " ", with: "_") + ".md"`. Nothing else
/// was removed, so a memory called "Work rhythm: afternoons for editing" landed as
/// `work_rhythm:_afternoons_for_editing.md`. Two things were wrong with that:
///
/// - **Finder shows a POSIX `:` as `/`.** The same file read
///   `work_rhythm/_afternoons_for_editing.md` in Finder and
///   `work_rhythm:_afternoons_for_editing.md` in mull — one file, two names, in a
///   product that asks to be trusted because the vault is just markdown you can open
///   in anything (CLAUDE.md §4 *Portable*).
/// - **A `/` in a memory name would have aimed the write at a folder that does not
///   exist**, and the write would simply have failed.
///
/// The names are not prettified for display anywhere, and that is deliberate: the row
/// in the Files sidebar says exactly what the file is called, so the sidebar and
/// Finder cannot disagree. Fixing the name is the fix; decorating it would recreate
/// the same problem in a nicer typeface.
enum MemoryFiles {

    /// The on-disk name for a memory. Capitalisation is the writer's — lowercasing
    /// made `VS Code` into `vs_code`, which is not what anyone wrote.
    static func fileName(for name: String) -> String {
        let base = MullDirectory.safeFileName(name)
        return (base.isEmpty ? "memory" : base) + ".md"
    }

    /// Rename memory files whose names predate `fileName(for:)`, and move the database
    /// rows with them.
    ///
    /// Both halves or neither: `filePath` is what `NotesSection` edits through,
    /// `ForgetService` deletes through, and `MEMORY.md` links to, so a file renamed
    /// without its row is a memory the user can see and no longer act on. The rename
    /// is attempted first and the row is only updated once it succeeded.
    ///
    /// Idempotent — a name already in the target form is skipped, so this can run on
    /// every launch.
    @discardableResult
    static func repairLegacyNames(database: MemoryWriting) -> Int {
        var repaired = 0
        for var entry in database.fetchAllMemories() {
            let current = (entry.filePath as NSString).lastPathComponent
            guard !current.isEmpty else { continue }
            let wanted = fileName(for: entry.name)
            guard wanted != current else { continue }

            let from = MullDirectory.url(for: "memory/\(current)")
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            // Never write over a memory that already occupies the target name; two
            // memories whose names differ only by punctuation would otherwise merge
            // into one file and the first of them would be gone.
            let to = MullDirectory.url(for: "memory/\(wanted)")
            guard !FileManager.default.fileExists(atPath: to.path) else { continue }

            do {
                try FileManager.default.moveItem(at: from, to: to)
            } catch {
                continue
            }
            entry.filePath = "memory/\(wanted)"
            database.updateMemory(entry)
            repaired += 1
        }
        return repaired
    }
}

/// The slice of the database this repair needs. Narrow on purpose: it makes the pass
/// testable without a real `DatabaseService`, and says in the signature that nothing
/// else about a memory is touched.
protocol MemoryWriting {
    func fetchAllMemories() -> [MemoryEntry]
    func updateMemory(_ entry: MemoryEntry)
}

extension DatabaseService: MemoryWriting {}
