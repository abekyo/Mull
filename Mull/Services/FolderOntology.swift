import Foundation

/// The schema of the second brain (Direction v3, Phase A).
///
/// Defines a fixed, numbered folder taxonomy under `~/mull/` so every piece of
/// collected data has a defined place to live and a defined shape to be
/// organized into. Two zones:
///
///  - `_raw/<connector>/` — the immutable SOURCE (capture, gmail, gcal, …). The
///    "source code" future models re-synthesize from. Never hand-edited.
///  - `NN_<slug>/` — the DERIVED, organized layer. Each folder owns an
///    `index.md` template: Curator-managed agent blocks the user can edit freely
///    (mull only ever updates its own blocks).
///
/// Phase A only scaffolds the structure + templates. Ingestion (Phase B) fills
/// `_raw/` and `09_inbox/`; synthesis (Phase C) fills the section blocks.
///
/// Note: the AI-facing contract files (me.md / now.md / full.md / MEMORY.md)
/// intentionally stay at the root for now — relocating them would break the MCP
/// resources and every reader. The numbered folders are the new richer layer and
/// reference those canonical files.
enum FolderOntology {

    struct Folder {
        let number: String        // "00", "01", …
        let slug: String          // "identity", "now", …
        let title: String         // "Identity"
        let purpose: String       // one-line description shown in the index header
        let sections: [String]    // template section headings → one agent block each
        let canonical: String?    // root file this folder mirrors, if any (e.g. "me.md")

        var path: String { "\(number)_\(slug)" }
        var indexPath: String { "\(path)/index.md" }
    }

    static let rawRoot = "_raw"

    /// Source connectors (Phase B populates these; Phase A just creates the dirs).
    static let rawConnectors = ["capture", "gmail", "gcal", "gdrive", "github", "notion"]

    static let folders: [Folder] = [
        Folder(number: "00", slug: "identity", title: "Identity",
               purpose: "Who you are — profile, skills, preferences, values.",
               sections: ["Summary", "Skills", "Preferences", "Values"],
               canonical: "me.md"),
        Folder(number: "01", slug: "now", title: "Now",
               purpose: "Your current state — what you're focused on right now.",
               sections: ["Current focus", "This week", "Upcoming"],
               canonical: "now.md"),
        Folder(number: "02", slug: "work", title: "Work",
               purpose: "Businesses and employers you work in or on.",
               sections: ["Organizations", "Responsibilities", "Status"],
               canonical: nil),
        Folder(number: "03", slug: "projects", title: "Projects",
               purpose: "Active projects. Per-project briefings live alongside this index.",
               sections: ["Active projects", "Recently touched"],
               canonical: nil),
        Folder(number: "04", slug: "career", title: "Career",
               purpose: "Your career arc — roles, achievements, goals.",
               sections: ["Roles", "Achievements", "Goals", "Resume material"],
               canonical: nil),
        Folder(number: "05", slug: "people", title: "People",
               purpose: "Key relationships and the context behind them.",
               sections: ["Key people", "Context per person"],
               canonical: nil),
        Folder(number: "06", slug: "knowledge", title: "Knowledge",
               purpose: "Decisions, references, and things you've learned.",
               sections: ["Decisions", "References", "Learnings"],
               canonical: "MEMORY.md"),
        Folder(number: "09", slug: "inbox", title: "Inbox",
               purpose: "Freshly ingested data, unsorted, awaiting routing.",
               sections: ["Unsorted"],
               canonical: nil),
    ]

    /// Folder a given raw connector's data is primarily routed into (Phase C uses
    /// this; declared here so the mapping lives with the schema).
    static func primaryDestination(forConnector connector: String) -> Folder? {
        switch connector {
        case "capture": return folder("01")
        case "gmail":   return folder("05")
        case "gcal":    return folder("01")
        case "github":  return folder("03")
        case "gdrive", "notion": return folder("06")
        default: return nil
        }
    }

    static func folder(_ number: String) -> Folder? {
        folders.first { $0.number == number }
    }

    // MARK: - Scaffold

    /// Create the folder structure and seed each folder's `index.md` template.
    /// Idempotent and non-destructive: existing user edits are preserved by the
    /// Curator, and raw-connector placeholders are written only once.
    static func scaffold() {
        guard MullDirectory.status == .ready else { return }

        migrateLegacyProjects()

        // Raw zone: one dir per connector, seeded once with a placeholder.
        for connector in rawConnectors {
            let keep = "\(rawRoot)/\(connector)/.keep"
            if !MullDirectory.exists(keep) {
                _ = MullDirectory.write("", to: keep)
            }
        }

        // Derived zone: each numbered folder's index.md, curated.
        for folder in folders {
            seedIndex(folder)
        }
    }

    /// Write/update a folder's index.md through the Curator. Section blocks are
    /// placeholders until synthesis (Phase C) fills them; user edits are protected.
    private static func seedIndex(_ folder: Folder) {
        var header = "# \(folder.number) \(folder.title)\n\n_\(folder.purpose)_"
        if let canonical = folder.canonical {
            header += "\n\nCanonical file: [../\(canonical)](../\(canonical))"
        }
        header += "\n\n> mull keeps its own blocks below up to date. Edit anything else freely — it won't be overwritten."

        // "Awaiting synthesis" only makes sense if a source actually routes here.
        // Folders with no connector (e.g. 02_work, 04_career) would otherwise sit
        // on that placeholder forever; show an honest invite instead.
        let hasSource = rawConnectors.contains {
            $0 != "capture" && primaryDestination(forConnector: $0)?.number == folder.number
        }
        let placeholder = hasSource ? "_(awaiting synthesis)_"
            : "_No connected source yet — add notes here, or connect one in Settings._"
        let blocks = folder.sections.map { section in
            ContextBlock(
                id: "section:\(ContextBlockFile.slug(section))",
                source: .agent,
                content: "## \(section)\n\n\(placeholder)",
                agentHash: nil
            )
        }
        _ = Curator.curate(relativePath: folder.indexPath, header: header,
                           pinnedContent: nil, agentBlocks: blocks)
    }

    /// One-time move of the old flat `projects/` into `03_projects/`.
    private static func migrateLegacyProjects() {
        let fm = FileManager.default
        let old = MullDirectory.root.appendingPathComponent("projects", isDirectory: true)
        guard fm.fileExists(atPath: old.path),
              let entries = try? fm.contentsOfDirectory(atPath: old.path) else { return }

        let newDir = MullDirectory.root.appendingPathComponent("03_projects", isDirectory: true)
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

        for name in entries where name.hasSuffix(".md") {
            let src = old.appendingPathComponent(name)
            let dst = newDir.appendingPathComponent(name)
            if !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
        // Remove the old dir if it's now empty.
        if let remaining = try? fm.contentsOfDirectory(atPath: old.path), remaining.isEmpty {
            try? fm.removeItem(at: old)
        }
    }
}
