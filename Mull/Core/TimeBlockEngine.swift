import Foundation

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

    let database: EventReading

    /// How long a break can be before returning to the same work counts as a *new*
    /// piece of work. Seconds; `0` turns rejoining off and restores the pure
    /// elapsed-time segmentation described above.
    ///
    /// Read from `Preferences` at construction so both binaries and every surface
    /// agree; tests pass it explicitly so the suite cannot depend on the developer's
    /// own settings.
    let resumeGap: TimeInterval

    init(database: EventReading, resumeGap: TimeInterval = Preferences.resumeGap) {
        self.database = database
        self.resumeGap = resumeGap
    }

    /// Maximum seconds a single inter-event gap can contribute to a block's
    /// `activeDuration`. Events are dense during real activity (keystrokes flush
    /// every ~3s, window titles poll every 5s), so a gap longer than this almost
    /// always means the user paused — only this much of it counts as engaged
    /// time. Blocks still *merge* across gaps up to 180s for a clean timeline;
    /// this cap only governs the activity total, not the visual span.
    static let activeGapCap: TimeInterval = 90

    /// Ten minutes, and the reasoning is worth keeping because the number is the
    /// least interesting part of it.
    ///
    /// The 180s window below asks only "how long since the last event?", so it is
    /// *more* forgiving of switching to Safari for two minutes (one block, flagged
    /// multi-app) than of stepping away from the same file for five (two blocks,
    /// identical captions, drawn as two unrelated cards). Elapsed time alone cannot
    /// tell a break from a boundary. Continuity of the work can, and the task key
    /// that answers it already exists for `analyzDay`.
    ///
    /// Merging across a pause is safe here because the honesty lives elsewhere:
    /// `activeGapCap` means a rejoined break adds at most 90s to `activeDuration`,
    /// so a longer window cannot inflate how long you worked — only the wall-clock
    /// span the calendar draws, which is the truth about when the session ran.
    static let defaultResumeGap: TimeInterval = 600

    /// Generate time blocks for a given day.
    func generateBlocks(for date: Date) -> [TimeBlock] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let events = database.fetchEvents(from: startOfDay, to: min(endOfDay, Date()))
            .filter { event in
                guard let app = event.appName else { return true }
                return !AnalyticsEngine.isNoiseApp(app)
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

                if gap < 180 {
                    // Same app, or a different app within 3 minutes (multitasking):
                    // either way the session continues. absorb() attributes the gap
                    // to the app the user was just in, so the dominant app can be
                    // settled honestly at the end.
                    if segment.app != block.app { block.isMultiApp = true }
                    block.absorb(segment, gap: gap)
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

        // Step 4: Settle each block's face on its dominant app (the comment at the top
        // says "dominant" — before this, the first event's app silently won), then label.
        // Chrome is computed over the whole day first, because the question "is
        // this segment furniture?" can only be answered by looking at the corpus,
        // never at one title.
        for i in 0..<blocks.count {
            blocks[i].finalizeDominantApp()
        }
        let chrome = chromeSegments(in: blocks)
        for i in 0..<blocks.count {
            blocks[i].label = generateLabel(for: blocks[i], chrome: chrome)
        }

        // Step 5: rejoin what a break split. Runs last because it needs the labels
        // and the settled apps to know whether two blocks are the same work — and
        // after the <30s filter, so a break is never bridged by a fragment that was
        // too small to be worth drawing on its own.
        return coalesceResumed(blocks, chrome: chrome)
    }

    /// Put the two halves of an interrupted session back together.
    ///
    /// Adjacent only, and only across a gap the user would call a break: A → B → A
    /// stays three blocks, because merging the two A's would draw a card straight
    /// through the middle of B. And same task only — the key is the one `analyzDay`
    /// groups by, so "resumed the parser after lunch" merges and "stopped the parser,
    /// answered mail" does not.
    private func coalesceResumed(_ blocks: [TimeBlock], chrome: Set<String>) -> [TimeBlock] {
        guard resumeGap > 0, blocks.count > 1 else { return blocks }

        var merged: [TimeBlock] = []
        for block in blocks {
            let gap = merged.last.map { block.start.timeIntervalSince($0.end) } ?? 0
            guard var previous = merged.last, gap >= 0, gap <= resumeGap,
                  continues(previous, block, chrome: chrome)
            else {
                merged.append(block)
                continue
            }
            previous.absorb(block, across: gap)
            merged[merged.count - 1] = previous
        }

        // A rejoined block has context from both halves, so its face and its caption
        // are settled over the whole session rather than over whichever fragment
        // happened to open it.
        for i in merged.indices where !merged[i].pauses.isEmpty {
            merged[i].finalizeDominantApp()
            merged[i].label = generateLabel(for: merged[i], chrome: chrome)
        }
        return merged
    }

    /// Whether the second block is the first one resumed, rather than something new.
    ///
    /// Graded, because the evidence is. Keying this on `normalizeTaskKey` alone —
    /// which is what the first version did — sounds strict and is, but it fails in
    /// the one direction that matters: when no project can be parsed the key falls
    /// back to the *label*, and a label is close to unique per block. Two stretches
    /// of browsing have two page titles, two stretches of terminal work have none at
    /// all, and both split forever however short the break. Which is the report:
    /// "the same app is open and it still says these are separate tasks".
    ///
    /// So the question asked here is not "can mull prove these are the same work?"
    /// but "can mull show they are *different* work?" — and only a named, different
    /// project can show that.
    private func continues(_ previous: TimeBlock, _ next: TimeBlock, chrome: Set<String>) -> Bool {
        // Two blocks that each name a project continue each other only if it is the
        // same project. Leaving Nocturne for PantryApp is a boundary however short
        // the gap, and this is the case worth being strict about.
        if let before = projectName(of: previous, chrome: chrome),
           let after = projectName(of: next, chrome: chrome) {
            return before == after
        }

        // Otherwise there is nothing in the record that separates them, and the app
        // still being in front of the user is the strongest thing left. Splitting
        // here would assert a boundary nothing observed — which §7.1 puts on the
        // wrong side of the line between an observation and a claim.
        if previous.app == next.app { return true }

        // Different apps, at most one of them naming anything: fall back to the
        // grouping `analyzDay` uses, so a project followed into a second app across a
        // break still reads as one session.
        return normalizeTaskKey(previous, chrome: chrome) == normalizeTaskKey(next, chrome: chrome)
    }

    /// The project a block can be *shown* to be about, or nil when its titles do not
    /// name one.
    ///
    /// Content-driven apps never name one, by the same rule `ProjectNames.rank` uses
    /// to keep them out of the vault: a web page title is not a project. Without this
    /// the parser reads "Swift Concurrency — Apple Developer" as the project "Swift
    /// Concurrency", and every page a reader opens becomes a different piece of work.
    private func projectName(of block: TimeBlock, chrome: Set<String>) -> String? {
        guard !ProjectNames.contentDrivenApps.contains(block.app.lowercased()),
              let title = block.topWindowTitle,
              let project = parseWindowTitle(title, app: block.app).project,
              isValidLabel(project, chrome: chrome)
        else { return nil }
        return project.lowercased()
    }

    /// Generate a human-readable label for a time block.
    /// Priority: project name > file name > window title > clipboard > app name
    private func generateLabel(for block: TimeBlock, chrome: Set<String>) -> String {
        if let topTitle = block.topWindowTitle {
            let parsed = parseWindowTitle(topTitle, app: block.app)
            // A segment that is really the app's own furniture is not a project,
            // whatever position it occupies in the title.
            let project = parsed.project.flatMap { isValidLabel($0, chrome: chrome) ? $0 : nil }
            // Prefer "Project — File" format if both exist. `task` stands in for the
            // file when the window is not on one, so a card reads "Mull — the thing
            // you were doing" rather than "Mull" over and over down the column.
            if let project, let detail = parsed.file ?? parsed.task {
                return "\(project) — \(detail)"
            }
            if let project {
                return project
            }
            if let file = parsed.file ?? parsed.task {
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
        /// What the window is about when it is not a file — the conversation a
        /// coding agent named, the document, the ticket. Captions the block beside
        /// the project; deliberately *not* folded into `file`, which feeds
        /// "resume at:" and has to stay a path someone can actually open.
        var task: String?
        var display: String   // cleaned display string
    }

    /// Parse window titles from common app formats:
    ///   VS Code: "filename.swift — ProjectName"
    ///   VS Code + Claude: "Chat title — ProjectName"
    ///   Xcode: "ProjectName — filename.swift — Xcode"
    ///   Browser: "Page Title — Site Name"
    private func parseWindowTitle(_ title: String, app: String) -> ParsedTitle {
        let separators = [" — ", " - ", " | "]
        // An editor puts the project last and what you are looking at first; a
        // browser puts the page first and the site last. Which end to trust is the
        // whole difference, and it is a property of the app — the same rule
        // `ProjectNames` uses to keep page titles out of the vault.
        let projectIsLast = !ProjectNames.contentDrivenApps.contains(app.lowercased())

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
                    // Last project-like segment for an editor, first for a browser.
                    //
                    // Keeping the *first* everywhere is what made VS Code's
                    // "「Mdファイル編集時のサイドバー位置ずれ問題」 — Mull" report the project as the
                    // Claude Code conversation. The header of this function has
                    // documented the shape as "Chat title — ProjectName" all along;
                    // only the fallback below implemented it, and it never ran
                    // because the chat title had already claimed the slot. One day
                    // of real capture produced 75 distinct titles for one editor,
                    // so every conversation read as a separate project: separate
                    // cards, separate entries in `get_projects`, and a session that
                    // could not be rejoined across a four-minute break.
                    project = (projectIsLast || project == nil) ? part : project
                }
            }

            // VS Code pattern: last part (after —) is usually the project
            if project == nil, let lastPart = parts.last {
                if isProjectName(lastPart) {
                    project = lastPart
                }
            }

            // If we only found one meaningful part, use it
            if project == nil && file == nil {
                // Take the last part as project (VS Code convention)
                project = parts.last
            }

            // Settling the project on the last segment would otherwise throw away
            // the specific half of the title, and "Mull" six times in a column says
            // less than the old (wrongly grouped) captions did.
            var task: String?
            if projectIsLast, file == nil, let first = parts.first, first != project {
                task = first
            }

            return ParsedTitle(project: project, file: file, task: task,
                               display: parts.joined(separator: " — "))
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
        guard parts.count >= 2, let ext = parts.last else { return false }
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

    /// Engaged time, in seconds — the sum of inter-event gaps with each gap
    /// capped (see `TimeBlockEngine.activeGapCap`). Unlike `duration` (raw
    /// wall-clock `end − start`, used for the calendar geometry), this excludes
    /// long idle pauses so "deep work" counts and "what you mainly did" totals
    /// reflect real activity, not time the user stepped away mid-block.
    var activeDuration: TimeInterval = 0

    /// The breaks this block was rejoined across, in order — empty unless
    /// `TimeBlockEngine.coalesceResumed` put an interrupted session back together.
    ///
    /// Carried rather than discarded because a merged card claims a span the user was
    /// not at the machine for the whole of, and CLAUDE.md §7.1 draws the line at what
    /// can be shown to come from the record. "09:00–11:30, away 5m" is an
    /// observation; "09:00–11:30" alone is a slightly larger claim than mull holds.
    var pauses: [DateInterval] = []

    /// Wall-clock seconds inside this block's span with no events in them at all.
    var pausedDuration: TimeInterval { pauses.reduce(0) { $0 + $1.duration } }

    // Context accumulation
    private var windowTitles: [String: Int] = [:]
    private var windowTitleApps: [String: String] = [:]   // title → app it belongs to
    private var clipboardTexts: [String] = []
    private var keystrokeCount: Int = 0

    // Per-app engaged time inside this block. Each inter-event gap is attributed to
    // the app the user was in *before* the switch (they were using it until they left),
    // capped like activeDuration so an idle pause doesn't crown the wrong app.
    private var appDurations: [String: TimeInterval] = [:]
    private var lastSegmentApp: String = ""

    var duration: TimeInterval { end.timeIntervalSince(start) }

    var durationFormatted: String {
        let minutes = Int(duration / 60)
        if minutes < 1 { return VaultText.t("<1m", "1分未満") }
        return VaultText.duration(minutes: minutes)
    }

    /// Shown to a person, so it follows their clock — see `TimeFormat`. The MCP
    /// tools spell their own times with `TimeFormat.machine`, which stays 24-hour.
    var startFormatted: String { TimeFormat.person(start) }

    var endFormatted: String { TimeFormat.person(end) }

    init(from segment: EventSegment) {
        self.app = segment.app
        self.start = segment.timestamp
        self.end = segment.timestamp
        self.eventCount = 1
        self.lastSegmentApp = segment.app
        addContext(segment)
    }

    /// Extend the block with the next event: advance the end, attribute the gap to the
    /// app the user was just in, and accumulate context. Single entry point for both the
    /// same-app and different-app (multitasking) cases in the engine loop.
    mutating func absorb(_ segment: EventSegment, gap: TimeInterval) {
        let engaged = min(gap, TimeBlockEngine.activeGapCap)
        end = segment.timestamp
        eventCount += 1
        activeDuration += engaged
        appDurations[lastSegmentApp, default: 0] += engaged
        lastSegmentApp = segment.app
        addContext(segment)
    }

    /// Rejoin a later block onto this one across a break, recording the break.
    ///
    /// The gap is attributed exactly as `absorb(_:gap:)` attributes an inter-event
    /// one — capped at `activeGapCap`, credited to the app the user was last in — so
    /// a rejoined session reports the same engaged time it would have reported had
    /// the break never been treated as a boundary. The pause lengthens `duration`,
    /// which is wall clock and should say so, and not `activeDuration`, which is the
    /// number every "how long did you work" surface reads.
    mutating func absorb(_ other: TimeBlock, across gap: TimeInterval) {
        let engaged = min(max(gap, 0), TimeBlockEngine.activeGapCap)

        pauses.append(DateInterval(start: end, end: max(other.start, end)))
        pauses.append(contentsOf: other.pauses)

        activeDuration += engaged + other.activeDuration
        appDurations[lastSegmentApp, default: 0] += engaged
        for (name, seconds) in other.appDurations { appDurations[name, default: 0] += seconds }
        lastSegmentApp = other.lastSegmentApp

        for (title, count) in other.windowTitles { windowTitles[title, default: 0] += count }
        windowTitleApps.merge(other.windowTitleApps) { _, new in new }
        clipboardTexts.append(contentsOf: other.clipboardTexts)
        keystrokeCount += other.keystrokeCount

        eventCount += other.eventCount
        isMultiApp = isMultiApp || other.isMultiApp || other.app != app
        end = other.end
    }

    /// Settle `app` on the app the user actually spent the most engaged time in — the
    /// block's true dominant app, not whichever app happened to open it. Called once by
    /// the engine after a block is complete; name, colour and label all follow from it.
    mutating func finalizeDominantApp() {
        if let dominant = appDurations.max(by: { $0.value < $1.value })?.key,
           appDurations[dominant, default: 0] > 0 {
            app = dominant
        }
    }

    /// Other apps the user touched in this block, by engaged time. Only dwells that
    /// register meaningfully (≥30s) — a half-second bounce through Finder isn't a story.
    var secondaryApps: [String] {
        appDurations
            .filter { $0.key != app && $0.value >= 30 }
            .sorted { $0.value > $1.value }
            .map(\.key)
    }

    mutating func addContext(_ segment: EventSegment) {
        switch segment.eventType {
        case .screenText, .appSwitch:
            if !segment.windowTitle.isEmpty {
                windowTitles[segment.windowTitle, default: 0] += 1
                windowTitleApps[segment.windowTitle] = segment.app
            }
        case .clipboard:
            if segment.text.count > 5 {
                clipboardTexts.append(segment.text)
            }
        case .keystroke:
            keystrokeCount += 1
        case .windowBody, .audio:
            // Body snapshots are territory for search/synthesis, not an activity
            // signal — letting them drive time blocks would double-count work the
            // title/keystroke channels already represent.
            break
        }
    }

    /// Most frequent window title, preferring titles that belong to the dominant app —
    /// so a Safari page name never captions a block whose face is Xcode.
    ///
    /// Ties break on the title itself rather than on `Dictionary`'s iteration order,
    /// which is seeded per process: two titles seen the same number of times used to
    /// caption the same block differently between one launch and the next. Rejoining
    /// two halves of a session is the case that produces exact ties routinely.
    var topWindowTitle: String? {
        let dominantOwned = windowTitles.filter { windowTitleApps[$0.key] == app }
        if let best = mostSeen(in: dominantOwned) { return best }
        return mostSeen(in: windowTitles)
    }

    private func mostSeen(in counts: [String: Int]) -> String? {
        counts.max { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }?.key
    }

    var topClipboard: String? {
        clipboardTexts.last.map { Redactor.mask($0) }
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

        lines.append(VaultText.t("What you mainly did today:", "今日おもにしたこと:"))
        for activity in mainActivities where !AnalyticsEngine.isNoiseApp(activity.app) {
            lines.append("- \(activity.label) (\(activity.durationFormatted), \(activity.app))")
        }

        let filteredOther = otherActivities.filter { !AnalyticsEngine.isNoiseApp($0.app) }
        if !filteredOther.isEmpty {
            lines.append("")
            lines.append(VaultText.t("Also:", "ほかに:"))
            for activity in filteredOther {
                lines.append("- \(activity.label) (\(activity.durationFormatted), \(activity.app))")
            }
        }

        lines.append("")
        lines.append(VaultText.t("App usage:", "アプリの使用:"))
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
        if minutes < 1 { return VaultText.t("<1m", "1分未満") }
        return VaultText.duration(minutes: minutes)
    }

}

extension TimeBlockEngine {

    /// Analyze a day's blocks and extract "what you mainly did" + supporting facts.
    func analyzDay(for date: Date) -> DailyActivity {
        let blocks = generateBlocks(for: date)
        guard !blocks.isEmpty else {
            return DailyActivity(mainActivities: [], otherActivities: [], totalDuration: 0, appBreakdown: [])
        }

        // Step 1: Group blocks by project/task (same label = same task)
        let chrome = chromeSegments(in: blocks)
        var taskGroups: [String: [TimeBlock]] = [:]
        for block in blocks {
            let key = normalizeTaskKey(block, chrome: chrome)
            taskGroups[key, default: []].append(block)
        }

        // Step 2: Create ActivitySummary per group, sorted by total duration
        let activities = taskGroups.map { key, blocks -> ActivitySummary in
            let totalDuration = blocks.reduce(0.0) { $0 + $1.activeDuration }
            let totalEvents = blocks.reduce(0) { $0 + $1.eventCount }
            let primaryApp = mostCommonApp(in: blocks)
            let label = bestLabel(for: blocks, key: key, chrome: chrome)

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

        // Step 4: App breakdown (engaged time, not wall-clock)
        var appDurations: [String: TimeInterval] = [:]
        for block in blocks {
            appDurations[block.app, default: 0] += block.activeDuration
        }
        let totalDuration = blocks.reduce(0.0) { $0 + $1.activeDuration }
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
    private func normalizeTaskKey(_ block: TimeBlock, chrome: Set<String>) -> String {
        // If we have a parsed title with a project, use that
        if let topTitle = block.topWindowTitle {
            let parsed = parseWindowTitle(topTitle, app: block.app)
            if let project = parsed.project, isValidLabel(project, chrome: chrome) {
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

    private func bestLabel(for blocks: [TimeBlock], key: String, chrome: Set<String>) -> String {
        // Find the most specific label from the longest block
        let sorted = blocks.sorted { $0.duration > $1.duration }
        for block in sorted {
            if let title = block.topWindowTitle {
                let parsed = parseWindowTitle(title, app: block.app)
                // Prefer "Project — File" if both exist
                if let project = parsed.project, let file = parsed.file {
                    if isValidLabel(project, chrome: chrome) { return "\(project) — \(file)" }
                }
                if let project = parsed.project, isValidLabel(project, chrome: chrome) {
                    return project
                }
            }
            if let label = sorted.first?.label, !label.isEmpty, label != sorted.first?.app,
               isValidLabel(label, chrome: chrome) {
                return label
            }
        }
        return key.prefix(1).uppercased() + key.dropFirst()
    }

    /// Whether a label may be presented as the thing the user was working on.
    ///
    /// Shape comes from `ProjectNames`, shared with `FactExtractor` and `Entity`
    /// so the three cannot drift apart again. `chrome` is the corpus half: it is
    /// what stops `元のプロファイル` — Firefox's default profile name, present in
    /// the title of every Firefox window — from being promoted to a project, as
    /// it was in the shipped vault. No blocklist can catch that; it is a
    /// different string in every locale.
    private func isValidLabel(_ label: String, chrome: Set<String>) -> Bool {
        if chrome.contains(label) { return false }
        return ProjectNames.isPlausible(label)
    }

    /// Chrome segments observed across a set of blocks.
    private func chromeSegments(in blocks: [TimeBlock]) -> Set<String> {
        ProjectNames.chrome(in: blocks.compactMap { block in
            guard let title = block.topWindowTitle else { return nil }
            return (app: block.app, title: title)
        })
    }
}

struct EventSegment {
    let timestamp: Date
    let app: String
    let windowTitle: String
    let eventType: RecordingEvent.EventType
    let text: String
}

// MARK: - Home Dashboard Data

struct ProjectSession: Identifiable {
    let id = UUID()
    let date: Date
    let duration: TimeInterval
    let mainLabel: String
    let app: String

    var durationFormatted: String {
        let minutes = Int(duration / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    var dateFormatted: String {
        let f = DateFormatter()
        f.dateFormat = "M/d (EEE)"
        return f.string(from: date)
    }
}

struct ProjectSnapshot: Identifiable {
    let id = UUID()
    let name: String
    let lastActiveDate: Date
    let lastFile: String?
    let lastClipboard: String?
    let totalDuration: TimeInterval
    let primaryApp: String
    let eventCount: Int
    let daysSinceActive: Int
    let sessions: [ProjectSession]

    var totalDurationFormatted: String {
        let minutes = Int(totalDuration / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    var lastActiveFormatted: String {
        if daysSinceActive == 0 { return VaultText.t("Today", "今日") }
        if daysSinceActive == 1 { return VaultText.t("Yesterday", "昨日") }
        return VaultText.t("\(daysSinceActive) days ago", "\(daysSinceActive)日前")
    }

}

struct DaySnapshot: Identifiable {
    let date: Date
    let totalDuration: TimeInterval
    let mainProject: String?
    let eventCount: Int
    let isToday: Bool
    var id: Date { date }

    /// The weekday abbreviation in the reader's own language.
    ///
    /// `"EEE"` is an English-shaped request — it returned "Sun" on a Japanese Mac
    /// that writes 日. The standalone symbols are the form meant to appear as a
    /// column heading rather than inside a sentence, which is exactly the use here.
    var dayName: String {
        let cal = Calendar.current
        let index = cal.component(.weekday, from: date) - 1
        return cal.shortStandaloneWeekdaySymbols[index]
    }

    /// The bare day digit. Deliberately not a date *format*: a localised "d" comes
    /// back as 19日 in Japanese, and this is rendered inside a small fixed circle
    /// that has room for the number and nothing else.
    var dayNumber: String {
        String(Calendar.current.component(.day, from: date))
    }

    var durationFormatted: String {
        let minutes = Int(totalDuration / 60)
        if minutes < 1 { return "" }
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m > 0 ? "\(h)h\(m)m" : "\(h)h"
    }
}

struct BriefingItem: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let subtext: String?
    let emphasis: Bool

    init(icon: String, text: String, subtext: String? = nil, emphasis: Bool = false) {
        self.icon = icon
        self.text = text
        self.subtext = subtext
        self.emphasis = emphasis
    }
}

/// Week-over-week comparison data for the briefing.
struct WeekComparison {
    let thisWeekDuration: TimeInterval
    let lastWeekDuration: TimeInterval   // same point in last week (e.g. Mon-Wed vs last Mon-Wed)
    let lastWeekFullDuration: TimeInterval // full last week
    let thisWeekDeepBlocks: Int          // 2h+ uninterrupted blocks
    let lastWeekDeepBlocks: Int
    let thisWeekContextSwitches: Int     // number of app switches
    let lastWeekContextSwitches: Int

    var durationDelta: TimeInterval { thisWeekDuration - lastWeekDuration }
    var durationDeltaPercent: Double {
        guard lastWeekDuration > 0 else { return 0 }
        return durationDelta / lastWeekDuration * 100
    }

    var thisWeekHours: String { formatDuration(thisWeekDuration) }
    var lastWeekHours: String { formatDuration(lastWeekDuration) }
    var deltaFormatted: String {
        let delta = abs(durationDelta)
        let str = formatDuration(delta)
        return durationDelta >= 0 ? "+\(str)" : "-\(str)"
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        VaultText.duration(seconds: d)
    }
}

extension TimeBlockEngine {

    /// Detect projects from the last N days of time blocks.
    func projectSnapshots(days: Int = 14) -> [ProjectSnapshot] {
        let calendar = Calendar.current
        let now = Date()

        struct ProjectAccum {
            var displayName: String
            var lastDate: Date
            var files: [String] = []
            var clipboards: [String] = []
            var duration: TimeInterval = 0
            var apps: [String: TimeInterval] = [:]
            var events: Int = 0
            var sessions: [ProjectSession] = []
        }

        var accum: [String: ProjectAccum] = [:]

        for dayOffset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let blocks = generateBlocks(for: date)

            var dayProjectDuration: [String: (duration: TimeInterval, label: String, app: String)] = [:]
            let chrome = chromeSegments(in: blocks)

            for block in blocks {
                let key = normalizeTaskKey(block, chrome: chrome)

                var data = accum[key] ?? ProjectAccum(
                    displayName: block.label.isEmpty ? block.app : block.label,
                    lastDate: block.end
                )

                if block.end > data.lastDate {
                    data.lastDate = block.end
                    if !block.label.isEmpty { data.displayName = block.label }
                }

                if let title = block.topWindowTitle {
                    let parsed = parseWindowTitle(title, app: block.app)
                    if let file = parsed.file { data.files.append(file) }
                }
                if let clip = block.topClipboard {
                    data.clipboards.append(clip)
                }

                // Engaged time, not wall clock. These totals are shown as how long
                // was spent on a project — `analyzDay` has always summed
                // `activeDuration` for the same question, and a block can now span a
                // rejoined break, which wall clock would bill to the project.
                data.duration += block.activeDuration
                data.apps[block.app, default: 0] += block.activeDuration
                data.events += block.eventCount

                accum[key] = data

                var dayData = dayProjectDuration[key] ?? (0, "", "")
                dayData.duration += block.activeDuration
                if dayData.label.isEmpty { dayData.label = block.label }
                if dayData.app.isEmpty { dayData.app = block.app }
                dayProjectDuration[key] = dayData
            }

            for (key, dayData) in dayProjectDuration {
                let session = ProjectSession(
                    date: date,
                    duration: dayData.duration,
                    mainLabel: dayData.label,
                    app: dayData.app
                )
                accum[key]?.sessions.append(session)
            }
        }

        return accum.compactMap { key, data in
            guard data.events >= 3 else { return nil }
            let primaryApp = data.apps.max(by: { $0.value < $1.value })?.key ?? "Unknown"
            let daysSince = calendar.dateComponents([.day], from: data.lastDate, to: now).day ?? 0

            let parts = data.displayName.components(separatedBy: " — ")
            let displayName = parts.first ?? data.displayName

            return ProjectSnapshot(
                name: displayName,
                lastActiveDate: data.lastDate,
                lastFile: data.files.last,
                lastClipboard: data.clipboards.last.map { Redactor.mask(String($0.prefix(80))) },
                totalDuration: data.duration,
                primaryApp: primaryApp,
                eventCount: data.events,
                daysSinceActive: daysSince,
                sessions: data.sessions.sorted { $0.date > $1.date }
            )
        }
        .sorted { $0.lastActiveDate > $1.lastActiveDate }
    }

    /// Generate day-by-day snapshots for a week starting from a given Monday.
    private func weekSnapshotsFrom(monday: Date) -> [DaySnapshot] {
        let calendar = Calendar.current
        let now = Date()

        return (0..<7).compactMap { offset -> DaySnapshot? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: monday) else { return nil }
            let isToday = calendar.isDateInToday(date)

            if date > now && !isToday {
                return DaySnapshot(date: date, totalDuration: 0, mainProject: nil, eventCount: 0, isToday: false)
            }

            let analysis = analyzDay(for: date)
            let mainProject = analysis.mainActivities.first.map { act -> String in
                let parts = act.label.components(separatedBy: " — ")
                return parts.first ?? act.label
            }

            return DaySnapshot(
                date: date,
                totalDuration: analysis.totalDuration,
                mainProject: mainProject,
                eventCount: analysis.mainActivities.reduce(0) { $0 + $1.eventCount }
                    + analysis.otherActivities.reduce(0) { $0 + $1.eventCount },
                isToday: isToday
            )
        }
    }

    /// Generate day-by-day snapshots for the current week (Mon-Sun).
    func weekSnapshots() -> [DaySnapshot] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today) else { return [] }
        return weekSnapshotsFrom(monday: monday)
    }

    /// Compare this week (up to today) vs same point in last week.
    func weekComparison() -> WeekComparison {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7

        guard let thisMonday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today),
              let lastMonday = calendar.date(byAdding: .day, value: -7, to: thisMonday) else {
            return WeekComparison(thisWeekDuration: 0, lastWeekDuration: 0, lastWeekFullDuration: 0,
                                  thisWeekDeepBlocks: 0, lastWeekDeepBlocks: 0,
                                  thisWeekContextSwitches: 0, lastWeekContextSwitches: 0)
        }

        let thisWeek = weekSnapshotsFrom(monday: thisMonday)
        let lastWeek = weekSnapshotsFrom(monday: lastMonday)

        // Only compare up to the same day-of-week
        let daysElapsed = daysFromMonday + 1
        let thisWeekSlice = thisWeek.prefix(daysElapsed)
        let lastWeekSlice = lastWeek.prefix(daysElapsed)

        let thisTotal = thisWeekSlice.reduce(0.0) { $0 + $1.totalDuration }
        let lastTotal = lastWeekSlice.reduce(0.0) { $0 + $1.totalDuration }
        let lastFull = lastWeek.reduce(0.0) { $0 + $1.totalDuration }

        // Deep work blocks: blocks >= 2 hours. Measured in engaged time, as
        // `BehaviorPatternEngine.detectContextSwitchCorrelation` measures it — the two
        // counted the same concept two different ways, and wall clock was the wrong
        // one of them even before a block could span a break.
        func countDeepBlocks(from monday: Date, days: Int) -> Int {
            var count = 0
            for offset in 0..<days {
                guard let date = calendar.date(byAdding: .day, value: offset, to: monday) else { continue }
                let blocks = generateBlocks(for: date)
                count += blocks.filter { $0.activeDuration >= 7200 }.count
            }
            return count
        }

        // Context switches: count app switch events
        func countSwitches(from monday: Date, days: Int) -> Int {
            var count = 0
            for offset in 0..<days {
                guard let date = calendar.date(byAdding: .day, value: offset, to: monday) else { continue }
                let start = calendar.startOfDay(for: date)
                guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
                let events = database.fetchEvents(from: start, to: min(end, now))
                count += events.filter { $0.eventType == .appSwitch }.count
            }
            return count
        }

        let thisDeep = countDeepBlocks(from: thisMonday, days: daysElapsed)
        let lastDeep = countDeepBlocks(from: lastMonday, days: daysElapsed)
        let thisSwitches = countSwitches(from: thisMonday, days: daysElapsed)
        let lastSwitches = countSwitches(from: lastMonday, days: daysElapsed)

        return WeekComparison(
            thisWeekDuration: thisTotal,
            lastWeekDuration: lastTotal,
            lastWeekFullDuration: lastFull,
            thisWeekDeepBlocks: thisDeep,
            lastWeekDeepBlocks: lastDeep,
            thisWeekContextSwitches: thisSwitches,
            lastWeekContextSwitches: lastSwitches
        )
    }
}
