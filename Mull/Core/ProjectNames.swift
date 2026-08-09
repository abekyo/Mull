import Foundation

/// The single answer to "is this window-title segment the name of a project?"
///
/// Before this existed there were four: `FactExtractor.extractProjectFacts`'s
/// `skipPatterns`, `TimeBlockEngine.isValidLabel`, and two different
/// `invalidProjects` lists in `LiveContextGenerator`. They disagreed with each
/// other, and all four worked the same wrong way — a hand-written blocklist of
/// strings someone had personally been annoyed by ("Welcome", "Untitled",
/// "gpt-4"). A blocklist only ever rejects the noise its author already saw.
/// The vault shipped `元のプロファイル` — Firefox's default profile name, which
/// sits in the title of every Firefox window — as a first-class project, because
/// nobody had thought to add that particular string.
///
/// So the rules here are about *shape* and *evidence*, never vocabulary:
///
///   - shape: a project name is short, is not a filename / URL / email / question,
///     and is not a sentence (`isPlausible`)
///   - evidence: a segment that appears in nearly every title one browser emits
///     is that browser's chrome, whatever language it is written in (`chrome`)
///
/// Foundation-only and dependency-free, so `Entity`, the selection layer and the
/// standalone eval harness can share one definition.
enum ProjectNames {

    /// Window-title separators, widest-first so " — " wins over " - ".
    static let separators = [" — ", " – ", " - ", " | ", " · ", " : "]

    /// Apps that name themselves in their own window title. Matched
    /// case-insensitively; a segment equal to one of these is chrome by
    /// definition, not a project.
    static let appNames: Set<String> = [
        "xcode", "code", "visual studio code", "cursor", "zed", "sublime text",
        "terminal", "iterm2", "warp", "ghostty", "simulator",
        "safari", "google chrome", "chrome", "firefox", "mozilla firefox",
        "arc", "brave browser", "brave", "microsoft edge", "edge",
        "finder", "preview", "system settings", "system preferences",
        "slack", "discord", "messages", "mail", "zoom", "teams", "line",
        "notion", "obsidian", "bear", "notes", "claude", "chatgpt",
        "loginwindow",
    ]
    // Deliberately absent: "mull". mull's own events are already dropped at
    // capture (RecordingService's exclusion list) and in `AnalyticsEngine
    // .isNoiseApp`, so the only titles containing it come from *other* apps —
    // "Mull.xcodeproj — Xcode" — where it is the user's project and listing it
    // here would make mull structurally unable to see the thing being built in
    // front of it.

    /// Apps whose window title is driven by whatever content is open rather than
    /// by what the user is building. A web page title is not a project name, and
    /// a folder name is not a project name — so these apps never contribute
    /// project candidates, and they are the apps the `chrome` rule inspects.
    static let contentDrivenApps: Set<String> = [
        "safari", "google chrome", "chrome", "firefox", "mozilla firefox",
        "arc", "brave browser", "brave", "microsoft edge", "edge", "finder",
    ]

    // MARK: - Shape

    /// Split a window title into its candidate segments.
    static func segments(of title: String) -> [String] {
        for sep in separators where title.contains(sep) {
            return title.components(separatedBy: sep)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return [title.trimmingCharacters(in: .whitespaces)]
    }

    /// Shape gate: could this segment be a project name at all?
    ///
    /// Deliberately contains no list of "bad project names". Everything it
    /// rejects, it rejects for a structural reason that holds in any language.
    static func isPlausible(_ segment: String, excluding apps: Set<String> = []) -> Bool {
        let s = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 2, s.count <= 40 else { return false }

        // The app is not the project.
        if appNames.contains(s.lowercased()) { return false }
        if apps.contains(where: { $0.lowercased() == s.lowercased() }) { return false }

        // A question is something the user asked an assistant, not a thing they
        // are building. (Chat clients put the prompt in the window title.)
        if s.contains("?") || s.contains("？") || s.contains("!") || s.contains("！") { return false }

        // URL, email, filename.
        if s.contains("://") || s.lowercased().hasPrefix("www.") { return false }
        if s.contains("@"), s.contains(".") { return false }
        if isFileName(s) { return false }

        // Purely numeric segments are counters, timestamps or page numbers.
        if s.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "/" }) { return false }

        if isSentence(s) { return false }
        if isPlaceholder(s) { return false }

        return true
    }

    /// The one list in this file, and the only kind that is defensible.
    ///
    /// These are not "strings someone found annoying" — they are the titles a
    /// document-based app emits when there is no document yet. AppKit ships
    /// "Untitled"; first-run windows ship "Welcome". They are a closed,
    /// enumerable category, unlike folder names or a browser profile's name in
    /// an arbitrary locale, which is why those are handled by `chrome` instead.
    ///
    /// The corpus rule cannot catch these: an unsaved document in Pages is not
    /// chrome by any measurement, it just isn't a project either.
    static func isPlaceholder(_ s: String) -> Bool {
        let lower = s.lowercased()
        let exact: Set<String> = [
            "untitled", "untitled document", "no title", "document", "new document",
            "new tab", "new window", "welcome", "getting started", "home", "start",
            "無題", "名称未設定", "新規タブ", "新規書類",
        ]
        if exact.contains(lower) { return true }
        return ["untitled ", "welcome to ", "getting started "].contains { lower.hasPrefix($0) }
    }

    static func isFileName(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count >= 2, let ext = parts.last else { return false }
        // Letters plus optional digits: "swift", but also "mp4", "3gp", "m4a".
        // At least one letter, so "2.0" stays a version number, not a file.
        return ext.count <= 5
            && ext.allSatisfy { $0.isLetter || $0.isNumber }
            && ext.contains(where: \.isLetter)
    }

    /// Sentence detection, for the two writing systems that reach a window title
    /// by different routes.
    ///
    /// Space-delimited scripts: more than four words is prose, not a name.
    ///
    /// Japanese has no spaces, so length alone cannot separate `確定申告アプリ`
    /// (a project) from `修正してください` (a prompt). The discriminator is
    /// hiragana density: Japanese *names* are built from kanji, katakana and
    /// latin (`元のプロファイル` is 1/8 hiragana, `見積書テンプレート` is 0/9),
    /// while Japanese *sentences* are mostly the grammar that binds them
    /// together (`修正してください` is 6/8, `うまくいかない` is 7/7).
    ///
    /// The rule this replaces was `if text.contains("を") { continue }` — a patch
    /// for one user's Claude Code session titles that silently discarded every
    /// window title containing the object particle, i.e. most legitimate
    /// Japanese document and project names.
    static func isSentence(_ s: String) -> Bool {
        if s.contains(" ") {
            let words = s.split(separator: " ")
            if words.count > 4 { return true }
        }

        let hiragana = s.unicodeScalars.filter { (0x3040...0x309F).contains($0.value) }.count
        if hiragana > 0, Double(hiragana) / Double(s.count) > 0.4 { return true }

        return isCaseMarkedClause(s)
    }

    /// The prose that hiragana density cannot see.
    ///
    /// Density works on sentences made of grammar (`修正してください` is 6/8). It
    /// misses the other shape Japanese prose takes: a long noun-heavy clause where
    /// the kanji and katakana carry the meaning and the grammar is two or three
    /// characters. `プロダクトの事業価値と社会的インパクトを検討` is 3/22 hiragana,
    /// which reads as a name by density, and it was shipped as a project — it
    /// appeared under "Working on:" in the block the user pastes into an AI.
    ///
    /// The discriminator is *distinct case particles*. A name takes at most one
    /// (`認証を実装`, `元のプロファイル`); a clause relates several things and needs
    /// two or more (`…の…と…を検討`). `の` is excluded because it is the possessive
    /// and appears in ordinary names.
    ///
    /// The length floor matters: at two or three characters, two of these are
    /// coincidence rather than grammar.
    private static func isCaseMarkedClause(_ s: String) -> Bool {
        guard s.count >= 12 else { return false }
        let caseParticles: Set<Character> = ["は", "が", "を", "に", "へ", "と", "で", "も"]
        return Set(s.filter { caseParticles.contains($0) }).count >= 2
    }

    // MARK: - Evidence

    /// Segments that are an app's chrome rather than anything the user works on.
    ///
    /// Only content-driven apps are inspected, and this is the whole reason the
    /// rule is safe. A browser's title is dictated by the page, so a segment that
    /// survives across nearly every page is furniture: a profile name, a window
    /// name, the browser's own name. An editor's title is dictated by the
    /// project, so the *same* observation there means the opposite — a segment
    /// present in every Xcode title is the project the user has been living in
    /// all week, and blocklisting it would be the worst possible outcome.
    ///
    /// Requires 5 distinct titles before judging: below that, "appears in all of
    /// them" is not evidence of anything.
    static func chrome(in observations: [(app: String, title: String)]) -> Set<String> {
        var titlesByApp: [String: Set<String>] = [:]
        for o in observations where contentDrivenApps.contains(o.app.lowercased()) {
            titlesByApp[o.app.lowercased(), default: []].insert(o.title)
        }

        var chrome: Set<String> = []
        for (_, titles) in titlesByApp where titles.count >= 5 {
            var counts: [String: Int] = [:]
            for title in titles {
                for segment in Set(segments(of: title)) {
                    counts[segment, default: 0] += 1
                }
            }
            let threshold = Int((Double(titles.count) * 0.8).rounded(.up))
            for (segment, count) in counts where count >= threshold {
                chrome.insert(segment)
            }
        }
        return chrome
    }

    /// Ranked project candidates from a corpus of (app, window title) sightings.
    ///
    /// - Parameter minMentions: how many sightings a name needs before mull is
    ///   willing to write it down. A file opened once in passing is not a project.
    static func rank(_ observations: [(app: String, title: String)],
                     minMentions: Int = 5) -> [(name: String, mentions: Int)] {
        let chromeSegments = chrome(in: observations)
        let observedApps = Set(observations.map(\.app))

        var mentions: [String: Int] = [:]
        for o in observations {
            // A web page title and a folder name are not projects.
            guard !contentDrivenApps.contains(o.app.lowercased()) else { continue }
            for segment in Set(segments(of: o.title)) {
                guard !chromeSegments.contains(segment) else { continue }
                guard isPlausible(segment, excluding: observedApps) else { continue }
                mentions[segment, default: 0] += 1
            }
        }

        return mentions
            .filter { $0.value >= minMentions }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (name: $0.key, mentions: $0.value) }
    }
}
