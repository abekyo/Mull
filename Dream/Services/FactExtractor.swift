import Foundation

/// Rule-based fact extraction from recorded events.
/// No LLM needed. Pure pattern matching + counting.
///
/// Turns raw data into structured facts like:
///   "Primary language: Swift"
///   "Currently working on: PantryApp (Storyboard refactor)"
///   "Most productive: 14:00-16:00"
///   "Communication style: bilingual (Japanese/English)"
///
/// These facts go into me.md, making AI understand the user from day one.
struct FactExtractor {

    let analytics: AnalyticsEngine
    let database: DatabaseService

    /// Extract all detectable facts from recorded data.
    func extractFacts(days: Int = 7) -> [Fact] {
        var facts: [Fact] = []

        facts.append(contentsOf: extractLanguageFacts(days: days))
        facts.append(contentsOf: extractRoleFacts(days: days))
        facts.append(contentsOf: extractProjectFacts(days: days))
        facts.append(contentsOf: extractWorkPatternFacts(days: days))
        facts.append(contentsOf: extractToolFacts(days: days))
        facts.append(contentsOf: extractTopicFacts(days: days))

        return facts
    }

    /// Generate plain text for me.md / now.md
    func generateFactSummary(days: Int = 7) -> String {
        let facts = extractFacts(days: days)
        guard !facts.isEmpty else { return "" }

        var lines: [String] = []
        let grouped = Dictionary(grouping: facts) { $0.category }

        // Order: identity → skills → projects → patterns
        for category in FactCategory.allCases {
            guard let catFacts = grouped[category], !catFacts.isEmpty else { continue }
            for fact in catFacts {
                lines.append("- \(fact.text)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Language

    private func extractLanguageFacts(days: Int) -> [Fact] {
        let mix = analytics.languageMix(days: days)
        var facts: [Fact] = []

        if mix.japanesePercent > 20 && mix.englishPercent > 20 {
            facts.append(Fact(.identity, "Bilingual: Japanese (\(pct(mix.japanesePercent))%) and English (\(pct(mix.englishPercent))%)"))
        } else if mix.japanesePercent > 50 {
            facts.append(Fact(.identity, "Primary language: Japanese"))
        } else if mix.englishPercent > 50 {
            facts.append(Fact(.identity, "Primary language: English"))
        }

        if mix.codePercent > 15 {
            facts.append(Fact(.identity, "Writes significant amount of code (\(pct(mix.codePercent))% of input)"))
        }

        return facts
    }

    // MARK: - Role (inferred from app usage)

    private func extractRoleFacts(days: Int) -> [Fact] {
        let apps = analytics.appUsage(days: days)
        let topApps = Set(apps.prefix(5).map(\.appName))
        var facts: [Fact] = []

        // Developer detection
        let devApps = Set(["Xcode", "Code", "IntelliJ IDEA", "Android Studio", "Terminal",
                           "iTerm2", "Warp", "Ghostty", "Cursor", "Zed", "Sublime Text"])
        let devOverlap = topApps.intersection(devApps)
        if devOverlap.count >= 2 {
            facts.append(Fact(.identity, "Software developer (primary tools: \(devOverlap.sorted().joined(separator: ", ")))"))
        } else if devOverlap.count == 1 {
            facts.append(Fact(.identity, "Uses \(devOverlap.first!) for development"))
        }

        // Designer detection
        let designApps = Set(["Figma", "Sketch", "Adobe XD", "Photoshop", "Illustrator", "Canva"])
        if !topApps.intersection(designApps).isEmpty {
            facts.append(Fact(.identity, "Works with design tools (\(topApps.intersection(designApps).sorted().joined(separator: ", ")))"))
        }

        // Communication heavy
        let commApps = Set(["Slack", "Discord", "Teams", "Zoom", "Messages", "Mail"])
        let commOverlap = topApps.intersection(commApps)
        if commOverlap.count >= 2 {
            facts.append(Fact(.skills, "Heavy communicator (uses \(commOverlap.sorted().joined(separator: ", ")))"))
        }

        return facts
    }

    // MARK: - Projects (inferred from window titles + clipboard)

    private func extractProjectFacts(days: Int) -> [Fact] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let events = database.fetchEvents(from: since, to: Date())
        var facts: [Fact] = []

        // Extract project names from window titles (patterns: "ProjectName — file.swift")
        var projectMentions: [String: Int] = [:]

        for event in events where event.eventType == .screenText {
            guard let text = event.textContent else { continue }

            // Xcode: "ProjectName — file.swift — Xcode"
            // VS Code: "file.swift — ProjectName"
            let separators = [" — ", " - "]
            for sep in separators {
                let parts = text.components(separatedBy: sep)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0.count > 2 && $0.count < 40 }
                    .filter { !["Xcode", "Code", "Terminal", "Safari", "Firefox", "Chrome", "Finder"].contains($0) }

                for part in parts {
                    // Skip if it looks like a filename (has extension)
                    if part.contains(".") && part.split(separator: ".").last?.count ?? 0 <= 5 { continue }
                    projectMentions[part, default: 0] += 1
                }
            }
        }

        // Top projects by mention count
        let topProjects = projectMentions
            .filter { $0.value >= 5 }
            .sorted { $0.value > $1.value }
            .prefix(3)

        for (project, count) in topProjects {
            facts.append(Fact(.projects, "Working on: \(project)"))
        }

        // Detect tech stack from clipboard/keystrokes
        let textContent = events
            .filter { $0.eventType == .keystroke || $0.eventType == .clipboard }
            .compactMap(\.textContent)
            .joined(separator: " ")

        var techStack: [String] = []
        let techPatterns: [(pattern: String, label: String)] = [
            ("Storyboard", "UIKit/Storyboard"),
            ("SwiftUI", "SwiftUI"),
            ("UIViewController", "UIKit"),
            ("struct.*View.*body", "SwiftUI"),
            ("React", "React"),
            ("NextJS", "Next.js"),
            ("useState", "React"),
            ("flutter", "Flutter"),
            ("tailwind", "Tailwind CSS"),
            ("vercel", "Vercel"),
        ]

        for (pattern, label) in techPatterns {
            if textContent.range(of: pattern, options: .caseInsensitive) != nil {
                if !techStack.contains(label) {
                    techStack.append(label)
                }
            }
        }

        if !techStack.isEmpty {
            facts.append(Fact(.skills, "Tech stack: \(techStack.joined(separator: ", "))"))
        }

        return facts
    }

    // MARK: - Work Patterns

    private func extractWorkPatternFacts(days: Int) -> [Fact] {
        var facts: [Fact] = []

        let peaks = analytics.peakHours(days: days)
        if !peaks.isEmpty {
            let peakStr = peaks.map { "\($0):00" }.joined(separator: ", ")
            facts.append(Fact(.patterns, "Most productive hours: \(peakStr)"))
        }

        let weekday = analytics.weekdayPattern(days: 30)
        let busiest = weekday.max(by: { $0.eventCount < $1.eventCount })
        let quietest = weekday.min(by: { $0.eventCount < $1.eventCount })
        if let b = busiest, let q = quietest, b.name != q.name {
            facts.append(Fact(.patterns, "Busiest day: \(b.name), quietest: \(q.name)"))
        }

        return facts
    }

    // MARK: - Tool Preferences

    private func extractToolFacts(days: Int) -> [Fact] {
        let apps = analytics.appUsage(days: days)
        var facts: [Fact] = []

        // Browser preference
        let browsers = ["Safari", "Firefox", "Chrome", "Arc", "Brave", "Edge"]
        if let primaryBrowser = apps.first(where: { browsers.contains($0.appName) }) {
            facts.append(Fact(.skills, "Primary browser: \(primaryBrowser.appName)"))
        }

        // Editor preference
        let editors = ["Code", "Xcode", "Cursor", "Zed", "Sublime Text", "IntelliJ IDEA", "Vim", "Neovim"]
        let usedEditors = apps.filter { editors.contains($0.appName) }
        if usedEditors.count >= 2 {
            let names = usedEditors.prefix(2).map(\.appName).joined(separator: " + ")
            facts.append(Fact(.skills, "Code editors: \(names)"))
        }

        return facts
    }

    // MARK: - Topics (from keywords)

    private func extractTopicFacts(days: Int) -> [Fact] {
        let keywords = analytics.topKeywords(days: days, limit: 10)
        var facts: [Fact] = []

        // Extract meaningful topic clusters
        let topWords = keywords.map(\.word)

        // Detect specific domain keywords
        let domainHints: [(keywords: [String], fact: String)] = [
            (["calorie", "nutrition", "diet", "health", "weight", "bmi"], "Working in health/nutrition domain"),
            (["payment", "stripe", "billing", "invoice", "subscription"], "Working on payment/billing features"),
            (["auth", "login", "password", "oauth", "session"], "Working on authentication"),
            (["deploy", "ci", "pipeline", "docker", "kubernetes"], "Working on deployment/infrastructure"),
            (["test", "spec", "assert", "mock", "fixture"], "Writing tests"),
            (["design", "layout", "color", "font", "spacing"], "Working on UI design"),
        ]

        for (hints, fact) in domainHints {
            let matches = topWords.filter { word in
                hints.contains { word.lowercased().contains($0) }
            }
            if matches.count >= 2 {
                facts.append(Fact(.projects, fact))
            }
        }

        return facts
    }

    private func pct(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}

// MARK: - Types

enum FactCategory: String, CaseIterable {
    case identity   // Who you are
    case skills     // What you know / use
    case projects   // What you're working on
    case patterns   // How you work
}

struct Fact {
    let category: FactCategory
    let text: String

    init(_ category: FactCategory, _ text: String) {
        self.category = category
        self.text = text
    }
}
