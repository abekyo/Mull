import Foundation

/// Rule-based facts about the user, from recorded events. No LLM.
///
/// **What this may and may not say.** Everything here is an *observation* that
/// can be pointed at the rows it came from:
///
///   VaultText.t("Primary language: Japanese", "主な言語: 日本語")          — measured over 200+ characters of prose
///   "Primary tools: Xcode + Terminal"     — measured share of tracked activity
///   "Working on: PantryApp"             — a name seen 5+ times in window titles
///
/// It used to also emit *inferences about the person*, and those are gone
/// (DIRECTION §4/§9.1: what dies is rule-based summary hardened into me.md, not
/// structure). Specifically removed:
///
///   - **Role** ("Software developer", "Designer"…). A vocation guessed from which
///     apps are open. Even scored and capped at one, it is a claim mull cannot
///     support: the evidence is an app list, and the output is a sentence about
///     who someone is. It sat in the first line an AI read about the user.
///   - **Tech stack** ("Works with: React, Vercel"). Guessed from clipboard
///     substrings. Copying a Stack Overflow answer is not a skill.
///   - **Domain** ("Working on authentication", "Writing tests"). Two keyword
///     hits from a fixed list, in a keyword table that is already noisy.
///
/// The rule for adding anything here: if mull cannot show the user the rows that
/// produced the line, it does not belong in their identity file. An AI that
/// wants to know what the user is doing right now calls `whats_active_now` /
/// `search`, which read live rows instead of a month-old guess.
struct FactExtractor {

    let analytics: AnalyticsEngine
    let database: EventReading

    /// Extract all detectable facts from recorded data.
    func extractFacts(days: Int = 7) -> [Fact] {
        var facts: [Fact] = []

        facts.append(contentsOf: extractLanguageFacts(days: days))
        facts.append(contentsOf: extractAppFacts(days: days))
        facts.append(contentsOf: extractProjectFacts(days: days))
        facts.append(contentsOf: extractToolFacts(days: days))

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
                facts.append(Fact(.identity, VaultText.t("Bilingual: Japanese (\(pct(jpShare))%) and English (\(pct(enShare))%)",
                                                  "二言語: 日本語 \(pct(jpShare))% / 英語 \(pct(enShare))%")))
            } else if jpShare > 65 {
                facts.append(Fact(.identity, "Primary language: Japanese"))
            } else if enShare > 65 {
                facts.append(Fact(.identity, VaultText.t("Primary language: English", "主な言語: 英語")))
            }
        }

        if mix.codePercent > 15 {
            facts.append(Fact(.identity, VaultText.t("Writes significant amount of code (\(pct(mix.codePercent))% of input)",
                                              "入力のうち \(pct(mix.codePercent))% がコード")))
        }

        return facts
    }

    // MARK: - Apps actually used

    /// Observations about which apps the user works in. Not a vocation.
    ///
    /// This replaces `extractRoleFacts`, which turned an app list into a sentence
    /// about who someone is ("Software developer", "Designer") and put it in the
    /// first line of me.md. Naming the tools is the part mull can actually
    /// support; naming the person was the part it could not.
    private func extractAppFacts(days: Int) -> [Fact] {
        let topAppNames = Set(analytics.appUsage(days: days).prefix(8).map(\.appName))
        var facts: [Fact] = []

        // Note-taking / knowledge management
        let knowledgeApps = Set(["Notion", "Obsidian", "Roam Research", "Logseq",
                                  "Apple Notes", "Notes", "Craft", "Evernote"])
        let knowledgeOverlap = topAppNames.intersection(knowledgeApps)
        if !knowledgeOverlap.isEmpty {
            facts.append(Fact(.skills, VaultText.t("Uses \(knowledgeOverlap.sorted().joined(separator: ", ")) for notes/knowledge",
                                            "メモ・知識に \(knowledgeOverlap.sorted().joined(separator: "、")) を使う")))
        }

        // Communication
        let commApps = Set(["Slack", "Discord", "Teams", "Zoom", "Messages", "Mail",
                             "LINE", "WhatsApp", "Telegram", "WeChat"])
        let commOverlap = topAppNames.intersection(commApps)
        if commOverlap.count >= 2 {
            facts.append(Fact(.skills, VaultText.t("Active communicator (\(commOverlap.sorted().joined(separator: ", ")))",
                                            "やりとりが多い（\(commOverlap.sorted().joined(separator: "、"))）")))
        }

        return facts
    }

    // MARK: - Projects (names seen repeatedly in window titles)

    private func extractProjectFacts(days: Int) -> [Fact] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let events = database.fetchEvents(from: since, to: Date())
        var facts: [Fact] = []

        // Project names: one shared gate (`ProjectNames`), not a local blocklist.
        // What used to be here was ~40 lines of hand-collected strings the author
        // had personally been annoyed by, plus `if text.contains("を")` — which
        // discarded every window title containing the Japanese object particle,
        // i.e. most real Japanese file and document names.
        let observations: [(app: String, title: String)] = events
            .filter { $0.eventType == .screenText }
            .compactMap { event in
                guard let title = event.textContent, let app = event.appName else { return nil }
                return (app: app, title: title)
            }

        for candidate in ProjectNames.rank(observations, minMentions: 5).prefix(3) {
            facts.append(Fact(.projects, VaultText.t("Working on: ", "取り組み中: ") + candidate.name))
        }

        return facts
    }

    // Removed with no replacement: "Most productive hours" / "Busiest day"
    // (dashboard analytics — they don't change an AI's answer), tech-stack
    // detection from clipboard substrings, and domain guessing from keyword
    // overlap. Peak hours still drive proactive timing in the Insights UI; they
    // just aren't asserted about the user in me.md.

    // MARK: - Tool Preferences

    private func extractToolFacts(days: Int) -> [Fact] {
        let apps = analytics.appUsage(days: days)
        var facts: [Fact] = []

        // Browser preference removed: which browser someone uses doesn't change
        // an AI's answer to a task. (The list stays, to exclude browsers from the
        // "primary tools" signal below.)
        let browsers = ["Safari", "Firefox", "Chrome", "Google Chrome", "Arc", "Brave Browser", "Edge"]

        // Apps that come with the machine rather than with the person.
        //
        // "Primary tools: Code + Claude + Finder" reads as three choices and is
        // two: every Mac user has Finder open, so listing it says nothing about
        // how this person works and spends a line of the paste saying it. Same
        // test as the browsers above, and the same reason.
        //
        // Deliberately short and deliberately about the platform, not about taste.
        // A longer list would be someone's opinion of which tools are boring.
        let platformApps = ["Finder", "System Settings", "System Preferences", "loginwindow"]

        // Primary work tools: not just code editors, but whatever they use most.
        let workApps = apps
            .filter { !browsers.contains($0.appName) }
            .filter { !platformApps.contains($0.appName) }
            .filter { !AnalyticsEngine.isNoiseApp($0.appName) }
            .prefix(3)
        if workApps.count >= 2 {
            let names = workApps.map(\.appName).joined(separator: " + ")
            facts.append(Fact(.skills, VaultText.t("Primary tools: ", "主な道具: ") + names))
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
