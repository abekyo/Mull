import Foundation

/// "Are these two captured strings the same thing said twice?"
///
/// mull's sources emit the same content repeatedly by construction, and every
/// consumer of that material has to answer this question:
///
/// - Window titles are polled every 5 seconds, so one screen produces the same
///   title over and over. A real `search` for `訂正ループ` came back with eight
///   results, all of them the same title, because nothing deduplicated them and
///   the ranker had no reason to prefer one copy over another. That is the
///   `duplicate-flood` case in the eval.
/// - A typing or dictation buffer flushes the sentence as it grows, so the same
///   utterance arrives in several lengths. `うーん、今のところ4年フィリピンにいて`
///   and `今のところ4年フィリピンにいてそろそろ国変えてもいいかなって思ってる`
///   differ at character one and say the same thing.
///
/// The two surfaces that needed this each grew their own version, which is the
/// shape PITFALLS.md §7 is about, so it lives here once.
///
/// Foundation-only, so `Selection`, the composer and the standalone eval harness
/// can all share the one definition.
enum NearDuplicate {

    /// Do these two strings say the same thing?
    ///
    /// The test is a shared contiguous run, sized against the SHORTER string
    /// rather than fixed. Two genuinely different notes can share a stock phrase
    /// (`TODO: wire the`, `database: database`); what they do not share is most of
    /// one of them. `coverage` is what separates those cases, and lowering it
    /// starts folding things the user wrote separately and meant separately.
    ///
    /// `floor` keeps very short strings out of it: at eight characters, "most of
    /// one of them" is a coincidence rather than evidence.
    static func sameContent(_ a: String, _ b: String,
                            coverage: Double = 0.6, floor: Int = 12) -> Bool {
        let x = canonical(a), y = canonical(b)
        if x == y { return true }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        let need = max(floor, Int(Double(short.count) * coverage))
        guard short.count >= need else { return false }
        let chars = Array(short)
        for start in 0...(chars.count - need) where long.contains(String(chars[start..<(start + need)])) {
            return true
        }
        return false
    }

    /// Is this string the same thing as something already kept?
    static func isRepeat(_ candidate: String, of kept: [String],
                         coverage: Double = 0.6, floor: Int = 12) -> Bool {
        kept.contains { sameContent($0, candidate, coverage: coverage, floor: floor) }
    }

    /// Collapse runs of whitespace and fold case, so the same title captured twice
    /// with different spacing is one string. Deliberately does NOT strip
    /// punctuation: `(2m41s)` is the only thing separating two otherwise identical
    /// activity lines, and removing it would merge two different measurements.
    private static func canonical(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
