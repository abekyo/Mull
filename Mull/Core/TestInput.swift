import Foundation

/// Single source of truth for "this looks like synthetic test/QA input, not real
/// activity." When you type "the quick brown fox" or "test   double   spaces" to
/// check that mull is recording, that input is not part of your real work — left
/// in, it pollutes keyword / phrase / language analytics with garbage.
///
/// This is the content-based sibling of RecordingService's app-exclusion list:
/// app exclusion filters by *source app*, this filters by *content*. Kept
/// dependency-free (Foundation only) so the recording gate and the analytics
/// layer can share one definition instead of each re-inventing the rules.
enum TestInput {

    /// Classic filler / pangrams people type to test text handling.
    private static let fillerPhrases: [String] = [
        "the quick brown fox",
        "pack my box with five dozen",
        "sphinx of black quartz",
        "lorem ipsum",
        "hello world hello world",
    ]

    /// Keyboard-row mashing. Strong, low-false-positive markers only
    /// (vim "hjkl" and numeric "12345" are intentionally excluded — they appear
    /// in real work).
    private static let keyboardMash: [String] = [
        "asdf", "asdfgh", "asdfjkl", "qwert", "qwerty", "qwertyuiop",
        "zxcv", "zxcvbn", "zxcvbnm",
    ]

    /// `true` when `raw` looks like QA/test input rather than genuine activity.
    /// High-precision by design: it would rather miss a test string than drop
    /// real work.
    static func isLikelyTestInput(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()

        // A. Known filler phrases / pangrams.
        if fillerPhrases.contains(where: { lower.contains($0) }) { return true }

        // B. Keyboard-row mashing.
        if keyboardMash.contains(where: { lower.contains($0) }) { return true }

        // C. Two or more consecutive single-letter "words" ("a b cd efg ...").
        //    Natural prose almost never has adjacent single-letter words —
        //    English has only "a" and "I".
        if hasConsecutiveSingleLetters(text) { return true }

        // D. Abnormal inter-word spacing — a 3+ space gap between words on a
        //    single short line ("test   double   spaces"). Code indentation is
        //    leading (line-start), not between words, so it isn't matched here.
        if !text.contains("\n") && text.count < 100 && containsWideInterWordGap(text) {
            return true
        }

        // E. The same character repeated 5+ times ("aaaaa").
        if hasLongCharRun(text) { return true }

        // F. A whole short line that is one character repeated ("ああ", "あああ",
        //    "!!"). Rule E only fires at five, which is why `ああ / あああ /
        //    あああ` sat at the top of the shipped me.md — as the user's pinned,
        //    authoritative identity — for over a month. Bounded to short lines so
        //    it cannot touch real prose.
        if text.count <= 12, isSingleRepeatedCharacter(text) { return true }

        return false
    }

    /// A string of 2+ characters that are all the same (ignoring whitespace).
    private static func isSingleRepeatedCharacter(_ text: String) -> Bool {
        let chars = text.filter { !$0.isWhitespace }
        guard chars.count >= 2, let first = chars.first else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func hasConsecutiveSingleLetters(_ text: String) -> Bool {
        var run = 0
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if token.count == 1, let c = token.first, c.isLetter {
                run += 1
                if run >= 2 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    private static func containsWideInterWordGap(_ text: String) -> Bool {
        // A non-space char, then 3+ spaces, then another non-space char.
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] != " " else { i += 1; continue }
            var j = i + 1
            while j < chars.count && chars[j] == " " { j += 1 }
            if j - (i + 1) >= 3 && j < chars.count { return true }
            i = j
        }
        return false
    }

    private static func hasLongCharRun(_ text: String) -> Bool {
        var last: Character?
        var run = 1
        for ch in text where !ch.isWhitespace {
            if ch == last {
                run += 1
                if run >= 5 { return true }
            } else {
                run = 1
                last = ch
            }
        }
        return false
    }
}
