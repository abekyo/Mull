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
    /// Dedup keys for emails already recorded, bounded so a long-running session with a
    /// busy inbox can't grow this without limit. `seenOrder` is the insertion order used
    /// to evict the oldest key once we pass the cap.
    ///
    /// Known limitation: this lives in memory only, so a relaunch forgets it and the
    /// next poll re-records whatever is still inside Mail's 24h window as fresh events.
    /// Fixing that properly needs persistence, and a new DB table is out of scope here.
    private var seenSubjects: Set<String> = []
    private var seenOrder: [String] = []
    private static let maxSeenSubjects = 2_000

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
            noteSeen(key)

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

    /// Record a dedup key, evicting the oldest keys once the cap is reached. Eviction is
    /// safe for our purpose: keys age out roughly in the order they arrived, and Mail
    /// only ever hands us the last 24h, so an evicted key is one we're unlikely to see
    /// again — at worst a very old mail is recorded twice.
    private func noteSeen(_ key: String) {
        seenSubjects.insert(key)
        seenOrder.append(key)
        guard seenOrder.count > Self.maxSeenSubjects else { return }
        let overflow = seenOrder.count - Self.maxSeenSubjects
        for old in seenOrder.prefix(overflow) { seenSubjects.remove(old) }
        seenOrder.removeFirst(overflow)
    }

    /// Sender-side markers for the same built-in categories the subject is screened for.
    /// Matched against the whole `sender` string (Mail hands us "Name <addr@host>"), so
    /// both the display name and the address/domain are covered.
    ///
    /// Why this exists: subject-only screening broke the "bank notices are auto-excluded"
    /// promise the moment a bank wrote a neutral subject — `alerts@chase.com` /
    /// "Your July summary is ready" matched nothing and was recorded.
    private static let excludedSenderMarkers: [String] = [
        // Security / no-reply automation
        "noreply", "no-reply", "donotreply", "do-not-reply", "security@", "accounts@",
        "verify", "verification", "auth@", "otp@",
        // Financial institutions and payment processors
        "bank", "銀行", "chase", "wellsfargo", "citibank", "capitalone", "amex",
        "americanexpress", "paypal", "stripe", "visa", "mastercard", "mufg", "smbc",
        "mizuho", "rakuten-bank", "card@", "billing@", "invoice@",
        // Bulk / marketing senders
        "newsletter", "marketing@", "mailer", "notifications@", "notification@",
    ]

    /// Exclude sensitive emails by pattern.
    private func isExcluded(subject: String, sender: String) -> Bool {
        let lower = subject.lowercased()
        let senderLower = sender.lowercased()

        // Password / security
        if lower.contains("password") || lower.contains("reset") ||
           lower.contains("verification code") || lower.contains("認証コード") ||
           lower.contains("パスワード") { return true }

        // Financial
        if lower.contains("bank") || lower.contains("credit card") ||
           lower.contains("statement") || lower.contains("口座") { return true }

        // Spam / marketing
        if lower.contains("unsubscribe") || lower.contains("配信停止") { return true }

        // Same categories, matched on who sent it rather than what it's titled.
        if Self.excludedSenderMarkers.contains(where: { senderLower.contains($0) }) { return true }

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
