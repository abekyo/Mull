import Foundation
import AppKit
import EventKit

/// Cold reading — gather everything we can know about the user
/// the instant they grant permissions. No recording needed.
///
/// Like a fortune teller: "I can see you're a developer who works
/// with Xcode and VS Code, you have a meeting at 15:00, and you
/// were just looking at something about Storyboard..."
///
/// This creates the "how do you know that?" moment in onboarding.
struct ColdReadService {

    /// Gather everything knowable right now, without any recording history.
    static func read() -> ColdReading {
        var facts: [String] = []
        var apps: [String] = []
        var schedule: [String] = []

        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        apps = runningApps
        let runningSet = Set(runningApps)

        let devApps = Set(["Xcode", "Code", "Visual Studio Code", "Cursor", "IntelliJ IDEA",
                           "Android Studio", "Terminal", "iTerm2", "Warp", "Ghostty", "Zed"])
        let designApps = Set(["Figma", "Sketch", "Photoshop", "Illustrator", "Canva"])
        let commApps = Set(["Slack", "Discord", "Teams", "Zoom", "Messages"])

        let devOverlap = runningSet.intersection(devApps)
        let designOverlap = runningSet.intersection(designApps)
        let commOverlap = runningSet.intersection(commApps)

        // 1. DEDUCTIVE observations — not "what's open" but "what that means"
        if devOverlap.count >= 2 {
            facts.append("You have \(devOverlap.sorted().joined(separator: " and ")) open at the same time — switching between projects or languages.")
        } else if devOverlap.count == 1 {
            if let app = devOverlap.first {
                facts.append("You're in \(app) right now — building something.")
            }
        }

        if !designOverlap.isEmpty && !devOverlap.isEmpty {
            facts.append("Design tools AND code editors open — you're turning designs into code.")
        }

        // What's NOT running is as interesting as what IS
        if commOverlap.isEmpty && devOverlap.count >= 1 {
            facts.append("No Slack, no Discord, no Zoom. You're in deep focus mode right now.")
        } else if commOverlap.count >= 2 {
            facts.append("Multiple communication tools active — collaborative session.")
        }

        // 2. Current window → DEDUCE what they're doing, not just state it
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let appName = frontApp.localizedName ?? ""
            let pid = frontApp.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success {
                let window = windowRef as! AXUIElement
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                if let title = titleRef as? String, !title.isEmpty {
                    // Deduce what they're doing from the window title
                    if title.contains(".swift") || title.contains(".ts") || title.contains(".py") {
                        let fileName = title.components(separatedBy: " ").first(where: { $0.contains(".") }) ?? title
                        facts.append("You're editing \(fileName) — in the middle of something.")
                    } else if title.contains("Stack Overflow") || title.contains("Google") {
                        facts.append("Researching something right now — \"\(String(title.prefix(50)))\"")
                    } else if title.lowercased().contains("pull request") || title.contains("PR #") {
                        facts.append("Reviewing a pull request right now.")
                    } else {
                        facts.append("You're looking at: \(String(title.prefix(60))) (\(appName))")
                    }
                }
            }
        }

        // 3. Clipboard → deduce INTENT, not just content
        if let clipText = NSPasteboard.general.string(forType: .string), !clipText.isEmpty {
            let preview = String(clipText.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            if clipText.contains("func ") || clipText.contains("class ") || clipText.contains("import ") {
                facts.append("You have code on your clipboard — probably moving something between files.")
            } else if clipText.contains("http") {
                facts.append("A URL on your clipboard: \"\(preview)\"")
            } else if clipText.count > 50 {
                facts.append("Your clipboard has a long text: \"\(preview)\" — writing or editing something.")
            } else {
                facts.append("Last thing you copied: \"\(preview)\"")
            }
        }

        // 4. Calendar → upcoming context
        let store = EKEventStore()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        if !events.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"

            // Find the NEXT meeting
            let upcoming = events.filter { $0.startDate > Date() }
            if let next = upcoming.first {
                let minutesUntil = Int(next.startDate.timeIntervalSince(Date()) / 60)
                if minutesUntil < 30 {
                    facts.append("You have \"\(next.title ?? "a meeting")\" in \(minutesUntil) minutes — wrapping up current work?")
                } else if minutesUntil < 60 {
                    facts.append("\"\(next.title ?? "Meeting")\" is coming up at \(formatter.string(from: next.startDate)).")
                }
            }

            // How busy is today?
            if events.count >= 4 {
                facts.append("Busy day — \(events.count) meetings scheduled. Not much maker time.")
            } else if events.count == 0 {
                facts.append("No meetings today. Full day for deep work.")
            }

            schedule = events.prefix(3).map { "\(formatter.string(from: $0.startDate)) \($0.title ?? "Meeting")" }
        } else {
            facts.append("Clear calendar today — no meetings pulling you away.")
        }

        // 5. System → personalize
        let userName = NSFullUserName()
        if !userName.isEmpty && userName.count < 30 {
            facts.insert("Hello, \(userName).", at: 0)
        }

        return ColdReading(
            facts: facts,
            runningApps: apps,
            schedule: schedule
        )
    }
}

struct ColdReading {
    let facts: [String]
    let runningApps: [String]
    let schedule: [String]

    var isEmpty: Bool { facts.isEmpty }
}
