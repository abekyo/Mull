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

    /// When a pass last looked further back than the usual two days. The window in
    /// which mull can notice a deletion is the window it reconciles, and deletions
    /// happen days after the write — see `CalendarMirrorRunner.sweepDays`.
    var lastSweep: Date?

    var created = 0
    var updated = 0
    var deleted = 0
    /// Events the user removed and mull agreed never to write again.
    var tombstoned = 0
    /// Events mull wrote and the user removed, however the run treated it.
    ///
    /// Not the same as `tombstoned`, and the gap between them is the point: a press
    /// writes the event again rather than agreeing to stay silent, so it records a
    /// removal without recording a tombstone. This is the number the retraction
    /// criterion in CLAUDE.md §0 wants — how often what mull wrote was not wanted —
    /// and reading `tombstoned` for it would have answered zero forever on a Mac where
    /// only the button is ever used.
    var removedByUser = 0

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
        removedByUser += plan.rejected.count
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

/// Decoded field by field, and in an extension so the memberwise initialiser survives.
///
/// A status written before `removedByUser` and `lastSweep` existed has neither key, and
/// the synthesised initialiser would throw on the first of them — which does not read
/// as an error anywhere, because `load()` catches it and hands back a fresh zero. Every
/// count since the mirror was first used would disappear at the moment of an upgrade,
/// silently, which is the exact failure this type was added to end.
extension CalendarMirrorStatus {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lastRun: try c.decodeIfPresent(Date.self, forKey: .lastRun),
            lastChange: try c.decodeIfPresent(Date.self, forKey: .lastChange),
            lastSweep: try c.decodeIfPresent(Date.self, forKey: .lastSweep),
            created: try c.decodeIfPresent(Int.self, forKey: .created) ?? 0,
            updated: try c.decodeIfPresent(Int.self, forKey: .updated) ?? 0,
            deleted: try c.decodeIfPresent(Int.self, forKey: .deleted) ?? 0,
            tombstoned: try c.decodeIfPresent(Int.self, forKey: .tombstoned) ?? 0,
            removedByUser: try c.decodeIfPresent(Int.self, forKey: .removedByUser) ?? 0,
            failures: try c.decodeIfPresent(Int.self, forKey: .failures) ?? 0,
            lastError: try c.decodeIfPresent(String.self, forKey: .lastError),
            lastErrorAt: try c.decodeIfPresent(Date.self, forKey: .lastErrorAt),
            quality: try c.decodeIfPresent(CalendarMirror.Quality.self, forKey: .quality)
                ?? CalendarMirror.Quality())
    }
}

/// The one question the UI asks about the mirror, with every answer that is not
/// "working" separated from every other one.
///
/// A single "on/off" was what made this invisible. Off, on-but-pointed-nowhere, on-but-
/// never-run and on-but-failing all showed the same empty calendar, and only the last
/// two are anything to act on.
enum CalendarMirrorState: Equatable {
    /// Never turned on, and nothing ever written by hand either. The only state with
    /// nothing to say.
    case off
    /// Off, but the button has been used. The state the author's own Mac has been in
    /// since 2026-08-09: 56 events written by hand, `calendarMirrorEnabled` never once
    /// written, and a status object holding counts that no screen would show, because
    /// every screen asked whether the *timer* was on.
    ///
    /// It is not a fault — writing by hand is a legitimate way to use this — but it is
    /// the one state where mull knows something the reader would want to be asked
    /// about, and it was the state being rendered as blank.
    case manualOnly(CalendarMirrorStatus)
    /// On, but no calendar chosen — so `run()` returns immediately, every hour, forever.
    case noCalendar
    /// On and pointed somewhere, and no run has finished yet.
    case waiting
    case working(CalendarMirrorStatus)
    case failing(CalendarMirrorStatus)

    static func current(status: CalendarMirrorStatus = .load(),
                        enabled: Bool = Preferences.mirrorEnabled,
                        calendarID: String? = Preferences.mirrorCalendarID) -> CalendarMirrorState {
        guard enabled else { return status.hasRun ? .manualOnly(status) : .off }
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
        case .off, .manualOnly, .waiting, .working: return false
        }
    }
}
