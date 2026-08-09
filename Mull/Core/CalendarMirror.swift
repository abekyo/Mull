import Foundation

/// Deciding what the calendar mirror should write, with no EventKit in it.
///
/// The mirror copies observed activity into a calendar the user picked, so that the
/// record of what happened sits beside what was planned — in Calendar.app, on the
/// phone, wherever that calendar already goes. Three properties make it safe enough
/// to run on a timer rather than only on a gesture, and all three live here rather
/// than in the runner, because the runner cannot be tested against somebody's real
/// calendar and this can:
///
/// 1. **Only settled work is written.** A block whose last event is recent can still
///    grow, and writing it would put a finish time in the calendar for something that
///    has not finished. `isSettled` is the exact condition under which no future
///    event can extend a block, so a mirrored event never moves once written.
/// 2. **Blocks are derived, so the mirror reconciles rather than appends.** The same
///    day yields different blocks after a settings change — on 2026-08-09 the same
///    events went from fourteen blocks to eight — so every run diffs desired against
///    present and deletes what no longer exists.
/// 3. **A deletion by the user is final.** Anything mull wrote and the user removed
///    is remembered and never written again. Without this the mirror is a loop that
///    takes the calendar away from the person who owns it.
enum CalendarMirror {

    /// How far back each run reconciles. Today and yesterday, so a block that settles
    /// just after midnight is still picked up, and no further: re-deriving ninety days
    /// of history every hour would cost far more than it could ever correct, and the
    /// history that matters is already in the vault.
    static let daysCovered = 2

    // MARK: - Naming what mull wrote

    /// EventKit has no custom fields, so the marker goes in `url`, which nothing else
    /// on a calendar event uses and which survives a sync round trip intact.
    ///
    /// The key is the block's start instant. It is stable across re-derivation for as
    /// long as the block itself is (a block's start is the first event in it, which
    /// no later event can change), and it cannot collide inside one calendar.
    static let scheme = "x-mull"

    static func key(forBlockStartingAt start: Date) -> String {
        String(Int(start.timeIntervalSince1970.rounded()))
    }

    static func marker(_ key: String) -> URL? {
        URL(string: "\(scheme)://block/\(key)")
    }

    /// The block key a calendar event was written for, or nil if mull did not write it.
    /// Anything without this marker belongs to the user, whatever calendar it sits in.
    static func key(fromMarker url: URL?) -> String? {
        guard let url, url.scheme == scheme, url.host == "block" else { return nil }
        let key = url.lastPathComponent
        return key.isEmpty || key == "/" ? nil : key
    }

    // MARK: - Settled

    /// Whether no future event can still extend this block.
    ///
    /// A block grows two ways: the engine's inner window absorbs an event within 180s,
    /// and `coalesceResumed` rejoins across a break of up to `resumeGap`. Past the
    /// larger of the two, both doors are shut and the block is final — which is the
    /// only moment its end time is a fact rather than "as of when you last looked".
    ///
    /// `resumeGap` of 0 (rejoining turned off) still has to clear the inner window,
    /// hence the max rather than the setting alone.
    static func isSettled(end: Date, now: Date, resumeGap: TimeInterval) -> Bool {
        now.timeIntervalSince(end) > max(resumeGap, 180)
    }

    // MARK: - The plan

    /// One mirrored event, as it should be.
    struct Entry: Equatable {
        let key: String
        let title: String
        let start: Date
        let end: Date
    }

    /// A mirrored event as it currently exists on the calendar.
    struct Existing: Equatable {
        let key: String
        let handle: CalendarService.EventHandle
        let title: String
        let start: Date
        let end: Date
    }

    struct Change: Equatable {
        let handle: CalendarService.EventHandle
        let entry: Entry
    }

    struct Removal: Equatable {
        let handle: CalendarService.EventHandle
        let key: String
    }

    struct Plan: Equatable {
        var create: [Entry] = []
        var update: [Change] = []
        var delete: [Removal] = []
        /// Keys mull wrote, the user removed, and mull must not write again.
        var tombstone: Set<String> = []

        var isEmpty: Bool { create.isEmpty && update.isEmpty && delete.isEmpty && tombstone.isEmpty }
    }

    /// What this run should do.
    ///
    /// - Parameters:
    ///   - blocks: every block in the covered range, settled or not.
    ///   - existing: the mirrored events currently on the calendar in that range.
    ///   - written: keys mull has created before now — the memory that lets a missing
    ///     event be read as "the user deleted it" rather than "not written yet".
    ///   - tombstoned: keys the user has already deleted once.
    static func plan(blocks: [TimeBlock],
                     existing: [Existing],
                     written: Set<String>,
                     tombstoned: Set<String>,
                     now: Date,
                     resumeGap: TimeInterval) -> Plan {

        let desired = blocks
            .filter { isSettled(end: $0.end, now: now, resumeGap: resumeGap) }
            .map { Entry(key: key(forBlockStartingAt: $0.start),
                         title: $0.label.isEmpty ? $0.app : $0.label,
                         start: $0.start,
                         end: $0.end) }

        var byKey: [String: Entry] = [:]
        for entry in desired { byKey[entry.key] = entry }
        let present = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        var plan = Plan()

        // Gone from the calendar but written before and still wanted: the user took it
        // out. That is an instruction, not a gap to fill.
        for entry in desired where present[entry.key] == nil {
            if written.contains(entry.key) {
                plan.tombstone.insert(entry.key)
            } else if !tombstoned.contains(entry.key) {
                plan.create.append(entry)
            }
        }

        // Still wanted and still there: follow it only if something actually differs,
        // so an unchanged day costs no writes at all.
        for entry in desired {
            guard let row = present[entry.key] else { continue }
            if row.title != entry.title || row.start != entry.start || row.end != entry.end {
                plan.update.append(Change(handle: row.handle, entry: entry))
            }
        }

        // Mirrored, but no longer a block mull would write — the segmentation changed
        // under it. Only ever mull's own events: `existing` is already filtered by the
        // marker, so nothing the user made is reachable from here.
        for row in existing where byKey[row.key] == nil {
            plan.delete.append(Removal(handle: row.handle, key: row.key))
        }

        return plan
    }
}
