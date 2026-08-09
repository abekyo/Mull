import Foundation

/// Where things live in `~/mull`, and the one-way moves that get an older vault
/// into that shape.
///
/// ## What this replaced, and why
///
/// This file used to be `FolderOntology` — a fixed numbered taxonomy
/// (`00_identity` … `09_inbox`) with an `index.md` template per folder, section
/// blocks, per-folder Japanese titles, and a connector→folder routing table.
/// DIRECTION §6.1 retired it on 2026-08-09. The short version of that ruling:
///
/// - **DIRECTION §6 had already suspended it on 2026-06-02** — one hour after it
///   shipped (`b3f4e14` 15:01:43 → `131d313` 16:05:01, same day). It was never a
///   decision that overrode the ruling; it was a leftover that predated it.
/// - **Nothing read it.** Of the eight folders, only `03_projects/*.md` and
///   `06_knowledge/corrections/ledger.md` had a reader — and
///   `MullDirectory.markdownFiles(in:)` skips `index.md`, so even that one reader
///   never opened a folder index. The selection layer touches no vault file at all.
/// - **Two of them had no writer.** `primaryDestination` routed no connector to
///   `02_work` or `04_career`, so `SynthesisEngine.gatherItems` always came back
///   empty for them. They could only ever hold the scaffold.
/// - **One of them contradicted `me.md`.** `00_identity/index.md` declared
///   `canonical: ../me.md` while carrying rule-based facts that `me.md`
///   deliberately drops (DIRECTION §4/§9.1 — the pre-digestion mull cut). Those
///   facts are still produced, at use-time, by `ContextComposer` and `ProfileTab`.
///
/// The line the shape follows now:
///
/// > **Categories are the user's — they cut them under `notes/`. Destinations are
/// > mull's — fixed, flat, obvious.**
///
/// The numbered scheme's mistake was mixing the two on one shelf, which put eight
/// shelves in front of the user that mull could not fill.
enum VaultLayout {

    // MARK: - mull's own destinations
    //
    // Every one of these has exactly one writer, named beside it. Adding a
    // destination here means adding a writer; a destination with no writer is the
    // thing this file exists to stop.

    /// Per-project briefings — `DeliberationEngine`, via the Curator.
    static let projects = "projects"

    /// The correction ledger and its cards — `Curator.recordCorrections`.
    /// The learning signal (CLAUDE.md §7.3), so it sits at the root rather than
    /// three levels down inside a category folder nothing else used.
    static let corrections = "corrections"

    /// Quick capture from the menu bar — `QuickCapture`. One file, not a folder:
    /// there has only ever been one thing in it.
    static let inboxFile = "inbox.md"

    // MARK: - The raw zone (territory)

    /// `_raw/<connector>/` — the immutable source layer (MAP-ARCHITECTURE 法則①).
    /// Not scaffolded: `MullDirectory.write` creates intermediate directories, so
    /// `RawStore.land` makes the folder on the first pull that has something to
    /// put in it, which is the only moment the folder means anything.
    static let rawRoot = "_raw"

    /// Connector ids `RawStore` and the Settings source list share.
    static let rawConnectors = ["capture", "gmail", "gcal", "gdrive", "github", "notion"]

    // MARK: - Migration

    /// Bring an older vault into the shape above. Idempotent, one-way, and it
    /// never deletes something a person wrote.
    static func migrate() {
        guard MullDirectory.status == .ready else { return }
        migrateNumberedFolders()
    }

    /// Retire `NN_slug/`.
    ///
    /// The order matters, and so does what is NOT deleted. `index.md` is mull's
    /// own scaffold, but since 2026-08-09 it has also been editable in the Files
    /// tab — so a person may have written in one, and the promise that mull does
    /// not destroy their writing (契約2 / CLAUDE.md §7.4) outranks the tidiness of
    /// removing the folder. Their prose is lifted out to a note before anything
    /// goes; only a scaffold with nothing of theirs in it is discarded.
    private static func migrateNumberedFolders() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: MullDirectory.root.path) else { return }

        for name in entries.sorted() where isNumberedFolder(name) {
            // The order is load-bearing. The index has to be dealt with BEFORE the
            // folder's contents are swept anywhere: `03_projects` moves wholesale into
            // `projects/`, so a scaffold index still sitting there rides along and
            // lands in the new folder — which would put back, under a better name,
            // exactly the empty file this whole change is removing.
            //
            // 1. Anything the user wrote above the first block, kept as a note.
            rescueIndexProse(folder: name)
            // 2. The scaffold itself, if that is all it was.
            discardScaffoldIndex(folder: name)
            // 3. Files that have a destination of their own.
            //    `03_projects` was itself a migration of a flat `projects/`, run
            //    between June and August 2026; this walks it back, so a vault that
            //    never saw the numbered scheme and one that did both land in the
            //    same place.
            if name.hasSuffix("_projects") { move(contentsOf: name, into: projects) }
            if name.hasSuffix("_knowledge") { move(contentsOf: "\(name)/corrections", into: corrections) }
            if name.hasSuffix("_inbox") { moveFile("\(name)/captures.md", to: inboxFile) }
            // 4. Everything else the user filed in here is theirs, and goes with them.
            move(contentsOf: name, into: "notes/\(name)")
            removeIfEmpty(name)
        }
    }

    /// `NN_slug` — matched structurally rather than against a list, so a vault
    /// carrying a folder from some intermediate version of the scheme is still
    /// recognised.
    static func isNumberedFolder(_ name: String) -> Bool {
        let chars = Array(name)
        guard chars.count > 3, chars[0].isNumber, chars[1].isNumber, chars[2] == "_" else {
            return false
        }
        return true
    }

    /// Lift the user's own prose out of a folder index into `notes/`.
    ///
    /// `MarkdownDoc.body` strips exactly what `indexHeader` used to emit — front
    /// matter, the `#` title, the leading promise — so what comes back is theirs
    /// and nobody else's. An untouched scaffold reduces to the empty string and
    /// this does nothing.
    private static func rescueIndexProse(folder: String) {
        let indexPath = "\(folder)/index.md"
        guard let raw = MullDirectory.read(indexPath) else { return }
        let (header, _) = ContextBlockFile.parse(raw)
        let theirs = MarkdownDoc.body(of: header)
        guard !theirs.isEmpty else { return }

        let note = "notes/\(folder).md"
        guard !MullDirectory.exists(note) else { return }   // already rescued
        _ = MullDirectory.write(
            "# \(folder)\n\n_Moved here on 2026-08-09, when mull retired its numbered folders "
                + "(DIRECTION §6.1). These are your words, taken out of `\(indexPath)` before it "
                + "was removed._\n\n\(theirs)\n",
            to: note)
    }

    /// Remove a folder index that holds nothing but mull's own writing. A block a
    /// human edited has been promoted to `src=human` by `Curator.merge`, and one
    /// of those keeps the file — it is not mull's to delete.
    private static func discardScaffoldIndex(folder: String) {
        let indexPath = "\(folder)/index.md"
        guard let raw = MullDirectory.read(indexPath) else { return }
        let (_, blocks) = ContextBlockFile.parse(raw)
        guard !blocks.contains(where: { $0.source != .agent }) else { return }
        _ = MullDirectory.delete(indexPath)
    }

    // MARK: - Small file moves (never overwrite, never delete the user's copy)

    /// Move every entry of `source` into `destination`, skipping any name that is
    /// already taken there. A collision leaves both files on disk — the mover's
    /// job is to relocate, not to choose a winner.
    private static func move(contentsOf source: String, into destination: String) {
        let fm = FileManager.default
        let from = MullDirectory.url(for: source)
        guard let names = try? fm.contentsOfDirectory(atPath: from.path), !names.isEmpty else { return }

        let to = MullDirectory.url(for: destination)
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in names {
            let target = to.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try? fm.moveItem(at: from.appendingPathComponent(name), to: target)
        }
        removeIfEmpty(source)
    }

    private static func moveFile(_ source: String, to destination: String) {
        let fm = FileManager.default
        let from = MullDirectory.url(for: source)
        let to = MullDirectory.url(for: destination)
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return }
        try? fm.moveItem(at: from, to: to)
    }

    /// Remove a directory only when nothing visible is left in it. `.DS_Store` and
    /// friends do not count as contents — but they also cannot be deleted blindly
    /// from a folder that still holds something, so the check comes first.
    private static func removeIfEmpty(_ relativePath: String) {
        let fm = FileManager.default
        let url = MullDirectory.url(for: relativePath)
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return }
        guard names.allSatisfy({ $0.hasPrefix(".") }) else { return }
        try? fm.removeItem(at: url)
    }
}
