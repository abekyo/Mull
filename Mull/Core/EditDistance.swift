import Foundation

/// How far one piece of text had to travel to become another, on a 0…1 scale.
///
/// This exists for one measurement: the distance between the draft the understudy
/// wrote and the text the user actually kept. CLAUDE.md's roadmap ("fidelity の実測:
/// 編集距離が日ごとに縮むことをログで確認") and DESIGN-NORTHSTAR §3.5 ("fidelity >
/// capability —「あなたらしさ」を測り、磨く(編集距離の縮み)") both stake the product on
/// that number shrinking over time, and until now nothing in mull computed it — the
/// word "fidelity" appeared eight times in comments and zero times in an expression.
enum EditDistance {

    /// Characters compared before the inputs are truncated.
    ///
    /// Levenshtein is O(n·m). At this bound the worst case is ~4M cell updates —
    /// single-digit milliseconds, run once when the user presses a button. Unbounded,
    /// two long reports (mull's are capped at 4000 model tokens but a hand-written one
    /// is not) would be hundreds of millions of updates and would visibly stall the
    /// approve button. Reports open with their substance, so a prefix is a fair sample.
    static let comparedPrefix = 2000

    /// Normalized distance: 0 when the texts are the same, 1 when they share nothing.
    ///
    /// Compared by CHARACTER, not by whitespace-delimited word, and this is the one
    /// decision in here worth arguing about. Word tokens are the usual choice and are
    /// cheaper, but Japanese does not put spaces between words: an entire Japanese
    /// paragraph tokenizes to one or two "words", so a word-level measure would return
    /// almost exactly 0.0 or 1.0 for the bilingual user this product is built around,
    /// making the trend line meaningless precisely where it matters. Characters are
    /// language-neutral and Levenshtein does not care what script they are in.
    ///
    /// Whitespace is normalized away first: re-wrapping a paragraph or inserting a
    /// blank line changes no words and says nothing about voice, so counting it would
    /// fill the series with noise and hide the drift the series exists to show.
    static func normalized(_ a: String, _ b: String) -> Double {
        let lhs = Array(canonical(a).prefix(comparedPrefix))
        let rhs = Array(canonical(b).prefix(comparedPrefix))
        let longest = max(lhs.count, rhs.count)
        guard longest > 0 else { return 0 }
        return min(1, Double(distance(lhs, rhs)) / Double(longest))
    }

    /// Collapses every run of whitespace to a single space and trims the ends.
    static func canonical(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// Levenshtein over two rolling rows rather than the full matrix: the algorithm
    /// only ever reads the previous row, so holding n·m cells would cost 4MB at the
    /// bound above to store numbers that are never looked at again.
    static func distance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)

        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let substitution = previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1,        // deletion
                                 current[j - 1] + 1,     // insertion
                                 substitution)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
