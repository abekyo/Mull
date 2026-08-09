import Foundation

/// Capture-time enrichment: cheap rule-based classification of an event into a
/// content `kind` (note / error / code / web / file / activity) and a `salience`
/// score. Computed once when the event is recorded and stored on the row, so the
/// selection layer doesn't recompute it on every query (SELECTION-LAYER.md §1,
/// "派生計算 → 本索引"). Dependency-free so capture, retrieval, and the eval share it.
enum Signal {

    /// Both signals at once, for the capture path.
    static func classify(text: String, eventType: RecordingEvent.EventType, windowTitle: String?) -> (type: String, salience: Double) {
        let k = kind(text: text, eventType: eventType, windowTitle: windowTitle)
        return (k, salience(for: k))
    }

    static func kind(text: String, eventType: RecordingEvent.EventType, windowTitle: String?) -> String {
        // Window-body snapshots are ambient documents. Classify by channel, not
        // content: a long Japanese body would trip the "note" heuristic and any
        // README would trip "error"/"web" — wrong kind, inflated salience.
        if eventType == .windowBody { return "document" }
        let t = text.lowercased()
        if t.contains("error") || t.contains("exception") || t.contains("failed")
            || t.contains("traceback") || t.contains("fatal") { return "error" }
        if t.contains("http://") || t.contains("https://") { return "web" }
        // A commitment, not a reminder. `salience(for:)` has scored "decision" at
        // note tier since it was written, but `kind` never returned it — the branch
        // was unreachable and SELECTION-LAYER §1's "type(決定・エラー・…)" was
        // aspirational. Gated to authored channels so a window title containing
        // 「方針」 is not read as an act; placed above the note heuristic because
        // 「この方針でやってください」 is a decision phrased as an instruction.
        if eventType == .clipboard || eventType == .keystroke, looksLikeDecision(text) {
            return "decision"
        }
        // Self-authored note: a Japanese imperative / instruction to oneself.
        if t.contains("して") || t.contains("ください") || t.contains("したい") { return "note" }
        if t.contains("func ") || t.contains("{") || t.contains("=>") || t.contains("();") { return "code" }
        if eventType == .screenText {
            let title = windowTitle ?? text
            if title.contains(".") { return "file" }
        }
        if eventType == .clipboard { return "note" }
        return "activity"
    }

    /// "A choice was made." The single source for both axes: the content axis
    /// (`kind` → `"decision"`) and the MODE axis (`Mode.decide`), which used to
    /// hold a private copy of this vocabulary.
    ///
    /// Deliberately narrow and trade-neutral — no tool, framework, or domain
    /// words — so it fires the same for a position size, a contract clause, and a
    /// refactor. Growing this list with per-occupation vocabulary is the failure
    /// mode to avoid.
    static func looksLikeDecision(_ text: String) -> Bool {
        let lower = text.lowercased()
        let en = ["decided", "let's go with", "we'll use", "going with",
                  "rejected", "instead of"]
        let ja = ["の方がいい", "にする", "やめる", "採用", "却下", "方針"]
        return en.contains { lower.contains($0) } || ja.contains { text.contains($0) }
    }

    static func salience(for type: String) -> Double {
        switch type {
        case "error": return 0.95
        case "note", "decision": return 0.85
        case "file", "code": return 0.45
        case "document": return 0.35   // ambient body snapshot — useful, not an act
        case "web": return 0.30
        default: return 0.20
        }
    }
}
