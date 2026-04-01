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

        // 1. Running apps → what kind of user they are
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)

        apps = runningApps
        let devApps = Set(["Xcode", "Code", "Visual Studio Code", "Cursor", "IntelliJ IDEA",
                           "Android Studio", "Terminal", "iTerm2", "Warp", "Ghostty", "Zed"])
        let designApps = Set(["Figma", "Sketch", "Photoshop", "Illustrator", "Canva"])
        let commApps = Set(["Slack", "Discord", "Teams", "Zoom"])

        let devOverlap = Set(runningApps).intersection(devApps)
        let designOverlap = Set(runningApps).intersection(designApps)
        let commOverlap = Set(runningApps).intersection(commApps)

        if devOverlap.count >= 1 {
            facts.append("You're a developer — \(devOverlap.sorted().joined(separator: ", ")) is open right now")
        }
        if designOverlap.count >= 1 {
            facts.append("You work with design — \(designOverlap.sorted().joined(separator: ", ")) is open")
        }
        if commOverlap.count >= 1 {
            facts.append("You use \(commOverlap.sorted().joined(separator: ", ")) for communication")
        }

        // 2. Current window → what they're doing RIGHT NOW
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
                    facts.append("Right now you're looking at: \(title) (\(appName))")
                }
            }
        }

        // 3. Clipboard → last thing they were working with
        if let clipText = NSPasteboard.general.string(forType: .string), !clipText.isEmpty {
            let preview = String(clipText.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            facts.append("Last thing you copied: \"\(preview)\"")
        }

        // 4. Calendar → today's schedule
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
            for event in events.prefix(3) {
                let time = formatter.string(from: event.startDate)
                let title = event.title ?? "Meeting"
                schedule.append("\(time) \(title)")

                // Is there a meeting soon?
                let minutesUntil = Int(event.startDate.timeIntervalSince(Date()) / 60)
                if minutesUntil > 0 && minutesUntil < 60 {
                    facts.append("You have \"\(title)\" in \(minutesUntil) minutes")
                }
            }

            if !schedule.isEmpty {
                facts.append("Your schedule today: \(schedule.joined(separator: " → "))")
            }
        }

        // 5. System info
        let locale = Locale.current
        if let lang = locale.language.languageCode?.identifier {
            if lang == "ja" {
                facts.append("Your system is set to Japanese")
            }
        }

        let userName = NSFullUserName()
        if !userName.isEmpty {
            facts.append("Hello, \(userName)")
        }

        // 6. Installed apps (quick check for dev tools)
        let fm = FileManager.default
        let appsDir = "/Applications"
        if let installed = try? fm.contentsOfDirectory(atPath: appsDir) {
            let hasXcode = installed.contains("Xcode.app")
            let hasVSCode = installed.contains("Visual Studio Code.app")
            let hasFigma = installed.contains("Figma.app")

            if hasXcode && hasVSCode {
                facts.append("You have both Xcode and VS Code installed — multi-editor workflow")
            }
            if hasFigma {
                facts.append("Figma is installed — you work with design")
            }
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
