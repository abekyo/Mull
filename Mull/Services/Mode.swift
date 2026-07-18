import Foundation

/// The MODE axis of the map (MAP-ARCHITECTURE.md): *how* a moment is engaged
/// with, not *what* it is about. This is the dimension that lets the map keep
/// everything and still mean it — a watched FX video is `consume`/`research`, a
/// dictated musing is `think`; both are KEPT and placed, never deleted.
///
/// Rule-based and cheap, computed at capture next to entity/contentType/salience
/// (see `Signal`) and stored on the row; recomputable for pre-migration rows via
/// `RecordingEvent.resolvedMode`. As models improve, swap the classifier and
/// regenerate the map — the territory (`_raw`) never changes.
enum Mode: String, Codable, CaseIterable {
    case produce        // you authored it — code, prose, design
    case consume        // input you received — articles, video, audio
    case decide         // a choice / commitment was made
    case think          // musing, dictation, planning out loud
    case research       // purposeful consume — gathering toward a goal
    case communicate    // message, email, post, meeting

    /// Classify one captured signal from app + event kind + text shape, plus the
    /// content kind when known. Co-occurrence lifts a bare `consume` to `research`
    /// (e.g. a how-to video watched while working), so consumption isn't dropped —
    /// it's labelled by intent.
    static func classify(text: String,
                         eventType: RecordingEvent.EventType,
                         appName: String?,
                         windowTitle: String?,
                         contentType: String?) -> Mode {
        let app = (appName ?? "").lowercased()
        let title = (windowTitle ?? "").lowercased()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if isCommsApp(app) { return .communicate }

        let consuming = isBrowser(app) || title.contains("youtube")
            || title.contains("audio playing") || app.contains("music")
            || app.contains("podcast") || app.contains("tv")
        if consuming {
            return looksLikeResearch(title: title, text: t.lowercased()) ? .research : .consume
        }

        if eventType == .clipboard || eventType == .keystroke, looksLikeDecision(t) {
            return .decide
        }
        if looksLikeThinking(t) { return .think }
        if isMakerApp(app) { return .produce }

        switch contentType {
        case "code", "note", "file": return .produce
        // "document" reaching here means a body snapshot outside maker apps /
        // browsers (Preview, Acrobat, …) — that's reading, not making.
        case "web", "document": return .consume
        default: return .think
        }
    }

    // MARK: - Heuristics (the regenerable part — swap for an LLM pass later)

    private static func isBrowser(_ app: String) -> Bool {
        ["safari", "chrome", "arc", "brave", "edge", "firefox", "orion"].contains { app.contains($0) }
    }
    private static func isCommsApp(_ app: String) -> Bool {
        // Exact / clear-substring matches only — never a 1-char token like "x"
        // that would swallow "Xcode".
        ["slack", "discord", "messages", "telegram", "zoom", "teams",
         "gmail", "outlook"].contains { app.contains($0) } || app == "mail"
    }
    private static func isMakerApp(_ app: String) -> Bool {
        ["code", "cursor", "xcode", "vim", "obsidian", "bear", "notion", "notes",
         "figma", "sketch", "photoshop", "illustrator", "terminal", "iterm",
         "warp", "ghostty"].contains { app.contains($0) }
    }
    private static func looksLikeResearch(title: String, text: String) -> Bool {
        let needles = ["how to", "tutorial", "guide", "docs", "documentation",
                       "stack overflow", "github", "search", "comparison",
                       "やり方", "とは", "解説", "比較", "手法", "戦略"]
        return needles.contains { title.contains($0) || text.contains($0) }
    }
    private static func looksLikeDecision(_ t: String) -> Bool {
        let lower = t.lowercased()
        let en = ["decided", "let's go with", "we'll use", "going with",
                  "rejected", "instead of"]
        let ja = ["の方がいい", "にする", "やめる", "採用", "却下", "方針"]
        return en.contains { lower.contains($0) } || ja.contains { t.contains($0) }
    }
    private static func looksLikeThinking(_ t: String) -> Bool {
        // Long, sentence-like prose (often dictation) rather than a title/snippet.
        guard t.count >= 40 else { return false }
        let lower = t.lowercased()
        return t.contains("。") || t.contains("、")
            || lower.contains(" think ") || lower.contains(" maybe ")
            || t.contains("かもしれない") || t.contains("だと思う")
    }
}

extension RecordingEvent {
    /// The stored mode, or a freshly computed one for rows captured before the
    /// `mode` column existed (the territory-pointing, regenerable contract).
    var resolvedMode: Mode {
        if let raw = mode, let parsed = Mode(rawValue: raw) { return parsed }
        return Mode.classify(text: textContent ?? "", eventType: eventType,
                             appName: appName, windowTitle: windowTitle,
                             contentType: contentType)
    }
}
