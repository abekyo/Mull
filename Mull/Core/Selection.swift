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
        ///
        /// `text` is captured material — a clipboard entry, a window body — which
        /// means a third party may have written it, and this line is about to be
        /// read by an agent that holds tool permissions. Marked here rather than at
        /// each call site so every consumer of a ranked slice gets the same frame.
        func line(_ formatter: DateFormatter) -> String {
            let when = formatter.string(from: timestamp)
            let ent = entity.map { " {\($0)}" } ?? ""
            let app = app.map { " [\($0)]" } ?? ""
            return "- \(when)\(app)\(ent) \(type): \(InstructionText.marked(text))"
        }
    }

    /// A ranked slice plus how it was arrived at, because the caller has to be
    /// able to say so. An agent that receives eight items cannot tell whether they
    /// matched its words or were substituted in when nothing did, and it will
    /// present them with the same confidence either way.
    struct Slice {
        let results: [Result]
        /// True when nothing matched the query literally and the anchor's own
        /// recent high-signal activity was returned instead.
        let substituted: Bool
    }

    /// Score and rank events for `query`.
    ///
    /// The two entity arguments are deliberately not one argument:
    ///
    /// - `entity` is an EXPLICIT scope. The caller named a project, so anything
    ///   else is not what it asked for: a hard filter is the correct reading.
    /// - `anchor` is an IMPLICIT prior — whatever the user happens to have open,
    ///   filled in by MCPServer when the caller named nothing. It **ranks and
    ///   never excludes**.
    ///
    /// These used to be the same parameter, and the implicit case inherited the
    /// explicit case's hard filter. The effect was that the default `search` —
    /// the one an agent makes when it has no reason to name a project — could
    /// only ever return events from the project already on screen. "How did I
    /// solve this last time" is asked precisely when the answer is somewhere
    /// else, so the tool was structurally unable to answer its headline question,
    /// and said "No relevant activity" rather than admitting it had filtered.
    static func rank(
        events: [RecordingEvent],
        query: String,
        entity: String?,
        anchor: String? = nil,
        type: String?,
        now: Date,
        since: TimeInterval,
        limit: Int = 8,
        corrections: CorrectionIndex = .empty
    ) -> [Result] {
        slice(events: events, query: query, entity: entity, anchor: anchor,
              type: type, now: now, since: since, limit: limit,
              corrections: corrections).results
    }

    /// `rank`, plus whether the result set is a substitution (see `Slice`).
    static func slice(
        events: [RecordingEvent],
        query: String,
        entity: String?,
        anchor: String? = nil,
        type: String?,
        now: Date,
        since: TimeInterval,
        limit: Int = 8,
        /// Human verdicts from past corrections. Defaults to empty, so every
        /// existing caller and the cold-start case behave exactly as before —
        /// the loop adds signal, it never gates on having any.
        corrections: CorrectionIndex = .empty
    ) -> Slice {
        let terms = tokens(query)
        let scopeEntity = entity?.lowercased()
        let anchorEntity = anchor?.lowercased()

        /// Everything that survives the filters, with its components computed once.
        struct Candidate {
            let result: Result
            let recency: Double
            let lexical: Double
            let salience: Double
            let entityMatch: Double
            let attributable: Double
            let mode: Double
            let correction: Double
        }

        let candidates: [Candidate] = events.compactMap { event in
            guard let raw = event.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                  raw.count >= 2, !TestInput.isLikelyTestInput(raw),
                  !SensitiveText.isSensitive(raw) else { return nil } // never surface secrets

            // Prefer the stored columns (computed once at capture); fall back to
            // recomputing for rows recorded before #4's backfill.
            let evType = event.contentType ?? Signal.kind(text: raw, eventType: event.eventType, windowTitle: event.windowTitle)
            if let want = type, want.lowercased() != evType { return nil }

            let evEntity = event.entity ?? Entity.from(event.windowTitle ?? raw)
            // The ONLY hard entity filter: the caller named this project.
            if let scope = scopeEntity, evEntity?.lowercased() != scope { return nil }

            // Components in [0,1].
            let age = now.timeIntervalSince(event.timestamp)
            let recency = max(0, 1 - age / max(since, 1))
            let lexical = terms.isEmpty ? 0 : Double(terms.filter { raw.lowercased().contains($0) }.count) / Double(terms.count)
            // A real match against the anchor, which is what SELECTION-LAYER's
            // `w2·entity` always meant. The previous expression scored "this event
            // has any entity at all", and only when no anchor was supplied — so on
            // the anchored path, the entity term was identically zero.
            let entityMatch = (anchorEntity != nil && evEntity?.lowercased() == anchorEntity) ? 1.0 : 0.0
            // Separate from `entityMatch`, and deliberately tiny: an event mull can
            // attribute to *some* project is more citable than a floating keystroke
            // fragment, whatever the anchor is. This is what the old expression was
            // worth in practice (0.10 × 0.3 = 0.03) and all it could ever decide was
            // an exact tie — so it is kept at exactly that weight, under a name that
            // says what it does, rather than masquerading as the entity term.
            let attributable = evEntity != nil ? 1.0 : 0.0
            let sal = event.salience ?? Signal.salience(for: evType)

            return Candidate(
                result: Result(timestamp: event.timestamp, app: event.appName,
                               type: evType, entity: evEntity, text: String(raw.prefix(200)),
                               eventID: event.id),
                recency: recency, lexical: lexical, salience: sal,
                entityMatch: entityMatch, attributable: attributable,
                mode: event.resolvedMode.weight,
                correction: corrections.delta(for: raw))
        }

        // Query present but zero term overlap → not relevant, UNLESS a `type`
        // facet is scoping (then the query is often the category itself, e.g.
        // "crash" for type=error — keep recent items of that type).
        let lexicalGate = !terms.isEmpty && type == nil
        let anyLexicalHit = candidates.contains { $0.lexical > 0 }

        // Substitution, not widening. The gate is relaxed only when NOTHING
        // matched literally — the case that otherwise returns "No relevant
        // activity" for "auth broken" while `login returns 401` sits right there.
        // Whenever literal hits do exist they are trusted alone, so a good match
        // is never padded out with merely-salient neighbours. Requiring both the
        // anchor and note/error-tier salience is what keeps the substitution from
        // becoming the dump this layer exists to avoid.
        let substituting = lexicalGate && !anyLexicalHit && anchorEntity != nil
        let substitutionSalienceFloor = 0.8

        let kept = candidates.filter { c in
            if substituting { return c.entityMatch == 1 && c.salience >= substitutionSalienceFloor }
            if lexicalGate { return c.lexical > 0 }
            return true
        }

        // Weighted fusion (SELECTION-LAYER §4). The four weights sum to 1; lexical
        // dominates when a query is present, recency and salience keep "what
        // matters now" afloat when it is vague, and the anchor pulls toward the
        // project in front of the user without being able to erase the others.
        // `attributable` and `mode` ride on top as ordering terms outside the sum.
        //
        // `mode` is deliberately additive rather than carved out of the four.
        // MAP-ARCHITECTURE says the MODE axis is used for 「重み付け・選別」 and
        // nothing here read it until 2026-08-09, so connecting it is the fix — but
        // the eval cannot yet size it: nearly every case shares `appName: "Code"`,
        // so mode is close to constant across the corpus and rebalancing the four
        // against it would be an unmeasured change (Invariant Contract 契約3).
        // 0.06 is twice the pure tiebreak and small enough that it reorders only
        // near-ties. Raising it requires eval cases with mode diversity first.
        // `correction` is the only term backed by a human verdict rather than a
        // heuristic, which is why it outweighs `mode` — and why it is the term the
        // eval can actually size (unlike mode, whose corpus is near-constant).
        // It orders; it cannot delete on its own: a dropped item still carries its
        // lexical and entity mass, so Law 5 holds.
        let scored = kept.map { c -> (Double, Result) in
            (0.40 * c.lexical + 0.22 * c.recency + 0.18 * c.salience + 0.20 * c.entityMatch
             + 0.03 * c.attributable + 0.06 * c.mode + 0.10 * c.correction, c.result)
        }

        let results = scored
            .filter { $0.0 > 0 }
            .sorted { $0.0 > $1.0 }
            .prefix(limit)
            .map(\.1)

        return Slice(results: Array(results), substituted: substituting && !results.isEmpty)
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
                let isCJK = TextScript.containsCJK(String(ch))
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
