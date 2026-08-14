import Foundation

/// Decides *whether* and *when* the nightly consolidation runs — and nothing about
/// what it does.
///
/// Split out of MullEngine because scheduling is a wholly separate concern from the
/// LLM pipeline it triggers: this file is about clocks, cross-process locks and PID
/// liveness, and it is the part that has to be correct even when the pipeline is
/// disabled (the gates run every 10 minutes on every install, LLM or no LLM).
/// MullEngine owns the run itself and hands this object a `runHandler`; the two
/// touch each other only through that closure and the lock API below.
///
/// The gates are checked cheapest-first (a DB read, then a COUNT, then a PID probe)
/// because `shouldRun()` is called far more often than it returns true.
final class ConsolidationScheduler {

    private let database: DatabaseService

    // Configurable thresholds.
    //
    // Static, and not private, because this number is part of the reason a new
    // install shows nothing written for its first day — and until Home could quote
    // it, that wait had no explanation anywhere in the UI. A light user sitting
    // below the event gate saw an empty page indefinitely and no stated reason for
    // it. A gate the user can't see is indistinguishable from a broken feature.
    static let minEventsRequired: Int = 50

    /// How far back a run gathers. `MullEngine.phase2Gather` opens exactly this
    /// window, and the summary is stamped with the day containing its midpoint —
    /// which is what `summaryDate(forRunAt:)` below predicts, one gate earlier.
    static let gatherWindowHours: Int = 24

    /// The calendar day a run started at `now` will be ABOUT.
    ///
    /// Mirrors `GatheredData.summaryDate`, which derives the same day from the
    /// window it actually gathered. The scheduler has to know it before gathering
    /// anything, so the two derivations are pinned together by a test rather than
    /// by sharing a call — see `ConsolidationSchedulerTests`.
    static func summaryDate(forRunAt now: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.date(byAdding: .hour, value: -gatherWindowHours, to: now) ?? now
        let midpoint = start.addingTimeInterval(now.timeIntervalSince(start) / 2)
        return calendar.startOfDay(for: midpoint)
    }

    /// What asked. The two differ in one gate: a launch may fill in a day that is
    /// already over, and may not start on a day still in progress.
    enum Trigger {
        /// The daily timer, at the hour the user picked.
        case schedule
        /// mull starting up, looking for a day it was not running to write.
        case launch
    }

    /// Performs the actual consolidation when the gates open. Set by MullEngine;
    /// captured weakly there so the scheduler never keeps the engine alive.
    var runHandler: (() async throws -> DailySummary?)?

    /// Called when a scheduled mull completes. Set by AppState (forwarded through
    /// MullEngine, which keeps the historical call site).
    var onSummaryComplete: ((DailySummary) -> Void)?
    var onSummaryFailed: ((Error) -> Void)?

    init(database: DatabaseService) {
        self.database = database
    }

    // MARK: - 3-Gate Trigger System

    /// Check all three gates (cheapest first). Returns true only if all pass.
    ///
    /// The 10-minute scan throttle that used to sit between gate 1 and gate 2 is
    /// gone. It was written for a design that polled, and the only callers now are
    /// a once-a-day timer and a once-per-launch catch-up — two COUNT(*)s a day.
    /// Worse, it had teeth it should not have had: a launch at 22:59 consumed the
    /// slot, and the 23:00 timer one minute later was refused before it reached a
    /// gate that had anything to say. Concurrency is gate 3's job, and gate 3 does
    /// it atomically and across processes, which a timestamp in one process never
    /// could.
    func shouldRun(triggeredBy trigger: Trigger = .schedule, now: Date = Date()) -> Bool {
        // Gate 1: Day — has the day this run would cover already been written?
        guard passesTimeGate(trigger: trigger, now: now) else { return false }

        // Gate 2: Data — is there enough new data? (cost: 1 DB count query)
        guard passesDataGate(now: now) else { return false }

        // Gate 3: Lock — is another mull already running? (cost: 1 DB read + PID check)
        guard passesLockGate(now: now) else { return false }

        return true
    }

    /// Gate 1: the day this run would be about has no summary yet.
    ///
    /// **This used to be "at least 24 hours since the last run finished", and that
    /// could not work.** The only caller fires at a fixed time of day, so the
    /// interval at the next fire was always 24 hours *minus* however long the
    /// previous run took — 23:59:59 after a run that took a second, 23:58:53 after
    /// one that took 67. Every one of those is less than 24, so the day after any
    /// successful run was refused, and the day after that was allowed. The written
    /// record could only ever appear every other day, and did: on this machine it
    /// ran 08-09 and 08-11 and skipped 08-10, having taken 67.8s on the 9th.
    /// Nothing looked broken from outside, because a gate returning false is what a
    /// gate is for.
    ///
    /// Asking whether the day itself has been written says what was meant, and it
    /// says it in a form the clock cannot erode. It is also what makes a launch
    /// catch-up safe: `fetchSummary` is a day-range query, so a run for a day
    /// already covered is refused no matter what hour either one happened at.
    ///
    /// A launch may only fill a day that is over. Today's record is the scheduled
    /// run's to write at the hour the user chose, and a half-day summary generated
    /// because somebody opened the window at lunchtime would take that slot and
    /// keep it (`insertSummary` replaces by date).
    private func passesTimeGate(trigger: Trigger, now: Date) -> Bool {
        let day = Self.summaryDate(forRunAt: now)
        if trigger == .launch, day >= Calendar.current.startOfDay(for: now) { return false }
        return database.fetchSummary(for: day) == nil
    }

    /// Gate 2: At least `minEventsRequired` new recording events.
    private func passesDataGate(now: Date) -> Bool {
        let lock = database.fetchmullLock()
        let since = lock?.lastSummaryAt ?? Date.distantPast
        // COUNT(*) in SQL, not SELECT * decoded into memory. With the LLM off,
        // `lastSummaryAt` stays nil forever, so `since` is .distantPast — fetching
        // rows here meant loading the ENTIRE event table (textContent included)
        // every 10 minutes just to compare a number against a threshold.
        return database.countEvents(from: since, to: now) >= Self.minEventsRequired
    }

    /// Gate 3: No other mull process is running (PID check).
    private func passesLockGate(now: Date = Date()) -> Bool {
        guard let lock = database.fetchmullLock() else { return true }
        guard let holderPID = lock.holderPID else { return true }

        // Check if the PID is still alive
        let isAlive = kill(holderPID, 0) == 0
        if isAlive {
            // A live holder is only "stale" if it has held the lock implausibly
            // long (a consolidation never runs this long) — measured from when it
            // ACQUIRED the lock, not from the last successful summary. Without an
            // acquire time, assume it's genuinely running and don't reclaim.
            guard let acquired = lock.acquiredAt else { return false }
            let hoursHeld = now.timeIntervalSince(acquired) / 3600
            return hoursHeld > Self.maxLockHoldHours // reclaim only if absurdly long
        }
        return true // Process is dead — reclaim
    }

    /// A consolidation should finish in minutes; if a live holder has held the
    /// lock longer than this, treat it as crashed-but-PID-recycled and reclaim.
    private static let maxLockHoldHours: Double = 2.0

    // MARK: - Acquire / Release Lock

    /// Take the lock, or report that someone else holds it.
    ///
    /// This must be ONE transaction. The old version read the row, mutated it in
    /// Swift, then wrote it back in a separate transaction — and `passesLockGate()`
    /// read it in a third. MullMCP opens a second DatabaseService on the same file,
    /// so two processes could both see `holderPID == nil` and both start a
    /// consolidation. GRDB's `write` on a pool is an IMMEDIATE transaction, so
    /// deciding and claiming inside a single block is genuinely atomic across
    /// processes: the loser blocks until the winner has committed, then sees the PID.
    func acquireLock() -> Bool {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        do {
            return try database.dbPool.write { db -> Bool in
                // The lock is a singleton row seeded at migration time; recreate it
                // if it ever went missing so acquisition can't silently no-op.
                guard let lock = try mullLock.fetchOne(db) else {
                    try db.execute(sql: """
                        INSERT INTO mull_lock (holderPID, acquiredAt, sessionsSinceLast)
                        VALUES (?, ?, 0)
                    """, arguments: [pid, Date()])
                    return true
                }

                if let holder = lock.holderPID {
                    // Same reclaim rules as passesLockGate, but evaluated under the
                    // write lock so the decision can't be raced.
                    if kill(holder, 0) == 0 {
                        guard let acquired = lock.acquiredAt,
                              Date().timeIntervalSince(acquired) / 3600 > Self.maxLockHoldHours
                        else { return false }  // genuinely running — back off
                    }
                    // dead PID, or held absurdly long → reclaim
                }

                try db.execute(sql: "UPDATE mull_lock SET holderPID = ?, acquiredAt = ? WHERE id = ?",
                               arguments: [pid, Date(), lock.id])
                return true
            }
        } catch {
            print("[mull] lock acquire failed: \(error.localizedDescription)")
            return false
        }
    }

    func releaseLock(success: Bool) {
        var lock = database.fetchmullLock() ?? mullLock(sessionsSinceLast: 0)
        lock.holderPID = nil
        lock.acquiredAt = nil
        if success {
            lock.lastSummaryAt = Date()
            lock.sessionsSinceLast = 0
        }
        database.updatemullLock(lock)
    }

    // MARK: - Scheduling

    /// Run the consolidation if every gate opens, and report either way. The one
    /// place the handler is called from, so the timer and the launch catch-up
    /// cannot drift apart in how they treat a failure.
    private func runIfDue(_ trigger: Trigger) async {
        guard shouldRun(triggeredBy: trigger) else { return }
        do {
            if let summary = try await runHandler?() {
                onSummaryComplete?(summary)
            }
        } catch {
            onSummaryFailed?(error)
        }
    }

    /// Look for a finished day nobody wrote, and write it.
    ///
    /// The timer is a one-shot at an hour of the day: miss the moment — the Mac
    /// asleep, mull quit, a reboot at the wrong end of the evening — and that day
    /// has no second chance, because the next fire is 24 hours later and covers a
    /// different 24 hours. That is how 2026-08-12 was lost on this machine: the
    /// last thing written that day was 13:43, so nothing was running at 23:00 and
    /// the day is simply not in the record.
    ///
    /// Gate 1 refuses to touch a day already written or a day still in progress,
    /// so this is safe to call on every launch, including several launches an hour.
    func catchUpOnLaunch() {
        Task { await runIfDue(.launch) }
    }

    /// Only ever touched on the main thread — see scheduleSummary.
    @MainActor private var mullTimer: Timer?

    /// Schedule the nightly consolidation using a proper macOS Timer.
    /// Survives app sleep/wake. Reschedules automatically.
    ///
    /// Main-actor isolated on purpose: `Timer.invalidate()` must run on the thread
    /// that installed the timer, and `RunLoop` is not safe to mutate from another
    /// thread. The reschedule at the end of a run happens inside a `Task`, which is
    /// NOT the main thread — doing the invalidate/add there left the nightly timer
    /// either duplicated or silently dead. (AppState.scheduleEveningDraft already
    /// hops back to the main actor for exactly this reason.)
    @MainActor
    func scheduleSummary(at hour: Int, minute: Int = 0) {
        mullTimer?.invalidate()

        let calendar = Calendar.current
        // nextDate handles DST-nonexistent times (e.g. 02:30 on a spring-forward
        // day) by rolling to the next valid time, and always returns a real future
        // date — so scheduling can't silently stop the way `date(from:)` → nil did.
        var match = DateComponents()
        match.hour = hour
        match.minute = minute
        guard let fireDate = calendar.nextDate(after: Date(), matching: match,
                                               matchingPolicy: .nextTime) else { return }

        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.runIfDue(.schedule)
                await MainActor.run { self.scheduleSummary(at: hour, minute: minute) }
            }
        }
        mullTimer = timer
        // Add to common run loop so it fires even during UI tracking
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Callable from anywhere (AppState's `deinit` is nonisolated), but the actual
    /// invalidate always happens on the main thread — the same thread that installed
    /// the timer on the main run loop.
    nonisolated func cancelSchedule() {
        Task { @MainActor in
            self.mullTimer?.invalidate()
            self.mullTimer = nil
        }
    }
}
