import Foundation

/// The learning signal from human corrections, applied at selection time.
///
/// A correction says one of two things about a piece of text: the human **kept**
/// it (it belonged) or **dropped** it (it did not). That verdict is
/// occupation-neutral — it holds whatever vocabulary the text is written in —
/// which is why it is the only layer that can lift the top salience tiers
/// without a per-trade word list. Adding FX words, then legal words, then video
/// words is the failure mode this replaces.
///
/// It is also the only signal no competitor can have. Screenpipe / ManicTime /
/// Timing capture the same activity; ChatGPT and Copilot Memory let you delete a
/// remembered item. **What none of them have is the correction tied to what you
/// were doing when you made it** (HARNESS.md 第II部 §6).
///
/// Deliberately GRDB-free: `Selection` reads it on every query and the eval
/// harness has to be able to build one, which is what makes the convergence
/// curve measurable at all.
struct CorrectionIndex {

    struct Entry {
        /// Verdict in [-1, +1]. Positive means "the human kept this".
        var delta: Double
        /// A readable fragment, so the ledger is something a person can audit.
        var sample: String
    }

    static let empty = CorrectionIndex(entries: [:])

    private(set) var entries: [String: Entry]

    init(entries: [String: Entry]) { self.entries = entries }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    /// What "the same text" means, for both sides of the loop.
    ///
    /// Built on `EditDistance.canonical` so whitespace and case differences
    /// between the vault copy of a line and the event it came from do not read as
    /// different texts. Truncated before hashing: a corrected bullet and the
    /// clipboard entry it was assembled from often share only a prefix.
    static func signature(_ text: String) -> String {
        // `EditDistance.canonical` collapses whitespace only — it deliberately
        // keeps case, because case IS voice for the fidelity series it was built
        // for. A correction verdict is not about voice, so the case fold is added
        // here rather than there.
        let canon = EditDistance.canonical(text).lowercased()
        return ContextBlock.hash(String(canon.prefix(64)))
    }

    /// The verdict for this text, or 0 if it has never been corrected.
    func delta(for text: String) -> Double {
        guard !entries.isEmpty else { return 0 }
        return entries[Self.signature(text)]?.delta ?? 0
    }

    // MARK: - Building

    /// Fold corrections into an index.
    ///
    /// Repeats reinforce rather than replace: a line dropped twice is stronger
    /// evidence than a line dropped once, clamped so no single text dominates.
    /// `survived` is worth a quarter of `dropped` because leaving something alone
    /// is weaker evidence than deleting it — a human who edits one bullet has not
    /// thereby endorsed the other five.
    static func fold(_ cards: [CorrectionCard]) -> CorrectionIndex {
        var out: [String: Entry] = [:]
        func add(_ line: String, _ d: Double) {
            let sig = signature(line)
            let prior = out[sig]?.delta ?? 0
            out[sig] = Entry(delta: max(-1, min(1, prior + d)), sample: sample(line))
        }
        for card in cards {
            for line in card.dropped { add(line, -1.0) }
            for line in card.survived { add(line, 0.25) }
        }
        return CorrectionIndex(entries: out)
    }

    /// Combine two indexes, summing verdicts and clamping. Used to fold today's
    /// corrections into the ledger already on disk without losing history.
    static func merge(_ a: CorrectionIndex, _ b: CorrectionIndex) -> CorrectionIndex {
        var out = a.entries
        for (sig, e) in b.entries {
            let prior = out[sig]?.delta ?? 0
            out[sig] = Entry(delta: max(-1, min(1, prior + e.delta)),
                             sample: out[sig]?.sample.isEmpty == false ? out[sig]!.sample : e.sample)
        }
        return CorrectionIndex(entries: out)
    }

    private static func sample(_ line: String) -> String {
        String(line.replacingOccurrences(of: "|", with: "/").prefix(60))
    }

    // MARK: - Ledger (the durable, human-editable form)

    /// Path inside the vault. Plain markdown, in the knowledge folder, because a
    /// signal the user cannot read and correct is not a signal they own
    /// (DIRECTION §6 / Invariant Contract 契約2).
    static let directory = "corrections"
    static let ledgerPath = directory + "/ledger.md"

    static let ledgerHeader = """
    # Correction ledger

    mull が出したものを、あなたがどう直したか。1行が1判定です。

    **このファイルは編集できます。** 行を消せばその判定は効かなくなり、
    `delta` を書き換えれば重みが変わります。mull はこのファイルを読んで
    選択の並び順を決めます（SELECTION-LAYER §4）。

    | 判定 | delta | signature | text |
    |---|---|---|---|
    """

    func renderLedger() -> String {
        var out = Self.ledgerHeader
        for (sig, e) in entries.sorted(by: { $0.value.delta < $1.value.delta }) {
            let verdict = e.delta < 0 ? "dropped" : "kept"
            out += "\n| \(verdict) | \(String(format: "%+.2f", e.delta)) | `\(sig)` | \(e.sample) |"
        }
        return out + "\n"
    }

    /// Parse a ledger table back into an index. Unparseable rows are skipped
    /// rather than failing the load — a hand-edited file must never be able to
    /// take the selection layer down.
    static func parseLedger(_ text: String) -> CorrectionIndex {
        var out: [String: Entry] = [:]
        for line in text.components(separatedBy: "\n") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 5, let delta = Double(cells[2]) else { continue }
            let sig = cells[3].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            guard !sig.isEmpty, sig != "signature" else { continue }
            out[sig] = Entry(delta: max(-1, min(1, delta)), sample: cells[4])
        }
        return CorrectionIndex(entries: out)
    }
}
