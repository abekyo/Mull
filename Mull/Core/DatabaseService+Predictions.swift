import Foundation
import GRDB
import os.log

// Predictions — mull's calibration loop.
//
// The only consumer is PredictionEngine, and it touches nothing else, which is
// why this is its own protocol (`PredictionStoring`) rather than part of the
// derived surface.
//
// Split out of DatabaseService.swift. Nothing here changed in the move.

extension DatabaseService {

    // MARK: - Predictions

    func insertPrediction(_ prediction: Prediction) {
        do {
            try dbPool.write { db in
                let p = prediction
                try p.insert(db)
            }
        } catch {
            databaseLogger.error("Failed to insert prediction for '\(prediction.project)': \(error.localizedDescription)")
        }
    }

    /// Pending predictions whose due time has passed — ready to grade.
    func fetchDuePredictions(asOf date: Date = Date()) -> [Prediction] {
        do {
            return try dbPool.read { db in
                try Prediction
                    .filter(Column("outcome") == "pending" && Column("dueAt") <= date)
                    .fetchAll(db)
            }
        } catch {
            databaseLogger.warning("Failed to fetch due predictions: \(error.localizedDescription)")
            return []
        }
    }

    /// Whether a pending prediction already exists for a project+kind (avoids dupes).
    func hasPendingPrediction(project: String, kind: String) -> Bool {
        do {
            return try dbPool.read { db in
                try Prediction
                    .filter(Column("outcome") == "pending"
                            && Column("project") == project
                            && Column("kind") == kind)
                    .fetchCount(db) > 0
            }
        } catch {
            return false
        }
    }

    func updatePrediction(_ prediction: Prediction) {
        do {
            try dbPool.write { db in
                try prediction.update(db)
            }
        } catch {
            databaseLogger.error("Failed to update prediction \(prediction.id ?? -1): \(error.localizedDescription)")
        }
    }

    /// Graded predictions created within the window, for hit-rate calculation.
    func fetchGradedPredictions(since: Date) -> [Prediction] {
        do {
            return try dbPool.read { db in
                try Prediction
                    .filter(Column("outcome") != "pending" && Column("createdAt") >= since)
                    .fetchAll(db)
            }
        } catch {
            databaseLogger.warning("Failed to fetch graded predictions: \(error.localizedDescription)")
            return []
        }
    }
}
