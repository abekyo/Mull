import Foundation

// Standalone evaluation harness for the selection layer (SELECTION-LAYER.md §6).
// Measures precision / recall / MRR of `Selection.rank` over labeled (need →
// ideal-slice) cases, so changes to the ranker can be judged, not guessed.
//
// Run:
//   swiftc -o /tmp/seleval \
//     Mull/Core/ProjectNames.swift Mull/Core/Entity.swift \
//     Mull/Services/Signal.swift Mull/Services/Selection.swift \
//     Mull/Services/TestInput.swift Mull/Services/SensitiveText.swift \
//     eval/selection_eval.swift && /tmp/seleval
//
// Compiles with a GRDB-free RecordingEvent shim (same shape Selection uses), so
// it runs in seconds without the app/host-test. Lives outside the Xcode targets.

// MARK: - Shim (matches the real RecordingEvent's shape; no GRDB)

struct RecordingEvent {
    enum EventType { case screenText, keystroke, clipboard, appSwitch, audio, windowBody }
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
    var entity: String? = nil
    var type: String? = nil
    var k: Int = 8
    let gold: Set<String>   // event texts that SHOULD surface
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
]

// MARK: - Run

@main
struct SelectionEval {
    static func main() {
        var sumP = 0.0, sumR = 0.0, sumMRR = 0.0
        print("case                          P     R    MRR   retrieved")
        print(String(repeating: "-", count: 64))
        for c in cases {
            let results = Selection.rank(events: c.events, query: c.query, entity: c.entity,
                                         type: c.type, now: now, since: 7 * 86_400, limit: c.k)
            let retrieved = results.map(\.text)
            let hit = Set(retrieved).intersection(c.gold)
            let precision = retrieved.isEmpty ? 0 : Double(hit.count) / Double(retrieved.count)
            let recall = c.gold.isEmpty ? 1 : Double(hit.count) / Double(c.gold.count)
            var rr = 0.0
            for (i, t) in retrieved.enumerated() where c.gold.contains(t) { rr = 1.0 / Double(i + 1); break }
            sumP += precision; sumR += recall; sumMRR += rr
            let flag = (recall < 1.0 || precision < 1.0) ? "  <" : ""
            print(String(format: "%-28@ %.2f  %.2f  %.2f   %d/%d%@",
                         c.name as NSString, precision, recall, rr, hit.count, retrieved.count, flag as NSString))
        }
        let n = Double(cases.count)
        print(String(repeating: "-", count: 64))
        print(String(format: "MEAN  precision=%.3f  recall=%.3f  MRR=%.3f  (n=%d)",
                     sumP / n, sumR / n, sumMRR / n, cases.count))

        // Diagnostic floor: fail if recall collapses. Precision is expected to be
        // imperfect at this baseline (no lexical gate yet) — the harness exists to
        // show exactly that, and to measure the next tuning step.
        exit(sumR / n >= 0.7 ? 0 : 1)
    }
}
