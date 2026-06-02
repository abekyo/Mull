import XCTest
import GRDB
@testable import mull

/// Tests for the prediction persistence + grading layer — the mechanism that
/// gives mull ground truth by predicting behavior and checking it against the log.
///
/// The suite shares one on-disk DB that accumulates rows across runs, so each
/// test tags its rows with a unique `statement` token and asserts only on those
/// — fully isolated from any leftover data.
final class PredictionEngineTests: XCTestCase {

    private var db: DatabaseService!

    override func setUp() {
        super.setUp()
        db = DatabaseService()
    }

    private func makePrediction(token: String, createdAt: Date, dueAt: Date) -> Prediction {
        Prediction(
            id: nil, createdAt: createdAt, project: token, kind: "resume",
            statement: token, dueAt: dueAt, outcome: "pending", gradedAt: nil
        )
    }

    func testDuePredictionIsReturned() {
        let token = "tok-due-\(#function)"
        let past = Date().addingTimeInterval(-3 * 86_400)
        db.insertPrediction(makePrediction(token: token, createdAt: past,
                                           dueAt: past.addingTimeInterval(86_400)))

        let mine = db.fetchDuePredictions(asOf: Date()).filter { $0.statement == token }
        XCTAssertEqual(mine.count, 1)
    }

    func testFutureDuePredictionIsNotReturned() {
        let token = "tok-future-\(#function)"
        let now = Date()
        db.insertPrediction(makePrediction(token: token, createdAt: now,
                                           dueAt: now.addingTimeInterval(86_400)))

        let mine = db.fetchDuePredictions(asOf: now).filter { $0.statement == token }
        XCTAssertTrue(mine.isEmpty)
    }

    func testHasPendingReflectsInsert() {
        let token = "tok-pending-\(#function)"
        XCTAssertFalse(db.hasPendingPrediction(project: token, kind: "resume"))
        db.insertPrediction(makePrediction(token: token, createdAt: Date(), dueAt: Date()))
        XCTAssertTrue(db.hasPendingPrediction(project: token, kind: "resume"))
    }

    func testGradingMovesOutOfPendingIntoGraded() {
        let token = "tok-grade-\(#function)"
        let created = Date().addingTimeInterval(-10 * 86_400)
        db.insertPrediction(makePrediction(token: token, createdAt: created, dueAt: created))

        var p = db.fetchDuePredictions(asOf: Date()).first { $0.statement == token }!
        p.outcome = "hit"
        p.gradedAt = Date()
        db.updatePrediction(p)

        XCTAssertTrue(db.fetchDuePredictions(asOf: Date()).filter { $0.statement == token }.isEmpty)
        let graded = db.fetchGradedPredictions(since: created.addingTimeInterval(-86_400))
            .filter { $0.statement == token }
        XCTAssertEqual(graded.count, 1)
        XCTAssertEqual(graded.first?.outcome, "hit")
    }

    func testHitRateNeedsMinimumSample() {
        // With an impossibly high minimum sample, hitRate must return nil
        // rather than a misleading ratio — regardless of accumulated rows.
        let engine = PredictionEngine(database: db)
        XCTAssertNil(engine.hitRate(days: 365, minSample: 1_000_000))
    }
}
