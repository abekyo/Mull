import Foundation

// MARK: - Counts that agree with the thing they count
//
// This used to build the phrase out of parts: `pluralized(3, "block")` returned
// "\(count) \(noun)", with the noun pluralised by suffixing an s. That was written
// when "mull carries no localisation catalogue" was true of the project. It has not
// been true since `Localizable.xcstrings` arrived, and the seam it left is the one
// WRITING.md §5.3 names: a translated sentence with an English fragment glued into
// it. In a Japanese window "3 events brought up to date" came out as
// "3 events を最新に更新" — half of it looked up, half of it hard-coded English, and
// nothing in the type system or the catalog to say so.
//
// So the unit of translation is the whole sentence, and the plural is chosen by
// picking between two whole sentences. English needs both; Japanese does not
// inflect for number, so both keys usually carry the same wording with the number
// substituted. That is a translation deciding how it reads, which is the point.

/// One sentence in the form that agrees with `count`.
///
/// Both arguments are literals at the call site, so both become keys in the string
/// catalog and both can be translated. Put the number in with interpolation — the
/// key becomes `%lld …`, and the translation places it wherever that language puts
/// it, which is not always the front.
///
///     counted(n, one: "1 new event", other: "\(n) new events")
func counted(_ count: Int, one: String.LocalizationValue,
             other: String.LocalizationValue) -> String {
    String(localized: count == 1 ? one : other)
}
