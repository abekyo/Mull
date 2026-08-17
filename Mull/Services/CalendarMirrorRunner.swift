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

    /// The keys mull has written, for the write sheet.
    ///
    /// A press used to be planned against an empty ledger, which made it structurally
    /// incapable of noticing a deletion: `CalendarMirror.plan` reads "written before,
    /// absent now" as the user having removed it, and with nothing written before,
    /// that branch could not be reached. The press still overrides deletions — that is
    /// `Trigger.press` — but it can only override something it can see.
    var writtenKeys: Set<String> { written }

    /// How far back a once-a-day pass reconciles.
    ///
    /// The hourly pass covers two days, and that is right for the work it does: almost
    /// everything it writes settled in the last few hours, and re-deriving a fortnight
    /// every hour would cost far more than it could correct. But the two-day window is
    /// also the only window in which mull can *notice a deletion*, and deletions do not
    /// happen on the day. Somebody tidying last week's calendar on a Sunday was
    /// invisible: no tombstone, no correction card, and the ledger holding the key for
    /// another twenty-three days without ever looking at it again.
    ///
    /// Kept under `ledgerHorizon`, or a sweep would find keys already pruned out of
    /// `written` and read its own past work as somebody else's events.
    static let sweepDays = 14

    /// What the mirror has been doing, for the screens that report it.
    ///
    /// Held in memory rather than decoded on demand, unlike the two ledgers above. The
    /// toolbar pill reads this from `body`, which re-runs on every hover and every
    /// frame of a drag — a `UserDefaults` read and a `JSONDecoder` pass per frame to
    /// re-learn a number that changes once an hour. Loaded once and written through.
    private(set) lazy var status: CalendarMirrorStatus = .load()

    private func update(_ change: (inout CalendarMirrorStatus) -> Void) {
        var next = status
        change(&next)
        status = next
        next.save()
    }

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

    /// Reconcile the covered range: today and yesterday, or the last fortnight on the
    /// first pass of a day.
    ///
    /// The deriving half runs off the main thread and the writing half comes back to
    /// it. Two days of blocks was already a database read on the main thread every
    /// hour; a fortnight of them once a day would be a visible stall, and fixing the
    /// window without moving the work would have traded one defect for another.
    func run(now: Date = Date()) {
        guard Preferences.mirrorEnabled, let calendarID = Preferences.mirrorCalendarID else { return }

        let sweeping = shouldSweep(now: now)
        guard let (from, to) = Self.range(endingAt: now,
                                          days: sweeping ? Self.sweepDays : CalendarMirror.daysCovered)
        else { return }

        let written = self.written
        let tombstoned = self.tombstoned

        Task.detached(priority: .utility) { [weak self] in
            guard let plan = self?.plan(in: calendarID, from: from, to: to,
                                        written: written, tombstoned: tombstoned,
                                        trigger: .reconcile, now: now) else { return }
            await MainActor.run {
                self?.apply(plan, calendarID: calendarID, now: now, swept: sweeping)
            }
        }
    }

    /// Whether this pass is the first of a calendar day, and so the one that looks
    /// further back. Anchored on the last sweep rather than on a counter, so a Mac
    /// asleep for three days sweeps once when it wakes rather than not at all.
    private func shouldSweep(now: Date) -> Bool {
        guard let last = status.lastSweep else { return true }
        return !Calendar.current.isDate(last, inSameDayAs: now)
    }

    /// Whole days back from the day `now` falls in, through to tomorrow's midnight.
    private static func range(endingAt now: Date, days: Int) -> (from: Date, to: Date)? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let from = cal.date(byAdding: .day, value: -(max(days, 1) - 1), to: today),
              let to = cal.date(byAdding: .day, value: 1, to: today) else { return nil }
        return (from, to)
    }

    /// What a run of either kind would do. Reads the database and EventKit and touches
    /// no mutable state of its own, so it is safe to call off the main thread — which
    /// both callers do, because a month on screen and a fortnight on a timer are the
    /// same amount of re-derivation and neither should stop the window.
    nonisolated func plan(in calendarID: String, from: Date, to: Date,
                          written: Set<String>, tombstoned: Set<String>,
                          trigger: CalendarMirror.Trigger, now: Date) -> CalendarMirror.Plan {
        let engine = TimeBlockEngine(database: database)
        return CalendarMirror.plan(
            blocks: blocks(from: from, to: to, engine: engine),
            existing: calendar.mirroredEvents(in: calendarID, from: from, to: to),
            written: written,
            tombstoned: tombstoned,
            now: now,
            resumeGap: engine.resumeGap,
            trigger: trigger)
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
    /// `tombstoned` is passed empty and `written` is not, and the difference is the
    /// whole point. The press must be able to *see* what mull wrote, or it cannot tell
    /// a row the user deleted from one that was never written, and the correction is
    /// lost exactly where it is most reliable. What it does with that knowledge is
    /// `Trigger.press`: write anyway, and file the card.
    ///
    /// `nonisolated` because it touches no mutable state of its own, and a month on
    /// screen means re-deriving six weeks of blocks — which is not work to do on the
    /// main thread while somebody waits for a sheet to open.
    nonisolated func manualPlan(in calendarID: String, from: Date, to: Date,
                                written: Set<String>, now: Date = Date()) -> CalendarMirror.Plan {
        plan(in: calendarID, from: from, to: to,
             written: written, tombstoned: [], trigger: .press, now: now)
    }

    /// Fold a hand-written result into the ledger, so the timer afterwards agrees with
    /// what the press did — including forgetting tombstones the press overrode.
    ///
    /// The status is recorded here too, and it has to be: on 2026-08-14 every one of
    /// the 37 keys in the ledger had come through this path rather than the timer, and
    /// nothing distinguished them. A press and a tick write the same events; only the
    /// status says which of them has ever happened.
    func recordManualResult(_ plan: CalendarMirror.Plan,
                            created: [String], updated: Int, deleted: [String],
                            now: Date = Date()) {
        var written = self.written
        written.formUnion(created)
        written.subtract(deleted)
        self.written = prune(written, before: now)

        var tombstoned = self.tombstoned
        tombstoned.subtract(created)
        self.tombstoned = prune(tombstoned, before: now)

        // The same wire the timer has. It ran from `apply` alone, and `apply` runs from
        // a timer that had never started, so no calendar correction had ever reached
        // `CorrectionIndex` — while this path wrote 56 events.
        recordRejections(plan, now: now)

        update { $0.record(plan, created: created.count, updated: updated,
                           deleted: deleted.count, failures: 0, lastError: nil, now: now) }
    }

    private func apply(_ plan: CalendarMirror.Plan, calendarID: String, now: Date, swept: Bool) {
        // Recorded even when there is nothing to do. "Ran and found nothing" and "did
        // not run" produce the same empty calendar and are the opposite problem, and
        // until this line there was no way to tell them apart from inside mull.
        guard !plan.isEmpty else {
            update {
                $0.record(plan, created: 0, updated: 0, deleted: 0,
                          failures: 0, lastError: nil, now: now)
                if swept { $0.lastSweep = now }
            }
            return
        }

        var written = self.written
        var tombstoned = self.tombstoned
        var created = 0, updated = 0, deleted = 0, failures = 0
        var lastError: String?

        // One failure is not a reason to abandon the rest — the next run tries again,
        // and the ledger has not recorded a write that did not happen. It is a reason
        // to say so afterwards, which is the half that was missing.
        func attempt(_ work: () throws -> Void) -> Bool {
            do { try work(); return true } catch {
                failures += 1
                lastError = (error as? CalendarService.WriteError)?.errorDescription
                    ?? error.localizedDescription
                return false
            }
        }

        for entry in plan.create {
            // The plan was derived off the main thread against a snapshot of the ledger,
            // and a press can land in that window. A key that has become `written` since
            // then is an event that now exists, and creating it again would put two
            // identical rows in somebody's day with only one of them in the ledger.
            guard !written.contains(entry.key) else { continue }
            let fields = CalendarService.EventFields(title: entry.title, start: entry.start,
                                                     end: entry.end, calendarID: calendarID)
            let extras = CalendarService.EventExtras(url: CalendarMirror.marker(entry.key))
            if attempt({ _ = try calendar.createEvent(fields, extras: extras) }) {
                written.insert(entry.key)
                created += 1
            }
        }

        for change in plan.update {
            let fields = CalendarService.EventFields(title: change.entry.title, start: change.entry.start,
                                                     end: change.entry.end, calendarID: calendarID)
            if attempt({ try calendar.updateEvent(change.handle, to: fields) }) { updated += 1 }
        }

        for removal in plan.delete {
            if attempt({ try calendar.deleteEvent(removal.handle) }) {
                written.remove(removal.key)
                deleted += 1
            }
        }

        // A key mull will never write again does not need to be remembered as written.
        tombstoned.formUnion(plan.tombstone)
        written.subtract(plan.tombstone)

        self.written = prune(written, before: now)
        self.tombstoned = prune(tombstoned, before: now)

        recordRejections(plan, now: now)

        update {
            $0.record(plan, created: created, updated: updated, deleted: deleted,
                      failures: failures, lastError: lastError, now: now)
            if swept { $0.lastSweep = now }
        }
    }

    /// Turn the blocks the user deleted into correction cards.
    ///
    /// This is the wire that was missing. `tombstone` already carried the strongest
    /// signal mull can get — it proposed a thing and a human removed it — and spent it
    /// entirely on not repeating itself. The cards go where `Curator`'s go, so
    /// `get_corrections` hands them to an agent and the verdict lands in the same
    /// ledger `Selection` already reads (§7.3 ①と②, both of them).
    ///
    /// Additive, like `Curator.recordCorrections`: a ledger the user has hand-edited is
    /// parsed and merged, never replaced.
    private func recordRejections(_ plan: CalendarMirror.Plan, now: Date) {
        let cards = CalendarMirror.correctionCards(for: plan, now: now,
                                                   context: Curator.contextSnapshotProvider?())
        guard !cards.isEmpty else { return }
        for card in cards {
            _ = MullDirectory.write(card.render(), to: "\(CorrectionIndex.directory)/\(card.id).md")
        }
        let onDisk = CorrectionIndex.parseLedger(MullDirectory.read(CorrectionIndex.ledgerPath) ?? "")
        let merged = CorrectionIndex.merge(onDisk, CorrectionIndex.fold(cards))
        _ = MullDirectory.write(merged.renderLedger(), to: CorrectionIndex.ledgerPath)
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
        // The counts described work in the calendar being left behind. Carrying them
        // over would report a mirror as healthy on the strength of writes it made
        // somewhere else — which is the same class of lie as the ledger itself.
        CalendarMirrorStatus.clear()
        status = CalendarMirrorStatus()
    }
}
