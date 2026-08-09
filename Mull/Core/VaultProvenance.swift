import Foundation

/// One answer to "who writes this vault file, and does an edit to it survive?"
///
/// There used to be four answers, and they disagreed. The sidebar decided with
/// `path.contains("/daily/") || path.contains("/memory/")`; the editor's
/// read-only guard read whatever the sidebar had decided; `list_files` carried
/// its own literal `["me.md", "now.md", "full.md", "MEMORY.md"]`; and
/// `pinnedRootFiles` named a fourth set. So `full.md` was mull's work in the MCP
/// listing and the user's note in the sidebar, and `mull.md` — which
/// `LiveContextGenerator` rewrites WHOLE on the 60s pass, with no Curator
/// anywhere in the path — was labelled "Your note", given a Save button, and
/// saved successfully. The next generation pass deleted what had been typed.
///
/// The two questions are separate and have to stay separate:
///
///   - `writtenByMull` is authorship. It decides the sidebar's label and accent
///     dot, and which entries `list_files` marks `(auto)`.
///   - `editable` is whether an edit is still there afterwards. It decides the
///     editor's lock, whether provenance markers are stripped for reading, and
///     whether the 5s auto-refresh may replace the buffer.
///
/// They are not the same question. mull writes every `NN_*/index.md` and every
/// `projects/*.md`, but through the Curator, which promotes any block the
/// user touches to `.human` and never overwrites it again — so those stay
/// editable, exactly as their own header line promises. Collapsing the two axes
/// into one flag is what put a Save button on a file that is regenerated every
/// minute.
///
/// Lives in Core because both the app and `MullMCP` have to give the same
/// answer, and Core is the only layer they share.
enum VaultProvenance {

    struct Rule: Equatable {
        /// mull authors the bytes here.
        let writtenByMull: Bool
        /// An edit made here survives mull's next pass over the file.
        let editable: Bool
    }

    /// mull rewrites the whole file on its own schedule. Nothing typed here lasts.
    static let generated = Rule(writtenByMull: true, editable: false)

    /// mull writes its own blocks through the Curator; everything else is the
    /// user's and is carried through untouched.
    static let curated = Rule(writtenByMull: true, editable: true)

    /// The user's. mull reads it and never writes it.
    static let owned = Rule(writtenByMull: false, editable: true)

    /// Root files mull regenerates, with the writer that does it.
    ///
    /// `me.md`, `now.md`, `full.md`, `MEMORY.md` and `proactive.md` all go
    /// through the Curator, so an edit would technically survive — they are
    /// read-only for a product reason rather than a mechanical one: they are
    /// mull's reading of the user, and the place to correct that reading is
    /// `me.pinned.md`, which sits under it and is theirs. `mull.md` is
    /// read-only for the mechanical reason: it is not curated at all.
    private static let generatedRootFiles: Set<String> = [
        "me.md",         // LiveContextGenerator / MullEngine, via Curator
        "now.md",        // LiveContextGenerator, via Curator
        "full.md",       // LiveContextGenerator / MullEngine, via Curator
        "MEMORY.md",     // Curator; ForgetService rewrites it whole on the forget path
        "mull.md",       // LiveContextGenerator — a raw whole-file write, no Curator
        "proactive.md",  // ProactiveLoop, via Curator
    ]

    /// Directories mull owns end to end. `daily/` and `memory/` are mull's own
    /// snapshots; `_raw/` is the immutable source layer `VaultLayout` describes
    /// as never hand-edited.
    private static let generatedDirs: Set<String> = ["daily", "memory", "_raw"]

    /// Directories whose `.md` files mull writes through the Curator: it owns its
    /// own blocks there and the user owns the rest, so neither may stamp over the
    /// other. Spelled here rather than taken from `VaultLayout`, which lives in the
    /// app layer and is not compiled into `MullMCP`.
    private static let curatedDirs: Set<String> = ["projects", "corrections"]

    /// The rule for a path relative to the vault root, e.g. `"me.md"`,
    /// `"projects/mull.md"`, `"daily/2026/08/2026-08-09.md"`.
    ///
    /// Anything with no writer behind it is `owned` — the user's notes, their
    /// `me.pinned.md`, an `.md` they dropped in by hand. **When you add a writer,
    /// add its path here**: the default is deliberately the safe one for a file
    /// mull does not touch, which is the wrong one for a file it does.
    /// `VaultProvenanceTests` pins the current set so the two stay together.
    static func rule(forVaultRelativePath path: String) -> Rule {
        let parts = path.split(separator: "/").map(String.init)
        guard let first = parts.first, let last = parts.last else { return owned }

        // Root file.
        if parts.count == 1 {
            return generatedRootFiles.contains(first) ? generated : owned
        }

        if generatedDirs.contains(first) { return generated }

        if curatedDirs.contains(first) { return curated }

        return owned
    }

    /// The rule for a file URL, resolved against the vault root. A URL outside
    /// the vault is `owned` — mull has no writer there by definition, and
    /// guessing otherwise would lock a file it does not manage.
    static func rule(for url: URL, vaultRoot: URL = MullDirectory.root) -> Rule {
        let root = vaultRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return owned }
        return rule(forVaultRelativePath: String(path.dropFirst(root.count + 1)))
    }

}
