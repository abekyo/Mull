import Foundation

/// The cloud tier: everything the nightly run does *after* the daily summary
/// exists — per-project deliberation and prediction bookkeeping.
///
/// **For a default-configuration user this tier produces nothing.** The LLM is
/// off by default (CLAUDE.md §8.1: "LLM は既定で Off"), and with `llmProvider == .off`
/// DeliberationEngine fails its first `LLMClient.complete` call and returns empty —
/// so no `projects/*.md` briefing is ever written. PredictionEngine is rule-based and does keep
/// running, but its rows are read back only by its own grader; nothing in the UI
/// surfaces them. That is roughly 750 lines of engine code whose entire output for
/// the default install is a no-op, and the call site inside `runSummary` said
/// nothing about it — three innocuous-looking `await`s. Naming the tier is the
/// point: when this file is cheap to delete, deleting it costs nothing.
///
/// Kept separate from MullEngine because it is orchestration, not pipeline: it
/// consumes no gathered data and contributes nothing to the DailySummary. Every
/// step is best-effort — a failure here must never break the daily summary, and
/// each engine writes through the Curator so user edits survive.
final class CloudTier {

    private let database: DatabaseService
    private let deliberation: DeliberationEngine

    init(database: DatabaseService, llm: LLMClient) {
        self.database = database
        self.deliberation = DeliberationEngine(database: database, llm: llm)
    }

    /// Run the whole tier. Called at the tail of a successful consolidation.
    func run() async {
        // Deliberate tier: refresh per-project briefings in ~/mull/projects/.
        // Best-effort — a failure here never breaks the daily summary, and
        // each project file is upserted via the Curator so user edits survive.
        await deliberation.deliberateActiveProjects()

        // The synthesis tier (Phase C) used to run here, filling each numbered
        // folder's index.md from ingested _raw data. Both it and the folders it
        // wrote were retired on 2026-08-09 — DIRECTION §6.1.

        // Epistemics: grade yesterday's behavior predictions against the log,
        // then place fresh bets. This is how proactivity earns a hit-rate
        // instead of guessing (DIRECTION.md 付録A "Epistemics").
        let predictor = PredictionEngine(database: database)
        _ = predictor.gradeDuePredictions()
        predictor.recordResumePredictions()
    }
}
