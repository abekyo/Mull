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

    // MARK: - What is fit to write in somebody's day

    /// The shortest block worth a row on a calendar.
    ///
    /// The same five minutes `ContextComposer` settled on, and for the same reason:
    /// a two-minute stay is a glance, not a piece of work, and a day of them buries
    /// the four things that were. The engine's own floor is 30 seconds, which is
    /// right for a grid you can zoom and wrong for a calendar that syncs to a phone.
    static let minimumDuration: TimeInterval = 300

    /// The longest title mull will put on somebody's calendar. Past this a window
    /// title is not a name, whatever shape it has.
    static let maxTitleLength = 80

    /// Whether a block's label is fit to be the title of an event on a real calendar.
    ///
    /// This is the same question `me.md` asks before it names a project, so it is
    /// answered by the same rules — `ProjectNames`, which judges *shape and evidence,
    /// never vocabulary*. Nothing here is a list of strings somebody found annoying;
    /// a blocklist only ever rejects the noise its author already saw.
    ///
    /// A label is a name or it is a sentence. `generateLabel` falls through to a
    /// cleaned window title when it can parse nothing, so "how do I cancel a Task in
    /// Swift" and "元のプロファイル" both reach here wearing the same shape as
    /// "Mull — parser". Written to a calendar the difference matters more than it does
    /// anywhere else in mull: this is the one surface that leaves the Mac, and the one
    /// a person reads every day without asking to.
    ///
    /// A filename passes on its own — `ViewController.swift` is exactly what somebody
    /// wants to see at 14:00 — even though `isPlausible` rejects it as a *project*
    /// name. The two questions are different and only one of them is being asked here.
    ///
    /// **What this does not catch.** `ProjectNames` has a second rule — chrome, the
    /// segment that appears in nearly every title one browser emits — and it is
    /// evidence-based, so it needs a corpus of at least five titles per app. A day's
    /// blocks carry one title each, which is below that threshold for every app but the
    /// one you lived in, so applying it here would mostly do nothing while looking like
    /// a protection. `元のプロファイル` therefore passes this gate. The corpus rule runs
    /// where the corpus is, in `TimeBlockEngine`; this is the shape gate only, and
    /// saying so is cheaper than a reader discovering it.
    static func isPresentable(_ label: String) -> Bool {
        presentableHead(of: label)?.whole == true
    }

    /// The leading run of a label that is fit to write, and whether that is all of it.
    ///
    /// `isPresentable` used to be the whole answer, and it is `allSatisfy`: one bad
    /// segment threw away the good ones with it. What that costs is measurable rather
    /// than theoretical. `eval/calendar/` on four real days: 103 minutes of
    /// `Formiq iOS — オンボーディングのデザインが単調な理由を調査` went to the calendar
    /// as **Code**, because the second segment is a clause and the first — the project,
    /// the part somebody actually wants at 14:00 — was discarded with it. Four of the
    /// eight fallbacks in that sample had a perfectly good project name in front of the
    /// segment that failed.
    ///
    /// Leading run rather than "any surviving segment", and the direction is the whole
    /// safety of it. `generateLabel` emits `project — detail` for an editor, so the
    /// front of the label is the name; for a browser the front is the page. Keeping the
    /// tail instead would have promoted `元のプロファイル` out of
    /// `販売が集客に変わる構造・13パターン — 元のプロファイル` — the exact string the
    /// chrome rule exists to stop. When the head fails, nothing is kept and the app's
    /// name is the answer, which is what that case should get.
    static func presentableHead(of label: String) -> (title: String, whole: Bool)? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxTitleLength else { return nil }
        let segments = ProjectNames.segments(of: trimmed)
        guard !segments.isEmpty else { return nil }
        let kept = segments.prefix { segment in
            ProjectNames.isPlausible(segment) || ProjectNames.isFileName(segment)
        }
        guard !kept.isEmpty else { return nil }
        // Rejoined rather than sliced out of the original, so a label written with
        // " - " or " | " comes back in one separator. Whole labels are returned
        // verbatim, so nothing that already passed changes shape.
        return kept.count == segments.count ? (trimmed, true) : (kept.joined(separator: " — "), false)
    }

    /// The title a block gets, and whether mull had to fall back to the app's name.
    ///
    /// Falling back is not a failure to report at the user — an hour of "Xcode" is
    /// true, and true is the floor this whole product stands on. It is a failure to
    /// *count*, which is why the flag comes back with the title: a day where half the
    /// rows say "Xcode" is a day mull could not read, and nothing else on this path
    /// would ever say so.
    /// **Copied text never becomes a title here.** `generateLabel` captions a block
    /// with the clipboard when no window offered a name, which is right for the grid
    /// and wrong for this path: the shape gate below asks whether a string *looks like*
    /// a name, and short copied fragments pass it exactly when they are worst —
    /// `田中商事 見積書`, `退職の相談`, `¥3,200,000` are all two-to-eight characters of
    /// something the user copied out of somebody else's document, and all three read as
    /// names. The long ones are already caught (`isPlausible` stops at 40 characters,
    /// the clipboard caption runs to 60), so what survived the gate was the selective
    /// worst case rather than a random sample.
    ///
    /// Settings promises writes are "taken from your window titles". This is the line
    /// that makes that sentence true rather than nearly true (CLAUDE.md §7.4).
    ///
    /// How much of the block's own label survived. Three answers rather than two,
    /// because "mull wrote the project but not what you were doing in it" is a
    /// different day from "mull wrote the name of your editor" and they used to be
    /// counted as the same failure.
    enum Naming: String, Equatable, Codable {
        /// The block's own label was fit to write, whole.
        case named
        /// Its leading segments were. The rest was dropped.
        case shortened
        /// None of it was, so the event says the app's name.
        case fellBack
    }

    static func title(for block: TimeBlock) -> (title: String, naming: Naming) {
        guard !block.label.isEmpty, block.label != block.app,
              !block.labelFromClipboard,
              let head = presentableHead(of: block.label) else { return (block.app, .fellBack) }
        return (head.title, head.whole ? .named : .shortened)
    }

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
        let handle: CalendarEventHandle
        let title: String
        let start: Date
        let end: Date
    }

    struct Change: Equatable {
        let handle: CalendarEventHandle
        let entry: Entry
    }

    struct Removal: Equatable {
        let handle: CalendarEventHandle
        let key: String
    }

    /// What this run could see about the quality of what it was about to write.
    ///
    /// Counted rather than inferred, because the alternative is the state mull was in
    /// until now: the titles that reach a calendar are window titles, nobody was
    /// scoring them, and the only way to find out they were bad was to read your own
    /// calendar and be disappointed. §4 says the selection is measured or it is vibes;
    /// this is the same rule applied to the one output a person sees every day.
    struct Quality: Equatable, Codable {
        /// Blocks whose own label was fit to write, whole.
        var named = 0
        /// Blocks written under the presentable front of their label, with the rest
        /// dropped. Counted apart from `named` on purpose: this number rising is the
        /// signal that titles are arriving half-readable, and folded into `named` it
        /// would be invisible.
        var shortened = 0
        /// Blocks that fell back to the app's name because none of their label was fit.
        var fellBack = 0
        /// Settled blocks dropped for being shorter than `minimumDuration`.
        var tooShort = 0

        var considered: Int { named + shortened + fellBack }

        /// How much of the range mull could name from what the user had open, whole or
        /// in part, 0…1. `nil` when there was nothing to name — a different answer from
        /// zero.
        ///
        /// **This measures how often the rule found a name, not whether the name was
        /// right.** There is no gold labelling anywhere in mull for calendar titles, so
        /// a gate that let junk through would raise this number rather than lower it.
        /// The list in `eval/calendar/` is where correctness is read, by a person, and
        /// it prints every title it would write for exactly that reason.
        var namedFraction: Double? {
            guard considered > 0 else { return nil }
            return Double(named + shortened) / Double(considered)
        }
    }

    struct Plan: Equatable {
        var create: [Entry] = []
        var update: [Change] = []
        var delete: [Removal] = []
        /// Keys mull wrote, the user removed, and mull must not write again. Empty on a
        /// press, which overrides deletions rather than honouring them.
        var tombstone: Set<String> = []
        /// Blocks mull wrote that the user removed, carrying what mull *would* have
        /// written for them. `tombstone` is what the ledger needs (keys, to stay silent
        /// about them); this is what the correction loop needs (the title, to learn
        /// what was not worth writing).
        ///
        /// Not the keys of `tombstone`. On a reconcile the two describe the same
        /// blocks, but a press fills this and leaves `tombstone` empty: it writes the
        /// event again *and* records that the user had removed it, because those are
        /// separate facts and only the second one teaches anything.
        var rejected: [Entry] = []
        var quality = Quality()

        var isEmpty: Bool { create.isEmpty && update.isEmpty && delete.isEmpty && tombstone.isEmpty }
    }

    /// What a run is: a timer reconciling, or somebody pressing the button.
    ///
    /// Both write the same events through the same marker. They differ on what an
    /// *absent* event means. To the timer, silence is the user having deleted it, so it
    /// tombstones and never offers it again. A press says the opposite out loud, so it
    /// writes over a tombstone — which is the only way back for somebody who cleared a
    /// day and changed their mind.
    ///
    /// What used to follow from that, and should not have: the press learned nothing.
    /// A deletion it wrote over is still "mull proposed this, the human removed it",
    /// the label §7.3 calls the best one there is, and the press was the only path in
    /// use — on this Mac 56 events were written by hand and the timer had never once
    /// met its own start condition. So the two questions are separated here. Whether to
    /// stay silent about a key is `honoursDeletions`; whether the deletion is worth
    /// recording is not in question, and both modes record it.
    enum Trigger {
        case reconcile
        case press

        /// Whether an absent event stops mull writing it again.
        var honoursDeletions: Bool { self == .reconcile }
    }

    /// What this run should do.
    ///
    /// - Parameters:
    ///   - blocks: every block in the covered range, settled or not.
    ///   - existing: the mirrored events currently on the calendar in that range.
    ///   - written: keys mull has created before now — the memory that lets a missing
    ///     event be read as "the user deleted it" rather than "not written yet".
    ///   - tombstoned: keys the user has already deleted once.
    ///   - trigger: a timer pass, or a deliberate press. See `Trigger`.
    static func plan(blocks: [TimeBlock],
                     existing: [Existing],
                     written: Set<String>,
                     tombstoned: Set<String>,
                     now: Date,
                     resumeGap: TimeInterval,
                     trigger: Trigger = .reconcile) -> Plan {

        var quality = Quality()
        var desired: [Entry] = []
        for block in blocks where isSettled(end: block.end, now: now, resumeGap: resumeGap) {
            // A glance is not a piece of work. Counted before it is dropped, so a day
            // that was all glances can say so rather than looking like an empty day.
            guard block.duration >= minimumDuration else {
                quality.tooShort += 1
                continue
            }
            let (title, naming) = title(for: block)
            switch naming {
            case .named:     quality.named += 1
            case .shortened: quality.shortened += 1
            case .fellBack:  quality.fellBack += 1
            }
            desired.append(Entry(key: key(forBlockStartingAt: block.start),
                                 title: title,
                                 start: block.start,
                                 end: block.end))
        }

        var byKey: [String: Entry] = [:]
        for entry in desired { byKey[entry.key] = entry }
        let present = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        var plan = Plan()
        plan.quality = quality

        // Gone from the calendar but written before and still wanted: the user took it
        // out. That is an instruction, not a gap to fill — and it is a correction
        // whichever way the run treats it.
        for entry in desired where present[entry.key] == nil {
            let removedByUser = written.contains(entry.key)
            if removedByUser {
                plan.rejected.append(entry)
            }
            if trigger.honoursDeletions {
                if removedByUser {
                    plan.tombstone.insert(entry.key)
                } else if !tombstoned.contains(entry.key) {
                    plan.create.append(entry)
                }
            } else {
                // A press overrides both the tombstone and the silence, and writes.
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

    // MARK: - The correction the mirror was throwing away

    /// Where a calendar correction is filed. Not a vault file — the correction did not
    /// happen in one — but the cards are keyed on this, so it has to be stable and it
    /// has to say which surface the user was looking at.
    static let correctionPath = "calendar"

    /// Cards for the blocks the user deleted off their calendar.
    ///
    /// "mull proposed this, the human rejected it" is the shape §7.3 calls the
    /// highest-quality relevance label there is, and until now the calendar produced
    /// it and dropped it: the key went into a `UserDefaults` list that exists only to
    /// stop mull re-proposing, and nothing downstream ever heard about it. The rest of
    /// mull learns from exactly this event through `Curator`; the one screen the user
    /// actually looks at every day did not.
    ///
    /// Wiring it to the timer alone was the same mistake one layer up: the timer had
    /// never run, so a card had never been written, while the button beside it had
    /// written 56 events. Both triggers fill `rejected` now, so both teach.
    ///
    /// `kept` is empty on purpose, and that is the whole verdict. The card's `dropped`
    /// then holds the title, so folding it into the ledger puts a negative delta on
    /// that text — which is right beyond the calendar too. A window title not worth an
    /// hour of somebody's day is not worth a slot in a context window either.
    ///
    /// Pure, like everything else in this type: the runner writes them.
    static func correctionCards(for plan: Plan,
                                now: Date = Date(),
                                context: String? = nil) -> [CorrectionCard] {
        plan.rejected.map { entry in
            CorrectionCard(path: correctionPath,
                           blockID: entry.key,
                           date: now,
                           kept: "",
                           wouldWrite: entry.title,
                           context: context)
        }
    }
}

// Written by hand, and in an extension so the memberwise initialiser survives — the
// tests build a `Quality` field by field, and a stored status must not be able to make
// `load()` throw. What a throw costs here is not a missing field: it is a fresh zero,
// and every count since the mirror was first used gone, which is the same silent lie
// the type was added to end.
extension CalendarMirror.Quality {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(named: try c.decodeIfPresent(Int.self, forKey: .named) ?? 0,
                  shortened: try c.decodeIfPresent(Int.self, forKey: .shortened) ?? 0,
                  fellBack: try c.decodeIfPresent(Int.self, forKey: .fellBack) ?? 0,
                  tooShort: try c.decodeIfPresent(Int.self, forKey: .tooShort) ?? 0)
    }
}
