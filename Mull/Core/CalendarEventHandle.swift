import Foundation

/// Which calendar event a write means.
///
/// EventKit gives every occurrence of a repeating event the same `eventIdentifier`,
/// and `event(withIdentifier:)` answers with the *first* one. Naming an event by that
/// string alone meant every edit, drag and delete aimed at Friday's stand-up landed on
/// Monday's instead — silently, and on somebody's real calendar. The occurrence date is
/// what separates this Friday from the rest of the series.
///
/// It lives in a file of its own, away from `CalendarService`, because it is a name
/// rather than a capability: `CalendarMirror` decides what to write in terms of these
/// and never touches EventKit, and `eval/calendar/run.sh` compiles that decision on its
/// own to score it. With this nested inside `CalendarService`, reaching the mirror's
/// planning meant importing EventKit, which meant the planning could not be scored
/// outside the app. `CalendarService.EventHandle` still names it — see the typealias
/// there — so every call site reads exactly as it did.
struct CalendarEventHandle: Equatable, Hashable {
    let identifier: String
    /// `EKEvent.occurrenceDate` for a repeating event; `nil` for one that occurs once,
    /// where the identifier already means exactly one row.
    let occurrenceDate: Date?
}
