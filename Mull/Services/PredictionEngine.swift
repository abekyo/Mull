import Foundation

/// Manufactures ground truth in a domain that has none.
///
/// mull can't know what's "right" for a person (preference is unverifiable),
/// but it CAN predict what they'll *do* — and tomorrow's log settles it. This
/// engine records behavior predictions and later grades them against the actual
/// record, producing a hit-rate that tells us (and the user) how well mull's
/// proactivity actually tracks reality. See DIRECTION.md 付録A "Epistemics".
///
/// v1 makes one kind of prediction: resumption. When a project goes quiet for a
/// day or two, mull predicts the user will return to it within a short window.
/// Either they do (hit) or they don't (miss). No judgment, just a checkable bet.
struct PredictionEngine {

    let database: DatabaseService

    /// Grace period after `dueAt` before a pending prediction is graded, so a
    /// late-night return still counts.
    private let graceHours: Double = 6

    /// How long after going quiet we bet the user resumes.
    private let resumeWindowDays = 2

    // MARK: - Record

    /// Look at recently-stalled projects and record resume predictions for any
    /// that don't already have a pending one.
    @discardableResult
    func recordResumePredictions(now: Date = Date()) -> [Prediction] {
        let engine = TimeBlockEngine(database: database)
        let projects = engine.projectSnapshots(days: 14)

        var recorded: [Prediction] = []
        for project in projects {
            // Recently quiet, not yet abandoned: the live edge where a resume is plausible.
            guard project.daysSinceActive >= 1, project.daysSinceActive <= resumeWindowDays else { continue }
            guard !database.hasPendingPrediction(project: project.name, kind: "resume") else { continue }

            let due = Calendar.current.date(byAdding: .day, value: resumeWindowDays, to: now) ?? now
            var prediction = Prediction(
                id: nil,
                createdAt: now,
                project: project.name,
                kind: "resume",
                statement: "Will return to \(project.name) within \(resumeWindowDays) days",
                dueAt: due,
                outcome: "pending",
                gradedAt: nil
            )
            database.insertPrediction(prediction)
            prediction.outcome = "pending"
            recorded.append(prediction)
        }
        return recorded
    }

    // MARK: - Grade

    /// Grade every pending prediction whose due time (plus grace) has passed,
    /// by checking the log for real activity on the project after it was made.
    @discardableResult
    func gradeDuePredictions(now: Date = Date()) -> (hits: Int, misses: Int) {
        let cutoff = Calendar.current.date(byAdding: .hour, value: -Int(graceHours), to: now) ?? now
        let due = database.fetchDuePredictions(asOf: cutoff)
        guard !due.isEmpty else { return (0, 0) }

        let engine = TimeBlockEngine(database: database)
        let projects = engine.projectSnapshots(days: 30)
        let lastActive = Dictionary(
            projects.map { ($0.name, $0.lastActiveDate) },
            uniquingKeysWith: { a, b in max(a, b) }
        )

        var hits = 0, misses = 0
        for var prediction in due {
            let resumed: Bool
            if prediction.kind == "resume", let last = lastActive[prediction.project] {
                // Hit if the project saw activity strictly after the prediction was made.
                resumed = last > prediction.createdAt
            } else {
                resumed = false
            }

            prediction.outcome = resumed ? "hit" : "miss"
            prediction.gradedAt = now
            database.updatePrediction(prediction)
            if resumed { hits += 1 } else { misses += 1 }
        }
        return (hits, misses)
    }

    // MARK: - Score

    /// Fraction of graded predictions that were correct over the window, or nil
    /// if there aren't enough yet to be meaningful.
    func hitRate(days: Int = 30, minSample: Int = 3) -> Double? {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        let graded = database.fetchGradedPredictions(since: since)
        guard graded.count >= minSample else { return nil }
        let hits = graded.filter { $0.outcome == "hit" }.count
        return Double(hits) / Double(graded.count)
    }
}
