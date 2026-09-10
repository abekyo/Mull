// Synthetic detector-only reproduction; no real user records or database.
// The production BehaviorPatternEngine.swift is compiled by run-pattern-audit.sh.
// TimeBlockEngine and AnalyticsEngine below supply deliberately small fixtures.
// This demonstrates output semantics, not end-to-end aggregation correctness.
import Foundation
struct Event { enum Kind { case appSwitch }; let eventType: Kind = .appSwitch; let timestamp: Date; let appName: String? }
protocol EventReading { func fetchEvents(from: Date, to: Date) -> [Event] }
struct DB: EventReading { var events: [Event] = []; func fetchEvents(from: Date, to: Date) -> [Event] { events.filter { $0.timestamp >= from && $0.timestamp <= to } } }
struct Session { let date: Date; let duration: Double }
struct Project { let name: String; let daysSinceActive: Int; let sessions: [Session] }
struct Block { let activeDuration: Double }
struct Comparison { var lastWeekDeepBlocks = 0; var thisWeekDeepBlocks = 0; var lastWeekContextSwitches = 0; var thisWeekContextSwitches = 0 }
struct TimeBlockEngine {
 let database: EventReading
 static var projects: [Project] = []
 func projectSnapshots(days: Int) -> [Project] { Self.projects }
 func weekComparison() -> Comparison { Comparison() }
 func generateBlocks(for: Date) -> [Block] { [] }
}
struct Hourly { let hour: Int; let eventCount: Int }
struct AnalyticsEngine {
 let database: EventReading
 func hourlyPattern(days: Int) -> [Hourly] { [Hourly(hour: Calendar.current.component(.hour, from: Date()), eventCount: 1)] }
 static func isNoiseApp(_ app: String) -> Bool { false }
}
let now = Date()
TimeBlockEngine.projects = [Project(name: "DailyChecks", daysSinceActive: 0, sessions: (1...3).map { Session(date: Calendar.current.date(byAdding: .day, value: -$0, to: now)!, duration: 240) })]
let avoidance = BehaviorPatternEngine(database: DB()).detectPatterns().filter { $0.type == .avoidance }
precondition(avoidance.count == 1)
print("DAILY AGGREGATES: " + avoidance[0].insight + " | " + avoidance[0].action + " | autoSurfaceable=\(avoidance[0].autoSurfaceable)")
TimeBlockEngine.projects = []
let peak = BehaviorPatternEngine(database: DB(events: [Event(timestamp: now, appName: "Google Chrome")])).detectPatterns().filter { $0.type == .peakWaste }
precondition(peak.count == 1)
print("ONE EVENT: " + peak[0].insight + " | " + peak[0].action + " | autoSurfaceable=\(peak[0].autoSurfaceable)")
