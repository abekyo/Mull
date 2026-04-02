import Foundation
import SwiftUI

/// Aggregates raw events into time blocks for calendar-style timeline.
/// Pure rule-based — no LLM needed.
///
/// Input: raw RecordingEvents
/// Output: "09:00-10:30 — Xcode: PantryApp (Storyboard refactor)"
///
/// Logic:
///   1. Group consecutive events by dominant app
///   2. Merge short gaps (< 3 min) into the surrounding block
///   3. Label each block from window titles + clipboard context
struct TimeBlockEngine {

    let database: DatabaseService

    /// Generate time blocks for a given day.
    func generateBlocks(for date: Date) -> [TimeBlock] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let events = database.fetchEvents(from: startOfDay, to: min(endOfDay, Date()))
            .filter { event in
                guard let app = event.appName else { return true }
                return !AnalyticsEngine.noiseApps.contains(app)
            }
        guard !events.isEmpty else { return [] }

        // Step 1: Create raw segments (1 per event with app + time)
        var segments: [EventSegment] = []
        for event in events {
            segments.append(EventSegment(
                timestamp: event.timestamp,
                app: event.appName ?? "Unknown",
                windowTitle: event.windowTitle ?? event.textContent ?? "",
                eventType: event.eventType,
                text: event.textContent ?? ""
            ))
        }

        // Step 2: Group into blocks by dominant app (merge if same app within 3 min)
        var blocks: [TimeBlock] = []
        var currentBlock: TimeBlock?

        for segment in segments {
            if var block = currentBlock {
                let gap = segment.timestamp.timeIntervalSince(block.end)

                // Same app and gap < 3 minutes → extend block
                if segment.app == block.app && gap < 180 {
                    block.end = segment.timestamp
                    block.eventCount += 1
                    block.addContext(segment)
                    currentBlock = block
                } else if gap < 180 {
                    // Different app but tiny gap → still extend (multitasking)
                    block.end = segment.timestamp
                    block.eventCount += 1
                    block.addContext(segment)
                    block.isMultiApp = true
                    currentBlock = block
                } else {
                    // Gap too large → save block and start new one
                    blocks.append(block)
                    currentBlock = TimeBlock(from: segment)
                }
            } else {
                currentBlock = TimeBlock(from: segment)
            }
        }

        if let last = currentBlock {
            blocks.append(last)
        }

        // Step 3: Filter out very short blocks (< 30 seconds)
        blocks = blocks.filter { $0.duration >= 30 }

        // Step 4: Generate labels
        for i in 0..<blocks.count {
            blocks[i].label = generateLabel(for: blocks[i])
        }

        return blocks
    }

    /// Generate a human-readable label for a time block.
    /// Priority: project name > file name > window title > clipboard > app name
    private func generateLabel(for block: TimeBlock) -> String {
        if let topTitle = block.topWindowTitle {
            let parsed = parseWindowTitle(topTitle, app: block.app)
            // Prefer "Project — File" format if both exist
            if let project = parsed.project, let file = parsed.file {
                return "\(project) — \(file)"
            }
            if let project = parsed.project {
                return project
            }
            if let file = parsed.file {
                return file
            }
            // Fallback to cleaned title
            return parsed.display
        }

        if let clip = block.topClipboard, clip.count > 5 {
            return String(clip.prefix(60))
        }

        return block.app
    }

    struct ParsedTitle {
        var project: String?  // e.g. "PantryApp", "notes-site"
        var file: String?     // e.g. "ViewController.swift"
        var display: String   // cleaned display string
    }

    /// Parse window titles from common app formats:
    ///   VS Code: "filename.swift — ProjectName"
    ///   VS Code + Claude: "Chat title — ProjectName"
    ///   Xcode: "ProjectName — filename.swift — Xcode"
    ///   Browser: "Page Title — Site Name"
    private func parseWindowTitle(_ title: String, app: String) -> ParsedTitle {
        let separators = [" — ", " - ", " | "]

        for sep in separators {
            let parts = title.components(separatedBy: sep)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.lowercased() != app.lowercased() }

            guard parts.count >= 2 else { continue }

            // Detect which part is the project and which is the file/task
            var project: String?
            var file: String?

            for part in parts {
                if isFileName(part) {
                    file = part
                } else if isProjectName(part) {
                    project = project ?? part // Keep the first project-like name
                }
            }

            // VS Code pattern: last part (after —) is usually the project
            if project == nil {
                let lastPart = parts.last!
                if isProjectName(lastPart) {
                    project = lastPart
                }
            }

            // If we only found one meaningful part, use it
            if project == nil && file == nil {
                // Take the last part as project (VS Code convention)
                project = parts.last
            }

            return ParsedTitle(project: project, file: file, display: parts.joined(separator: " — "))
        }

        // No separator found — single-part title
        if isFileName(title) {
            return ParsedTitle(project: nil, file: title, display: title)
        }
        return ParsedTitle(project: nil, file: nil, display: String(title.prefix(80)))
    }

    /// Looks like a file: has extension with 1-5 char suffix
    private func isFileName(_ str: String) -> Bool {
        let parts = str.split(separator: ".")
        guard parts.count >= 2 else { return false }
        let ext = parts.last!
        return ext.count <= 5 && ext.allSatisfy(\.isLetter)
    }

    /// Looks like a project name: short, no spaces (or camelCase/kebab-case), no extension
    private func isProjectName(_ str: String) -> Bool {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        // Too long → probably a sentence/chat message
        guard trimmed.count <= 40 else { return false }
        // Has file extension → it's a file, not a project
        if isFileName(trimmed) { return false }
        // Contains question marks or exclamation → it's a chat message
        if trimmed.contains("?") || trimmed.contains("？") || trimmed.contains("!") || trimmed.contains("！") { return false }
        // Very long with spaces → probably a sentence
        if trimmed.contains(" ") && trimmed.count > 25 { return false }
        return true
    }
}

// MARK: - Data Types

struct TimeBlock: Identifiable {
    let id = UUID()
    var app: String
    var start: Date
    var end: Date
    var eventCount: Int
    var label: String = ""
    var isMultiApp = false

    // Context accumulation
    private var windowTitles: [String: Int] = [:]
    private var clipboardTexts: [String] = []
    private var keystrokeCount: Int = 0

    var duration: TimeInterval { end.timeIntervalSince(start) }

    var durationFormatted: String {
        let minutes = Int(duration / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes > 0 ? "\(hours)h \(remainingMinutes)m" : "\(hours)h"
    }

    var startFormatted: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: start)
    }

    var endFormatted: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: end)
    }

    var color: Color { DS.appColor(app) }

    init(from segment: EventSegment) {
        self.app = segment.app
        self.start = segment.timestamp
        self.end = segment.timestamp
        self.eventCount = 1
        addContext(segment)
    }

    mutating func addContext(_ segment: EventSegment) {
        switch segment.eventType {
        case .screenText, .appSwitch:
            if !segment.windowTitle.isEmpty {
                windowTitles[segment.windowTitle, default: 0] += 1
            }
        case .clipboard:
            if segment.text.count > 5 {
                clipboardTexts.append(segment.text)
            }
        case .keystroke:
            keystrokeCount += 1
        case .audio:
            break
        }
    }

    var topWindowTitle: String? {
        windowTitles.max(by: { $0.value < $1.value })?.key
    }

    var topClipboard: String? {
        clipboardTexts.last
    }
}

// MARK: - Daily Summary (rule-based "what you mainly did")

struct DailyActivity {
    let mainActivities: [ActivitySummary]  // Top 3 by time
    let otherActivities: [ActivitySummary] // Everything else
    let totalDuration: TimeInterval
    let appBreakdown: [(app: String, duration: TimeInterval, percentage: Double)]

    /// Generate plain text for AI or UI.
    func asText() -> String {
        var lines: [String] = []

        lines.append("What you mainly did today:")
        for activity in mainActivities {
            lines.append("- \(activity.label) (\(activity.durationFormatted), \(activity.app))")
        }

        if !otherActivities.isEmpty {
            lines.append("")
            lines.append("Also:")
            for activity in otherActivities {
                lines.append("- \(activity.label) (\(activity.durationFormatted), \(activity.app))")
            }
        }

        lines.append("")
        lines.append("App usage:")
        for (app, _, pct) in appBreakdown.prefix(6) {
            lines.append("- \(app): \(String(format: "%.0f", pct))%")
        }

        return lines.joined(separator: "\n")
    }
}

struct ActivitySummary: Identifiable {
    let id = UUID()
    let label: String
    let app: String
    let totalDuration: TimeInterval
    let eventCount: Int
    let blocks: [TimeBlock]

    var durationFormatted: String {
        let minutes = Int(totalDuration / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    var color: Color { blocks.first?.color ?? .secondary }
}

extension TimeBlockEngine {

    /// Analyze a day's blocks and extract "what you mainly did" + supporting facts.
    func analyzDay(for date: Date) -> DailyActivity {
        let blocks = generateBlocks(for: date)
        guard !blocks.isEmpty else {
            return DailyActivity(mainActivities: [], otherActivities: [], totalDuration: 0, appBreakdown: [])
        }

        // Step 1: Group blocks by project/task (same label = same task)
        var taskGroups: [String: [TimeBlock]] = [:]
        for block in blocks {
            let key = normalizeTaskKey(block)
            taskGroups[key, default: []].append(block)
        }

        // Step 2: Create ActivitySummary per group, sorted by total duration
        var activities = taskGroups.map { key, blocks -> ActivitySummary in
            let totalDuration = blocks.reduce(0.0) { $0 + $1.duration }
            let totalEvents = blocks.reduce(0) { $0 + $1.eventCount }
            let primaryApp = mostCommonApp(in: blocks)
            let label = bestLabel(for: blocks, key: key)

            return ActivitySummary(
                label: label,
                app: primaryApp,
                totalDuration: totalDuration,
                eventCount: totalEvents,
                blocks: blocks
            )
        }
        .sorted { $0.totalDuration > $1.totalDuration }

        // Step 3: Split into main (top 3) vs other
        let main = Array(activities.prefix(3))
        let other = Array(activities.dropFirst(3).prefix(5))

        // Step 4: App breakdown
        var appDurations: [String: TimeInterval] = [:]
        for block in blocks {
            appDurations[block.app, default: 0] += block.duration
        }
        let totalDuration = blocks.reduce(0.0) { $0 + $1.duration }
        let appBreakdown = appDurations
            .sorted { $0.value > $1.value }
            .map { (app: $0.key, duration: $0.value, percentage: $0.value / max(totalDuration, 1) * 100) }

        return DailyActivity(
            mainActivities: main,
            otherActivities: other,
            totalDuration: totalDuration,
            appBreakdown: appBreakdown
        )
    }

    /// Normalize block into a task key for grouping.
    /// Same project across Xcode + Code + Terminal = same task.
    private func normalizeTaskKey(_ block: TimeBlock) -> String {
        // If we have a parsed title with a project, use that
        if let topTitle = block.topWindowTitle {
            let parsed = parseWindowTitle(topTitle, app: block.app)
            if let project = parsed.project {
                return project.lowercased()
            }
        }

        // Otherwise extract from label
        let label = block.label.isEmpty ? block.app : block.label
        let separators = [" — ", " - ", " | "]
        for sep in separators {
            let parts = label.components(separatedBy: sep)
            if parts.count > 1, let first = parts.first {
                let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 2 && trimmed.count < 30 {
                    return trimmed.lowercased()
                }
            }
        }

        return label.lowercased().prefix(40).description
    }

    private func mostCommonApp(in blocks: [TimeBlock]) -> String {
        var counts: [String: TimeInterval] = [:]
        for block in blocks {
            counts[block.app, default: 0] += block.duration
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? "Unknown"
    }

    private func bestLabel(for blocks: [TimeBlock], key: String) -> String {
        // Find the most specific label from the longest block
        let sorted = blocks.sorted { $0.duration > $1.duration }
        for block in sorted {
            if let title = block.topWindowTitle {
                let parsed = parseWindowTitle(title, app: block.app)
                // Prefer "Project — File" if both exist
                if let project = parsed.project, let file = parsed.file {
                    return "\(project) — \(file)"
                }
                if let project = parsed.project {
                    return project
                }
            }
            if let label = sorted.first?.label, !label.isEmpty, label != sorted.first?.app {
                return label
            }
        }
        return key.prefix(1).uppercased() + key.dropFirst()
    }
}

struct EventSegment {
    let timestamp: Date
    let app: String
    let windowTitle: String
    let eventType: RecordingEvent.EventType
    let text: String
}
