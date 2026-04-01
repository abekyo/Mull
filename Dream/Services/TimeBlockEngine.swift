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
    private func generateLabel(for block: TimeBlock) -> String {
        // Use the most common window title as the label
        if let topTitle = block.topWindowTitle {
            // Clean up the title
            let cleaned = cleanTitle(topTitle, app: block.app)
            return cleaned
        }

        // Fallback: use clipboard content if meaningful
        if let clip = block.topClipboard, clip.count > 5 {
            return String(clip.prefix(60))
        }

        return block.app
    }

    private func cleanTitle(_ title: String, app: String) -> String {
        var clean = title

        // Remove app name from title
        let separators = [" — ", " - ", " | "]
        for sep in separators {
            let parts = clean.components(separatedBy: sep)
            if parts.count > 1 {
                let filtered = parts.filter {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != app.lowercased()
                }
                if let best = filtered.first {
                    clean = best.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }

        return String(clean.prefix(80))
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

    var color: Color {
        switch app {
        case "Xcode": .blue
        case "Code": .purple
        case "Cursor": .cyan
        case "Safari", "Firefox", "Chrome", "Arc": .orange
        case "Slack", "Discord", "Messages": .green
        case "Mail": .red
        case "Finder": .gray
        case "Terminal", "iTerm2", "Warp", "Ghostty": .mint
        case "Simulator": .indigo
        default: .secondary
        }
    }

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

struct EventSegment {
    let timestamp: Date
    let app: String
    let windowTitle: String
    let eventType: RecordingEvent.EventType
    let text: String
}
