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

        // Only claim a primary language once there's enough human prose to back
        // it up — a handful of clipboard items is not a reliable signal.
        let proseTotal = mix.japanesePercent + mix.englishPercent
        if mix.proseSampleCount >= 200, proseTotal > 0 {
            // Compare Japanese vs English relative to each other (prose only),
            // so copied code can't tilt the verdict toward English.
            let jpShare = mix.japanesePercent / proseTotal * 100
            let enShare = mix.englishPercent / proseTotal * 100

            if jpShare >= 25 && enShare >= 25 {
                facts.append(Fact(.identity, "Bilingual: Japanese (\(pct(jpShare))%) and English (\(pct(enShare))%)"))
            } else if jpShare > 65 {
                facts.append(Fact(.identity, "Primary language: Japanese"))
            } else if enShare > 65 {
                facts.append(Fact(.identity, "Primary language: English"))
            }
        }

        if mix.codePercent > 15 {
            facts.append(Fact(.identity, "Writes significant amount of code (\(pct(mix.codePercent))% of input)"))
        }

        return facts
    }

    // MARK: - Role (inferred from app usage)

    private func extractRoleFacts(days: Int) -> [Fact] {
        let apps = analytics.appUsage(days: days)
        let topApps = Set(apps.prefix(8).map(\.appName))
        var facts: [Fact] = []

        // Role detection — check multiple profiles, pick the best match
        let roleProfiles: [(role: String, apps: Set<String>, minMatch: Int)] = [
            ("Software developer", Set(["Xcode", "Code", "IntelliJ IDEA", "Android Studio",
                                         "Terminal", "iTerm2", "Warp", "Ghostty", "Cursor",
                                         "Zed", "Sublime Text", "Simulator"]), 2),
            ("Designer", Set(["Figma", "Sketch", "Adobe XD", "Photoshop", "Illustrator",
                               "Canva", "Affinity Designer", "Pixelmator Pro"]), 1),
            ("Writer", Set(["Google Docs", "Microsoft Word", "Pages", "Ulysses",
                             "iA Writer", "Scrivener", "Bear", "Typora"]), 1),
            ("Researcher", Set(["Zotero", "Mendeley", "Papers", "DEVONthink",
                                 "Preview", "Books"]), 1),
            ("Content creator", Set(["Final Cut Pro", "DaVinci Resolve", "Premiere Pro",
                                      "Logic Pro", "GarageBand", "OBS", "ScreenFlow"]), 1),
            ("Business/analyst", Set(["Microsoft Excel", "Numbers", "Google Sheets",
                                       "Tableau", "Power BI"]), 1),
            ("Student", Set(["Anki", "Quizlet", "GoodNotes", "Notability"]), 1),
        ]

        for profile in roleProfiles {
            let overlap = topApps.intersection(profile.apps)
            if overlap.count >= profile.minMatch {
                facts.append(Fact(.identity, "\(profile.role) (primary tools: \(overlap.sorted().joined(separator: ", ")))"))
            }
        }

        // Note-taking / knowledge management
        let knowledgeApps = Set(["Notion", "Obsidian", "Roam Research", "Logseq",
                                  "Apple Notes", "Notes", "Craft", "Evernote"])
        let knowledgeOverlap = topApps.intersection(knowledgeApps)
        if !knowledgeOverlap.isEmpty {
            facts.append(Fact(.skills, "Uses \(knowledgeOverlap.sorted().joined(separator: ", ")) for notes/knowledge"))
        }

        // Communication
        let commApps = Set(["Slack", "Discord", "Teams", "Zoom", "Messages", "Mail",
                             "LINE", "WhatsApp", "Telegram", "WeChat"])
        let commOverlap = topApps.intersection(commApps)
        if commOverlap.count >= 2 {
            facts.append(Fact(.skills, "Active communicator (\(commOverlap.sorted().joined(separator: ", ")))"))
        }

        return facts
    }

    // MARK: - Projects (inferred from window titles + clipboard)

    private func extractProjectFacts(days: Int) -> [Fact] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let events = database.fetchEvents(from: since, to: Date())
        var facts: [Fact] = []

        // Extract project names from window titles
        // Real projects: "PantryApp — ViewController.swift — Xcode"
        // NOT projects: chat messages, UI placeholders, long sentences
        var projectMentions: [String: Int] = [:]

        let skipPatterns = [
            "Queue another", "Untitled", "Welcome to", "Getting Started",
            "Welcome", "Analyze project", "Visual Studio Code",
            "gpt-4", "gpt-3", "claude", "Summarize", "Summary",
            "Evaluate", "Fix ", "Debug", "Review",
            "⌘", "？", "？", "！", "。", "、",  // Japanese punctuation = chat, not project
        ]
        let skipApps = Set(["Xcode", "Code", "Terminal", "Safari", "Firefox", "Chrome",
                            "Finder", "Simulator", "System Settings", "mull",
                            "Google Chrome", "Arc", "Brave Browser"])

        for event in events where event.eventType == .screenText {
            guard let text = event.textContent else { continue }

            // Skip if text looks like a sentence, prompt, or question
            if text.count > 50 { continue }
            if text.contains("？") || text.contains("?") || text.contains("！") { continue }
            // Skip Claude Code session titles (prompts being used as window titles)
            if text.contains("ください") || text.contains("して") || text.contains("を") { continue }
            // Skip email addresses used as window titles
            if text.contains("@") && text.contains(".") { continue }

            let separators = [" — ", " - "]
            for sep in separators {
                let parts = text.components(separatedBy: sep)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { part in
                        guard part.count > 2 && part.count < 30 else { return false }
                        guard !skipApps.contains(part) else { return false }
                        // Skip if matches skip patterns
                        guard !skipPatterns.contains(where: { part.contains($0) }) else { return false }
                        // Skip if it looks like a filename
                        if part.contains(".") && part.split(separator: ".").last?.count ?? 0 <= 5 { return false }
                        // Must look like a project name: starts with uppercase or is a known pattern
                        let first = part.first ?? Character(" ")
                        return first.isUppercase || first.isNumber
                    }

                for part in parts {
                    projectMentions[part, default: 0] += 1
                }
            }
        }

        let topProjects = projectMentions
            .filter { $0.value >= 5 }
            .sorted { $0.value > $1.value }
            .prefix(3)

        for (project, _) in topProjects {
            facts.append(Fact(.projects, "Working on: \(project)"))
        }

        // Detect domain-specific tools/frameworks from clipboard content
        let textContent = events
            .filter { $0.eventType == .clipboard }
            .compactMap(\.textContent)
            .joined(separator: " ")

        var detectedTools: [String] = []
        let toolPatterns: [(pattern: String, label: String)] = [
            // Development
            ("Storyboard", "UIKit/Storyboard"), ("SwiftUI", "SwiftUI"),
            ("UIViewController", "UIKit"), ("React", "React"),
            ("NextJS", "Next.js"), ("flutter", "Flutter"),
            ("tailwind", "Tailwind CSS"), ("vercel", "Vercel"),
            // Design
            ("Figma", "Figma"), ("Auto Layout", "Auto Layout"),
            // Data / Analytics
            ("VLOOKUP", "Excel/Sheets"), ("pivot table", "Excel/Sheets"),
            ("SELECT.*FROM", "SQL"), ("pandas", "Python/pandas"),
            // Writing / Content
            ("WordPress", "WordPress"), ("Markdown", "Markdown"),
            // Marketing
            ("Google Analytics", "Google Analytics"), ("SEO", "SEO"),
            ("Search Console", "Search Console"),
        ]

        for (pattern, label) in toolPatterns {
            if textContent.range(of: pattern, options: .caseInsensitive) != nil {
                if !detectedTools.contains(label) {
                    detectedTools.append(label)
                }
            }
        }

        if !detectedTools.isEmpty {
            facts.append(Fact(.skills, "Works with: \(detectedTools.joined(separator: ", "))"))
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
        let browsers = ["Safari", "Firefox", "Chrome", "Google Chrome", "Arc", "Brave Browser", "Edge"]
        if let primaryBrowser = apps.first(where: { browsers.contains($0.appName) }) {
            facts.append(Fact(.skills, "Primary browser: \(primaryBrowser.appName)"))
        }

        // Primary work tools — not just "code editors" but whatever they use most
        let workApps = apps
            .filter { !browsers.contains($0.appName) }
            .filter { !AnalyticsEngine.noiseApps.contains($0.appName) }
            .prefix(3)
        if workApps.count >= 2 {
            let names = workApps.map(\.appName).joined(separator: " + ")
            facts.append(Fact(.skills, "Primary tools: \(names)"))
        }

        return facts
    }

    // MARK: - Topics (from keywords)

    private func extractTopicFacts(days: Int) -> [Fact] {
        let keywords = analytics.topKeywords(days: days, limit: 10)
        var facts: [Fact] = []

        // Extract meaningful topic clusters
        let topWords = keywords.map(\.word)

        // Detect domain from keywords — covers all professions
        let domainHints: [(keywords: [String], fact: String)] = [
            // Health
            (["calorie", "nutrition", "diet", "health", "weight", "bmi"], "Working in health/nutrition domain"),
            // Finance
            (["revenue", "budget", "forecast", "profit", "expense", "invoice"], "Working on finance/accounting"),
            (["trading", "forex", "indicator", "chart", "candle", "signal"], "Working on trading/markets"),
            // Development
            (["payment", "stripe", "billing", "subscription"], "Working on payment integration"),
            (["auth", "login", "oauth", "session"], "Working on authentication"),
            (["deploy", "ci", "pipeline", "docker"], "Working on deployment"),
            (["test", "spec", "assert", "mock"], "Writing tests"),
            // Design
            (["design", "layout", "color", "font", "spacing", "wireframe"], "Working on design"),
            (["prototype", "mockup", "component", "figma"], "Working on prototyping"),
            // Writing
            (["chapter", "draft", "manuscript", "editor", "publish"], "Working on writing/publishing"),
            (["blog", "article", "content", "post", "seo"], "Working on content/SEO"),
            // Marketing
            (["campaign", "conversion", "funnel", "ads", "marketing"], "Working on marketing"),
            (["analytics", "traffic", "engagement", "impression"], "Working on analytics"),
            // Education
            (["lecture", "assignment", "exam", "study", "course"], "Working on education/learning"),
            // Research
            (["paper", "citation", "methodology", "hypothesis", "experiment"], "Working on research"),
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
