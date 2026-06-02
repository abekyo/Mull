import Foundation

/// The selection layer's retrieval core (SELECTION-LAYER.md §4): given a need
/// (query + facets, anchored on the current state), return the few most relevant
/// events — not a raw dump, not a lossy summary. Hybrid fusion of recency,
/// entity match, lexical overlap, and salience. No embeddings yet (start simple,
/// add later). Pure given a fetched event list, so it's testable.
struct Selection {

    struct Result {
        let timestamp: Date
        let app: String?
        let type: String       // note / error / code / web / file / activity
        let entity: String?
        let text: String

        /// Cited one-liner for an MCP response.
        func line(_ formatter: DateFormatter) -> String {
            let when = formatter.string(from: timestamp)
            let ent = entity.map { " {\($0)}" } ?? ""
            let app = app.map { " [\($0)]" } ?? ""
            return "- \(when)\(app)\(ent) \(type): \(text)"
        }
    }

    /// Score and rank events for `query`, optionally scoped by entity/type/since.
    /// When `entity` is nil the caller should pass the current-state entity as the
    /// anchor (done in MCPServer).
    static func rank(
        events: [RecordingEvent],
        query: String,
        entity: String?,
        type: String?,
        now: Date,
        since: TimeInterval,
        limit: Int = 8
    ) -> [Result] {
        let terms = tokens(query)
        let anchorEntity = entity?.lowercased()

        let scored: [(Double, Result)] = events.compactMap { event in
            guard let raw = event.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                  raw.count >= 2, !TestInput.isLikelyTestInput(raw),
                  !SensitiveText.isSensitive(raw) else { return nil } // never surface secrets

            let evType = classify(event)
            if let want = type, want.lowercased() != evType { return nil }

            let evEntity = Entity.from(event.windowTitle ?? raw)
            if let anchor = anchorEntity, evEntity?.lowercased() != anchor { return nil }

            // Components in [0,1].
            let age = now.timeIntervalSince(event.timestamp)
            let recency = max(0, 1 - age / max(since, 1))
            let lexical = terms.isEmpty ? 0 : Double(terms.filter { raw.lowercased().contains($0) }.count) / Double(terms.count)
            // Query present but zero term overlap → not relevant, UNLESS a `type`
            // facet is scoping (then the query is often the category itself, e.g.
            // "crash" for type=error — keep recent items of that type). Without
            // this gate, recent/salient-but-unrelated events pad the results.
            // (Synonym recall without literal overlap is the embeddings step, later.)
            if !terms.isEmpty && lexical == 0 && type == nil { return nil }
            let entityBonus = (anchorEntity == nil && evEntity != nil) ? 0.3 : 0
            let sal = salience(type: evType)

            // Weighted fusion. Lexical dominates when a query is present; recency
            // and salience keep "what matters now" afloat when it's vague.
            let score = 0.45 * lexical + 0.25 * recency + 0.20 * sal + 0.10 * entityBonus
            guard score > 0 else { return nil }

            return (score, Result(timestamp: event.timestamp, app: event.appName,
                                  type: evType, entity: evEntity, text: String(raw.prefix(200))))
        }

        return scored
            .sorted { $0.0 > $1.0 }
            .prefix(limit)
            .map(\.1)
    }

    // MARK: - Cheap structure (rule-based, not summarization)

    static func classify(_ event: RecordingEvent) -> String {
        let t = (event.textContent ?? "").lowercased()
        if t.contains("error") || t.contains("exception") || t.contains("failed")
            || t.contains("traceback") || t.contains("fatal") { return "error" }
        if t.contains("http://") || t.contains("https://") { return "web" }
        // Self-authored note: a Japanese imperative / instruction to oneself.
        if t.contains("して") || t.contains("ください") || t.contains("したい") { return "note" }
        if t.contains("func ") || t.contains("{") || t.contains("=>") || t.contains("();") { return "code" }
        if event.eventType == .screenText, let title = event.windowTitle ?? event.textContent,
           title.contains(".") { return "file" }
        if event.eventType == .clipboard { return "note" }
        return "activity"
    }

    private static func salience(type: String) -> Double {
        switch type {
        case "error": return 0.95
        case "note": return 0.85
        case "decision": return 0.85
        case "file": return 0.45
        case "code": return 0.45
        case "web": return 0.30
        default: return 0.20
        }
    }

    private static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }
}
