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
        let t = text.lowercased()
        if t.contains("error") || t.contains("exception") || t.contains("failed")
            || t.contains("traceback") || t.contains("fatal") { return "error" }
        if t.contains("http://") || t.contains("https://") { return "web" }
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

    static func salience(for type: String) -> Double {
        switch type {
        case "error": return 0.95
        case "note", "decision": return 0.85
        case "file", "code": return 0.45
        case "web": return 0.30
        default: return 0.20
        }
    }
}
