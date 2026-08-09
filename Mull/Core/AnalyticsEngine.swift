import Foundation

/// Rule-based analytics engine. No LLM. Pure counting and pattern detection.
///
/// Analyzes recorded events to find:
///   1. Word frequency — what keywords appear most in your typing/clipboard
///   2. App usage patterns — what apps you use, when, how long
///   3. Work rhythm — peak hours, patterns by day of week
///   4. Topic clusters — groups of related words that appear together
///   5. Language mix — ratio of Japanese / English / code
///
/// Results feed into me.md/now.md so AI understands your patterns without being told.
final class AnalyticsEngine {

    private let database: DatabaseService

    init(database: DatabaseService) {
        self.database = database
    }

    // MARK: - Word Frequency

    /// Top keywords from keystrokes + clipboard, weighted by recency.
    func topKeywords(days: Int = 7, limit: Int = 30) -> [KeywordStat] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let events = database.fetchEvents(from: since, to: Date())

        let textEvents = events.filter { $0.eventType == .keystroke || $0.eventType == .clipboard }

        var wordCounts: [String: Int] = [:]
        let stopWords = Self.allStopWords

        for event in textEvents {
            guard let text = event.textContent else { continue }
            guard let app = event.appName, !Self.isNoiseApp(app) else { continue }
            // Skip synthetic test/QA input (also cleans data recorded before the
            // recording-gate filter existed).
            if TestInput.isLikelyTestInput(text) { continue }
            // Skip noise sources
            if MarkdownDoc.isGeneratedByMull(text) { continue }
            if text.hasPrefix("/Users/") || text.hasPrefix("Screenshot ") { continue }
            if text.contains("Conditional downcast") || text.contains("Validation failed") { continue }
            if text.hasPrefix("#") && text.contains("0x") { continue }
            // Skip URLs and URL fragments (Search Console data, links, etc.)
            if text.contains("http://") || text.contains("https://") { continue }
            if text.contains(".org/") || text.contains(".com/") || text.contains(".net/") { continue }
            // Skip HTML/structured data noise
            if text.contains("インデックス登録") || text.contains("クロール") { continue }
            if text.contains("noindex") || text.contains("canonical") { continue }
            // Skip un-converted romaji from keystroke events.
            //
            // A keystroke buffer is what the fingers did, not what was written: on
            // a Japanese IME it is the pre-conversion romaji, and mull captures it
            // before the space bar turns it into kana. The old rule only caught
            // fragments under 5 characters, so `deknanngaete`, `karahodotooi` and
            // `tukurenaidarouk` sailed through and were published as the user's
            // "focus topics" — the same reason `CurrentState` and `ProactiveLoop`
            // exclude keystroke events from anything a person reads.
            //
            // The discriminator is shape, not length: an IME buffer is a single
            // unbroken latin run. Real typed English has spaces, and confirmed
            // Japanese has kana or kanji, so both survive.
            if event.eventType == .keystroke,
               !text.contains(" "), !TextScript.containsCJK(text) { continue }
            // Skip long unbroken strings (Japanese clipboard text with no spaces = 1 giant "word")
            if !text.contains(" ") && text.count > 20 { continue }
            let words = tokenize(text)
            for word in words {
                let lower = word.lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !lower.isEmpty else { continue }
                guard lower.count > 2 else { continue } // Skip 1-2 char words
                guard !stopWords.contains(lower) else { continue }
                // Skip pure numbers
                guard !lower.allSatisfy(\.isNumber) else { continue }
                // Skip file paths
                guard !lower.contains("/") else { continue }
                // Skip command-like fragments (e.g. "着手してください", "解消せよ")
                if lower.hasSuffix("ください") || lower.hasSuffix("しなさい") || lower.hasSuffix("せよ") { continue }
                wordCounts[lower, default: 0] += 1
            }
        }

        return wordCounts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { KeywordStat(word: $0.key, count: $0.value) }
    }

    /// Frequently typed/copied phrases (2-3 word combinations).
    func topPhrases(days: Int = 7, limit: Int = 15) -> [KeywordStat] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let events = database.fetchEvents(from: since, to: Date())
            .filter { $0.eventType == .keystroke || $0.eventType == .clipboard }

        var phraseCounts: [String: Int] = [:]

        for event in events {
            guard let text = event.textContent else { continue }
            guard let app = event.appName, !Self.isNoiseApp(app) else { continue }
            if TestInput.isLikelyTestInput(text) { continue }
            if MarkdownDoc.isGeneratedByMull(text) || text.hasPrefix("/Users/") { continue }
            if text.contains("http://") || text.contains("https://") { continue }
            if text.contains(".org/") || text.contains(".com/") || text.contains(".net/") { continue }
            if text.hasPrefix("Screenshot ") || text.contains("Validation failed") { continue }
            // Skip long unbroken Japanese text (would create giant "phrases")
            if !text.contains(" ") && text.count > 20 { continue }
            let words = tokenize(text)
            // Bigrams
            for i in 0..<max(0, words.count - 1) {
                let phrase = "\(words[i]) \(words[i+1])".lowercased()
                guard phrase.count > 4 else { continue }
                phraseCounts[phrase, default: 0] += 1
            }
            // Trigrams
            for i in 0..<max(0, words.count - 2) {
                let phrase = "\(words[i]) \(words[i+1]) \(words[i+2])".lowercased()
                phraseCounts[phrase, default: 0] += 1
            }
        }

        // Filter noise phrases
        let noisePatterns = ["screenshot", "2024", "2025", "2026", "2027",
                             "at am", "at pm", "png", "jpg", "jpeg",
                             "mull is", "events captured",
                             "cfbundle", "info.plist",
                             "着手して", "解消して", "ください", "しなさい",
                             "phase ", "残り"]

        return phraseCounts
            .filter { $0.value >= 3 }
            .filter { phrase in
                let key = phrase.key
                let words = key.components(separatedBy: " ")
                // Skip empty or near-empty words
                if words.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return false }
                // Skip if ANY word in the phrase is a pure number
                if words.contains(where: { $0.allSatisfy(\.isNumber) }) { return false }
                // Skip if phrase contains noise pattern
                if noisePatterns.contains(where: { key.contains($0) }) { return false }
                // Skip if all words are < 3 chars (e.g. "at am")
                if words.allSatisfy({ $0.count < 3 }) { return false }
                return true
            }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { KeywordStat(word: $0.key, count: $0.value) }
    }

    // MARK: - App Usage Patterns

    /// Apps to exclude from analytics output.
    ///
    /// Matched case-insensitively via `isNoiseApp`. `appName` comes from
    /// `NSRunningApplication.localizedName`, which is "Mull" (project.yml sets
    /// PRODUCT_NAME: Mull) — a case-sensitive `Set.contains("mull")` never
    /// matched it, so mull's own activity was being counted in the user's
    /// analytics. The list previously held "mull" twice, which a Set silently
    /// deduped, hiding the fact that the capitalized name was never covered.
    static let noiseApps: Set<String> = [
        "mull", "usernotificationcenter", "notificationcenter",
        "securityagent", "loginwindow", "universalaccessauthwarn",
        "system settings", "systempreferences",
    ]

    /// Whether this app should be excluded from analytics.
    static func isNoiseApp(_ app: String) -> Bool {
        noiseApps.contains(app.lowercased())
    }

    /// App usage breakdown with time estimates.
    func appUsage(days: Int = 7) -> [AppUsageStat] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let events = database.fetchEvents(from: since, to: Date())
            .filter { $0.eventType == .appSwitch }

        var appEventCounts: [String: Int] = [:]
        for event in events {
            guard let app = event.appName, !Self.isNoiseApp(app) else { continue }
            appEventCounts[app, default: 0] += 1
        }

        let total = max(appEventCounts.values.reduce(0, +), 1)

        return appEventCounts
            .sorted { $0.value > $1.value }
            .map { AppUsageStat(appName: $0.key, eventCount: $0.value, percentage: Double($0.value) / Double(total) * 100) }
    }

    // MARK: - Work Rhythm

    /// Hourly activity distribution (0-23).
    func hourlyPattern(days: Int = 7) -> [HourlyStat] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let events = database.fetchEvents(from: since, to: Date())

        var hourCounts = [Int: Int]()
        for event in events {
            let hour = Calendar.current.component(.hour, from: event.timestamp)
            hourCounts[hour, default: 0] += 1
        }

        let maxCount = max(hourCounts.values.max() ?? 1, 1)

        return (0..<24).map { hour in
            let count = hourCounts[hour] ?? 0
            return HourlyStat(
                hour: hour,
                eventCount: count,
                intensity: Double(count) / Double(maxCount)
            )
        }
    }

    /// Peak productivity hours (top 3 most active hours).
    func peakHours(days: Int = 7) -> [Int] {
        hourlyPattern(days: days)
            .sorted { $0.eventCount > $1.eventCount }
            .prefix(3)
            .map(\.hour)
            .sorted()
    }

    /// Day-of-week pattern.
    func weekdayPattern(days: Int = 30) -> [WeekdayStat] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let events = database.fetchEvents(from: since, to: Date())

        var dayCounts = [Int: Int]()
        for event in events {
            let weekday = Calendar.current.component(.weekday, from: event.timestamp)
            dayCounts[weekday, default: 0] += 1
        }

        let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let maxCount = max(dayCounts.values.max() ?? 1, 1)

        return (1...7).map { day in
            let count = dayCounts[day] ?? 0
            return WeekdayStat(
                weekday: day,
                name: dayNames[day],
                eventCount: count,
                intensity: Double(count) / Double(maxCount)
            )
        }
    }

    // MARK: - Language Mix

    /// Ratio of Japanese / English / Code in typed content.
    /// Uses clipboard only — the most reliable source for language detection.
    /// Window titles are mostly English filenames even for Japanese users.
    ///
    /// "Primary language" is a claim about how a *human writes*, so it must be
    /// measured on human prose only. Two things used to corrupt it:
    ///   1. Test/QA input ("the quick brown fox") — pure English letters.
    ///   2. Copied code — identifiers like `viewDidLoad`/`func` are English
    ///      letters and would land in `englishChars`, drowning out real prose.
    /// Both are now excluded from the Japanese-vs-English count: test input is
    /// dropped entirely, and a code snippet is counted whole as `codeChars` so
    /// its identifiers can't masquerade as English.
    func languageMix(days: Int = 7) -> LanguageMix {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let events = database.fetchEvents(from: since, to: Date())
            .filter { $0.eventType == .clipboard }

        var japaneseChars = 0
        var englishChars = 0
        var codeChars = 0

        for event in events {
            guard let text = event.textContent else { continue }
            guard let app = event.appName, !Self.isNoiseApp(app) else { continue }

            // Drop synthetic test/QA input — it's all ASCII letters and would
            // read as English.
            if TestInput.isLikelyTestInput(text) { continue }

            // Count a code snippet as a single code blob so its English-looking
            // identifiers never inflate the human-language ratio.
            if looksLikeCode(text) {
                codeChars += text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
                continue
            }

            // Human prose — this is the only thing the JP/EN ratio is built from.
            for scalar in text.unicodeScalars {
                if (0x3000...0x9FFF).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value) {
                    japaneseChars += 1
                } else if scalar.value < 128 && CharacterSet.letters.contains(scalar) {
                    englishChars += 1
                }
            }
        }

        let total = max(japaneseChars + englishChars + codeChars, 1)
        return LanguageMix(
            japanesePercent: Double(japaneseChars) / Double(total) * 100,
            englishPercent: Double(englishChars) / Double(total) * 100,
            codePercent: Double(codeChars) / Double(total) * 100,
            proseSampleCount: japaneseChars + englishChars
        )
    }

    /// Heuristic: does this clipboard text look like source code rather than
    /// human prose? Used to keep identifiers out of the language ratio.
    private func looksLikeCode(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = ["func ", "let ", "var ", "def ", "class ", "struct ",
                       "import ", "return ", "const ", "public ", "private ",
                       "void ", "=>", "();", "() {", "){", "</", "/>", "});"]
        let hits = markers.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
        if hits >= 2 { return true }

        // High symbol density is the other strong code signal.
        let symbols = CharacterSet(charactersIn: "=(){}<>[];:/\\|+-*&^%$#@")
        let symbolCount = text.unicodeScalars.filter { symbols.contains($0) }.count
        let letterCount = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return letterCount > 0 && Double(symbolCount) / Double(letterCount) > 0.25
    }

    // MARK: - Generate Plain Text Summary for AI

    /// Generate a rule-based analytics summary that can be appended to me.md/now.md.
    /// No LLM needed. Pure data.
    /// Behavioral patterns as a markdown list.
    ///
    /// Bullets, not the bare `Label: value` lines this used to emit. Six of those
    /// stacked on consecutive lines are ONE paragraph to markdown — the newlines
    /// between them are soft breaks — so what read as a table in the source
    /// rendered as a single run-on sentence everywhere the file was displayed.
    /// The caller supplies the heading; the old self-titling first line put
    /// "Behavioral patterns (auto-detected, last 7 days):" directly beneath
    /// whatever heading had just introduced it.
    func generatePatternSummary(days: Int = 7) -> String {
        var lines: [String] = []

        // Top keywords — only show if meaningful results exist
        let keywords = topKeywords(days: days, limit: 15)
            .filter { !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !keywords.isEmpty {
            lines.append("- **Focus topics** — \(keywords.prefix(8).map { "\($0.word) (\($0.count))" }.joined(separator: ", "))")
        }

        // Top phrases — only show if meaningful results exist
        let phrases = topPhrases(days: days, limit: 5)
            .filter { !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !phrases.isEmpty {
            lines.append("- **Recurring themes** — \(phrases.prefix(3).map { "\"\($0.word)\" (\($0.count))" }.joined(separator: ", "))")
        }

        // App usage
        let apps = appUsage(days: days)
        if !apps.isEmpty {
            let topApps = apps.prefix(5).map { "\($0.appName) (\(String(format: "%.0f", $0.percentage))%)" }
            lines.append("- **Top apps** — \(topApps.joined(separator: ", "))")
        }

        // Peak hours
        let peaks = peakHours(days: days)
        if !peaks.isEmpty {
            lines.append("- **Peak hours** — \(peaks.map { "\($0):00" }.joined(separator: ", "))")
        }

        // Language mix
        let lang = languageMix(days: days)
        lines.append("- **Language mix** — Japanese \(String(format: "%.0f", lang.japanesePercent))%, English \(String(format: "%.0f", lang.englishPercent))%, Code \(String(format: "%.0f", lang.codePercent))%")

        // Weekday pattern — only report once enough weekdays have data, so a
        // not-yet-seen day isn't misreported as the "quietest."
        let weekdays = weekdayPattern(days: 30)
        let daysWithData = weekdays.filter { $0.eventCount > 0 }.count
        let busiestDay = weekdays.max(by: { $0.eventCount < $1.eventCount })
        let quietestDay = weekdays.min(by: { $0.eventCount < $1.eventCount })
        if daysWithData >= 4, let busiest = busiestDay, let quietest = quietestDay, busiest.name != quietest.name {
            lines.append("- **Busiest day** — \(busiest.name) · **quietest** — \(quietest.name)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Tokenizer

    /// Split text into words. Handles Japanese (by character), English (by space), code (by symbols).
    private func tokenize(_ text: String) -> [String] {
        var words: [String] = []
        var currentWord = ""

        for char in text {
            if char.isWhitespace || char.isNewline {
                if !currentWord.isEmpty {
                    words.append(currentWord)
                    currentWord = ""
                }
            } else if let scalar = char.unicodeScalars.first,
                      CharacterSet.punctuationCharacters.contains(scalar) ||
                      CharacterSet(charactersIn: "=(){}<>[];:/\\|+-*").contains(scalar) {
                if !currentWord.isEmpty {
                    words.append(currentWord)
                    currentWord = ""
                }
                // Don't add punctuation as a word
            } else {
                currentWord.append(char)
            }
        }
        if !currentWord.isEmpty {
            words.append(currentWord)
        }

        return words
    }

    // MARK: - Stop Words

    /// Common words to exclude from frequency analysis.
    private static let stopWords: Set<String> = [
        // English
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "shall", "can", "need", "dare", "ought",
        "to", "of", "in", "for", "on", "with", "at", "by", "from", "as",
        "into", "through", "during", "before", "after", "above", "below",
        "and", "but", "or", "nor", "not", "so", "yet", "both", "either",
        "it", "its", "this", "that", "these", "those", "he", "she", "they",
        "we", "you", "i", "me", "my", "your", "his", "her", "our", "their",
        "if", "then", "else", "when", "where", "how", "what", "which", "who",
        // Japanese particles / common
        "の", "は", "が", "を", "に", "で", "と", "も", "か", "な",
        "だ", "です", "ます", "する", "した", "して", "ない", "ある",
        "いる", "れる", "られる", "こと", "もの", "ため", "よう",
        "この", "その", "あの", "どの",
        // Code
        "var", "let", "func", "if", "else", "return", "import", "class",
        "struct", "enum", "case", "self", "true", "false", "nil", "void",
        "int", "string", "bool", "private", "public", "static",
        // Date/time noise
        "am", "pm", "at", "01", "02", "03", "04", "05", "06", "07",
        "08", "09", "10", "11", "12", "13", "14", "15", "16", "17",
        "18", "19", "20", "21", "22", "23", "24", "25", "26", "27",
        "28", "29", "30", "31", "2024", "2025", "2026", "2027",
        // File extension / path noise
        "png", "jpg", "jpeg", "gif", "svg", "pdf", "md", "txt",
        "swift", "ts", "tsx", "js", "json", "html", "css",
        "screenshot", "img", "image", "file", "folder",
        "users", "downloads", "documents", "library",
        "developer", "xcode", "deriveddata", "build", "products",
        "debug", "release", "contents", "macos", "resources",
        "about", "auto", "updated",
        // Xcode noise
        "cfbundleshortversionstring", "cfbundleversion", "cfbundlename",
        "cfbundleidentifier", "infoplist", "plist",
        "thread", "queue", "serial", "main",
        "validation", "failed", "invalid", "error",
        // URL / web noise
        "https", "http", "www", "com", "app", "vercel",
        "org", "net", "miis", "maths", "industry", "studygroups",
        "category", "tag", "view", "page", "index",
        "該当なし", "インデックス", "クロール", "登録",
        // Japanese business-email boilerplate — these are politeness formulas,
        // not topics. Surfacing "ご確認のほど" as a "focus topic" is noise.
        "ご確認のほど", "ご確認", "よろしくお願いいたします", "よろしくお願いします",
        "お願いいたします", "お願い致します", "ご返信お願い致します", "ご返信",
        "お世話になっております", "お世話になります", "ご興味をお持ちいただけましたら",
        "ご連絡", "ご案内", "拝啓", "敬具", "各位", "ご質問", "その他",
    ]

    /// Path noise that is machine-specific rather than universal.
    ///
    /// The account name appears in every `/Users/<name>/…` title and every
    /// derived-data path, so it out-ranks real topics. It used to be hard-coded
    /// as one developer's login name, which meant this filter worked on exactly
    /// one Mac and leaked that name into the source; read it from the running
    /// account instead.
    private static let accountWords: Set<String> = {
        let home = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
        return Set([NSUserName(), home]
            .map { $0.lowercased() }
            .filter { $0.count > 2 })
    }()

    /// What `analyze` actually filters against.
    private static let allStopWords: Set<String> = stopWords.union(accountWords)
}

// MARK: - Data Types

struct KeywordStat: Identifiable {
    let word: String
    let count: Int
    var id: String { word }
}

struct AppUsageStat: Identifiable {
    let appName: String
    let eventCount: Int
    let percentage: Double
    var id: String { appName }
}

struct HourlyStat: Identifiable {
    let hour: Int
    let eventCount: Int
    let intensity: Double // 0.0 to 1.0
    var id: Int { hour }
}

struct WeekdayStat: Identifiable {
    let weekday: Int
    let name: String
    let eventCount: Int
    let intensity: Double
    var id: Int { weekday }
}

struct LanguageMix {
    let japanesePercent: Double
    let englishPercent: Double
    let codePercent: Double
    /// Number of human-prose letters (Japanese + English) the ratio was built
    /// from. A confidence gate: too few letters means "don't claim a primary
    /// language yet."
    var proseSampleCount: Int = 0
}
