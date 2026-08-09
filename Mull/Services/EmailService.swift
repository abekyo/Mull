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

    // MARK: - Access problems
    //
    // Talking to Mail.app raises a macOS Automation prompt, and the old code had
    // no branch for "the user said no": the script wrapped its whole body in a
    // bare `try`, `fetchRecent` returned on any error, and the Settings toggle
    // stayed visibly ON promising a capture that would never happen again for the
    // life of the install. A silent permanent failure is the worst kind — the
    // problem is now a value the UI can show.

    /// Why mull can't read mail headers, in the user's terms.
    /// `Error` so it can travel as the failure of a `Result` from the script runner.
    enum AccessProblem: Error, Equatable, Sendable {
        /// The macOS Automation permission was denied (AppleScript error -1743).
        case automationDenied
        /// Mail.app has no accounts, so there is no inbox to read.
        case mailNotConfigured
        /// Anything else AppleScript reported, verbatim.
        case scriptFailed(String)

        var message: String {
            switch self {
            case .automationDenied:
                "macOS is blocking mull from controlling Mail. Allow it in System Settings › Privacy & Security › Automation › mull › Mail."
            case .mailNotConfigured:
                "Mail.app has no accounts set up, so there is no inbox to read."
            case .scriptFailed(let detail):
                "Mail returned an error: \(detail)"
            }
        }

        /// Only the Automation case can be re-asked from inside mull; the rest
        /// need something fixed outside it.
        var isPermission: Bool { self == .automationDenied }
    }

    /// AppleScript is not thread-safe and mull now runs it from two places (the
    /// five-minute poll and the Settings access check), so every Apple event goes
    /// through one serial queue. Keeping it off the main thread also means the
    /// Settings window stays alive while macOS puts up the Automation prompt.
    private static let scriptQueue = DispatchQueue(label: "com.mull.email.applescript")

    /// The last thing that went wrong talking to Mail, or nil if the last attempt
    /// worked. Static and lock-guarded because the poll writes it from
    /// `scriptQueue` while Settings reads it on the main thread.
    private static let problemLock = NSLock()
    private static var storedProblem: AccessProblem?

    /// Called once when a working capture starts failing, so the app can say so
    /// somewhere the user is actually looking. Set by AppState; the poll runs on
    /// `scriptQueue`, so implementations must hop to the main actor themselves.
    nonisolated(unsafe) static var onProblemAppeared: ((AccessProblem) -> Void)?

    static var lastProblem: AccessProblem? {
        get { problemLock.lock(); defer { problemLock.unlock() }; return storedProblem }
        set { problemLock.lock(); storedProblem = newValue; problemLock.unlock() }
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
        // Turning capture off retires the old complaint with it — otherwise the
        // error row outlives the setting that caused it.
        if isEnabled { start() } else { Self.lastProblem = nil }
    }

    /// Ask Mail whether mull can actually read it, raising the Automation prompt
    /// if it hasn't been answered yet. Returns nil when capture will work.
    ///
    /// Deliberately a *static* probe with no side effects beyond `lastProblem`:
    /// Settings calls it the moment the user opts in, so the toggle can report the
    /// real answer instead of assuming one.
    static func checkMailAccess() async -> AccessProblem? {
        await withCheckedContinuation { continuation in
            scriptQueue.async {
                let problem = probeAccounts()
                lastProblem = problem
                continuation.resume(returning: problem)
            }
        }
    }

    /// The smallest question that still triggers the Automation prompt, and whose
    /// answer also distinguishes "denied" from "Mail has no accounts" — two
    /// failures that look identical from an empty inbox query.
    private static func probeAccounts() -> AccessProblem? {
        let script = """
        tell application "Mail"
            return (count of accounts)
        end tell
        """
        guard let scriptObj = NSAppleScript(source: script) else {
            return .scriptFailed("mull could not compile its Mail query.")
        }
        var error: NSDictionary?
        let result = scriptObj.executeAndReturnError(&error)
        if let error { return problem(from: error) }
        return result.int32Value > 0 ? nil : .mailNotConfigured
    }

    /// Map AppleScript's error dictionary onto something a person can act on.
    /// -1743 is `errAEEventNotPermitted` — the Automation denial, and the whole
    /// reason this mapping exists.
    private static func problem(from error: NSDictionary) -> AccessProblem {
        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown error \(code)"
        switch code {
        case -1743, -1744:
            return .automationDenied
        case -600, -1728:
            // Mail isn't running/installed, or there is no inbox object to get.
            return .mailNotConfigured
        default:
            return .scriptFailed(message)
        }
    }

    /// Fetch recent emails (last 24h) from Mail.app.
    ///
    /// Runs on `scriptQueue`, so a hung or prompting Apple event can't freeze the
    /// UI. Every mutation of the dedup set happens on that one queue.
    private func fetchRecent() {
        guard isEnabled else { return }
        Self.scriptQueue.async { [weak self] in
            guard let self, self.isEnabled else { return }
            let hadProblem = Self.lastProblem != nil
            switch Self.runInboxQuery() {
            case .failure(let problem):
                Self.lastProblem = problem
                // Settings › Data was the only place this ever showed, so a
                // permission revoked months after the user agreed left the
                // toggle on, the capture dead, and nothing anywhere saying so.
                // Announce the transition once — not on every five-minute poll.
                if !hadProblem { Self.onProblemAppeared?(problem) }
            case .success(let output):
                Self.lastProblem = nil
                self.record(output)
            }
        }
    }

    /// Ask Mail for the last 24h of headers. The body is no longer wrapped in a
    /// blanket `try` — swallowing the error there is what turned a denied prompt
    /// into a permanently, silently empty capture.
    private static func runInboxQuery() -> Result<String, AccessProblem> {
        let script = """
        tell application "Mail"
            set output to ""
            set recentMessages to (every message of inbox whose date received > (current date) - 86400)
            repeat with msg in recentMessages
                set msgSubject to subject of msg
                set msgSender to sender of msg
                set msgDate to date received of msg
                set output to output & msgSubject & "\\t" & msgSender & "\\t" & (msgDate as string) & "\\n"
            end repeat
            return output
        end tell
        """

        guard let scriptObj = NSAppleScript(source: script) else {
            return .failure(.scriptFailed("mull could not compile its Mail query."))
        }
        var error: NSDictionary?
        let result = scriptObj.executeAndReturnError(&error)
        if let error { return .failure(problem(from: error)) }
        return .success(result.stringValue ?? "")
    }

    /// Turn the tab-separated script output into events.
    private func record(_ output: String) {
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
