import Foundation

/// Time-scoped erasure — "forget the last fifteen minutes".
///
/// A browser's Clear History works because in a browser the history *is* the
/// artifact: delete the rows and the thing is gone. mull is not shaped that way.
/// Raw events are only the input. Sixty seconds later the Curator has folded them
/// into me.md / now.md / full.md and frozen a copy into `daily/`; overnight the
/// LLM pass turns them into summaries, memories and knowledge entries. Deleting
/// `recording_events` alone erases the source and leaves every conclusion drawn
/// from it standing — the user believes 15:00 is gone while a sentence about it
/// sits at the top of the file every AI reads first. A privacy control that
/// reports success it did not achieve is worse than no control at all.
///
/// So forgetting is a pull through every derived layer, and it happens in two
/// steps the caller must keep in order:
///
///   1. `plan(...)` — read-only. Says exactly what will go, and, just as
///      importantly, what will NOT: the user's own writing, memories mull cannot
///      unmix, and anything already handed to a cloud provider.
///   2. `forget(_:)` — performs the plan.
///
/// The split exists so the confirmation dialog can name what is coming along.
/// "Forget the last hour" that quietly takes yesterday's report with it is an
/// ambush; one that says so first is a choice.
enum ForgetService {

    // MARK: - Plan

    /// What a forget over `interval` would remove, and what it would leave behind.
    struct Plan {
        let interval: DateInterval

        // Removed —
        var events: Int = 0
        var summaries: [DailySummary] = []
        var memories: [MemoryEntry] = []
        var knowledge: Int = 0
        /// `daily/YYYY/MM/YYYY-MM-DD.md` snapshots that must be deleted whole.
        var frozenSnapshots: [String] = []
        /// Unapproved understudy drafts (`reports/.drafts/`) for the affected days.
        var drafts: [String] = []

        // Kept, and reported —
        /// Approved reports for the affected days. These are the user's own
        /// writing (or prose they chose to keep), so mull will not delete them.
        var userReports: [String] = []
        /// Memories that predate the window but were revised inside it.
        var revisedMemories: [String] = []
        /// Blocks in the context files that the user pinned or edited by hand.
        /// Filled in by `forget` — a plan cannot know until it tries.
        var retainedBlocks: [String] = []
        /// Non-nil when a cloud provider is switched on, meaning some of this
        /// window may already have left the Mac and cannot be recalled.
        var cloudProvider: String?

        // Failed, and reported —
        //
        // The header comment stakes this feature on one sentence: a privacy
        // control that reports success it did not achieve is worse than no
        // control at all. These fields are that sentence made structural.
        // `forget` fills them, and anything in them must reach the user.

        /// The database layer at which deletion stopped, if it did. Layers go in
        /// order, so everything before this one is genuinely gone and everything
        /// at and after it still stands.
        var failedLayer: String?
        /// Files `forget` tried to clean and couldn't (relative paths) — they
        /// may still mention the window.
        var failedFiles: [String] = []
        /// True when the FTS shadow tables or the freelist could not be
        /// scrubbed: the rows are unreachable, but their text may linger in the
        /// database file until the next successful cleanup.
        var scrubFailed: Bool = false

        /// One honest report of what did NOT happen, or nil when the plan was
        /// carried out in full. Same register as `sentence(label:)` — only what
        /// changes what the user should do next.
        var failureMessage: String? {
            if let failedLayer {
                return String(localized: "Deleting \(failedLayer) failed, so this window is only partly forgotten. Try Forget again.")
            }
            var parts: [String] = []
            if !failedFiles.isEmpty {
                let names = failedFiles.map { ($0 as NSString).lastPathComponent }
                    .joined(separator: ", ")
                parts.append(String(localized: "Some files could not be cleaned and may still mention this window: \(names)."))
            }
            if scrubFailed {
                parts.append("The records are gone, but the database could not be fully scrubbed — fragments may remain on disk until the next cleanup.")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }

        /// Whether this forget would remove anything at all.
        var isEmpty: Bool {
            events == 0 && summaries.isEmpty && memories.isEmpty && knowledge == 0
                && frozenSnapshots.isEmpty && drafts.isEmpty
        }

        // MARK: What the user is told
        //
        // Two sentences, and only when they change the decision.
        //
        // An earlier version of this itemised all six categories it removes and
        // all four it keeps. Every line was true, and the whole thing was wrong:
        // this control gets pressed maybe twice a year, in the ten seconds after
        // something landed on screen that shouldn't have been recorded. Nobody
        // reads a ledger in that state. A dialog they have to parse is a dialog
        // they dismiss, and a privacy control people dismiss protects nothing.
        //
        // So the depth stays exactly as deep — summaries, memories, knowledge,
        // snapshots and drafts all still go — and the telling collapses to what a
        // person actually needs to decide: roughly how much, and the one thing
        // mull cannot undo. The rest is mull's job to get right, not the user's
        // job to audit.

        /// The whole message. `label` is the window in the user's words, e.g.
        /// "the last 15 minutes".
        func sentence(label: String) -> String {
            guard !isEmpty else { return String(localized: "There's nothing recorded in \(label).") }
            // One sentence per case rather than a stem plus an inflected fragment:
            // "\(events) recorded event" + "s" cannot be translated, and the joined
            // halves left the middle clause outside the catalog entirely (WRITING.md §5.3).
            let scale: String
            if events == 1 {
                scale = String(localized: "1 recorded event from \(label), and everything mull worked out from it, will be deleted.")
            } else if events > 1 {
                scale = String(localized: "\(events.formatted()) recorded events from \(label), and everything mull worked out from it, will be deleted.")
            } else {
                scale = String(localized: "Everything mull recorded in \(label), and everything mull worked out from it, will be deleted.")
            }
            return scale + " " + String(localized: "Your own notes and reports are kept.")
        }

        /// The single caveat worth interrupting for: text that has already left
        /// the Mac. Everything else mull keeps back is either the user's own
        /// writing (which they know they wrote) or invisible bookkeeping.
        ///
        /// It belongs in the confirmation, not in a report afterwards — you need
        /// it to decide, and telling someone after the fact that it couldn't
        /// really be forgotten is the worst possible moment to say so.
        var warning: String? {
            guard let cloudProvider else { return nil }
            return String(localized: "Some of it may already have been sent to \(cloudProvider), which mull can't take back.")
        }
    }

    /// Read-only survey of `interval`. Touches nothing.
    ///
    /// `cloudProvider` is passed in rather than read from `UserDefaults` here so
    /// this stays testable and so the one place that knows how the AI tab encodes
    /// "off" does not get duplicated into a second spelling.
    static func plan(interval: DateInterval,
                     database: DatabaseService,
                     cloudProvider: String? = nil) -> Plan {
        var plan = Plan(interval: interval)
        plan.cloudProvider = cloudProvider

        plan.events = database.countEvents(from: interval.start, to: interval.end)
        plan.summaries = database.fetchSummaries(in: interval)
        plan.memories = database.fetchMemories(createdIn: interval)
        plan.knowledge = database.countKnowledge(sourcedIn: interval)
        plan.revisedMemories = database.fetchMemories(revisedIn: interval).map(\.name)

        for day in days(in: interval) {
            // Today's snapshot is rewritten from full.md on the next 60s tick, so
            // it repairs itself and is not worth naming in a dialog. A past day's
            // is frozen — nothing will ever regenerate it, and it still contains
            // the window. Deleting the whole day to erase part of it is coarse,
            // which is precisely why the plan says so out loud.
            let snapshot = snapshotPath(for: day)
            if !Calendar.current.isDateInToday(day), MullDirectory.exists(snapshot) {
                plan.frozenSnapshots.append(snapshot)
            }

            let draft = ReportWriter.draftCachePath(for: day)
            if MullDirectory.exists(draft) { plan.drafts.append(draft) }

            let report = ReportWriter.path(for: day)
            if MullDirectory.exists(report) { plan.userReports.append(report) }
        }

        return plan
    }

    // MARK: - Forget

    /// Thrown when a database layer cannot be deleted. Carries the layer's name
    /// so the caller can say where the forget stopped: layers before it are
    /// gone, the one named and everything after it still stand.
    struct LayerError: Error {
        let layer: String
        let underlying: Error
    }

    /// Execute `plan`. Returns it back with `retainedBlocks` filled in — the
    /// context-file blocks mull refused to touch because they are the user's —
    /// and with the failure fields filled for anything it could not do. File and
    /// scrub failures are collected and reported, not thrown: half a forget is
    /// still worth finishing. A database failure throws `LayerError`, because
    /// nothing after that point is safe to claim.
    ///
    /// Order matters. Rows go before blocks: the retraction below removes mull's
    /// own blocks outright, but the *regeneration* that follows must not be able
    /// to re-derive them from data that is still sitting in the database.
    @discardableResult
    static func forget(_ plan: Plan, database: DatabaseService) throws -> Plan {
        var result = plan

        // 1. The source, and everything the nightly pass concluded from it.
        try layer("recorded events") { try database.deleteEvents(in: plan.interval) }
        try layer("daily summaries") { try database.deleteSummaries(plan.summaries) }
        try layer("memories") { try database.deleteMemories(plan.memories) }
        try layer("knowledge entries") { try database.deleteKnowledge(sourcedIn: plan.interval) }

        // 1b. The same window, in every copy of the database that is not the live
        //     one. A `.corrupt-*` quarantine is a copy a future launch will merge
        //     back in — so without this, forgetting 15:00 and then relaunching can
        //     hand 15:00 straight back — and a drained `.reattached-*` is a copy
        //     that simply sits there holding the window forever. Scrubbed rather
        //     than deleted: a pending quarantine holds rows the live database does
        //     not, and taking the whole file to erase fifteen minutes would forget
        //     months nobody asked to forget.
        result.failedFiles += QuarantineRecovery.scrub(
            interval: plan.interval,
            memoryFilePaths: plan.memories.map(\.filePath),
            besidePrimary: database.databaseFilePath)

        // 2. The memory files those rows pointed at, and the index entries that
        //    linked to them — otherwise MEMORY.md keeps advertising a description
        //    of the forgotten window and links into a hole.
        for memory in plan.memories where !MullDirectory.delete(memory.filePath) {
            result.failedFiles.append(memory.filePath)
        }
        if !pruneMemoryIndex(removing: plan.memories) {
            result.failedFiles.append("MEMORY.md")
        }

        // 3. Frozen artifacts. Nothing regenerates these, so they must be deleted
        //    rather than waited out.
        for path in plan.frozenSnapshots where !MullDirectory.delete(path) {
            result.failedFiles.append(path)
        }
        for path in plan.drafts where !MullDirectory.delete(path) {
            result.failedFiles.append(path)
        }

        // 4. Retract mull's blocks from the curated files. The 60s pass would
        //    eventually prune the live blocks by itself, but not the `nightly:`
        //    ones — those refresh once a day, so without this a forget at 15:00
        //    leaves the window described until the next consolidation.
        //    A retraction that could not be written back is the worst failure in
        //    this whole routine — these three files are the ones every AI reads
        //    first — so it goes in `failedFiles` with the rest.
        for (file, prefixes) in [("me.md", ["fact:", "mem:", "pref:"]),
                                 ("now.md", ["now:", "nightly:"]),
                                 ("full.md", ["full:", "nightly:"])] {
            let retraction = Curator.retract(relativePath: file, idPrefixes: prefixes)
            result.retainedBlocks += retraction.retained.map { "\(file) — \($0)" }
            if !retraction.written { result.failedFiles.append(file) }
        }

        // 5. The text lives on in the FTS shadow tables and in pages the freelist
        //    has not handed back until these run. "Forgotten" has to mean gone
        //    from the file, not just unreachable by a query — so a failure here
        //    is the plan's to report, not the log's to absorb.
        let scrubbed = database.rebuildFTSIndexes()
        let reclaimed = database.vacuum()
        result.scrubFailed = !(scrubbed && reclaimed)

        return result
    }

    /// Names the layer a database failure happened in, so the error can say
    /// where the forget stopped rather than just that it did.
    private static func layer(_ name: String, _ delete: () throws -> Void) throws {
        do { try delete() } catch { throw LayerError(layer: name, underlying: error) }
    }

    // MARK: - Helpers

    /// Every calendar day the interval touches.
    static func days(in interval: DateInterval) -> [Date] {
        let calendar = Calendar.current
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: interval.start)
        let last = calendar.startOfDay(for: interval.end)
        while cursor <= last {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// Where the day's record lives. `VaultLayout` owns the formula; this stays as
    /// the name the deletion planner has always called it by.
    static func snapshotPath(for day: Date) -> String { VaultLayout.dailyPath(for: day) }

    /// Drop the index lines that link to memory files being deleted, leaving the
    /// rest of MEMORY.md byte-identical. Returns `false` when the pruned index
    /// could not be written back.
    ///
    /// Deliberately surgical rather than a full rebuild: MEMORY.md carries a
    /// truncation rule and any blocks the user added by hand, and re-deriving the
    /// whole file to remove two lines would put both at risk for no gain.
    private static func pruneMemoryIndex(removing memories: [MemoryEntry]) -> Bool {
        guard !memories.isEmpty,
              let existing = MullDirectory.read("MEMORY.md") else { return true }
        let targets = Set(memories.map(\.filePath))
        let kept = existing.components(separatedBy: "\n").filter { line in
            !targets.contains { line.contains("(\($0))") }
        }
        let text = kept.joined(separator: "\n")
        guard text != existing else { return true }
        return MullDirectory.write(text, to: "MEMORY.md")
    }
}
