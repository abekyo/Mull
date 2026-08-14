import Foundation

/// Clock times, spelled two different ways on purpose.
///
/// `DateFormatter(dateFormat: "HH:mm")` is a *fixed* 24-hour pattern. On a Mac set
/// to 12-hour time it printed "14:00" in the calendar grid while every other app on
/// the screen said "2 PM" — and on a Japanese machine it printed "14:00" where the
/// system spells the hour "14時". A fixed pattern is right for text a machine reads
/// back and wrong for text a person reads.
///
/// So: `person(...)` follows the reader's locale and their 12/24-hour setting;
/// `machine(...)` stays 24-hour for me.md, now.md and the MCP tools, where a stable
/// unambiguous form matters more than local habit.
///
/// The formatters are built per call rather than cached. `DateFormatter` is a
/// reference type with mutable state, and these are read from a detached load task
/// as well as the main actor; a shared instance would be the kind of shared mutable
/// state that only misbehaves under load.
enum TimeFormat {

    /// A time of day as the reader's Mac would write it: "2:30 PM", "14:30", "14:30".
    static func person(_ date: Date) -> String {
        template("jmm").string(from: date)
    }

    /// The hour alone, for a grid gutter: "2 PM", "14", "14時".
    static func hour(_ date: Date) -> String {
        template("j").string(from: date)
    }

    /// Day and time together, for lines in a multi-day log where "14:30" alone
    /// would not say *which* day: "8月7日 15:02", "8/7, 3:02 PM".
    static func personDay(_ date: Date) -> String {
        template("Mdjmm").string(from: date)
    }

    /// The 24 hour labels of a day, in order, built from one formatter.
    ///
    /// The gutter asks for all of them on every layout pass, and a formatter each is
    /// 24 allocations per pass — this is the same answer for one.
    static func hourLabels(startingFrom reference: Date = Date()) -> [String] {
        let formatter = template("j")
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: reference)
        return (0..<24).map { hour in
            guard let date = calendar.date(byAdding: .hour, value: hour, to: midnight) else { return "" }
            return formatter.string(from: date)
        }
    }

    /// Fixed 24-hour. For context files and MCP output — read by an AI, not a person.
    ///
    /// The locale is not decoration. A `DateFormatter` left on the user's locale
    /// *rewrites* `HH:mm` to that locale's clock, so on a Mac set to 12-hour time
    /// this pattern quietly produced "2:05 PM" — which is what every `HH:mm`
    /// formatter in mull was doing, in me.md, now.md and the MCP tools, while
    /// reading like a guarantee of 24-hour output. `en_US_POSIX` is the one locale
    /// that always takes a fixed pattern literally.
    static func machine(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// `2026-08-15`. The same reasoning as `machine` above, and the same locale: a
    /// front-matter key is read by whatever opens the file next, not by a person
    /// deciding whether the month comes first.
    static func machineDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// A formatter carrying the *fields* wanted, leaving their order, separators and
    /// spelling to the reader's locale.
    private static func template(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(pattern)
        return f
    }
}
