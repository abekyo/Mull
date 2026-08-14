import Foundation

/// What the calendar mirror has actually been doing.
///
/// The mirror was built to be quiet and became silent, which are not the same thing.
/// Every write went through `try?` and every failure through `catch { continue }`, on
/// the sound reasoning that one bad event is no reason to abandon the rest — but
/// nothing above that loop ever learned a run had happened, let alone that one had
/// failed. On 2026-08-14 the ledger held 37 keys and neither preference the timer
/// needs had ever been written, and there was no way to tell from inside the product
/// whether that meant "it ran and stopped", "it never ran", or "it runs every hour and
/// throws everything away". Reading `defaults` was the only way to find out.
///
/// So the run reports. Not to a log file nobody opens: to a line in Settings and a pill
/// in the calendar's toolbar, which is where somebody is standing when the question
/// occurs to them.
struct CalendarMirrorStatus: Codable, Equatable {

    /// When a run last finished, whether or not it changed anything. This is the field
    /// that separates "nothing to write" from "not running".
    var lastRun: Date?
    /// When a run last actually wrote to the calendar.
    var lastChange: Date?

    var created = 0
    var updated = 0
    var deleted = 0
    /// Events the user removed and mull agreed never to write again.
    var tombstoned = 0

    /// Writes EventKit refused. Cumulative, because one failure is noise and forty is
    /// a broken calendar account.
    var failures = 0
    var lastError: String?
    var lastErrorAt: Date?

    /// The most recent reading, not a running total: it describes the range the mirror
    /// covers right now, and a fraction averaged over three weeks of history would
    /// answer a question nobody asked.
    var quality = CalendarMirror.Quality()

    var hasRun: Bool { lastRun != nil }

    /// Fold one run's outcome in.
    mutating func record(_ plan: CalendarMirror.Plan,
                         created: Int, updated: Int, deleted: Int,
                         failures: Int, lastError: String?,
                         now: Date) {
        lastRun = now
        quality = plan.quality
        self.created += created
        self.updated += updated
        self.deleted += deleted
        tombstoned += plan.tombstone.count
        if created + updated + deleted > 0 { lastChange = now }
        if failures > 0 {
            self.failures += failures
            self.lastError = lastError
            lastErrorAt = now
        }
    }

    // MARK: - Persistence

    static let storageKey = "calendarMirrorStatus"

    static func load(from store: UserDefaults = Preferences.store) -> CalendarMirrorStatus {
        guard let data = store.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(CalendarMirrorStatus.self, from: data)
        else { return CalendarMirrorStatus() }
        return decoded
    }

    func save(to store: UserDefaults = Preferences.store) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        store.set(data, forKey: Self.storageKey)
    }

    static func clear(from store: UserDefaults = Preferences.store) {
        store.removeObject(forKey: storageKey)
    }
}

/// The one question the UI asks about the mirror, with every answer that is not
/// "working" separated from every other one.
///
/// A single "on/off" was what made this invisible. Off, on-but-pointed-nowhere, on-but-
/// never-run and on-but-failing all showed the same empty calendar, and only the last
/// two are anything to act on.
enum CalendarMirrorState: Equatable {
    /// Never turned on. The state the author's own Mac was in for the whole of the
    /// mirror's life, without any screen ever saying so.
    case off
    /// On, but no calendar chosen — so `run()` returns immediately, every hour, forever.
    case noCalendar
    /// On and pointed somewhere, and no run has finished yet.
    case waiting
    case working(CalendarMirrorStatus)
    case failing(CalendarMirrorStatus)

    static func current(status: CalendarMirrorStatus = .load(),
                        enabled: Bool = Preferences.mirrorEnabled,
                        calendarID: String? = Preferences.mirrorCalendarID) -> CalendarMirrorState {
        guard enabled else { return .off }
        guard calendarID != nil else { return .noCalendar }
        guard status.hasRun else { return .waiting }
        // A failure only counts while it is the last thing that happened. A write that
        // failed on Tuesday and has landed every hour since is history, not a fault,
        // and a pill that stays red forever is a pill people stop reading.
        guard let failed = status.lastErrorAt else { return .working(status) }
        if let wrote = status.lastChange, wrote >= failed { return .working(status) }
        return .failing(status)
    }

    var isFaulty: Bool {
        switch self {
        case .noCalendar, .failing: return true
        case .off, .waiting, .working: return false
        }
    }
}
