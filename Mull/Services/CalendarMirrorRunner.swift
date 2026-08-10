import Foundation

/// Runs the calendar mirror on a timer and applies what `CalendarMirror` decides.
///
/// Everything that could be wrong about *what* to write is in `CalendarMirror`, where
/// a test can reach it. What is left here is the parts that need a clock, a database
/// and EventKit: when to run, what the day's blocks are, and the small persistent
/// memory of which events mull created and which of those the user has since removed.
@MainActor
final class CalendarMirrorRunner {

    private let database: EventReading
    private let calendar: CalendarService
    private var timer: Timer?

    /// Keys mull has created. Without this a missing event is ambiguous — never
    /// written, or written and deleted — and the mirror would resurrect deletions.
    private var written: Set<String> {
        get { Set(Preferences.store.stringArray(forKey: Self.writtenKey) ?? []) }
        set { Preferences.store.set(Array(newValue).sorted(), forKey: Self.writtenKey) }
    }

    /// Keys the user deleted. Permanent within the retention horizon: mull wrote it
    /// once, the user said no, and asking again every hour is not a design.
    private var tombstoned: Set<String> {
        get { Set(Preferences.store.stringArray(forKey: Self.tombstoneKey) ?? []) }
        set { Preferences.store.set(Array(newValue).sorted(), forKey: Self.tombstoneKey) }
    }

    private static let writtenKey = "calendarMirrorWritten"
    private static let tombstoneKey = "calendarMirrorTombstoned"

    /// Both ledgers are keyed on a block's start instant, so they prune by arithmetic
    /// rather than by remembering when each entry was added. Kept a little longer than
    /// the covered range so a run that is late by a day still recognises its own work.
    private static let ledgerHorizon: TimeInterval = 30 * 86_400

    init(database: EventReading, calendar: CalendarService) {
        self.database = database
        self.calendar = calendar
    }

    deinit { timer?.invalidate() }

    // MARK: - Scheduling

    /// Start, restart or stop the timer to match the current settings. Safe to call
    /// whenever a setting changes; it never leaves two timers running.
    func reschedule() {
        timer?.invalidate()
        timer = nil
        guard Preferences.mirrorEnabled, Preferences.mirrorCalendarID != nil else { return }

        let interval = Preferences.mirrorInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.run() }
        }
        // The mirror is bookkeeping, not an alarm: letting it slide rather than waking
        // the machine for it is the polite form, and a block that settled ten minutes
        // ago is no less settled an hour later.
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - One pass

    /// Reconcile the covered range. Returns what it did, for the tests and the log.
    @discardableResult
    func run(now: Date = Date()) -> CalendarMirror.Plan {
        guard Preferences.mirrorEnabled, let calendarID = Preferences.mirrorCalendarID else {
            return CalendarMirror.Plan()
        }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let from = cal.date(byAdding: .day, value: -(CalendarMirror.daysCovered - 1), to: today),
              let to = cal.date(byAdding: .day, value: 1, to: today) else { return CalendarMirror.Plan() }

        let engine = TimeBlockEngine(database: database)
        let plan = CalendarMirror.plan(
            blocks: blocks(from: from, to: to, engine: engine),
            existing: calendar.mirroredEvents(in: calendarID, from: from, to: to),
            written: written,
            tombstoned: tombstoned,
            now: now,
            resumeGap: engine.resumeGap)

        apply(plan, calendarID: calendarID, now: now)
        return plan
    }

    /// Every block whose day falls in the range. Derived per day because that is the
    /// unit `generateBlocks` segments in — asking it for a span would let a block
    /// straddle midnight and be counted twice.
    private nonisolated func blocks(from: Date, to: Date, engine: TimeBlockEngine) -> [TimeBlock] {
        let cal = Calendar.current
        var day = cal.startOfDay(for: from)
        var out: [TimeBlock] = []
        while day < to {
            out.append(contentsOf: engine.generateBlocks(for: day))
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    // MARK: - Written by hand

    /// What the toolbar's write button would do to `calendarID` for a range the user
    /// picked out on screen.
    ///
    /// Both ledgers are passed empty, and that is the whole difference from a timed
    /// run. A press is a stronger signal than the silence the timer reads: it writes
    /// a block the user once deleted rather than honouring the tombstone, which is
    /// also the only way back for somebody who cleared a day and then wanted it.
    /// Nothing is tombstoned by this path either — a missing event is a thing to
    /// write, not a decision to record.
    ///
    /// `nonisolated` because it touches neither ledger and no other mutable state, and
    /// a month on screen means re-deriving six weeks of blocks — which is not work to
    /// do on the main thread while somebody waits for a sheet to open.
    nonisolated func manualPlan(in calendarID: String, from: Date, to: Date,
                                now: Date = Date()) -> CalendarMirror.Plan {
        let engine = TimeBlockEngine(database: database)
        return CalendarMirror.plan(
            blocks: blocks(from: from, to: to, engine: engine),
            existing: calendar.mirroredEvents(in: calendarID, from: from, to: to),
            written: [],
            tombstoned: [],
            now: now,
            resumeGap: engine.resumeGap)
    }

    /// Fold a hand-written result into the ledger, so the timer afterwards agrees with
    /// what the press did — including forgetting tombstones the press overrode.
    func recordManualResult(created: [String], deleted: [String], now: Date = Date()) {
        var written = self.written
        written.formUnion(created)
        written.subtract(deleted)
        self.written = prune(written, before: now)

        var tombstoned = self.tombstoned
        tombstoned.subtract(created)
        self.tombstoned = prune(tombstoned, before: now)
    }

    private func apply(_ plan: CalendarMirror.Plan, calendarID: String, now: Date) {
        guard !plan.isEmpty else { return }
        var written = self.written
        var tombstoned = self.tombstoned

        for entry in plan.create {
            let fields = CalendarService.EventFields(title: entry.title, start: entry.start,
                                                     end: entry.end, calendarID: calendarID)
            do {
                _ = try calendar.createEvent(fields,
                                             extras: CalendarService.EventExtras(url: CalendarMirror.marker(entry.key)))
                written.insert(entry.key)
            } catch {
                // One event failing is not a reason to abandon the rest: the next run
                // will try again, and the ledger has not recorded a write that did not
                // happen.
                continue
            }
        }

        for change in plan.update {
            let fields = CalendarService.EventFields(title: change.entry.title, start: change.entry.start,
                                                     end: change.entry.end, calendarID: calendarID)
            try? calendar.updateEvent(change.handle, to: fields)
        }

        for removal in plan.delete {
            try? calendar.deleteEvent(removal.handle)
            written.remove(removal.key)
        }

        // A key mull will never write again does not need to be remembered as written.
        tombstoned.formUnion(plan.tombstone)
        written.subtract(plan.tombstone)

        self.written = prune(written, before: now)
        self.tombstoned = prune(tombstoned, before: now)
    }

    /// Both ledgers are sets of block-start epochs, so old entries fall out by age.
    private func prune(_ keys: Set<String>, before now: Date) -> Set<String> {
        let cutoff = now.addingTimeInterval(-Self.ledgerHorizon).timeIntervalSince1970
        return keys.filter { key in
            guard let seconds = Double(key) else { return false }
            return seconds >= cutoff
        }
    }

    /// Forget everything the mirror has written, without touching the calendar.
    /// Used when the target calendar changes: keys written into the old one say
    /// nothing about the new one, and carrying them over would read every absent
    /// event there as a user deletion and tombstone the whole day.
    func forgetLedger() {
        Preferences.store.removeObject(forKey: Self.writtenKey)
        Preferences.store.removeObject(forKey: Self.tombstoneKey)
    }
}
