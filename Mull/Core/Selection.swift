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
        // Back-pointer (MAP-ARCHITECTURE.md): the source event in the territory.
        // The map node points INTO _raw — it never replaces it — so a reader can
        // always return to the full original. Nil only for synthetic results.
        let eventID: Int64?

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

            // Prefer the stored columns (computed once at capture); fall back to
            // recomputing for rows recorded before #4's backfill.
            let evType = event.contentType ?? Signal.kind(text: raw, eventType: event.eventType, windowTitle: event.windowTitle)
            if let want = type, want.lowercased() != evType { return nil }

            let evEntity = event.entity ?? Entity.from(event.windowTitle ?? raw)
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
            let sal = event.salience ?? Signal.salience(for: evType)

            // Weighted fusion. Lexical dominates when a query is present; recency
            // and salience keep "what matters now" afloat when it's vague.
            let score = 0.45 * lexical + 0.25 * recency + 0.20 * sal + 0.10 * entityBonus
            guard score > 0 else { return nil }

            return (score, Result(timestamp: event.timestamp, app: event.appName,
                                  type: evType, entity: evEntity, text: String(raw.prefix(200)),
                                  eventID: event.id))
        }

        return scored
            .sorted { $0.0 > $1.0 }
            .prefix(limit)
            .map(\.1)
    }

    /// Split a query into matchable terms.
    ///
    /// Japanese has no spaces and CJK codepoints ARE alphanumerics, so splitting on
    /// `alphanumerics.inverted` collapsed a whole Japanese query into ONE token —
    /// and `lexical` then required the candidate text to contain the entire query
    /// verbatim. Nothing ever did, the `lexical == 0` gate discarded every
    /// candidate, and `search` answered "No relevant activity" for any Japanese
    /// query (undoing the widened CJK candidate window MCPServer already fetches).
    ///
    /// Fix: emit character BIGRAMS for CJK runs — the standard n-gram substitute for
    /// a morphological analyzer, and what SQLite's FTS trigram/`unicode61` fallbacks
    /// approximate. "選択レイヤー" → 選択 / 択レ / レイ / イヤ / ヤー, each of which a
    /// relevant snippet plausibly contains. A single-character run is kept as-is so
    /// one-kanji queries ("鬱", "本") still match.
    private static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        for run in s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) {
            guard !run.isEmpty else { continue }
            // A run can mix scripts ("swift開発"). Segment it so latin stays whole
            // words and only the CJK stretches become bigrams.
            var segment: [Character] = []
            var segmentIsCJK = false

            func flush() {
                guard !segment.isEmpty else { return }
                if segmentIsCJK {
                    if segment.count == 1 {
                        out.append(String(segment[0]))
                    } else {
                        for i in 0..<(segment.count - 1) { out.append(String(segment[i...(i + 1)])) }
                    }
                } else if segment.count >= 2 {
                    out.append(String(segment))
                }
                segment = []
            }

            for ch in run {
                let isCJK = DatabaseService.containsCJK(String(ch))
                if isCJK != segmentIsCJK { flush(); segmentIsCJK = isCJK }
                segment.append(ch)
            }
            flush()
        }
        // Bigrams overlap heavily; duplicates would skew the overlap ratio.
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}
