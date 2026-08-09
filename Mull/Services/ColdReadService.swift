import Foundation
import AppKit
import EventKit

/// What mull can already see the instant permissions are granted, before it has
/// recorded anything.
///
/// This is not a cold read and must not perform like one. A fortune-teller's trick
/// works by hiding where the knowledge came from, and DESIGN-NORTHSTAR §3.5 names
/// exactly that as a DON'T ("出所を隠した不気味な的中"): the understudy shows its
/// sources. So every fact here names what it was read from — the running apps, the
/// front window's title, the clipboard, the calendar — and stops there. mull reports
/// the observation; the user is the one who knows what it means.
///
/// Two rules govern everything below:
///
/// - **Name the source.** The moment this produces should be "it can see that
///   already?", not "how could it possibly know that?" The first is legible. The
///   second is a stranger reading your mind, and it is the wrong first impression
///   for a custode.
/// - **Never assert an absence you can't verify.** Without calendar access mull
///   cannot tell an empty day from a day it isn't allowed to look at, and saying
///   "nothing on your calendar today" in that state is simply a false statement
///   about the user's life. It says what it can't see instead.
struct ColdReadService {

    /// How long any one blocking system call is given before mull gives up on it.
    /// The Accessibility round-trip goes to another process: if that process is
    /// wedged (a spinning beachball, a modal dialog), the default AX messaging
    /// timeout is several seconds, and onboarding would sit frozen behind it.
    private static let callTimeout: TimeInterval = 1.0

    /// Gather everything knowable right now, without any recording history.
    ///
    /// `async`, and bounded: the blocking parts (Accessibility, EventKit) run off
    /// the main thread and are abandoned after `budget`, so the caller's UI keeps
    /// drawing no matter what state the rest of the machine is in. A read that runs
    /// out of time returns whatever it had — a short reading, never a hang.
    static func read(budget: TimeInterval = 2.5) async -> ColdReading {
        // Cheap, main-thread-affine snapshots first: AppKit's app list and the
        // pasteboard. These don't cross a process boundary, so they can't wedge.
        let snapshot = await MainActor.run { Snapshot.capture() }

        // Everything knowable without crossing a process boundary — what the read
        // falls back to when the parts that do cross one never come back. It keeps
        // the clipboard alongside the app list: both came from the cheap pass that
        // has already finished, so dropping one of them on timeout made the short
        // reading shorter than it needed to be.
        let fallback = ColdReading(facts: snapshot.appFacts + [snapshot.clipboardFact].compactMap { $0 },
                                   runningApps: snapshot.runningApps,
                                   frontApp: snapshot.frontAppName,
                                   frontWindow: nil,
                                   schedule: [],
                                   calendarAccess: .unknown,
                                   timedOut: true)

        // A syscall already in flight can't be interrupted, so the budget can only
        // be something the caller *returns* from — never a wait for the slow half
        // to notice it has been cancelled.
        return await withCheckedContinuation { (continuation: CheckedContinuation<ColdReading, Never>) in
            let answer = FirstAnswer(continuation)

            // The blocking half: Accessibility across a process boundary, then
            // EventKit. Raced, never awaited.
            Task.detached(priority: .userInitiated) {
                var facts = snapshot.appFacts

                let windowTitle = Self.frontWindowTitle(snapshot)
                if let title = windowTitle {
                    facts.append(Self.frontWindowFact(title: title, appName: snapshot.frontAppName))
                }
                if let clipboardFact = snapshot.clipboardFact { facts.append(clipboardFact) }

                let calendar = Self.readCalendar()
                // A blind spot is worth naming next to things mull *can* see. On its
                // own it isn't a reading — a screen whose only line is "mull can't
                // read your calendar" should fall through to the empty state instead.
                if calendar.access == .granted || !facts.isEmpty {
                    facts.append(contentsOf: calendar.facts)
                }

                answer.resume(ColdReading(facts: facts,
                                          runningApps: snapshot.runningApps,
                                          frontApp: snapshot.frontAppName,
                                          frontWindow: windowTitle,
                                          schedule: calendar.schedule,
                                          calendarAccess: calendar.access,
                                          timedOut: false))
            }

            // The budget itself. Take what the cheap pass already knows and move on.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                answer.resume(fallback)
            }
        }
    }

    /// Whichever of the two racers above answers first, delivered exactly once.
    ///
    /// `withTaskGroup` cannot express this race, which is what it was written as.
    /// A task group awaits every child on the way out of its scope, so a group
    /// whose losing child is parked in a blocking Accessibility call returns only
    /// once that call finishes — budget or no budget. Measured against a wedged
    /// front app, a 2.5s budget picked the right (short) reading and then handed
    /// it back five seconds late, which is the single thing the budget exists to
    /// prevent; the `timedOut` flag was reachable but the deadline was not.
    ///
    /// One continuation has no such join. The loser resumes nothing, and the
    /// abandoned work finishes into this box, which drops it.
    private final class FirstAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ColdReading, Never>?

        init(_ continuation: CheckedContinuation<ColdReading, Never>) {
            self.continuation = continuation
        }

        func resume(_ reading: ColdReading) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: reading)
        }
    }

    // MARK: - Cheap snapshot (main thread, no cross-process calls)

    private struct Snapshot {
        let runningApps: [String]
        let appFacts: [String]
        let frontAppName: String
        let frontAppPID: pid_t?
        let clipboardFact: String?

        @MainActor
        static func capture() -> Snapshot {
            let runningApps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.localizedName)
            let front = NSWorkspace.shared.frontmostApplication

            return Snapshot(
                runningApps: runningApps,
                appFacts: appFacts(for: Set(runningApps)),
                frontAppName: front?.localizedName ?? "",
                frontAppPID: front?.processIdentifier,
                clipboardFact: clipboardFact()
            )
        }

        /// 1. What is open. Named, counted, and attributed — no inference about why.
        private static func appFacts(for running: Set<String>) -> [String] {
            let devApps = Set(["Xcode", "Code", "Visual Studio Code", "Cursor", "IntelliJ IDEA",
                               "Android Studio", "Terminal", "iTerm2", "Warp", "Ghostty", "Zed"])
            let designApps = Set(["Figma", "Sketch", "Photoshop", "Illustrator", "Canva"])
            let commApps = Set(["Slack", "Discord", "Teams", "Zoom", "Messages"])

            let dev = running.intersection(devApps)
            let design = running.intersection(designApps)
            let comm = running.intersection(commApps)

            var facts: [String] = []

            if dev.count >= 2 {
                facts.append("Open right now: \(dev.sorted().joined(separator: ", ")).")
            } else if let app = dev.first {
                facts.append("\(app) is open right now.")
            }

            if !design.isEmpty && !dev.isEmpty {
                facts.append("Also open: \(design.sorted().joined(separator: ", ")), alongside the editors.")
            }

            // The absence of the comm apps is a real observation. What it *means* —
            // focus, avoidance, a quiet morning — is not mull's to say.
            if comm.isEmpty && dev.count >= 1 {
                facts.append("No chat or meeting apps are running.")
            } else if comm.count >= 2 {
                facts.append("Running now: \(comm.sorted().joined(separator: ", ")).")
            }

            return facts
        }

        /// 3. The clipboard, reported as the clipboard. What it was copied *for* is a
        ///    guess, and a guess dressed as knowledge is the uncanny hit §3.5 bans.
        ///    Reported by *shape*, never by content. This runs on the first screen the
        ///    user ever sees, before any trust exists — quoting whatever happens to be
        ///    on the pasteboard means mull's opening line can be someone's password,
        ///    2FA code, or private message read back to them. Naming the shape lands
        ///    the same "how do you know that?" without holding a secret hostage.
        private static func clipboardFact() -> String? {
            guard let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty else { return nil }
            if SensitiveText.isSensitive(clip) {
                return "There is something on your clipboard. mull won't repeat it."
            }
            if clip.contains("func ") || clip.contains("class ") || clip.contains("import ") {
                return "There is code on your clipboard."
            }
            let words = clip.split(whereSeparator: \.isWhitespace).count
            return "There is text on your clipboard — about \(words) \(words == 1 ? "word" : "words")."
        }
    }

    // MARK: - Front window (Accessibility — blocking, bounded)

    /// 2. The front window's title, raw.
    ///
    /// Kept separate from the sentence built out of it (`frontWindowFact`) because
    /// the two have different readers: the sentence is for a person on the
    /// onboarding screen, the raw title is what goes into the context block handed
    /// to an AI, where mull's phrasing would only be noise around the fact.
    private static func frontWindowTitle(_ snapshot: Snapshot) -> String? {
        guard let pid = snapshot.frontAppPID else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        // Bound the cross-process wait. Without this an unresponsive frontmost app
        // holds the read for the AX default (seconds), which the user experiences as
        // onboarding freezing right after they granted a permission.
        AXUIElementSetMessagingTimeout(appElement, Float(Self.callTimeout))

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let ref = windowRef,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        // Checked above rather than force-cast blind: a non-conforming app can return
        // something that isn't an AXUIElement, and the old `as!` crashed on it.
        let window = ref as! AXUIElement

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
    }

    /// The same title, said to be the front window's title.
    private static func frontWindowFact(title: String, appName: String) -> String {
        if title.contains(".swift") || title.contains(".ts") || title.contains(".py") {
            let fileName = title.components(separatedBy: " ").first(where: { $0.contains(".") }) ?? title
            return "\(fileName) is the open file in \(appName)."
        }
        return "The front window is \"\(String(title.prefix(60)))\" in \(appName)."
    }

    // MARK: - Calendar (EventKit — blocking, and only speaks when it can see)

    private struct CalendarReading {
        let access: ColdReading.CalendarAccess
        let facts: [String]
        let schedule: [String]
    }

    /// 4. Today's calendar. Stated, never used to hurry the user along
    ///    (§1 Ritmo umano: 急かさない) — and never asserted without access.
    private static func readCalendar() -> CalendarReading {
        let status = EKEventStore.authorizationStatus(for: .event)
        // macOS 14 is the deployment target and read access is the only grant that
        // lets mull see events; "Add only" (.writeOnly) can write but not read, so it
        // is not knowledge. Same test HomeTab uses, so the two screens agree.
        guard status == .fullAccess else {
            // Say what mull can't see, and why. An unknown day is not an empty day.
            let line: String
            switch status {
            case .denied, .restricted, .writeOnly:
                line = "mull can't read your calendar — that permission is off, so today's schedule isn't part of this."
            default:
                line = "mull hasn't been given calendar access yet, so it can't see your schedule."
            }
            return CalendarReading(access: .unavailable, facts: [line], schedule: [])
        }

        let store = EKEventStore()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return CalendarReading(access: .unknown, facts: [], schedule: [])
        }
        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        guard !events.isEmpty else {
            // Verified empty — mull looked, and there is nothing there.
            return CalendarReading(access: .granted,
                                   facts: ["Your calendar is clear today — mull looked."],
                                   schedule: [])
        }

        // These lines are read by the person, not by an AI, so they follow the
        // reader's clock. (A bare "HH:mm" formatter would not have anyway — an
        // unpinned locale rewrites that pattern; see `TimeFormat`.)
        var facts: [String] = []

        // The next meeting, as a time on a clock. No nudge, no question.
        if let next = events.first(where: { $0.startDate > Date() }),
           next.startDate.timeIntervalSince(Date()) < 3600 {
            facts.append("\"\(next.title ?? "A meeting")\" is at \(TimeFormat.person(next.startDate)), from your calendar.")
        }

        // The count, without a verdict on what kind of day that makes.
        if events.count >= 4 {
            facts.append("Your calendar has \(events.count) events today.")
        }

        let schedule = events.prefix(3).map { "\(TimeFormat.person($0.startDate)) \($0.title ?? "Meeting")" }
        return CalendarReading(access: .granted, facts: facts, schedule: schedule)
    }
}

struct ColdReading {
    /// Whether the calendar part of this reading is knowledge or a blind spot.
    /// `unknown` means mull ran out of time before it looked — also not "empty".
    enum CalendarAccess { case granted, unavailable, unknown }

    let facts: [String]
    let runningApps: [String]
    let frontApp: String
    /// The front window's title, unedited. Nil when Accessibility is not granted,
    /// the app exposes no focused window, or the read ran out of budget.
    let frontWindow: String?
    let schedule: [String]
    var calendarAccess: CalendarAccess = .unknown
    /// True when the read was abandoned on its time budget. The facts present are
    /// still true; they are just fewer than a complete pass would have found.
    var timedOut: Bool = false

    var isEmpty: Bool { facts.isEmpty }

    /// The reading rewritten as a context block a person can hand to an AI.
    ///
    /// This exists because of what onboarding's last screen used to be: it promised
    /// "this is what you'd hand an AI" and then, for every single first-time user,
    /// showed an empty pane above a disabled button — the record is empty on a fresh
    /// install by definition, so the one screen carrying the product's whole claim
    /// was guaranteed to fail on the only run where it matters. What is true at that
    /// moment is this: mull cannot yet say what you did, but it can already say what
    /// you are doing. That is a smaller claim, and it is one the screen can keep.
    ///
    /// Two things are deliberately left out:
    ///
    /// - **The blind-spot lines.** "mull hasn't been given calendar access yet" is
    ///   worth telling the *user*; pasted into a chat it is a sentence about mull's
    ///   permissions, not about the person, and it would be the AI's first
    ///   impression of them.
    /// - **The clipboard.** `facts` reports it by shape only, and even that is a
    ///   statement about a buffer the user has not agreed to send anywhere. The
    ///   onboarding screen may name it; the clipboard payload must not carry it.
    func contextBlock() -> String {
        var lines: [String] = []

        if !runningApps.isEmpty {
            // Capped, and said to be capped. The unbounded list is ten lines of
            // menu-bar utilities that say nothing about the work.
            let named = runningApps.sorted().prefix(8)
            var line = "- Open on this Mac: \(named.joined(separator: ", "))"
            if runningApps.count > named.count { line += " (and \(runningApps.count - named.count) more)" }
            lines.append(line)
        }

        if let window = frontWindow, !frontApp.isEmpty {
            lines.append("- In front: \"\(String(window.prefix(80)))\" in \(frontApp)")
        }

        // Only when mull actually looked. An unknown day is not an empty day, so
        // silence here is the honest output — never "no meetings today".
        if calendarAccess == .granted && !schedule.isEmpty {
            lines.append("- Today's schedule: \(schedule.joined(separator: " · "))")
        }

        guard !lines.isEmpty else { return "" }
        return "# On this Mac right now\n\n"
            + "_Read live from the running apps and open windows — mull has not recorded a day yet._\n\n"
            + lines.joined(separator: "\n")
    }
}
