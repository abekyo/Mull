import Foundation

// MARK: - Counts that agree with the thing they count
//
// mull carries no localisation catalogue (there is no .strings or .stringsdict in
// the project), so there is nothing for `String.localizedStringWithFormat` to look
// a plural rule up in, and interpolating `"\(n) blocks"` prints "1 blocks" one day
// in seven. Two English forms chosen here is the honest version of that. When a
// second UI language does arrive this becomes a catalogue lookup and every call
// site holds — which is the point of routing them all through one place.
//
// It is one place because it briefly was not: the rule was written twice, once as
// a free `pluralized` next to the week bars and once folded into Home's own
// "showing N of M" label, which is exactly how two screens end up disagreeing
// about how to say "1 project".

/// "1 block", "3 blocks". Pass `plural:` for anything English does not pluralise
/// by suffixing an s.
func pluralized(_ count: Int, _ singular: String, plural: String? = nil) -> String {
    "\(count) \(pluralNoun(count, singular, plural: plural))"
}

/// The noun alone, in the form that agrees with `count` — for the call sites that
/// need to place the number somewhere other than directly in front of it.
func pluralNoun(_ count: Int, _ singular: String, plural: String? = nil) -> String {
    count == 1 ? singular : plural ?? singular + "s"
}
