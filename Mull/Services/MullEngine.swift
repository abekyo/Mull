import Foundation

/// The mull Engine — 3-gate trigger system + 4-phase LLM consolidation.
/// Implements a standard gated memory-consolidation pipeline: capture
/// continuously, consolidate on a gated schedule, summarize, then prune.
final class MullEngine {

    private let database: DatabaseService
    private let fileManager = FileManager.default
    private let llm = LLMClient()
    private lazy var deliberation = DeliberationEngine(database: database, llm: llm)
    private lazy var synthesis = SynthesisEngine(llm: llm)

    // Configurable thresholds
    private let minHoursSinceLast: Double = 24
    private let minEventsRequired: Int = 50

    // Scan throttle — minimum 10 minutes between data scans
    private var lastDataScanAt: Date = .distantPast
    private let dataScanInterval: TimeInterval = 10 * 60 // 10 minutes

    // Paths
    private var mullOutputDir: URL {
        let home = fileManager.homeDirectoryForCurrentUser
        return home.appendingPathComponent("mull", isDirectory: true)
    }

    private var dailyDir: URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM"
        let subpath = formatter.string(from: Date())
        return mullOutputDir.appendingPathComponent("daily/\(subpath)", isDirectory: true)
    }

    private var memoryDir: URL {
        mullOutputDir.appendingPathComponent("memory", isDirectory: true)
    }

    private var memoryIndexPath: URL {
        mullOutputDir.appendingPathComponent("MEMORY.md")
    }

    // MARK: - Output Files (3 layers for token-conscious AI export)

    /// Layer A: "Who" — always safe to include. ~200 tokens.
    var meFilePath: URL {
        mullOutputDir.appendingPathComponent("me.md")
    }

    /// Layer B: "Now" — current projects + this week. ~500 tokens.
    var nowFilePath: URL {
        mullOutputDir.appendingPathComponent("now.md")
    }

    /// Layer C: "Full" — everything. Use sparingly. ~1500+ tokens.
    var fullFilePath: URL {
        mullOutputDir.appendingPathComponent("full.md")
    }

    init(database: DatabaseService) {
        self.database = database
    }

    // MARK: - 3-Gate Trigger System

    /// Check all three gates (cheapest first). Returns true only if all pass.
    func shouldRun() -> Bool {
        // Gate 1: Time — has enough time passed? (cost: 1 DB read)
        guard passesTimeGate() else { return false }

        // Scan throttle: don't check data gate more than every 10 minutes
        // Throttle: skip if scanned within the interval above
        let sinceScan = Date().timeIntervalSince(lastDataScanAt)
        guard sinceScan >= dataScanInterval else { return false }
        lastDataScanAt = Date()

        // Gate 2: Data — is there enough new data? (cost: 1 DB count query)
        guard passesDataGate() else { return false }

        // Gate 3: Lock — is another mull already running? (cost: 1 DB read + PID check)
        guard passesLockGate() else { return false }

        return true
    }

    /// Gate 1: At least `minHoursSinceLast` hours since last mull.
    private func passesTimeGate() -> Bool {
        guard let lock = database.fetchmullLock() else { return true }
        guard let lastMull = lock.lastSummaryAt else { return true } // Never consolidated

        let hoursSince = Date().timeIntervalSince(lastMull) / 3600
        return hoursSince >= minHoursSinceLast
    }

    /// Gate 2: At least `minEventsRequired` new recording events.
    private func passesDataGate() -> Bool {
        let lock = database.fetchmullLock()
        let since = lock?.lastSummaryAt ?? Date.distantPast
        let events = database.fetchEvents(from: since, to: Date())
        return events.count >= minEventsRequired
    }

    /// Gate 3: No other mull process is running (PID check).
    private func passesLockGate() -> Bool {
        guard let lock = database.fetchmullLock() else { return true }
        guard let holderPID = lock.holderPID else { return true }

        // Check if the PID is still alive
        let isAlive = kill(holderPID, 0) == 0
        if isAlive {
            // Check stale threshold (1 hour)
            if let lastMull = lock.lastSummaryAt {
                let hoursSince = Date().timeIntervalSince(lastMull) / 3600
                return hoursSince > 1.0 // Stale after 1 hour — reclaim
            }
            return false
        }
        return true // Process is dead — reclaim
    }

    // MARK: - Acquire / Release Lock

    private func acquireLock() {
        var lock = database.fetchmullLock() ?? mullLock(sessionsSinceLast: 0)
        lock.holderPID = Int32(ProcessInfo.processInfo.processIdentifier)
        database.updatemullLock(lock)
    }

    private func releaseLock(success: Bool) {
        var lock = database.fetchmullLock() ?? mullLock(sessionsSinceLast: 0)
        lock.holderPID = nil
        if success {
            lock.lastSummaryAt = Date()
            lock.sessionsSinceLast = 0
        }
        database.updatemullLock(lock)
    }

    // MARK: - 4-Phase mull Execution

    func runSummary() async throws -> DailySummary {
        let startTime = Date()
        acquireLock()

        do {
            // Phase 1: Orient
            let existingMemories = phase1Orient()

            // Phase 2: Gather
            let rawData = phase2Gather()

            // Phase 3: Consolidate — try LLM first, fall back to rule-based
            let summary: ConsolidatedSummary
            do {
                summary = try await phase3Consolidate(
                    rawData: rawData,
                    existingMemories: existingMemories
                )
            } catch {
                // LLM failed (no API key, Ollama not running, etc.)
                // Fall back to rule-based summary — still useful, no LLM needed
                print("[mull] LLM failed: \(error.localizedDescription). Using rule-based summary.")
                summary = phase3RuleBasedFallback(rawData: rawData)
            }

            // Phase 3.5: Extract Knowledge — what was learned, not what was done
            await extractKnowledge(from: rawData)

            // Phase 4: Prune & Index
            try phase4PruneAndIndex(summary: summary)

            let duration = Date().timeIntervalSince(startTime)
            let provider = UserDefaults.standard.string(forKey: "llmProvider") ?? "off"

            let dailySummary = DailySummary(
                date: Calendar.current.startOfDay(for: Date()),
                content: summary.fullMarkdown,
                morningSection: summary.morning,
                afternoonSection: summary.afternoon,
                eveningSection: summary.evening,
                learnings: summary.learnings,
                inProgress: summary.inProgress,
                eventCount: rawData.events.count,
                processingSeconds: duration,
                llmProvider: provider,
                createdAt: Date()
            )

            database.insertSummary(dailySummary)
            try writeDailyFile(dailySummary)

            // Generate me.md — the single "you" file for AI
            try generateMeFile()

            // Deliberate tier: refresh per-project briefings in ~/mull/projects/.
            // Best-effort — a failure here never breaks the daily summary, and
            // each project file is upserted via the Curator so user edits survive.
            await deliberation.deliberateActiveProjects()

            // Synthesis tier (Phase C): fill category folder index.md files from
            // ingested _raw data. Best-effort; no-op when the LLM is off.
            await synthesis.synthesizeAll()

            // Epistemics: grade yesterday's behavior predictions against the log,
            // then place fresh bets. This is how proactivity earns a hit-rate
            // instead of guessing (PRODUCT.md "Epistemics").
            let predictor = PredictionEngine(database: database)
            _ = predictor.gradeDuePredictions()
            predictor.recordResumePredictions()

            // Prune processed raw events (keep summaries forever)
            pruneProcessedEvents()

            releaseLock(success: true)
            return dailySummary

        } catch {
            releaseLock(success: false)
            throw error
        }
    }

    // MARK: - Phase 1: Orient

    /// Read existing memory files to understand current knowledge landscape.
    private func phase1Orient() -> [MemoryEntry] {
        database.fetchAllMemories()
    }

    // MARK: - Phase 2: Gather

    /// Collect the past 24 hours of recording events, grouped by time and app.
    private func phase2Gather() -> GatheredData {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .hour, value: -24, to: Date())!

        let events = database.fetchEvents(from: yesterday, to: Date())

        // Group by time period
        var morning: [RecordingEvent] = []
        var afternoon: [RecordingEvent] = []
        var evening: [RecordingEvent] = []

        for event in events {
            let hour = calendar.component(.hour, from: event.timestamp)
            if hour < 12 {
                morning.append(event)
            } else if hour < 18 {
                afternoon.append(event)
            } else {
                evening.append(event)
            }
        }

        // Group by app
        let appGroups = Dictionary(grouping: events) { $0.appName ?? "Unknown" }

        return GatheredData(
            events: events,
            morning: morning,
            afternoon: afternoon,
            evening: evening,
            appGroups: appGroups
        )
    }

    // MARK: - Phase 3 Fallback: Rule-based summary (no LLM)

    /// Generate a narrative summary — same data, told as a story.
    private func phase3RuleBasedFallback(rawData: GatheredData) -> ConsolidatedSummary {
        let engine = TimeBlockEngine(database: database)
        let analysis = engine.analyzDay(for: Date())
        let analyticsEngine = AnalyticsEngine(database: database)

        let narrator = NarrativeEngine(
            analysis: analysis,
            analytics: analyticsEngine,
            database: database
        )

        let narrative = narrator.generateNarrative()
        let dateStr = Date().formatted(.dateTime.year().month().day())

        let fullMarkdown = "# \(dateStr)\n\n\(narrative)"

        return ConsolidatedSummary(
            fullMarkdown: fullMarkdown,
            morning: narrative, // Put the whole narrative in morning for now
            afternoon: nil,
            evening: nil,
            learnings: nil,
            inProgress: nil,
            memoryUpdatesJSON: nil
        )
    }

    // MARK: - Phase 3.5: Knowledge Extraction

    /// Extract knowledge from today's events — decisions, solutions, discoveries.
    private func extractKnowledge(from rawData: GatheredData) async {
        let extractor = KnowledgeExtractor(database: database)
        let existingKnowledge = database.fetchAllKnowledge()

        // Try LLM extraction first
        do {
            let prompt = extractor.buildExtractionPrompt(
                events: rawData.events,
                existingKnowledge: existingKnowledge
            )
            let response = try await callLLM(prompt: prompt)
            let entries = extractor.parseResponse(response)

            for entry in entries {
                // Deduplicate: skip if we already have knowledge with same topic+project
                let isDuplicate = existingKnowledge.contains {
                    $0.topic.lowercased() == entry.topic.lowercased() &&
                    $0.project.lowercased() == entry.project.lowercased()
                }
                if !isDuplicate {
                    database.insertKnowledge(entry)
                }
            }

            if !entries.isEmpty {
                print("[mull] Extracted \(entries.count) knowledge entries via LLM")
            }
        } catch {
            // LLM failed — use rule-based fallback
            print("[mull] LLM knowledge extraction failed: \(error.localizedDescription). Using rule-based.")
            let entries = extractor.extractRuleBased(events: rawData.events)

            for entry in entries {
                let isDuplicate = existingKnowledge.contains {
                    $0.decision.prefix(50) == entry.decision.prefix(50)
                }
                if !isDuplicate {
                    database.insertKnowledge(entry)
                }
            }

            if !entries.isEmpty {
                print("[mull] Extracted \(entries.count) knowledge entries via rules")
            }
        }
    }

    // MARK: - Phase 3: Consolidate (LLM)

    /// Send gathered data to LLM for summarization.
    private func phase3Consolidate(
        rawData: GatheredData,
        existingMemories: [MemoryEntry]
    ) async throws -> ConsolidatedSummary {
        let prompt = buildConsolidationPrompt(data: rawData, memories: existingMemories)
        let response = try await callLLM(prompt: prompt)
        return parseConsolidationResponse(response)
    }

    private func buildConsolidationPrompt(data: GatheredData, memories: [MemoryEntry]) -> String {
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none)

        let existingMemoriesBlock: String
        if memories.isEmpty {
            existingMemoriesBlock = "(No existing memories yet.)"
        } else {
            existingMemoriesBlock = memories.map { mem in
                "- [\(mem.memoryType.rawValue)] **\(mem.name)**: \(mem.description)\n  Content: \(String(mem.content.prefix(200)))"
            }.joined(separator: "\n")
        }

        // 4 precise phases: orient → gather → consolidate → prune
        let prompt = """
        # mull: Memory Consolidation

        You are performing a nightly reflective pass over accumulated activity data — mulling over the user's day.
        Synthesize what happened today into a structured daily summary AND durable memory updates
        so that future AI sessions can orient quickly.

        **Today's date: \(dateStr)**

        ---

        ## Phase 1 — Orient (understand existing knowledge)

        Here are the existing memories. Skim them to avoid duplicates and spot what might be outdated:

        \(existingMemoriesBlock)

        ## Phase 2 — Gather recent signal (today's raw activity)

        ### Morning (\(data.morning.count) events)
        \(summarizeEvents(data.morning, maxItems: 30))

        ### Afternoon (\(data.afternoon.count) events)
        \(summarizeEvents(data.afternoon, maxItems: 30))

        ### Evening (\(data.evening.count) events)
        \(summarizeEvents(data.evening, maxItems: 30))

        ### Apps Used (time allocation)
        \(data.appGroups.map { "- \($0.key): \($0.value.count) events" }.joined(separator: "\n"))

        ## Phase 3 — Consolidate (create summary + update memories)

        ### Daily Summary
        Create bullet points for each time period. Start each bullet with a verb.
        Only include sections that have meaningful activity.

        ### Memory Updates
        Based on today's activity and existing memories, identify updates:

        - **Create** new memories for: user preferences, project context, working patterns,
          or references discovered today that aren't already captured
        - **Update** existing memories that have new information (e.g., project status changed)
        - **Delete** memories that today's activity contradicts or proves outdated
          (e.g., a memory says "uses CGEvent tap" but today switched to Accessibility API)

        **Rules for memory updates:**
        - Convert relative dates to absolute: "today" → "\(dateStr)", "yesterday" → specific date
        - Keep each memory description under 150 characters
        - Memory types: "user" (who they are), "feedback" (how they work), "project" (what they're doing), "reference" (where to find things)
        - Do NOT create memories for information derivable from code or git history
        - Merge into existing memories rather than creating near-duplicates

        ## Phase 4 — Prune (keep knowledge lean)

        Review the MEMORY_UPDATES you're about to output:
        - Are any existing memories now stale or contradicted? Mark them for deletion.
        - Are any new memories redundant with existing ones? Merge instead of creating.
        - Would the total memory count exceed 50? If so, delete the least useful ones.

        ---

        ## Output Format

        ---MORNING---
        (bullet points, or omit if no morning activity)
        ---AFTERNOON---
        (bullet points, or omit if no afternoon activity)
        ---EVENING---
        (bullet points, or omit if no evening activity)
        ---LEARNED---
        (key insights — only if genuinely new/surprising, otherwise omit entirely)
        ---IN_PROGRESS---
        (ongoing work — only if something is clearly unfinished, otherwise omit)
        ---MEMORY_UPDATES---
        [
          {"action": "create", "type": "project", "name": "...", "description": "...(under 150 chars)", "content": "..."},
          {"action": "update", "type": "user", "name": "existing memory name", "description": "...", "content": "..."},
          {"action": "delete", "type": "feedback", "name": "memory name to remove", "description": "", "content": ""}
        ]
        """

        return prompt
    }

    private func summarizeEvents(_ events: [RecordingEvent], maxItems: Int) -> String {
        if events.isEmpty { return "(no activity)" }

        // Deduplicate and compress events for the prompt
        var seen = Set<String>()
        var lines: [String] = []

        for event in events.prefix(maxItems * 3) {
            // Privacy: never send clipboard/keystroke secrets (API keys, emails,
            // card numbers, tokens) to an LLM. Same guard full.md uses.
            if let raw = event.textContent, SensitiveText.isSensitive(raw) { continue }

            let key = "\(event.appName ?? ""):\(event.eventType.rawValue):\(event.textContent?.prefix(50) ?? "")"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let app = event.appName ?? "Unknown"
            let typeLabel = event.eventType == .keystroke ? "typed" : event.eventType.rawValue
            let text = event.textContent.map { String($0.prefix(200)) } ?? ""

            lines.append("[\(app)] \(typeLabel): \(text)")

            if lines.count >= maxItems { break }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - LLM Call

    private func callLLM(prompt: String) async throws -> String {
        try await llm.complete(prompt: prompt)
    }

    // MARK: - Parse Response

    private func parseConsolidationResponse(_ response: String) -> ConsolidatedSummary {
        // Try structured parsing first (---TAG--- format)
        func extractSection(_ tag: String) -> String? {
            // Support both "---TAG---" and "--- TAG ---" (LLM formatting variance)
            let patterns = ["---\(tag)---", "--- \(tag) ---", "---\(tag) ---", "--- \(tag)---"]
            var startIdx: String.Index?

            for pattern in patterns {
                if let range = response.range(of: pattern, options: .caseInsensitive) {
                    startIdx = range.upperBound
                    break
                }
            }
            guard let start = startIdx else { return nil }
            let afterTag = response[start...]

            // Find next section marker
            if let nextDash = afterTag.range(of: "---", options: [], range: afterTag.index(after: afterTag.startIndex)..<afterTag.endIndex) {
                let content = String(afterTag[..<nextDash.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return content.isEmpty ? nil : content
            }
            return String(afterTag).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let morning = extractSection("MORNING")
        let afternoon = extractSection("AFTERNOON")
        let evening = extractSection("EVENING")
        let learnings = extractSection("LEARNED")
        let inProgress = extractSection("IN_PROGRESS")

        // Fallback: if no structured tags found, use the entire response as content
        let hasStructuredContent = morning != nil || afternoon != nil || evening != nil
        let dateStr = Date().formatted(.dateTime.year().month().day())

        var md: [String] = []
        md.append("# \(dateStr)")
        md.append("")

        if hasStructuredContent {
            if let m = morning {
                md.append("## Morning")
                md.append(m)
                md.append("")
            }
            if let a = afternoon {
                md.append("## Afternoon")
                md.append(a)
                md.append("")
            }
            if let e = evening {
                md.append("## Evening")
                md.append(e)
                md.append("")
            }
        } else {
            // LLM didn't follow format — use raw response (still better than empty)
            let cleanResponse = response
                .replacingOccurrences(of: "---MEMORY_UPDATES---", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanResponse.isEmpty {
                md.append(cleanResponse)
                md.append("")
            }
        }

        if let l = learnings {
            md.append("## Learned")
            md.append(l)
            md.append("")
        }
        if let ip = inProgress {
            md.append("## In progress")
            md.append(ip)
            md.append("")
        }

        return ConsolidatedSummary(
            fullMarkdown: md.joined(separator: "\n"),
            morning: morning,
            afternoon: afternoon,
            evening: evening,
            learnings: learnings,
            inProgress: inProgress,
            memoryUpdatesJSON: extractSection("MEMORY_UPDATES")
        )
    }

    // MARK: - Phase 4: Prune & Index

    private func phase4PruneAndIndex(summary: ConsolidatedSummary) throws {
        // Apply memory updates from LLM
        if let updatesJSON = summary.memoryUpdatesJSON,
           let data = updatesJSON.data(using: .utf8),
           let updates = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            for update in updates {
                applyMemoryUpdate(update)
            }
        }

        // Rebuild MEMORY.md index
        try rebuildMemoryIndex()
    }

    private func applyMemoryUpdate(_ update: [String: String]) {
        guard let action = update["action"],
              let name = update["name"],
              let description = update["description"] ?? update["name"] as String?,
              let typeStr = update["type"],
              let type = MemoryEntry.MemoryType(rawValue: typeStr) else { return }

        let content = update["content"] ?? description

        switch action {
        case "create":
            let fileName = name.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .appending(".md")

            let entry = MemoryEntry(
                name: name,
                description: description,
                memoryType: type,
                content: content,
                filePath: "memory/\(fileName)",
                createdAt: Date(),
                updatedAt: Date()
            )
            database.insertMemory(entry)

            // Write file to disk
            let filePath = memoryDir.appendingPathComponent(fileName)
            try? fileManager.createDirectory(at: memoryDir, withIntermediateDirectories: true)
            let fileContent = """
            ---
            name: \(name)
            description: \(description)
            type: \(typeStr)
            ---

            \(content)
            """
            try? fileContent.write(to: filePath, atomically: true, encoding: .utf8)

        case "update":
            var memories = database.fetchAllMemories()
            if let idx = memories.firstIndex(where: { $0.name == name }) {
                memories[idx].content = content
                memories[idx].description = description
                memories[idx].updatedAt = Date()
                database.updateMemory(memories[idx])
            }

        case "delete":
            // Remove from database — stale/contradicted memories should not persist
            let allMemories = database.fetchAllMemories()
            if let target = allMemories.first(where: { $0.name == name }) {
                // Delete file on disk
                let filePath = memoryDir.appendingPathComponent(
                    target.filePath.replacingOccurrences(of: "memory/", with: "")
                )
                try? fileManager.removeItem(at: filePath)
                // Remove from DB (via raw SQL since GRDB delete needs primary key)
                try? database.dbPool.write { db in
                    try db.execute(sql: "DELETE FROM memory_entries WHERE name = ?", arguments: [name])
                }
            }

        default:
            break
        }
    }

    /// Rebuild MEMORY.md index with size limits: 200 lines, 25KB.
    private func rebuildMemoryIndex() throws {
        let memories = database.fetchAllMemories()
        var lines: [String] = ["# MEMORY.md", ""]

        let maxLines = 200
        let maxBytes = 25_000

        for memory in memories {
            let entry = "- [\(memory.name)](\(memory.filePath)) — \(String(memory.description.prefix(150)))"
            lines.append(entry)

            // Enforce line limit
            if lines.count >= maxLines { break }

            // Enforce byte limit
            let currentSize = lines.joined(separator: "\n").utf8.count
            if currentSize >= maxBytes {
                lines.removeLast()
                lines.append("")
                lines.append("<!-- WARNING: MEMORY.md truncated at \(maxBytes / 1000)KB limit. \(memories.count - lines.count + 2) entries omitted. -->")
                break
            }
        }

        var indexContent = lines.joined(separator: "\n")

        // The index is regenerated from the DB (the source of truth) each run, but we
        // never wipe blocks the user added by hand: preserve any human/pinned blocks.
        let existing = (try? String(contentsOf: memoryIndexPath, encoding: .utf8)) ?? ""
        let humanBlocks = ContextBlockFile.parse(existing).blocks.filter { $0.source != .agent }
        if !humanBlocks.isEmpty {
            indexContent += "\n\n" + ContextBlockFile.serialize(header: "", blocks: humanBlocks)
        }

        try fileManager.createDirectory(at: mullOutputDir, withIntermediateDirectories: true)
        try indexContent.write(to: memoryIndexPath, atomically: true, encoding: .utf8)
    }

    // MARK: - File Output

    /// Daily files are now managed by LiveContextGenerator.snapshotDaily().
    /// This method is kept only for database persistence — it no longer writes to disk.
    private func writeDailyFile(_ summary: DailySummary) throws {
        // No-op: LiveContextGenerator owns the daily file.
    }

    // MARK: - 3-Layer File Generation

    /// Generate 3 files with different token budgets:
    ///
    ///   me.md   (~200 tokens) — "Who are you?" Always safe to include.
    ///   now.md  (~500 tokens) — "What are you working on?" Include when relevant.
    ///   full.md (~1500 tokens) — Everything. Use when starting a big new task.
    ///
    /// Usage in any CLAUDE.md:
    ///   Light:  `Read ~/mull/me.md`
    ///   Normal: `Read ~/mull/me.md` + `Read ~/mull/now.md`
    ///   Full:   `Read ~/mull/full.md`
    private func generateMeFile() throws {
        let memories = database.fetchAllMemories()
        let recentSummaries = database.fetchRecentSummaries(limit: 7)
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)

        try fileManager.createDirectory(at: mullOutputDir, withIntermediateDirectories: true)

        // ── Layer A: me.md (~200 tokens) ──
        // Timeless identity. Changes slowly. Safe to always include.
        try generateLayerA(memories: memories, timestamp: timestamp)

        // ── Layer B: now.md (~500 tokens) ──
        // Current context. Changes weekly. Include when task-relevant.
        try generateLayerB(memories: memories, summaries: recentSummaries, timestamp: timestamp)

        // ── Layer C: full.md (~1500 tokens) ──
        // Complete picture. Include when onboarding AI to a new task.
        try generateLayerC(memories: memories, summaries: recentSummaries, timestamp: timestamp)
    }

    /// me.md — "Who are you?" Compact, stable, always safe.
    ///
    /// Curated, not rewritten: the nightly LLM pass updates only its own agent blocks
    /// and shares block ids with the 60s rule-based pass (LiveContextGenerator), so the
    /// two never duplicate or clobber each other, and pinned/human blocks are preserved.
    private func generateLayerA(memories: [MemoryEntry], timestamp: String) throws {
        var agentBlocks: [ContextBlock] = []

        for mem in memories where mem.memoryType == .user {
            agentBlocks.append(ContextBlock(
                id: Curator.memoryBlockID(name: mem.name, description: mem.description),
                source: .agent, content: "- \(mem.description)", agentHash: nil))
        }

        for mem in memories.filter({ $0.memoryType == .feedback }).prefix(5) {
            agentBlocks.append(ContextBlock(
                id: Curator.feedbackBlockID(name: mem.name, description: mem.description),
                source: .agent, content: "- \(mem.description)", agentHash: nil))
        }

        let header = "About the user (auto-updated: \(timestamp)).\nPinned/edited blocks are authoritative; agent blocks are rule-based and may be inaccurate — correct them in place or in me.pinned.md."
        Curator.curate(relativePath: "me.md", header: header,
                       pinnedContent: Curator.pinnedFacts(), agentBlocks: agentBlocks)
    }

    /// now.md — "What are you working on?" Current projects + this week.
    private func generateLayerB(memories: [MemoryEntry], summaries: [DailySummary], timestamp: String) throws {
        var lines: [String] = []
        lines.append("# now.md — What I'm Working On")
        lines.append("<!-- ~500 tokens. Include when task context helps. Updated: \(timestamp) -->")
        lines.append("")

        // Active projects
        let projects = memories.filter { $0.memoryType == .project }
        if !projects.isEmpty {
            lines.append("## Projects")
            for p in projects {
                lines.append("- **\(p.name)**: \(p.description)")
            }
            lines.append("")
        }

        // This week's activity — 1 line per day
        let weekSummaries = summaries.prefix(7)
        if !weekSummaries.isEmpty {
            lines.append("## This Week")
            for s in weekSummaries {
                lines.append("- \(s.dateShort): \(s.preview)")
            }
            lines.append("")
        }

        // Key references
        let refs = memories.filter { $0.memoryType == .reference }
        if !refs.isEmpty {
            lines.append("## References")
            for r in refs.prefix(5) {
                lines.append("- \(r.name): \(r.description)")
            }
            lines.append("")
        }

        // Behavioral patterns (rule-based, no LLM)
        let patterns = AnalyticsEngine(database: database).generatePatternSummary(days: 7)
        if !patterns.isEmpty {
            lines.append(patterns)
        }

        try lines.joined(separator: "\n")
            .write(to: nowFilePath, atomically: true, encoding: .utf8)
    }

    /// full.md — Everything. For onboarding AI to a new major task.
    private func generateLayerC(memories: [MemoryEntry], summaries: [DailySummary], timestamp: String) throws {
        var lines: [String] = []
        lines.append("# full.md — Complete Context")
        lines.append("<!-- ~1500 tokens. Use when starting a big task. Updated: \(timestamp) -->")
        lines.append("")

        // Include me.md content
        if let meContent = try? String(contentsOf: meFilePath, encoding: .utf8) {
            lines.append(meContent)
            lines.append("")
        }

        // Include now.md content (skip header to avoid duplication)
        if let nowContent = try? String(contentsOf: nowFilePath, encoding: .utf8) {
            let body = nowContent.components(separatedBy: "\n")
                .dropFirst(2) // Skip header + token comment
                .joined(separator: "\n")
            lines.append(body)
            lines.append("")
        }

        // Extended: full daily summaries (not just preview)
        if !summaries.isEmpty {
            lines.append("## Daily Details (Last 7 Days)")
            for s in summaries.prefix(7) {
                lines.append("### \(s.dateShort)")
                let detail = s.content.components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .prefix(15)
                    .joined(separator: "\n")
                lines.append(detail)
                lines.append("")
            }
        }

        // Extended: all feedback memories
        let feedback = memories.filter { $0.memoryType == .feedback }
        if !feedback.isEmpty {
            lines.append("## Working Style & Feedback")
            for f in feedback {
                lines.append("- \(f.content)")
            }
            lines.append("")
        }

        // Behavioral patterns — what the user can't see about themselves
        let patterns = BehaviorPatternEngine(database: database).detectPatterns()
        if !patterns.isEmpty {
            lines.append("## Behavioral Patterns (auto-detected)")
            lines.append("These are patterns the user cannot see about themselves. Use them to give better advice:")
            lines.append("")
            for pattern in patterns.prefix(5) {
                lines.append("### \(pattern.title)")
                lines.append("**Insight:** \(pattern.insight)")
                lines.append("**Action:** \(pattern.action)")
                lines.append("**Evidence:** \(pattern.evidence)")
                lines.append("")
            }
        }

        // Knowledge base — decisions, solutions, discoveries
        let knowledgeEntries = database.fetchAllKnowledge()
        if !knowledgeEntries.isEmpty {
            lines.append("## Knowledge Base")
            lines.append("Decisions and solutions I've accumulated:")
            lines.append("")
            for entry in knowledgeEntries.prefix(20) {
                lines.append("### \(entry.topic) [\(entry.project)]")
                lines.append(entry.decision)
                if let reasoning = entry.reasoning, !reasoning.isEmpty {
                    lines.append("Why: \(reasoning)")
                }
                if let rejected = entry.rejected, !rejected.isEmpty {
                    lines.append("Rejected: \(rejected)")
                }
                if let related = entry.relatedProjects, !related.isEmpty {
                    lines.append("Also applies to: \(related)")
                }
                lines.append("")
            }
        }

        try lines.joined(separator: "\n")
            .write(to: fullFilePath, atomically: true, encoding: .utf8)
    }

    // MARK: - Prune Processed Events

    /// Delete raw recording events that have been processed into summaries.
    /// Keeps the last 24 hours as buffer, deletes everything older.
    /// Summaries and memory files are kept forever.
    /// Prune events according to user's retention setting, not a hardcoded value.
    private func pruneProcessedEvents() {
        let retentionSetting = UserDefaults.standard.string(forKey: "dataRetention") ?? "unlimited"
        guard retentionSetting != "unlimited", let days = Int(retentionSetting) else { return }
        try? database.deleteEventsOlderThan(days: days)
    }

    // MARK: - Scheduling

    private var mullTimer: Timer?

    /// Called when a scheduled mull completes. Set by AppState.
    var onSummaryComplete: ((DailySummary) -> Void)?
    var onSummaryFailed: ((Error) -> Void)?

    /// Schedule the nightly consolidation using a proper macOS Timer.
    /// Survives app sleep/wake. Reschedules automatically.
    func scheduleSummary(at hour: Int, minute: Int = 0) {
        mullTimer?.invalidate()

        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute

        guard let scheduledDate = calendar.date(from: components) else { return }

        let fireDate: Date
        if scheduledDate <= Date() {
            guard let next = calendar.date(byAdding: .day, value: 1, to: scheduledDate) else { return }
            fireDate = next
        } else {
            fireDate = scheduledDate
        }

        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task {
                if self.shouldRun() {
                    do {
                        let summary = try await self.runSummary()
                        self.onSummaryComplete?(summary)
                    } catch {
                        self.onSummaryFailed?(error)
                    }
                }
                self.scheduleSummary(at: hour, minute: minute)
            }
        }
        mullTimer = timer
        // Add to common run loop so it fires even during UI tracking
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancelSchedule() {
        mullTimer?.invalidate()
        mullTimer = nil
    }
}

// MARK: - Supporting Types

struct GatheredData {
    let events: [RecordingEvent]
    let morning: [RecordingEvent]
    let afternoon: [RecordingEvent]
    let evening: [RecordingEvent]
    let appGroups: [String: [RecordingEvent]]
}

struct ConsolidatedSummary {
    let fullMarkdown: String
    let morning: String?
    let afternoon: String?
    let evening: String?
    let learnings: String?
    let inProgress: String?
    let memoryUpdatesJSON: String?
}

enum mullError: LocalizedError {
    case missingAPIKey(String)
    case llmFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider): "No API key configured for \(provider). Set it in Settings → AI."
        case .llmFailed(let detail): "LLM call failed: \(detail)"
        }
    }
}
