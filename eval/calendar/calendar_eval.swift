import Foundation

// Scoring the text the calendar mirror would write into somebody's real day, against
// a real day (CLAUDE.md §0 場面 E, §4).
//
// The ranker has had two harnesses since 2026-08: a synthetic corpus and, because the
// synthetic one flatters the ranker that was written to it, a real-log one. The
// mirror's titles had neither. They are window titles, they go to a calendar that may
// sync to an account, and until this file the only measurement of them was a person
// reading their own week and being disappointed.
//
// What it reports, per day:
//
//   named       the block's own label was fit to write, whole
//   shortened   its front was, so the event keeps the project and drops the rest
//   fell back   none of it was, so the event says "Xcode" instead
//   too short   under CalendarMirror.minimumDuration, not written at all
//   clipboard   the label was copied text, refused on provenance (never counted named)
//
// and then the refusals themselves, in full, because the aggregate is the thing you
// track and the list is the thing you learn from. A rule that starts refusing good
// titles shows up here as a falling `named` and a list of names you recognise.
//
// There is no gold labelling and no gate. `isPresentable` is a rule over shape, so
// "was this refusal right?" is a question a person answers by reading the list — which
// is exactly what the list is for. The pass/fail specification lives in
// Tests/CalendarMirrorTests.swift; this is the measurement.
//
//   ./eval/calendar/harvest.sh --on 2026-08-13
//   ./eval/calendar/run.sh

// MARK: - Shim
//
// `EventSegment` names `RecordingEvent.EventType`, and the real `RecordingEvent` is a
// GRDB record. Same trick as eval/EvalCore.swift, kept local because this harness
// needs one nested enum and none of EvalCore's ranking machinery.

struct RecordingEvent {
    enum EventType: String {
        case screenText, keystroke, clipboard, appSwitch, audio, windowBody
    }
}

// MARK: - On-disk case

struct DayCase: Decodable {
    struct Event: Decodable {
        let ts: String
        let eventType: String
        let app: String
        let title: String
        let text: String
    }
    let name: String
    let day: String
    let events: [Event]
}

/// GRDB writes `2026-08-08 15:10:42.188`; sqlite's `datetime()` drops the fraction.
/// Accept both, or half the harvested rows silently vanish.
func parseDBDate(_ s: String) -> Date? {
    for pattern in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"] {
        let df = DateFormatter()
        df.dateFormat = pattern
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        if let d = df.date(from: s) { return d }
    }
    return nil
}

extension DayCase {
    /// The same segments `TimeBlockEngine.generateBlocks` builds, minus the noise-app
    /// filter — `AnalyticsEngine` is not compiled here, and a noise app that survives
    /// makes the score pessimistic rather than flattering, which is the safe direction.
    func segments() -> [EventSegment] {
        events.compactMap { event in
            guard let ts = parseDBDate(event.ts),
                  let type = RecordingEvent.EventType(rawValue: event.eventType) else { return nil }
            return EventSegment(timestamp: ts,
                                app: event.app,
                                windowTitle: event.title.isEmpty ? event.text : event.title,
                                eventType: type,
                                text: event.text)
        }
    }
}

// MARK: - One day, scored

struct Refusal {
    let reason: String
    let title: String
    let app: String
    let minutes: Int
}

struct DayScore {
    let name: String
    let quality: CalendarMirror.Quality
    let written: [(title: String, minutes: Int)]
    let refusals: [Refusal]
}

func score(_ dayCase: DayCase, resumeGap: TimeInterval) -> DayScore {
    let blocks = BlockSegmenter.blocks(from: dayCase.segments(), resumeGap: resumeGap)

    // `now` is the far end of the day, so every block in a harvested day counts as
    // settled. Scoring "would this have been written eventually" rather than "was it
    // written by 4pm" is the question the titles are the answer to.
    let end = (blocks.map(\.end).max() ?? Date()).addingTimeInterval(86_400)
    let plan = CalendarMirror.plan(blocks: blocks, existing: [], written: [], tombstoned: [],
                                   now: end, resumeGap: resumeGap)

    var refusals: [Refusal] = []
    for block in blocks where CalendarMirror.isSettled(end: block.end, now: end, resumeGap: resumeGap) {
        let minutes = Int(block.duration / 60)
        guard block.duration >= CalendarMirror.minimumDuration else {
            refusals.append(Refusal(reason: "too short", title: block.label.isEmpty ? block.app : block.label,
                                    app: block.app, minutes: minutes))
            continue
        }
        let (written, naming) = CalendarMirror.title(for: block)
        switch naming {
        case .named:
            continue
        case .shortened:
            // Not a refusal so much as a haircut, and it is listed for the same reason
            // the refusals are: this is where a rule that starts trimming good titles
            // becomes visible, and the aggregate cannot show it.
            refusals.append(Refusal(reason: "shortened to “\(written)”", title: block.label,
                                    app: block.app, minutes: minutes))
        case .fellBack:
            let reason: String
            if block.label.isEmpty || block.label == block.app {
                reason = "no title"
            } else if block.labelFromClipboard {
                reason = "clipboard"
            } else {
                reason = "not a name"
            }
            refusals.append(Refusal(reason: reason, title: block.label, app: block.app, minutes: minutes))
        }
    }

    let written = plan.create.map { (title: $0.title, minutes: Int($0.end.timeIntervalSince($0.start) / 60)) }
    return DayScore(name: dayCase.name, quality: plan.quality, written: written, refusals: refusals)
}

// MARK: - Report

func pct(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }

func report(_ s: DayScore) {
    let q = s.quality
    print("── \(s.name)")
    print("   named       \(q.named)")
    print("   shortened   \(q.shortened)")
    print("   fell back   \(q.fellBack)")
    print("   too short   \(q.tooShort)")
    if let fraction = q.namedFraction {
        print("   NAMED       \(pct(fraction))  (\(q.named + q.shortened)/\(q.considered) events mull could name)")
    } else {
        print("   NAMED       —  (nothing long enough to write)")
    }

    // Every row, not the top twenty. NAMED counts how often the rule found a name and
    // cannot count whether the name was right — a gate that let junk through would
    // raise it. Correctness is read here, by a person, so truncating this list is
    // truncating the only measurement of it there is.
    if !s.written.isEmpty {
        print("\n   what would land on the calendar (read these — NAMED cannot tell you if they are right):")
        for row in s.written.sorted(by: { $0.minutes > $1.minutes }) {
            print(String(format: "     %4dm  %@", row.minutes, row.title))
        }
    }

    let refused = s.refusals.filter { $0.reason != "too short" }
    if !refused.isEmpty {
        print("\n   refused or trimmed (a rule that starts eating good names shows up here):")
        for r in refused.sorted(by: { $0.minutes > $1.minutes }) {
            print(String(format: "     %4dm  [%@] %@  →  %@", r.minutes, r.reason, r.title, r.app))
        }
    }
    print("")
}

// MARK: - Main

@main
struct CalendarEval {
    static func main() {

    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let casesDir = here.appendingPathComponent("cases")

    let files = (try? FileManager.default.contentsOfDirectory(at: casesDir,
                                                              includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

    guard !files.isEmpty else {
        FileHandle.standardError.write(Data("""
            No cases in eval/calendar/cases/.

                ./eval/calendar/harvest.sh --on YYYY-MM-DD

            cuts a day out of your own database. It is gitignored, and it is your window
            titles and clipboard, so it stays that way.

            """.utf8))
        exit(1)
    }

    // Whatever the reader's own segmentation setting is would make two runs on two Macs
    // incomparable, so the harness pins the default and says so.
    let resumeGap = BlockSegmenter.defaultResumeGap
    print("Calendar title quality · resumeGap \(Int(resumeGap))s · floor \(Int(CalendarMirror.minimumDuration / 60))m\n")

    var totalNamed = 0, totalShortened = 0, totalConsidered = 0, totalShort = 0
    for file in files {
        guard let data = try? Data(contentsOf: file),
              let dayCase = try? JSONDecoder().decode(DayCase.self, from: data) else {
            FileHandle.standardError.write(Data("skipped (unreadable): \(file.lastPathComponent)\n".utf8))
            continue
        }
        let scored = score(dayCase, resumeGap: resumeGap)
        report(scored)
        totalNamed += scored.quality.named
        totalShortened += scored.quality.shortened
        totalConsidered += scored.quality.considered
        totalShort += scored.quality.tooShort
    }

    guard totalConsidered > 0 else {
        print("Nothing long enough to write in any harvested day.")
        exit(0)
    }
    let readable = totalNamed + totalShortened
    print("═══ \(files.count) day(s): NAMED \(pct(Double(readable) / Double(totalConsidered)))"
          + "  (\(readable)/\(totalConsidered), of which \(totalShortened) shortened),"
          + " \(totalShort) too short")
    }
}
