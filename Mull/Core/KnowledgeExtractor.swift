import Foundation

/// Extracts knowledge from daily activity data.
///
/// Activity = what you did.
/// Knowledge = what you learned, decided, or discovered.
///
/// Two modes:
///   1. LLM extraction — sends daily events to LLM with a knowledge-focused prompt
///   2. Rule-based fallback — extracts decisions from clipboard patterns
///
/// Runs after the nightly summary, using the same gathered data.
struct KnowledgeExtractor {

    let database: DatabaseService

    // MARK: - LLM Extraction

    /// Build a prompt that asks the LLM to extract knowledge, not summarize activity.
    func buildExtractionPrompt(events: [RecordingEvent], existingKnowledge: [KnowledgeEntry]) -> String {
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none)

        // Prepare clipboard and keystroke data — these contain the richest knowledge signals
        let clipEvents = events.filter { $0.eventType == .clipboard }
        let titleEvents = events.filter { $0.eventType == .screenText }

        var clipboardSection = ""
        for event in clipEvents.suffix(40) {
            guard let text = event.textContent, text.count > 10 else { continue }
            // Privacy: drop clipboard secrets before they reach the LLM.
            if SensitiveText.isSensitive(text) { continue }
            let clean = String(text.prefix(300)).replacingOccurrences(of: "\n", with: "\\n")
            let app = event.appName ?? "Unknown"
            clipboardSection += "[\(app)] \(clean)\n"
        }

        var titlesSection = ""
        var seenTitles = Set<String>()
        for event in titleEvents {
            guard let text = event.textContent else { continue }
            let key = String(text.prefix(60).lowercased())
            guard !seenTitles.contains(key) else { continue }
            seenTitles.insert(key)
            titlesSection += "- \(String(text.prefix(120)))\n"
        }

        // Existing knowledge for dedup
        let existingBlock = existingKnowledge.isEmpty ? "(none yet)" :
            existingKnowledge.prefix(20).map { "- [\($0.project)] \($0.topic): \($0.decision)" }.joined(separator: "\n")

        return """
        # Knowledge Extraction

        You are analyzing a developer's daily activity to extract **knowledge** — not activity.

        Activity = "Worked on ChartVM for 3 hours" (we already have this)
        Knowledge = "Chose closure-based bindings over Combine because project has no Combine dependency"

        **Date: \(dateStr)**

        ## What they copied/pasted today (richest knowledge signal):
        \(clipboardSection.isEmpty ? "(nothing)" : clipboardSection)

        ## Files and pages they worked on:
        \(titlesSection.isEmpty ? "(nothing)" : titlesSection)

        ## Existing knowledge (avoid duplicates):
        \(existingBlock)

        ## Your task

        Extract 1-5 knowledge entries. Only extract if there is REAL knowledge — decisions, solutions,
        discoveries, or rejected alternatives. Do NOT extract activity or timestamps.

        For each entry, identify:
        - **topic**: The subject (e.g. "MVVM binding strategy", "Core Data migration fix")
        - **decision**: What was decided or learned (1-2 sentences)
        - **reasoning**: Why this decision was made (if apparent)
        - **rejected**: Alternatives that were considered but not chosen (if apparent)
        - **project**: Which project this relates to
        - **related_projects**: Other projects this could apply to (if any)
        - **tags**: Comma-separated keywords for search

        If there is no real knowledge to extract (just routine coding), return an empty array.

        ## Output Format (JSON array only, no other text):
        [
          {
            "topic": "...",
            "decision": "...",
            "reasoning": "...",
            "rejected": "...",
            "project": "...",
            "related_projects": "...",
            "tags": "..."
          }
        ]
        """
    }

    /// Parse LLM response into KnowledgeEntry objects.
    func parseResponse(_ response: String) -> [KnowledgeEntry] {
        // Find JSON array in response
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]") else { return [] }

        let jsonStr = String(response[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        let now = Date()
        return array.compactMap { dict -> KnowledgeEntry? in
            guard let topic = dict["topic"] as? String,
                  let decision = dict["decision"] as? String,
                  let project = dict["project"] as? String,
                  !topic.isEmpty, !decision.isEmpty else { return nil }

            return KnowledgeEntry(
                topic: topic,
                decision: decision,
                reasoning: dict["reasoning"] as? String,
                rejected: dict["rejected"] as? String,
                project: project,
                relatedProjects: dict["related_projects"] as? String,
                tags: dict["tags"] as? String,
                sourceDate: now,
                createdAt: now
            )
        }
    }

    // MARK: - Rule-Based Fallback

    /// Extract knowledge without LLM — pattern matching on clipboard content.
    ///
    /// Looks for:
    ///   - Decision patterns: "use X instead of Y", "chose X because", "switched to X"
    ///   - Error + solution pairs: error message followed by a fix
    ///   - Configuration/architecture notes: copied text that looks like a plan or decision
    func extractRuleBased(events: [RecordingEvent]) -> [KnowledgeEntry] {
        let now = Date()
        var entries: [KnowledgeEntry] = []

        let clipEvents = events.filter { $0.eventType == .clipboard }
        let titleEvents = events.filter { $0.eventType == .screenText }

        // Detect the primary project from window titles
        let projectName = detectProject(from: titleEvents)

        // Pattern 1: Decision language in clipboard (any profession)
        let decisionPatterns = [
            // English
            "instead of", "rather than", "chose", "decided",
            "switched to", "replaced", "migrated from", "because",
            "better than", "prefer", "should use", "went with",
            "dropped", "cancelled", "approved", "rejected",
            // Japanese
            "のかわりに", "にした", "を採用", "を選択", "廃止", "導入",
            "にすべき", "がいい", "をやめる", "に決定",
        ]

        for event in clipEvents {
            guard let text = event.textContent, text.count > 20, text.count < 500 else { continue }

            let lower = text.lowercased()
            let matchedPattern = decisionPatterns.first { lower.contains($0) }
            guard matchedPattern != nil else { continue }

            // Skip code-only content
            let codeChars = text.filter { "{}[]();=<>".contains($0) }.count
            if Double(codeChars) / Double(text.count) > 0.15 { continue }

            entries.append(KnowledgeEntry(
                topic: extractTopic(from: text),
                decision: String(text.prefix(200)),
                reasoning: nil,
                rejected: nil,
                project: projectName,
                relatedProjects: nil,
                tags: extractTags(from: text),
                sourceDate: event.timestamp,
                createdAt: now
            ))

            if entries.count >= 3 { break }
        }

        // Pattern 2: Phase/milestone language (project progress)
        let phasePatterns = ["phase", "step", "milestone", "完了", "着手", "フェーズ"]
        for event in clipEvents {
            guard let text = event.textContent, text.count > 10, text.count < 300 else { continue }
            let lower = text.lowercased()
            guard phasePatterns.contains(where: { lower.contains($0) }) else { continue }
            guard !entries.contains(where: { $0.decision == String(text.prefix(200)) }) else { continue }

            entries.append(KnowledgeEntry(
                topic: "Project progress",
                decision: String(text.prefix(200)),
                reasoning: nil,
                rejected: nil,
                project: projectName,
                relatedProjects: nil,
                tags: "progress,milestone",
                sourceDate: event.timestamp,
                createdAt: now
            ))

            if entries.count >= 5 { break }
        }

        return entries
    }

    // MARK: - Helpers

    private func detectProject(from titleEvents: [RecordingEvent]) -> String {
        var projectCounts: [String: Int] = [:]
        for event in titleEvents {
            guard let text = event.textContent else { continue }
            // VS Code pattern: "file — ProjectName"
            let parts = text.components(separatedBy: " — ")
            if parts.count >= 2, let project = parts.last {
                let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 2 && trimmed.count < 30 && !trimmed.contains(".") {
                    projectCounts[trimmed, default: 0] += 1
                }
            }
            // Xcode pattern: "ProjectName — file.swift"
            if let first = parts.first {
                let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 2 && trimmed.count < 30 && !trimmed.contains(".") {
                    projectCounts[trimmed, default: 0] += 1
                }
            }
        }
        return projectCounts.max(by: { $0.value < $1.value })?.key ?? "Unknown"
    }

    private func extractTopic(from text: String) -> String {
        // Take the first meaningful phrase (up to first period or newline)
        let firstLine = text.components(separatedBy: .newlines).first ?? text
        let firstSentence = firstLine.components(separatedBy: ".").first ?? firstLine
        let trimmed = firstSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(80))
    }

    private func extractTags(from text: String) -> String {
        let domainWords = Set([
            // Dev
            "swift", "swiftui", "uikit", "combine", "mvvm", "react", "python", "sql", "api", "git",
            // Design
            "design", "layout", "prototype", "wireframe", "figma", "color", "typography",
            // Business
            "budget", "revenue", "forecast", "strategy", "marketing", "sales", "roi",
            // Content
            "seo", "content", "blog", "article", "draft", "publish",
            // Trading
            "trading", "forex", "indicator", "chart", "signal",
            // Research
            "research", "analysis", "hypothesis", "experiment", "data",
        ])
        let words = text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { domainWords.contains($0) }
        return Array(Set(words)).prefix(5).joined(separator: ",")
    }
}
