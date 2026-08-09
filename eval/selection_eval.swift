import Foundation

// Standalone evaluation harness for the selection layer (SELECTION-LAYER.md §6).
// Measures precision / recall / MRR of `Selection.rank` over labeled (need →
// ideal-slice) cases, so changes to the ranker can be judged, not guessed.
//
// Run:  ./eval/run.sh
//
// Compiles with a GRDB-free RecordingEvent shim (same shape Selection uses), so
// it runs in seconds without the app/host-test. Lives outside the Xcode targets.
//
// The file list in run.sh is the whole fragility of this harness: every GRDB-free
// symbol Selection reaches for has to be listed, and nothing it reaches for may
// import GRDB. It has rotted twice that way (2026-07-18: Selection started
// calling DatabaseService.containsCJK, which imports GRDB; the shim also fell
// behind RecordingEvent.id). Both are fixed — containsCJK now lives in
// Mull/Core/TextScript.swift — and CI runs run.sh so it cannot rot silently again.

// The RecordingEvent shim, the baseline strategies and the metrics live in
// eval/EvalCore.swift, shared with eval/real/real_eval.swift so the two harnesses
// cannot drift apart and report incomparable numbers.

// MARK: - Case model + builders

let now = Date()
func minsAgo(_ m: Int) -> Date { now.addingTimeInterval(Double(-m * 60)) }

/// Terse event builder. type defaults to clipboard (a "note"-ish signal).
func ev(_ mins: Int, _ text: String, app: String? = "Code", title: String? = nil,
        kind: RecordingEvent.EventType = .clipboard) -> RecordingEvent {
    RecordingEvent(timestamp: minsAgo(mins), eventType: kind, appName: app,
                   windowTitle: title ?? text, textContent: text)
}

struct EvalCase {
    let name: String
    let events: [RecordingEvent]
    let query: String
    /// EXPLICIT scope: the agent named a project. A hard filter is correct — it
    /// asked for that project and nothing else.
    var entity: String? = nil
    /// IMPLICIT anchor: the agent named nothing, and MCPServer filled in whatever
    /// the user happens to have open (MCPServer.toolSearch). This is a *prior*,
    /// not a request — the agent never asked to be confined to the current
    /// project, and "how did I solve this last time" is answered from a different
    /// one. Conflating the two is the defect these cases exist to measure.
    var anchor: String? = nil
    var type: String? = nil
    var k: Int = 8
    let gold: Set<String>   // event texts that SHOULD surface
    /// What this case is for. `.guard` cases pass before and after a change and
    /// exist to catch over-correction; `.gap` cases are known-failing targets.
    var role: Role = .guardrail

    enum Role { case guardrail, gap }
}

let cases: [EvalCase] = [
    // 1. Plain lexical match wins.
    EvalCase(name: "lexical-note", events: [
        ev(5, "fix navigation bug in settings"),
        ev(6, "buy milk later"),
        ev(7, "standup notes nothing special"),
    ], query: "navigation bug", k: 3, gold: ["fix navigation bug in settings"]),

    // 2. Type filter: only errors.
    EvalCase(name: "type-error", events: [
        ev(3, "Fatal error: index out of range in Cart.swift"),
        ev(4, "decided to use JWT for auth"),
        ev(5, "func authToken() { return token }"),
    ], query: "crash", type: "error", k: 5,
       gold: ["Fatal error: index out of range in Cart.swift"]),

    // 3. Recency tiebreak: newer of two identical-topic notes.
    EvalCase(name: "recency", events: [
        ev(5, "refactor the auth module now"),
        ev(7200, "refactor the auth module old"),
    ], query: "refactor auth", k: 1, gold: ["refactor the auth module now"]),

    // 4. Entity scoping drops other projects.
    EvalCase(name: "entity-scope", events: [
        ev(5, "todo: add chart", title: "Dashboard.swift — PantryApp", kind: .screenText),
        ev(6, "todo: fix login", title: "Login.swift — OtherApp", kind: .screenText),
    ], query: "todo", entity: "PantryApp", k: 5,
       gold: ["todo: add chart"]),

    // 5. Sensitive content is never surfaced.
    EvalCase(name: "sensitive-excluded", events: [
        ev(3, "password: hunter2 for the staging db"),
        ev(4, "reset password flow needs a rewrite"),
    ], query: "password", k: 5, gold: ["reset password flow needs a rewrite"]),

    // 6. Test/QA input is never surfaced.
    EvalCase(name: "testinput-excluded", events: [
        ev(3, "test   double   spaces"),
        ev(4, "design spaces between the cards"),
    ], query: "spaces", k: 5, gold: ["design spaces between the cards"]),

    // 7. Salience: a decision-note beats a code line for the same term.
    EvalCase(name: "salience-note-over-code", events: [
        ev(5, "decided to use JWT for auth"),
        ev(6, "func auth() {", kind: .keystroke),
    ], query: "auth", k: 1, gold: ["decided to use JWT for auth"]),

    // 8. Japanese self-instruction note.
    EvalCase(name: "ja-note", events: [
        ev(5, "Calendar IUOを解消して"),
        ev(6, "lunch with team"),
    ], query: "calendar", k: 3, gold: ["Calendar IUOを解消して"]),

    // 9. Multiple gold → recall.
    EvalCase(name: "multi-gold-recall", events: [
        ev(5, "onboarding screen copy draft"),
        ev(6, "onboarding analytics events list"),
        ev(7, "onboarding flow edge cases"),
        ev(8, "deploy script tweak"),
        ev(9, "weekly review notes"),
    ], query: "onboarding", k: 5, gold: [
        "onboarding screen copy draft",
        "onboarding analytics events list",
        "onboarding flow edge cases",
    ]),

    // 10. File type filter.
    EvalCase(name: "type-file", events: [
        ev(5, "ProfileView.swift — App", title: "ProfileView.swift — App", kind: .screenText),
        ev(6, "view the dashboard mockup"),
    ], query: "view", type: "file", k: 5, gold: ["ProfileView.swift — App"]),

    // 11. Distractor flood (precision pressure).
    EvalCase(name: "distractors", events: [
        ev(5, "stripe integration webhook signature check"),
        ev(6, "groceries"), ev(7, "call dentist"), ev(8, "water plants"),
        ev(9, "read article"), ev(10, "stretch break"),
    ], query: "stripe webhook", k: 3,
       gold: ["stripe integration webhook signature check"]),

    // 12. Two errors, both relevant.
    EvalCase(name: "two-errors", events: [
        ev(3, "Exception: nil unwrap in Parser"),
        ev(4, "Error: failed to decode JSON response"),
        ev(5, "shipped the release"),
    ], query: "error", type: "error", k: 5, gold: [
        "Exception: nil unwrap in Parser",
        "Error: failed to decode JSON response",
    ]),

    // 13. Note type restricts to notes.
    EvalCase(name: "type-note", events: [
        ev(5, "remember to update the changelog"),
        ev(6, "Fatal error: boom"),
    ], query: "changelog", type: "note", k: 5,
       gold: ["remember to update the changelog"]),

    // 14. Entity anchor + lexical together.
    EvalCase(name: "entity-plus-lexical", events: [
        ev(5, "cache layer redesign", title: "Cache.swift — Mull", kind: .screenText),
        ev(6, "cache layer redesign", title: "Cache.swift — OtherApp", kind: .screenText),
    ], query: "cache", entity: "Mull", k: 1,
       gold: ["cache layer redesign"]),  // both share text; entity picks Mull's

    // 15. Short query, single strong hit.
    EvalCase(name: "single-hit", events: [
        ev(5, "migrate to SwiftData from CoreData"),
        ev(6, "buy coffee"),
    ], query: "SwiftData", k: 3, gold: ["migrate to SwiftData from CoreData"]),

    // 16. Recency among three.
    EvalCase(name: "recency-3", events: [
        ev(2, "deploy v3 to prod"),
        ev(120, "deploy v2 to prod"),
        ev(2880, "deploy v1 to prod"),
    ], query: "deploy prod", k: 1, gold: ["deploy v3 to prod"]),

    // 17. No false positive from unrelated salient note.
    EvalCase(name: "no-salient-false-pos", events: [
        ev(5, "URGENT decided to drop the feature"),
        ev(6, "graphql schema stitching notes"),
    ], query: "graphql", k: 1, gold: ["graphql schema stitching notes"]),

    // 18. Mixed kinds, lexical wins across kinds.
    EvalCase(name: "mixed-kinds", events: [
        ev(5, "rate limiter design doc", kind: .clipboard),
        ev(6, "RateLimiter.swift — Api", title: "RateLimiter.swift — Api", kind: .screenText),
        ev(7, "lunch"),
    ], query: "rate limiter", k: 3, gold: [
        "rate limiter design doc", "RateLimiter.swift — Api",
    ]),

    // 19. Error term but type=note should NOT return the error.
    EvalCase(name: "type-note-excludes-error", events: [
        ev(3, "Error: timeout talking to redis"),
        ev(4, "note: redis timeout — bump the pool size"),
    ], query: "redis timeout", type: "note", k: 5,
       gold: ["note: redis timeout — bump the pool size"]),

    // 20. Japanese + English mixed query term.
    EvalCase(name: "ja-en-mixed", events: [
        ev(5, "MVVMリファクタを Phase 2 まで進めた"),
        ev(6, "random keystrokes asdf"),
    ], query: "MVVM", k: 3, gold: ["MVVMリファクタを Phase 2 まで進めた"]),

    // ────────────────────────────────────────────────────────────────────────
    // 21-28: the cases the first twenty could not see.
    //
    // Every case above either scopes an entity explicitly or scopes none at all,
    // so none of them exercises the path the agent actually takes: call `search`
    // with no entity, and MCPServer anchors on the current one. The benchmark
    // scored 1.000 across the board because it never asked the ranker the
    // question the product exists to answer.
    // ────────────────────────────────────────────────────────────────────────

    // 21. GAP — "how did I solve this last time?" The answer is in ANOTHER
    // project, which is what makes it worth asking. An anchor must not delete it.
    EvalCase(name: "cross-entity-solution", events: [
        ev(10, "TODO: wire up the chart", title: "Dashboard.swift — PantryApp", kind: .screenText),
        ev(4320, "solved the stripe webhook signature mismatch by using the raw body",
           title: "Webhook.swift — PaymentsApp", kind: .screenText),
        ev(6, "lunch with the design team", title: "Notes — PantryApp"),
    ], query: "stripe webhook signature", anchor: "PantryApp", k: 3,
       gold: ["solved the stripe webhook signature mismatch by using the raw body"],
       role: .gap),

    // 22. GAP — two prior fixes, both outside the anchor, both wanted.
    EvalCase(name: "cross-entity-multi", events: [
        ev(20, "notes on the grid layout", title: "Grid.swift — Mull"),
        ev(2880, "fixed the flaky test by seeding the clock", title: "ClockTests.swift — PaymentsApp"),
        ev(5760, "flaky test came back — the fix was to seed the clock", title: "Sched.swift — PantryApp"),
    ], query: "flaky test", anchor: "Mull", k: 5, gold: [
        "fixed the flaky test by seeding the clock",
        "flaky test came back — the fix was to seed the clock",
    ], role: .gap),

    // 23. GAP — the user's words are not the log's words. "auth broken" never
    // appears; the event that answers it says "login returns 401". With a literal
    // gate this returns "No relevant activity" and the agent believes it.
    EvalCase(name: "synonym-fallback-in-anchor", events: [
        ev(8, "login returns 401 after the session expires", title: "Session.swift — PaymentsApp"),
        ev(9, "groceries and dry cleaning", title: "Notes — Home"),
        ev(2880, "ProfileView.swift — PaymentsApp", title: "ProfileView.swift — PaymentsApp", kind: .screenText),
    ], query: "auth broken", anchor: "PaymentsApp", k: 3,
       gold: ["login returns 401 after the session expires"], role: .gap),

    // 24. GUARD — the anchor still has to RANK once it stops filtering. Same
    // words in two projects, the anchored one slightly older: the anchor is the
    // only signal that can outvote recency, and it must.
    EvalCase(name: "anchor-prefers-current", events: [
        ev(5, "cache layer redesign for the other app", title: "Cache.swift — OtherApp", kind: .screenText),
        ev(6, "cache layer redesign in mull", title: "Cache.swift — Mull", kind: .screenText),
    ], query: "cache redesign", anchor: "Mull", k: 1,
       gold: ["cache layer redesign in mull"]),

    // 25. GUARD — an EXPLICIT entity is a request, not a prior. It keeps filtering.
    EvalCase(name: "explicit-entity-still-filters", events: [
        ev(5, "retry logic with exponential backoff", title: "Net.swift — OtherApp", kind: .screenText),
        ev(6, "retry logic rewritten", title: "Net.swift — Mull", kind: .screenText),
    ], query: "retry", entity: "Mull", k: 5, gold: ["retry logic rewritten"]),

    // 26. GUARD — no anchor, no literal hit, nothing to say. Returning nothing is
    // the correct answer; a relaxed gate must not start inventing relevance.
    EvalCase(name: "no-anchor-no-flood", events: [
        ev(5, "URGENT decided to drop the feature"),
        ev(6, "quarterly planning notes"),
    ], query: "graphql", k: 3, gold: []),

    // 27. GUARD — when literal hits DO exist, the anchor's other salient notes
    // must not be padded in beside them.
    EvalCase(name: "no-dilution-when-lexical-hits", events: [
        ev(5, "the export csv job times out on big accounts", title: "Export.swift — PantryApp"),
        ev(6, "remember to renew the domain", title: "Notes — PantryApp"),
    ], query: "export csv", anchor: "PantryApp", k: 3,
       gold: ["the export csv job times out on big accounts"]),

    // 28. GUARD — a stale cross-entity hit must not outrank a live in-anchor one.
    EvalCase(name: "anchor-beats-stale-cross-entity", events: [
        ev(5, "redis pool exhausted under load", title: "Cache.swift — Mull"),
        ev(10080, "redis pool exhausted last quarter too", title: "Old.swift — LegacyApp"),
    ], query: "redis pool", anchor: "Mull", k: 1,
       gold: ["redis pool exhausted under load"]),

    // ---- 29-32: shapes taken from a REAL log, not invented ----
    //
    // Cases 1-28 were written by the person who wrote the ranker, after they
    // wrote it, and the ranker scores 1.000 on all of them. The four below came
    // the other way round: eval/real/ was pointed at four windows of an actual
    // mull database (1,493 events, 2026-06-10 and 2026-08-08), gold was labelled
    // by hand BEFORE running anything, and mull scored F1 0.220. These are the
    // failures that produced that number, transcribed to neutral content so they
    // can ship and run in CI — the corpus stays on the machine it came from.
    //
    // They are `.gap`: known-failing, and the list of what is still broken. A gap
    // that starts passing should be moved up into the guardrails above.

    // 29. GAP — capture polls the window title every 5 seconds, so one session
    // lands in the log a dozen times over. On the real window six of eight slots
    // went to six byte-identical copies of one title, and the two clipboard notes
    // that held the actual answer were never reached: they share no words with
    // the query, so the lexical gate drops them. There is no dedup anywhere in
    // Selection — `scored` can and does return the same string N times.
    EvalCase(name: "duplicate-flood", events: [
        ev(3, "open source feasibility check — mull", title: "Code — Mull", kind: .screenText),
        ev(4, "open source feasibility check — mull", title: "Code — Mull", kind: .screenText),
        ev(5, "open source feasibility check — mull", title: "Code — Mull", kind: .screenText),
        ev(6, "open source feasibility check — mull", title: "Code — Mull", kind: .screenText),
        ev(7, "open source feasibility check — mull", title: "Code — Mull", kind: .screenText),
        ev(8, "open source feasibility check — mull", title: "Code — Mull", kind: .screenText),
        ev(9,  "blocker 2: a clean clone cannot build — project.yml configFiles", title: "Notes — Mull"),
        ev(10, "blocker 4: the commit email address", title: "Notes — Mull"),
    ], query: "open source", anchor: "Mull", k: 8, gold: [
        "open source feasibility check — mull",
        "blocker 2: a clean clone cannot build — project.yml configFiles",
        "blocker 4: the commit email address",
    ], role: .gap),

    // 30. GAP — mull records the clipboard, so a question the user pasted into an
    // agent IS an event. It matches its own query perfectly and ranks first: the
    // agent is handed its own question back as context. This one cannot be
    // imagined into a synthetic corpus — nobody writes their own query into the
    // events list — and it appeared the first time the ranker met a real log.
    EvalCase(name: "query-echo", events: [
        ev(1, "What was I mainly working on this week?"),
        ev(40, "shipped the retry rewrite and closed the flaky test", title: "Notes — Mull"),
        ev(55, "decided to drop the second calendar column", title: "Notes — Mull"),
    ], query: "What was I mainly working on this week?", anchor: "Mull", k: 3, gold: [
        "shipped the retry rewrite and closed the flaky test",
        "decided to drop the second calendar column",
    ], role: .gap),

    // 31. GAP — the same thought copied three times across fifteen minutes, each
    // version longer than the last, which is simply how a person drafts. All
    // three rank; the complete one came third. Two of three slots bought nothing,
    // because nothing checks whether one result is contained in another.
    EvalCase(name: "subsumption", events: [
        ev(20, "stepping into the judgment layer"),
        ev(15, "stepping into the judgment layer is probably necessary in the end, but what this product"),
        ev(3,  "stepping into the judgment layer is probably necessary in the end, but what this product actually does is hard to see, and stepping in risks losing trust through off-target suggestions"),
    ], query: "judgment layer", anchor: "Dream", k: 3, gold: [
        "stepping into the judgment layer is probably necessary in the end, but what this product actually does is hard to see, and stepping in risks losing trust through off-target suggestions",
    ], role: .gap),

    // 32. GAP — `Entity.from` reads the trailing segment of a window title, so a
    // browser tab gets filed under the BROWSER PROFILE, not the project. On the
    // real window the one page that actually held mull's icon drafts was filed
    // under the Firefox profile name, scored entityMatch 0 against the Mull
    // anchor, and lost every slot to repeats of an in-anchor session title —
    // while another project's icon work leaked in on lexical overlap alone.
    EvalCase(name: "entity-junk-profile", events: [
        ev(5, "app icon design work — mull", title: "Code — Mull", kind: .screenText),
        ev(6, "app icon design work — mull", title: "Code — Mull", kind: .screenText),
        ev(7, "app icon design work — mull", title: "Code — Mull", kind: .screenText),
        ev(8, "mull icon draft: tree rings — Default Profile", title: "Firefox — Default Profile", kind: .screenText),
        ev(9, "app icon prototype — OtherApp", title: "Code — OtherApp", kind: .screenText),
    ], query: "icon draft", anchor: "Mull", k: 3,
       gold: ["mull icon draft: tree rings — Default Profile"], role: .gap),
]

// The strategies (mull / full-context / recency-only / entity-only) and the
// metrics live in eval/EvalCore.swift — shared with the real-log harness.

extension EvalCase {
    var need: Need {
        Need(events: events, query: query, entity: entity, anchor: anchor,
             type: type, k: k, now: now, since: 7 * 86_400)
    }
}

// MARK: - Convergence: does correcting mull improve it?
//
// The 28 cases above measure whether the ranker is *right*. They cannot measure
// the correction loop, because mull already scores 1.000 on them — there is no
// headroom for a human verdict to fill.
//
// These cases are built so the heuristics get them WRONG. Each is a pair of
// same-project notes where the one that matters is older, so recency points at
// the wrong one and nothing else separates them. Precision@1 starts at 0.00 —
// as it should. Only a person can say which of two notes about the same thing
// mattered.
//
// That is the honest shape of the claim. This is a MECHANISM demonstration —
// "a human verdict resolves what the heuristics cannot" — not a claim about how
// much value real corrections carry. That needs real corrections, and N=1 of
// them (STRATEGY, the 撤回基準).

struct TiedPair {
    let name: String
    let query: String
    let wanted: String    // what the human keeps
    let unwanted: String  // what the human deletes
    /// The unwanted item is the NEWER one. Every heuristic mull has — recency,
    /// entity, salience, lexical overlap, mode — either ties or actively favours
    /// it. A ranker with no human verdict gets this wrong, and should: nothing in
    /// the index says which of two same-day notes about the same project you
    /// cared about. That is exactly the gap a correction fills.
    var events: [RecordingEvent] {
        [ev(120, wanted,   title: "Notes — Mull", kind: .clipboard),
         ev(5,   unwanted, title: "Notes — Mull", kind: .clipboard)]
    }
}

let tiedPairs: [TiedPair] = [
    TiedPair(name: "onboarding",  query: "onboarding",
             wanted: "onboarding copy needs the pricing line",
             unwanted: "onboarding copy looked fine to me"),
    TiedPair(name: "pricing",     query: "pricing",
             wanted: "pricing page conversion dropped after the change",
             unwanted: "pricing page colours were updated"),
    TiedPair(name: "lot-size",    query: "ロット",
             wanted: "ロットを落としたのはドローダウンが2%を超えたから",
             unwanted: "ロットの計算式をメモしておく"),
    TiedPair(name: "contract",    query: "契約",
             wanted: "契約の第3条は先方が折れないので飲む",
             unwanted: "契約のテンプレートを保存した"),
]

/// One correction: the human kept `wanted` and deleted `unwanted`.
func card(for p: TiedPair) -> CorrectionCard {
    CorrectionCard(path: "01_now/index.md", blockID: "note:\(p.name)", date: now,
                   kept: p.wanted, wouldWrite: p.wanted + "\n" + p.unwanted, context: nil)
}

/// Precision over every pair, when the first `k` have been corrected.
func convergence(afterCorrections k: Int) -> Double {
    let index = CorrectionIndex.fold(tiedPairs.prefix(k).map(card(for:)))
    var hits = 0
    for p in tiedPairs {
        let top = Selection.rank(events: p.events, query: p.query, entity: nil,
                                 anchor: "Mull", type: nil, now: now,
                                 since: 7 * 86_400, limit: 1,
                                 corrections: index).first?.text
        if top == p.wanted { hits += 1 }
    }
    return Double(hits) / Double(tiedPairs.count)
}

func printConvergence() {
    print("\nconvergence — precision@1 on \(tiedPairs.count) ties the ranker cannot break")
    print(String(repeating: "-", count: 68))
    var line = ""
    for k in 0...tiedPairs.count {
        let v = convergence(afterCorrections: k)
        print("  corrections applied: \(k)   precision@1: \(String(format: "%.2f", v))")
        line += k == 0 ? "" : " → "
        line += String(format: "%.2f", v)
    }
    print("  curve: " + line)
    let start = convergence(afterCorrections: 0)
    let end = convergence(afterCorrections: tiedPairs.count)
    print(String(repeating: "-", count: 68))
    print(end > start
          ? "  corrections improve the ranking (+\(String(format: "%.2f", end - start)))"
          : "  ⚠ corrections did NOT improve the ranking — the loop is not connected")
}

// MARK: - Run

@main
struct SelectionEval {
    static func main() {
        // Per-case detail for mull only; baselines are summarised below.
        print("case                              P     R    MRR   retrieved")
        print(String(repeating: "-", count: 68))
        var openGaps: [String] = []
        var regressions: [String] = []
        for c in cases {
            let retrieved = retrieve(.mull, c.need)
            let s = score(retrieved: retrieved, gold: c.gold)
            let hits = Set(retrieved).intersection(c.gold).count
            let perfect = s.p == 1 && s.r == 1
            if !perfect { (c.role == .gap ? { openGaps.append($0) } : { regressions.append($0) })(c.name) }
            let flag = perfect ? "" : (c.role == .gap ? "   <GAP" : "   <REGRESSION")
            // %-32@ does not pad on Darwin's String(format:) — pad by hand or the
            // whole table collapses into one ragged column.
            print(pad(c.name, 32) + String(format: "%.2f  %.2f  %.2f   %d/%d",
                                           s.p, s.r, s.mrr, hits, retrieved.count) + flag)
        }

        print(String(repeating: "-", count: 68))
        print(String(format: "n=%d cases  (%d gap, %d guard)", cases.count,
                     cases.filter { $0.role == .gap }.count,
                     cases.filter { $0.role == .guardrail }.count))

        // Strategy comparison — the number that actually decides anything.
        let beatsBaselines = printStrategyTable(needs: cases.map { ($0.need, $0.gold) })

        // Gaps are SUPPOSED to fail — that is the difference between the two
        // roles, and a harness with no open gaps has stopped pointing at anything.
        // They are printed, not gated; a guardrail failure is the thing that has
        // to stop a push.
        if !openGaps.isEmpty {
            print("\nopen gaps (known-failing, not gated): \(openGaps.joined(separator: ", "))")
        }
        if !regressions.isEmpty {
            print("\nREGRESSIONS: \(regressions.joined(separator: ", "))")
        }

        // Release gate (SELECTION-LAYER §6.1). Beating the baselines on F1 is necessary
        // but far too slack on its own — mull clears them by a wide margin, so
        // that test alone would stay green through a serious regression. The
        // second clause is the specific failure this harness was extended to
        // catch: a case where mull holds the answer and returns nothing, which is
        // what "No relevant activity" looked like from the agent's side. Scoped to
        // guardrails: returning nothing IS the documented behaviour of some gaps.
        let silentMisses = cases.filter { c in
            c.role == .guardrail && !c.gold.isEmpty
                && score(retrieved: retrieve(.mull, c.need), gold: c.gold).r == 0
        }
        if !silentMisses.isEmpty {
            print("\nanswered nothing while holding the answer: \(silentMisses.map(\.name).joined(separator: ", "))")
        }
        let passed = beatsBaselines && silentMisses.isEmpty && regressions.isEmpty
        printConvergence()
        print(passed ? "\nGATE: pass" : "\nGATE: fail")
        exit(passed ? 0 : 1)
    }
}
