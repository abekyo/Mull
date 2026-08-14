import Foundation

/// Who writes a file in `~/mull` — asked in one place, because two places disagreed.
///
/// The MCP server kept a list of files an agent must not raw-overwrite; the Files tab
/// kept a separate hand-written list of files the user must not type into. They were
/// meant to describe the same fact and had drifted three names apart, so the Files tab
/// offered `full.md`, `mull.md` and `proactive.md` as ordinary editable notes —
/// complete with a Save button — while mull went on regenerating them underneath.
///
/// `mull.md` was the one that lost work outright. It is the only one written with a
/// wholesale `MullDirectory.write` rather than through the Curator, so it carries no
/// provenance markers and there is no hand-edit to promote and protect: whatever the
/// user typed was gone at the next 60-second pass, silently. The same agent that mull
/// *refused* to let touch that file was being held to a stricter rule than mull's own
/// editor held the person who owns the machine.
///
/// The fix is not a longer list. It is one list.
enum VaultOwnership {
    /// mull writes this file and will write it again. It is shown read-only, with its
    /// provenance markers stripped for display — which is exactly why it cannot be
    /// saved from that surface: the buffer on screen is not the file on disk.
    case mull
    /// mull maintains its own blocks in this file; every other line in it is yours.
    ///
    /// `projects/*.md` (DeliberationEngine's briefings) and `corrections/*.md` are
    /// genuinely both: mull owns the blocks it stamped, and `Curator.merge` promotes
    /// any block a human edits to `.human` and never touches it again — so the file
    /// is safe to type into, wherever it is opened. (It used to be opened in mull's
    /// own Files tab; since 2026-08-15 that is Finder, Obsidian or an editor —
    /// DIRECTION §6.2. The ownership answer is the same either way, which is the
    /// point of it living here rather than in a view.)
    ///
    /// Distinct from `.user` because an *agent* may not write it wholesale: a raw
    /// `write_note` would flatten the provenance markers and take the user's edits
    /// with them. Agents go through `curate`. This is the same line `VaultProvenance`
    /// draws with `curated`, and the two must not drift apart again.
    case shared
    /// Yours. mull reads it; the words in it are not mull's to replace.
    ///
    /// `me.pinned.md` is here, not under `.mull`, even though mull does write to it —
    /// it lays the scaffold down and maintains the delimited onboarding section. What
    /// it never rewrites is a line the user wrote, which is what this distinction is
    /// about (CLAUDE.md §7.4).
    case user

    /// Root-level files mull generates for itself.
    ///
    /// Add a generated root file here and both surfaces learn about it at once. That is
    /// the whole point of the type; resist writing the names down anywhere else.
    static let mullWrittenRootFiles: Set<String> = [
        "me.md",        // mull's reading of the user
        "now.md",       // what they are working on
        "full.md",      // everything, assembled
        "MEMORY.md",    // the memory index
        "mull.md",      // the orientation note handed to agents (wholesale rewrite)
        "proactive.md", // the briefs the proactive loop keeps
    ]

    /// Folders whose entire contents mull generates, matched at the vault ROOT.
    ///
    /// `_raw/` is here because MAP-ARCHITECTURE 法則① calls it the territory —
    /// immutable, lossless, never hand-edited. It was missing, so `write_note` would
    /// let an agent overwrite `_raw/<connector>/items.ndjson`: the one layer the
    /// architecture says must never be destroyed was the one with no guard on it.
    ///
    /// At the root, not at any depth. Matching anywhere meant a folder the user named
    /// `daily/` or `memory/` inside their own `notes/` was locked read-only and closed
    /// to agents — mull only ever creates these two at the top of the vault, so that
    /// is where they mean something. (The old behaviour was a leftover from a
    /// `path.contains("/daily/")` substring check.)
    private static let mullWrittenFolders: Set<String> = ["daily", "memory", "_raw"]

    /// Folders mull writes into through the Curator — its own blocks only. Root-level,
    /// for the same reason as above. Named here rather than taken from `VaultLayout`,
    /// which is not compiled into `MullMCP`; `VaultLayoutTests` pins the two together.
    private static let curatedFolders: Set<String> = ["projects", "corrections"]

    /// Root-level files mull assembles but does not own.
    ///
    /// `rules.md` is the rules drawn from the user's own corrections (`RuleBook`).
    /// mull collects them and keeps the file current; every rule in it originated
    /// with a human, and rewriting one promotes that block to `.human` for good.
    /// So: the user may type into it, an agent may only `curate` — which is
    /// exactly `.shared`, and the reason this set exists alongside the `.mull` one.
    private static let curatedRootFiles: Set<String> = ["rules.md"]

    /// Files the user alone writes. mull lays a scaffold down and then only ever
    /// reads them; **no agent tool may write one, including `curate`.**
    ///
    /// This is a stronger promise than `.user`, and it needs to be, because both of
    /// these files are read back as the user's own words. A line an agent added to
    /// `me.pinned.md` is served to every later assistant as something the user
    /// declared about themselves (CLAUDE.md §7.4). `inbox.md` carries the same claim
    /// in its own header — "Yours — mull never rewrites this file" — and in
    /// `QuickCapture`'s doc comment, "a file NO agent ever writes". Neither claim was
    /// enforced anywhere until this set existed; `inbox.md` was simply absent from
    /// every table and answered `.user`, which the MCP server lets an agent overwrite.
    static let userOnlyFiles: Set<String> = [Curator.pinnedFileName, "inbox.md"]

    /// Accepts a vault-relative path *or* an absolute one — the Files tab has URLs and
    /// the MCP server has relative paths, and the answer must not depend on which.
    static func of(path: String) -> VaultOwnership {
        let components = vaultRelative(path).split(separator: "/").map(String.init)
        guard let name = components.last else { return .user }
        let parents = components.dropLast()

        // The vault root's own folders. Asked first, so a file that could match two
        // rules answers as mull's.
        if let top = parents.first, mullWrittenFolders.contains(top) { return .mull }
        if let top = parents.first, curatedFolders.contains(top) { return .shared }
        // AT THE ROOT — not by name anywhere. Matching the name at any depth meant
        // `projects/mull.md` was read as the orientation file mull rewrites whole,
        // so the MCP server refused an agent the very path its own `write_note`
        // description offers as the example, and the Files tab showed the briefing
        // read-only. A note the user happens to call `now.md` was locked the same way.
        if parents.isEmpty, mullWrittenRootFiles.contains(name) { return .mull }
        if parents.isEmpty, curatedRootFiles.contains(name) { return .shared }
        return .user
    }

    /// An absolute path inside the vault, as a vault-relative one. Anything else is
    /// returned unchanged — including an absolute path from somewhere else entirely,
    /// which then has parents and so cannot be mistaken for a root file.
    private static func vaultRelative(_ path: String) -> String {
        let root = MullDirectory.root.standardizedFileURL.path + "/"
        guard path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count))
    }

    /// Does mull assemble the whole of this file? Typing into one is pointless — the
    /// next pass rewrites it — which is what `AboutYouView` says in words over me.md.
    static func isMullWritten(path: String) -> Bool { of(path: path) == .mull }

    /// Must a wholesale write (an agent's `write_note`) be refused?
    ///
    /// Broader than `isMullWritten` by exactly one case, and the gap is the point:
    /// a curated file is one the person at the keyboard may type into and an agent may
    /// not stamp over. The editor asks the narrower question, the MCP server asks this
    /// one, and both still get their answer from this type — which is what the two
    /// hand-written lists that preceded it failed to do.
    static func refusesWholesaleWrite(path: String) -> Bool {
        refusesAllAgentWrites(path: path) || of(path: path) != .user
    }

    /// Is this a file no agent tool may write, by any route — `write_note` *or*
    /// `curate`? See `userOnlyFiles`. Being unable to overwrite a file is not the same
    /// as being allowed to add to it, and for these two the difference is whose words
    /// the reader is looking at.
    static func refusesAllAgentWrites(path: String) -> Bool {
        // At the root, like every other name-matched rule here: `notes/inbox.md` is a
        // note the user happened to name that, not the capture file.
        let components = vaultRelative(path).split(separator: "/").map(String.init)
        return components.count == 1 && userOnlyFiles.contains(components[0])
    }
}
