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

// MARK: - Shim (matches the real RecordingEvent's shape; no GRDB)

struct RecordingEvent {
    enum EventType { case screenText, keystroke, clipboard, appSwitch, audio, windowBody }
    // Back-pointer into _raw. Left nil: these cases are synthetic, and the eval
    // scores by text, not by identity.
    var id: Int64? = nil
    var timestamp: Date
    var eventType: EventType
    var appName: String?
    var windowTitle: String?
    var textContent: String?
    // #4 capture-time columns. Left nil here so the eval exercises Selection's
    // recompute fallback (same path as pre-backfill rows).
    var entity: String? = nil
    var contentType: String? = nil
    var salience: Double? = nil
    // MODE axis. Left nil so the eval exercises Mode's recompute path, the same
    // way entity/contentType/salience do.
    var mode: String? = nil
}

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
]

// MARK: - Strategies
//
// A benchmark with one competitor measures nothing: whatever mull scores, there
// is no number it had to beat. These are the alternatives mull's whole premise
// is an argument against (README, "Does context actually help?"). Selection has
// to beat all three on the same cases or the premise is unsupported.

enum Strategy: String, CaseIterable {
    case mull           = "mull"
    case fullContext    = "full-context"   // dump everything — the ETH paper's subject
    case recencyOnly    = "recency-only"   // "just show me the last N things"
    case entityOnly     = "entity-only"    // "just show me this project"
}

/// Selection truncates and trims; baselines must be scored on the same strings
/// or the gold-set comparison silently misses.
private func normalized(_ e: RecordingEvent) -> String? {
    guard let t = e.textContent?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 2 else { return nil }
    return String(t.prefix(200))
}

func retrieve(_ s: Strategy, _ c: EvalCase) -> [String] {
    let newestFirst = c.events.sorted { $0.timestamp > $1.timestamp }
    switch s {
    case .mull:
        return Selection.rank(events: c.events, query: c.query,
                              entity: c.entity, anchor: c.anchor ?? c.entity,
                              type: c.type, now: now, since: 7 * 86_400, limit: c.k)
            .map(\.text)
    case .fullContext:
        // No ranking, no limit, no filtering — including none of mull's secret
        // and test-input exclusions. That is what "just give the model the
        // context" actually means, and its cost belongs in the comparison.
        return newestFirst.compactMap(normalized)
    case .recencyOnly:
        return newestFirst.prefix(c.k).compactMap(normalized)
    case .entityOnly:
        let scope = (c.entity ?? c.anchor)?.lowercased()
        return newestFirst
            .filter { e in
                guard let scope else { return true }
                return Entity.from(e.windowTitle ?? e.textContent ?? "")?.lowercased() == scope
            }
            .prefix(c.k).compactMap(normalized)
    }
}

// MARK: - Metrics

struct Score { var p = 0.0, r = 0.0, mrr = 0.0 }

func score(retrieved: [String], gold: Set<String>) -> Score {
    let hit = Set(retrieved).intersection(gold)
    // An empty gold set means "the right answer is silence". Returning nothing
    // then is a perfect score, not a zero — the old formula scored it 0 and would
    // have punished the ranker for being correctly quiet.
    if gold.isEmpty { return retrieved.isEmpty ? Score(p: 1, r: 1, mrr: 1) : Score(p: 0, r: 1, mrr: 0) }
    var rr = 0.0
    for (i, t) in retrieved.enumerated() where gold.contains(t) { rr = 1.0 / Double(i + 1); break }
    return Score(p: retrieved.isEmpty ? 0 : Double(hit.count) / Double(retrieved.count),
                 r: Double(hit.count) / Double(gold.count),
                 mrr: rr)
}

func f1(_ p: Double, _ r: Double) -> Double { (p + r) == 0 ? 0 : 2 * p * r / (p + r) }


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

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
}

// MARK: - Run

@main
struct SelectionEval {
    static func main() {
        let n = Double(cases.count)

        // Per-case detail for mull only; baselines are summarised below.
        print("case                              P     R    MRR   retrieved")
        print(String(repeating: "-", count: 68))
        var failures: [String] = []
        for c in cases {
            let retrieved = retrieve(.mull, c)
            let s = score(retrieved: retrieved, gold: c.gold)
            let hits = Set(retrieved).intersection(c.gold).count
            let perfect = s.p == 1 && s.r == 1
            if !perfect { failures.append(c.name) }
            let flag = perfect ? "" : (c.role == .gap ? "   <GAP" : "   <REGRESSION")
            // %-32@ does not pad on Darwin's String(format:) — pad by hand or the
            // whole table collapses into one ragged column.
            print(pad(c.name, 32) + String(format: "%.2f  %.2f  %.2f   %d/%d",
                                           s.p, s.r, s.mrr, hits, retrieved.count) + flag)
        }

        // Strategy comparison — the number that actually decides anything.
        var means: [Strategy: Score] = [:]
        for st in Strategy.allCases {
            var acc = Score()
            for c in cases {
                let s = score(retrieved: retrieve(st, c), gold: c.gold)
                acc.p += s.p; acc.r += s.r; acc.mrr += s.mrr
            }
            means[st] = Score(p: acc.p / n, r: acc.r / n, mrr: acc.mrr / n)
        }

        print(String(repeating: "-", count: 68))
        print(String(format: "n=%d cases  (%d gap, %d guard)", cases.count,
                     cases.filter { $0.role == .gap }.count,
                     cases.filter { $0.role == .guardrail }.count))
        print("")
        print("strategy        precision   recall      MRR       F1")
        print(String(repeating: "-", count: 68))
        for st in Strategy.allCases {
            let m = means[st]!
            print(pad(st.rawValue, 16) + String(format: "%.3f      %.3f     %.3f    %.3f",
                                                m.p, m.r, m.mrr, f1(m.p, m.r)))
        }
        print(String(repeating: "-", count: 68))

        // full-context always scores recall 1.000 by construction — it returns
        // everything, so it cannot miss. That is exactly why recall alone is not
        // the gate: the question is whether selecting beats dumping once the cost
        // of the dump is counted, which is what F1 does here.
        let mine = means[.mull]!
        let rivals = Strategy.allCases.filter { $0 != .mull }
        let beaten = rivals.filter { f1(mine.p, mine.r) > f1(means[$0]!.p, means[$0]!.r) }

        for st in rivals {
            let m = means[st]!
            let delta = f1(mine.p, mine.r) - f1(m.p, m.r)
            print("  vs " + pad(st.rawValue, 16) + String(format: "F1 %+.3f  ", delta)
                  + (delta > 0 ? "beat" : "NOT BEATEN"))
        }
        if !failures.isEmpty {
            print("\nnot perfect: \(failures.joined(separator: ", "))")
        }

        // Release gate (ROADMAP §1-B). Beating the baselines on F1 is necessary
        // but far too slack on its own — mull currently clears them by ~0.3, so
        // that test alone would stay green through a serious regression. The
        // second clause is the specific failure this harness was extended to
        // catch: a case where mull holds the answer and returns nothing, which is
        // what "No relevant activity" looked like from the agent's side.
        let silentMisses = cases.filter { c in
            !c.gold.isEmpty && score(retrieved: retrieve(.mull, c), gold: c.gold).r == 0
        }
        if !silentMisses.isEmpty {
            print("\nanswered nothing while holding the answer: \(silentMisses.map(\.name).joined(separator: ", "))")
        }
        let passed = beaten.count == rivals.count && mine.r >= 0.7 && silentMisses.isEmpty
        printConvergence()
        print(passed ? "\nGATE: pass" : "\nGATE: fail")
        exit(passed ? 0 : 1)
    }
}
