import XCTest
import GRDB
@testable import mull

/// Tests for the prediction persistence + grading layer.
///
/// The suite shares one on-disk DB that accumulates rows across runs, so each
/// test uses a per-RUN-unique token (UUID) for its project/statement and asserts
/// only on its own rows. This is immune to leftover data without depending on
/// deleteAllData clearing the predictions table.
final class PredictionEngineTests: XCTestCase {

    private var db: DatabaseService!

    override func setUp() {
        super.setUp()
        db = try! DatabaseService.temporary()
    }

    /// A token no other test or prior run could collide with.
    private func token() -> String { "pred-test-\(UUID().uuidString)" }

    private func makePrediction(_ token: String, createdAt: Date, dueAt: Date) -> Prediction {
        Prediction(
            id: nil, createdAt: createdAt, project: token, kind: "resume",
            statement: token, dueAt: dueAt, outcome: "pending", gradedAt: nil
        )
    }

    func testDuePredictionIsReturned() {
        let t = token()
        let past = Date().addingTimeInterval(-3 * 86_400)
        db.insertPrediction(makePrediction(t, createdAt: past, dueAt: past.addingTimeInterval(86_400)))

        let mine = db.fetchDuePredictions(asOf: Date()).filter { $0.statement == t }
        XCTAssertEqual(mine.count, 1)
    }

    func testFutureDuePredictionIsNotReturned() {
        let t = token()
        let now = Date()
        db.insertPrediction(makePrediction(t, createdAt: now, dueAt: now.addingTimeInterval(86_400)))

        XCTAssertTrue(db.fetchDuePredictions(asOf: now).filter { $0.statement == t }.isEmpty)
    }

    func testHasPendingReflectsInsert() {
        let t = token()
        XCTAssertFalse(db.hasPendingPrediction(project: t, kind: "resume"))
        db.insertPrediction(makePrediction(t, createdAt: Date(), dueAt: Date()))
        XCTAssertTrue(db.hasPendingPrediction(project: t, kind: "resume"))
    }

    func testGradingMovesOutOfPendingIntoGraded() {
        let t = token()
        let created = Date().addingTimeInterval(-10 * 86_400)
        db.insertPrediction(makePrediction(t, createdAt: created, dueAt: created))

        var p = db.fetchDuePredictions(asOf: Date()).first { $0.statement == t }!
        p.outcome = "hit"
        p.gradedAt = Date()
        db.updatePrediction(p)

        XCTAssertTrue(db.fetchDuePredictions(asOf: Date()).filter { $0.statement == t }.isEmpty)
        let graded = db.fetchGradedPredictions(since: created.addingTimeInterval(-86_400))
            .filter { $0.statement == t }
        XCTAssertEqual(graded.count, 1)
        XCTAssertEqual(graded.first?.outcome, "hit")
    }

    func testHitRateNeedsMinimumSample() {
        let engine = PredictionEngine(database: db)
        // Impossibly high minimum → nil regardless of accumulated rows.
        XCTAssertNil(engine.hitRate(days: 365, minSample: 1_000_000))
    }
}
