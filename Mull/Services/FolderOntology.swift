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
        let fills: FillSource     // how this folder gets its content — drives guidance

        var path: String { "\(number)_\(slug)" }
        var indexPath: String { "\(path)/index.md" }

        /// One plain line for the index header: how this folder fills and what,
        /// if anything, the user should DO. The fool-proofing — every folder
        /// explains itself, so an empty one never reads as "broken / now what?".
        var guidance: String { guidance(japanese: UserLanguage.isJapanese) }

        func guidance(japanese: Bool) -> String {
            if japanese {
                switch fills {
                case .automatic:
                    return "mull が作業を見ながら自動で埋めます — 何もしなくて大丈夫です。"
                case .nightlyAI:
                    return "Settings で AI をオンにすると自動で埋まります。自分で書いても構いません。AI なしでも mull は動きます。"
                case .connectSource(let name):
                    return "Settings で \(name) を接続すると自動で埋まります。自分で書き足しても構いません。"
                case .yourNotes:
                    return "自動では埋まりません — 自由に書く場所です。書いたことは AI が読む文脈になります。"
                }
            }
            switch fills {
            case .automatic:
                return "Fills automatically as mull watches you work — nothing to do."
            case .nightlyAI:
                return "Turn on AI in Settings to fill this automatically, or jot entries here yourself. mull works fully offline without it."
            case .connectSource(let name):
                return "Connect \(name) in Settings to fill this automatically, or add entries here yourself."
            case .yourNotes:
                return "No automatic source — just write here. What you add becomes context the AI uses."
            }
        }

        /// Short placeholder shown inside an otherwise-empty section.
        var emptyHint: String { emptyHint(japanese: UserLanguage.isJapanese) }

        func emptyHint(japanese: Bool) -> String {
            if japanese {
                switch fills {
                case .automatic:            return "_まだ何もありません — 作業すると自動で埋まります。_"
                case .nightlyAI:            return "_まだ何もありません — Settings で AI をオンにするか、自分で書いてください。_"
                case .connectSource(let n): return "_まだ何もありません — Settings で \(n) を接続するか、自分で書いてください。_"
                case .yourNotes:            return "_自由に書いてください。_"
                }
            }
            switch fills {
            case .automatic:            return "_Nothing here yet — fills automatically as you work._"
            case .nightlyAI:            return "_Nothing here yet — turn on AI in Settings, or add your own._"
            case .connectSource(let n): return "_Nothing here yet — connect \(n) in Settings, or add your own._"
            case .yourNotes:            return "_Write here freely._"
            }
        }

        /// Heading + purpose as the reader's language spells them. The folder's
        /// on-disk name (`03_projects`) and block ids stay English — they are
        /// structure, stable across locale switches; only display text follows.
        var displayTitle: String {
            UserLanguage.isJapanese ? (FolderOntology.jaTitles[number] ?? title) : title
        }
        var displayPurpose: String {
            UserLanguage.isJapanese ? (FolderOntology.jaPurposes[number] ?? purpose) : purpose
        }
    }

    /// How a folder's content arrives — drives the self-explaining guidance.
    enum FillSource {
        case automatic               // derived from what mull already captures
        case nightlyAI               // richer with an LLM on; offline = jot here
        case connectSource(String)   // connect a source in Settings (e.g. "Gmail")
        case yourNotes               // no automatic source — the user writes it
    }

    static let rawRoot = "_raw"

    /// Source connectors (Phase B populates these; Phase A just creates the dirs).
    static let rawConnectors = ["capture", "gmail", "gcal", "gdrive", "github", "notion"]

    static let folders: [Folder] = [
        Folder(number: "00", slug: "identity", title: "Identity",
               purpose: "Who you are — profile, skills, preferences, values.",
               sections: ["Summary", "Skills", "Preferences", "Values"],
               canonical: "me.md", fills: .automatic),
        Folder(number: "01", slug: "now", title: "Now",
               purpose: "Your current state — what you're focused on right now.",
               sections: ["Current focus", "This week", "Upcoming"],
               canonical: "now.md", fills: .automatic),
        Folder(number: "02", slug: "work", title: "Work",
               purpose: "Businesses and employers you work in or on.",
               sections: ["Organizations", "Responsibilities", "Status"],
               canonical: nil, fills: .yourNotes),
        Folder(number: "03", slug: "projects", title: "Projects",
               purpose: "Active projects. Per-project briefings live alongside this index.",
               sections: ["Active projects", "Recently touched"],
               canonical: nil, fills: .automatic),
        Folder(number: "04", slug: "career", title: "Career",
               purpose: "Your career arc — roles, achievements, goals.",
               sections: ["Roles", "Achievements", "Goals", "Resume material"],
               canonical: nil, fills: .yourNotes),
        Folder(number: "05", slug: "people", title: "People",
               purpose: "Key relationships and the context behind them.",
               sections: ["Key people", "Context per person"],
               canonical: nil, fills: .connectSource("Gmail")),
        Folder(number: "06", slug: "knowledge", title: "Knowledge",
               purpose: "Decisions, references, and things you've learned.",
               sections: ["Decisions", "References", "Learnings"],
               canonical: "MEMORY.md", fills: .nightlyAI),
        Folder(number: "09", slug: "inbox", title: "Inbox",
               purpose: "Freshly ingested data, unsorted, awaiting routing.",
               sections: ["Unsorted"],
               canonical: nil, fills: .automatic),
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

    // MARK: - Japanese display text
    //
    // Keyed by the stable identifiers (folder number, English section name), so
    // schema and translation cannot drift silently — a folder or section missing
    // from these maps falls back to English, and a test asserts completeness.

    static let jaTitles: [String: String] = [
        "00": "自分", "01": "いま", "02": "仕事", "03": "プロジェクト",
        "04": "キャリア", "05": "人", "06": "知識", "09": "インボックス",
    ]

    static let jaPurposes: [String: String] = [
        "00": "あなたが誰か — プロフィール、スキル、好み、価値観。",
        "01": "いまの状態 — 直近で取り組んでいること。",
        "02": "関わっている事業・勤め先。",
        "03": "進行中のプロジェクト。プロジェクト別の資料もこのフォルダに入ります。",
        "04": "キャリアの歩み — 役割、実績、目標。",
        "05": "大事な人間関係と、その背景。",
        "06": "決めたこと、参照資料、学んだこと。",
        "09": "取り込んだばかりの未整理データ。ここから各フォルダへ振り分けられます。",
    ]

    static let jaSections: [String: String] = [
        "Summary": "概要", "Skills": "スキル", "Preferences": "好み", "Values": "価値観",
        "Current focus": "いまの焦点", "This week": "今週", "Upcoming": "この先",
        "Organizations": "組織", "Responsibilities": "担当", "Status": "状況",
        "Active projects": "進行中", "Recently touched": "最近触れたもの",
        "Roles": "役割", "Achievements": "実績", "Goals": "目標", "Resume material": "職務経歴の材料",
        "Key people": "主要な人", "Context per person": "人ごとの背景",
        "Decisions": "決定", "References": "参照", "Learnings": "学び",
        "Unsorted": "未整理",
    ]

    /// Display heading for a schema section. Block ids stay slugs of the ENGLISH
    /// name (stable across locale switches); only the visible `## heading` follows
    /// the reader. Shared by seedIndex, FolderFiller and SynthesisEngine so all
    /// three writers produce the same heading for the same block.
    static func sectionHeading(_ section: String, japanese: Bool = UserLanguage.isJapanese) -> String {
        japanese ? (jaSections[section] ?? section) : section
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
    /// The Curator header for a folder's index.md. Shared by `seedIndex` (the
    /// empty template) and `FolderFiller` (the rule-based fill) so both produce
    /// an identical header and only the section blocks differ.
    /// Four separate pieces of chrome — purpose, how-it-fills, canonical link and
    /// a never-overwritten promise — used to open every index above the content,
    /// and in a folder with nothing in it yet they were four times longer than the
    /// three `_Nothing here yet_` placeholders they introduced. Three of the four
    /// are facts ABOUT the file, so they belong in front matter; only the promise,
    /// which changes how the user may safely act, stays in the body.
    static func indexHeader(for folder: Folder) -> String {
        let ja = UserLanguage.isJapanese
        var meta: [(String, String)] = [
            (ja ? "内容" : "purpose", folder.displayPurpose),
            (ja ? "埋まり方" : "fills", folder.guidance),
        ]
        if let canonical = folder.canonical {
            meta.append((ja ? "元ファイル" : "canonical", "../\(canonical)"))
        }
        return MarkdownDoc.header(
            title: "\(folder.number) \(folder.displayTitle)",
            meta: meta,
            note: ja
                ? "mull が自動更新するのは、mull 自身が書いたブロックだけです。それ以外はどこを編集しても上書きされません。"
                : "mull keeps its own blocks below up to date. Edit anything else freely — it won't be overwritten.")
    }

    /// Seed a folder's index with its section skeleton — but only on first
    /// creation.
    ///
    /// The skeleton exists so a brand-new vault is shaped and self-explaining
    /// rather than a bare header. Re-applying it on every launch would fight the
    /// fillers, which own `section:` blocks and (correctly) omit the ones they
    /// have nothing for: scaffold would re-add the placeholder at startup and the
    /// filler would drop it five minutes later, forever.
    private static func seedIndex(_ folder: Folder) {
        let header = indexHeader(for: folder)

        // An existing index gets its header refreshed and nothing else — the
        // fillers and the user own the blocks by then. No agent candidates and no
        // managed prefixes means `merge` carries every existing block through
        // untouched, which is exactly the intent.
        guard !MullDirectory.exists(folder.indexPath) else {
            _ = Curator.curate(relativePath: folder.indexPath, header: header,
                               pinnedContent: nil, agentBlocks: [])
            return
        }

        // Each empty section explains itself (folder.emptyHint) instead of the old
        // jargon "(awaiting synthesis)" — a fresh, empty vault is never confusing.
        let placeholder = folder.emptyHint
        let blocks = folder.sections.map { section in
            ContextBlock(
                id: "section:\(ContextBlockFile.slug(section))",
                source: .agent,
                content: "## \(sectionHeading(section))\n\n\(placeholder)",
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
