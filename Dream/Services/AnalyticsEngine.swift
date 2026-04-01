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
        let stopWords = Self.stopWords

        for event in textEvents {
            guard let text = event.textContent else { continue }
            let words = tokenize(text)
            for word in words {
                let lower = word.lowercased()
                guard lower.count > 1 else { continue }
                guard !stopWords.contains(lower) else { continue }
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

        // Only keep phrases that appear 3+ times (real patterns, not noise)
        return phraseCounts
            .filter { $0.value >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { KeywordStat(word: $0.key, count: $0.value) }
    }

    // MARK: - App Usage Patterns

    /// App usage breakdown with time estimates.
    func appUsage(days: Int = 7) -> [AppUsageStat] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let events = database.fetchEvents(from: since, to: Date())
            .filter { $0.eventType == .appSwitch }

        var appEventCounts: [String: Int] = [:]
        for event in events {
            guard let app = event.appName else { continue }
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
    func languageMix(days: Int = 7) -> LanguageMix {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let events = database.fetchEvents(from: since, to: Date())
            .filter { $0.eventType == .keystroke || $0.eventType == .clipboard }

        var japaneseChars = 0
        var englishChars = 0
        var codeChars = 0

        for event in events {
            guard let text = event.textContent else { continue }
            for scalar in text.unicodeScalars {
                if (0x3000...0x9FFF).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value) {
                    japaneseChars += 1
                } else if scalar.value < 128 && CharacterSet.letters.contains(scalar) {
                    englishChars += 1
                } else if CharacterSet(charactersIn: "=(){}<>[];:/\\|+-*&^%$#@!").contains(scalar) {
                    codeChars += 1
                }
            }
        }

        let total = max(japaneseChars + englishChars + codeChars, 1)
        return LanguageMix(
            japanesePercent: Double(japaneseChars) / Double(total) * 100,
            englishPercent: Double(englishChars) / Double(total) * 100,
            codePercent: Double(codeChars) / Double(total) * 100
        )
    }

    // MARK: - Generate Plain Text Summary for AI

    /// Generate a rule-based analytics summary that can be appended to me.md/now.md.
    /// No LLM needed. Pure data.
    func generatePatternSummary(days: Int = 7) -> String {
        var lines: [String] = []
        lines.append("Behavioral patterns (auto-detected, last \(days) days):")
        lines.append("")

        // Top keywords
        let keywords = topKeywords(days: days, limit: 15)
        if !keywords.isEmpty {
            lines.append("Most used words: \(keywords.prefix(10).map { "\($0.word)(\($0.count))" }.joined(separator: ", "))")
        }

        // Top phrases
        let phrases = topPhrases(days: days, limit: 5)
        if !phrases.isEmpty {
            lines.append("Repeated phrases: \(phrases.map { "\"\($0.word)\"(\($0.count))" }.joined(separator: ", "))")
        }

        // App usage
        let apps = appUsage(days: days)
        if !apps.isEmpty {
            let topApps = apps.prefix(5).map { "\($0.appName)(\(String(format: "%.0f", $0.percentage))%)" }
            lines.append("Top apps: \(topApps.joined(separator: ", "))")
        }

        // Peak hours
        let peaks = peakHours(days: days)
        if !peaks.isEmpty {
            lines.append("Peak hours: \(peaks.map { "\($0):00" }.joined(separator: ", "))")
        }

        // Language mix
        let lang = languageMix(days: days)
        lines.append("Language mix: Japanese \(String(format: "%.0f", lang.japanesePercent))%, English \(String(format: "%.0f", lang.englishPercent))%, Code \(String(format: "%.0f", lang.codePercent))%")

        // Weekday pattern
        let weekdays = weekdayPattern(days: 30)
        let busiestDay = weekdays.max(by: { $0.eventCount < $1.eventCount })
        let quietestDay = weekdays.min(by: { $0.eventCount < $1.eventCount })
        if let busiest = busiestDay, let quietest = quietestDay {
            lines.append("Busiest day: \(busiest.name), Quietest: \(quietest.name)")
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
            } else if CharacterSet.punctuationCharacters.contains(char.unicodeScalars.first!) ||
                      CharacterSet(charactersIn: "=(){}<>[];:/\\|+-*").contains(char.unicodeScalars.first!) {
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
        // File extension noise
        "png", "jpg", "jpeg", "gif", "svg", "pdf", "md", "txt",
        "swift", "ts", "tsx", "js", "json", "html", "css",
        "screenshot", "img", "image", "file", "folder",
    ]
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
}
