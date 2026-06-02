import Foundation
import AppKit

/// Captures email metadata from Mail.app via AppleScript.
/// Phase 1: Subject + sender only. Body is never read.
///
/// Privacy: OFF by default. User must opt-in in Settings → Data.
final class EmailService {

    private let database: DatabaseService
    private var pollTimer: Timer?
    private var lastFetchDate: Date = Date()
    private var seenSubjects: Set<String> = []

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "emailCaptureEnabled")
    }

    init(database: DatabaseService) {
        self.database = database
    }

    /// Start polling Mail.app every 5 minutes for new emails.
    func start() {
        guard isEnabled else { return }
        fetchRecent()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.fetchRecent()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Restart if settings changed.
    func refreshState() {
        stop()
        if isEnabled { start() }
    }

    /// Fetch recent emails (last 24h) from Mail.app.
    private func fetchRecent() {
        guard isEnabled else { return }

        let script = """
        tell application "Mail"
            set output to ""
            try
                set recentMessages to (every message of inbox whose date received > (current date) - 86400)
                repeat with msg in recentMessages
                    set msgSubject to subject of msg
                    set msgSender to sender of msg
                    set msgDate to date received of msg
                    set output to output & msgSubject & "\\t" & msgSender & "\\t" & (msgDate as string) & "\\n"
                end repeat
            end try
            return output
        end tell
        """

        var error: NSDictionary?
        guard let scriptObj = NSAppleScript(source: script) else { return }
        let result = scriptObj.executeAndReturnError(&error)

        guard error == nil, let output = result.stringValue, !output.isEmpty else { return }

        // Parse tab-separated lines
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        for line in lines {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }

            let subject = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let sender = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            // Dedup — don't re-record same email
            let key = "\(subject)|\(sender)"
            guard !seenSubjects.contains(key) else { continue }
            seenSubjects.insert(key)

            // Skip excluded patterns
            if isExcluded(subject: subject, sender: sender) { continue }

            let text = "\(sender): \(subject)"
            let event = RecordingEvent(
                timestamp: Date(),
                eventType: .screenText, // Reuse screenText type for now
                appName: "Mail",
                windowTitle: subject,
                textContent: text
            )
            database.insertEvent(event)
        }
    }

    /// Exclude sensitive emails by pattern.
    private func isExcluded(subject: String, sender: String) -> Bool {
        let lower = subject.lowercased()

        // Password / security
        if lower.contains("password") || lower.contains("reset") ||
           lower.contains("verification code") || lower.contains("認証コード") ||
           lower.contains("パスワード") { return true }

        // Financial
        if lower.contains("bank") || lower.contains("credit card") ||
           lower.contains("statement") || lower.contains("口座") { return true }

        // Spam / marketing
        if lower.contains("unsubscribe") || lower.contains("配信停止") { return true }

        // Excluded senders from user settings
        let excludedSenders = UserDefaults.standard.stringArray(forKey: "emailExcludedSenders") ?? []
        for excluded in excludedSenders {
            if sender.lowercased().contains(excluded.lowercased()) { return true }
        }

        return false
    }

    /// Get recent email summary for now.md (no body, just metadata).
    func recentEmailSummary(hours: Int = 24) -> String? {
        guard isEnabled else { return nil }

        let since = Calendar.current.date(byAdding: .hour, value: -hours, to: Date())!
        let events = database.fetchEvents(from: since, to: Date())
            .filter { $0.appName == "Mail" }

        guard !events.isEmpty else { return nil }

        var lines: [String] = ["Recent emails:"]
        var seen = Set<String>()

        for event in events.reversed() {
            guard let text = event.textContent else { continue }
            let key = String(text.prefix(80).lowercased())
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            lines.append("- \(text)")
            if seen.count >= 10 { break }
        }

        return lines.joined(separator: "\n")
    }
}
