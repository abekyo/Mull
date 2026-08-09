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

    /// How much this engagement counts as **an act of yours** rather than ambient
    /// input. Feeds `Selection.rank` as a small ordering term.
    ///
    /// MAP-ARCHITECTURE calls MODE "一番効く" and says it is used for
    /// 「重み付け・選別・配置」, but until 2026-08-09 nothing in the selection path
    /// read it — the axis was computed, stored, and ignored. This is the weight
    /// that connects it.
    ///
    /// It orders; it never filters. Law 5 forbids destructive lenses, so a
    /// `consume` event is ranked lower, never dropped.
    var weight: Double {
        switch self {
        case .decide:      return 1.00   // a commitment — the scarcest signal
        case .produce:     return 0.80   // you authored it
        case .think:       return 0.60   // your reasoning, not yet a commitment
        case .research:    return 0.50   // consumption with intent behind it
        case .communicate: return 0.40   // authored, but for someone else
        case .consume:     return 0.20   // input you received
        }
    }

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

        // Read the media markers from the text as well as the title.
        //
        // Looking only at `windowTitle` meant an event whose text was
        // `… — Mull | https://www.youtube.com/watch?v=…` was labelled `produce`,
        // because the URL sits in the content and the title said nothing. The
        // label matters: `produce` means the user authored it, and everything
        // downstream (the pasted block, `Mode.weight`) trusts that. A video the
        // user watched was being reported as a thing the user made.
        let body = t.lowercased()
        let mediaMarker = ["youtube", "audio playing", "vimeo", "netflix", "spotify"]
        let consuming = isBrowser(app) || app.contains("music")
            || app.contains("podcast") || app.contains("tv")
            || mediaMarker.contains { title.contains($0) || body.contains($0) }
        if consuming {
            return looksLikeResearch(title: title, text: body) ? .research : .consume
        }

        // Vocabulary lives in `Signal` — the content axis and this axis must agree
        // on what a decision is, and two copies would drift (HARNESS.md 原理4).
        if eventType == .clipboard || eventType == .keystroke, Signal.looksLikeDecision(t) {
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
