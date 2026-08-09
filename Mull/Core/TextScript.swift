import Foundation

/// Which writing system a string is in, for the decisions that turn on it.
///
/// Lives here — not on `DatabaseService` — because the selection layer needs it
/// too, and `DatabaseService` imports GRDB. Keeping this GRDB-free is what lets
/// `eval/selection_eval.swift` compile and run standalone in seconds.
enum TextScript {

    /// True when the string contains kana or CJK ideographs.
    ///
    /// FTS5's default `unicode61` tokenizer treats every CJK codepoint as a token
    /// character, so a contiguous Japanese run indexes as ONE token: 「今日の会議のメモ」
    /// is a single term. A substring query like 会議 therefore can never
    /// prefix-match it, and FTS silently returns nothing. Those queries take the
    /// LIKE path against the base table instead.
    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            (0x3040...0x30FF).contains(u.value) ||   // hiragana + katakana
            (0x3400...0x4DBF).contains(u.value) ||   // CJK extension A
            (0x4E00...0x9FFF).contains(u.value) ||   // CJK unified ideographs
            (0xF900...0xFAFF).contains(u.value)      // CJK compatibility
        }
    }
}
