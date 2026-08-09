import Foundation

/// One human correction of mull's output, recorded as a Correction Card
/// (HARNESS.md 第II部 §2).
///
/// **Sections 1–3 are filled from what mull can observe. Sections 4–8 are left
/// blank on purpose.** Hidden axis, Reasoning chain and Contrast are the
/// intellectual work of the card — a machine-written guess there is a plausible
/// lie, not a label. That boundary is the same one §3.6's constitution draws
/// ("下書きまで・発火は常に主") and the same one DIRECTION 付録A ② draws between
/// observation and interpretation: **observation is automatable, interpretation
/// is not.**
///
/// Why this exists at all: until 2026-08-09 mull detected human edits (Curator
/// promoted the block to `.human`) and then **threw the signal away**. It knew
/// it had been corrected and kept no record of what about. The edit distance in
/// `ReportWriter` measured the same thing as a scalar — how *much* was changed —
/// which cannot answer "what was different this time" (PRC-003 文脈転写の不可能性).
struct CorrectionCard {

    /// Which curated file, and which block inside it.
    let path: String
    let blockID: String
    let date: Date

    /// What the human left behind. This is the ground truth of the correction.
    let kept: String

    /// What mull would write for this block id on this pass.
    ///
    /// **Not the exact text the human edited.** The block marker stores only a
    /// hash of what mull last wrote, so the original is unrecoverable once
    /// overwritten. For the rule-based passes (which regenerate deterministically
    /// every 60s) this is nearly always the same text; for the nightly LLM pass it
    /// may not be. The card says so rather than claiming a provenance it lacks
    /// (Invariant Contract 契約1).
    let wouldWrite: String?

    /// `whats_active_now()` at the time the correction was noticed, when the
    /// caller has a database to ask. Nil in the MCP binary and in tests.
    let context: String?

    /// Lines mull would have written that the human did not keep.
    var dropped: [String] {
        guard let w = wouldWrite else { return [] }
        let keptSet = Set(Self.lines(kept))
        return Self.lines(w).filter { !keptSet.contains($0) }
    }

    /// Lines present in both — mull wrote them and the human let them stand.
    var survived: [String] {
        guard let w = wouldWrite else { return [] }
        let wouldSet = Set(Self.lines(w))
        return Self.lines(kept).filter { wouldSet.contains($0) }
    }

    /// Lines the human wrote that mull did not propose.
    var added: [String] {
        guard let w = wouldWrite else { return Self.lines(kept) }
        let wouldSet = Set(Self.lines(w))
        return Self.lines(kept).filter { !wouldSet.contains($0) }
    }

    /// How far the human moved the block, 0…1. The scalar `ReportWriter` already
    /// tracked for reports — kept here so the convergence curve can be measured
    /// outside the daily report, which is where it was trapped.
    var drift: Double {
        guard let w = wouldWrite else { return 1 }
        return EditDistance.normalized(w, kept)
    }

    static func lines(_ s: String) -> [String] {
        s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `CRX-2026-08-09-a1b2c3` — date for reading, block hash for uniqueness, so
    /// two corrections on the same day never collide and the same block corrected
    /// twice is visibly the same block.
    var id: String {
        "CRX-\(Self.day(date))-\(String(ContextBlock.hash(path + blockID).prefix(6)))"
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: d)
    }

    /// The card, as markdown. Sections 4–8 ship as prompts, not as guesses.
    func render() -> String {
        var out = """
        ## [CORRECTION] ID: \(id)
        - Date: \(Self.day(date))
        - File: `\(path)`
        - Block: `\(blockID)`
        - Drift: \(String(format: "%.2f", drift))
        - Retrieval cues: \(cues.joined(separator: ", "))

        ### 1. Context snapshot  ← 自動
        """
        out += "\n" + (context.map { $0 } ?? "_（この呼び出し元はデータベースを持たないため未取得）_")

        out += "\n\n### 2. Failed move  ← 自動\n"
        if let w = wouldWrite {
            out += "\n**mull がこの id に書こうとしている内容**（訂正直前の版そのものではない。上の doc comment 参照）:\n\n"
            out += "```\n\(w)\n```\n"
        } else {
            out += "\n_この pass では mull はこの id に候補を出していない。人間が書いた内容のみ記録する。_\n"
        }
        out += "\n**人間が残した内容**:\n\n```\n\(kept)\n```\n"

        out += "\n### 3. Signals observed  ← 自動（機械走査）\n\n"
        out += "- 編集距離: \(String(format: "%.2f", drift))\n"
        out += "- mull が書いて残らなかった行: \(dropped.count)\n"
        for l in dropped.prefix(10) { out += "  - ~~\(l)~~\n" }
        out += "- mull が書いて残った行: \(survived.count)\n"
        for l in survived.prefix(10) { out += "  - \(l)\n" }
        out += "- 人間が足した行: \(added.count)\n"
        for l in added.prefix(10) { out += "  - **\(l)**\n" }

        out += """

        ### 4. Hidden axis  ← 人＋モデル。自動生成しない

        _真の分水嶺は何か。表層の違いではなく、なぜその違いが問題なのか。_

        ### 5. Reasoning chain  ← 人＋モデル。自動生成しない

        _この訂正を入れなかった場合、読み手の認知はどう壊れるか。_

        ### 6. Judgment criteria  ← 人

        _あなたはどの基準で線を引いたか。_

        ### 7. Reusable rule

        - Use when:
        - Avoid when:
        - Check question:
        - Safer alternative:

        ### 8. Contrast  ← 人＋モデル。自動生成しない

        - Similar-looking success:
        - Why different:
        - Boundary learned:

        ### 9. Transfer

        - Abstract principle:
        - Scope:
        - Tags:

        """
        return out
    }

    /// Retrieval cues, so the card can be *found* later. A card nobody can
    /// retrieve is dead storage — half the reason the Case Card schema has nine
    /// sections is this field and the Check question (HARNESS.md 第II部 §3).
    var cues: [String] {
        var c = [blockID, (path as NSString).deletingPathExtension]
        if let first = Self.lines(kept).first { c.append(String(first.prefix(30))) }
        return c.filter { !$0.isEmpty }
    }
}
