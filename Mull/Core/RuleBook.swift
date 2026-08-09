import Foundation

/// `~/mull/rules.md` — the rules your corrections produced, in the one place an
/// agent reads at the start of every session.
///
/// This is the last link of the chain CLAUDE.md §0 calls 場面 **B**:
///
/// ```
/// mull が草案する → 人が直す → Correction Card §1–3（観測・自動）
///                            → エージェントが §4–9 を埋める（解釈）
///                            → rules.md → 次のセッションで読まれる
/// ```
///
/// Everything before the last arrow existed by 2026-08-09 and stopped there: the
/// cards were written into a folder nothing pointed at. A rule nobody reads is
/// not a rule, so this type is deliberately small and deliberately final —
/// **it is the step that makes the loop a loop.**
///
/// Two things it does NOT do, both on purpose:
///
/// - **It does not write the rule.** Section 7 of a card is filled by a human or
///   an agent, never by mull (HARNESS.md 第II部 §2 の自動化境界). This type only
///   collects what was written and puts it where it will be read.
/// - **It does not own the file.** `rules.md` goes through `Curator`, so a rule
///   the user rewrites is promoted to `.human` and mull never touches it again.
///   The rules are the user's; mull assembles the index of them.
///
/// GRDB-free, and pure apart from `rebuild()` — the same discipline as
/// `CorrectionIndex`, for the same reason: `MullMCP` links it and the tests have
/// to be able to build one from strings.
enum RuleBook {

    /// Root of the vault, next to `me.md`. A rule that lives three folders deep is
    /// a rule the user never opens.
    static let path = "rules.md"

    /// The block id an agent writes into a Correction Card to record the rule it
    /// drew from that correction. One id, so a card can carry exactly one rule —
    /// a correction that teaches three separate things is three corrections.
    static let blockID = "rule"

    /// Files in `corrections/` that are not cards.
    private static let nonCardFiles: Set<String> = ["ledger.md"]

    // MARK: - Reading cards

    /// The rule an agent recorded in this card, if any.
    ///
    /// Nil means the card is still **unfilled** — mull wrote sections 1–3 and
    /// nobody has done the interpretation yet. That is the normal state of a fresh
    /// card, not an error.
    static func rule(inCard text: String) -> String? {
        let (_, blocks) = ContextBlockFile.parse(text)
        guard let block = blocks.first(where: { $0.id == blockID }) else { return nil }
        let body = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// Card ids whose rule has not been written yet, oldest first.
    ///
    /// Oldest first because a correction loses its context as it ages: the card
    /// records what mull saw, but the person who can say *why* they made the edit
    /// is losing that answer by the day.
    static func unfilled(cards: [(id: String, text: String)]) -> [String] {
        cards.filter { rule(inCard: $0.text) == nil }.map(\.id).sorted()
    }

    // MARK: - Composing the book

    /// One block per card that has a rule. Pure, so the assembly is testable
    /// without a vault.
    ///
    /// The card id is the block id, which means re-running this is idempotent and
    /// a rule whose card is deleted stops being emitted — but it does NOT vanish
    /// from `rules.md`, because `Curator.curate` is called without a managed
    /// prefix here. Rules accumulate; removing one is the user's act, not a side
    /// effect of tidying the corrections folder.
    static func compose(cards: [(id: String, text: String)]) -> [ContextBlock] {
        cards.compactMap { card in
            guard let body = rule(inCard: card.text) else { return nil }
            let content = "### \(card.id)\n\n\(body)"
            return ContextBlock(id: card.id, source: .agent, content: content,
                                agentHash: ContextBlock.hash(content))
        }.sorted { $0.id < $1.id }
    }

    /// Continuation lines carry their own `> ` because `MarkdownDoc.header` marks
    /// only the first one, and a note that falls out of its own blockquote reads
    /// as body text the user is meant to edit.
    static func header(count: Int, pending: Int) -> String {
        var note = "あなたが mull の出力を直したとき、そこから引き出された規則です。"
        note += "\n>\n> **この規則は記録からは出てきません。** mull が観測できるのは事実"
        note += "（何を開いていたか、何をコピーしたか）で、「どう振る舞ってほしいか」は"
        note += "あなたが直した瞬間にしか現れません。ここにあるものは全てあなた由来です。"
        note += "\n>\n> **編集できます。** 書き換えた規則は `human` として保護され、mull は二度と上書きしません。"
        note += "要らない規則はブロックごと消してください。"
        if pending > 0 {
            note += "\n>\n> 未記入の訂正が **\(pending) 件**あります"
            note += "（`corrections/` にカードがあり、まだ規則が書かれていない）。"
        }
        return MarkdownDoc.header(
            title: "Rules",
            meta: [("rules", "\(count)"),
                   ("pending", "\(pending)"),
                   ("provenance", "agent = mull が集めた / human = あなたが書き換えた")],
            note: note)
    }

    // MARK: - I/O

    /// Every card in `corrections/`, as (id, text).
    static func loadCards() -> [(id: String, text: String)] {
        MullDirectory.markdownFiles(in: CorrectionIndex.directory)
            .filter { !nonCardFiles.contains(($0 as NSString).lastPathComponent) }
            .compactMap { relative in
                guard let text = MullDirectory.read(relative) else { return nil }
                let id = (relative as NSString).lastPathComponent
                    .replacingOccurrences(of: ".md", with: "")
                return (id, text)
            }
    }

    /// Re-assemble `rules.md` from the cards on disk.
    ///
    /// Cheap enough to call on the read path (a handful of small files), and doing
    /// so is what guarantees the file an agent reads is not stale. Goes through
    /// `Curator.curate`, so this is also a correction-detection point: a rule the
    /// user rewrote is itself a correction, and gets its own card.
    @discardableResult
    static func rebuild() -> Bool {
        let cards = loadCards()
        let blocks = compose(cards: cards)
        // Nothing to say yet, and no file to keep fresh: stay silent rather than
        // laying down an empty scaffold the user has to wonder about.
        guard !blocks.isEmpty || MullDirectory.read(path) != nil else { return false }
        return Curator.curate(relativePath: path,
                              header: header(count: blocks.count,
                                             pending: unfilled(cards: cards).count),
                              pinnedContent: nil,
                              agentBlocks: blocks)
    }
}
