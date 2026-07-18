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

    // Configurable thresholds
    private let minHoursSinceLast: Double = 24
    private let minEventsRequired: Int = 50

    // Scan throttle — minimum 10 minutes between data scans
    private var lastDataScanAt: Date = .distantPast
    private let dataScanInterval: TimeInterval = 10 * 60 // 10 minutes

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
    func shouldRun() -> Bool {
        // Gate 1: Time — has enough time passed? (cost: 1 DB read)
        guard passesTimeGate() else { return false }

        // Scan throttle: don't check data gate more than every 10 minutes
        // Throttle: skip if scanned within the interval above
        let sinceScan = Date().timeIntervalSince(lastDataScanAt)
        guard sinceScan >= dataScanInterval else { return false }
        lastDataScanAt = Date()

        // Gate 2: Data — is there enough new data? (cost: 1 DB count query)
        guard passesDataGate() else { return false }

        // Gate 3: Lock — is another mull already running? (cost: 1 DB read + PID check)
        guard passesLockGate() else { return false }

        return true
    }

    /// Gate 1: At least `minHoursSinceLast` hours since last mull.
    private func passesTimeGate() -> Bool {
        guard let lock = database.fetchmullLock() else { return true }
        guard let lastMull = lock.lastSummaryAt else { return true } // Never consolidated

        let hoursSince = Date().timeIntervalSince(lastMull) / 3600
        return hoursSince >= minHoursSinceLast
    }

    /// Gate 2: At least `minEventsRequired` new recording events.
    private func passesDataGate() -> Bool {
        let lock = database.fetchmullLock()
        let since = lock?.lastSummaryAt ?? Date.distantPast
        // COUNT(*) in SQL, not SELECT * decoded into memory. With the LLM off,
        // `lastSummaryAt` stays nil forever, so `since` is .distantPast — fetching
        // rows here meant loading the ENTIRE event table (textContent included)
        // every 10 minutes just to compare a number against a threshold.
        return database.countEvents(from: since, to: Date()) >= minEventsRequired
    }

    /// Gate 3: No other mull process is running (PID check).
    private func passesLockGate() -> Bool {
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
            let hoursHeld = Date().timeIntervalSince(acquired) / 3600
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
                if self.shouldRun() {
                    do {
                        if let summary = try await self.runHandler?() {
                            self.onSummaryComplete?(summary)
                        }
                    } catch {
                        self.onSummaryFailed?(error)
                    }
                }
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
