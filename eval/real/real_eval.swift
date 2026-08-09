import Foundation

// The real-log half of the selection eval (SELECTION-LAYER.md §6.2).
//
// Same shim, same strategies, same metrics as eval/selection_eval.swift — that is
// what eval/EvalCore.swift is for. The only difference is where the events come
// from: `harvest.sh` cuts them out of an actual mull database instead of a Swift
// literal. That single change is the point of the file. The synthetic corpus has
// no duplicates, one Japanese case, one app name, and distractors that share no
// characters with the query. A real 45-minute window has all four the other way
// round, and the ranker has never been scored against one.
//
//   ./eval/real/harvest.sh --at ... --name ...   # cut a window, label gold BY HAND
//   ./eval/real/run.sh                           # then score it
//
// Cases live in eval/real/cases/*.json and are gitignored: they are raw keystrokes
// and clipboard contents. Nothing here is committed except the tooling. There is
// no GATE — this harness reports, it does not gate CI, because CI has no database.

// MARK: - On-disk case

struct RealCase: Decodable {
    struct Event: Decodable {
        let id: Int64?
        let ts: String
        let eventType: String
        let app: String?
        let title: String?
        let entity: String?
        let contentType: String?
        let salience: Double?
        let mode: String?
        let text: String?
    }
    let name: String
    let query: String
    var entity: String? = nil
    var anchor: String? = nil
    var type: String? = nil
    var k: Int = 8
    /// The moment the question is asked, in the DB's own format.
    let now: String
    /// Event ids that SHOULD have surfaced. Ids, not strings: real text is long,
    /// Japanese, and frequently duplicated, and hand-copying it into a gold list
    /// is both miserable and a source of silent mismatches.
    let gold: [Int64]
    let events: [Event]
    /// Free-text note about what the moment was. Optional.
    var note: String? = nil
}

/// GRDB writes `2026-08-08 15:10:42.188`; sqlite's `datetime()` drops the
/// fraction. Accept both, or half the harvested rows silently vanish.
func parseDBDate(_ s: String) -> Date? {
    let fmts = ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"]
    for f in fmts {
        let df = DateFormatter()
        df.dateFormat = f
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        if let d = df.date(from: s) { return d }
    }
    return nil
}

extension RealCase {
    func build() -> (Need, Set<String>, [Int64: String])? {
        guard let nowDate = parseDBDate(now) else {
            FileHandle.standardError.write(Data("\(name): unparseable now: \(now)\n".utf8))
            return nil
        }
        var byID: [Int64: String] = [:]
        let events: [RecordingEvent] = events.compactMap { e in
            guard let ts = parseDBDate(e.ts) else { return nil }
            let ev = RecordingEvent(
                id: e.id,
                timestamp: ts,
                eventType: RecordingEvent.EventType(rawValue: e.eventType) ?? .screenText,
                appName: e.app, windowTitle: e.title, textContent: e.text,
                entity: e.entity, contentType: e.contentType,
                salience: e.salience, mode: e.mode)
            if let id = e.id, let n = normalized(ev) { byID[id] = n }
            return ev
        }
        // Gold is ids; scoring is by text (Selection returns text). Resolve here,
        // and complain loudly about ids that are not in the window — a typo'd gold
        // id would otherwise just look like a ranker miss.
        var goldTexts = Set<String>()
        for id in gold {
            if let t = byID[id] { goldTexts.insert(t) }
            else { FileHandle.standardError.write(Data("\(name): gold id \(id) is not in the window\n".utf8)) }
        }
        let need = Need(events: events, query: query, entity: entity, anchor: anchor,
                        type: type, k: k, now: nowDate, since: 7 * 86_400)
        return (need, goldTexts, byID)
    }
}

// MARK: - Run

func short(_ s: String, _ n: Int) -> String {
    let one = s.replacingOccurrences(of: "\n", with: " ")
    return one.count <= n ? one : String(one.prefix(n)) + "…"
}

@main
struct RealEval {
    static func main() {
        let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                      ? CommandLine.arguments[1]
                      : FileManager.default.currentDirectoryPath + "/eval/real/cases")

        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
              !files.isEmpty else {
            print("no cases in \(dir.path)")
            print("harvest one:  ./eval/real/harvest.sh --at \"YYYY-MM-DD HH:MM:SS\" --name mycase --anchor MyProject --query \"...\"")
            exit(0)
        }

        var needs: [(Need, Set<String>)] = []
        var rows: [(String, Score, Int, Int, Int, Int)] = []   // name, score, hits, retrieved, gold, events
        var detail: [(String, [String], Set<String>)] = []

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let rc = try? JSONDecoder().decode(RealCase.self, from: data),
                  let (need, gold, _) = rc.build() else {
                print("skipped (unreadable): \(file.lastPathComponent)")
                continue
            }
            let retrieved = retrieve(.mull, need)
            let s = score(retrieved: retrieved, gold: gold)
            needs.append((need, gold))
            rows.append((rc.name, s, Set(retrieved).intersection(gold).count, retrieved.count, gold.count, need.events.count))
            detail.append((rc.name, retrieved, gold))
        }

        print("case                              P     R    MRR   hit/ret  gold  events")
        print(String(repeating: "-", count: 68))
        for (name, s, hits, ret, gold, evs) in rows {
            print(pad(short(name, 30), 32) + String(format: "%.2f  %.2f  %.2f   %d/%d      %d     %d",
                                                    s.p, s.r, s.mrr, hits, ret, gold, evs))
        }
        print(String(repeating: "-", count: 68))
        print("n=\(rows.count) real cases, \(needs.reduce(0) { $0 + $1.0.events.count }) real events")

        _ = printStrategyTable(needs: needs)

        // What mull actually returned, per case. On real data the interesting part
        // is never the number — it is which six near-identical window titles ate
        // the slots.
        print("\n" + String(repeating: "=", count: 68))
        for (name, retrieved, gold) in detail {
            print("\n▼ \(name)")
            if retrieved.isEmpty { print("   (returned nothing)") }
            for (i, t) in retrieved.enumerated() {
                print("   \(gold.contains(t) ? "✓" : " ") \(i + 1). \(short(t, 84))")
            }
            let missed = gold.subtracting(Set(retrieved))
            for t in missed.sorted() { print("   ✗ MISSED  \(short(t, 84))") }
        }
    }
}
