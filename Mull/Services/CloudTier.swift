import Foundation

/// The cloud tier: everything the nightly run does *after* the daily summary
/// exists — per-project deliberation, category synthesis, and prediction
/// bookkeeping.
///
/// **For a default-configuration user this tier produces nothing.** The LLM is
/// off by default (CLAUDE.md §9: "LLMは既定でOff"), and with `llmProvider == .off`
/// both DeliberationEngine and SynthesisEngine fail their first `LLMClient.complete`
/// call and return empty — so no `03_projects/*.md` briefing and no folder
/// `index.md` is ever written. PredictionEngine is rule-based and does keep
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
    private let synthesis: SynthesisEngine

    init(database: DatabaseService, llm: LLMClient) {
        self.database = database
        self.deliberation = DeliberationEngine(database: database, llm: llm)
        self.synthesis = SynthesisEngine(llm: llm)
    }

    /// Run the whole tier. Called at the tail of a successful consolidation.
    func run() async {
        // Deliberate tier: refresh per-project briefings in ~/mull/projects/.
        // Best-effort — a failure here never breaks the daily summary, and
        // each project file is upserted via the Curator so user edits survive.
        await deliberation.deliberateActiveProjects()

        // Synthesis tier (Phase C): fill category folder index.md files from
        // ingested _raw data. Best-effort; no-op when the LLM is off.
        await synthesis.synthesizeAll()

        // Epistemics: grade yesterday's behavior predictions against the log,
        // then place fresh bets. This is how proactivity earns a hit-rate
        // instead of guessing (DIRECTION.md 付録A "Epistemics").
        let predictor = PredictionEngine(database: database)
        _ = predictor.gradeDuePredictions()
        predictor.recordResumePredictions()
    }
}
