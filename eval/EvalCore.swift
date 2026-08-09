import Foundation

// Shared spine of both eval harnesses (SELECTION-LAYER.md §6).
//
//   eval/selection_eval.swift  — hand-written cases, ships in the repo, runs in CI
//   eval/real/real_eval.swift  — cases harvested from a real mull DB, never committed
//
// The two exist for opposite reasons: the synthetic set is a regression net whose
// cases were invented by the person who wrote the ranker, and the real set is the
// correction for exactly that — its distractors are whatever the machine actually
// recorded, not what the author thought to type. They MUST score identically, so
// the shim, the strategies and the metrics live here rather than being copied.
// Copying is how this harness rotted twice before (SELECTION-LAYER §6.4).

// MARK: - Shim (matches the real RecordingEvent's shape; no GRDB)

struct RecordingEvent {
    enum EventType: String {
        case screenText, keystroke, clipboard, appSwitch, audio, windowBody
    }
    // Back-pointer into _raw. Usually nil here: the synthetic cases are made up,
    // and both harnesses score by text, not by identity.
    var id: Int64? = nil
    var timestamp: Date
    var eventType: EventType
    var appName: String?
    var windowTitle: String?
    var textContent: String?
    // #4 capture-time columns. Nil exercises Selection's recompute fallback, the
    // same path pre-backfill rows take.
    var entity: String? = nil
    var contentType: String? = nil
    var salience: Double? = nil
    // MODE axis.
    var mode: String? = nil
}

// MARK: - Need
//
// One question, asked at one moment, against one set of events. Both harnesses
// reduce to this before scoring, so neither can accidentally hand Selection a
// different shape of request than the other.

struct Need {
    var events: [RecordingEvent]
    var query: String
    /// EXPLICIT scope: the caller named a project. A hard filter is correct.
    var entity: String? = nil
    /// IMPLICIT anchor: whatever the user had open, filled in by MCPServer. Ranks,
    /// never excludes.
    var anchor: String? = nil
    var type: String? = nil
    var k: Int = 8
    /// The moment the question was asked — NOT process start. Real cases carry
    /// real timestamps, so a fixed `now` is the difference between "recency" being
    /// meaningful and every event being two months stale.
    var now: Date
    var since: TimeInterval = 7 * 86_400

    /// What MCPServer actually passes: an explicit entity also acts as the anchor.
    var effectiveAnchor: String? { anchor ?? entity }
}

// MARK: - Strategies
//
// A benchmark with one competitor measures nothing: whatever mull scores, there
// is no number it had to beat. These are the alternatives mull's whole premise
// is an argument against (README, "Does context actually help?").

enum Strategy: String, CaseIterable {
    case mull           = "mull"
    case fullContext    = "full-context"   // dump everything — the ETH paper's subject
    case recencyOnly    = "recency-only"   // "just show me the last N things"
    case entityOnly     = "entity-only"    // "just show me this project"
}

/// Selection truncates and trims; baselines must be scored on the same strings
/// or the gold-set comparison silently misses.
func normalized(_ e: RecordingEvent) -> String? {
    guard let t = e.textContent?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 2 else { return nil }
    return String(t.prefix(200))
}

func retrieve(_ s: Strategy, _ n: Need) -> [String] {
    let newestFirst = n.events.sorted { $0.timestamp > $1.timestamp }
    switch s {
    case .mull:
        return Selection.rank(events: n.events, query: n.query,
                              entity: n.entity, anchor: n.effectiveAnchor,
                              type: n.type, now: n.now, since: n.since, limit: n.k)
            .map(\.text)
    case .fullContext:
        // No ranking, no limit, no filtering — including none of mull's secret
        // and test-input exclusions. That is what "just give the model the
        // context" actually means, and its cost belongs in the comparison.
        return newestFirst.compactMap(normalized)
    case .recencyOnly:
        return newestFirst.prefix(n.k).compactMap(normalized)
    case .entityOnly:
        let scope = n.effectiveAnchor?.lowercased()
        return newestFirst
            .filter { e in
                guard let scope else { return true }
                return Entity.from(e.windowTitle ?? e.textContent ?? "")?.lowercased() == scope
            }
            .prefix(n.k).compactMap(normalized)
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
    // `retrieved.count` is deliberately the raw count, duplicates included. Real
    // capture polls window titles every 5s, so the same string lands in the log a
    // dozen times; a ranker that spends six of eight slots on six copies of one
    // note HAS wasted six slots, and precision is where that shows up. The
    // synthetic corpus has no duplicates and so never exercised this.
    return Score(p: retrieved.isEmpty ? 0 : Double(hit.count) / Double(retrieved.count),
                 r: Double(hit.count) / Double(gold.count),
                 mrr: rr)
}

func f1(_ p: Double, _ r: Double) -> Double { (p + r) == 0 ? 0 : 2 * p * r / (p + r) }

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
}

/// The strategy comparison table both harnesses print.
func printStrategyTable(needs: [(Need, Set<String>)]) -> Bool {
    let n = Double(needs.count)
    var means: [Strategy: Score] = [:]
    for st in Strategy.allCases {
        var acc = Score()
        for (need, gold) in needs {
            let s = score(retrieved: retrieve(st, need), gold: gold)
            acc.p += s.p; acc.r += s.r; acc.mrr += s.mrr
        }
        means[st] = Score(p: acc.p / n, r: acc.r / n, mrr: acc.mrr / n)
    }

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
    // everything, so it cannot miss. That is exactly why recall alone is not the
    // gate: the question is whether selecting beats dumping once the cost of the
    // dump is counted, which is what F1 does here.
    let mine = means[.mull]!
    let rivals = Strategy.allCases.filter { $0 != .mull }
    var allBeaten = true
    for st in rivals {
        let delta = f1(mine.p, mine.r) - f1(means[st]!.p, means[st]!.r)
        if delta <= 0 { allBeaten = false }
        print("  vs " + pad(st.rawValue, 16) + String(format: "F1 %+.3f  ", delta)
              + (delta > 0 ? "beat" : "NOT BEATEN"))
    }
    return allBeaten && mine.r >= 0.7
}
